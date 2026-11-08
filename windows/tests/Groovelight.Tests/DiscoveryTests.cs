using System.Text.Json;
using System.Text.Json.Serialization;
using Groovelight.Core.Devices;
using Groovelight.Core.Discovery;
using Groovelight.Core.Library;
using static Groovelight.Core.Discovery.Discovery;

namespace Groovelight.Tests;

/// <summary>The Mac's DiscoveryTests, ported: both read GroovelightKit's Fixtures/Discovery and must pick the same.</summary>
public class DiscoveryTests
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) } };

    private sealed record Fixture(long Today, List<Song> Songs, List<Play> Plays, List<PastPick> Past);

    private sealed record Draw(string Key, string Reason, List<long> TrackIds);

    private sealed record Expected(List<Draw> Song, List<Draw> Album, List<Draw> Artist, Dictionary<string, long> Affinity);

    private static T Load<T>(string name) =>
        JsonSerializer.Deserialize<T>(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "Discovery", name + ".json")), Json)!;

    [Fact]
    public void PicksTheSameAsTheMac()
    {
        var fixture = Load<Fixture>("picks");
        var expected = Load<Expected>("picks-expected");
        var picker = new DailyPicks(fixture.Songs, fixture.Plays, fixture.Past, fixture.Today);
        foreach (var song in fixture.Songs)
            Assert.Equal(expected.Affinity[song.Id.ToString(System.Globalization.CultureInfo.InvariantCulture)], picker.Taste[song.Id].Affinity);
        void Check(Kind kind, List<Draw> draws)
        {
            var actual = picker.Draw(kind, 3);
            Assert.Equal(draws.Select(draw => (draw.Key, draw.Reason, string.Join(",", draw.TrackIds))),
                         actual.Select(pick => (pick.Key, pick.Reason.Code, string.Join(",", pick.TrackIds))));
        }
        Check(Kind.Song, expected.Song);
        Check(Kind.Album, expected.Album);
        Check(Kind.Artist, expected.Artist);
    }

    [Fact]
    public void KeepsTheDaysPickAllDay()
    {
        var fixture = Load<Fixture>("picks");
        var picker = new DailyPicks(fixture.Songs, fixture.Plays, [.. fixture.Past, new PastPick(fixture.Today, Kind.Album, "björk|homogenic", "anniversary,25")], fixture.Today);
        var pick = picker.PickOf(Kind.Album)!;
        Assert.Equal(("björk|homogenic", (Reason)new Reason.Anniversary(25)), (pick.Key, pick.Reason));
        Assert.Equal([11L, 12, 13, 14, 15], pick.TrackIds);
    }

    [Fact]
    public void CountsRecentPlaysMore()
    {
        Assert.Equal([1000L, 750, 500, 250, 0], new long[] { 0, 45, 90, 180, 5000 }.Select(age => Decayed(1000, age)));
        var song = new Song { Id = 1, Title = "A", Artist = "X", AlbumArtist = "X", Album = "Y", AlbumKey = "y", Loved = true, Rating = 4, Duration = 100, Order = 1 };
        var taste = new Taste([song], [
            new Play { TrackId = 1, Day = 100, Counted = true, Source = "mac" },
            new Play { TrackId = 1, Day = 100, Skipped = true, Source = "mac" },
            new Play { TrackId = 1, Day = 10, Counted = true, Count = 9, Source = "summary" },
        ], 100);
        Assert.Equal((10L, 1L, (long?)100), (taste[1].Plays, taste[1].Skips, taste[1].LastDay));
        Assert.Equal(1000 - 400 + 9 * Decayed(1000, 90) + 3000 + 2000, taste[1].Affinity);
        var withLastFm = new Taste([song], [
            new Play { TrackId = 1, Day = 10, Counted = true, Count = 9, Source = "summary" },
            new Play { TrackId = 1, Day = 50, Counted = true, Source = "lastfm" },
        ], 100);
        Assert.Equal(1, withLastFm[1].Plays);
    }

    [Fact]
    public void DrawsTheSameNumbersEverywhere()
    {
        var random = new Discovery.Random("groovelight");
        Assert.Equal([2_317_881_071_274_320_010UL, 15_988_805_049_024_803_882UL, 36UL], new[] { random.Next(), random.Next(), random.Below(100) });
        var weighted = new Discovery.Random("w");
        Assert.Null(weighted.Weighted([0, 0]));
        Assert.Equal(1, weighted.Weighted([0, 5, 0]));
        Assert.True(CompareCodePoints("Ólafur", "Portishead") > 0);
        Assert.True(CompareCodePoints("a\U0001F600", "a�") > 0);
    }

    [Fact]
    public void CountsDaysInTheLocalCalendar()
    {
        Assert.Equal(0, DaysFromCivil(1970, 1, 1));
        Assert.Equal(20400, DaysFromCivil(2025, 11, 8));
        Assert.Equal(2025, YearOfDay(20400));
        Assert.Equal(1969, YearOfDay(-1));
        var saoPaulo = TimeZoneInfo.FindSystemTimeZoneById(OperatingSystem.IsWindows() ? "E. South America Standard Time" : "America/Sao_Paulo");
        var moment = DateTime.UnixEpoch.AddSeconds(20400L * 86_400 + 5400);
        Assert.Equal(20399, DayOf(moment, saoPaulo));
        Assert.Equal(20400, DayOf(moment, TimeZoneInfo.Utc));
    }

    [Fact]
    public void KeepsTheDaysPicksInTheLibrary()
    {
        using var database = TestLibrary.Seeded();
        database.RecordListen(1, DateTime.UnixEpoch.AddSeconds(1_700_000_000), 180);
        var date = DateTime.UnixEpoch.AddSeconds(1_800_000_000);
        var first = database.DailyPicksFor(date, TimeZoneInfo.Utc).Picks;
        Assert.Equal([Kind.Song, Kind.Album, Kind.Artist], first.Select(pick => pick.Kind));
        database.RecordListen(2, date, 180);
        var later = database.DailyPicksFor(date.AddHours(1), TimeZoneInfo.Utc).Picks;
        Assert.Equal(first.Select(pick => (pick.Key, pick.Reason)), later.Select(pick => (pick.Key, pick.Reason)));
        var stored = database.Read(db => db.PastPicks(0));
        Assert.Equal(3, stored.Count);
        Assert.All(stored, pick => Assert.Equal(DayOf(date, TimeZoneInfo.Utc), pick.Day));
    }
}

/// <summary>The Mac's ListeningStatsTests and HomeSnapshotTests, ported: the PC must make the same Home as the Mac.</summary>
public class HomeSnapshotTests
{
    private static readonly DateTime Now = DateTime.UnixEpoch.AddSeconds(1_800_000_000); // Fri 15 Jan 2027, 08:00 UTC

    [Fact]
    public void SummarizesListening()
    {
        using var database = TestLibrary.Seeded();
        database.RecordListen(1, Now.AddHours(-1), 180);
        database.RecordListen(1, Now.AddDays(-1), 180);
        database.RecordListen(4, Now.AddDays(-2), 120);
        database.RecordListen(2, Now.AddDays(-2), 3);
        database.RecordListen(3, Now.AddDays(-40), 180);
        database.ApplyDeviceHistory([new DeviceHistoryEvent
        {
            Id = "x", TrackId = 4, Kind = "play", Value = 150, AtMs = (long)(Now.AddDays(-5) - DateTime.UnixEpoch).TotalMilliseconds,
        }], "phone");
        database.Write(db => ListeningLog.Insert(db, new Listen
        {
            TrackId = 5, StartedAt = Now.AddDays(-900), Listened = 0, Duration = 180, Counted = true, Source = Listen.Sources.Summary, Count = 7,
            Artist = "Someone", Title = "Song A", Album = "Hits 1999",
        }));
        // São Paulo is 3 hours behind: the same listens fall on its days and hours.
        foreach (var (zone, hour) in new[] { (TimeZoneInfo.Utc, 7), (SaoPaulo(), 4) })
        {
            var week = database.Read(db => db.ListeningStatsFor(ListeningStats.StatsRange.Week, Now, zone));
            Assert.Equal((4L, 2L), (week.Plays, week.Songs));
            Assert.Equal((180 + 180 + 120 + 3 + 150) / 60.0, week.Minutes, 3);
            Assert.Equal(3, week.Streak);
            Assert.Equal((7, "2027-01-15"), (week.Buckets.Count, week.Buckets[^1].Label));
            Assert.Equal(3, week.Buckets[^1].Minutes[ListeningStats.Place.Here], 3);
            Assert.Equal(new Dictionary<string, long> { ["here"] = 3, ["devices"] = 1 }, week.Places);
            Assert.Equal(1, week.Hours[5][hour]);
            Assert.Equal(2, week.NewSongs);
            Assert.Contains(week.TopArtists.Select(artist => artist.Name), name => name == "The Beatles");
        }
        var all = database.Read(db => db.ListeningStatsFor(ListeningStats.StatsRange.All, Now, TimeZoneInfo.Utc));
        Assert.Equal(5 + 7, all.Plays);
        Assert.Equal(["2026", "2027"], all.Buckets.Select(bucket => bucket.Label));
        Assert.Equal(["1960s"], all.Decades.Select(decade => decade.Name));
        Assert.Equal((6L, 0L), (all.LibrarySongs, all.Loved));
    }

    /// <summary>The same library and listens as the Mac's test give the same JSON as its <c>home.json</c>.</summary>
    [Fact]
    public void MakesTheSameHomeAsTheMac()
    {
        using var database = TestLibrary.Seeded();
        database.Write(db => db.Execute("UPDATE track SET dateAdded = ?", DateTime.UnixEpoch.AddSeconds(1_600_000_000)));
        database.RecordListen(1, Now.AddHours(-1), 180);
        database.RecordListen(4, Now.AddDays(-1), 120);
        var home = database.HomeSnapshotFor(Now, TimeZoneInfo.Utc);
        Assert.Equal(3, database.Read(db => db.PastPicks(home.Day)).Count);

        var mac = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "Discovery", "home.json")))!;
        var windows = System.Text.Json.Nodes.JsonNode.Parse(WireJson.Encode(home))!;
        Assert.Equal(Normalized(mac), Normalized(windows));
    }

    private static TimeZoneInfo SaoPaulo() =>
        TimeZoneInfo.FindSystemTimeZoneById(OperatingSystem.IsWindows() ? "E. South America Standard Time" : "America/Sao_Paulo");

    /// <summary>JSON with sorted keys and numbers as decimals (Swift writes 3 where .NET may write 3.0).</summary>
    private static string Normalized(System.Text.Json.Nodes.JsonNode? node) => node switch
    {
        System.Text.Json.Nodes.JsonObject obj => "{" + string.Join(",", obj.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => $"\"{pair.Key}\":{Normalized(pair.Value)}")) + "}",
        System.Text.Json.Nodes.JsonArray array => "[" + string.Join(",", array.Select(Normalized)) + "]",
        System.Text.Json.Nodes.JsonValue value when value.GetValueKind() == JsonValueKind.Number => value.GetValue<decimal>().ToString("0.######", System.Globalization.CultureInfo.InvariantCulture),
        null => "null",
        _ => node.ToJsonString(),
    };
}
