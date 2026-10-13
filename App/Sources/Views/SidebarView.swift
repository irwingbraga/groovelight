import LibraryKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// Playlists with their songs' covers, for the cover icons.
    @State private var playlists: [PlaylistSummary] = []
    @State private var renaming: Int64?
    @State private var draftName = ""

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            // A link to the toolbar search field (it stays reachable there when the sidebar is collapsed).
            Label("Search", systemImage: "magnifyingglass").tag(SidebarItem.search)
            Section("Library") {
                Label("Recently Added", systemImage: "clock").tag(SidebarItem.recentlyAdded)
                Label("Artists", systemImage: "music.microphone").tag(SidebarItem.artists)
                Label("Albums", systemImage: "square.stack").tag(SidebarItem.albums)
                Label("Songs", systemImage: "music.note").tag(SidebarItem.songs)
                Label("Genres", systemImage: "guitars").tag(SidebarItem.genres)
            }
            Section("Explore") {
                Label("Shelf", systemImage: "rectangle.stack.badge.play").tag(SidebarItem.shelf)
            }
            // Players and memory cards, while they are connected.
            if !model.devices.devices.isEmpty {
                Section("Devices") {
                    ForEach(model.devices.devices) { device in
                        HStack {
                            Label(device.name, systemImage: device.isWireless ? "smartphone" : "sdcard")
                            Spacer()
                            if model.devices.job?.deviceId == device.id, model.devices.job?.isRunning == true {
                                ProgressView().controlSize(.mini)
                            } else if device.isWireless {
                                Circle()
                                    .fill(device.isOnline ? Color.green : Color.secondary.opacity(0.4))
                                    .frame(width: 7, height: 7)
                                    .help(device.isOnline ? "Online" : "Offline: it syncs when its app next checks in")
                            } else {
                                Button { model.devices.eject(device) } label: { Image(systemName: "eject.fill") }
                                    .buttonStyle(.borderless)
                                    .help("Eject \(device.name)")
                            }
                        }
                        .tag(SidebarItem.device(device.id))
                        .contextMenu {
                            Button("Sync Now") { model.devices.sync(device) }
                                .disabled(model.devices.job?.isRunning == true)
                            if !device.isWireless {
                                Button("Eject") { model.devices.eject(device) }
                            }
                        }
                    }
                }
            }
            Section("Playlists") {
                Label("All Playlists", systemImage: "square.grid.2x2").tag(SidebarItem.allPlaylists)
                Label {
                    Text("Loved Songs")
                } icon: {
                    Image(systemName: "heart.fill").foregroundStyle(.pink)
                }
                .tag(SidebarItem.lovedSongs)
                .contextMenu {
                    QueueMenuItems(source: .lovedSongs)
                    Divider()
                    Button("Export Playlist…") { model.playlistFiles.export(playlistId: nil) }
                }
                .dropDestination(for: TrackTransfer.self) { items, _ in
                    model.love(trackIds: items.map(\.id))
                    return true
                }
                ForEach(playlists) { summary in
                    let playlist = summary.playlist
                    if let id = playlist.id {
                        Group {
                            if renaming == id {
                                TextField("Name", text: $draftName)
                                    .onSubmit { commitRename(id) }
                            } else {
                                Label {
                                    Text(playlist.name)
                                } icon: {
                                    SidebarCover(summary: summary)
                                }
                            }
                        }
                        .tag(SidebarItem.playlist(id))
                        .contextMenu {
                            QueueMenuItems(source: .playlist(id))
                            Divider()
                            Button("Edit Playlist…") { model.editPlaylist(playlist) }
                            if playlist.isSmart {
                                Button("Edit Rules…") { model.editSmartPlaylist(playlist) }
                            }
                            Button("Rename") {
                                draftName = playlist.name
                                renaming = id
                            }
                            Button("Export Playlist…") { model.playlistFiles.export(playlistId: id) }
                            Button("Delete Playlist", role: .destructive) { model.deletePlaylist(id) }
                        }
                        .dropDestination(for: TrackTransfer.self) { items, _ in
                            // Smart playlists are filled by their rules.
                            guard !playlist.isSmart else { return false }
                            try? model.database.addTracks(items.map(\.id), toPlaylist: id)
                            return true
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                if let job = model.metadata.libraryJob {
                    LibraryJobRow(job: job)
                }
                newPlaylistButton
            }
        }
        .observing(model.database, id: 0, { try LibraryDatabase.playlistOverview($0).playlists }) { playlists = $0 }
    }

    private var newPlaylistButton: some View {
            // Click for a playlist; the arrow offers a smart playlist.
            Menu {
                Button("New Playlist", systemImage: "music.note.list") { model.newPlaylist() }
                Button("New Smart Playlist…", systemImage: "gearshape") { model.newSmartPlaylist() }
            } label: {
                Label("New Playlist", systemImage: "plus")
            } primaryAction: {
                model.newPlaylist()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }

    private func commitRename(_ id: Int64) {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { try? model.database.renamePlaylist(id, to: name) }
        renaming = nil
    }
}

/// Drag payload for tracks (track ids).
struct TrackTransfer: Codable, Transferable {
    var id: Int64

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

/// Progress of the background "Fetch Missing Info" job, at the bottom of the sidebar.
private struct LibraryJobRow: View {
    var job: MetadataStore.LibraryJobProgress
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(job.step.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(job.done) of \(job.total)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    model.metadata.stopFetchingMissingInfo()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Stop fetching missing info")
            }
            ProgressView(value: Double(job.done), total: Double(max(job.total, 1)))
                .controlSize(.small)
            if !job.remaining.isEmpty {
                Text("Then: " + job.remaining.map(\.rawValue).joined(separator: ", "))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .help("Fetching missing library info in the background, one request at a time")
    }
}

/// A playlist's cover as its sidebar icon, name included, exactly as in All Playlists (the chosen cover, else its
/// songs' covers or its generated colors).
private struct SidebarCover: View {
    var summary: PlaylistSummary

    static let side: CGFloat = 20
    /// The size of a cover in All Playlists.
    static let cardSide: CGFloat = 200
    static let cornerRadius: CGFloat = 4

    var body: some View {
        let playlist = summary.playlist
        // Drawn at the size of an All Playlists card, then shrunk: the name wraps and sits as on the card (at 20 pt
        // the title's minimum font size would wrap it differently).
        PlaylistCoverView(name: playlist.name, cover: playlist.coverStyle, songHashes: summary.artworkHashes,
                          seed: playlist.id ?? 0, cornerRadius: Self.cornerRadius * Self.cardSide / Self.side)
            .frame(width: Self.cardSide, height: Self.cardSide)
            .scaleEffect(Self.side / Self.cardSide)
            .frame(width: Self.side, height: Self.side)
    }
}
