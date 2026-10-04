import CryptoKit
import Foundation
import Security

/// Program listings from outside the broadcast, for channels whose station sends little or none:
///   EPGTalk (epgtalk.com) local-market and national XMLTV feeds,
///   XMLTV files or URLs the user imports,
///   TVmaze (tvmaze.com, CC BY-SA) network schedules.
/// Runs off the main thread; results go to the Library ranked below the station's own data.
final class OnlineGuide {
    struct Settings {
        var epgTalk = true
        var tvMaze = true
        var market = ""                       // EPGTalk local market ("" = detect)
        var imports: [String] = []            // XMLTV file paths or URLs
        var sdUser = "", sdHash = "", sdLineup = ""   // Schedules Direct (all empty: not used)
    }

    /// What one refresh did, for the Settings page.
    struct Report {
        var lines: [String] = []
        var matched: [String: String] = [:]   // channel id -> source description
        var markets: [String] = []
        var detectedMarket = ""
    }

    static let epgTalkLocal = URL(string: "https://epgtalk.com/US_local_guide.xml.gz")!
    static let epgTalkNational = URL(string: "https://epgtalk.com/US_guide.xml.gz")!
    static let folder: URL = {
        let u = Library.folder.appendingPathComponent("online", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    // MARK: networks

    /// Broadcast networks with national schedules that affiliates carry at the same local times.
    static let affiliateNetworks = ["ABC", "CBS", "NBC", "FOX", "PBS", "The CW", "MyNetworkTV", "ION Television"]
    /// Networks whose affiliates air the network schedule at the same local clock times (PBS stations
    /// schedule independently; multicast networks air one feed at the same moment everywhere).
    static let clockNetworks: Set<String> = ["ABC", "CBS", "NBC", "FOX", "The CW"]

    /// Multicast networks by the short names stations give them in their channel tables, and the
    /// names the national feed uses. A guess the user can correct in Settings > Channels.
    static let multicast: [(short: [String], network: String)] = [
        (["GREAT", "GAF"], "Great American Family"), (["Antenna", "ANTENNA"], "Antenna TV"),
        (["Grit", "GRIT"], "Grit"), (["ShopLC", "SHOPLC"], "Shop LC"), (["Rewind", "REWIND"], "Rewind TV"),
        (["Comet", "COMET"], "Comet TV"), (["Laff", "LAFF"], "Laff"), (["Bounce", "BOUNCE"], "Bounce"),
        (["COZI", "Cozi"], "COZI TV"), (["HEROES", "H&I"], "Heroes & Icons"), (["QVC"], "QVC"), (["HSN"], "HSN"),
        (["GameSho"], "Game Show Central"), (["GSN"], "Game Show Network"), (["OXYGEN"], "Oxygen True Crime"), (["Quest"], "Quest"),
        (["Crime"], "True Crime Network"), (["Mystery"], "ION Mystery"), (["IONPlus"], "ION Plus"),
        (["CourtTV"], "Court TV"), (["MeTV"], "MeTV"), (["START"], "Start TV"), (["MOVIES"], "Movies!"),
        (["CATCHY"], "Catchy Comedy"), (["STORY"], "Story Television"), (["DABL"], "Dabl"),
        (["TOONS"], "MeTV Toons"), (["BUSTED"], "Busted"), (["DEFY"], "Defy TV"), (["World"], "World Channel"),
        (["OPBKids"], "PBS Kids"),
    ]

    /// A network for a channel from its name, when it can be told.
    static func guessNetwork(_ ch: VirtualChannel) -> String? {
        let name = ch.name.trimmingCharacters(in: .whitespaces)
        if let m = multicast.first(where: { $0.short.contains(name) }) { return m.network }
        for n in ["FOX", "ION", "PBS", "CW"] where name.uppercased().hasPrefix(n) {
            return n == "ION" ? "ION Television" : n == "CW" ? "The CW" : n
        }
        return nil
    }

    // MARK: refresh

    /// Fetch what is due and match listings to `channels`. Calls `deliver` (any thread) with the
    /// events for each guide key. Synchronous: call on a background queue.
    /// `reference`: the stations' own broadcast listings by network ("NBC" -> KGW's), used to tell
    /// which online markets keep the same clock as ours.
    static func refresh(channels: [VirtualChannel], settings: Settings, reference: [String: [(start: Date, title: String)]],
                        force: Bool, deliver: (String, [GuideEvent]) -> Void) -> Report {
        var report = Report()
        let channels = channels.filter { !$0.hidden }

        if settings.epgTalk {
            // local market feed: exact listings for stations in the market, and same-network affiliates
            if let feed = loadFeed(epgTalkLocal, maxAge: force ? 0 : 12 * 3600, report: &report) {
                report.markets = markets(in: feed)
                let scores = marketAlignment(feed, reference: reference)
                let detected = scores.filter { $0.value >= 3 }.max { $0.value < $1.value }?.key ?? ""
                let market = settings.market.isEmpty ? detected : settings.market
                report.detectedMarket = detected
                report.lines.append("Markets on our clock: " + scores.filter { $0.value >= 3 }.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) (\($0.value))" }.joined(separator: ", "))
                for ch in channels {
                    if let id = exactChannel(feed, market: market, ch: ch), let ev = feed.programmes[id], !ev.isEmpty {
                        deliver(ch.guideKey, events(ev, source: "EPGTalk", priority: 1))
                        report.matched[ch.id] = "EPGTalk (\(feed.channels[id]?.names.first ?? id))"
                    } else if let net = ch.network, affiliateNetworks.contains(net),
                              let id = proxyAffiliate(feed, network: net, scores: scores), let ev = feed.programmes[id] {
                        let label = feed.channels[id]?.names.first ?? net
                        deliver(ch.guideKey, events(ev, source: "EPGTalk: \(net) schedule from \(label); local programs may differ", priority: 3))
                        report.matched[ch.id] = report.matched[ch.id] ?? "EPGTalk (\(label), \(net) schedule)"
                    }
                }
            }
            // national feed: multicast networks (read only when a channel needs one)
            let wanted = Set(channels.compactMap { ch -> String? in
                guard let n = ch.network, !affiliateNetworks.contains(n) else { return nil }
                return n.lowercased()
            })
            if !wanted.isEmpty, let feed = loadFeed(epgTalkNational, maxAge: force ? 0 : 12 * 3600, report: &report,
                                                   keep: { names in names.contains { wanted.contains(normalized($0)) } }) {
                for ch in channels {
                    guard let n = ch.network?.lowercased(), wanted.contains(n) else { continue }
                    let ids = feed.channels.values.filter { $0.names.contains { normalized($0) == n } }.map(\.id).sorted()
                    guard let id = ids.max(by: { (feed.programmes[$0]?.count ?? 0) < (feed.programmes[$1]?.count ?? 0) }),
                          let ev = feed.programmes[id], !ev.isEmpty else { continue }
                    // where the station sends its own listings, they must agree (a wrong network guess does not)
                    if let ref = reference[ch.network!], ref.count >= 5 {
                        let set = Set(ref.map { "\(Int($0.start.timeIntervalSince1970 / 60))|\(titleKey($0.title))" })
                        if !ev.contains(where: { set.contains("\(Int($0.start.timeIntervalSince1970 / 60))|\(titleKey($0.title))") }) {
                            report.lines.append("\(ch.number) \(ch.name): national \(ch.network!) schedule does not match the broadcast; not used")
                            continue
                        }
                    }
                    deliver(ch.guideKey, events(ev, source: "EPGTalk (\(ch.network!) national schedule)", priority: 1))
                    report.matched[ch.id] = "EPGTalk (\(ch.network!) national schedule)"
                }
            }
        }

        // imported XMLTV: matched by channel number, or by name
        for src in settings.imports {
            let url = src.hasPrefix("http") ? URL(string: src) : URL(fileURLWithPath: (src as NSString).expandingTildeInPath)
            guard let url, let feed = loadFeed(url, maxAge: force ? 0 : 6 * 3600, report: &report) else { continue }
            for ch in channels {
                let ids = feed.channels.values.filter { c in
                    c.names.contains { $0 == ch.number || $0.hasPrefix(ch.number + " ") || $0.caseInsensitiveCompare(ch.name) == .orderedSame }
                }.map(\.id)
                guard let id = ids.first, let ev = feed.programmes[id], !ev.isEmpty else { continue }
                deliver(ch.guideKey, events(ev, source: "Imported (\(url.lastPathComponent))", priority: 2))
                report.matched[ch.id] = report.matched[ch.id] ?? "Imported (\(url.lastPathComponent))"
            }
        }

        // Schedules Direct, if the user subscribes: exact listings by channel number
        if !settings.sdUser.isEmpty, !settings.sdHash.isEmpty, !settings.sdLineup.isEmpty {
            let cache = folder.appendingPathComponent("schedulesdirect.stamp")
            let age = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { Date().timeIntervalSince($0) } ?? .infinity
            if force || age > 12 * 3600 {
                let byKey = SchedulesDirect.listings(user: settings.sdUser, hash: settings.sdHash, lineup: settings.sdLineup,
                                                     channels: channels, days: 7, report: &report)
                for (key, ev) in byKey where !ev.isEmpty {
                    deliver(key, ev)
                    if let ch = channels.first(where: { $0.guideKey == key }) { report.matched[ch.id] = report.matched[ch.id] ?? "Schedules Direct" }
                }
                if !byKey.isEmpty { FileManager.default.createFile(atPath: cache.path, contents: nil) }
            } else {
                report.lines.append("Schedules Direct: up to date (refreshed every 12 hours)")
            }
        }

        // TVmaze: network schedules for affiliates, at the network's local clock times
        if settings.tvMaze {
            let nets = Set(channels.compactMap(\.network).filter { affiliateNetworks.contains($0) })
            if !nets.isEmpty {
                let byNet = tvMazeSchedule(networks: nets, maxAge: force ? 0 : 12 * 3600, report: &report)
                for ch in channels {
                    guard let n = ch.network, let ev = byNet[n], !ev.isEmpty else { continue }
                    deliver(ch.guideKey, ev)
                    report.matched[ch.id] = report.matched[ch.id] ?? "TVmaze (\(n) schedule)"
                }
            }
        }
        return report
    }

    // MARK: XMLTV

    struct XChannel { var id: String; var names: [String] }
    struct XProgramme {
        var start: Date, stop: Date
        var title = "", subtitle = "", desc = "", rating = "", captions = false
    }
    struct Feed {
        var channels: [String: XChannel] = [:]
        var programmes: [String: [XProgramme]] = [:]
    }

    static func normalized(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "&amp;", with: "&").lowercased()
        for suffix in [" hd", " east", " (east)"] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Download (if older than maxAge) and parse a feed. `keep`: only keep programmes of channels
    /// whose names pass (saves memory on the 170 MB national feed).
    static func loadFeed(_ url: URL, maxAge: TimeInterval, report: inout Report,
                         keep: (([String]) -> Bool)? = nil) -> Feed? {
        let data: Data
        if url.isFileURL {
            guard let d = try? Data(contentsOf: url) else { report.lines.append("Could not read \(url.path)"); return nil }
            data = d
        } else {
            let cache = folder.appendingPathComponent(url.lastPathComponent)
            let age = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { Date().timeIntervalSince($0) } ?? .infinity
            if age > maxAge {
                if let d = download(url) { try? d.write(to: cache); report.lines.append("Downloaded \(url.lastPathComponent) (\(d.count / 1024) KB)") }
                else { report.lines.append("Could not download \(url.absoluteString)") }
            }
            guard let d = try? Data(contentsOf: cache) else { return nil }
            data = d
        }
        let xml = data.starts(with: [0x1F, 0x8B]) ? gunzip(data) : data
        guard let xml else { report.lines.append("Could not decompress \(url.lastPathComponent)"); return nil }
        let p = XMLTVParser(keep: keep)
        let parser = XMLParser(data: xml)
        parser.delegate = p
        parser.parse()
        let n = p.feed.programmes.values.reduce(0) { $0 + $1.count }
        report.lines.append("\(url.lastPathComponent): \(p.feed.channels.count) channels, \(n) programs kept")
        return p.feed
    }

    static func download(_ url: URL) -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("SDR TV/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        var out: Data?
        URLSession.shared.dataTask(with: req) { d, r, _ in
            if let d, (r as? HTTPURLResponse)?.statusCode == 200 { out = d }
            done.signal()
        }.resume()
        done.wait()
        return out
    }

    /// gzip = 10-byte header (+ optional fields), raw DEFLATE, 8-byte trailer.
    static func gunzip(_ d: Data) -> Data? {
        let b = [UInt8](d.prefix(512))
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 { i += 2 + Int(b[10]) | Int(b[11]) << 8 }
        if flags & 8 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 16 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 2 != 0 { i += 2 }
        let body = d.subdata(in: d.startIndex + i ..< d.endIndex - 8)
        return try? (body as NSData).decompressed(using: .zlib) as Data
    }

    final class XMLTVParser: NSObject, XMLParserDelegate {
        var feed = Feed()
        let keep: (([String]) -> Bool)?
        private var keepIDs = Set<String>()
        private var chan: XChannel?
        private var prog: XProgramme?
        private var progChannel = ""
        private var text = ""
        private var inRating = false
        private static let fmt: DateFormatter = {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMddHHmmss Z"; return f
        }()

        init(keep: (([String]) -> Bool)?) { self.keep = keep }

        func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String] = [:]) {
            text = ""
            switch el {
            case "channel": chan = XChannel(id: a["id"] ?? "", names: [])
            case "programme":
                let ch = a["channel"] ?? ""
                guard keep == nil || keepIDs.contains(ch), let s = a["start"].flatMap(Self.fmt.date(from:)),
                      let e = a["stop"].flatMap(Self.fmt.date(from:)) else { prog = nil; return }
                prog = XProgramme(start: s, stop: e); progChannel = ch
            case "rating": inRating = true
            case "subtitles": prog?.captions = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }

        func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch el {
            case "display-name": if !t.isEmpty { chan?.names.append(t) }
            case "channel":
                if let c = chan {
                    feed.channels[c.id] = c
                    if keep?(c.names) ?? true { keepIDs.insert(c.id) }
                }
                chan = nil
            case "title": if prog != nil, prog!.title.isEmpty { prog!.title = t }
            case "sub-title": if prog != nil, prog!.subtitle.isEmpty { prog!.subtitle = t }
            case "desc": if prog != nil, prog!.desc.isEmpty { prog!.desc = t }
            case "value": if inRating, prog != nil, prog!.rating.isEmpty { prog!.rating = t }
            case "rating": inRating = false
            case "programme":
                if let p = prog { feed.programmes[progChannel, default: []].append(p) }
                prog = nil
            default: break
            }
            text = ""
        }
    }

    static func events(_ ps: [XProgramme], source: String, priority: Int) -> [GuideEvent] {
        ps.map { p in
            let desc = [p.subtitle, p.desc].filter { !$0.isEmpty }.joined(separator: ". ")
            var e = GuideEvent(eventID: Int(p.start.timeIntervalSince1970 / 60) & 0x3FFF_FFFF, start: p.start,
                               duration: max(60, Int(p.stop.timeIntervalSince(p.start))), title: p.title)
            e.desc = desc.isEmpty ? nil : desc
            e.rating = p.rating.isEmpty ? nil : p.rating
            e.captions = p.captions ? true : nil
            e.source = source; e.priority = priority
            return e
        }
    }

    // MARK: matching

    /// "CBS Seattle", "US - Antenna TV Kansas City", "8.1 US - NBC News Portland" -> market names.
    static func markets(in feed: Feed) -> [String] {
        var m = Set<String>()
        let nets = ["ABC", "CBS", "NBC", "FOX", "PBS", "CW", "NBC News"]
        for c in feed.channels.values {
            guard var n = c.names.first else { continue }
            if n.hasPrefix("US - ") { n.removeFirst(5) }
            for net in nets.sorted(by: { $0.count > $1.count }) where n.hasPrefix(net + " ") {
                let city = String(n.dropFirst(net.count + 1)).trimmingCharacters(in: .whitespaces)
                if !city.isEmpty { m.insert(city) }
                break
            }
        }
        return m.sorted()
    }

    /// Title for comparison: no "[NEW]"-style tags, punctuation or emoji, first 14 characters.
    static func titleKey(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression).lowercased()
        return String(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init).prefix(14))
    }

    /// The market a feed channel belongs to (its first name ends with it).
    static func market(of c: XChannel, among markets: [String]) -> String? {
        guard let n = c.names.first else { return nil }
        return markets.filter { n.hasSuffix(" " + $0) }.max { $0.count < $1.count }
    }

    /// Does a feed channel carry this network? (Its name has the network as a word.)
    static func carries(_ c: XChannel, _ network: String) -> Bool {
        let n = network.lowercased()
        return c.names.contains { name in
            let l = name.lowercased()
            return l.hasPrefix(n + " ") || l.contains(" " + n + " ") || l.hasSuffix(" " + n)
        }
    }

    /// For each market: how many of its programs match our stations' own broadcast listings in title
    /// and start time (network programs line up only between stations on the same clock).
    static func marketAlignment(_ feed: Feed, reference: [String: [(start: Date, title: String)]]) -> [String: Int] {
        let ms = markets(in: feed)
        var refSet: [String: Set<String>] = [:]          // network -> "minute|title"
        for (net, evs) in reference where clockNetworks.contains(net) { refSet[net] = Set(evs.map { "\(Int($0.start.timeIntervalSince1970 / 60))|\(titleKey($0.title))" }) }
        var score: [String: Int] = [:]
        for c in feed.channels.values {
            guard let m = market(of: c, among: ms) else { continue }
            for (net, set) in refSet where carries(c, net) {
                let hits = (feed.programmes[c.id] ?? []).filter { set.contains("\(Int($0.start.timeIntervalSince1970 / 60))|\(titleKey($0.title))") }.count
                score[m, default: 0] = max(score[m, default: 0], hits)
            }
        }
        return score
    }

    /// The market's own listing for this channel: same channel number, the market in its name, and
    /// the same network when we know it.
    static func exactChannel(_ feed: Feed, market: String, ch: VirtualChannel) -> String? {
        guard !market.isEmpty else { return nil }
        return feed.channels.values.first { c in
            c.names.contains { $0.hasPrefix(ch.number + " ") && $0.hasSuffix(" " + market) } && (ch.network.map { carries(c, $0) } ?? true)
        }?.id
    }

    /// Another market's affiliate of the same network, in the market best aligned with our clock:
    /// its network programs air when ours do (local programs will differ).
    static func proxyAffiliate(_ feed: Feed, network: String, scores: [String: Int]) -> String? {
        guard clockNetworks.contains(network) else { return nil }
        let ms = markets(in: feed)
        let candidates = feed.channels.values.filter { carries($0, network) && !$0.names.contains { $0.contains(" News ") } && (feed.programmes[$0.id]?.count ?? 0) > 20 }
        let best = candidates.compactMap { c -> (String, Int)? in
            guard let m = market(of: c, among: ms), let s = scores[m], s >= 3 else { return nil }
            return (c.id, s)
        }.max { $0.1 < $1.1 }
        return best?.0
    }

    // MARK: TVmaze

    /// Today and the next two days of network schedules. TVmaze gives each airing's time on the
    /// network's own clock; affiliates carry network shows at the same local clock time.
    static func tvMazeSchedule(networks: Set<String>, maxAge: TimeInterval, report: inout Report) -> [String: [GuideEvent]] {
        var out: [String: [GuideEvent]] = [:]
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        let local = DateFormatter(); local.locale = Locale(identifier: "en_US_POSIX"); local.dateFormat = "yyyy-MM-dd HH:mm"
        local.timeZone = .current
        for k in 0..<3 {
            let date = day.string(from: Date().addingTimeInterval(Double(k) * 86400))
            let url = URL(string: "https://api.tvmaze.com/schedule?country=US&date=\(date)")!
            let cache = folder.appendingPathComponent("tvmaze-\(date).json")
            let age = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { Date().timeIntervalSince($0) } ?? .infinity
            if age > maxAge, let d = download(url) { try? d.write(to: cache) }
            guard let d = try? Data(contentsOf: cache),
                  let list = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { continue }
            for item in list {
                guard let show = item["show"] as? [String: Any], let net = (show["network"] as? [String: Any])?["name"] as? String,
                      networks.contains(net), let airdate = item["airdate"] as? String, let airtime = item["airtime"] as? String,
                      !airtime.isEmpty, let start = local.date(from: "\(airdate) \(airtime)") else { continue }
                let runtime = (item["runtime"] as? Int) ?? (show["runtime"] as? Int) ?? 30
                var e = GuideEvent(eventID: Int(start.timeIntervalSince1970 / 60) & 0x3FFF_FFFF, start: start,
                                   duration: runtime * 60, title: show["name"] as? String ?? "")
                let ep = item["name"] as? String ?? ""
                let summary = ((item["summary"] as? String) ?? (show["summary"] as? String) ?? "")
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                e.desc = [ep, summary].filter { !$0.isEmpty }.joined(separator: ". ")
                if e.desc?.isEmpty ?? true { e.desc = nil }
                e.source = "TVmaze: \(net) network schedule; local programs may differ. Data from TVmaze.com (CC BY-SA)."
                e.priority = 4
                out[net, default: []].append(e)
            }
        }
        let n = out.values.reduce(0) { $0 + $1.count }
        report.lines.append("TVmaze: \(n) network airings for \(networks.sorted().joined(separator: ", "))")
        return out
    }
}

// MARK: - Schedules Direct (optional; the user's own subscription)


/// Schedules Direct JSON API (https://json.schedulesdirect.org/20141201). Listings are matched to
/// channels by ATSC number from the user's antenna lineup. Their terms: individual use, open
/// source software. Nothing happens unless the user signs in under Settings > Guide.
enum SchedulesDirect {
    static let base = "https://json.schedulesdirect.org/20141201/"
    static let userAgent: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        return "SDR TV/\(v) (macOS)"
    }()

    struct Lineup: Hashable { var id: String; var name: String; var location: String }

    // credentials: the username in preferences, the SHA-1 of the password in the Keychain
    private static let keychainService = "SDR TV Schedules Direct"

    static func passwordHash(_ password: String) -> String {
        Insecure.SHA1.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func storeHash(_ hash: String, user: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                kSecAttrAccount as String: user]
        SecItemDelete(q as CFDictionary)
        var add = q; add[kSecValueData as String] = Data(hash.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadHash(user: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                kSecAttrAccount as String: user, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func forget(user: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                       kSecAttrAccount as String: user] as CFDictionary)
    }

    // HTTP

    enum SDError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(m) = self { return m }; return nil }
    }

    /// One request; JSON in and out. Synchronous: background threads only.
    static func call(_ path: String, method: String = "GET", token: String? = nil, body: Any? = nil) throws -> Any {
        var req = URLRequest(url: URL(string: base + path)!, timeoutInterval: 120)
        req.httpMethod = method
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let token { req.setValue(token, forHTTPHeaderField: "token") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let done = DispatchSemaphore(value: 0)
        var data: Data?, failure: Error?
        URLSession.shared.dataTask(with: req) { d, _, e in data = d; failure = e; done.signal() }.resume()
        done.wait()
        if let failure { throw failure }
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) else { throw SDError.message("No response from Schedules Direct") }
        if let o = json as? [String: Any], let code = o["code"] as? Int, code != 0 {
            throw SDError.message((o["message"] as? String) ?? "Schedules Direct error \(code)")
        }
        return json
    }

    static func token(user: String, hash: String) throws -> String {
        let r = try call("token", method: "POST", body: ["username": user, "password": hash]) as? [String: Any]
        guard let t = r?["token"] as? String else { throw SDError.message("Sign-in failed") }
        return t
    }

    /// Account expiry and the lineups already on the account.
    static func status(token: String) throws -> (expires: String, lineups: [Lineup]) {
        let r = try call("status", token: token) as? [String: Any] ?? [:]
        let expires = ((r["account"] as? [String: Any])?["expires"] as? String) ?? ""
        let lineups = (r["lineups"] as? [[String: Any]] ?? []).compactMap { l -> Lineup? in
            guard let id = l["lineup"] as? String ?? l["ID"] as? String else { return nil }
            return Lineup(id: id, name: l["name"] as? String ?? id, location: "")
        }
        return (String(expires.prefix(10)), lineups)
    }

    /// Antenna lineups for a ZIP code.
    static func antennaLineups(token: String, zip: String) throws -> [Lineup] {
        let r = try call("headends?country=USA&postalcode=\(zip)", token: token) as? [[String: Any]] ?? []
        return r.filter { ($0["transport"] as? String) == "Antenna" }.flatMap { h -> [Lineup] in
            (h["lineups"] as? [[String: Any]] ?? []).compactMap { l in
                guard let id = l["lineup"] as? String else { return nil }
                return Lineup(id: id, name: l["name"] as? String ?? id, location: h["location"] as? String ?? "")
            }
        }
    }

    /// Put a lineup on the account (Schedules Direct allows six changes a day).
    static func addLineup(token: String, id: String) throws { _ = try call("lineups/\(id)", method: "PUT", token: token) }

    /// Listings for our channels: lineup map by ATSC number -> schedules -> program details.
    static func listings(user: String, hash: String, lineup: String, channels: [VirtualChannel], days: Int,
                         report: inout OnlineGuide.Report) -> [String: [GuideEvent]] {
        do {
            let tok = try token(user: user, hash: hash)
            let lu = try call("lineups/\(lineup)", token: tok) as? [String: Any] ?? [:]
            var stationFor: [String: String] = [:]                 // "6.1" -> stationID
            for m in lu["map"] as? [[String: Any]] ?? [] {
                guard let sid = m["stationID"] as? String else { continue }
                if let maj = m["atscMajor"] as? Int, let min = m["atscMinor"] as? Int { stationFor["\(maj).\(min)"] = sid }
                else if let ch = m["channel"] as? String { stationFor[ch.replacingOccurrences(of: "-", with: ".")] = sid }
            }
            let wanted = channels.compactMap { ch in stationFor[ch.number].map { (ch, $0) } }
            guard !wanted.isEmpty else { report.lines.append("Schedules Direct: no channels of \(lineup) match ours"); return [:] }
            let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
            fmt.timeZone = TimeZone(identifier: "UTC")
            let dates = (0..<days).map { fmt.string(from: Date().addingTimeInterval(Double($0) * 86400)) }
            let sids = Array(Set(wanted.map(\.1)))
            let sched = try call("schedules", method: "POST", token: tok, body: sids.map { ["stationID": $0, "date": dates] }) as? [[String: Any]] ?? []
            // details of every program, 5000 to a request
            var airings: [String: [[String: Any]]] = [:]           // stationID -> airings
            var programIDs = Set<String>()
            for s in sched {
                guard let sid = s["stationID"] as? String else { continue }
                let ps = s["programs"] as? [[String: Any]] ?? []
                airings[sid, default: []] += ps
                ps.compactMap { $0["programID"] as? String }.forEach { programIDs.insert($0) }
            }
            var programs: [String: [String: Any]] = [:]
            let ids = Array(programIDs)
            for chunk in stride(from: 0, to: ids.count, by: 5000) {
                let part = Array(ids[chunk..<min(chunk + 5000, ids.count)])
                for p in try call("programs", method: "POST", token: tok, body: part) as? [[String: Any]] ?? [] {
                    if let id = p["programID"] as? String { programs[id] = p }
                }
            }
            let iso = ISO8601DateFormatter()
            var out: [String: [GuideEvent]] = [:]
            for (ch, sid) in wanted {
                out[ch.guideKey] = (airings[sid] ?? []).compactMap { a in
                    guard let pid = a["programID"] as? String, let t = (a["airDateTime"] as? String).flatMap(iso.date(from:)),
                          let dur = a["duration"] as? Int else { return nil }
                    let p = programs[pid] ?? [:]
                    let title = ((p["titles"] as? [[String: Any]])?.first?["title120"] as? String) ?? "Program"
                    var e = GuideEvent(eventID: Int(t.timeIntervalSince1970 / 60) & 0x3FFF_FFFF, start: t, duration: dur, title: title)
                    let d = p["descriptions"] as? [String: Any]
                    let text = ((d?["description1000"] as? [[String: Any]])?.first?["description"] as? String)
                        ?? ((d?["description100"] as? [[String: Any]])?.first?["description"] as? String) ?? ""
                    let ep = p["episodeTitle150"] as? String ?? ""
                    let desc = [ep, text].filter { !$0.isEmpty }.joined(separator: ". ")
                    e.desc = desc.isEmpty ? nil : desc
                    e.rating = ((a["ratings"] as? [[String: Any]]) ?? (p["contentRating"] as? [[String: Any]]))?
                        .first { ($0["body"] as? String)?.contains("USA") ?? false }?["code"] as? String
                    if (a["audioProperties"] as? [String])?.contains("cc") == true { e.captions = true }
                    e.source = "Schedules Direct"; e.priority = 2
                    return e
                }
            }
            report.lines.append("Schedules Direct: \(wanted.count) channels, \(programIDs.count) programs from \(lineup)")
            return out
        } catch {
            report.lines.append("Schedules Direct: \(error.localizedDescription)")
            return [:]
        }
    }
}
