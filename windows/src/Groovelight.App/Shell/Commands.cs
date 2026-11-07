using Groovelight.Audio;
using Groovelight.Model;
using Groovelight.Views;

namespace Groovelight.Shell;

/// <summary>What each menu command and shortcut does (the Mac's PlayerCommands).</summary>
public static class Commands
{
    private static AppModel Model => AppModel.Current;
    private static MainWindow Window => MainWindow.Current;

    /// <summary>The navigation pane's pages in order, like the numbered sections of Music.</summary>
    public static readonly IReadOnlyList<(SidebarItem Item, ShortcutAction Action)> Pages =
    [
        (SidebarItem.RecentlyAdded, ShortcutAction.RecentlyAdded), (SidebarItem.Artists, ShortcutAction.Artists), (SidebarItem.Albums, ShortcutAction.Albums),
        (SidebarItem.Songs, ShortcutAction.Songs), (SidebarItem.Genres, ShortcutAction.Genres), (SidebarItem.Shelf, ShortcutAction.Shelf),
        (SidebarItem.AllPlaylists, ShortcutAction.AllPlaylists), (SidebarItem.LovedSongs, ShortcutAction.LovedSongs),
    ];

    /// <summary>The cover size the View menu changes: the Albums page's or the Shelf's.</summary>
    public static CoverSize? Covers => Model.IsShowingNowPlaying || Model.Path.Count > 0 ? null
        : Model.Selection.Kind == PageKind.Albums ? CoverSize.Albums : Model.Selection.Kind == PageKind.Shelf ? CoverSize.Shelf : null;

    public static bool IsEnabled(ShortcutAction action) => action switch
    {
        ShortcutAction.SkipForward or ShortcutAction.SkipBack or ShortcutAction.Love or ShortcutAction.GoToCurrentSong => Model.Player.Current is not null,
        ShortcutAction.Back => Model.Path.Count > 0 && !Model.IsShowingNowPlaying,
        ShortcutAction.BiggerCovers or ShortcutAction.SmallerCovers or ShortcutAction.DefaultCoverSize => Covers is not null,
        _ => true,
    };

    public static void Run(ShortcutAction action)
    {
        if (!IsEnabled(action)) return;
        var player = Model.Player;
        switch (action)
        {
            case ShortcutAction.PlayPause: player.TogglePlayPause(); break;
            case ShortcutAction.Next: player.Next(); break;
            case ShortcutAction.Previous: player.Previous(); break;
            case ShortcutAction.SkipForward: Model.SkipBy(10); break;
            case ShortcutAction.SkipBack: Model.SkipBy(-10); break;
            case ShortcutAction.VolumeUp: player.Volume = Math.Min(1, player.Volume + 0.1f); break;
            case ShortcutAction.VolumeDown: player.Volume = Math.Max(0, player.Volume - 0.1f); break;
            case ShortcutAction.Mute: Model.ToggleMute(); break;
            case ShortcutAction.Shuffle: player.SetShuffle(!player.IsShuffled); break;
            case ShortcutAction.CycleRepeat: Model.CycleRepeat(); break;
            case ShortcutAction.Love: Model.ToggleLovedCurrent(); break;
            case ShortcutAction.GoToCurrentSong: Model.GoToCurrentSong(); break;
            case ShortcutAction.Search: Window.HideSettings(); Model.ShowSearch(); break;
            case ShortcutAction.Back: Model.GoBack(); break;
            case ShortcutAction.NowPlaying: Model.IsShowingNowPlaying = !Model.IsShowingNowPlaying; break;
            case ShortcutAction.Lyrics: Model.ToggleLyrics(); break;
            case ShortcutAction.UpNext: Model.ToggleUpNext(); break;
            case ShortcutAction.Visualizer: Window.ShowVisualizer(); break;
            case ShortcutAction.Equalizer: Window.ShowEqualizer(); break;
            case ShortcutAction.MainWindow: Window.BringToFront(); break;
            case ShortcutAction.BiggerCovers: Covers?.Change(1); break;
            case ShortcutAction.SmallerCovers: Covers?.Change(-1); break;
            case ShortcutAction.DefaultCoverSize: Covers?.Reset(); break;
            case ShortcutAction.NewPlaylist: Model.NewPlaylist(); break;
            case ShortcutAction.NewSmartPlaylist: Model.NewSmartPlaylist(); break;
            case ShortcutAction.ImportMusic: Window.ChooseAndImport(); break;
            case ShortcutAction.AddFolder: Window.ChooseLibraryFolder(); break;
            case ShortcutAction.FetchMissingInfo:
                if (Model.Metadata.IsFetchingLibraryInfo) Model.Metadata.StopFetchingMissingInfo();
                else Model.Metadata.FetchMissingInfo();
                break;
            case ShortcutAction.BackUp: Window.ChooseAndBackUp(); break;
            default:
                if (Pages.FirstOrDefault(page => page.Action == action) is { Item: not null } page)
                {
                    Model.IsShowingNowPlaying = false;
                    Window.HideSettings();
                    Model.Selection = page.Item;
                }
                break;
        }
    }

    public static string RepeatTitle(RepeatMode mode) => mode switch { RepeatMode.All => "All", RepeatMode.One => "One", _ => "Off" };
}
