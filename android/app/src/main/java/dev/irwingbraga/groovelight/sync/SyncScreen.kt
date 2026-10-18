package dev.irwingbraga.groovelight.sync

import android.app.Application
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.work.WorkInfo
import androidx.work.WorkManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.util.Date

/** A pairing in progress: the code to compare with the Mac's. */
data class PairingState(val mac: FoundMac, val code: String? = null, val error: String? = null)

class SyncViewModel(application: Application) : AndroidViewModel(application) {
    val prefs = Prefs(application)
    private val work = WorkManager.getInstance(application)

    val paired = MutableStateFlow(prefs.isPaired)
    val folder = MutableStateFlow(prefs.folder)
    /** How the music is listened to (null until chosen, see [Prefs.resolvedMode]). */
    val mode = MutableStateFlow(prefs.resolvedMode)
    val autoSync = MutableStateFlow(prefs.autoSync)
    val charging = MutableStateFlow(prefs.onlyWhileCharging)
    val macs = MutableStateFlow<List<FoundMac>>(emptyList())
    val pairing = MutableStateFlow<PairingState?>(null)
    /** Whether the Mac answered lately. */
    val reachable = MutableStateFlow<Boolean?>(null)

    /** The running or last sync, from WorkManager (the button's and the automatic one). */
    val syncWork: StateFlow<WorkInfo?> = combine(work.getWorkInfosForUniqueWorkFlow(SyncWorker.NOW),
        work.getWorkInfosForUniqueWorkFlow(SyncWorker.AUTOMATIC)) { now, automatic ->
        (now + automatic).firstOrNull { it.state == WorkInfo.State.RUNNING } ?: now.firstOrNull()
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    private var discovery: Job? = null
    private var polling: Job? = null

    fun startDiscovery() {
        if (discovery != null) return
        discovery = viewModelScope.launch { Discovery.macs(getApplication()).collect { macs.value = it } }
    }

    fun stopDiscovery() {
        discovery?.cancel()
        discovery = null
    }

    /** While the app is open: asks the Mac every few seconds whether its Sync button was pressed. */
    fun startPolling() {
        if (polling != null) return
        polling = viewModelScope.launch(Dispatchers.IO) {
            while (true) {
                if (prefs.isPaired) {
                    val status = runCatching { SyncEngine(getApplication(), prefs).connect().status() }.getOrNull()
                    reachable.value = status != null
                    if (status?.optBoolean("syncRequested") == true && prefs.folder != null) SyncWorker.syncNow(getApplication())
                }
                delay(5_000)
            }
        }
    }

    fun stopPolling() {
        polling?.cancel()
        polling = null
    }

    fun pair(mac: FoundMac) {
        pairing.value = PairingState(mac)
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val keys = Pairing.newKeyPair()
                val devicePublic = Pairing.rawPublic(keys)
                val client = MacClient(mac.host, mac.port, prefs.deviceId, null)
                val answer = client.pair(deviceName(), "${Build.MANUFACTURER} ${Build.MODEL}", devicePublic)
                val macPublic = Pairing.fromBase64(answer.getString("publicKey"))
                val (key, code) = Pairing.derive(keys.private, macPublic, devicePublic, macPublic)
                pairing.value = PairingState(mac, code)
                // Waits for the user to compare the codes and allow this device on the Mac.
                repeat(180) {
                    when (client.pairStatus()) {
                        "accepted" -> {
                            prefs.key = Pairing.base64(key)
                            prefs.macId = answer.getString("macId")
                            prefs.macName = answer.getString("macName")
                            prefs.host = mac.host
                            prefs.port = mac.port
                            pairing.value = null
                            paired.value = true
                            SyncWorker.schedule(getApplication(), prefs)
                            return@launch
                        }
                        "rejected" -> {
                            pairing.value = PairingState(mac, error = "Not allowed on the Mac.")
                            return@launch
                        }
                    }
                    delay(1_000)
                }
                pairing.value = PairingState(mac, error = "The Mac did not answer in time.")
            } catch (error: Exception) {
                pairing.value = PairingState(mac, error = error.message ?: "Could not reach the Mac.")
            }
        }
    }

    fun cancelPairing() { pairing.value = null }

    /** The previous folder after a change, while it still holds songs Groovelight put there (offered for removal). */
    val previousFolder = MutableStateFlow<String?>(null)

    fun setFolder(uri: Uri) {
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        val app = getApplication<Application>()
        app.contentResolver.takePersistableUriPermission(uri, flags)
        val old = prefs.folder
        prefs.folder = uri.toString()
        folder.value = prefs.folder
        if (old != null && old != prefs.folder) {
            viewModelScope.launch(Dispatchers.IO) {
                val songs = runCatching {
                    val previous = DeviceFolder(app, Uri.parse(old))
                    previous.scan()
                    previous.read(SyncEngine.MANIFEST)?.let { org.json.JSONObject(it.decodeToString()).optJSONObject("entries")?.length() } ?: 0
                }.getOrDefault(0)
                if (songs > 0) previousFolder.value = old else releaseFolder(old)
            }
        }
    }

    /** Removes what Groovelight wrote in the previous folder (only its own files), then lets go of the folder. */
    fun cleanPreviousFolder(remove: Boolean) {
        val old = previousFolder.value ?: return
        previousFolder.value = null
        viewModelScope.launch(Dispatchers.IO) {
            if (remove) runCatching {
                val previous = DeviceFolder(getApplication(), Uri.parse(old))
                previous.scan()
                val entries = previous.read(SyncEngine.MANIFEST)?.let { org.json.JSONObject(it.decodeToString()).optJSONObject("entries") }
                val paths = entries?.keys()?.asSequence()?.toList() ?: emptyList()
                for (path in paths) previous.delete(path)
                previous.delete(SyncEngine.MANIFEST)
                previous.pruneEmptyFolders(paths)
                previous.scanMedia(paths)
            }
            releaseFolder(old)
        }
    }

    private fun releaseFolder(uri: String) {
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        runCatching { getApplication<Application>().contentResolver.releasePersistableUriPermission(Uri.parse(uri), flags) }
    }

    fun setAutoSync(on: Boolean) {
        prefs.autoSync = on
        autoSync.value = on
        SyncWorker.schedule(getApplication(), prefs)
    }

    fun setCharging(on: Boolean) {
        prefs.onlyWhileCharging = on
        charging.value = on
        SyncWorker.schedule(getApplication(), prefs)
    }

    fun syncNow() = SyncWorker.syncNow(getApplication())

    fun setMode(value: Prefs.Mode) {
        prefs.mode = value
        mode.value = value
    }

    fun forget() {
        prefs.forgetMac()
        paired.value = false
        reachable.value = null
        SyncWorker.schedule(getApplication(), prefs)
    }

    private fun deviceName(): String =
        android.provider.Settings.Global.getString(getApplication<Application>().contentResolver,
            android.provider.Settings.Global.DEVICE_NAME) ?: "${Build.MANUFACTURER} ${Build.MODEL}"
}

/**
 * Pairing with the Mac, the music folder and syncing. The whole app in Sync only mode; in the player, its Sync tab
 * (and the setup before the first sync). `listening` is a card for switching modes, shown once paired.
 */
@Composable
fun SyncScreen(title: String, model: SyncViewModel = viewModel(), listening: (@Composable () -> Unit)? = null) {
    val paired by model.paired.collectAsState()
    Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(title, fontSize = 28.sp, fontWeight = FontWeight.Bold)
        if (paired) PairedScreen(model, listening) else PairScreen(model)
    }
}

@Composable
private fun PairScreen(model: SyncViewModel) {
    val macs by model.macs.collectAsState()
    val pairing by model.pairing.collectAsState()
    LaunchedEffect(Unit) { model.startDiscovery() }
    var host by remember { mutableStateOf("") }
    var port by remember { mutableStateOf("52300") }

    Text("Open Groovelight on your Mac and turn on Settings, Devices, “Sync with Android devices over Wi-Fi”. Macs on this Wi-Fi show up here.",
        color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.75f))
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (macs.isEmpty()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(12.dp))
                    Text("Looking for Groovelight…")
                }
            }
            for (mac in macs) {
                Row(Modifier.fillMaxWidth().clickable { model.pair(mac) }.padding(vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(mac.name, fontWeight = FontWeight.SemiBold)
                        Text("${mac.host}:${mac.port}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f))
                    }
                    Text("Pair", color = MaterialTheme.colorScheme.primary)
                }
            }
        }
    }
    // When the network blocks discovery (some routers and guest networks), the Mac's address works too.
    Text("Not listed? Enter the Mac's address (shown in Groovelight's Settings, Devices):", fontSize = 13.sp)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        OutlinedTextField(host, { host = it }, Modifier.weight(1f), label = { Text("Address") }, singleLine = true)
        OutlinedTextField(port, { port = it.filter(Char::isDigit) }, Modifier.width(100.dp), label = { Text("Port") }, singleLine = true)
    }
    OutlinedButton(onClick = { model.pair(FoundMac(host, host, host.trim(), port.toIntOrNull() ?: 52300)) }, enabled = host.isNotBlank()) {
        Text("Pair with this address")
    }

    pairing?.let { state ->
        AlertDialog(
            onDismissRequest = { model.cancelPairing() },
            confirmButton = { TextButton(onClick = { model.cancelPairing() }) { Text(if (state.error != null) "OK" else "Cancel") } },
            title = { Text(if (state.error != null) "Pairing failed" else "Pair with ${state.mac.name}") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    when {
                        state.error != null -> Text(state.error)
                        state.code == null -> Row(verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                            Spacer(Modifier.width(12.dp))
                            Text("Contacting the Mac…")
                        }
                        else -> {
                            Text("${state.code.take(3)} ${state.code.drop(3)}", fontSize = 40.sp, fontWeight = FontWeight.SemiBold)
                            Text("Check that Groovelight on the Mac shows the same code, then click Allow there.")
                        }
                    }
                }
            })
    }
}

@Composable
private fun PairedScreen(model: SyncViewModel, listening: (@Composable () -> Unit)?) {
    val prefs = model.prefs
    val folder by model.folder.collectAsState()
    val autoSync by model.autoSync.collectAsState()
    val charging by model.charging.collectAsState()
    val reachable by model.reachable.collectAsState()
    val work by model.syncWork.collectAsState()
    val context = androidx.compose.ui.platform.LocalContext.current
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri -> uri?.let(model::setFolder) }
    // Opens the picker on the SD card itself.
    val sdPicker = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        result.data?.data?.let(model::setFolder)
    }
    val sdCard = remember { Storage.sdCardPicker(context) }
    val previousFolder by model.previousFolder.collectAsState()
    val mode by model.mode.collectAsState()
    LaunchedEffect(Unit) {
        model.stopDiscovery()
        model.startPolling()
    }
    var lastResult by remember { mutableStateOf(prefs.lastResult) }
    LaunchedEffect(work?.state) { lastResult = prefs.lastResult }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(prefs.macName ?: "Mac", fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
            Text(when (reachable) { true -> "Connected"; false -> "Not reachable: is Groovelight open on the same Wi-Fi?"; null -> "Checking…" },
                color = if (reachable == true) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f), fontSize = 14.sp)
            Text("Choose what this device gets on the Mac: it is listed under Devices in Groovelight.",
                fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f))
        }
    }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Music folder", fontWeight = FontWeight.SemiBold)
            val chosen = remember(folder) { folder?.let { DeviceFolder(context, Uri.parse(it)) } }
            Text(chosen?.displayName ?: "Not chosen yet", color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.75f))
            chosen?.volume?.let { volume ->
                Text("${formatBytes(volume.free)} free of ${formatBytes(volume.total)}", fontSize = 13.sp,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f))
            }
            Text((if (mode == Prefs.Mode.PLAYER) "Groovelight keeps the songs here." else "Your player app finds the songs here.") +
                " Pick a folder such as Music (Android does not let apps use a drive's top level).",
                fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (sdCard != null) {
                    OutlinedButton(onClick = { sdPicker.launch(sdCard) }) { Text("Choose on SD card") }
                }
                OutlinedButton(onClick = { picker.launch(null) }) { Text(if (folder == null) "Choose Folder" else "Change Folder") }
            }
        }
    }

    val running = work?.state == WorkInfo.State.RUNNING || work?.state == WorkInfo.State.ENQUEUED
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (work?.state == WorkInfo.State.RUNNING) {
                val done = work?.progress?.getInt("done", 0) ?: 0
                val total = work?.progress?.getInt("total", 0) ?: 0
                val current = work?.progress?.getString("current") ?: "Getting ready…"
                Text(if (total > 0) "$done of $total" else "Syncing…", fontWeight = FontWeight.SemiBold)
                if (total > 0) LinearProgressIndicator(progress = { done.toFloat() / total }, Modifier.fillMaxWidth())
                else LinearProgressIndicator(Modifier.fillMaxWidth())
                Text(current, fontSize = 13.sp, maxLines = 1)
            } else {
                Text(lastResult?.let { "Last sync: $it" } ?: "Not synced yet", fontWeight = FontWeight.SemiBold)
                if (prefs.lastSync > 0) {
                    Text(DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(prefs.lastSync)), fontSize = 13.sp,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f))
                }
            }
            Button(onClick = { model.syncNow() }, enabled = folder != null && !running, modifier = Modifier.fillMaxWidth()) {
                Text("Sync Now")
            }
        }
    }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            SettingRow("Sync automatically on Wi-Fi", "Checks every 15 minutes and syncs when there is something new.", autoSync, model::setAutoSync)
            if (autoSync) SettingRow("Only while charging", null, charging, model::setCharging)
        }
    }

    listening?.invoke()

    TextButton(onClick = { model.forget() }) { Text("Forget ${prefs.macName ?: "this Mac"}") }

    if (previousFolder != null) {
        AlertDialog(
            onDismissRequest = { model.cleanPreviousFolder(false) },
            title = { Text("Remove songs from the old folder?") },
            text = { Text("The previous folder still has the songs Groovelight put there. The next sync copies them to the new folder; remove the old copies to free the space. Only Groovelight's own files are removed.") },
            confirmButton = { TextButton(onClick = { model.cleanPreviousFolder(true) }) { Text("Remove") } },
            dismissButton = { TextButton(onClick = { model.cleanPreviousFolder(false) }) { Text("Keep") } })
    }
    Spacer(Modifier.height(24.dp))
}

@Composable
private fun SettingRow(title: String, detail: String?, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title)
            detail?.let { Text(it, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)) }
        }
        Switch(checked, onChange)
    }
}

fun formatBytes(bytes: Long): String = when {
    bytes >= 1_000_000_000L -> "%.1f GB".format(bytes / 1_000_000_000.0)
    bytes >= 1_000_000L -> "%.0f MB".format(bytes / 1_000_000.0)
    else -> "%.0f KB".format(bytes / 1_000.0)
}
