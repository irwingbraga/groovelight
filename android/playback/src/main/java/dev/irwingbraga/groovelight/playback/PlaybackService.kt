package dev.irwingbraga.groovelight.playback

import android.app.PendingIntent
import android.content.pm.ApplicationInfo
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.util.EventLogger
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/**
 * Plays the music: one ExoPlayer in a media session, which gives the notification, the lock screen, Bluetooth and
 * wired headset buttons and the hardware keys of players. The app's screens control it through a MediaController.
 */
class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null

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
        // Debug builds log every player event (adb logcat -s EventLogger), for checking formats on a device.
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) player.addAnalyticsListener(EventLogger())
        val builder = MediaSession.Builder(this, player)
        // Tapping the notification opens the app.
        packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
            builder.setSessionActivity(PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        }
        session = builder.build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    override fun onDestroy() {
        session?.run {
            player.release()
            release()
        }
        session = null
        super.onDestroy()
    }
}
