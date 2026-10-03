import Foundation

/// US broadcast TV RF channels after the 2016-2020 repack (6 MHz each; 37 is radio astronomy).
enum RFBand {
    static let channels: [Int] = Array(2...36).filter { $0 != 37 }

    static func centerMHz(_ rf: Int) -> Double {
        switch rf {
        case 2...4: return 57 + 6 * Double(rf - 2)
        case 5...6: return 79 + 6 * Double(rf - 5)
        case 7...13: return 177 + 6 * Double(rf - 7)
        default: return 473 + 6 * Double(rf - 14)
        }
    }

    /// Tune 4 MHz above the channel so the HackRF's DC spur falls outside it.
    static func tuneHz(_ rf: Int) -> UInt64 { UInt64((centerMHz(rf) + 4) * 1e6) }

    /// Where the 8VSB pilot should appear relative to the tuned frequency.
    static func pilotHint(_ rf: Int) -> Double { (centerMHz(rf) - 3) * 1e6 + 309_440.559 - Double(tuneHz(rf)) }
}

struct VirtualChannel: Codable, Hashable, Identifiable {
    var rf: Int
    var major: Int
    var minor: Int
    var name: String
    var program: Int
    var sourceID: Int
    var hidden = false
    var signalDB: Double = 0
    // receiver settings the scan found best for this RF channel (optional: older lists lack them)
    var lna: Int?
    var vga: Int?
    var amp: Bool?
    /// Set when every receiver setting failed to decode it: shown as weak, skipped by channel
    /// up/down, retried when the user picks it. Separate from `hidden` (the user unchecked it).
    var unavailable: Bool?
    var bestSNR: Double?

    var isUnavailable: Bool { unavailable ?? false }

    var id: String { "\(major).\(minor)" }
    var number: String { "\(major).\(minor)" }
    var guideKey: String { "\(rf)-\(sourceID)" }
}

struct GuideEvent: Codable, Hashable, Identifiable {
    var eventID: Int
    var start: Date
    var duration: Int
    var title: String

    var id: String { "\(eventID)-\(Int(start.timeIntervalSince1970))" }
    var end: Date { start.addingTimeInterval(TimeInterval(duration)) }
}

/// Persistent channel list and broadcast guide (Application Support/SDR TV).
final class Library {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let u = base.appendingPathComponent("SDR TV", isDirectory: true)
        // the app was called ATSC Receiver before: carry its channels and guide over
        let old = base.appendingPathComponent("ATSC Receiver", isDirectory: true)
        if !FileManager.default.fileExists(atPath: u.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: u)
        }
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    private(set) var channels: [VirtualChannel] = []
    private(set) var guide: [String: [GuideEvent]] = [:]      // guideKey -> events sorted by start

    init() {
        if let d = try? Data(contentsOf: Self.folder.appendingPathComponent("channels.json")),
           let c = try? JSONDecoder().decode([VirtualChannel].self, from: d) { channels = c }
        if let d = try? Data(contentsOf: Self.folder.appendingPathComponent("guide.json")),
           let g = try? JSONDecoder().decode([String: [GuideEvent]].self, from: d) { guide = g }
        prune()
    }

    /// Everything the user has not unchecked. Weak channels stay listed (marked) so they can be retried.
    var visibleChannels: [VirtualChannel] { channels.filter { !$0.hidden } }
    var unavailableRFs: [Int] { Array(Set(channels.filter { $0.isUnavailable && !$0.hidden }.map(\.rf))).sorted() }

    /// Every channel on `rf` could not be decoded with any setting.
    func markUnavailable(rf: Int, bestSNR: Double) {
        for i in channels.indices where channels[i].rf == rf { channels[i].unavailable = true; channels[i].bestSNR = bestSNR }
        save()
    }

    func restore(rf: Int) {
        for i in channels.indices where channels[i].rf == rf { channels[i].unavailable = nil }
        save()
    }

    /// Receiver settings that worked for an RF channel.
    func setGains(rf: Int, lna: Int, vga: Int, amp: Bool) {
        for i in channels.indices where channels[i].rf == rf {
            channels[i].lna = lna; channels[i].vga = vga; channels[i].amp = amp
        }
        save()
    }

    func setChannels(_ list: [VirtualChannel]) {
        channels = list.sorted { ($0.major, $0.minor) < ($1.major, $1.minor) }
        save()
    }

    /// Merge the channels found on one RF channel (replacing what was known for it). The receiver
    /// settings and weak mark belong to the RF channel, so they carry over to the new entries.
    func merge(rf: Int, found: [VirtualChannel]) {
        let hiddenIDs = Set(channels.filter { $0.hidden }.map(\.id))
        let old = channels.first { $0.rf == rf }
        var list = channels.filter { $0.rf != rf }
        for var c in found {
            c.hidden = c.hidden || hiddenIDs.contains(c.id)
            if let old {
                c.lna = c.lna ?? old.lna; c.vga = c.vga ?? old.vga; c.amp = c.amp ?? old.amp
                c.unavailable = c.unavailable ?? old.unavailable; c.bestSNR = c.bestSNR ?? old.bestSNR
            }
            list.append(c)
        }
        setChannels(list)
    }

    /// Replace the whole list with a fresh scan, keeping which channels the user hid.
    func replaceAll(_ found: [VirtualChannel], keepingHiddenFrom old: [VirtualChannel]) {
        let hiddenIDs = Set(old.filter { $0.hidden }.map(\.id))
        setChannels(found.map { var c = $0; c.hidden = c.hidden || hiddenIDs.contains(c.id); return c })
    }

    func setHidden(_ id: String, _ hidden: Bool) {
        if let i = channels.firstIndex(where: { $0.id == id }) {
            channels[i].hidden = hidden
            if !hidden { channels[i].unavailable = nil }     // re-enabling it clears the weak mark
            save()
        }
    }

    func add(event e: GuideEvent, key: String) {
        var list = guide[key] ?? []
        if let i = list.firstIndex(where: { $0.eventID == e.eventID && abs($0.start.timeIntervalSince(e.start)) < 60 }) {
            if list[i] == e { return }
            list[i] = e
        } else {
            // a new event replaces anything it overlaps (schedules change)
            list.removeAll { $0.start < e.end && e.start < $0.end }
            list.append(e)
        }
        list.sort { $0.start < $1.start }
        guide[key] = list
        dirty = true
    }

    private var dirty = false

    /// When each RF channel's guide was last read completely (RF channel -> time).
    private(set) var guideUpdated: [Int: Date] = {
        let d = UserDefaults.standard.dictionary(forKey: "guideUpdated") as? [String: Double] ?? [:]
        return Dictionary(uniqueKeysWithValues: d.compactMap { k, v in Int(k).map { ($0, Date(timeIntervalSince1970: v)) } })
    }()

    func markGuideUpdated(rf: Int) {
        guideUpdated[rf] = Date()
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: guideUpdated.map { (String($0.key), $0.value.timeIntervalSince1970) }),
                                  forKey: "guideUpdated")
    }

    /// The last time the guide for this RF channel extends to, or nil if there is none.
    func guideEnd(rf: Int) -> Date? {
        channels.filter { $0.rf == rf }.compactMap { guide[$0.guideKey]?.last?.end }.max()
    }

    func events(_ key: String, from: Date, to: Date) -> [GuideEvent] {
        (guide[key] ?? []).filter { $0.end > from && $0.start < to }
    }

    func now(_ key: String, at t: Date = Date()) -> (GuideEvent?, GuideEvent?) {
        let list = guide[key] ?? []
        let i = list.firstIndex { $0.start <= t && t < $0.end }
        guard let i else { return (nil, list.first { $0.start > t }) }
        return (list[i], i + 1 < list.count ? list[i + 1] : nil)
    }

    func prune() {
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        for (k, v) in guide {
            let keep = v.filter { $0.end > cutoff }
            guide[k] = keep.isEmpty ? nil : keep
        }
    }

    func save() {
        if let d = try? JSONEncoder().encode(channels) { try? d.write(to: Self.folder.appendingPathComponent("channels.json")) }
        saveGuideIfNeeded(force: true)
    }

    func saveGuideIfNeeded(force: Bool = false) {
        guard dirty || force else { return }
        prune()
        if let d = try? JSONEncoder().encode(guide) { try? d.write(to: Self.folder.appendingPathComponent("guide.json")) }
        dirty = false
    }
}

/// One caption screen from the decoder (see dsp/atsc_captions.h).
struct CaptionScreen: Decodable { var regions: [CaptionRegion] }

struct CaptionRegion: Decodable, Hashable {
    var x: Double
    var y: Double
    var anchor: Int
    var grid: Int?                 // 1 for CEA-608 rows (32 x 15 grid)
    var lines: [String]
}
