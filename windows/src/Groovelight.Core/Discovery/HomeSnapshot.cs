using Groovelight.Core.Library;
using Microsoft.Data.Sqlite;

namespace Groovelight.Core.Discovery;

using static Discovery;

/// <summary>
/// Home as the hosts make it (the Mac's HomeSnapshot, same JSON): the day's picks, each with the next ones drawn for
/// "Something Else", and the dashboard for every range. The phones get it over wireless sync (<c>GET /home</c>).
/// </summary>
public sealed class HomeSnapshot
{
    public sealed class Card
    {
        public Kind Kind { get; set; }
        /// <summary>The song id, the album key or the artist name.</summary>
        public string Key { get; set; } = "";
        /// <summary><see cref="Reason.Code"/>.</summary>
        public string Reason { get; set; } = "";
        /// <summary>The line under the card ("8 plays, last heard 2 months ago").</summary>
        public string ReasonText { get; set; } = "";
        public string Title { get; set; } = "";
        public string Subtitle { get; set; } = "";
        public string? ArtworkHash { get; set; }
        /// <summary>The songs to play for it, in order.</summary>
        public List<long> TrackIds { get; set; } = [];
    }

    /// <summary>Days since 1970 (local calendar) the picks are for.</summary>
    public long Day { get; set; }
    /// <summary>The day's pick first, then up to five more, for each kind.</summary>
    public List<Card> Song { get; set; } = [];
    public List<Card> Album { get; set; } = [];
    public List<Card> Artist { get; set; } = [];
    /// <summary>Week, month, year and all time.</summary>
    public List<ListeningStats> Stats { get; set; } = [];

    public List<Card> Cards(Kind kind) => kind switch { Kind.Song => Song, Kind.Album => Album, _ => Artist };
}

public static class HomeStore
{
    /// <summary>
    /// Today's Home: the picks (made and kept on the first call of the day) with five more of each kind, and, with
    /// <paramref name="stats"/>, the dashboard for every range.
    /// </summary>
    public static HomeSnapshot HomeSnapshotFor(this LibraryDatabase database, DateTime? utcNow = null, TimeZoneInfo? zone = null, bool stats = true, int choices = 6)
    {
        var now = utcNow ?? DateTime.UtcNow;
        var (picks, picker) = database.DailyPicksFor(now, zone);
        return database.Read(db =>
        {
            var snapshot = new HomeSnapshot { Day = DayOf(now, zone) };
            foreach (var kind in Enum.GetValues<Kind>())
            {
                var first = picks.FirstOrDefault(pick => pick.Kind == kind);
                var others = picker.Draw(kind, choices).Where(pick => pick.Key != first?.Key);
                var cards = (first is null ? others : others.Prepend(first)).Take(choices).Select(pick => db.HomeCard(pick)).OfType<HomeSnapshot.Card>();
                snapshot.Cards(kind).AddRange(cards);
            }
            if (stats)
                snapshot.Stats = [.. Enum.GetValues<ListeningStats.StatsRange>().Select(range => db.ListeningStatsFor(range, now, zone))];
            return snapshot;
        });
    }

    /// <summary>A pick as Home shows it (null when its songs are gone).</summary>
    public static HomeSnapshot.Card? HomeCard(this SqliteConnection db, Pick pick)
    {
        var tracks = db.TracksWithIds(pick.TrackIds);
        if (tracks.Count == 0) return null;
        var first = tracks[0];
        static string? Cover(Track track) => track.FetchedArtworkHash ?? track.ArtworkHash;
        var (title, subtitle, artwork) = pick.Kind switch
        {
            Kind.Song => (first.Title, first.DisplayArtist, Cover(first)),
            Kind.Album => (first.DisplayAlbum, tracks.Any(track => track.IsCompilation) ? "Various Artists" : first.DisplayAlbumArtist, Cover(first)),
            _ => (pick.Key, $"Essentials, {(tracks.Count == 1 ? "1 song" : $"{tracks.Count} songs")}",
                  db.ArtistPhotos([pick.Key]).GetValueOrDefault(pick.Key) ?? tracks.Select(Cover).FirstOrDefault(hash => hash is not null)),
        };
        return new HomeSnapshot.Card
        {
            Kind = pick.Kind, Key = pick.Key, Reason = pick.Reason.Code, ReasonText = Text(pick.Reason, pick.Kind), Title = title, Subtitle = subtitle,
            ArtworkHash = artwork, TrackIds = [.. pick.TrackIds],
        };
    }

    /// <summary>Songs by id, in the order asked (missing ones left out).</summary>
    public static List<Track> TracksWithIds(this SqliteConnection db, IReadOnlyList<long> ids)
    {
        if (ids.Count == 0) return [];
        var found = db.FetchTracks($"SELECT * FROM track WHERE id IN ({string.Join(",", ids.Select(_ => "?"))})", [.. ids.Cast<object?>()])
            .Where(track => track.Id is not null).ToDictionary(track => track.Id!.Value);
        return [.. ids.Where(found.ContainsKey).Select(id => found[id])];
    }

    /// <summary>The line under a pick (the same words on the Mac).</summary>
    public static string Text(Reason reason, Kind kind) => reason switch
    {
        Reason.Rediscover r => $"{r.Plays} plays, last heard {Ago(r.DaysSince)}",
        Reason.HiddenGem g => g.Loved ? "You love it, and have hardly played it" : $"Rated {g.Rating} stars, hardly played",
        Reason.NewToYou n => n.DaysSinceAdded == 0 ? "Added today, not played much yet" : $"Added {Ago(n.DaysSinceAdded)}, not played much yet",
        Reason.Anniversary a => $"Released {a.Years} years ago",
        Reason.Favorite f => f.Plays > 1 ? $"One of your favorites, {f.Plays} plays" : f.Plays == 1 ? "One of your favorites, 1 play" : "One of your favorites",
        _ => kind == Kind.Artist ? "Not played yet: a good day to start" : "Not played yet",
    };

    public static string Ago(long days) => days switch
    {
        < 1 => "today",
        1 => "yesterday",
        < 14 => $"{days} days ago",
        < 60 => $"{days / 7} weeks ago",
        < 730 => $"{days / 30} months ago",
        _ => $"{days / 365} years ago",
    };

    public static string Title(Kind kind) => kind switch { Kind.Song => "Song of the Day", Kind.Album => "Album of the Day", _ => "Artist of the Day" };
}
