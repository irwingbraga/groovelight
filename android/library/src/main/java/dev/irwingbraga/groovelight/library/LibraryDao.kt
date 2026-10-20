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

    // Search: `pattern` is a LIKE pattern ("%word%", with %, _ and ! escaped by !, see `likePattern`); `match` an FTS
    // query (see `ftsQuery`), over titles, artists, albums and the names credited.

    @Query("""
        SELECT track.* FROM search JOIN track ON track.id = search.rowid WHERE search MATCH :match
        ORDER BY track.title COLLATE NOCASE LIMIT :limit
    """)
    suspend fun searchTracks(match: String, limit: Int): List<Track>

    @Query("SELECT * FROM album WHERE title LIKE :pattern ESCAPE '!' OR artist LIKE :pattern ESCAPE '!' ORDER BY title COLLATE NOCASE LIMIT :limit")
    suspend fun searchAlbums(pattern: String, limit: Int): List<Album>

    @Query("""
        SELECT artist AS name, COUNT(*) AS albums, MIN(artworkHash) AS artworkHash FROM album
        WHERE isCompilation = 0 AND artist LIKE :pattern ESCAPE '!' GROUP BY artist ORDER BY artist COLLATE NOCASE LIMIT :limit
    """)
    suspend fun searchArtists(pattern: String, limit: Int): List<ArtistSummary>

    /** People credited (producers, engineers, players...) whose name matches, with how many albums they are on. */
    @Query("""
        SELECT name, COUNT(DISTINCT albumKey) AS albums FROM credit WHERE name LIKE :pattern ESCAPE '!'
        GROUP BY name ORDER BY albums DESC, name COLLATE NOCASE LIMIT :limit
    """)
    suspend fun searchPeople(pattern: String, limit: Int): List<PersonSummary>

    // Credits

    @Query("SELECT * FROM credit WHERE albumKey = :albumKey ORDER BY id")
    fun creditsOfAlbum(albumKey: String): Flow<List<Credit>>

    /** Everything a person is credited on, as on the Mac's person pages. */
    @Query("SELECT albumKey, trackId, roles FROM credit WHERE name = :name ORDER BY id")
    fun creditsOf(name: String): Flow<List<PersonCredit>>

    @Query("SELECT * FROM album WHERE `key` IN (:keys) ORDER BY year, title COLLATE NOCASE")
    suspend fun albumsWithKeys(keys: List<String>): List<Album>

    @Query("SELECT * FROM track WHERE id IN (:ids)")
    suspend fun tracksWithIds(ids: List<Long>): List<Track>

    // Loves and ratings made here: the song changes at once, and the journal keeps them for the Mac.

    @Query("UPDATE track SET loved = :loved, lovedAt = :at WHERE id = :id")
    suspend fun updateLoved(id: Long, loved: Boolean, at: Long?)

    @Query("UPDATE track SET rating = :rating WHERE id = :id")
    suspend fun updateRating(id: Long, rating: Int)

    @Insert suspend fun insertEvent(event: HistoryEvent)

    @Query("SELECT * FROM history_event WHERE sent = 0 ORDER BY id")
    suspend fun unsentEvents(): List<HistoryEvent>

    @Transaction
    suspend fun setLoved(id: Long, loved: Boolean, at: Long = System.currentTimeMillis()) {
        updateLoved(id, loved, if (loved) at else null)
        insertEvent(HistoryEvent(trackId = id, kind = HistoryEvent.LOVE, value = if (loved) 1 else 0, at = at))
    }

    @Transaction
    suspend fun setRating(id: Long, stars: Int, at: Long = System.currentTimeMillis()) {
        updateRating(id, stars.coerceIn(0, 5))
        insertEvent(HistoryEvent(trackId = id, kind = HistoryEvent.RATING, value = stars.coerceIn(0, 5), at = at))
    }

    // The Mac's equalizer

    @Query("SELECT * FROM mac_eq_preset ORDER BY isCurrent DESC, name COLLATE NOCASE")
    fun macEqPresets(): Flow<List<MacEqPreset>>

    @Query("""
        SELECT playlist.id, playlist.name, playlist.isSmart, COUNT(playlist_item.trackId) AS songs, playlist.coverStyle,
            playlist.coverPalette, playlist.coverPattern, playlist.coverHash, playlist.coverShowsTitle,
            (SELECT track.artworkHash FROM playlist_item AS opening JOIN track ON track.id = opening.trackId
             WHERE opening.playlistId = playlist.id AND track.artworkHash IS NOT NULL ORDER BY opening.position LIMIT 1) AS artworkHash
        FROM playlist LEFT JOIN playlist_item ON playlist_item.playlistId = playlist.id
        GROUP BY playlist.id ORDER BY playlist.name COLLATE NOCASE
    """)
    fun playlists(): Flow<List<PlaylistSummary>>

    @Query("SELECT * FROM playlist WHERE id = :id")
    fun playlist(id: Long): Flow<Playlist?>

    /** Up to four different covers of a playlist's songs, in order, for its mosaic. */
    @Query("""
        SELECT track.artworkHash FROM playlist_item JOIN track ON track.id = playlist_item.trackId
        WHERE playlistId = :playlistId AND track.artworkHash IS NOT NULL GROUP BY track.artworkHash ORDER BY MIN(position) LIMIT 4
    """)
    suspend fun playlistCovers(playlistId: Long): List<String>

    @Query("SELECT track.* FROM playlist_item JOIN track ON track.id = playlist_item.trackId WHERE playlistId = :playlistId ORDER BY position")
    fun tracksOfPlaylist(playlistId: Long): Flow<List<Track>>

    @Query("SELECT * FROM track WHERE loved = 1 ORDER BY lovedAt IS NULL, lovedAt DESC, title COLLATE NOCASE")
    fun lovedTracks(): Flow<List<Track>>

    @Query("SELECT COUNT(*) FROM track")
    suspend fun trackCount(): Int

    @Query("""
        SELECT DISTINCT artworkHash FROM album WHERE artworkHash IS NOT NULL UNION SELECT DISTINCT artworkHash FROM track
        WHERE artworkHash IS NOT NULL UNION SELECT DISTINCT coverHash FROM playlist WHERE coverHash IS NOT NULL
    """)
    suspend fun artworkHashes(): List<String>

    @Query("DELETE FROM playlist_item") suspend fun clearPlaylistItems()
    @Query("DELETE FROM playlist") suspend fun clearPlaylists()
    @Query("DELETE FROM track") suspend fun clearTracks()
    @Query("DELETE FROM album") suspend fun clearAlbums()
    @Query("DELETE FROM credit") suspend fun clearCredits()
    @Query("DELETE FROM search") suspend fun clearSearch()
    @Query("DELETE FROM mac_eq_preset") suspend fun clearMacEqPresets()

    @Insert suspend fun insertAlbums(albums: List<Album>)
    @Insert suspend fun insertTracks(tracks: List<Track>)
    @Insert suspend fun insertPlaylists(playlists: List<Playlist>)
    @Insert suspend fun insertPlaylistItems(items: List<PlaylistItem>)
    @Insert suspend fun insertCredits(credits: List<Credit>)
    @Insert suspend fun insertSearch(entries: List<SearchEntry>)
    @Insert suspend fun insertMacEqPresets(presets: List<MacEqPreset>)

    /**
     * Replaces the library with a snapshot's, in one transaction (screens see the old or the new one, never half).
     * Loves and ratings made here and not sent to the Mac yet are applied again over it.
     */
    @Transaction
    suspend fun replace(snapshot: Snapshot) {
        clearPlaylistItems()
        clearPlaylists()
        clearCredits()
        clearSearch()
        clearTracks()
        clearAlbums()
        insertAlbums(snapshot.albums)
        insertTracks(snapshot.tracks)
        insertPlaylists(snapshot.playlists)
        insertPlaylistItems(snapshot.items)
        insertCredits(snapshot.credits)
        insertSearch(snapshot.searchEntries())
        // An older Mac sends no equalizer: the presets it sent before are kept.
        if (snapshot.equalizer.isNotEmpty()) {
            clearMacEqPresets()
            insertMacEqPresets(snapshot.equalizer)
        }
        for (event in unsentEvents()) when (event.kind) {
            HistoryEvent.LOVE -> updateLoved(event.trackId, event.value == 1, if (event.value == 1) event.at else null)
            HistoryEvent.RATING -> updateRating(event.trackId, event.value)
        }
    }
}

/** A LIKE pattern matching `text` anywhere, for the search queries. */
fun likePattern(text: String): String =
    "%" + text.trim().replace("!", "!!").replace("%", "!%").replace("_", "!_") + "%"

/**
 * An FTS query finding rows with every word typed, each as a prefix ("radio ok" finds "Radiohead", "OK Computer"):
 * words are quoted so FTS syntax typed by the user (AND, *, quotes) is searched as text. Null when there are no words.
 */
fun ftsQuery(text: String): String? {
    val words = text.split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }
    if (words.isEmpty()) return null
    return words.joinToString(" ") { "\"$it*\"" }
}
