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

    // what is on
    @Published private(set) var channels: [VirtualChannel] = []
    @Published private(set) var current: VirtualChannel?
    private var previous: VirtualChannel?
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
    @Published private(set) var scanResults: [VirtualChannel] = []
    @Published private(set) var scanFinished = false
    @Published var setupVisible = false             // modal scan window (first run, or a rescan)
    var firstRun: Bool { !defaults.bool(forKey: "initialScanDone") }
    @Published private(set) var recordingSince: Date?

    private var bannerTimer: DispatchWorkItem?
    private var volumeTimer: DispatchWorkItem?
    private var controlsTimer: DispatchWorkItem?
    private var entryTimer: DispatchWorkItem?
    private var statusTimer: DispatchWorkItem?
    private var lastPackets: UInt64 = 0
    private var retryTicks = 0
    private var lockedAt: Date?

    private init() {
        defaults.register(defaults: ["amp": false, "lna": 24, "vga": 20, "autoGain": true, "volume": 0.8])
        ampOn = defaults.bool(forKey: "amp")
        lna = defaults.integer(forKey: "lna")
        vga = defaults.integer(forKey: "vga")
        autoGain = defaults.bool(forKey: "autoGain")
        volume = defaults.double(forKey: "volume")
        engine.player.volume = Float(volume)
        channels = library.visibleChannels

        engine.onChannels = { [weak self] list in self?.channelsReceived(list) }
        engine.onEvent = { [weak self] src, ev in
            guard let self else { return }
            library.add(event: ev, key: "\(engine.currentRF)-\(src)")
            guideTick &+= 1
        }
        engine.onFormat = { [weak self] w, h, il, ach in
            guard let self else { return }
            format = "\(h == 1088 ? 1080 : h)\(il ? "i" : "p")"
            audioLayout = ach >= 6 ? "5.1" : ach == 1 ? "Mono" : ach > 0 ? "Stereo" : ""
        }
        engine.onClock = { [weak self] d in self?.broadcastClock = d }

        openDevice()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.library.saveGuideIfNeeded() }
    }

    // MARK: device

    func openDevice() {
        let start = current ?? lastWatched() ?? channels.first
        let rf = start?.rf ?? 14
        do {
            try engine.open(rf: rf, amp: ampOn, lna: lna, vga: vga)
            deviceError = nil
            if firstRun || channels.isEmpty { beginSetup() }
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

    func tune(_ ch: VirtualChannel, showBanner: Bool = true) {
        guard deviceError == nil else { return }
        if let cur = current, cur.id != ch.id { previous = cur }
        if engine.currentRF != ch.rf || current == nil { engine.tune(rf: ch.rf); lockedAt = nil }
        engine.select(program: ch.program)
        current = ch
        hasPicture = false; format = ""; audioLayout = ""
        defaults.set(ch.id, forKey: "lastChannel")
        if showBanner { showInfo() }
    }

    func step(_ d: Int) {
        guard !channels.isEmpty else { return }
        let i = current.flatMap { c in channels.firstIndex { $0.id == c.id } } ?? -d
        tune(channels[(i + d + channels.count) % channels.count])
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
        guard !list.isEmpty, !scanning else { scanFound = list; return }
        let snr = stats.snr_db
        library.merge(rf: engine.currentRF, found: list.map { var c = $0; c.signalDB = snr; return c })
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

    func scan() {
        guard !scanning, deviceError == nil else { return }
        scanning = true; scanProgress = 0; scanCancel = false; scanFinished = false; scanResults = []
        guideVisible = false; bannerVisible = false
        hasPicture = false
        let rfs = RFBand.channels
        let engine = self.engine
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [VirtualChannel] = []
            for (i, rf) in rfs.enumerated() {
                guard let self, !self.scanCancel else { break }
                DispatchQueue.main.sync {
                    self.scanProgress = Double(i) / Double(rfs.count)
                    self.scanRF = rf
                    self.scanFound = []
                    engine.tune(rf: rf)
                    engine.select(program: -1)             // demodulate and read tables, decode nothing
                }
                // wait for 8VSB lock, then for the virtual channel table
                var locked = false
                let lockDeadline = Date().addingTimeInterval(1.6)
                while Date() < lockDeadline {
                    Thread.sleep(forTimeInterval: 0.1)
                    if engine.stats().state == ATSC_LOCKED { locked = true; break }
                }
                guard locked else { continue }
                let snr = engine.stats().snr_db
                let tableDeadline = Date().addingTimeInterval(3.5)
                var got: [VirtualChannel] = []
                while Date() < tableDeadline {
                    Thread.sleep(forTimeInterval: 0.1)
                    got = DispatchQueue.main.sync { self.scanFound }
                    if !got.isEmpty { break }
                }
                // linger briefly to collect guide data for this station
                if !got.isEmpty { Thread.sleep(forTimeInterval: 1.5) }
                let list = got.filter { $0.rf == rf }.map { c -> VirtualChannel in var c = c; c.signalDB = snr; return c }
                found.append(contentsOf: list)
                DispatchQueue.main.sync {
                    self.scanResults = found.filter { !$0.hidden }.sorted { ($0.major, $0.minor) < ($1.major, $1.minor) }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let completed = !self.scanCancel
                self.scanning = false
                self.scanProgress = 1
                self.scanFinished = true
                if completed || !found.isEmpty {
                    // a finished scan replaces the list; keep the user's hidden choices
                    self.library.replaceAll(found, keepingHiddenFrom: self.library.channels)
                    self.channels = self.library.visibleChannels
                }
                self.library.save()
                if !found.isEmpty { self.defaults.set(true, forKey: "initialScanDone") }
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
            .appendingPathComponent("ATSC Receiver", isDirectory: true)
    }

    func toggleRecording() {
        if recordingSince != nil {
            engine.stopRecording(); recordingSince = nil
            flash("Recording saved to Movies/ATSC Receiver")
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
        } catch {
            flash("Could not record: \(error.localizedDescription)")
        }
    }

    func revealRecordings() {
        try? FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.recordingsFolder)
    }

    // MARK: housekeeping

    private func tick() {
        let s = engine.stats()
        stats = s
        let moving = s.packets != lastPackets
        lastPackets = s.packets
        if s.state == ATSC_LOCKED, moving { if lockedAt == nil { lockedAt = Date() } } else if !scanning { lockedAt = nil }
        hasPicture = s.state == ATSC_LOCKED && moving && !format.isEmpty

        if let dev = engine.device, !dev.isStreaming {
            engine.closeDevice(); deviceError = "HackRF disconnected"
        }
        if deviceError != nil {
            retryTicks += 1
            if retryTicks % 4 == 0 { openDevice() }
            return
        }
        // automatic gain: hold the ADC level between -24 and -12 dBFS (never switches the amp on)
        if autoGain, !scanning, s.dbfs > -60 {
            if s.dbfs > -12 { if vga >= 2 { vga -= 2 } else if lna >= 8 { lna -= 8 } }
            else if s.dbfs < -24 { if vga <= 60 { vga += 2 } else if lna <= 32 { lna += 8 } }
        }
        if ampOn && s.dbfs > -6 {
            ampOn = false
            flash("Signal very strong: RF amplifier switched off")
        }
    }

    /// Signal quality 0...4 bars from the equalizer SNR (15 dB is about the decoding threshold).
    var bars: Int {
        guard stats.state == ATSC_LOCKED else { return 0 }
        switch stats.snr_db {
        case ..<15: return 1
        case ..<18: return 2
        case ..<21: return 3
        default: return 4
        }
    }

    func shutdown() {
        if recordingSince != nil { engine.stopRecording() }
        library.save()
        engine.closeDevice()
    }
}
