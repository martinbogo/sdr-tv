import Foundation

/// Byte ring for 8-bit IQ from the HackRF, read strictly in order by the DSP thread.
final class SampleRing {
    let size = 64 << 20                       // 64 MB, ~1.6 s at 20 Msps
    private let buf: UnsafeMutablePointer<Int8>
    private var total = 0                     // bytes ever written
    private let cond = NSCondition()

    init() {
        buf = .allocate(capacity: size)
        buf.initialize(repeating: 0, count: size)
    }

    deinit { buf.deallocate() }

    var written: Int { cond.lock(); defer { cond.unlock() }; return total }

    /// Power of the newest `bytes` of samples in dBFS (for gain setting: unlike the receiver's own
    /// level reading, this cannot lag behind a gain change). `after`: only count data written since then.
    func recentLevel(bytes: Int = 400_000, after: Int = 0) -> Double? {
        cond.lock(); defer { cond.unlock() }
        let n = min(bytes, total - after) & ~1
        guard n >= 20_000 else { return nil }
        var pw = 0.0
        for k in 0..<n {
            let v = Double(buf[(total - n + k) % size]); pw += v * v
        }
        return 10 * log10(max(pw / Double(n / 2), 1e-9)) - 20 * log10(128)
    }

    func write(_ p: UnsafeRawPointer, _ n: Int) {
        cond.lock()
        var src = p.assumingMemoryBound(to: Int8.self), left = n
        while left > 0 {
            let i = total % size, k = min(left, size - i)
            (buf + i).update(from: src, count: k)
            src += k; left -= k; total += k
        }
        cond.signal()
        cond.unlock()
    }

    /// Copies up to `max` bytes starting at `cursor` (IQ-pair aligned), waiting up to 50 ms for data.
    /// If the reader fell more than a ring behind, it skips ahead and `overrun` is set.
    func read(cursor: inout Int, into out: UnsafeMutablePointer<Int8>, max: Int, overrun: inout Bool) -> Int {
        cond.lock(); defer { cond.unlock() }
        if total - cursor < 2 { _ = cond.wait(until: Date().addingTimeInterval(0.05)) }
        if total - cursor > size - (4 << 20) {
            cursor = (total - size / 2) & ~1
            overrun = true
        }
        let n = min(max, total - cursor) & ~1
        guard n > 0 else { return 0 }
        let s = cursor % size, k = min(n, size - s)
        out.update(from: buf + s, count: k)
        if k < n { (out + k).update(from: buf, count: n - k) }
        cursor += n
        return n
    }
}

enum RadioError: LocalizedError {
    case call(String, Int32)

    var errorDescription: String? {
        switch self {
        case let .call(what, code):
            if what == "hackrf_open" && code == HACKRF_ERROR_NOT_FOUND.rawValue { return "No HackRF found" }
            if what == "hackrf_open" && code == HACKRF_ERROR_LIBUSB.rawValue {
                return "The HackRF is busy (another program may be using it)"
            }
            let name = hackrf_error_name(hackrf_error(rawValue: code)).map { String(cString: $0) } ?? "\(code)"
            return "\(what) failed: \(name)"
        }
    }
}

/// libhackrf control: frequency and gains change live without restarting the stream.
final class HackRFDevice {
    private var dev: OpaquePointer?
    private let ring: SampleRing
    private static var libraryReady = false
    /// Every libhackrf call goes through this one serial queue. Control requests are USB transfers
    /// that libhackrf waits on without a timeout: a USB hiccup must never freeze the main thread.
    static let control = DispatchQueue(label: "hackrf.control", qos: .userInteractive)

    init(ring: SampleRing) { self.ring = ring }

    private func check(_ r: Int32, _ what: String) throws {
        if r != HACKRF_SUCCESS.rawValue { throw RadioError.call(what, r) }
    }

    func open() throws {
        // after any queued work (a previous device closing must finish before this one opens)
        try Self.control.sync {
            if !Self.libraryReady { try check(hackrf_init(), "hackrf_init"); Self.libraryReady = true }
            var d: OpaquePointer?
            try check(hackrf_open(&d), "hackrf_open")
            dev = d
        }
    }

    func start(freq: UInt64, amp: Bool, lna: Int, vga: Int) throws {
        try Self.control.sync { try startNow(freq: freq, amp: amp, lna: lna, vga: vga) }
    }

    private func startNow(freq: UInt64, amp: Bool, lna: Int, vga: Int) throws {
        guard let dev else { throw RadioError.call("hackrf_open", HACKRF_ERROR_NOT_FOUND.rawValue) }
        try check(hackrf_set_sample_rate(dev, 20_000_000), "hackrf_set_sample_rate")
        try check(hackrf_set_baseband_filter_bandwidth(dev, hackrf_compute_baseband_filter_bw(15_000_000)),
                  "hackrf_set_baseband_filter_bandwidth")
        try check(hackrf_set_freq(dev, freq), "hackrf_set_freq")
        try check(hackrf_set_amp_enable(dev, amp ? 1 : 0), "hackrf_set_amp_enable")
        try check(hackrf_set_lna_gain(dev, UInt32(lna)), "hackrf_set_lna_gain")
        try check(hackrf_set_vga_gain(dev, UInt32(vga)), "hackrf_set_vga_gain")
        let ctx = Unmanaged.passUnretained(ring).toOpaque()
        try check(hackrf_start_rx(dev, { t in
            guard let t, let ctx = t.pointee.rx_ctx else { return 0 }
            Unmanaged<SampleRing>.fromOpaque(ctx).takeUnretainedValue()
                .write(t.pointee.buffer, Int(t.pointee.valid_length))
            return 0
        }, ctx), "hackrf_start_rx")
    }

    // Frequency and gain changes are queued (in order) and return at once. `wait: true` blocks
    // until applied: only for background threads that measure the result (gain setting in scans).
    private func control(wait: Bool, _ work: @escaping (OpaquePointer) -> Void) {
        guard let d = dev else { return }
        if wait { Self.control.sync { work(d) } } else { Self.control.async { work(d) } }
    }
    func setFrequency(_ hz: UInt64, wait: Bool = false) { control(wait: wait) { _ = hackrf_set_freq($0, hz) } }
    func setAmp(_ on: Bool, wait: Bool = false) { control(wait: wait) { _ = hackrf_set_amp_enable($0, on ? 1 : 0) } }
    func setLNA(_ db: Int, wait: Bool = false) { control(wait: wait) { _ = hackrf_set_lna_gain($0, UInt32(db)) } }
    func setVGA(_ db: Int, wait: Bool = false) { control(wait: wait) { _ = hackrf_set_vga_gain($0, UInt32(db)) } }

    var isStreaming: Bool {
        guard let dev else { return false }
        return hackrf_is_streaming(dev) == HACKRF_TRUE.rawValue
    }

    /// Returns at once; the device is stopped and closed on the control queue.
    func close() {
        guard let d = dev else { return }
        dev = nil
        Self.control.async { _ = hackrf_stop_rx(d); _ = hackrf_close(d) }
    }
}
