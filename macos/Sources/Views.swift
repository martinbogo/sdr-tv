import AVFoundation
import SwiftUI

// MARK: - video surface

struct VideoSurface: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let aspect: CGFloat

    func makeNSView(context: Context) -> VideoHostView {
        let v = VideoHostView()
        v.videoLayer = layer
        v.aspect = aspect
        return v
    }

    func updateNSView(_ v: VideoHostView, context: Context) {
        if v.aspect != aspect { v.aspect = aspect; v.needsLayout = true }
    }
}

/// Black view that keeps the video layer centred at the picture's display aspect ratio.
final class VideoHostView: NSView {
    var videoLayer: AVSampleBufferDisplayLayer? {
        didSet {
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = CGColor.black
            if let v = videoLayer { layer?.addSublayer(v) }
        }
    }
    var aspect: CGFloat = 16.0 / 9.0

    override func layout() {
        super.layout()
        guard let v = videoLayer, bounds.width > 0, bounds.height > 0 else { return }
        var w = bounds.width, h = w / aspect
        if h > bounds.height { h = bounds.height; w = h * aspect }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        v.frame = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        CATransaction.commit()
    }
}

// MARK: - main screen

struct TVScreen: View {
    @EnvironmentObject var tv: TV
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(layer: tv.engine.player.layer, aspect: tv.aspect)
                .opacity(tv.hasPicture && !tv.scanning && !tv.setupVisible ? 1 : 0)
            if tv.hasPicture, tv.captionService != 0, !tv.guideVisible { CaptionOverlay() }
            idleMessage
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    Spacer()
                    if let s = tv.status { StatusOSD(text: s, progress: tv.scanning ? tv.scanProgress : nil) }
                    Spacer()
                }
                .padding(.top, 34)
                Spacer()
                if tv.bannerVisible, !tv.guideVisible { ChannelBanner().transition(.opacity.combined(with: .move(edge: .bottom))) }
                if tv.controlsVisible, !tv.guideVisible { ControlBar().transition(.opacity) }
            }
            .padding(24)
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 12) {
                    if !tv.entry.isEmpty { EntryOSD(text: tv.entry) }
                    if let since = tv.recordingSince { RecordingOSD(since: since) }
                    if tv.weakSignal { WeakSignalOSD() }
                    Spacer()
                    if tv.volumeVisible { VolumeOSD() .transition(.opacity) }
                    Spacer()
                }
            }
            .padding(28)
            if tv.guideVisible { GuideOSD().transition(.opacity) }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.25), value: tv.bannerVisible)
        .animation(.easeInOut(duration: 0.25), value: tv.guideVisible)
        .animation(.easeInOut(duration: 0.2), value: tv.entry)
        .onContinuousHover { phase in if case .active = phase { tv.mouseMoved() } }
        .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true; DispatchQueue.main.async { tv.configureWindow(); tv.setWindowButtons(visible: false) } }
        .onKeyPress(phases: .down) { press in handle(press) }
        .sheet(isPresented: $tv.setupVisible) {
            SetupSheet().environmentObject(tv).interactiveDismissDisabled()
        }
    }

    @ViewBuilder private var idleMessage: some View {
        if let err = tv.deviceError {
            VStack(spacing: 10) {
                Image(systemName: "cable.connector.slash").font(.system(size: 44))
                Text(err).font(.title2)
                Text("Connect the HackRF with an antenna attached. It is picked up automatically.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .foregroundStyle(.white.opacity(0.85))
        } else if !tv.hasPicture, !tv.scanning, !tv.setupVisible, !tv.rechecking, tv.current != nil {
            TuningOSD()
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if tv.guideVisible { return .ignored }         // the guide handles its own keys
        switch press.key {
        case .upArrow: tv.step(1)
        case .downArrow: tv.step(-1)
        case .rightArrow: tv.changeVolume(0.05)
        case .leftArrow: tv.changeVolume(-0.05)
        case .return: tv.entry.isEmpty ? tv.toggleInfo() : tv.commitEntry()
        case .escape: tv.bannerVisible = false; tv.entry = ""
        default:
            guard let c = press.characters.first else { return .ignored }
            switch c.lowercased() {
            case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "-": tv.type(c)
            case "g": tv.guideVisible = true
            case "i": tv.toggleInfo()
            case "m": tv.toggleMute()
            case "c": tv.cycleCaptions()
            case "a": tv.cycleAudio()
            case "l": tv.recall()
            case "r": tv.toggleRecording()
            case "f": NSApp.keyWindow?.toggleFullScreen(nil)
            case "s": tv.beginSetup()
            default: return .ignored
            }
        }
        return .handled
    }
}

// MARK: - OSD pieces

private struct OSDPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .environment(\.colorScheme, .dark)
    }
}

struct SignalBars: View {
    let bars: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < bars ? Color.white : Color.white.opacity(0.25))
                    .frame(width: 4, height: CGFloat(5 + 4 * i))
            }
        }
    }
}

struct ChannelBanner: View {
    @EnvironmentObject var tv: TV

    var body: some View {
        let _ = tv.guideTick
        let ch = tv.current
        let (now, next) = ch.map { tv.library.now($0.guideKey) } ?? (nil, nil)
        OSDPanel {
            HStack(alignment: .center, spacing: 22) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ch?.number ?? "–").font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(ch?.name ?? "").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                }
                .frame(minWidth: 110, alignment: .leading)
                Divider().frame(height: 64)
                VStack(alignment: .leading, spacing: 6) {
                    if let now {
                        Text(now.title).font(.title2.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 10) {
                            Text("\(now.start.formatted(date: .omitted, time: .shortened)) – \(now.end.formatted(date: .omitted, time: .shortened))")
                                .foregroundStyle(.secondary)
                            ProgressView(value: min(1, max(0, Date().timeIntervalSince(now.start) / Double(max(now.duration, 1)))))
                                .frame(width: 160).tint(.white)
                        }
                        .font(.callout)
                    } else {
                        Text(ch?.name ?? "No program information").font(.title2.weight(.semibold))
                        Text("No guide data yet").font(.callout).foregroundStyle(.secondary)
                    }
                    if let next {
                        Text("Next  \(next.start.formatted(date: .omitted, time: .shortened))  \(next.title)")
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 20)
                VStack(alignment: .trailing, spacing: 8) {
                    Text(Date().formatted(date: .omitted, time: .shortened)).font(.title3.weight(.medium)).monospacedDigit()
                    HStack(spacing: 8) {
                        if !tv.videoCodec.isEmpty { Badge(tv.videoCodec) }
                        if !tv.format.isEmpty { Badge(tv.format) }
                        if !tv.audioLayout.isEmpty { Badge(tv.audioLayout) }
                        if tv.audioTracks.count > 1 { Badge("\(tv.audioTracks.count) audio") }
                        if tv.captionService != 0 { Badge("CC") }
                        SignalBars(bars: tv.bars)
                    }
                    Text("RF \(ch?.rf ?? 0)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 900)
        }
        .foregroundStyle(.white)
    }
}

struct Badge: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.caption.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.7), lineWidth: 1))
    }
}

struct StatusOSD: View {
    let text: String
    let progress: Double?
    var body: some View {
        OSDPanel {
            VStack(spacing: 8) {
                Text(text).font(.callout.weight(.medium))
                if let progress { ProgressView(value: progress).frame(width: 320).tint(.white) }
            }
        }
        .foregroundStyle(.white)
    }
}

struct EntryOSD: View {
    let text: String
    var body: some View {
        OSDPanel { Text(text + "_").font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit() }
            .foregroundStyle(.white)
    }
}

struct RecordingOSD: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { ctx in
            let s = Int(ctx.date.timeIntervalSince(since))
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text(String(format: "REC %d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)).monospacedDigit()
            }
            .font(.callout.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
        }
    }
}

struct VolumeOSD: View {
    @EnvironmentObject var tv: TV
    var body: some View {
        OSDPanel {
            VStack(spacing: 10) {
                Image(systemName: tv.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.title2)
                GeometryReader { g in
                    ZStack(alignment: .bottom) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white).frame(height: g.size.height * (tv.muted ? 0 : tv.volume))
                    }
                }
                .frame(width: 8, height: 160)
                Text(tv.muted ? "Mute" : "\(Int(tv.volume * 100))").font(.caption).monospacedDigit()
            }
        }
        .foregroundStyle(.white)
    }
}

/// Appears while the mouse moves; hides after a few idle seconds.
struct ControlBar: View {
    @EnvironmentObject var tv: TV
    var body: some View {
        HStack(spacing: 18) {
            Button { tv.step(-1) } label: { Image(systemName: "chevron.down") }.help("Previous channel (↓)")
            Menu {
                ForEach(tv.channels) { ch in Button("\(ch.number)  \(ch.name)\(ch.isUnavailable ? "  (weak)" : "")") { tv.tune(ch) } }
            } label: {
                Text(tv.current.map { "\($0.number)  \($0.name)" } ?? "Channels").monospacedDigit()
            }
            .menuStyle(.borderlessButton).fixedSize()
            Button { tv.step(1) } label: { Image(systemName: "chevron.up") }.help("Next channel (↑)")
            Divider().frame(height: 18)
            Button { tv.guideVisible = true } label: { Image(systemName: "list.bullet.rectangle") }.help("Guide (G)")
            Button { tv.toggleInfo() } label: { Image(systemName: "info.circle") }.help("Info (I)")
            Divider().frame(height: 18)
            Button { tv.toggleMute() } label: { Image(systemName: tv.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                .help("Mute (M)")
            Slider(value: Binding(get: { tv.volume }, set: { tv.volume = $0; tv.muted = false }), in: 0...1).frame(width: 110)
            Divider().frame(height: 18)
            Menu {
                Button { tv.selectCaptions(nil) } label: { choiceLabel("Off", tv.captionService == 0) }
                ForEach(tv.captionChoices) { c in
                    Button { tv.selectCaptions(c) } label: { choiceLabel(c.label, tv.captionService == c.service) }
                }
            } label: {
                Image(systemName: tv.captionService == 0 ? "captions.bubble" : "captions.bubble.fill")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Captions (C)")
            if tv.audioTracks.count > 1 {
                Menu {
                    ForEach(Array(tv.audioTracks.enumerated()), id: \.offset) { i, t in
                        Button { tv.selectAudio(i) } label: { choiceLabel(tv.label(for: t), i == tv.audioIndex) }
                    }
                } label: { Image(systemName: "waveform.badge.plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Audio track (A)")
            }
            Divider().frame(height: 18)
            Button { tv.toggleRecording() } label: {
                Image(systemName: tv.recordingSince == nil ? "record.circle" : "stop.circle.fill")
                    .foregroundStyle(tv.recordingSince == nil ? Color.white : Color.red)
            }
            .help("Record (R)")
            SettingsLink { Image(systemName: "gearshape") }.help("Settings (⌘,)")
        }
        .buttonStyle(.plain)
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .padding(.top, 12)
    }
}

@ViewBuilder func choiceLabel(_ text: String, _ selected: Bool) -> some View {
    if selected { Label(text, systemImage: "checkmark") } else { Text(text) }
}

// MARK: - guide

struct GuideOSD: View {
    @EnvironmentObject var tv: TV
    @State private var row = 0
    @State private var startOffset = 0          // half-hours from the current slot
    @FocusState private var focused: Bool

    private let slots = 6                       // 3 hours in 30-minute columns
    private let chWidth: CGFloat = 170
    private let rowH: CGFloat = 46

    private var slotStart: Date {
        let now = Date()
        let t = floor(now.timeIntervalSince1970 / 1800) * 1800
        return Date(timeIntervalSince1970: t + Double(startOffset) * 1800)
    }

    var body: some View {
        let _ = tv.guideTick
        let start = slotStart, end = start.addingTimeInterval(Double(slots) * 1800)
        GeometryReader { g in
            let gridW = g.size.width * 0.86 - chWidth - 40
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Guide").font(.title.weight(.semibold))
                    Spacer()
                    Text(Date().formatted(date: .complete, time: .shortened)).foregroundStyle(.secondary)
                }
                .padding(.bottom, 12)
                HStack(spacing: 0) {
                    Color.clear.frame(width: chWidth, height: 24)
                    ForEach(0..<slots, id: \.self) { i in
                        Text(start.addingTimeInterval(Double(i) * 1800).formatted(date: .omitted, time: .shortened))
                            .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                            .frame(width: gridW / CGFloat(slots), alignment: .leading)
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 4) {
                            ForEach(Array(tv.channels.enumerated()), id: \.element.id) { i, ch in
                                GuideRow(ch: ch, from: start, to: end, width: gridW, height: rowH, chWidth: chWidth,
                                         selected: i == row, current: ch.id == tv.current?.id)
                                    .id(i)
                                    .onTapGesture { tv.tune(ch); tv.guideVisible = false }
                            }
                        }
                    }
                    .onChange(of: row) { _, r in withAnimation { proxy.scrollTo(r, anchor: .center) } }
                }
                Text("↑↓ choose  ·  ←→ time  ·  Return watch  ·  Esc or G close")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 10)
            }
            .padding(24)
            .frame(width: g.size.width * 0.86, height: g.size.height * 0.8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.white)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }
        .background(Color.black.opacity(0.45))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            row = tv.current.flatMap { c in tv.channels.firstIndex { $0.id == c.id } } ?? 0
        }
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .upArrow: row = max(0, row - 1)
            case .downArrow: row = min(tv.channels.count - 1, row + 1)
            case .leftArrow: startOffset = max(0, startOffset - 1)
            case .rightArrow: startOffset = min(40, startOffset + 1)
            case .return:
                if tv.channels.indices.contains(row) { tv.tune(tv.channels[row]) }
                tv.guideVisible = false
            case .escape: tv.guideVisible = false
            default:
                if press.characters.lowercased() == "g" { tv.guideVisible = false } else { return .ignored }
            }
            return .handled
        }
    }
}

struct GuideRow: View {
    @EnvironmentObject var tv: TV
    let ch: VirtualChannel
    let from: Date, to: Date
    let width, height, chWidth: CGFloat
    let selected, current: Bool

    var body: some View {
        let span = to.timeIntervalSince(from)
        let events = tv.library.events(ch.guideKey, from: from, to: to)
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(ch.number).font(.headline).monospacedDigit().frame(width: 52, alignment: .leading)
                Text(ch.name).font(.headline.weight(.regular)).lineLimit(1)
                if current { Image(systemName: "play.fill").font(.caption).foregroundStyle(.secondary) }
                if ch.isUnavailable { Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.caption).foregroundStyle(.orange).help("Weak signal last time") }
            }
            .frame(width: chWidth, alignment: .leading)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04))
                if events.isEmpty {
                    Text("No guide information").foregroundStyle(.tertiary).padding(.leading, 10)
                }
                ForEach(events) { e in
                    let x0 = max(0, e.start.timeIntervalSince(from)) / span * Double(width)
                    let x1 = min(span, e.end.timeIntervalSince(from)) / span * Double(width)
                    let live = e.start <= Date() && Date() < e.end
                    Text(e.title)
                        .font(.callout).lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(width: max(0, CGFloat(x1 - x0) - 3), height: height - 6, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(live ? Color.white.opacity(0.16) : Color.white.opacity(0.08)))
                        .offset(x: CGFloat(x0))
                }
            }
            .frame(width: width, height: height - 6, alignment: .leading)
            .clipped()
        }
        .padding(.vertical, 3)
        .opacity(ch.isUnavailable && !selected ? 0.55 : 1)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.45) : Color.clear))
    }
}

// MARK: - settings

struct SettingsView: View {
    var body: some View {
        TabView {
            TunerSettings().tabItem { Label("Tuner", systemImage: "antenna.radiowaves.left.and.right") }
            ChannelSettings().tabItem { Label("Channels", systemImage: "list.number") }
            AccessibilitySettings().tabItem { Label("Captions & Audio", systemImage: "captions.bubble") }
            RecordingSettings().tabItem { Label("Recording", systemImage: "record.circle") }
        }
        .frame(width: 520, height: 460)
    }
}

struct TunerSettings: View {
    @EnvironmentObject var tv: TV
    var body: some View {
        Form {
            Section {
                Toggle("Automatic gain", isOn: $tv.autoGain)
                gain("LNA gain", $tv.lna, 0...40, 8)
                gain("VGA gain", $tv.vga, 0...62, 2)
                Toggle("RF amplifier (+11 dB)", isOn: $tv.ampOn)
            } footer: {
                Text("Automatic gain keeps the level between -24 and -12 dBFS using LNA and VGA. Turn the RF amplifier on only for weak stations; it switches itself off if the signal gets too strong.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Signal") {
                LabeledContent("Status", value: stateText)
                LabeledContent("SNR", value: tv.stats.state == ATSC_LOCKED ? String(format: "%.1f dB", tv.stats.snr_db) : "–")
                LabeledContent("Level", value: String(format: "%.1f dBFS", tv.stats.dbfs))
                LabeledContent("Error correction", value: "\(tv.stats.rs_corrected) fixed, \(tv.stats.rs_bad) lost")
            }
        }
        .formStyle(.grouped)
    }

    private var stateText: String {
        switch tv.stats.state {
        case ATSC_LOCKED: return "Locked"
        case ATSC_ACQ_FIELD, ATSC_ACQ_SEGMENT: return "Searching"
        default: return "No signal"
        }
    }

    private func gain(_ title: String, _ v: Binding<Int>, _ r: ClosedRange<Double>, _ step: Double) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { Double(v.wrappedValue) }, set: { v.wrappedValue = Int($0) }), in: r, step: step)
                Text("\(v.wrappedValue) dB").monospacedDigit().frame(width: 46, alignment: .trailing)
            }
        }
        .disabled(tv.autoGain)
    }
}

struct ChannelSettings: View {
    @EnvironmentObject var tv: TV
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Scan for Channels…") { tv.beginSetup() }.disabled(tv.scanning)
                if tv.scanning { ProgressView(value: tv.scanProgress).frame(width: 180) }
                Spacer()
                Text("\(tv.channels.count) channels").foregroundStyle(.secondary)
            }
            Table(tv.allChannels) {
                TableColumn("Show") { ch in
                    Toggle("", isOn: Binding(get: { !ch.hidden }, set: { tv.setHidden(ch, !$0) }))
                        .labelsHidden()
                        .help("Unchecked channels are removed from the channel list, guide and menus until you check them again.")
                }
                .width(40)
                TableColumn("Channel") { ch in Text(ch.number).monospacedDigit() }.width(64)
                TableColumn("Name", value: \.name)
                TableColumn("RF") { ch in Text("\(ch.rf)").monospacedDigit() }.width(36)
                TableColumn("Signal") { ch in
                    if ch.isUnavailable {
                        Text("Weak").foregroundStyle(.orange).help("Too weak last time it was tuned; choosing it retries.")
                    } else {
                        Text(ch.signalDB > 0 ? String(format: "%.0f dB", ch.signalDB) : "–").monospacedDigit()
                    }
                }
                .width(70)
            }
        }
        .padding(20)
    }
}

struct RecordingSettings: View {
    @EnvironmentObject var tv: TV
    var body: some View {
        Form {
            LabeledContent("Saved to", value: "Movies/ATSC Receiver")
            Button("Show Recordings in Finder") { tv.revealRecordings() }
            Text("Recordings are the broadcast stream saved exactly as received (MPEG transport stream, .ts): the channel's video, audio and guide data with no re-encoding. Play them with VLC or IINA.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

// MARK: - setup / scan window

/// Shown on first launch (and for rescans): scans every RF channel with the picture hidden,
/// then saves the channel list for later launches.
struct SetupSheet: View {
    @EnvironmentObject var tv: TV

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tv.firstRun ? "Welcome to ATSC Receiver" : "Scan for Channels").font(.title2.weight(.semibold))
                    Text(subtitle).foregroundStyle(.secondary)
                }
            }
            if let err = tv.deviceError {
                Label(err, systemImage: "cable.connector.slash").foregroundStyle(.orange)
                Text("Connect the HackRF (with the PortaPack in HackRF mode) and a TV antenna. The scan starts as soon as it is detected.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: tv.scanFinished ? 1 : tv.scanProgress)
                    Text(progressText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                List(tv.scanResults) { ch in
                    HStack {
                        Text(ch.number).monospacedDigit().frame(width: 56, alignment: .leading)
                        Text(ch.name)
                        Spacer()
                        Text("RF \(ch.rf)").foregroundStyle(.secondary).monospacedDigit()
                        SignalBars(bars: bars(ch.signalDB)).environment(\.colorScheme, .dark)
                            .padding(4).background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .frame(minHeight: 220)
                .overlay {
                    if tv.scanResults.isEmpty {
                        Text(tv.scanFinished ? "No channels found" : "Stations will appear here as they are found")
                            .foregroundStyle(.secondary)
                    }
                }
                if tv.scanFinished && tv.scanResults.isEmpty {
                    Text("Check that the antenna is connected and try another position (near a window helps). For distant stations, turn on the RF amplifier in Settings.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                if tv.scanning {
                    Button("Stop") { tv.cancelScan() }
                } else if tv.scanFinished && tv.scanResults.isEmpty || tv.deviceError == nil && !tv.scanFinished {
                    Button("Scan Again") { tv.beginSetup() }.disabled(tv.deviceError != nil)
                }
                Spacer()
                if !tv.firstRun && !tv.scanning {
                    Button("Close") { tv.finishSetup() }
                }
                Button("Start Watching") { tv.finishSetup() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(tv.scanning || tv.channels.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var subtitle: String {
        if tv.deviceError != nil { return "Waiting for the HackRF" }
        if tv.scanning { return "Finding the TV stations your antenna receives. This takes about two minutes." }
        if tv.scanResults.isEmpty { return "The scan found no digital TV stations." }
        return "Found \(tv.scanResults.count) channels. They are saved, so this runs only once."
    }

    private var progressText: String {
        if tv.scanFinished { return "Scan complete" }
        if tv.scanRF == 0 { return "Starting…" }
        let phase = tv.scanPhase.isEmpty ? "" : "\(tv.scanPhase) · "
        return "\(phase)RF channel \(tv.scanRF) (\(Int(RFBand.centerMHz(tv.scanRF))) MHz) · \(tv.scanResults.count) found"
    }

    private func bars(_ snr: Double) -> Int { snr < 15 ? 1 : snr < 18 ? 2 : snr < 21 ? 3 : 4 }
}

// MARK: - reception diagnostics

/// Replaces a bare "Tuning…": shows each stage of reception live, what the automatic rescue is
/// trying, and a plain explanation when something fails.
struct TuningOSD: View {
    @EnvironmentObject var tv: TV

    var body: some View {
        let d = tv.diagnosis
        OSDPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(tv.current?.number ?? "").font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(tv.current?.name ?? "").font(.title3)
                    Spacer()
                    Text("RF \(tv.current?.rf ?? 0) · \(Int(RFBand.centerMHz(tv.current?.rf ?? 14))) MHz")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(d.stages) { st in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            icon(st.state).frame(width: 16)
                            Text(st.title).font(.callout.weight(.semibold)).frame(width: 64, alignment: .leading)
                            Text(st.detail).font(.callout).foregroundStyle(st.state == .pending ? .tertiary : .primary)
                                .monospacedDigit()
                        }
                    }
                }
                if let note = tv.rescueNote {
                    Label(note, systemImage: "wand.and.stars").font(.callout).foregroundStyle(.yellow)
                } else if let hint = d.hint {
                    Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 520)
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private func icon(_ s: TV.Stage.State) -> some View {
        switch s {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .working: ProgressView().controlSize(.mini).tint(.white)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}

struct WeakSignalOSD: View {
    @EnvironmentObject var tv: TV
    var body: some View {
        HStack(spacing: 8) {
            SignalBars(bars: tv.bars)
            Text(tv.lossRate > 0.02 ? String(format: "Weak signal · %.0f%% lost", tv.lossRate * 100) : "Weak signal")
                .font(.callout.weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
    }
}

// MARK: - captions

/// Draws the decoder's caption screen over the picture, inside the caption-safe area (the
/// central 80% of the picture) with the positions and anchoring the broadcaster specified.
struct CaptionOverlay: View {
    @EnvironmentObject var tv: TV

    var body: some View {
        GeometryReader { g in
            let pic = pictureRect(g.size)
            let safe = pic.insetBy(dx: pic.width * 0.1, dy: pic.height * 0.1)
            let row = safe.height / 15
            let fs = max(10, row * 0.8 * tv.captionScale)
            ZStack(alignment: .topLeading) {
                ForEach(Array(tv.captionRegions.enumerated()), id: \.offset) { _, r in
                    Color.clear.frame(width: 0, height: 0)
                        .overlay(alignment: alignment(r.anchor)) {
                            VStack(alignment: hAlign(r.anchor), spacing: 0) {
                                ForEach(Array(r.lines.enumerated()), id: \.offset) { _, line in
                                    Text(line.isEmpty ? " " : line)
                                        .font(.system(size: fs, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, fs * 0.25)
                                        .frame(minHeight: row * tv.captionScale)
                                        .background(Color.black.opacity(line.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : tv.captionBackground))
                                        .fixedSize()
                                }
                            }
                        }
                        .position(x: safe.minX + CGFloat(r.x) * safe.width, y: safe.minY + CGFloat(r.y) * safe.height)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tv.captionRegions.flatMap(\.lines).joined(separator: " "))
    }

    private func pictureRect(_ size: CGSize) -> CGRect {
        var w = size.width, h = w / tv.aspect
        if h > size.height { h = size.height; w = h * tv.aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func alignment(_ a: Int) -> Alignment {
        [.topLeading, .top, .topTrailing, .leading, .center, .trailing, .bottomLeading, .bottom, .bottomTrailing][min(max(a, 0), 8)]
    }

    private func hAlign(_ a: Int) -> HorizontalAlignment {
        switch a % 3 { case 1: return .center; case 2: return .trailing; default: return .leading }
    }
}

struct AccessibilitySettings: View {
    @EnvironmentObject var tv: TV
    private let languages = ["eng", "spa", "fra", "por", "deu", "ita", "zho", "kor", "vie", "tgl", "rus", "ara", "jpn"]

    var body: some View {
        Form {
            Section {
                Toggle("Show captions", isOn: $tv.captionsOn)
                Picker("Preferred caption language", selection: $tv.captionLanguage) {
                    ForEach(languages, id: \.self) { Text(TV.languageName($0)).tag($0) }
                }
                Picker("Text size", selection: $tv.captionScale) {
                    Text("Small").tag(0.8); Text("Medium").tag(1.0); Text("Large").tag(1.3); Text("Extra large").tag(1.6)
                }
                LabeledContent("Background") {
                    Slider(value: $tv.captionBackground, in: 0...1)
                }
            } header: {
                Text("Closed captions")
            } footer: {
                Text("Digital (CEA-708) captions are used when the station provides them in your language, otherwise analog-compatible (CEA-608) captions. Press C to switch captions while watching.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Preferred audio language", selection: $tv.audioLanguage) {
                    ForEach(languages, id: \.self) { Text(TV.languageName($0)).tag($0) }
                }
                Toggle("Prefer audio description when available", isOn: $tv.preferDescription)
            } header: {
                Text("Audio")
            } footer: {
                Text("Audio description narrates what is on screen for blind and low-vision viewers. Press A to switch audio tracks while watching.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
