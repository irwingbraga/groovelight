package dev.irwingbraga.groovelight.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.sin
import kotlin.math.sqrt

class EqualizerTest {
    @Test
    fun qAndBandwidthRoundTrip() {
        for (q in listOf(0.3, 0.707, 1.41, 4.0, 10.0)) assertEquals(q, EqMath.qFromBandwidth(EqMath.bandwidth(q)), 1e-9)
        assertEquals(1.4142, EqMath.qFromBandwidth(1.0), 0.001)
    }

    @Test
    fun peakBandHitsItsGainAtCenter() {
        val band = EqBand(frequency = 1_000.0, gain = 6.0, q = 1.4)
        assertEquals(6.0, EqMath.response(band, 1_000.0), 0.01)
        assertEquals(0.0, EqMath.response(band, 20.0), 0.1)
        assertEquals(0.0, EqMath.response(EqBand(enabled = false, frequency = 100.0, gain = 12.0), 100.0), 0.0)
        for (f in EqMath.logSpaced(20)) assertEquals(0.0, EqMath.response(EqPreset.FLAT, f), 1e-6)
    }

    /** The Mac's EQMath gives these for the same curves (dumped from GroovelightKit): the two curves are the same. */
    @Test
    fun curvesMatchTheMacs() {
        val rock = EqPreset.BUILT_INS.first { it.name == "Rock" }
        assertEquals(-6.411123221527716, rock.preamp, 1e-6)
        val rockAt = mapOf(31.0 to -1.273159341784499, 100.0 to -2.089054726230677, 440.0 to -7.264349200055415, 1000.0 to -5.5784585639814175,
            3000.0 to -3.3272070401435996, 8000.0 to -3.3751929500735094, 15000.0 to -3.855004369033076)
        for ((f, db) in rockAt) assertEquals("Rock at $f Hz", db, EqMath.response(rock, f, 44_100.0), 1e-6)

        val custom = EqPreset("x", -3.0, listOf(
            EqBand(type = EqFilter.LOW_SHELF, frequency = 105.0, gain = 5.5, q = 0.7),
            EqBand(type = EqFilter.HIGH_PASS, frequency = 30.0, q = 0.707),
            EqBand(type = EqFilter.NOTCH, frequency = 3000.0, q = 4.0),
            EqBand(type = EqFilter.HIGH_SHELF, frequency = 9000.0, gain = -4.0, q = 0.7),
            EqBand(type = EqFilter.BAND_PASS, frequency = 1000.0, q = 0.5),
            EqBand(type = EqFilter.LOW_PASS, frequency = 18000.0, q = 0.707)))
        val customAt = mapOf(20.0 to -33.304714491757906, 100.0 to -14.100349664806556, 1000.0 to -3.0373219870441632,
            9000.0 to -18.63487642660857, 19000.0 to -31.327385096409472)
        for ((f, db) in customAt) assertEquals("custom at $f Hz", db, EqMath.response(custom, f, 96_000.0), 1e-6)
        assertEquals(0.0, EqMath.autoPreamp(custom.bands), 0.0)
    }

    @Test
    fun autoPreampCancelsTheLoudestBoost() {
        assertEquals(-9.0, EqMath.autoPreamp(listOf(EqBand(frequency = 100.0, gain = 9.0, q = 1.0))), 0.2)
        assertEquals(0.0, EqMath.autoPreamp(listOf(EqBand(frequency = 100.0, gain = -6.0))), 0.0)
        for (preset in EqPreset.BUILT_INS) {
            assertEquals(EqMath.BAND_COUNT, preset.bands.size)
            assertTrue(preset.preamp <= 0)
        }
    }

    /** A sine through the filters comes out at the level the curve says, in every channel. */
    @Test
    fun filtersSoundAsTheCurveSays() {
        val preset = EqPreset("Test", -2.0, EqPreset.FLAT.bands.toMutableList().also {
            it[8] = EqBand(frequency = 1_000.0, gain = 6.0, q = 1.4)
            it[2] = EqBand(type = EqFilter.LOW_SHELF, frequency = 63.0, gain = -8.0, q = 0.7)
        })
        val rate = 48_000
        for (frequency in listOf(50.0, 400.0, 1_000.0, 5_000.0)) {
            val filters = EqFilters().apply { configure(rate, 2); setPreset(preset) }
            val frames = rate
            val samples = FloatArray(frames * 2) { i -> (0.25 * sin(2 * PI * frequency * (i / 2) / rate)).toFloat() }
            filters.process(samples, frames)
            // The second half (filters settled), left and right.
            for (channel in 0..1) {
                val tail = (frames / 2 until frames).map { samples[it * 2 + channel].toDouble() }
                val rms = sqrt(tail.sumOf { it * it } / tail.size)
                val db = 20 * log10(rms / (0.25 / sqrt(2.0)))
                assertEquals("at $frequency Hz", EqMath.response(preset, frequency, rate.toDouble()), db, 0.05)
            }
        }
    }

    @Test
    fun aFlatCurvePassesSamplesUnchanged() {
        val filters = EqFilters().apply { configure(44_100, 2); setPreset(EqPreset.FLAT) }
        assertFalse(filters.isActive)
        val samples = floatArrayOf(0.5f, -0.25f, 0.1f, 1f)
        filters.process(samples, 2)
        assertTrue(samples.contentEquals(floatArrayOf(0.5f, -0.25f, 0.1f, 1f)))
    }

    @Test
    fun readsAutoEqFilesAndTheMacsBands() {
        val text = """
            Preamp: -6.2 dB
            Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
            Filter 2: ON PK Fc 160 Hz Gain -2.1 dB Q 0.83
            Filter 3: OFF HSC Fc 10000 Hz Gain 3.0 dB Q 0.70
        """.trimIndent()
        val preset = ParametricEqFile.parse(text, "HD 600")
        assertNotNull(preset)
        preset!!
        assertEquals(-6.2, preset.preamp, 0.0)
        assertEquals(15, preset.bands.size)
        assertEquals(EqBand(true, EqFilter.LOW_SHELF, 105.0, 5.5, 0.70), preset.bands[0])
        assertFalse(preset.bands[2].enabled)
        assertFalse(preset.bands[3].enabled)
        // Through JSON as the Mac writes it, unchanged.
        assertEquals(preset, EqPreset.fromJson(preset.toJson()))
        val mac = EqPreset.bands(org.json.JSONArray("""[{"isEnabled":true,"type":"lowShelf","frequency":105,"gain":5.5,"q":0.7}]"""))
        assertEquals(EqBand(true, EqFilter.LOW_SHELF, 105.0, 5.5, 0.7), mac[0])
        assertEquals(15, mac.size)
        assertTrue(abs(mac[14].frequency - 16_000.0) < 1e-9 && !mac[14].enabled)
    }
}
