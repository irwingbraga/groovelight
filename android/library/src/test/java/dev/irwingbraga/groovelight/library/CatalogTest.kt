package dev.irwingbraga.groovelight.library

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class CatalogTest {
    private val database = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext<Context>(), LibraryDatabase::class.java)
        .allowMainThreadQueries().build()

    @After fun close() = database.close()

    /** The catalog the Mac's SnapshotFixtureTests writes (GroovelightKit/Tests): the same file on both sides. */
    private fun fixture() = javaClass.classLoader!!.getResourceAsStream("catalog-v1.json")

    @Test
    fun readsTheMacsLibraryAndWhatTheDeviceHasChosen() = runTest {
        val catalog = Catalog.read(fixture())
        assertEquals(setOf("OK Computer", "Kid A", "Hits"), catalog.albums.map { it.title }.toSet())
        assertEquals(listOf(101L, 201L, 301L), catalog.tracks.map { it.id })
        assertEquals(284_500L, catalog.tracks.first().durationMs)
        assertEquals(Choice(albumKeys = setOf("radiohead|ok computer"), trackIds = setOf(301), excludedTrackIds = setOf(201)), catalog.choice)
        catalog.importInto(database)
        val dao = database.catalog()
        assertEquals(listOf("Radiohead"), dao.artists().first().map { it.name })
        assertEquals(listOf("Idioteque"), dao.tracksOfAlbum("radiohead|kid a").first().map { it.title })
        assertEquals(catalog.choice, Choice.of(dao.chosen().first()))
        assertEquals(listOf("Kid A"), dao.searchAlbums(likePattern("kid"), 5).map { it.title })
    }

    @Test
    fun requestsWaitInOrderAndShowWhereEachAlbumStands() = runTest {
        val dao = database.catalog()
        val add = dao.insertRequest(TransferRequest(action = TransferRequest.ADD, kind = TransferRequest.ALBUM, key = "radiohead|kid a"))
        dao.insertRequest(TransferRequest(action = TransferRequest.REMOVE, kind = TransferRequest.SONG, key = "301"))
        val pending = dao.pendingRequests()
        val chosen = Choice(albumKeys = setOf("radiohead|ok computer"), trackIds = setOf(301))
        val after = chosen.applying(pending)
        assertEquals(setOf("radiohead|ok computer", "radiohead|kid a"), after.albumKeys)
        assertTrue(after.trackIds.isEmpty())
        val kidA = CatalogAlbum("radiohead|kid a", "Kid A", "Radiohead")
        assertEquals(Availability.WAITING, Availability.of(onDevice = false, chosen = chosen.holdsAlbum(kidA), chosenAfter = after.holdsAlbum(kidA), others = false))
        // Sent: only the requests up to the one the Mac answered for are removed.
        dao.removeRequests(upTo = add)
        assertEquals(listOf("301"), dao.pendingRequests().map { it.key })
        // Chosen and not here yet: it arrives at the next sync; here and no longer chosen: it leaves (unless playlists may hold it).
        assertEquals(Availability.ARRIVING, Availability.of(onDevice = false, chosen = true, chosenAfter = true, others = false))
        assertEquals(Availability.LEAVING, Availability.of(onDevice = true, chosen = false, chosenAfter = false, others = false))
        assertEquals(Availability.ON_DEVICE, Availability.of(onDevice = true, chosen = false, chosenAfter = false, others = true))
        assertEquals(Availability.ON_MAC, Availability.of(onDevice = false, chosen = false, chosenAfter = false, others = true))
        // Everything chosen holds every album and song.
        assertTrue(Choice(everything = true).holdsSong(CatalogTrack(1, "x", "y", "z", codec = "flac"), null))
    }

    @Test
    fun removingFromTheDeviceLeavesTheSongsOffWhateverBringsThem() {
        val album = CatalogAlbum("band|lp", "LP", "Band")
        val one = CatalogTrack(1, "One", "Band", "band|lp", codec = "flac")
        val songs = { kind: String, key: String -> if (kind == TransferRequest.ALBUM && key == "band|lp") setOf(1L, 2L) else setOfNotNull(key.toLongOrNull()) }
        // All music chosen on the Mac; the album removed here: its songs leave, the choice of all music stays.
        val everything = Choice(everything = true)
        val removed = everything.applying(listOf(TransferRequest(action = TransferRequest.REMOVE, kind = TransferRequest.ALBUM, key = "band|lp")), songs)
        assertTrue(removed.everything && !removed.holdsSong(one, album) && !removed.holdsAlbum(album, setOf(1, 2)))
        assertEquals(Availability.WAITING, Availability.of(true, everything.holdsAlbum(album, setOf(1, 2)), removed.holdsAlbum(album, setOf(1, 2)), false))
        // Once the Mac has it: here until the next sync, leaving.
        assertEquals(Availability.LEAVING, Availability.of(onDevice = true, chosen = false, chosenAfter = false, others = true, removed = true))
        // Adding the song again brings it back.
        val back = removed.applying(listOf(TransferRequest(action = TransferRequest.ADD, kind = TransferRequest.SONG, key = "1")), songs)
        assertTrue(back.holdsSong(one, album))
    }
}
