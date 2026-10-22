package dev.irwingbraga.groovelight.app

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.core.content.ContextCompat
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.ListenableFuture
import dev.irwingbraga.groovelight.R
import dev.irwingbraga.groovelight.playback.PlaybackService
import dev.irwingbraga.groovelight.sync.MainActivity

/**
 * The Quick Settings tile: the song playing (or paused) as its subtitle, on while playing; tapping it plays or pauses,
 * and with nothing to play it opens the app. Holding it opens the app too (the activity takes the tile's preferences).
 */
class PlayerTile : TileService() {
    private var connecting: ListenableFuture<MediaController>? = null
    private var controller: MediaController? = null
    private val listener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) = show()
    }

    override fun onStartListening() {
        show()
        val future = MediaController.Builder(this, SessionToken(this, ComponentName(this, PlaybackService::class.java))).buildAsync()
        connecting = future
        future.addListener({
            controller = runCatching { future.get() }.getOrNull()?.also {
                it.addListener(listener)
                show()
            }
        }, ContextCompat.getMainExecutor(this))
    }

    override fun onStopListening() {
        controller?.removeListener(listener)
        controller = null
        connecting?.let(MediaController::releaseFuture)
        connecting = null
    }

    override fun onClick() {
        val player = controller
        if (player == null || player.currentMediaItem == null) return openApp()
        if (player.isPlaying) player.pause() else {
            // Restored after a restart, or stopped (the player closed): prepared first.
            if (player.playbackState == Player.STATE_IDLE) player.prepare()
            if (player.playbackState == Player.STATE_ENDED) player.seekTo(player.currentMediaItemIndex, 0)
            player.play()
        }
    }

    private fun show() {
        val tile = qsTile ?: return
        val player = controller
        val item = player?.currentMediaItem
        val playing = player?.isPlaying == true
        tile.label = getString(R.string.app_name)
        tile.subtitle = item?.mediaMetadata?.title?.toString() ?: player?.mediaMetadata?.title?.toString() ?: "Nothing playing"
        tile.state = if (playing) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.icon = Icon.createWithResource(this, if (playing) R.drawable.ic_pause else R.drawable.ic_play)
        tile.contentDescription = if (playing) "Pause ${tile.subtitle}" else "Play"
        tile.updateTile()
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    private fun openApp() {
        val intent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
