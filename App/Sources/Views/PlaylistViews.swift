import LibraryKit
import SwiftUI

// MARK: - All Playlists

/// Every playlist as a grid of cards, like Albums: Loved Songs first, then the playlists by name.
struct AllPlaylistsView: View {
    @Environment(AppModel.self) private var model
    @State private var overview: PlaylistOverview?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 22)], alignment: .leading, spacing: 26) {
                if let overview {
                    PlaylistCard(title: "Loved Songs", subtitle: songCount(overview.lovedCount),
                                 cover: { LovedSongsCover() },
                                 open: { model.selection = .lovedSongs },
                                 play: { shuffle in playLoved(shuffle: shuffle) }) {
                        Button("Play") { playLoved(shuffle: false) }
                        Button("Shuffle") { playLoved(shuffle: true) }
                        QueueMenuItems(source: .lovedSongs)
                    }
                    ForEach(overview.playlists) { summary in
                        let playlist = summary.playlist
                        PlaylistCard(title: playlist.name,
                                     subtitle: playlist.isSmart ? "Smart Playlist · \(songCount(summary.trackCount))" : songCount(summary.trackCount),
                                     cover: { PlaylistCoverView(name: playlist.name, cover: playlist.coverStyle, songHashes: summary.artworkHashes,
                                                                seed: summary.id, isSmart: playlist.isSmart) },
                                     open: { model.selection = .playlist(summary.id) },
                                     play: { shuffle in model.playPlaylist(summary.id, shuffle: shuffle) }) {
                            Button("Play") { model.playPlaylist(summary.id) }
                            Button("Shuffle") { model.playPlaylist(summary.id, shuffle: true) }
                            QueueMenuItems(source: .playlist(summary.id))
                            Divider()
                            Button("Edit Playlist…") { model.editPlaylist(playlist) }
                            if playlist.isSmart {
                                Button("Edit Rules…") { model.editSmartPlaylist(playlist) }
                            }
                            Button("Delete Playlist", role: .destructive) { model.deletePlaylist(summary.id) }
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("All Playlists")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Playlist", systemImage: "music.note.list") { model.newPlaylist() }
                    Button("New Smart Playlist…", systemImage: "gearshape") { model.newSmartPlaylist() }
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }
                .help("New Playlist")
            }
        }
        .observing(model.database, id: 0, { try LibraryDatabase.playlistOverview($0) }) { overview = $0 }
    }

    private func songCount(_ count: Int) -> String { count == 1 ? "1 song" : "\(count) songs" }

    private func playLoved(shuffle: Bool) {
        Task {
            let tracks = (try? await model.database.writer.read { try LibraryDatabase.lovedTracks($0) }) ?? []
            model.play(tracks, shuffle: shuffle)
        }
    }
}

/// A playlist in the grid: cover with hover Play and Shuffle buttons (like album cards), name and song count.
private struct PlaylistCard<Cover: View, Menu: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var cover: () -> Cover
    var open: () -> Void
    var play: (_ shuffle: Bool) -> Void
    @ViewBuilder var menu: () -> Menu
    @State private var isHovering = false

    var body: some View {
        // A plain button like the album cards' navigation links; the hover buttons inside take their own clicks.
        Button(action: open) { card }
            .buttonStyle(.plain)
            .contextMenu { menu() }
            #if DEBUG
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { DebugHitTargets.playlistCards[title] = $0 }
            #endif
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover()
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.25), radius: isHovering ? 10 : 4, y: isHovering ? 6 : 2)
                .overlay(alignment: .bottomLeading) {
                    if isHovering {
                        HStack {
                            Button { play(false) } label: { Image(systemName: "play.fill").frame(width: 18, height: 18) }
                                .glassButtonStyle()
                                .buttonBorderShape(.circle)
                            Spacer()
                            Button { play(true) } label: { Image(systemName: "shuffle").frame(width: 18, height: 18) }
                                .glassButtonStyle()
                                .buttonBorderShape(.circle)
                        }
                        .padding(8)
                        .transition(.opacity)
                    }
                }
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(.rect)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering } }
    }
}

// MARK: - Covers

/// Cover of the built-in Loved Songs playlist.
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

// MARK: - Playlist pages

/// Header shared by playlist pages: cover, name, song count and length, optional rules line, Play / Shuffle / extra.
private struct PlaylistHeader<Cover: View, Extra: View>: View {
    var title: String
    var tracks: [Track]
    var detail: String? = nil
    @ViewBuilder var cover: () -> Cover
    @ViewBuilder var extra: () -> Extra
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            cover()
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                Text("\(tracks.count) songs, \(formatLongDuration(tracks.reduce(0) { $0 + $1.duration }))")
                    .foregroundStyle(.secondary)
                if let detail {
                    Label(detail, systemImage: "gearshape")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack {
                    Button { model.play(tracks) } label: { Label("Play", systemImage: "play.fill") }
                        .glassProminentButtonStyle()
                        .disabled(tracks.isEmpty)
                    Button { model.play(tracks, shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                        .glassButtonStyle()
                        .disabled(tracks.isEmpty)
                    extra()
                }
                .controlSize(.large)
            }
        }
    }
}

struct PlaylistView: View {
    var playlistId: Int64
    @Environment(AppModel.self) private var model
    @State private var playlist: Playlist?
    @State private var tracks: [Track] = []

    /// Distinct covers of the songs, in playlist order.
    private var songHashes: [String] {
        var seen = Set<String>()
        return tracks.compactMap(\.artworkHash).filter { seen.insert($0).inserted }.prefix(4).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PlaylistHeader(title: playlist?.name ?? "", tracks: tracks, detail: playlist?.rules?.summary) {
                    if let playlist {
                        EditableCover(playlist: playlist, songHashes: songHashes)
                    }
                } extra: {
                    if let playlist, playlist.isSmart {
                        Button { model.editSmartPlaylist(playlist) } label: { Label("Edit Rules", systemImage: "slider.horizontal.3") }
                            .glassButtonStyle()
                    }
                    PageMoreMenu {
                        QueueMenuItems(source: .playlist(playlistId))
                        if let playlist {
                            Divider()
                            Button("Edit Playlist…", systemImage: "pencil") { model.editPlaylist(playlist) }
                        }
                        Button("Export Playlist…", systemImage: "square.and.arrow.up") { model.playlistFiles.export(playlistId: playlistId) }
                    }
                }
                if tracks.isEmpty, playlist?.isSmart == true {
                    PlaylistEmptyNote(title: "No Matching Songs", systemImage: "gearshape",
                                      message: "Songs that match the rules show up here as your library changes.")
                } else if tracks.isEmpty {
                    PlaylistEmptyNote(title: "No Songs Yet", systemImage: "music.note.list",
                                      message: "Drag songs here or use Add to Playlist from a song's menu.")
                } else {
                    TrackList(tracks: tracks, style: .playlist)
                }
            }
            // Full width and leading even without songs, so an empty playlist keeps the page's layout.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(28)
        }
        .coverWash {
            if let playlist {
                // Without the title: letters would only smear the color.
                PlaylistCoverView(name: playlist.name, cover: playlist.coverStyle, songHashes: songHashes,
                                  seed: playlist.id ?? 0, cornerRadius: 0, hidesTitle: true)
            }
        }
        .dropDestination(for: TrackTransfer.self) { items, _ in
            guard playlist?.isSmart != true else { return false }
            try? model.database.addTracks(items.flatMap(\.ids), toPlaylist: playlistId)
            return true
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .observing(model.database, id: playlistId, { [playlistId] db in
            (try Playlist.fetchOne(db, key: playlistId), try LibraryDatabase.tracks(db, playlistId: playlistId))
        }) { value in
            playlist = value.0
            tracks = value.1
        }
    }
}

/// The built-in Loved Songs playlist: every loved song, most recently loved first. Dropping songs here loves them.
struct LovedSongsView: View {
    @Environment(AppModel.self) private var model
    @State private var tracks: [Track] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PlaylistHeader(title: "Loved Songs", tracks: tracks) {
                    LovedSongsCover()
                } extra: {
                    PageMoreMenu {
                        QueueMenuItems(source: .lovedSongs)
                        Divider()
                        Button("Export Playlist…", systemImage: "square.and.arrow.up") { model.playlistFiles.export(playlistId: nil) }
                    }
                }
                if tracks.isEmpty {
                    PlaylistEmptyNote(title: "No Loved Songs", systemImage: "heart",
                                      message: "Songs you love (the heart in the player or Love in a song's menu) show up here.")
                } else {
                    TrackList(tracks: tracks, style: .playlist)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(28)
        }
        .coverWash { LovedSongsCover() }
        .dropDestination(for: TrackTransfer.self) { items, _ in
            model.love(trackIds: items.flatMap(\.ids))
            return true
        }
        .navigationTitle("Loved Songs")
        .observing(model.database, id: 0, { try LibraryDatabase.lovedTracks($0) }) { tracks = $0 }
    }
}

/// Where the songs of an empty playlist would be: a dashed drop area under the header, in place of the song list.
private struct PlaylistEmptyNote: View {
    var title: String
    var systemImage: String
    var message: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        }
        .padding(.top, 8)
    }
}

/// The playlist page's cover: clicking it (or right-clicking) offers Edit Playlist and Choose Cover Image.
private struct EditableCover: View {
    var playlist: Playlist
    var songHashes: [String]
    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    var body: some View {
        Menu {
            items
        } label: {
            PlaylistCoverView(name: playlist.name, cover: playlist.coverStyle, songHashes: songHashes, seed: playlist.id ?? 0,
                              isSmart: playlist.isSmart, cornerRadius: 12)
                .overlay(alignment: .bottomTrailing) {
                    if isHovering {
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(8)
                            .glassBackground(in: .circle)
                            .padding(10)
                            .transition(.opacity)
                    }
                }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .contextMenu { items }
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering } }
        .help("Edit Playlist")
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { DebugHitTargets.playlistCover = $0 }
        #endif
    }

    @ViewBuilder
    private var items: some View {
        Button("Edit Playlist…") { model.editPlaylist(playlist) }
        if playlist.isSmart {
            Button("Edit Rules…") { model.editSmartPlaylist(playlist) }
        }
    }
}

/// The round glass "⋯" button of album and playlist pages.
struct PageMoreMenu<Items: View>: View {
    @ViewBuilder var items: () -> Items

    var body: some View {
        Menu(content: items) {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .fixedSize()
        .help("More")
    }
}
