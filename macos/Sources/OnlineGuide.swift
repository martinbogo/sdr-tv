import Foundation

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
