using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Groovelight.Metadata;

// The subset of the MusicBrainz JSON web service that Groovelight uses.

public sealed record MBArtistCredit
{
    public sealed record ArtistRef
    {
        [JsonPropertyName("id")] public string Id { get; init; } = "";
        [JsonPropertyName("name")] public string Name { get; init; } = "";
    }

    [JsonPropertyName("name")] public string Name { get; init; } = "";
    [JsonPropertyName("joinphrase")] public string? Joinphrase { get; init; }
    [JsonPropertyName("artist")] public ArtistRef Artist { get; init; } = new();
}

public static class MBArtistCredits
{
    /// <summary>"Artist A feat. Artist B", as credited.</summary>
    public static string DisplayName(this IEnumerable<MBArtistCredit> credits) => string.Concat(credits.Select(credit => credit.Name + (credit.Joinphrase ?? "")));

    /// <summary>The special "Various Artists" artist.</summary>
    public static bool IsVariousArtists(this IEnumerable<MBArtistCredit> credits) =>
        credits.Any(credit => credit.Artist.Id == "89ad4ac3-39f7-470e-963a-56509c546377");
}

public sealed record MBGenre
{
    [JsonPropertyName("name")] public string Name { get; init; } = "";
    [JsonPropertyName("count")] public int? Count { get; init; }
}

public sealed record MBReleaseGroup
{
    [JsonPropertyName("id")] public string Id { get; init; } = "";
    [JsonPropertyName("title")] public string? Title { get; init; }
    [JsonPropertyName("primary-type")] public string? PrimaryType { get; init; }
    [JsonPropertyName("secondary-types")] public List<string>? SecondaryTypes { get; init; }
    [JsonPropertyName("first-release-date")] public string? FirstReleaseDate { get; init; }
    [JsonPropertyName("genres")] public List<MBGenre>? Genres { get; init; }
    [JsonPropertyName("relations")] public List<MBRelation>? Relations { get; init; }
}

public sealed record MBRecordingRef
{
    [JsonPropertyName("id")] public string Id { get; init; } = "";
    [JsonPropertyName("title")] public string? Title { get; init; }
    [JsonPropertyName("genres")] public List<MBGenre>? Genres { get; init; }
    /// <summary>Credits of the recording (performers, production) and its works (songwriting), when requested.</summary>
    [JsonPropertyName("relations")] public List<MBRelation>? Relations { get; init; }
}

public sealed record MBTrack
{
    [JsonPropertyName("id")] public string Id { get; init; } = "";
    [JsonPropertyName("number")] public string? Number { get; init; }
    [JsonPropertyName("position")] public int? Position { get; init; }
    [JsonPropertyName("title")] public string Title { get; init; } = "";
    /// <summary>Milliseconds.</summary>
    [JsonPropertyName("length")] public int? Length { get; init; }
    [JsonPropertyName("artist-credit")] public List<MBArtistCredit>? ArtistCredit { get; init; }
    [JsonPropertyName("recording")] public MBRecordingRef? Recording { get; init; }
}

public sealed record MBMedium
{
    [JsonPropertyName("position")] public int? Position { get; init; }
    [JsonPropertyName("format")] public string? Format { get; init; }
    [JsonPropertyName("track-count")] public int? TrackCount { get; init; }
    /// <summary>Present on release lookups (tracks) and on recording search results (track).</summary>
    [JsonPropertyName("tracks")] public List<MBTrack>? Tracks { get; init; }
    [JsonPropertyName("track")] public List<MBTrack>? Track { get; init; }

    [JsonIgnore] public IReadOnlyList<MBTrack> AllTracks => Tracks ?? Track ?? [];
}

public sealed record MBRelease
{
    [JsonPropertyName("id")] public string Id { get; init; } = "";
    [JsonPropertyName("title")] public string Title { get; init; } = "";
    /// <summary>Search relevance (0 to 100), only on search results.</summary>
    [JsonPropertyName("score")] public int? Score { get; init; }
    [JsonPropertyName("status")] public string? Status { get; init; }
    [JsonPropertyName("date")] public string? Date { get; init; }
    [JsonPropertyName("country")] public string? Country { get; init; }
    [JsonPropertyName("track-count")] public int? TrackCount { get; init; }
    [JsonPropertyName("artist-credit")] public List<MBArtistCredit>? ArtistCredit { get; init; }
    [JsonPropertyName("release-group")] public MBReleaseGroup? ReleaseGroup { get; init; }
    [JsonPropertyName("media")] public List<MBMedium>? Media { get; init; }
    [JsonPropertyName("genres")] public List<MBGenre>? Genres { get; init; }
    /// <summary>Release-level credits (producer, mastering, design...), when requested.</summary>
    [JsonPropertyName("relations")] public List<MBRelation>? Relations { get; init; }

    /// <summary>Original year of the album (its release group's first release), then this edition's date.</summary>
    [JsonIgnore] public int? Year => YearFrom(ReleaseGroup?.FirstReleaseDate) ?? YearFrom(Date);
    [JsonIgnore] public string ArtistName => ArtistCredit?.DisplayName() ?? "";
    [JsonIgnore] public int TotalTracks => TrackCount ?? Media?.Sum(medium => medium.TrackCount ?? medium.AllTracks.Count) ?? 0;

    /// <summary>Most voted genre of the release, then of its release group, title cased.</summary>
    [JsonIgnore]
    public string? PrimaryGenre
    {
        get
        {
            var genres = (Genres is { Count: > 0 } ? Genres : ReleaseGroup?.Genres) ?? [];
            var best = genres.OrderByDescending(genre => genre.Count ?? 0).FirstOrDefault();
            return best is null ? null : CultureInfo.InvariantCulture.TextInfo.ToTitleCase(best.Name);
        }
    }

    /// <summary>What ReleaseMatcher.Rank counts hits by: the album (release group), or the release when that is unknown.</summary>
    [JsonIgnore] public string HitKey => ReleaseGroup?.Id ?? Id;

    public static int? YearFrom(string? date) =>
        date is { Length: >= 4 } && int.TryParse(date[..4], NumberStyles.None, CultureInfo.InvariantCulture, out var year) ? year : null;
}

public sealed record MBRecording
{
    [JsonPropertyName("id")] public string Id { get; init; } = "";
    [JsonPropertyName("title")] public string Title { get; init; } = "";
    [JsonPropertyName("score")] public int? Score { get; init; }
    [JsonPropertyName("length")] public int? Length { get; init; }
    [JsonPropertyName("artist-credit")] public List<MBArtistCredit>? ArtistCredit { get; init; }
    [JsonPropertyName("releases")] public List<MBRelease>? Releases { get; init; }
}

public sealed record MBArtist
{
    [JsonPropertyName("id")] public string Id { get; init; } = "";
    [JsonPropertyName("name")] public string Name { get; init; } = "";
    [JsonPropertyName("score")] public int? Score { get; init; }
    [JsonPropertyName("disambiguation")] public string? Disambiguation { get; init; }
    [JsonPropertyName("relations")] public List<MBRelation>? Relations { get; init; }
}

/// <summary>
/// A MusicBrainz relationship: who did what (performer with instruments, producer, engineer, songwriter...), or a link
/// to a work (the composition), a place (studio) or a URL.
/// </summary>
public sealed record MBRelation
{
    public sealed record WorkRef
    {
        [JsonPropertyName("id")] public string Id { get; init; } = "";
        [JsonPropertyName("title")] public string? Title { get; init; }
        [JsonPropertyName("relations")] public List<MBRelation>? Relations { get; init; }
    }

    public sealed record PlaceRef
    {
        [JsonPropertyName("id")] public string Id { get; init; } = "";
        [JsonPropertyName("name")] public string Name { get; init; } = "";
    }

    public sealed record UrlTarget
    {
        [JsonPropertyName("resource")] public string Resource { get; init; } = "";
    }

    [JsonPropertyName("type")] public string Type { get; init; } = "";
    [JsonPropertyName("attributes")] public List<string>? Attributes { get; init; }
    [JsonPropertyName("target-credit")] public string? TargetCredit { get; init; }
    [JsonPropertyName("artist")] public MBArtistCredit.ArtistRef? Artist { get; init; }
    [JsonPropertyName("work")] public WorkRef? Work { get; init; }
    [JsonPropertyName("place")] public PlaceRef? Place { get; init; }
    [JsonPropertyName("url")] public UrlTarget? Url { get; init; }

    /// <summary>Name as credited on this release, falling back to the artist's name.</summary>
    [JsonIgnore] public string? CreditedName => !string.IsNullOrEmpty(TargetCredit) ? TargetCredit : Artist?.Name;
}

internal sealed record MBReleaseSearch([property: JsonPropertyName("releases")] List<MBRelease> Releases);
internal sealed record MBRecordingSearch([property: JsonPropertyName("recordings")] List<MBRecording> Recordings);
internal sealed record MBArtistSearch([property: JsonPropertyName("artists")] List<MBArtist> Artists);

/// <summary>MusicBrainz web service client, rate limited to one request per second as the service requires.</summary>
public sealed class MusicBrainzClient(IHttpFetcher fetcher, ClientIdentity identity, RateLimiter? limiter = null)
{
    private readonly RateLimiter limiter = limiter ?? new RateLimiter(TimeSpan.FromMilliseconds(1100));
    private const string BaseUrl = "https://musicbrainz.org/ws/2";

    internal static T Decode<T>(byte[] data) => JsonSerializer.Deserialize<T>(data) ?? throw new MetadataException(MetadataErrorKind.InvalidResponse);

    /// <summary>Releases matching an album title and artist, best first.</summary>
    public async Task<List<MBRelease>> SearchReleasesAsync(string album, string? artist, int limit = 10, CancellationToken cancellation = default)
    {
        var query = $"release:({Escape(album)})";
        if (!string.IsNullOrEmpty(artist)) query += $" AND artist:({Escape(artist)})";
        var data = await GetAsync("release", cancellation, ("query", query), ("limit", limit.ToString(CultureInfo.InvariantCulture)));
        return Decode<MBReleaseSearch>(data).Releases;
    }

    /// <summary>Recordings matching a title and (optional) artist, each listing the releases it appears on.</summary>
    public async Task<List<MBRecording>> SearchRecordingsAsync(string title, string? artist, bool officialAlbumsOnly = false, int limit = 25,
                                                              CancellationToken cancellation = default)
    {
        var query = $"recording:({Escape(title)})";
        if (!string.IsNullOrEmpty(artist)) query += $" AND artist:({Escape(artist)})";
        if (officialAlbumsOnly) query += " AND status:official AND primarytype:album";
        var data = await GetAsync("recording", cancellation, ("query", query), ("limit", limit.ToString(CultureInfo.InvariantCulture)));
        return Decode<MBRecordingSearch>(data).Recordings;
    }

    /// <summary>Full release with its tracklist, artist credits, release group and genres.</summary>
    public async Task<MBRelease> ReleaseAsync(string id, CancellationToken cancellation = default) =>
        Decode<MBRelease>(await GetAsync($"release/{id}", cancellation, ("inc", "recordings artist-credits release-groups genres")));

    /// <summary>Release with its tracklist and every credit (release, recording and work relationships).</summary>
    public async Task<MBRelease> ReleaseWithCreditsAsync(string id, CancellationToken cancellation = default) =>
        Decode<MBRelease>(await GetAsync($"release/{id}", cancellation,
            ("inc", "recordings artist-credits artist-rels recording-level-rels work-rels work-level-rels place-rels release-groups")));

    /// <summary>Artists matching a name, best first.</summary>
    public async Task<List<MBArtist>> SearchArtistsAsync(string name, int limit = 5, CancellationToken cancellation = default) =>
        Decode<MBArtistSearch>(await GetAsync("artist", cancellation, ("query", $"artist:({Escape(name)})"), ("limit", limit.ToString(CultureInfo.InvariantCulture)))).Artists;

    /// <summary>Wikidata item id of an artist, from its URL relationships.</summary>
    public async Task<string?> WikidataIdAsync(string artistId, CancellationToken cancellation = default) =>
        WikidataId(Decode<MBArtist>(await GetAsync($"artist/{artistId}", cancellation, ("inc", "url-rels"))).Relations);

    /// <summary>Wikidata item id ("Q202996") of a release group, from its URL relationships.</summary>
    public async Task<string?> WikidataIdForReleaseGroupAsync(string releaseGroupId, CancellationToken cancellation = default) =>
        WikidataId(Decode<MBReleaseGroup>(await GetAsync($"release-group/{releaseGroupId}", cancellation, ("inc", "url-rels"))).Relations);

    internal static string? WikidataId(IEnumerable<MBRelation>? relations)
    {
        var link = relations?.FirstOrDefault(relation => relation.Type == "wikidata")?.Url?.Resource;
        if (link is null || !Uri.TryCreate(link, UriKind.Absolute, out var uri)) return null;
        var last = uri.Segments.LastOrDefault()?.Trim('/');
        return last is not null && last.StartsWith('Q') ? last : null;
    }

    private Task<byte[]> GetAsync(string path, CancellationToken cancellation, params (string Key, string? Value)[] items) =>
        fetcher.GetAsync(HttpFetching.Build($"{BaseUrl}/{path}", [.. items, ("fmt", "json")]), identity, limiter, cancellation: cancellation);

    /// <summary>Escapes Lucene special characters in a search term.</summary>
    internal static string Escape(string term)
    {
        const string special = "+-&|!(){}[]^\"~*?:\\/";
        var result = new System.Text.StringBuilder();
        foreach (var character in term)
        {
            if (special.Contains(character)) result.Append('\\');
            result.Append(character);
        }
        return result.ToString();
    }
}
