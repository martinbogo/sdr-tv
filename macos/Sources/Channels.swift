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

/// Signal quality, the same scale everywhere bars are shown. Quality is the equalizer's SNR on the
/// known training sequence (and packet loss when it is known), not the input level: a strong but
/// distorted signal (multipath) can have plenty of level and still not decode. About 15 dB is needed.
enum SignalQuality {
    static func bars(snr: Double, loss: Double = 0, locked: Bool = true) -> Int {
        guard locked, snr > 0 else { return 0 }
        if loss > 0.05 { return min(1, bars(snr: snr)) }      // data being lost: never more than 1
        switch snr {
        case ..<15: return 1
        case ..<18: return 2
        case ..<21: return 3
        default: return 4
        }
    }

    static func label(bars: Int) -> String {
        ["No signal", "Poor", "Fair", "Good", "Excellent"][max(0, min(4, bars))]
    }
}

struct VirtualChannel: Codable, Hashable, Identifiable {
    var rf: Int
    var major: Int
    var minor: Int
    var name: String
    var program: Int
    var sourceID: Int
    var hidden = false
    /// Quality (SNR, dB) last measured on this RF channel with the receiver settled; 0 if never.
    var signalDB: Double = 0
    // receiver settings the scan found best for this RF channel (optional: older lists lack them)
    var lna: Int?
    var vga: Int?
    var amp: Bool?
    /// Set when every receiver setting failed to decode it: shown as weak, skipped by channel
    /// up/down, retried when the user picks it. Separate from `hidden` (the user unchecked it).
    var unavailable: Bool?
    var bestSNR: Double?
    /// Reception bucket: 1 excellent (locks at normal gain, clean), 2 good (needs extra gain or the
    /// RF amplifier, clean after), 3 poor (everything else). Poor channels are unchecked
    /// automatically; nil until measured.
    var tier: Int?
    /// The app unchecked it (poor reception), as opposed to the user.
    var autoHidden: Bool?
    /// The user checked a poor channel back on: keep showing it whatever its reception.
    var userKept: Bool?
    /// The network the channel carries ("CBS", "Great American Family"): matches it to online listings.
    var network: String?
    /// Recent reception results for the RF channel (oldest first, at most 4): scans, failed tunes,
    /// clean viewing. The bucket comes from these, so one bad moment does not hide a station.
    var tierHistory: [Int]?

    var isUnavailable: Bool { unavailable ?? false }
    /// Bars for the last measurement (none for a station marked weak).
    var bars: Int { isUnavailable ? 0 : SignalQuality.bars(snr: signalDB) }

    var tierLabel: String {
        switch tier {
        case 1: return "Excellent"
        case 2: return amp == true ? "Good (RF amplifier)" : "Good (extra gain)"
        case 3: return "Poor"
        default: return "Not measured"
        }
    }

    /// Add a reception result and re-bucket from the recent ones.
    mutating func record(_ t: Int) {
        var h = (tierHistory ?? tier.map { [$0] } ?? []) + [t]   // lists from before histories: start from the bucket
        if h.count > 4 { h.removeFirst(h.count - 4) }
        tierHistory = h
        assign(tier: Self.bucket(from: h))
    }

    /// Poor needs two poor results in the last three; Excellent needs the latest excellent and no
    /// poor among the last three; anything between is Good. A first result stands on its own.
    static func bucket(from h: [Int]) -> Int {
        guard let last = h.last else { return 3 }
        if h.count == 1 { return last }
        let recent = h.suffix(3)
        if recent.filter({ $0 == 3 }).count >= 2 { return 3 }
        if last == 1 && !recent.contains(3) { return 1 }
        return 2
    }

    /// Put the channel in a bucket. Poor ones are unchecked unless the user chose to keep them;
    /// a channel the app unchecked comes back when it is measured good again (by a scan).
    mutating func assign(tier t: Int) {
        tier = t
        if t == 3 {
            if userKept == true { unavailable = true }
            else if !hidden { hidden = true; autoHidden = true }
        } else {
            unavailable = nil
            if autoHidden == true { hidden = false; autoHidden = nil }
        }
    }

    var id: String { "\(major).\(minor)" }
    var number: String { "\(major).\(minor)" }
    var guideKey: String { "\(rf)-\(sourceID)" }
}

struct GuideEvent: Codable, Hashable, Identifiable {
    var eventID: Int
    var start: Date
    var duration: Int
    var title: String
    // from the broadcast's descriptors and Extended Text Tables (optional: older guides lack them)
    var rating: String?
    var captions: Bool?
    var captionLangs: [String]?
    var audioLangs: [String]?
    var desc: String?
    /// Where the listing came from (nil: the station's own broadcast) and its rank: lower wins.
    /// 0 broadcast, 1 EPGTalk listing for this station, 2 imported XMLTV, 3 EPGTalk same-network
    /// affiliate in this time zone, 4 TVmaze network schedule.
    var source: String?
    var priority: Int?
    var rank: Int { priority ?? 0 }

    var id: String { "\(eventID)-\(Int(start.timeIntervalSince1970))" }
    var end: Date { start.addingTimeInterval(TimeInterval(duration)) }
}

/// The app's preferences. SDRTV_DEFAULTS_SUITE (tests) keeps a separate set, so an automated run never
/// touches the real ones (with SDRTV_DATA_DIR for the files).
enum AppDefaults {
    static let store: UserDefaults = ProcessInfo.processInfo.environment["SDRTV_DEFAULTS_SUITE"]
        .flatMap { UserDefaults(suiteName: $0) } ?? .standard
}

/// Persistent channel list and broadcast guide (Application Support/SDR TV).
final class Library {
    static let folder: URL = {
        if let dir = ProcessInfo.processInfo.environment["SDRTV_DATA_DIR"] {   // tests: a scratch folder
            let u = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
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

    /// Record a settled quality measurement for an RF channel (saved only when it moves by a dB or more).
    func setQuality(rf: Int, snr: Double) {
        guard let old = channels.first(where: { $0.rf == rf }), abs(old.signalDB - snr) >= 1 else { return }
        for i in channels.indices where channels[i].rf == rf { channels[i].signalDB = snr }
        save()
    }

    func setChannels(_ list: [VirtualChannel]) {
        // a channel number belongs to one RF channel: if it appears on two (samples from the previous
        // frequency decoded just after a retune), keep the better-received one
        var best: [String: VirtualChannel] = [:]
        for c in list {
            if let b = best[c.id] {
                let better = (c.tier ?? 9, -c.signalDB) < (b.tier ?? 9, -b.signalDB)
                if better { best[c.id] = c }
            } else { best[c.id] = c }
        }
        channels = best.values.sorted { ($0.major, $0.minor) < ($1.major, $1.minor) }
        save()
    }

    /// Merge the channels found on one RF channel (replacing what was known for it). The receiver
    /// settings and weak mark belong to the RF channel, so they carry over to the new entries.
    func merge(rf: Int, found: [VirtualChannel]) {
        let byID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let hiddenIDs = Set(channels.filter { $0.hidden }.map(\.id))
        let old = channels.first { $0.rf == rf }
        var list = channels.filter { $0.rf != rf }
        for var c in found {
            c.hidden = c.hidden || hiddenIDs.contains(c.id)
            if let prev = byID[c.id] { c.autoHidden = prev.autoHidden; c.userKept = prev.userKept; c.network = c.network ?? prev.network }
            if let old {
                c.lna = c.lna ?? old.lna; c.vga = c.vga ?? old.vga; c.amp = c.amp ?? old.amp
                c.unavailable = c.unavailable ?? old.unavailable; c.bestSNR = c.bestSNR ?? old.bestSNR
                c.tier = c.tier ?? old.tier; c.tierHistory = c.tierHistory ?? old.tierHistory
                if c.signalDB == 0 { c.signalDB = old.signalDB }
            }
            list.append(c)
        }
        setChannels(list)
    }

    /// Apply a finished scan. Stations it found replace what was known for their RF channels (keeping
    /// which channels the user hid). Stations it did not find stay listed, marked weak: reception
    /// comes and goes, and only the user removes channels (by unchecking them).
    func applyScan(_ found: [VirtualChannel]) {
        let byID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let foundRFs = Set(found.map(\.rf))
        var list: [VirtualChannel] = []
        let historyByRF = Dictionary(channels.map { ($0.rf, $0.tierHistory ?? []) }, uniquingKeysWith: { a, _ in a })
        for var c in found {
            let t = c.tier ?? 3
            c.tierHistory = historyByRF[c.rf]
            if let prev = byID[c.id] {
                // the user's own unchecking stands; the app's is undone by a good result (assign)
                c.hidden = prev.hidden
                c.autoHidden = prev.autoHidden; c.userKept = prev.userKept
                c.network = c.network ?? prev.network
                if c.tierHistory == nil { c.tierHistory = prev.tierHistory }
            }
            c.unavailable = nil
            c.record(t)
            list.append(c)
        }
        let foundIDs = Set(list.map(\.id))
        for var c in channels where !foundRFs.contains(c.rf) && !foundIDs.contains(c.id) {
            c.record(3)                             // not received this time: a poor result
            list.append(c)
        }
        setChannels(list)
    }

    /// A reception result while watching (1 clean at normal gain, 2 clean with a boost, 3 failed),
    /// for every channel on the RF channel. Returns the resulting bucket.
    @discardableResult
    func record(rf: Int, _ t: Int) -> Int {
        var result = t
        for i in channels.indices where channels[i].rf == rf { channels[i].record(t); result = channels[i].tier ?? t }
        save()
        return result
    }

    /// The user checks or unchecks a channel in Settings.
    func setHidden(_ id: String, _ hidden: Bool) {
        if let i = channels.firstIndex(where: { $0.id == id }) {
            channels[i].hidden = hidden
            channels[i].autoHidden = nil
            if hidden { channels[i].userKept = nil }
            else {
                channels[i].unavailable = nil               // re-enabling it clears the weak mark
                if channels[i].tier == 3 { channels[i].userKept = true }
            }
            save()
        }
    }

    /// Descriptions that arrived before their event (event ID by guide key).
    private var pendingDesc: [String: [Int: String]] = [:]

    func add(event incoming: GuideEvent, key: String) {
        var e = incoming
        var list = guide[key] ?? []
        if let i = list.firstIndex(where: { $0.eventID == e.eventID && abs($0.start.timeIntervalSince(e.start)) < 60 }) {
            if e.desc == nil { e.desc = list[i].desc }            // descriptions come separately
            if list[i] == e { return }
            list[i] = e
        } else {
            if let d = pendingDesc[key]?.removeValue(forKey: e.eventID) { e.desc = d }
            // a new event replaces anything it overlaps (schedules change)
            list.removeAll { $0.start < e.end && e.start < $0.end }
            list.append(e)
        }
        list.sort { $0.start < $1.start }
        guide[key] = list
        dirty = true
    }

    private var dirty = false

    /// Listings from an online source or an imported file for one channel. An event only fills
    /// time that no better-ranked listing covers; it replaces overlapping listings of its own or a
    /// worse rank (the station's own broadcast data, rank 0, always wins).
    func addExternal(_ events: [GuideEvent], key: String) {
        guard !events.isEmpty else { return }
        var list = guide[key] ?? []
        var changed = false
        for e in events where e.end > Date().addingTimeInterval(-6 * 3600) {
            if list.contains(where: { $0.rank < e.rank && $0.start < e.end && e.start < $0.end }) { continue }
            if let same = list.firstIndex(where: { $0.rank == e.rank && $0.start == e.start && $0.duration == e.duration }) {
                if list[same] != e { list[same] = e; changed = true }
                continue
            }
            list.removeAll { $0.rank >= e.rank && $0.start < e.end && e.start < $0.end }
            list.append(e); changed = true
        }
        guard changed else { return }
        list.sort { $0.start < $1.start }
        guide[key] = list
        dirty = true
    }

    func setNetwork(_ id: String, _ network: String?) {
        guard let i = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[i].network = (network?.isEmpty ?? true) ? nil : network
        save()
    }

    /// A program description (Extended Text Table) for event `eventID` on guide key `key`.
    func describe(key: String, eventID: Int, text: String) {
        if var list = guide[key], let i = list.firstIndex(where: { $0.eventID == eventID && $0.end > Date() }) {
            if list[i].desc == text { return }
            list[i].desc = text; guide[key] = list; dirty = true
        } else {
            pendingDesc[key, default: [:]][eventID] = text
        }
    }

    /// When each RF channel's guide was last read completely (RF channel -> time).
    private(set) var guideUpdated: [Int: Date] = {
        let d = AppDefaults.store.dictionary(forKey: "guideUpdated") as? [String: Double] ?? [:]
        return Dictionary(uniqueKeysWithValues: d.compactMap { k, v in Int(k).map { ($0, Date(timeIntervalSince1970: v)) } })
    }()

    func markGuideUpdated(rf: Int) {
        guideUpdated[rf] = Date()
        AppDefaults.store.set(Dictionary(uniqueKeysWithValues: guideUpdated.map { (String($0.key), $0.value.timeIntervalSince1970) }),
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
    var lines: [String]            // plain text (also read by VoiceOver)
    var runs: [[CaptionRun]]?      // the same lines as styled runs
    var justify: Int?              // 708: 0 left, 1 right, 2 centre, 3 full
    var fill: String?              // 708 window fill colour "#RRGGBB" and opacity
    var fo: Double?
}

/// A run of caption text in one style (colours "#RRGGBB", opacities 0...1; see dsp/atsc_captions.c).
struct CaptionRun: Decodable, Hashable {
    var t: String
    var fg: String, fo: Double
    var bg: String, bo: Double
    var i: Int, u: Int
    var f: Int                     // 708 font style: 0 default, 1 mono serif, 2 serif, 3 mono sans, 4 sans, 5 casual, 6 cursive, 7 small caps
    var s: Int                     // pen size: 0 small, 1 standard, 2 large
    var e: Int                     // edge: 0 none, 1 raised, 2 depressed, 3 uniform (outline), 4/5 drop shadow
}
