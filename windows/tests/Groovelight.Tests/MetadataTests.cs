using System.Text.Json;
using Groovelight.Core;
using Groovelight.Core.Library;
using Groovelight.Metadata;

namespace Groovelight.Tests;

public class LyricsParsingTests
{
    [Fact]
    public void ParsesSyncedLyrics()
    {
        const string lrc = "[ar:Radiohead]\n[ti:Karma Police]\n[00:26.78]Karma police\n[00:31.00]Arrest this man\n[01:02.50][02:10.00]Chorus line\n[00:33:39]He talks in maths";
        var lyrics = SyncedLyrics.Parse(lrc);
        Assert.True(lyrics.IsSynced);
        Assert.Equal(["Karma police", "Arrest this man", "He talks in maths", "Chorus line", "Chorus line"], lyrics.Lines.Select(line => line.Text));
        Assert.Equal(26.78, lyrics.Lines[0].Time!.Value, 6);
        Assert.Equal(33.39, lyrics.Lines[2].Time!.Value, 6);
        Assert.Equal(130, lyrics.Lines[4].Time!.Value, 6);
        Assert.Null(lyrics.LineIndex(10));
        Assert.Equal(1, lyrics.LineIndex(31.5));
        Assert.Equal(4, lyrics.LineIndex(500));
    }

    [Fact]
    public void AppliesOffset() => Assert.Equal(9.5, SyncedLyrics.Parse("[offset:+500]\n[00:10.00]Line").Lines[0].Time!.Value, 6);

    [Fact]
    public void KeepsPlainLyrics()
    {
        var lyrics = SyncedLyrics.Parse("\nFirst line\n\nSecond line\n\n");
        Assert.False(lyrics.IsSynced);
        Assert.Equal("First line\n\nSecond line", lyrics.PlainText);
        Assert.Null(lyrics.LineIndex(5));
    }
}

public class MatchingTests
{
    internal const string ReleaseJson = """
        {"id":"6a09041b-0f79-3278-88d9-0552dd28d37f","title":"OK Computer","status":"Official","date":"1997-07-01","country":"US",
         "artist-credit":[{"name":"Radiohead","joinphrase":"","artist":{"id":"a74b1b7f-71a5-4011-9441-d0b5e4122711","name":"Radiohead"}}],
         "release-group":{"id":"b1392450-e666-3926-a536-22c65f834433","title":"OK Computer","primary-type":"Album","secondary-types":[],
                          "first-release-date":"1997-05-21",
                          "genres":[{"name":"alternative rock","count":27},{"name":"art rock","count":15}]},
         "genres":[],
         "media":[{"position":1,"format":"CD","track-count":3,"tracks":[
            {"id":"t1","number":"1","position":1,"title":"Airbag","length":284400,"recording":{"id":"rec-1","title":"Airbag"}},
            {"id":"t2","number":"2","position":2,"title":"Paranoid Android","length":383493,"recording":{"id":"rec-2","title":"Paranoid Android"}},
            {"id":"t3","number":"3","position":3,"title":"Subterranean Homesick Alien","length":267000,"recording":{"id":"rec-3","title":"Subterranean Homesick Alien"}}
         ]}]}
        """;

    internal static MBRelease Release() => JsonSerializer.Deserialize<MBRelease>(ReleaseJson)!;

    [Fact]
    public void GuessesFromFileNames()
    {
        var full = new FileNameGuess("03 - Radiohead - Karma Police");
        Assert.True(full.TrackNumber == 3 && full.Artist == "Radiohead" && full.Title == "Karma Police");
        var numbered = new FileNameGuess("07. Lucky");
        Assert.True(numbered.TrackNumber == 7 && numbered.Artist is null && numbered.Title == "Lucky");
        var discTrack = new FileNameGuess("1-04 Exit Music (For a Film)");
        Assert.True(discTrack.TrackNumber == 4 && discTrack.Title == "Exit Music (For a Film)");
        var plain = new FileNameGuess("Radiohead - No Surprises");
        Assert.True(plain.TrackNumber is null && plain.Artist == "Radiohead" && plain.Title == "No Surprises");
        var numericTitle = new FileNameGuess("1979");
        Assert.True(numericTitle.TrackNumber is null && numericTitle.Title == "1979");
    }

    [Fact]
    public void ComparesLoosely()
    {
        Assert.Equal("beatles", "The Beatles".MatchKey());
        Assert.Equal("exit music for a film", "Exit Music (For a Film)".MatchKey());
        Assert.Equal("simon and garfunkel", "Simon & Garfunkel".MatchKey());
        Assert.Equal("beyonce", "Beyoncé".MatchKey());
        Assert.True("paranoid android".Similarity("paranoid androd") > 0.9);
        Assert.True("airbag".Similarity("lucky") < 0.3);
    }

    [Fact]
    public void PairsFilesWithTracks()
    {
        var release = Release();
        LocalTrackInfo[] local =
        [
            new(1, "Paranoid Androd", null, 2, null, 384),
            new(2, "Airbag", null, 1, null, 285),
            new(3, "Subterranean Homesick Alien", null, null, null, 268),
            new(4, "Voice Memo", null, 9, null, 30),
        ];
        var match = ReleaseMatcher.Match(local, release);
        Assert.Equal(2, match.MatchFor(1)?.TrackNumber);
        Assert.Equal(1, match.MatchFor(2)?.TrackNumber);
        Assert.Equal(3, match.MatchFor(3)?.TrackNumber);
        Assert.Equal([4L], match.UnmatchedLocalIds);
        Assert.True(match.Score is > 0.6 and < 1);

        var proposal = ReleaseMatcher.Proposal(match);
        var android = proposal[1];
        Assert.Equal("Paranoid Android", android.Title);
        Assert.True(android.Album == "OK Computer" && android.AlbumArtist == "Radiohead" && android.Artist == "Radiohead");
        Assert.True(android.Year == 1997 && android.TrackNumber == 2 && android.TrackTotal == 3 && android.DiscNumber == 1 && android.DiscTotal == 1);
        Assert.Equal("Alternative Rock", android.Genre);
        Assert.Equal("6a09041b-0f79-3278-88d9-0552dd28d37f", android.MusicBrainzReleaseId);
        Assert.Equal("rec-2", android.MusicBrainzRecordingId);
        Assert.False(android.IsCompilation);
        Assert.False(proposal.ContainsKey(4));
    }

    private static MBRelease Ranked(string id, int score, int tracks, string status = "Official", List<string>? secondary = null, string? format = null) => new()
    {
        Id = id, Title = "OK Computer", Score = score, Status = status, TrackCount = tracks,
        ReleaseGroup = new MBReleaseGroup { Id = "g", PrimaryType = "Album", SecondaryTypes = secondary ?? [] },
        Media = format is null ? null : [new MBMedium { Position = 1, Format = format, TrackCount = tracks }],
    };

    [Fact]
    public void RanksTheLikelyAlbumFirst()
    {
        var ranked = ReleaseMatcher.Rank([
            Ranked("live", 100, 12, secondary: ["Live"]), Ranked("bootleg", 100, 12, "Bootleg"), Ranked("deluxe", 100, 35),
            Ranked("studio", 98, 12), Ranked("studio", 98, 12),
        ], 12);
        Assert.Equal(["studio", "live", "bootleg", "deluxe"], ranked.Select(release => release.Id));
    }

    [Fact]
    public void PrefersTheClosestAudioEditionForLooseFiles()
    {
        var ranked = ReleaseMatcher.Rank([Ranked("box", 100, 33, format: "DVD-Video"), Ranked("deluxe", 100, 27, format: "CD"), Ranked("cd", 100, 12, format: "CD")], 4);
        Assert.Equal(["cd", "deluxe", "box"], ranked.Select(release => release.Id));
    }

    [Fact]
    public void OffersAlbumFieldsToSongsMissingFromTheRelease()
    {
        var match = ReleaseMatcher.Match([new LocalTrackInfo(1, "Airbag", null, 1, null, 285), new LocalTrackInfo(4, "Voice Memo", null, 9, null, 30)], Release());
        Assert.False(ReleaseMatcher.Proposal(match).ContainsKey(4));
        var stray = ReleaseMatcher.Proposal(match, includingUnmatched: true)[4];
        Assert.True(stray.Album == "OK Computer" && stray.AlbumArtist == "Radiohead" && stray.Year == 1997);
        Assert.Equal("6a09041b-0f79-3278-88d9-0552dd28d37f", stray.MusicBrainzReleaseId);
        Assert.True(stray.Title is null && stray.TrackNumber is null && stray.MusicBrainzRecordingId is null);
    }

    internal static Track Song(long id, string title, string album, double duration = 200)
    {
        var track = TestLibrary.MakeTrack(1, title, "Radiohead", album, (int)id);
        track.Id = id;
        track.Duration = duration;
        return track;
    }

    [Fact]
    public void GroupsSongsTaggedWithDifferentAlbums()
    {
        Track[] songs = [Song(1, "Airbag", "OK Computer"), Song(2, "Lucky", "OK Computer"), Song(3, "Paranoid Android", "Pablo Honey"),
                         Song(4, "Let Down", "OK Computer"), Song(5, "No Surprises", "Untitled")];
        var group = new SongGroup(songs, sampleSize: 3);
        Assert.True(group.Album == "OK Computer" && group.Artist == "Radiohead");
        Assert.True(group.AlbumCount == 3 && group.IsMixed);
        Assert.Equal([1L, 3, 5], group.Sample.Select(info => info.Id));
        Assert.False(new SongGroup(songs.Take(2).ToList()).IsMixed);
    }

    [Fact]
    public void UsesTheOriginalYear()
    {
        Assert.Equal(1997, new MBRelease { Id = "r", Title = "OK Computer", Date = "2009-03-24", ReleaseGroup = new MBReleaseGroup { Id = "g", FirstReleaseDate = "1997-05-21" } }.Year);
        Assert.Equal(2009, new MBRelease { Id = "r", Title = "X", Date = "2009" }.Year);
    }
}

/// <summary>Serves canned responses by URL path and records the requests.</summary>
internal sealed class StubFetcher(Dictionary<string, (int Status, string Body)> routes) : IHttpFetcher
{
    private readonly Lock gate = new();
    public List<(Uri Url, IReadOnlyDictionary<string, string> Headers)> Requests { get; } = [];

    public Task<(byte[] Data, int Status)> GetAsync(Uri url, IReadOnlyDictionary<string, string> headers, CancellationToken cancellation = default)
    {
        lock (gate)
        {
            Requests.Add((url, headers));
            var (status, body) = routes.TryGetValue(Uri.UnescapeDataString(url.AbsolutePath), out var route) ? route : (404, "");
            return Task.FromResult((System.Text.Encoding.UTF8.GetBytes(body), status));
        }
    }

    public static string? Query(Uri url, string name) =>
        url.Query.TrimStart('?').Split('&').Select(part => part.Split('=', 2)).Where(pair => Uri.UnescapeDataString(pair[0]) == name)
            .Select(pair => Uri.UnescapeDataString(pair[1])).FirstOrDefault();
}

/// <summary>Answers 503 the first time, then 200 with <paramref name="body"/>.</summary>
internal sealed class FlakyFetcher(string body) : IHttpFetcher
{
    public int Calls { get; private set; }

    public Task<(byte[] Data, int Status)> GetAsync(Uri url, IReadOnlyDictionary<string, string> headers, CancellationToken cancellation = default)
    {
        Calls++;
        return Task.FromResult((System.Text.Encoding.UTF8.GetBytes(body), Calls == 1 ? 503 : 200));
    }
}

public class ClientTests
{
    private readonly ClientIdentity identity = new("1.0", Contact: "me@example.com");
    private static RateLimiter NoWait => new(TimeSpan.Zero);

    [Fact]
    public async Task RetriesWhenMusicBrainzSaysSlowDown()
    {
        var flaky = new FlakyFetcher("""{"releases":[]}""");
        await new MusicBrainzClient(flaky, identity, NoWait).SearchReleasesAsync("X", null, cancellation: TestContext.Current.CancellationToken);
        Assert.Equal(2, flaky.Calls);
    }

    [Fact]
    public async Task SearchesMusicBrainz()
    {
        var stub = new StubFetcher(new() { ["/ws/2/release"] = (200, $$"""{"releases":[{{MatchingTests.ReleaseJson}}]}""") });
        var releases = await new MusicBrainzClient(stub, identity, NoWait).SearchReleasesAsync("OK Computer (Remastered)", "Radiohead", cancellation: TestContext.Current.CancellationToken);
        Assert.Equal("OK Computer", releases[0].Title);
        var (url, headers) = stub.Requests[0];
        Assert.Equal("Groovelight/1.0 ( me@example.com )", headers["User-Agent"]);
        Assert.Equal(@"release:(OK Computer \(Remastered\)) AND artist:(Radiohead)", StubFetcher.Query(url, "query"));
        Assert.Equal("json", StubFetcher.Query(url, "fmt"));
    }

    private MetadataService Service(StubFetcher stub) => new(identity, stub);

    [Fact]
    public async Task FindsTheAlbumOfSongsWithMixedUpTags()
    {
        const string wrong = """{"releases":[{"id":"pablo","title":"Pablo Honey","score":100,"status":"Official","track-count":3}]}""";
        const string right = """{"id":"okc","title":"OK Computer","status":"Official","track-count":3}""";
        var recordings = string.Join(",", new[] { "Airbag", "Paranoid Android", "Lucky" }.Select(title =>
            $$"""{"id":"rec-{{title}}","title":"{{title}}","score":100,"length":200000,"releases":[{{right}}]}"""));
        var stub = new StubFetcher(new() { ["/ws/2/release"] = (200, wrong), ["/ws/2/recording"] = (200, $$"""{"recordings":[{{recordings}}]}""") });
        Track[] songs = [MatchingTests.Song(1, "Airbag", "Pablo Honey"), MatchingTests.Song(2, "Paranoid Android", "Pablo Honey"), MatchingTests.Song(3, "Lucky", "OK Computer")];
        var candidates = await Service(stub).CandidatesAsync(songs, cancellation: TestContext.Current.CancellationToken);
        Assert.Equal(["okc", "pablo"], candidates.Select(release => release.Id));
        var paths = stub.Requests.Select(request => request.Url.AbsolutePath).ToList();
        Assert.Equal("/ws/2/release", paths[0]);
        Assert.Equal(3, paths.Count(path => path == "/ws/2/recording"));

        // Songs tagged as one album keep the plain album search.
        var tagged = new StubFetcher(new() { ["/ws/2/release"] = (200, wrong) });
        Assert.Equal(["pablo"], (await Service(tagged).CandidatesAsync(songs.Take(2).ToList(), cancellation: TestContext.Current.CancellationToken)).Select(release => release.Id));
        Assert.Single(tagged.Requests);
    }

    [Fact]
    public async Task SearchesWithoutAClearedField()
    {
        var stub = new StubFetcher(new() { ["/ws/2/release"] = (200, $$"""{"releases":[{{MatchingTests.ReleaseJson}}]}""") });
        var service = Service(stub);
        Track[] songs = [MatchingTests.Song(1, "Airbag", "OK Computer"), MatchingTests.Song(2, "Lucky", "OK Computer")];
        await service.CandidatesAsync(songs, "OK Computer", "", TestContext.Current.CancellationToken);
        Assert.Equal("release:(OK Computer)", StubFetcher.Query(stub.Requests[^1].Url, "query"));
        await service.CandidatesAsync(songs, cancellation: TestContext.Current.CancellationToken);
        Assert.Equal("release:(OK Computer) AND artist:(Radiohead)", StubFetcher.Query(stub.Requests[^1].Url, "query"));
    }

    [Fact]
    public async Task RateLimitsRequests()
    {
        var limiter = new RateLimiter(TimeSpan.FromMilliseconds(150));
        var watch = System.Diagnostics.Stopwatch.StartNew();
        for (var index = 0; index < 3; index++) await limiter.WaitAsync(TestContext.Current.CancellationToken);
        Assert.True(watch.Elapsed >= TimeSpan.FromMilliseconds(285));
    }

    [Fact]
    public async Task FallsBackToLyricsSearch()
    {
        const string search = """
            [{"trackName":"Karma Police","artistName":"Someone Else","duration":264,"syncedLyrics":"[00:01.00]Wrong"},
             {"trackName":"Karma Police","artistName":"Radiohead","duration":263,"plainLyrics":"Plain only"},
             {"trackName":"Karma Police (Live)","artistName":"Radiohead","duration":264,"syncedLyrics":"[00:26.78]Karma police"}]
            """;
        var stub = new StubFetcher(new() { ["/api/search"] = (200, search) });
        var lyrics = await new LrcLibClient(stub, identity, NoWait).LyricsAsync("Karma Police", "Radiohead", "OK Computer", 264, TestContext.Current.CancellationToken);
        Assert.Equal("[00:26.78]Karma police", lyrics?.Synced);
        Assert.Equal(["/api/get", "/api/search"], stub.Requests.Select(request => request.Url.AbsolutePath));
    }

    [Fact]
    public async Task RetriesWhenLrcLibIsBusy()
    {
        var busy = new FlakyFetcher("""{"plainLyrics":"Hi"}""");
        var lyrics = await new LrcLibClient(busy, identity, NoWait).LyricsAsync("A", "B", null, 100, TestContext.Current.CancellationToken);
        Assert.True(lyrics?.Plain == "Hi" && busy.Calls == 2);
    }

    [Fact]
    public async Task ReturnsExactLyrics()
    {
        var stub = new StubFetcher(new() { ["/api/get"] = (200, """{"instrumental":false,"plainLyrics":"Hi","syncedLyrics":""}""") });
        var lyrics = await new LrcLibClient(stub, identity, NoWait).LyricsAsync("A", "B", null, 100, TestContext.Current.CancellationToken);
        Assert.Equal(new FetchedLyrics(null, "Hi", false), lyrics);
        Assert.Equal("100", StubFetcher.Query(stub.Requests[0].Url, "duration"));
    }

    [Fact]
    public async Task PicksITunesArtwork()
    {
        const string body = """
            {"results":[{"collectionName":"OK Computer OKNOTOK 1997 2017","artistName":"Radiohead","artworkUrl100":"https://x/a/100x100bb.jpg"},
                        {"collectionName":"OK Computer","artistName":"Radiohead","artworkUrl100":"https://x/b/100x100bb.jpg"}]}
            """;
        var candidate = await new ArtworkClient(new StubFetcher(new() { ["/search"] = (200, body) }), identity).ITunesAsync("OK Computer", "Radiohead", TestContext.Current.CancellationToken);
        Assert.Equal("https://x/a/3000x3000bb.jpg", candidate?.Url.AbsoluteUri);
        Assert.Equal(ArtworkSource.ITunes, candidate?.Source);
    }

    [Fact]
    public void EncodesPlusSigns() => Assert.Equal("https://example.com/s?q=AC%2BDC", HttpFetching.Build("https://example.com/s", ("q", "AC+DC")).AbsoluteUri);
}

public class CreditsTests
{
    internal static MBRelease Release() =>
        JsonSerializer.Deserialize<MBRelease>(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "ok-computer-credits.json")))!;

    [Fact]
    public void BuildsAlbumAndTrackCredits()
    {
        var release = Release();
        var match = ReleaseMatcher.Match([new LocalTrackInfo(7, "Karma Police", null, 6, null, 264)], release);
        var info = CreditsBuilder.AlbumInfo(release, match, null);
        var kinds = info.Sections.Select(section => section.Kind).ToList();
        Assert.True(kinds.Contains(CreditKind.Musicians) && kinds.Contains(CreditKind.Songwriting) && kinds.Contains(CreditKind.Production));
        var colin = info.Sections.First(section => section.Kind == CreditKind.Musicians).Credits.First(credit => credit.Name == "Colin Greenwood");
        Assert.Contains("bass guitar", colin.Roles);
        var production = info.Sections.First(section => section.Kind == CreditKind.Production);
        Assert.Contains("producer", production.Credits.First(credit => credit.Name == "Nigel Godrich").Roles);
        Assert.Contains(production.Credits, credit => credit.Roles.Contains("assistant engineer"));
        Assert.Contains(info.Sections.First(section => section.Kind == CreditKind.Songwriting).Credits, credit => credit.Name == "Thom Yorke");

        var track = TestLibrary.MakeTrack(1, "Karma Police", "Radiohead", "OK Computer", 6);
        track.Id = 7;
        var songCredits = info.SectionsForTrack(track);
        Assert.Contains(songCredits, section => section.Kind == CreditKind.Musicians);
        Assert.DoesNotContain(songCredits.FirstOrDefault(section => section.Kind == CreditKind.Production)?.Credits ?? [], credit => credit.Name == "Nick Ingman");
        Assert.Contains(songCredits.First(section => section.Kind == CreditKind.Musicians).Credits, credit => credit.Name == "Nick Ingman" && credit.Roles.SequenceEqual(["conductor"]));
    }

    [Fact]
    public void RoundTripsThroughTheLibraryInTheMacFormat()
    {
        using var database = LibraryDatabase.InMemory();
        var info = CreditsBuilder.AlbumInfo(Release(), null, new AlbumAbout { Title = "OK Computer", Summary = "Third album.", Url = "https://en.wikipedia.org/wiki/OK_Computer", Language = "en" });
        database.SetAlbumInfo(info.Encode(), "radiohead\u001Fok computer");
        var stored = database.Read(db => db.AlbumInfo("radiohead\u001Fok computer"))!.Value;
        var decoded = AlbumInfo.Decode(stored.Data)!;
        Assert.Equal(info.Sections.Count, decoded.Sections.Count);
        Assert.Equal("Third album.", decoded.About?.Summary);
        // Swift's keys and raw values.
        var json = System.Text.Encoding.UTF8.GetString(stored.Data);
        Assert.Contains("\"kind\":\"Musicians\"", json);
        Assert.Contains("\"releaseSections\"", json);
        Assert.Contains("\"fetchedAt\":", json);
    }

    [Fact]
    public void ReadsAlbumInfoWrittenByTheMac()
    {
        const string mac = """
            {"sections":[{"kind":"Recorded At","credits":[{"name":"St Catherine's Court","roles":["recording"]}]}],"trackSections":{},
             "localRecordings":{"7":"rec-6"},"about":{"title":"OK Computer","summary":"Third.","url":"https:\/\/en.wikipedia.org\/wiki\/OK_Computer","language":"en"},
             "fetchedAt":783000000}
            """;
        var info = AlbumInfo.Decode(System.Text.Encoding.UTF8.GetBytes(mac))!;
        Assert.Equal(CreditKind.RecordedAt, info.Sections[0].Kind);
        Assert.Equal("https://en.wikipedia.org/wiki/OK_Computer", info.About?.Url);
        Assert.Equal(Dates.FromReferenceSeconds(783000000), info.FetchedAt);
    }

    [Fact]
    public void IndexesPeopleAcrossTheLibrary()
    {
        using var database = LibraryDatabase.InMemory();
        var root = database.AddRoot("/music");
        var ids = new List<long>();
        database.Write(db =>
        {
            foreach (var (number, title) in new[] { (1, "Airbag"), (6, "Karma Police") })
            {
                var track = TestLibrary.MakeTrack(root.Id!.Value, title, "Radiohead", "OK Computer", number);
                db.Insert(track);
                ids.Add(track.Id!.Value);
            }
        });
        var release = Release();
        var info = CreditsBuilder.AlbumInfo(release, ReleaseMatcher.Match([new LocalTrackInfo(ids[0], "Airbag", null, 1, null, 284), new LocalTrackInfo(ids[1], "Karma Police", null, 6, null, 264)], release), null);
        var key = Track.MakeAlbumKey("OK Computer", null, "Radiohead", false);
        database.SetCredits(info.CreditEntries(key), key);
        var nigelId = info.Sections.SelectMany(section => section.Credits).First(credit => credit.Name == "Nigel Godrich").ArtistId;
        var nigel = database.Read(db => db.Credits(new CreditPerson("Nigel Godrich", nigelId)));
        Assert.Equal(["OK Computer"], nigel.Albums.Select(album => album.Album.Title));
        Assert.Equal(["Airbag", "Karma Police"], nigel.Tracks.Select(item => item.Track.Title));
        Assert.Contains("producer", nigel.Roles);
        var stanleyId = info.Sections.SelectMany(section => section.Credits).First(credit => credit.Name == "Stanley Donwood").ArtistId;
        var stanley = database.Read(db => db.Credits(new CreditPerson("Stanley Donwood", stanleyId)));
        Assert.Equal(2, stanley.Tracks.Count);
        Assert.Equal(["design and illustration"], stanley.Roles);
        database.SetCredits(info.CreditEntries(key), key);
        Assert.Equal(2, database.Read(db => db.Credits(new CreditPerson("Nigel Godrich", nigelId))).Tracks.Count);
    }

    [Fact]
    public async Task ReadsWikipediaThroughWikidata()
    {
        var stub = new StubFetcher(new()
        {
            ["/w/api.php"] = (200, """{"entities":{"Q202996":{"sitelinks":{"enwiki":{"title":"OK Computer"}}}}}"""),
            ["/api/rest_v1/page/summary/OK_Computer"] = (200, """
                {"type":"standard","title":"OK Computer","extract":"OK Computer is the third studio album by Radiohead.",
                 "content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/OK_Computer"}}}
                """),
        });
        var about = await new WikipediaClient(stub, new ClientIdentity("1")).SummaryAsync("Q202996", ["pt", "en"], TestContext.Current.CancellationToken);
        Assert.StartsWith("OK Computer is the third", about?.Summary);
        Assert.Equal("en", about?.Language);
        Assert.Equal("https://en.wikipedia.org/wiki/OK_Computer", about?.Url);
    }
}

public class ArtistInfoTests
{
    [Fact]
    public async Task FindsTheArtistThroughAnAlbum()
    {
        var stub = new StubFetcher(new()
        {
            ["/ws/2/release"] = (200, """{"releases":[{"id":"r1","title":"Nevermind","score":100,"artist-credit":[{"name":"Nirvana","artist":{"id":"nirvana-us","name":"Nirvana"}}]}]}"""),
            ["/ws/2/artist/nirvana-us"] = (200, """{"id":"nirvana-us","name":"Nirvana","relations":[{"type":"wikidata","url":{"resource":"https://www.wikidata.org/wiki/Q11649"}}]}"""),
            ["/w/api.php"] = (200, """{"entities":{"Q11649":{"sitelinks":{"enwiki":{"title":"Nirvana (band)"}}}}}"""),
            ["/api/rest_v1/page/summary/Nirvana_(band)"] = (200, """{"type":"standard","title":"Nirvana (band)","extract":"Nirvana was an American rock band.","content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/Nirvana_(band)"}}}"""),
        });
        var info = await new MetadataService(new ClientIdentity("1"), stub).ArtistInfoAsync("Nirvana", ["Nevermind"], ["en"], TestContext.Current.CancellationToken);
        Assert.Equal("nirvana-us", info.ArtistId);
        Assert.Equal("Nirvana was an American rock band.", info.About?.Summary);
        Assert.DoesNotContain(stub.Requests, request => request.Url.AbsolutePath == "/ws/2/artist");
    }

    /// <summary>
    /// "Too many requests" from Wikipedia fails the lookup (nothing is kept, the next look tries again); an article that is
    /// not there is an answer. Info saved before this, artist found but no article, is looked up again.
    /// </summary>
    [Fact]
    public async Task TellsBusyWikipediaFromNoArticle()
    {
        Dictionary<string, (int, string)> Routes(int summary) => new()
        {
            ["/ws/2/release"] = (200, """{"releases":[{"id":"r1","title":"Nevermind","score":100,"artist-credit":[{"name":"Nirvana","artist":{"id":"nirvana-us","name":"Nirvana"}}]}]}"""),
            ["/ws/2/artist/nirvana-us"] = (200, """{"id":"nirvana-us","name":"Nirvana","relations":[{"type":"wikidata","url":{"resource":"https://www.wikidata.org/wiki/Q11649"}}]}"""),
            ["/w/api.php"] = (200, """{"entities":{"Q11649":{"sitelinks":{"enwiki":{"title":"Nirvana (band)"}}}}}"""),
            ["/api/rest_v1/page/summary/Nirvana_(band)"] = (summary, "{}"),
        };
        var token = TestContext.Current.CancellationToken;
        var busy = new MetadataService(new ClientIdentity("1"), new StubFetcher(Routes(429)));
        var error = await Assert.ThrowsAsync<MetadataException>(() => busy.ArtistInfoAsync("Nirvana", ["Nevermind"], ["en"], token));
        Assert.Equal(MetadataErrorKind.Http, error.Kind);
        var missing = await new MetadataService(new ClientIdentity("1"), new StubFetcher(Routes(404))).ArtistInfoAsync("Nirvana", ["Nevermind"], ["en"], token);
        Assert.Equal(("nirvana-us", (AlbumAbout?)null, (bool?)true, false), (missing.ArtistId, missing.About, missing.AboutChecked, missing.NeedsAbout));
        var saved = ArtistInfo.Decode("""{"artistId":"nirvana-us","fetchedAt":815827845.6,"imageChecked":true}"""u8.ToArray())!;
        Assert.True(saved.NeedsAbout);
        Assert.False(new ArtistInfo { FetchedAt = DateTime.UtcNow }.NeedsAbout);
    }

    [Fact]
    public void TidiesWikipediaSummaries()
    {
        Assert.Equal("The members are Thom Yorke; brothers Jonny and Colin Greenwood (bass); Ed O'Brien; and Philip Selway.",
                     WikipediaClient_Tidy("The members are Thom Yorke ; brothers Jonny and Colin Greenwood (bass); Ed O'Brien ; and Philip Selway."));
        Assert.Equal("Björk is a singer.", WikipediaClient_Tidy("Björk ( ) is a singer ."));
    }

    private static string WikipediaClient_Tidy(string text) => WikipediaClient.Tidy(text);

    [Fact]
    public void PicksArtistPhotoSizes()
    {
        const string thumb = "https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/Radiohead.jpg/330px-Radiohead.jpg";
        Assert.Equal("https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/Radiohead.jpg/960px-Radiohead.jpg",
                     WikipediaClient.ImageUrl(thumb, "https://upload.wikimedia.org/x/Radiohead.jpg", 5940));
        Assert.Equal("https://upload.wikimedia.org/x/Small.jpg", WikipediaClient.ImageUrl(thumb, "https://upload.wikimedia.org/x/Small.jpg", 367));
        Assert.Null(WikipediaClient.ImageUrl(null, null, null));
    }

    [Fact]
    public void StoresArtistInfoByName()
    {
        using var database = LibraryDatabase.InMemory();
        database.SetArtistInfo("{}"u8.ToArray(), "Radiohead");
        Assert.NotNull(database.Read(db => db.ArtistInfo("RADIOHEAD")));
    }
}
