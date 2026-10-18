package dev.irwingbraga.groovelight.ui

import android.app.Application
import android.content.ComponentName
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import dev.irwingbraga.groovelight.playback.AudioPathReport
import dev.irwingbraga.groovelight.playback.PlaybackService
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The screens' side of playback: a MediaController connected to [PlaybackService], and what it is playing. */
class PlayerModel(application: Application) : AndroidViewModel(application) {
    data class NowPlaying(
        val title: String,
        val artist: String?,
        val album: String?,
        val isPlaying: Boolean,
        val hasNext: Boolean,
        val hasPrevious: Boolean,
        /** Why the song could not be played (a format this device cannot decode, a file gone). */
        val error: String?,
    )

    private val state = MutableStateFlow<NowPlaying?>(null)
    val nowPlaying: StateFlow<NowPlaying?> = state.asStateFlow()
    val audioPath = AudioPathReport.current

    private var controller: MediaController? = null
    private val listener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) = update(player)
    }
    private val connecting = MediaController.Builder(application, SessionToken(application, ComponentName(application, PlaybackService::class.java)))
        .buildAsync()

    init {
        connecting.addListener({
            runCatching { connecting.get() }.getOrNull()?.let { connected ->
                controller = connected
                connected.addListener(listener)
                update(connected)
            }
        }, ContextCompat.getMainExecutor(application))
    }

    private fun update(player: Player) {
        val item = player.currentMediaItem
        if (item == null) {
            state.value = null
            return
        }
        val metadata = player.mediaMetadata
        state.value = NowPlaying(
            title = metadata.title?.toString() ?: item.mediaMetadata.title?.toString() ?: "",
            artist = metadata.artist?.toString(),
            album = metadata.albumTitle?.toString(),
            isPlaying = player.isPlaying,
            hasNext = player.hasNextMediaItem(),
            hasPrevious = player.hasPreviousMediaItem(),
            error = player.playerError?.let { error ->
                when (error.errorCode) {
                    PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED ->
                        "Android cannot read ${item.mediaId.substringAfterLast('.').uppercase()} files"
                    PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND -> "The file is no longer in the music folder"
                    else -> error.errorCodeName
                }
            },
        )
    }

    /** Plays `items` from `start` (replacing the queue). */
    fun play(items: List<MediaItem>, start: Int) {
        controller?.run {
            setMediaItems(items, start, 0)
            prepare()
            play()
        }
    }

    fun togglePlayPause() {
        controller?.run {
            if (isPlaying) pause() else {
                // After an error the player is idle: prepare again to retry.
                if (playbackState == Player.STATE_IDLE) prepare()
                play()
            }
        }
    }

    fun next() { controller?.seekToNextMediaItem() }

    fun previous() { controller?.seekToPrevious() }

    override fun onCleared() {
        controller?.removeListener(listener)
        MediaController.releaseFuture(connecting)
    }
}
