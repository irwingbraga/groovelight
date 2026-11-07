using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Groovelight.Core.Library;
using Microsoft.Data.Sqlite;

namespace Groovelight.Core.Devices;

/// <summary>
/// JSON as the Mac's wireless protocol and device manifests write it: camelCase keys, nil values left out, dates in ISO
/// 8601 without fractions (Swift's <c>.iso8601</c> strategy rejects them).
/// </summary>
public static class WireJson
{
    public static readonly JsonSerializerOptions Options = Create();

    private static JsonSerializerOptions Create()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            NumberHandling = JsonNumberHandling.AllowReadingFromString,
        };
        options.Converters.Add(new Iso8601DateConverter());
        options.Converters.Add(new LossyEncodingConverter());
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        return options;
    }

    public static byte[] Encode<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, Options);

    public static T? Decode<T>(ReadOnlySpan<byte> data)
    {
        try { return JsonSerializer.Deserialize<T>(data, Options); }
        catch (JsonException) { return default; }
    }
}

public sealed class Iso8601DateConverter : JsonConverter<DateTime>
{
    public override DateTime Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        DateTime.Parse(reader.GetString()!, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal);

    public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture));
}

public static class CodecNames
{
    /// <summary>The codec's name in the protocol (the Mac's <c>AudioSpec.Codec</c> raw value).</summary>
    public static string RawValue(this Codec codec) => codec switch
    {
        Codec.OggFlac => "oggFLAC",
        _ => JsonNamingPolicy.CamelCase.ConvertName(codec.ToString()),
    };

    public static string RawValue(string? formatName) => Codecs.FromFormatName(formatName).RawValue();
}

// MARK: - Profile and selection

/// <summary>How music is laid out on a portable player or memory card (kept per device and in its manifest).</summary>
public sealed record DeviceProfile
{
    /// <summary>Folder for the songs, from the device's root ("Music"; empty: the root itself).</summary>
    public string MusicFolder { get; set; } = "Music";
    /// <summary>Path of each song inside it, as in Organize.</summary>
    public string Template { get; set; } = OrganizeOptions.DefaultTemplate;
    /// <summary>Folder for the playlists (M3U8), from the root.</summary>
    public string PlaylistFolder { get; set; } = "Playlists";
    public bool WritesPlaylists { get; set; } = true;
    /// <summary>A cover.jpg in each album folder, for players that do not read embedded artwork.</summary>
    public bool WritesCovers { get; set; } = true;
    /// <summary>Longest side of cover.jpg in pixels; 0 keeps the original image.</summary>
    public int CoverSize { get; set; } = 600;
    /// <summary>Synced lyrics as .lrc files beside the songs.</summary>
    public bool WritesLyrics { get; set; } = true;
    /// <summary>Lossless songs go to the device in this lossy format (null: as they are).</summary>
    public LossyEncoding? Encoding { get; set; }

    public static readonly int[] CoverSizes = [300, 500, 600, 1000, 0];

    [JsonIgnore] public OrganizeOptions Naming => new() { Template = Template, OrganizeFolders = true, PortableNames = true };
}

/// <summary>What a device holds: everything, or a mix of playlists, artists, albums, genres and songs.</summary>
public sealed record DeviceSelection
{
    public bool Everything { get; set; }
    public bool LovedSongs { get; set; }
    public HashSet<long> PlaylistIds { get; set; } = [];
    public HashSet<string> Artists { get; set; } = [];
    public HashSet<string> AlbumKeys { get; set; } = [];
    public HashSet<string> Genres { get; set; } = [];
    /// <summary>Songs chosen one by one (from the phone app's view of the whole library).</summary>
    public HashSet<long> TrackIds { get; set; } = [];
    /// <summary>Songs removed from this device: left out whatever brings them, their files deleted from it.</summary>
    public HashSet<long> ExcludedTrackIds { get; set; } = [];
    /// <summary>Formats chosen for parts of the selection ("album:key", "artist:name", "song:id") over the device's own.</summary>
    public Dictionary<string, string> Encodings { get; set; } = [];

    [JsonIgnore]
    public bool IsEmpty => !Everything && !LovedSongs && PlaylistIds.Count == 0 && Artists.Count == 0 && AlbumKeys.Count == 0 && Genres.Count == 0 && TrackIds.Count == 0;

    public DeviceSelection Copy() => this with
    {
        PlaylistIds = [.. PlaylistIds], Artists = [.. Artists], AlbumKeys = [.. AlbumKeys], Genres = [.. Genres], TrackIds = [.. TrackIds],
        ExcludedTrackIds = [.. ExcludedTrackIds], Encodings = new Dictionary<string, string>(Encodings),
    };

    /// <summary>The format a song goes to the device in: the one chosen for it, its album, its artist, else <paramref name="fallback"/>.</summary>
    public LossyEncoding? Encoding(Track track, LossyEncoding? fallback)
    {
        foreach (var key in new[] { $"song:{track.Id ?? -1}", $"album:{track.AlbumKey}", $"artist:{track.DisplayAlbumArtist}", $"artist:{track.DisplayArtist}" })
            if (Encodings.TryGetValue(key, out var chosen)) return LossyEncodings.Parse(chosen);
        return fallback;
    }

    /// <summary>
    /// The selection with the requests applied, in order: removing takes the album, artist, song or playlist off this
    /// device only (its songs, from <paramref name="songs"/>, are left out from then on); adding chooses it and brings
    /// back its songs removed before.
    /// </summary>
    public DeviceSelection Applying(IEnumerable<TransferRequest> requests, Func<TransferKind, string, IReadOnlyList<long>>? songs = null)
    {
        songs ??= (kind, key) => kind == TransferKind.Song && long.TryParse(key, out var id) ? [id] : [];
        var selection = Copy();
        foreach (var request in requests)
        {
            var ids = songs(request.Kind, request.Key);
            var isId = long.TryParse(request.Key, out var id);
            if (request.Action == TransferAction.Add)
            {
                selection.ExcludedTrackIds.ExceptWith(ids);
                // A format asked for with it (or the device's again, when none).
                if (request.Kind != TransferKind.Playlist)
                {
                    if (request.Encoding is { } encoding) selection.Encodings[request.EncodingKey] = encoding;
                    else selection.Encodings.Remove(request.EncodingKey);
                }
                switch (request.Kind)
                {
                    case TransferKind.Album: selection.AlbumKeys.Add(request.Key); break;
                    case TransferKind.Artist: selection.Artists.Add(request.Key); break;
                    case TransferKind.Song when isId: selection.TrackIds.Add(id); break;
                    case TransferKind.Playlist when isId: selection.PlaylistIds.Add(id); break;
                }
            }
            else
            {
                selection.ExcludedTrackIds.UnionWith(ids);
                selection.Encodings.Remove(request.EncodingKey);
                switch (request.Kind)
                {
                    case TransferKind.Album: selection.AlbumKeys.Remove(request.Key); break;
                    case TransferKind.Artist: selection.Artists.Remove(request.Key); break;
                    case TransferKind.Song when isId: selection.TrackIds.Remove(id); break;
                    case TransferKind.Playlist when isId: selection.PlaylistIds.Remove(id); break;
                }
            }
        }
        return selection;
    }
}

/// <summary>A playlist to write on the device, with its songs.</summary>
public sealed record DevicePlaylist(string Name, IReadOnlyList<Track> Tracks);

public static class DeviceQueries
{
    public static List<Track> TracksWithIds(this SqliteConnection db, IEnumerable<long> ids)
    {
        var all = ids.Distinct().ToList();
        var tracks = new List<Track>();
        for (var start = 0; start < all.Count; start += 500)
        {
            var chunk = all.Skip(start).Take(500).ToList();
            tracks.AddRange(db.FetchTracks($"SELECT * FROM track WHERE id IN ({string.Join(",", chunk)})"));
        }
        return tracks;
    }

    /// <summary>The songs and playlists a selection puts on a device (songs once each, in library order).</summary>
    public static (List<Track> Tracks, List<DevicePlaylist> Playlists) DeviceContents(this SqliteConnection db, DeviceSelection selection)
    {
        var playlists = new List<DevicePlaylist>();
        if (selection.LovedSongs) playlists.Add(new DevicePlaylist("Loved Songs", db.LovedTracks()));
        foreach (var playlist in db.Playlists())
        {
            if (playlist.Id is { } id && selection.PlaylistIds.Contains(id)) playlists.Add(new DevicePlaylist(playlist.Name, db.TracksOfPlaylist(id)));
        }
        List<Track> tracks;
        if (selection.Everything) tracks = db.AllTracks();
        else
        {
            tracks = playlists.SelectMany(playlist => playlist.Tracks).ToList();
            foreach (var artist in selection.Artists.Order(StringComparer.Ordinal))
                foreach (var album in db.Albums(AlbumSort.Year, artist)) tracks.AddRange(db.TracksOfAlbum(album.AlbumKey));
            foreach (var key in selection.AlbumKeys.Order(StringComparer.Ordinal)) tracks.AddRange(db.TracksOfAlbum(key));
            foreach (var genre in selection.Genres.Order(StringComparer.Ordinal))
                tracks.AddRange(db.FetchTracks("SELECT * FROM track WHERE TRIM(genre) = ? COLLATE NOCASE", genre));
            tracks.AddRange(db.TracksWithIds(selection.TrackIds).OrderBy(track => track.Path, StringComparer.Ordinal));
        }
        var seen = new HashSet<long>();
        // Songs removed from the device stay off it, and out of its playlists.
        var excluded = selection.ExcludedTrackIds;
        tracks = tracks.Where(track => !excluded.Contains(track.Id ?? -1) && seen.Add(track.Id ?? -1)).ToList();
        if (excluded.Count > 0) playlists = playlists.Select(playlist => playlist with { Tracks = playlist.Tracks.Where(track => !excluded.Contains(track.Id ?? -1)).ToList() }).ToList();
        return (tracks, playlists);
    }

    /// <summary>The songs of what a device asks for: an album, an artist (their albums and their songs on others), a song or a playlist.</summary>
    public static List<long> TrackIdsOf(this SqliteConnection db, TransferKind kind, string key)
    {
        switch (kind)
        {
            case TransferKind.Album:
                return db.TracksOfAlbum(key).Select(track => track.Id ?? -1).ToList();
            case TransferKind.Artist:
                var ids = db.Albums(AlbumSort.Year, key).SelectMany(album => db.TracksOfAlbum(album.AlbumKey)).Select(track => track.Id ?? -1).ToList();
                ids.AddRange(db.FetchTracks("SELECT * FROM track WHERE artist = ?", key).Select(track => track.Id ?? -1));
                return ids;
            case TransferKind.Song:
                return long.TryParse(key, out var id) ? [id] : [];
            default:
                return long.TryParse(key, out var playlist) ? db.TracksOfPlaylist(playlist).Select(track => track.Id ?? -1).ToList() : [];
        }
    }
}

// MARK: - Manifest

public enum ManifestKind { Song, CueSheet, Cover, Lyrics, Playlist }

/// <summary>A file Groovelight wrote on a device.</summary>
public sealed record ManifestEntry
{
    public ManifestKind Kind { get; set; }
    public long? TrackId { get; set; }
    /// <summary>What the file was made from: the source's path, size and date for songs, a content hash otherwise.</summary>
    public string Fingerprint { get; set; } = "";
    public long Size { get; set; }
    /// <summary>Written by a sync (removed when no longer selected) rather than sent once (kept until removed by hand).</summary>
    public bool Synced { get; set; }
}

/// <summary>
/// What Groovelight wrote on a device, kept there as <c>.groovelight-device.json</c>: lets a sync copy only what changed
/// and remove only its own files (never other files on the card).
/// </summary>
public sealed record DeviceManifest
{
    public const string FileName = ".groovelight-device.json";

    public DeviceProfile? Profile { get; set; }
    /// <summary>Relative path on the device to its entry.</summary>
    public Dictionary<string, ManifestEntry> Entries { get; set; } = [];
    public DateTime? LastSync { get; set; }

    public static DeviceManifest Read(string root)
    {
        try { return WireJson.Decode<DeviceManifest>(File.ReadAllBytes(Path.Combine(root, FileName))) ?? new DeviceManifest(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return new DeviceManifest(); }
    }

    public void Write(string root)
    {
        var path = Path.Combine(root, FileName);
        var temporary = path + ".tmp";
        File.WriteAllBytes(temporary, WireJson.Encode(this));
        File.Move(temporary, path, true);
    }

    /// <summary>Space taken by Groovelight's files.</summary>
    [JsonIgnore] public long MusicBytes => Entries.Values.Sum(entry => entry.Size);

    public DeviceManifest Copy() => this with { Entries = Entries.ToDictionary(pair => pair.Key, pair => pair.Value with { }) };
}

// MARK: - Planning

/// <summary>What a planned file is made of.</summary>
public abstract record DeviceContent
{
    public sealed record File(string Path) : DeviceContent;
    /// <summary>Made when written: cover.jpg from the artwork cache.</summary>
    public sealed record Cover(string Hash) : DeviceContent;
    public sealed record Data(byte[] Bytes) : DeviceContent;
    /// <summary>The song converted: to FLAC, or to the device's lossy format.</summary>
    public sealed record Converted(ConversionSource Source) : DeviceContent;
}

public sealed record DeviceWrite(string Path, DeviceContent Content, ManifestEntry Entry);

/// <summary>Everything a sync or send will do on a device.</summary>
public sealed class DeviceSyncPlan
{
    public List<DeviceWrite> Writes { get; } = [];
    /// <summary>Relative paths of Groovelight's files to remove.</summary>
    public List<string> Deletions { get; } = [];
    /// <summary>Desired files already on the device and current.</summary>
    public Dictionary<string, ManifestEntry> Unchanged { get; } = [];
    /// <summary>Songs left out, with the reason.</summary>
    public List<(string Title, string Reason)> Skipped { get; } = [];
    public int SongCount { get; set; }
    public long BytesToFree { get; set; }

    public long BytesToWrite => Writes.Sum(write => write.Entry.Size);
    /// <summary>How much more (or less, when negative) of the device the music will take.</summary>
    public long NetBytes => BytesToWrite - BytesToFree;
    public bool IsEmpty => Writes.Count == 0 && Deletions.Count == 0;
}

/// <summary>
/// A device where Groovelight itself plays the music (Groovelight for Android in Player mode, Groovelight for iOS): it
/// gets the songs only, and songs in formats it cannot decode are converted to FLAC.
/// </summary>
public sealed record DevicePlayer(IReadOnlySet<string> Decodes)
{
    public enum DeliveryKind { AsIs, Flac, Skip }

    public (DeliveryKind Kind, string? Reason) Delivery(Track track)
    {
        var codec = Codecs.FromFormatName(track.Format);
        if (Decodes.Contains(codec.RawValue())) return (DeliveryKind.AsIs, null);
        return codec switch
        {
            Codec.Dsf or Codec.Dsdiff => (DeliveryKind.Skip, "DSD does not play on this device yet"),
            Codec.Module => (DeliveryKind.Skip, "tracker modules do not play on this device"),
            _ => (DeliveryKind.Flac, null),
        };
    }
}

public enum DeviceSyncMode
{
    /// <summary>The device ends up with exactly the selection: Groovelight's other synced files are removed.</summary>
    Sync,
    /// <summary>Adds the songs (and updates them); nothing is removed.</summary>
    Send,
}

/// <summary>Plans and carries out syncs and sends to devices (the Mac's DeviceSync).</summary>
public static partial class DeviceSync
{
    /// <summary>FAT32's largest file.</summary>
    public const long Fat32Limit = 4L * 1024 * 1024 * 1024 - 1;

    /// <summary>The codec a converted song has on the device, from its fingerprint ("|flac", "|opus160"...); null for one copied as it is.</summary>
    public static string? ConvertedCodec(string fingerprint)
    {
        var suffix = fingerprint.Split('|').LastOrDefault();
        if (suffix == "flac") return "flac";
        return LossyEncodings.Parse(suffix)?.Codec();
    }

    /// <summary>
    /// Plans putting <paramref name="tracks"/> and <paramref name="playlists"/> on the device at <paramref name="root"/>.
    /// <paramref name="existing"/> answers whether a path is already taken by a file Groovelight did not write (another name
    /// is then used); <paramref name="fat32"/> enforces the 4 GB file limit.
    /// </summary>
    public static DeviceSyncPlan Plan(IReadOnlyList<Track> tracks, IReadOnlyList<DevicePlaylist> playlists, DeviceProfile profile, DeviceManifest manifest,
                                      DeviceSyncMode mode, string root, bool fat32 = false, DevicePlayer? player = null, IReadOnlySet<long>? excluded = null,
                                      Func<Track, LossyEncoding?>? formats = null, Func<string, bool>? existing = null)
    {
        existing ??= _ => false;
        excluded ??= new HashSet<long>();
        var format = formats ?? (_ => profile.Encoding);
        if (excluded.Count > 0) tracks = tracks.Where(track => !excluded.Contains(track.Id ?? -1)).ToList();
        var plan = new DeviceSyncPlan();
        var desired = new Dictionary<string, (DeviceContent Content, ManifestEntry Entry)>();
        // Lowercased paths in use (FAT and exFAT ignore case).
        var taken = new HashSet<string>();
        // Where each song went, for playlists.
        var placed = new Dictionary<long, string>();
        var musicFolder = Clean(profile.MusicFolder);
        var naming = profile.Naming;

        string InMusic(string relative) => musicFolder.Length == 0 ? relative : $"{musicFolder}/{relative}";
        bool IsForeign(string path) => !manifest.Entries.ContainsKey(path) && existing(path);
        // A free name for the path: " (2)", " (3)"... when another planned file or a file not ours holds it.
        string Claim(string path)
        {
            var candidate = path;
            var counter = 2;
            while (taken.Contains(candidate.ToLowerInvariant()) || IsForeign(candidate))
            {
                var slash = path.LastIndexOf('/');
                var folder = slash >= 0 ? path[..slash] : "";
                var file = slash >= 0 ? path[(slash + 1)..] : path;
                var dot = file.LastIndexOf('.');
                var name = dot > 0 ? $"{file[..dot]} ({counter}){file[dot..]}" : $"{file} ({counter})";
                candidate = folder.Length == 0 ? name : $"{folder}/{name}";
                counter++;
            }
            taken.Add(candidate.ToLowerInvariant());
            return candidate;
        }
        void Add(string path, DeviceContent content, ManifestKind kind, string fingerprint, long size, long? trackId = null) =>
            desired[path] = (content, new ManifestEntry { Kind = kind, TrackId = trackId, Fingerprint = fingerprint, Size = size, Synced = mode == DeviceSyncMode.Sync });
        static string SongFingerprint(Track track) =>
            $"{track.FilePath}|{track.FileSize}|{(long)Math.Floor((track.ModifiedAt.ToUniversalTime() - DateTime.UnixEpoch).TotalSeconds)}";
        // A CUE song's share of its album's file, by duration.
        var cueDurations = tracks.Where(track => track.IsCueTrack).GroupBy(track => track.FilePath).ToDictionary(group => group.Key, group => group.Sum(track => track.Duration));
        long CueSize(Track track) => cueDurations.TryGetValue(track.FilePath, out var total) && total > 0
            ? (long)(track.FileSize * Math.Min(track.Duration / total, 1)) : track.FileSize;

        // Where each song was put last time.
        var previousPaths = new Dictionary<long, string>();
        foreach (var (path, entry) in manifest.Entries)
            if (entry.Kind == ManifestKind.Song && entry.TrackId is { } id) previousPaths[id] = path;
        // Songs, each in its template path, in a stable order so names numbered for collisions stay put.
        var covers = new Dictionary<string, string>();
        // A player device, or one set to a lossy format, gets each song of a CUE album as a file of its own.
        var splitsCue = player is not null || tracks.Any(track => track.IsCueTrack && format(track) is not null);
        foreach (var track in tracks.Where(track => !track.IsCueTrack || splitsCue).OrderBy(track => track.Path, StringComparer.Ordinal))
        {
            if (track.Id is not { } id) continue;
            if (fat32 && track.FileSize > Fat32Limit)
            {
                plan.Skipped.Add((track.Title, "larger than 4 GB, which FAT32 cards cannot hold"));
                continue;
            }
            var delivery = track.IsCueTrack ? DevicePlayer.DeliveryKind.Flac : player?.Delivery(track).Kind ?? DevicePlayer.DeliveryKind.AsIs;
            if (delivery == DevicePlayer.DeliveryKind.Skip)
            {
                plan.Skipped.Add((track.Title, player!.Delivery(track).Reason!));
                continue;
            }
            // The device's lossy format for lossless songs (a player that cannot decode it gets FLAC instead).
            var codec = Codecs.FromFormatName(track.Format);
            LossyEncoding? encoding = null;
            if (format(track) is { } lossy && (LossyEncodings.AppliesTo(codec) || track.IsCueTrack) && (player?.Decodes.Contains(lossy.Codec()) ?? true))
            {
                encoding = lossy;
                delivery = DevicePlayer.DeliveryKind.Flac;
            }
            var converted = delivery == DevicePlayer.DeliveryKind.Flac;
            var source = track.IsCueTrack ? ConversionSource.CueTrack(track, encoding) : new ConversionSource(track.FilePath, Encoding: encoding);
            var relative = InMusic(FileNaming.RelativePath(NamingFields.Of(track), converted ? source.FileExtension : Path.GetExtension(track.FilePath).TrimStart('.'), naming));
            // A song keeps the name it already has on the device (a numbered one too) while its intended name is the same.
            string final;
            if (previousPaths.TryGetValue(id, out var previous)
                && (previous.Equals(relative, StringComparison.OrdinalIgnoreCase) || StripCounter(previous).Equals(relative, StringComparison.OrdinalIgnoreCase))
                && !taken.Contains(previous.ToLowerInvariant()))
            {
                taken.Add(previous.ToLowerInvariant());
                final = previous;
            }
            else final = Claim(relative);
            var region = track.IsCueTrack ? $"|{Number(track.StartTime ?? 0)}-{Number(track.EndTime ?? -1)}" : "";
            var suffix = converted ? "|" + (encoding?.RawValue() ?? "flac") : "";
            // An encoded song's size is about its bitrate times its length.
            var size = encoding is { } chosen ? chosen.Kbps() * 125L * (long)Math.Ceiling(track.Duration) : track.IsCueTrack ? CueSize(track) : track.FileSize;
            Add(final, converted ? new DeviceContent.Converted(source) : new DeviceContent.File(track.FilePath), ManifestKind.Song, SongFingerprint(track) + region + suffix, size, id);
            placed[id] = final;
            plan.SongCount++;
            var folder = Folder(final);
            if (!covers.ContainsKey(folder) && (track.FetchedArtworkHash ?? track.ArtworkHash) is { } hash) covers[folder] = hash;
            if (profile.WritesLyrics && track.DisplayLyrics() is { } lyrics && IsSyncedLyrics(lyrics))
            {
                var lrc = WithoutExtension(final) + ".lrc";
                if (!IsForeign(lrc) && taken.Add(lrc.ToLowerInvariant()))
                {
                    var data = System.Text.Encoding.UTF8.GetBytes(lyrics);
                    Add(lrc, new DeviceContent.Data(data), ManifestKind.Lyrics, Hash(data), data.Length, id);
                }
            }
        }

        // CUE albums (not for a player device: it got their songs above): the audio file and its sheet, in the album's folder.
        if (!splitsCue)
        {
            foreach (var group in tracks.Where(track => track.IsCueTrack).GroupBy(track => track.FilePath).OrderBy(group => group.Key, StringComparer.Ordinal))
            {
                var first = group.MinBy(track => track.TrackNumber ?? 0)!;
                var audio = group.Key;
                var size = File.Exists(audio) ? new FileInfo(audio).Length : first.FileSize;
                if (fat32 && size > Fat32Limit)
                {
                    plan.Skipped.Add((first.Album ?? Path.GetFileName(audio), "larger than 4 GB, which FAT32 cards cannot hold"));
                    continue;
                }
                var relative = InMusic(FileNaming.RelativePath(NamingFields.Of(first), Path.GetExtension(audio).TrimStart('.'), naming));
                var folder = Folder(relative);
                var audioTarget = Claim(folder.Length == 0 ? Path.GetFileName(audio) : $"{folder}/{Path.GetFileName(audio)}");
                Add(audioTarget, new DeviceContent.File(audio), ManifestKind.Song, $"{audio}|{size}", size);
                foreach (var song in group) if (song.Id is { } id) placed[id] = audioTarget;
                plan.SongCount += group.Count();
                if (first.CueSheetPath is { } sheet && sheet != audio)
                {
                    var sheetSize = File.Exists(sheet) ? new FileInfo(sheet).Length : 0;
                    var sheetTarget = Claim(Folder(audioTarget) + "/" + Path.GetFileName(sheet));
                    Add(sheetTarget, new DeviceContent.File(sheet), ManifestKind.CueSheet, $"{sheet}|{sheetSize}", sheetSize);
                }
                if (!covers.ContainsKey(folder) && (first.FetchedArtworkHash ?? first.ArtworkHash) is { } hash) covers[folder] = hash;
            }
        }

        if (profile.WritesCovers)
        {
            foreach (var (folder, hash) in covers.OrderBy(pair => pair.Key, StringComparer.Ordinal))
            {
                var path = folder.Length == 0 ? "cover.jpg" : $"{folder}/cover.jpg";
                // A cover.jpg that came from elsewhere is left alone.
                if (IsForeign(path) || !taken.Add(path.ToLowerInvariant())) continue;
                Add(path, new DeviceContent.Cover(hash), ManifestKind.Cover, $"{hash}|{profile.CoverSize}", 150_000);
            }
        }

        if (profile.WritesPlaylists)
        {
            var playlistFolder = Clean(profile.PlaylistFolder);
            foreach (var playlist in playlists)
            {
                var name = FileNaming.Sanitize(playlist.Name, naming);
                var path = Claim((playlistFolder.Length == 0 ? "" : playlistFolder + "/") + (name.Length == 0 ? "Playlist" : name) + ".m3u8");
                // The songs at their device paths, so the file's paths are relative to the playlist's own folder.
                var onDevice = playlist.Tracks.Select(track => track.Id is { } id && placed.TryGetValue(id, out var target)
                    ? track with { Path = Path.Combine(root, target.Replace('/', Path.DirectorySeparatorChar)), AudioPath = track.IsCueTrack ? Path.Combine(root, target.Replace('/', Path.DirectorySeparatorChar)) : null }
                    : null).OfType<Track>().ToList();
                var folderPath = Path.GetDirectoryName(Path.Combine(root, path.Replace('/', Path.DirectorySeparatorChar)))!;
                var data = PlaylistFile.Write(playlist.Name, onDevice, PlaylistFormat.M3u8, new PlaylistPathStyle.Relative(folderPath));
                Add(path, new DeviceContent.Data(data), ManifestKind.Playlist, Hash(data), data.Length);
            }
        }

        // Against what is there: new or changed files are written, current ones kept.
        foreach (var (path, (content, entry)) in desired.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (manifest.Entries.TryGetValue(path, out var old) && old.Fingerprint == entry.Fingerprint && existing(path))
            {
                var kept = old with { };
                // A song sent once becomes part of the sync when the selection includes it.
                if (mode == DeviceSyncMode.Sync) kept.Synced = true;
                plan.Unchanged[path] = kept;
            }
            else
            {
                var written = entry with { };
                if (mode == DeviceSyncMode.Send && manifest.Entries.TryGetValue(path, out var previousEntry)) written.Synced = previousEntry.Synced;
                plan.Writes.Add(new DeviceWrite(path, content, written));
            }
        }
        // Groovelight's files no longer wanted: in a sync, the ones it synced; in any plan, songs removed from the device.
        foreach (var (path, entry) in manifest.Entries)
        {
            if (desired.ContainsKey(path)) continue;
            if ((mode == DeviceSyncMode.Sync && entry.Synced) || (entry.TrackId is { } trackId && excluded.Contains(trackId)))
            {
                plan.Deletions.Add(path);
                plan.BytesToFree += entry.Size;
            }
        }
        plan.Deletions.Sort(StringComparer.Ordinal);
        return plan;
    }

    /// <summary>
    /// A sync of the selection and, in the same plan, songs sent to the device since (a wireless device only takes them
    /// when it next connects). Sent songs are added without making them part of the sync.
    /// </summary>
    public static DeviceSyncPlan Plan((IReadOnlyList<Track> Tracks, IReadOnlyList<DevicePlaylist> Playlists) syncing,
                                      (IReadOnlyList<Track> Tracks, IReadOnlyList<DevicePlaylist> Playlists) sending, DeviceProfile profile, DeviceManifest manifest,
                                      string root, Func<string, bool> existing, bool fat32 = false, DevicePlayer? player = null, IReadOnlySet<long>? excluded = null,
                                      Func<Track, LossyEncoding?>? formats = null)
    {
        excluded ??= new HashSet<long>();
        var plan = Plan(syncing.Tracks, syncing.Playlists, profile, manifest, DeviceSyncMode.Sync, root, fat32, player, excluded, formats, existing);
        var sentTracks = sending.Tracks.Where(track => !excluded.Contains(track.Id ?? -1)).ToList();
        if (sentTracks.Count == 0 && sending.Playlists.Count == 0) return plan;
        // The device as the sync leaves it (files it would remove are still there), then the sends on top.
        var after = manifest.Copy();
        foreach (var (path, entry) in plan.Unchanged) after.Entries[path] = entry;
        foreach (var write in plan.Writes) after.Entries[write.Path] = write.Entry;
        var written = plan.Writes.Select(write => write.Path).ToHashSet();
        var sends = Plan(sentTracks, sending.Playlists, profile, after, DeviceSyncMode.Send, root, fat32, player, null, formats, path => written.Contains(path) || existing(path));
        plan.Writes.AddRange(sends.Writes.Where(write => !written.Contains(write.Path)));
        // A sent song the sync was about to remove stays, as a sent file from now on.
        var removed = plan.Deletions.ToHashSet();
        var kept = sends.Writes.Select(write => write.Path).Concat(sends.Unchanged.Keys).ToHashSet();
        plan.Deletions.RemoveAll(kept.Contains);
        plan.BytesToFree = plan.Deletions.Sum(path => manifest.Entries.TryGetValue(path, out var entry) ? entry.Size : 0);
        foreach (var (path, entry) in sends.Unchanged)
        {
            if (plan.Unchanged.ContainsKey(path) || written.Contains(path)) continue;
            plan.Unchanged[path] = removed.Contains(path) ? entry with { Synced = false } : entry;
        }
        plan.Skipped.AddRange(sends.Skipped);
        plan.SongCount += sends.Writes.Count(write => write.Entry.Kind == ManifestKind.Song);
        return plan;
    }

    /// <summary>
    /// Carries out a plan: removals first (to make room), then the files, each copied under a temporary name and then
    /// renamed so a pulled card never holds half a song under its real name. The manifest is saved as it goes, so an
    /// interrupted sync resumes where it stopped. Returns the updated manifest.
    /// </summary>
    public static DeviceManifest Run(DeviceSyncPlan plan, string root, DeviceProfile profile, DeviceManifest manifest, Func<string, int, byte[]?> cover,
                                     Action<int, int>? progress = null, Func<bool>? isCancelled = null, ConversionCache? conversions = null)
    {
        manifest = manifest.Copy();
        manifest.Profile = profile;
        var emptied = new HashSet<string>();
        string Full(string relative) => Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
        foreach (var path in plan.Deletions)
        {
            try { File.Delete(Full(path)); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            manifest.Entries.Remove(path);
            emptied.Add(Folder(path));
        }
        foreach (var (path, entry) in plan.Unchanged) manifest.Entries[path] = entry;
        manifest.Write(root);
        for (var index = 0; index < plan.Writes.Count; index++)
        {
            if (isCancelled?.Invoke() == true) break;
            progress?.Invoke(index, plan.Writes.Count);
            var write = plan.Writes[index];
            var target = Full(write.Path);
            var folder = Path.GetDirectoryName(target)!;
            Directory.CreateDirectory(folder);
            var partial = Path.Combine(folder, $".{Path.GetFileName(target)}.partial");
            if (File.Exists(partial)) File.Delete(partial);
            var entry = write.Entry with { };
            switch (write.Content)
            {
                case DeviceContent.File file:
                    File.Copy(file.Path, partial);
                    break;
                case DeviceContent.Data data:
                    File.WriteAllBytes(partial, data.Bytes);
                    break;
                case DeviceContent.Converted converted:
                    if (conversions is not null) File.Copy(conversions.Converted(converted.Source, entry.Fingerprint), partial);
                    else FormatConverter.Convert(converted.Source, partial);
                    entry.Size = new FileInfo(partial).Length;
                    break;
                case DeviceContent.Cover image:
                    if (cover(image.Hash, profile.CoverSize) is not { } bytes) continue;
                    File.WriteAllBytes(partial, bytes);
                    entry.Size = bytes.Length;
                    break;
            }
            File.Move(partial, target, true);
            manifest.Entries[write.Path] = entry;
            emptied.Remove(Folder(write.Path));
            // Saved every so often: a pulled card loses at most a few songs of progress.
            if (index % 25 == 24) manifest.Write(root);
        }
        progress?.Invoke(plan.Writes.Count, plan.Writes.Count);
        manifest.LastSync = DateTime.UtcNow;
        manifest.Write(root);
        RemoveEmptyFolders(emptied, root);
        return manifest;
    }

    /// <summary>Folders left empty by removals, up to (not including) the root.</summary>
    internal static void RemoveEmptyFolders(IEnumerable<string> folders, string root)
    {
        foreach (var start in folders.OrderByDescending(folder => folder.Length))
        {
            var current = start;
            while (current.Length > 0 && current != ".")
            {
                var full = Path.Combine(root, current.Replace('/', Path.DirectorySeparatorChar));
                try
                {
                    if (!Directory.Exists(full) || Directory.EnumerateFileSystemEntries(full).Any(entry => Path.GetFileName(entry) is not (".DS_Store" or "desktop.ini" or "Thumbs.db"))) break;
                    Directory.Delete(full, true);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { break; }
                current = Folder(current);
            }
        }
    }

    private static string Folder(string path) => path.LastIndexOf('/') is var slash and >= 0 ? path[..slash] : "";

    private static string WithoutExtension(string path)
    {
        var slash = path.LastIndexOf('/');
        var dot = path.LastIndexOf('.');
        return dot > slash ? path[..dot] : path;
    }

    private static string Number(double value) => value.ToString("R", CultureInfo.InvariantCulture) is var text && !text.Contains('.') && !text.Contains('E') ? text + ".0" : value.ToString("R", CultureInfo.InvariantCulture);

    /// <summary>"Music/A/01 x (2).flac" to "Music/A/01 x.flac".</summary>
    internal static string StripCounter(string path) => path.Contains(" (") ? CounterPattern().Replace(path, "$1") : path;

    [GeneratedRegex(@" \(\d+\)(\.[^./]+)?$")]
    private static partial Regex CounterPattern();

    /// <summary>A folder setting as a clean relative path ("/Music/" to "Music").</summary>
    internal static string Clean(string folder) =>
        string.Join("/", folder.Split(['/', '\\']).Select(FileNaming.CleanComponent).Where(part => part.Length > 0 && part != ".."));

    internal static string Hash(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data).AsSpan(0, 12));

    /// <summary>Whether lyrics carry LRC timestamps ("[01:23.45]").</summary>
    public static bool IsSyncedLyrics(string text) => SyncedPattern().IsMatch(text);

    [GeneratedRegex(@"\[\d{1,2}:\d{2}([.:]\d{1,3})?\]")]
    private static partial Regex SyncedPattern();
}
