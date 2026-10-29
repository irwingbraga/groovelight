package dev.irwingbraga.groovelight.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioTapTest {
    /** Each side's loudness is measured on its own: a song loud on the left and quiet on the right reads so. */
    @Test
    fun levelsAreMeasuredOnEachSide() {
        val channel = AudioTap.Channel()
        assertNull(channel.levels(256))
        // Interleaved stereo: the left at 0.5, the right at 0.1.
        val samples = FloatArray(1024 * 2) { if (it % 2 == 0) 0.5f else 0.1f }
        channel.write(samples, samples.size, 2)
        val levels = channel.levels(512)
        assertNotNull(levels)
        assertEquals(0.5f, levels!!.first, 0.001f)
        assertEquals(0.1f, levels.second, 0.001f)
        // The mono mix the visualizers read is unchanged.
        val mono = FloatArray(256)
        assertTrue(channel.read(mono))
        assertEquals(0.3f, mono[0], 0.001f)
    }

    /** The tap copies while anything shows it, a visualizer or a VU meter, and stops when the last one goes. */
    @Test
    fun copiesWhileAnythingShowsIt() {
        assertFalse(AudioTap.enabled)
        AudioTap.start()
        AudioTap.start()
        AudioTap.stop()
        assertTrue(AudioTap.enabled)
        AudioTap.stop()
        assertFalse(AudioTap.enabled)
    }
}
