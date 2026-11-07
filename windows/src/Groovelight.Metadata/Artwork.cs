using System.Text.Json;

namespace Groovelight.Metadata;

/// <summary>A cover image found online.</summary>
public sealed record ArtworkCandidate(ArtworkSource Source, Uri Url);

public enum ArtworkSource { CoverArtArchive, ITunes, Wikimedia }

public static class ArtworkSources
{
    public static string Title(this ArtworkSource source) => source switch
    {
        ArtworkSource.CoverArtArchive => "Cover Art Archive",
        ArtworkSource.ITunes => "Apple Music",
        _ => "Wikimedia Commons",
    };
}

/// <summary>Album covers from the Cover Art Archive (by MusicBrainz release) and the iTunes Search API (by artist and album).</summary>
public sealed class ArtworkClient(IHttpFetcher fetcher, ClientIdentity identity)
{
    /// <summary>Front cover of a release (1200 px), falling back to its release group's cover.</summary>
    public static List<ArtworkCandidate> CoverArtArchive(string releaseId, string? releaseGroupId)
    {
        var candidates = new List<ArtworkCandidate> { new(ArtworkSource.CoverArtArchive, new Uri($"https://coverartarchive.org/release/{releaseId}/front-1200")) };
        if (releaseGroupId is not null)
            candidates.Add(new ArtworkCandidate(ArtworkSource.CoverArtArchive, new Uri($"https://coverartarchive.org/release-group/{releaseGroupId}/front-1200")));
        return candidates;
    }

    /// <summary>Best matching album cover from the iTunes Search API, at up to 3000 px.</summary>
    public async Task<ArtworkCandidate?> ITunesAsync(string album, string? artist, CancellationToken cancellation = default)
    {
        var term = string.Join(" ", new[] { artist, album }.OfType<string>());
        var data = await fetcher.GetAsync(HttpFetching.Build("https://itunes.apple.com/search", ("term", term), ("entity", "album"), ("limit", "10")),
                                          identity, cancellation: cancellation);
        using var document = JsonDocument.Parse(data);
        if (!document.RootElement.TryGetProperty("results", out var results)) return null;
        var wantedAlbum = album.MatchKey();
        var wantedArtist = artist?.MatchKey();
        foreach (var result in results.EnumerateArray())
        {
            string? Text(string name) => result.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
            if (Text("collectionName")?.MatchKey() is not { } name) continue;
            var albumMatches = name == wantedAlbum || name.StartsWith(wantedAlbum, StringComparison.Ordinal);
            var artistMatches = wantedArtist is null || Text("artistName")?.MatchKey() == wantedArtist;
            if (!albumMatches || !artistMatches) continue;
            if (Text("artworkUrl100") is not { } small) return null;
            // "…/100x100bb.jpg" is a resizable template.
            return Uri.TryCreate(small.Replace("100x100bb", "3000x3000bb"), UriKind.Absolute, out var large) ? new ArtworkCandidate(ArtworkSource.ITunes, large) : null;
        }
        return null;
    }

    /// <summary>Downloads a candidate; null when the service has no image.</summary>
    public async Task<byte[]?> DownloadAsync(ArtworkCandidate candidate, CancellationToken cancellation = default)
    {
        try
        {
            return await fetcher.GetAsync(candidate.Url, identity, "image/*", cancellation);
        }
        catch (MetadataException error) when (error.Kind == MetadataErrorKind.NotFound)
        {
            return null;
        }
    }
}
