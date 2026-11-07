using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Groovelight.Metadata;

/// <summary>Lyrics with optional line timings, parsed from LRC ("[01:23.45]line") or plain text.</summary>
public sealed record SyncedLyrics
{
    public sealed record Line(double? Time, string Text);

    public IReadOnlyList<Line> Lines { get; }

    public bool IsSynced => Lines.Any(line => line.Time is not null);

    public SyncedLyrics(IReadOnlyList<Line> lines) => Lines = lines;

    /// <summary>
    /// Parses LRC, including several time tags on one line and the <c>[offset:+/-ms]</c> tag. Text without any time tags
    /// is returned as unsynced lines.
    /// </summary>
    public static SyncedLyrics Parse(string text)
    {
        var timed = new List<Line>();
        var plain = new List<Line>();
        var offset = 0.0;
        foreach (var rawLine in text.Replace("\r\n", "\n").Split('\n'))
        {
            var rest = rawLine.Trim(' ', '\t');
            var times = new List<double>();
            while (rest.StartsWith('[') && rest.IndexOf(']') is var close and > 0)
            {
                var tag = rest[1..close];
                if (ParseTime(tag) is { } time) times.Add(time);
                else if (tag.StartsWith("offset:", StringComparison.OrdinalIgnoreCase)
                         && double.TryParse(tag[7..].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var ms))
                {
                    // Positive offset means the lyrics come sooner.
                    offset = ms / 1000;
                }
                else if (times.Count == 0 && tag.Contains(':'))
                {
                    // Metadata tag such as [ar:Artist]; the whole line is skipped.
                    rest = "";
                    break;
                }
                else break;
                rest = rest[(close + 1)..];
            }
            var lineText = rest.Trim(' ', '\t');
            if (times.Count == 0) plain.Add(new Line(null, lineText));
            else timed.AddRange(times.Select(time => new Line(time, lineText)));
        }
        if (timed.Count == 0)
        {
            // Trim leading and trailing blank lines of plain lyrics.
            while (plain.Count > 0 && plain[0].Text.Length == 0) plain.RemoveAt(0);
            while (plain.Count > 0 && plain[^1].Text.Length == 0) plain.RemoveAt(plain.Count - 1);
            return new SyncedLyrics(plain);
        }
        return new SyncedLyrics(timed.Select(line => line with { Time = Math.Max(0, (line.Time ?? 0) - offset) })
                                     .Select((line, order) => (line, order)).OrderBy(item => item.line.Time).ThenBy(item => item.order)
                                     .Select(item => item.line).ToList());
    }

    /// <summary>Index of the line being sung at <paramref name="time"/>, or null before the first line.</summary>
    public int? LineIndex(double time)
    {
        if (!IsSynced) return null;
        int low = 0, high = Lines.Count - 1;
        int? found = null;
        while (low <= high)
        {
            var mid = (low + high) / 2;
            if ((Lines[mid].Time ?? 0) <= time)
            {
                found = mid;
                low = mid + 1;
            }
            else high = mid - 1;
        }
        return found;
    }

    public string PlainText => string.Join("\n", Lines.Select(line => line.Text));

    /// <summary>"mm:ss.xx", "mm:ss:xx" or "mm:ss".</summary>
    internal static double? ParseTime(string tag)
    {
        var parts = tag.Split(':');
        if (parts.Length < 2 || !int.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var minutes)) return null;
        var secondsPart = parts.Length == 3 ? $"{parts[1]}.{parts[2]}" : parts[1];
        if (!double.TryParse(secondsPart, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var seconds) || seconds is < 0 or >= 60) return null;
        return minutes * 60 + seconds;
    }
}

/// <summary>Lyrics found online: synced LRC when available, otherwise plain text.</summary>
public sealed record FetchedLyrics(string? Synced, string? Plain, bool IsInstrumental)
{
    /// <summary>Text to store: LRC when synced lyrics exist.</summary>
    public string? BestText => Synced ?? Plain;
}

/// <summary>LRCLIB (https://lrclib.net): free synced lyrics, no API key.</summary>
public sealed class LrcLibClient(IHttpFetcher fetcher, ClientIdentity identity, RateLimiter? limiter = null)
{
    private readonly RateLimiter limiter = limiter ?? new RateLimiter(TimeSpan.FromMilliseconds(400));

    internal sealed record Record
    {
        [JsonPropertyName("trackName")] public string? TrackName { get; init; }
        [JsonPropertyName("artistName")] public string? ArtistName { get; init; }
        [JsonPropertyName("duration")] public double? Duration { get; init; }
        [JsonPropertyName("instrumental")] public bool? Instrumental { get; init; }
        [JsonPropertyName("plainLyrics")] public string? PlainLyrics { get; init; }
        [JsonPropertyName("syncedLyrics")] public string? SyncedLyrics { get; init; }

        public FetchedLyrics Lyrics => new(string.IsNullOrEmpty(SyncedLyrics) ? null : SyncedLyrics,
                                           string.IsNullOrEmpty(PlainLyrics) ? null : PlainLyrics, Instrumental ?? false);
    }

    /// <summary>
    /// Exact lookup by signature (LRCLIB matches the duration within 2 seconds), then a search that keeps only results
    /// with the same artist and a close duration. Null when nothing is found.
    /// </summary>
    public async Task<FetchedLyrics?> LyricsAsync(string title, string artist, string? album, double duration, CancellationToken cancellation = default)
    {
        try
        {
            var data = await fetcher.GetAsync(HttpFetching.Build("https://lrclib.net/api/get",
                ("track_name", title), ("artist_name", artist), ("album_name", album ?? ""),
                ("duration", ((int)Math.Round(duration)).ToString(CultureInfo.InvariantCulture))), identity, limiter, cancellation: cancellation);
            return JsonSerializer.Deserialize<Record>(data)?.Lyrics;
        }
        catch (MetadataException error) when (error.Kind == MetadataErrorKind.NotFound)
        {
            // Fall through to search.
        }
        var found = await fetcher.GetAsync(HttpFetching.Build("https://lrclib.net/api/search", ("track_name", title), ("artist_name", artist)),
                                           identity, limiter, cancellation: cancellation);
        var records = JsonSerializer.Deserialize<List<Record>>(found) ?? [];
        var artistKey = artist.MatchKey();
        var candidates = records.Where(record => record.ArtistName?.MatchKey() == artistKey && Math.Abs((record.Duration ?? 0) - duration) <= 3).ToList();
        // Prefer synced lyrics, then plain, then an instrumental marker.
        var match = candidates.FirstOrDefault(record => !string.IsNullOrEmpty(record.SyncedLyrics))
                    ?? candidates.FirstOrDefault(record => !string.IsNullOrEmpty(record.PlainLyrics))
                    ?? candidates.FirstOrDefault(record => record.Instrumental == true);
        return match?.Lyrics;
    }
}
