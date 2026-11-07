using System.Text.Json.Serialization;
using Groovelight.Core.Library;
using Microsoft.Data.Sqlite;

namespace Groovelight.Core.Devices;

public enum TransferAction { Add, Remove }

public enum TransferKind { Album, Artist, Song, Playlist }

/// <summary>
/// A change the phone app asks of its selection: add or remove an album, an artist, a song or a playlist. Made on the
/// device (also while the computer is away) and sent when it is reachable; applying one twice changes nothing.
/// </summary>
public sealed record TransferRequest(string Id, TransferAction Action, TransferKind Kind, string Key, string? Encoding = null)
{
    /// <summary>Its key among <see cref="DeviceSelection.Encodings"/>.</summary>
    [JsonIgnore] public string EncodingKey => $"{Kind.ToString().ToLowerInvariant()}:{Key}";
}

/// <summary>
/// The whole library as the phone app browses it from the computer (protocol v2): every song and album, with covers by
/// hash, so the device can show what it does not hold and ask for it. <c>Chosen</c> is what the device's selection holds.
/// </summary>
public sealed record DeviceCatalog
{
    public const int CurrentVersion = 1;

    public sealed record Song(long Id, string Title, string Artist, string AlbumKey, int? DiscNumber, int? TrackNumber, double Duration, string Codec,
                              int? SampleRate, int? BitDepth, string? Genre, int? Year, string? ArtworkHash);

    public sealed record Album(string Key, string Title, string Artist, int? Year, bool IsCompilation, string? ArtworkHash);

    /// <summary>What the device's selection holds, as the app can change it.</summary>
    public sealed record ChosenSet
    {
        public bool Everything { get; init; }
        public List<string> AlbumKeys { get; init; } = [];
        public List<string> Artists { get; init; } = [];
        public List<long> TrackIds { get; init; } = [];
        public List<long> ExcludedTrackIds { get; init; } = [];
        public Dictionary<string, string> Encodings { get; init; } = [];
        /// <summary>Playlists, genres or Loved Songs are chosen too (on the computer, not from the app).</summary>
        public bool HasOthers { get; init; }

        public static ChosenSet Of(DeviceSelection selection) => new()
        {
            Everything = selection.Everything, AlbumKeys = selection.AlbumKeys.Order(StringComparer.Ordinal).ToList(),
            Artists = selection.Artists.Order(StringComparer.Ordinal).ToList(), TrackIds = selection.TrackIds.Order().ToList(),
            ExcludedTrackIds = selection.ExcludedTrackIds.Order().ToList(), Encodings = new Dictionary<string, string>(selection.Encodings),
            HasOthers = selection.LovedSongs || selection.PlaylistIds.Count > 0 || selection.Genres.Count > 0,
        };
    }

    public int Version { get; init; } = CurrentVersion;
    public List<Song> Songs { get; init; } = [];
    public List<Album> Albums { get; init; } = [];
    public ChosenSet Chosen { get; init; } = new();
    /// <summary>The format this device gets lossless songs in (a lossy encoding's raw value; null: as they are).</summary>
    public string? Encoding { get; init; }
    /// <summary>Artists' photos (album artists), as in the snapshot.</summary>
    public List<DeviceSnapshot.Artist>? Artists { get; init; }

    public static DeviceCatalog Build(SqliteConnection db, DeviceSelection selection, LossyEncoding? encoding = null)
    {
        var songs = new List<Song>();
        var albums = new Dictionary<string, Album>();
        foreach (var track in db.AllTracks())
        {
            if (track.Id is not { } id) continue;
            var artwork = track.FetchedArtworkHash ?? track.ArtworkHash;
            songs.Add(new Song(id, track.Title, track.DisplayArtist, track.AlbumKey, track.DiscNumber, track.TrackNumber, track.Duration,
                CodecNames.RawValue(track.Format), track.SampleRate is { } rate ? (int)rate : null, track.BitDepth, track.Genre?.Trim().NonEmpty(), track.Year, artwork));
            if (!albums.TryGetValue(track.AlbumKey, out var album))
            {
                albums[track.AlbumKey] = new Album(track.AlbumKey, track.DisplayAlbum, track.IsCompilation ? "Various Artists" : track.DisplayAlbumArtist, track.Year,
                    track.IsCompilation, artwork);
            }
            else if (album.ArtworkHash is null && artwork is not null) albums[track.AlbumKey] = album with { ArtworkHash = artwork };
        }
        var artists = db.ArtistPhotos(albums.Values.Where(album => !album.IsCompilation).Select(album => album.Artist))
            .Select(pair => new DeviceSnapshot.Artist(pair.Key, pair.Value)).OrderBy(artist => artist.Name, StringComparer.Ordinal).ToList();
        return new DeviceCatalog
        {
            Songs = songs.OrderBy(song => song.Id).ToList(), Albums = albums.Values.OrderBy(album => album.Key, StringComparer.Ordinal).ToList(),
            Chosen = ChosenSet.Of(selection), Encoding = encoding?.RawValue(), Artists = artists,
        };
    }
}

/// <summary>
/// Something done on a device the library should know: a love or unlove, a rating, a play or a skip, with when it
/// happened; or a playlist edit (a negative playlist id for one made on the device). Sent by the phone app
/// (<c>POST /history</c>); applying one twice changes nothing.
/// </summary>
public sealed record DeviceHistoryEvent
{
    public string Id { get; init; } = "";
    public long TrackId { get; init; }
    /// <summary>"love", "rating", "play", "skip", "playlistCreate", "playlistAdd", "playlistRemove", "playlistRename", "playlistDelete" (others left alone).</summary>
    public string Kind { get; init; } = "";
    public int Value { get; init; }
    /// <summary>Milliseconds since 1970.</summary>
    public long AtMs { get; init; }
    public long? PlaylistId { get; init; }
    public string? Name { get; init; }
    public List<long>? TrackIds { get; init; }

    [JsonIgnore] public DateTime Date => DateTime.UnixEpoch.AddMilliseconds(AtMs);
    [JsonIgnore] public bool IsPlaylistEdit => Kind is "playlistCreate" or "playlistAdd" or "playlistRemove" or "playlistRename" or "playlistDelete";
}

/// <summary>What a device's history changed: loves (to tell Last.fm) and plays counted (to scrobble).</summary>
public sealed class DeviceHistoryChanges
{
    public List<(long TrackId, bool Loved)> Loves { get; } = [];
    public List<(long TrackId, DateTime StartedAt, double Listened)> Plays { get; } = [];
    public bool IsEmpty => Loves.Count == 0 && Plays.Count == 0;
}

public static class DeviceHistory
{
    /// <summary>
    /// Applies a device's history, in order. A love or unlove made on the device wins unless the song was loved here
    /// after it. Plays and skips count once each (by device and event id), and a play only moves Last Played forward.
    /// </summary>
    public static DeviceHistoryChanges ApplyDeviceHistory(this LibraryDatabase database, IReadOnlyList<DeviceHistoryEvent> events, string deviceId = "") => database.Write(db =>
    {
        var changed = new Dictionary<long, bool>();
        var changes = new DeviceHistoryChanges();
        using var transaction = db.BeginTransaction();
        // Playlist edits keep the device's order; the rest by time.
        foreach (var edit in events.Where(item => item.IsPlaylistEdit))
            if (FirstTime(db, edit, deviceId)) ApplyPlaylistEdit(db, edit, deviceId);
        foreach (var item in events.Where(item => !item.IsPlaylistEdit).OrderBy(item => item.AtMs))
        {
            var track = db.FetchTracks("SELECT * FROM track WHERE id = ?", item.TrackId).FirstOrDefault();
            if (track is null) continue;
            switch (item.Kind)
            {
                case "rating":
                    db.Execute("UPDATE track SET rating = ? WHERE id = ?", Math.Clamp(item.Value, 0, 5), item.TrackId);
                    break;
                case "love":
                    var loved = item.Value == 1;
                    if (loved == track.IsLoved) continue;
                    // Loved here after the device's change: the newer one stays.
                    if (track.IsLoved && track.LovedAt is { } lovedAt && lovedAt > item.Date) continue;
                    db.Execute("UPDATE track SET isLoved = ?, lovedAt = ? WHERE id = ?", loved, loved ? item.Date : null, item.TrackId);
                    changed[item.TrackId] = loved;
                    break;
                case "play" or "skip":
                    if (!FirstTime(db, item, deviceId)) continue;
                    if (item.Kind == "skip") db.Execute("UPDATE track SET skipCount = skipCount + 1 WHERE id = ?", item.TrackId);
                    else
                    {
                        db.Execute("""
                            UPDATE track SET playCount = playCount + 1,
                                lastPlayedAt = CASE WHEN lastPlayedAt IS NULL OR lastPlayedAt < ? THEN ? ELSE lastPlayedAt END
                            WHERE id = ?
                            """, item.Date, item.Date, item.TrackId);
                        changes.Plays.Add((item.TrackId, item.Date, item.Value));
                    }
                    break;
            }
        }
        // Counted plays are remembered for a year.
        db.Execute("DELETE FROM deviceHistoryEvent WHERE appliedAt < ?", DateTime.UtcNow.AddDays(-365));
        transaction.Commit();
        changes.Loves.AddRange(changed.OrderBy(pair => pair.Key).Select(pair => (pair.Key, pair.Value)));
        return changes;
    });

    /// <summary>Notes the event as applied; false when it was already (a resend after a lost answer).</summary>
    private static bool FirstTime(SqliteConnection db, DeviceHistoryEvent item, string deviceId) =>
        db.Execute("INSERT OR IGNORE INTO deviceHistoryEvent (deviceId, eventId, appliedAt) VALUES (?, ?, ?)", deviceId, item.Id, DateTime.UtcNow) > 0;

    /// <summary>The playlist an edit is about: a negative id is one the device made, found by what it was made as here.</summary>
    private static Playlist? FindPlaylist(SqliteConnection db, long? id, string deviceId)
    {
        if (id is not { } given) return null;
        var resolved = given >= 0 ? given : db.Column<long>("SELECT playlistId FROM deviceHistoryEvent WHERE deviceId = ? AND localPlaylistId = ? AND playlistId IS NOT NULL",
            deviceId, given).Cast<long?>().FirstOrDefault();
        return resolved is { } found ? db.Playlists().FirstOrDefault(playlist => playlist.Id == found) : null;
    }

    private static void Append(SqliteConnection db, IEnumerable<long> trackIds, long playlistId)
    {
        var position = db.Column<long>("SELECT COALESCE(MAX(position) + 1, 0) FROM playlistItem WHERE playlistId = ?", playlistId).FirstOrDefault();
        foreach (var trackId in trackIds)
            db.Execute("INSERT INTO playlistItem (playlistId, trackId, position) VALUES (?, ?, ?)", playlistId, trackId, position++);
    }

    private static void ApplyPlaylistEdit(SqliteConnection db, DeviceHistoryEvent item, string deviceId)
    {
        // Songs the library still has, in the order given.
        var given = item.TrackIds ?? [];
        var known = given.Count == 0 ? [] : db.Column<long>($"SELECT id FROM track WHERE id IN ({string.Join(",", given)})").ToHashSet();
        var songs = given.Where(known.Contains).ToList();
        if (item.Kind == "playlistCreate")
        {
            if (item.PlaylistId is not { } localId || FindPlaylist(db, localId, deviceId) is not null) return;
            var name = item.Name?.Trim() is { Length: > 0 } trimmed ? trimmed : "New Playlist";
            db.Execute("INSERT INTO playlist (name, createdAt) VALUES (?, ?)", name, item.Date);
            var made = db.LastInsertRowId();
            Append(db, songs, made);
            db.Execute("UPDATE deviceHistoryEvent SET localPlaylistId = ?, playlistId = ? WHERE deviceId = ? AND eventId = ?", localId, made, deviceId, item.Id);
            return;
        }
        if (FindPlaylist(db, item.PlaylistId, deviceId) is not { Id: { } id } target) return;
        switch (item.Kind)
        {
            case "playlistAdd" when !target.IsSmart:
                Append(db, songs, id);
                break;
            case "playlistRemove" when !target.IsSmart:
                var removed = given.ToHashSet();
                var kept = db.TracksOfPlaylist(id).Select(track => track.Id ?? -1).Where(trackId => !removed.Contains(trackId)).ToList();
                db.Execute("DELETE FROM playlistItem WHERE playlistId = ?", id);
                Append(db, kept, id);
                break;
            case "playlistRename":
                if (item.Name?.Trim() is { Length: > 0 } name) db.Execute("UPDATE playlist SET name = ? WHERE id = ?", name, id);
                break;
            case "playlistDelete":
                db.Execute("DELETE FROM playlist WHERE id = ?", id);
                break;
        }
    }
}

/// <summary>
/// The library as a player device needs it, for the songs on that device: what the computer knows about each song
/// (tags as shown, loudness, loves, ratings, play history, lyrics, cover), their albums, and the playlists holding them.
/// Ids are the computer's, so what happens on the device maps back to the same songs.
/// </summary>
public sealed record DeviceSnapshot
{
    public const int CurrentVersion = 1;

    public sealed record Song(long Id, string Path, string Title, string Artist, string AlbumKey, int? DiscNumber, int? TrackNumber, string? Genre, int? Year,
                              double Duration, string Codec, int? SampleRate, int? BitDepth, double? TrackGain, double? AlbumGain, double? Loudness, bool Loved,
                              DateTime? LovedAt, int Rating, int PlayCount, DateTime? LastPlayed, DateTime DateAdded, string? Lyrics, string? ArtworkHash);

    public sealed record Album(string Key, string Title, string Artist, int? Year, bool IsCompilation, string? ArtworkHash);

    /// <summary>A playlist's cover as the computer draws it: "generated", "image" or "songs".</summary>
    public sealed record Cover(string Style, string? Palette, string? Pattern, string? ImageHash, bool ShowsTitle);

    /// <summary>A smart playlist's rules, for the device to evaluate them on its own songs (dates in ISO 8601, as the rest).</summary>
    public sealed record Playlist(long Id, string Name, bool IsSmart, List<long> SongIds, Cover? Cover, SmartPlaylistRules? Rules);

    public sealed record Credit(string Name, List<string> Roles, string AlbumKey, long? TrackId, bool WholeRelease);

    public sealed record EqBand(bool IsEnabled, string Type, double Frequency, double Gain, double Q);

    public sealed record EqPreset(string Name, double Preamp, List<EqBand> Bands);

    public sealed record Equalizer(List<EqPreset> Presets, EqPreset? Current, bool IsEnabled);

    public sealed record Artist(string Name, string ArtworkHash);

    public int Version { get; init; } = CurrentVersion;
    public DateTime CreatedAt { get; init; } = DateTime.UtcNow;
    public List<Song> Songs { get; init; } = [];
    public List<Album> Albums { get; init; } = [];
    public List<Playlist> Playlists { get; init; } = [];
    public List<Credit>? Credits { get; init; }
    [JsonPropertyName("equalizer")] public Equalizer? EqualizerSettings { get; init; }
    public List<Artist>? Artists { get; init; }

    /// <summary>
    /// The snapshot for the songs on a device: <paramref name="paths"/> maps each song's id to its path there,
    /// <paramref name="codecs"/> the converted ones to their codec there.
    /// </summary>
    public static DeviceSnapshot Build(SqliteConnection db, IReadOnlyDictionary<long, string> paths, IReadOnlyDictionary<long, string>? codecs = null, Equalizer? equalizer = null)
    {
        codecs ??= new Dictionary<long, string>();
        var songs = new List<Song>();
        var albums = new Dictionary<string, Album>();
        foreach (var track in db.TracksWithIds(paths.Keys))
        {
            if (track.Id is not { } id || !paths.TryGetValue(id, out var path)) continue;
            var artwork = track.FetchedArtworkHash ?? track.ArtworkHash;
            // An encoded song: its format's sample rate, no bit depth (lossy).
            var lossy = codecs.TryGetValue(id, out var codec) ? LossyEncodings.All.Cast<LossyEncoding?>().FirstOrDefault(encoding => encoding!.Value.Codec() == codec) : null;
            songs.Add(new Song(id, path, track.Title, track.DisplayArtist, track.AlbumKey, track.DiscNumber, track.TrackNumber, track.Genre?.Trim().NonEmpty(), track.Year,
                track.Duration, codec ?? CodecNames.RawValue(track.Format), track.SampleRate is { } rate ? (int)(lossy?.OutputRate(rate) ?? rate) : null,
                lossy is null ? track.BitDepth : null, track.ReplayGainTrackGain, track.ReplayGainAlbumGain, track.Loudness, track.IsLoved, track.LovedAt, track.Rating,
                track.PlayCount, track.LastPlayedAt, track.DateAdded, track.DisplayLyrics(), artwork));
            if (!albums.TryGetValue(track.AlbumKey, out var album))
                albums[track.AlbumKey] = new Album(track.AlbumKey, track.DisplayAlbum, track.IsCompilation ? "Various Artists" : track.DisplayAlbumArtist, track.Year, track.IsCompilation, artwork);
            else if (album.ArtworkHash is null && artwork is not null) albums[track.AlbumKey] = album with { ArtworkHash = artwork };
        }
        var playlists = new List<Playlist>();
        foreach (var playlist in db.Playlists())
        {
            if (playlist.Id is not { } id) continue;
            var all = db.TracksOfPlaylist(id).Select(track => track.Id ?? -1).ToList();
            var songIds = all.Where(paths.ContainsKey).ToList();
            var rules = playlist.Rules;
            // Playlists with songs on the device, empty ones (to add songs to there), and smart ones (evaluated there).
            if (songIds.Count > 0 || (all.Count == 0 && !playlist.IsSmart) || rules is not null)
                playlists.Add(new Playlist(id, playlist.Name, playlist.IsSmart, songIds, CoverOf(playlist.CoverStyle), rules));
        }
        // Credits of the albums on the device; song credits only for songs that are there.
        var credits = new List<Credit>();
        var keys = albums.Keys.ToList();
        for (var start = 0; start < keys.Count; start += 500)
        {
            var chunk = keys.Skip(start).Take(500).ToList();
            var marks = string.Join(",", chunk.Select(_ => "?"));
            var rows = db.Query($"SELECT name, roles, albumKey, trackId, wholeRelease FROM creditIndex WHERE albumKey IN ({marks}) ORDER BY id",
                row => new Credit(row.Get<string>("name")!, row.Get<string>("roles")!.Split('\n').ToList(), row.Get<string>("albumKey")!, row.Get<long?>("trackId"),
                    row.Get<bool>("wholeRelease")), chunk.Cast<object?>().ToArray());
            // Song credits only for songs that are there.
            credits.AddRange(rows.Where(credit => credit.TrackId is not { } songId || paths.ContainsKey(songId)));
        }
        var names = albums.Values.Where(album => !album.IsCompilation).Select(album => album.Artist).Concat(songs.Select(song => song.Artist)).ToHashSet();
        var artists = db.ArtistPhotos(names).Select(pair => new Artist(pair.Key, pair.Value)).OrderBy(artist => artist.Name, StringComparer.Ordinal).ToList();
        return new DeviceSnapshot
        {
            Songs = songs.OrderBy(song => song.Id).ToList(), Albums = albums.Values.OrderBy(album => album.Key, StringComparer.Ordinal).ToList(), Playlists = playlists,
            Credits = credits, EqualizerSettings = equalizer, Artists = artists,
        };
    }

    private static Cover? CoverOf(PlaylistCover? cover) => cover?.Kind switch
    {
        PlaylistCoverKind.Generated generated => new Cover("generated", generated.Palette, generated.Pattern, null, true),
        PlaylistCoverKind.Image image => new Cover("image", null, null, image.Hash, cover.ShowsTitle),
        PlaylistCoverKind.SongCovers => new Cover("songs", null, null, null, true),
        _ => null,
    };
}
