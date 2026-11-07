using Microsoft.Data.Sqlite;

namespace Groovelight.Core.Library;

public enum AlbumSort { Artist, Title, Year, RecentlyAdded }

/// <summary>The library's reads, the same queries as the Mac's.</summary>
public static class LibraryQueries
{
    internal const string AlbumArtistSql = """
        CASE WHEN MAX(isCompilation) THEN 'Various Artists'
             ELSE COALESCE(NULLIF(MAX(albumArtist), ''), NULLIF(MAX(artist), ''), 'Unknown Artist') END
        """;

    internal const string ArtistNameSql = "COALESCE(NULLIF(TRIM(albumArtist), ''), NULLIF(TRIM(artist), ''), 'Unknown Artist')";

    public static List<AlbumSummary> Albums(this SqliteConnection db, AlbumSort sort = AlbumSort.Artist, string? artist = null)
    {
        var order = sort switch
        {
            AlbumSort.Artist => "artist COLLATE NOCASE, year, title COLLATE NOCASE",
            AlbumSort.Title => "title COLLATE NOCASE",
            AlbumSort.Year => "year DESC, artist COLLATE NOCASE",
            _ => "dateAdded DESC",
        };
        var arguments = new List<object?>();
        var filter = "";
        if (artist == ArtistSummary.Compilations)
        {
            filter = "WHERE isCompilation = 1";
        }
        else if (artist is not null)
        {
            filter = $"WHERE isCompilation = 0 AND {ArtistNameSql} = ? COLLATE NOCASE";
            arguments.Add(artist);
        }
        return db.Query($"""
            SELECT albumKey,
                   COALESCE(NULLIF(MAX(album), ''), 'Unknown Album') AS title,
                   {AlbumArtistSql} AS artist,
                   MAX(year) AS year,
                   MAX(genre) AS genre,
                   COUNT(*) AS trackCount,
                   SUM(duration) AS duration,
                   MAX(artworkHash) AS artworkHash,
                   MIN(dateAdded) AS dateAdded
            FROM track {filter}
            GROUP BY albumKey
            ORDER BY {order}
            """, Records.ReadAlbum, [.. arguments]);
    }

    public static List<AlbumSummary> RecentlyAddedAlbums(this SqliteConnection db, int limit = 60) =>
        db.Albums(AlbumSort.RecentlyAdded).Take(limit).ToList();

    public static List<ArtistSummary> Artists(this SqliteConnection db) => db.Query($"""
        SELECT {ArtistNameSql} AS name,
               COUNT(DISTINCT albumKey) AS albumCount,
               COUNT(*) AS trackCount,
               MAX(artworkHash) AS artworkHash
        FROM track
        WHERE isCompilation = 0
        GROUP BY {ArtistNameSql} COLLATE NOCASE
        ORDER BY name COLLATE NOCASE
        """, Records.ReadArtist);

    /// <summary>The "Compilations" entry for the artist list, or null when the library has no compilation albums.</summary>
    public static ArtistSummary? Compilations(this SqliteConnection db) => db.QueryOne("""
        SELECT COUNT(DISTINCT albumKey) AS albumCount, COUNT(*) AS trackCount, MAX(artworkHash) AS artworkHash
        FROM track WHERE isCompilation = 1
        """, row => row.Get<int>("trackCount") > 0
            ? new ArtistSummary(ArtistSummary.Compilations, row.Get<int>("albumCount"), row.Get<int>("trackCount"), row.Get<string>("artworkHash"))
            : null);

    public static List<string> Genres(this SqliteConnection db) => db.Column<string>("""
        SELECT DISTINCT TRIM(genre) AS g FROM track WHERE genre IS NOT NULL AND TRIM(genre) != ''
        ORDER BY g COLLATE NOCASE
        """);

    public static List<Track> TracksOfAlbum(this SqliteConnection db, string albumKey) =>
        db.FetchTracks("SELECT * FROM track WHERE albumKey = ? ORDER BY discNumber, trackNumber, title COLLATE NOCASE", albumKey);

    public static List<Track> TracksOfArtist(this SqliteConnection db, string artist) => db.FetchTracks($"""
        SELECT * FROM track WHERE {ArtistNameSql} = ? COLLATE NOCASE OR artist = ? COLLATE NOCASE
        ORDER BY year, album COLLATE NOCASE, discNumber, trackNumber
        """, artist, artist);

    public static List<Track> TracksOfGenre(this SqliteConnection db, string genre) => db.FetchTracks("""
        SELECT * FROM track WHERE TRIM(genre) = ? COLLATE NOCASE
        ORDER BY artist COLLATE NOCASE, album COLLATE NOCASE, discNumber, trackNumber
        """, genre);

    public static List<Track> AllTracks(this SqliteConnection db) => db.FetchTracks("SELECT * FROM track ORDER BY title COLLATE NOCASE");

    public static List<Playlist> Playlists(this SqliteConnection db) =>
        db.Query("SELECT * FROM playlist ORDER BY name COLLATE NOCASE", Records.ReadPlaylist);

    /// <summary>Songs of a playlist: its items in order, or for a smart playlist the songs matching its rules.</summary>
    public static List<Track> TracksOfPlaylist(this SqliteConnection db, long playlistId)
    {
        if (db.FetchPlaylist(playlistId)?.Rules is { } rules) return db.TracksMatching(rules);
        return db.FetchTracks("""
            SELECT track.* FROM playlistItem JOIN track ON track.id = playlistItem.trackId
            WHERE playlistItem.playlistId = ? ORDER BY playlistItem.position
            """, playlistId);
    }

    /// <summary>Loved Songs: most recently loved first (songs loved before dates were kept come last, by artist and album).</summary>
    public static List<Track> LovedTracks(this SqliteConnection db) => db.FetchTracks($"""
        SELECT * FROM track WHERE isLoved = 1
        ORDER BY lovedAt IS NULL, lovedAt DESC, {ArtistNameSql} COLLATE NOCASE, album COLLATE NOCASE, discNumber, trackNumber
        """);

    /// <summary>Loved Songs and every playlist with its count, length and covers (for the All Playlists grid).</summary>
    public static PlaylistOverview PlaylistOverview(this SqliteConnection db)
    {
        static List<string> Covers(IEnumerable<Track> tracks) =>
            tracks.Select(track => track.ArtworkHash).OfType<string>().Distinct().Take(4).ToList();
        var loved = db.LovedTracks();
        var summaries = db.Playlists().Select(playlist =>
        {
            var tracks = playlist.Id is { } id ? db.TracksOfPlaylist(id) : [];
            return new PlaylistSummary(playlist, tracks.Count, tracks.Sum(track => track.Duration), Covers(tracks));
        }).ToList();
        return new PlaylistOverview(loved.Count, loved.Sum(track => track.Duration), Covers(loved), summaries);
    }

    public static List<LibraryRoot> Roots(this SqliteConnection db) => db.Query("SELECT * FROM libraryRoot ORDER BY path", Records.ReadRoot);

    /// <summary>Online album info (credits, background) cached for an album, with when it was fetched.</summary>
    public static (byte[] Data, DateTime FetchedAt)? AlbumInfo(this SqliteConnection db, string albumKey)
    {
        var rows = db.Query("SELECT data, fetchedAt FROM albumInfo WHERE albumKey = ?",
                            row => (row.Required<byte[]>("data"), row.Get<DateTime>("fetchedAt")), albumKey);
        return rows.Count == 0 ? null : rows[0];
    }

    public static (byte[] Data, DateTime FetchedAt)? ArtistInfo(this SqliteConnection db, string name)
    {
        var rows = db.Query("SELECT data, fetchedAt FROM artistInfo WHERE artistKey = ?",
                            row => (row.Required<byte[]>("data"), row.Get<DateTime>("fetchedAt")), name.ToLowerInvariant());
        return rows.Count == 0 ? null : rows[0];
    }

    /// <summary>How many songs each library folder holds, by folder id.</summary>
    public static Dictionary<long, int> TrackCountsByRoot(this SqliteConnection db) =>
        db.Query("SELECT rootId, COUNT(*) AS n FROM track GROUP BY rootId", row => (row.Get<long>("rootId"), row.Get<int>("n")))
          .ToDictionary(pair => pair.Item1, pair => pair.Item2);
}
