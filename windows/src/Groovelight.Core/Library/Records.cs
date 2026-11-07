using Microsoft.Data.Sqlite;

namespace Groovelight.Core.Library;

/// <summary>Reading and writing the library's records (GRDB's record types on the Mac).</summary>
public static class Records
{
    private static readonly string[] TrackColumns =
    [
        "rootId", "path", "fileSize", "modifiedAt", "title", "artist", "album", "albumArtist", "composer", "genre", "year",
        "trackNumber", "trackTotal", "discNumber", "discTotal", "isCompilation", "bpm", "comment", "lyrics",
        "musicBrainzRecordingId", "musicBrainzReleaseId", "replayGainTrackGain", "replayGainAlbumGain", "duration", "format",
        "sampleRate", "bitDepth", "bitrate", "channels", "artworkHash", "albumKey", "rating", "isLoved", "playCount", "skipCount",
        "lastPlayedAt", "dateAdded", "metadataOverrides", "fetchedLyrics", "lyricsCheckedAt", "fetchedArtworkHash", "lovedAt",
        "audioPath", "startTime", "endTime", "loudness", "loudnessCheckedAt",
    ];

    private static object?[] TrackValues(Track t) =>
    [
        t.RootId, t.Path, t.FileSize, t.ModifiedAt, t.Title, t.Artist, t.Album, t.AlbumArtist, t.Composer, t.Genre, t.Year,
        t.TrackNumber, t.TrackTotal, t.DiscNumber, t.DiscTotal, t.IsCompilation, t.Bpm, t.Comment, t.Lyrics,
        t.MusicBrainzRecordingId, t.MusicBrainzReleaseId, t.ReplayGainTrackGain, t.ReplayGainAlbumGain, t.Duration, t.Format,
        t.SampleRate, t.BitDepth, t.Bitrate, t.Channels, t.ArtworkHash, t.AlbumKey, t.Rating, t.IsLoved, t.PlayCount, t.SkipCount,
        t.LastPlayedAt, t.DateAdded, t.MetadataOverrides, t.FetchedLyrics, t.LyricsCheckedAt, t.FetchedArtworkHash, t.LovedAt,
        t.AudioPath, t.StartTime, t.EndTime, t.Loudness, t.LoudnessCheckedAt,
    ];

    private static readonly string InsertTrackSql =
        $"INSERT INTO track ({string.Join(", ", TrackColumns)}) VALUES ({string.Join(", ", TrackColumns.Select(_ => "?"))})";

    private static readonly string UpdateTrackSql =
        $"UPDATE track SET {string.Join(", ", TrackColumns.Select(column => column + " = ?"))} WHERE id = ?";

    public static Track ReadTrack(Row row) => new()
    {
        Id = row.Get<long?>("id"),
        RootId = row.Get<long>("rootId"),
        Path = row.Required<string>("path"),
        FileSize = row.Get<long>("fileSize"),
        ModifiedAt = row.Get<DateTime>("modifiedAt"),
        Title = row.Get<string>("title") ?? "",
        Artist = row.Get<string>("artist"),
        Album = row.Get<string>("album"),
        AlbumArtist = row.Get<string>("albumArtist"),
        Composer = row.Get<string>("composer"),
        Genre = row.Get<string>("genre"),
        Year = row.Get<int?>("year"),
        TrackNumber = row.Get<int?>("trackNumber"),
        TrackTotal = row.Get<int?>("trackTotal"),
        DiscNumber = row.Get<int?>("discNumber"),
        DiscTotal = row.Get<int?>("discTotal"),
        IsCompilation = row.Get<bool>("isCompilation"),
        Bpm = row.Get<int?>("bpm"),
        Comment = row.Get<string>("comment"),
        Lyrics = row.Get<string>("lyrics"),
        MusicBrainzRecordingId = row.Get<string>("musicBrainzRecordingId"),
        MusicBrainzReleaseId = row.Get<string>("musicBrainzReleaseId"),
        ReplayGainTrackGain = row.Get<double?>("replayGainTrackGain"),
        ReplayGainAlbumGain = row.Get<double?>("replayGainAlbumGain"),
        Duration = row.Get<double>("duration"),
        Format = row.Get<string>("format"),
        SampleRate = row.Get<double?>("sampleRate"),
        BitDepth = row.Get<int?>("bitDepth"),
        Bitrate = row.Get<double?>("bitrate"),
        Channels = row.Get<int?>("channels"),
        ArtworkHash = row.Get<string>("artworkHash"),
        AlbumKey = row.Get<string>("albumKey") ?? "",
        Rating = row.Get<int>("rating"),
        IsLoved = row.Get<bool>("isLoved"),
        PlayCount = row.Get<int>("playCount"),
        SkipCount = row.Get<int>("skipCount"),
        LastPlayedAt = row.Get<DateTime?>("lastPlayedAt"),
        DateAdded = row.Get<DateTime>("dateAdded"),
        MetadataOverrides = row.Get<byte[]>("metadataOverrides"),
        FetchedLyrics = row.Get<string>("fetchedLyrics"),
        LyricsCheckedAt = row.Get<DateTime?>("lyricsCheckedAt"),
        FetchedArtworkHash = row.Get<string>("fetchedArtworkHash"),
        LovedAt = row.Get<DateTime?>("lovedAt"),
        AudioPath = row.Get<string>("audioPath"),
        StartTime = row.Get<double?>("startTime"),
        EndTime = row.Get<double?>("endTime"),
        Loudness = row.Get<double?>("loudness"),
        LoudnessCheckedAt = row.Get<DateTime?>("loudnessCheckedAt"),
    };

    /// <summary>Inserts the track and sets its id.</summary>
    public static void Insert(this SqliteConnection connection, Track track)
    {
        connection.Execute(InsertTrackSql, TrackValues(track));
        track.Id = connection.LastInsertRowId();
    }

    public static void Update(this SqliteConnection connection, Track track)
    {
        if (track.Id is not { } id) throw new InvalidOperationException("The track was never saved.");
        connection.Execute(UpdateTrackSql, [.. TrackValues(track), id]);
    }

    public static Track? FetchTrack(this SqliteConnection connection, long id) =>
        connection.QueryOne("SELECT * FROM track WHERE id = ?", ReadTrack, id);

    public static List<Track> FetchTracks(this SqliteConnection connection, string sql, params object?[] arguments) =>
        connection.Query(sql, ReadTrack, arguments);

    public static LibraryRoot ReadRoot(Row row) => new()
    {
        Id = row.Get<long?>("id"),
        Path = row.Required<string>("path"),
        Bookmark = row.Get<byte[]>("bookmark") ?? [],
        AddedAt = row.Get<DateTime>("addedAt"),
        LastScanAt = row.Get<DateTime?>("lastScanAt"),
        EventId = row.Get<long?>("eventId"),
        EventsVolumeId = row.Get<string>("eventsVolumeId"),
        LastFullScanAt = row.Get<DateTime?>("lastFullScanAt"),
    };

    public static void Insert(this SqliteConnection connection, LibraryRoot root)
    {
        connection.Execute("""
            INSERT INTO libraryRoot (path, bookmark, addedAt, lastScanAt, eventId, eventsVolumeId, lastFullScanAt) VALUES (?, ?, ?, ?, ?, ?, ?)
            """, root.Path, root.Bookmark, root.AddedAt, root.LastScanAt, root.EventId, root.EventsVolumeId, root.LastFullScanAt);
        root.Id = connection.LastInsertRowId();
    }

    public static void Update(this SqliteConnection connection, LibraryRoot root) =>
        connection.Execute("""
            UPDATE libraryRoot SET path = ?, bookmark = ?, addedAt = ?, lastScanAt = ?, eventId = ?, eventsVolumeId = ?, lastFullScanAt = ?
            WHERE id = ?
            """, root.Path, root.Bookmark, root.AddedAt, root.LastScanAt, root.EventId, root.EventsVolumeId, root.LastFullScanAt, root.Id);

    public static Playlist ReadPlaylist(Row row) => new()
    {
        Id = row.Get<long?>("id"),
        Name = row.Required<string>("name"),
        CreatedAt = row.Get<DateTime>("createdAt"),
        SmartRules = row.Get<byte[]>("smartRules"),
        Cover = row.Get<byte[]>("cover"),
    };

    public static void Insert(this SqliteConnection connection, Playlist playlist)
    {
        connection.Execute("INSERT INTO playlist (name, createdAt, smartRules, cover) VALUES (?, ?, ?, ?)",
                           playlist.Name, playlist.CreatedAt, playlist.SmartRules, playlist.Cover);
        playlist.Id = connection.LastInsertRowId();
    }

    public static Playlist? FetchPlaylist(this SqliteConnection connection, long id) =>
        connection.QueryOne("SELECT * FROM playlist WHERE id = ?", ReadPlaylist, id);

    public static AlbumSummary ReadAlbum(Row row) => new(
        row.Required<string>("albumKey"), row.Get<string>("title") ?? "", row.Get<string>("artist") ?? "", row.Get<int?>("year"),
        row.Get<string>("genre"), row.Get<int>("trackCount"), row.Get<double>("duration"), row.Get<string>("artworkHash"),
        row.Get<DateTime>("dateAdded"));

    public static ArtistSummary ReadArtist(Row row) => new(
        row.Get<string>("name") ?? "", row.Get<int>("albumCount"), row.Get<int>("trackCount"), row.Get<string>("artworkHash"));
}
