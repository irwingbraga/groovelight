using System.Globalization;
using System.Text;
using System.Xml;
using Microsoft.Data.Sqlite;

namespace Groovelight.Core.Library;

/// <summary>
/// Playlist files of other players: M3U / M3U8, PLS, XSPF, Windows Media Player (WPL) and Music / iTunes XML. Read into
/// entries (a location and whatever the file says about the song), written from library songs.
/// </summary>
public enum PlaylistFormat { M3u8, M3u, Pls, Xspf, Wpl, MusicXml }

public static class PlaylistFormats
{
    /// <summary>Formats a playlist can be saved in (WPL is read only: little else reads it).</summary>
    public static readonly IReadOnlyList<PlaylistFormat> Exportable = [PlaylistFormat.M3u8, PlaylistFormat.M3u, PlaylistFormat.Pls, PlaylistFormat.Xspf, PlaylistFormat.MusicXml];

    /// <summary>Every extension read (ZPL is the Zune variant of WPL).</summary>
    public static readonly IReadOnlySet<string> ReadableExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "m3u8", "m3u", "pls", "xspf", "wpl", "zpl", "xml" };

    public static string FileExtension(this PlaylistFormat format) => format switch
    {
        PlaylistFormat.M3u8 => "m3u8",
        PlaylistFormat.M3u => "m3u",
        PlaylistFormat.Pls => "pls",
        PlaylistFormat.Xspf => "xspf",
        PlaylistFormat.Wpl => "wpl",
        _ => "xml",
    };

    public static string Name(this PlaylistFormat format) => format switch
    {
        PlaylistFormat.M3u8 => "M3U8 (Unicode)",
        PlaylistFormat.M3u => "M3U",
        PlaylistFormat.Pls => "PLS",
        PlaylistFormat.Xspf => "XSPF",
        PlaylistFormat.Wpl => "Windows Media Player",
        _ => "Music / iTunes XML",
    };

    public static PlaylistFormat? FromExtension(string extension) => extension.TrimStart('.').ToLowerInvariant() switch
    {
        "m3u8" => PlaylistFormat.M3u8,
        "m3u" => PlaylistFormat.M3u,
        "pls" => PlaylistFormat.Pls,
        "xspf" => PlaylistFormat.Xspf,
        "wpl" or "zpl" => PlaylistFormat.Wpl,
        "xml" => PlaylistFormat.MusicXml,
        _ => null,
    };
}

/// <summary>One song of a playlist file: where it was, and what the file says about it (used when the path no longer matches).</summary>
public sealed record PlaylistEntry(string? Path = null, string? Title = null, string? Artist = null, string? Album = null, double? Duration = null)
{
    /// <summary>How the entry is described to the user when it is not found.</summary>
    public string Label
    {
        get
        {
            if (!string.IsNullOrEmpty(Title)) return string.Join(" - ", new[] { Artist, Title }.Where(part => !string.IsNullOrEmpty(part)));
            return Path is null ? "Unknown song" : System.IO.Path.GetFileName(Path);
        }
    }
}

/// <summary>A playlist read from a file (a Music XML file can hold several).</summary>
public sealed record PlaylistDocument(string Name, IReadOnlyList<PlaylistEntry> Entries)
{
    public bool Equals(PlaylistDocument? other) => other is not null && Name == other.Name && Entries.SequenceEqual(other.Entries);
    public override int GetHashCode() => HashCode.Combine(Name, Entries.Count);
}

public sealed class PlaylistFileException(string message) : Exception(message)
{
    public static PlaylistFileException Unreadable(string name) => new($"{name} is not a playlist Groovelight can read.");
    public static PlaylistFileException UnknownFormat(string name) => new($"{name} is not a playlist file (M3U, M3U8, PLS, XSPF, WPL or Music XML).");
}

/// <summary>Where songs are written in the file: absolute paths, or paths relative to the playlist's folder.</summary>
public abstract record PlaylistPathStyle
{
    public sealed record Absolute : PlaylistPathStyle;
    public sealed record Relative(string Folder) : PlaylistPathStyle;
}

public static class PlaylistFile
{
    private static readonly bool IsWindows = OperatingSystem.IsWindows();

    static PlaylistFile() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

    // MARK: Reading

    public static List<PlaylistDocument> Read(string path)
    {
        var format = PlaylistFormats.FromExtension(Path.GetExtension(path)) ?? throw PlaylistFileException.UnknownFormat(Path.GetFileName(path));
        return Parse(File.ReadAllBytes(path), format, Path.GetFileNameWithoutExtension(path), Path.GetDirectoryName(Path.GetFullPath(path))!);
    }

    /// <summary><paramref name="name"/> is used when the file has no title of its own; relative locations resolve against <paramref name="folder"/>.</summary>
    public static List<PlaylistDocument> Parse(byte[] data, PlaylistFormat format, string name, string folder)
    {
        var documents = format switch
        {
            PlaylistFormat.M3u8 or PlaylistFormat.M3u => [ParseM3u(Text(data), name, folder)],
            PlaylistFormat.Pls => [ParsePls(Text(data), name, folder)],
            PlaylistFormat.Xspf => [ParseXml(data, name, folder, isWpl: false)],
            PlaylistFormat.Wpl => [ParseXml(data, name, folder, isWpl: true)],
            _ => ParseMusicXml(data, folder),
        };
        if (documents.Count == 0) throw PlaylistFileException.Unreadable(name);
        return documents;
    }

    /// <summary>UTF-8 (with or without a byte order mark), else Windows Latin-1, as older M3U and PLS files are.</summary>
    internal static string Text(byte[] data)
    {
        var start = data is [0xEF, 0xBB, 0xBF, ..] ? 3 : 0;
        try { return new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(data, start, data.Length - start); }
        catch (DecoderFallbackException) { return Encoding.GetEncoding(1252).GetString(data, start, data.Length - start); }
    }

    private static IEnumerable<string> Lines(string text) =>
        text.Split(['\r', '\n', '\u2028', '\u2029', '\u0085'], StringSplitOptions.RemoveEmptyEntries);

    internal static PlaylistDocument ParseM3u(string text, string name, string folder)
    {
        var entries = new List<PlaylistEntry>();
        var pending = new PlaylistEntry();
        foreach (var raw in Lines(text))
        {
            var line = raw.Trim(' ', '\t', '﻿');
            if (line.Length == 0) continue;
            if (line.StartsWith('#'))
            {
                if (line.StartsWith("#EXTINF:", StringComparison.Ordinal))
                {
                    // #EXTINF:<seconds>[ attributes],<artist> - <title>
                    var info = line["#EXTINF:".Length..];
                    var comma = info.IndexOf(',');
                    var head = comma < 0 ? info : info[..comma];
                    var seconds = double.TryParse(head.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault(), NumberStyles.Float, CultureInfo.InvariantCulture, out var value) ? value : (double?)null;
                    pending = pending with { Duration = seconds > 0 ? seconds : null };
                    if (comma >= 0)
                    {
                        var label = info[(comma + 1)..].Trim(' ', '\t');
                        var dash = label.IndexOf(" - ", StringComparison.Ordinal);
                        pending = dash >= 0 ? pending with { Artist = label[..dash], Title = label[(dash + 3)..] } : pending with { Title = label };
                    }
                }
                else if (line.StartsWith("#EXTALB:", StringComparison.Ordinal))
                {
                    pending = pending with { Album = line["#EXTALB:".Length..].Trim(' ', '\t') };
                }
                else if (line.StartsWith("#EXTART:", StringComparison.Ordinal))
                {
                    pending = pending with { Artist = line["#EXTART:".Length..].Trim(' ', '\t') };
                }
                else if (line.StartsWith("#PLAYLIST:", StringComparison.Ordinal))
                {
                    var title = line["#PLAYLIST:".Length..].Trim(' ', '\t');
                    if (title.Length > 0) name = title;
                }
                continue;
            }
            entries.Add(pending with { Path = Resolve(line, folder) });
            pending = new PlaylistEntry();
        }
        return new PlaylistDocument(name, entries);
    }

    internal static PlaylistDocument ParsePls(string text, string name, string folder)
    {
        var files = new SortedDictionary<int, PlaylistEntry>();
        foreach (var raw in Lines(text))
        {
            var line = raw.Trim(' ', '\t');
            var equals = line.IndexOf('=');
            if (equals < 0) continue;
            var key = line[..equals].ToLowerInvariant();
            var value = line[(equals + 1)..];
            foreach (var (prefix, apply) in new (string, Func<PlaylistEntry, PlaylistEntry>)[]
            {
                ("file", entry => entry with { Path = Resolve(value, folder) }),
                ("title", entry => entry with { Title = value }),
                ("length", entry => entry with { Duration = double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds) && seconds > 0 ? seconds : null }),
            })
            {
                if (key.StartsWith(prefix, StringComparison.Ordinal) && int.TryParse(key[prefix.Length..], out var number))
                    files[number] = apply(files.GetValueOrDefault(number) ?? new PlaylistEntry());
            }
        }
        // A title written as "Artist - Title", as most players do.
        var entries = files.Values.Where(entry => entry.Path is not null).Select(entry =>
        {
            if (entry.Title is { } title && title.IndexOf(" - ", StringComparison.Ordinal) is var dash and >= 0)
                return entry with { Artist = title[..dash], Title = title[(dash + 3)..] };
            return entry;
        }).ToList();
        return new PlaylistDocument(name, entries);
    }

    /// <summary>XSPF and WPL, both XML.</summary>
    private static PlaylistDocument ParseXml(byte[] data, string name, string folder, bool isWpl)
    {
        var entries = new List<PlaylistEntry>();
        try
        {
            var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore, XmlResolver = null };
            using var reader = XmlReader.Create(new MemoryStream(data), settings);
            var stack = new List<string>();
            PlaylistEntry? entry = null;
            var text = new StringBuilder();
            while (reader.Read())
            {
                switch (reader.NodeType)
                {
                    case XmlNodeType.Element:
                    {
                        var element = reader.LocalName.ToLowerInvariant();
                        text.Clear();
                        if (isWpl && element == "media" && reader.GetAttribute("src") is { } source)
                            entries.Add(new PlaylistEntry(Resolve(source, folder)));
                        else if (!isWpl && element == "track")
                            entry = new PlaylistEntry();
                        if (!reader.IsEmptyElement) stack.Add(element);
                        break;
                    }
                    case XmlNodeType.Text or XmlNodeType.CDATA or XmlNodeType.SignificantWhitespace:
                        text.Append(reader.Value);
                        break;
                    case XmlNodeType.EndElement:
                    {
                        var element = reader.LocalName.ToLowerInvariant();
                        if (stack.Count > 0) stack.RemoveAt(stack.Count - 1);
                        var value = text.ToString().Trim();
                        text.Clear();
                        // The playlist's own title: directly under <playlist> (XSPF) or <head> (WPL), not a song's.
                        if (element == "title" && entry is null && value.Length > 0 && stack.LastOrDefault() == (isWpl ? "head" : "playlist"))
                        {
                            name = value;
                            break;
                        }
                        if (isWpl || entry is null) break;
                        switch (element)
                        {
                            case "location" when entry.Path is null:
                                // A URI: relative ones are percent-encoded too.
                                var location = value.StartsWith("file:", StringComparison.OrdinalIgnoreCase) ? value : Uri.UnescapeDataString(value);
                                entry = entry with { Path = Resolve(location, folder) };
                                break;
                            case "title": entry = entry with { Title = value }; break;
                            case "creator": entry = entry with { Artist = value }; break;
                            case "album": entry = entry with { Album = value }; break;
                            case "duration":
                                entry = entry with { Duration = double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var milliseconds) ? milliseconds / 1000 : null };
                                break;
                            case "track":
                                entries.Add(entry);
                                entry = null;
                                break;
                        }
                        break;
                    }
                }
            }
        }
        catch (XmlException)
        {
            throw PlaylistFileException.Unreadable(name);
        }
        return new PlaylistDocument(name, entries);
    }

    internal static List<PlaylistDocument> ParseMusicXml(byte[] data, string folder)
    {
        Dictionary<string, object?>? plist;
        try { plist = PropertyList.Parse(data) as Dictionary<string, object?>; }
        catch (Exception exception) when (exception is XmlException or FormatException) { plist = null; }
        if (plist?.GetValueOrDefault("Playlists") is not List<object?> playlists) throw PlaylistFileException.Unreadable("The XML file");
        var tracks = plist.GetValueOrDefault("Tracks") as Dictionary<string, object?> ?? [];
        var documents = new List<PlaylistDocument>();
        foreach (var item in playlists.OfType<Dictionary<string, object?>>())
        {
            // The library itself, Music's built-in lists (Music, Movies, Downloaded...) and folders are left out.
            if (item.GetValueOrDefault("Master") is true || item.ContainsKey("Distinguished Kind") || item.GetValueOrDefault("Folder") is true
                || item.GetValueOrDefault("Visible") is false) continue;
            var entries = new List<PlaylistEntry>();
            foreach (var reference in (item.GetValueOrDefault("Playlist Items") as List<object?> ?? []).OfType<Dictionary<string, object?>>())
            {
                if (reference.GetValueOrDefault("Track ID") is not { } id
                    || tracks.GetValueOrDefault(Convert.ToString(id, CultureInfo.InvariantCulture)!) is not Dictionary<string, object?> track) continue;
                entries.Add(new PlaylistEntry(
                    track.GetValueOrDefault("Location") is string location ? Resolve(location, folder) : null,
                    track.GetValueOrDefault("Name") as string, track.GetValueOrDefault("Artist") as string, track.GetValueOrDefault("Album") as string,
                    track.GetValueOrDefault("Total Time") is long milliseconds ? milliseconds / 1000.0 : null));
            }
            documents.Add(new PlaylistDocument(item.GetValueOrDefault("Name") as string ?? "Playlist", entries));
        }
        return documents;
    }

    /// <summary>
    /// A full path from a file URL, an absolute path or a path relative to the playlist (either separator). Null for
    /// web addresses, and for drive-letter paths off Windows (they cannot point into a Mac's library).
    /// </summary>
    internal static string? Resolve(string location, string folder)
    {
        location = location.Trim(' ', '\t');
        if (location.Length == 0) return null;
        try
        {
            if (location.StartsWith("file:", StringComparison.OrdinalIgnoreCase))
                return Uri.TryCreate(location, UriKind.Absolute, out var uri) && uri.IsFile ? Path.GetFullPath(uri.LocalPath) : null;
            if (location.Contains("://", StringComparison.Ordinal)) return null;
            var hasDrive = location.Length > 1 && location[1] == ':';
            if (hasDrive && !IsWindows) return null;
            var path = IsWindows ? location.Replace('/', '\\') : location.Replace('\\', '/');
            return Path.GetFullPath(Path.IsPathRooted(path) ? path : Path.Combine(folder, path));
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return null;
        }
    }

    // MARK: Writing

    public static byte[] Write(string name, IReadOnlyList<Track> tracks, PlaylistFormat format, PlaylistPathStyle? paths = null)
    {
        paths ??= new PlaylistPathStyle.Absolute();
        switch (format)
        {
            case PlaylistFormat.M3u8 or PlaylistFormat.M3u or PlaylistFormat.Wpl:
            {
                var lines = new List<string> { "#EXTM3U", $"#PLAYLIST:{name}" };
                foreach (var track in tracks)
                {
                    lines.Add($"#EXTINF:{(int)Math.Round(track.Duration)},{Label(track)}");
                    if (track.Album is { } album) lines.Add($"#EXTALB:{album}");
                    lines.Add(Location(track, paths));
                }
                var text = string.Join("\n", lines) + "\n";
                // Plain M3U is read as Windows Latin-1 by older players: kept to it when every character fits.
                if (format == PlaylistFormat.M3u)
                {
                    var latin = Encoding.GetEncoding(1252, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback);
                    try { return latin.GetBytes(text); } catch (EncoderFallbackException) { }
                }
                return Encoding.UTF8.GetBytes(text);
            }
            case PlaylistFormat.Pls:
            {
                var lines = new List<string> { "[playlist]" };
                for (var index = 0; index < tracks.Count; index++)
                {
                    var number = index + 1;
                    lines.Add($"File{number}={Location(tracks[index], paths)}");
                    lines.Add($"Title{number}={Label(tracks[index])}");
                    lines.Add($"Length{number}={(int)Math.Round(tracks[index].Duration)}");
                }
                lines.Add($"NumberOfEntries={tracks.Count}");
                lines.Add("Version=2");
                return Encoding.UTF8.GetBytes(string.Join("\n", lines) + "\n");
            }
            case PlaylistFormat.Xspf:
            {
                var xml = new StringBuilder();
                xml.Append($"""
                    <?xml version="1.0" encoding="UTF-8"?>
                    <playlist version="1" xmlns="http://xspf.org/ns/0/">
                      <title>{Escape(name)}</title>
                      <trackList>

                    """);
                foreach (var track in tracks)
                {
                    xml.Append("    <track>\n");
                    xml.Append($"      <location>{Escape(UriOf(track, paths))}</location>\n");
                    xml.Append($"      <title>{Escape(track.Title)}</title>\n");
                    if (track.Artist is { } artist) xml.Append($"      <creator>{Escape(artist)}</creator>\n");
                    if (track.Album is { } album) xml.Append($"      <album>{Escape(album)}</album>\n");
                    xml.Append($"      <duration>{(long)Math.Round(track.Duration * 1000)}</duration>\n");
                    xml.Append("    </track>\n");
                }
                xml.Append("  </trackList>\n</playlist>\n");
                return Encoding.UTF8.GetBytes(xml.ToString());
            }
            default:
                return MusicXml(name, tracks);
        }
    }

    /// <summary>A playlist as Music exports it (File > Library > Export Playlist), which Music and iTunes import back.</summary>
    internal static byte[] MusicXml(string name, IReadOnlyList<Track> tracks)
    {
        var table = new Dictionary<string, object?>();
        var items = new List<object?>();
        for (var index = 0; index < tracks.Count; index++)
        {
            var track = tracks[index];
            var id = track.Id ?? index + 1;
            var info = new Dictionary<string, object?>
            {
                ["Track ID"] = id, ["Name"] = track.Title, ["Total Time"] = (long)Math.Round(track.Duration * 1000),
                ["Location"] = new Uri(track.FilePath).AbsoluteUri, ["Kind"] = $"{track.Format ?? "Audio"} audio file",
            };
            if (track.Artist is { } artist) info["Artist"] = artist;
            if (track.Album is { } album) info["Album"] = album;
            if (track.AlbumArtist is { } albumArtist) info["Album Artist"] = albumArtist;
            if (track.Genre is { } genre) info["Genre"] = genre;
            if (track.Year is { } year) info["Year"] = (long)year;
            if (track.TrackNumber is { } number) info["Track Number"] = (long)number;
            if (track.DiscNumber is { } disc) info["Disc Number"] = (long)disc;
            table[id.ToString(CultureInfo.InvariantCulture)] = info;
            items.Add(new Dictionary<string, object?> { ["Track ID"] = id });
        }
        return PropertyList.Write(new Dictionary<string, object?>
        {
            ["Major Version"] = 1L, ["Minor Version"] = 1L, ["Application Version"] = "Groovelight", ["Date"] = DateTime.UtcNow,
            ["Tracks"] = table,
            ["Playlists"] = new List<object?> { new Dictionary<string, object?> { ["Name"] = name, ["Playlist ID"] = 1L, ["All Items"] = true, ["Playlist Items"] = items } },
        });
    }

    /// <summary>"Artist - Title", what M3U and PLS players show.</summary>
    private static string Label(Track track) => string.Join(" - ", new[] { track.Artist, track.Title }.Where(part => !string.IsNullOrEmpty(part)));

    /// <summary>The song's audio file (for a CUE track, the file holding the album: the entry's title tells the songs apart).</summary>
    private static string Location(Track track, PlaylistPathStyle paths) =>
        paths is PlaylistPathStyle.Relative relative ? RelativePath(track.FilePath, Path.GetFullPath(relative.Folder)) : track.FilePath;

    private static string UriOf(Track track, PlaylistPathStyle paths)
    {
        if (paths is not PlaylistPathStyle.Relative relative) return new Uri(track.FilePath).AbsoluteUri;
        var path = RelativePath(track.FilePath, Path.GetFullPath(relative.Folder));
        if (Path.IsPathRooted(path)) return new Uri(path).AbsoluteUri;
        return string.Join("/", path.Split(Path.DirectorySeparatorChar).Select(Uri.EscapeDataString));
    }

    /// <summary><paramref name="path"/> as seen from <paramref name="folder"/>, with ".." steps (absolute when they share nothing but the root).</summary>
    internal static string RelativePath(string path, string folder)
    {
        var separator = Path.DirectorySeparatorChar;
        var comparison = IsWindows ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var target = path.Split(separator, StringSplitOptions.RemoveEmptyEntries);
        var base_ = folder.Split(separator, StringSplitOptions.RemoveEmptyEntries);
        var common = 0;
        while (common < Math.Min(target.Length, base_.Length) && string.Equals(target[common], base_[common], comparison)) common++;
        // Nothing shared, or (on Windows) only the drive: absolute.
        if (common == 0 || (IsWindows && common == 1 && base_.Length > 0 && base_[0].EndsWith(':'))) return path;
        return string.Join(separator, Enumerable.Repeat("..", base_.Length - common).Concat(target[common..]));
    }

    private static string Escape(string text) =>
        text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");

    // MARK: Matching entries to library songs

    /// <summary>
    /// The library song for each entry (null when none fits): by path first (for a CUE album file, the track whose title
    /// matches), then by title and artist, preferring the same album and a close length.
    /// </summary>
    public static List<long?> MatchPlaylistEntries(this SqliteConnection db, IReadOnlyList<PlaylistEntry> entries)
    {
        // Windows paths are case-insensitive.
        var collate = IsWindows ? " COLLATE NOCASE" : "";
        var results = new List<long?>();
        foreach (var entry in entries)
        {
            results.Add(Match(entry));
        }
        return results;

        long? Match(PlaylistEntry entry)
        {
            if (entry.Path is { } path)
            {
                foreach (var candidate in PathVariants(path))
                {
                    if (db.Scalar<long?>($"SELECT id FROM track WHERE path = ?{collate}", candidate) is { } id) return id;
                    var cueTracks = db.FetchTracks($"SELECT * FROM track WHERE audioPath = ?{collate} ORDER BY startTime", candidate);
                    if (cueTracks.Count > 0) return (cueTracks.FirstOrDefault(track => Fold(track.Title) == Fold(entry.Title)) ?? cueTracks[0]).Id;
                }
            }
            if (string.IsNullOrEmpty(entry.Title)) return null;
            var candidates = db.FetchTracks("SELECT * FROM track WHERE title = ? COLLATE NOCASE", entry.Title);
            var fitting = candidates.Where(track => string.IsNullOrEmpty(entry.Artist)
                || Fold(track.Artist) == Fold(entry.Artist) || Fold(track.AlbumArtist) == Fold(entry.Artist)).ToList();
            return fitting.Count == 0 ? null : fitting.MaxBy(track => Score(track, entry))!.Id;
        }
    }

    /// <summary>The path as written, precomposed and decomposed (systems disagree on accents), and fully resolved.</summary>
    private static IEnumerable<string> PathVariants(string path)
    {
        string[] variants = [path, path.Normalize(NormalizationForm.FormC), path.Normalize(NormalizationForm.FormD), Resolved(path)];
        return variants.Distinct();

        static string Resolved(string path)
        {
            try { return new FileInfo(path).ResolveLinkTarget(returnFinalTarget: true)?.FullName ?? Path.GetFullPath(path); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException) { return path; }
        }
    }

    private static string Fold(string? text) => Groovelight.Core.Text.Fold(text ?? "").Trim(' ', '\t');

    private static int Score(Track track, PlaylistEntry entry)
    {
        var score = 0;
        if (entry.Album is { } album && Fold(track.Album) == Fold(album)) score += 2;
        if (entry.Duration is { } duration && Math.Abs(track.Duration - duration) <= 3) score += 1;
        return score;
    }
}
