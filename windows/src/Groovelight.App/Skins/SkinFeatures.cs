using Groovelight.Model;
using Groovelight.Skins;
using Groovelight.Support;
using Groovelight.Views;
using Microsoft.UI.Xaml.Controls;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace Groovelight.SkinViews;

/// <summary>The user's cassettes (in the data folder's Cassettes, a folder for each, as on the Mac).</summary>
public static class SkinStore
{
    private static CassetteStore? cassettes;

    public static CassetteStore Cassettes => cassettes ??= new CassetteStore(Path.Combine(AppModel.Current.DataDirectory, "Cassettes"));

    /// <summary>Whether a file opened with the app is a cassette to add (a shared zip, a folder, or its cassette.json).</summary>
    public static bool IsCassette(string path) =>
        path.EndsWith(".cassette", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".cassette.zip", StringComparison.OrdinalIgnoreCase)
        || Path.GetFileName(path).Equals(CassetteStore.FileName, StringComparison.OrdinalIgnoreCase);
}

/// <summary>
/// The sound of a cassette deck cueing: holding Rewind or Fast Forward with the heads on the tape, the music racing by
/// as a high chatter over the motor and the hiss. It runs while the scan goes on (each step keeps it going) and stops a
/// moment after the last; off when turned off in Settings.
/// </summary>
public static class TapeCue
{
    private static MediaPlayer? player;
    private static Microsoft.UI.Dispatching.DispatcherQueueTimer? stopping;

    public static bool IsEnabled => AppModel.Current.Preferences.Bool(SkinInfo.TapeCueStorageKey, true);

    /// <summary>One step of a scan: starts the sound, or keeps it going.</summary>
    public static void Cue()
    {
        if (!IsEnabled) return;
        if (player is null)
        {
            var file = Path.Combine(AppContext.BaseDirectory, "Skins", "TapeCue.wav");
            if (!File.Exists(file)) return;
            player = new MediaPlayer { IsLoopingEnabled = true, Source = MediaSource.CreateFromUri(new Uri(file)), AudioCategory = MediaPlayerAudioCategory.SoundEffects };
        }
        if (player.PlaybackSession.PlaybackState != MediaPlaybackState.Playing)
        {
            var length = player.PlaybackSession.NaturalDuration;
            if (length > TimeSpan.Zero) player.PlaybackSession.Position = TimeSpan.FromSeconds(Random.Shared.NextDouble() * length.TotalSeconds);
            player.Volume = 0.55;
            player.Play();
        }
        // The scan steps every 0.15 s: a little longer without one, the key was let go.
        stopping ??= AppModel.Current.Queue.CreateTimer();
        stopping.Interval = TimeSpan.FromMilliseconds(320);
        stopping.IsRepeating = false;
        stopping.Tick -= Stop;
        stopping.Tick += Stop;
        stopping.Stop();
        stopping.Start();
    }

    private static void Stop(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args) => player?.Pause();
}

internal static class SkinFeatures
{
    private static AppModel Model => AppModel.Current;

    public static void Register()
    {
        NowPlayingView.DeckFactory = skin => SkinInfo.ParseSkin(skin) is var parsed && parsed != NowPlayingSkin.Cover ? new DeckView(parsed) : null;
        NowPlayingView.SkinMenu = MenuItems;
        MainWindow.CassettesOpener = CassettesWindow.Show;
        var opener = MainWindow.FileOpener;
        MainWindow.FileOpener = paths =>
        {
            var cassettes = paths.Where(SkinStore.IsCassette).ToList();
            foreach (var cassette in cassettes) _ = OpenCassetteAsync(cassette);
            var rest = paths.Except(cassettes).ToList();
            if (rest.Count > 0) opener?.Invoke(rest);
        };
        SettingsPage.PlaybackExtras.Add(_ =>
        {
            var panel = new StackPanel { Spacing = 4 };
            panel.Children.Add(SettingsPage.Header("Cassette Deck"));
            panel.Children.Add(new SettingsCard("Tape sound when cueing",
                "In Now Playing's cassette deck, holding Rewind or Fast Forward plays the tape racing past the heads, as a real deck does.",
                SettingsPage.Toggle(TapeCue.IsEnabled, on => Model.Preferences.Set(SkinInfo.TapeCueStorageKey, on))));
            return panel;
        });
    }

    /// <summary>The look menu: Cover, Vinyl, Cassette, CD or PC Player, the PC Player's theme, the cassette, and the Cassettes window.</summary>
    private static IEnumerable<MenuFlyoutItemBase> MenuItems()
    {
        var prefs = Model.Preferences;
        var skin = SkinInfo.ParseSkin(prefs.String(SkinInfo.StorageKey));
        foreach (var option in Enum.GetValues<NowPlayingSkin>())
        {
            var item = new RadioMenuFlyoutItem { Text = option.DisplayName(), GroupName = "skin", IsChecked = option == skin };
            item.Click += (_, _) => prefs.Set(SkinInfo.StorageKey, option.RawValue());
            yield return item;
        }
        yield return new MenuFlyoutSeparator();
        var theme = SkinInfo.ParseTheme(prefs.String(SkinInfo.PcThemeStorageKey));
        var themes = new MenuFlyoutSubItem { Text = "PC Player Theme" };
        foreach (var option in Enum.GetValues<PcTheme>())
        {
            var item = new RadioMenuFlyoutItem { Text = option.DisplayName(), GroupName = "pcTheme", IsChecked = option == theme };
            item.Click += (_, _) =>
            {
                prefs.Set(SkinInfo.PcThemeStorageKey, option.RawValue());
                prefs.Set(SkinInfo.StorageKey, NowPlayingSkin.PcPlayer.RawValue());
            };
            themes.Items.Add(item);
        }
        yield return themes;
        var chosen = SkinStore.Cassettes.Design(prefs.String(SkinInfo.CassetteStorageKey)).Id;
        var cassettes = new MenuFlyoutSubItem { Text = "Cassette" };
        foreach (var design in SkinStore.Cassettes.All)
        {
            var item = new RadioMenuFlyoutItem { Text = design.Name, GroupName = "cassette", IsChecked = design.Id == chosen };
            item.Click += (_, _) =>
            {
                prefs.Set(SkinInfo.CassetteStorageKey, design.Id.ToString().ToUpperInvariant());
                prefs.Set(SkinInfo.StorageKey, NowPlayingSkin.Cassette.RawValue());
            };
            cassettes.Items.Add(item);
        }
        yield return cassettes;
        yield return new MenuFlyoutSeparator();
        yield return Menus.Item("Cassettes…", CassettesWindow.Show);
    }

    /// <summary>A cassette opened with the app (Explorer, Open With): added, chosen and shown in Now Playing.</summary>
    public static async Task OpenCassetteAsync(string path)
    {
        try
        {
            var design = SkinStore.Cassettes.Import(path);
            Model.Preferences.Set(SkinInfo.CassetteStorageKey, design.Id.ToString().ToUpperInvariant());
            Model.Preferences.Set(SkinInfo.StorageKey, NowPlayingSkin.Cassette.RawValue());
            Model.IsShowingNowPlaying = true;
        }
        catch (Exception error) when (error is IOException or FormatException or UnauthorizedAccessException or InvalidDataException)
        {
            if (MainWindow.Current.RootXamlRoot is { } root) await Ui.Alert(root, "Cassette", error.Message);
        }
    }
}
