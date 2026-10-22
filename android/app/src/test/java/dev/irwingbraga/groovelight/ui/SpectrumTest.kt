package dev.irwingbraga.groovelight.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import kotlin.math.PI
import kotlin.math.hypot
import kotlin.math.sin

class SpectrumTest {
    @Test
    fun aToneLandsInItsBin() {
        val size = Spectrum.SIZE
        val rate = 44_100.0
        // 440 Hz: bin 440 / (44100 / 2048), about 20.4.
        val re = FloatArray(size) { sin(2 * PI * 440.0 * it / rate).toFloat() }
        val im = FloatArray(size)
        Spectrum.fft(re, im)
        val loudest = (1 until size / 2).maxBy { hypot(re[it].toDouble(), im[it].toDouble()) }
        assertEquals(20, loudest)
        // A full-scale sine gives about size / 2 in its bin (spread over two bins, as 440 Hz falls between them).
        val peak = hypot(re[20].toDouble(), im[20].toDouble()) + hypot(re[21].toDouble(), im[21].toDouble())
        assert(peak > size / 2 * 0.8) { "peak $peak" }
    }
}
