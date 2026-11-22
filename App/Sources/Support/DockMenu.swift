import AppKit
import LibraryKit
import PlayerCore

/// The menu of the app's Dock icon, like Music's: the song playing, Love, the playback controls, Shuffle and Repeat.
/// Built anew each time it opens, so it always shows the current state.
@MainActor
enum DockMenu {
    static func make(_ model: AppModel) -> NSMenu {
        let menu = NSMenu()
        let player = model.player
        if let item = player.current {
            menu.addItem(.sectionHeader(title: "Now Playing"))
            menu.addItem(info(item.title))
            let byline = [item.artist, item.album].filter { !$0.isEmpty }.joined(separator: ", ")
            if !byline.isEmpty { menu.addItem(info(byline)) }
            let loved = (try? model.database.writer.read { try Track.fetchOne($0, key: item.id) })??.isLoved == true
            menu.addItem(action(loved ? "Undo Love" : "Love") { model.toggleLovedCurrent() })
            menu.addItem(.separator())
        }
        menu.addItem(action(player.state == .playing ? "Pause" : "Play", enabled: player.current != nil) {
            player.togglePlayPause()
        })
        menu.addItem(action("Next", enabled: player.current != nil) { player.next() })
        menu.addItem(action("Previous", enabled: player.current != nil) { player.previous() })
        menu.addItem(.separator())
        menu.addItem(action("Shuffle", checked: player.isShuffled) { player.setShuffle(!player.isShuffled) })
        let repeatItem = NSMenuItem(title: "Repeat", action: nil, keyEquivalent: "")
        let repeatMenu = NSMenu()
        for (title, mode) in [("Off", RepeatMode.off), ("All", .all), ("One", .one)] {
            repeatMenu.addItem(action(title, checked: player.repeatMode == mode) { player.repeatMode = mode })
        }
        repeatItem.submenu = repeatMenu
        menu.addItem(repeatItem)
        return menu
    }

    private static func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func action(_ title: String, enabled: Bool = true, checked: Bool = false, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? #selector(Handler.run(_:)) : nil, keyEquivalent: "")
        let handler = Handler(run)
        item.target = handler
        item.representedObject = handler  // The item keeps its handler alive: targets are weak.
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        return item
    }

    @MainActor private final class Handler: NSObject {
        let perform: @MainActor () -> Void
        init(_ perform: @escaping @MainActor () -> Void) { self.perform = perform }
        @objc func run(_ sender: Any?) { perform() }
    }
}
