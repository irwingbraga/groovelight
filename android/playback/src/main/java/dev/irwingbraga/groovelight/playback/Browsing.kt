@file:OptIn(UnstableApi::class)

package dev.irwingbraga.groovelight.playback

import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.MediaItem
import androidx.media3.session.MediaSession

/**
 * The library as Android Auto (and other media browsers) browse it, provided by the app ([current]): items by id
 * ([ROOT] and what it lists), search, and the songs to play for an item chosen there (its album or playlist, from it).
 */
interface Browsing {
    /** The items under `parentId` (browsable lists, or playable songs). */
    suspend fun children(parentId: String): List<MediaItem>

    suspend fun item(id: String): MediaItem?

    suspend fun search(query: String): List<MediaItem>

    /** What plays when `id` is chosen: a song plays with the rest of where it was listed; an album or a playlist from its start. */
    suspend fun playable(id: String): MediaSession.MediaItemsWithStartPosition?

    companion object {
        const val ROOT = "root"
        @Volatile var current: Browsing? = null
    }
}
