using Groovelight.Core.Library;

namespace Groovelight.Metadata;

/// <summary>Finds album metadata, covers and lyrics online for local tracks (the Mac's MetadataService).</summary>
public sealed class MetadataService
{
    public MusicBrainzClient MusicBrainz { get; }
    public ArtworkClient Artwork { get; }
    public LrcLibClient Lyrics { get; }
    public WikipediaClient Wikipedia { get; }

    public MetadataService(ClientIdentity identity, IHttpFetcher? fetcher = null)
    {
        fetcher ??= new HttpFetcher();
        MusicBrainz = new MusicBrainzClient(fetcher, identity);
        Artwork = new ArtworkClient(fetcher, identity);
        Lyrics = new LrcLibClient(fetcher, identity);
        Wikipedia = new WikipediaClient(fetcher, identity);
    }

    /// <summary>With the app's shared clients (their rate limiters pace every request of the app).</summary>
    public MetadataService(ClientIdentity identity, IHttpFetcher fetcher, MusicBrainzClient musicBrainz, LrcLibClient lyrics)
    {
        MusicBrainz = musicBrainz;
        Artwork = new ArtworkClient(fetcher, identity);
        Lyrics = lyrics;
        Wikipedia = new WikipediaClient(fetcher, identity);
    }

    /// <summary>
    /// Credits and the Wikipedia summary for an album's songs. Uses the songs' MusicBrainz release id when they have one;
    /// otherwise searches and only accepts a confident match. Returns <see cref="AlbumInfo.NotFound"/> when nothing fits.
    /// </summary>
    public async Task<AlbumInfo> AlbumInfoAsync(IReadOnlyList<Track> tracks, IReadOnlyList<string> languages, CancellationToken cancellation = default)
    {
        var local = tracks.Select(LocalTrackInfo.From).OfType<LocalTrackInfo>().ToList();
        MBRelease? release = null;
        ReleaseMatch? match = null;
        if (CommonReleaseId(tracks) is { } id)
        {
            release = await MusicBrainz.ReleaseWithCreditsAsync(id, cancellation);
            match = ReleaseMatcher.Match(local, release);
        }
        else
        {
            foreach (var candidate in (await CandidatesAsync(tracks, cancellation: cancellation)).Take(2))
            {
                var full = await MusicBrainz.ReleaseWithCreditsAsync(candidate.Id, cancellation);
                var attempt = ReleaseMatcher.Match(local, full);
                if (IsConfident(attempt, local.Count))
                {
                    release = full;
                    match = attempt;
                    break;
                }
            }
        }
        if (release is null) return AlbumInfo.NotFound();
        AlbumAbout? about = null;
        if (release.ReleaseGroup?.Id is { } group)
        {
            try
            {
                if (await MusicBrainz.WikidataIdForReleaseGroupAsync(group, cancellation) is { } wikidata)
                    about = await Wikipedia.SummaryAsync(wikidata, languages, cancellation);
            }
            catch (Exception error) when (error is MetadataException or HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
            {
            }
        }
        return CreditsBuilder.AlbumInfo(release, match, about);
    }

    /// <summary>
    /// The Wikipedia summary of an artist. The artist is found through one of their albums first (names are ambiguous),
    /// with a name search as the fallback that only accepts an exact, top scoring name.
    /// </summary>
    public async Task<ArtistInfo> ArtistInfoAsync(string name, IReadOnlyList<string> albumTitles, IReadOnlyList<string> languages,
                                                  CancellationToken cancellation = default)
    {
        var key = name.MatchKey();
        string? artistId = null;
        foreach (var title in albumTitles.Take(2))
        {
            if (artistId is not null) break;
            foreach (var release in await MusicBrainz.SearchReleasesAsync(title, name, 5, cancellation))
            {
                if ((release.Score ?? 0) < 90) continue;
                if (release.ArtistCredit?.FirstOrDefault(credit => credit.Name.MatchKey() == key || credit.Artist.Name.MatchKey() == key) is { } credit)
                {
                    artistId = credit.Artist.Id;
                    break;
                }
            }
        }
        artistId ??= (await MusicBrainz.SearchArtistsAsync(name, cancellation: cancellation))
            .FirstOrDefault(artist => (artist.Score ?? 0) >= 100 && artist.Name.MatchKey() == key)?.Id;
        if (artistId is null) return new ArtistInfo { FetchedAt = DateTime.UtcNow };
        AlbumAbout? about = null;
        if (await MusicBrainz.WikidataIdAsync(artistId, cancellation) is { } wikidata)
        {
            // No article, or one Wikipedia cannot summarize, is an answer; "too many requests" or no connection is not:
            // it throws, nothing is kept, and the next look tries again.
            try { about = await Wikipedia.SummaryAsync(wikidata, languages, cancellation); }
            catch (Exception error) when (error is MetadataException { Kind: MetadataErrorKind.NotFound } or System.Text.Json.JsonException) { }
        }
        return new ArtistInfo { ArtistId = artistId, About = about, FetchedAt = DateTime.UtcNow, AboutChecked = true };
    }

    /// <summary>The release id shared by most of the songs, if any.</summary>
    internal static string? CommonReleaseId(IReadOnlyList<Track> tracks)
    {
        var ids = tracks.Select(track => track.MusicBrainzReleaseId).OfType<string>().ToList();
        if (ids.Count * 2 <= tracks.Count) return null;
        return ids.GroupBy(id => id).MaxBy(group => group.Count())?.Key;
    }

    /// <summary>At least 80% of the local songs paired with good scores.</summary>
    public static bool IsConfident(ReleaseMatch match, int localCount) =>
        localCount > 0 && match.Matches.Count(item => item.Score >= 0.7) >= localCount * 0.8;

    /// <summary>
    /// Candidate releases for a group of tracks (usually an album), best first. Tagged albums are searched by album and
    /// artist; files without an album are identified one by one, and the releases those recordings appear on become
    /// candidates. <paramref name="album"/> and <paramref name="artist"/> replace the tags (a typed search); an empty
    /// string searches without that field, and null uses the tags.
    /// </summary>
    public async Task<List<MBRelease>> CandidatesAsync(IReadOnlyList<Track> tracks, string? album = null, string? artist = null,
                                                      CancellationToken cancellation = default)
    {
        var group = new SongGroup(tracks, sampleSize: 3);
        var albumTitle = album is null ? group.Album : album.Length == 0 ? null : album;
        var albumArtist = artist is null ? group.Artist : artist.Length == 0 ? null : artist;
        var releases = new List<MBRelease>();
        if (albumTitle is not null)
        {
            releases = await MusicBrainz.SearchReleasesAsync(albumTitle, albumArtist, cancellation: cancellation);
            if (releases.Count > 0 && !group.IsMixed) return ReleaseMatcher.Rank(releases, tracks.Count);
        }
        var hits = new Dictionary<string, int>();
        foreach (var info in group.Sample)
        {
            // A typed artist (or a cleared one) wins over the song's own tag.
            var searchArtist = artist is not null ? albumArtist : info.Artist ?? albumArtist;
            var recordings = await MusicBrainz.SearchRecordingsAsync(info.Title, searchArtist, officialAlbumsOnly: true, cancellation: cancellation);
            if (recordings.Count == 0) recordings = await MusicBrainz.SearchRecordingsAsync(info.Title, searchArtist, cancellation: cancellation);
            var fitting = recordings.Where(recording =>
            {
                var titleFits = recording.Title.MatchKey().Similarity(info.Title.MatchKey()) >= 0.8;
                var durationFits = recording.Length is not { } length || Math.Abs(length / 1000.0 - info.Duration) <= 10;
                return titleFits && (info.Duration <= 0 || durationFits);
            });
            var found = new HashSet<string>();
            foreach (var recording in fitting)
            {
                foreach (var release in recording.Releases ?? [])
                {
                    // Carry the recording's score over to its releases for ranking.
                    var scored = release with { Score = recording.Score, ArtistCredit = release.ArtistCredit ?? recording.ArtistCredit };
                    releases.Add(scored);
                    found.Add(scored.HitKey);
                }
            }
            foreach (var id in found) hits[id] = hits.GetValueOrDefault(id) + 1;
        }
        return ReleaseMatcher.Rank(releases, tracks.Count, hits, group.Sample.Count);
    }

    /// <summary>Fetches the full release and pairs it with the tracks.</summary>
    public async Task<ReleaseMatch> MatchAsync(IReadOnlyList<Track> tracks, string releaseId, CancellationToken cancellation = default)
    {
        var release = await MusicBrainz.ReleaseAsync(releaseId, cancellation);
        return ReleaseMatcher.Match(tracks.Select(LocalTrackInfo.From).OfType<LocalTrackInfo>().ToList(), release);
    }

    /// <summary>Downloads the first available cover: Cover Art Archive for the release, then the iTunes Search API.</summary>
    public async Task<(ArtworkCandidate Candidate, byte[] Data)?> CoverAsync(MBRelease? release, string album, string? artist, CancellationToken cancellation = default)
    {
        var candidates = release is null ? [] : ArtworkClient.CoverArtArchive(release.Id, release.ReleaseGroup?.Id);
        foreach (var candidate in candidates)
        {
            try
            {
                if (await Artwork.DownloadAsync(candidate, cancellation) is { Length: > 0 } data) return (candidate, data);
            }
            catch (Exception error) when (error is MetadataException or HttpRequestException or TaskCanceledException) { }
        }
        try
        {
            if (await Artwork.ITunesAsync(album, artist, cancellation) is { } found && await Artwork.DownloadAsync(found, cancellation) is { Length: > 0 } image)
                return (found, image);
        }
        catch (Exception error) when (error is MetadataException or HttpRequestException or TaskCanceledException or System.Text.Json.JsonException) { }
        return null;
    }

    /// <summary>Lyrics for a track (synced when available), or null when LRCLIB has none.</summary>
    public async Task<FetchedLyrics?> LyricsAsync(Track track, CancellationToken cancellation = default)
    {
        var info = LocalTrackInfo.From(track);
        var artist = info?.Artist ?? track.AlbumArtist ?? "";
        if (artist.Length == 0) return null;
        return await Lyrics.LyricsAsync(info?.Title ?? track.Title, artist, track.Album, track.Duration, cancellation);
    }
}
