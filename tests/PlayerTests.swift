// Player: channel switching between stations whose clocks are unrelated.
// Feeds synthetic audio (silence) and video in real time, the way the media thread does, and checks
// that after each switch the playback clock follows the new station's audio and no frame is late.
// Built and run by tests/run.sh together with macos/Sources/Player.swift.
import AVFoundation
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("  ok    \(what)") } else { print("  FAIL  \(what) (line \(line))"); failures += 1 }
}

/// One station: audio and video timestamps on its own clock, video sent ~0.8 s ahead (as broadcasters do).
func play(_ p: Player, base: Int64, seconds: Double, videoJumpAt: Double? = nil, videoJump: Int64 = 0) {
    let w = 64, h = 36
    let y = [UInt8](repeating: 128, count: w * h), uv = [UInt8](repeating: 128, count: w * h / 4)
    let audio = [Float](repeating: 0, count: 1536 * 2)
    let start = Date()
    var aPTS = base, vPTS = base + 72_000
    var didJump = false
    while Date().timeIntervalSince(start) < seconds {
        let due = Double(aPTS - base) / 90_000
        let wait = due - Date().timeIntervalSince(start)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        audio.withUnsafeBufferPointer { p.audio(stereo: $0.baseAddress!, frames: 1536, rate: 48_000, pts: aPTS & ((1 << 33) - 1)) }
        aPTS += 2880                                         // 1536 samples at 48 kHz
        let jumped = videoJumpAt.map { Double(aPTS - base) / 90_000 >= $0 } ?? false
        if jumped, !didJump { vPTS += videoJump; didJump = true }       // once: the encoder's clock restarts
        while vPTS - (didJump ? videoJump : 0) < aPTS + 72_000 {
            y.withUnsafeBufferPointer { yp in uv.withUnsafeBufferPointer { up in
                p.video(y: yp.baseAddress!, u: up.baseAddress!, v: up.baseAddress!, yStride: w, uvStride: w / 2,
                        width: w, height: h, sarNum: 1, sarDen: 1, pts: vPTS & ((1 << 33) - 1))
            } }
            vPTS += 3003
        }
    }
}

/// After a switch: is the clock on the new station's audio timeline, about one buffer behind?
func clockFollows(_ p: Player, base: Int64, playedFor seconds: Double, _ what: String) {
    guard let clock = p.clockTicks else { check(false, "\(what): clock running"); return }
    let expected = base + Int64(seconds * 90_000) - p.bufferTicks
    let off = Double(clock - expected) / 90
    check(abs(off) < 300, "\(what): clock follows its audio (off by \(Int(off)) ms)")
    let f = p.videoFrameCounts
    check(f.total > 10 && f.late == 0, "\(what): \(f.late) of \(f.total) video frames late")
}

@main
struct PlayerTests {
    static func main() {
        let p = Player()
        p.muted = true
        let done = DispatchSemaphore(value: 0)
        // The player posts a few things to the main queue: keep it running while stations play.
        Thread {
            print("switching between stations with unrelated clocks")
            let stations: [(String, Int64)] = [("station A, clock near the 33-bit top", 8_500_000_000),
                                              ("station B, clock 26 hours behind A", 90_000 * 400),
                                              ("station C, clock ahead of B", 90_000 * 60_000),
                                              ("station B again", 90_000 * 400)]
            for (name, base) in stations {
                p.flush()
                play(p, base: base, seconds: 1.6)
                clockFollows(p, base: base, playedFor: 1.6, name)
            }
            print("video timestamps jump on their own (an inserted ad) while audio carries on")
            p.flush()
            play(p, base: 90_000 * 1000, seconds: 3.0, videoJumpAt: 1.0, videoJump: 90_000 * 3600)
            let ahead = p.farAheadFrames
            check(ahead <= 20, "picture keeps moving: \(ahead) frames stuck ahead of the clock before realigning")
            p.flush()
            play(p, base: 90_000 * 1000, seconds: 3.0, videoJumpAt: 1.0, videoJump: -90_000 * 600)
            let f = p.videoFrameCounts
            check(f.late <= 20, "after a backwards jump: \(f.late) of \(f.total) frames late before realigning")
            print("rapid channel changes racing the media thread")
            var stuck = 0
            for k in 0..<12 {
                let base = Int64(90_000 * (2000 + k * 5000))
                let flusher = Thread { Thread.sleep(forTimeInterval: Double(k % 4) * 0.004); p.flush() }   // the main thread changing channel
                p.flush(); flusher.start()
                play(p, base: base, seconds: 0.5)
                if p.clockTicks == nil { stuck += 1 }
            }
            check(stuck == 0 || p.keepPlaying() != nil, "the clock keeps running after racing flushes (\(stuck) of 12 stopped)")
            p.flush(); play(p, base: 90_000 * 77_000, seconds: 1.6)
            clockFollows(p, base: 90_000 * 77_000, playedFor: 1.6, "after the races")
            print("timestamps wrapping past 2^33 mid-stream")
            p.flush()
            play(p, base: (1 << 33) - 90_000, seconds: 2.0)        // wraps after one second
            clockFollows(p, base: (1 << 33) - 90_000, playedFor: 2.0, "wrapping station")
            check(p.bufferTicks <= 54_000, "buffer stays small on clean input (\(p.bufferTicks / 90) ms)")
            done.signal()
        }.start()
        while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        print(failures == 0 ? "player: all passed" : "player: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
