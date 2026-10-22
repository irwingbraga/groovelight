package dev.irwingbraga.groovelight.app

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import dev.irwingbraga.groovelight.library.Album
import dev.irwingbraga.groovelight.library.LibraryDatabase
import dev.irwingbraga.groovelight.library.Playlist
import dev.irwingbraga.groovelight.library.PlaylistItem
import dev.irwingbraga.groovelight.library.Track
import dev.irwingbraga.groovelight.playback.Browsing
import dev.irwingbraga.groovelight.sync.Prefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = android.app.Application::class)
class LibraryBrowsingTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()

    private suspend fun seed() {
        Prefs(context).folder = "content://com.android.externalstorage.documents/tree/primary%3AMusic"
        // The database is the app's one (a singleton): emptied for each test.
        withContext(Dispatchers.IO) { LibraryDatabase.get(context).clearAllTables() }
        val library = LibraryDatabase.get(context).library()
        library.insertAlbums(listOf(Album("radiohead|ok computer", "OK Computer", "Radiohead", 1997), Album("x|hits", "Hits", "Someone")))
        library.insertTracks(listOf(
            Track(101, "Airbag", "Radiohead", "radiohead|ok computer", trackNumber = 1, path = "a.flac", codec = "flac", loved = true),
            Track(102, "Paranoid Android", "Radiohead", "radiohead|ok computer", trackNumber = 2, path = "b.flac", codec = "flac"),
            Track(201, "Song", "Someone", "x|hits", trackNumber = 1, path = "c.mp3", codec = "mp3"),
        ))
        library.insertPlaylists(listOf(Playlist(7, "Mix")))
        library.insertPlaylistItems(listOf(PlaylistItem(7, 0, 201), PlaylistItem(7, 1, 102)))
    }

    @Test
    fun browsesTheLibraryDownToItsSongs() = runTest {
        seed()
        val browsing = LibraryBrowsing(context)
        assertEquals(listOf("recent", "albums", "artists", "playlists"), browsing.children(Browsing.ROOT).map { it.mediaId })
        val albums = browsing.children("albums")
        assertEquals(listOf("album:radiohead|ok computer", "album:x|hits"), albums.map { it.mediaId }.sorted())
        assertTrue(albums.all { it.mediaMetadata.isBrowsable == true && it.mediaMetadata.isPlayable == true })
        assertEquals(listOf("artist:Radiohead", "artist:Someone"), browsing.children("artists").map { it.mediaId })
        assertEquals(listOf("album:radiohead|ok computer"), browsing.children("artist:Radiohead").map { it.mediaId })
        assertEquals(listOf("song:101@album:radiohead|ok computer", "song:102@album:radiohead|ok computer"),
            browsing.children("album:radiohead|ok computer").map { it.mediaId })
        assertEquals(listOf("loved", "playlist:7"), browsing.children("playlists").map { it.mediaId })
        assertEquals(listOf("Airbag"), browsing.children("loved").map { it.mediaMetadata.title.toString() })
    }

    @Test
    fun aChosenSongPlaysWithTheRestOfWhereItWasListed() = runTest {
        seed()
        val browsing = LibraryBrowsing(context)
        // From the playlist: its songs, from the one chosen; as player items (their files, the app's ids).
        val fromPlaylist = browsing.playable("song:102@playlist:7")!!
        assertEquals(listOf("201", "102"), fromPlaylist.mediaItems.map { it.mediaId })
        assertEquals(1, fromPlaylist.startIndex)
        assertTrue(fromPlaylist.mediaItems.all { it.localConfiguration != null })
        // An album chosen: all of it, from the start.
        val album = browsing.playable("album:radiohead|ok computer")!!
        assertEquals(listOf("101", "102"), album.mediaItems.map { it.mediaId })
        assertEquals(0, album.startIndex)
        assertEquals("Album · OK Computer", album.mediaItems.first().mediaMetadata.extras?.getString("dev.irwingbraga.groovelight.source"))
    }
}
