using Groovelight.Core.Library;
using Microsoft.Data.Sqlite;

namespace Groovelight.Core.Discovery;

using static Discovery;

/// <summary>The library and the log as the picks see them, and the day's picks kept in the library (the Mac's DiscoveryStore).</summary>
public static class DiscoveryStore
{
    public static (List<Song> Songs, List<Play> Plays) DiscoveryInput(this SqliteConnection db, TimeZoneInfo? zone = null)
    {
        var songs = db.Query("""
            SELECT id, title, artist, albumArtist, album, albumKey, genre, year, isLoved, rating, dateAdded, duration, discNumber,
                   trackNumber, isCompilation
            FROM track
            """, row =>
        {
            var artist = row.Get<string>("artist") is { Length: > 0 } a ? a : null;
            var albumArtist = row.Get<string>("albumArtist") is { Length: > 0 } b ? b : null;
            return new Song
            {
                Id = row.Get<long>("id"), Title = row.Get<string>("title") ?? "", Artist = artist ?? albumArtist ?? "",
                AlbumArtist = row.Get<bool>("isCompilation") ? "Various Artists" : albumArtist ?? artist ?? "",
                Album = row.Get<string>("album") ?? "", AlbumKey = row.Get<string>("albumKey") ?? "", Genre = row.Get<string>("genre"),
                Year = row.Get<int?>("year"), Loved = row.Get<bool>("isLoved"), Rating = row.Get<int>("rating"),
                AddedDay = DayOf(row.Get<DateTime>("dateAdded"), zone), Duration = row.Get<double>("duration"),
                Order = (row.Get<long?>("discNumber") ?? 1) * 1000 + (row.Get<long?>("trackNumber") ?? 0),
            };
        });
        var plays = db.Query("SELECT trackId, startedAt, counted, skipped, count, source FROM listen WHERE trackId IS NOT NULL", row => new Play
        {
            TrackId = row.Get<long>("trackId"), Day = DayOf(row.Get<DateTime>("startedAt"), zone), Counted = row.Get<bool>("counted"),
            Skipped = row.Get<bool>("skipped"), Count = row.Get<long>("count"), Source = row.Get<string>("source") ?? "",
        });
        return (songs, plays);
    }

    public static List<PastPick> PastPicks(this SqliteConnection db, long since) =>
        db.Query("SELECT day, kind, key, reason FROM dailyPick WHERE day >= ? ORDER BY day", row =>
                ParseKind(row.Get<string>("kind")) is { } kind ? new PastPick(row.Get<long>("day"), kind, row.Get<string>("key") ?? "", row.Get<string>("reason")) : null, since)
            .OfType<PastPick>().ToList();

    /// <summary>Today's picks (made and kept on the first call of the day), with the picker for "Something else".</summary>
    public static (List<Pick> Picks, DailyPicks Picker) DailyPicksFor(this LibraryDatabase database, DateTime? utc = null, TimeZoneInfo? zone = null) =>
        database.Write(db =>
        {
            var today = DayOf(utc ?? DateTime.UtcNow, zone);
            var (songs, plays) = db.DiscoveryInput(zone);
            var picker = new DailyPicks(songs, plays, db.PastPicks(today - 120), today);
            var picks = new List<Pick>();
            foreach (var kind in Enum.GetValues<Kind>())
            {
                if (picker.PickOf(kind) is not { } pick) continue;
                picks.Add(pick);
                db.Execute("INSERT OR IGNORE INTO dailyPick (day, kind, key, reason) VALUES (?, ?, ?, ?)", today, Raw(kind), pick.Key, pick.Reason.Code);
            }
            return (picks, picker);
        });
}
