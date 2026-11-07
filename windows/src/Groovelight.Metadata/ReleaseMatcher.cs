using System.Globalization;
using System.Text;
using Groovelight.Core.Library;

namespace Groovelight.Metadata;

/// <summary>What the matcher needs to know about a local file.</summary>
public sealed record LocalTrackInfo(long Id, string Title, string? Artist, int? TrackNumber, int? DiscNumber, double Duration)
{
    public static LocalTrackInfo? From(Track track)
    {
        if (track.Id is not { } id) return null;
        // Untagged files are titled after their file name: "03 - Artist - Title" gives a better title to compare.
        var name = Path.GetFileNameWithoutExtension(track.Path);
        var guess = new FileNameGuess(name);
        var untitled = track.Title == name;
        return new LocalTrackInfo(id, untitled ? guess.Title : track.Title, track.Artist ?? (untitled ? guess.Artist : null),
                                  track.TrackNumber ?? (untitled ? guess.TrackNumber : null), track.DiscNumber, track.Duration);
    }
}

/// <summary>A local file paired with a track of a release.</summary>
public sealed record TrackMatch(long LocalId, MBTrack Track, int DiscNumber, int TrackNumber, int TrackTotal, double Score);

/// <summary>How a release fits a set of local files.</summary>
public sealed record ReleaseMatch(MBRelease Release, List<TrackMatch> Matches, List<long> UnmatchedLocalIds, double Score)
{
    public TrackMatch? MatchFor(long localId) => Matches.FirstOrDefault(match => match.LocalId == localId);
}

public static class ReleaseMatcher
{
    /// <summary>
    /// Orders search results by how likely they are the local album: search score, same track count, official status,
    /// studio album over live or compilation releases, and (when files were identified one by one) how many of the
    /// sampled files were found on each album.
    /// </summary>
    public static List<MBRelease> Rank(IEnumerable<MBRelease> releases, int localCount, IReadOnlyDictionary<string, int>? hits = null, int sampled = 0)
    {
        double Weight(MBRelease release)
        {
            var value = (release.Score ?? 50) / 100.0 * 0.5;
            if (sampled > 0)
            {
                var found = hits?.GetValueOrDefault(release.HitKey) ?? 0;
                value += (double)found / sampled * 0.9;
                if (found == sampled) value += 0.1;
            }
            var count = release.TotalTracks;
            if (count == localCount) value += 0.3;
            else if (count > localCount) value += 0.15 * localCount / count;
            var formats = release.Media?.Select(medium => medium.Format).OfType<string>().ToList() ?? [];
            if (formats.Any(format => format.Contains("Video", StringComparison.Ordinal) || format.Contains("Blu-ray", StringComparison.Ordinal) || format == "DVD")) value -= 0.1;
            if (release.Status == "Official") value += 0.1;
            if (release.ReleaseGroup?.PrimaryType == "Album") value += 0.05;
            if (release.ReleaseGroup?.SecondaryTypes is null or { Count: 0 }) value += 0.05;
            return value;
        }
        var seen = new HashSet<string>();
        return releases.Where(release => seen.Add(release.Id)).Select((release, offset) => (release, offset, weight: Weight(release)))
            .OrderByDescending(item => item.weight).ThenBy(item => item.offset).Select(item => item.release).ToList();
    }

    /// <summary>Pairs local files with the release's tracks (greedy on the best pair scores).</summary>
    public static ReleaseMatch Match(IReadOnlyList<LocalTrackInfo> local, MBRelease release)
    {
        var slots = (release.Media ?? []).SelectMany((medium, index) => medium.AllTracks.Select((track, offset) =>
            (Track: track, Disc: medium.Position ?? index + 1, Number: track.Position ?? offset + 1, Total: medium.TrackCount ?? medium.AllTracks.Count))).ToList();
        var multiDisc = (release.Media?.Count ?? 0) > 1;
        var pairs = new List<(int Local, int Slot, double Score)>();
        for (var li = 0; li < local.Count; li++)
        {
            for (var si = 0; si < slots.Count; si++)
            {
                var score = PairScore(local[li], slots[si].Track, slots[si].Disc, slots[si].Number, multiDisc);
                if (score >= 0.45) pairs.Add((li, si, score));
            }
        }
        // Stable: equal scores keep their order, as Swift's sort of this list did in practice.
        pairs = pairs.Select((pair, order) => (pair, order)).OrderByDescending(item => item.pair.Score).ThenBy(item => item.order).Select(item => item.pair).ToList();
        var usedLocal = new HashSet<int>();
        var usedSlot = new HashSet<int>();
        var matches = new List<TrackMatch>();
        foreach (var pair in pairs)
        {
            if (usedLocal.Contains(pair.Local) || usedSlot.Contains(pair.Slot)) continue;
            usedLocal.Add(pair.Local);
            usedSlot.Add(pair.Slot);
            var slot = slots[pair.Slot];
            matches.Add(new TrackMatch(local[pair.Local].Id, slot.Track, slot.Disc, slot.Number, slot.Total, pair.Score));
        }
        matches = matches.OrderBy(match => match.DiscNumber).ThenBy(match => match.TrackNumber).ToList();
        var unmatched = local.Where((_, index) => !usedLocal.Contains(index)).Select(info => info.Id).ToList();
        var total = Math.Max(Math.Max(local.Count, slots.Count), 1);
        return new ReleaseMatch(release, matches, unmatched, matches.Sum(match => match.Score) / total);
    }

    internal static double PairScore(LocalTrackInfo file, MBTrack track, int disc, int number, bool multiDisc)
    {
        var title = file.Title.MatchKey().Similarity(track.Title.MatchKey());
        double durationScore;
        if (track.Length is { } length && file.Duration > 0)
        {
            var difference = Math.Abs(length / 1000.0 - file.Duration);
            durationScore = difference <= 2 ? 1 : difference <= 5 ? 0.7 : difference <= 10 ? 0.3 : 0;
        }
        else durationScore = 0.5;
        double numberScore;
        if (file.TrackNumber is { } trackNumber)
        {
            var discMatches = !multiDisc || (file.DiscNumber ?? 1) == disc;
            numberScore = trackNumber == number && discMatches ? 1 : 0;
        }
        else numberScore = 0.5;
        return title * 0.5 + durationScore * 0.3 + numberScore * 0.2;
    }

    /// <summary>
    /// Proposed tags for every matched file. With <paramref name="includingUnmatched"/>, files without a track on the
    /// release get the album's own fields.
    /// </summary>
    public static Dictionary<long, TrackMetadata> Proposal(ReleaseMatch match, bool includingUnmatched = false)
    {
        var release = match.Release;
        var album = AlbumFields(release);
        var result = new Dictionary<long, TrackMetadata>();
        foreach (var item in match.Matches)
        {
            var artist = item.Track.ArtistCredit?.DisplayName() ?? release.ArtistName;
            result[item.LocalId] = album with
            {
                Title = item.Track.Title, Artist = artist.Length == 0 ? null : artist, TrackNumber = item.TrackNumber,
                TrackTotal = item.TrackTotal, DiscNumber = item.DiscNumber, MusicBrainzRecordingId = item.Track.Recording?.Id,
            };
        }
        if (includingUnmatched) foreach (var id in match.UnmatchedLocalIds) result[id] = album;
        return result;
    }

    /// <summary>The fields every song of the release shares: album, album artist, genre, year, disc count, compilation, release id.</summary>
    public static TrackMetadata AlbumFields(MBRelease release)
    {
        var isVarious = release.ArtistCredit?.IsVariousArtists() ?? false;
        var albumArtist = isVarious ? "Various Artists" : release.ArtistName;
        return new TrackMetadata
        {
            Album = release.Title, AlbumArtist = albumArtist.Length == 0 ? null : albumArtist, Genre = release.PrimaryGenre, Year = release.Year,
            DiscTotal = release.Media?.Count, IsCompilation = isVarious, MusicBrainzReleaseId = release.Id,
        };
    }
}

/// <summary>Songs fixed together as one album, whatever albums their tags name now.</summary>
public sealed class SongGroup
{
    /// <summary>The album title most of the songs name.</summary>
    public string? Album { get; }
    /// <summary>The album artist (or artist) most of the songs name.</summary>
    public string? Artist { get; }
    /// <summary>How many different albums the songs are in now.</summary>
    public int AlbumCount { get; }
    /// <summary>A few songs to identify one by one, taken in turn from each album they are in now.</summary>
    public List<LocalTrackInfo> Sample { get; }

    public bool IsMixed => AlbumCount > 1;

    public SongGroup(IReadOnlyList<Track> tracks, int sampleSize = 4)
    {
        Album = MostCommon(tracks.Select(track => track.Album?.Trim()).OfType<string>());
        Artist = MostCommon(tracks.Select(track => (track.AlbumArtist ?? track.Artist)?.Trim()).OfType<string>());
        var order = new List<string>();
        var byAlbum = new Dictionary<string, List<Track>>();
        foreach (var track in tracks)
        {
            if (!byAlbum.ContainsKey(track.AlbumKey)) { order.Add(track.AlbumKey); byAlbum[track.AlbumKey] = []; }
            byAlbum[track.AlbumKey].Add(track);
        }
        AlbumCount = order.Count;
        // Round robin over the albums: a release holding a song from each of them is the likely album.
        var picked = new List<Track>();
        for (var round = 0; picked.Count < sampleSize && picked.Count < tracks.Count; round++)
        {
            foreach (var key in order)
            {
                if (picked.Count >= sampleSize) break;
                if (byAlbum[key].Skip(round).FirstOrDefault() is { } track) picked.Add(track);
            }
        }
        Sample = picked.Select(LocalTrackInfo.From).OfType<LocalTrackInfo>().ToList();
    }

    /// <summary>The most frequent non-empty value; ties go to the one seen first.</summary>
    internal static string? MostCommon(IEnumerable<string> values)
    {
        var counts = new Dictionary<string, int>();
        var order = new List<string>();
        foreach (var value in values.Where(value => value.Length > 0))
        {
            if (!counts.ContainsKey(value)) order.Add(value);
            counts[value] = counts.GetValueOrDefault(value) + 1;
        }
        string? best = null;
        foreach (var value in order) if (best is null || counts[value] > counts[best]) best = value;
        return best;
    }
}

/// <summary>Artist, title and track number guessed from a file name such as "03 - Artist - Title" or "03. Title".</summary>
public sealed record FileNameGuess
{
    public int? TrackNumber { get; }
    public string? Artist { get; }
    public string Title { get; }

    public FileNameGuess(string name)
    {
        var rest = name.Replace('_', ' ').Trim();
        // Leading track number ("03", "1-03" for disc-track), followed by a separator.
        var digits = new string(rest.TakeWhile(character => char.IsDigit(character) || character == '-').ToArray());
        if (digits.Length > 0 && char.IsDigit(digits[0]) && digits.Split('-', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() is { } last
            && int.TryParse(last, NumberStyles.None, CultureInfo.InvariantCulture, out var number) && number is > 0 and < 200
            && rest.Length > digits.Length && " .-)".Contains(rest[digits.Length]))
        {
            TrackNumber = number;
            rest = new string(rest[digits.Length..].SkipWhile(character => " .-)".Contains(character)).ToArray());
        }
        var parts = rest.Split(" - ").Select(part => part.Trim()).Where(part => part.Length > 0).ToList();
        if (parts.Count >= 2)
        {
            Artist = parts[0];
            Title = string.Join(" - ", parts.Skip(1));
        }
        else Title = parts.FirstOrDefault() ?? name;
    }
}

public static class MatchText
{
    /// <summary>
    /// Loose comparison key: case and diacritics folded, "&amp;" as "and", punctuation dropped, spaces collapsed, a
    /// leading "The" removed.
    /// </summary>
    public static string MatchKey(this string text)
    {
        var folded = Groovelight.Core.Text.Fold(text).Replace("&", " and ");
        var cleaned = new StringBuilder(folded.Length);
        foreach (var rune in folded.EnumerateRunes()) cleaned.Append(Rune.IsLetterOrDigit(rune) ? rune.ToString() : " ");
        var words = cleaned.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
        if (words.Count > 1 && words[0] == "the") words.RemoveAt(0);
        return string.Join(" ", words);
    }

    /// <summary>1 for equal strings, down to 0, from the Levenshtein distance (on characters).</summary>
    public static double Similarity(this string a, string b)
    {
        if (a == b) return 1;
        var left = a.EnumerateRunes().ToArray();
        var right = b.EnumerateRunes().ToArray();
        if (left.Length == 0 || right.Length == 0) return 0;
        var previous = Enumerable.Range(0, right.Length + 1).ToArray();
        var current = new int[right.Length + 1];
        for (var i = 1; i <= left.Length; i++)
        {
            current[0] = i;
            for (var j = 1; j <= right.Length; j++)
            {
                var cost = left[i - 1] == right[j - 1] ? 0 : 1;
                current[j] = Math.Min(Math.Min(previous[j] + 1, current[j - 1] + 1), previous[j - 1] + cost);
            }
            (previous, current) = (current, previous);
        }
        return 1 - (double)previous[right.Length] / Math.Max(left.Length, right.Length);
    }
}
