import LibraryKit
import SwiftUI

/// No music yet: pair with the Mac, or sync to bring it.
struct EmptyLibrary: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window

    var body: some View {
        ContentUnavailableView {
            Label("Your music is on your Mac", systemImage: "laptopcomputer.and.iphone")
        } description: {
            if model.sync.isPaired {
                Text(model.sync.isSyncing ? "Syncing with \(model.sync.mac?.name ?? "your Mac")…"
                     : "Turn off Downloaded to see \(model.sync.mac?.name ?? "your Mac")'s library and add music from it, or choose what this device gets on the Mac.")
            } else {
                Text("Pair with Groovelight on your Mac to bring albums and playlists here, with everything Groovelight knows about them.")
            }
        } actions: {
            if !model.sync.isPaired {
                Button("Pair with Your Mac") { window.isPairing = true }
                    .buttonStyle(.glassProminent)
            } else {
                Button("Show the Mac's Music") { model.catalog.downloadedOnly = false }
                    .buttonStyle(.glassProminent)
                if !model.sync.isSyncing {
                    Button("Sync Now") { model.sync.syncNow() }
                }
            }
        }
    }
}

/// Albums as covers, as many columns as fit; pinching changes the size of the covers (kept, as on the Mac).
struct AlbumGrid: View {
    @Environment(AppModel.self) private var model
    let albums: [AlbumSummary]
    /// False inside a page that scrolls already (an artist's).
    var scrolls = true
    @AppStorage("albums.coverSize") private var coverSize: Double = 160
    @State private var pinchStart: Double?

    var body: some View {
        Group {
            if scrolls {
                ScrollView { grid }
            } else {
                grid
            }
        }
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? coverSize
                pinchStart = start
                coverSize = min(max(start * value.magnification, 100), 300)
            }
            .onEnded { _ in pinchStart = nil })
    }

    private var grid: some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: coverSize, maximum: coverSize * 1.4), spacing: 16)], spacing: 20) {
                ForEach(albums) { album in
                    NavigationLink(value: LibraryRoute.album(album.albumKey)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Cover(hash: album.artworkHash, corner: 8)
                                .hoverEffect(.lift)
                            Text(album.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .draggable(SongsTransfer(ids: model.library.read { try LibraryDatabase.tracks($0, albumKey: album.albumKey) }?.compactMap(\.id) ?? []))
                }
            }
            .padding()
    }
}

struct ArtistList: View {
    let artists: [ArtistSummary]
    let compilations: ArtistSummary?

    var body: some View {
        let sections = SectionIndex.sections(artists, by: \.name)
        List {
            // Compilations first, as on the Mac.
            if let compilations {
                NavigationLink(value: LibraryRoute.artist(compilations.name)) {
                    ArtistRow(artist: compilations)
                }
            }
            // The A to Z index on the side, as in Contacts.
            ForEach(sections) { section in
                Section {
                    ForEach(section.items, id: \.element.id) { _, artist in
                        NavigationLink(value: LibraryRoute.artist(artist.name)) {
                            ArtistRow(artist: artist)
                        }
                    }
                }
                .sectionIndexLabel(section.letter)
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(SectionIndex.visibility(count: artists.count, sections: sections.count))
    }
}

struct ArtistRow: View {
    @Environment(AppModel.self) private var model
    let artist: ArtistSummary

    var body: some View {
        HStack(spacing: 12) {
            Cover(hash: model.library.artistPhoto(artist.name) ?? artist.artworkHash, size: 44, corner: 22, symbol: "music.microphone")
            VStack(alignment: .leading) {
                Text(artist.displayName)
                Text(artist.albumCount == 1 ? "1 album" : "\(artist.albumCount) albums").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Songs in order; a tap plays them from there. Sorted by title (Songs), they have the A to Z index on the side.
struct SongList: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]
    var showsArtwork = false
    var showsNumbers = false
    var indexed = false

    var body: some View {
        let sections = indexed ? SectionIndex.sections(tracks, by: \.title) : [IndexSection(id: 0, letter: "", items: Array(tracks.enumerated()))]
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.items, id: \.element.id) { index, track in
                        Button {
                            model.play(tracks, startAt: index)
                        } label: {
                            SongRow(track: track, showsArtwork: showsArtwork, showsNumber: showsNumbers,
                                    isCurrent: model.currentSongId == track.id)
                        }
                        .buttonStyle(.plain)
                        .draggable(SongsTransfer(ids: track.id.map { [$0] } ?? []))
                        .contextMenu { SongMenu(track: track) }
                    }
                }
                .sectionIndexLabel(indexed ? section.letter : nil)
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(indexed ? SectionIndex.visibility(count: tracks.count, sections: sections.count) : .hidden)
    }
}

struct SongRow: View {
    let track: Track
    var showsArtwork = false
    var showsNumber = false
    var isCurrent = false

    var body: some View {
        HStack(spacing: 12) {
            if showsArtwork {
                Cover(hash: track.artworkHash, size: 40, corner: 6)
            } else if showsNumber {
                Text(track.trackNumber.map(String.init) ?? "").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 24, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1).foregroundStyle(isCurrent ? Color.accentColor : .primary)
                if showsArtwork || track.isCompilation || track.artist != track.albumArtist && track.albumArtist != nil {
                    Text(track.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            QualityBadge(tier: track.audioSpec.tier, isMini: true)
            if track.isLoved { Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink) }
            Text(Duration.seconds(track.duration).formatted(.time(pattern: .minuteSecond))).font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }
}

/// Every playlist as a grid of cards, as on the Mac: Loved Songs first, then the playlists by name, each with its
/// cover, name and song count ("Smart Playlist" before it for smart ones); Play and Shuffle on the cover under the
/// pointer (iPad), and in the card's menu.
struct PlaylistList: View {
    @Environment(AppModel.self) private var model
    let playlists: [PlaylistSummary]
    let lovedCount: Int

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)], alignment: .leading, spacing: 20) {
                PlaylistCard(title: "Loved Songs", subtitle: Self.songCount(lovedCount), route: .section(.lovedSongs),
                             play: { shuffle in play(model.library.read { try LibraryDatabase.lovedTracks($0) } ?? [], shuffle: shuffle) }) {
                    LovedSongsCover()
                }
                ForEach(playlists) { summary in
                    let playlist = summary.playlist
                    PlaylistCard(title: playlist.name,
                                 subtitle: playlist.isSmart ? "Smart Playlist · \(Self.songCount(summary.trackCount))" : Self.songCount(summary.trackCount),
                                 route: .playlist(summary.id),
                                 play: { shuffle in
                                     play(model.library.read { try LibraryDatabase.tracks($0, playlistId: summary.id) } ?? [], shuffle: shuffle)
                                 }) {
                        summary.coverView()
                    }
                    // Songs dropped on a playlist are added to it (not a smart one: its rules fill it), as in the sidebar.
                    .dropDestination(for: SongsTransfer.self) { items, _ in
                        guard !playlist.isSmart else { return false }
                        model.library.addToPlaylist(summary.id, trackIds: items.flatMap(\.ids))
                        return true
                    }
                }
            }
            .padding()
        }
        .navigationTitle("All Playlists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { NewPlaylistButton() }
        }
    }

    private func play(_ tracks: [Track], shuffle: Bool) {
        guard !tracks.isEmpty else { return }
        model.play(tracks, shuffle: shuffle)
    }

    static func songCount(_ count: Int) -> String { count == 1 ? "1 song" : "\(count) songs" }
}

/// A playlist in the grid: its cover (Play and Shuffle on it under the pointer, as the Mac's under the mouse), name and
/// song count; a tap opens it, and its menu plays it.
private struct PlaylistCard<CoverView: View>: View {
    let title: String
    let subtitle: String
    let route: LibraryRoute
    let play: (_ shuffle: Bool) -> Void
    @ViewBuilder let cover: () -> CoverView
    @State private var isHovering = false

    var body: some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 4) {
                cover()
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    .overlay(alignment: .bottom) {
                        if isHovering {
                            HStack {
                                Button { play(false) } label: { Image(systemName: "play.fill").frame(width: 18, height: 18) }
                                Spacer()
                                Button { play(true) } label: { Image(systemName: "shuffle").frame(width: 18, height: 18) }
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .padding(8)
                            .transition(.opacity)
                        }
                    }
                    .hoverEffect(.lift)
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering } }
        .contextMenu {
            Button("Play", systemImage: "play") { play(false) }
            Button("Shuffle", systemImage: "shuffle") { play(true) }
        }
    }
}

/// The cover of Loved Songs, as on the Mac: a white heart on pink.
struct LovedSongsCover: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(LinearGradient(colors: [Color(red: 1, green: 0.42, blue: 0.55), Color(red: 0.86, green: 0.12, blue: 0.36)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                GeometryReader { geometry in
                    Image(systemName: "heart.fill")
                        .font(.system(size: geometry.size.width * 0.38))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .aspectRatio(1, contentMode: .fit)
    }
}

struct LovedSongs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tracks = model.library.read { try LibraryDatabase.lovedTracks($0) } ?? []
        SongList(tracks: tracks, showsArtwork: true)
            .overlay {
                if tracks.isEmpty { ContentUnavailableView("No Loved Songs", systemImage: "heart") }
            }
            .id(model.library.contents.lovedCount)
    }
}

// MARK: - Pages

/// An album: its cover, play and shuffle, and its songs by disc.
struct AlbumDetail: View {
    @Environment(AppModel.self) private var model
    let albumKey: String
    @State private var isRemoving = false
    @State private var showsArtist = false

    var body: some View {
        let tracks = model.library.read { try LibraryDatabase.tracks($0, albumKey: albumKey) } ?? []
        let album = model.library.contents.albums.first { $0.albumKey == albumKey }
        List {
            Section {
                VStack(spacing: 12) {
                    Cover(hash: album?.artworkHash, corner: 12, large: true)
                        .frame(maxWidth: 300)
                        .shadow(radius: 12, y: 6)
                    VStack(spacing: 2) {
                        Text(album?.title ?? "").font(.title2.bold()).multilineTextAlignment(.center)
                        if let album {
                            // A button (a link in a list row takes the whole row).
                            Button { showsArtist = true } label: { Text(album.artist).font(.title3) }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                        }
                        Text(Self.details(album, tracks: tracks)).font(.caption).foregroundStyle(.secondary)
                        AlbumQualitySummary(specs: tracks.map(\.audioSpec)).padding(.top, 2)
                    }
                    PlayShuffleButtons(tracks: tracks)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                Button { model.play(tracks, startAt: index) } label: {
                    SongRow(track: track, showsNumber: true, isCurrent: model.currentSongId == track.id)
                }
                .buttonStyle(.plain)
                .draggable(SongsTransfer(ids: track.id.map { [$0] } ?? []))
                .contextMenu { SongMenu(track: track) }
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    AddToPlaylistMenu(trackIds: tracks.compactMap(\.id), title: "Add Album to Playlist")
                    if model.sync.isPaired {
                        // Its page on the Mac: its songs that are not here, and the format it comes in.
                        NavigationLink(value: LibraryRoute.macAlbum(albumKey)) {
                            Label("Format and Songs on the Mac", systemImage: "desktopcomputer")
                        }
                        Divider()
                        Button("Remove from This Device", systemImage: "minus.circle", role: .destructive) { isRemoving = true }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .navigationDestination(isPresented: $showsArtist) {
            if let album { ArtistDestination(name: album.artist) }
        }
        .confirmationDialog("Remove “\(album?.title ?? "")” from This Device?", isPresented: $isRemoving, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { model.catalog.request(.remove, .album, key: albumKey) }
        } message: {
            Text("\(tracks.count == 1 ? "Its song is" : "Its \(tracks.count) songs are") deleted from this device at the next sync, to free its space. Your Mac's library keeps everything; add it again from the Library with Downloaded off.")
        }
    }

    /// "Rock · 1969" (the format is on the quality line under it).
    static func details(_ album: AlbumSummary?, tracks: [Track]) -> String {
        var parts: [String] = []
        if let genre = album?.genre { parts.append(genre) }
        if let year = album?.year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }
}

struct PlayShuffleButtons: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]

    var body: some View {
        HStack(spacing: 12) {
            Button { model.play(tracks) } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
            Button { model.play(tracks, shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .frame(maxWidth: 360)
        .disabled(tracks.isEmpty)
    }
}

/// An artist: their photo and albums.
struct ArtistDetail: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        let albums = model.library.read { try LibraryDatabase.albums($0, artist: name) } ?? []
        ScrollView {
            VStack(spacing: 16) {
                Cover(hash: model.library.artistPhoto(name) ?? albums.first?.artworkHash, size: 160, corner: 80, large: true,
                      symbol: "music.microphone")
                Text(ArtistSummary.displayName(name)).font(.title.bold())
                AlbumGrid(albums: albums, scrolls: false)
            }
            .padding(.top)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PlaylistDetail: View {
    @Environment(AppModel.self) private var model
    let playlistId: Int64

    var body: some View {
        let playlist = model.library.contents.playlists.first { $0.id == playlistId }
        let tracks = model.library.read { try LibraryDatabase.tracks($0, playlistId: playlistId) } ?? []
        List {
            Section {
                VStack(spacing: 12) {
                    playlist?.coverView(cornerRadius: 12)
                        .frame(maxWidth: 260)
                        .shadow(radius: 12, y: 6)
                    VStack(spacing: 2) {
                        Text(playlist?.playlist.name ?? "Playlist").font(.title2.bold()).multilineTextAlignment(.center)
                        Text(tracks.count == 1 ? "1 song" : "\(tracks.count) songs").font(.caption).foregroundStyle(.secondary)
                    }
                    PlayShuffleButtons(tracks: tracks)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
            let editable = playlist.map { !$0.playlist.isSmart } ?? false
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                Button { model.play(tracks, startAt: index) } label: {
                    SongRow(track: track, showsArtwork: true, isCurrent: model.currentSongId == track.id)
                }
                .buttonStyle(.plain)
                .contextMenu { SongMenu(track: track, playlistId: editable ? playlistId : nil) }
            }
            .onDelete(perform: editable ? { offsets in
                model.library.removeFromPlaylist(playlistId, trackIds: offsets.compactMap { tracks[$0].id })
            } : nil)
        }
        .listStyle(.plain)
        .navigationTitle(playlist?.playlist.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let playlist, !playlist.playlist.isSmart {
                ToolbarItem(placement: .primaryAction) { PlaylistActions(summary: playlist) }
            }
        }
    }
}

/// Sync with the Mac: an icon and a title, so it can sit in a vertical bar (icon), a horizontal one, or the overflow
/// menu (both), as iPhone Duo needs.
struct SyncButton: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if model.sync.isSyncing {
                Button { model.sync.cancelSync() } label: {
                    Label { Text("Stop Syncing") } icon: { ProgressView() }
                }
            } else {
                Button {
                    if model.sync.isPaired { model.sync.syncNow() } else { window.isPairing = true }
                } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            }
        }
    }
}
