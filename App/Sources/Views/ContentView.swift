import AppKit
import LibraryKit
import PlayerCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var systemAppearance = SystemAppearance()

    /// The whole window goes dark on the Shelf, like the Cover Flow screens it is modeled on.
    private var isShowingShelf: Bool {
        model.selection == .shelf && model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        @Bindable var model = model
        ZStack {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
            } detail: {
                NavigationStack(path: $model.path) {
                    DetailView()
                }
            }
            .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search")
            .toolbar { LibraryToolbar() }
            .toolbar(model.isShowingNowPlaying ? .hidden : .automatic, for: .windowToolbar)

            if model.isShowingNowPlaying {
                NowPlayingView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .modifier(AppSheets())
        .alert("Groovelight", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        // Always an explicit scheme, never nil: going from `.dark` back to nil left the sidebar half dark in the light
        // theme, so outside the Shelf the window gets the system's current scheme instead.
        .preferredColorScheme(isShowingShelf ? .dark : systemAppearance.colorScheme)
        .onKeyPress(.space) {
            model.player.togglePlayPause()
            return .handled
        }
        #if DEBUG
        .onAppear { DebugTour.runIfRequested(model: model, openWindow: openWindow) }
        #endif
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                SearchResultsView(query: model.searchText)
            } else {
                switch model.selection ?? .albums {
                case .recentlyAdded: AlbumsGridView(mode: .recentlyAdded)
                case .albums: AlbumsGridView(mode: .all)
                case .artists: ArtistsView()
                case .songs: SongsView()
                case .genres: GenresView()
                case .shelf: ShelfView()
                case .allPlaylists: AllPlaylistsView()
                case .lovedSongs: LovedSongsView()
                case .playlist(let id): PlaylistView(playlistId: id)
                }
            }
        }
        // Fresh identity per destination: avoids SwiftUI reusing a Table/List subtree mid-update when switching.
        .id(model.searchText.isEmpty ? model.selection : nil)
        .overlay(alignment: .bottom) {
            if let progress = model.scanProgress {
                ScanProgressBadge(progress: progress)
                    .padding(.bottom, 16)
            }
        }
        .playerBarInset()
        .sidePanel()
        .navigationDestination(for: AppModel.Route.self) { route in
            Group {
                switch route {
                case .album(let album): AlbumDetailView(album: album)
                case .person(let person): PersonView(person: person)
                }
            }
            .playerBarInset()
            .sidePanel()
        }
    }
}

struct ScanProgressBadge: View {
    var progress: ScanProgress

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            if progress.filesFound > 0 {
                Text("Scanning library… \(progress.filesProcessed) of \(progress.filesFound)")
            } else {
                Text("Looking for music…")
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Shown when the library has no tracks yet.
struct EmptyLibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Your Library Is Empty", systemImage: "music.note.house")
        } description: {
            Text("Add the folder where you keep your music. Groovelight reads tags and artwork and keeps the library in sync as files change.")
        } actions: {
            Button("Add Music Folder…") { model.chooseLibraryFolder() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
    }
}

extension View {
    /// Runs a database observation for the lifetime of the view (restarting when `id` changes).
    func observing<T: Sendable, ID: Equatable>(_ database: LibraryDatabase, id: ID, _ fetch: @escaping @Sendable (Database) throws -> T,
                                               update: @escaping @MainActor (T) -> Void) -> some View {
        task(id: id) {
            do {
                for try await value in database.observe(fetch) {
                    update(value)
                }
            } catch {}
        }
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds.rounded())
    let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
    return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
}

func formatLongDuration(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    if minutes >= 60 { return "\(minutes / 60) hr \(minutes % 60) min" }
    return "\(minutes) min"
}

/// The system's light or dark setting, tracked live. Read from the app rather than the window, since the window's
/// own appearance is overridden while the Shelf is shown.
@MainActor @Observable
final class SystemAppearance {
    private(set) var colorScheme: ColorScheme = .light
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        update()
        observation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.update() }
        }
    }

    private func update() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        colorScheme = isDark ? .dark : .light
    }
}

/// Right side panel (Up Next or the lyrics of the song that is playing). Applied per page, like the player bar: an
/// inspector attached to the NavigationStack is covered by pushed album pages.
private struct SidePanelModifier: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .inspector(isPresented: Binding(get: { model.sidePanel != nil }, set: { if !$0 { model.sidePanel = nil } })) {
                Group {
                    switch model.sidePanel {
                    case .lyrics: LyricsSidePanel()
                    default: QueueView()
                    }
                }
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            }
    }
}

extension View {
    func sidePanel() -> some View { modifier(SidePanelModifier()) }
}

/// Every sheet of the main window, in two groups (kept apart from `ContentView`, and split, so each body stays quick to
/// type-check).
private struct AppSheets: ViewModifier {
    func body(content: Content) -> some View {
        content
            .modifier(EditingSheets())
            .modifier(LibrarySheets())
    }
}

/// Sheets that edit songs and playlists.
private struct EditingSheets: ViewModifier {
    @Environment(AppModel.self) private var model

    private var review: Binding<MetadataStore.ReviewRequest?> {
        Binding(get: { model.metadata.reviewTracks }, set: { model.metadata.reviewTracks = $0 })
    }
    private var credits: Binding<Track?> {
        Binding(get: { model.creditsTrack }, set: { model.creditsTrack = $0 })
    }
    private var info: Binding<AppModel.InfoRequest?> {
        Binding(get: { model.infoEditor }, set: { model.infoEditor = $0 })
    }
    private var playlist: Binding<AppModel.PlaylistEditRequest?> {
        Binding(get: { model.playlistEditor }, set: { model.playlistEditor = $0 })
    }
    private var smartPlaylist: Binding<AppModel.SmartEditorRequest?> {
        Binding(get: { model.smartPlaylistEditor }, set: { model.smartPlaylistEditor = $0 })
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: review) { FixMetadataSheet(tracks: $0.tracks) }
            .sheet(item: credits) { TrackCreditsSheet(track: $0) }
            .sheet(item: info) { GetInfoSheet(tracks: $0.tracks) }
            .sheet(item: playlist) { EditPlaylistSheet(playlist: $0.playlist) }
            .sheet(item: smartPlaylist) { SmartPlaylistEditor(playlist: $0.playlist) }
    }
}

/// Sheets about the library's files: locating folders after a restore, organizing and importing.
private struct LibrarySheets: ViewModifier {
    @Environment(AppModel.self) private var model

    private var locate: Binding<Bool> {
        Binding(get: { !(model.backup?.foldersToLocate.isEmpty ?? true) }, set: { if !$0 { model.backup.foldersToLocate = [] } })
    }
    private var organize: Binding<FilesStore.OrganizeRequest?> {
        Binding(get: { model.files?.organizeRequest }, set: { model.files.organizeRequest = $0 })
    }
    private var importSession: Binding<ImportSession?> {
        Binding(get: { model.files?.importSession }, set: { model.files.importSession = $0 })
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: locate) { LocateFoldersSheet() }
            .sheet(item: organize) { OrganizeSheet(tracks: $0.tracks) }
            .sheet(item: importSession) { ImportSheet(session: $0) }
    }
}

extension Color {
    /// Groovelight's navy (lighter in dark mode, for contrast), used as the tint of every window and for highlights,
    /// whatever accent color the system uses.
    static let brand = Color("AccentColor")
}
