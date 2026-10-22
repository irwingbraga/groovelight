@file:OptIn(UnstableApi::class)

package dev.irwingbraga.groovelight.playback

import android.app.PendingIntent
import android.content.Context
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
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.util.EventLogger
import android.os.Bundle
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaLibraryService.LibraryParams
import androidx.media3.session.MediaLibraryService.MediaLibrarySession
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionError
import com.google.common.collect.ImmutableList
import kotlinx.coroutines.guava.future
import com.google.common.util.concurrent.Futures
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import com.google.common.util.concurrent.ListenableFuture

/**
 * Plays the music: one ExoPlayer in a media session, which gives the notification, the lock screen, Bluetooth and
 * wired headset buttons and the hardware keys of players. The app's screens control it through a MediaController.
 * The queue is kept across restarts ([QueueStore]): it comes back paused where it was.
 */
class PlaybackService : MediaLibraryService() {
    private var session: MediaLibrarySession? = null
    private lateinit var bitPerfect: BitPerfect
    private val scope = MainScope()
    private lateinit var queue: QueueStore
    private val handler = Handler(Looper.getMainLooper())
    private val listens = mutableListOf<Listens.Tracker>()
    private lateinit var players: List<ExoPlayer>
    private lateinit var crossfade: Crossfade
    private val music = AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build()

    /** The player the session (and so the app, the notification and headsets) controls now. */
    private val player: ExoPlayer get() = crossfade.active

    @OptIn(UnstableApi::class)
    override fun onCreate() {
        super.onCreate()
        PlaybackSettings.init(this)
        bitPerfect = BitPerfect(this)
        // Two players: one plays, the other starts the next song when crossfading ([Crossfade]), then they swap.
        players = listOf(buildPlayer(0, focus = true), buildPlayer(1, focus = false))
        crossfade = Crossfade(players) { from, to -> handOver(from, to) }
        queue = QueueStore(this)
        queue.load()?.let { saved ->
            // Not prepared: nothing is decoded (and no notification shows) until play is pressed.
            player.setMediaItems(saved.items, saved.index, saved.positionMs)
            player.repeatMode = saved.repeatMode
        }
        NowPlayingInfo.update(player)
        SleepTimer.attach(player)
        crossfade.start()
        // The normalization setting, or bit-perfect output starting or ending, changes the song's volume at once.
        scope.launch {
            combine(PlaybackSettings.normalization, PlaybackSettings.bitPerfectActive) { _, _ -> }.collect {
                if (SleepTimer.state.value !is SleepTimer.State.At) crossfade.applyVolume(player)
            }
        }
        val builder = MediaLibrarySession.Builder(this, player, Library())
        // Tapping the notification opens the app.
        packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
            builder.setSessionActivity(PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        }
        session = builder.build()
    }

    /** A player (`index`: its [AudioTap] channel) with everything around it; `focus`: whether it holds audio focus (the one playing does). */
    @OptIn(UnstableApi::class)
    private fun buildPlayer(index: Int, focus: Boolean): ExoPlayer {
        // Decoders hand over 32-bit float instead of 16-bit PCM: 24-bit files keep their resolution (float holds 24 bits
        // exactly), where the default would cut them to 16 bits before Android's mixer. The equalizer runs in the sink
        // (Media3 skips audio processors for float output), and speed is the audio output's, which keeps the pitch.
        val renderers = object : DefaultRenderersFactory(this) {
            override fun buildAudioSink(context: Context, enableFloatOutput: Boolean, enableAudioOutputPlaybackParams: Boolean): AudioSink =
                EqualizerSink(super.buildAudioSink(context, enableFloatOutput, enableAudioOutputPlaybackParams)!!,
                    settings = { PlaybackSettings.activeCurve }, bitPerfect = bitPerfect::prepare, tap = AudioTap.channels[index])
        }.setEnableAudioFloatOutput(true).setEnableAudioOutputPlaybackParameters(true)
        val player = ExoPlayer.Builder(this, renderers)
            .setAudioAttributes(music, /* handleAudioFocus = */ focus)
            // Headphones unplugged or Bluetooth disconnected: pause instead of playing out loud.
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_LOCAL)
            .build()
        player.addAnalyticsListener(AudioPathReport.listener)
        player.addListener(AudioPathReport.playerListener(player))
        player.addListener(Normalization.listener(player) { crossfade.level(it) })
        // Debug builds log every player event (adb logcat -s EventLogger), for checking formats on a device.
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) player.addAnalyticsListener(EventLogger())
        player.addListener(saving(player))
        listens += Listens.Tracker(player).also(player::addListener)
        // What is playing, for the home screen widgets.
        player.addListener(object : Player.Listener {
            override fun onEvents(player: Player, events: Player.Events) {
                if (player === this@PlaybackService.player) NowPlayingInfo.update(player)
            }
        })
        return player
    }

    /** Crossfade moved the music to the other player: the session, audio focus and the sleep timer follow it. */
    private fun handOver(from: ExoPlayer, to: ExoPlayer) {
        AudioTap.active = players.indexOf(to)
        from.setAudioAttributes(music, /* handleAudioFocus = */ false)
        to.setAudioAttributes(music, /* handleAudioFocus = */ true)
        session?.player = to
        SleepTimer.attach(to)
        NowPlayingInfo.update(to)
        queue.save(to)
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession? = session

    /** Saves the queue when it changes, when playback pauses or stops, and every 10 seconds while playing. */
    private fun saving(player: Player) = object : Player.Listener {
        private val tick = object : Runnable {
            override fun run() {
                if (player === this@PlaybackService.player) queue.save(player)
                handler.postDelayed(this, 10_000)
            }
        }

        override fun onEvents(player: Player, events: Player.Events) {
            // Only the player playing: the other one, fading out, holds just the song it ends.
            if (player !== this@PlaybackService.player) return
            if (events.containsAny(Player.EVENT_TIMELINE_CHANGED, Player.EVENT_MEDIA_ITEM_TRANSITION, Player.EVENT_IS_PLAYING_CHANGED,
                    Player.EVENT_REPEAT_MODE_CHANGED, Player.EVENT_POSITION_DISCONTINUITY)) queue.save(player)
            if (events.contains(Player.EVENT_IS_PLAYING_CHANGED)) {
                handler.removeCallbacks(tick)
                if (player.isPlaying) handler.postDelayed(tick, 10_000)
            }
        }
    }

    /**
     * The session's answers: browsing the library (Android Auto, through [Browsing]), playing what is chosen there
     * (browsers send ids only: they become the songs, with the rest of their album or playlist), voice search ("play
     * ... on Groovelight"), and resuming (Bluetooth's play button or the system's media controls after a restart: the
     * saved queue, where it was).
     */
    private inner class Library : MediaLibrarySession.Callback {
        private val browsing get() = Browsing.current

        override fun onGetLibraryRoot(session: MediaLibrarySession, browser: MediaSession.ControllerInfo, params: LibraryParams?):
            ListenableFuture<LibraryResult<MediaItem>> {
            val extras = Bundle().apply {
                putBoolean("android.media.browse.SEARCH_SUPPORTED", true)
                // Albums as a grid, songs as a list.
                putInt("android.media.browse.CONTENT_STYLE_BROWSABLE_HINT", 2)
                putInt("android.media.browse.CONTENT_STYLE_PLAYABLE_HINT", 1)
            }
            val root = MediaItem.Builder().setMediaId(Browsing.ROOT)
                .setMediaMetadata(MediaMetadata.Builder().setTitle("Groovelight").setIsBrowsable(true).setIsPlayable(false).build())
                .build()
            return Futures.immediateFuture(LibraryResult.ofItem(root, LibraryParams.Builder().setExtras(extras).build()))
        }

        override fun onGetChildren(session: MediaLibrarySession, browser: MediaSession.ControllerInfo, parentId: String, page: Int,
                                   pageSize: Int, params: LibraryParams?): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> =
            scope.future {
                val items = browsing?.children(parentId).orEmpty()
                LibraryResult.ofItemList(paged(items, page, pageSize), params)
            }

        override fun onGetItem(session: MediaLibrarySession, browser: MediaSession.ControllerInfo, mediaId: String):
            ListenableFuture<LibraryResult<MediaItem>> = scope.future {
            browsing?.item(mediaId)?.let { LibraryResult.ofItem(it, null) } ?: LibraryResult.ofError(SessionError.ERROR_BAD_VALUE)
        }

        override fun onSearch(session: MediaLibrarySession, browser: MediaSession.ControllerInfo, query: String, params: LibraryParams?):
            ListenableFuture<LibraryResult<Void>> {
            scope.launch { session.notifySearchResultChanged(browser, query, browsing?.search(query).orEmpty().size, params) }
            return Futures.immediateFuture(LibraryResult.ofVoid())
        }

        override fun onGetSearchResult(session: MediaLibrarySession, browser: MediaSession.ControllerInfo, query: String, page: Int,
                                       pageSize: Int, params: LibraryParams?): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> =
            scope.future { LibraryResult.ofItemList(paged(browsing?.search(query).orEmpty(), page, pageSize), params) }

        override fun onSetMediaItems(mediaSession: MediaSession, controller: MediaSession.ControllerInfo, mediaItems: MutableList<MediaItem>,
                                     startIndex: Int, startPositionMs: Long): ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
            // The app's own items carry their files: as they are.
            if (mediaItems.all { it.localConfiguration != null }) {
                return Futures.immediateFuture(MediaSession.MediaItemsWithStartPosition(mediaItems, startIndex, startPositionMs))
            }
            return scope.future {
                val chosen = mediaItems.getOrNull(startIndex.coerceAtLeast(0)) ?: mediaItems.first()
                val query = chosen.requestMetadata.searchQuery
                val resolved = when {
                    // Voice search: the songs found, the first one first.
                    chosen.mediaId.isEmpty() && query != null -> browsing?.search(query)?.firstOrNull()?.let { browsing?.playable(it.mediaId) }
                    else -> browsing?.playable(chosen.mediaId)
                }
                resolved ?: MediaSession.MediaItemsWithStartPosition(emptyList(), 0, 0)
            }
        }

        override fun onAddMediaItems(mediaSession: MediaSession, controller: MediaSession.ControllerInfo, mediaItems: MutableList<MediaItem>):
            ListenableFuture<MutableList<MediaItem>> = scope.future {
            // Added from a browser (Play Next, Add to Queue): each one's songs.
            mediaItems.flatMap { item -> if (item.localConfiguration != null) listOf(item) else browsing?.playable(item.mediaId)?.mediaItems.orEmpty() }
                .toMutableList()
        }

        @OptIn(UnstableApi::class)
        override fun onPlaybackResumption(mediaSession: MediaSession, controller: MediaSession.ControllerInfo, isForPlayback: Boolean):
            ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
            val player = mediaSession.player
            val items = (0 until player.mediaItemCount).map { player.getMediaItemAt(it) }
            if (items.isEmpty()) return Futures.immediateFailedFuture(UnsupportedOperationException("Nothing to resume"))
            return Futures.immediateFuture(MediaSession.MediaItemsWithStartPosition(items, player.currentMediaItemIndex, player.currentPosition))
        }

        private fun paged(items: List<MediaItem>, page: Int, pageSize: Int): ImmutableList<MediaItem> {
            if (pageSize <= 0 || pageSize == Int.MAX_VALUE) return ImmutableList.copyOf(items)
            val from = (page * pageSize).coerceAtMost(items.size)
            return ImmutableList.copyOf(items.subList(from, (from + pageSize).coerceAtMost(items.size)))
        }
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        crossfade.release()
        bitPerfect.release()
        SleepTimer.detach()
        scope.cancel()
        queue.save(player)
        // The song playing when the service ends counts too.
        listens.forEach { it.finish() }
        NowPlayingInfo.clear()
        session?.release()
        players.forEach { it.release() }
        session = null
        super.onDestroy()
    }
}
