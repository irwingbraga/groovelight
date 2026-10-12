import LibraryKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var playlists: [Playlist] = []
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
            Section("Playlists") {
                Label("All Playlists", systemImage: "square.grid.2x2").tag(SidebarItem.allPlaylists)
                Label {
                    Text("Loved Songs")
                } icon: {
                    Image(systemName: "heart.fill").foregroundStyle(.pink)
                }
                .tag(SidebarItem.lovedSongs)
                .contextMenu { QueueMenuItems(source: .lovedSongs) }
                .dropDestination(for: TrackTransfer.self) { items, _ in
                    model.love(trackIds: items.map(\.id))
                    return true
                }
                ForEach(playlists) { playlist in
                    if let id = playlist.id {
                        Group {
                            if renaming == id {
                                TextField("Name", text: $draftName)
                                    .onSubmit { commitRename(id) }
                            } else {
                                Label(playlist.name, systemImage: playlist.isSmart ? "gearshape" : "music.note.list")
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
        .observing(model.database, id: 0, { try LibraryDatabase.playlists($0) }) { playlists = $0 }
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
