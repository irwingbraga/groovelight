using Microsoft.Data.Sqlite;

namespace Groovelight.Core.Library;

public enum LastFmKind { Scrobble, Love, Unlove }

/// <summary>A scrobble, love or unlove waiting to be sent to Last.fm (the Mac's lastfmQueue table).</summary>
public sealed record LastFmQueueItem
{
    public long? Id { get; init; }
    public LastFmKind Kind { get; init; }
    public string Artist { get; init; } = "";
    public string Track { get; init; } = "";
    public string? Album { get; init; }
    public string? AlbumArtist { get; init; }
    public double? Duration { get; init; }
    public int? TrackNumber { get; init; }
    /// <summary>When the song started playing (scrobbles), or when the love changed.</summary>
    public DateTime Timestamp { get; init; }
    /// <summary>Failed attempts so far (items failing again and again are dropped).</summary>
    public int Attempts { get; init; }
}

public static class LastFmQueue
{
    private static string Raw(LastFmKind kind) => kind.ToString().ToLowerInvariant();

    public static void EnqueueLastFm(this LibraryDatabase database, LastFmQueueItem item) => database.Write(db =>
    {
        // A love followed by an unlove (or the reverse) of the same song: only the last one matters.
        if (item.Kind != LastFmKind.Scrobble)
            db.Execute("DELETE FROM lastfmQueue WHERE kind IN ('love', 'unlove') AND artist = ? COLLATE NOCASE AND track = ? COLLATE NOCASE", item.Artist, item.Track);
        db.Execute("INSERT INTO lastfmQueue (kind, artist, track, album, albumArtist, duration, trackNumber, timestamp, attempts) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            Raw(item.Kind), item.Artist, item.Track, item.Album, item.AlbumArtist, item.Duration, item.TrackNumber, item.Timestamp, item.Attempts);
        return true;
    });

    /// <summary>Waiting items of these kinds, oldest first.</summary>
    public static List<LastFmQueueItem> PendingLastFm(this LibraryDatabase database, IReadOnlyCollection<LastFmKind> kinds, int limit) => database.Read(db =>
    {
        var names = string.Join(",", kinds.Select(kind => $"'{Raw(kind)}'"));
        return db.Query($"SELECT * FROM lastfmQueue WHERE kind IN ({names}) ORDER BY timestamp, id LIMIT {limit}", row => new LastFmQueueItem
        {
            Id = row.Get<long>("id"), Kind = Enum.Parse<LastFmKind>(row.Get<string>("kind")!, true), Artist = row.Get<string>("artist")!, Track = row.Get<string>("track")!,
            Album = row.Get<string>("album"), AlbumArtist = row.Get<string>("albumArtist"), Duration = row.Get<double?>("duration"), TrackNumber = row.Get<int?>("trackNumber"),
            Timestamp = row.Get<DateTime>("timestamp"), Attempts = row.Get<int>("attempts"),
        });
    });

    public static void RemoveLastFm(this LibraryDatabase database, IReadOnlyCollection<long> ids) => database.Write(db =>
    {
        if (ids.Count > 0) db.Execute($"DELETE FROM lastfmQueue WHERE id IN ({string.Join(",", ids)})");
        return true;
    });

    /// <summary>Counts a failed attempt for these items, dropping the ones that failed <paramref name="maxAttempts"/> times.</summary>
    public static void FailedLastFm(this LibraryDatabase database, IReadOnlyCollection<long> ids, int maxAttempts) => database.Write(db =>
    {
        foreach (var id in ids) db.Execute("UPDATE lastfmQueue SET attempts = attempts + 1 WHERE id = ?", id);
        db.Execute("DELETE FROM lastfmQueue WHERE attempts >= ?", maxAttempts);
        return true;
    });

    public static int LastFmQueueCount(this SqliteConnection db) => (int)db.Scalar<long>("SELECT COUNT(*) FROM lastfmQueue");
}
