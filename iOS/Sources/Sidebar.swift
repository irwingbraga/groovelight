import LibraryKit
import SwiftUI

/// The places of the app, as the Mac's sidebar lists them (same names, same symbols, same order): Search; Library
/// (Recently Added, Artists, Albums, Songs, Genres); Explore (Shelf); Playlists (All Playlists, Loved Songs, each
/// playlist).
enum SidebarItem: Hashable {
    case search
    case recentlyAdded, artists, albums, songs, genres
    case shelf
    case allPlaylists, lovedSongs
    case playlist(Int64)

    static let library: [SidebarItem] = [.recentlyAdded, .artists, .albums, .songs, .genres]

    var title: String {
        switch self {
        case .search: "Search"
        case .recentlyAdded: "Recently Added"
        case .artists: "Artists"
        case .albums: "Albums"
        case .songs: "Songs"
        case .genres: "Genres"
        case .shelf: "Shelf"
        case .allPlaylists: "All Playlists"
        case .lovedSongs: "Loved Songs"
        case .playlist: "Playlist"
        }
    }

    /// The Mac sidebar's symbols.
    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .recentlyAdded: "clock"
        case .artists: "music.microphone"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .genres: "guitars"
        case .shelf: "rectangle.stack.badge.play"
        case .allPlaylists: "square.grid.2x2"
        case .lovedSongs: "heart.fill"
        case .playlist: "music.note.list"
        }
    }
}

/// Where a tap in the library goes.
enum LibraryRoute: Hashable {
    case album(String)
    case artist(String)
    case playlist(Int64)
    case genre(String)
    case section(SidebarItem)
    case macAlbum(String)
    case macArtist(String)
}

extension View {
    /// The pages a library list opens, in any navigation stack.
    func libraryDestinations() -> some View {
        navigationDestination(for: LibraryRoute.self) { route in
            switch route {
            case .album(let key): AlbumDetail(albumKey: key)
            case .artist(let name): ArtistDestination(name: name)
            case .playlist(let id): PlaylistDetail(playlistId: id)
            case .genre(let name): GenreDetail(genre: name)
            case .section(let item): SidebarItemContent(item: item)
            case .macAlbum(let key): MacAlbumView(albumKey: key)
            case .macArtist(let name): ArtistDestination(name: name, onMac: true)
            }
        }
    }
}

/// A sidebar item's page, without its navigation stack (the sidebar's detail or the iPhone's Library stack holds it).
/// With Downloaded off, Recently Added, Albums, Artists and Songs show the Mac's music with this device's.
struct SidebarItemContent: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem

    var body: some View {
        let contents = model.library.contents
        let filtered = [.recentlyAdded, .albums, .artists, .songs, .genres].contains(item)
        Group {
            if filtered, model.catalog.showsMac {
                MergedLibrarySection(item: item)
            } else if model.library.isEmpty, item != .search, item != .shelf {
                EmptyLibrary()
            } else {
                switch item {
                case .search: SearchResults()
                case .recentlyAdded: AlbumGrid(albums: contents.recentlyAdded)
                case .albums: AlbumGrid(albums: contents.albums)
                case .artists: ArtistList(artists: contents.artists, compilations: contents.compilations)
                case .songs: SongList(tracks: contents.songs, showsArtwork: true, indexed: true)
                case .genres: GenreList()
                case .shelf: ShelfContent()
                case .allPlaylists: PlaylistList(playlists: contents.playlists, lovedCount: contents.lovedCount)
                case .lovedSongs: LovedSongs()
                case .playlist(let id): PlaylistDetail(playlistId: id)
                }
            }
        }
        .navigationTitle(titleOf(item))
        .toolbar {
            if filtered { ToolbarItem(placement: .topBarTrailing) { DownloadedToggle() } }
        }
    }

    private func titleOf(_ item: SidebarItem) -> String {
        if case .playlist(let id) = item { return model.library.contents.playlists.first { $0.id == id }?.playlist.name ?? "Playlist" }
        return item.title
    }
}

/// The sidebar where there is room (iPad, the iPhone Duo's inner display), as on the Mac: Search, Library, Explore and
/// Playlists, with syncing and Settings at the bottom (where the Mac has New Playlist).
struct LibrarySidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            SidebarRow(item: .search).tag(SidebarItem.search)
            Section("Library") {
                ForEach(SidebarItem.library, id: \.self) { item in
                    SidebarRow(item: item).tag(item)
                }
            }
            Section("Explore") {
                SidebarRow(item: .shelf).tag(SidebarItem.shelf)
            }
            Section("Playlists") {
                SidebarRow(item: .allPlaylists).tag(SidebarItem.allPlaylists)
                // Songs dropped here are loved, or added to the playlist (not a smart one: its rules fill it), as on the Mac.
                SidebarRow(item: .lovedSongs).tag(SidebarItem.lovedSongs)
                    .dropDestination(for: SongsTransfer.self) { items, _ in
                        for id in items.flatMap(\.ids) { model.library.setLoved(true, trackId: id) }
                        return true
                    }
                ForEach(model.library.contents.playlists) { summary in
                    PlaylistSidebarRow(summary: summary).tag(SidebarItem.playlist(summary.id))
                        .dropDestination(for: SongsTransfer.self) { items, _ in
                            guard !summary.playlist.isSmart else { return false }
                            model.library.addToPlaylist(summary.id, trackIds: items.flatMap(\.ids))
                            return true
                        }
                }
            }
        }
        .navigationTitle("Groovelight")
        .toolbar(removing: .title)
        .safeAreaBar(edge: .bottom) { SidebarFooter() }
    }
}

/// A sidebar item: its symbol (Loved Songs' heart in pink, as on the Mac) and its name.
struct SidebarRow: View {
    let item: SidebarItem

    var body: some View {
        Label {
            Text(item.title)
        } icon: {
            if item == .lovedSongs {
                Image(systemName: item.symbol).foregroundStyle(.pink)
            } else {
                Image(systemName: item.symbol)
            }
        }
    }
}

/// A playlist with its cover as the icon, as in the Mac's sidebar.
struct PlaylistSidebarRow: View {
    let summary: PlaylistSummary

    var body: some View {
        Label {
            Text(summary.playlist.name).lineLimit(1)
        } icon: {
            summary.coverView(hidesTitle: true, cornerRadius: 4).frame(width: 22, height: 22)
        }
    }
}

/// The bottom of the sidebar: the Mac this device syncs with (and Sync), and Settings.
struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window

    var body: some View {
        let sync = model.sync
        HStack(spacing: 10) {
            Group {
                if let mac = sync.mac {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mac.name).font(.footnote.weight(.semibold)).lineLimit(1)
                        Group {
                            if case let .syncing(done, total, _) = sync.phase {
                                Text(total > 0 ? "Syncing \(done) of \(total)…" : "Syncing…")
                            } else if case .failed = sync.phase {
                                Text("Sync failed")
                            } else if let date = sync.lastSync {
                                Text("Synced \(date, format: .relative(presentation: .named))")
                            } else {
                                Text("Not synced yet")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                } else {
                    Button("Pair with Your Mac") { window.isPairing = true }
                        .font(.footnote.weight(.semibold))
                }
            }
            Spacer(minLength: 0)
            if sync.isPaired {
                if sync.isSyncing {
                    Button { sync.cancelSync() } label: { Label("Stop Syncing", systemImage: "stop.circle") }
                } else {
                    Button { sync.syncNow() } label: { Label("Sync Now", systemImage: "arrow.triangle.2.circlepath") }
                }
            }
            Button { window.isShowingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// The iPhone's Library tab: the sidebar's Library and Playlists, as a list (Search and Shelf are tabs there).
struct LibraryHome: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            // Nothing here yet: the way to music first, above the (empty) places, not over them.
            if model.library.isEmpty, !model.catalog.showsMac {
                Section { EmptyLibrary().listRowBackground(Color.clear) }
            }
            Section {
                ForEach(SidebarItem.library, id: \.self) { item in
                    NavigationLink(value: LibraryRoute.section(item)) { SidebarRow(item: item) }
                }
            }
            Section("Playlists") {
                NavigationLink(value: LibraryRoute.section(.allPlaylists)) { SidebarRow(item: .allPlaylists) }
                NavigationLink(value: LibraryRoute.section(.lovedSongs)) { SidebarRow(item: .lovedSongs) }
                ForEach(model.library.contents.playlists) { summary in
                    NavigationLink(value: LibraryRoute.playlist(summary.id)) { PlaylistSidebarRow(summary: summary) }
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { DownloadedToggle() }
            ToolbarItem(placement: .primaryAction) { PlaybackTargetButton() }
            SyncButton()
        }
    }
}

/// Genres, each opening its songs.
struct GenreList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let genres = model.library.read { try LibraryDatabase.genres($0) } ?? []
        List(genres, id: \.self) { genre in
            NavigationLink(value: LibraryRoute.genre(genre)) {
                Label(genre, systemImage: "guitars")
            }
        }
        .listStyle(.plain)
        .overlay {
            if genres.isEmpty { ContentUnavailableView("No Genres", systemImage: "guitars") }
        }
        .id(model.library.contents.songs.count)
    }
}

/// A genre's songs, to play or shuffle (those here); with Downloaded off, the Mac's too.
struct GenreDetail: View {
    @Environment(AppModel.self) private var model
    let genre: String

    var body: some View {
        let tracks = model.library.read { try LibraryDatabase.tracks($0, genre: genre) } ?? []
        Group {
            if model.catalog.showsMac {
                MergedSongList(songs: model.catalog.songs(genre: genre), showsCover: true)
            } else {
                SongList(tracks: tracks, showsArtwork: true)
            }
        }
        .safeAreaInset(edge: .top) {
            PlayShuffleButtons(tracks: tracks).padding(.horizontal).padding(.bottom, 8)
        }
        .navigationTitle(genre)
    }
}
