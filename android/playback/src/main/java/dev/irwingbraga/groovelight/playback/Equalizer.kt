package dev.irwingbraga.groovelight.playback

import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.PI
import kotlin.math.asinh
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sinh
import kotlin.math.sqrt

// The 15-band parametric equalizer, the same as the Mac's (PlayerCore/Equalizer.swift): the same filter types, RBJ
// cookbook biquads, ranges, built-in presets and auto preamp, so a curve sounds the same on both.

/** Filter shape of a band; [raw] is the Mac's `EQFilterType` raw value. */
enum class EqFilter(val raw: String, val label: String, val usesGain: Boolean) {
    PEAK("peak", "Peak", true),
    LOW_SHELF("lowShelf", "Low Shelf", true),
    HIGH_SHELF("highShelf", "High Shelf", true),
    LOW_PASS("lowPass", "Low Pass", false),
    HIGH_PASS("highPass", "High Pass", false),
    BAND_PASS("bandPass", "Band Pass", false),
    NOTCH("notch", "Notch", false);

    companion object {
        fun of(raw: String): EqFilter = entries.firstOrNull { it.raw == raw } ?: PEAK
    }
}

data class EqBand(
    val enabled: Boolean = true,
    val type: EqFilter = EqFilter.PEAK,
    /** Center or corner frequency in Hz. */
    val frequency: Double,
    /** dB, used by peak and shelf filters only. */
    val gain: Double = 0.0,
    val q: Double = EqMath.DEFAULT_Q,
)

data class EqPreset(val name: String, val preamp: Double = 0.0, val bands: List<EqBand>) {
    fun toJson(): JSONObject = JSONObject().put("name", name).put("preamp", preamp).put("bands", bandsJson(bands))

    /** Whether any band changes the sound (a flat curve plays as if the equalizer were off). */
    val isFlat: Boolean get() = preamp == 0.0 && bands.none { it.enabled && (!it.type.usesGain || it.gain != 0.0) }

    companion object {
        val FLAT = EqPreset("Flat", 0.0, EqMath.ISO_FREQUENCIES.map { EqBand(frequency = it) })

        /** A preset of 15 gains on the ISO bands, with the preamp that keeps it from clipping. */
        fun iso(name: String, vararg gains: Double): EqPreset {
            val bands = EqMath.ISO_FREQUENCIES.zip(gains.toList()) { frequency, gain -> EqBand(frequency = frequency, gain = gain) }
            return EqPreset(name, EqMath.autoPreamp(bands), bands)
        }

        val BUILT_INS: List<EqPreset> = listOf(
            FLAT,
            iso("Bass Booster", 6.0, 5.5, 5.0, 4.0, 3.0, 2.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0),
            iso("Bass Reducer", -6.0, -5.5, -5.0, -4.0, -3.0, -2.0, -1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0),
            iso("Treble Booster", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 5.5, 6.0),
            iso("Vocal Booster", -2.0, -2.0, -1.5, -1.0, 0.0, 1.5, 3.0, 3.5, 3.5, 3.0, 2.0, 1.0, 0.0, -1.0, -1.5),
            iso("Loudness", 6.0, 5.0, 4.0, 2.5, 1.0, 0.0, -1.0, -1.5, -1.0, 0.0, 1.0, 2.5, 3.5, 4.0, 4.0),
            iso("Acoustic", 4.5, 4.5, 4.0, 3.0, 1.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.0, 3.5, 3.0, 2.5, 2.0),
            iso("Electronic", 4.5, 4.0, 3.5, 1.5, 0.0, -1.5, -1.0, 0.0, 1.0, 1.5, 0.5, 1.5, 3.5, 4.0, 4.5),
            iso("Rock", 5.0, 4.5, 4.0, 3.0, 1.5, -0.5, -1.0, -0.5, 0.5, 1.5, 2.5, 3.0, 3.5, 3.5, 3.5),
            iso("Jazz", 4.0, 3.5, 3.0, 2.0, 1.5, -1.0, -1.5, -1.5, 0.0, 1.0, 1.5, 2.0, 2.5, 3.0, 3.0),
            iso("Classical", 4.5, 4.0, 3.5, 3.0, 2.5, 1.0, -1.0, -1.5, -1.5, -1.0, 0.0, 1.0, 2.0, 3.0, 3.5),
            iso("Small Speakers", 5.5, 5.0, 4.5, 3.5, 2.5, 1.5, 0.5, 0.0, -0.5, -1.0, -1.5, -2.0, -2.5, -3.0, -3.5),
        )

        fun isBuiltInName(name: String) = BUILT_INS.any { it.name == name }

        fun fromJson(json: JSONObject): EqPreset =
            EqPreset(json.optString("name"), json.optDouble("preamp", 0.0), bands(json.optJSONArray("bands") ?: JSONArray()))

        /** Bands as the Mac writes them (`isEnabled`, `type`, `frequency`, `gain`, `q`), padded or cut to 15. */
        fun bands(array: JSONArray): List<EqBand> {
            val bands = (0 until array.length()).map { index ->
                val band = array.getJSONObject(index)
                EqBand(band.optBoolean("isEnabled", true), EqFilter.of(band.optString("type", "peak")),
                    band.optDouble("frequency", 1000.0), band.optDouble("gain", 0.0), band.optDouble("q", EqMath.DEFAULT_Q))
            }.take(EqMath.BAND_COUNT)
            return bands + (bands.size until EqMath.BAND_COUNT).map { EqBand(enabled = false, frequency = EqMath.ISO_FREQUENCIES[it]) }
        }

        fun bandsJson(bands: List<EqBand>): JSONArray = JSONArray().apply {
            bands.forEach {
                put(JSONObject().put("isEnabled", it.enabled).put("type", it.type.raw).put("frequency", it.frequency)
                    .put("gain", it.gain).put("q", it.q))
            }
        }
    }
}

object EqMath {
    const val BAND_COUNT = 15

    /** ISO 2/3-octave centers. */
    val ISO_FREQUENCIES = listOf(25.0, 40.0, 63.0, 100.0, 160.0, 250.0, 400.0, 630.0, 1_000.0, 1_600.0, 2_500.0, 4_000.0, 6_300.0,
        10_000.0, 16_000.0)

    /** Q of a 2/3-octave band. */
    val DEFAULT_Q = qFromBandwidth(2.0 / 3.0)

    val FREQUENCY_RANGE = 20.0..20_000.0
    val GAIN_RANGE = -24.0..24.0
    val Q_RANGE = 0.1..18.0
    val PREAMP_RANGE = -24.0..24.0

    fun bandwidth(q: Double): Double = 2 / ln(2.0) * asinh(1 / (2 * q))

    fun qFromBandwidth(octaves: Double): Double = 1 / (2 * sinh(ln(2.0) / 2 * octaves))

    /** One biquad's coefficients, normalized (a0 = 1). */
    class Biquad(val b0: Double, val b1: Double, val b2: Double, val a1: Double, val a2: Double)

    /** RBJ audio EQ cookbook coefficients, as the Mac's `EQMath.coefficients`. */
    fun coefficients(band: EqBand, sampleRate: Double): Biquad {
        val f = min(band.frequency, sampleRate / 2 * 0.999)
        val w0 = 2 * PI * f / sampleRate
        val cosw = cos(w0)
        val sinw = sin(w0)
        val alpha = sinw / (2 * max(band.q, 0.01))
        val a = 10.0.pow(band.gain / 40)
        val raw = when (band.type) {
            EqFilter.PEAK -> doubleArrayOf(1 + alpha * a, -2 * cosw, 1 - alpha * a, 1 + alpha / a, -2 * cosw, 1 - alpha / a)
            EqFilter.LOW_SHELF -> {
                val s = 2 * sqrt(a) * alpha
                doubleArrayOf(a * ((a + 1) - (a - 1) * cosw + s), 2 * a * ((a - 1) - (a + 1) * cosw), a * ((a + 1) - (a - 1) * cosw - s),
                    (a + 1) + (a - 1) * cosw + s, -2 * ((a - 1) + (a + 1) * cosw), (a + 1) + (a - 1) * cosw - s)
            }
            EqFilter.HIGH_SHELF -> {
                val s = 2 * sqrt(a) * alpha
                doubleArrayOf(a * ((a + 1) + (a - 1) * cosw + s), -2 * a * ((a - 1) + (a + 1) * cosw), a * ((a + 1) + (a - 1) * cosw - s),
                    (a + 1) - (a - 1) * cosw + s, 2 * ((a - 1) - (a + 1) * cosw), (a + 1) - (a - 1) * cosw - s)
            }
            EqFilter.LOW_PASS -> doubleArrayOf((1 - cosw) / 2, 1 - cosw, (1 - cosw) / 2, 1 + alpha, -2 * cosw, 1 - alpha)
            EqFilter.HIGH_PASS -> doubleArrayOf((1 + cosw) / 2, -(1 + cosw), (1 + cosw) / 2, 1 + alpha, -2 * cosw, 1 - alpha)
            EqFilter.BAND_PASS -> doubleArrayOf(alpha, 0.0, -alpha, 1 + alpha, -2 * cosw, 1 - alpha)
            EqFilter.NOTCH -> doubleArrayOf(1.0, -2 * cosw, 1.0, 1 + alpha, -2 * cosw, 1 - alpha)
        }
        val a0 = raw[3]
        return Biquad(raw[0] / a0, raw[1] / a0, raw[2] / a0, raw[4] / a0, raw[5] / a0)
    }

    /** Magnitude response in dB of one band at `frequency`. */
    fun response(band: EqBand, frequency: Double, sampleRate: Double = 48_000.0): Double {
        if (!band.enabled) return 0.0
        val c = coefficients(band, sampleRate)
        val w = 2 * PI * frequency / sampleRate
        val numRe = c.b0 + c.b1 * cos(w) + c.b2 * cos(2 * w)
        val numIm = -(c.b1 * sin(w) + c.b2 * sin(2 * w))
        val denRe = 1 + c.a1 * cos(w) + c.a2 * cos(2 * w)
        val denIm = -(c.a1 * sin(w) + c.a2 * sin(2 * w))
        val magnitude = sqrt((numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm))
        return 20 * log10(max(magnitude, 1e-9))
    }

    /** The whole curve's response in dB (bands plus preamp). */
    fun response(preset: EqPreset, frequency: Double, sampleRate: Double = 48_000.0): Double =
        preset.bands.fold(preset.preamp) { total, band -> total + response(band, frequency, sampleRate) }

    /** The preamp that keeps the curve's loudest boost at or below 0 dB. */
    fun autoPreamp(bands: List<EqBand>, sampleRate: Double = 48_000.0): Double {
        val flat = EqPreset("", 0.0, bands)
        val peak = logSpaced(256).maxOf { response(flat, it, sampleRate) }
        return min(0.0, -peak)
    }

    fun logSpaced(count: Int, range: ClosedFloatingPointRange<Double> = FREQUENCY_RANGE): List<Double> {
        val lo = log10(range.start)
        val hi = log10(range.endInclusive)
        return (0 until count).map { 10.0.pow(lo + (hi - lo) * it / (count - 1)) }
    }
}

/** The Equalizer APO / AutoEq `ParametricEQ.txt` format (headphone corrections), as the Mac reads and writes it. */
object ParametricEqFile {
    fun parse(text: String, name: String): EqPreset? {
        var preamp = 0.0
        val bands = mutableListOf<EqBand>()
        for (raw in text.lines()) {
            val line = raw.trim()
            val tokens = line.split(Regex("\\s+"))
            if (line.lowercase().startsWith("preamp:")) {
                tokens.getOrNull(1)?.toDoubleOrNull()?.let { preamp = it }
                continue
            }
            val on = tokens.indexOfFirst { it == "ON" || it == "OFF" }
            if (!line.lowercase().startsWith("filter") || on < 0 || on + 1 >= tokens.size) continue
            val type = when (tokens[on + 1].uppercase()) {
                "PK", "PEQ" -> EqFilter.PEAK
                "LSC", "LS", "LSQ" -> EqFilter.LOW_SHELF
                "HSC", "HS", "HSQ" -> EqFilter.HIGH_SHELF
                "LP", "LPQ" -> EqFilter.LOW_PASS
                "HP", "HPQ" -> EqFilter.HIGH_PASS
                "BP" -> EqFilter.BAND_PASS
                "NO" -> EqFilter.NOTCH
                else -> continue
            }
            fun after(key: String) = tokens.indexOf(key).takeIf { it >= 0 && it + 1 < tokens.size }?.let { tokens[it + 1].toDoubleOrNull() }
            val frequency = after("Fc") ?: continue
            bands += EqBand(tokens[on] == "ON", type, frequency, after("Gain") ?: 0.0,
                after("Q") ?: if (type == EqFilter.PEAK) EqMath.DEFAULT_Q else 0.707)
        }
        if (bands.isEmpty()) return null
        val kept = bands.take(EqMath.BAND_COUNT)
        return EqPreset(name, preamp, kept + (kept.size until EqMath.BAND_COUNT).map { EqBand(enabled = false, frequency = EqMath.ISO_FREQUENCIES[it]) })
    }
}
