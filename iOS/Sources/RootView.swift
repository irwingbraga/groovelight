import SwiftUI

enum AppTab: Hashable {
    case library, shelf, settings, search
}

/// Where there is room (iPad, the iPhone Duo's inner display), the Mac's layout: its sidebar beside the page, and its
/// floating player bar over the page. Where there is not (iPhone, the Duo's outer display), tabs (the Duo shows their bar
/// on the side) with the Library's places as a list and the mini player as the tab view's accessory. Now Playing covers
/// everything in both.
struct RootView: View {
    @Environment(AppModel.self) private var model
    /// What this window shows: each window (Stage Manager, Split View) has its own Now Playing, sheets and pages.
    @State private var window = WindowModel()
    @Environment(\.horizontalSizeClass) private var sizeClass
    // `-GLDebugShelf YES` opens the Shelf, for layout checks.
    // `-GLDebugSection recentlyAdded|artists|songs|genres` opens that place (where there is a sidebar).
    @State private var selection: SidebarItem? = UserDefaults.standard.bool(forKey: "GLDebugShelf") ? .shelf
        : SidebarItem.library.first { "\($0)" == UserDefaults.standard.string(forKey: "GLDebugSection") } ?? .albums
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = UserDefaults.standard.bool(forKey: "GLDebugShelf") ? AppTab.shelf : AppTab.library

    var body: some View {
        @Bindable var window = window
        Group {
            if sizeClass == .regular {
                SplitRoot(selection: $selection)
                    .focusedSceneValue(\.sidebarSelection, $selection)
            } else {
                TabRoot(tab: $tab)
            }
        }
        .fullScreenCover(isPresented: $window.isShowingNowPlaying) {
            if let item = model.nowPlaying {
                NowPlayingView(item: item) { window.isShowingNowPlaying = false }
            }
        }
        .sheet(isPresented: $window.isPairing) { PairingSheet() }
        .sheet(isPresented: $window.isShowingSettings) { SettingsView(isSheet: true) }
        // Leaving the screen: what was played and loved goes to the Mac (and Last.fm) now. In front: this window is the
        // one the app's own requests (the debug openers) go to.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .background { model.sync.sendHistory() }
            if phase == .active || model.activeWindow == nil { model.activeWindow = window }
        }
        // Just paired: other devices can play here from now on, and the Library shows the Mac's music (once, from the
        // window in front).
        .onChange(of: model.sync.isPaired) { _, paired in
            guard model.activeWindow === window else { return }
            if paired { model.relay.start(model: model) } else { model.relay.stop() }
            if paired { model.catalog.downloadedOnly = false }
        }
        .onChange(of: model.nowPlaying == nil) { _, stopped in
            guard stopped else { return }
            // Not while playback moves between this device and the Mac (nothing plays for a moment).
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if model.nowPlaying == nil { window.isShowingNowPlaying = false }
            }
        }
        .focusedSceneValue(\.window, window)
        .environment(window)
    }
}

/// What one window shows, apart from the others: Now Playing, the pairing and Settings sheets, and a page asked for.
@MainActor @Observable
final class WindowModel {
    /// The pairing sheet is up.
    var isPairing = false
    /// Now Playing covers the window (`-GLDebugOpenNowPlaying YES` opens it at launch, for layout checks).
    var isShowingNowPlaying = UserDefaults.standard.bool(forKey: "GLDebugOpenNowPlaying")
    /// Settings, as a sheet where the sidebar has no room for them (iPad, the iPhone Duo's inner display).
    var isShowingSettings = UserDefaults.standard.bool(forKey: "GLDebugOpenSettings")
    /// A page asked for from Now Playing, the player bar or the mini player (the song's album or artist), for the
    /// window's navigation stack to open.
    var requestedRoute: LibraryRoute?

    /// Opens a page in the library, closing Now Playing.
    func show(_ route: LibraryRoute) {
        isShowingNowPlaying = false
        requestedRoute = route
    }
}

/// The sidebar and the page, with the player bar floating over the page as on the Mac. Artists get a list column
/// between them, as on the Mac, with the bar spanning the list and the page.
struct SplitRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    @Binding var selection: SidebarItem?
    @State private var path: [LibraryRoute] = []
    /// The artist shown in the Artists' list column.
    @State private var artist: String?
    /// The page's column, where the player bar floats, and the list column when there is one.
    @State private var detail: CGRect = .zero
    @State private var list: CGRect = .zero

    private var hasList: Bool { selection == .artists }

    var body: some View {
        Group {
            if hasList {
                NavigationSplitView {
                    LibrarySidebar(selection: $selection)
                } content: {
                    ArtistColumn(selection: $artist)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 340)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("split")) } action: { list = $0 }
                        .onDisappear { list = .zero }
                } detail: {
                    page {
                        if let artist {
                            ArtistPage(name: artist).id(artist)
                        } else {
                            ContentUnavailableView("Select an Artist", systemImage: "music.microphone")
                        }
                    }
                    .id(artist)
                }
            } else {
                NavigationSplitView {
                    LibrarySidebar(selection: $selection)
                } detail: {
                    page { SidebarItemContent(item: selection ?? .albums) }
                        .id(selection)
                }
            }
        }
        // Room under the lists for the bar, on every page, and for pages that place their own controls (the Shelf).
        .contentMargins(.bottom, 88, for: .scrollContent)
        .environment(\.playerBarInset, 88)
        // Over the split view, not the page's stack: the split view hosts the pages pushed onto it, which would leave
        // a bar (or an inset) of the stack behind.
        .overlay(alignment: .bottomLeading) {
            let bar = hasList && list.width > 0 ? list.union(detail) : detail
            PlayerBar()
                .frame(width: bar.width)
                .offset(x: bar.minX)
                .opacity(bar.width > 0 ? 1 : 0)
        }
        .coordinateSpace(.named("split"))
    }

    /// The page's stack, measured for the bar.
    private func page(@ViewBuilder _ root: () -> some View) -> some View {
        NavigationStack(path: $path) {
            root().libraryDestinations()
        }
        .debugOpenAlbum(path: $path)
        // An album or artist asked for from Now Playing or the player bar (an artist in the list, on Artists).
        .onChange(of: window.requestedRoute) { _, route in
            guard let route else { return }
            switch route {
            case .artist(let name) where hasList, .macArtist(let name) where hasList:
                artist = name
                path = []
            default:
                path = [route]
            }
            window.requestedRoute = nil
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("split")) } action: { detail = $0 }
    }
}

extension EnvironmentValues {
    /// The height the floating player bar covers at the bottom of the page, where it floats over it (iPad).
    @Entry var playerBarInset: CGFloat = 0
}

/// The iPhone's tabs: Library, Shelf, Settings and Search.
struct TabRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    @Binding var tab: AppTab
    @State private var path: [LibraryRoute] = []

    var body: some View {
        TabView(selection: $tab) {
            Tab("Library", systemImage: "music.note.house", value: AppTab.library) {
                NavigationStack(path: $path) {
                    LibraryHome().libraryDestinations()
                }
                .debugOpenAlbum(path: $path)
            }
            Tab(SidebarItem.shelf.title, systemImage: SidebarItem.shelf.symbol, value: AppTab.shelf) { ShelfView() }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { SettingsView() }
            Tab(value: AppTab.search, role: .search) { SearchView() }
        }
        .tabViewStyle(.sidebarAdaptable)
        // An album or artist asked for from Now Playing or the mini player: on the Library tab.
        .onChange(of: window.requestedRoute) { _, route in
            guard let route else { return }
            tab = .library
            path = [route]
            window.requestedRoute = nil
        }
        .tabViewBottomAccessory(isEnabled: model.nowPlaying != nil) {
            if let item = model.nowPlaying {
                MiniPlayer(item: item) { window.isShowingNowPlaying = true }
            }
        }
    }
}

/// The song playing, in the tab view's bottom accessory: tap opens Now Playing.
struct MiniPlayer: View {
    @Environment(AppModel.self) private var model
    let item: NowPlayingItem
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Cover(hash: item.artworkHash, size: 32, corner: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Group {
                    if model.isRemote {
                        Text("\(Image(systemName: "hifispeaker.fill")) \(model.targetName) · \(item.artist)")
                    } else {
                        // Each part opens its page.
                        SongLinks(item: item, oneLine: true)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { model.togglePlayPause() } label: {
                Label(item.isPlaying ? "Pause" : "Play", systemImage: item.isPlaying ? "pause.fill" : "play.fill")
            }
            .labelStyle(.iconOnly)
            Button { model.next() } label: { Label("Next", systemImage: "forward.fill") }
                .labelStyle(.iconOnly)
        }
        .tint(.primary)
        .padding(.horizontal, 12)
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .accessibilityAction(named: "Open Now Playing", open)
    }
}

extension View {
    /// `-GLDebugOpenAlbum <title>` opens that album's page (here, or on the Mac when it is not here), for layout checks.
    func debugOpenAlbum(path: Binding<[LibraryRoute]>) -> some View {
        modifier(DebugOpenAlbum(path: path))
    }
}

private struct DebugOpenAlbum: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var path: [LibraryRoute]

    func body(content: Content) -> some View {
        #if DEBUG
        content.task {
            // `-GLDebugOpenGenre <name>` opens that genre's songs.
            if let genre = UserDefaults.standard.string(forKey: "GLDebugOpenGenre") {
                path = [.genre(genre)]
                return
            }
            guard let title = UserDefaults.standard.string(forKey: "GLDebugOpenAlbum") else { return }
            for _ in 0..<40 {
                if !model.library.isEmpty, let album = model.catalog.albums().first(where: { $0.title == title }) {
                    path = [model.catalog.isHere(album: album.key) ? .album(album.key) : .macAlbum(album.key)]
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        #else
        content
        #endif
    }
}
