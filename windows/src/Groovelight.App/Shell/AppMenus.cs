using Groovelight.Audio;
using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Xaml.Controls;

namespace Groovelight.Shell;

/// <summary>
/// The menu bar in the title bar (the Mac's menus): File, Edit, Controls, View and Help, every command with its
/// remappable shortcut shown. Rebuilt when what it shows changes (playing, shuffle, the page).
/// </summary>
public sealed class AppMenus
{
    private static AppModel Model => AppModel.Current;
    private static MainWindow Window => MainWindow.Current;
    public MenuBar Bar { get; } = new() { VerticalAlignment = Microsoft.UI.Xaml.VerticalAlignment.Center };
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? pending;

    /// <summary>Extra items of the File menu's Library submenu and other parts, added by later features.</summary>
    public static List<Func<IEnumerable<MenuFlyoutItemBase>>> HelpItems { get; } = [];

    public AppMenus()
    {
        Rebuild();
        Model.Player.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName is nameof(PlaybackController.State) or nameof(PlaybackController.Current) or nameof(PlaybackController.IsShuffled)
                or nameof(PlaybackController.RepeatMode) or nameof(PlaybackController.Rate) or nameof(PlaybackController.BitPerfect)) Schedule();
            else if (args.PropertyName == nameof(PlaybackController.Volume) && (Model.Player.Volume == 0) != wasMuted) Schedule();
        };
        Model.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName is nameof(AppModel.Selection) or nameof(AppModel.Path) or nameof(AppModel.IsShowingNowPlaying) or nameof(AppModel.ScanProgress)) Schedule();
        };
        Model.SleepTimer.PropertyChanged += (_, _) => Schedule();
        Model.Metadata.PropertyChanged += (_, args) => { if (args.PropertyName == nameof(MetadataStore.IsFetchingLibraryInfo)) Schedule(); };
        Model.Shortcuts.Changed += Schedule;
    }

    private bool wasMuted;

    private void Schedule()
    {
        pending ??= Model.Queue.CreateTimer();
        pending.Interval = TimeSpan.FromMilliseconds(150);
        pending.IsRepeating = false;
        pending.Tick -= OnTick;
        pending.Tick += OnTick;
        pending.Start();
    }

    private void OnTick(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args) => Rebuild();

    private static MenuFlyoutItem Command(string text, ShortcutAction action, string? glyph = null)
    {
        var item = Menus.Item(text, () => Commands.Run(action), glyph, Commands.IsEnabled(action));
        if (Model.Shortcuts.Shortcut(action) is { } shortcut) item.KeyboardAcceleratorTextOverride = shortcut.Display();
        return item;
    }

    private static MenuFlyoutItem Item(string text, Action action, bool enabled = true, string? glyph = null) => Menus.Item(text, action, glyph, enabled);

    public void Rebuild()
    {
        wasMuted = Model.Player.Volume == 0;
        Bar.Items.Clear();
        Bar.Items.Add(Menu("File", File()));
        Bar.Items.Add(Menu("Edit", Edit()));
        Bar.Items.Add(Menu("Controls", Controls()));
        Bar.Items.Add(Menu("View", View()));
        Bar.Items.Add(Menu("Help", Help()));
    }

    private static MenuBarItem Menu(string title, IEnumerable<MenuFlyoutItemBase> items)
    {
        var menu = new MenuBarItem { Title = title };
        foreach (var item in items) menu.Items.Add(item);
        return menu;
    }

    /// <summary>The playlist on screen for Export Playlist: Loved Songs (null id) or a playlist; none elsewhere.</summary>
    private static (bool Exportable, long? Id) ExportablePlaylist =>
        Model.Path.Count > 0 || Model.IsShowingNowPlaying ? (false, null)
        : Model.Selection.Kind == PageKind.Playlist ? (true, Model.Selection.PlaylistId)
        : Model.Selection.Kind == PageKind.LovedSongs ? (true, null) : (false, null);

    private IEnumerable<MenuFlyoutItemBase> File()
    {
        yield return Menus.SubItem("New", [Command("Playlist", ShortcutAction.NewPlaylist), Command("Smart Playlist…", ShortcutAction.NewSmartPlaylist)]);
        yield return new MenuFlyoutSeparator();
        yield return Command("Import…", ShortcutAction.ImportMusic, Glyphs.Import);
        yield return Command("Add Folder to Library…", ShortcutAction.AddFolder, Glyphs.Folder);
        var export = ExportablePlaylist;
        var library = new List<MenuFlyoutItemBase>
        {
            Item("Import Playlist…", Window.ChooseAndImportPlaylist),
            Item("Export Playlist…", () => Model.Request(new DialogRequest.ExportPlaylist(export.Id)), export.Exportable),
            new MenuFlyoutSeparator(),
            Item("Organize Library Files…", () => Model.Request(new DialogRequest.Organize(null))),
            Item(Window.UndoTitle, Window.UndoLastFileChange, Window.CanUndoFileChange),
            new MenuFlyoutSeparator(),
            Command(Model.Metadata.IsFetchingLibraryInfo ? "Stop Fetching Missing Info" : "Fetch Missing Info in Background", ShortcutAction.FetchMissingInfo),
            Item("Rescan Library Folders", Model.RescanAll, Model.ScanProgress is null),
            new MenuFlyoutSeparator(),
            Command("Back Up Library…", ShortcutAction.BackUp),
            Item("Restore from Backup…", Window.ChooseAndRestore),
        };
        yield return Menus.SubItem("Library", library);
        yield return new MenuFlyoutSeparator();
        yield return Item("Settings", Window.ShowSettings, glyph: Glyphs.Settings).With(item => item.KeyboardAcceleratorTextOverride = "Ctrl+,");
        yield return new MenuFlyoutSeparator();
        yield return Item("Exit", () => Microsoft.UI.Xaml.Application.Current.Exit());
    }

    private static IEnumerable<MenuFlyoutItemBase> Edit()
    {
        yield return Command("Search Library", ShortcutAction.Search, Glyphs.Search);
    }

    private IEnumerable<MenuFlyoutItemBase> Controls()
    {
        var player = Model.Player;
        yield return Command(player.State == PlaybackState.Playing ? "Pause" : "Play", ShortcutAction.PlayPause);
        yield return Command("Next", ShortcutAction.Next);
        yield return Command("Previous", ShortcutAction.Previous);
        yield return Command("Skip Forward 10 Seconds", ShortcutAction.SkipForward);
        yield return Command("Skip Back 10 Seconds", ShortcutAction.SkipBack);
        yield return new MenuFlyoutSeparator();
        yield return Command("Increase Volume", ShortcutAction.VolumeUp);
        yield return Command("Decrease Volume", ShortcutAction.VolumeDown);
        yield return Command(player.Volume == 0 ? "Unmute" : "Mute", ShortcutAction.Mute);
        yield return new MenuFlyoutSeparator();
        var shuffle = new ToggleMenuFlyoutItem { Text = "Shuffle", IsChecked = player.IsShuffled };
        shuffle.Click += (_, _) => player.SetShuffle(!player.IsShuffled);
        if (Model.Shortcuts.Shortcut(ShortcutAction.Shuffle) is { } shuffleKey) shuffle.KeyboardAcceleratorTextOverride = shuffleKey.Display();
        yield return shuffle;
        yield return Menus.SubItem("Repeat", Enum.GetValues<RepeatMode>().Select(mode => (MenuFlyoutItemBase)Radio(Commands.RepeatTitle(mode), "repeat", player.RepeatMode == mode, () => player.RepeatMode = mode)));
        yield return Command("Cycle Repeat Mode", ShortcutAction.CycleRepeat);
        var speed = Menus.SubItem("Playback Speed", PlaybackPrefs.Speeds.Select(rate => (MenuFlyoutItemBase)Radio(PlaybackPrefs.SpeedLabel(rate), "speed", player.Rate == rate, () => Model.SetRate(rate))));
        speed.IsEnabled = !player.BitPerfect;
        yield return speed;
        var bitPerfect = new ToggleMenuFlyoutItem { Text = "Bit-Perfect Playback", IsChecked = player.BitPerfect };
        bitPerfect.Click += (_, _) => Model.SetBitPerfect(!player.BitPerfect);
        yield return bitPerfect;
        var timer = Model.SleepTimer;
        var sleep = new List<MenuFlyoutItemBase> { Radio("Off", "sleep", !timer.IsActive, timer.Cancel), new MenuFlyoutSeparator() };
        foreach (var minutes in SleepTimer.Choices)
        {
            var title = minutes < 60 || minutes % 60 != 0 ? $"{minutes} Minutes" : $"{minutes / 60} Hour{(minutes == 60 ? "" : "s")}";
            sleep.Add(Radio(title, "sleep", timer.Mode is SleepTimer.TimerMode.Minutes chosen && chosen.Count == minutes, () => timer.Start(new SleepTimer.TimerMode.Minutes(minutes))));
        }
        sleep.Add(Radio("End of Current Song", "sleep", timer.Mode is SleepTimer.TimerMode.EndOfSong, () => timer.Start(new SleepTimer.TimerMode.EndOfSong())));
        yield return Menus.SubItem("Sleep Timer", sleep);
        yield return new MenuFlyoutSeparator();
        yield return Command("Love or Undo Love", ShortcutAction.Love);
        yield return Command("Go to Current Song", ShortcutAction.GoToCurrentSong);
    }

    private static RadioMenuFlyoutItem Radio(string text, string group, bool isChecked, Action action)
    {
        var item = new RadioMenuFlyoutItem { Text = text, GroupName = group, IsChecked = isChecked };
        item.Click += (_, _) => action();
        return item;
    }

    private IEnumerable<MenuFlyoutItemBase> View()
    {
        foreach (var (item, action) in Commands.Pages) yield return Command(ShortcutStore.Title(action), action);
        yield return Command("Back", ShortcutAction.Back, Glyphs.Back);
        yield return new MenuFlyoutSeparator();
        yield return Command("Bigger Covers", ShortcutAction.BiggerCovers);
        yield return Command("Smaller Covers", ShortcutAction.SmallerCovers);
        yield return Command("Default Cover Size", ShortcutAction.DefaultCoverSize);
        yield return new MenuFlyoutSeparator();
        yield return Command(Model.IsShowingNowPlaying ? "Hide Now Playing" : "Show Now Playing", ShortcutAction.NowPlaying);
        yield return Command("Lyrics", ShortcutAction.Lyrics, Glyphs.Lyrics);
        yield return Command("Up Next", ShortcutAction.UpNext, Glyphs.Queue);
        yield return new MenuFlyoutSeparator();
        yield return Command("Show Visualizer", ShortcutAction.Visualizer, Glyphs.Visualizer);
        yield return Command("Equalizer", ShortcutAction.Equalizer, Glyphs.Equalizer);
        yield return Item("Mini Player", Window.ShowMiniPlayer, glyph: Glyphs.Mini);
        yield return Item("Cassettes", Window.ShowCassettes, glyph: Glyphs.Cassette);
        yield return new MenuFlyoutSeparator();
        yield return Command("Library Window", ShortcutAction.MainWindow);
    }

    private static IEnumerable<MenuFlyoutItemBase> Help()
    {
        foreach (var extra in HelpItems) foreach (var item in extra()) yield return item;
        yield return Item("Groovelight on GitHub", () => AppModel.OpenUrl(AppLinks.Repository));
        yield return Item("Report an Issue…", () => AppModel.OpenUrl(AppLinks.Repository + "/issues"));
        yield return new MenuFlyoutSeparator();
        yield return Item("Acknowledgements", Window.ShowAcknowledgements);
        yield return Item("About Groovelight", Window.ShowAbout);
    }
}

public static class AppLinks
{
    public const string Repository = "https://github.com/irwingbraga/groovelight";
}
