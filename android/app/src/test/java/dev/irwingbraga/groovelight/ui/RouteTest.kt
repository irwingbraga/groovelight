package dev.irwingbraga.groovelight.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RouteTest {
    @Test
    fun routesSurviveSaving() {
        val routes = listOf(Route.Library, Route.Search, Route.Shelf, Route.Settings, Route.Sync, Route.Equalizer, Route.LovedSongs,
            Route.AlbumPage("radiohead|ok computer: live"), Route.ArtistPage("Godspeed You! Black Emperor"), Route.PlaylistPage(42),
            Route.PersonPage("Nigel Godrich"), Route.MacAlbumPage("radiohead|kid a"), Route.MacArtistPage("Sigur Rós"))
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
