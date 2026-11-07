using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Groovelight.Core.Library;

namespace Groovelight.Metadata;

/// <summary>The app's API account on Last.fm (created at https://www.last.fm/api/account/create).</summary>
public sealed record LastFmCredentials(string ApiKey, string Secret);

public sealed class LastFmException(LastFmException.Kind kind, int code = 0, string message = "") : Exception(message)
{
    public enum Kind { Api, Http, InvalidResponse, Offline }

    public Kind Reason { get; } = kind;
    public int Code { get; } = code;

    /// <summary>Worth retrying later: the service is down or busy, or the computer is offline.</summary>
    public bool IsTemporary => Reason switch
    {
        Kind.Api => Code is 8 or 11 or 16 or 29,
        Kind.Http => Code >= 500 || Code == 429,
        Kind.Offline => true,
        _ => false,
    };

    /// <summary>The session or the API account is not valid any more: the user has to connect again.</summary>
    public bool NeedsReconnect => Reason == Kind.Api && Code is 4 or 9 or 10 or 13 or 26;

    /// <summary>The token was not authorized yet in the browser.</summary>
    public bool IsUnauthorizedToken => Reason == Kind.Api && Code == 14;

    public string Describe() => Reason switch
    {
        Kind.Api when Message.Length > 0 => Message,
        Kind.Api => $"Last.fm error {Code}",
        Kind.Http => $"Last.fm answered HTTP {Code}",
        Kind.InvalidResponse => "Unexpected answer from Last.fm",
        _ => "Last.fm is not reachable",
    };
}

/// <summary>A song as Last.fm wants it for now playing and scrobbles.</summary>
public sealed record LastFmTrack(string Artist, string Track, string? Album = null, string? AlbumArtist = null, double? Duration = null, int? TrackNumber = null);

/// <summary>
/// The Last.fm web service (the Mac's LastFMClient): desktop authentication, now playing, scrobbles and loves. Write calls
/// are signed with the API secret and the user's session key.
/// </summary>
public sealed class LastFmClient(LastFmCredentials credentials, string? sessionKey = null, HttpMessageHandler? handler = null, ClientIdentity? identity = null)
{
    public static readonly Uri Endpoint = new("https://ws.audioscrobbler.com/2.0/");
    private static readonly HttpClient Shared = new() { Timeout = TimeSpan.FromSeconds(20) };
    private readonly HttpClient http = handler is null ? Shared : new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20) };
    private readonly ClientIdentity who = identity ?? new ClientIdentity("1.0");

    public string? SessionKey { get; } = sessionKey;

    /// <summary>Step 1: a token to authorize in the browser.</summary>
    public async Task<string> GetTokenAsync() =>
        (await CallAsync("auth.getToken", [], false, false)).GetProperty("token").GetString() ?? throw new LastFmException(LastFmException.Kind.InvalidResponse);

    /// <summary>Step 2: the page where the user allows the app to use their account.</summary>
    public Uri AuthorizationUrl(string token) => new($"https://www.last.fm/api/auth/?api_key={Encode(credentials.ApiKey)}&token={Encode(token)}");

    /// <summary>Step 3, once authorized: the user name and a session key that does not expire.</summary>
    public async Task<(string Name, string Key)> GetSessionAsync(string token)
    {
        var json = await CallAsync("auth.getSession", new() { ["token"] = token }, false, false);
        if (!json.TryGetProperty("session", out var session) || session.GetProperty("name").GetString() is not { } name || session.GetProperty("key").GetString() is not { } key)
            throw new LastFmException(LastFmException.Kind.InvalidResponse);
        return (name, key);
    }

    public async Task UpdateNowPlayingAsync(LastFmTrack track)
    {
        var parameters = new Dictionary<string, string> { ["artist"] = track.Artist, ["track"] = track.Track };
        if (track.Album is { } album) parameters["album"] = album;
        if (track.AlbumArtist is { } albumArtist) parameters["albumArtist"] = albumArtist;
        if (track.Duration is { } duration) parameters["duration"] = ((int)Math.Round(duration)).ToString(CultureInfo.InvariantCulture);
        if (track.TrackNumber is { } number) parameters["trackNumber"] = number.ToString(CultureInfo.InvariantCulture);
        await CallAsync("track.updateNowPlaying", parameters, true, true);
    }

    /// <summary>Sends up to 50 scrobbles in one request; returns how many Last.fm accepted and ignored.</summary>
    public async Task<(int Accepted, int Ignored)> ScrobbleAsync(IReadOnlyList<(LastFmTrack Track, DateTime StartedAt)> scrobbles)
    {
        if (scrobbles.Count > 50) throw new ArgumentException("Last.fm takes at most 50 scrobbles per request");
        var json = await CallAsync("track.scrobble", ScrobbleParameters(scrobbles), true, true);
        if (!json.TryGetProperty("scrobbles", out var body) || !body.TryGetProperty("@attr", out var attributes)) throw new LastFmException(LastFmException.Kind.InvalidResponse);
        return (Int(attributes, "accepted"), Int(attributes, "ignored"));
    }

    public Task SetLovedAsync(bool loved, string artist, string track) =>
        CallAsync(loved ? "track.love" : "track.unlove", new() { ["artist"] = artist, ["track"] = track }, true, true);

    /// <summary>Indexed parameters of a scrobble batch ("artist[0]", "timestamp[0]"...).</summary>
    public static Dictionary<string, string> ScrobbleParameters(IReadOnlyList<(LastFmTrack Track, DateTime StartedAt)> scrobbles)
    {
        var parameters = new Dictionary<string, string>();
        for (var index = 0; index < scrobbles.Count; index++)
        {
            var (track, started) = scrobbles[index];
            parameters[$"artist[{index}]"] = track.Artist;
            parameters[$"track[{index}]"] = track.Track;
            parameters[$"timestamp[{index}]"] = ((long)(started.ToUniversalTime() - DateTime.UnixEpoch).TotalSeconds).ToString(CultureInfo.InvariantCulture);
            if (track.Album is { } album) parameters[$"album[{index}]"] = album;
            if (track.AlbumArtist is { } albumArtist) parameters[$"albumArtist[{index}]"] = albumArtist;
            if (track.Duration is { } duration) parameters[$"duration[{index}]"] = ((int)Math.Round(duration)).ToString(CultureInfo.InvariantCulture);
            if (track.TrackNumber is { } number) parameters[$"trackNumber[{index}]"] = number.ToString(CultureInfo.InvariantCulture);
        }
        return parameters;
    }

    /// <summary>The request signature: every parameter but <c>format</c> and <c>callback</c>, sorted by name, name and value concatenated, then the secret, MD5.</summary>
    public static string Signature(IReadOnlyDictionary<string, string> parameters, string secret)
    {
        var text = string.Concat(parameters.Where(pair => pair.Key is not ("format" or "callback")).OrderBy(pair => pair.Key, StringComparer.Ordinal)
            .Select(pair => pair.Key + pair.Value)) + secret;
        return Convert.ToHexStringLower(MD5.HashData(Encoding.UTF8.GetBytes(text)));
    }

    /// <summary>Form encoding with unreserved ASCII only.</summary>
    public static string FormEncoded(IReadOnlyDictionary<string, string> parameters) =>
        string.Join("&", parameters.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => Encode(pair.Key) + "=" + Encode(pair.Value)));

    private static string Encode(string text) => Uri.EscapeDataString(text);

    private async Task<JsonElement> CallAsync(string method, Dictionary<string, string> extra, bool post, bool needsSession)
    {
        var parameters = new Dictionary<string, string>(extra) { ["method"] = method, ["api_key"] = credentials.ApiKey };
        if (needsSession)
        {
            if (SessionKey is null) throw new LastFmException(LastFmException.Kind.Api, 9, "Not connected to Last.fm");
            parameters["sk"] = SessionKey;
        }
        parameters["api_sig"] = Signature(parameters, credentials.Secret);
        parameters["format"] = "json";
        var body = FormEncoded(parameters);
        using var request = post
            ? new HttpRequestMessage(HttpMethod.Post, Endpoint) { Content = new StringContent(body, Encoding.UTF8, "application/x-www-form-urlencoded") }
            : new HttpRequestMessage(HttpMethod.Get, new Uri(Endpoint + "?" + body));
        request.Headers.UserAgent.ParseAdd(who.UserAgent);
        HttpResponseMessage response;
        byte[] data;
        try
        {
            response = await http.SendAsync(request);
            data = await response.Content.ReadAsByteArrayAsync();
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException)
        {
            throw new LastFmException(LastFmException.Kind.Offline);
        }
        // Errors come as JSON (often with a 4xx status): read the body first.
        JsonElement? json = null;
        try { json = JsonDocument.Parse(data).RootElement.Clone(); }
        catch (JsonException) { }
        if (json is { ValueKind: JsonValueKind.Object } root && root.TryGetProperty("error", out var code) && code.ValueKind == JsonValueKind.Number)
            throw new LastFmException(LastFmException.Kind.Api, code.GetInt32(), root.TryGetProperty("message", out var message) ? message.GetString() ?? "" : "");
        if (!response.IsSuccessStatusCode) throw new LastFmException(LastFmException.Kind.Http, (int)response.StatusCode);
        return json ?? throw new LastFmException(LastFmException.Kind.InvalidResponse);
    }

    private static int Int(JsonElement element, string name) => element.TryGetProperty(name, out var value)
        ? value.ValueKind == JsonValueKind.Number ? value.GetInt32() : int.TryParse(value.GetString(), out var parsed) ? parsed : 0 : 0;
}

/// <summary>When a play counts as a scrobble: the song is longer than 30 seconds and was played for half its length or 4 minutes, whichever comes first.</summary>
public static class ScrobbleRules
{
    public static bool IsEligible(double duration, double listened) => duration > 30 && listened >= Math.Min(duration / 2, 240);
}

/// <summary>
/// Sends what waits in the Last.fm queue (the Mac's LastFMSender): scrobbles in batches of 50, then loves and unloves.
/// Sent items leave the queue; when Last.fm or the network is down they stay for the next try; items Last.fm keeps
/// refusing are dropped after a few attempts.
/// </summary>
public sealed class LastFmSender(LibraryDatabase database)
{
    public abstract record Outcome
    {
        public sealed record Sent(int Scrobbles, int Loves, int Ignored) : Outcome;
        public sealed record Postponed(string Reason) : Outcome;
        public sealed record NeedsReconnect(string Reason) : Outcome;
    }

    public const int MaxAttempts = 3;
    private readonly SemaphoreSlim gate = new(1, 1);

    public async Task<Outcome> SendAsync(LastFmClient client)
    {
        await gate.WaitAsync();
        try
        {
            int scrobbled = 0, loved = 0, ignored = 0;
            // Scrobbles, oldest first.
            while (database.PendingLastFm([LastFmKind.Scrobble], 50) is { Count: > 0 } batch)
            {
                try
                {
                    var (accepted, skipped) = await client.ScrobbleAsync(batch.Select(item => (Track(item), item.Timestamp)).ToList());
                    database.RemoveLastFm(batch.Select(item => item.Id!.Value).ToList());
                    scrobbled += accepted;
                    ignored += skipped;
                }
                catch (LastFmException error)
                {
                    // A refused batch is sent again one song at a time, so only the bad one is held back.
                    if (error.NeedsReconnect || error.IsTemporary || batch.Count == 1)
                    {
                        if (Handle(error, batch.Select(item => item.Id!.Value).ToList()) is { } outcome) return outcome;
                        continue;
                    }
                    foreach (var item in batch)
                    {
                        try
                        {
                            var (accepted, skipped) = await client.ScrobbleAsync([(Track(item), item.Timestamp)]);
                            database.RemoveLastFm([item.Id!.Value]);
                            scrobbled += accepted;
                            ignored += skipped;
                        }
                        catch (LastFmException failure)
                        {
                            if (Handle(failure, [item.Id!.Value]) is { } outcome) return outcome;
                        }
                    }
                }
            }
            // Loves and unloves.
            while (database.PendingLastFm([LastFmKind.Love, LastFmKind.Unlove], 20) is { Count: > 0 } batch)
            {
                foreach (var item in batch)
                {
                    try
                    {
                        await client.SetLovedAsync(item.Kind == LastFmKind.Love, item.Artist, item.Track);
                        database.RemoveLastFm([item.Id!.Value]);
                        loved++;
                    }
                    catch (LastFmException error)
                    {
                        if (Handle(error, [item.Id!.Value]) is { } outcome) return outcome;
                    }
                }
            }
            return new Outcome.Sent(scrobbled, loved, ignored);
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>What a failure means: stop for now, stop and reconnect, or count the attempt and go on.</summary>
    private Outcome? Handle(LastFmException error, IReadOnlyCollection<long> ids)
    {
        if (error.NeedsReconnect) return new Outcome.NeedsReconnect(error.Describe());
        if (error.IsTemporary) return new Outcome.Postponed(error.Describe());
        database.FailedLastFm(ids, MaxAttempts);
        return null;
    }

    public static LastFmTrack Track(LastFmQueueItem item) => new(item.Artist, item.Track, item.Album, item.AlbumArtist, item.Duration, item.TrackNumber);
}
