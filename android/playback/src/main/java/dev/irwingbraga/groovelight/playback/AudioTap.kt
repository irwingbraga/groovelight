package dev.irwingbraga.groovelight.playback

/**
 * The music as it is heard, for the visualizers: the equalizer's sink copies what it hands to Android (mixed to mono)
 * into a ring, only while a visualizer shows ([enabled]). Each player has its own channel (crossfade plays two); the
 * one playing is [active]. [read] gives the latest samples that are audible now, the output's latency allowed for.
 */
object AudioTap {
    /** Set by a visualizer while it is on screen: otherwise the sink copies nothing. */
    @Volatile var enabled = false
    @Volatile var active = 0

    internal val channels = Array(2) { Channel() }

    class Channel internal constructor() {
        private val ring = FloatArray(SIZE)
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
                ring[((written + frame) % SIZE).toInt()] = sum / channels
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
    }

    /** Fills `out` with the latest audible samples (mono, -1 to 1) of the player playing; false when it plays nothing. */
    fun read(out: FloatArray): Boolean = channels[active].read(out)

    /** The sample rate of what [read] gives. */
    val sampleRate: Int get() = channels[active].sampleRate

    private const val SIZE = 1 shl 15
}
