package dev.irwingbraga.groovelight.playback

import android.os.SystemClock
import androidx.media3.common.MediaItem
import androidx.media3.common.Player

/**
 * How long each song was heard, for plays, skips and scrobbles: the time it actually played (seeking and pausing
 * do not count), from when it started. The app sets [onListen] (the library counts it, the Mac gets it later).
 */
object Listens {
    /** A song that stopped being the current one (finished, skipped, replaced or the player closed). */
    data class Listen(val mediaId: String, val startedAt: Long, val listenedMs: Long)

    @Volatile var onListen: ((Listen) -> Unit)? = null

    /** Follows one player: add it as a listener, and call [finish] when the player goes away. */
    internal class Tracker(private val player: Player) : Player.Listener {
        private var mediaId: String? = null
        private var startedAt = 0L
        private var listenedMs = 0L
        /** While playing: when it started playing (elapsed realtime). */
        private var since: Long? = null

        init {
            begin(player.currentMediaItem)
            if (player.isPlaying) resume()
        }

        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            finish()
            begin(mediaItem)
            if (player.isPlaying) resume()
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            if (isPlaying) resume() else pause()
        }

        override fun onPlaybackStateChanged(state: Int) {
            // The queue ended (or was cleared): the last song counts now, not when the next one starts.
            if (state == Player.STATE_ENDED || state == Player.STATE_IDLE) {
                finish()
                // Played again from there (Play after the end, or after an error): a new listen.
                begin(player.currentMediaItem)
            }
        }

        private fun begin(item: MediaItem?) {
            mediaId = item?.mediaId?.takeIf { it.isNotEmpty() }
            startedAt = 0
            listenedMs = 0
            since = null
        }

        private fun resume() {
            if (mediaId == null || since != null) return
            if (startedAt == 0L) startedAt = System.currentTimeMillis()
            since = SystemClock.elapsedRealtime()
        }

        private fun pause() {
            since?.let { listenedMs += SystemClock.elapsedRealtime() - it }
            since = null
        }

        /** Reports the current song, if it played at all. */
        fun finish() {
            pause()
            val id = mediaId
            // Under a second is not a listen (nor a skip): a song passed through, as when crossfade stops the player that
            // faded out just as it reached the next song.
            if (id != null && listenedMs >= 1_000) Listens.onListen?.invoke(Listen(id, startedAt, listenedMs))
            begin(null)
        }
    }
}
