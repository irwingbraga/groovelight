using System.Text.Json.Serialization;
using Microsoft.Data.Sqlite;

namespace Groovelight.Core.Library;

/// <summary>
/// Rules of a smart playlist, stored as JSON in <c>playlist.smartRules</c> (the Mac's format). Evaluated as SQL, so the
/// playlist stays current as the library changes.
/// </summary>
public sealed record SmartPlaylistRules
{
    public SmartMatch Match { get; set; } = SmartMatch.All;
    public List<SmartRule> Rules { get; set; } = [new SmartRule()];
    public SmartLimit? Limit { get; set; }
}

public enum SmartMatch { All, Any }

public enum SmartFieldKind { Text, Number, Date, Bool, Quality }

public enum SmartField
{
    Title, Artist, Album, AlbumArtist, Composer, Genre, Comment, Kind,
    Year, Rating, Plays, Skips, Time, Bitrate, SampleRate, BitDepth, Bpm,
    DateAdded, LastPlayed,
    Loved, Compilation, HasArtwork, HasLyrics,
    Quality,
}

public enum SmartOperator
{
    Contains, DoesNotContain, Is, IsNot, BeginsWith, EndsWith,
    GreaterThan, LessThan, InRange,
    InTheLast, NotInTheLast, IsBefore, IsAfter,
    IsTrue, IsFalse,
    IsAtLeast,
}

public enum PeriodUnit { Days, Weeks, Months }

public static class SmartFields
{
    public static SmartFieldKind KindOf(this SmartField field) => field switch
    {
        SmartField.Title or SmartField.Artist or SmartField.Album or SmartField.AlbumArtist or SmartField.Composer
            or SmartField.Genre or SmartField.Comment or SmartField.Kind => SmartFieldKind.Text,
        SmartField.Year or SmartField.Rating or SmartField.Plays or SmartField.Skips or SmartField.Time or SmartField.Bitrate
            or SmartField.SampleRate or SmartField.BitDepth or SmartField.Bpm => SmartFieldKind.Number,
        SmartField.DateAdded or SmartField.LastPlayed => SmartFieldKind.Date,
        SmartField.Loved or SmartField.Compilation or SmartField.HasArtwork or SmartField.HasLyrics => SmartFieldKind.Bool,
        _ => SmartFieldKind.Quality,
    };

    public static string DisplayName(this SmartField field) => field switch
    {
        SmartField.Title => "Title",
        SmartField.Artist => "Artist",
        SmartField.Album => "Album",
        SmartField.AlbumArtist => "Album Artist",
        SmartField.Composer => "Composer",
        SmartField.Genre => "Genre",
        SmartField.Comment => "Comments",
        SmartField.Kind => "Format",
        SmartField.Year => "Year",
        SmartField.Rating => "Rating",
        SmartField.Plays => "Plays",
        SmartField.Skips => "Skips",
        SmartField.Time => "Time",
        SmartField.Bitrate => "Bit Rate",
        SmartField.SampleRate => "Sample Rate",
        SmartField.BitDepth => "Bit Depth",
        SmartField.Bpm => "BPM",
        SmartField.DateAdded => "Date Added",
        SmartField.LastPlayed => "Last Played",
        SmartField.Loved => "Loved",
        SmartField.Compilation => "Compilation",
        SmartField.HasArtwork => "Has Artwork",
        SmartField.HasLyrics => "Has Lyrics",
        _ => "Quality",
    };

    /// <summary>Unit shown after a number value; values are entered in this unit.</summary>
    public static string? Unit(this SmartField field) => field switch
    {
        SmartField.Time => "minutes",
        SmartField.Bitrate => "kbps",
        SmartField.SampleRate => "kHz",
        SmartField.BitDepth => "bit",
        SmartField.Rating => "stars",
        _ => null,
    };

    /// <summary>Multiplier from the entered unit to the stored value (minutes to seconds, kHz to Hz).</summary>
    internal static double Scale(this SmartField field) => field switch
    {
        SmartField.Time => 60,
        SmartField.SampleRate => 1000,
        _ => 1,
    };

    /// <summary>SQL expression over the track table. Only fixed strings: values are always bound as arguments.</summary>
    internal static string Sql(this SmartField field) => field switch
    {
        SmartField.Title => "title",
        SmartField.Artist => "COALESCE(artist, '')",
        SmartField.Album => "COALESCE(album, '')",
        SmartField.AlbumArtist => "COALESCE(NULLIF(albumArtist, ''), artist, '')",
        SmartField.Composer => "COALESCE(composer, '')",
        SmartField.Genre => "COALESCE(genre, '')",
        SmartField.Comment => "COALESCE(comment, '')",
        SmartField.Kind => "COALESCE(format, '')",
        SmartField.Year => "year",
        SmartField.Rating => "rating",
        SmartField.Plays => "playCount",
        SmartField.Skips => "skipCount",
        SmartField.Time => "duration",
        SmartField.Bitrate => "bitrate",
        SmartField.SampleRate => "sampleRate",
        SmartField.BitDepth => "bitDepth",
        SmartField.Bpm => "bpm",
        SmartField.DateAdded => "dateAdded",
        SmartField.LastPlayed => "lastPlayedAt",
        SmartField.Loved => "isLoved",
        SmartField.Compilation => "isCompilation",
        SmartField.HasArtwork => "(artworkHash IS NOT NULL)",
        SmartField.HasLyrics => "(COALESCE(lyrics, '') != '' OR COALESCE(fetchedLyrics, '') != '')",
        _ => $"{SmartPlaylistSql.QualityFunction}(format, sampleRate, bitDepth, bitrate)",
    };

    public static IReadOnlyList<SmartOperator> Operators(SmartFieldKind kind) => kind switch
    {
        SmartFieldKind.Text => [SmartOperator.Contains, SmartOperator.DoesNotContain, SmartOperator.Is, SmartOperator.IsNot, SmartOperator.BeginsWith, SmartOperator.EndsWith],
        SmartFieldKind.Number => [SmartOperator.Is, SmartOperator.IsNot, SmartOperator.GreaterThan, SmartOperator.LessThan, SmartOperator.InRange],
        SmartFieldKind.Date => [SmartOperator.InTheLast, SmartOperator.NotInTheLast, SmartOperator.IsAfter, SmartOperator.IsBefore],
        SmartFieldKind.Bool => [SmartOperator.IsTrue, SmartOperator.IsFalse],
        _ => [SmartOperator.Is, SmartOperator.IsNot, SmartOperator.IsAtLeast],
    };

    public static string DisplayName(this SmartOperator op) => op switch
    {
        SmartOperator.Contains => "contains",
        SmartOperator.DoesNotContain => "does not contain",
        SmartOperator.Is => "is",
        SmartOperator.IsNot => "is not",
        SmartOperator.BeginsWith => "begins with",
        SmartOperator.EndsWith => "ends with",
        SmartOperator.GreaterThan => "is greater than",
        SmartOperator.LessThan => "is less than",
        SmartOperator.InRange => "is in the range",
        SmartOperator.InTheLast => "is in the last",
        SmartOperator.NotInTheLast => "is not in the last",
        SmartOperator.IsBefore => "is before",
        SmartOperator.IsAfter => "is after",
        SmartOperator.IsTrue => "is true",
        SmartOperator.IsFalse => "is false",
        _ => "is at least",
    };

    internal static int Days(this PeriodUnit unit) => unit switch
    {
        PeriodUnit.Days => 1,
        PeriodUnit.Weeks => 7,
        _ => 30,
    };
}

/// <summary>One condition. Every value kind is stored so switching the field or operator in the editor keeps what was typed.</summary>
public sealed record SmartRule
{
    /// <summary>A UUID, upper case as Swift writes it.</summary>
    public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public SmartField Field { get; set; } = SmartField.Artist;
    public SmartOperator Op { get; set; } = SmartOperator.Contains;
    public string Text { get; set; } = "";
    public double Number { get; set; }
    /// <summary>Upper bound for <see cref="SmartOperator.InRange"/>.</summary>
    public double Number2 { get; set; }
    public DateTime Date { get; set; } = DateTime.UtcNow;
    public int Period { get; set; } = 2;
    public PeriodUnit PeriodUnit { get; set; } = PeriodUnit.Weeks;
    /// <summary>Stored as its number, as Swift encodes the Int-backed enum.</summary>
    [JsonConverter(typeof(JsonNumberEnumConverter<QualityTier>))]
    public QualityTier Quality { get; set; } = QualityTier.Lossless;

    /// <summary>Changes the field, keeping the operator when the new field supports it.</summary>
    public void SetField(SmartField field)
    {
        Field = field;
        var allowed = SmartFields.Operators(field.KindOf());
        if (!allowed.Contains(Op)) Op = allowed[0];
    }
}

public enum SmartLimitUnit { Songs, Minutes, Hours, Megabytes, Gigabytes }

public enum SmartLimitSelection
{
    Random, Title, Album, Artist, Genre,
    HighestRated, LowestRated, MostPlayed, LeastPlayed,
    MostRecentlyPlayed, LeastRecentlyPlayed, MostRecentlyAdded, LeastRecentlyAdded,
}

public static class SmartLimits
{
    public static string DisplayName(this SmartLimitUnit unit) => unit switch
    {
        SmartLimitUnit.Songs => "songs",
        SmartLimitUnit.Minutes => "minutes",
        SmartLimitUnit.Hours => "hours",
        SmartLimitUnit.Megabytes => "MB",
        _ => "GB",
    };

    public static string DisplayName(this SmartLimitSelection selection) => selection switch
    {
        SmartLimitSelection.Random => "random",
        SmartLimitSelection.Title => "title",
        SmartLimitSelection.Album => "album",
        SmartLimitSelection.Artist => "artist",
        SmartLimitSelection.Genre => "genre",
        SmartLimitSelection.HighestRated => "highest rating",
        SmartLimitSelection.LowestRated => "lowest rating",
        SmartLimitSelection.MostPlayed => "most played",
        SmartLimitSelection.LeastPlayed => "least played",
        SmartLimitSelection.MostRecentlyPlayed => "most recently played",
        SmartLimitSelection.LeastRecentlyPlayed => "least recently played",
        SmartLimitSelection.MostRecentlyAdded => "most recently added",
        _ => "least recently added",
    };
}

public sealed record SmartLimit
{
    public int Count { get; set; } = 25;
    public SmartLimitUnit Unit { get; set; } = SmartLimitUnit.Songs;
    public SmartLimitSelection SelectedBy { get; set; } = SmartLimitSelection.Random;
    /// <summary>Seed for random: a stable shuffle, so the playlist does not reshuffle every time a play count changes.</summary>
    public int Seed { get; set; } = Random.Shared.Next(1, 1_000_001);

    internal string OrderSql() => SelectedBy switch
    {
        // Multiplicative hash of the id: a fixed pseudo-random order per seed.
        SmartLimitSelection.Random => $"((id + {Seed}) * 2654435761) % 4294967291",
        SmartLimitSelection.Title => "title COLLATE NOCASE",
        SmartLimitSelection.Album => "album COLLATE NOCASE, discNumber, trackNumber",
        SmartLimitSelection.Artist => "artist COLLATE NOCASE, album COLLATE NOCASE, discNumber, trackNumber",
        SmartLimitSelection.Genre => "genre COLLATE NOCASE, artist COLLATE NOCASE",
        SmartLimitSelection.HighestRated => "rating DESC, playCount DESC",
        SmartLimitSelection.LowestRated => "rating, playCount",
        SmartLimitSelection.MostPlayed => "playCount DESC, lastPlayedAt DESC",
        SmartLimitSelection.LeastPlayed => "playCount, lastPlayedAt",
        SmartLimitSelection.MostRecentlyPlayed => "lastPlayedAt IS NULL, lastPlayedAt DESC",
        SmartLimitSelection.LeastRecentlyPlayed => "lastPlayedAt IS NOT NULL, lastPlayedAt",
        SmartLimitSelection.MostRecentlyAdded => "dateAdded DESC",
        _ => "dateAdded",
    };

    /// <summary>Size of a track in the limit's unit.</summary>
    internal double SizeOf(Track track) => Unit switch
    {
        SmartLimitUnit.Songs => 1,
        SmartLimitUnit.Minutes => track.Duration / 60,
        SmartLimitUnit.Hours => track.Duration / 3600,
        SmartLimitUnit.Megabytes => track.FileSize / 1_000_000.0,
        _ => track.FileSize / 1_000_000_000.0,
    };
}

public static class SmartPlaylistSql
{
    internal const string QualityFunction = "glQualityTier";

    /// <summary><c>glQualityTier(format, sampleRate, bitDepth, bitrate)</c>: the tier's number, so smart playlists agree with the badges.</summary>
    internal static void RegisterFunctions(SqliteConnection connection) =>
        connection.CreateFunction<string?, double?, long?, double?, long>(QualityFunction,
            (format, sampleRate, bitDepth, bitrate) => (long)new AudioSpec(format, sampleRate, (int?)bitDepth, bitrate, null).Tier,
            isDeterministic: true);

    /// <summary>WHERE clause and arguments for the rules (an empty rule list matches every track).</summary>
    internal static (string Sql, List<object?> Arguments) WhereClause(SmartPlaylistRules rules, DateTime now)
    {
        var arguments = new List<object?>();
        var parts = rules.Rules.Select(rule => Condition(rule, now, arguments)).ToList();
        if (parts.Count == 0) return ("1", arguments);
        var joiner = rules.Match == SmartMatch.All ? " AND " : " OR ";
        return (string.Join(joiner, parts.Select(part => $"({part})")), arguments);
    }

    internal static string Condition(SmartRule rule, DateTime now, List<object?> arguments)
    {
        var column = rule.Field.Sql();
        string Bind(object? value)
        {
            arguments.Add(value);
            return "?";
        }
        string Like(string pattern) => $"{column} LIKE {Bind(pattern)} ESCAPE '\\'";
        var escaped = rule.Text.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_");

        switch (rule.Field.KindOf(), rule.Op)
        {
            case (SmartFieldKind.Text, SmartOperator.Contains): return Like($"%{escaped}%");
            case (SmartFieldKind.Text, SmartOperator.DoesNotContain): return $"NOT ({Like($"%{escaped}%")})";
            case (SmartFieldKind.Text, SmartOperator.Is): return $"{column} = {Bind(rule.Text)} COLLATE NOCASE";
            case (SmartFieldKind.Text, SmartOperator.IsNot): return $"{column} != {Bind(rule.Text)} COLLATE NOCASE";
            case (SmartFieldKind.Text, SmartOperator.BeginsWith): return Like($"{escaped}%");
            case (SmartFieldKind.Text, SmartOperator.EndsWith): return Like($"%{escaped}");

            case (SmartFieldKind.Number, var op):
            {
                var value = rule.Number * rule.Field.Scale();
                var upper = rule.Number2 * rule.Field.Scale();
                // Whole units compare with a tolerance (a 3:59.6 song "is 4 minutes"; 44.1 kHz).
                var tolerance = rule.Field == SmartField.Time ? 30.0 : rule.Field == SmartField.Bitrate ? 2 : 0.001;
                return op switch
                {
                    SmartOperator.Is => $"{column} BETWEEN {Bind(value - tolerance)} AND {Bind(value + tolerance)}",
                    SmartOperator.IsNot => $"COALESCE({column} NOT BETWEEN {Bind(value - tolerance)} AND {Bind(value + tolerance)}, 1)",
                    SmartOperator.GreaterThan => $"{column} > {Bind(value)}",
                    SmartOperator.LessThan => $"COALESCE({column}, 0) < {Bind(value)}",
                    SmartOperator.InRange => $"{column} BETWEEN {Bind(Math.Min(value, upper) - tolerance)} AND {Bind(Math.Max(value, upper) + tolerance)}",
                    _ => "1",
                };
            }

            case (SmartFieldKind.Date, var op):
                switch (op)
                {
                    case SmartOperator.InTheLast or SmartOperator.NotInTheLast:
                        var since = now.AddDays(-rule.Period * rule.PeriodUnit.Days());
                        return op == SmartOperator.InTheLast ? $"{column} >= {Bind(since)}" : $"({column} IS NULL OR {column} < {Bind(since)})";
                    case SmartOperator.IsAfter:
                        return $"{column} >= {Bind(StartOfLocalDay(rule.Date).AddDays(1))}";
                    case SmartOperator.IsBefore:
                        return $"{column} < {Bind(StartOfLocalDay(rule.Date))}";
                    default:
                        return "1";
                }

            case (SmartFieldKind.Bool, SmartOperator.IsTrue): return $"{column} = 1";
            case (SmartFieldKind.Bool, SmartOperator.IsFalse): return $"{column} = 0";

            case (SmartFieldKind.Quality, SmartOperator.Is): return $"{column} = {Bind((long)rule.Quality)}";
            case (SmartFieldKind.Quality, SmartOperator.IsNot): return $"{column} != {Bind((long)rule.Quality)}";
            // Tiers are ordered standard, high quality, lossless, Hi-Res, DSD: "at least Lossless" includes Hi-Res and DSD.
            case (SmartFieldKind.Quality, SmartOperator.IsAtLeast): return $"{column} >= {Bind((long)rule.Quality)}";

            default: return "1";
        }
    }

    /// <summary>The start of the date's day in local time (Calendar.current.startOfDay on the Mac), as UTC.</summary>
    private static DateTime StartOfLocalDay(DateTime date) => date.ToLocalTime().Date.ToUniversalTime();
}

public static class SmartPlaylistQueries
{
    /// <summary>
    /// Tracks matching smart playlist rules: ordered by the limit's selection when there is a limit, otherwise like an
    /// album list (artist, album, disc, track).
    /// </summary>
    public static List<Track> TracksMatching(this SqliteConnection db, SmartPlaylistRules rules, DateTime? now = null)
    {
        var (whereSql, arguments) = SmartPlaylistSql.WhereClause(rules, now ?? DateTime.UtcNow);
        const string defaultOrder = "COALESCE(NULLIF(albumArtist, ''), artist) COLLATE NOCASE, album COLLATE NOCASE, discNumber, trackNumber, title COLLATE NOCASE";
        if (rules.Limit is not { } limit)
            return db.FetchTracks($"SELECT * FROM track WHERE {whereSql} ORDER BY {defaultOrder}", [.. arguments]);
        var ordered = db.FetchTracks($"SELECT * FROM track WHERE {whereSql} ORDER BY {limit.OrderSql()}, id", [.. arguments]);
        if (limit.Unit == SmartLimitUnit.Songs) return ordered.Take(Math.Max(limit.Count, 0)).ToList();
        var total = 0.0;
        var result = new List<Track>();
        foreach (var track in ordered)
        {
            var size = limit.SizeOf(track);
            if (total + size > limit.Count) break;
            total += size;
            result.Add(track);
        }
        return result;
    }
}

public sealed partial class LibraryDatabase
{
    public Playlist CreateSmartPlaylist(string name, SmartPlaylistRules rules, PlaylistCover? cover = null) => Write(db =>
    {
        var playlist = new Playlist { Name = name, SmartRules = SwiftJson.Encode(rules), Cover = cover is null ? null : SwiftJson.Encode(cover) };
        db.Insert(playlist);
        return playlist;
    });

    public void UpdateSmartPlaylist(long playlistId, string name, SmartPlaylistRules rules) =>
        Write(db => db.Execute("UPDATE playlist SET name = ?, smartRules = ? WHERE id = ?", name, SwiftJson.Encode(rules), playlistId));
}
