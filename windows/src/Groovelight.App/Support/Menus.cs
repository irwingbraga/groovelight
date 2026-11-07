using Groovelight.Core.Library;
using Groovelight.Model;
using Microsoft.UI.Xaml.Controls;

namespace Groovelight.Support;

/// <summary>The context menus shared by every page (the Mac's TrackContextMenu, QueueMenuItems and the album menu).</summary>
public static class Menus
{
    private static AppModel Model => AppModel.Current;

    /// <summary>The "Send To" submenu (devices and folders), filled in by device sync.</summary>
    public static Func<SongSource, MenuFlyoutSubItem?>? SendTo { get; set; }

    public static MenuFlyoutItem Item(string text, Action action, string? glyph = null, bool enabled = true)
    {
        var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
        if (glyph is not null) item.Icon = new FontIcon { Glyph = glyph };
        item.Click += (_, _) => action();
        return item;
    }

    public static MenuFlyoutSubItem SubItem(string text, IEnumerable<MenuFlyoutItemBase> items, string? glyph = null)
    {
        var sub = new MenuFlyoutSubItem { Text = text };
        if (glyph is not null) sub.Icon = new FontIcon { Glyph = glyph };
        foreach (var item in items) sub.Items.Add(item);
        return sub;
    }

    public static MenuFlyout Flyout(IEnumerable<MenuFlyoutItemBase> items)
    {
        var flyout = new MenuFlyout();
        foreach (var item in items) flyout.Items.Add(item);
        return flyout;
    }

    /// <summary>"Play Next", "Add to Up Next" and "Send To" for an album or playlist.</summary>
    public static IEnumerable<MenuFlyoutItemBase> QueueItems(SongSource source)
    {
        yield return Item("Play Next", () => Model.Enqueue(source, next: true), Glyphs.PlayNext);
        yield return Item("Add to Up Next", () => Model.Enqueue(source, next: false), Glyphs.AddToQueue);
        if (SendTo?.Invoke(source) is { } send) yield return send;
    }

    /// <summary>The menu of songs. <paramref name="contextAlbumKey"/>: the album page it is shown on ("Go to Album" is left out).</summary>
    public static IEnumerable<MenuFlyoutItemBase> TrackItems(IReadOnlyList<Track> tracks, string? contextAlbumKey = null)
    {
        yield return Item("Play", () => Model.Play(tracks), Glyphs.Play);
        yield return Item("Play Next", () => Model.PlayNext(tracks), Glyphs.PlayNext);
        yield return Item("Add to Up Next", () => Model.AddToUpNext(tracks), Glyphs.AddToQueue);
        yield return new MenuFlyoutSeparator();
        if (tracks.Count == 1)
        {
            var track = tracks[0];
            yield return Item(track.IsLoved ? "Undo Love" : "Love", () => Model.ToggleLoved(track), track.IsLoved ? Glyphs.HeartFilled : Glyphs.Heart);
        }
        yield return SubItem("Add to Playlist", AddToPlaylistItems(tracks), Glyphs.AddToPlaylist);
        yield return new MenuFlyoutSeparator();
        // Only when every song shares the artist or album.
        var artists = tracks.Select(ArtistPageName).Distinct().ToList();
        if (artists.Count == 1 && artists[0] is { } artist) yield return Item("Go to Artist", () => Model.ShowArtist(artist), Glyphs.Artist);
        var albums = tracks.Select(track => track.AlbumKey).Distinct().ToList();
        if (albums.Count == 1 && albums[0] != contextAlbumKey) yield return Item("Go to Album", () => Model.ShowAlbum(albums[0]), Glyphs.Album);
        yield return new MenuFlyoutSeparator();
        yield return Item("Get Info…", () => Model.GetInfo(tracks), Glyphs.Info);
        if (tracks.Count == 1) yield return Item("Credits…", () => Model.ShowCredits(tracks[0]), Glyphs.People);
        yield return Item("Fix Metadata…", () => Model.Request(new DialogRequest.FixMetadata(tracks)), Glyphs.Wand);
        yield return Item("Show in File Explorer", () => AppModel.ShowInExplorer(tracks), Glyphs.Folder);
        if (SendTo?.Invoke(new SongSource.Tracks(tracks)) is { } send) yield return send;
    }

    public static IEnumerable<MenuFlyoutItemBase> AddToPlaylistItems(IReadOnlyList<Track> tracks)
    {
        yield return Item("New Playlist", () => Model.NewPlaylist(tracks), Glyphs.Add);
        var playlists = Model.Playlists.Where(playlist => !playlist.IsSmart).ToList();
        if (playlists.Count > 0) yield return new MenuFlyoutSeparator();
        foreach (var playlist in playlists) yield return Item(playlist.Name, () => Model.Add(tracks, playlist));
    }

    /// <summary>The menu of an album (its cover in a grid, its page's "⋯").</summary>
    public static IEnumerable<MenuFlyoutItemBase> AlbumItems(AlbumSummary album, bool includePlay = true)
    {
        if (includePlay)
        {
            yield return Item("Play", () => Model.PlayAlbum(album), Glyphs.Play);
            yield return Item("Shuffle", () => Model.PlayAlbum(album, shuffle: true), Glyphs.Shuffle);
        }
        foreach (var item in QueueItems(new SongSource.Album(album.AlbumKey))) yield return item;
        yield return new MenuFlyoutSeparator();
        yield return Item("Get Info…", () => Model.GetInfo(album.AlbumKey), Glyphs.Info);
        yield return Item("Fix Metadata…", async () =>
        {
            var tracks = await Model.TracksAsync(new SongSource.Album(album.AlbumKey));
            Model.Request(new DialogRequest.FixMetadata(tracks));
        }, Glyphs.Wand);
    }

    /// <summary>Name of the song's page under Artists (album artist first). Null for compilations.</summary>
    public static string? ArtistPageName(Track track)
    {
        if (track.IsCompilation) return null;
        foreach (var name in new[] { track.AlbumArtist, track.Artist })
        {
            if (name?.Trim() is { Length: > 0 } trimmed) return trimmed;
        }
        return "Unknown Artist";
    }
}

/// <summary>Segoe Fluent Icons used across the app (the Mac's SF Symbols).</summary>
public static class Glyphs
{
    public const string Play = "", Pause = "", Next = "", Previous = "", Shuffle = "";
    public const string Repeat = "", RepeatOne = "", Heart = "", HeartFilled = "", Lyrics = "";
    public const string Queue = "", PlayNext = "", AddToQueue = "", AddToPlaylist = "", Add = "";
    public const string Artist = "", Album = "", Info = "", People = "", Wand = "", Folder = "";
    public const string Volume = "", Mute = "", Volume1 = "", Volume2 = "", Volume3 = "";
    public const string Speaker = "", Moon = "", More = "", Settings = "", Search = "", Clock = "";
    public const string Note = "", Songs = "", Genres = "", Shelf = "", Grid = "", Delete = "";
    public const string Edit = "", Rename = "", Export = "", Import = "", Refresh = "", Close = "";
    public const string Device = "", Phone = "", Eject = "", Sync = "", Check = "", Back = "";
    public const string FullScreen = "", BackToWindow = "", Visualizer = "", Equalizer = "", Cassette = "";
    public const string Mini = "", Smart = "", Link = "", Globe = "", Download = "", Warning = "";
    public const string Chevron = "", ChevronDown = "", Star = "", StarFilled = "", Library = "";
}
