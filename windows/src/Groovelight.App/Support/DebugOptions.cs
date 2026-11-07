using System.Globalization;
using Groovelight.Core.Library;
using Groovelight.Model;

namespace Groovelight.Support;

/// <summary>
/// Command line options for checking the UI over SSH (the Mac's debug tour launch arguments):
/// <c>--debug-data &lt;folder&gt;</c> uses another library, <c>--debug-library &lt;folder&gt;</c> adds a music folder,
/// <c>--debug-page &lt;page&gt;</c> opens a page (albums, artists, songs, genres, shelf, playlists, loved, search:&lt;text&gt;,
/// settings, album:&lt;title&gt;), <c>--debug-play</c> starts the first album, <c>--debug-panel lyrics|queue</c>,
/// <c>--debug-now-playing</c>, and <c>--debug-snapshot-delay &lt;seconds&gt;</c>.
/// </summary>
internal static class DebugOptions
{
    private static string? Value(string name)
    {
        var args = Environment.GetCommandLineArgs();
        var index = Array.IndexOf(args, name);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }

    private static bool Flag(string name) => Environment.GetCommandLineArgs().Contains(name);

    public static string? DataDirectory => Value("--debug-data");

    /// <summary><c>--debug-window-size 1000x700</c>: the window's size in display-independent pixels.</summary>
    public static (int Width, int Height)? WindowSize =>
        Value("--debug-window-size")?.Split('x') is [var width, var height] && int.TryParse(width, out var w) && int.TryParse(height, out var h) ? (w, h) : null;

    public static double SnapshotDelay =>
        double.TryParse(Value("--debug-snapshot-delay"), NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds) ? seconds : 3;

    public static async void Apply(MainWindow window)
    {
        var model = AppModel.Current;
        if (Value("--debug-library") is { } library) model.AddLibraryFolder(library);
        // Wireless sync on (as its Settings switch).
        if (Flag("--debug-wireless") && model.Wireless is { } wireless)
        {
            try { wireless.IsEnabled = true; }
            catch (Exception error) { CrashLog.Write(error, "debug wireless"); }
        }
        if (Value("--debug-page") is { } page)
        {
            switch (page)
            {
                case "settings": window.ShowSettings(); break;
                case var section when section.StartsWith("settings:", StringComparison.Ordinal):
                    model.Preferences.Set(Views.SettingsPage.LastSectionKey, section[9..]);
                    window.ShowSettings();
                    break;
                case var search when search.StartsWith("search:", StringComparison.Ordinal): model.SearchText = search[7..]; break;
                case var album when album.StartsWith("album:", StringComparison.Ordinal):
                    model.Selection = SidebarItem.Albums;
                    await Task.Delay(800);
                    var key = await Task.Run(() => model.Database.Read(db => db.Albums().FirstOrDefault(item => item.Title.Contains(album[6..], StringComparison.OrdinalIgnoreCase))));
                    if (key is not null) model.ShowAlbum(key);
                    break;
                default:
                    if (SidebarItem.FromTag(page switch
                        {
                            "albums" => "Albums", "artists" => "Artists", "songs" => "Songs", "genres" => "Genres", "shelf" => "Shelf",
                            "playlists" => "AllPlaylists", "loved" => "LovedSongs", "recent" => "RecentlyAdded", _ => page,
                        }) is { } item) model.Selection = item;
                    break;
            }
        }
        if (Flag("--debug-play"))
        {
            await Task.Delay(1500);
            var first = await Task.Run(() => model.Database.Read(db => db.Albums().FirstOrDefault()));
            if (first is not null)
            {
                model.PlayAlbum(first);
                if (Flag("--debug-mute")) model.Player.Volume = 0;
            }
        }
        if (Flag("--debug-equalizer"))
        {
            window.ShowEqualizer();
        }
        if (Flag("--debug-mini")) window.ShowMiniPlayer();
        // Before the visualizer opens, so it starts in that style.
        if (Value("--debug-visualizer-style") is { } style) model.Preferences.Set(Shell.VisualizerView.StyleKey, style);
        if (Flag("--debug-visualizer")) window.ShowVisualizer();
        // A vintage player in Now Playing ("vinyl", "cassette", "compactDisc", "pcPlayer", "corona"), a cassette by name, the Cassettes window.
        if (Value("--debug-skin") is { } skin)
        {
            model.Preferences.Set(Skins.SkinInfo.PcThemeStorageKey, skin == "corona" ? "corona" : "classic");
            model.Preferences.Set(Skins.SkinInfo.StorageKey, skin == "corona" ? "pcPlayer" : skin);
        }
        if (Value("--debug-cassette") is { } cassette && SkinViews.SkinStore.Cassettes.All.FirstOrDefault(design => design.Name == cassette) is { } design)
            model.Preferences.Set(Skins.SkinInfo.CassetteStorageKey, design.Id.ToString().ToUpperInvariant());
        if (Flag("--debug-cassettes")) SkinViews.CassettesWindow.Show();
        if (Value("--debug-import") is { } import)
        {
            await Task.Delay(1500);
            model.Files.ImportItems([import]);
        }
        if (Value("--debug-fix") is { } fix)
        {
            await Task.Delay(1500);
            var album = await Task.Run(() => model.Database.Read(db => db.Albums().FirstOrDefault(item => item.Title.Contains(fix, StringComparison.OrdinalIgnoreCase))));
            if (album is not null) model.Request(new DialogRequest.FixMetadata(await model.TracksAsync(new SongSource.Album(album.AlbumKey))));
        }
        if (Value("--debug-request") is { } request)
        {
            await Task.Delay(1500);
            switch (request)
            {
                case "organize": model.Request(new DialogRequest.Organize(null)); break;
                case "getinfo":
                    var tracks = await Task.Run(() => model.Database.Read(db => db.AllTracks().Take(1).ToList()));
                    model.GetInfo(tracks);
                    break;
                case "smart": model.NewSmartPlaylist(); break;
            }
        }
        if (Value("--debug-panel") is { } panel) model.SidePanel = panel == "lyrics" ? SidePanel.Lyrics : SidePanel.Queue;
        if (Flag("--debug-now-playing"))
        {
            await Task.Delay(2000);
            model.IsShowingNowPlaying = true;
            // Now Playing's lyrics or Up Next ("lyrics", "queue").
            if (Value("--debug-now-playing-panel") is { } shown)
            {
                model.IsShowingLyrics = shown == "lyrics";
                model.IsShowingNowPlayingQueue = shown == "queue";
            }
        }
    }
}
