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
    // Output gate: after a station or program change, decoding carries on briefly with the old one
    // (packets already in the pipeline). Nothing reaches the player until the media thread has
    // made the latest change: old pictures and sound must not start the new channel's clock.
    private var tuneSerial = 0, programSerial = 0          // cmdLock: changes asked for (main thread)
    private var appliedTune = 0, appliedProgram = 0         // cmdLock: changes the media thread has made
    private var cmdResetSerial = 0, cmdProgramSerial = 0
    private var tuneSerialForDSP = 0                        // tuneLock

    private func outputAllowed() -> Bool {
        cmdLock.lock(); defer { cmdLock.unlock() }
        return appliedTune == tuneSerial && appliedProgram == programSerial
    }
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
    private var tuneRF = 0, tuneNewRF = false            // a retune (not a gain change) is pending
    /// The RF channel whose packets the media thread is decoding (media thread only).
    private var mediaRF = 0
    private var cmdRF = 0

    // recording
    private let recLock = NSLock()
    /// Recordings in progress (several programs of one RF channel can be recorded at once).
    private struct Recorder { var file: FileHandle; var pids: Set<Int>; var buffer = Data() }
    private var recorders: [String: Recorder] = [:]

    // app callbacks (main thread)
    var onChannels: (([VirtualChannel]) -> Void)?
    /// Guide data arrives in floods (a station's whole guide within seconds of tuning): it is
    /// collected on the media thread and handed to the main thread in batches, at most 4 a second.
    struct GuideBatch {
        var events: [(rf: Int, source: Int, event: GuideEvent)] = []
        var descriptions: [(rf: Int, source: Int, eventID: Int, text: String)] = []
        var isEmpty: Bool { events.isEmpty && descriptions.isEmpty }
    }
    var onGuide: ((GuideBatch) -> Void)?
    private var guideBatch = GuideBatch()             // media thread only
    private var guideFlushedAt = Date()

    /// Media thread: pass collected guide data on if a quarter second has passed.
    private func flushGuide(force: Bool = false) {
        guard !guideBatch.isEmpty, force || Date().timeIntervalSince(guideFlushedAt) > 0.25 else { return }
        let b = guideBatch
        guideBatch = GuideBatch(); guideFlushedAt = Date()
        DispatchQueue.main.async { [weak self] in self?.onGuide?(b) }
    }
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
            let e = Unmanaged<Engine>.fromOpaque(ctx).takeUnretainedValue()
            guard e.outputAllowed() else { return }
            e.player.video(
                y: y, u: u, v: v, yStride: Int(ys), uvStride: Int(uvs), width: Int(w), height: Int(h),
                sarNum: Int(sn), sarDen: Int(sd), pts: pts)
        }
        cb.audio = { ctx, s, n, rate, pts in
            guard let ctx, let s else { return }
            let e = Unmanaged<Engine>.fromOpaque(ctx).takeUnretainedValue()
            guard e.outputAllowed() else { return }
            e.player.audio(stereo: s, frames: Int(n), rate: Int(rate), pts: pts)
        }
        cb.channels = { ctx, ch, n in
            guard let ctx, let ch else { return }
            let e = Unmanaged<Engine>.fromOpaque(ctx).takeUnretainedValue()
            let rf = e.mediaRF
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
            let rating = fixedCString(ev.pointee.rating)
            let g = GuideEvent(eventID: Int(ev.pointee.event_id),
                               start: Date(timeIntervalSince1970: TimeInterval(ev.pointee.start_utc)),
                               duration: Int(ev.pointee.duration), title: title,
                               rating: rating.isEmpty ? nil : rating,
                               captions: ev.pointee.captions != 0 ? true : nil,
                               captionLangs: langList(fixedCString(ev.pointee.caption_langs)),
                               audioLangs: langList(fixedCString(ev.pointee.audio_langs)))
            let src = Int(ev.pointee.source_id), rf = e.mediaRF
            e.guideBatch.events.append((rf, src, g))
        }
        cb.description = { ctx, src, evid, text in
            guard let ctx, let text else { return }
            let e = Unmanaged<Engine>.fromOpaque(ctx).takeUnretainedValue()
            let t = String(cString: text), rf = e.mediaRF
            e.guideBatch.descriptions.append((rf, Int(src), Int(evid), t))
        }
        cb.time = { ctx, utc in
            guard let ctx else { return }
            let e = Unmanaged<Engine>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { e.onClock?(Date(timeIntervalSince1970: TimeInterval(utc))) }
        }
        cb.captions = { ctx, pts, json in
            guard let ctx, let json else { return }
            let e = Unmanaged<Engine>.fromOpaque(ctx).takeUnretainedValue()
            guard e.outputAllowed() else { return }
            e.player.caption(json: String(cString: json), pts: pts)
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
        // the DSP thread resets the media layer once the receiver has dropped the old channel's
        // samples, so nothing decoded afterwards (guide events especially) belongs to the old one
        cmdLock.lock(); tuneSerial += 1; let serial = tuneSerial; cmdLock.unlock()
        tuneLock.lock(); tuneGen += 1; tuneHint = RFBand.pilotHint(rf); tuneRF = rf; tuneNewRF = true; tuneSerialForDSP = serial; tuneLock.unlock()
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
        cmdLock.lock(); programSerial += 1; cmdProgram = program; cmdProgramSerial = programSerial; cmdLock.unlock()
        player.flush()
    }

    func mediaStatus() -> atsc_media_status {
        var s = atsc_media_status()
        if let media { atsc_media_get_status(media, &s) }
        return s
    }

    /// Guide collection on the RF channel being decoded: the channel, distinct guide sections so far,
    /// and seconds since a new one arrived (a mux carries 19.39 Mb/s, about 12,900 packets a second).
    func guideProgress() -> (rf: Int, sections: Int, quiet: Double) {
        var n: Int32 = 0, since: UInt64 = 0
        if let media { atsc_media_guide_progress(media, &n, &since) }
        return (mediaRF, Int(n), Double(since) / 12_900)
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
            tuneLock.lock()
            let gen = tuneGen, hint = tuneHint, rf = tuneRF, newRF = tuneNewRF, serial = tuneSerialForDSP
            tuneNewRF = false
            tuneLock.unlock()
            if gen != seenGen {
                if ProcessInfo.processInfo.environment["ATSC_DEBUG"] != nil { FileHandle.standardError.write("DSP reset (retune/gain) gen \(gen)\n".data(using: .utf8)!) }
                seenGen = gen
                // skip samples from before the retune: the tuner settling, and transfers still in
                // flight on USB from the old frequency (they could decode as the old station)
                Thread.sleep(forTimeInterval: newRF ? 0.06 : 0.02)
                cursor = ring.written & ~1
                if let rx { atsc_rx_reset(rx, hint) }
                if newRF { cmdLock.lock(); cmdReset = true; cmdRF = rf; cmdResetSerial = serial; cmdLock.unlock() }
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
            let reset = cmdReset, rf = cmdRF, prog = cmdProgram, aud = cmdAudio, ccs = cmdCaptions
            let resetSerial = cmdResetSerial, progSerial = cmdProgramSerial
            cmdReset = false; cmdProgram = nil; cmdAudio = nil; cmdCaptions = nil
            cmdLock.unlock()
            if let media {
                if reset {
                    atsc_media_reset(media); mediaRF = rf
                    cmdLock.lock(); appliedTune = max(appliedTune, resetSerial); cmdLock.unlock()
                }
                if let prog {
                    // open the gate first: the new program's cached keyframe is replayed right away
                    cmdLock.lock(); appliedProgram = max(appliedProgram, progSerial); cmdLock.unlock()
                    atsc_media_select(media, Int32(prog))
                }
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
            flushGuide()
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

    /// The program being watched (manual recording, R).
    func startRecording(to url: URL) throws {
        var pids = [Int32](repeating: 0, count: 8)
        let n = media.map { atsc_media_selected_pids($0, &pids, 8) } ?? 0
        try startRecorder(id: "manual", pids: Set(pids.prefix(Int(n)).map(Int.init)), to: url)
    }

    func stopRecording() { stopRecorder(id: "manual") }

    /// Any program of the RF channel being received. Returns false until its streams are known
    /// (the program map arrives within ~0.1 s of tuning); call again.
    func startRecording(id: String, program: Int, to url: URL) throws -> Bool {
        var pids = [Int32](repeating: 0, count: 16)
        let n = media.map { atsc_media_program_pids($0, Int32(program), &pids, 16) } ?? 0
        guard n > 0 else { return false }
        try startRecorder(id: id, pids: Set(pids.prefix(Int(n)).map(Int.init)), to: url)
        return true
    }

    func isRecording(id: String) -> Bool { recLock.lock(); defer { recLock.unlock() }; return recorders[id] != nil }

    private func startRecorder(id: String, pids: Set<Int>, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        recLock.lock(); recorders[id] = Recorder(file: fh, pids: pids); recLock.unlock()
    }

    func stopRecorder(id: String) {
        recLock.lock()
        if let r = recorders.removeValue(forKey: id) { try? r.file.write(contentsOf: r.buffer); try? r.file.close() }
        recLock.unlock()
    }

    private func record(_ p: UnsafePointer<UInt8>) {
        recLock.lock(); defer { recLock.unlock() }
        guard !recorders.isEmpty else { return }
        let pid = Int(p[1] & 0x1F) << 8 | Int(p[2])
        for (id, var r) in recorders where r.pids.contains(pid) {
            r.buffer.append(p, count: 188)
            if r.buffer.count >= 1 << 20 { try? r.file.write(contentsOf: r.buffer); r.buffer.removeAll(keepingCapacity: true) }
            recorders[id] = r
        }
    }
}

/// A C char array (imported as a tuple) as a String.
private func fixedCString<T>(_ v: T) -> String {
    var v = v
    return withUnsafeBytes(of: &v) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

/// "eng,spa" -> ["eng", "spa"]; nil when empty.
private func langList(_ s: String) -> [String]? { s.isEmpty ? nil : s.split(separator: ",").map(String.init) }
