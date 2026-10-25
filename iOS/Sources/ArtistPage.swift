import LibraryKit
import SwiftUI

// Artists where there is room, as on the Mac: the artist list as a column of its own between the sidebar and the page,
// and the artist's page with their photo beside their name, then each album with its cover beside its songs.

/// The artist list column: this device's artists, or with Downloaded off the Mac's too. Compilations first, as on the Mac.
struct ArtistColumn: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?

    struct Entry: Identifiable {
        var name: String
        var albums: Int
        var artworkHash: String?
        var id: String { name }
    }

    private var entries: [Entry] {
        let catalog = model.catalog
        if catalog.showsMac {
            let compilations = catalog.compilations
            return (compilations.isEmpty ? [] : [Entry(name: ArtistSummary.compilations, albums: compilations.count, artworkHash: nil)])
                + catalog.artists.map { Entry(name: $0.name, albums: $0.albums, artworkHash: $0.artworkHash) }
        }
        let contents = model.library.contents
        return ((contents.compilations.map { [$0] } ?? []) + contents.artists)
            .map { Entry(name: $0.name, albums: $0.albumCount, artworkHash: model.library.artistPhoto($0.name) ?? $0.artworkHash) }
    }

    var body: some View {
        let entries = entries
        let catalog = model.catalog
        List(entries, selection: $selection) { entry in
            HStack(spacing: 12) {
                Group {
                    if entry.name == ArtistSummary.compilations {
                        CompilationsArtwork()
                    } else if catalog.showsMac {
                        CatalogCover(hash: entry.artworkHash, size: 40, corner: 20)
                    } else {
                        Cover(hash: entry.artworkHash, size: 40, corner: 20, symbol: "music.microphone")
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(.circle)
                VStack(alignment: .leading) {
                    Text(ArtistSummary.displayName(entry.name)).lineLimit(1)
                    Text(entry.albums == 1 ? "1 album" : "\(entry.albums) albums").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if catalog.showsMac, entry.name != ArtistSummary.compilations {
                    if catalog.isWaiting(artist: entry.name) {
                        AvailabilityMark(availability: .waiting)
                    } else if catalog.isHere(artist: entry.name) {
                        AvailabilityMark(availability: .onDevice)
                    }
                }
            }
            .tag(entry.name)
        }
        .overlay {
            if entries.isEmpty {
                if catalog.showsMac, catalog.catalog == nil { MacLibraryUnavailable() } else { ContentUnavailableView("No Artists", systemImage: "music.microphone") }
            }
        }
        .navigationTitle("Artists")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { DownloadedToggle() } }
        .safeAreaInset(edge: .top, spacing: 0) { if catalog.showsMac { CatalogNotice() } }
        .refreshable { if catalog.showsMac { await catalog.refresh() } }
        .task(id: catalog.showsMac ? model.sync.mac?.id : nil) { if catalog.showsMac { await catalog.refresh() } }
        // As on the Mac, an artist is always shown: the first one, or the one with that name whatever its case.
        .onChange(of: entries.map(\.name), initial: true) { _, names in
            if let wanted = selection, !names.contains(wanted) {
                selection = names.first { $0.caseInsensitiveCompare(wanted) == .orderedSame }
                    ?? (wanted.caseInsensitiveCompare("Various Artists") == .orderedSame && names.first == ArtistSummary.compilations ? names.first : nil)
            }
            if selection == nil { selection = names.first }
        }
    }
}

/// An artist's page as on the Mac: their photo beside their name, their numbers, Play and Shuffle; then each album with
/// its cover beside its songs. With Downloaded off, the Mac's albums too (bring them here from it).
struct ArtistPage: View {
    @Environment(AppModel.self) private var model
    let name: String
    @State private var width: CGFloat = 900

    private var isCompilations: Bool { name == ArtistSummary.compilations }

    var body: some View {
        let catalog = model.catalog
        let local = model.library.read { try LibraryDatabase.albums($0, sort: .year, artist: name) } ?? []
        let mac = catalog.showsMac ? catalog.albums(artist: name) : []
        let tracks = local.flatMap { album in model.library.read { try LibraryDatabase.tracks($0, albumKey: album.albumKey) } ?? [] }
        let albumCount = catalog.showsMac ? mac.count : local.count
        let songCount = catalog.showsMac ? mac.reduce(0) { $0 + catalog.songsAnywhere(album: $1.key).count } : tracks.count
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Group {
                    if width >= 560 {
                        HStack(alignment: .bottom, spacing: 28) { photo(local: local, mac: mac); header(albums: albumCount, songs: songCount, tracks: tracks) }
                    } else {
                        VStack(alignment: .leading, spacing: 20) { photo(local: local, mac: mac); header(albums: albumCount, songs: songCount, tracks: tracks) }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                LazyVStack(alignment: .leading, spacing: 44) {
                    if catalog.showsMac {
                        ForEach(mac, id: \.key) { MacArtistAlbumSection(album: $0) }
                    } else {
                        ForEach(local) { LocalArtistAlbumSection(album: $0) }
                    }
                }
            }
            .padding(28)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle(ArtistSummary.displayName(name))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func photo(local: [AlbumSummary], mac: [DeviceCatalog.Album]) -> some View {
        Group {
            if isCompilations {
                CompilationsArtwork()
            } else if model.catalog.showsMac {
                CatalogCover(hash: model.catalog.photo(of: name) ?? mac.first?.artworkHash, size: 220, corner: 110)
            } else {
                Cover(hash: model.library.artistPhoto(name) ?? local.first?.artworkHash, size: 220, corner: 110, large: true, symbol: "music.microphone")
            }
        }
        .frame(width: 220, height: 220)
        .clipShape(.circle)
        .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
    }

    private func header(albums: Int, songs: Int, tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ArtistSummary.displayName(name)).font(.system(size: 34, weight: .bold)).lineLimit(2)
            Text("\(albums == 1 ? "1 album" : "\(albums) albums"), \(songs == 1 ? "1 song" : "\(songs) songs")").foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { model.play(tracks) } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(.glassProminent)
                Button { model.play(tracks, shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                    .buttonStyle(.glass)
                    // What is here plays; the Mac's albums are brought here first.
                    .disabled(tracks.isEmpty)
                if model.catalog.showsMac, !isCompilations { ArtistTransferButton(name: name) }
            }
            .controlSize(.large)
            .disabled(tracks.isEmpty && !model.catalog.showsMac)
            .padding(.top, 4)
            if model.catalog.isWaiting(artist: name) {
                Text("Waiting for the Mac").font(.subheadline.weight(.medium)).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.bottom, 24)
    }
}

/// Bring all of an artist's albums here (with the ones added on the Mac later), or let them go.
struct ArtistTransferButton: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        let catalog = model.catalog
        if !catalog.holdsEverything {
            if catalog.isChosen(artist: name) {
                Button(role: .destructive) { catalog.request(.remove, .artist, key: name) } label: {
                    Text(catalog.isWaiting(artist: name) ? "Cancel" : "Remove Artist from This Device")
                }
                .buttonStyle(.glass)
            } else {
                Menu {
                    FormatChoices(title: "Add As") { catalog.request(.add, .artist, key: name, encoding: $0) }
                } label: {
                    Label("Add Artist to This Device", systemImage: "arrow.down.circle")
                } primaryAction: {
                    catalog.request(.add, .artist, key: name)
                }
                .buttonStyle(.glass)
            }
        }
    }
}

/// The Compilations entry's picture: stacked albums on the app's colour, as on the Mac.
struct CompilationsArtwork: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: proxy.size.width * 0.42, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityLabel("Compilations")
    }
}

/// An album on its artist's page: the cover on the left; title, genre and year, its buttons and the songs on the
/// right (under the cover where the page is narrow), as on the Mac.
private struct ArtistAlbumLayout<CoverView: View, Buttons: View, Songs: View>: View {
    let title: String
    let subtitle: String
    let route: LibraryRoute
    @ViewBuilder let cover: (CGFloat) -> CoverView
    @ViewBuilder let buttons: Buttons
    @ViewBuilder let songs: Songs
    @State private var width: CGFloat = 900

    var body: some View {
        let sideBySide = width >= 560
        let size = sideBySide ? min(320, width * 0.32) : min(260, width)
        Group {
            if sideBySide {
                HStack(alignment: .top, spacing: 32) { coverLink(size); details }
            } else {
                VStack(alignment: .leading, spacing: 18) { coverLink(size); details }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func coverLink(_ size: CGFloat) -> some View {
        NavigationLink(value: route) {
            cover(size).frame(width: size, height: size).shadow(color: .black.opacity(0.25), radius: 10, y: 5)
                .hoverEffect(.lift)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(title)")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    NavigationLink(value: route) {
                        Text(title).font(.system(size: 22, weight: .bold)).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) { buttons }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
            }
            Divider()
            songs
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An album here, with its songs (a tap plays from there).
private struct LocalArtistAlbumSection: View {
    @Environment(AppModel.self) private var model
    let album: AlbumSummary
    @State private var isRemoving = false

    var body: some View {
        let tracks = model.library.read { try LibraryDatabase.tracks($0, albumKey: album.albumKey) } ?? []
        ArtistAlbumLayout(title: album.title, subtitle: [album.genre, album.year.map(String.init)].compactMap(\.self).joined(separator: " · "),
                          route: .album(album.albumKey)) { size in
            Cover(hash: album.artworkHash, size: size, corner: 8, large: true)
        } buttons: {
            Button { model.play(tracks) } label: { Label("Play", systemImage: "play.fill") }
            Button { model.play(tracks, shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }
            Menu {
                AddToPlaylistMenu(trackIds: tracks.compactMap(\.id), title: "Add Album to Playlist")
                if model.sync.isPaired {
                    NavigationLink(value: LibraryRoute.macAlbum(album.albumKey)) {
                        Label("Format and Songs on the Mac", systemImage: "desktopcomputer")
                    }
                    Divider()
                    Button("Remove from This Device", systemImage: "minus.circle", role: .destructive) { isRemoving = true }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        } songs: {
            VStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    Button { model.play(tracks, startAt: index) } label: {
                        SongRow(track: track, showsNumber: true, isCurrent: model.currentSongId == track.id).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .draggable(SongsTransfer(ids: track.id.map { [$0] } ?? []))
                    .contextMenu { SongMenu(track: track) }
                    if index < tracks.count - 1 { Divider().padding(.leading, 36) }
                }
            }
        }
        .confirmationDialog("Remove “\(album.title)” from This Device?", isPresented: $isRemoving, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { model.catalog.request(.remove, .album, key: album.albumKey) }
        } message: {
            Text("Its songs are deleted from this device at the next sync. Your Mac's library keeps everything.")
        }
    }
}

/// An album of the Mac's library (or here): its songs, each to bring here on its own, and the album to bring or let go.
private struct MacArtistAlbumSection: View {
    @Environment(AppModel.self) private var model
    let album: DeviceCatalog.Album

    var body: some View {
        let catalog = model.catalog
        let here = catalog.isHere(album: album.key)
        let songs = catalog.songsAnywhere(album: album.key)
        let availability = catalog.availability(album: album)
        let tracks = here ? model.library.read { try LibraryDatabase.tracks($0, albumKey: album.key) } ?? [] : []
        let genre = songs.lazy.compactMap(\.genre).first
        ArtistAlbumLayout(title: album.title, subtitle: [genre, album.year.map(String.init)].compactMap(\.self).joined(separator: " · "),
                          route: here ? .album(album.key) : .macAlbum(album.key)) { size in
            CatalogCover(hash: album.artworkHash, size: size, corner: 8)
        } buttons: {
            if here {
                Button { model.play(tracks) } label: { Label("Play", systemImage: "play.fill") }
                Button { model.play(tracks, shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }
            }
            if availability == .onMac || availability == .leaving {
                Menu {
                    FormatChoices(title: "Add As") { catalog.request(.add, .album, key: album.key, encoding: $0) }
                } label: {
                    Label("Add \(album.title) to This Device", systemImage: "arrow.down")
                } primaryAction: {
                    catalog.request(.add, .album, key: album.key)
                }
            } else if !here {
                AvailabilityMark(availability: availability).font(.title2)
            }
            Menu {
                NavigationLink(value: LibraryRoute.macAlbum(album.key)) {
                    Label("Format and Songs on the Mac", systemImage: "desktopcomputer")
                }
                if catalog.canRemove(album: album) {
                    Divider()
                    Button("Remove from This Device", systemImage: "minus.circle", role: .destructive) {
                        catalog.request(.remove, .album, key: album.key)
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        } songs: {
            VStack(spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    MergedSongRow(song: song, showsCover: false).padding(.vertical, 8)
                    if index < songs.count - 1 { Divider().padding(.leading, 36) }
                }
            }
        }
    }
}

/// An artist's page in any stack: the Mac's layout where there is room, the phone's list where there is not.
struct ArtistDestination: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    let name: String
    /// Asked for as an artist of the Mac's library (not here).
    var onMac = false

    var body: some View {
        if sizeClass == .regular {
            ArtistPage(name: name)
        } else if onMac || (model.catalog.showsMac && !model.catalog.isHere(artist: name)) {
            MacArtistView(name: name)
        } else {
            ArtistDetail(name: name)
        }
    }
}
