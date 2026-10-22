package dev.irwingbraga.groovelight.update

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VersionTest {
    @Test
    fun comparesReleasesPartByPart() {
        assertTrue(isNewer("0.4.0", "0.3.1"))
        assertTrue(isNewer("v0.10.0", "0.9.9"))
        assertTrue(isNewer("1.0", "0.99.99"))
        assertTrue(isNewer("0.4.1", "0.4"))
        assertFalse(isNewer("0.4.0", "0.4.0"))
        assertFalse(isNewer("v0.4.0", "0.4"))
        assertFalse(isNewer("0.3.9", "0.4.0"))
        // A preview's suffix is not a newer version.
        assertFalse(isNewer("0.4.0-beta", "0.4.0"))
    }

    @Test
    fun releaseNotesAreReadable() {
        val notes = """
            > [!NOTE]
            > This is a preview release.

            ## Highlights
            - **Claude** works with [Groovelight](https://example.com).

            ## Android
            - Plays your **Mac's** music.
            - Run `adb`.

            ## Fixed
            - Something on the Mac.
        """.trimIndent()
        org.junit.Assert.assertEquals("• Plays your Mac's music.\n• Run adb.", readableNotes(notes))
        org.junit.Assert.assertEquals("This is a preview release.\n\nHighlights\n• Claude works with Groovelight.",
            readableNotes(notes.substringBefore("## Android").trim()))
    }
}
