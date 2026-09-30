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

    /// Switch the decoded program within the current RF channel.
    func select(program: Int) {
        cmdLock.lock(); cmdProgram = program; cmdLock.unlock()
        player.flush()
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

    private func dspLoop() {
        let chunk = 1 << 19
        let buf = UnsafeMutablePointer<Int8>.allocate(capacity: chunk)
        var cursor = ring.written & ~1
        var seenGen = -1
        while true {
            tuneLock.lock(); let gen = tuneGen, hint = tuneHint; tuneLock.unlock()
            if gen != seenGen {
                seenGen = gen
                // skip samples from before the retune (plus 20 ms for the tuner to settle)
                Thread.sleep(forTimeInterval: 0.02)
                cursor = ring.written & ~1
                if let rx { atsc_rx_reset(rx, hint) }
            }
            var over = false
            let n = ring.read(cursor: &cursor, into: buf, max: chunk, overrun: &over)
            if over { overruns += 1; if let rx { atsc_rx_reset(rx, hint) } }
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
            let reset = cmdReset, prog = cmdProgram
            cmdReset = false; cmdProgram = nil
            cmdLock.unlock()
            if let media {
                if reset { atsc_media_reset(media) }
                if let prog { atsc_media_select(media, Int32(prog)) }
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
