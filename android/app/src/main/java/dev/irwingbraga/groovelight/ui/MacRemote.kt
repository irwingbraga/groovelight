package dev.irwingbraga.groovelight.ui

import android.content.Context
import android.util.Log
import dev.irwingbraga.groovelight.sync.MacClient
import dev.irwingbraga.groovelight.sync.MacError
import dev.irwingbraga.groovelight.sync.Prefs
import dev.irwingbraga.groovelight.sync.RemoteDevice
import dev.irwingbraga.groovelight.sync.RemoteState
import dev.irwingbraga.groovelight.sync.SyncEngine
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * The paired Mac, and the other devices reached through it, as places to play music: whether the Mac lets this device
 * control playback, the devices there now, what the chosen one plays (followed as it changes, by waiting on its state),
 * and the commands sent to it. The same routes as Groovelight for iOS.
 */
class MacRemote(private val context: Context, private val scope: CoroutineScope) {
    sealed interface Availability {
        data object Unknown : Availability
        data object Checking : Availability
        data object Available : Availability
        /** The Mac's page for this device has not turned it on. */
        data object NotAllowed : Availability
        data class Unreachable(val message: String) : Availability
    }

    /** The Mac's state, and when it arrived (this device's clock). */
    data class Received(val state: RemoteState, val atMs: Long)

    private val prefs = Prefs(context)
    private val available = MutableStateFlow<Availability>(Availability.Unknown)
    val availability: StateFlow<Availability> = available.asStateFlow()
    private val received = MutableStateFlow<Received?>(null)
    val state: StateFlow<Received?> = received.asStateFlow()
    private var client: MacClient? = null
    private val connecting = Mutex()
    private var follower: Job? = null
    private val others = MutableStateFlow<List<RemoteDevice>>(emptyList())
    /** The other devices music can play on now (phones with Groovelight open), as of the last check. */
    val devices: StateFlow<List<RemoteDevice>> = others.asStateFlow()
    private val skippedCount = MutableStateFlow(0)
    /** Songs of the last queue sent there that it does not have (left out), to say so. */
    val skipped: StateFlow<Int> = skippedCount.asStateFlow()

    /** The device followed and sent commands: null for the Mac. */
    var device: String? = null
        private set

    val macName: String get() = prefs.macName ?: "Mac"
    val isPaired: Boolean get() = prefs.key != null && prefs.macId != null

    /** Asks the Mac whether this device may play music there (when the list of devices opens). */
    suspend fun check() {
        if (!isPaired) return
        if (available.value != Availability.Available) available.value = Availability.Checking
        runCatching {
            io {
                val client = connected()
                if (device == null) apply(client.remoteState())
                others.value = runCatching { client.remoteDevices() }.getOrDefault(emptyList())
            }
        }
            .onSuccess { available.value = Availability.Available }
            .onFailure { others.value = emptyList(); failed(it) }
    }

    /** Follows (and sends commands to) the Mac (null), or another device; what was known of the last one is dropped. */
    fun use(device: String?) {
        if (device == this.device) return
        stopFollowing()
        this.device = device
        received.value = null
        skippedCount.value = 0
    }

    /** Follows the Mac's player until [stopFollowing]. */
    fun follow() {
        if (follower?.isActive == true) return
        follower = scope.launch {
            var failures = 0
            while (isActive) {
                try {
                    val next = io { connected().remoteState(after = received.value?.state?.version, device = device) }
                    apply(next)
                    available.value = Availability.Available
                    failures = 0
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    failures++
                    client = null
                    Log.w(TAG, "Following the Mac failed", error)
                    if (failures >= 3) failed(error)
                    delay(1000L * minOf(failures, 5))
                }
            }
        }
    }

    fun stopFollowing() {
        follower?.cancel()
        follower = null
    }

    /** Sends a command; the Mac answers with its state after it, shown at once. */
    fun send(command: JSONObject) = send(command, device)

    /** Sends a command to the Mac (null) or a device; its answer is shown only when that is the one followed. */
    fun send(command: JSONObject, to: String?) {
        scope.launch {
            runCatching { io { connected().remote(command, to) } }
                .onSuccess { if (to == device) { apply(it); countSkipped(command, it) } }
                .onFailure { Log.w(TAG, "Command failed", it); failed(it) }
        }
    }

    suspend fun sendAndWait(command: JSONObject) {
        val answer = io { connected().remote(command, device) }
        apply(answer)
        countSkipped(command, answer)
    }

    /** A queue sent: the songs not in the queue there are ones it does not have. */
    private fun countSkipped(command: JSONObject, answer: JSONObject) {
        if (command.optString("command") != "play") return
        val sent = command.optJSONArray("songIds")?.length() ?: return
        skippedCount.value = maxOf(sent - (answer.optJSONArray("queue")?.length() ?: 0), 0)
    }

    /** Where the Mac's song is now, in milliseconds, moved on from the last state. */
    fun positionMs(now: Long = System.currentTimeMillis()): Long {
        val (state, at) = received.value ?: return 0
        val seconds = if (state.playing) state.positionSeconds + (now - at) / 1000.0 * state.rate else state.positionSeconds
        val duration = state.item?.durationSeconds ?: seconds
        return (minOf(seconds, duration) * 1000).toLong().coerceAtLeast(0)
    }

    private fun apply(json: JSONObject) {
        received.value = Received(RemoteState.from(json), System.currentTimeMillis())
    }

    private fun failed(error: Throwable) {
        // A device that has gone: the Mac itself is fine.
        if (error is MacError && error.status == 404) return
        client = null
        available.value = if (error is MacError && error.status == 403) Availability.NotAllowed
        else Availability.Unreachable(error.message ?: "Not reachable")
    }

    /** The connection to the Mac (for waiting on commands from other devices too). */
    suspend fun connected(): MacClient = connecting.withLock {
        client ?: io { SyncEngine(context, prefs).connect() }.also { client = it }
    }

    private suspend fun <T> io(block: suspend () -> T): T = withContext(Dispatchers.IO) { block() }

    private companion object {
        const val TAG = "MacRemote"
    }
}
