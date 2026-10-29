import PlayerCore
import SwiftUI
import Visualizers

@main
struct GroovelightApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // One library window, like Music. The principal role keeps what a WindowGroup window has (full screen, its own
        // Space), which a plain Window scene does not.
        Window("Groovelight", id: "main") {
            ContentView()
                .environment(model)
                .tint(.brand)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowManagerRole(.principal)
        // Files opened with the app (the command line tool, Finder's Open With) go to the app delegate only: a scene
        // that takes the event shows its window again, which made the whole window fade out and back in.
        .handlesExternalEvents(matching: [])
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
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 1100, height: 700)

        Window("Cassettes", id: WindowID.cassettes) {
            CassettesWindow()
                .environment(model)
                .tint(.brand)
        }
        .defaultSize(width: 420, height: 560)
        .defaultPosition(.center)
        .handlesExternalEvents(matching: [])

        Window("Equalizer", id: WindowID.equalizer) {
            EqualizerView()
                .environment(model)
                .tint(.brand)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .handlesExternalEvents(matching: [])

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
    static let cassettes = "cassettes"
}

struct PlayerCommands: Commands {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// The playlist on screen for File > Library > Export Playlist: `.some(nil)` is Loved Songs, nil means none.
    private var exportablePlaylist: Int64?? {
        guard model.path.isEmpty, !model.isShowingNowPlaying else { return nil }
        switch model.selection {
        case .playlist(let id): return .some(id)
        case .lovedSongs: return .some(nil)
        default: return nil
        }
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if Updates.shared.isAvailable {
                Button("Check for Updates…") { Updates.shared.checkForUpdates() }
            }
        }
        CommandGroup(replacing: .help) {
            Button("Groovelight on GitHub") { NSWorkspace.shared.open(Updates.repository) }
            Button("Report an Issue…") { NSWorkspace.shared.open(Updates.repository.appendingPathComponent("issues")) }
            Divider()
            Button("Acknowledgements") { Updates.showAcknowledgements() }
        }
        // The File menu of Music: New, Import, and the library's housekeeping in a Library submenu.
        CommandGroup(replacing: .newItem) {
            Menu("New") {
                Button("Playlist") { model.newPlaylist() }
                    .shortcut(.newPlaylist, shortcuts)
                Button("Smart Playlist…") { model.newSmartPlaylist() }
                    .shortcut(.newSmartPlaylist, shortcuts)
            }
            Divider()
            Button("Import…") { model.files.chooseAndImport() }
                .shortcut(.importMusic, shortcuts)
            Button("Add Folder to Library…") { model.chooseLibraryFolder() }
                .shortcut(.addFolder, shortcuts)
            Menu("Library") {
                Button("Import Playlist…") { model.playlistFiles.chooseAndImport() }
                    .disabled(model.playlistFiles.isImporting)
                Button("Export Playlist…") { model.playlistFiles.export(playlistId: exportablePlaylist ?? nil) }
                    .disabled(exportablePlaylist == nil)
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
                .shortcut(.fetchMissingInfo, shortcuts)
                Button("Rescan Library Folders") { model.rescanAll() }
                    .disabled(model.scanProgress != nil)
                Divider()
                Button("Back Up Library…") { model.backup.chooseAndBackUp() }
                    .shortcut(.backUp, shortcuts)
                    .disabled(model.backup.isWorking)
                Button("Restore from Backup…") { model.backup.chooseAndRestore() }
                    .disabled(model.backup.isWorking)
            }
        }
        CommandGroup(after: .textEditing) {
            Button("Search Library") { model.showSearch() }
                .shortcut(.search, shortcuts)
        }
        CommandMenu("Controls") {
            // Plain Space is handled by the library views so it still types spaces in text fields.
            Button(model.player.state == .playing ? "Pause" : "Play") { model.player.togglePlayPause() }
                .shortcut(.playPause, shortcuts)
            Button("Next") { model.player.next() }
                .shortcut(.next, shortcuts)
            Button("Previous") { model.player.previous() }
                .shortcut(.previous, shortcuts)
            Button("Skip Forward 10 Seconds") { model.player.seek(to: min(model.player.duration, model.player.currentTime + 10)) }
                .shortcut(.skipForward, shortcuts)
                .disabled(model.player.current == nil)
            Button("Skip Back 10 Seconds") { model.player.seek(to: max(0, model.player.currentTime - 10)) }
                .shortcut(.skipBack, shortcuts)
                .disabled(model.player.current == nil)
            Divider()
            Button("Increase Volume") { model.player.volume = min(1, model.player.volume + 0.1) }
                .shortcut(.volumeUp, shortcuts)
            Button("Decrease Volume") { model.player.volume = max(0, model.player.volume - 0.1) }
                .shortcut(.volumeDown, shortcuts)
            Button(model.player.volume == 0 ? "Unmute" : "Mute") { model.toggleMute() }
                .shortcut(.mute, shortcuts)
            Divider()
            Toggle("Shuffle", isOn: Binding(get: { model.player.isShuffled }, set: { model.player.setShuffle($0) }))
                .shortcut(.shuffle, shortcuts)
            Picker("Repeat", selection: Binding(get: { model.player.repeatMode }, set: { model.player.repeatMode = $0 })) {
                Text("Off").tag(RepeatMode.off)
                Text("All").tag(RepeatMode.all)
                Text("One").tag(RepeatMode.one)
            }
            Button("Cycle Repeat Mode") {
                model.player.repeatMode = switch model.player.repeatMode {
                case .off: .all
                case .all: .one
                case .one: .off
                }
            }
            .shortcut(.cycleRepeat, shortcuts)
            Picker("Playback Speed", selection: Binding(get: { model.player.rate }, set: { model.setRate($0) })) {
                ForEach(PlaybackPrefs.speeds, id: \.self) { speed in
                    Text(PlaybackPrefs.speedLabel(speed)).tag(speed)
                }
            }
            .disabled(model.player.bitPerfect)
            Toggle("Bit-Perfect Playback", isOn: Binding(get: { model.player.bitPerfect }, set: { on in
                model.player.bitPerfect = on
                UserDefaults.standard.set(on, forKey: PlaybackPrefs.bitPerfect)
            }))
            Picker("Sleep Timer", selection: Binding(get: { model.sleepTimer.mode }, set: { mode in
                if let mode { model.sleepTimer.start(mode) } else { model.sleepTimer.cancel() }
            })) {
                Text("Off").tag(SleepTimer.Mode?.none)
                Divider()
                ForEach(SleepTimer.choices, id: \.self) { minutes in
                    Text(minutes < 60 || minutes % 60 != 0 ? "\(minutes) Minutes" : "\(minutes / 60) Hour\(minutes == 60 ? "" : "s")")
                        .tag(SleepTimer.Mode?.some(.minutes(minutes)))
                }
                Text("End of Current Song").tag(SleepTimer.Mode?.some(.endOfSong))
            }
            Divider()
            Button("Love or Undo Love") { model.toggleLovedCurrent() }
                .shortcut(.love, shortcuts)
                .disabled(model.player.current == nil)
            Button("Go to Current Song") { model.goToCurrentSong() }
                .shortcut(.goToCurrentSong, shortcuts)
                .disabled(model.player.current == nil)
        }
        CommandGroup(after: .sidebar) {
            Divider()
            // The sidebar's pages in order, like the numbered sections of Music.
            ForEach(Self.pages, id: \.action) { page in
                Button(page.action.title) {
                    model.isShowingNowPlaying = false
                    model.selection = page.item
                }
                .shortcut(page.action, shortcuts)
            }
            Button("Back") { model.goBack() }
                .shortcut(.back, shortcuts)
                .disabled(model.path.isEmpty || model.isShowingNowPlaying)
            Divider()
        }
        // The automatic entry for the library window, with Music's shortcut.
        CommandGroup(replacing: .singleWindowList) {
            Button("Groovelight") { openWindow.mainWindow() }
                .shortcut(.mainWindow, shortcuts)
        }
        CommandGroup(after: .toolbar) {
            // The cover size of the Albums page or the Shelf (also their toolbar sliders and pinching).
            let covers: CoverSize? = model.isShowingNowPlaying || !model.path.isEmpty ? nil
                : model.selection == .albums ? .albums : model.selection == .shelf ? .shelf : nil
            Button("Bigger Covers") { covers?.change(by: 1) }
                .shortcut(.biggerCovers, shortcuts)
                .disabled(covers == nil)
            Button("Smaller Covers") { covers?.change(by: -1) }
                .shortcut(.smallerCovers, shortcuts)
                .disabled(covers == nil)
            Button("Default Cover Size") { covers?.reset() }
                .shortcut(.defaultCoverSize, shortcuts)
                .disabled(covers == nil)
            Divider()
            Button(model.isShowingNowPlaying ? "Hide Now Playing" : "Show Now Playing") {
                withAnimation(.smooth) { model.isShowingNowPlaying.toggle() }
            }
            .shortcut(.nowPlaying, shortcuts)
            Button("Lyrics") { model.toggleLyrics() }
                .shortcut(.lyrics, shortcuts)
            Button("Up Next") { model.isShowingQueue.toggle() }
                .shortcut(.upNext, shortcuts)
            Divider()
            Button("Show Visualizer") { openWindow.visualizer() }
                .shortcut(.visualizer, shortcuts)
            Button("Equalizer") { openWindow(id: WindowID.equalizer) }
                .shortcut(.equalizer, shortcuts)
        }
    }

    private static let pages: [(item: SidebarItem, action: ShortcutAction)] = [
        (.recentlyAdded, .recentlyAdded), (.artists, .artists), (.albums, .albums), (.songs, .songs),
        (.genres, .genres), (.shelf, .shelf), (.allPlaylists, .allPlaylists), (.lovedSongs, .lovedSongs),
    ]

    private var shortcuts: ShortcutStore { model.shortcuts }
}

extension OpenWindowAction {
    /// Brings the library window forward, opening one if it was closed.
    func mainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            callAsFunction(id: "main")
        }
    }

    /// Opens the visualizer, or brings the existing one to the front.
    func visualizer() {
        callAsFunction(id: WindowID.visualizer, value: WindowID.visualizerValue)
    }
}

/// Files opened with the app (Finder's Open With, the Dock icon, the command line tool) go to the import.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            guard let model = AppModel.current else { return }
            // A cassette design is added and shown in Now Playing; anything else is music to import.
            let cassettes = urls.filter { $0.pathExtension.lowercased() == "cassette" }
            for url in cassettes { model.openCassette(url) }
            let music = urls.filter { $0.pathExtension.lowercased() != "cassette" }
            if !music.isEmpty { model.control.open(music) }
        }
    }
}
