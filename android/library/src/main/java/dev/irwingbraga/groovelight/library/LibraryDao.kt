package dev.irwingbraga.groovelight.library

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Transaction
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

@Dao
interface LibraryDao {
    @Query("SELECT * FROM album ORDER BY artistName COLLATE NOCASE, year, title COLLATE NOCASE")
    fun albums(): Flow<List<Album>>

    @Query("SELECT * FROM artist ORDER BY sortName COLLATE NOCASE")
    fun artists(): Flow<List<Artist>>

    @Query("SELECT * FROM track WHERE albumId = :albumId ORDER BY IFNULL(discNumber, 1), IFNULL(trackNumber, 0), title COLLATE NOCASE")
    fun tracksOfAlbum(albumId: Long): Flow<List<Track>>

    @Query("SELECT * FROM playlist ORDER BY name COLLATE NOCASE")
    fun playlists(): Flow<List<Playlist>>

    @Query("SELECT track.* FROM playlist_item JOIN track ON track.id = playlist_item.trackId WHERE playlistId = :playlistId ORDER BY position")
    fun tracksOfPlaylist(playlistId: Long): Flow<List<Track>>

    @Query("SELECT COUNT(*) FROM track")
    suspend fun trackCount(): Int

    @Upsert suspend fun upsertArtists(artists: List<Artist>)
    @Upsert suspend fun upsertAlbums(albums: List<Album>)
    @Upsert suspend fun upsertTracks(tracks: List<Track>)
    @Upsert suspend fun upsertPlaylists(playlists: List<Playlist>)

    /** Songs that left the device (their playlist entries go with them). */
    @Query("DELETE FROM track WHERE id IN (:ids)")
    suspend fun deleteTracks(ids: List<Long>)

    @Query("DELETE FROM playlist_item WHERE playlistId = :playlistId")
    suspend fun clearPlaylist(playlistId: Long)

    @Upsert suspend fun upsertPlaylistItems(items: List<PlaylistItem>)

    /** Replaces a playlist's songs, in order. */
    @Transaction
    suspend fun setPlaylistTracks(playlistId: Long, trackIds: List<Long>) {
        clearPlaylist(playlistId)
        upsertPlaylistItems(trackIds.mapIndexed { index, id -> PlaylistItem(playlistId, index, id) })
    }
}
