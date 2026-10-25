import PlayerCore
import SwiftUI

// The Mac's menus and keyboard shortcuts on the iPad (its menu bar, and the list shown while Command is held): the
// Controls menu and the sidebar's pages, with the Mac's default keys.

extension FocusedValues {
    /// The sidebar's page in the window in front (where there is a sidebar).
    @Entry var sidebarSelection: Binding<SidebarItem?>?
    /// What the window in front shows (Now Playing, a page asked for).
    @Entry var window: WindowModel?
}

struct PlayerCommands: Commands {
    let model: AppModel
    @FocusedValue(\.sidebarSelection) private var selection
    @FocusedValue(\.window) private var window

    /// The sidebar's pages in order, numbered as on the Mac (and in Music).
    private static let pages: [(title: String, item: SidebarItem, key: KeyEquivalent)] = [
        ("Recently Added", .recentlyAdded, "1"), ("Artists", .artists, "2"), ("Albums", .albums, "3"), ("Songs", .songs, "4"),
        ("Genres", .genres, "5"), ("Shelf", .shelf, "6"), ("All Playlists", .allPlaylists, "7"), ("Loved Songs", .lovedSongs, "8"),
    ]

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Search Library") { go(to: .search) }
                .keyboardShortcut("f")
                .disabled(selection == nil)
        }
        CommandMenu("Controls") {
            let playing = model.nowPlaying
            Button(playing?.isPlaying == true ? "Pause" : "Play") { model.togglePlayPause() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(playing == nil)
            Button("Next") { model.next() }
                .keyboardShortcut(.rightArrow)
                .disabled(playing == nil)
            Button("Previous") { model.previous() }
                .keyboardShortcut(.leftArrow)
                .disabled(playing == nil)
            Button("Skip Forward 10 Seconds") { skip(by: 10) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(playing == nil)
            Button("Skip Back 10 Seconds") { skip(by: -10) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(playing == nil)
            Divider()
            Toggle("Shuffle", isOn: Binding(get: { model.isShuffled }, set: { if $0 != model.isShuffled { model.toggleShuffle() } }))
                .keyboardShortcut("s")
            Button("Cycle Repeat Mode") { model.cycleRepeat() }
                .keyboardShortcut("r")
            Divider()
            Button("Love or Undo Love") { model.toggleLove() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(playing == nil)
            Button("Go to Current Song") {
                if let playing, let route = model.albumRoute(of: playing) { window?.show(route) }
            }
            .keyboardShortcut("l")
            .disabled(playing == nil)
            Divider()
            Button(window?.isShowingNowPlaying == true ? "Hide Now Playing" : "Show Now Playing") { window?.isShowingNowPlaying.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(playing == nil || window == nil)
        }
        CommandGroup(after: .sidebar) {
            ForEach(Self.pages, id: \.key) { page in
                Button(page.title) { go(to: page.item) }
                    .keyboardShortcut(page.key)
                    .disabled(selection == nil)
            }
        }
    }

    private func go(to item: SidebarItem) {
        window?.isShowingNowPlaying = false
        selection?.wrappedValue = item
    }

    private func skip(by seconds: TimeInterval) {
        let time = model.time(at: .now)
        model.seek(to: min(max(0, time + seconds), max(model.duration, 0)))
    }
}
