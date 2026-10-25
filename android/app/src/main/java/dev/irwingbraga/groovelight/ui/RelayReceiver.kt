package dev.irwingbraga.groovelight.ui

import android.content.Context
import android.util.Log
import androidx.core.content.edit
import dev.irwingbraga.groovelight.sync.MacClient
import dev.irwingbraga.groovelight.sync.RemoteState
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
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * This device as a place other devices play music on, through the Mac: while the app runs, it waits there for their
 * commands, plays what they send with its own player, and tells the Mac what it plays after each change, so they follow
 * it. Off with "Let other devices play here" in Sync. The same routes as Groovelight for iOS.
 *
 * `apply` runs a command on the main thread; `state` describes the player there (null when it has nothing).
 */
class RelayReceiver(
    context: Context,
    private val scope: CoroutineScope,
    private val remote: MacRemote,
    private val apply: (JSONObject) -> Unit,
    private val state: () -> RemoteState?,
) {
    private val prefs = context.getSharedPreferences("player", Context.MODE_PRIVATE)
    private val enabledFlow = MutableStateFlow(prefs.getBoolean("relay.enabled", true))
    val enabled: StateFlow<Boolean> = enabledFlow.asStateFlow()
    private var job: Job? = null
    private var applied = 0
    private var sent: String? = null

    fun setEnabled(on: Boolean) {
        enabledFlow.value = on
        prefs.edit { putBoolean("relay.enabled", on) }
        if (on) start() else stop()
    }

    /** Starts waiting for commands (when paired and turned on). */
    fun start() {
        if (job?.isActive == true || !enabledFlow.value || !remote.isPaired) return
        job = scope.launch { run() }
    }

    fun stop() {
        job?.cancel()
        job = null
    }

    private suspend fun run() {
        var failures = 0
        while (scope.isActive) {
            try {
                val client = remote.connected()
                // Commands sent before this device was there are not for it.
                var last = io { client.relayCommands(null).getInt("last") }
                applied = last
                sent = null
                report(client, force = true)
                failures = 0
                // Reports the player as it changes here, while waiting for commands.
                val reporter = scope.launch {
                    while (isActive) {
                        delay(1000)
                        runCatching { report(client, force = false) }
                    }
                }
                try {
                    while (scope.isActive) {
                        val commands = io { client.relayCommands(last) }.optJSONArray("commands") ?: continue
                        if (commands.length() == 0) continue
                        for (index in 0 until commands.length()) {
                            val relayed = commands.getJSONObject(index)
                            val command = relayed.getJSONObject("command")
                            Log.i(TAG, "${relayed.optString("fromName")}: ${command.optString("command")}")
                            withContext(Dispatchers.Main) { apply(command) }
                            last = relayed.getInt("seq")
                        }
                        applied = last
                        // The player needs a moment to start a song before what it plays can be told.
                        delay(300)
                        report(client, force = true)
                    }
                } finally {
                    reporter.cancel()
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                failures++
                if (failures == 1) Log.w(TAG, "Waiting for other devices failed", error)
                // The Mac is away: try again now and then, less often the longer it stays away.
                delay(5000L * minOf(failures, 12))
            }
        }
    }

    /** Tells the Mac what plays here, when it changed (a seek counts; steady playing does not) or when `force`d. */
    private suspend fun report(client: MacClient, force: Boolean) {
        val now = withContext(Dispatchers.Main) { state() }
        val signature = now?.let(::signature) ?: "-"
        if (!force && signature == sent) return
        sent = signature
        io { client.relayState(now?.toJson(), applied) }
    }

    /** What changes when anything but the steady progress of the song does: the moment the song started, while playing. */
    private fun signature(state: RemoteState): String {
        val anchor = if (state.playing) System.currentTimeMillis() / 1000.0 - state.positionSeconds / maxOf(state.rate, 0.01)
        else state.positionSeconds
        return listOf(state.item?.id, state.playing, Math.round(anchor), state.shuffle, state.repeatMode, state.queue.hashCode(),
            state.queueIndex).joinToString("|")
    }

    private suspend fun <T> io(block: suspend () -> T): T = withContext(Dispatchers.IO) { block() }

    private companion object {
        const val TAG = "RelayReceiver"
    }
}
