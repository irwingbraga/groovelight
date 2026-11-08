namespace Groovelight.Core.Discovery;

using static Discovery;

/// <summary>
/// Song, Album and Artist of the Day (the Mac's Discovery.DailyPicks). A day's pick, once made, is kept (a past pick with
/// today's day), so it stays the same all day however the log changes; "Something else" draws the next ones with the same seed.
/// </summary>
public sealed class DailyPicks
{
    /// <summary>How long a pick stays out of the draw.</summary>
    public static readonly IReadOnlyDictionary<Kind, long> Rest = new Dictionary<Kind, long> { [Kind.Song] = 90, [Kind.Album] = 30, [Kind.Artist] = 14 };

    private readonly Dictionary<long, Song> byId;

    public DailyPicks(IReadOnlyList<Song> songs, IReadOnlyList<Play> plays, IReadOnlyList<PastPick> past, long today)
    {
        Songs = songs.OrderBy(song => song.Id).ToList();
        Taste = new Taste(songs, plays, today);
        Today = today;
        Past = past;
        byId = [];
        foreach (var song in songs) byId.TryAdd(song.Id, song);
    }

    public IReadOnlyList<Song> Songs { get; }
    public Taste Taste { get; }
    public long Today { get; }
    public IReadOnlyList<PastPick> Past { get; }

    /// <summary>Today's pick of a kind: the one kept for today, or the first draw.</summary>
    public Pick? PickOf(Kind kind)
    {
        if (Past.FirstOrDefault(pick => pick.Day == Today && pick.Kind == kind) is { } kept && Make(kind, kept.Key, Reason.FromCode(kept.Reason)) is { } pick)
            return pick;
        return Draw(kind, 1).FirstOrDefault();
    }

    /// <summary>The first <paramref name="count"/> draws of the day for a kind (the pick, then "Something else").</summary>
    public List<Pick> Draw(Kind kind, int count)
    {
        var resting = Past.Where(pick => pick.Kind == kind && pick.Day < Today && Today - pick.Day < Rest[kind]).Select(pick => pick.Key).ToHashSet();
        var pools = Candidates(kind).Select(pool => (pool.Share, Items: pool.Items.Where(item => !resting.Contains(item.Key)).ToList())).ToList();
        var random = new Discovery.Random(Seed(Today, kind));
        var picks = new List<Pick>();
        while (picks.Count < count)
        {
            var shares = pools.Select(pool => pool.Items.Count == 0 ? 0 : pool.Share).ToList();
            if (random.Weighted(shares) is not { } poolIndex || random.Weighted(pools[poolIndex].Items.Select(item => item.Weight).ToList()) is not { } itemIndex) break;
            var item = pools[poolIndex].Items[itemIndex];
            pools[poolIndex].Items.RemoveAt(itemIndex);
            foreach (var pool in pools) pool.Items.RemoveAll(other => other.Key == item.Key);
            if (Make(kind, item.Key, item.Reason) is { } pick) picks.Add(pick);
        }
        return picks;
    }

    internal sealed record Candidate(string Key, long Weight, Reason Reason);

    internal sealed record Pool(long Share, List<Candidate> Items);

    internal List<Pool> Candidates(Kind kind) => kind switch
    {
        Kind.Song => SongCandidates(),
        Kind.Album => AlbumCandidates(),
        _ => ArtistCandidates(),
    };

    private List<Pool> SongCandidates()
    {
        List<Candidate> rediscover = [], gems = [], fresh = [], unplayed = [];
        foreach (var song in Songs)
        {
            var score = Taste[song.Id];
            var key = song.Id.ToString(System.Globalization.CultureInfo.InvariantCulture);
            if (score.Plays >= 3 && score.LastDay is { } last && Today - last >= 60)
            {
                var since = Today - last;
                rediscover.Add(new(key, (score.Affinity + score.Plays * 200) * Math.Min(since, 730) / 365 + 1, new Reason.Rediscover(score.Plays, since)));
            }
            else if ((song.Loved || song.Rating >= 4) && score.Plays < 3)
                gems.Add(new(key, 1000 + song.Rating * 200L + (song.Loved ? 1000 : 0), new Reason.HiddenGem(song.Loved, song.Rating)));
            else if (Today - song.AddedDay <= 60 && score.Plays < 2)
                fresh.Add(new(key, Math.Max(1000 - (Today - song.AddedDay) * 10, 100), new Reason.NewToYou(Today - song.AddedDay)));
            else if (score.Plays == 0)
                unplayed.Add(new(key, 1, new Reason.Unplayed()));
        }
        return [new(60, rediscover), new(30, gems), new(10, fresh), new(rediscover.Count == 0 && gems.Count == 0 && fresh.Count == 0 ? 1 : 0, unplayed)];
    }

    private sealed class Group(string key)
    {
        public string Key { get; } = key;
        public List<Song> Songs { get; } = [];
        public long Affinity { get; set; }
        public long Plays { get; set; }
        public long? LastDay { get; set; }
    }

    private List<Group> Groups(Func<Song, string?> key)
    {
        var groups = new Dictionary<string, Group>();
        foreach (var song in Songs)
        {
            if (key(song) is not { } name) continue;
            var score = Taste[song.Id];
            if (!groups.TryGetValue(name, out var group)) groups[name] = group = new Group(name);
            group.Songs.Add(song);
            group.Affinity += score.Affinity;
            group.Plays += score.Plays;
            if (score.LastDay is { } last) group.LastDay = Math.Max(group.LastDay ?? last, last);
        }
        var list = groups.Values.ToList();
        list.Sort((a, b) => CompareCodePoints(a.Key, b.Key));
        return list;
    }

    private List<Pool> AlbumCandidates()
    {
        var thisYear = YearOfDay(Today);
        List<Candidate> rediscover = [], anniversaries = [], fresh = [], any = [];
        foreach (var album in Groups(song => song.AlbumKey.Length == 0 ? null : song.AlbumKey))
        {
            var years = album.Songs.Where(song => song.Year is not null).Select(song => (long?)song.Year!.Value).Min() is { } earliest ? thisYear - earliest : (long?)null;
            if (album.Plays >= 5 && album.LastDay is { } last && Today - last >= 45)
            {
                var since = Today - last;
                rediscover.Add(new(album.Key, (album.Affinity + album.Plays * 100) * Math.Min(since, 730) / 365 + 1, new Reason.Rediscover(album.Plays, since)));
            }
            else if (years is { } age && age >= 10 && age % 5 == 0)
                anniversaries.Add(new(album.Key, album.Plays > 0 ? 1000 + album.Plays * 20 : 300, new Reason.Anniversary(age)));
            else if (album.Songs.Max(song => song.AddedDay) is var added && Today - added <= 60 && album.Plays < 3)
                fresh.Add(new(album.Key, 1000, new Reason.NewToYou(Today - added)));
            else
                any.Add(new(album.Key, 1, album.Plays == 0 ? new Reason.Unplayed() : new Reason.Favorite(album.Plays)));
        }
        return [new(55, rediscover), new(20, anniversaries), new(25, fresh), new(rediscover.Count == 0 && anniversaries.Count == 0 && fresh.Count == 0 ? 1 : 0, any)];
    }

    private List<Pool> ArtistCandidates()
    {
        List<Candidate> favorites = [], unplayed = [];
        foreach (var artist in Groups(song => song.Artist.Length == 0 ? null : song.Artist))
        {
            if (artist.Plays > 0) favorites.Add(new(artist.Key, SquareRoot(artist.Affinity) + 1, new Reason.Favorite(artist.Plays)));
            else if (artist.Songs.Count >= 3) unplayed.Add(new(artist.Key, 1, new Reason.Unplayed()));
        }
        return [new(85, favorites), new(15, unplayed)];
    }

    private Pick? Make(Kind kind, string key, Reason? reason = null)
    {
        switch (kind)
        {
            case Kind.Song:
                if (!long.TryParse(key, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var id) || !byId.ContainsKey(id)) return null;
                return new Pick(kind, key, reason ?? ReasonFor(kind, key), [id]);
            case Kind.Album:
                var tracks = Songs.Where(song => song.AlbumKey == key).OrderBy(song => song.Order).ThenBy(song => song.Id).Select(song => song.Id).ToList();
                return tracks.Count == 0 ? null : new Pick(kind, key, reason ?? ReasonFor(kind, key), tracks);
            default:
                var essentials = Essentials(key);
                return essentials.Count == 0 ? null : new Pick(kind, key, reason ?? ReasonFor(kind, key), essentials);
        }
    }

    /// <summary>The reason of a kept pick (worked out again from today's draw, or as a favorite).</summary>
    private Reason ReasonFor(Kind kind, string key) =>
        Candidates(kind).SelectMany(pool => pool.Items).FirstOrDefault(item => item.Key == key)?.Reason ?? new Reason.Favorite(0);

    /// <summary>An artist's most liked songs (up to 15), then up to 5 never played, for Artist of the Day.</summary>
    public List<long> Essentials(string artist)
    {
        var theirs = Songs.Where(song => song.Artist == artist).ToList();
        var liked = theirs.Where(song => Taste[song.Id].Affinity > 0)
            .OrderByDescending(song => Taste[song.Id].Affinity).ThenBy(song => song.Id).Take(15).ToList();
        var random = new Discovery.Random(Seed(Today, Kind.Artist) + "|" + artist);
        var unplayed = theirs.Where(song => Taste[song.Id].Plays == 0 && Taste[song.Id].Affinity == 0).ToList();
        var extra = new List<Song>();
        while (extra.Count < 5 && unplayed.Count > 0)
        {
            var index = (int)random.Below((ulong)unplayed.Count);
            extra.Add(unplayed[index]);
            unplayed.RemoveAt(index);
        }
        return liked.Concat(extra).Select(song => song.Id).ToList();
    }
}
