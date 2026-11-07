using Groovelight.Core.Library;

namespace Groovelight.Model;

/// <summary>The pages of the navigation pane (the Mac's sidebar items).</summary>
public enum PageKind { Search, RecentlyAdded, Artists, Albums, Songs, Genres, Shelf, AllPlaylists, LovedSongs, Playlist, Device }

/// <summary>A navigation pane item: a page, a playlist (by id) or a device (by id).</summary>
public sealed record SidebarItem(PageKind Kind, long PlaylistId = 0, string? DeviceId = null)
{
    public static readonly SidebarItem Search = new(PageKind.Search);
    public static readonly SidebarItem RecentlyAdded = new(PageKind.RecentlyAdded);
    public static readonly SidebarItem Artists = new(PageKind.Artists);
    public static readonly SidebarItem Albums = new(PageKind.Albums);
    public static readonly SidebarItem Songs = new(PageKind.Songs);
    public static readonly SidebarItem Genres = new(PageKind.Genres);
    public static readonly SidebarItem Shelf = new(PageKind.Shelf);
    public static readonly SidebarItem AllPlaylists = new(PageKind.AllPlaylists);
    public static readonly SidebarItem LovedSongs = new(PageKind.LovedSongs);

    public static SidebarItem Playlist(long id) => new(PageKind.Playlist, id);
    public static SidebarItem Device(string id) => new(PageKind.Device, DeviceId: id);

    /// <summary>The tag stored on a navigation item.</summary>
    public string Tag => Kind switch
    {
        PageKind.Playlist => $"playlist:{PlaylistId}",
        PageKind.Device => $"device:{DeviceId}",
        _ => Kind.ToString(),
    };

    public static SidebarItem? FromTag(string? tag)
    {
        if (tag is null) return null;
        if (tag.StartsWith("playlist:", StringComparison.Ordinal) && long.TryParse(tag[9..], out var id)) return Playlist(id);
        if (tag.StartsWith("device:", StringComparison.Ordinal)) return Device(tag[7..]);
        return Enum.TryParse<PageKind>(tag, out var kind) ? new SidebarItem(kind) : null;
    }
}

/// <summary>Search result categories ("Albums ›" opens all of one).</summary>
public enum SearchCategory { Artists, Albums, Songs, Credits }

/// <summary>A page pushed on top of the selected one (album, person, artist from search, a search category).</summary>
public abstract record Route
{
    public sealed record Album(AlbumSummary Summary) : Route;
    public sealed record Person(CreditPerson Who) : Route;
    public sealed record Artist(string Name) : Route;
    public sealed record SearchResults(SearchCategory Category, string Query) : Route;
}

/// <summary>What the right side pane shows.</summary>
public enum SidePanel { None, Queue, Lyrics }

/// <summary>A group of songs that menus can play or queue.</summary>
public abstract record SongSource
{
    public sealed record Album(string AlbumKey) : SongSource;
    public sealed record Playlist(long Id) : SongSource;
    public sealed record LovedSongs : SongSource;
    public sealed record Tracks(IReadOnlyList<Track> Items) : SongSource;
}
