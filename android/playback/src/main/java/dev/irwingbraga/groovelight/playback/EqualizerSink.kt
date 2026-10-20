package dev.irwingbraga.groovelight.playback

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.ForwardingAudioSink
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.pow

/**
 * The equalizer's filters: one biquad per enabled band and channel, run in double precision on interleaved float
 * samples (transposed direct form II). A new curve keeps the filters' state, so changing it while playing does not click.
 */
class EqFilters {
    private var sampleRate = 0
    private var channels = 0
    private var preset: EqPreset? = null
    private var gain = 1.0
    private var coefficients = emptyArray<EqMath.Biquad>()
    /** Two state values per band and channel. */
    private var state = DoubleArray(0)

    /** Whether the filters change the sound at all (no curve, or a flat one, passes samples unchanged). */
    val isActive: Boolean get() = preset != null

    fun configure(sampleRate: Int, channels: Int) {
        if (sampleRate == this.sampleRate && channels == this.channels) return
        this.sampleRate = sampleRate
        this.channels = channels
        rebuild()
    }

    /** The curve to apply, or null for none. */
    fun setPreset(preset: EqPreset?) {
        val used = preset?.takeIf { !it.isFlat }
        if (used == this.preset) return
        this.preset = used
        rebuild()
    }

    fun reset() = state.fill(0.0)

    private fun rebuild() {
        val preset = preset
        if (preset == null || sampleRate == 0 || channels == 0) {
            coefficients = emptyArray()
            gain = 1.0
            state = DoubleArray(0)
            return
        }
        val bands = preset.bands.filter { it.enabled && (!it.type.usesGain || it.gain != 0.0) }.map {
            it.copy(frequency = it.frequency.coerceIn(EqMath.FREQUENCY_RANGE), gain = it.gain.coerceIn(EqMath.GAIN_RANGE),
                q = it.q.coerceIn(EqMath.Q_RANGE))
        }
        val previous = state
        coefficients = bands.map { EqMath.coefficients(it, sampleRate.toDouble()) }.toTypedArray()
        gain = 10.0.pow(preset.preamp.coerceIn(EqMath.PREAMP_RANGE) / 20)
        state = DoubleArray(coefficients.size * channels * 2).also { previous.copyInto(it, endIndex = minOf(previous.size, it.size)) }
    }

    /** Filters `frames` frames of interleaved samples in place. */
    fun process(samples: FloatArray, frames: Int) {
        if (preset == null) return
        val channels = channels
        val bands = coefficients.size
        for (frame in 0 until frames) {
            for (channel in 0 until channels) {
                val index = frame * channels + channel
                var x = samples[index] * gain
                for (band in 0 until bands) {
                    val c = coefficients[band]
                    val s = (band * channels + channel) * 2
                    val y = c.b0 * x + state[s]
                    state[s] = c.b1 * x - c.a1 * y + state[s + 1]
                    state[s + 1] = c.b2 * x - c.a2 * y
                    x = y
                }
                samples[index] = x.toFloat()
            }
        }
    }
}

/**
 * Runs the equalizer on the audio on its way to Android. Media3's audio processors are skipped for hi-res songs when
 * the output is float (which keeps their 24 bits), so the equalizer sits here instead: decoded PCM in any integer depth
 * or float is converted to float, filtered, and handed to the real sink as float.
 *
 * A stream that [bitPerfect] takes (sample rate, channels, and the encoding the real sink will write) goes through
 * untouched, without the equalizer, as on the Mac when it plays bit-perfect.
 */
@OptIn(UnstableApi::class)
class EqualizerSink(
    sink: AudioSink,
    private val settings: () -> EqPreset?,
    private val bitPerfect: (sampleRate: Int, channels: Int, encoding: Int) -> Boolean,
) : ForwardingAudioSink(sink) {
    private val filters = EqFilters()
    /** Whether the current stream is converted and filtered here (decided when it is configured). */
    private var processing = false
    private var inputEncoding = C.ENCODING_INVALID
    private var channels = 0
    private var output: ByteBuffer = ByteBuffer.allocateDirect(0)
    private var samples = FloatArray(0)
    /** A filtered buffer the real sink has not taken all of yet. */
    private var pending: ByteBuffer? = null

    override fun configure(audioSinkConfig: AudioSink.AudioSinkConfig) {
        val format = audioSinkConfig.format
        val pcm = MimeTypes.AUDIO_RAW == format.sampleMimeType
        // The real sink writes 16-bit as it comes and hi-res as float (it is built with float output).
        val written = if (format.pcmEncoding == C.ENCODING_PCM_16BIT || format.pcmEncoding == C.ENCODING_PCM_8BIT) C.ENCODING_PCM_16BIT
            else C.ENCODING_PCM_FLOAT
        val direct = pcm && bitPerfect(format.sampleRate, format.channelCount, written)
        processing = !direct && pcm && format.pcmEncoding in SUPPORTED
        pending = null
        if (!processing) return super.configure(audioSinkConfig)
        inputEncoding = format.pcmEncoding
        channels = format.channelCount
        filters.configure(format.sampleRate, channels)
        filters.reset()
        val floatFormat = format.buildUpon().setPcmEncoding(C.ENCODING_PCM_FLOAT).build()
        @Suppress("DEPRECATION")
        super.configure(AudioSink.AudioSinkConfig.Builder(floatFormat)
            .setOutputChannelMapping(audioSinkConfig.outputChannelMapping)
            .setPreferredBufferSizeOverride(audioSinkConfig.preferredBufferSizeOverride)
            .setTimeline(audioSinkConfig.timeline)
            .setMediaPeriodId(audioSinkConfig.mediaPeriodId)
            .build())
    }

    override fun handleBuffer(buffer: ByteBuffer, presentationTimeUs: Long, encodedAccessUnitCount: Int): Boolean {
        if (!processing) return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount)
        // The renderer hands the same buffer again until it is taken: filtered once, then offered until the sink has it all.
        val filtered = pending ?: convert(buffer).also { pending = it }
        val done = super.handleBuffer(filtered, presentationTimeUs, encodedAccessUnitCount)
        if (done) pending = null
        return done
    }

    private fun convert(buffer: ByteBuffer): ByteBuffer {
        val bytesPerSample = when (inputEncoding) {
            C.ENCODING_PCM_8BIT -> 1
            C.ENCODING_PCM_16BIT -> 2
            C.ENCODING_PCM_24BIT -> 3
            else -> 4
        }
        val count = buffer.remaining() / bytesPerSample
        if (samples.size < count) samples = FloatArray(count)
        val input = buffer.order(ByteOrder.LITTLE_ENDIAN)
        var position = input.position()
        for (i in 0 until count) {
            samples[i] = when (inputEncoding) {
                C.ENCODING_PCM_8BIT -> ((input.get(position).toInt() and 0xFF) - 128) / 128f
                C.ENCODING_PCM_16BIT -> input.getShort(position) / 32768f
                C.ENCODING_PCM_24BIT -> ((input.get(position).toInt() and 0xFF) or ((input.get(position + 1).toInt() and 0xFF) shl 8) or
                    (input.get(position + 2).toInt() shl 16)) / 8388608f
                C.ENCODING_PCM_32BIT -> (input.getInt(position) / 2147483648.0).toFloat()
                else -> input.getFloat(position)
            }
            position += bytesPerSample
        }
        buffer.position(buffer.limit())
        filters.setPreset(settings())
        filters.process(samples, count / channels.coerceAtLeast(1))
        if (output.capacity() < count * 4) output = ByteBuffer.allocateDirect(count * 4 * 2).order(ByteOrder.nativeOrder())
        output.clear()
        output.asFloatBuffer().put(samples, 0, count)
        output.limit(count * 4)
        return output
    }

    override fun flush() {
        pending = null
        filters.reset()
        super.flush()
    }

    override fun reset() {
        pending = null
        filters.reset()
        super.reset()
    }

    private companion object {
        val SUPPORTED = setOf(C.ENCODING_PCM_8BIT, C.ENCODING_PCM_16BIT, C.ENCODING_PCM_24BIT, C.ENCODING_PCM_32BIT, C.ENCODING_PCM_FLOAT)
    }
}
