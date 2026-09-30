import Foundation

/// Signal path: HackRF -> ring -> DSP thread (atsc_rx, with its own worker threads) -> transport
/// packets -> media thread (demux, PSIP, decode) -> Player. Callbacks to the app arrive on the
/// media thread and are forwarded to the main thread.
final class Engine {
    let ring = SampleRing()
    let player = Player()
    private(set) var device: HackRFDevice?
    private var rx: OpaquePointer?
    private var media: OpaquePointer?

    // packets from the demodulator to the media thread
    private let pktLock = NSLock()
    private var pktBuf = [UInt8]()
    private var pktOK = [UInt8]()
    private let pktSignal = DispatchSemaphore(value: 0)

    // commands for the media thread
    private let cmdLock = NSLock()
    private var cmdReset = false
    private var cmdProgram: Int?
    private var cmdAudio: Int?
    private var cmdCaptions: Int?

    /// Audio tracks and caption services of the selected program, refreshed by the media thread.
    struct ProgramInfo: Equatable {
        var audio: [AudioTrack] = []
        var captions: [CaptionService] = []
    }
    struct AudioTrack: Equatable { var pid: Int; var codec: String; var lang: String; var role: Int; var channels: Int }
    struct CaptionService: Equatable { var lang: String; var digital: Bool; var number: Int; var easyReader: Bool }
    var onProgramInfo: ((ProgramInfo) -> Void)?
    private var lastInfo = ProgramInfo()

    // retune requests for the DSP thread
    private let tuneLock = NSLock()
    private var tuneGen = 0, tuneHint = 0.0

    // recording
    private let recLock = NSLock()
    private var recFile: FileHandle?
    private var recPIDs = Set<Int>()
    private var recBuffer = Data()

    // app callbacks (main thread)
    var onChannels: (([VirtualChannel]) -> Void)?
    var onEvent: ((Int, GuideEvent) -> Void)?           // source_id, event
    var onFormat: ((Int, Int, Bool, Int) -> Void)?      // width, height, interlaced, audio channels
    var onClock: ((Date) -> Void)?
    var currentRF = 0

    private(set) var overruns = 0
    private var started = false

    init() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        rx = atsc_rx_create(20e6, 0, { ctx, pkt, ok in
            guard let ctx, let pkt else { return }
            Unmanaged<Engine>.fromOpaque(ctx).takeUnretainedValue().packet(pkt, ok != 0)
        }, ctx)
        var cb = atsc_media_cb()
        cb.ctx = ctx
        cb.video = { ctx, y, u, v, ys, uvs, w, h, sn, sd, pts in
            guard let ctx, let y, let u, let v else { return }
            Unmanaged<Engine>.fromOpaque(ctx).takeUnretainedValue().player.video(
                y: y, u: u, v: v, yStride: Int(ys), uvStride: Int(uvs), width: Int(w), height: Int(h),
                sarNum: Int(sn), sarDen: Int(sd), pts: pts)
        }
        cb.audio = { ctx, s, n, rate, pts in
            guard let ctx, let s else { return }
            Unmanaged<Engine>.fromOpaque(ctx).takeUnretainedValue().player.audio(stereo: s, frames: Int(n), rate: Int(rate), pts: pts)
        }
        cb.channels = { ctx, ch, n in
            guard let ctx, let ch else { return }
            let e = Unmanaged<Engine>.fromOpaque(ctx).takeUnretainedValue()
            let rf = e.currentRF
            let list = (0..<Int(n)).map { i -> VirtualChannel in
                var c = ch[i]
                let name = withUnsafeBytes(of: &c.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                return VirtualChannel(rf: rf, major: Int(c.major), minor: Int(c.minor), name: name,
                                      program: Int(c.program), sourceID: Int(c.source_id), hidden: c.hidden != 0)
            }
            DispatchQueue.main.async { e.onChannels?(list) }
        }
        cb.event = { ctx, ev in
            guard let ctx, let ev else { return }
            let e = Unmanaged<Engine>.fromOpaque(ctx).takeUnretainedValue()
            var t = ev.pointee.title
            let title = withUnsafeBytes(of: &t) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let g = GuideEvent(eventID: Int(ev.pointee.event_id),
                               start: Date(timeIntervalSince1970: TimeInterval(ev.pointee.start_utc)),
                               duration: Int(ev.pointee.duration), title: title)
            let src = Int(ev.pointee.source_id)
            DispatchQueue.main.async { e.onEvent?(src, g) }
        }
        cb.time = { ctx, utc in
            guard let ctx else { return }
            let e = Unmanaged<Engine>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { e.onClock?(Date(timeIntervalSince1970: TimeInterval(utc))) }
        }
        cb.captions = { ctx, pts, json in
            guard let ctx, let json else { return }
            Unmanaged<Engine>.fromOpaque(ctx).takeUnretainedValue().player.caption(json: String(cString: json), pts: pts)
        }
        cb.format = { ctx, w, h, il, ach in
            guard let ctx else { return }
            let e = Unmanaged<Engine>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { e.onFormat?(Int(w), Int(h), il != 0, Int(ach)) }
        }
        media = withUnsafePointer(to: &cb) { atsc_media_create($0) }
    }

    // MARK: device

    func open(rf: Int, amp: Bool, lna: Int, vga: Int) throws {
        device?.close(); device = nil
        let d = HackRFDevice(ring: ring)
        do {
            try d.open()
            try d.start(freq: RFBand.tuneHz(rf), amp: amp, lna: lna, vga: vga)
        } catch {
            d.close(); throw error
        }
        device = d
        tune(rf: rf)
        if !started { started = true; startThreads() }
    }

    func closeDevice() { device?.close(); device = nil }

    /// Retune to an RF channel: the DSP thread drops old samples and reacquires.
    func tune(rf: Int) {
        currentRF = rf
        device?.setFrequency(RFBand.tuneHz(rf))
        tuneLock.lock(); tuneGen += 1; tuneHint = RFBand.pilotHint(rf); tuneLock.unlock()
        cmdLock.lock(); cmdReset = true; cmdLock.unlock()
        player.flush()
    }

    /// Reacquire on the current RF channel (after a gain change), dropping older samples.
    func retune() {
        tuneLock.lock(); tuneGen += 1; tuneLock.unlock()
    }

    func select(audio index: Int) { cmdLock.lock(); cmdAudio = index; cmdLock.unlock() }

    /// 0 off, 1...4 CC1-CC4, 101...163 DTV service 1-63.
    func select(captions service: Int) { cmdLock.lock(); cmdCaptions = service; cmdLock.unlock() }

    /// Switch the decoded program within the current RF channel.
    func select(program: Int) {
        cmdLock.lock(); cmdProgram = program; cmdLock.unlock()
        player.flush()
    }

    func mediaStatus() -> atsc_media_status {
        var s = atsc_media_status()
        if let media { atsc_media_get_status(media, &s) }
        return s
    }

    func stats() -> atsc_stats {
        var s = atsc_stats()
        if let rx { atsc_rx_get_stats(rx, &s) }
        return s
    }

    // MARK: threads

    private func startThreads() {
        let dsp = Thread { [unowned self] in dspLoop() }
        dsp.qualityOfService = .userInteractive; dsp.name = "atsc.dsp"; dsp.start()
        let med = Thread { [unowned self] in mediaLoop() }
        med.qualityOfService = .userInteractive; med.name = "atsc.media"; med.start()
    }

    private var dumpFile: FileHandle? = {
        guard let p = ProcessInfo.processInfo.environment["ATSC_DUMP"] else { return nil }
        FileManager.default.createFile(atPath: p, contents: nil)
        return FileHandle(forWritingAtPath: p)
    }()
    private var dumped = 0

    private func dspLoop() {
        let chunk = 1 << 19
        let buf = UnsafeMutablePointer<Int8>.allocate(capacity: chunk)
        var cursor = ring.written & ~1
        var seenGen = -1
        while true {
            tuneLock.lock(); let gen = tuneGen, hint = tuneHint; tuneLock.unlock()
            if gen != seenGen {
                if ProcessInfo.processInfo.environment["ATSC_DEBUG"] != nil { FileHandle.standardError.write("DSP reset (retune/gain) gen \(gen)\n".data(using: .utf8)!) }
                seenGen = gen
                // skip samples from before the retune (plus 20 ms for the tuner to settle)
                Thread.sleep(forTimeInterval: 0.02)
                cursor = ring.written & ~1
                if let rx { atsc_rx_reset(rx, hint) }
            }
            var over = false
            let n = ring.read(cursor: &cursor, into: buf, max: chunk, overrun: &over)
            if over { overruns += 1; if let rx { atsc_rx_reset(rx, hint) } }
            if n > 0, let dump = dumpFile {
                dump.write(Data(bytes: buf, count: n)); dumped += n
                if dumped > 120_000_000 { try? dump.close(); dumpFile = nil; FileHandle.standardError.write("dump done\n".data(using: .utf8)!) }
            }
            if n > 0, let rx { atsc_rx_process(rx, buf, n / 2) }
        }
    }

    private func packet(_ p: UnsafePointer<UInt8>, _ ok: Bool) {
        pktLock.lock()
        pktBuf.append(contentsOf: UnsafeBufferPointer(start: p, count: 188))
        pktOK.append(ok ? 1 : 0)
        let n = pktOK.count
        pktLock.unlock()
        if n % 64 == 0 { pktSignal.signal() }
        if ok { record(p) }
    }

    private func mediaLoop() {
        var local = [UInt8](), localOK = [UInt8]()
        while true {
            _ = pktSignal.wait(timeout: .now() + .milliseconds(20))
            cmdLock.lock()
            let reset = cmdReset, prog = cmdProgram, aud = cmdAudio, ccs = cmdCaptions
            cmdReset = false; cmdProgram = nil; cmdAudio = nil; cmdCaptions = nil
            cmdLock.unlock()
            if let media {
                if reset { atsc_media_reset(media) }
                if let prog { atsc_media_select(media, Int32(prog)) }
                if let aud { atsc_media_select_audio(media, Int32(aud)) }
                if let ccs { atsc_media_select_captions(media, Int32(ccs)) }
                publishInfo(media)
            }
            pktLock.lock()
            swap(&local, &pktBuf); swap(&localOK, &pktOK)
            pktLock.unlock()
            if reset { local.removeAll(); localOK.removeAll() }
            guard let media else { continue }
            local.withUnsafeBufferPointer { b in
                for i in 0..<localOK.count { atsc_media_push(media, b.baseAddress! + 188 * i, Int32(localOK[i])) }
            }
            local.removeAll(keepingCapacity: true); localOK.removeAll(keepingCapacity: true)
        }
    }

    private var infoTick = 0

    /// Snapshot the program's audio tracks and caption services (on the media thread).
    private func publishInfo(_ media: OpaquePointer) {
        infoTick += 1
        if infoTick % 10 != 0 { return }
        var info = ProgramInfo()
        var t = [atsc_audio_track](repeating: atsc_audio_track(), count: 8)
        let na = Int(atsc_media_audio_tracks(media, &t, 8))
        for i in 0..<na {
            var tr = t[i]
            let lang = withUnsafeBytes(of: &tr.lang) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            info.audio.append(AudioTrack(pid: Int(tr.pid), codec: String(cString: atsc_stream_type_name(tr.stream_type)),
                                         lang: lang, role: Int(tr.role), channels: Int(tr.channels)))
        }
        var c = [atsc_caption_service](repeating: atsc_caption_service(), count: 16)
        let nc = Int(atsc_media_caption_services(media, &c, 16))
        for i in 0..<nc {
            var cs = c[i]
            let lang = withUnsafeBytes(of: &cs.lang) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            info.captions.append(CaptionService(lang: lang, digital: cs.digital != 0, number: Int(cs.number), easyReader: cs.easy_reader != 0))
        }
        if info != lastInfo {
            lastInfo = info
            DispatchQueue.main.async { [weak self] in self?.onProgramInfo?(info) }
        }
    }

    // MARK: recording

    func startRecording(to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        var pids = [Int32](repeating: 0, count: 8)
        let n = media.map { atsc_media_selected_pids($0, &pids, 8) } ?? 0
        recLock.lock()
        recFile = fh; recPIDs = Set(pids.prefix(Int(n)).map(Int.init)); recBuffer.removeAll()
        recLock.unlock()
    }

    func stopRecording() {
        recLock.lock()
        if let f = recFile { try? f.write(contentsOf: recBuffer); try? f.close() }
        recFile = nil; recBuffer.removeAll()
        recLock.unlock()
    }

    private func record(_ p: UnsafePointer<UInt8>) {
        recLock.lock(); defer { recLock.unlock() }
        guard let f = recFile else { return }
        let pid = Int(p[1] & 0x1F) << 8 | Int(p[2])
        guard recPIDs.contains(pid) else { return }
        recBuffer.append(p, count: 188)
        if recBuffer.count >= 1 << 20 { try? f.write(contentsOf: recBuffer); recBuffer.removeAll(keepingCapacity: true) }
    }
}
