package dev.irwingbraga.groovelight.playback

import android.content.Context
import android.net.Uri
import androidx.media3.common.Player
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * What is playing, for what shows it outside the app (home screen widgets): kept by [PlaybackService] while it runs,
 * and read from the saved queue otherwise ([of]), paused where it was left.
 */
object NowPlayingInfo {
    data class Info(
        val title: String,
        val artist: String?,
        val artwork: Uri?,
        val isPlaying: Boolean,
        val hasNext: Boolean,
        val hasPrevious: Boolean,
    )

    private val state = MutableStateFlow<Info?>(null)
    /** Null when the service is not running (then the saved queue tells) or nothing is queued. */
    val current: StateFlow<Info?> = state

    internal fun update(player: Player) {
        val item = player.currentMediaItem
        state.value = item?.let {
            val metadata = player.mediaMetadata
            Info(
                title = metadata.title?.toString() ?: it.mediaMetadata.title?.toString() ?: "",
                artist = metadata.artist?.toString() ?: it.mediaMetadata.artist?.toString(),
                artwork = metadata.artworkUri ?: it.mediaMetadata.artworkUri,
                isPlaying = player.isPlaying,
                hasNext = player.hasNextMediaItem(),
                hasPrevious = player.mediaItemCount > 0,
            )
        }
    }

    internal fun clear() {
        state.value = null
    }

    /** What is playing now, or the saved queue's song (paused) when the service is not running. */
    fun of(context: Context): Info? = state.value ?: QueueStore(context).load()?.let { saved ->
        val item = saved.items[saved.index]
        Info(item.mediaMetadata.title?.toString() ?: "", item.mediaMetadata.artist?.toString(), item.mediaMetadata.artworkUri,
            isPlaying = false, hasNext = saved.index < saved.items.lastIndex, hasPrevious = true)
    }
}
