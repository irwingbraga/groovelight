using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Groovelight.Core;
using Groovelight.Core.Library;

namespace Groovelight.Metadata;

// The credits model, stored as JSON in the library in the Mac's format (so a library or a backup moves between them).

/// <summary>One person (or group, or studio) and what they did, e.g. "Colin Greenwood: bass guitar, percussion".</summary>
public sealed record Credit
{
    public string Name { get; init; } = "";
    /// <summary>MusicBrainz artist id, when the credit is an artist.</summary>
    public string? ArtistId { get; init; }
    public List<string> Roles { get; init; } = [];
}

[JsonConverter(typeof(JsonStringEnumConverter<CreditKind>))]
public enum CreditKind
{
    [JsonStringEnumMemberName("Musicians")] Musicians,
    [JsonStringEnumMemberName("Songwriting")] Songwriting,
    [JsonStringEnumMemberName("Production")] Production,
    [JsonStringEnumMemberName("Recorded At")] RecordedAt,
    [JsonStringEnumMemberName("Artwork & Design")] Design,
}

public static class CreditKinds
{
    public static string Title(this CreditKind kind) => kind switch
    {
        CreditKind.Musicians => "Musicians",
        CreditKind.Songwriting => "Songwriting",
        CreditKind.Production => "Production",
        CreditKind.RecordedAt => "Recorded At",
        _ => "Artwork & Design",
    };
}

public sealed record CreditSection
{
    public CreditKind Kind { get; init; }
    public List<Credit> Credits { get; init; } = [];
}

/// <summary>An album's (or artist's) background from Wikipedia.</summary>
public sealed record AlbumAbout
{
    public string Title { get; init; } = "";
    public string Summary { get; init; } = "";
    public string Url { get; init; } = "";
    /// <summary>Wikipedia language code ("en", "pt").</summary>
    public string Language { get; init; } = "en";
    /// <summary>The article's main image (Wikimedia Commons), at a size suited to the app.</summary>
    public string? ImageUrl { get; init; }
}

/// <summary>Everything fetched for an album page: credits for the whole album and each song, and the Wikipedia summary.</summary>
public sealed record AlbumInfo
{
    public string? ReleaseId { get; init; }
    public string? ReleaseTitle { get; init; }
    public List<CreditSection> Sections { get; init; } = [];
    /// <summary>Credits per MusicBrainz recording id.</summary>
    public Dictionary<string, List<CreditSection>> TrackSections { get; init; } = [];
    /// <summary>Local track id (as a string, for JSON) to MusicBrainz recording id.</summary>
    public Dictionary<string, string> LocalRecordings { get; init; } = [];
    /// <summary>Credits of the release itself (mastering, design...), which apply to every song.</summary>
    public List<CreditSection>? ReleaseSections { get; init; }
    public AlbumAbout? About { get; init; }
    public DateTime FetchedAt { get; init; } = DateTime.UtcNow;

    public static AlbumInfo NotFound(DateTime? date = null) => new() { ReleaseSections = [], FetchedAt = date ?? DateTime.UtcNow };

    [JsonIgnore] public bool IsEmpty => Sections.Count == 0 && About is null;

    /// <summary>Main producers (not assistants or executives), for the header's "Produced by" line.</summary>
    [JsonIgnore]
    public List<string> Producers => (Sections.FirstOrDefault(section => section.Kind == CreditKind.Production)?.Credits ?? [])
        .Where(credit => credit.Roles.Contains("producer") || credit.Roles.Contains("co-producer")).Take(3).Select(credit => credit.Name).ToList();

    /// <summary>Index entries: everyone credited on the album, and on each local song.</summary>
    public List<CreditIndexEntry> CreditEntries(string albumKey)
    {
        var releaseWide = (ReleaseSections ?? []).SelectMany(section => section.Credits).Select(credit => credit.Name).ToHashSet();
        var entries = Sections.SelectMany(section => section.Credits.Select(credit =>
            new CreditIndexEntry(new CreditPerson(credit.Name, credit.ArtistId), albumKey, null, credit.Roles, releaseWide.Contains(credit.Name)))).ToList();
        foreach (var (local, recording) in LocalRecordings)
        {
            if (!long.TryParse(local, out var trackId)) continue;
            foreach (var section in TrackSections.GetValueOrDefault(recording) ?? [])
            {
                entries.AddRange(section.Credits.Select(credit =>
                    new CreditIndexEntry(new CreditPerson(credit.Name, credit.ArtistId), albumKey, trackId, credit.Roles)));
            }
        }
        return entries;
    }

    /// <summary>Credits of one local song.</summary>
    public List<CreditSection> SectionsForTrack(Track track)
    {
        var recording = track.MusicBrainzRecordingId ?? (track.Id is { } id ? LocalRecordings.GetValueOrDefault(id.ToString(System.Globalization.CultureInfo.InvariantCulture)) : null);
        return recording is not null && TrackSections.TryGetValue(recording, out var sections) ? sections : [];
    }

    public byte[] Encode() => SwiftJson.Encode(this);

    public static AlbumInfo? Decode(byte[]? data) => SwiftJson.Decode<AlbumInfo>(data);
}

/// <summary>What an artist page shows from the web: the Wikipedia summary and a photo.</summary>
public sealed record ArtistInfo
{
    public string? ArtistId { get; init; }
    public AlbumAbout? About { get; init; }
    public DateTime FetchedAt { get; init; } = DateTime.UtcNow;
    /// <summary>The artist's photo, stored in the artwork cache.</summary>
    public string? ImageHash { get; init; }
    /// <summary>Whether a photo was looked for (null in info cached before photos).</summary>
    public bool? ImageChecked { get; init; }
    /// <summary>
    /// Whether Wikipedia answered (with the article, or that there is none). Null when it was not reached (before this
    /// was kept, an error such as "too many requests" was saved as "no article"): looked up again.
    /// </summary>
    public bool? AboutChecked { get; init; }

    [JsonIgnore] public bool IsEmpty => About is null;

    /// <summary>The artist was found but Wikipedia never answered: worth asking again now.</summary>
    [JsonIgnore] public bool NeedsAbout => ArtistId is not null && About is null && AboutChecked != true;

    public byte[] Encode() => SwiftJson.Encode(this);

    public static ArtistInfo? Decode(byte[]? data) => SwiftJson.Decode<ArtistInfo>(data);
}

public static class CreditsBuilder
{
    /// <summary>Attributes that qualify a role rather than name an instrument.</summary>
    private static readonly HashSet<string> Qualifiers = ["additional", "guest", "solo", "assistant", "co", "executive", "associate", "minor"];

    /// <summary>Section and display role for one relationship, null for relationships that are not credits.</summary>
    internal static (CreditKind Kind, List<string> Roles)? Classify(MBRelation relation, bool isWork)
    {
        var attributes = relation.Attributes ?? [];
        var qualifier = attributes.Where(Qualifiers.Contains).ToList();
        var details = attributes.Where(attribute => !Qualifiers.Contains(attribute)).ToList();
        List<string> Role(string name)
        {
            var prefix = qualifier.Contains("assistant") ? "assistant " : qualifier.Contains("co") ? "co-" :
                qualifier.Contains("executive") ? "executive " : qualifier.Contains("additional") ? "additional " : "";
            return [prefix + name];
        }
        if (isWork)
        {
            return relation.Type switch
            {
                "writer" => (CreditKind.Songwriting, ["songwriter"]),
                "composer" => (CreditKind.Songwriting, ["composer"]),
                "lyricist" => (CreditKind.Songwriting, ["lyrics"]),
                "librettist" => (CreditKind.Songwriting, ["libretto"]),
                "arranger" or "instrument arranger" or "vocal arranger" => (CreditKind.Songwriting, ["arrangement"]),
                "translator" => (CreditKind.Songwriting, ["translation"]),
                _ => null,
            };
        }
        return relation.Type switch
        {
            "instrument" => (CreditKind.Musicians, details.Count == 0 ? ["instruments"] : details),
            "vocal" => (CreditKind.Musicians, details.Count == 0 ? ["vocals"] : details.Select(detail => detail.EndsWith("vocals", StringComparison.Ordinal) ? detail : $"{detail} vocals").ToList()),
            "performer" => (CreditKind.Musicians, ["performer"]),
            "performing orchestra" => (CreditKind.Musicians, ["orchestra"]),
            "conductor" => (CreditKind.Musicians, ["conductor"]),
            "chorus master" => (CreditKind.Musicians, ["chorus master"]),
            "producer" => (CreditKind.Production, Role("producer")),
            "engineer" or "audio" => (CreditKind.Production, Role("engineer")),
            "sound" => (CreditKind.Production, Role("sound engineer")),
            "recording" => (CreditKind.Production, Role("recording engineer")),
            "mix" => (CreditKind.Production, Role("mixing")),
            "mastering" => (CreditKind.Production, Role("mastering")),
            "editor" => (CreditKind.Production, Role("editing")),
            "programming" => (CreditKind.Production, Role("programming")),
            "instrument arranger" or "vocal arranger" or "arranger" or "orchestrator" => (CreditKind.Production, ["arrangement"]),
            "design/illustration" or "design" or "illustration" or "graphic design" or "art direction" or "photography" or "artwork" =>
                (CreditKind.Design, [relation.Type == "design/illustration" ? "design and illustration" : relation.Type]),
            "recorded at" or "recording location" => (CreditKind.RecordedAt, ["recording"]),
            "mixed at" => (CreditKind.RecordedAt, ["mixing"]),
            "mastered at" => (CreditKind.RecordedAt, ["mastering"]),
            _ => null,
        };
    }

    /// <summary>Groups relationships into sections, merging the roles of each person (in order of first appearance).</summary>
    internal static List<CreditSection> Sections(IEnumerable<(MBRelation Relation, bool IsWork)> relations)
    {
        var grouped = new Dictionary<CreditKind, List<Credit>>();
        foreach (var (relation, isWork) in relations)
        {
            if (Classify(relation, isWork) is not var (kind, roles)) continue;
            string name;
            string? id;
            if (kind == CreditKind.RecordedAt && relation.Place is { } place)
            {
                name = place.Name;
                id = null;
            }
            else if (relation.CreditedName is { } credited)
            {
                name = credited;
                id = relation.Artist?.Id;
            }
            else continue;
            var credits = grouped.TryGetValue(kind, out var existing) ? existing : grouped[kind] = [];
            var index = credits.FindIndex(credit => credit.Name == name);
            if (index >= 0)
            {
                foreach (var role in roles.Where(role => !credits[index].Roles.Contains(role))) credits[index].Roles.Add(role);
            }
            else credits.Add(new Credit { Name = name, ArtistId = id, Roles = [.. roles] });
        }
        return Enum.GetValues<CreditKind>().Where(grouped.ContainsKey).Select(kind => new CreditSection { Kind = kind, Credits = grouped[kind] }).ToList();
    }

    /// <summary>The relationships of one recording: its own, plus the songwriting credits of the works it performs.</summary>
    internal static List<(MBRelation, bool)> RelationsOfRecording(MBRecordingRef recording)
    {
        var result = new List<(MBRelation, bool)>();
        foreach (var relation in recording.Relations ?? [])
        {
            if (relation.Type == "performance" && relation.Work is { } work) result.AddRange((work.Relations ?? []).Select(item => (item, true)));
            else result.Add((relation, false));
        }
        return result;
    }

    /// <summary>Album credits (release relationships plus every track's) and per-track credits, mapped to local songs.</summary>
    public static AlbumInfo AlbumInfo(MBRelease release, ReleaseMatch? match, AlbumAbout? about, DateTime? date = null)
    {
        var recordings = (release.Media ?? []).SelectMany(medium => medium.AllTracks).Select(track => track.Recording).OfType<MBRecordingRef>();
        var all = (release.Relations ?? []).Select(relation => (relation, false)).ToList();
        var trackSections = new Dictionary<string, List<CreditSection>>();
        foreach (var recording in recordings)
        {
            var relations = RelationsOfRecording(recording);
            all.AddRange(relations);
            var sections = Sections(relations);
            if (sections.Count > 0) trackSections[recording.Id] = sections;
        }
        var localRecordings = new Dictionary<string, string>();
        foreach (var item in match?.Matches ?? [])
        {
            if (item.Track.Recording?.Id is { } recording) localRecordings[item.LocalId.ToString(System.Globalization.CultureInfo.InvariantCulture)] = recording;
        }
        return new AlbumInfo
        {
            ReleaseId = release.Id, ReleaseTitle = release.Title, Sections = Sections(all), TrackSections = trackSections,
            LocalRecordings = localRecordings, ReleaseSections = Sections((release.Relations ?? []).Select(relation => (relation, false))),
            About = about, FetchedAt = date ?? DateTime.UtcNow,
        };
    }
}

/// <summary>Album and artist summaries from Wikipedia, found through their Wikidata items.</summary>
public sealed partial class WikipediaClient(IHttpFetcher fetcher, ClientIdentity identity, RateLimiter? limiter = null)
{
    /// <summary>
    /// One pace for the whole app: Wikimedia answers bursts (an artist page, then the next) with 429, which the limited
    /// requests wait out and try again.
    /// </summary>
    public static readonly RateLimiter SharedLimiter = new(TimeSpan.FromMilliseconds(250));

    private readonly RateLimiter limiter = limiter ?? SharedLimiter;

    /// <summary>Summary of the article linked to a Wikidata item, in the first of <paramref name="languages"/> that has one.</summary>
    public async Task<AlbumAbout?> SummaryAsync(string wikidataId, IReadOnlyList<string> languages, CancellationToken cancellation = default)
    {
        var sites = string.Join("|", languages.Select(language => $"{language}wiki"));
        var data = await fetcher.GetAsync(HttpFetching.Build("https://www.wikidata.org/w/api.php",
            ("action", "wbgetentities"), ("ids", wikidataId), ("props", "sitelinks"), ("sitefilter", sites), ("format", "json")), identity, limiter, cancellation: cancellation);
        using var document = JsonDocument.Parse(data);
        if (!document.RootElement.TryGetProperty("entities", out var entities) || !entities.TryGetProperty(wikidataId, out var entity)
            || !entity.TryGetProperty("sitelinks", out var sitelinks)) return null;
        foreach (var language in languages)
        {
            if (!sitelinks.TryGetProperty($"{language}wiki", out var link) || !link.TryGetProperty("title", out var title)) continue;
            if (await SummaryAsync(title.GetString() ?? "", language, cancellation) is { } about) return about;
        }
        return null;
    }

    /// <summary>
    /// The image at about 960 px: the original when small enough, otherwise a Commons thumbnail of that width (thumbnail
    /// URLs end in "/330px-File.jpg"; Commons only renders standard widths).
    /// </summary>
    internal static string? ImageUrl(string? thumbnail, string? original, int? originalWidth, int width = 960)
    {
        if (original is not null && originalWidth is { } size && size <= width) return original;
        if (thumbnail is not null && ThumbnailWidth().Match(thumbnail) is { Success: true } match)
            return thumbnail[..match.Index] + $"/{width}px-" + thumbnail[(match.Index + match.Length)..];
        return original ?? thumbnail;
    }

    [GeneratedRegex(@"/\d+px-")]
    private static partial Regex ThumbnailWidth();

    /// <summary>Wikipedia's summaries drop some bracketed text and leave "Thom Yorke ;" or "()" behind.</summary>
    internal static string Tidy(string text)
    {
        text = Regex.Replace(text, @"\s*\(\s*[;,]?\s*\)", "");
        text = Regex.Replace(text, @"\s+([;,.:!?])", "$1");
        return Regex.Replace(text, @"[ \t]{2,}", " ");
    }

    /// <summary>Wikipedia's REST summary (first paragraphs) of an article.</summary>
    public async Task<AlbumAbout?> SummaryAsync(string title, string language, CancellationToken cancellation = default)
    {
        var path = Uri.EscapeDataString(title.Replace(' ', '_'));
        var url = new Uri($"https://{language}.wikipedia.org/api/rest_v1/page/summary/{path}");
        try
        {
            using var document = JsonDocument.Parse(await fetcher.GetAsync(url, identity, limiter, cancellation: cancellation));
            var root = document.RootElement;
            string? Text(JsonElement element, string name) => element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
            if (Text(root, "type") == "disambiguation" || Text(root, "extract") is not { Length: > 0 } extract) return null;
            if (!root.TryGetProperty("content_urls", out var urls) || !urls.TryGetProperty("desktop", out var desktop) || Text(desktop, "page") is not { } page) return null;
            string? thumbnail = root.TryGetProperty("thumbnail", out var thumb) ? Text(thumb, "source") : null;
            string? original = null;
            int? originalWidth = null;
            if (root.TryGetProperty("originalimage", out var originalImage))
            {
                original = Text(originalImage, "source");
                if (originalImage.TryGetProperty("width", out var width) && width.TryGetInt32(out var value)) originalWidth = value;
            }
            return new AlbumAbout
            {
                Title = Text(root, "title") ?? title, Summary = Tidy(extract), Url = page, Language = language,
                ImageUrl = ImageUrl(thumbnail, original, originalWidth),
            };
        }
        catch (MetadataException error) when (error.Kind == MetadataErrorKind.NotFound)
        {
            return null;
        }
    }
}
