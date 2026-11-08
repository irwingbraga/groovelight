package dev.irwingbraga.groovelight.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Home as the Mac and the PC send it: `home.json` is a copy of GroovelightKit's Fixtures/Discovery/home.json. */
class HomeTest {
    private fun fixture() = HomeSnapshot.read(javaClass.classLoader!!.getResourceAsStream("home.json").readBytes().decodeToString())

    @Test
    fun readsTheMacsHome() {
        val home = fixture()
        assertEquals(listOf("week", "month", "year", "all"), home.stats.map { it.range })
        HomeSnapshot.KINDS.forEach { kind -> assertTrue(home.cards(kind).isNotEmpty()) }
        val album = home.album.first()
        assertEquals("album", album.kind)
        assertEquals("OK Computer", album.title)
        assertEquals("One of your favorites, 1 play", album.reasonText)
        assertEquals(listOf(4L), album.trackIds)
        assertNull(album.artworkHash)
        assertEquals(home.artist.first().key, home.artist.first().title)
    }

    @Test
    fun readsTheDashboard() {
        val week = fixture().stats("week")!!
        assertEquals(2L, week.plays)
        assertEquals(mapOf("here" to 2L), week.places)
        assertEquals(7, week.buckets.size)
        assertEquals(3.0, week.buckets.last().minutes["here"]!!, 0.001)
        assertEquals(7, week.hours.size)
        assertTrue(week.hours.all { it.size == 24 })
        assertEquals(1L, week.hours[5][7])
        assertEquals(6L, week.librarySongs)
        assertTrue(week.topSongs.isNotEmpty())
    }
}
