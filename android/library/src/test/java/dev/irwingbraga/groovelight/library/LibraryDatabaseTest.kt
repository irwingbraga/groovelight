package dev.irwingbraga.groovelight.library

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class LibraryDatabaseTest {
    private val database = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext<Context>(), LibraryDatabase::class.java)
        .allowMainThreadQueries().build()
    private val library = database.library()

    @After fun close() = database.close()

    @Test
    fun keepsAlbumsInDiscAndTrackOrder() = runTest {
        library.upsertArtists(listOf(Artist(1, "Radiohead")))
        library.upsertAlbums(listOf(Album(10, "OK Computer", 1, "Radiohead", 1997)))
        library.upsertTracks(listOf(
            Track(102, "Paranoid Android", 1, "Radiohead", 10, discNumber = 1, trackNumber = 2, path = "Radiohead/OK Computer/02.flac"),
            Track(101, "Airbag", 1, "Radiohead", 10, discNumber = 1, trackNumber = 1, path = "Radiohead/OK Computer/01.flac"),
        ))
        assertEquals(listOf("Airbag", "Paranoid Android"), library.tracksOfAlbum(10).first().map { it.title })
        assertEquals(2, library.trackCount())
    }

    @Test
    fun replacesPlaylistSongsInOrder() = runTest {
        library.upsertTracks(listOf(
            Track(1, "One", null, "A", null, path = "1.flac"),
            Track(2, "Two", null, "A", null, path = "2.flac"),
            Track(3, "Three", null, "A", null, path = "3.flac"),
        ))
        library.upsertPlaylists(listOf(Playlist(7, "Mix")))
        library.setPlaylistTracks(7, listOf(3, 1, 2))
        library.setPlaylistTracks(7, listOf(2, 3))
        assertEquals(listOf("Two", "Three"), library.tracksOfPlaylist(7).first().map { it.title })
        // Songs removed from the device leave their playlists.
        library.deleteTracks(listOf(3))
        assertEquals(listOf("Two"), library.tracksOfPlaylist(7).first().map { it.title })
    }
}
