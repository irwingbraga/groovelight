using Microsoft.Data.Sqlite;

namespace Groovelight.Core.Library;

/// <summary>The library's changes, the same as the Mac's.</summary>
public sealed partial class LibraryDatabase
{
    public Playlist CreatePlaylist(string name, IReadOnlyList<long>? trackIds = null, PlaylistCover? cover = null) => Write(db =>
    {
        var playlist = new Playlist { Name = name, Cover = cover is null ? null : SwiftJson.Encode(cover) };
        db.Insert(playlist);
        Append(db, trackIds ?? [], playlist.Id!.Value);
        return playlist;
    });

    public void AddTracks(IReadOnlyList<long> trackIds, long playlistId) => Write(db => Append(db, trackIds, playlistId));

    public void RenamePlaylist(long playlistId, string name) =>
        Write(db => db.Execute("UPDATE playlist SET name = ? WHERE id = ?", name, playlistId));

    /// <summary>Renames a playlist and sets its cover (null shows the songs' covers).</summary>
    public void UpdatePlaylist(long playlistId, string name, PlaylistCover? cover) =>
        Write(db => db.Execute("UPDATE playlist SET name = ?, cover = ? WHERE id = ?", name, cover is null ? null : SwiftJson.Encode(cover), playlistId));

    public void DeletePlaylist(long playlistId) => Write(db => db.Execute("DELETE FROM playlist WHERE id = ?", playlistId));

    /// <summary>Rewrites the playlist order to exactly <paramref name="trackIds"/>.</summary>
    public void SetPlaylistTracks(long playlistId, IReadOnlyList<long> trackIds) => Write(db =>
    {
        db.Execute("DELETE FROM playlistItem WHERE playlistId = ?", playlistId);
        Append(db, trackIds, playlistId);
    });

    internal static void Append(SqliteConnection db, IReadOnlyList<long> trackIds, long playlistId)
    {
        var start = db.Scalar<long>("SELECT COALESCE(MAX(position) + 1, 0) FROM playlistItem WHERE playlistId = ?", playlistId);
        for (var offset = 0; offset < trackIds.Count; offset++)
        {
            db.Execute("INSERT INTO playlistItem (playlistId, trackId, position) VALUES (?, ?, ?)", playlistId, trackIds[offset], start + offset);
        }
    }

    public void RecordPlay(long trackId, DateTime? at = null) =>
        Write(db => db.Execute("UPDATE track SET playCount = playCount + 1, lastPlayedAt = ? WHERE id = ?", at ?? DateTime.UtcNow, trackId));

    public void RecordSkip(long trackId) => Write(db => db.Execute("UPDATE track SET skipCount = skipCount + 1 WHERE id = ?", trackId));

    public void SetLoved(bool loved, long trackId, DateTime? at = null) => SetLoved(loved, [trackId], at);

    public void SetLoved(bool loved, IReadOnlyList<long> trackIds, DateTime? at = null)
    {
        var date = at ?? DateTime.UtcNow;
        Write(db =>
        {
            foreach (var id in trackIds)
            {
                // Loving an already loved song keeps its original date.
                db.Execute("""
                    UPDATE track SET lovedAt = CASE WHEN ? THEN COALESCE(CASE WHEN isLoved THEN lovedAt END, ?) END, isLoved = ?
                    WHERE id = ?
                    """, loved, date, loved, id);
            }
        });
    }

    public void SetRating(int rating, long trackId) =>
        Write(db => db.Execute("UPDATE track SET rating = ? WHERE id = ?", Math.Clamp(rating, 0, 5), trackId));

    public LibraryRoot AddRoot(string path, byte[]? bookmark = null) => Write(db =>
    {
        var existing = db.QueryOne("SELECT * FROM libraryRoot WHERE path = ?", Records.ReadRoot, path);
        if (existing is not null)
        {
            existing.Bookmark = bookmark ?? existing.Bookmark;
            db.Update(existing);
            return existing;
        }
        var root = new LibraryRoot { Path = path, Bookmark = bookmark ?? [] };
        db.Insert(root);
        return root;
    });

    /// <summary>
    /// Applies metadata fixes. With <paramref name="asOverrides"/>, they are also kept as overrides so a rescan does not
    /// revert them (used when the fix is not written to the file); otherwise existing overrides of those fields are cleared.
    /// </summary>
    public void ApplyMetadata(IReadOnlyDictionary<long, TrackMetadata> changes, bool asOverrides) => Write(db =>
    {
        foreach (var (id, metadata) in changes)
        {
            if (db.FetchTrack(id) is not { } track) continue;
            track.Apply(metadata);
            track.SetOverrides(asOverrides ? (track.GetOverrides() ?? new TrackMetadata()).Merging(metadata) : null);
            db.Update(track);
        }
    });

    /// <summary>Records the file's new size and date after Groovelight rewrote its tags, so the scanner does not reread it.</summary>
    public void UpdateFileInfo(long trackId, long fileSize, DateTime modifiedAt) =>
        Write(db => db.Execute("UPDATE track SET fileSize = ?, modifiedAt = ? WHERE id = ?", fileSize, modifiedAt, trackId));

    /// <summary>Stores lyrics fetched online (null records a miss) and the lookup time.</summary>
    public void SetFetchedLyrics(string? lyrics, long trackId, DateTime? at = null) =>
        Write(db => db.Execute("UPDATE track SET fetchedLyrics = COALESCE(?, fetchedLyrics), lyricsCheckedAt = ? WHERE id = ?",
                               lyrics, at ?? DateTime.UtcNow, trackId));

    /// <summary>Sets an online cover on tracks, replacing the shown artwork.</summary>
    public void SetFetchedArtwork(string hash, IReadOnlyList<long> trackIds) => Write(db =>
    {
        foreach (var id in trackIds) db.Execute("UPDATE track SET fetchedArtworkHash = ?, artworkHash = ? WHERE id = ?", hash, hash, id);
    });

    public void SetArtistInfo(byte[] data, string name, DateTime? at = null) =>
        Write(db => db.Execute("INSERT OR REPLACE INTO artistInfo (artistKey, data, fetchedAt) VALUES (?, ?, ?)",
                               name.ToLowerInvariant(), data, at ?? DateTime.UtcNow));

    public void SetAlbumInfo(byte[] data, string albumKey, DateTime? at = null) =>
        Write(db => db.Execute("INSERT OR REPLACE INTO albumInfo (albumKey, data, fetchedAt) VALUES (?, ?, ?)",
                               albumKey, data, at ?? DateTime.UtcNow));

    /// <summary>
    /// Records that a folder's changes are in the library up to <paramref name="eventId"/> of the volume's change journal
    /// <paramref name="volumeId"/> (null forgets it, so the next launch checks every file).
    /// </summary>
    public void SetWatchState(long rootId, long? eventId, string? volumeId) =>
        Write(db => db.Execute("UPDATE libraryRoot SET eventId = ?, eventsVolumeId = ? WHERE id = ?", eventId, volumeId, rootId));

    public void RemoveRoot(long rootId) => Write(db => db.Execute("DELETE FROM libraryRoot WHERE id = ?", rootId));
}
