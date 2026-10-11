import LibraryKit
import MetadataKit
import PlayerCore
import SwiftUI

struct ArtistsView: View {
    @Environment(AppModel.self) private var model
    @State private var artists: [ArtistSummary] = []
    /// Artist photos by lowercased name (artists looked up so far).
    @State private var photos: [String: String] = [:]

    var body: some View {
        @Bindable var model = model
        let selected = model.selectedArtist
        HStack(spacing: 0) {
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
            .frame(width: 250)
            Divider()

            Group {
                if let selected {
                    ArtistDetailView(artist: selected)
                } else {
                    ContentUnavailableView("Select an Artist", systemImage: "music.microphone")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

struct ArtistDetailView: View {
    var artist: String
    @Environment(AppModel.self) private var model
    @State private var albums: [AlbumSummary] = []
    @State private var info: ArtistInfo?

    /// The artist's photo, or their first album's cover until a photo is known.
    private var headerImage: String? { info?.imageHash ?? albums.first?.artworkHash }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Side by side when there is room, stacked in narrow windows.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 28) {
                        photo
                        title
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        photo
                        title
                    }
                }
                AlbumGrid(albums: albums)
            }
            .padding(28)
        }
        // The same color wash as album pages, from the photo (or the cover standing in for it).
        .coverWash { ArtworkImage(hash: headerImage, size: .small, cornerRadius: 0) }
        .observing(model.database, id: artist, { [artist] db in try LibraryDatabase.albums(db, sort: .year, artist: artist) }) { albums = $0 }
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
            Text(albums.count == 1 ? "1 album" : "\(albums.count) albums")
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
            Button {
                Task {
                    do {
                        let tracks = try await model.database.writer.read { [artist] in try LibraryDatabase.tracks($0, artist: artist) }
                        model.play(tracks, shuffle: true)
                    } catch {
                        model.errorMessage = "Could not load \(artist): \(error.localizedDescription)"
                    }
                }
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(.bottom, 24)
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

struct GenresView: View {
    @Environment(AppModel.self) private var model
    @State private var genres: [String] = []
    @State private var selected: String?
    @State private var tracks: [Track] = []

    var body: some View {
        HStack(spacing: 0) {
            SelectableList(items: genres, id: \.self, selection: $selected) { genre in
                Text(genre)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .frame(width: 210)
            Divider()

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
        }
        .navigationTitle("Genres")
        .observing(model.database, id: 0, { try LibraryDatabase.genres($0) }) { value in
            genres = value
            if selected == nil { selected = value.first }
        }
        .observing(model.database, id: selected, { [selected] db in
            guard let selected else { return [] }
            return try LibraryDatabase.tracks(db, genre: selected)
        }) { tracks = $0 }
    }
}

struct SearchResultsView: View {
    var query: String
    @Environment(AppModel.self) private var model
    @State private var tracks: [Track] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Results for “\(query)”")
                    .font(.system(size: 24, weight: .bold))
                if tracks.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    TrackList(tracks: tracks, style: .playlist)
                }
            }
            .padding(24)
        }
        .navigationTitle("Search")
        .observing(model.database, id: query, { [query] db in try LibraryDatabase.search(db, query: query) }) { tracks = $0 }
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
