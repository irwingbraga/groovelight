package dev.irwingbraga.groovelight.library

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class LibraryDatabaseTest {
    private val database = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext<Context>(), LibraryDatabase::class.java)
        .allowMainThreadQueries().build()
    private val library = database.library()

    @After fun close() = database.close()

    /** The snapshot the Mac's SnapshotFixtureTests writes (GroovelightKit/Tests): the same file on both sides. */
    private fun fixture(): Snapshot = Snapshot.read(javaClass.classLoader!!.getResourceAsStream("snapshot-v1.json"))

    @Test
    fun readsTheMacsSnapshot() {
        val snapshot = fixture()
        assertEquals(listOf("Hits", "OK Computer"), snapshot.albums.map { it.title })
        val airbag = snapshot.tracks.first { it.id == 101L }
        assertEquals("Music/Radiohead/OK Computer (1997)/01 Airbag.flac", airbag.path)
        assertEquals(284_500L, airbag.durationMs)
        assertEquals(24, airbag.bitDepth)
        assertTrue(airbag.loved)
        assertEquals(1_700_000_000_000L, airbag.lovedAt)
        assertEquals("[00:10.00]In the next world war", airbag.lyrics)
        // ReplayGain first, else the measured loudness against -18 LUFS, as on the Mac.
        assertEquals(-7.25, airbag.normalizationGain!!, 0.0)
        assertEquals(-6.0, snapshot.tracks.first { it.id == 102L }.normalizationGain!!, 0.0)
        assertNull(snapshot.tracks.first { it.id == 201L }.normalizationGain)
        assertEquals(setOf("abc123"), snapshot.artworkHashes)
    }

    @Test
    fun importsAndReplacesTheLibrary() = runTest {
        fixture().importInto(database)
        assertEquals(listOf("Airbag", "Paranoid Android"), library.tracksOfAlbum("radiohead|ok computer").first().map { it.title })
        assertEquals(listOf("Song", "Airbag"), library.tracksOfPlaylist(7).first().map { it.title })
        // Album artists, compilations apart; playlists with their counts and first cover.
        assertEquals(listOf("Radiohead"), library.artists().first().map { it.name })
        val playlists = library.playlists().first()
        assertEquals(listOf("Mix" to 2, "Most Played" to 2), playlists.map { it.name to it.songs })
        assertEquals("abc123", playlists.first().artworkHash)
        // Mix has a cover the Mac generates: its palette and pattern.
        assertEquals(listOf("generated", "ocean", "vinyl"), playlists.first().let { listOf(it.coverStyle, it.coverPalette, it.coverPattern) })
        assertEquals(null, playlists.last().coverStyle)
        assertEquals(listOf("abc123"), library.playlistCovers(7))
        assertEquals(listOf("Airbag"), library.lovedTracks().first().map { it.title })

        // The next sync's snapshot replaces everything: a song left the device, and its playlist entry with it.
        val smaller = fixture().let { Snapshot(it.albums, it.tracks.filter { track -> track.id != 201L }, it.playlists,
            it.items.filter { item -> item.trackId != 201L }) }
        smaller.importInto(database)
        assertEquals(2, library.trackCount())
        assertEquals(listOf("Airbag"), library.tracksOfPlaylist(7).first().map { it.title })
    }

    @Test
    fun searchesAndListsAnArtist() = runTest {
        fixture().importInto(database)
        assertEquals(listOf("Paranoid Android"), library.searchTracks(ftsQuery("paranoid")!!, 10).map { it.title })
        // Every word as a prefix, in any field: "radio air" finds Airbag by Radiohead.
        assertEquals(listOf("Airbag"), library.searchTracks(ftsQuery("radio air")!!, 10).map { it.title })
        // Credits find songs: on the whole album (the producer) or on one song (the guitarist).
        assertEquals(listOf("Airbag", "Paranoid Android"), library.searchTracks(ftsQuery("godrich")!!, 10).map { it.title })
        assertEquals(listOf("Paranoid Android"), library.searchTracks(ftsQuery("Jonny")!!, 10).map { it.title })
        assertEquals(listOf("OK Computer"), library.searchAlbums(likePattern("ok comp"), 10).map { it.title })
        assertEquals(listOf("Radiohead"), library.searchArtists(likePattern("RADIO"), 10).map { it.name })
        assertEquals(listOf(PersonSummary("Nigel Godrich", 1)), library.searchPeople(likePattern("nigel"), 10))
        // FTS syntax and wildcards typed are matched as text.
        assertNull(ftsQuery(" * \" "))
        assertTrue(library.searchTracks(ftsQuery("air* OR song")!!, 10).isEmpty())
        assertTrue(library.searchAlbums(likePattern("%"), 10).isEmpty())
        assertEquals(listOf("Airbag", "Paranoid Android"), library.tracksOfArtist("Radiohead").first().map { it.title })
        assertEquals("Paranoid Android", library.track(102).first()?.title)
    }

    @Test
    fun readsCreditsAndTheMacsEqualizer() = runTest {
        fixture().importInto(database)
        val credits = library.creditsOfAlbum("radiohead|ok computer").first()
        assertEquals(listOf("Nigel Godrich", "Jonny Greenwood"), credits.map { it.name })
        assertEquals(listOf("producer", "engineer"), credits.first().roleList)
        assertEquals(listOf(PersonCredit("radiohead|ok computer", 102, "guitar")), library.creditsOf("Jonny Greenwood").first())
        // The curve in use first (and whether the Mac's equalizer is on), then the saved presets.
        val presets = library.macEqPresets().first()
        assertEquals(listOf("Bass" to true, "Headphones" to false), presets.map { it.name to it.isCurrent })
        assertTrue(presets.first().enabled)
        assertTrue(presets.last().bands.contains("\"type\":\"lowShelf\""))
    }

    @Test
    fun lovesAndRatingsMadeHereSurviveTheNextSync() = runTest {
        fixture().importInto(database)
        library.setLoved(102, true, at = 5_000)
        library.setLoved(101, false)
        library.setRating(201, 4)
        assertEquals(listOf("Paranoid Android"), library.lovedTracks().first().map { it.title })
        // The Mac does not know yet: its snapshot still says otherwise, and the device's changes win.
        fixture().importInto(database)
        assertEquals(listOf("Paranoid Android"), library.lovedTracks().first().map { it.title })
        assertEquals(5_000L, library.track(102).first()?.lovedAt)
        assertEquals(4, library.track(201).first()?.rating)
        assertEquals(listOf("love", "love", "rating"), library.unsentEvents().map { it.kind })
    }
}
