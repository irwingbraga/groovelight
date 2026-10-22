package dev.irwingbraga.groovelight.app

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import dev.irwingbraga.groovelight.playback.Browsing
import dev.irwingbraga.groovelight.widget.withPlayer

/**
 * "Play ... on Groovelight" (Google Assistant, Android Auto's voice): the songs found for the words, the first one
 * playing, or the queue as it was when nothing was said but "play".
 */
object VoiceSearch {
    @OptIn(UnstableApi::class)
    suspend fun play(context: Context, query: String?) {
        val browsing = Browsing.current ?: LibraryBrowsing(context)
        val found = query?.takeIf { it.isNotBlank() }?.let { browsing.search(it).firstOrNull() }?.let { browsing.playable(it.mediaId) }
        withPlayer(context) { player ->
            if (found != null) player.setMediaItems(found.mediaItems, found.startIndex, found.startPositionMs)
            if (player.mediaItemCount == 0) return@withPlayer
            player.prepare()
            player.play()
        }
    }
}
