import PlayerCore
import SwiftUI
import Visualizers

@main
struct GroovelightApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Groovelight", id: "main") {
            ContentView()
                .environment(model)
                .tint(.brand)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1360, height: 860)
        .windowToolbarStyle(.unified)
        .commands { PlayerCommands(model: model) }

        // A WindowGroup (not a single-instance Window): SwiftUI makes Window scenes auxiliary, and auxiliary windows
        // cannot enter or leave a full screen Space reliably. Keying it by one fixed value keeps a single window.
        WindowGroup("Visualizer", id: WindowID.visualizer, for: String.self) { _ in
            VisualizerScreen()
                .environment(model)
                .tint(.brand)
        } defaultValue: {
            WindowID.visualizerValue
        }
        .defaultSize(width: 1100, height: 700)

        Window("Equalizer", id: WindowID.equalizer) {
            EqualizerView()
                .environment(model)
                .tint(.brand)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra {
            MiniPlayerView()
                .menuBarGlass()
                .environment(model)
                .tint(.brand)
        } label: {
            // The app icon's note as a template image: the menu bar tints it for light and dark.
            Image("MenuBarNote")
                .accessibilityLabel("Groovelight")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .tint(.brand)
        }
    }
}

enum WindowID {
    static let visualizer = "visualizer"
    /// The one value the visualizer group is opened with, so `openVisualizer` reuses the existing window.
    static let visualizerValue = "main"
    static let equalizer = "equalizer"
}

struct PlayerCommands: Commands {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Playlist") { model.newPlaylist() }
                .keyboardShortcut("n")
            Button("New Smart Playlist…") { model.newSmartPlaylist() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Add Folder to Library…") { model.chooseLibraryFolder() }
                .keyboardShortcut("o")
        }
        CommandMenu("Library") {
            Button("Import Folder…") { model.files.chooseAndImport(folders: true) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Import Files…") { model.files.chooseAndImport(folders: false) }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Organize Library Files…") { model.files.organize() }
            Button(model.files.undoTitle) { Task { await model.files.undoLast() } }
                .disabled(model.files.undoable == nil || model.files.isWorking)
            Divider()
            Button(model.metadata.isFetchingLibraryInfo ? "Stop Fetching Missing Info" : "Fetch Missing Info in Background") {
                if model.metadata.isFetchingLibraryInfo {
                    model.metadata.stopFetchingMissingInfo()
                } else {
                    model.metadata.fetchMissingInfo()
                }
            }
            .keyboardShortcut("u", modifiers: [.command, .option])
            Divider()
            Button("Rescan Library Folders") { model.rescanAll() }
                .disabled(model.scanProgress != nil)
            Divider()
            Button("Back Up Library…") { model.backup.chooseAndBackUp() }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(model.backup.isWorking)
            Button("Restore from Backup…") { model.backup.chooseAndRestore() }
                .disabled(model.backup.isWorking)
        }
        CommandMenu("Controls") {
            // Plain Space is handled by the library views so it still types spaces in text fields.
            Button(model.player.state == .playing ? "Pause" : "Play") { model.player.togglePlayPause() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Next") { model.player.next() }
                .keyboardShortcut(.rightArrow)
            Button("Previous") { model.player.previous() }
                .keyboardShortcut(.leftArrow)
            Divider()
            Button("Increase Volume") { model.player.volume = min(1, model.player.volume + 0.1) }
                .keyboardShortcut(.upArrow)
            Button("Decrease Volume") { model.player.volume = max(0, model.player.volume - 0.1) }
                .keyboardShortcut(.downArrow)
            Divider()
            Toggle("Shuffle", isOn: Binding(get: { model.player.isShuffled }, set: { model.player.setShuffle($0) }))
            Picker("Repeat", selection: Binding(get: { model.player.repeatMode }, set: { model.player.repeatMode = $0 })) {
                Text("Off").tag(RepeatMode.off)
                Text("All").tag(RepeatMode.all)
                Text("One").tag(RepeatMode.one)
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Show Visualizer") { openWindow.visualizer() }
                .keyboardShortcut("t")
            Button("Equalizer") { openWindow(id: WindowID.equalizer) }
                .keyboardShortcut("e", modifiers: [.command, .option])
            Button(model.isShowingNowPlaying ? "Hide Now Playing" : "Show Now Playing") {
                withAnimation(.smooth) { model.isShowingNowPlaying.toggle() }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }
}

extension OpenWindowAction {
    /// Opens the visualizer, or brings the existing one to the front.
    func visualizer() {
        callAsFunction(id: WindowID.visualizer, value: WindowID.visualizerValue)
    }
}
