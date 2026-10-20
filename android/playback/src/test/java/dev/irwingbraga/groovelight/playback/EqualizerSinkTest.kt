package dev.irwingbraga.groovelight.playback

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.audio.AudioSink
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy
import java.nio.ByteBuffer
import java.nio.ByteOrder

@UnstableApi
class EqualizerSinkTest {
    /** The real sink, faked: records the format it is configured with and the samples it takes. */
    private class Recorder {
        var format: Format? = null
        val samples = mutableListOf<Float>()
        /** How many bytes it takes per call (to test a sink that is full and takes part of a buffer). */
        var takes = Int.MAX_VALUE
        val sink: AudioSink = Proxy.newProxyInstance(AudioSink::class.java.classLoader, arrayOf(AudioSink::class.java)) { _, method, args ->
            when (method.name) {
                "configure" -> { format = (args[0] as AudioSink.AudioSinkConfig).format; null }
                "handleBuffer" -> {
                    val buffer = args[0] as ByteBuffer
                    val count = minOf(takes, buffer.remaining()) / 4
                    repeat(count) { samples += buffer.order(ByteOrder.nativeOrder()).float }
                    !buffer.hasRemaining()
                }
                else -> when (method.returnType) {
                    Boolean::class.javaPrimitiveType -> false
                    Int::class.javaPrimitiveType -> 0
                    Long::class.javaPrimitiveType -> 0L
                    Float::class.javaPrimitiveType -> 0f
                    else -> null
                }
            }
        } as AudioSink
    }

    private fun pcm(encoding: Int, rate: Int = 48_000) = AudioSink.AudioSinkConfig.Builder(
        Format.Builder().setSampleMimeType(MimeTypes.AUDIO_RAW).setPcmEncoding(encoding).setChannelCount(2).setSampleRate(rate).build()).build()

    @Test
    fun convertsEveryDepthToFloatUnchangedWithTheEqualizerOff() {
        val recorder = Recorder()
        val sink = EqualizerSink(recorder.sink, settings = { null }, bitPerfect = { _, _, _ -> false })
        sink.configure(pcm(C.ENCODING_PCM_16BIT))
        assertEquals(C.ENCODING_PCM_FLOAT, recorder.format?.pcmEncoding)
        val shorts = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putShort(16384).putShort(-32768).putShort(0).putShort(32767).flip() as ByteBuffer
        assertTrue(sink.handleBuffer(shorts, 0, 1))
        assertFalse(shorts.hasRemaining())
        assertEquals(listOf(0.5f, -1f, 0f, 32767 / 32768f), recorder.samples)

        // 24-bit, packed little endian: the full resolution reaches the sink.
        recorder.samples.clear()
        sink.configure(pcm(C.ENCODING_PCM_24BIT))
        val packed = ByteBuffer.wrap(byteArrayOf(0x01, 0x00, 0x00, 0x00, 0x00, 0x80.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0x7F, 0x00, 0x00, 0x40))
        assertTrue(sink.handleBuffer(packed, 0, 1))
        assertEquals(listOf(1 / 8388608f, -1f, 8388607 / 8388608f, 0.5f), recorder.samples)
    }

    @Test
    fun filtersWithTheCurveAndOffersTheRestWhenTheSinkIsFull() {
        val recorder = Recorder()
        // A preamp alone: every sample at half (-6.02 dB).
        val half = EqPreset("Half", -20 * kotlin.math.log10(2.0), EqPreset.FLAT.bands)
        val sink = EqualizerSink(recorder.sink, settings = { half }, bitPerfect = { _, _, _ -> false })
        sink.configure(pcm(C.ENCODING_PCM_FLOAT))
        val input = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN).putFloat(0.8f).putFloat(-0.4f).putFloat(1f).putFloat(0f).flip() as ByteBuffer
        // The sink takes 8 bytes at a time: the renderer calls again with the same buffer until it is all taken.
        recorder.takes = 8
        assertFalse(sink.handleBuffer(input, 0, 1))
        assertTrue(sink.handleBuffer(input, 0, 1))
        assertEquals(4, recorder.samples.size)
        listOf(0.4f, -0.2f, 0.5f, 0f).zip(recorder.samples).forEach { (expected, actual) -> assertEquals(expected, actual, 1e-6f) }
    }

    @Test
    fun bitPerfectStreamsGoThroughUntouched() {
        val recorder = Recorder()
        var asked: Triple<Int, Int, Int>? = null
        val sink = EqualizerSink(recorder.sink, settings = { EqPreset.BUILT_INS[1] }, bitPerfect = { rate, channels, encoding ->
            asked = Triple(rate, channels, encoding)
            true
        })
        // A 24-bit song: the real sink writes it as float, so that is the format asked of the DAC.
        sink.configure(pcm(C.ENCODING_PCM_24BIT, rate = 96_000))
        assertEquals(Triple(96_000, 2, C.ENCODING_PCM_FLOAT), asked)
        assertEquals(C.ENCODING_PCM_24BIT, recorder.format?.pcmEncoding)
    }
}
