import LibraryKit
import MetadataKit
import PlayerCore
import SwiftUI

/// The artist list, a column of its own between the sidebar and the page (like Music). Side by side in one column, the
/// two scroll views under the same toolbar made it flicker whenever the page redrew while scrolled.
struct ArtistListColumn: View {
    @Environment(AppModel.self) private var model
    @State private var artists: [ArtistSummary] = []
    /// Artist photos by lowercased name (artists looked up so far).
    @State private var photos: [String: String] = [:]

    var body: some View {
        @Bindable var model = model
        // Custom list instead of List(selection:): setting the initial selection while an outline table loads its
        // rows crashes SwiftUI (AttributeGraph precondition) when the window is not key.
        SelectableList(items: artists, id: \.name, selection: $model.selectedArtist, scrollsToSelection: true) { artist in
            HStack(spacing: 10) {
                // The artist's photo when known, otherwise one of their album covers.
                ArtworkImage(hash: photos[artist.name.lowercased()] ?? artist.artworkHash, size: .small, cornerRadius: 20)
                    .frame(width: 40, height: 40)
                    .clipShape(.circle)
                VStack(alignment: .leading) {
                    Text(artist.name).lineLimit(1)
                    Text(artist.albumCount == 1 ? "1 album" : "\(artist.albumCount) albums")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .navigationTitle("Artists")
        .observing(model.database, id: 0, { try LibraryDatabase.artists($0) }) { value in
            artists = value
            // Names coming from other pages may differ in case from the grouped artist name.
            if let wanted = model.selectedArtist, !value.contains(where: { $0.name == wanted }) {
                model.selectedArtist = value.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }?.name
            }
            if model.selectedArtist == nil { model.selectedArtist = value.first?.name }
        }
        .observing(model.database, id: "photos", { db in
            try LibraryDatabase.allArtistInfo(db).compactMap { row -> (String, String)? in
                (try? JSONDecoder().decode(ArtistInfo.self, from: row.data))?.imageHash.map { (row.artistKey, $0) }
            }
        }) { pairs in
            photos = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        }
    }
}

/// The Artists page: the artist chosen in the list column.
struct ArtistsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let selected = model.selectedArtist {
                ArtistDetailView(artist: selected)
            } else {
                ContentUnavailableView("Select an Artist", systemImage: "music.microphone")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(model.selectedArtist ?? "Artists")
    }
}

struct ArtistDetailView: View {
    var artist: String
    @Environment(AppModel.self) private var model
    @State private var albums: [ArtistAlbum] = []
    @State private var info: ArtistInfo?
    @State private var pageWidth: CGFloat = 900

    /// One of the artist's albums with its songs.
    struct ArtistAlbum: Identifiable, Sendable {
        var album: AlbumSummary
        var tracks: [Track]
        var id: String { album.albumKey }
    }

    /// The artist's photo, or their first album's cover until a photo is known.
    private var headerImage: String? { info?.imageHash ?? albums.first?.album.artworkHash }
    private var allTracks: [Track] { albums.flatMap(\.tracks) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Side by side when there is room, stacked in narrow windows. Decided from the page width, not with
                // ViewThatFits: that re-measured (and rebuilt) the large photo on every layout pass, such as hovering a
                // song, and the toolbar's glass flickered as it re-sampled the page.
                // The header never asks for more width than the page has: its minimum width resized the page, which
                // switched the layout back and forth until AppKit gave up, in a window at its minimum size.
                Group {
                    if pageWidth >= 760 {
                        HStack(alignment: .bottom, spacing: 28) {
                            photo
                            title
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 20) {
                            photo
                            title
                        }
                    }
                }
                .frame(minWidth: 0, alignment: .leading)
                // Each album like Music's artist pages: cover on the left, its songs on the right.
                LazyVStack(alignment: .leading, spacing: 44) {
                    ForEach(albums) { entry in
                        ArtistAlbumSection(album: entry.album, tracks: entry.tracks)
                    }
                }
            }
            .padding(28)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        .observing(model.database, id: artist, { [artist] db in
            try LibraryDatabase.albums(db, sort: .year, artist: artist).map { album in
                ArtistAlbum(album: album, tracks: try LibraryDatabase.tracks(db, albumKey: album.albumKey))
            }
        }) { albums = $0 }
        .observing(model.database, id: "info-\(artist)", { [artist] db in try LibraryDatabase.artistInfo(db, name: artist)?.data }) { data in
            info = data.flatMap { try? JSONDecoder().decode(ArtistInfo.self, from: $0) }
        }
        .task(id: artist) { await model.metadata.loadArtistInfo(name: artist) }
    }

    private var photo: some View {
        VStack(spacing: 6) {
            ArtworkImage(hash: headerImage, size: .large, cornerRadius: 0)
                .frame(width: 220, height: 220)
                .clipShape(.circle)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
            if info?.imageHash != nil, let url = info?.about?.url {
                // Commons photos have various open licenses: credit and link to the source article.
                Link("Photo: Wikimedia Commons", destination: url)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(artist)
                .font(.system(size: 34, weight: .bold))
                .lineLimit(2)
            let songs = allTracks.count
            Text("\(albums.count == 1 ? "1 album" : "\(albums.count) albums"), \(songs == 1 ? "1 song" : "\(songs) songs")")
                .foregroundStyle(.secondary)
            if let about = info?.about {
                AboutExcerpt(about: about)
            } else if model.metadata.artistInfoInFlight.contains(artist) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Looking up artist info…")
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                Button { model.play(allTracks) } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(.glassProminent)
                Button { model.play(allTracks, shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                    .buttonStyle(.glass)
            }
            .controlSize(.large)
            .disabled(albums.isEmpty)
            .padding(.top, 4)
        }
        .padding(.bottom, 24)
    }
}

/// An album on its artist's page: the cover on the left; title, genre and year, actions and the songs on the right
/// (stacked under the cover when the page is narrow).
private struct ArtistAlbumSection: View {
    var album: AlbumSummary
    var tracks: [Track]
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 900

    var body: some View {
        let sideBySide = width >= 720
        let coverSize = sideBySide ? min(320, width * 0.32) : min(260, width)
        Group {
            if sideBySide {
                HStack(alignment: .top, spacing: 32) {
                    cover(coverSize)
                    details
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    cover(coverSize)
                    details
                }
            }
        }
        // Like the page header: the layout must not widen what it is measured from.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func cover(_ size: CGFloat) -> some View {
        NavigationLink(value: AppModel.Route.album(album)) {
            ArtworkImage(hash: album.artworkHash, size: .large, cornerRadius: 8)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .help("Show \(album.title)")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    NavigationLink(value: AppModel.Route.album(album)) {
                        Text(album.title)
                            .font(.system(size: 22, weight: .bold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    let subtitle = [album.genre, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Button { model.playAlbum(album) } label: { Image(systemName: "play.fill").frame(width: 18, height: 18) }
                        .help("Play")
                    Button { model.playAlbum(album, shuffle: true) } label: { Image(systemName: "shuffle").frame(width: 18, height: 18) }
                        .help("Shuffle")
                    Menu {
                        QueueMenuItems(source: .album(album.albumKey))
                        Divider()
                        Button("Get Info…") { model.getInfo(albumKey: album.albumKey) }
                        Button("Fix Metadata…") { model.metadata.review(tracks) }
                        Button("Show in Finder") { model.showInFinder(tracks) }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 18, height: 18)
                    }
                    .menuIndicator(.hidden)
                    .help("More")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }
            Divider()
            TrackList(tracks: tracks, style: .album, albumKey: album.albumKey)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SongsView: View {
    @Environment(AppModel.self) private var model
    @State private var tracks: [Track] = []
    @State private var selection: Set<Track.ID> = []
    @State private var sortOrder = [KeyPathComparator(\Track.title, comparator: .localizedStandard)]

    var body: some View {
        Table(tracks, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { track in
                if model.player.current?.id == track.id {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.brand)
                } else if track.isLoved {
                    Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption)
                }
            }
            .width(18)
            TableColumn("Title", value: \.title, comparator: .localizedStandard) { track in
                SongTitleCell(track: track, isSelected: selection.contains(track.id)) { menuTracks(for: track) }
            }
            .width(min: 160, ideal: 280)
            TableColumn("Artist", value: \.displayArtist, comparator: .localizedStandard)
                .width(min: 100, ideal: 180)
            TableColumn("Album", value: \.displayAlbum, comparator: .localizedStandard)
                .width(min: 100, ideal: 180)
            TableColumn("Genre") { Text($0.genre ?? "") }
                .width(min: 60, ideal: 100)
            TableColumn("Time", value: \.duration) { Text(formatDuration($0.duration)).monospacedDigit() }
                .width(60)
            TableColumn("Plays", value: \.playCount) { Text($0.playCount == 0 ? "" : "\($0.playCount)").monospacedDigit() }
                .width(44)
            TableColumn("Quality", value: \.qualityRank) { track in
                let spec = track.audioSpec
                HStack(spacing: 6) {
                    QualityBadge(tier: spec.tier, isMini: true)
                    Text(spec.compactText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .help(spec.tier == .standard ? spec.summary : "\(spec.tier.displayName) · \(spec.summary)")
            }
            .width(min: 150, ideal: 190)
        }
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            TrackContextMenu(tracks: tracks.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if let first = ids.first, let index = tracks.firstIndex(where: { $0.id == first }) {
                model.play(tracks, startAt: index)
            }
        }
        .onChange(of: sortOrder) { tracks.sort(using: sortOrder) }
        .navigationTitle("Songs")
        .navigationSubtitle("\(tracks.count) songs")
        .observing(model.database, id: 0, { try LibraryDatabase.allTracks($0) }) { value in
            tracks = value.sorted(using: sortOrder)
        }
    }

    /// The selected songs when `track` is part of a multi-selection, otherwise just `track`.
    private func menuTracks(for track: Track) -> [Track] {
        guard selection.contains(track.id), selection.count > 1 else { return [track] }
        return tracks.filter { selection.contains($0.id) }
    }
}

/// Title cell of the Songs table, with the "⋯" menu at its trailing edge (shown on hover or selection).
private struct SongTitleCell: View {
    var track: Track
    var isSelected: Bool
    var menuTracks: () -> [Track]
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(track.title).lineLimit(1)
            Spacer(minLength: 4)
            TrackMenuButton(tracks: menuTracks)
                .opacity(isHovering || isSelected ? 1 : 0)
        }
        // Table cells size to their content; fill the column so the button sits at its trailing edge.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }
}

/// The genre list, a column of its own (like the artist list).
struct GenreListColumn: View {
    @Environment(AppModel.self) private var model
    @State private var genres: [String] = []

    var body: some View {
        @Bindable var model = model
        SelectableList(items: genres, id: \.self, selection: $model.selectedGenre) { genre in
            Text(genre)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
        .navigationTitle("Genres")
        .observing(model.database, id: 0, { try LibraryDatabase.genres($0) }) { value in
            genres = value
            if model.selectedGenre == nil || !value.contains(model.selectedGenre ?? "") { model.selectedGenre = value.first }
        }
    }
}

/// The Genres page: the songs of the genre chosen in the list column.
struct GenresView: View {
    @Environment(AppModel.self) private var model
    @State private var tracks: [Track] = []

    var body: some View {
        let selected = model.selectedGenre
        ScrollView {
            if let selected {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(selected).font(.system(size: 28, weight: .bold))
                        Spacer()
                        Button { model.play(tracks, shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                            .buttonStyle(.glassProminent)
                    }
                    TrackList(tracks: tracks, style: .playlist)
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(selected ?? "Genres")
        .observing(model.database, id: selected, { [selected] db in
            guard let selected else { return [] }
            return try LibraryDatabase.tracks(db, genre: selected)
        }) { tracks = $0 }
    }
}

/// Lightweight single-selection list with sidebar-style highlighting.
struct SelectableList<Item, ID: Hashable, Row: View>: View {
    var items: [Item]
    var id: KeyPath<Item, ID>
    @Binding var selection: ID?
    /// Scrolls the selected row into view when the selection is set from elsewhere (e.g. opening an artist).
    var scrollsToSelection = false
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items, id: id) { item in
                        let isSelected = selection == item[keyPath: id]
                        row(item)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(isSelected ? Color.brand.opacity(0.25) : .clear, in: .rect(cornerRadius: 8))
                            .contentShape(.rect)
                            .onTapGesture { selection = item[keyPath: id] }
                    }
                }
                .padding(8)
            }
            .onChange(of: items.count, initial: true) {
                if scrollsToSelection, let selection { proxy.scrollTo(selection, anchor: .center) }
            }
        }
    }
}
