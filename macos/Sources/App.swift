import SwiftUI

@main
struct SDRTVApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var tv = TV.shared

    var body: some Scene {
        Window("SDR TV", id: "tv") {
            TVScreen()
                .environmentObject(tv)
                .frame(minWidth: 480, minHeight: 270)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
        .commands { TVCommands(tv: tv) }

        Settings {
            SettingsView().environmentObject(tv)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { TV.shared.shutdown() }
}

struct TVCommands: Commands {
    @ObservedObject var tv: TV

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(tv.recordingSince == nil ? "Start Recording" : "Stop Recording") { tv.toggleRecording() }
                .keyboardShortcut("r")
            Button("Show Recordings in Finder") { tv.revealRecordings() }
        }
        CommandMenu("Channel") {
            Button("Channel Up") { tv.step(1) }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("Channel Down") { tv.step(-1) }.keyboardShortcut(.downArrow, modifiers: .command)
            Button("Previous Channel") { tv.recall() }.keyboardShortcut("l", modifiers: .command)
            Divider()
            Button(tv.guideVisible ? "Hide Guide" : "Show Guide") { tv.guideVisible.toggle() }.keyboardShortcut("g", modifiers: .command)
            Button("Show Info") { tv.toggleInfo() }.keyboardShortcut("i", modifiers: .command)
            Divider()
            Menu("Go to Channel") {
                ForEach(tv.channels) { ch in Button("\(ch.number)  \(ch.name)\(ch.isUnavailable ? "  (weak)" : "")") { tv.tune(ch) } }
            }
            Button(tv.guideRefreshing ? "Stop Updating Guide" : "Update Guide") {
                tv.guideRefreshing ? tv.cancelGuideRefresh() : tv.refreshGuide()
            }
            .keyboardShortcut("u", modifiers: .command)
            .disabled(tv.scanning)
            Divider()
            Button("Scan for Channels…") { tv.beginSetup() }.disabled(tv.scanning)
        }
        CommandMenu("Controls") {
            Button("Volume Up") { tv.changeVolume(0.05) }.keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Volume Down") { tv.changeVolume(-0.05) }.keyboardShortcut(.leftArrow, modifiers: .command)
            Button(tv.muted ? "Unmute" : "Mute") { tv.toggleMute() }.keyboardShortcut("m", modifiers: [.command, .shift])
            Divider()
            Menu("Captions") {
                Button("Off") { tv.selectCaptions(nil) }
                ForEach(tv.captionChoices) { c in Button(c.label) { tv.selectCaptions(c) } }
            }
            Button("Next Caption Setting") { tv.cycleCaptions() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Menu("Audio Track") {
                ForEach(Array(tv.audioTracks.enumerated()), id: \.offset) { i, t in Button(tv.label(for: t)) { tv.selectAudio(i) } }
            }
            .disabled(tv.audioTracks.isEmpty)
            Button("Next Audio Track") { tv.cycleAudio() }.keyboardShortcut("a", modifiers: [.command, .shift])
        }
    }
}
