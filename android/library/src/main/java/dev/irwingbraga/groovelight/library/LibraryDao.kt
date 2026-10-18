package dev.irwingbraga.groovelight.library

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Transaction
import kotlinx.coroutines.flow.Flow

@Dao
interface LibraryDao {
    @Query("SELECT * FROM album ORDER BY artist COLLATE NOCASE, year, title COLLATE NOCASE")
    fun albums(): Flow<List<Album>>

    @Query("SELECT * FROM album WHERE artist = :artist ORDER BY year, title COLLATE NOCASE")
    fun albumsOf(artist: String): Flow<List<Album>>

    /** Albums by others with songs of this artist (compilations, features). */
    @Query("""
        SELECT DISTINCT album.* FROM album JOIN track ON track.albumKey = album.`key`
        WHERE track.artist = :artist AND album.artist != :artist ORDER BY album.year, album.title COLLATE NOCASE
    """)
    fun albumsAppearingOn(artist: String): Flow<List<Album>>

    @Query("SELECT * FROM album WHERE `key` = :key")
    fun album(key: String): Flow<Album?>

    /** Albums by when their newest song was added on the Mac, newest first. */
    @Query("SELECT album.* FROM album JOIN track ON track.albumKey = album.`key` GROUP BY album.`key` ORDER BY MAX(track.dateAdded) DESC")
    fun recentAlbums(): Flow<List<Album>>

    @Query("""
        SELECT artist AS name, COUNT(*) AS albums, MIN(artworkHash) AS artworkHash FROM album
        WHERE isCompilation = 0 GROUP BY artist ORDER BY artist COLLATE NOCASE
    """)
    fun artists(): Flow<List<ArtistSummary>>

    @Query("SELECT * FROM track WHERE albumKey = :albumKey ORDER BY IFNULL(discNumber, 1), IFNULL(trackNumber, 0), title COLLATE NOCASE")
    fun tracksOfAlbum(albumKey: String): Flow<List<Track>>

    @Query("SELECT * FROM track ORDER BY title COLLATE NOCASE")
    fun tracks(): Flow<List<Track>>

    @Query("SELECT * FROM track WHERE id = :id")
    fun track(id: Long): Flow<Track?>

    /** An artist's songs: on their albums, and theirs on other albums (compilations, features), album by album. */
    @Query("""
        SELECT track.* FROM track JOIN album ON album.`key` = track.albumKey WHERE album.artist = :artist OR track.artist = :artist
        ORDER BY album.year, album.title COLLATE NOCASE, IFNULL(track.discNumber, 1), IFNULL(track.trackNumber, 0)
    """)
    fun tracksOfArtist(artist: String): Flow<List<Track>>

    // Search: `pattern` is a LIKE pattern ("%word%", with %, _ and ! escaped by !, see `likePattern`).

    @Query("SELECT * FROM track WHERE title LIKE :pattern ESCAPE '!' OR artist LIKE :pattern ESCAPE '!' ORDER BY title COLLATE NOCASE LIMIT :limit")
    suspend fun searchTracks(pattern: String, limit: Int): List<Track>

    @Query("SELECT * FROM album WHERE title LIKE :pattern ESCAPE '!' OR artist LIKE :pattern ESCAPE '!' ORDER BY title COLLATE NOCASE LIMIT :limit")
    suspend fun searchAlbums(pattern: String, limit: Int): List<Album>

    @Query("""
        SELECT artist AS name, COUNT(*) AS albums, MIN(artworkHash) AS artworkHash FROM album
        WHERE isCompilation = 0 AND artist LIKE :pattern ESCAPE '!' GROUP BY artist ORDER BY artist COLLATE NOCASE LIMIT :limit
    """)
    suspend fun searchArtists(pattern: String, limit: Int): List<ArtistSummary>

    @Query("""
        SELECT playlist.id, playlist.name, playlist.isSmart, COUNT(playlist_item.trackId) AS songs,
            (SELECT track.artworkHash FROM playlist_item AS opening JOIN track ON track.id = opening.trackId
             WHERE opening.playlistId = playlist.id AND track.artworkHash IS NOT NULL ORDER BY opening.position LIMIT 1) AS artworkHash
        FROM playlist LEFT JOIN playlist_item ON playlist_item.playlistId = playlist.id
        GROUP BY playlist.id ORDER BY playlist.name COLLATE NOCASE
    """)
    fun playlists(): Flow<List<PlaylistSummary>>

    @Query("SELECT * FROM playlist WHERE id = :id")
    fun playlist(id: Long): Flow<Playlist?>

    @Query("SELECT track.* FROM playlist_item JOIN track ON track.id = playlist_item.trackId WHERE playlistId = :playlistId ORDER BY position")
    fun tracksOfPlaylist(playlistId: Long): Flow<List<Track>>

    @Query("SELECT * FROM track WHERE loved = 1 ORDER BY lovedAt IS NULL, lovedAt DESC, title COLLATE NOCASE")
    fun lovedTracks(): Flow<List<Track>>

    @Query("SELECT COUNT(*) FROM track")
    suspend fun trackCount(): Int

    @Query("SELECT DISTINCT artworkHash FROM album WHERE artworkHash IS NOT NULL UNION SELECT DISTINCT artworkHash FROM track WHERE artworkHash IS NOT NULL")
    suspend fun artworkHashes(): List<String>

    @Query("DELETE FROM playlist_item") suspend fun clearPlaylistItems()
    @Query("DELETE FROM playlist") suspend fun clearPlaylists()
    @Query("DELETE FROM track") suspend fun clearTracks()
    @Query("DELETE FROM album") suspend fun clearAlbums()

    @Insert suspend fun insertAlbums(albums: List<Album>)
    @Insert suspend fun insertTracks(tracks: List<Track>)
    @Insert suspend fun insertPlaylists(playlists: List<Playlist>)
    @Insert suspend fun insertPlaylistItems(items: List<PlaylistItem>)

    /** Replaces the library with a snapshot's, in one transaction (screens see the old or the new one, never half). */
    @Transaction
    suspend fun replace(albums: List<Album>, tracks: List<Track>, playlists: List<Playlist>, items: List<PlaylistItem>) {
        clearPlaylistItems()
        clearPlaylists()
        clearTracks()
        clearAlbums()
        insertAlbums(albums)
        insertTracks(tracks)
        insertPlaylists(playlists)
        insertPlaylistItems(items)
    }
}

/** A LIKE pattern matching `text` anywhere, for the search queries. */
fun likePattern(text: String): String =
    "%" + text.trim().replace("!", "!!").replace("%", "!%").replace("_", "!_") + "%"
