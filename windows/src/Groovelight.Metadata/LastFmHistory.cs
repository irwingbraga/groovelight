using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Groovelight.Core.Library;

namespace Groovelight.Metadata;

/// <summary>A scrobble from the user's Last.fm history.</summary>
public sealed record LastFmPlay(string Artist, string Title, string Album, DateTime Date);

public sealed record LastFmHistoryPage(IReadOnlyList<LastFmPlay> Plays, int Page, int TotalPages, int Total);

/// <summary>
/// Song names as Last.fm and the library may spell them differently: case, accents, "feat." parts, bracketed notes
/// ("Remastered 2011", "Live") and punctuation are left out. The Mac has the same rules (SongKey).
/// </summary>
public static partial class SongKey
{
    public static string Key(string artist, string title) => ArtistName(artist) + "\u0001" + Normalize(title);

    public static string ArtistName(string artist)
    {
        var name = Normalize(artist);
        return name.StartsWith("the ", StringComparison.Ordinal) ? name[4..] : name;
    }

    public static string Normalize(string text)
    {
        var decomposed = text.Normalize(NormalizationForm.FormD);
        var folded = new StringBuilder(decomposed.Length);
        foreach (var character in decomposed)
            if (CharUnicodeInfo.GetUnicodeCategory(character) != UnicodeCategory.NonSpacingMark) folded.Append(character);
        var value = folded.ToString().Normalize(NormalizationForm.FormC).ToLowerInvariant();
        value = Bracketed().Replace(value, "");
        value = DashNote().Replace(value, "");
        value = Featuring().Replace(value, "");
        value = value.Replace("&", " and ", StringComparison.Ordinal);
        value = Punctuation().Replace(value, " ");
        return value.Trim();
    }

    [GeneratedRegex(@"\s*[(\[][^)\]]*[)\]]")]
    private static partial Regex Bracketed();

    [GeneratedRegex(@"\s+-\s+.*\b(remaster\w*|live|version|edit|mono|stereo|demo|mix)\b.*$")]
    private static partial Regex DashNote();

    [GeneratedRegex(@"\s+(feat\.?|ft\.?|featuring)\s+.*$")]
    private static partial Regex Featuring();

    [GeneratedRegex(@"[^\p{L}\p{N}]+")]
    private static partial Regex Punctuation();
}

/// <summary>
/// Brings the user's Last.fm history into the listening log (rows with source "lastfm"), oldest page first, so a stopped
/// import picks up where it left off. Plays Groovelight itself sent (a play here within 2 minutes of the scrobble) are not
/// counted twice. Songs not in the library keep their names. The Mac's LastFMHistoryImport.
/// </summary>
public sealed class LastFmHistoryImport(LibraryDatabase database, LastFmClient client, string user)
{
    public sealed record Progress(int Imported, int Matched, int Page, int TotalPages, int Total);

    /// <summary>Between pages (Last.fm asks for no more than about 5 calls a second).</summary>
    public TimeSpan Pause { get; init; } = TimeSpan.FromSeconds(1);
    public Func<DateTime> Now { get; init; } = () => DateTime.UtcNow;

    private sealed record Song(long Id, string Album, double Duration);

    public async Task<Progress> RunAsync(Action<Progress>? progress = null, CancellationToken cancellation = default)
    {
        var newest = database.Read(db => db.Scalar<DateTime?>("SELECT MAX(startedAt) FROM listen WHERE source = ?", Listen.Sources.LastFm));
        DateTime? from = newest?.AddSeconds(1);
        var to = Now();
        var first = await PageAsync(1, from, to, cancellation);
        var state = new Progress(0, 0, 0, first.TotalPages, first.Total);
        if (first.TotalPages == 0 || first.Plays.Count == 0) return state;
        progress?.Invoke(state);

        var (library, local) = Indexes(from);
        for (var number = first.TotalPages; number >= 1; number--)
        {
            cancellation.ThrowIfCancellationRequested();
            var page = number == 1 ? first : await PageAsync(number, from, to, cancellation);
            var (imported, matched) = Save(page.Plays.Reverse(), library, local);
            state = state with { Imported = state.Imported + imported, Matched = state.Matched + matched, Page = first.TotalPages - number + 1 };
            progress?.Invoke(state);
            if (number > 1) await Task.Delay(Pause, cancellation);
        }
        return state;
    }

    /// <summary>A page, tried again a few times when Last.fm is busy or the connection drops.</summary>
    private async Task<LastFmHistoryPage> PageAsync(int number, DateTime? from, DateTime to, CancellationToken cancellation)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                return await client.RecentTracksAsync(user, from, to, number);
            }
            catch (LastFmException error) when (error.IsTemporary && attempt < 3)
            {
                await Task.Delay(Pause * (5 * (attempt + 1)), cancellation);
            }
        }
    }

    /// <summary>The library's songs by name, and the times of plays already in the log by name.</summary>
    private (Dictionary<string, List<Song>> Library, Dictionary<string, List<DateTime>> Local) Indexes(DateTime? from) => database.Read(db =>
    {
        var library = new Dictionary<string, List<Song>>();
        foreach (var (id, artist, albumArtist, title, album, duration) in db.Query("SELECT id, artist, albumArtist, title, album, duration FROM track",
                     row => (row.Get<long>("id"), row.Get<string>("artist"), row.Get<string>("albumArtist"), row.Get<string>("title") ?? "",
                             row.Get<string>("album"), row.Get<double>("duration"))))
        {
            var song = new Song(id, SongKey.Normalize(album ?? ""), duration);
            foreach (var name in new[] { artist, albumArtist }.OfType<string>().Distinct())
            {
                var key = SongKey.Key(name, title);
                if (!library.TryGetValue(key, out var songs)) library[key] = songs = [];
                songs.Add(song);
            }
        }
        var local = new Dictionary<string, List<DateTime>>();
        var start = from?.AddMinutes(-10) ?? DateTime.MinValue;
        foreach (var (artist, title, startedAt) in db.Query("SELECT artist, title, startedAt FROM listen WHERE source NOT IN (?, ?) AND startedAt >= ?",
                     row => (row.Get<string>("artist") ?? "", row.Get<string>("title") ?? "", row.Get<DateTime>("startedAt")),
                     Listen.Sources.LastFm, Listen.Sources.Summary, start))
        {
            var key = SongKey.Key(artist, title);
            if (!local.TryGetValue(key, out var times)) local[key] = times = [];
            times.Add(startedAt);
        }
        return (library, local);
    });

    private (int Imported, int Matched) Save(IEnumerable<LastFmPlay> plays, Dictionary<string, List<Song>> library, Dictionary<string, List<DateTime>> local) =>
        database.Write(db =>
        {
            int imported = 0, matched = 0;
            foreach (var play in plays)
            {
                var key = SongKey.Key(play.Artist, play.Title);
                if (local.TryGetValue(key, out var times) && times.Any(time => Math.Abs((time - play.Date).TotalSeconds) <= 120)) continue;
                var album = SongKey.Normalize(play.Album);
                var candidates = library.GetValueOrDefault(key) ?? [];
                var song = candidates.FirstOrDefault(candidate => candidate.Album == album) ?? candidates.FirstOrDefault();
                ListeningLog.Insert(db, new Listen
                {
                    TrackId = song?.Id, StartedAt = play.Date, Listened = song?.Duration ?? 0, Duration = song?.Duration ?? 0,
                    Counted = true, Skipped = false, Source = Listen.Sources.LastFm, Artist = play.Artist, Title = play.Title, Album = play.Album,
                });
                imported++;
                if (song is not null) matched++;
            }
            return (imported, matched);
        });
}
