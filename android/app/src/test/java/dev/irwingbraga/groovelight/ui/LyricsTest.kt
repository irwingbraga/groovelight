package dev.irwingbraga.groovelight.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LyricsTest {
    @Test
    fun readsSyncedLyrics() {
        val lyrics = Lyrics.parse("[ar:Radiohead]\n[00:10.00]In the next world war\n[00:12.5]In a jackknifed juggernaut\n[01:02.345][00:05]Again\n\n") as Lyrics.Synced
        assertEquals(listOf(5_000L, 10_000L, 12_500L, 62_345L), lyrics.lines.map { it.timeMs })
        assertEquals(listOf("Again", "In the next world war", "In a jackknifed juggernaut", "Again"), lyrics.lines.map { it.text })
        assertEquals(-1, lyrics.lineAt(4_999))
        assertEquals(0, lyrics.lineAt(5_000))
        assertEquals(1, lyrics.lineAt(11_000))
        assertEquals(3, lyrics.lineAt(600_000))
    }

    @Test
    fun appliesTheOffset() {
        val lyrics = Lyrics.parse("[offset:+500]\n[00:10.00]Line") as Lyrics.Synced
        assertEquals(9_500L, lyrics.lines.single().timeMs)
    }

    @Test
    fun keepsPlainLyrics() {
        assertEquals(Lyrics.Plain("First line\nSecond line"), Lyrics.parse("First line\nSecond line\n"))
        assertNull(Lyrics.parse("  \n"))
        assertNull(Lyrics.parse(null))
        assertTrue(Lyrics.parse("[ti:Title]\nWords") is Lyrics.Plain)
    }
}
