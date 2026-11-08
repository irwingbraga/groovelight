using System.Globalization;
using System.Text;
using Groovelight.Core.Library;

namespace Groovelight.Core.Discovery;

/// <summary>
/// Home's picks of the day, worked out from the listening log (the Mac's Discovery). Everything here is integer math over a
/// seeded random generator, so the same library, log and day give the same picks on Windows and on the Mac, which check it
/// against the same fixtures (GroovelightKit's Fixtures/Discovery).
/// </summary>
public static class Discovery
{
    public enum Kind { Song, Album, Artist }

    public static string Raw(Kind kind) => kind switch { Kind.Song => "song", Kind.Album => "album", _ => "artist" };

    public static Kind? ParseKind(string? text) => text switch { "song" => Kind.Song, "album" => Kind.Album, "artist" => Kind.Artist, _ => null };

    /// <summary>What the picks need of a song.</summary>
    public sealed record Song
    {
        public long Id { get; init; }
        public string Title { get; init; } = "";
        public string Artist { get; init; } = "";
        /// <summary>The album's artist (Various Artists for compilations).</summary>
        public string AlbumArtist { get; init; } = "";
        public string Album { get; init; } = "";
        public string AlbumKey { get; init; } = "";
        public string? Genre { get; init; }
        public int? Year { get; init; }
        public bool Loved { get; init; }
        public int Rating { get; init; }
        /// <summary>Days since 1970 (local calendar) the song was added.</summary>
        public long AddedDay { get; init; }
        public double Duration { get; init; }
        /// <summary>Disc and track number (disc * 1000 + track), for the album's order.</summary>
        public long Order { get; init; }
    }

    /// <summary>What the picks need of a listen.</summary>
    public sealed record Play
    {
        public long TrackId { get; init; }
        /// <summary>Days since 1970 (local calendar).</summary>
        public long Day { get; init; }
        public bool Counted { get; init; }
        public bool Skipped { get; init; }
        public long Count { get; init; } = 1;
        public string Source { get; init; } = "";
    }

    /// <summary>An earlier pick, so picks do not come back too soon.</summary>
    public sealed record PastPick(long Day, Kind Kind, string Key, string? Reason = null);

    /// <summary>Why something was picked, for the line under it.</summary>
    public abstract record Reason
    {
        /// <summary>Much played, not lately.</summary>
        public sealed record Rediscover(long Plays, long DaysSince) : Reason;
        /// <summary>Loved or rated, hardly played.</summary>
        public sealed record HiddenGem(bool Loved, long Rating) : Reason;
        public sealed record NewToYou(long DaysSinceAdded) : Reason;
        public sealed record Anniversary(long Years) : Reason;
        public sealed record Favorite(long Plays) : Reason;
        public sealed record Unplayed : Reason;

        /// <summary>As stored with a pick ("rediscover,12,90"), the same on the Mac.</summary>
        public string Code => this switch
        {
            Rediscover r => $"rediscover,{r.Plays},{r.DaysSince}",
            HiddenGem g => $"hiddenGem,{(g.Loved ? 1 : 0)},{g.Rating}",
            NewToYou n => $"newToYou,{n.DaysSinceAdded}",
            Anniversary a => $"anniversary,{a.Years}",
            Favorite f => $"favorite,{f.Plays}",
            _ => "unplayed",
        };

        public static Reason? FromCode(string? code)
        {
            if (code is null) return null;
            var parts = code.Split(',');
            var numbers = parts.Skip(1).Select(part => long.TryParse(part, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ? (long?)value : null)
                .OfType<long>().ToArray();
            return (parts[0], numbers.Length) switch
            {
                ("rediscover", 2) => new Rediscover(numbers[0], numbers[1]),
                ("hiddenGem", 2) => new HiddenGem(numbers[0] == 1, numbers[1]),
                ("newToYou", 1) => new NewToYou(numbers[0]),
                ("anniversary", 1) => new Anniversary(numbers[0]),
                ("favorite", 1) => new Favorite(numbers[0]),
                ("unplayed", 0) => new Unplayed(),
                _ => null,
            };
        }
    }

    public sealed record Pick(Kind Kind, string Key, Reason Reason, IReadOnlyList<long> TrackIds);

    /// <summary>Days since 1970-01-01 of a calendar date (Howard Hinnant's algorithm, as on the Mac).</summary>
    public static long DaysFromCivil(long year, long month, long day)
    {
        var y = month <= 2 ? year - 1 : year;
        var era = (y >= 0 ? y : y - 399) / 400;
        var yoe = y - era * 400;
        var doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1;
        var doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146_097 + doe - 719_468;
    }

    /// <summary>The year of a day number.</summary>
    public static long YearOfDay(long days)
    {
        var z = days + 719_468;
        var era = (z >= 0 ? z : z - 146_096) / 146_097;
        var doe = z - era * 146_097;
        var yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        var doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        var mp = (5 * doy + 2) / 153;
        var month = mp + (mp < 10 ? 3 : -9);
        return yoe + era * 400 + (month <= 2 ? 1 : 0);
    }

    /// <summary>Days since 1970 of a moment (UTC) in a time zone: the local calendar day it falls on.</summary>
    public static long DayOf(DateTime utc, TimeZoneInfo? zone = null)
    {
        var moment = DateTime.SpecifyKind(utc, DateTimeKind.Utc);
        var seconds = (long)Math.Floor((moment - DateTime.UnixEpoch).TotalSeconds) + (long)(zone ?? TimeZoneInfo.Local).GetUtcOffset(moment).TotalSeconds;
        return seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400;
    }

    /// <summary><paramref name="value"/> halved every 90 days of <paramref name="age"/> (straight lines in between), in whole numbers.</summary>
    public static long Decayed(long value, long age)
    {
        var halvings = age / 90;
        if (halvings >= 20) return 0;
        var start = value >> (int)halvings;
        return start - start / 2 * (age % 90) / 90;
    }

    /// <summary>The whole number square root (rounded down).</summary>
    public static long SquareRoot(long value)
    {
        if (value <= 0) return 0;
        var x = (long)Math.Sqrt(value);
        while (x * x > value) x--;
        while ((x + 1) * (x + 1) <= value) x++;
        return x;
    }

    /// <summary>Code point order (what the Mac compares too), for lists drawn from to be in the same order everywhere.</summary>
    public static int CompareCodePoints(string a, string b)
    {
        using var left = a.EnumerateRunes().GetEnumerator();
        using var right = b.EnumerateRunes().GetEnumerator();
        while (true)
        {
            var hasLeft = left.MoveNext();
            var hasRight = right.MoveNext();
            if (!hasLeft || !hasRight) return hasLeft ? 1 : hasRight ? -1 : 0;
            var difference = left.Current.Value.CompareTo(right.Current.Value);
            if (difference != 0) return difference;
        }
    }

    /// <summary>The text a day's picks are seeded with.</summary>
    public static string Seed(long today, Kind kind) => $"groovelight|{today}|{Raw(kind)}";

    /// <summary>SplitMix64, seeded from text with FNV-1a: the same numbers on every platform.</summary>
    public sealed class Random
    {
        private ulong state;

        public Random(string seed)
        {
            var hash = 0xcbf29ce484222325UL;
            foreach (var b in Encoding.UTF8.GetBytes(seed))
            {
                hash ^= b;
                hash = unchecked(hash * 0x100000001b3UL);
            }
            state = hash;
        }

        public ulong Next()
        {
            unchecked
            {
                state += 0x9e3779b97f4a7c15UL;
                var z = state;
                z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9UL;
                z = (z ^ (z >> 27)) * 0x94d049bb133111ebUL;
                return z ^ (z >> 31);
            }
        }

        /// <summary>0 up to (not including) <paramref name="bound"/>.</summary>
        public ulong Below(ulong bound) => bound == 0 ? 0 : Next() % bound;

        /// <summary>An index of <paramref name="weights"/> drawn in proportion to them (null when all are 0).</summary>
        public int? Weighted(IReadOnlyList<long> weights)
        {
            var total = weights.Aggregate(0UL, (sum, weight) => sum + (ulong)Math.Max(weight, 0));
            if (total == 0) return null;
            var target = Below(total);
            for (var index = 0; index < weights.Count; index++)
            {
                if (weights[index] <= 0) continue;
                if (target < (ulong)weights[index]) return index;
                target -= (ulong)weights[index];
            }
            return null;
        }
    }

    /// <summary>Each song's standing from the log: plays (recent ones weigh more), loves, ratings, skips, and when it was last heard.</summary>
    public sealed class Taste
    {
        public sealed record Score(long Affinity, long Plays, long Skips, long? LastDay);

        private readonly Dictionary<long, Score> scores = [];

        /// <summary>
        /// Plays a half-life of 90 days apart weigh half as much. Summary rows (play counts from before the log) are left out
        /// for songs with Last.fm history, which has those plays already.
        /// </summary>
        public Taste(IReadOnlyList<Song> songs, IReadOnlyList<Play> plays, long today)
        {
            var withLastFm = plays.Where(play => play.Source == Listen.Sources.LastFm).Select(play => play.TrackId).ToHashSet();
            var weighted = new Dictionary<long, long>();
            foreach (var play in plays)
            {
                if (play.Source == Listen.Sources.Summary && withLastFm.Contains(play.TrackId)) continue;
                var age = Math.Max(today - play.Day, 0);
                var score = scores.GetValueOrDefault(play.TrackId) ?? new Score(0, 0, 0, null);
                if (play.Counted)
                {
                    score = score with { Plays = score.Plays + play.Count, LastDay = Math.Max(score.LastDay ?? play.Day, play.Day) };
                    weighted[play.TrackId] = weighted.GetValueOrDefault(play.TrackId) + Decayed(1000, age) * play.Count;
                }
                else if (play.Skipped)
                {
                    score = score with { Skips = score.Skips + play.Count };
                    weighted[play.TrackId] = weighted.GetValueOrDefault(play.TrackId) - Decayed(400, age) * play.Count;
                }
                scores[play.TrackId] = score;
            }
            foreach (var song in songs)
            {
                var score = scores.GetValueOrDefault(song.Id) ?? new Score(0, 0, 0, null);
                var value = weighted.GetValueOrDefault(song.Id);
                if (song.Loved) value += 3000;
                value += Math.Max(song.Rating - 2, 0) * 1000L;
                scores[song.Id] = score with { Affinity = Math.Max(value, 0) };
            }
        }

        public Score this[long id] => scores.GetValueOrDefault(id) ?? new Score(0, 0, 0, null);
    }
}
