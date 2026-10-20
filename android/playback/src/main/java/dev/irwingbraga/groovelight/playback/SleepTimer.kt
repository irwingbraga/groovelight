package dev.irwingbraga.groovelight.playback

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Pauses the music after a while, or at the end of the song playing. Kept with the playback service (not the
 * screens), so it works with the app closed; the last 10 seconds fade out.
 */
object SleepTimer {
    sealed interface State {
        data object Off : State
        /** Pauses at `endsAt` (SystemClock.elapsedRealtime). */
        data class At(val endsAt: Long) : State
        data object EndOfSong : State
    }

    private val _state = MutableStateFlow<State>(State.Off)
    val state: StateFlow<State> = _state.asStateFlow()

    private val handler = Handler(Looper.getMainLooper())
    private var player: Player? = null
    /** The song's volume when the fade started, or null while not fading. */
    private var volumeBeforeFade: Float? = null

    fun start(minutes: Int) {
        cancel()
        _state.value = State.At(SystemClock.elapsedRealtime() + minutes * 60_000L)
        handler.post(tick)
    }

    fun endOfSong() {
        cancel()
        _state.value = State.EndOfSong
    }

    fun cancel() {
        handler.removeCallbacks(tick)
        volumeBeforeFade?.let { volume -> player?.volume = volume }
        volumeBeforeFade = null
        _state.value = State.Off
    }

    private val tick = object : Runnable {
        override fun run() {
            val state = _state.value as? State.At ?: return
            val player = player
            val left = state.endsAt - SystemClock.elapsedRealtime()
            if (left <= 0) {
                player?.pause()
                // Back to the song's own volume for the next time it plays.
                volumeBeforeFade?.let { volume -> player?.volume = volume }
                volumeBeforeFade = null
                _state.value = State.Off
                return
            }
            if (player != null && left < FADE_MS) {
                val from = volumeBeforeFade ?: player.volume.also { volumeBeforeFade = it }
                player.volume = from * (left.toFloat() / FADE_MS)
            }
            handler.postDelayed(this, if (left < FADE_MS) 100 else minOf(left - FADE_MS, 1_000).coerceAtLeast(100))
        }
    }

    /** Called by the service with its player: the end-of-song timer watches it. */
    internal fun attach(player: Player) {
        this.player = player
        player.addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                if (_state.value == State.EndOfSong && reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO) {
                    player.pause()
                    _state.value = State.Off
                }
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_ENDED && _state.value == State.EndOfSong) _state.value = State.Off
            }
        })
    }

    internal fun detach() {
        cancel()
        player = null
    }

    private const val FADE_MS = 10_000L
}
