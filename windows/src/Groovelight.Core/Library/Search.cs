using Microsoft.Data.Sqlite;

namespace Groovelight.Core.Library;

/// <summary>Everything in the library matching a search, by category.</summary>
public sealed record LibrarySearchResults
{
    public List<ArtistSummary> Artists { get; init; } = [];
    public List<AlbumSummary> Albums { get; init; } = [];
    public List<Track> Songs { get; init; } = [];
    /// <summary>People from the album credits (musicians, producers, engineers, studios) who are not library artists.</summary>
    public List<CreditedPerson> People { get; init; } = [];

    public bool IsEmpty => Artists.Count == 0 && Albums.Count == 0 && Songs.Count == 0 && People.Count == 0;
}

/// <summary>A person from the credits matching a search, with what they did.</summary>
public sealed record CreditedPerson(CreditPerson Person, IReadOnlyList<string> Roles, int AlbumCount)
{
    public string Id => Person.ArtistId ?? "name:" + Person.Name.ToLowerInvariant();
}

/// <summary>
/// Word prefix matching that ignores case, accents and punctuation: every word of the query must start a word of the
/// text ("beat yel" matches "Yellow Submarine" by "The Beatles", "acdc" does not match "AC/DC" but "ac dc" does).
/// </summary>
public sealed class SearchMatcher
{
    public IReadOnlyList<string> Words { get; }
    private readonly string phrase;

    public SearchMatcher(string query)
    {
        Words = SplitWords(query);
        phrase = string.Join(' ', Words);
    }

    public bool IsEmpty => Words.Count == 0;

    /// <summary>Lower is better: 0 exact, 1 the text starts with the query, 2 every query word starts a word of the text. Null when some query word matches nothing.</summary>
    public int? Score(string text)
    {
        var textWords = SplitWords(text);
        if (Words.Count == 0 || !Words.All(word => textWords.Any(candidate => candidate.StartsWith(word, StringComparison.Ordinal)))) return null;
        var joined = string.Join(' ', textWords);
        if (joined == phrase) return 0;
        if (joined.StartsWith(phrase, StringComparison.Ordinal)) return 1;
        return 2;
    }

    internal static List<string> SplitWords(string text)
    {
        var folded = Text.Fold(text);
        var words = new List<string>();
        var start = -1;
        for (var index = 0; index <= folded.Length; index++)
        {
            var isWordCharacter = index < folded.Length && char.IsLetterOrDigit(folded[index]);
            if (isWordCharacter && start < 0) start = index;
            else if (!isWordCharacter && start >= 0)
            {
                words.Add(folded[start..index]);
                start = -1;
            }
        }
        return words;
    }
}

public static class LibrarySearch
{
    /// <summary>Artists, albums, songs and credited people matching <paramref name="query"/>, best matches first in each category.</summary>
    public static LibrarySearchResults Search(this SqliteConnection db, string query, int limit = 300)
    {
        var matcher = new SearchMatcher(query);
        if (matcher.IsEmpty) return new LibrarySearchResults();

        var artists = Ranked(db.Artists(), limit, artist => matcher.Score(artist.Name));
        // Albums by title first, then albums of a matching artist.
        var albums = Ranked(db.Albums(AlbumSort.Artist), limit,
                            album => matcher.Score(album.Title) ?? matcher.Score(album.Title + " " + album.Artist) + 3);
        var songs = SearchSongs(db, matcher, limit);
        var artistNames = artists.Select(artist => artist.Name.ToLowerInvariant()).ToHashSet();
        var people = Ranked(CreditedPeople(db), limit,
                            person => artistNames.Contains(person.Person.Name.ToLowerInvariant()) ? null : matcher.Score(person.Person.Name));
        return new LibrarySearchResults { Artists = artists, Albums = albums, Songs = songs, People = people };
    }

    /// <summary>Songs by full-text search, a title match weighing most.</summary>
    private static List<Track> SearchSongs(SqliteConnection db, SearchMatcher matcher, int limit)
    {
        var pattern = string.Join(' ', matcher.Words.Select(word => $"\"{word}\"*"));
        // Columns: title, artist, album, albumArtist, composer, genre.
        return db.FetchTracks("""
            SELECT track.* FROM track
            JOIN track_ft ON track_ft.rowid = track.id AND track_ft MATCH ?
            ORDER BY bm25(track_ft, 10.0, 4.0, 3.0, 3.0, 2.0, 1.0)
            LIMIT ?
            """, pattern, limit);
    }

    /// <summary>Everyone in the credits, one entry per person (by MusicBrainz id, or by name without one).</summary>
    private static List<CreditedPerson> CreditedPeople(SqliteConnection db) => db.Query("""
        SELECT MIN(name) AS name, artistId, COUNT(DISTINCT albumKey) AS albumCount, GROUP_CONCAT(roles, char(10)) AS roles
        FROM creditIndex
        GROUP BY COALESCE(artistId, 'name:' || nameKey)
        """, row =>
    {
        var counts = new Dictionary<string, int>();
        foreach (var role in (row.Get<string>("roles") ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries))
            counts[role] = counts.GetValueOrDefault(role) + 1;
        var roles = counts.OrderByDescending(pair => pair.Value).ThenBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => pair.Key).ToList();
        return new CreditedPerson(new CreditPerson(row.Get<string>("name") ?? "", row.Get<string>("artistId")), roles, row.Get<int>("albumCount"));
    });

    /// <summary>The items that match, best score first (ties keep their order), at most <paramref name="limit"/>.</summary>
    internal static List<T> Ranked<T>(IEnumerable<T> items, int limit, Func<T, int?> score) =>
        items.Select((item, index) => (item, score: score(item), index))
             .Where(match => match.score is not null)
             .OrderBy(match => match.score).ThenBy(match => match.index)
             .Take(limit).Select(match => match.item).ToList();
}
