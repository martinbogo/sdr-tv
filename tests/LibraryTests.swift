// Channel list rules: scans merge, buckets, hiding, one RF channel per channel number.
// Built and run by tests/run.sh together with macos/Sources/Channels.swift.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("  ok    \(what)") } else { print("  FAIL  \(what) (line \(line))"); failures += 1 }
}

func ch(_ rf: Int, _ major: Int, _ minor: Int, tier: Int? = nil, snr: Double = 0) -> VirtualChannel {
    var c = VirtualChannel(rf: rf, major: major, minor: minor, name: "C\(major)", program: minor, sourceID: minor)
    c.tier = tier; c.signalDB = snr
    return c
}

@main
struct LibraryTests {
    static func main() {
        let lib = Library()
        lib.setChannels([])

        print("scan merging")
        lib.applyScan([ch(26, 8, 1, tier: 1, snr: 24), ch(26, 8, 2, tier: 1, snr: 24), ch(25, 6, 1, tier: 2, snr: 18)])
        check(lib.channels.count == 3, "first scan lists 3 channels")
        lib.applyScan([ch(26, 8, 1, tier: 1, snr: 24), ch(26, 8, 2, tier: 1, snr: 24)])
        var koin = lib.channels.first { $0.id == "6.1" }
        check(koin != nil, "a station a scan misses is kept")
        check(koin?.hidden == false && koin?.tier == 2, "...and one miss does not hide a station that came in before")
        lib.applyScan([ch(26, 8, 1, tier: 1, snr: 24), ch(26, 8, 2, tier: 1, snr: 24)])
        koin = lib.channels.first { $0.id == "6.1" }
        check(koin?.hidden == true && koin?.autoHidden == true, "...two misses make it Poor, unchecked automatically")

        print("bucket from recent results")
        check(VirtualChannel.bucket(from: [3]) == 3, "a first poor result hides a new station")
        check(VirtualChannel.bucket(from: [1, 1, 3]) == 2, "one poor result among good ones: Good, still shown")
        check(VirtualChannel.bucket(from: [1, 3, 3]) == 3, "two poor in the last three: Poor")
        check(VirtualChannel.bucket(from: [3, 3, 1]) == 3, "one good result after two poor: still Poor")
        check(VirtualChannel.bucket(from: [3, 3, 1, 1]) == 2, "...a second good one: Good again")
        check(VirtualChannel.bucket(from: [3, 1, 1, 1]) == 1, "consistently excellent again: Excellent")

        print("buckets and hiding")
        lib.applyScan([ch(26, 8, 1, tier: 1), ch(26, 8, 2, tier: 1), ch(25, 6, 1, tier: 1)])
        lib.applyScan([ch(26, 8, 1, tier: 1), ch(26, 8, 2, tier: 1), ch(25, 6, 1, tier: 1)])
        check(lib.channels.first { $0.id == "6.1" }?.hidden == false, "scans measuring it good bring it back")
        lib.setHidden("8.2", true)
        lib.applyScan([ch(26, 8, 1, tier: 1), ch(26, 8, 2, tier: 1), ch(25, 6, 1, tier: 1)])
        check(lib.channels.first { $0.id == "8.2" }?.hidden == true, "the user's own unchecking survives a scan")
        lib.applyScan([ch(26, 8, 1, tier: 1), ch(26, 8, 2, tier: 1), ch(25, 6, 1, tier: 3)])
        lib.applyScan([ch(26, 8, 1, tier: 1), ch(26, 8, 2, tier: 1), ch(25, 6, 1, tier: 3)])
        check(lib.channels.first { $0.id == "6.1" }?.hidden == true, "poor twice: hidden")
        lib.setHidden("6.1", false)
        check(lib.channels.first { $0.id == "6.1" }?.userKept == true, "checking a poor channel keeps it")
        lib.applyScan([ch(26, 8, 1, tier: 1), ch(26, 8, 2, tier: 1), ch(25, 6, 1, tier: 3)])
        check(lib.channels.first { $0.id == "6.1" }?.hidden == false, "...and a later poor scan leaves it shown")

        print("one RF channel per channel number")
        lib.applyScan([ch(26, 8, 1, tier: 1), ch(26, 8, 2, tier: 1), ch(25, 6, 1, tier: 1),
                       ch(24, 2, 1, tier: 1, snr: 20), ch(28, 2, 1, tier: 3, snr: 1)])
        let katu = lib.channels.filter { $0.id == "2.1" }
        check(katu.count == 1 && katu.first?.rf == 24, "a duplicate on another RF channel keeps the better one")

        print("receiver settings survive a channel table update")
        lib.setGains(rf: 26, lna: 32, vga: 18, amp: true)
        lib.merge(rf: 26, found: [ch(26, 8, 1), ch(26, 8, 2)])
        let kgw = lib.channels.first { $0.id == "8.1" }
        check(kgw?.lna == 32 && kgw?.vga == 18 && kgw?.amp == true, "gains carry over")
        check(kgw?.tier == 1 && (kgw?.tierHistory?.count ?? 0) > 0, "bucket and its history carry over")

        print("lists saved before reception histories")
        var old = ch(31, 31, 1, tier: 1); old.tierHistory = nil
        old.record(3)
        check(old.tier == 2 && old.hidden == false, "an Excellent station's first failure leaves it Good, shown")

        print("results while watching")
        lib.record(rf: 26, 3)
        check(lib.channels.first { $0.id == "8.1" }?.hidden == false, "one failed tune of a good station keeps it shown")
        lib.record(rf: 26, 3)
        check(lib.channels.first { $0.id == "8.1" }?.hidden == true, "a second failure hides it")

        print(failures == 0 ? "library: all passed" : "library: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
