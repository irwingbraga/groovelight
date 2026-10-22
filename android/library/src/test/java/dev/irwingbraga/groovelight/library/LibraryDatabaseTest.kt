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
        assertEquals(setOf("abc123", "face01"), snapshot.artworkHashes)
    }

    @Test
    fun importsAndReplacesTheLibrary() = runTest {
        fixture().importInto(database)
        assertEquals(listOf("Airbag", "Paranoid Android"), library.tracksOfAlbum("radiohead|ok computer").first().map { it.title })
        assertEquals(listOf("Song", "Airbag"), library.tracksOfPlaylist(7).first().map { it.title })
        // Album artists, compilations apart; playlists with their counts and first cover.
        assertEquals(listOf("Radiohead"), library.artists().first().map { it.name })
        // The artist's photo from the Mac, over their covers, and fetched with them.
        assertEquals("face01", library.artists().first().first().artworkHash)
        assertTrue("face01" in fixture().artworkHashes && "face01" in library.artworkHashes())
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

    @Test
    fun playsAndSkipsCountAsOnTheMac() = runTest {
        fixture().importInto(database)
        // Airbag lasts 284.5 s: a play from half of it, a skip under 20 s, nothing in between.
        val before = library.track(101).first()!!
        assertTrue(library.recordListen(101, startedAt = 9_000_000_000_000, listenedMs = 143_000))
        assertTrue(library.recordListen(101, startedAt = 8_000_000_000_000, listenedMs = 5_000))
        assertTrue(!library.recordListen(101, startedAt = 8_000_000_000_000, listenedMs = 60_000))
        assertTrue(!library.recordListen(999, startedAt = 8_000_000_000_000, listenedMs = 300_000))
        assertEquals(listOf("play" to 143, "skip" to 5), library.unsentEvents().map { it.kind to it.value })
        // Until the Mac has it, the play is added to the snapshot's count.
        fixture().importInto(database)
        val after = library.track(101).first()!!
        assertEquals(before.playCount + 1, after.playCount)
        assertEquals(9_000_000_000_000L, after.lastPlayed)
    }

    @Test
    fun smartPlaylistsFollowWhatIsPlayedHere() = runTest {
        fixture().importInto(database)
        // Most Played (played songs, most played first): Airbag 12, Song 3; Paranoid Android not played yet.
        assertEquals(listOf(101L, 201L), library.tracksOfPlaylist(8).first().map { it.id })
        repeat(4) { library.recordListen(102, startedAt = 9_000_000_000_000 + it, listenedMs = 200_000) }
        assertEquals(listOf(101L, 102L, 201L), library.tracksOfPlaylist(8).first().map { it.id })
        // Rules on what the device does not know keep the Mac's songs.
        val composer = SmartRules(true, listOf(SmartRules.Rule("composer", "contains", "Yorke")), null)
        assertTrue(!composer.evaluable)
        assertNull(composer.evaluate(emptyList(), emptyMap()))
    }

    @Test
    fun smartRulesMatchAsOnTheMac() {
        val album = Album("a", "OK Computer", "Radiohead")
        val tracks = listOf(
            Track(1, "Airbag", "Radiohead", "a", trackNumber = 1, durationMs = 284_000, path = "1", codec = "flac", loved = true, rating = 5),
            Track(2, "Paranoid Android", "Radiohead", "a", trackNumber = 2, durationMs = 383_000, path = "2", codec = "flac", lastPlayed = 1_000),
            Track(3, "Subterranean Homesick Alien", "Radiohead", "a", trackNumber = 3, durationMs = 267_000, path = "3", codec = "flac", year = 1997),
        )
        val albums = mapOf("a" to album)
        fun ids(rules: SmartRules, now: Long = 10_000_000_000) = rules.evaluate(tracks, albums, now)?.map { it.id }
        fun rule(field: String, op: String, text: String = "", number: Double = 0.0, number2: Double = 0.0) =
            SmartRules.Rule(field, op, text, number, number2)
        assertEquals(listOf(1L, 2L), ids(SmartRules(false, listOf(rule("loved", "isTrue"), rule("title", "contains", "PARANOID")), null)))
        assertEquals(listOf(1L), ids(SmartRules(true, listOf(rule("rating", "greaterThan", number = 4.0)), null)))
        // Minutes with a 30 second tolerance; years missing are not in a range.
        assertEquals(listOf(1L, 3L), ids(SmartRules(true, listOf(rule("time", "inRange", number = 4.0, number2 = 5.0)), null)))
        assertEquals(listOf(3L), ids(SmartRules(true, listOf(rule("year", "is", number = 1997.0)), null)))
        // Never played counts as not in the last two weeks.
        val recent = SmartRules.Rule("lastPlayed", "notInTheLast", period = 2, periodUnit = "weeks")
        assertEquals(listOf(1L, 2L, 3L), ids(SmartRules(true, listOf(recent), null)))
        // Limits: the 10 minutes most recently played (never played last), cut where the next song does not fit.
        assertEquals(listOf(2L), ids(SmartRules(true, emptyList(), SmartRules.Limit(10, "minutes", "mostRecentlyPlayed", 0))))
        // Rules read back from what is kept.
        val kept = SmartRules(true, listOf(recent), SmartRules.Limit(25, "songs", "random", 8))
        assertEquals(kept, SmartRules.fromJson(kept.toJson()))
    }

    @Test
    fun playlistsEditedHereSurviveTheNextSync() = runTest {
        fixture().importInto(database)
        val car = library.createPlaylist("Car", listOf(201, 999), at = 5_000)
        assertEquals(-5_000L, car)
        library.addToPlaylist(car, listOf(102, 101))
        library.removeFromPlaylist(car, listOf(201))
        library.renamePlaylist(7, "Mix 2")
        library.addToPlaylist(8, listOf(102))
        assertEquals(listOf(102L, 101L), library.tracksOfPlaylist(car).first().map { it.id })
        // Smart playlists take no songs; the Mac does not know yet, and the next snapshot keeps the edits.
        assertEquals(listOf(101L, 201L), library.tracksOfPlaylist(8).first().map { it.id })
        fixture().importInto(database)
        assertEquals("Car", library.playlist(car).first()?.name)
        assertEquals(listOf(102L, 101L), library.tracksOfPlaylist(car).first().map { it.id })
        assertEquals("Mix 2", library.playlist(7).first()?.name)
        assertEquals(listOf("playlistCreate", "playlistAdd", "playlistRemove", "playlistRename", "playlistAdd"),
            library.unsentEvents().map { it.kind })
        assertEquals(listOf(201L, 999L), library.unsentEvents().first().trackIdList)
        library.deletePlaylist(car)
        assertNull(library.playlist(car).first())
    }
}
