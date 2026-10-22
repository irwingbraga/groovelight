package dev.irwingbraga.groovelight.update

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import androidx.core.content.edit
import dev.irwingbraga.groovelight.BuildConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * The GitHub build updates itself: it reads the latest release of Groovelight on GitHub (once a day, or when asked
 * in Settings), and when it is newer, downloads its APK, checks it against the SHA-256 GitHub gives, and hands it to
 * Android's package installer, which asks the user and installs it over this one (same signing key).
 */
object AppUpdates {
    const val SUPPORTED = true
    private const val LATEST = "https://api.github.com/repos/irwingbraga/groovelight/releases/latest"
    private const val DAY = 24 * 60 * 60 * 1000L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val current = MutableStateFlow<UpdateState>(UpdateState.Idle)
    val state: StateFlow<UpdateState> = current
    /** A version the user chose not to install now: not offered again on its own (Settings still shows it). */
    private val skipped = MutableStateFlow<String?>(null)
    val dismissed: StateFlow<String?> = skipped

    /** The update being installed, to try again after the installer stops (allowing installs first cancels it). */
    private var installing: UpdateState.Available? = null

    private fun prefs(context: Context) = context.getSharedPreferences("updates", Context.MODE_PRIVATE)

    /** Checks when the last check is a day old (debug builds only when asked: a release cannot replace them). */
    fun checkIfDue(context: Context) {
        val prefs = prefs(context)
        skipped.value = prefs.getString("dismissed", null)
        if (BuildConfig.DEBUG || System.currentTimeMillis() - prefs.getLong("checkedAt", 0) < DAY) return
        check(context)
    }

    fun check(context: Context) {
        if (current.value is UpdateState.Checking || current.value is UpdateState.Downloading) return
        current.value = UpdateState.Checking
        scope.launch {
            current.value = runCatching { latest() }.fold(
                onSuccess = { release ->
                    prefs(context).edit { putLong("checkedAt", System.currentTimeMillis()) }
                    release
                },
                onFailure = { UpdateState.Failed("Could not reach GitHub: ${it.message ?: "no connection"}") },
            )
        }
    }

    fun dismiss(context: Context, version: String) {
        skipped.value = version
        prefs(context).edit { putString("dismissed", version) }
    }

    private fun latest(): UpdateState {
        val connection = URL(LATEST).openConnection() as HttpURLConnection
        connection.setRequestProperty("Accept", "application/vnd.github+json")
        connection.connectTimeout = 15_000
        connection.readTimeout = 15_000
        val release = connection.inputStream.use { JSONObject(it.readBytes().decodeToString()) }
        val version = release.getString("tag_name").removePrefix("v")
        if (!isNewer(version, BuildConfig.VERSION_NAME)) return UpdateState.UpToDate(BuildConfig.VERSION_NAME)
        val assets = release.getJSONArray("assets")
        val apk = (0 until assets.length()).map(assets::getJSONObject)
            // "Groovelight-<version>.apk" since 0.5.0 (with the player), "GroovelightSync-<version>.apk" before.
            .firstOrNull { it.getString("name").let { name -> name.endsWith(".apk") && (name.startsWith("Groovelight-") || name.startsWith("GroovelightSync-")) } }
            ?: return UpdateState.UpToDate(BuildConfig.VERSION_NAME)
        return UpdateState.Available(
            version = version,
            notes = release.optString("body").trim(),
            url = apk.getString("browser_download_url"),
            size = apk.optLong("size"),
            sha256 = apk.optString("digest").takeIf { it.startsWith("sha256:") }?.removePrefix("sha256:"),
        )
    }

    /** Downloads the available version and starts installing it. */
    fun install(context: Context) {
        val update = when (val state = current.value) {
            is UpdateState.Available -> state
            is UpdateState.Failed -> state.available ?: return
            else -> return
        }
        val app = context.applicationContext
        installing = update
        current.value = UpdateState.Downloading(update.version, 0f)
        scope.launch {
            runCatching {
                val file = download(app, update)
                current.value = UpdateState.Installing(update.version)
                installer(app, file)
            }.onFailure { error ->
                current.value = UpdateState.Failed(error.message ?: "The update could not be installed", update)
            }
        }
    }

    private fun download(context: Context, update: UpdateState.Available): File {
        val folder = File(context.cacheDir, "updates")
        val file = File(folder, "Groovelight-${update.version}.apk")
        // Downloaded already (trying again): kept when it still matches.
        if (file.exists() && update.sha256 != null && sha256(file).equals(update.sha256, ignoreCase = true)) return file
        folder.deleteRecursively()
        folder.mkdirs()
        val digest = MessageDigest.getInstance("SHA-256")
        val connection = URL(update.url).openConnection() as HttpURLConnection
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        val total = connection.contentLengthLong.takeIf { it > 0 } ?: update.size
        connection.inputStream.use { input ->
            file.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                var read = 0L
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                    digest.update(buffer, 0, count)
                    read += count
                    if (total > 0) current.value = UpdateState.Downloading(update.version, (read.toFloat() / total).coerceIn(0f, 1f))
                }
            }
        }
        val sha = digest.digest().joinToString("") { "%02x".format(it) }
        if (update.sha256 != null && !sha.equals(update.sha256, ignoreCase = true)) {
            file.delete()
            throw IllegalStateException("The download arrived damaged: try again")
        }
        return file
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun installer(context: Context, file: File) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            setSize(file.length())
            // No confirmation when Android allows it (the app installed itself before); otherwise Android asks.
            setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            session.openWrite("base.apk", 0, file.length()).use { output ->
                file.inputStream().use { it.copyTo(output) }
                session.fsync(output)
            }
            val intent = Intent(context, UpdateReceiver::class.java)
            // Mutable: the installer adds the status to it.
            val status = PendingIntent.getBroadcast(context, id, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
            session.commit(status.intentSender)
        }
    }

    internal fun installFinished(status: Int, message: String?) {
        val version = (current.value as? UpdateState.Installing)?.version ?: return
        val retry = installing
        current.value = when (status) {
            PackageInstaller.STATUS_SUCCESS -> UpdateState.UpToDate(version)
            // Also when Android first sends the user to allow installs from Groovelight: then Try Again goes on.
            PackageInstaller.STATUS_FAILURE_ABORTED -> UpdateState.Failed(
                "The installation was stopped. If Android asked to allow installs from Groovelight, allow them, then try again.", retry)
            PackageInstaller.STATUS_FAILURE_CONFLICT, PackageInstaller.STATUS_FAILURE_INCOMPATIBLE ->
                UpdateState.Failed("This copy of Groovelight cannot be updated by the release (it is signed differently): install the release from GitHub")
            else -> UpdateState.Failed(message ?: "The update could not be installed", retry)
        }
    }
}

/** The installer's answers: it may first need the user to confirm (then its screen opens), then success or failure. */
class UpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            @Suppress("DEPRECATION")
            (intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT))?.let { confirm ->
                context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            return
        }
        AppUpdates.installFinished(status, intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE))
    }
}
