package dev.irwingbraga.groovelight.sync

import android.content.Context
import android.net.Uri
import android.os.Build
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.time.Instant
import java.time.temporal.ChronoUnit

/**
 * One sync: tells the Mac what the folder holds, gets the plan, removes and downloads files, and keeps the manifest
 * (`.groovelight-device.json`, the same file Groovelight writes on memory cards) up to date as it goes.
 */
class SyncEngine(private val context: Context, private val prefs: Prefs) {
    data class Progress(val done: Int, val total: Int, val current: String)

    companion object {
        const val MANIFEST = ".groovelight-device.json"
    }

    /** The paired Mac at its last address, or found again on the network (its address may have changed). */
    suspend fun connect(): MacClient {
        val key = prefs.key?.let { Pairing.fromBase64(it) } ?: throw MacError("Not paired with a Mac")
        val macId = prefs.macId ?: throw MacError("Not paired with a Mac")
        val host = prefs.host
        if (host != null) {
            val client = MacClient(host, prefs.port, prefs.deviceId, key)
            if (runCatching { client.info().getString("id") == macId }.getOrDefault(false)) return client
        }
        val found = withTimeoutOrNull(10_000) {
            Discovery.macs(context).mapNotNull { macs -> macs.firstOrNull { it.id == macId } }.first()
        } ?: throw MacError("${prefs.macName ?: "The Mac"} is not reachable. Is Groovelight open, with wireless sync on, on the same Wi-Fi?")
        prefs.host = found.host
        prefs.port = found.port
        return MacClient(found.host, found.port, prefs.deviceId, key)
    }

    suspend fun run(progress: (Progress) -> Unit): String {
        val tree = prefs.folder?.let(Uri::parse) ?: throw MacError("Choose a music folder first")
        val client = connect()
        val folder = DeviceFolder(context, tree)
        progress(Progress(0, 0, "Looking at the music folder…"))
        val files = folder.scan().filter { !it.endsWith(".partial") && it != MANIFEST }
        val manifest = folder.read(MANIFEST)?.let { runCatching { JSONObject(it.decodeToString()) }.getOrNull() }
            ?: JSONObject().put("entries", JSONObject())
        val entries = manifest.optJSONObject("entries") ?: JSONObject().also { manifest.put("entries", it) }

        progress(Progress(0, 0, "Asking ${prefs.macName ?: "the Mac"}…"))
        val request = JSONObject()
            .put("manifest", manifest)
            .put("files", JSONArray(files))
            .put("capacity", folder.totalBytes)
            .put("available", folder.freeBytes)
            .put("volumes", Storage.json(folder.volumes))
            .put("model", "${Build.MANUFACTURER} ${Build.MODEL}")
            .put("name", deviceName())
        val plan = client.sync(request)
        val session = plan.getString("session")
        val writes = plan.getJSONArray("writes")
        val deletions = plan.getJSONArray("deletions")
        val failed = mutableListOf<String>()
        val touched = mutableListOf<String>()

        // Removals first, to make room.
        for (i in 0 until deletions.length()) {
            val path = deletions.getString(i)
            folder.delete(path)
            entries.remove(path)
            touched += path
        }
        folder.pruneEmptyFolders(touched.toList())
        plan.optJSONObject("unchanged")?.let { unchanged -> for (path in unchanged.keys()) entries.put(path, unchanged.get(path)) }
        manifest.put("profile", plan.opt("profile"))
        save(folder, manifest)

        var written = 0
        for (i in 0 until writes.length()) {
            val write = writes.getJSONObject(i)
            val path = write.getString("path")
            progress(Progress(i, writes.length(), path.substringAfterLast('/')))
            // Never over a file that is not Groovelight's.
            if (folder.exists(path) && !entries.has(path)) {
                failed += "$path: a file not from Groovelight is already there"
                continue
            }
            try {
                val size = download(client, folder, session, write.getInt("index"), path)
                val entry = write.getJSONObject("entry").put("size", size)
                entries.put(path, entry)
                touched += path
                written++
                if (written % 25 == 0) save(folder, manifest)
            } catch (error: IOException) {
                failed += "$path: ${error.message}"
            }
        }
        manifest.put("lastSync", Instant.now().truncatedTo(ChronoUnit.SECONDS).toString())
        save(folder, manifest)
        folder.scanMedia(touched)
        progress(Progress(writes.length(), writes.length(), "Finishing…"))

        val result = JSONObject().put("written", written).put("deleted", deletions.length())
            .put("failed", JSONArray(failed)).put("available", folder.freeBytes)
        runCatching { client.done(session, result) }
        val summary = when {
            written == 0 && deletions.length() == 0 && failed.isEmpty() -> "Up to date"
            else -> buildList {
                if (written > 0) add("$written added")
                if (deletions.length() > 0) add("${deletions.length()} removed")
                if (failed.isNotEmpty()) add("${failed.size} failed")
            }.joinToString(", ")
        }
        prefs.lastResult = summary
        prefs.lastSync = System.currentTimeMillis()
        return summary
    }

    /** Downloads one file, resuming a partial copy; up to three tries when Wi-Fi drops. Returns its size. */
    private fun download(client: MacClient, folder: DeviceFolder, session: String, index: Int, path: String): Long {
        var attempt = 0
        while (true) {
            attempt++
            val (output, offset) = folder.openPartial(path)
            var size = offset
            try {
                val (input, connection) = try {
                    client.download(session, index, offset)
                } catch (error: MacError) {
                    output.close()
                    if (error.status == 416) {
                        folder.discardPartial(path)
                        continue
                    }
                    throw error
                }
                try {
                    output.use { out ->
                        input.use { stream ->
                            val buffer = ByteArray(256 * 1024)
                            while (true) {
                                val count = stream.read(buffer)
                                if (count < 0) break
                                out.write(buffer, 0, count)
                                size += count
                            }
                        }
                    }
                } finally {
                    connection.disconnect()
                }
                folder.commit(path, size)
                return size
            } catch (error: IOException) {
                runCatching { output.close() }
                if (attempt >= 3) throw error
                // The partial file keeps what arrived; the next try continues from there.
                folder.scan()
            }
        }
    }

    private fun save(folder: DeviceFolder, manifest: JSONObject) {
        folder.write(MANIFEST, manifest.toString(1).toByteArray())
    }

    private fun deviceName(): String =
        android.provider.Settings.Global.getString(context.contentResolver, android.provider.Settings.Global.DEVICE_NAME)
            ?: "${Build.MANUFACTURER} ${Build.MODEL}"
}
