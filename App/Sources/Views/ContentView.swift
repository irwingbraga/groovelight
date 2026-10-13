import AppKit
import LibraryKit
import PlayerCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var systemAppearance = SystemAppearance()
    @FocusState private var isSearchFocused: Bool
    /// Files are being dragged over the window (to import them).
    @State private var isDropTargeted = false

    /// The whole window goes dark on the Shelf, like the Cover Flow screens it is modeled on.
    private var isShowingShelf: Bool { model.selection == .shelf }

    /// Artists and Genres get a list column between the sidebar and the page, like Music: macOS then gives the list its
    /// own part of the toolbar (side by side in one column, two scroll views under one toolbar made it flicker).
    @ViewBuilder private var splitView: some View {
        @Bindable var model = model
        switch model.selection {
        case .artists, .genres:
            NavigationSplitView {
                sidebar
            } content: {
                Group {
                    if model.selection == .genres { GenreListColumn() } else { ArtistListColumn() }
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 340)
            } detail: {
                pages
            }
        default:
            NavigationSplitView {
                sidebar
            } detail: {
                pages
            }
        }
    }

    private var sidebar: some View {
        SidebarView()
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
    }

    private var pages: some View {
        @Bindable var model = model
        return NavigationStack(path: $model.path) {
            DetailView()
        }
    }

    var body: some View {
        @Bindable var model = model
        ZStack {
            splitView
            // In the toolbar so it stays reachable with the sidebar collapsed; the sidebar's Search item focuses it.
            .searchable(text: $model.searchText, placement: .toolbar, prompt: "Artists, Albums, Songs, Credits")
            .searchFocused($isSearchFocused)
            .onSubmit(of: .search) { RecentSearches.add(model.searchText) }
            .onChange(of: model.selection) { _, selection in
                if selection == .search { isSearchFocused = true }
            }
            .onChange(of: model.searchFocusRequest) { isSearchFocused = true }
            .toolbar(model.isShowingNowPlaying ? .hidden : .automatic, for: .windowToolbar)

            if isDropTargeted {
                DropToImportOverlay()
                    .transition(.opacity)
                    .zIndex(2)
            }

            if model.isShowingNowPlaying {
                NowPlayingView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        // Songs, folders or cue sheets dragged from Finder open Import.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted.animation(.easeOut(duration: 0.15))) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let fileURL = URL(dataRepresentation: url, relativeTo: nil) {
                        urls.append(fileURL)
                    }
                }
                await MainActor.run { model.files.importItems(urls) }
            }
            return true
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
            switch model.selection ?? .albums {
            case .search: SearchView()
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
        // Fresh identity per destination: avoids SwiftUI reusing a Table/List subtree mid-update when switching.
        .id(model.selection)
        .animation(.smooth, value: model.sync.note)
        .overlay(alignment: .bottom) {
            if let progress = model.scanProgress {
                ScanProgressBadge(progress: progress)
                    .padding(.bottom, 16)
            } else if let note = model.sync.note {
                // What a quiet update picked up from the folders.
                Label(note, systemImage: "checkmark.circle")
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .playerBarInset()
        .sidePanel()
        .navigationDestination(for: AppModel.Route.self) { route in
            Group {
                switch route {
                case .album(let album): AlbumDetailView(album: album)
                case .person(let person): PersonView(person: person)
                case .artist(let name): ArtistDetailView(artist: name)
                case .searchCategory(let category, let query): SearchCategoryView(category: category, query: query)
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

/// Shown while files are dragged over the window.
private struct DropToImportOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 44, weight: .light))
                Text("Drop to Import")
                    .font(.system(size: 20, weight: .semibold))
                Text("Songs and folders are moved into your library, tagged and named.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(36)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

extension Color {
    /// Groovelight's navy (lighter in dark mode, for contrast), used as the tint of every window and for highlights,
    /// whatever accent color the system uses.
    static let brand = Color("AccentColor")
}
