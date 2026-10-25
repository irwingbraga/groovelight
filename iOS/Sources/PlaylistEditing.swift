import LibraryKit
import SwiftUI

/// Adds songs to a playlist here (not a smart one), or to a new one; the Mac gets the change with the next sync.
struct AddToPlaylistMenu: View {
    @Environment(AppModel.self) private var model
    let trackIds: [Int64]
    var title = "Add to Playlist"

    var body: some View {
        Menu(title, systemImage: "text.badge.plus") {
            Button("New Playlist", systemImage: "plus") {
                model.library.createPlaylist(named: "New Playlist", trackIds: trackIds)
            }
            Divider()
            ForEach(model.library.editablePlaylists) { summary in
                Button(summary.playlist.name) { model.library.addToPlaylist(summary.id, trackIds: trackIds) }
            }
        }
    }
}

/// What a long press on a song offers: love it, add it to a playlist, and (in a playlist) take it out.
/// Songs dragged (a song, or an album's songs) onto a playlist or Loved Songs in the sidebar, as on the Mac.
struct SongsTransfer: Codable, Transferable {
    var ids: [Int64]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

struct SongMenu: View {
    @Environment(AppModel.self) private var model
    let track: Track
    /// The playlist the song is shown in, when it can be edited.
    var playlistId: Int64?

    var body: some View {
        if let id = track.id {
            Button(track.isLoved ? "Unlove" : "Love", systemImage: track.isLoved ? "heart.slash" : "heart") {
                model.library.setLoved(!track.isLoved, trackId: id)
            }
            AddToPlaylistMenu(trackIds: [id])
            if let playlistId {
                Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive) {
                    model.library.removeFromPlaylist(playlistId, trackIds: [id])
                }
            }
            if model.sync.isPaired {
                Divider()
                // Off this device at the next sync (the Mac keeps it).
                Button("Remove from This Device", systemImage: "trash", role: .destructive) {
                    model.catalog.request(.remove, .song, key: String(id))
                }
            }
        }
    }
}

/// A new playlist's name, asked before making it.
struct NewPlaylistButton: View {
    @Environment(AppModel.self) private var model
    @State private var isNaming = false
    @State private var name = ""

    var body: some View {
        Button("New Playlist", systemImage: "plus") {
            name = ""
            isNaming = true
        }
        .alert("New Playlist", isPresented: $isNaming) {
            TextField("Name", text: $name)
            Button("Create") { model.library.createPlaylist(named: name.isEmpty ? "New Playlist" : name) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It goes to your Mac with the next sync.")
        }
    }
}

/// Rename or delete a playlist made by hand (smart ones are edited on the Mac).
struct PlaylistActions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let summary: PlaylistSummary
    @State private var isRenaming = false
    @State private var isDeleting = false
    @State private var name = ""

    var body: some View {
        Menu {
            Button("Rename…", systemImage: "pencil") {
                name = summary.playlist.name
                isRenaming = true
            }
            Button("Delete Playlist", systemImage: "trash", role: .destructive) { isDeleting = true }
        } label: {
            Label("Playlist", systemImage: "ellipsis")
        }
        .alert("Rename Playlist", isPresented: $isRenaming) {
            TextField("Name", text: $name)
            Button("Rename") { if !name.trimmingCharacters(in: .whitespaces).isEmpty { model.library.renamePlaylist(summary.id, to: name) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(summary.playlist.name)”?", isPresented: $isDeleting, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                model.library.deletePlaylist(summary.id)
                dismiss()
            }
        } message: {
            Text("It is deleted on your Mac too, with the next sync. Its songs stay.")
        }
    }
}
