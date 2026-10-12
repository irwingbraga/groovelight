import AppKit
import Observation
import SwiftUI

/// A menu command with a keyboard shortcut the user can change in Settings, Shortcuts.
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case playPause, next, previous, skipForward, skipBack, volumeUp, volumeDown, mute, shuffle, cycleRepeat, love, goToCurrentSong
    case search, recentlyAdded, artists, albums, songs, genres, shelf, allPlaylists, lovedSongs, back
    case nowPlaying, lyrics, upNext, visualizer, equalizer, mainWindow, biggerCovers, smallerCovers, defaultCoverSize
    case newPlaylist, newSmartPlaylist, importMusic, addFolder, fetchMissingInfo, backUp

    var id: Self { self }

    enum Group: String, CaseIterable, Identifiable {
        case playback = "Playback", navigation = "Go To", windows = "Views and Windows", library = "Library"
        var id: Self { self }
    }

    var group: Group {
        switch self {
        case .playPause, .next, .previous, .skipForward, .skipBack, .volumeUp, .volumeDown, .mute, .shuffle, .cycleRepeat, .love,
             .goToCurrentSong: .playback
        case .search, .recentlyAdded, .artists, .albums, .songs, .genres, .shelf, .allPlaylists, .lovedSongs, .back: .navigation
        case .nowPlaying, .lyrics, .upNext, .visualizer, .equalizer, .mainWindow, .biggerCovers, .smallerCovers, .defaultCoverSize: .windows
        case .newPlaylist, .newSmartPlaylist, .importMusic, .addFolder, .fetchMissingInfo, .backUp: .library
        }
    }

    var title: String {
        switch self {
        case .playPause: "Play / Pause"
        case .next: "Next"
        case .previous: "Previous"
        case .skipForward: "Skip Forward 10 Seconds"
        case .skipBack: "Skip Back 10 Seconds"
        case .volumeUp: "Increase Volume"
        case .volumeDown: "Decrease Volume"
        case .mute: "Mute / Unmute"
        case .shuffle: "Shuffle"
        case .cycleRepeat: "Cycle Repeat Mode"
        case .love: "Love or Undo Love"
        case .goToCurrentSong: "Go to Current Song"
        case .search: "Search Library"
        case .recentlyAdded: "Recently Added"
        case .artists: "Artists"
        case .albums: "Albums"
        case .songs: "Songs"
        case .genres: "Genres"
        case .shelf: "Shelf"
        case .allPlaylists: "All Playlists"
        case .lovedSongs: "Loved Songs"
        case .back: "Back"
        case .nowPlaying: "Show or Hide Now Playing"
        case .lyrics: "Lyrics"
        case .upNext: "Up Next"
        case .visualizer: "Visualizer"
        case .equalizer: "Equalizer"
        case .mainWindow: "Library Window"
        case .biggerCovers: "Bigger Covers (Albums)"
        case .smallerCovers: "Smaller Covers (Albums)"
        case .defaultCoverSize: "Default Cover Size (Albums)"
        case .newPlaylist: "New Playlist"
        case .newSmartPlaylist: "New Smart Playlist"
        case .importMusic: "Import"
        case .addFolder: "Add Folder to Library"
        case .fetchMissingInfo: "Fetch Missing Info in Background"
        case .backUp: "Back Up Library"
        }
    }

    var defaultShortcut: KeyboardShortcut? {
        switch self {
        case .playPause: KeyboardShortcut("p", modifiers: [.command, .option])
        case .next: KeyboardShortcut(.rightArrow)
        case .previous: KeyboardShortcut(.leftArrow)
        case .skipForward: KeyboardShortcut(.rightArrow, modifiers: [.command, .option])
        case .skipBack: KeyboardShortcut(.leftArrow, modifiers: [.command, .option])
        case .volumeUp: KeyboardShortcut(.upArrow)
        case .volumeDown: KeyboardShortcut(.downArrow)
        case .mute: KeyboardShortcut(.downArrow, modifiers: [.command, .option])
        case .shuffle: KeyboardShortcut("s")
        case .cycleRepeat: KeyboardShortcut("r")
        case .love: KeyboardShortcut("l", modifiers: [.command, .shift])
        case .goToCurrentSong: KeyboardShortcut("l")
        case .search: KeyboardShortcut("f")
        case .recentlyAdded: KeyboardShortcut("1")
        case .artists: KeyboardShortcut("2")
        case .albums: KeyboardShortcut("3")
        case .songs: KeyboardShortcut("4")
        case .genres: KeyboardShortcut("5")
        case .shelf: KeyboardShortcut("6")
        case .allPlaylists: KeyboardShortcut("7")
        case .lovedSongs: KeyboardShortcut("8")
        case .back: KeyboardShortcut("[")
        case .nowPlaying: KeyboardShortcut("f", modifiers: [.command, .shift])
        case .lyrics: KeyboardShortcut("l", modifiers: [.command, .option])
        case .upNext: KeyboardShortcut("u", modifiers: [.command, .option])
        case .visualizer: KeyboardShortcut("t")
        case .equalizer: KeyboardShortcut("e", modifiers: [.command, .option])
        case .mainWindow: KeyboardShortcut("0")
        case .biggerCovers: KeyboardShortcut("+")
        case .smallerCovers: KeyboardShortcut("-")
        case .defaultCoverSize: nil
        case .newPlaylist: KeyboardShortcut("n")
        case .newSmartPlaylist: KeyboardShortcut("n", modifiers: [.command, .option])
        case .importMusic: KeyboardShortcut("o")
        case .addFolder: KeyboardShortcut("o", modifiers: [.command, .shift])
        case .fetchMissingInfo: KeyboardShortcut("u", modifiers: [.command, .shift])
        case .backUp: KeyboardShortcut("b", modifiers: [.command, .option])
        }
    }
}

/// The shortcuts in use: the defaults with the user's changes on top (saved in the defaults, and in backups).
@MainActor @Observable
final class ShortcutStore {
    static let key = "shortcuts.custom"

    /// A key and modifiers as saved; an empty key means the user removed the shortcut.
    struct Stored: Codable, Equatable {
        var key: String
        var modifiers: Int

        static let none = Stored(key: "", modifiers: 0)
    }

    private(set) var custom: [ShortcutAction: Stored] = [:]
    /// The action whose shortcut is being recorded in Settings (one at a time).
    var recording: ShortcutAction?

    /// Shortcuts that belong to macOS or the standard menus (Quit, Close, Copy...), never assigned.
    static let reserved: [(Stored, String)] = [
        reserve("q", .command, "Quit"), reserve("w", .command, "Close"), reserve("w", [.command, .option], "Close All"),
        reserve("h", .command, "Hide"), reserve("h", [.command, .option], "Hide Others"), reserve("m", .command, "Minimize"),
        reserve(",", .command, "Settings"), reserve("c", .command, "Copy"), reserve("v", .command, "Paste"),
        reserve("x", .command, "Cut"), reserve("a", .command, "Select All"), reserve("z", .command, "Undo"),
        reserve("z", [.command, .shift], "Redo"), reserve("`", .command, "Cycle Windows"), reserve(" ", .command, "Spotlight"),
    ]

    private static func reserve(_ key: String, _ modifiers: EventModifiers, _ name: String) -> (Stored, String) {
        (Stored(key: key, modifiers: Int(modifiers.rawValue)), name)
    }

    init() {
        load()
    }

    func shortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        guard let stored = custom[action] else { return action.defaultShortcut }
        guard let character = stored.key.first else { return nil }
        // The keys the user pressed, as they are: no remapping for other keyboard layouts.
        return KeyboardShortcut(KeyEquivalent(character), modifiers: EventModifiers(rawValue: stored.modifiers), localization: .custom)
    }

    func isCustomized(_ action: ShortcutAction) -> Bool { custom[action] != nil }

    /// Shown after a button's name in its tooltip, like " (⌘S)"; empty without a shortcut.
    func hint(_ action: ShortcutAction) -> String {
        shortcut(for: action).map { " (\(Self.display($0)))" } ?? ""
    }

    /// Sets a shortcut, or returns why it cannot be used (taken by another command or by macOS).
    func set(_ stored: Stored, for action: ShortcutAction) -> String? {
        if !stored.key.isEmpty {
            if let reserved = Self.reserved.first(where: { $0.0 == stored }) {
                return "\(Self.display(stored)) is reserved for \(reserved.1)."
            }
            if let other = ShortcutAction.allCases.first(where: { $0 != action && shortcut(for: $0).map(Self.stored) == stored }) {
                return "\(Self.display(stored)) is already used by \(other.title)."
            }
        }
        custom[action] = Self.stored(action.defaultShortcut) == stored ? nil : stored
        save()
        return nil
    }

    func reset(_ action: ShortcutAction) {
        custom[action] = nil
        save()
    }

    func resetAll() {
        custom = [:]
        save()
    }

    /// Reloads the saved shortcuts (after restoring a backup).
    func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode([String: Stored].self, from: data) else { custom = [:]; return }
        custom = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in ShortcutAction(rawValue: key).map { ($0, value) } })
    }

    private func save() {
        let saved = Dictionary(uniqueKeysWithValues: custom.map { ($0.key.rawValue, $0.value) })
        if saved.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    // MARK: - Keys

    static func stored(_ shortcut: KeyboardShortcut?) -> Stored {
        guard let shortcut else { return .none }
        return Stored(key: String(shortcut.key.character).lowercased(), modifiers: Int(shortcut.modifiers.rawValue))
    }

    /// The shortcut of a key press, or nil for keys that cannot be one (a plain letter would stop typing in text fields).
    static func stored(from event: NSEvent) -> Stored? {
        var modifiers: EventModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        // Without Shift and Option, so Option-L is recorded as L (not ¬) and Shift-L as Shift plus l.
        guard let key = event.charactersIgnoringModifiers?.lowercased().first ?? event.characters?.first else { return nil }
        let isFunctionKey = (0xF704...0xF726).contains(key.unicodeScalars.first?.value ?? 0)
        guard isFunctionKey || !modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        return Stored(key: String(key), modifiers: Int(modifiers.rawValue))
    }

    static func display(_ shortcut: KeyboardShortcut) -> String { display(stored(shortcut)) }

    static func display(_ stored: Stored) -> String {
        let modifiers = EventModifiers(rawValue: stored.modifiers)
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        guard let scalar = stored.key.unicodeScalars.first else { return text }
        let names: [UInt32: String] = [
            0xF700: "↑", 0xF701: "↓", 0xF702: "←", 0xF703: "→", 0x20: "Space", 0x0D: "↩", 0x03: "⌤", 0x09: "⇥",
            0x1B: "⎋", 0x7F: "⌫", 0xF728: "⌦", 0xF729: "↖", 0xF72B: "↘", 0xF72C: "⇞", 0xF72D: "⇟",
        ]
        if let name = names[scalar.value] { return text + name }
        if (0xF704...0xF726).contains(scalar.value) { return text + "F\(scalar.value - 0xF704 + 1)" }
        return text + stored.key.uppercased()
    }
}

extension View {
    /// The shortcut the user chose for `action` (none when they removed it).
    func shortcut(_ action: ShortcutAction, _ store: ShortcutStore) -> some View {
        keyboardShortcut(store.shortcut(for: action))
    }
}
