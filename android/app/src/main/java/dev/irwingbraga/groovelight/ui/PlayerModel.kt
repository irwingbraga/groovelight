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
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.ExperimentalCoroutinesApi
import android.net.Uri as AndroidUri
import dev.irwingbraga.groovelight.app.playerItems
import dev.irwingbraga.groovelight.library.ArtworkStore
import dev.irwingbraga.groovelight.sync.Transfers
import dev.irwingbraga.groovelight.library.LibraryDatabase
import dev.irwingbraga.groovelight.sync.RemoteCommand
import dev.irwingbraga.groovelight.sync.RemoteDevice
import org.json.JSONObject
import dev.irwingbraga.groovelight.sync.RemoteState

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
        /** Where the music plays when not here (the Mac's or a phone's name, chosen in Play On), null when here. */
        val playingOn: String? = null,
    )

    /** Where music plays: this device, the paired Mac, or another device through the Mac (their player, controlled from here). */
    sealed interface Target {
        data object ThisDevice : Target
        data object Mac : Target
        data class Device(val device: RemoteDevice) : Target

        /** The Mac's id (null) or the device's, as [MacRemote] takes it. */
        val deviceId: String? get() = (this as? Device)?.device?.id

        companion object {
            val THIS_DEVICE: Target = ThisDevice
            val MAC: Target = Mac
        }
    }

    /** A song of Up Next: `index` is its place in the player's queue. */
    data class QueueEntry(val index: Int, val key: String, val title: String, val artist: String?, val artwork: Uri?, val id: Long?)

    data class Progress(val positionMs: Long, val durationMs: Long)

    private val prefs = application.getSharedPreferences("player", Context.MODE_PRIVATE)
    private val state = MutableStateFlow<NowPlaying?>(null)
    private val queue = MutableStateFlow<List<QueueEntry>>(emptyList())
    private val shuffling = MutableStateFlow(prefs.getBoolean("shuffle", false))

    /** The paired Mac as a place to play (Play On). */
    val remote = MacRemote(application, viewModelScope)
    private val targets = MutableStateFlow(Target.THIS_DEVICE)
    val target: StateFlow<Target> = targets.asStateFlow()
    /** Music plays elsewhere, controlled from here. */
    private val isRemote: Boolean get() = targets.value != Target.THIS_DEVICE

    /** Where music plays, by name. */
    fun targetName(target: Target = targets.value): String = when (target) {
        Target.ThisDevice -> "This device"
        Target.Mac -> remote.macName
        is Target.Device -> target.device.name
    }

    /** Covers of the Mac's library fetched for songs playing elsewhere: the song is shown again with its cover. */
    private val coversFetched = MutableStateFlow(0)
    private val coversAsked = mutableSetOf<String>()

    /** The song playing where music plays. */
    val nowPlaying: StateFlow<NowPlaying?> = combine(state, targets, remote.state, coversFetched) { local, target, received, _ ->
        if (target == Target.THIS_DEVICE) local else received?.state?.let(::remoteNowPlaying)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, null)
    /** What plays next where music plays (there, the songs this device knows: they are shown, not edited). */
    val upNext: StateFlow<List<QueueEntry>> = combine(queue, targets, remoteUpNext()) { entries, target, there ->
        if (target == Target.THIS_DEVICE) entries else there
    }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    /** The queue after the song playing elsewhere, with titles and covers from this device's library. */
    @OptIn(ExperimentalCoroutinesApi::class)
    private fun remoteUpNext(): Flow<List<QueueEntry>> = remote.state
        .map { received -> received?.state?.let { it.queue.drop((it.queueIndex ?: return@let emptyList()) + 1) } ?: emptyList() }
        .distinctUntilChanged()
        .mapLatest { ids ->
            if (ids.isEmpty()) return@mapLatest emptyList()
            val tracks = LibraryDatabase.get(getApplication()).library().tracksWithIds(ids).associateBy { it.id }
            val artwork = ArtworkStore(getApplication())
            ids.mapIndexedNotNull { offset, id ->
                tracks[id]?.let { track ->
                    QueueEntry(offset, "$offset:$id", track.title, track.artist,
                        track.artworkHash?.let(artwork::file)?.takeIf { it.exists() }?.let(AndroidUri::fromFile), id)
                }
            }
        }
    val shuffle: StateFlow<Boolean> = combine(shuffling, targets, remote.state) { local, target, received ->
        if (target == Target.THIS_DEVICE) local else received?.state?.shuffle == true
    }.stateIn(viewModelScope, SharingStarted.Eagerly, shuffling.value)
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
    /** Other devices playing music here, through the Mac. */
    val relay = RelayReceiver(application, viewModelScope, remote, ::applyRelayed, ::localState)

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
                relay.start()
            }
        }, ContextCompat.getMainExecutor(application))
        // Music playing elsewhere: the mini player follows that player's pauses, not this device's (paused meanwhile).
        viewModelScope.launch {
            combine(targets, remote.state) { target, received -> if (target == Target.THIS_DEVICE) null else received?.state?.playing }
                .collect { playing -> if (playing != null) followPauses(playing) }
        }
    }

    private fun update(player: Player) {
        val item = player.currentMediaItem
        if (item == null) {
            state.value = null
            return
        }
        if (!isRemote) followPauses(player.isPlaying)
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
            if (isRemote) {
                emit(Progress(remote.positionMs(), ((remote.state.value?.state?.item?.durationSeconds ?: 0.0) * 1000).toLong()))
                delay(250)
                continue
            }
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
        if (items.isEmpty()) return
        if (isRemote) {
            val ids = items.map { it.mediaId.toLongOrNull() }
            val known = ids.filterNotNull()
            val first = ids.take(start.coerceIn(0, ids.size)).count { it != null }
            remote.send(RemoteCommand.play(known, first.coerceAtMost(known.lastIndex.coerceAtLeast(0)), 0.0, shuffle == true))
            return
        }
        val player = controller ?: return
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

    /** Whether the Mac plays: it has every song of its library, here or not. */
    val playsOnMac: Boolean get() = targets.value == Target.MAC

    /** Songs of the Mac's library, by its ids, on the Mac (which has them all, here or not); only when it plays. */
    fun playOnMac(ids: List<Long>, start: Int = 0, shuffle: Boolean = false) {
        if (!playsOnMac || ids.isEmpty()) return
        remote.send(RemoteCommand.play(ids, start.coerceIn(0, ids.lastIndex), 0.0, shuffle))
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
        if (isRemote) return remote.send(RemoteCommand.shuffle(remote.state.value?.state?.shuffle != true))
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
        if (isRemote) {
            val next = when (remote.state.value?.state?.repeatMode) { "off", null -> "all"; "all" -> "one"; else -> "off" }
            return remote.send(RemoteCommand.repeatMode(next))
        }
        val player = controller ?: return
        player.repeatMode = when (player.repeatMode) {
            Player.REPEAT_MODE_OFF -> Player.REPEAT_MODE_ALL
            Player.REPEAT_MODE_ALL -> Player.REPEAT_MODE_ONE
            else -> Player.REPEAT_MODE_OFF
        }
    }

    fun skipTo(index: Int) {
        if (isRemote) return
        controller?.run {
            seekTo(index, 0)
            if (playbackState == Player.STATE_IDLE) prepare()
            play()
        }
    }

    fun removeFromQueue(index: Int) { if (!isRemote) controller?.removeMediaItem(index) }

    /** Moves a song of Up Next; in order (not shuffled) it keeps its new place when shuffle is turned on and off. */
    fun moveInQueue(from: Int, to: Int) {
        if (isRemote) return
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
        if (isRemote) return
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
        if (isRemote) remote.state.value?.state?.let { followPauses(it.playing) } else controller?.let { followPauses(it.isPlaying) }
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

    /** The Mac's volume (0 to 1), while music plays there; a phone's own buttons set its level. */
    fun setRemoteVolume(volume: Float) {
        if (targets.value == Target.MAC) remote.send(RemoteCommand.volume(volume.toDouble().coerceIn(0.0, 1.0)))
    }

    fun seekTo(milliseconds: Long) {
        if (isRemote) remote.send(RemoteCommand.seek(milliseconds / 1000.0)) else controller?.seekTo(milliseconds)
    }

    fun togglePlayPause() {
        if (isRemote) {
            return remote.send(if (remote.state.value?.state?.playing == true) RemoteCommand.pause() else RemoteCommand.resume())
        }
        controller?.run {
            if (isPlaying) pause() else {
                // After an error, or restored after a restart, the player is idle: prepare to play.
                if (playbackState == Player.STATE_IDLE) prepare()
                if (playbackState == Player.STATE_ENDED) seekTo(currentMediaItemIndex, 0)
                play()
            }
        }
    }

    fun next() { if (isRemote) remote.send(RemoteCommand.next()) else controller?.seekToNext() }

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
    fun previous() { if (isRemote) remote.send(RemoteCommand.previous()) else controller?.seekToPrevious() }

    /**
     * Moves playback: what plays where music plays now goes on on the chosen one at the same place, and stops where it
     * was. A queue coming here keeps the songs on this device, from where it was.
     */
    fun choose(target: Target, done: () -> Unit = {}) {
        if (target == targets.value) return done()
        val from = targets.value
        viewModelScope.launch {
            if (target == Target.THIS_DEVICE) {
                val there = remote.state.value?.state
                val item = there?.item
                // Songs this device does not have as the Mac does (not synced since the Mac's library changed): the
                // music stays where it is.
                if (there != null && item != null && !takeOver(there, item, remote.positionMs())) return@launch done()
                remote.stopFollowing()
                targets.value = Target.THIS_DEVICE
                return@launch done()
            }
            if (from == Target.THIS_DEVICE) {
                val player = controller
                remote.use(target.deviceId)
                if (player != null && player.isPlaying && player.mediaItemCount > 0) {
                    val ids = (0 until player.mediaItemCount).mapNotNull { player.getMediaItemAt(it).mediaId.toLongOrNull() }
                    val index = (0 until player.currentMediaItemIndex).count { player.getMediaItemAt(it).mediaId.toLongOrNull() != null }
                    val position = player.currentPosition / 1000.0
                    // Quiet here first: both playing the same song a moment apart sounds broken.
                    player.pause()
                    val handed = runCatching { remote.sendAndWait(RemoteCommand.play(ids, index, position)) }
                    if (handed.isFailure) {
                        player.play()
                        remote.use(from.deviceId)
                        return@launch done()
                    }
                }
            } else {
                // From one place to another: the queue goes on there, then stops where it was.
                val there = remote.state.value?.state
                val position = remote.positionMs() / 1000.0
                remote.use(target.deviceId)
                val index = there?.queueIndex
                if (there != null && there.playing && index != null) {
                    val handed = runCatching { remote.sendAndWait(RemoteCommand.play(there.queue, index, position)) }
                    if (handed.isFailure) {
                        remote.use(from.deviceId)
                        remote.follow()
                        return@launch done()
                    }
                    remote.send(RemoteCommand.pause(), to = from.deviceId)
                }
            }
            targets.value = target
            remote.follow()
            done()
        }
    }

    /**
     * A command from another device (through the Mac) for the player here. A queue it sends plays here, even while this
     * device was playing elsewhere; songs not on this device are left out.
     */
    private fun applyRelayed(command: JSONObject) {
        val player = controller ?: return
        when (command.optString("command")) {
            "play" -> viewModelScope.launch {
                val songs = command.optJSONArray("songIds") ?: return@launch
                val ids = (0 until songs.length()).map { songs.getLong(it) }
                val startAt = command.optInt("startAt", 0)
                val dao = LibraryDatabase.get(getApplication()).library()
                val tracks = dao.tracksWithIds(ids).associateBy { it.id }
                val ordered = ids.mapNotNull { tracks[it] }
                if (ordered.isEmpty()) return@launch
                // The song asked for, or the next one here; its position only when it is that song.
                val wanted = ids.getOrNull(startAt)?.let { tracks[it] }
                val first = ids.drop(startAt).firstNotNullOfOrNull { tracks[it] }
                val start = first?.let { song -> ordered.indexOfFirst { it.id == song.id } }?.coerceAtLeast(0) ?: 0
                val albums = dao.albumsWithKeys(ordered.map { it.albumKey }.distinct()).associateBy { it.key }
                val items = playerItems(getApplication(), ordered, albums).mapIndexed { index, item -> withOrder(item, index.toDouble()) }
                if (isRemote) {
                    remote.stopFollowing()
                    targets.value = Target.THIS_DEVICE
                }
                val positionMs = if (wanted != null) (command.optDouble("position", 0.0) * 1000).toLong() else 0L
                setShuffling(false)
                player.shuffleModeEnabled = false
                player.setMediaItems(items, start.coerceAtMost(items.lastIndex), positionMs)
                player.prepare()
                player.play()
            }
            "pause" -> player.pause()
            "resume" -> {
                if (player.playbackState == Player.STATE_IDLE) player.prepare()
                player.play()
            }
            "next" -> player.seekToNext()
            "previous" -> player.seekToPrevious()
            "seek" -> player.seekTo((command.optDouble("position", 0.0) * 1000).toLong())
            "shuffle" -> if (command.optBoolean("on") != shuffling.value && !isRemote) toggleShuffle()
            "repeatMode" -> player.repeatMode = when (command.optString("mode")) {
                "all" -> Player.REPEAT_MODE_ALL
                "one" -> Player.REPEAT_MODE_ONE
                else -> Player.REPEAT_MODE_OFF
            }
            "stop" -> player.stop()
            // The device's own volume buttons set the level here.
            else -> Unit
        }
    }

    /** What plays here, as other devices following this one see it. */
    private fun localState(): RemoteState? {
        val player = controller ?: return null
        val count = player.mediaItemCount
        val ids = (0 until count).map { player.getMediaItemAt(it).mediaId.toLongOrNull() }
        val current = player.currentMediaItem
        val item = current?.mediaId?.toLongOrNull()?.let { id ->
            val metadata = current.mediaMetadata
            val duration = player.duration.takeIf { it != C.TIME_UNSET } ?: metadata.durationMs ?: 0
            RemoteState.Item(
                id = id, title = metadata.title?.toString() ?: "", artist = metadata.artist?.toString() ?: "",
                album = metadata.albumTitle?.toString() ?: "", albumKey = metadata.extras?.getString(ALBUM_KEY),
                artworkHash = metadata.artworkUri?.lastPathSegment?.removeSuffix(".jpg"), durationSeconds = duration / 1000.0,
            )
        }
        val index = if (count > 0) (0 until player.currentMediaItemIndex).count { ids[it] != null } else null
        return RemoteState(
            item = item, playing = player.isPlaying, positionSeconds = player.currentPosition.coerceAtLeast(0) / 1000.0,
            rate = player.playbackParameters.speed.toDouble(), volume = 1.0, shuffle = shuffling.value,
            repeatMode = when (player.repeatMode) { Player.REPEAT_MODE_ALL -> "all"; Player.REPEAT_MODE_ONE -> "one"; else -> "off" },
            queue = ids.filterNotNull(), queueIndex = index?.takeIf { item != null }, version = "",
        )
    }

    /**
     * Plays the Mac's queue here from where it was (the songs this device has), as it was playing or paused. False when
     * the song playing there is not here as the Mac knows it (another song has its id: not synced since the Mac's
     * library changed), so nothing else is played by mistake.
     */
    private suspend fun takeOver(mac: RemoteState, item: RemoteState.Item, positionMs: Long): Boolean {
        val player = controller ?: return false
        val dao = LibraryDatabase.get(getApplication()).library()
        val tracks = dao.tracksWithIds(mac.queue).associateBy { it.id }
        if (tracks[item.id]?.title != item.title) return false
        val ordered = mac.queue.mapNotNull { tracks[it] }
        val start = ordered.indexOfFirst { it.id == item.id }
        if (start < 0) return false
        val albums = dao.albumsWithKeys(ordered.map { it.albumKey }.distinct()).associateBy { it.key }
        val items = playerItems(getApplication(), ordered, albums).mapIndexed { index, mediaItem -> withOrder(mediaItem, index.toDouble()) }
        if (items.size != ordered.size) return false
        if (mac.playing) remote.send(RemoteCommand.pause())
        setShuffling(false)
        player.setMediaItems(items, start, positionMs)
        player.prepare()
        if (mac.playing) player.play()
        return true
    }

    /** The Mac's song as Now Playing shows it (its cover when the Mac sent it to this device). */
    private fun remoteNowPlaying(mac: RemoteState): NowPlaying? {
        val item = mac.item ?: return null
        val cover = item.artworkHash?.let(::remoteCover)?.let(AndroidUri::fromFile)
        return NowPlaying(
            id = item.id, title = item.title, artist = item.artist, album = item.album, albumArtist = null, albumKey = item.albumKey,
            artwork = cover, source = null, isPlaying = mac.playing, isBuffering = false,
            hasNext = (mac.queueIndex ?: 0) + 1 < mac.queue.size || mac.repeatMode != "off",
            repeatMode = when (mac.repeatMode) { "all" -> Player.REPEAT_MODE_ALL; "one" -> Player.REPEAT_MODE_ONE; else -> Player.REPEAT_MODE_OFF },
            durationMs = (item.durationSeconds * 1000).toLong(), error = null, playingOn = targetName(),
        )
    }

    /** Lyrics of the Mac's songs not on this device, fetched for Now Playing while they play elsewhere (by song id). */
    val macLyrics = MutableStateFlow<Map<Long, String>>(emptyMap())
    private val lyricsAsked = mutableSetOf<Long>()

    /** Fetches a song's lyrics from the Mac once (the Mac looks them up online first when it has none); they land in `macLyrics`. */
    fun fetchLyrics(id: Long) {
        if (!lyricsAsked.add(id)) return
        viewModelScope.launch {
            val text = Transfers.fetchLyrics(getApplication(), id)
            if (text != null) macLyrics.value = macLyrics.value + (id to text) else lyricsAsked.remove(id)
        }
    }

    /**
     * The cover of a song playing elsewhere: this device's (its album is here), else the Mac's library's as the Library
     * shows it, fetched from the Mac the first time.
     */
    private fun remoteCover(hash: String): java.io.File? {
        ArtworkStore(getApplication()).file(hash).takeIf { it.exists() }?.let { return it }
        Transfers.covers(getApplication()).file(hash).takeIf { it.length() > 0 }?.let { return it }
        if (coversAsked.add(hash)) viewModelScope.launch {
            if (Transfers.fetchCover(getApplication(), hash)) coversFetched.value++
        }
        return null
    }

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
        relay.stop()
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
