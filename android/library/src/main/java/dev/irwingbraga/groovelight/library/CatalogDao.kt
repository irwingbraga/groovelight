package dev.irwingbraga.groovelight.library

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Transaction
import kotlinx.coroutines.flow.Flow

/** The Mac's whole library on the device, what the device's selection holds there, and the requests waiting to be sent. */
@Dao
interface CatalogDao {
    @Query("SELECT * FROM catalog_album ORDER BY artist COLLATE NOCASE, year, title COLLATE NOCASE")
    fun albums(): Flow<List<CatalogAlbum>>

    @Query("SELECT * FROM catalog_album WHERE `key` = :key")
    fun album(key: String): Flow<CatalogAlbum?>

    @Query("SELECT * FROM catalog_album WHERE artist = :artist ORDER BY year, title COLLATE NOCASE")
    fun albumsOf(artist: String): Flow<List<CatalogAlbum>>

    @Query("""
        SELECT artist AS name, COUNT(*) AS albums, MIN(artworkHash) AS artworkHash FROM catalog_album
        WHERE isCompilation = 0 GROUP BY artist ORDER BY artist COLLATE NOCASE
    """)
    fun artists(): Flow<List<CatalogArtist>>

    @Query("SELECT * FROM catalog_track ORDER BY title COLLATE NOCASE")
    fun tracks(): Flow<List<CatalogTrack>>

    @Query("SELECT * FROM catalog_track WHERE albumKey = :key ORDER BY IFNULL(discNumber, 1), IFNULL(trackNumber, 0), title COLLATE NOCASE")
    fun tracksOfAlbum(key: String): Flow<List<CatalogTrack>>

    @Query("SELECT COUNT(*) FROM catalog_track WHERE albumKey = :key") suspend fun trackCount(key: String): Int

    @Query("SELECT * FROM catalog_album WHERE title LIKE :pattern ESCAPE '!' OR artist LIKE :pattern ESCAPE '!' ORDER BY title COLLATE NOCASE LIMIT :limit")
    suspend fun searchAlbums(pattern: String, limit: Int): List<CatalogAlbum>

    @Query("SELECT COUNT(*) FROM catalog_track") fun songCount(): Flow<Int>

    @Query("SELECT COUNT(*) FROM catalog_album") suspend fun albumCount(): Int

    @Query("SELECT * FROM catalog_chosen") fun chosen(): Flow<List<CatalogChosen>>

    @Query("DELETE FROM catalog_album") suspend fun clearAlbums()
    @Query("DELETE FROM catalog_track") suspend fun clearTracks()
    @Query("DELETE FROM catalog_chosen") suspend fun clearChosen()
    @Insert suspend fun insertAlbums(albums: List<CatalogAlbum>)
    @Insert suspend fun insertTracks(tracks: List<CatalogTrack>)
    @Insert suspend fun insertChosen(chosen: List<CatalogChosen>)

    /** Replaces the catalog with the Mac's (and what the selection holds). */
    @Transaction
    suspend fun replace(albums: List<CatalogAlbum>, tracks: List<CatalogTrack>, chosen: List<CatalogChosen>) {
        clearTracks()
        clearAlbums()
        insertAlbums(albums)
        insertTracks(tracks)
        setChosen(chosen)
    }

    @Transaction
    suspend fun setChosen(chosen: List<CatalogChosen>) {
        clearChosen()
        insertChosen(chosen)
    }

    // Requests

    @Insert suspend fun insertRequest(request: TransferRequest): Long

    @Query("SELECT * FROM transfer_request ORDER BY id") suspend fun pendingRequests(): List<TransferRequest>

    @Query("SELECT * FROM transfer_request ORDER BY id") fun pending(): Flow<List<TransferRequest>>

    @Query("DELETE FROM transfer_request WHERE id <= :upTo") suspend fun removeRequests(upTo: Long)
}
