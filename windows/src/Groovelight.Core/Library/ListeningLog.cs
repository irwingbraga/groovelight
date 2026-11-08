using Microsoft.Data.Sqlite;

namespace Groovelight.Core.Library;

/// <summary>
/// One listen (the Mac's listen table): a song played all the way, partly, or skipped, here, on a device, or on Last.fm.
/// Home's picks, playlists and charts are worked out from these.
/// </summary>
public sealed record Listen
{
    public static class Sources
    {
        public const string Mac = "mac";
        public const string Windows = "windows";
        public const string LastFm = "lastfm";
        /// <summary>The song's play count from before the log (<see cref="Count"/> plays, at the last one).</summary>
        public const string Summary = "summary";
        public static string Device(string id) => "device:" + id;
    }

    public long? Id { get; init; }
    /// <summary>Null for a Last.fm play of a song not in the library, or a song since removed.</summary>
    public long? TrackId { get; init; }
    public DateTime StartedAt { get; init; }
    /// <summary>Seconds heard.</summary>
    public double Listened { get; init; }
    public double Duration { get; init; }
    /// <summary>Heard long enough to count as a play (what Play Count counts).</summary>
    public bool Counted { get; init; }
    /// <summary>Stopped early (what Skips counts).</summary>
    public bool Skipped { get; init; }
    public string Source { get; init; } = Sources.Windows;
    /// <summary>Plays this row stands for: 1, or a song's total for a summary row.</summary>
    public int Count { get; init; } = 1;
    public string Artist { get; init; } = "";
    public string Title { get; init; } = "";
    public string Album { get; init; } = "";

    /// <summary>
    /// A listen of <paramref name="seconds"/> of a song: a play when at least half (or 4 minutes) was heard, a skip when it
    /// stopped in the first 20 seconds (or the first half of a shorter song).
    /// </summary>
    public static Listen Of(Track track, DateTime startedAt, double seconds, string source)
    {
        var duration = track.Duration;
        var counted = duration > 0 && seconds >= Math.Min(duration * 0.5, 240);
        return new Listen
        {
            TrackId = track.Id, StartedAt = startedAt, Listened = seconds, Duration = duration, Counted = counted,
            Skipped = !counted && seconds < Math.Min(20, duration * 0.5), Source = source,
            Artist = track.Artist ?? "", Title = track.Title, Album = track.Album ?? "",
        };
    }
}

public static class ListeningLog
{
    /// <summary>
    /// Records a listen made here: the log row, and Play Count, Last Played and Skips as before. Null when the song is gone.
    /// </summary>
    public static Listen? RecordListen(this LibraryDatabase database, long trackId, DateTime startedAt, double listened, string source = Listen.Sources.Windows) =>
        database.Write(db =>
        {
            var track = db.FetchTracks("SELECT * FROM track WHERE id = ?", trackId).FirstOrDefault();
            if (track is null) return null;
            var listen = Listen.Of(track, startedAt, listened, source);
            Count(db, listen);
            return Insert(db, listen);
        });

    /// <summary>Play Count, Last Played and Skips for a listen.</summary>
    internal static void Count(SqliteConnection db, Listen listen)
    {
        if (listen.TrackId is not { } trackId) return;
        if (listen.Counted)
        {
            var end = listen.StartedAt.AddSeconds(listen.Listened);
            db.Execute("""
                UPDATE track SET playCount = playCount + 1,
                    lastPlayedAt = CASE WHEN lastPlayedAt IS NULL OR lastPlayedAt < ? THEN ? ELSE lastPlayedAt END
                WHERE id = ?
                """, end, end, trackId);
        }
        else if (listen.Skipped)
        {
            db.Execute("UPDATE track SET skipCount = skipCount + 1 WHERE id = ?", trackId);
        }
    }

    public static Listen Insert(SqliteConnection db, Listen listen)
    {
        db.Execute("""
            INSERT INTO listen (trackId, startedAt, listened, duration, counted, skipped, source, count, artist, title, album)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, listen.TrackId, listen.StartedAt, listen.Listened, listen.Duration, listen.Counted, listen.Skipped, listen.Source,
            listen.Count, listen.Artist, listen.Title, listen.Album);
        return listen with { Id = db.LastInsertRowId() };
    }

    /// <summary>Listens from a source, and how many of them are songs in the library.</summary>
    public static (int Plays, int Matched) ListenCounts(this SqliteConnection db, string source) =>
        db.Query("SELECT COUNT(*) AS plays, COUNT(trackId) AS matched FROM listen WHERE source = ?",
            row => (row.Get<int>("plays"), row.Get<int>("matched")), source).FirstOrDefault();

    /// <summary>Listens from <paramref name="start"/> on (all when null), oldest first.</summary>
    public static List<Listen> Listens(this LibraryDatabase database, DateTime? start = null) => database.Read(db =>
        start is { } from
            ? db.Query("SELECT * FROM listen WHERE startedAt >= ? ORDER BY startedAt, id", Map, from)
            : db.Query("SELECT * FROM listen ORDER BY startedAt, id", Map));

    internal static Listen Map(Row row) => new()
    {
        Id = row.Get<long>("id"), TrackId = row.Get<long?>("trackId"), StartedAt = row.Get<DateTime>("startedAt"),
        Listened = row.Get<double>("listened"), Duration = row.Get<double>("duration"), Counted = row.Get<bool>("counted"),
        Skipped = row.Get<bool>("skipped"), Source = row.Get<string>("source")!, Count = row.Get<int>("count"),
        Artist = row.Get<string>("artist")!, Title = row.Get<string>("title")!, Album = row.Get<string>("album")!,
    };
}
