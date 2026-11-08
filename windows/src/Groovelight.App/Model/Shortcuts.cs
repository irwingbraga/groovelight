using System.Text.Json;
using Groovelight.Core;
using Windows.System;

namespace Groovelight.Model;

/// <summary>A menu command with a keyboard shortcut the user can change in Settings, Shortcuts (the Mac's ShortcutAction).</summary>
public enum ShortcutAction
{
    PlayPause, Next, Previous, SkipForward, SkipBack, VolumeUp, VolumeDown, Mute, Shuffle, CycleRepeat, Love, GoToCurrentSong,
    Search, Home, RecentlyAdded, Artists, Albums, Songs, Genres, Shelf, AllPlaylists, LovedSongs, Back,
    NowPlaying, Lyrics, UpNext, Visualizer, Equalizer, MainWindow, BiggerCovers, SmallerCovers, DefaultCoverSize,
    NewPlaylist, NewSmartPlaylist, ImportMusic, AddFolder, FetchMissingInfo, BackUp,
}

public enum ShortcutGroup { Playback, Navigation, Windows, Library }

/// <summary>
/// A key and modifiers as saved, in the Mac's format so backups carry them: the key as a lowercase character (arrows and
/// function keys as AppKit's private-use characters), the modifiers as SwiftUI's bits. Ctrl is saved as the Mac's
/// Command and Alt as Option, so a shortcut keeps its place on the keyboard on either computer.
/// </summary>
public sealed record StoredShortcut(string Key, int Modifiers)
{
    public const int Shift = 2, Control = 4, Option = 8, Command = 16;
    public static readonly StoredShortcut None = new("", 0);

    public bool IsEmpty => Key.Length == 0;
    /// <summary>Ctrl on Windows: the Mac's Command (or its Control, from a Mac backup).</summary>
    public bool HasCtrl => (Modifiers & (Command | Control)) != 0;
    public bool HasAlt => (Modifiers & Option) != 0;
    public bool HasShift => (Modifiers & Shift) != 0;

    public static StoredShortcut Of(string key, bool ctrl = true, bool alt = false, bool shift = false) =>
        new(key, (ctrl ? Command : 0) | (alt ? Option : 0) | (shift ? Shift : 0));

    /// <summary>Same keys whichever of Command or Control a Mac backup used.</summary>
    public bool Matches(StoredShortcut other) =>
        Key == other.Key && HasCtrl == other.HasCtrl && HasAlt == other.HasAlt && HasShift == other.HasShift;

    public const char Up = '', Down = '', Left = '', Right = '', F1 = '';
    public const char Delete = '', Home = '', End = '', PageUp = '', PageDown = '';

    private static readonly Dictionary<VirtualKey, char> Keys = new()
    {
        [VirtualKey.Up] = Up, [VirtualKey.Down] = Down, [VirtualKey.Left] = Left, [VirtualKey.Right] = Right,
        [VirtualKey.Space] = ' ', [VirtualKey.Enter] = '\r', [VirtualKey.Tab] = '\t', [VirtualKey.Escape] = '\u001B',
        [VirtualKey.Back] = '\u007F', [VirtualKey.Delete] = Delete, [VirtualKey.Home] = Home, [VirtualKey.End] = End,
        [VirtualKey.PageUp] = PageUp, [VirtualKey.PageDown] = PageDown,
        [(VirtualKey)186] = ';', [(VirtualKey)187] = '+', [(VirtualKey)188] = ',', [(VirtualKey)189] = '-', [(VirtualKey)190] = '.',
        [(VirtualKey)191] = '/', [(VirtualKey)192] = '`', [(VirtualKey)219] = '[', [(VirtualKey)220] = '\\', [(VirtualKey)221] = ']',
        [(VirtualKey)222] = '\'', [VirtualKey.Add] = '+', [VirtualKey.Subtract] = '-',
    };

    /// <summary>The key of a key press, or null for keys that cannot be part of a shortcut (modifiers alone).</summary>
    public static char? KeyCharacter(VirtualKey key)
    {
        if (key is >= VirtualKey.A and <= VirtualKey.Z) return char.ToLowerInvariant((char)key);
        if (key is >= VirtualKey.Number0 and <= VirtualKey.Number9) return (char)key;
        if (key is >= VirtualKey.NumberPad0 and <= VirtualKey.NumberPad9) return (char)('0' + (key - VirtualKey.NumberPad0));
        if (key is >= VirtualKey.F1 and <= VirtualKey.F24) return (char)(F1 + (key - VirtualKey.F1));
        return Keys.TryGetValue(key, out var character) ? character : null;
    }

    public static bool IsFunctionKey(char key) => key is >= F1 and <= '';

    /// <summary>"Ctrl+Alt+P".</summary>
    public string Display()
    {
        if (IsEmpty) return "";
        var parts = new List<string>();
        if (HasCtrl) parts.Add("Ctrl");
        if (HasAlt) parts.Add("Alt");
        if (HasShift) parts.Add("Shift");
        var key = Key[0];
        parts.Add(key switch
        {
            Up => "Up", Down => "Down", Left => "Left", Right => "Right", ' ' => "Space", '\r' => "Enter", '\t' => "Tab",
            '\u001B' => "Esc", '\u007F' => "Backspace", Delete => "Delete", Home => "Home", End => "End", PageUp => "PgUp",
            PageDown => "PgDn",
            _ when IsFunctionKey(key) => $"F{key - F1 + 1}",
            _ => Key.ToUpperInvariant(),
        });
        return string.Join("+", parts);
    }
}

/// <summary>The shortcuts in use: the defaults with the user's changes on top (saved in the preferences and backups).</summary>
public sealed class ShortcutStore
{
    public const string Key = "shortcuts.custom";
    private readonly Preferences preferences;
    private Dictionary<ShortcutAction, StoredShortcut> custom = [];

    public event Action? Changed;

    public ShortcutStore(Preferences preferences)
    {
        this.preferences = preferences;
        Load();
    }

    public static ShortcutGroup GroupOf(ShortcutAction action) => action switch
    {
        <= ShortcutAction.GoToCurrentSong => ShortcutGroup.Playback,
        <= ShortcutAction.Back => ShortcutGroup.Navigation,
        <= ShortcutAction.DefaultCoverSize => ShortcutGroup.Windows,
        _ => ShortcutGroup.Library,
    };

    public static string GroupTitle(ShortcutGroup group) => group switch
    {
        ShortcutGroup.Playback => "Playback",
        ShortcutGroup.Navigation => "Go To",
        ShortcutGroup.Windows => "Views and Windows",
        _ => "Library",
    };

    public static string Title(ShortcutAction action) => action switch
    {
        ShortcutAction.PlayPause => "Play / Pause",
        ShortcutAction.SkipForward => "Skip Forward 10 Seconds",
        ShortcutAction.SkipBack => "Skip Back 10 Seconds",
        ShortcutAction.VolumeUp => "Increase Volume",
        ShortcutAction.VolumeDown => "Decrease Volume",
        ShortcutAction.Mute => "Mute / Unmute",
        ShortcutAction.CycleRepeat => "Cycle Repeat Mode",
        ShortcutAction.Love => "Love or Undo Love",
        ShortcutAction.GoToCurrentSong => "Go to Current Song",
        ShortcutAction.Search => "Search Library",
        ShortcutAction.Home => "Home",
        ShortcutAction.RecentlyAdded => "Recently Added",
        ShortcutAction.AllPlaylists => "All Playlists",
        ShortcutAction.LovedSongs => "Loved Songs",
        ShortcutAction.NowPlaying => "Show or Hide Now Playing",
        ShortcutAction.UpNext => "Up Next",
        ShortcutAction.MainWindow => "Library Window",
        ShortcutAction.BiggerCovers => "Bigger Covers (Albums, Shelf)",
        ShortcutAction.SmallerCovers => "Smaller Covers (Albums, Shelf)",
        ShortcutAction.DefaultCoverSize => "Default Cover Size (Albums, Shelf)",
        ShortcutAction.NewPlaylist => "New Playlist",
        ShortcutAction.NewSmartPlaylist => "New Smart Playlist",
        ShortcutAction.ImportMusic => "Import",
        ShortcutAction.AddFolder => "Add Folder to Library",
        ShortcutAction.FetchMissingInfo => "Fetch Missing Info in Background",
        ShortcutAction.BackUp => "Back Up Library",
        _ => action.ToString(),
    };

    /// <summary>The Mac's defaults with Ctrl for Command and Alt for Option.</summary>
    public static StoredShortcut? Default(ShortcutAction action) => action switch
    {
        ShortcutAction.PlayPause => StoredShortcut.Of("p", alt: true),
        ShortcutAction.Next => StoredShortcut.Of(StoredShortcut.Right.ToString()),
        ShortcutAction.Previous => StoredShortcut.Of(StoredShortcut.Left.ToString()),
        ShortcutAction.SkipForward => StoredShortcut.Of(StoredShortcut.Right.ToString(), alt: true),
        ShortcutAction.SkipBack => StoredShortcut.Of(StoredShortcut.Left.ToString(), alt: true),
        ShortcutAction.VolumeUp => StoredShortcut.Of(StoredShortcut.Up.ToString()),
        ShortcutAction.VolumeDown => StoredShortcut.Of(StoredShortcut.Down.ToString()),
        ShortcutAction.Mute => StoredShortcut.Of(StoredShortcut.Down.ToString(), alt: true),
        ShortcutAction.Shuffle => StoredShortcut.Of("s"),
        ShortcutAction.CycleRepeat => StoredShortcut.Of("r"),
        ShortcutAction.Love => StoredShortcut.Of("l", shift: true),
        ShortcutAction.GoToCurrentSong => StoredShortcut.Of("l"),
        ShortcutAction.Search => StoredShortcut.Of("f"),
        ShortcutAction.Home => StoredShortcut.Of("h", shift: true),
        ShortcutAction.RecentlyAdded => StoredShortcut.Of("1"),
        ShortcutAction.Artists => StoredShortcut.Of("2"),
        ShortcutAction.Albums => StoredShortcut.Of("3"),
        ShortcutAction.Songs => StoredShortcut.Of("4"),
        ShortcutAction.Genres => StoredShortcut.Of("5"),
        ShortcutAction.Shelf => StoredShortcut.Of("6"),
        ShortcutAction.AllPlaylists => StoredShortcut.Of("7"),
        ShortcutAction.LovedSongs => StoredShortcut.Of("8"),
        ShortcutAction.Back => StoredShortcut.Of("["),
        ShortcutAction.NowPlaying => StoredShortcut.Of("f", shift: true),
        ShortcutAction.Lyrics => StoredShortcut.Of("l", alt: true),
        ShortcutAction.UpNext => StoredShortcut.Of("u", alt: true),
        ShortcutAction.Visualizer => StoredShortcut.Of("t"),
        ShortcutAction.Equalizer => StoredShortcut.Of("e", alt: true),
        ShortcutAction.MainWindow => StoredShortcut.Of("0"),
        ShortcutAction.BiggerCovers => StoredShortcut.Of("+"),
        ShortcutAction.SmallerCovers => StoredShortcut.Of("-"),
        ShortcutAction.NewPlaylist => StoredShortcut.Of("n"),
        ShortcutAction.NewSmartPlaylist => StoredShortcut.Of("n", alt: true),
        ShortcutAction.ImportMusic => StoredShortcut.Of("o"),
        ShortcutAction.AddFolder => StoredShortcut.Of("o", shift: true),
        ShortcutAction.FetchMissingInfo => StoredShortcut.Of("u", shift: true),
        ShortcutAction.BackUp => StoredShortcut.Of("b", alt: true),
        _ => null,
    };

    /// <summary>Shortcuts that belong to Windows or the standard commands, never assigned.</summary>
    public static readonly IReadOnlyList<(StoredShortcut Shortcut, string Name)> Reserved =
    [
        (StoredShortcut.Of("c"), "Copy"), (StoredShortcut.Of("v"), "Paste"), (StoredShortcut.Of("x"), "Cut"),
        (StoredShortcut.Of("a"), "Select All"), (StoredShortcut.Of("z"), "Undo"), (StoredShortcut.Of("y"), "Redo"),
        (StoredShortcut.Of(","), "Settings"), (StoredShortcut.Of("w"), "Close"), (StoredShortcut.Of("q"), "Exit"),
        (StoredShortcut.Of(((char)(StoredShortcut.F1 + 3)).ToString(), ctrl: false, alt: true), "Close Window"),
    ];

    public StoredShortcut? Shortcut(ShortcutAction action)
    {
        if (!custom.TryGetValue(action, out var stored)) return Default(action);
        return stored.IsEmpty ? null : stored;
    }

    public bool IsCustomized(ShortcutAction action) => custom.ContainsKey(action);

    /// <summary>Shown after a button's name in its tooltip, like " (Ctrl+S)"; empty without a shortcut.</summary>
    public string Hint(ShortcutAction action) => Shortcut(action) is { } shortcut ? $" ({shortcut.Display()})" : "";

    /// <summary>The action of a key press, if any.</summary>
    public ShortcutAction? Action(StoredShortcut pressed) =>
        Enum.GetValues<ShortcutAction>().Cast<ShortcutAction?>().FirstOrDefault(action => Shortcut(action!.Value) is { } shortcut && shortcut.Matches(pressed));

    /// <summary>Sets a shortcut, or returns why it cannot be used (taken by another command or by Windows).</summary>
    public string? Set(StoredShortcut stored, ShortcutAction action)
    {
        if (!stored.IsEmpty)
        {
            if (Reserved.FirstOrDefault(entry => entry.Shortcut.Matches(stored)) is { Name: not null } reserved)
                return $"{stored.Display()} is reserved for {reserved.Name}.";
            foreach (var other in Enum.GetValues<ShortcutAction>())
            {
                if (other != action && Shortcut(other) is { } taken && taken.Matches(stored))
                    return $"{stored.Display()} is already used by {Title(other)}.";
            }
        }
        if (Default(action) is { } original && original.Matches(stored)) custom.Remove(action);
        else if (Default(action) is null && stored.IsEmpty) custom.Remove(action);
        else custom[action] = stored;
        Save();
        return null;
    }

    public void Reset(ShortcutAction action)
    {
        custom.Remove(action);
        Save();
    }

    public void ResetAll()
    {
        custom = [];
        Save();
    }

    /// <summary>Reloads the saved shortcuts (after restoring a backup).</summary>
    public void Load()
    {
        custom = [];
        if (preferences.Data(Key) is { } data)
        {
            try
            {
                var saved = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(data) ?? [];
                foreach (var (name, value) in saved)
                {
                    if (!Enum.TryParse<ShortcutAction>(name, ignoreCase: true, out var action)) continue;
                    var key = value.TryGetProperty("key", out var k) ? k.GetString() ?? "" : "";
                    var modifiers = value.TryGetProperty("modifiers", out var m) ? m.GetInt32() : 0;
                    custom[action] = new StoredShortcut(key, modifiers);
                }
            }
            catch (JsonException)
            {
            }
        }
        Changed?.Invoke();
    }

    private void Save()
    {
        if (custom.Count == 0) preferences.Remove(Key);
        else
        {
            // The Mac's raw values are camelCase case names.
            var saved = custom.ToDictionary(pair => char.ToLowerInvariant(pair.Key.ToString()[0]) + pair.Key.ToString()[1..],
                                            pair => new { key = pair.Value.Key, modifiers = pair.Value.Modifiers });
            preferences.Set(Key, JsonSerializer.SerializeToUtf8Bytes(saved));
        }
        Changed?.Invoke();
    }
}
