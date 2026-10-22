package dev.irwingbraga.groovelight.playback

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer

/**
 * Crossfade between songs ([PlaybackSettings.crossfade] seconds, 0 for none): ExoPlayer plays one song at a time, so
 * two players take turns. Near the end of a song the idle one gets the same queue from the next song and starts it
 * from silence, rising, and becomes the one playing (`onSwap`: the session, audio focus and the screens follow it)
 * while the other fades its last seconds out and stops.
 *
 * Not between songs of the same album (gapless albums stay gapless), nor with bit-perfect output, repeat one, the
 * sleep timer at the end of the song, or songs shorter than twice the fade. Pausing or changing song during a fade
 * ends it at once.
 */
internal class Crossfade(private val players: List<ExoPlayer>, private val onSwap: (from: ExoPlayer, to: ExoPlayer) -> Unit) {
    private val handler = Handler(Looper.getMainLooper())
    /** Each player's fade level (0 to 1), multiplied with its song's normalization gain. */
    private val levels = mutableMapOf<Player, Float>()
    private var fading: Fade? = null
    var active: ExoPlayer = players.first()
        private set

    private class Fade(val from: ExoPlayer, val to: ExoPlayer, val startedAt: Long, val durationMs: Long)

    /** The level a player plays at now (1 but while fading). */
    fun level(player: Player): Float = levels[player] ?: 1f

    /** Sets a player's volume: its song's gain, times its fade level. */
    fun applyVolume(player: Player) {
        player.volume = Normalization.volume(player.currentMediaItem) * level(player)
    }

    fun start() {
        handler.post(watch)
        players.forEach { player ->
            player.addListener(object : Player.Listener {
                override fun onIsPlayingChanged(isPlaying: Boolean) {
                    // Paused (or stopped) during a fade: the song fading out stops too.
                    if (!isPlaying && player === fading?.to && player.playbackState != Player.STATE_BUFFERING) finish()
                }

                override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                    // Another song chosen during a fade: no more of the old one. The old one reaching its next song: done.
                    if (player === fading?.to && reason != Player.MEDIA_ITEM_TRANSITION_REASON_PLAYLIST_CHANGED) finish()
                    if (player === fading?.from) finish()
                }
            })
        }
    }

    fun release() {
        handler.removeCallbacksAndMessages(null)
        fading = null
    }

    /** Checks a few times a second whether the song playing is near its end. */
    private val watch = object : Runnable {
        override fun run() {
            if (fading == null) maybeStart()
            handler.postDelayed(this, if (fading != null) 30 else 200)
        }
    }

    private fun maybeStart() {
        val seconds = PlaybackSettings.crossfade.value
        val from = active
        if (seconds <= 0 || !from.isPlaying || PlaybackSettings.bitPerfectActive.value) return
        if (SleepTimer.state.value == SleepTimer.State.EndOfSong || from.repeatMode == Player.REPEAT_MODE_ONE) return
        val duration = from.duration.takeIf { it != C.TIME_UNSET } ?: return
        val fadeMs = seconds * 1_000L
        val left = duration - from.currentPosition
        if (left > fadeMs || left < 500 || duration < fadeMs * 2 || !from.hasNextMediaItem()) return
        val next = from.getMediaItemAt(from.nextMediaItemIndex)
        if (from.currentMediaItem?.let(::albumOf) != null && albumOf(from.currentMediaItem!!) == albumOf(next)) return
        begin(from, players.first { it !== from }, left)
    }

    private fun begin(from: ExoPlayer, to: ExoPlayer, durationMs: Long) {
        val items = (0 until from.mediaItemCount).map(from::getMediaItemAt)
        to.setMediaItems(items, from.nextMediaItemIndex, 0)
        to.repeatMode = from.repeatMode
        to.playbackParameters = from.playbackParameters
        levels[to] = 0f
        applyVolume(to)
        to.prepare()
        to.play()
        // The old one plays out its song, fading to silence as it ends, and is stopped as it moves on. It is left exactly as
        // it is: changing its queue (or pausing at the end) makes it drop the next song it already reads for gapless
        // playback and buffer again, a gap in the song fading out.
        active = to
        fading = Fade(from, to, SystemClock.elapsedRealtime(), durationMs)
        onSwap(from, to)
        handler.post(ramp)
    }

    private val ramp = object : Runnable {
        override fun run() {
            val fade = fading ?: return
            val progress = ((SystemClock.elapsedRealtime() - fade.startedAt).toFloat() / fade.durationMs).coerceIn(0f, 1f)
            // Equal power: the sum sounds as loud as one song all the way through.
            levels[fade.to] = kotlin.math.sin(progress * Math.PI / 2).toFloat()
            levels[fade.from] = kotlin.math.cos(progress * Math.PI / 2).toFloat()
            applyVolume(fade.to)
            applyVolume(fade.from)
            if (progress >= 1f || fade.from.playbackState == Player.STATE_ENDED) finish() else handler.postDelayed(this, 30)
        }
    }

    /** Ends the fade: the old song stops, the new one plays at its own volume. */
    private fun finish() {
        val fade = fading ?: return
        fading = null
        handler.removeCallbacks(ramp)
        fade.from.stop()
        fade.from.clearMediaItems()
        levels.remove(fade.from)
        levels.remove(fade.to)
        applyVolume(fade.from)
        applyVolume(fade.to)
    }

    companion object {
        /** Extra of an item's metadata: its album (songs of the same album are not crossfaded). */
        const val ALBUM_KEY = "dev.irwingbraga.groovelight.album"

        private fun albumOf(item: MediaItem): String? = item.mediaMetadata.extras?.getString(ALBUM_KEY)
    }
}
