package dev.irwingbraga.groovelight.playback

import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.sqrt

/**
 * The music as it is heard, for the visualizers and the players' VU meters: the equalizer's sink copies what it hands
 * to Android (mixed to mono, and its left and right) into rings, only while something shows it ([enabled]). Each
 * player has its own channel (crossfade plays two); the one playing is [active]. [read] gives the latest samples that
 * are audible now, the output's latency allowed for, and [levels] their loudness on each side.
 */
object AudioTap {
    private val users = AtomicInteger(0)

    /** True while a visualizer or a VU meter is on screen ([start]ed and not yet [stop]ped): otherwise the sink copies nothing. */
    val enabled: Boolean get() = users.get() > 0
    @Volatile var active = 0

    fun start() { users.incrementAndGet() }
    fun stop() { users.updateAndGet { (it - 1).coerceAtLeast(0) } }

    internal val channels = Array(2) { Channel() }

    class Channel internal constructor() {
        private val ring = FloatArray(SIZE)
        private val left = FloatArray(SIZE)
        private val right = FloatArray(SIZE)
        /** Frames written so far. */
        private var written = 0L
        @Volatile var sampleRate = 44_100
        /** Frames written but not heard yet (in the output's buffers). */
        @Volatile var latencyFrames = 0L
        @Volatile var lastWriteAt = 0L

        @Synchronized
        internal fun write(samples: FloatArray, count: Int, channels: Int) {
            val frames = count / channels.coerceAtLeast(1)
            for (frame in 0 until frames) {
                var sum = 0f
                val base = frame * channels
                for (channel in 0 until channels) sum += samples[base + channel]
                val at = ((written + frame) % SIZE).toInt()
                ring[at] = sum / channels
                left[at] = samples[base]
                right[at] = if (channels > 1) samples[base + 1] else samples[base]
            }
            written += frames
            lastWriteAt = System.nanoTime()
        }

        @Synchronized
        internal fun read(out: FloatArray): Boolean {
            // Nothing written lately: paused, or another player plays.
            if (System.nanoTime() - lastWriteAt > 300_000_000L || written < out.size) return false
            val end = (written - latencyFrames.coerceIn(0, SIZE - out.size.toLong())).coerceAtLeast(out.size.toLong())
            val start = end - out.size
            for (i in out.indices) out[i] = ring[((start + i) % SIZE).toInt()]
            return true
        }

        /** The RMS of the latest audible [frames] on the left and the right (full scale 1), or null when nothing plays. */
        @Synchronized
        internal fun levels(frames: Int): Pair<Float, Float>? {
            if (System.nanoTime() - lastWriteAt > 300_000_000L || written < frames) return null
            val end = (written - latencyFrames.coerceIn(0, SIZE - frames.toLong())).coerceAtLeast(frames.toLong())
            var l = 0.0
            var r = 0.0
            for (i in 0 until frames) {
                val at = ((end - frames + i) % SIZE).toInt()
                l += left[at] * left[at]
                r += right[at] * right[at]
            }
            return sqrt(l / frames).toFloat() to sqrt(r / frames).toFloat()
        }
    }

    /** The loudness heard now on each side: the RMS over the last 50 ms, or null when nothing plays here. */
    fun levels(): Pair<Float, Float>? = channels[active].let { it.levels((it.sampleRate / 20).coerceIn(256, SIZE / 2)) }

    /** Fills `out` with the latest audible samples (mono, -1 to 1) of the player playing; false when it plays nothing. */
    fun read(out: FloatArray): Boolean = channels[active].read(out)

    /** The sample rate of what [read] gives. */
    val sampleRate: Int get() = channels[active].sampleRate

    private const val SIZE = 1 shl 15
}
