using System.Net;
using Groovelight.Core.Library;
using Groovelight.Metadata;

namespace Groovelight.Tests;

/// <summary>The Mac's ScrobblerTests, ported.</summary>
public class LastFmTests
{
    /// <summary>Answers each request from its form parameters, and keeps them.</summary>
    private sealed class FakeLastFm(Func<Dictionary<string, string>, (int Status, string Body)> answer) : HttpMessageHandler
    {
        public List<Dictionary<string, string>> Calls { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var text = request.Content is null ? request.RequestUri!.Query.TrimStart('?') : await request.Content.ReadAsStringAsync(cancellationToken);
            var parameters = text.Split('&', StringSplitOptions.RemoveEmptyEntries).Select(pair => pair.Split('=', 2))
                .ToDictionary(pair => Uri.UnescapeDataString(pair[0]), pair => Uri.UnescapeDataString(pair.Length > 1 ? pair[1] : ""));
            Calls.Add(parameters);
            var (status, body) = answer(parameters);
            return new HttpResponseMessage((HttpStatusCode)status) { Content = new StringContent(body) };
        }
    }

    [Fact]
    public void SignsRequestsLikeLastFm()
    {
        Assert.Equal("0bf279e021f3a81b4553dd7e76cf72ad",
            LastFmClient.Signature(new Dictionary<string, string> { ["method"] = "auth.getSession", ["api_key"] = "KEY", ["token"] = "TOK", ["format"] = "json" }, "SECRET"));
        Assert.Equal("5db62934573e3bf31004fd1dcef6cd8d", LastFmClient.Signature(new Dictionary<string, string>
        {
            ["method"] = "track.scrobble", ["api_key"] = "KEY", ["sk"] = "SK", ["artist[0]"] = "Björk", ["track[0]"] = "Jóga", ["timestamp[0]"] = "1700000000",
        }, "SECRET"));
    }

    [Fact]
    public void ScrobbleRulesFollowLastFm()
    {
        Assert.False(ScrobbleRules.IsEligible(30, 30));
        Assert.True(ScrobbleRules.IsEligible(200, 100));
        Assert.False(ScrobbleRules.IsEligible(200, 99));
        // Long songs: 4 minutes are enough.
        Assert.True(ScrobbleRules.IsEligible(1200, 240));
        Assert.False(ScrobbleRules.IsEligible(1200, 239));
    }

    [Fact]
    public void EncodesBatchesAndForms()
    {
        var date = DateTime.UnixEpoch.AddSeconds(1_700_000_000);
        var parameters = LastFmClient.ScrobbleParameters([(new LastFmTrack("A", "One", "X", Duration: 199.6, TrackNumber: 1), date), (new LastFmTrack("B", "Two"), date.AddSeconds(200))]);
        Assert.Equal("A", parameters["artist[0]"]);
        Assert.Equal("200", parameters["duration[0]"]);
        Assert.Equal("1", parameters["trackNumber[0]"]);
        Assert.Equal("1700000200", parameters["timestamp[1]"]);
        Assert.False(parameters.ContainsKey("album[1]"));
        Assert.Equal("artist=Bj%C3%B6rk&track=J%C3%B3ga%20%26%20Co%2B", LastFmClient.FormEncoded(new Dictionary<string, string> { ["track"] = "Jóga & Co+", ["artist"] = "Björk" }));
    }

    [Fact]
    public void QueueKeepsOnlyTheLastLoveOfASong()
    {
        using var database = LibraryDatabase.InMemory();
        database.EnqueueLastFm(new LastFmQueueItem { Kind = LastFmKind.Love, Artist = "A", Track = "One", Timestamp = DateTime.UtcNow });
        database.EnqueueLastFm(new LastFmQueueItem { Kind = LastFmKind.Unlove, Artist = "a", Track = "one", Timestamp = DateTime.UtcNow });
        database.EnqueueLastFm(new LastFmQueueItem { Kind = LastFmKind.Scrobble, Artist = "A", Track = "One", Timestamp = DateTime.UtcNow });
        Assert.Equal([LastFmKind.Unlove], database.PendingLastFm([LastFmKind.Love, LastFmKind.Unlove], 10).Select(item => item.Kind));
        Assert.Equal(2, database.Read(db => db.LastFmQueueCount()));
    }

    [Fact]
    public async Task SendsTheQueueAndHandlesFailures()
    {
        using var database = LibraryDatabase.InMemory();
        var start = DateTime.UnixEpoch.AddSeconds(1_700_000_000);
        for (var index = 0; index < 55; index++)
            database.EnqueueLastFm(new LastFmQueueItem { Kind = LastFmKind.Scrobble, Artist = "A", Track = $"Song {index}", Duration = 200, Timestamp = start.AddSeconds(index * 200) });
        database.EnqueueLastFm(new LastFmQueueItem { Kind = LastFmKind.Love, Artist = "A", Track = "Song 1", Timestamp = DateTime.UtcNow });
        var sender = new LastFmSender(database);
        var credentials = new LastFmCredentials("KEY", "SECRET");

        // Last.fm down: everything waits.
        var down = new FakeLastFm(_ => (503, """{"error": 11, "message": "Service Offline"}"""));
        Assert.Equal(new LastFmSender.Outcome.Postponed("Service Offline"), await sender.SendAsync(new LastFmClient(credentials, "SK", down)));
        Assert.Equal(56, database.PendingLastFm([LastFmKind.Scrobble, LastFmKind.Love], 100).Count);

        // Up: two batches (50 + 5) and the love, all signed with the session key.
        var up = new FakeLastFm(parameters => parameters["method"] == "track.scrobble"
            ? (200, """{"scrobbles": {"@attr": {"accepted": """ + parameters.Keys.Count(key => key.StartsWith("artist[", StringComparison.Ordinal)) + """, "ignored": 0}}}""")
            : (200, "{}"));
        Assert.Equal(new LastFmSender.Outcome.Sent(55, 1, 0), await sender.SendAsync(new LastFmClient(credentials, "SK", up)));
        Assert.Empty(database.PendingLastFm([LastFmKind.Scrobble, LastFmKind.Love], 100));
        Assert.Equal(["track.scrobble", "track.scrobble", "track.love"], up.Calls.Select(call => call["method"]));
        Assert.All(up.Calls, call => Assert.True(call["sk"] == "SK" && call["api_sig"].Length == 32));
        Assert.Equal(50, up.Calls[0].Keys.Count(key => key.StartsWith("artist[", StringComparison.Ordinal)));

        // Session revoked: stop and ask to connect again; the scrobble waits.
        database.EnqueueLastFm(new LastFmQueueItem { Kind = LastFmKind.Scrobble, Artist = "A", Track = "Later", Timestamp = DateTime.UtcNow });
        var revoked = new FakeLastFm(_ => (403, """{"error": 9, "message": "Invalid session key"}"""));
        Assert.Equal(new LastFmSender.Outcome.NeedsReconnect("Invalid session key"), await sender.SendAsync(new LastFmClient(credentials, "SK", revoked)));
        Assert.Single(database.PendingLastFm([LastFmKind.Scrobble], 10));

        // A song Last.fm keeps refusing is dropped after a few tries; the others still go.
        database.EnqueueLastFm(new LastFmQueueItem { Kind = LastFmKind.Scrobble, Artist = "A", Track = "Bad", Timestamp = DateTime.UtcNow.AddSeconds(1) });
        var picky = new FakeLastFm(parameters => parameters.ContainsValue("Bad") ? (400, """{"error": 6, "message": "Invalid parameters"}""")
            : (200, """{"scrobbles": {"@attr": {"accepted": 1, "ignored": 0}}}"""));
        Assert.Equal(new LastFmSender.Outcome.Sent(1, 0, 0), await sender.SendAsync(new LastFmClient(credentials, "SK", picky)));
        Assert.Empty(database.PendingLastFm([LastFmKind.Scrobble], 10));
    }

    [Fact]
    public async Task AuthenticatesInThreeSteps()
    {
        var fake = new FakeLastFm(parameters => parameters["method"] switch
        {
            "auth.getToken" => (200, """{"token": "TOK"}"""),
            "auth.getSession" when parameters["token"] == "TOK" => (200, """{"session": {"name": "irwing", "key": "SESSION"}}"""),
            _ => (403, """{"error": 14, "message": "Unauthorized Token"}"""),
        });
        var client = new LastFmClient(new LastFmCredentials("KEY", "SECRET"), handler: fake);
        var token = await client.GetTokenAsync();
        Assert.Equal("https://www.last.fm/api/auth/?api_key=KEY&token=TOK", client.AuthorizationUrl(token).ToString());
        Assert.Equal(("irwing", "SESSION"), await client.GetSessionAsync(token));
        var error = await Assert.ThrowsAsync<LastFmException>(() => client.GetSessionAsync("OTHER"));
        Assert.True(error.IsUnauthorizedToken);
    }
}

/// <summary>The Mac's LastFMHistoryTests, ported.</summary>
public class LastFmHistoryTests
{
    private sealed class Pages(Func<Dictionary<string, string>, (int Status, string Body)> answer) : HttpMessageHandler
    {
        public List<Dictionary<string, string>> Calls { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var parameters = request.RequestUri!.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries).Select(pair => pair.Split('=', 2))
                .ToDictionary(pair => Uri.UnescapeDataString(pair[0]), pair => Uri.UnescapeDataString(pair.Length > 1 ? pair[1] : ""));
            Calls.Add(parameters);
            var (status, body) = answer(parameters);
            return Task.FromResult(new HttpResponseMessage((HttpStatusCode)status) { Content = new StringContent(body) });
        }
    }

    [Fact]
    public void MatchesNamesSpelledDifferently()
    {
        Assert.Equal(SongKey.Key("Beyonce", "Crazy In Love"), SongKey.Key("Beyoncé feat. JAY-Z", "Crazy in Love (Remastered 2023)"));
        Assert.Equal(SongKey.Key("Beatles", "Something"), SongKey.Key("The Beatles", "Something - 2019 Mix"));
        Assert.Equal(SongKey.Key("Simon and Garfunkel", "Mrs Robinson"), SongKey.Key("Simon & Garfunkel", "Mrs. Robinson"));
        Assert.Equal("stay with me", SongKey.Normalize("Stay With Me"));
        Assert.NotEqual(SongKey.Key("Radiohead", "Lucky"), SongKey.Key("Radiohead", "Airbag"));
    }

    [Fact]
    public void ReadsAPageOfHistory()
    {
        var json = System.Text.Json.JsonDocument.Parse("""
            {"recenttracks": {"@attr": {"page": "2", "totalPages": "7", "total": "1300"}, "track": [
              {"name": "Now", "artist": {"#text": "A"}, "album": {"#text": "B"}, "@attr": {"nowplaying": "true"}},
              {"name": "Airbag", "artist": {"#text": "Radiohead"}, "album": {"#text": "OK Computer"}, "date": {"uts": "1700000000"}}
            ]}}
            """).RootElement;
        var page = LastFmClient.HistoryPage(json);
        Assert.Equal((2, 7, 1300), (page.Page, page.TotalPages, page.Total));
        Assert.Equal([new LastFmPlay("Radiohead", "Airbag", "OK Computer", DateTime.UnixEpoch.AddSeconds(1_700_000_000))], page.Plays);
    }

    [Fact]
    public async Task ImportsHistoryOldestFirstWithoutCountingOwnScrobblesTwice()
    {
        using var database = TestLibrary.Seeded();
        var base_ = DateTime.UnixEpoch.AddSeconds(1_800_000_000);
        var seconds = 1_800_000_000L;
        // Played here, then scrobbled by Groovelight: the same play.
        database.RecordListen(4, base_, 180);
        string Item(string artist, string title, string album, int offset) =>
            $$$"""{"name": "{{{title}}}", "artist": {"#text": "{{{artist}}}"}, "album": {"#text": "{{{album}}}"}, "date": {"uts": "{{{seconds + offset}}}"}}""";
        var pages = new Dictionary<int, string[]>
        {
            [1] = [Item("Radiohead", "Paranoid Android", "OK Computer", 30), Item("Unknown Band", "Lost Song", "X", -500)],
            [2] = [Item("the beatles", "Something (Remastered)", "Abbey Road", -1000), Item("Beatles", "Come Together", "Abbey Road", -2000)],
        };
        var fake = new Pages(parameters =>
        {
            var number = int.Parse(parameters.GetValueOrDefault("page", "1"));
            var tracks = string.Join(",", pages.GetValueOrDefault(number) ?? []);
            return (200, $$$"""{"recenttracks": {"@attr": {"page": "{{{number}}}", "totalPages": "2", "total": "4"}, "track": [{{{tracks}}}]}}""");
        });
        var importer = new LastFmHistoryImport(database, new LastFmClient(new LastFmCredentials("K", "S"), handler: fake), "ana")
        {
            Pause = TimeSpan.Zero, Now = () => base_.AddHours(1),
        };
        var result = await importer.RunAsync(cancellation: TestContext.Current.CancellationToken);
        Assert.Equal((3, 2, 2), (result.Imported, result.Matched, result.Page));
        Assert.Equal(["1", "2"], fake.Calls.Select(call => call["page"]));
        Assert.All(fake.Calls, call => Assert.Equal(("user.getRecentTracks", "ana", false), (call["method"], call["user"], call.ContainsKey("from"))));

        var imported = database.Listens().Where(listen => listen.Source == Listen.Sources.LastFm).ToList();
        Assert.Equal(["Come Together", "Something (Remastered)", "Lost Song"], imported.Select(listen => listen.Title));
        Assert.Equal([1L, 2L, null], imported.Select(listen => listen.TrackId));
        Assert.True(imported[0].Counted && imported[0].Duration == 180);
        // Play counts stay as they were: Last.fm plays are history, not new plays.
        Assert.Equal(0, database.Read(db => db.FetchTracks("SELECT * FROM track WHERE id = 1"))[0].PlayCount);

        await importer.RunAsync(cancellation: TestContext.Current.CancellationToken);
        Assert.Equal((seconds - 500 + 1).ToString(System.Globalization.CultureInfo.InvariantCulture), fake.Calls[^1]["from"]);
    }
}
