using Groovelight.Core;
using Groovelight.Core.Library;

namespace Groovelight.Tests;

public class SmartPlaylistTests
{
    private static readonly DateTime Now = DateTime.UnixEpoch.AddSeconds(1_800_000_000);

    /// <summary>Eight songs with varied tags, play history and formats.</summary>
    private static LibraryDatabase Library()
    {
        var database = LibraryDatabase.InMemory();
        var rootId = database.AddRoot("/music").Id!.Value;
        Track Make(string title, string artist, string album, int year, int plays = 0, bool loved = false, double addedDaysAgo = 100,
                   double? playedDaysAgo = null, string format = "FLAC", double sampleRate = 44_100, int? bitDepth = 16,
                   double? bitrate = 900, double duration = 240, long size = 30_000_000, string genre = "Rock", bool artwork = true,
                   int rating = 0)
        {
            var track = TestLibrary.MakeTrack(rootId, title, artist, album, 1);
            track.Path = $"/music/{artist}/{album}/{title}.{format.ToLowerInvariant()}";
            track.Year = year;
            track.PlayCount = plays;
            track.IsLoved = loved;
            track.DateAdded = Now.AddDays(-addedDaysAgo);
            track.LastPlayedAt = playedDaysAgo is { } days ? Now.AddDays(-days) : null;
            track.Format = format;
            track.SampleRate = sampleRate;
            track.BitDepth = bitDepth;
            track.Bitrate = bitrate;
            track.Duration = duration;
            track.FileSize = size;
            track.Genre = genre;
            track.ArtworkHash = artwork ? "hash" : null;
            track.Rating = rating;
            return track;
        }
        database.Write(db =>
        {
            foreach (var track in new[]
            {
                Make("Airbag", "Radiohead", "OK Computer", 1997, plays: 40, playedDaysAgo: 1, rating: 5),
                Make("Karma Police", "Radiohead", "OK Computer", 1997, plays: 25, loved: true, playedDaysAgo: 20),
                Make("Movement 1", "Aurelia Quartet", "Hi-Res Sessions", 2024, addedDaysAgo: 2, sampleRate: 96_000, bitDepth: 24, bitrate: 3000, genre: "Jazz"),
                Make("Hit 1", "Radio Days", "Three Twenty", 2003, plays: 3, addedDaysAgo: 5, playedDaysAgo: 3, format: "MP3", bitDepth: null,
                     bitrate: 320, duration: 200, size: 8_000_000, genre: "Pop"),
                Make("Side B", "Mixtape Club", "Mixed Bag", 1989, format: "MP3", bitDepth: null, bitrate: 192, duration: 180, size: 4_000_000,
                     genre: "Pop", artwork: false),
                Make("100% Pure_Fun", "The Wildcards", "Symbols", 1999, plays: 1, playedDaysAgo: 400, duration: 600, genre: "Electronic"),
                Make("Dsd Track", "Aurelia Quartet", "DSD Test", 2020, format: "DSD Stream", sampleRate: 2_822_400, bitDepth: 1, bitrate: null, genre: "Jazz"),
                Make("Long Song", "Velvet Static", "Chrome Hearts", 2010, plays: 10, playedDaysAgo: 60, duration: 1200, size: 120_000_000, genre: "Electronic"),
            })
            {
                db.Insert(track);
            }
        });
        return database;
    }

    private static List<string> Titles(SmartPlaylistRules rules, LibraryDatabase database) =>
        database.Read(db => db.TracksMatching(rules, Now)).Select(track => track.Title).Order(StringComparer.Ordinal).ToList();

    private static SmartPlaylistRules Rules(params SmartRule[] rules) => new() { Rules = [.. rules] };

    [Fact]
    public void TextRules()
    {
        using var db = Library();
        Assert.Equal(["Airbag", "Hit 1", "Karma Police"], Titles(Rules(new SmartRule { Field = SmartField.Artist, Op = SmartOperator.Contains, Text = "radio" }), db));
        Assert.Equal(["Airbag", "Karma Police"], Titles(Rules(new SmartRule { Field = SmartField.Artist, Op = SmartOperator.Is, Text = "radiohead" }), db));
        Assert.Equal(["100% Pure_Fun"], Titles(Rules(new SmartRule { Field = SmartField.Title, Op = SmartOperator.BeginsWith, Text = "100%" }), db));
        // "%" and "_" are literal, not wildcards.
        Assert.Equal(["100% Pure_Fun"], Titles(Rules(new SmartRule { Field = SmartField.Title, Op = SmartOperator.Contains, Text = "e_F" }), db));
        Assert.Equal(["100% Pure_Fun"], Titles(Rules(new SmartRule { Field = SmartField.Title, Op = SmartOperator.Contains, Text = "_" }), db));
        Assert.Equal(["Dsd Track", "Movement 1"], Titles(Rules(new SmartRule { Field = SmartField.Genre, Op = SmartOperator.DoesNotContain, Text = "o" }), db));
    }

    [Fact]
    public void NumberRules()
    {
        using var db = Library();
        Assert.Equal(["100% Pure_Fun", "Airbag", "Karma Police"],
                     Titles(Rules(new SmartRule { Field = SmartField.Year, Op = SmartOperator.InRange, Number = 1990, Number2 = 1999 }), db));
        Assert.Equal(["Airbag", "Karma Police"], Titles(Rules(new SmartRule { Field = SmartField.Plays, Op = SmartOperator.GreaterThan, Number = 20 }), db));
        // Minutes and kHz are converted to the stored seconds and Hz.
        Assert.Equal(["Long Song"], Titles(Rules(new SmartRule { Field = SmartField.Time, Op = SmartOperator.GreaterThan, Number = 15 }), db));
        Assert.Equal(["Movement 1"], Titles(Rules(new SmartRule { Field = SmartField.SampleRate, Op = SmartOperator.Is, Number = 96 }), db));
        Assert.Equal(["Hit 1"], Titles(Rules(new SmartRule { Field = SmartField.Bitrate, Op = SmartOperator.Is, Number = 320 }), db));
        Assert.Equal(["Airbag"], Titles(Rules(new SmartRule { Field = SmartField.Rating, Op = SmartOperator.Is, Number = 5 }), db));
    }

    [Fact]
    public void DateRules()
    {
        using var db = Library();
        Assert.Equal(["Hit 1", "Movement 1"],
                     Titles(Rules(new SmartRule { Field = SmartField.DateAdded, Op = SmartOperator.InTheLast, Period = 1, PeriodUnit = PeriodUnit.Weeks }), db));
        Assert.Equal(["Airbag", "Hit 1", "Karma Police"],
                     Titles(Rules(new SmartRule { Field = SmartField.LastPlayed, Op = SmartOperator.InTheLast, Period = 1, PeriodUnit = PeriodUnit.Months }), db));
        // Never played counts as "not played in the last 2 months".
        Assert.Equal(4, Titles(Rules(new SmartRule { Field = SmartField.LastPlayed, Op = SmartOperator.NotInTheLast, Period = 2, PeriodUnit = PeriodUnit.Months }), db).Count);
    }

    [Fact]
    public void BoolAndQualityRules()
    {
        using var db = Library();
        Assert.Equal(["Karma Police"], Titles(Rules(new SmartRule { Field = SmartField.Loved, Op = SmartOperator.IsTrue }), db));
        Assert.Equal(["Side B"], Titles(Rules(new SmartRule { Field = SmartField.HasArtwork, Op = SmartOperator.IsFalse }), db));
        Assert.Equal(["Movement 1"], Titles(Rules(new SmartRule { Field = SmartField.Quality, Op = SmartOperator.Is, Quality = QualityTier.HiResLossless }), db));
        Assert.Equal(["Dsd Track", "Movement 1"],
                     Titles(Rules(new SmartRule { Field = SmartField.Quality, Op = SmartOperator.IsAtLeast, Quality = QualityTier.HiResLossless }), db));
        Assert.Equal(["Hit 1"], Titles(Rules(new SmartRule { Field = SmartField.Quality, Op = SmartOperator.Is, Quality = QualityTier.HighQuality }), db));
        Assert.Equal(6, Titles(Rules(new SmartRule { Field = SmartField.Quality, Op = SmartOperator.IsAtLeast, Quality = QualityTier.Lossless }), db).Count);
    }

    [Fact]
    public void MatchAllOrAny()
    {
        using var db = Library();
        SmartRule[] rules = [new() { Field = SmartField.Genre, Op = SmartOperator.Is, Text = "Jazz" }, new() { Field = SmartField.Year, Op = SmartOperator.GreaterThan, Number = 2022 }];
        Assert.Equal(["Movement 1"], Titles(new SmartPlaylistRules { Match = SmartMatch.All, Rules = [.. rules] }, db));
        Assert.Equal(["Dsd Track", "Movement 1"], Titles(new SmartPlaylistRules { Match = SmartMatch.Any, Rules = [.. rules] }, db));
        Assert.Equal(8, Titles(new SmartPlaylistRules { Rules = [] }, db).Count);
    }

    [Fact]
    public void Limits()
    {
        using var db = Library();
        var mostPlayed = new SmartPlaylistRules { Rules = [], Limit = new SmartLimit { Count = 3, SelectedBy = SmartLimitSelection.MostPlayed } };
        Assert.Equal(["Airbag", "Karma Police", "Long Song"], db.Read(d => d.TracksMatching(mostPlayed, Now)).Select(track => track.Title));

        // 12 minutes of the most recently added: Movement 1 (4:00), Hit 1 (3:20), then Airbag (4:00, the oldest additions
        // tie and fall back to library order) still fits; Karma Police would go over.
        var recent = new SmartPlaylistRules { Rules = [], Limit = new SmartLimit { Count = 12, Unit = SmartLimitUnit.Minutes, SelectedBy = SmartLimitSelection.MostRecentlyAdded } };
        var minutes = db.Read(d => d.TracksMatching(recent, Now));
        Assert.Equal(["Movement 1", "Hit 1", "Airbag"], minutes.Select(track => track.Title));
        Assert.True(minutes.Sum(track => track.Duration) <= 12 * 60);

        // Random is stable for a seed.
        var random = new SmartPlaylistRules { Rules = [], Limit = new SmartLimit { Count = 4, SelectedBy = SmartLimitSelection.Random, Seed = 42 } };
        var first = db.Read(d => d.TracksMatching(random)).Select(track => track.Id).ToList();
        var second = db.Read(d => d.TracksMatching(random)).Select(track => track.Id).ToList();
        Assert.Equal(first, second);
        Assert.Equal(4, first.Count);
    }

    [Fact]
    public void SmartPlaylistsUpdateLive()
    {
        using var db = Library();
        var id = db.CreateSmartPlaylist("Loved", Rules(new SmartRule { Field = SmartField.Loved, Op = SmartOperator.IsTrue })).Id!.Value;
        Assert.Equal(["Karma Police"], db.Read(d => d.TracksOfPlaylist(id)).Select(track => track.Title));

        var airbag = db.Read(d => d.Scalar<long>("SELECT id FROM track WHERE title = ?", "Airbag"));
        db.SetLoved(true, airbag);
        Assert.Equal(["Airbag", "Karma Police"], db.Read(d => d.TracksOfPlaylist(id)).Select(track => track.Title).Order(StringComparer.Ordinal));

        db.UpdateSmartPlaylist(id, "Loved Radiohead", Rules(new SmartRule { Field = SmartField.Loved, Op = SmartOperator.IsTrue },
                                                            new SmartRule { Field = SmartField.Artist, Op = SmartOperator.Is, Text = "Radiohead" }));
        var updated = db.Read(d => d.FetchPlaylist(id))!;
        Assert.Equal("Loved Radiohead", updated.Name);
        Assert.Equal(2, updated.Rules?.Rules.Count);
    }

    [Fact]
    public void LovedSongsNewestFirst()
    {
        using var db = Library();
        var ids = new[] { "Side B", "Airbag", "Hit 1" }.Select(title => db.Read(d => d.Scalar<long>("SELECT id FROM track WHERE title = ?", title))).ToArray();
        db.SetLoved(true, ids[0], Now.AddDays(-3));
        db.SetLoved(true, ids[1], Now.AddDays(-1));
        db.SetLoved(true, ids[2], Now.AddDays(-2));
        // Loving again keeps the first date; "Karma Police" was loved before dates existed and comes last.
        db.SetLoved(true, ids[0], Now);
        Assert.Equal(["Airbag", "Hit 1", "Side B", "Karma Police"], db.Read(d => d.LovedTracks()).Select(track => track.Title));

        db.SetLoved(false, ids[1]);
        var unloved = db.Read(d => d.FetchTrack(ids[1]))!;
        Assert.False(unloved.IsLoved);
        Assert.Null(unloved.LovedAt);

        db.CreateSmartPlaylist("Jazz", Rules(new SmartRule { Field = SmartField.Genre, Op = SmartOperator.Is, Text = "Jazz" }));
        var overview = db.Read(d => d.PlaylistOverview());
        Assert.Equal(3, overview.LovedCount);
        Assert.Equal(["Jazz"], overview.Playlists.Select(summary => summary.Playlist.Name));
        Assert.Equal(2, overview.Playlists[0].TrackCount);
    }

    [Fact]
    public void RulesRoundTripAsJson()
    {
        var rules = new SmartPlaylistRules
        {
            Match = SmartMatch.Any,
            Rules = [new SmartRule { Field = SmartField.Quality, Op = SmartOperator.IsAtLeast, Quality = QualityTier.HiResLossless }],
            Limit = new SmartLimit { Count = 2, Unit = SmartLimitUnit.Hours, SelectedBy = SmartLimitSelection.HighestRated },
        };
        var decoded = SwiftJson.Decode<SmartPlaylistRules>(SwiftJson.Encode(rules))!;
        Assert.Equal(rules.Match, decoded.Match);
        Assert.Equal(rules.Limit, decoded.Limit);
        Assert.Equal(rules.Rules[0].Id, decoded.Rules[0].Id);
        Assert.Equal(rules.Rules[0].Quality, decoded.Rules[0].Quality);
        Assert.Equal(rules.Rules[0].Date, decoded.Rules[0].Date, TimeSpan.FromMilliseconds(1));
    }
}
