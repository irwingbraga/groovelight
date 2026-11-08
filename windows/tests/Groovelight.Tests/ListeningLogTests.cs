using Groovelight.Core.Devices;
using Groovelight.Core.Library;

namespace Groovelight.Tests;

/// <summary>The Mac's ListeningLogTests, ported.</summary>
public class ListeningLogTests
{
    private static readonly DateTime Start = DateTime.UnixEpoch.AddSeconds(1_800_000_000);

    [Fact]
    public void LogsPlaysSkipsAndPartialListens()
    {
        using var database = TestLibrary.Seeded();
        database.RecordListen(1, Start, 170);
        database.RecordListen(1, Start.AddSeconds(200), 5);
        database.RecordListen(2, Start.AddSeconds(300), 60);
        Assert.Null(database.RecordListen(999, Start, 100));

        var log = database.Listens();
        Assert.Equal([true, false, false], log.Select(listen => listen.Counted));
        Assert.Equal([false, true, false], log.Select(listen => listen.Skipped));
        Assert.All(log, listen => Assert.Equal(Listen.Sources.Windows, listen.Source));
        Assert.Equal(("The Beatles", "Come Together", "Abbey Road"), (log[0].Artist, log[0].Title, log[0].Album));

        var tracks = database.Read(db => db.FetchTracks("SELECT * FROM track WHERE id IN (1, 2) ORDER BY id"));
        Assert.Equal((1, 1), (tracks[0].PlayCount, tracks[0].SkipCount));
        Assert.Equal(Start.AddSeconds(170), tracks[0].LastPlayedAt);
        Assert.Equal((0, 0), (tracks[1].PlayCount, tracks[1].SkipCount));
        Assert.Equal(2, database.Listens(Start.AddSeconds(100)).Count);
    }

    [Fact]
    public void LogsDevicePlaysOnce()
    {
        using var database = TestLibrary.Seeded();
        const long at = 1_800_000_000_000;
        DeviceHistoryEvent[] events =
        [
            new() { Id = "a", TrackId = 3, Kind = "play", Value = 150, AtMs = at },
            new() { Id = "b", TrackId = 3, Kind = "skip", Value = 4, AtMs = at + 1000 },
        ];
        database.ApplyDeviceHistory(events, "phone");
        database.ApplyDeviceHistory(events, "phone");
        var log = database.Listens();
        Assert.Equal(2, log.Count);
        Assert.All(log, listen => Assert.Equal(("device:phone", 3L), (listen.Source, listen.TrackId ?? 0)));
        Assert.True(log[0].Counted && !log[0].Skipped && log[0].Listened == 150);
        Assert.True(log[1].Skipped && !log[1].Counted);
    }

    [Fact]
    public void KeepsListensOfRemovedSongs()
    {
        using var database = TestLibrary.Seeded();
        database.RecordListen(4, DateTime.UtcNow, 180);
        database.Write(db => db.Execute("DELETE FROM track WHERE id = 4"));
        var listen = Assert.Single(database.Listens());
        Assert.Null(listen.TrackId);
        Assert.Equal("Paranoid Android", listen.Title);
    }
}
