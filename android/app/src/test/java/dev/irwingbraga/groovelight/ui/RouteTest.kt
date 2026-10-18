package dev.irwingbraga.groovelight.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RouteTest {
    @Test
    fun routesSurviveSaving() {
        val routes = listOf(Route.Library, Route.Search, Route.Sync, Route.LovedSongs, Route.AlbumPage("radiohead|ok computer: live"),
            Route.ArtistPage("Godspeed You! Black Emperor"), Route.PlaylistPage(42))
        assertEquals(routes, routes.map { Route.decode(Route.encode(it)) })
        assertNull(Route.decode("playlist:x"))
        assertNull(Route.decode("unknown"))
    }

    @Test
    fun filesNamesUnderTheirLetter() {
        assertEquals("R", indexLetter("radiohead"))
        assertEquals("#", indexLetter("2Pac"))
        assertEquals("A", indexLetter("  (Album)"))
        assertEquals("#", indexLetter(""))
    }
}
