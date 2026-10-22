package dev.irwingbraga.groovelight.widget

import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.core.content.ContextCompat
import androidx.glance.GlanceId
import androidx.glance.action.ActionParameters
import androidx.glance.appwidget.action.ActionCallback
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import dev.irwingbraga.groovelight.app.playerItems
import dev.irwingbraga.groovelight.library.LibraryDatabase
import dev.irwingbraga.groovelight.playback.PlaybackService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume

/** What a widget's button asks of the player ([Command]), or the album it plays ([AlbumKey]). */
val Command = ActionParameters.Key<String>("command")
val AlbumKey = ActionParameters.Key<String>("album")

/** The widgets' buttons: play or pause, next and previous, and playing an album (Recently Played). */
class PlayerAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val album = parameters[AlbumKey]
        if (album != null) return playAlbum(context, album)
        withPlayer(context) { player ->
            when (parameters[Command]) {
                "playPause" -> if (player.isPlaying) player.pause() else resume(player)
                "next" -> player.seekToNext()
                "previous" -> player.seekToPrevious()
            }
        }
    }

    private suspend fun playAlbum(context: Context, key: String) {
        val library = LibraryDatabase.get(context).library()
        val album = library.albumNow(key) ?: return
        val items = playerItems(context, library.tracksOfAlbumNow(key), mapOf(key to album), "Album · ${album.title}")
        if (items.isEmpty()) return
        withPlayer(context) { player ->
            player.setMediaItems(items, 0, 0)
            player.prepare()
            player.play()
        }
    }
}

/** Plays from where the queue is: prepared first when restored or stopped, from the start when it ended. */
private fun resume(player: Player) {
    if (player.playbackState == Player.STATE_IDLE) player.prepare()
    if (player.playbackState == Player.STATE_ENDED) player.seekTo(player.currentMediaItemIndex, 0)
    player.play()
}

/** Connects to the player (starting its service when needed), gives it the commands, and lets go a moment later. */
internal suspend fun withPlayer(context: Context, block: (MediaController) -> Unit) = withContext(Dispatchers.Main) {
    // The application's context: the one actions get comes from a broadcast, which may not bind to the player's service.
    val app = context.applicationContext
    val future = MediaController.Builder(app, SessionToken(app, ComponentName(app, PlaybackService::class.java))).buildAsync()
    val controller = suspendCancellableCoroutine<MediaController?> { continuation ->
        future.addListener({ continuation.resume(runCatching { future.get() }.getOrNull()) }, ContextCompat.getMainExecutor(app))
    } ?: return@withContext
    try {
        block(controller)
        // The commands reach the session before the connection closes.
        delay(1_000)
    } finally {
        controller.release()
    }
}

/** A cover for a widget, decoded small (widgets travel to the home screen as parcels). */
internal fun widgetCover(path: String?, size: Int): Bitmap? = path?.let {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(it, bounds)
    if (bounds.outWidth <= 0) return null
    var sample = 1
    while (bounds.outWidth / (sample * 2) >= size) sample *= 2
    BitmapFactory.decodeFile(it, BitmapFactory.Options().apply { inSampleSize = sample })
}
