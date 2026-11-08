using System.Globalization;
using Groovelight.Core.Library;
using Microsoft.Data.Sqlite;

namespace Groovelight.Core.Discovery;

/// <summary>Home's dashboard: listening time, plays, when and what, for a range of days (the Mac's ListeningStats, same JSON).</summary>
public sealed class ListeningStats
{
    public enum StatsRange { Week, Month, Year, All }

    /// <summary>Where listens came from, the keys of <see cref="Places"/> and of each bucket's minutes.</summary>
    public static class Place
    {
        /// <summary>This computer (the Mac or the PC).</summary>
        public const string Here = "here";
        public const string Devices = "devices";
        public const string LastFm = "lastfm";

        public static string Of(string source) =>
            source == Listen.Sources.LastFm ? LastFm : source.StartsWith("device:", StringComparison.Ordinal) ? Devices : Here;
    }

    public sealed class Bucket
    {
        /// <summary>"2025-11-08", "2025-11" or "2025".</summary>
        public string Label { get; set; } = "";
        /// <summary>Minutes heard, by place.</summary>
        public Dictionary<string, double> Minutes { get; set; } = [];
        public double Total() => Minutes.Values.Sum();
    }

    public sealed class Ranked
    {
        public string Name { get; set; } = "";
        /// <summary>The artist (songs and albums).</summary>
        public string Detail { get; set; } = "";
        /// <summary>The album key (albums), the song id (songs), for opening it.</summary>
        public string Key { get; set; } = "";
        public long Plays { get; set; }
        public string? ArtworkHash { get; set; }
    }

    public StatsRange Range { get; set; }
    public double Minutes { get; set; }
    public long Plays { get; set; }
    public long Songs { get; set; }
    /// <summary>Songs heard for the first time in the range.</summary>
    public long NewSongs { get; set; }
    /// <summary>Days in a row, up to today (or yesterday), with at least one play.</summary>
    public long Streak { get; set; }
    public List<Bucket> Buckets { get; set; } = [];
    /// <summary>Plays by weekday (0 is Sunday) and hour: 7 rows of 24.</summary>
    public long[][] Hours { get; set; } = [.. Enumerable.Range(0, 7).Select(_ => new long[24])];
    public List<Ranked> TopSongs { get; set; } = [];
    public List<Ranked> TopAlbums { get; set; } = [];
    public List<Ranked> TopArtists { get; set; } = [];
    public List<Ranked> Genres { get; set; } = [];
    /// <summary>"1990s" and its plays.</summary>
    public List<Ranked> Decades { get; set; } = [];
    public Dictionary<string, long> Places { get; set; } = [];
    public long LibrarySongs { get; set; }
    public long NeverPlayed { get; set; }
    public long Loved { get; set; }

    /// <summary>Days back from today (null for all time).</summary>
    public static int? Days(StatsRange range) => range switch
    {
        StatsRange.Week => 7,
        StatsRange.Month => 30,
        StatsRange.Year => 365,
        _ => null,
    };
}

public static class ListeningStatsStore
{
    /// <summary>
    /// The dashboard for a range, ending today in <paramref name="zone"/>. Summary rows (play counts from before the log) only
    /// count in "all time" totals and the top lists, not in time based charts.
    /// </summary>
    public static ListeningStats ListeningStatsFor(this SqliteConnection db, ListeningStats.StatsRange range, DateTime? utcNow = null, TimeZoneInfo? zone = null)
    {
        zone ??= TimeZoneInfo.Local;
        var now = utcNow ?? DateTime.UtcNow;
        var stats = new ListeningStats { Range = range };
        var offset = zone.GetUtcOffset(now);
        var localNow = now + offset;
        var today = localNow.Date;
        var days = ListeningStats.Days(range);
        // The start of the range as a UTC moment (the zone's offset now, as the Mac does).
        var since = days is { } count ? DateTime.SpecifyKind(today.AddDays(1 - count) - offset, DateTimeKind.Utc) : new DateTime(1, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        var local = $"'{(long)offset.TotalSeconds} seconds'";
        var summary = Listen.Sources.Summary;
        const string filter = "startedAt >= ? AND (source <> ? OR ? = 1)";
        const string joined = "l.startedAt >= ? AND (l.source <> ? OR ? = 1)";
        var isAll = range == ListeningStats.StatsRange.All;
        object[] arguments = [since, summary, isAll];

        db.QueryOne($"""
            SELECT COALESCE(SUM(CASE WHEN source <> ? THEN listened ELSE 0 END), 0) AS seconds,
                   COALESCE(SUM(CASE WHEN counted THEN count ELSE 0 END), 0) AS plays,
                   COUNT(DISTINCT CASE WHEN counted THEN COALESCE(trackId, artist || '|' || title) END) AS songs
            FROM listen WHERE {filter}
            """, row =>
        {
            stats.Minutes = row.Get<double>("seconds") / 60;
            stats.Plays = row.Get<long>("plays");
            stats.Songs = row.Get<long>("songs");
            return row;
        }, [summary, .. arguments]);
        stats.NewSongs = db.Scalar<long>("""
            SELECT COUNT(*) FROM (SELECT trackId FROM listen WHERE counted AND trackId IS NOT NULL GROUP BY trackId HAVING MIN(startedAt) >= ?)
            """, since);

        // Streak: local days with plays, newest first.
        var played = db.Column<string>($"SELECT DISTINCT date(startedAt, {local}) AS day FROM listen WHERE counted AND source <> ? ORDER BY day DESC LIMIT 400", summary).ToHashSet();
        stats.Streak = Streak(played, today);

        // Time based charts.
        var format = range switch
        {
            ListeningStats.StatsRange.Week or ListeningStats.StatsRange.Month => "%Y-%m-%d",
            ListeningStats.StatsRange.Year => "%Y-%m",
            _ => "%Y",
        };
        var buckets = new Dictionary<string, Dictionary<string, double>>();
        foreach (var (bucket, source, seconds) in db.Query($"""
            SELECT strftime('{format}', startedAt, {local}) AS bucket, source, SUM(listened) AS seconds
            FROM listen WHERE startedAt >= ? AND source <> ? GROUP BY bucket, source
            """, row => (row.Required<string>("bucket"), row.Required<string>("source"), row.Get<double>("seconds")), since, summary))
        {
            var minutes = buckets.TryGetValue(bucket, out var found) ? found : buckets[bucket] = [];
            var place = ListeningStats.Place.Of(source);
            minutes[place] = minutes.GetValueOrDefault(place) + seconds / 60;
        }
        stats.Buckets = [.. BucketLabels(range, today, buckets.Keys).Select(label => new ListeningStats.Bucket { Label = label, Minutes = buckets.GetValueOrDefault(label) ?? [] })];
        foreach (var (weekday, hour, plays) in db.Query($"""
            SELECT CAST(strftime('%w', startedAt, {local}) AS INTEGER) AS weekday, CAST(strftime('%H', startedAt, {local}) AS INTEGER) AS hour,
                   SUM(count) AS plays
            FROM listen WHERE counted AND startedAt >= ? AND source <> ? GROUP BY weekday, hour
            """, row => (row.Get<long>("weekday"), row.Get<long>("hour"), row.Get<long>("plays")), since, summary))
        {
            if (weekday is >= 0 and < 7 && hour is >= 0 and < 24) stats.Hours[weekday][hour] = plays;
        }
        foreach (var (source, plays) in db.Query($"SELECT source, SUM(count) AS plays FROM listen WHERE counted AND {filter} GROUP BY source",
                     row => (row.Required<string>("source"), row.Get<long>("plays")), arguments))
        {
            var place = ListeningStats.Place.Of(source);
            stats.Places[place] = stats.Places.GetValueOrDefault(place) + plays;
        }

        // Top lists (songs in the library; artists also from Last.fm plays of songs not in it).
        stats.TopSongs = db.Query($"""
            SELECT t.id, t.title, COALESCE(NULLIF(t.artist, ''), t.albumArtist, '') AS artist, t.artworkHash, SUM(l.count) AS plays
            FROM listen l JOIN track t ON t.id = l.trackId WHERE l.counted AND {joined}
            GROUP BY t.id ORDER BY plays DESC, t.id LIMIT 10
            """, row => new ListeningStats.Ranked
        {
            Name = row.Get<string>("title") ?? "", Detail = row.Get<string>("artist") ?? "", Key = row.Get<long>("id").ToString(CultureInfo.InvariantCulture),
            Plays = row.Get<long>("plays"), ArtworkHash = row.Get<string>("artworkHash"),
        }, arguments);
        stats.TopAlbums = db.Query($"""
            SELECT t.albumKey, MAX(t.album) AS album,
                   CASE WHEN MAX(t.isCompilation) THEN 'Various Artists' ELSE COALESCE(MAX(NULLIF(t.albumArtist, '')), MAX(t.artist), '') END AS artist,
                   MAX(t.artworkHash) AS artworkHash, SUM(l.count) AS plays
            FROM listen l JOIN track t ON t.id = l.trackId WHERE l.counted AND {joined}
            GROUP BY t.albumKey ORDER BY plays DESC, t.albumKey LIMIT 10
            """, row => new ListeningStats.Ranked
        {
            Name = row.Get<string>("album") ?? "", Detail = row.Get<string>("artist") ?? "", Key = row.Get<string>("albumKey") ?? "",
            Plays = row.Get<long>("plays"), ArtworkHash = row.Get<string>("artworkHash"),
        }, arguments);
        stats.TopArtists = db.Query($"""
            SELECT artist, SUM(count) AS plays FROM listen WHERE counted AND artist <> '' AND {filter}
            GROUP BY artist COLLATE NOCASE ORDER BY plays DESC, artist LIMIT 10
            """, row => new ListeningStats.Ranked { Name = row.Get<string>("artist") ?? "", Key = row.Get<string>("artist") ?? "", Plays = row.Get<long>("plays") }, arguments);
        stats.Genres = db.Query($"""
            SELECT t.genre, SUM(l.count) AS plays FROM listen l JOIN track t ON t.id = l.trackId
            WHERE l.counted AND t.genre IS NOT NULL AND t.genre <> '' AND {joined}
            GROUP BY t.genre COLLATE NOCASE ORDER BY plays DESC, t.genre LIMIT 8
            """, row => new ListeningStats.Ranked { Name = row.Get<string>("genre") ?? "", Key = row.Get<string>("genre") ?? "", Plays = row.Get<long>("plays") }, arguments);
        stats.Decades = db.Query($"""
            SELECT (t.year / 10) * 10 AS decade, SUM(l.count) AS plays FROM listen l JOIN track t ON t.id = l.trackId
            WHERE l.counted AND t.year > 0 AND {joined}
            GROUP BY decade ORDER BY decade
            """, row =>
        {
            var decade = row.Get<long>("decade");
            return new ListeningStats.Ranked { Name = $"{decade}s", Key = decade.ToString(CultureInfo.InvariantCulture), Plays = row.Get<long>("plays") };
        }, arguments);

        db.QueryOne("""
            SELECT COUNT(*) AS songs, SUM(CASE WHEN playCount = 0 THEN 1 ELSE 0 END) AS never, SUM(CASE WHEN isLoved THEN 1 ELSE 0 END) AS loved
            FROM track
            """, row =>
        {
            stats.LibrarySongs = row.Get<long>("songs");
            stats.NeverPlayed = row.Get<long?>("never") ?? 0;
            stats.Loved = row.Get<long?>("loved") ?? 0;
            return row;
        });
        return stats;
    }

    /// <summary>Days in a row with plays, from today, or from yesterday when nothing was played yet today.</summary>
    internal static long Streak(HashSet<string> played, DateTime today)
    {
        static string Text(DateTime day) => day.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var day = played.Contains(Text(today)) ? today : today.AddDays(-1);
        long count = 0;
        while (played.Contains(Text(day)))
        {
            count++;
            day = day.AddDays(-1);
        }
        return count;
    }

    /// <summary>Every bucket of the range, empty ones too (all time: from the first year with listens).</summary>
    internal static List<string> BucketLabels(ListeningStats.StatsRange range, DateTime today, IEnumerable<string> existing)
    {
        switch (range)
        {
            case ListeningStats.StatsRange.Week or ListeningStats.StatsRange.Month:
                var days = ListeningStats.Days(range) ?? 0;
                return [.. Enumerable.Range(0, days).Reverse().Select(back => today.AddDays(-back).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture))];
            case ListeningStats.StatsRange.Year:
                return [.. Enumerable.Range(0, 12).Reverse().Select(back => today.AddMonths(-back).ToString("yyyy-MM", CultureInfo.InvariantCulture))];
            default:
                var first = existing.Select(label => int.TryParse(label, CultureInfo.InvariantCulture, out var year) ? year : (int?)null).Min() ?? today.Year;
                return [.. Enumerable.Range(first, today.Year - first + 1).Select(year => year.ToString(CultureInfo.InvariantCulture))];
        }
    }
}
