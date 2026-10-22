package dev.irwingbraga.groovelight.ui

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Bundle
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import androidx.lifecycle.AndroidViewModel
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import dev.irwingbraga.groovelight.playback.AudioPathReport
import dev.irwingbraga.groovelight.playback.PlaybackService
import dev.irwingbraga.groovelight.playback.SleepTimer
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flow

/**
 * The screens' side of playback: a MediaController connected to [PlaybackService], what it is playing, and the queue.
 *
 * The queue is always played in its order (the player's own shuffle stays off): shuffling reorders the songs after the
 * one playing, and turning it off puts them back in their original order, which each item carries ([ORDER]). So Up
 * Next shows exactly what plays next, and Play Next, Add to Queue and reordering do what they say in both modes.
 */
class PlayerModel(application: Application) : AndroidViewModel(application) {
    data class NowPlaying(
        /** The song's id on the Mac (null for an item that is not from the library). */
        val id: Long?,
        val title: String,
        val artist: String?,
        val album: String?,
        val albumArtist: String?,
        val albumKey: String?,
        /** The cover file the Mac sent. */
        val artwork: Uri?,
        /** Where the queue came from ("Album", "Playlist", ...), for Now Playing's header. */
        val source: String?,
        val isPlaying: Boolean,
        val isBuffering: Boolean,
        val hasNext: Boolean,
        val repeatMode: Int,
        /** From the library until the player knows (it is not prepared yet after a restart). */
        val durationMs: Long,
        /** Why the song could not be played (a format this device cannot decode, a file gone). */
        val error: String?,
    )

    /** A song of Up Next: `index` is its place in the player's queue. */
    data class QueueEntry(val index: Int, val key: String, val title: String, val artist: String?, val artwork: Uri?, val id: Long?)

    data class Progress(val positionMs: Long, val durationMs: Long)

    private val prefs = application.getSharedPreferences("player", Context.MODE_PRIVATE)
    private val state = MutableStateFlow<NowPlaying?>(null)
    val nowPlaying: StateFlow<NowPlaying?> = state.asStateFlow()
    private val queue = MutableStateFlow<List<QueueEntry>>(emptyList())
    val upNext: StateFlow<List<QueueEntry>> = queue.asStateFlow()
    private val shuffling = MutableStateFlow(prefs.getBoolean("shuffle", false))
    val shuffle: StateFlow<Boolean> = shuffling.asStateFlow()
    val audioPath = AudioPathReport.current
    private val speeds = MutableStateFlow(1f)
    /** Playback speed (1 is normal; the pitch is kept). */
    val speed: StateFlow<Float> = speeds.asStateFlow()
    val sleepTimer = SleepTimer.state

    /**
     * Whether the mini player is put away: closed by the user, or paused for longer than [hideAfter] (counted from when
     * it paused, also while the app was away). Playing anything brings it back; the queue is kept either way.
     */
    private val hidden = MutableStateFlow(false)
    val miniPlayerHidden: StateFlow<Boolean> = hidden.asStateFlow()
    /** Minutes paused before the mini player hides itself (0: never). */
    private val hideMinutes = MutableStateFlow(prefs.getInt("hideAfterMinutes", 15))
    val hideAfter: StateFlow<Int> = hideMinutes.asStateFlow()
    private var hiding: Job? = null
    private var wasPlaying: Boolean? = null

    private var controller: MediaController? = null
    private val listener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) {
            // Shuffle asked by another controller (a car, a watch): done the queue's way.
            if (player.shuffleModeEnabled) {
                player.shuffleModeEnabled = false
                if (!shuffling.value) toggleShuffle()
            }
            update(player)
            if (events.contains(Player.EVENT_PLAYBACK_PARAMETERS_CHANGED)) speeds.value = player.playbackParameters.speed
            if (events.containsAny(Player.EVENT_TIMELINE_CHANGED, Player.EVENT_MEDIA_ITEM_TRANSITION)) updateQueue(player)
        }
    }
    private val connecting = MediaController.Builder(application, SessionToken(application, ComponentName(application, PlaybackService::class.java)))
        .buildAsync()

    init {
        connecting.addListener({
            runCatching { connecting.get() }.getOrNull()?.let { connected ->
                controller = connected
                connected.addListener(listener)
                update(connected)
                updateQueue(connected)
                speeds.value = connected.playbackParameters.speed
            }
        }, ContextCompat.getMainExecutor(application))
    }

    private fun update(player: Player) {
        val item = player.currentMediaItem
        if (item == null) {
            state.value = null
            return
        }
        followPauses(player.isPlaying)
        val metadata = player.mediaMetadata
        val extras = item.mediaMetadata.extras
        val duration = player.duration.takeIf { it != C.TIME_UNSET } ?: item.mediaMetadata.durationMs ?: 0
        state.value = NowPlaying(
            id = item.mediaId.toLongOrNull(),
            title = metadata.title?.toString() ?: item.mediaMetadata.title?.toString() ?: "",
            artist = metadata.artist?.toString(),
            album = metadata.albumTitle?.toString(),
            albumArtist = metadata.albumArtist?.toString(),
            albumKey = extras?.getString(ALBUM_KEY),
            artwork = metadata.artworkUri ?: item.mediaMetadata.artworkUri,
            source = extras?.getString(SOURCE),
            isPlaying = player.isPlaying,
            isBuffering = player.playbackState == Player.STATE_BUFFERING,
            hasNext = player.hasNextMediaItem(),
            repeatMode = player.repeatMode,
            durationMs = duration,
            error = player.playerError?.let { error ->
                when (error.errorCode) {
                    PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED, PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED ->
                        "This device cannot play ${extension(item)?.let { "$it files" } ?: "this file"}"
                    PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND -> "The file is no longer in the music folder. Sync to bring it back."
                    PlaybackException.ERROR_CODE_IO_NO_PERMISSION -> "Groovelight cannot read the music folder. Choose it again in Sync."
                    else -> "Cannot play this song (${error.errorCodeName})"
                }
            },
        )
    }

    private fun updateQueue(player: Player) {
        val current = player.currentMediaItemIndex
        queue.value = (current + 1 until player.mediaItemCount).map { index ->
            val item = player.getMediaItemAt(index)
            // Keys stay unique when a song is in the queue twice.
            QueueEntry(index, "$index:${item.mediaId}", item.mediaMetadata.title?.toString() ?: "", item.mediaMetadata.artist?.toString(),
                item.mediaMetadata.artworkUri, item.mediaId.toLongOrNull())
        }
    }

    private fun extension(item: MediaItem): String? =
        item.localConfiguration?.uri?.lastPathSegment?.substringAfterLast('.', "")?.takeIf { it.isNotEmpty() && it.length <= 5 }?.uppercase()

    /** Where the song is and how long it is, while collected (four times a second, for the seek bar). */
    val progress: Flow<Progress> = flow {
        while (true) {
            emit(controller?.let { player ->
                val duration = player.duration.takeIf { it != C.TIME_UNSET } ?: player.currentMediaItem?.mediaMetadata?.durationMs ?: 0
                Progress(player.currentPosition.coerceAtLeast(0), duration.coerceAtLeast(0))
            } ?: Progress(0, 0))
            delay(250)
        }
    }

    /**
     * Plays `items` from `start`, replacing the queue. `shuffle` true plays them shuffled (from a random song), false in
     * order, and null keeps the current mode (shuffled from `start` when shuffle is on, as tapping a song does).
     */
    fun play(items: List<MediaItem>, start: Int, shuffle: Boolean? = null) {
        val player = controller ?: return
        if (items.isEmpty()) return
        val shuffled = shuffle ?: shuffling.value
        val ordered = items.mapIndexed { index, item -> withOrder(item, index.toDouble()) }
        val queue = when {
            !shuffled -> ordered
            shuffle == true -> ordered.shuffled()
            else -> listOf(ordered[start]) + (ordered.take(start) + ordered.drop(start + 1)).shuffled()
        }
        setShuffling(shuffled)
        player.shuffleModeEnabled = false
        player.setMediaItems(queue, if (shuffled) 0 else start, 0)
        player.prepare()
        player.play()
    }

    /** Plays the songs right after the current one (the last one asked plays first, as on the Mac). */
    fun playNext(items: List<MediaItem>) {
        val player = controller ?: return
        if (player.mediaItemCount == 0) return play(items, 0, shuffle = false)
        val current = player.currentMediaItemIndex
        val currentOrder = order(player, current)
        val following = (0 until player.mediaItemCount).map { order(player, it) }.filter { it > currentOrder }.minOrNull() ?: (currentOrder + 1)
        val step = (following - currentOrder) / (items.size + 1)
        player.addMediaItems(current + 1, items.mapIndexed { index, item -> withOrder(item, currentOrder + step * (index + 1)) })
    }

    /** Adds the songs at the end of the queue. */
    fun addToQueue(items: List<MediaItem>) {
        val player = controller ?: return
        if (player.mediaItemCount == 0) return play(items, 0, shuffle = false)
        val last = (0 until player.mediaItemCount).maxOf { order(player, it) }
        player.addMediaItems(items.mapIndexed { index, item -> withOrder(item, last + index + 1) })
    }

    fun toggleShuffle() {
        val player = controller ?: return setShuffling(!shuffling.value)
        val count = player.mediaItemCount
        val current = player.currentMediaItemIndex
        if (count == 0) return setShuffling(!shuffling.value)
        val items = (0 until count).map { player.getMediaItemAt(it) }
        if (!shuffling.value) {
            // The current song first, then all the others shuffled.
            player.replaceMediaItems(current + 1, count, items.filterIndexed { index, _ -> index != current }.shuffled())
            player.removeMediaItems(0, current)
        } else {
            // Back to the original order around the current song.
            val sorted = items.indices.sortedBy { order(items[it], it) }
            val at = sorted.indexOf(current)
            player.replaceMediaItems(current + 1, count, sorted.drop(at + 1).map { items[it] })
            player.replaceMediaItems(0, current, sorted.take(at).map { items[it] })
        }
        setShuffling(!shuffling.value)
    }

    /** Off, then the whole queue, then the current song. */
    fun cycleRepeat() {
        val player = controller ?: return
        player.repeatMode = when (player.repeatMode) {
            Player.REPEAT_MODE_OFF -> Player.REPEAT_MODE_ALL
            Player.REPEAT_MODE_ALL -> Player.REPEAT_MODE_ONE
            else -> Player.REPEAT_MODE_OFF
        }
    }

    fun skipTo(index: Int) {
        controller?.run {
            seekTo(index, 0)
            if (playbackState == Player.STATE_IDLE) prepare()
            play()
        }
    }

    fun removeFromQueue(index: Int) { controller?.removeMediaItem(index) }

    /** Moves a song of Up Next; in order (not shuffled) it keeps its new place when shuffle is turned on and off. */
    fun moveInQueue(from: Int, to: Int) {
        val player = controller ?: return
        if (from == to) return
        player.moveMediaItem(from, to)
        if (shuffling.value) return
        val before = if (to > 0) order(player, to - 1) else null
        val after = if (to < player.mediaItemCount - 1) order(player, to + 1) else null
        val order = when {
            before != null && after != null -> (before + after) / 2
            before != null -> before + 1
            after != null -> after - 1
            else -> 0.0
        }
        player.replaceMediaItem(to, withOrder(player.getMediaItemAt(to), order))
    }

    fun clearUpNext() {
        controller?.run { if (currentMediaItemIndex + 1 < mediaItemCount) removeMediaItems(currentMediaItemIndex + 1, mediaItemCount) }
    }

    /**
     * Puts the mini player away: playback stops (its notification goes) and the queue stays, so Play on a headset or
     * playing anything brings it back. [reopen] undoes it.
     */
    fun closePlayer() {
        controller?.run {
            pause()
            stop()
        }
        hidden.value = true
    }

    fun reopen() { hidden.value = false }

    /** Empties the queue: nothing is left to play, and the mini player goes. */
    fun clearQueue() {
        controller?.run {
            stop()
            clearMediaItems()
        }
    }

    fun setHideAfter(minutes: Int) {
        hideMinutes.value = minutes
        prefs.edit { putInt("hideAfterMinutes", minutes) }
        wasPlaying = null
        controller?.let { followPauses(it.isPlaying) }
    }

    /**
     * Playing shows the mini player; pausing starts the wait before it hides. The time it paused is kept, so after the
     * app was away (or ended) for longer, it opens with the mini player put away.
     */
    private fun followPauses(playing: Boolean) {
        if (playing == wasPlaying) return
        val first = wasPlaying == null
        wasPlaying = playing
        hiding?.cancel()
        if (playing) {
            hidden.value = false
            prefs.edit { remove("pausedAt") }
            return
        }
        val now = System.currentTimeMillis()
        val pausedAt = if (first) prefs.getLong("pausedAt", now) else now
        prefs.edit { putLong("pausedAt", pausedAt) }
        val minutes = hideMinutes.value
        if (minutes <= 0) return
        val left = pausedAt + minutes * 60_000L - now
        if (left <= 0) hidden.value = true
        else hiding = viewModelScope.launch {
            delay(left)
            hidden.value = true
        }
    }

    fun seekTo(milliseconds: Long) { controller?.seekTo(milliseconds) }

    fun togglePlayPause() {
        controller?.run {
            if (isPlaying) pause() else {
                // After an error, or restored after a restart, the player is idle: prepare to play.
                if (playbackState == Player.STATE_IDLE) prepare()
                if (playbackState == Player.STATE_ENDED) seekTo(currentMediaItemIndex, 0)
                play()
            }
        }
    }

    fun next() { controller?.seekToNext() }

    fun setSpeed(speed: Float) { controller?.setPlaybackSpeed(speed) }

    /** Pauses after `minutes`, or at the end of the song playing (null); 0 cancels. */
    fun sleepIn(minutes: Int?) {
        when (minutes) {
            null -> SleepTimer.endOfSong()
            0 -> SleepTimer.cancel()
            else -> SleepTimer.start(minutes)
        }
    }

    /** The previous song, or the start of this one after its first seconds. */
    fun previous() { controller?.seekToPrevious() }

    private fun setShuffling(on: Boolean) {
        shuffling.value = on
        prefs.edit { putBoolean("shuffle", on) }
    }

    private fun order(player: Player, index: Int): Double = order(player.getMediaItemAt(index), index)

    private fun order(item: MediaItem, index: Int): Double =
        item.mediaMetadata.extras?.takeIf { it.containsKey(ORDER) }?.getDouble(ORDER) ?: index.toDouble()

    private fun withOrder(item: MediaItem, order: Double): MediaItem {
        val extras = Bundle(item.mediaMetadata.extras ?: Bundle()).apply { putDouble(ORDER, order) }
        return item.buildUpon().setMediaMetadata(item.mediaMetadata.buildUpon().setExtras(extras).build()).build()
    }

    override fun onCleared() {
        controller?.removeListener(listener)
        MediaController.releaseFuture(connecting)
    }

    companion object {
        /** Extras of an item's metadata: its album, where the queue came from, and its place in the original order. */
        const val ALBUM_KEY = "dev.irwingbraga.groovelight.album"
        const val SOURCE = "dev.irwingbraga.groovelight.source"
        const val ORDER = "dev.irwingbraga.groovelight.order"
    }
}
