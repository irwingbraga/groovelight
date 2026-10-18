package dev.irwingbraga.groovelight.playback

import android.app.PendingIntent
import android.content.pm.ApplicationInfo
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.util.EventLogger
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

/**
 * Plays the music: one ExoPlayer in a media session, which gives the notification, the lock screen, Bluetooth and
 * wired headset buttons and the hardware keys of players. The app's screens control it through a MediaController.
 * The queue is kept across restarts ([QueueStore]): it comes back paused where it was.
 */
class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null
    private lateinit var queue: QueueStore
    private val handler = Handler(Looper.getMainLooper())

    @OptIn(UnstableApi::class)
    override fun onCreate() {
        super.onCreate()
        val music = AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build()
        // Decoders hand over 32-bit float instead of 16-bit PCM: 24-bit files keep their resolution (float holds 24 bits
        // exactly), where the default would cut them to 16 bits before Android's mixer.
        val renderers = DefaultRenderersFactory(this).setEnableAudioFloatOutput(true)
        val player = ExoPlayer.Builder(this, renderers)
            .setAudioAttributes(music, /* handleAudioFocus = */ true)
            // Headphones unplugged or Bluetooth disconnected: pause instead of playing out loud.
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_LOCAL)
            .build()
        player.addAnalyticsListener(AudioPathReport.listener)
        player.addListener(AudioPathReport.playerListener(player))
        player.addListener(Normalization.listener(player))
        // Debug builds log every player event (adb logcat -s EventLogger), for checking formats on a device.
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) player.addAnalyticsListener(EventLogger())
        queue = QueueStore(this)
        queue.load()?.let { saved ->
            // Not prepared: nothing is decoded (and no notification shows) until play is pressed.
            player.setMediaItems(saved.items, saved.index, saved.positionMs)
            player.repeatMode = saved.repeatMode
        }
        player.addListener(saving(player))
        val builder = MediaSession.Builder(this, player).setCallback(Resumption())
        // Tapping the notification opens the app.
        packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
            builder.setSessionActivity(PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        }
        session = builder.build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    /** Saves the queue when it changes, when playback pauses or stops, and every 10 seconds while playing. */
    private fun saving(player: Player) = object : Player.Listener {
        private val tick = object : Runnable {
            override fun run() {
                queue.save(player)
                handler.postDelayed(this, 10_000)
            }
        }

        override fun onEvents(player: Player, events: Player.Events) {
            if (events.containsAny(Player.EVENT_TIMELINE_CHANGED, Player.EVENT_MEDIA_ITEM_TRANSITION, Player.EVENT_IS_PLAYING_CHANGED,
                    Player.EVENT_REPEAT_MODE_CHANGED, Player.EVENT_POSITION_DISCONTINUITY)) queue.save(player)
            if (events.contains(Player.EVENT_IS_PLAYING_CHANGED)) {
                handler.removeCallbacks(tick)
                if (player.isPlaying) handler.postDelayed(tick, 10_000)
            }
        }
    }

    /** Bluetooth's play button or the system's media controls after a restart: the saved queue, where it was. */
    private inner class Resumption : MediaSession.Callback {
        @OptIn(UnstableApi::class)
        override fun onPlaybackResumption(mediaSession: MediaSession, controller: MediaSession.ControllerInfo, isForPlayback: Boolean):
            ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
            val player = mediaSession.player
            val items = (0 until player.mediaItemCount).map { player.getMediaItemAt(it) }
            if (items.isEmpty()) return Futures.immediateFailedFuture(UnsupportedOperationException("Nothing to resume"))
            return Futures.immediateFuture(MediaSession.MediaItemsWithStartPosition(items, player.currentMediaItemIndex, player.currentPosition))
        }
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        session?.run {
            queue.save(player)
            player.release()
            release()
        }
        session = null
        super.onDestroy()
    }
}
