import PlayerCore
import SwiftUI
import Visualizers

@main
struct GroovelightApp: App {
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
            // The Albums page's cover size (also its toolbar slider and pinching).
            let onAlbums = model.selection == .albums && model.path.isEmpty && !model.isShowingNowPlaying
            Button("Bigger Covers") { if onAlbums { CoverSize.change(by: 1) } }
                .shortcut(.biggerCovers, shortcuts)
                .disabled(!onAlbums)
            Button("Smaller Covers") { if onAlbums { CoverSize.change(by: -1) } }
                .shortcut(.smallerCovers, shortcuts)
                .disabled(!onAlbums)
            Button("Default Cover Size") { if onAlbums { CoverSize.reset() } }
                .shortcut(.defaultCoverSize, shortcuts)
                .disabled(!onAlbums)
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
