import AppKit
import SwiftUI

/// The app's state and commands. Main thread only.
final class TV: ObservableObject {
    static let shared = TV()
    let engine = Engine()
    let library = Library()
    private let defaults = UserDefaults.standard

    // tuner settings
    @Published var ampOn: Bool { didSet { defaults.set(ampOn, forKey: "amp"); engine.device?.setAmp(ampOn) } }
    @Published var lna: Int { didSet { defaults.set(lna, forKey: "lna"); engine.device?.setLNA(lna) } }
    @Published var vga: Int { didSet { defaults.set(vga, forKey: "vga"); engine.device?.setVGA(vga) } }
    @Published var autoGain: Bool { didSet { defaults.set(autoGain, forKey: "autoGain") } }
    @Published var volume: Double { didSet { defaults.set(volume, forKey: "volume"); engine.player.volume = Float(volume) } }
    @Published var muted = false { didSet { engine.player.muted = muted } }

    // accessibility: captions and audio tracks
    @Published var captionsOn: Bool { didSet { defaults.set(captionsOn, forKey: "captionsOn"); applyCaptionChoice() } }
    @Published var captionLanguage: String { didSet { defaults.set(captionLanguage, forKey: "captionLanguage"); applyCaptionChoice() } }
    @Published var captionScale: Double { didSet { defaults.set(captionScale, forKey: "captionScale") } }
    @Published var captionBackground: Double { didSet { defaults.set(captionBackground, forKey: "captionBackground") } }
    // caption appearance: the broadcaster's styling, or the viewer's own (US rules require the choice)
    @Published var captionCustom: Bool { didSet { defaults.set(captionCustom, forKey: "captionCustom") } }
    @Published var captionTextColor: String { didSet { defaults.set(captionTextColor, forKey: "captionTextColor") } }
    @Published var captionBackColor: String { didSet { defaults.set(captionBackColor, forKey: "captionBackColor") } }
    @Published var captionFont: Int { didSet { defaults.set(captionFont, forKey: "captionFont") } }
    @Published var captionEdge: Int { didSet { defaults.set(captionEdge, forKey: "captionEdge") } }
    @Published var audioLanguage: String { didSet { defaults.set(audioLanguage, forKey: "audioLanguage") } }
    @Published var preferDescription: Bool { didSet { defaults.set(preferDescription, forKey: "preferDescription") } }
    @Published private(set) var audioTracks: [Engine.AudioTrack] = []
    @Published private(set) var audioIndex = 0
    @Published private(set) var captionChoices: [CaptionChoice] = []
    @Published private(set) var captionService = 0          // what is being decoded (0 off)
    @Published private(set) var captionRegions: [CaptionRegion] = []
    private var tracksChosenFor: String?

    struct CaptionChoice: Identifiable, Hashable {
        let service: Int          // 1...4 CC1-CC4, 101... DTV service
        let lang: String
        let label: String
        var id: Int { service }
    }

    // what is on
    @Published private(set) var channels: [VirtualChannel] = []
    @Published private(set) var current: VirtualChannel?
    private var previous: VirtualChannel?
    @Published private(set) var aspect: CGFloat = 16.0 / 9.0   // picture display aspect
    /// The channel's last-seen picture, shown dimmed until live video arrives.
    @Published private(set) var still: Snapshots.Still?
    /// The live picture is on screen since the last channel change (set the moment the player shows
    /// its first frame, ahead of the half-second status check).
    @Published private(set) var liveShown = false
    private let snapshots = Snapshots()
    private var snapshotTicks = 0
    @Published private(set) var format = ""          // "1080i", "720p", "480i"
    @Published private(set) var audioLayout = ""     // "5.1", "Stereo"
    @Published private(set) var stats = atsc_stats()
    @Published private(set) var hasPicture = false
    @Published private(set) var deviceError: String?
    @Published private(set) var broadcastClock: Date?
    @Published var guideTick = 0                     // bumps when guide data changes

    // on-screen display
    @Published var bannerVisible = false
    @Published var volumeVisible = false
    @Published var controlsVisible = false
    @Published var guideVisible = false
    @Published var entry = ""                        // digits typed for direct channel entry
    @Published var status: String?                  // transient message (top)
    @Published private(set) var scanning = false
    @Published private(set) var scanProgress = 0.0
    @Published private(set) var scanRF = 0
    @Published private(set) var scanPhase = ""
    @Published private(set) var scanResults: [VirtualChannel] = []
    @Published private(set) var scanFinished = false
    // online listings (EPGTalk, imported XMLTV, TVmaze) for channels the broadcast leaves empty
    @Published var enhanceSD: Bool { didSet { defaults.set(enhanceSD, forKey: "enhanceSD"); engine.player.enhancer.enabled = enhanceSD } }
    @Published var useEPGTalk: Bool { didSet { defaults.set(useEPGTalk, forKey: "useEPGTalk"); refreshOnlineGuide() } }
    @Published var useTVMaze: Bool { didSet { defaults.set(useTVMaze, forKey: "useTVMaze"); refreshOnlineGuide() } }
    @Published var guideMarket: String { didSet { defaults.set(guideMarket, forKey: "guideMarket"); refreshOnlineGuide() } }
    @Published var xmltvImports: [String] { didSet { defaults.set(xmltvImports, forKey: "xmltvImports"); refreshOnlineGuide(force: true) } }
    // Schedules Direct (optional): username and chosen lineup in preferences, password hash in the Keychain
    @Published private(set) var sdUser: String
    @Published var sdLineup: String { didSet { defaults.set(sdLineup, forKey: "sdLineup") } }
    @Published private(set) var sdStatus = ""
    @Published private(set) var sdLineups: [SchedulesDirect.Lineup] = []
    @Published private(set) var sdBusy = false
    @Published private(set) var onlineReport = OnlineGuide.Report()
    @Published private(set) var onlineRefreshing = false
    @Published private(set) var onlineUpdatedAt: Date?
    @Published private(set) var guideRefreshing = false
    @Published private(set) var guideRefreshProgress = 0.0
    @Published private(set) var guideRefreshNote = ""
    @Published var setupVisible = false             // modal scan window (first run, or a rescan)
    var firstRun: Bool { !defaults.bool(forKey: "initialScanDone") }
    @Published private(set) var recordingSince: Date?
    // scheduled recordings
    let schedule = RecordingSchedule()
    @Published private(set) var scheduleTick = 0                  // bumps when the schedule changes
    @Published private(set) var activeRecordings: [ScheduledRecording] = []
    private var warnedRecordings = Set<UUID>()
    private var blockedTuneAt: (id: String, at: Date)?
    private var awake: NSObjectProtocol?

    private var bannerTimer: DispatchWorkItem?
    private var volumeTimer: DispatchWorkItem?
    private var controlsTimer: DispatchWorkItem?
    private var entryTimer: DispatchWorkItem?
    private var statusTimer: DispatchWorkItem?
    private var lastPackets: UInt64 = 0
    private var retryTicks = 0
    private var lockedAt: Date?

    // reception health
    @Published private(set) var media = atsc_media_status()
    var videoCodec: String { media.video_type != 0 ? String(cString: atsc_stream_type_name(media.video_type)) : "" }
    var audioCodec: String { media.audio_type != 0 ? String(cString: atsc_stream_type_name(media.audio_type)) : "" }
    @Published private(set) var lossRate = 0.0       // fraction of packets lost over the last ~2 s
    @Published private(set) var weakSignal = false   // picture showing but data being lost
    @Published private(set) var rescueNote: String?  // what the automatic rescue is trying
    private var tunedAt = Date()
    private var lastFrameAt: Date?
    var secondsSinceTune: Double { Date().timeIntervalSince(tunedAt) }
    private var lastVideoFrames: UInt64 = 0
    private var rsHist: [(good: UInt64, bad: UInt64)] = []
    private var rescue: Rescue?
    @Published private(set) var rechecking = false

    /// Receiver settings tried, in order, when a channel will not decode.
    private struct Rescue {
        var rf: Int
        var step = 0
        var stepStarted = Date()
        var bestSNR = 0.0
        var base: (lna: Int, vga: Int)
        var settling = false
        static let ladder: [(dLNA: Int, dVGA: Int, amp: Bool, note: String)] = [
            (0, 0, false, "Adjusting gain"),
            (0, 8, false, "Adding 8 dB of gain"),
            (8, 8, false, "Adding 16 dB of gain"),
            (0, 0, true, "Switching in the RF amplifier"),
            (0, -8, true, "RF amplifier with less gain (avoids overload)"),
        ]
    }

    private init() {
        defaults.register(defaults: ["amp": false, "lna": 24, "vga": 20, "autoGain": true, "volume": 0.8,
                                     "captionsOn": false, "captionLanguage": "eng", "captionScale": 1.0,
                                     "captionBackground": 0.75, "audioLanguage": "eng", "preferDescription": false])
        enhanceSD = defaults.object(forKey: "enhanceSD") as? Bool ?? true
        useEPGTalk = defaults.object(forKey: "useEPGTalk") as? Bool ?? true
        useTVMaze = defaults.object(forKey: "useTVMaze") as? Bool ?? true
        guideMarket = defaults.string(forKey: "guideMarket") ?? ""
        xmltvImports = defaults.stringArray(forKey: "xmltvImports") ?? []
        sdUser = defaults.string(forKey: "sdUser") ?? ""
        sdLineup = defaults.string(forKey: "sdLineup") ?? ""
        captionsOn = defaults.bool(forKey: "captionsOn")
        captionLanguage = defaults.string(forKey: "captionLanguage") ?? "eng"
        captionScale = defaults.double(forKey: "captionScale")
        captionBackground = defaults.double(forKey: "captionBackground")
        captionCustom = defaults.bool(forKey: "captionCustom")
        captionTextColor = defaults.string(forKey: "captionTextColor") ?? "#FFFFFF"
        captionBackColor = defaults.string(forKey: "captionBackColor") ?? "#000000"
        captionFont = defaults.integer(forKey: "captionFont")
        captionEdge = defaults.integer(forKey: "captionEdge")
        audioLanguage = defaults.string(forKey: "audioLanguage") ?? "eng"
        preferDescription = defaults.bool(forKey: "preferDescription")
        ampOn = defaults.bool(forKey: "amp")
        lna = defaults.integer(forKey: "lna")
        vga = defaults.integer(forKey: "vga")
        autoGain = defaults.bool(forKey: "autoGain")
        volume = defaults.double(forKey: "volume")
        engine.player.volume = Float(volume)
        engine.player.enhancer.enabled = enhanceSD
        channels = library.visibleChannels

        engine.onChannels = { [weak self] list in self?.channelsReceived(list) }
        engine.onGuide = { [weak self] batch in
            guard let self else { return }
            let debug = ProcessInfo.processInfo.environment["ATSC_GUIDEDEBUG"] != nil
            for (rf, src, ev) in batch.events where rf > 0 {
                if debug { FileHandle.standardError.write("guide rf \(rf) source \(src) \(ev.start) \(ev.duration / 60) min \(ev.title)\n".data(using: .utf8)!) }
                library.add(event: ev, key: "\(rf)-\(src)")
            }
            for (rf, src, evid, text) in batch.descriptions where rf > 0 {
                library.describe(key: "\(rf)-\(src)", eventID: evid, text: text)
            }
            guideTick &+= 1                          // one view refresh per batch
        }
        engine.onFormat = { [weak self] w, h, il, ach in
            guard let self else { return }
            format = "\(h == 1088 ? 1080 : h)\(il ? "i" : "p")"
            audioLayout = ach >= 6 ? "5.1" : ach == 1 ? "Mono" : ach > 0 ? "Stereo" : ""
        }
        engine.onClock = { [weak self] d in self?.broadcastClock = d }
        engine.player.onAspect = { [weak self] a in self?.aspect = a }
        engine.player.onFirstPicture = { [weak self] in self?.liveShown = true; self?.still = nil }
        engine.player.onCaption = { [weak self] json in self?.showCaptions(json) }
        engine.onProgramInfo = { [weak self] info in self?.programInfo(info) }

        openDevice()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.library.saveGuideIfNeeded() }
        // online listings: shortly after launch (the picture comes first), then every 6 hours
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.refreshOnlineGuide() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.refreshOnlineGuide() }
    }

    // MARK: device

    func openDevice() {
        let start = current ?? lastWatched() ?? channels.first
        let rf = start?.rf ?? 14
        do {
            try engine.open(rf: rf, amp: ampOn, lna: lna, vga: vga)
            deviceError = nil
            if firstRun || library.channels.isEmpty { beginSetup() }
            else if let start, !setupVisible { tune(start, showBanner: true) }
        } catch {
            deviceError = error.localizedDescription
            if firstRun { setupVisible = true }      // the setup window explains what is missing
        }
    }

    /// Show the scan window and start scanning (first run, or Channel > Scan for Channels).
    func beginSetup() {
        setupVisible = true
        scanFinished = false
        scanResults = []
        if deviceError == nil { scan() }
    }

    /// Close the scan window and start watching.
    func finishSetup() {
        setupVisible = false
        if let first = lastWatched() ?? channels.first { current = nil; tune(first) }
    }

    private func lastWatched() -> VirtualChannel? {
        guard let id = defaults.string(forKey: "lastChannel") else { return nil }
        return channels.first { $0.id == id }
    }

    // MARK: tuning

    /// Keep the current picture as the channel's last-seen still.
    private func captureStill() {
        guard let cur = current, hasPicture else { return }
        let a = aspect, id = cur.id, player = engine.player
        DispatchQueue.global(qos: .utility).async { [weak self] in   // image work off the main thread
            guard let img = player.snapshot(aspect: a) else { return }
            DispatchQueue.main.async { self?.snapshots.store(img, aspect: a, for: id) }
        }
    }

    func tune(_ ch: VirtualChannel, showBanner: Bool = true, forRecording: Bool = false) {
        guard deviceError == nil else { return }
        // a scheduled recording holds the tuner on its station: another station stops it, so ask first
        if !forRecording, let rec = activeRecordings.first(where: { $0.rf != ch.rf }) {
            if let b = blockedTuneAt, b.id == ch.id, Date().timeIntervalSince(b.at) < 6 {
                for r in activeRecordings where r.rf != ch.rf { finishRecording(r, note: "Stopped early: changed station") }
            } else {
                blockedTuneAt = (ch.id, Date())
                flash("Recording \"\(rec.title)\" until \(rec.recordUntil.formatted(date: .omitted, time: .shortened)). Channels from the same station still work; choose \(ch.number) again to stop the recording and change.", seconds: 6)
                return
            }
        }
        if current?.id != ch.id { captureStill() }
        liveShown = false
        still = current?.id == ch.id && hasPicture ? nil : snapshots.still(for: ch.id)
        if ch.isUnavailable { flash("\(ch.number) \(ch.name) was too weak last time. Trying again…", seconds: 4) }
        if let cur = current, cur.id != ch.id { previous = cur }
        if engine.currentRF != ch.rf || current == nil {
            // the station's own receiver settings go in before the retune, so the receiver acquires
            // once at the right gain instead of being jolted by a gain change just after
            if let l = ch.lna, l != lna { lna = l }
            if let v = ch.vga, v != vga { vga = v }
            if let a = ch.amp, a != ampOn { ampOn = a }
            engine.tune(rf: ch.rf); lockedAt = nil
        }
        engine.select(program: ch.program)
        current = ch
        hasPicture = false; format = ""; audioLayout = ""
        tunedAt = Date(); lastFrameAt = nil; lastVideoFrames = 0; rsHist = []; weakSignal = false
        audioTracks = []; audioIndex = 0; captionChoices = []; captionRegions = []; tracksChosenFor = nil
        applyCaptionChoice()
        if rescue?.rf != ch.rf { rescue = nil; rescueNote = nil }
        defaults.set(ch.id, forKey: "lastChannel")
        if showBanner { showInfo() }
    }

    /// Channel up/down: skips channels marked weak (they can still be chosen directly).
    func step(_ d: Int) {
        let list = channels.filter { !$0.isUnavailable || $0.id == current?.id }
        guard !list.isEmpty else { return }
        let i = current.flatMap { c in list.firstIndex { $0.id == c.id } } ?? -d
        tune(list[(i + d + list.count) % list.count])
    }

    func recall() { if let p = previous { tune(p) } }

    /// Direct entry: digits and "." (8.1, 81 or 8 then pause).
    func type(_ c: Character) {
        if c == "." || c == "-" { if !entry.contains(".") { entry += entry.isEmpty ? "" : "." } }
        else if c.isNumber, entry.count < 6 { entry.append(c) }
        entryTimer?.cancel()
        let t = DispatchWorkItem { [weak self] in self?.commitEntry() }
        entryTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: t)
    }

    func commitEntry() {
        entryTimer?.cancel()
        let e = entry; entry = ""
        guard !e.isEmpty else { return }
        let parts = e.split(separator: ".").compactMap { Int($0) }
        var match: VirtualChannel?
        if parts.count == 2 { match = channels.first { $0.major == parts[0] && $0.minor == parts[1] } }
        else if let n = parts.first {
            match = channels.first { $0.major == n }                                     // "8" -> 8.1
                ?? channels.first { "\($0.major)\($0.minor)" == String(n) }               // "81" -> 8.1
        }
        if let match { tune(match) } else { flash("No channel \(e)") }
    }

    // MARK: channel list

    private func channelsReceived(_ list: [VirtualChannel]) {
        if scanning || rechecking { scanFound = list; return }
        guard !list.isEmpty else { return }
        guard let rf = list.first?.rf, rf > 0 else { return }
        library.merge(rf: rf, found: list)
        channels = library.visibleChannels
        // a station may renumber: keep the current selection pointing at the same program
        if let cur = current, let upd = channels.first(where: { $0.rf == cur.rf && $0.program == cur.program }) {
            current = upd
        }
    }

    func setHidden(_ ch: VirtualChannel, _ hidden: Bool) {
        library.setHidden(ch.id, hidden)
        channels = library.visibleChannels
    }

    var allChannels: [VirtualChannel] { library.channels }

    // MARK: scanning

    private var scanFound: [VirtualChannel] = []
    private var scanCancel = false

    /// Set LNA/VGA (and optionally the RF amp) on the device to bring the ADC level near `target`
    /// dBFS for the RF channel just tuned. Runs on the scan thread. Returns the settings used.
    private func settleGain(target: Double, allowAmp: Bool) -> (lna: Int, vga: Int, amp: Bool, dbfs: Double) {
        var l = 24, v = 20, amp = false
        let dev = engine.device                     // background thread: gain changes wait until applied
        dev?.setAmp(false, wait: true); dev?.setLNA(l, wait: true); dev?.setVGA(v, wait: true)
        var level = -100.0
        for _ in 0..<6 {
            // measure only samples taken after the gain change has settled in the tuner (~10 ms)
            let mark = engine.ring.written
            Thread.sleep(forTimeInterval: 0.04)
            level = engine.ring.recentLevel(after: mark + 200_000) ?? engine.stats().dbfs
            let err = target - level
            if abs(err) < 3 { break }
            var nv = v + Int((err / 2).rounded()) * 2
            var rest = 0
            if nv > 62 { rest = nv - 62; nv = 62 } else if nv < 0 { rest = nv; nv = 0 }
            if rest > 4, l <= 32 { l += 8; nv = max(0, nv - 8) }
            else if rest < -4, l >= 8 { l -= 8; nv = min(62, nv + 8) }
            else if rest > 6, l == 40, v == 62, allowAmp, !amp { amp = true; dev?.setAmp(true, wait: true) }
            if nv == v && rest == 0 { break }
            v = nv
            dev?.setLNA(l, wait: true); dev?.setVGA(v, wait: true)
        }
        // front-end protection, as in normal viewing
        if amp && level > -6 { amp = false; dev?.setAmp(false, wait: true) }
        return (l, v, amp, level)
    }

    /// One RF channel: gain, lock, then the virtual channel table (and a little guide data).
    /// What one RF channel gave: its channels, the pilot strength, and whether more gain could help
    /// (the signal arrived too low for the gain setting to reach its target level).
    private struct ScanResult { var list: [VirtualChannel]; var pilotSNR: Double; var levelLow = false }

    private func scanOne(rf: Int, lockWait: Double, tableWait: Double, target: Double, allowAmp: Bool, boosted: Bool = false)
        -> ScanResult {
        let t0 = Date(); var marks: [(String, Date)] = []
        func mark(_ s: String) { marks.append((s, Date())) }
        defer {
            if ProcessInfo.processInfo.environment["ATSC_DEBUG"] != nil {
                var last = t0
                let parts = marks.map { m -> String in defer { last = m.1 }; return String(format: "%@ %.2f", m.0, m.1.timeIntervalSince(last)) }
                FileHandle.standardError.write(String(format: "scantime RF %d%@: %.2f s [%@]\n", rf, boosted ? " (boosted)" : "",
                    Date().timeIntervalSince(t0), parts.joined(separator: ", ")).data(using: .utf8)!)
            }
        }
        DispatchQueue.main.sync {
            scanRF = rf
            scanFound = []
            engine.device?.setAmp(false); engine.device?.setLNA(24); engine.device?.setVGA(20)
            engine.tune(rf: rf)
            engine.select(program: -1)                 // demodulate and read tables, decode nothing
        }
        // The pilot search needs only ~50 ms of samples. No 8VSB pilot (it stands well above the
        // data when a station is there at all): nothing to find on this frequency, move on.
        if !boosted {
            Thread.sleep(forTimeInterval: 0.1)         // past the receiver reset (stats still show the old channel until then)
            var st = engine.stats()
            let deadline = Date().addingTimeInterval(0.6)
            while Date() < deadline, st.state.rawValue < ATSC_ACQ_SEGMENT.rawValue || st.pilot_snr_db <= 0 {
                Thread.sleep(forTimeInterval: 0.03); st = engine.stats()
            }
            // measured: noise alone reads 11-16 dB here, stations that lock 35 dB and up
            mark("pilot")
            if st.pilot_snr_db < 22 { return ScanResult(list: [], pilotSNR: st.pilot_snr_db) }
        }
        let g = settleGain(target: target, allowAmp: allowAmp)
        mark("gain")
        engine.retune()                                // reacquire at the new gain
        var locked = false
        let lockDeadline = Date().addingTimeInterval(lockWait)
        while Date() < lockDeadline {
            Thread.sleep(forTimeInterval: 0.05)
            if engine.stats().state == ATSC_LOCKED { locked = true; break }
        }
        let pilot = engine.stats().pilot_snr_db
        let levelLow = g.dbfs < target - 6
        mark("lock")
        guard locked else { return ScanResult(list: [], pilotSNR: pilot, levelLow: levelLow) }
        // Channel tables repeat at least every 0.4 s. If not one packet decodes cleanly within 1.2 s
        // the signal is locked but unusable: no point waiting for tables.
        let tableDeadline = Date().addingTimeInterval(tableWait)
        var since = Date(), s0 = engine.stats()
        var got: [VirtualChannel] = []
        while Date() < tableDeadline {
            Thread.sleep(forTimeInterval: 0.05)
            got = DispatchQueue.main.sync { self.scanFound }
            if !got.isEmpty { break }
            let s1 = engine.stats()
            let now = s1.rs_good &+ s1.rs_corrected, before = s0.rs_good &+ s0.rs_corrected
            // the receiver reacquired by itself (a lock that trained badly): its counters restarted
            if now < before || s1.rs_bad < s0.rs_bad { s0 = s1; since = Date(); continue }
            if Date().timeIntervalSince(since) > 1.2, now == before { break }   // nothing decodes: unusable
        }
        mark("tables")
        if got.isEmpty { return ScanResult(list: [], pilotSNR: pilot, levelLow: levelLow) }
        // settled quality over one second: SNR, and packet loss summed over 0.1 s steps (the
        // receiver's counters restart whenever it reacquires, so only forward steps count)
        var sum = 0.0, good = 0.0, bad = 0.0
        var prev = engine.stats()
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 0.1)
            let st = engine.stats()
            sum += st.state == ATSC_LOCKED ? st.snr_db : 0
            let g1 = st.rs_good &+ st.rs_corrected, g0 = prev.rs_good &+ prev.rs_corrected
            if g1 >= g0, st.rs_bad >= prev.rs_bad { good += Double(g1 - g0); bad += Double(st.rs_bad - prev.rs_bad) }
            else { bad += 1 }                          // it reacquired: count that against it
            prev = st
        }
        let loss = good + bad > 0 ? bad / (good + bad) : 1
        let snr = sum / 6
        if ProcessInfo.processInfo.environment["ATSC_DEBUG"] != nil {
            FileHandle.standardError.write(String(format: "scan RF %d: snr %.1f loss %.3f (good %.0f bad %.0f) gain %d/%d amp %d boosted %d\n",
                rf, snr, loss, good, bad, g.lna, g.vga, g.amp ? 1 : 0, boosted ? 1 : 0).data(using: .utf8)!)
        }
        let tier = !boosted && !g.amp && snr >= 17 && loss < 0.01 ? 1 : snr >= 15 && loss < 0.05 ? 2 : 3
        // the guide only for stations that will be shown (a full one takes ~8-12 s)
        mark("quality")
        // now-and-next only (the first table, ~3 hours, arrives within a few seconds); watching the
        // station, Update Guide and the online sources fill in the rest
        if tier <= 2 { collectGuide(rf: rf, maxWait: 4, quietFor: 1.5) }
        mark("guide")
        let list = got.filter { $0.rf == rf }.map { c -> VirtualChannel in
            var c = c; c.signalDB = snr; c.lna = g.lna; c.vga = g.vga; c.amp = g.amp; c.tier = tier; return c
        }
        return ScanResult(list: list, pilotSNR: pilot, levelLow: levelLow)
    }

    /// The channels found on one RF channel were already found on another: the previous
    /// station's samples decoded just after the retune.
    private func isStaleDecode(_ list: [VirtualChannel], found: [VirtualChannel]) -> Bool {
        guard let rf = list.first?.rf else { return false }
        let ids = Set(list.map(\.id))
        return found.contains { $0.rf != rf && ids.contains($0.id) }
    }

    /// Stay on the RF channel being decoded until its broadcast guide is complete: a mux repeats
    /// every guide section within ~10-20 s, so it is done once nothing new has come for 4 s.
    /// Runs off the main thread. Returns false if no guide arrived at all.
    @discardableResult
    private func collectGuide(rf: Int, maxWait: Double, quietFor: Double = 4, cancelled: () -> Bool = { false }) -> Bool {
        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline, !cancelled() {
            Thread.sleep(forTimeInterval: 0.25)
            let p = engine.guideProgress()
            if p.rf == rf, p.sections > 0, p.quiet >= quietFor { break }
        }
        let p = engine.guideProgress()
        guard p.rf == rf, p.sections > 0 else { return false }
        DispatchQueue.main.async { self.library.markGuideUpdated(rf: rf); self.library.saveGuideIfNeeded(force: true) }
        return true
    }

    /// Visit every station the user watches and read its guide (the user asked for it: this takes
    /// the picture away for a minute or two). Weak stations are left alone. Ends back on the channel
    /// that was playing.
    func refreshGuide() {
        guard !scanning, !guideRefreshing, deviceError == nil else { return }
        let back = current
        var rfs: [Int] = []
        for c in channels where !c.isUnavailable && !rfs.contains(c.rf) { rfs.append(c.rf) }
        // the channel being watched last, so the sweep ends where it started
        if let r = back?.rf, let i = rfs.firstIndex(of: r) { rfs.remove(at: i); rfs.append(r) }
        guard !rfs.isEmpty else { return }
        guideRefreshing = true; guideRefreshProgress = 0; scanCancel = false
        hasPicture = false; liveShown = false; captionRegions = []
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for (i, rf) in rfs.enumerated() {
                guard let self, !self.scanCancel else { break }
                let names: String = DispatchQueue.main.sync {
                    self.guideRefreshProgress = Double(i) / Double(rfs.count)
                    let chs = self.channels.filter { $0.rf == rf }
                    if let c = chs.first {
                        self.engine.tune(rf: rf)
                        self.engine.select(program: -1)                 // tables only, no decoding
                        if let l = c.lna { self.lna = l }
                        if let v = c.vga { self.vga = v }
                        if let a = c.amp, a != self.ampOn { self.ampOn = a }
                    }
                    let n = chs.prefix(3).map(\.name).joined(separator: ", ")
                    self.guideRefreshNote = "Reading the guide from \(n)\(chs.count > 3 ? "…" : "")"
                    return n
                }
                _ = names
                let lockDeadline = Date().addingTimeInterval(5)
                while Date() < lockDeadline, !self.scanCancel, self.engine.stats().state != ATSC_LOCKED {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if self.engine.stats().state == ATSC_LOCKED {
                    self.collectGuide(rf: rf, maxWait: 25, cancelled: { self.scanCancel })
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let done = !self.scanCancel
                self.guideRefreshing = false
                self.guideTick &+= 1
                self.library.saveGuideIfNeeded(force: true)
                if let back { self.current = nil; self.tune(back, showBanner: false) }
                self.flash(done ? "Guide updated" : "Guide update stopped")
            }
        }
    }

    func cancelGuideRefresh() { scanCancel = true }

    private var onlinePending = false

    /// Fetch and match online listings in the background (downloads are cached for 12 hours unless
    /// `force`). Channels without a network setting get one guessed from their name first.
    func refreshOnlineGuide(force: Bool = false) {
        if onlineRefreshing { onlinePending = true; return }
        for ch in library.channels where ch.network == nil {
            if let n = OnlineGuide.guessNetwork(ch) { library.setNetwork(ch.id, n) }
        }
        let chans = library.channels
        var settings = OnlineGuide.Settings(epgTalk: useEPGTalk, tvMaze: useTVMaze, market: guideMarket, imports: xmltvImports)
        if !sdUser.isEmpty, let h = SchedulesDirect.loadHash(user: sdUser) { settings.sdUser = sdUser; settings.sdHash = h; settings.sdLineup = sdLineup }
        // the stations' own listings, by network: tells which online markets share our clock
        var reference: [String: [(start: Date, title: String)]] = [:]
        for ch in chans { if let n = ch.network {
            reference[n, default: []] += library.events(ch.guideKey, from: Date().addingTimeInterval(-6 * 3600), to: Date().addingTimeInterval(3 * 86400))
                .filter { $0.rank == 0 }.map { ($0.start, $0.title) }
        } }
        onlineRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var batches: [(String, [GuideEvent])] = []
            let report = OnlineGuide.refresh(channels: chans, settings: settings, reference: reference, force: force) { key, events in batches.append((key, events)) }
            DispatchQueue.main.async {
                guard let self else { return }
                for (key, events) in batches { self.library.addExternal(events, key: key) }
                self.library.saveGuideIfNeeded(force: true)
                self.guideTick &+= 1
                self.onlineReport = report
                self.onlineUpdatedAt = Date()
                self.onlineRefreshing = false
                if self.onlinePending { self.onlinePending = false; self.refreshOnlineGuide() }
            }
        }
    }

    // MARK: Schedules Direct

    /// Check the account and keep the credentials (password only as its SHA-1, in the Keychain).
    func sdSignIn(user: String, password: String) {
        let u = user.trimmingCharacters(in: .whitespaces), hash = SchedulesDirect.passwordHash(password)
        sdBusy = true; sdStatus = "Signing in…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let tok = try SchedulesDirect.token(user: u, hash: hash)
                let st = try SchedulesDirect.status(token: tok)
                SchedulesDirect.storeHash(hash, user: u)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.sdUser = u; self.defaults.set(u, forKey: "sdUser")
                    self.sdLineups = st.lineups
                    if self.sdLineup.isEmpty, let first = st.lineups.first { self.sdLineup = first.id }
                    self.sdStatus = "Signed in" + (st.expires.isEmpty ? "" : "; subscription until \(st.expires)")
                    self.sdBusy = false
                    self.refreshOnlineGuide(force: true)
                }
            } catch {
                DispatchQueue.main.async { self?.sdStatus = error.localizedDescription; self?.sdBusy = false }
            }
        }
    }

    /// Antenna lineups for a ZIP code (to add one to the account).
    func sdFindLineups(zip: String) {
        guard let hash = SchedulesDirect.loadHash(user: sdUser) else { return }
        let u = sdUser
        sdBusy = true; sdStatus = "Looking up antenna lineups…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let tok = try SchedulesDirect.token(user: u, hash: hash)
                let found = try SchedulesDirect.antennaLineups(token: tok, zip: zip)
                let mine = try SchedulesDirect.status(token: tok).lineups
                DispatchQueue.main.async {
                    self?.sdLineups = Array(Set(mine + found)).sorted { $0.id < $1.id }
                    self?.sdStatus = found.isEmpty ? "No antenna lineups for \(zip)" : "\(found.count) antenna lineup\(found.count == 1 ? "" : "s") found"
                    self?.sdBusy = false
                }
            } catch { DispatchQueue.main.async { self?.sdStatus = error.localizedDescription; self?.sdBusy = false } }
        }
    }

    /// Use a lineup, adding it to the account if needed (Schedules Direct allows six changes a day).
    func sdUse(_ lineup: SchedulesDirect.Lineup) {
        guard let hash = SchedulesDirect.loadHash(user: sdUser) else { return }
        let u = sdUser
        sdBusy = true; sdStatus = "Adding \(lineup.name)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let tok = try SchedulesDirect.token(user: u, hash: hash)
                if !(try SchedulesDirect.status(token: tok).lineups.contains { $0.id == lineup.id }) {
                    try SchedulesDirect.addLineup(token: tok, id: lineup.id)
                }
                DispatchQueue.main.async {
                    self?.sdLineup = lineup.id; self?.sdStatus = "Using \(lineup.name)"; self?.sdBusy = false
                    self?.refreshOnlineGuide(force: true)
                }
            } catch { DispatchQueue.main.async { self?.sdStatus = error.localizedDescription; self?.sdBusy = false } }
        }
    }

    func sdSignOut() {
        SchedulesDirect.forget(user: sdUser)
        sdUser = ""; defaults.removeObject(forKey: "sdUser")
        sdLineup = ""; sdLineups = []; sdStatus = ""
    }

    func setNetwork(_ ch: VirtualChannel, _ network: String?) {
        library.setNetwork(ch.id, network)
        channels = library.visibleChannels
        refreshOnlineGuide()
    }

    private var guideNotedAt: Date?

    /// While a channel plays, its station's whole guide streams in too; note when it is complete.
    private func noteGuideWhileWatching() {
        guard let cur = current, guideNotedAt != tunedAt else { return }
        let t = tunedAt
        let p = engine.guideProgress()
        if p.rf == cur.rf, p.sections > 0, p.quiet >= 4 {
            guideNotedAt = t
            library.markGuideUpdated(rf: cur.rf)
            library.saveGuideIfNeeded(force: true)
        }
    }

    private var qualitySum = 0.0, qualityN = 0, qualityFor: Date?
    private var viewRecordedFor: Date?

    /// Average the quality while a channel plays (from 3 s after tuning, outside any rescue) and
    /// keep it for the channel list, so its bars reflect how the station really comes in.
    private func noteQualityWhileWatching(_ s: atsc_stats) {
        guard let cur = current, rescue == nil, Date().timeIntervalSince(tunedAt) > 3 else { return }
        if qualityFor != tunedAt { qualityFor = tunedAt; qualitySum = 0; qualityN = 0 }
        qualitySum += s.state == ATSC_LOCKED ? s.snr_db : 0; qualityN += 1
        if qualityN % 20 == 0 { library.setQuality(rf: cur.rf, snr: qualitySum / Double(qualityN)); channels = library.visibleChannels }
        // 20 s of clean viewing counts as a reception result (once per tune)
        if viewRecordedFor != tunedAt, Date().timeIntervalSince(tunedAt) > 20, hasPicture, lossRate < 0.01 {
            viewRecordedFor = tunedAt
            let avg = qualitySum / Double(max(qualityN, 1))
            library.record(rf: cur.rf, avg >= 17 && !ampOn ? 1 : 2)
            channels = library.visibleChannels
            current = channels.first { $0.id == cur.id } ?? cur
        }
    }

    /// Stations whose guide is missing or runs out within six hours (and so are worth refreshing).
    var staleGuideRFs: [Int] {
        let soon = Date().addingTimeInterval(6 * 3600)
        var rfs: [Int] = []
        for c in channels where !c.isUnavailable && !rfs.contains(c.rf) {
            // a station read in the last six hours is as current as it can be, even if it sent little
            if let t = library.guideUpdated[c.rf], Date().timeIntervalSince(t) < 6 * 3600 { continue }
            if (library.guideEnd(rf: c.rf) ?? .distantPast) < soon { rfs.append(c.rf) }
        }
        return rfs
    }

    func scan() {
        guard !scanning, !guideRefreshing, deviceError == nil else { return }
        scanning = true; scanProgress = 0; scanCancel = false; scanFinished = false; scanResults = []
        guideVisible = false; bannerVisible = false
        hasPicture = false
        var rfs = RFBand.channels
        if let only = ProcessInfo.processInfo.environment["ATSC_SCANRFS"] {   // debugging: scan only these
            rfs = only.split(separator: ",").compactMap { Int($0) }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [VirtualChannel] = []
            var weak: [Int] = []
            func publish() {
                DispatchQueue.main.sync {
                    self?.scanResults = found.filter { !$0.hidden }.sorted { ($0.major, $0.minor) < ($1.major, $1.minor) }
                }
            }
            // pass 1: every RF channel, gain set for that channel
            for (i, rf) in rfs.enumerated() {
                guard let self, !self.scanCancel else { break }
                DispatchQueue.main.sync { self.scanProgress = 0.8 * Double(i) / Double(rfs.count); self.scanPhase = "" }
                let r = self.scanOne(rf: rf, lockWait: 1.0, tableWait: 2.0, target: -18, allowAmp: false)
                // more gain or the amplifier only help a signal that arrives too low to set the level;
                // at a healthy level, poor quality is noise in the signal itself and a retry is wasted
                if r.list.isEmpty {
                    if r.pilotSNR > 28, r.levelLow { weak.append(rf) }
                } else if !self.isStaleDecode(r.list, found: found) {
                    found.append(contentsOf: r.list); publish()
                    if r.list.first?.tier == 3, r.levelLow { weak.append(rf) }
                }
            }
            // pass 2: weak candidates get more gain, the RF amp if still low, and longer to lock
            for (i, rf) in weak.enumerated() {
                guard let self, !self.scanCancel else { break }
                DispatchQueue.main.sync {
                    self.scanProgress = 0.8 + 0.2 * Double(i) / Double(max(weak.count, 1))
                    self.scanPhase = "Retrying weak signals"
                }
                var r = self.scanOne(rf: rf, lockWait: 1.5, tableWait: 2, target: -12, allowAmp: false, boosted: true)
                if (r.list.first?.tier ?? 3) == 3, !self.scanCancel {
                    let amp = self.scanOne(rf: rf, lockWait: 1.5, tableWait: 2, target: -12, allowAmp: true, boosted: true)
                    if !amp.list.isEmpty, (amp.list.first?.tier ?? 3) <= (r.list.first?.tier ?? 3) { r = amp }
                }
                if !r.list.isEmpty, !self.isStaleDecode(r.list, found: found) {
                    // a boosted result replaces a poorer one from the first pass
                    if (r.list.first?.tier ?? 3) <= (found.first { $0.rf == rf }?.tier ?? 3) {
                        found.removeAll { $0.rf == rf }
                        found.append(contentsOf: r.list); publish()
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let completed = !self.scanCancel
                self.engine.device?.setAmp(self.ampOn); self.engine.device?.setLNA(self.lna); self.engine.device?.setVGA(self.vga)
                self.scanning = false
                self.scanProgress = 1
                self.scanFinished = true
                self.scanPhase = ""
                if completed || !found.isEmpty {
                    // merge: found stations are updated, missed ones stay listed as weak
                    self.library.applyScan(found)
                    self.channels = self.library.visibleChannels
                }
                self.library.save()
                if !found.isEmpty { self.defaults.set(true, forKey: "initialScanDone") }
                self.refreshOnlineGuide()
                if !self.setupVisible, let first = self.lastWatched() ?? self.channels.first { self.current = nil; self.tune(first) }
            }
        }
    }

    func cancelScan() { scanCancel = true }

    // MARK: OSD

    func showInfo(seconds: Double = 4) {
        bannerVisible = true
        bannerTimer?.cancel()
        let t = DispatchWorkItem { [weak self] in withAnimation(.easeOut(duration: 0.4)) { self?.bannerVisible = false } }
        bannerTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: t)
    }

    func toggleInfo() { if bannerVisible { bannerTimer?.cancel(); bannerVisible = false } else { showInfo(seconds: 8) } }

    func changeVolume(_ d: Double) {
        volume = min(1, max(0, volume + d)); muted = false
        pokeVolume()
    }

    func toggleMute() { muted.toggle(); pokeVolume() }

    private func pokeVolume() {
        volumeVisible = true
        volumeTimer?.cancel()
        let t = DispatchWorkItem { [weak self] in withAnimation(.easeOut(duration: 0.4)) { self?.volumeVisible = false } }
        volumeTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: t)
    }

    /// Mouse activity: show the control bar and window buttons, hide them again when idle.
    func mouseMoved() {
        if !controlsVisible { withAnimation(.easeIn(duration: 0.15)) { controlsVisible = true } }
        setWindowButtons(visible: true)
        controlsTimer?.cancel()
        let t = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.5)) { self?.controlsVisible = false }
            self?.setWindowButtons(visible: false)
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        controlsTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: t)
    }

    /// TV-style window: black behind the picture, resizing locked to 16:9.
    func configureWindow() {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }) else { return }
        w.backgroundColor = .black
        w.contentAspectRatio = NSSize(width: 16, height: 9)
        w.isMovableByWindowBackground = true
    }

    func setWindowButtons(visible: Bool) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            w.standardWindowButton(b)?.animator().alphaValue = visible ? 1 : 0
        }
    }

    func flash(_ text: String, seconds: Double = 3) {
        status = text
        statusTimer?.cancel()
        let t = DispatchWorkItem { [weak self] in withAnimation { self?.status = nil } }
        statusTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: t)
    }

    // MARK: recording

    static var recordingsFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SDR TV", isDirectory: true)
    }

    func toggleRecording() {
        if recordingSince != nil {
            engine.stopRecording(); recordingSince = nil
            updateAwake()
            flash("Recording saved to Movies/SDR TV")
            return
        }
        guard let ch = current, hasPicture else { flash("Nothing to record yet"); return }
        do {
            try FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let title = library.now(ch.guideKey).0?.title ?? ch.name
            let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let url = Self.recordingsFolder.appendingPathComponent("\(ch.number) \(ch.name) - \(safe) - \(f.string(from: Date())).ts")
            try engine.startRecording(to: url)
            recordingSince = Date()
            updateAwake()
        } catch {
            flash("Could not record: \(error.localizedDescription)")
        }
    }

    // MARK: scheduled recordings

    /// Schedule (or, if already scheduled, cancel) recording a guide program.
    func toggleScheduledRecording(_ ch: VirtualChannel, _ e: GuideEvent) {
        if let existing = schedule.scheduled(channelID: ch.id, start: e.start) {
            cancelRecording(existing)
            return
        }
        guard e.end > Date() else { flash("That program has ended"); return }
        let r = ScheduledRecording(channelID: ch.id, channelName: ch.name, rf: ch.rf, program: ch.program,
                                   title: e.title, start: e.start, end: e.end)
        schedule.add(r)
        scheduleTick &+= 1
        let clash = schedule.conflicts(with: r)
        if let c = clash.first {
            flash("Scheduled \"\(e.title)\", but it overlaps \"\(c.title)\" on another station. One tuner receives one station at a time: the one that starts first is recorded.", seconds: 8)
        } else {
            flash("Will record \"\(e.title)\" on \(ch.number) at \(e.start.formatted(date: .omitted, time: .shortened))")
        }
        superviseSchedule()
    }

    /// Record the program on now, to its end (falls back to manual recording without a guide entry).
    func recordThisProgram() {
        guard let ch = current else { return }
        if let e = library.now(ch.guideKey).0 { toggleScheduledRecording(ch, e) } else { toggleRecording() }
    }

    func cancelRecording(_ r: ScheduledRecording) {
        if r.state == .recording { finishRecording(r, note: "Stopped early") }
        else { schedule.remove(r.id); scheduleTick &+= 1; flash("Recording of \"\(r.title)\" cancelled") }
    }

    func deleteScheduleEntry(_ r: ScheduledRecording) {
        if r.state == .recording { finishRecording(r, note: "Stopped early") }
        schedule.remove(r.id); scheduleTick &+= 1
    }

    private func finishRecording(_ r0: ScheduledRecording, note: String? = nil) {
        var r = r0
        engine.stopRecorder(id: r.id.uuidString)
        r.state = .done; r.note = note
        schedule.update(r)
        activeRecordings.removeAll { $0.id == r.id }
        scheduleTick &+= 1
        updateAwake()
        flash("Recording of \"\(r.title)\" saved to Movies/SDR TV")
    }

    /// Start and stop scheduled recordings on time (called every couple of seconds).
    private func superviseSchedule() {
        let now = Date()
        for var r in schedule.items where r.state == .scheduled {
            if now > r.recordUntil { r.state = .missed; r.note = r.note ?? "Could not start in time"; schedule.update(r); scheduleTick &+= 1; continue }
            let needsTune = engine.currentRF != r.rf || current == nil
            // a minute's warning before taking over the tuner
            if needsTune, now >= r.recordFrom.addingTimeInterval(-60), !warnedRecordings.contains(r.id) {
                warnedRecordings.insert(r.id)
                flash("Recording \"\(r.title)\" on \(r.channelID) starts in a minute; SDR TV will tune to it.", seconds: 8)
            }
            guard now >= r.recordFrom.addingTimeInterval(-8) else { continue }
            if needsTune {
                if let other = activeRecordings.first(where: { $0.rf != r.rf }) {
                    r.state = .failed; r.note = "Overlapped \"\(other.title)\" on another station"; schedule.update(r); scheduleTick &+= 1
                    continue
                }
                let ch = library.channels.first { $0.id == r.channelID }
                    ?? VirtualChannel(rf: r.rf, major: 0, minor: 0, name: r.channelName, program: r.program, sourceID: 0)
                tune(ch, forRecording: true)
                continue                                    // start once the station's program map is in
            }
            guard now >= r.recordFrom else { continue }
            do {
                try FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm"
                let safe = r.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                let url = Self.recordingsFolder.appendingPathComponent("\(r.channelID) \(r.channelName) - \(safe) - \(f.string(from: r.start)).ts")
                if try engine.startRecording(id: r.id.uuidString, program: r.program, to: url) {
                    r.state = .recording; r.file = url.path
                    schedule.update(r); activeRecordings.append(r); scheduleTick &+= 1
                    updateAwake()
                    flash("Recording \"\(r.title)\"")
                }
            } catch {
                r.state = .failed; r.note = error.localizedDescription; schedule.update(r); scheduleTick &+= 1
            }
        }
        for r in activeRecordings where now >= r.recordUntil { finishRecording(r) }
        updateAwake()
    }

    /// Keep the Mac from sleeping while recording, or about to.
    private func updateAwake() {
        let soon = Date().addingTimeInterval(180)
        let need = !activeRecordings.isEmpty || recordingSince != nil
            || schedule.items.contains { $0.state == .scheduled && $0.recordFrom < soon && $0.recordUntil > Date() }
        if need, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled], reason: "Recording TV")
        } else if !need, let a = awake {
            ProcessInfo.processInfo.endActivity(a); awake = nil
        }
    }

    func revealRecordings() {
        try? FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.recordingsFolder)
    }

    // MARK: captions and audio tracks

    static func languageName(_ code: String) -> String {
        guard !code.isEmpty else { return "Unknown language" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    static func roleName(_ role: Int) -> String? {
        switch role {
        case 1: return "Music and effects"
        case 2: return "Audio description"
        case 3: return "Hearing impaired"
        case 4: return "Dialogue"
        case 5: return "Commentary"
        case 6: return "Emergency"
        default: return nil
        }
    }

    func label(for t: Engine.AudioTrack) -> String {
        var s = Self.languageName(t.lang)
        if let r = Self.roleName(t.role) { s += " (\(r))" }
        if t.channels >= 6 { s += " 5.1" }
        return s
    }

    private func programInfo(_ info: Engine.ProgramInfo) {
        audioTracks = info.audio
        // caption choices: what the broadcaster announces, plus the standard defaults
        var list: [CaptionChoice] = []
        for c in info.captions {
            let svc = c.digital ? 100 + c.number : (c.number == 1 ? 1 : 3)
            if list.contains(where: { $0.service == svc }) { continue }
            let name = Self.languageName(c.lang) + (c.easyReader ? " (easy reader)" : "")
            list.append(CaptionChoice(service: svc, lang: c.lang, label: c.digital ? name : "\(name) (CC\(svc))"))
        }
        if !list.contains(where: { $0.service == 101 }) { list.append(CaptionChoice(service: 101, lang: "eng", label: "Service 1 (digital)")) }
        if !list.contains(where: { $0.service == 1 }) { list.append(CaptionChoice(service: 1, lang: "eng", label: "CC1")) }
        if !list.contains(where: { $0.service == 3 }) { list.append(CaptionChoice(service: 3, lang: "", label: "CC3")) }
        captionChoices = list
        // first time we see this channel's tracks: pick the preferred language / description
        if let ch = current, tracksChosenFor != ch.id, !info.audio.isEmpty {
            tracksChosenFor = ch.id
            let byLang = info.audio.indices.filter { info.audio[$0].lang == audioLanguage }
            let desc = byLang.first { info.audio[$0].role == 2 }
            let main = byLang.first { info.audio[$0].role != 2 }
            let pick = (preferDescription ? desc ?? main : main ?? desc) ?? 0
            if pick != audioIndex { selectAudio(pick, announce: false) }
            applyCaptionChoice()
        }
    }

    func selectAudio(_ i: Int, announce: Bool = true) {
        guard audioTracks.indices.contains(i) || audioTracks.isEmpty else { return }
        audioIndex = i
        engine.select(audio: i)
        if announce, audioTracks.indices.contains(i) { flash("Audio: \(label(for: audioTracks[i]))", seconds: 2.5) }
    }

    func cycleAudio() {
        guard audioTracks.count > 1 else { flash(audioTracks.isEmpty ? "No audio tracks" : "Only one audio track", seconds: 2); return }
        let i = (audioIndex + 1) % audioTracks.count
        audioLanguage = audioTracks[i].lang
        selectAudio(i)
    }

    /// The caption service to decode, from the on/off setting and the preferred language.
    private func preferredCaptionService() -> Int {
        guard captionsOn else { return 0 }
        if let c = captionChoices.first(where: { $0.lang == captionLanguage && $0.service > 100 }) { return c.service }
        if let c = captionChoices.first(where: { $0.lang == captionLanguage }) { return c.service }
        return captionLanguage == "spa" ? 3 : 101
    }

    private func applyCaptionChoice() {
        let svc = preferredCaptionService()
        if svc != captionService {
            captionService = svc
            engine.select(captions: svc)
            if svc == 0 { captionRegions = [] }
        }
    }

    func selectCaptions(_ c: CaptionChoice?) {
        if let c {
            captionLanguage = c.lang.isEmpty ? captionLanguage : c.lang
            captionsOn = true
            if captionService != c.service { captionService = c.service; engine.select(captions: c.service) }
            flash("Captions: \(c.label)", seconds: 2.5)
        } else {
            captionsOn = false
            flash("Captions off", seconds: 2)
        }
    }

    /// C key: off -> each available service -> off.
    func cycleCaptions() {
        let list = captionChoices.isEmpty ? [CaptionChoice(service: 101, lang: "eng", label: "Service 1 (digital)")] : captionChoices
        if !captionsOn { selectCaptions(list[0]); return }
        if let i = list.firstIndex(where: { $0.service == captionService }), i + 1 < list.count { selectCaptions(list[i + 1]) }
        else { selectCaptions(nil) }
    }

    var captionLabel: String {
        captionChoices.first { $0.service == captionService }?.label ?? (captionService == 0 ? "Off" : "On")
    }

    private var ccCount = 0, ccText = 0
    private func showCaptions(_ json: String) {
        if ProcessInfo.processInfo.environment["ATSC_DEBUG"] != nil {
            ccCount += 1; if json.contains("\"lines\"") { ccText += 1 }
            if ccCount % 20 == 1 { FileHandle.standardError.write("captions: \(ccCount) screens, \(ccText) with text, service \(captionService): \(json.prefix(120))\n".data(using: .utf8)!) }
        }
        guard captionService != 0, let d = json.data(using: .utf8),
              let screen = try? JSONDecoder().decode(CaptionScreen.self, from: d) else {
            if captionService == 0 { captionRegions = [] }
            return
        }
        captionRegions = screen.regions
    }

    // MARK: housekeeping

    private func tick() {
        let s = engine.stats()
        stats = s
        let m = engine.mediaStatus()
        media = m
        // picture present = new video frames are being decoded
        if m.video_frames != lastVideoFrames { lastVideoFrames = m.video_frames; lastFrameAt = Date() }
        // after a dropout the last good frame is held until a clean keyframe (up to ~3 s): keep it up
        let picture = lastFrameAt.map { Date().timeIntervalSince($0) < 3.5 } ?? false
        hasPicture = s.state == ATSC_LOCKED && picture && !format.isEmpty
        if hasPicture, still != nil { still = nil }
        engine.player.keepPlaying()
        if liveShown, !hasPicture, (lastFrameAt.map { Date().timeIntervalSince($0) > 3.5 } ?? (secondsSinceTune > 4)) { liveShown = false }
        // refresh the last-seen picture every 10 s of clean viewing
        snapshotTicks += 1
        if hasPicture, lossRate < 0.01, snapshotTicks % 20 == 0 { captureStill() }
        if s.state == ATSC_LOCKED { if lockedAt == nil { lockedAt = Date() } } else if !scanning { lockedAt = nil }
        // packet loss over the last ~2 s
        rsHist.append((s.rs_good + s.rs_corrected, s.rs_bad))
        if rsHist.count > 5 { rsHist.removeFirst() }
        if let f = rsHist.first, let l = rsHist.last {
            let good = Double(l.good &- f.good), bad = Double(l.bad &- f.bad)
            lossRate = good + bad > 0 ? bad / (good + bad) : (s.state == ATSC_LOCKED ? 0 : 1)
        }
        if rsHist.count >= 2 {
            let a = rsHist[rsHist.count - 2], b = rsHist[rsHist.count - 1]
            let good = Double(b.good &- a.good), bad = Double(b.bad &- a.bad)
            recentLoss = good + bad > 0 ? bad / (good + bad) : 1
        } else { recentLoss = 1 }
        weakSignal = hasPicture && (lossRate > 0.02 || (s.snr_db > 0 && s.snr_db < 15.5))

        if let dev = engine.device, !dev.isStreaming {
            engine.closeDevice(); deviceError = "HackRF disconnected"
        }
        if deviceError != nil {
            retryTicks += 1
            if retryTicks % 4 == 0 { openDevice() }
            return
        }
        if ProcessInfo.processInfo.environment["ATSC_DEBUG"] != nil { debugLog(s, m) }
        if ProcessInfo.processInfo.environment["ATSC_GAINTEST"] != nil {   // stress test: 2 dB gain jolts
            gainTestTicks += 1
            if gainTestTicks % 10 == 0 { vga = vga == 20 ? 22 : 20 }
        }
        if !scanning, !guideRefreshing, snapshotTicks % 4 == 0 { superviseSchedule() }
        if scanning || rechecking || guideRefreshing { return }
        noteGuideWhileWatching()
        noteQualityWhileWatching(s)
        superviseReception(s, m)
        // Automatic gain. Every gain change is a small jolt to the demodulator, so it stays still
        // while reception is clean and only acts when the level is far off, or data is being lost.
        if autoGain, rescue == nil, s.dbfs > -60 {
            let clean = hasPicture && lossRate < 0.01
            let high = clean ? -8.0 : -12.0, low = clean ? -32.0 : -24.0
            if s.dbfs > high { if vga >= 2 { vga -= 2 } else if lna >= 8 { lna -= 8 } }
            else if s.dbfs < low { if vga <= 60 { vga += 2 } else if lna <= 32 { lna += 8 } }
        }
        if ampOn && s.dbfs > -6 {
            ampOn = false
            flash("Signal very strong: RF amplifier switched off")
        }
    }

    private var dbgPrev: (Date, UInt64, UInt64)?
    private var gainTestTicks = 0
    private func debugLog(_ s: atsc_stats, _ m: atsc_media_status) {
        let now = Date()
        var vfps = 0.0, afps = 0.0
        if let p = dbgPrev { let dt = now.timeIntervalSince(p.0); vfps = Double(m.video_frames &- p.1) / dt; afps = Double(m.audio_frames &- p.2) / dt }
        dbgPrev = (now, m.video_frames, m.audio_frames)
        FileHandle.standardError.write(String(format: "t=%.1f fields=%llu clock=%+.2fppm pilot=%.0fdB ", now.timeIntervalSince(tunedAt), s.fields, s.clock_ppm, s.pilot_snr_db).data(using: .utf8)!)
        FileHandle.standardError.write(String(format: "state=%d snr=%.1f dbfs=%.1f lna=%d vga=%d amp=%d loss=%.1f%% video=%.1ffps audio=%.1ffr/s overruns=%d rescue=%@ dropped=%llu relocks=%llu enhanced=%d slow=%d\n",
            s.state.rawValue, s.snr_db, s.dbfs, lna, vga, ampOn ? 1 : 0, lossRate * 100, vfps, afps, engine.overruns,
            rescueNote ?? "-", m.dropped_packets, s.relocks, engine.player.enhancer.enhanced, engine.player.enhancer.slow).data(using: .utf8)!)
    }

    /// Is the current channel failing because of the signal (as opposed to, say, a codec)?
    /// Packet loss over the last half second only (decisions after a tune cannot wait for ~2 s of history).
    private var recentLoss = 1.0

    /// The demodulator is delivering clean data (the picture follows within a GOP, ~1 s).
    private func receptionGood(_ s: atsc_stats) -> Bool {
        s.state == ATSC_LOCKED && s.snr_db >= 15 && recentLoss < 0.05
    }

    private func signalProblem(_ s: atsc_stats) -> Bool {
        s.state != ATSC_LOCKED || s.snr_db < 15.5 || lossRate > 0.2
    }

    /// Starts and steps the rescue ladder for the current channel when reception fails.
    private func superviseReception(_ s: atsc_stats, _ m: atsc_media_status) {
        guard let ch = current, !setupVisible else { return }
        if ch.isUnavailable, hasPicture, lossRate < 0.05 {       // a weak channel that works now
            library.restore(rf: ch.rf)
            channels = library.visibleChannels
            current = channels.first { $0.id == ch.id } ?? ch
        }
        if var r = rescue {
            if r.settling { return }
            r.bestSNR = max(r.bestSNR, s.state == ATSC_LOCKED ? s.snr_db : 0)
            if receptionGood(s) {
                // this setting works: keep it for the RF channel
                library.setGains(rf: r.rf, lna: lna, vga: vga, amp: ampOn)
                library.restore(rf: r.rf)
                // it took more than resetting the gain: extra gain or the amplifier, so bucket 2
                if r.step >= 1 { library.record(rf: r.rf, 2); viewRecordedFor = tunedAt }
                channels = library.visibleChannels
                flash("Reception recovered (\(Rescue.ladder[r.step].note.lowercased()))")
                rescue = nil; rescueNote = nil
                return
            }
            // lock takes ~0.1 s and a clean field or two shows in the error rate; the amplifier
            // steps get a little longer for the front end to settle after switching
            let dwell = Rescue.ladder[r.step].amp ? 2.0 : 1.5
            if Date().timeIntervalSince(r.stepStarted) < dwell { rescue = r; return }
            r.step += 1
            // more LNA/VGA gain only helps a signal that arrives low; with the level already near
            // the target the noise is in the signal itself, and only the RF amplifier can help
            while r.step < Rescue.ladder.count, !Rescue.ladder[r.step].amp, s.dbfs > -22 { r.step += 1 }
            if r.step >= Rescue.ladder.count {
                giveUp(ch, bestSNR: r.bestSNR)
                return
            }
            applyRescueStep(&r)
            rescue = r
            return
        }
        let sinceTune = Date().timeIntervalSince(tunedAt)
        // working reception on a station with no saved receiver settings: remember these
        if ch.lna == nil, sinceTune > 3, hasPicture, lossRate < 0.01 {
            library.setGains(rf: ch.rf, lna: lna, vga: vga, amp: ampOn)
            channels = library.visibleChannels
            current = channels.first { $0.id == ch.id } ?? ch
        }
        // Start a rescue as soon as the demodulator shows it is not getting there: 2 s after a tune
        // without clean data (the receiver has reacquired by itself a few times by then), or once
        // the picture has been gone for 3 s.
        let notComingUp = lastFrameAt == nil && sinceTune > 2 && !receptionGood(s)
        let lostPicture = lastFrameAt.map { Date().timeIntervalSince($0) > 4 } ?? false
        guard notComingUp || (lostPicture && signalProblem(s)) else { return }
        // step 1 measures and sets the gain from scratch (a bad saved gain must not doom the rest)
        var r = Rescue(rf: ch.rf, base: (lna, vga))
        r.settling = true
        rescue = r
        rescueNote = "\(Rescue.ladder[0].note) (step 1 of \(Rescue.ladder.count))"
        let rf = ch.rf
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let g = self.settleGain(target: -18, allowAmp: false)
            DispatchQueue.main.async {
                guard var r = self.rescue, r.rf == rf else { return }
                r.base = (g.lna, g.vga); r.settling = false
                self.applyRescueStep(&r)
                self.rescue = r
            }
        }
    }

    private func applyRescueStep(_ r: inout Rescue) {
        let st = Rescue.ladder[r.step]
        lna = min(40, max(0, r.base.lna + st.dLNA))
        vga = min(62, max(0, r.base.vga + st.dVGA))
        if ampOn != st.amp { ampOn = st.amp }
        r.stepStarted = Date()
        rescueNote = "\(st.note) (step \(r.step + 1) of \(Rescue.ladder.count))"
        engine.retune()
    }

    /// Nothing worked: take the RF channel's channels out of the list and go back.
    private func giveUp(_ ch: VirtualChannel, bestSNR: Double) {
        rescue = nil; rescueNote = nil
        if ampOn { ampOn = false }
        let bucket = library.record(rf: ch.rf, 3)     // poor twice in three tries: unchecked
        library.markUnavailable(rf: ch.rf, bestSNR: bestSNR)   // skipped by channel up/down until it works
        let kept = library.channels.first { $0.id == ch.id }?.userKept == true || bucket != 3
        channels = library.visibleChannels
        let why = bestSNR > 0 ? String(format: "best signal quality %.1f dB, about 15 dB is needed", bestSNR)
                              : "no usable signal"
        if kept {
            let note = bucket != 3 ? "It usually comes in, so it stays listed; if this keeps happening it will be moved to Poor and hidden. "
                                   : "You chose to keep it listed. "
            flash("\(ch.number) \(ch.name) is too weak to receive right now (\(why)). " + note
                  + "Choose it again to retry; channel up/down will skip it until then.", seconds: 10)
        } else {
            let n = library.channels.filter { $0.rf == ch.rf }.count
            flash("\(ch.number) \(ch.name) has poor reception (\(why)), so \(n == 1 ? "it was" : "all \(n) channels from this station were") "
                  + "moved to Poor and unchecked. Check \(n == 1 ? "it" : "them") in Settings > Channels to show \(n == 1 ? "it" : "them") again.", seconds: 10)
        }
        if let back = previous.flatMap({ p in channels.first { $0.id == p.id } }) ?? channels.first {
            current = nil; tune(back)
        } else {
            current = nil
        }
    }

    /// What the tuning screen shows: one line per stage of reception.
    struct Stage: Identifiable {
        enum State { case ok, working, warning, failed, pending }
        let id: Int
        let title: String
        let detail: String
        let state: State
    }

    var diagnosis: (stages: [Stage], hint: String?) {
        let s = stats, m = media
        let rf = current?.rf ?? engine.currentRF
        let since = Date().timeIntervalSince(tunedAt)
        var st: [Stage] = []
        var hint: String?
        func add(_ t: String, _ d: String, _ state: Stage.State) { st.append(Stage(id: st.count, title: t, detail: d, state: state)) }

        // 1. the station's carrier
        let level = String(format: "%.0f dBFS", s.dbfs)
        if s.state == ATSC_ACQ_PILOT { add("Signal", "Listening on RF \(rf) (\(Int(RFBand.centerMHz(rf))) MHz), level \(level)", .working) }
        else if s.pilot_snr_db < 20 {
            add("Signal", "No ATSC signal found on RF \(rf) (level \(level))", since > 2 ? .failed : .working)
            if since > 2 { hint = "The station's carrier is not being received. It may be off the air, or the antenna needs a better position." }
        } else { add("Signal", String(format: "Station carrier found (%.0f dB above noise), level %@", s.pilot_snr_db, level), .ok) }

        // 2. synchronisation
        if s.state == ATSC_LOCKED { add("Sync", "Locked", .ok) }
        else if s.state == ATSC_ACQ_PILOT { add("Sync", "Waiting", .pending) }
        else { add("Sync", "Synchronising", since > 3 ? .failed : .working) }

        // 3. signal quality
        if s.state == ATSC_LOCKED {
            let snr = String(format: "%.1f dB", s.snr_db)
            let loss = lossRate > 0.001 ? String(format: ", %.0f%% of data lost", lossRate * 100) : ""
            if s.snr_db >= 17.5 && lossRate < 0.02 { add("Quality", "SNR \(snr)\(loss)", .ok) }
            else if s.snr_db >= 15 && lossRate < 0.2 { add("Quality", "SNR \(snr), weak\(loss)", .warning) }
            else {
                add("Quality", "SNR \(snr), about 15 dB is needed\(loss)", since > 3 ? .failed : .working)
                hint = hint ?? "The signal is too weak or noisy to decode. Moving the antenna (higher, near a window) usually helps."
            }
        } else { add("Quality", "–", .pending) }

        // 4. program tables
        if m.program_mapped != 0 { add("Program", "Found in the broadcast", .ok) }
        else if m.tables_seen != 0 && m.program_listed == 0 {
            add("Program", "Channel \(current?.number ?? "") is not in this broadcast any more", .failed)
            hint = hint ?? "The station has changed its line-up. Rescan to update the channel list."
        } else { add("Program", s.state == ATSC_LOCKED ? "Reading channel information" : "–", s.state == ATSC_LOCKED ? .working : .pending) }

        // 5. video and audio
        if m.program_mapped != 0 {
            let vName = m.video_type != 0 ? String(cString: atsc_stream_type_name(m.video_type)) : "none"
            if m.video_type != 0 && m.video_supported == 0 {
                add("Video", "\(vName) is not supported", .failed)
                hint = hint ?? "This channel uses a video format the app cannot decode."
            } else if m.video_type == 0 {
                add("Video", "No video (audio-only or data service)", .warning)
            } else if m.video_frames > 0 { add("Video", "\(vName) \(format)", .ok) }
            else { add("Video", "\(vName): waiting for the first picture", .working) }
            let aName = m.audio_type != 0 ? String(cString: atsc_stream_type_name(m.audio_type)) : "none"
            if m.audio_type != 0 && m.audio_supported == 0 { add("Audio", "\(aName) is not supported", .warning) }
            else if m.audio_frames > 0 { add("Audio", "\(aName) \(audioLayout)", .ok) }
            else { add("Audio", m.audio_type == 0 ? "No audio" : "\(aName)", m.audio_type == 0 ? .warning : .working) }
        } else {
            add("Video", "–", .pending); add("Audio", "–", .pending)
        }
        return (st, hint)
    }

    /// Signal quality 0...4 bars from the equalizer SNR (15 dB is about the decoding threshold).
    var bars: Int { SignalQuality.bars(snr: stats.snr_db, loss: lossRate, locked: stats.state == ATSC_LOCKED) }


    func shutdown() {
        if recordingSince != nil { engine.stopRecording() }
        library.save()
        engine.closeDevice()
    }
}
