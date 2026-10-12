import LibraryKit
import MetadataKit
import SwiftUI

/// The Search page: recent searches until something is typed in the toolbar field, then the results by category.
struct SearchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        Group {
            if query.isEmpty {
                SearchLandingView()
            } else {
                SearchResultsView(query: query)
            }
        }
        .navigationTitle("Search")
    }
}

/// A category of search results, opened in full from its section header.
enum SearchCategory: String, CaseIterable, Identifiable, Hashable {
    case artists = "Artists", albums = "Albums", songs = "Songs", credits = "Credits"
    var id: Self { self }
}

/// Searches recently opened or submitted, newest first (one per line in the defaults).
enum RecentSearches {
    static let key = "search.recent"
    private static let limit = 10

    static func add(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        let current = list(UserDefaults.standard.string(forKey: key) ?? "")
        let updated = [query] + current.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        UserDefaults.standard.set(updated.prefix(limit).joined(separator: "\n"), forKey: key)
    }

    static func list(_ stored: String) -> [String] { stored.split(separator: "\n").map(String.init) }
}

private struct SearchLandingView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(RecentSearches.key) private var recent = ""

    var body: some View {
        let searches = RecentSearches.list(recent)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Search")
                        .font(.system(size: 30, weight: .bold))
                    Text("Find artists, albums and songs, and the people credited on your albums: musicians, producers, engineers and studios.")
                        .foregroundStyle(.secondary)
                }
                if !searches.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Recent Searches")
                                .font(.system(size: 20, weight: .bold))
                            Spacer()
                            Button("Clear") { recent = "" }
                                .buttonStyle(.link)
                        }
                        .padding(.bottom, 6)
                        ForEach(searches, id: \.self) { search in
                            Button {
                                model.searchText = search
                            } label: {
                                Label(search, systemImage: "magnifyingglass")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                    .frame(maxWidth: 520, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }
}

/// Search results like Music's: a section per category ("Artists ›" opens them all), artists as large round photos,
/// albums in one row of covers, songs in a grid of three rows that scrolls sideways, and people from the credits.
struct SearchResultsView: View {
    var query: String
    @Environment(AppModel.self) private var model
    @State private var page = SearchPage()
    /// The query `page` belongs to (nil until the first search finishes, so "No Results" does not flash).
    @State private var resultsQuery: String?

    var body: some View {
        let results = page.results
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if resultsQuery != nil && results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .padding(.top, 60)
                }
                if !results.artists.isEmpty {
                    section(.artists) {
                        HorizontalShelf(items: Array(results.artists.prefix(20)), itemWidth: 200, spacing: 24) { artist in
                            ArtistCircle(artist: artist, photo: page.photos[artist.name.lowercased()], size: 200)
                        }
                    }
                }
                if !results.albums.isEmpty {
                    section(.albums) {
                        HorizontalShelf(items: Array(results.albums.prefix(30)), itemWidth: 220, spacing: 22) { album in
                            NavigationLink(value: AppModel.Route.album(album)) {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !results.songs.isEmpty {
                    section(.songs) {
                        SongGridShelf(tracks: Array(results.songs.prefix(36)))
                    }
                }
                if !results.people.isEmpty {
                    section(.credits) {
                        HorizontalShelf(items: Array(results.people.prefix(20)), itemWidth: 160, spacing: 24) { person in
                            PersonCircle(person: person, size: 160)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .observing(model.database, id: query, { [query] db in try SearchPage.load(db, query: query) }) { [query] value in
            page = value
            resultsQuery = query
        }
        // Opening a result remembers the search.
        .onChange(of: model.path.count) { old, new in
            if new > old { RecentSearches.add(query) }
        }
    }

    /// A category's header ("Albums ›", which opens all of them) above its row.
    private func section<Content: View>(_ category: SearchCategory, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: AppModel.Route.searchCategory(category, query)) {
                HStack(spacing: 4) {
                    Text(category.rawValue)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 19, weight: .bold))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Show all \(category.rawValue.lowercased())")
            content()
        }
    }
}

/// The results of a search with the artists' photos (by lowercased name).
struct SearchPage: Sendable {
    var results = LibrarySearchResults()
    var photos: [String: String] = [:]

    static func load(_ db: Database, query: String) throws -> SearchPage {
        let results = try LibraryDatabase.search(db, query: query)
        var photos: [String: String] = [:]
        for artist in results.artists.prefix(100) {
            if let data = try LibraryDatabase.artistInfo(db, name: artist.name)?.data,
               let hash = (try? JSONDecoder().decode(ArtistInfo.self, from: data))?.imageHash {
                photos[artist.name.lowercased()] = hash
            }
        }
        return SearchPage(results: results, photos: photos)
    }
}

/// Every result of one category ("Albums ›" in the results).
struct SearchCategoryView: View {
    var category: SearchCategory
    var query: String
    @Environment(AppModel.self) private var model
    @State private var page = SearchPage()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.rawValue)
                        .font(.system(size: 28, weight: .bold))
                    Text("Results for “\(query)”")
                        .foregroundStyle(.secondary)
                }
                switch category {
                case .artists:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 24)], alignment: .leading, spacing: 26) {
                        ForEach(page.results.artists) { artist in
                            ArtistCircle(artist: artist, photo: page.photos[artist.name.lowercased()], size: 170)
                        }
                    }
                case .albums:
                    AlbumGrid(albums: page.results.albums)
                case .songs:
                    TrackList(tracks: page.results.songs, style: .playlist)
                case .credits:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 24)], alignment: .leading, spacing: 26) {
                        ForEach(page.results.people) { PersonCircle(person: $0, size: 150) }
                    }
                }
            }
            .padding(28)
        }
        .navigationTitle(category.rawValue)
        .observing(model.database, id: query, { [query] db in try SearchPage.load(db, query: query) }) { page = $0 }
    }
}

/// An artist as a large round photo (or one of their covers) with the name below; opens the artist's page.
struct ArtistCircle: View {
    var artist: ArtistSummary
    var photo: String?
    var size: CGFloat

    var body: some View {
        NavigationLink(value: AppModel.Route.artist(artist.name)) {
            VStack(spacing: 10) {
                ArtworkImage(hash: photo ?? artist.artworkHash, size: .small, cornerRadius: 0)
                    .frame(width: size, height: size)
                    .clipShape(.circle)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                Text(artist.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
            .frame(width: size)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Someone from the credits as a round monogram with their main roles; opens their page.
struct PersonCircle: View {
    var person: CreditedPerson
    var size: CGFloat

    var body: some View {
        NavigationLink(value: AppModel.Route.person(person.person)) {
            VStack(spacing: 6) {
                PersonAvatar(name: person.person.name)
                    .frame(width: size, height: size)
                Text(person.person.name)
                    .font(.system(size: 13))
                    .padding(.top, 4)
                Text(person.roles.prefix(2).map(\.capitalizingFirstLetter).joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(width: size)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// One row of items that scrolls sideways, with page buttons at the edges while hovered (like Music's shelves).
struct HorizontalShelf<Item: Identifiable, Content: View>: View {
    var items: [Item]
    var itemWidth: CGFloat
    var spacing: CGFloat
    @ViewBuilder var content: (Item) -> Content
    @State private var position = ScrollPosition(edge: .leading)
    @State private var offset: CGFloat = 0
    @State private var viewport: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var isHovering = false

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: spacing) {
                ForEach(items) { item in
                    content(item).frame(width: itemWidth)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition($position)
        .onScrollGeometryChange(for: [CGFloat].self) { geometry in
            [geometry.contentOffset.x, geometry.containerSize.width, geometry.contentSize.width]
        } action: { _, values in
            offset = values[0]
            viewport = values[1]
            contentWidth = values[2]
        }
        .overlay(alignment: .leading) {
            if isHovering && offset > 1 { pageButton(forward: false) }
        }
        .overlay(alignment: .trailing) {
            if isHovering && offset + viewport < contentWidth - 1 { pageButton(forward: true) }
        }
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering } }
    }

    private func pageButton(forward: Bool) -> some View {
        Button {
            let step = max(viewport - itemWidth, itemWidth)
            let target = min(max(offset + (forward ? step : -step), 0), max(contentWidth - viewport, 0))
            withAnimation(.smooth) { position.scrollTo(x: target) }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 22, height: 44)
        }
        .buttonStyle(.glass)
        .padding(.horizontal, -12)
        .transition(.opacity)
    }
}

/// Songs in a grid of three rows that scrolls sideways: cover, title, artist and "⋯" in each cell.
private struct SongGridShelf: View {
    var tracks: [Track]
    @Environment(AppModel.self) private var model

    private struct Column: Identifiable {
        var id: Int
        var rows: [(index: Int, track: Track)]
    }

    var body: some View {
        let columns = stride(from: 0, to: tracks.count, by: 3).map { start in
            Column(id: start, rows: (start..<min(start + 3, tracks.count)).map { ($0, tracks[$0]) })
        }
        HorizontalShelf(items: columns, itemWidth: 400, spacing: 24) { column in
            VStack(spacing: 0) {
                ForEach(column.rows, id: \.track.id) { row in
                    SongGridCell(track: row.track) { model.play(tracks, startAt: row.index) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct SongGridCell: View {
    var track: Track
    var onPlay: () -> Void
    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    var body: some View {
        let isCurrent = model.player.current?.id == track.id
        let isPlaying = model.player.state == .playing
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    if isCurrent { model.player.togglePlayPause() } else { onPlay() }
                } label: {
                    ArtworkImage(hash: track.artworkHash, size: .small, cornerRadius: 5)
                        .frame(width: 46, height: 46)
                        .overlay {
                            CoverPlayOverlay(isRowHovered: isHovering, isTargetHovered: false, isCurrent: isCurrent,
                                             isPlaying: isPlaying, cornerRadius: 5)
                        }
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13))
                        .foregroundStyle(isCurrent ? Color.brand : .primary)
                    Text(track.artist ?? track.albumArtist ?? "Unknown Artist")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                TrackMenuButton(tracks: { [track] })
                    .opacity(isHovering ? 1 : 0.6)
            }
            .padding(.vertical, 7)
            Divider().padding(.leading, 58)
        }
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { onPlay() }
        .contextMenu { TrackContextMenu(tracks: [track]) }
        .draggable(TrackTransfer(id: track.id ?? 0))
    }
}
