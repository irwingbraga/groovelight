package dev.irwingbraga.groovelight.ui

import android.content.Context
import android.media.AudioAttributes
import android.media.SoundPool
import android.os.Handler
import android.os.Looper
import dev.irwingbraga.groovelight.R

/**
 * The sound of a cassette deck cueing, as on the Mac and the iPhone: holding Rewind or Fast Forward with the heads on the
 * tape, the music racing by as a high chatter over the motor and the hiss. It runs while the scan goes on (each step
 * keeps it going) and fades out a moment after the last; off when turned off in Now Playing Look.
 */
object TapeCue {
    private var pool: SoundPool? = null
    private var sound = 0
    private var stream = 0
    private val handler = Handler(Looper.getMainLooper())
    private val fadeOut = object : Runnable {
        var step = 0
        override fun run() {
            val volume = 0.55f * (1 - (step + 1) / 3f)
            pool?.setVolume(stream, volume, volume)
            if (++step < 3) handler.postDelayed(this, 40) else { pool?.stop(stream); stream = 0 }
        }
    }

    fun init(context: Context) {
        if (pool != null) return
        pool = SoundPool.Builder().setMaxStreams(1)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            .build().also { sound = it.load(context, R.raw.tape_cue, 1) }
    }

    /** One step of a scan: starts the sound, or keeps it going. */
    fun cue() {
        val pool = pool ?: return
        if (!Cassettes.tapeCue.value) return
        handler.removeCallbacks(fadeOut)
        if (stream == 0) stream = pool.play(sound, 0.55f, 0.55f, 1, -1, 1f) else pool.setVolume(stream, 0.55f, 0.55f)
        // The scan steps every 0.15 s: a little longer without one, the key was let go.
        fadeOut.step = 0
        handler.postDelayed(fadeOut, 260)
    }
}
