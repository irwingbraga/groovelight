package dev.irwingbraga.groovelight.sync

import android.content.Context
import android.net.Uri
import android.os.Build
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.withTimeoutOrNull
import dev.irwingbraga.groovelight.library.ArtworkStore
import dev.irwingbraga.groovelight.library.LibraryDatabase
import dev.irwingbraga.groovelight.library.Snapshot
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.security.MessageDigest
import javax.net.ssl.SSLException
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

    /**
     * The paired Mac at its last address, found again on the network (its address may have changed), or away from home
     * at its Tailscale address. Over HTTPS when
     * the Mac offers it (protocol v2): its certificate is pinned the first time, with the Mac's proof that it holds the
     * pairing key, and from then on nothing else is accepted.
     */
    suspend fun connect(): MacClient {
        val key = prefs.key?.let { Pairing.fromBase64(it) } ?: throw MacError("Not paired with a Mac")
        val macId = prefs.macId ?: throw MacError("Not paired with a Mac")
        val (host, info) = locate(key, macId)
        prefs.isAway = isTailscale(host)
        val tlsPort = info.optInt("tlsPort", 0)
        prefs.tlsPort = tlsPort
        if (tlsPort == 0) {
            // Pinned before: someone may be pretending the Mac has no HTTPS, so its traffic can be read.
            if (prefs.certificate != null) {
                throw MacError("${prefs.macName ?: "The Mac"} did not offer its secure connection. Update Groovelight on the Mac, or forget it here and pair again.")
            }
            return MacClient(host, prefs.port, prefs.deviceId, key)
        }
        prefs.certificate?.let { pinned ->
            val client = MacClient(host, prefs.port, prefs.deviceId, key, MacClient.Tls(tlsPort, pinned))
            val check = runCatching { client.info() }
            if (check.isSuccess) return client
            // Another certificate (the Mac made a new one): pinned again below, only with the Mac's proof.
            if (check.exceptionOrNull() !is SSLException) throw check.exceptionOrNull()!!
        }
        val fingerprint = MacClient(host, prefs.port, prefs.deviceId, key).pinnedCertificate()
        prefs.certificate = fingerprint
        return MacClient(host, prefs.port, prefs.deviceId, key, MacClient.Tls(tlsPort, fingerprint))
    }

    /**
     * Where the Mac is now (the host answering) and its `/info`: its last address on this network, the Mac found again
     * on it, or its Tailscale addresses. [Prefs.host] stays its address at home, tried first next time.
     */
    private suspend fun locate(key: ByteArray, macId: String): Pair<String, JSONObject> {
        fun probe(host: String, port: Int, timeout: Int): JSONObject? =
            runCatching { MacClient(host, port, prefs.deviceId, key).info(timeout) }.getOrNull()?.takeIf { it.optString("id") == macId }
        fun found(host: String, info: JSONObject): Pair<String, JSONObject> {
            info.optJSONArray("awayAddresses")?.let { away -> prefs.awayHosts = (0 until away.length()).map { away.getString(it) } }
            return host to info
        }
        prefs.host?.let { host -> probe(host, prefs.port, 4_000)?.let { return found(host, it) } }
        val mac = withTimeoutOrNull(5_000) {
            Discovery.macs(context).mapNotNull { macs -> macs.firstOrNull { it.id == macId } }.first()
        }
        if (mac != null) {
            probe(mac.host, mac.port, 8_000)?.let { info ->
                prefs.host = mac.host
                prefs.port = mac.port
                return found(mac.host, info)
            }
        }
        for (away in prefs.awayHosts) probe(away, prefs.port, 8_000)?.let { return found(away, it) }
        throw MacError("${prefs.macName ?: "The Mac"} is not reachable. Is Groovelight open on the Mac, and this device on the same Wi-Fi (or, away from home, on Tailscale with the Mac allowing it)?")
    }

    suspend fun run(progress: (Progress) -> Unit): String {
        val tree = prefs.folder?.let(Uri::parse) ?: throw MacError("Choose a music folder first")
        val client = connect()
        if (client.isAway && !prefs.syncsOverMobileData &&
            context.getSystemService(android.net.ConnectivityManager::class.java).isActiveNetworkMetered) {
            throw MacError("Away from home, syncing waits for Wi-Fi. To sync over mobile data, turn it on in Settings.")
        }
        var missingCovers = 0
        // First what was done here: loves and ratings (so the Mac's snapshot has them) and requests (so this sync brings
        // what they asked for).
        if (prefs.mode == Prefs.Mode.PLAYER && prefs.tlsPort != 0) {
            runCatching { Transfers.sendHistory(context, client) }
            runCatching { Transfers.send(context, client) }
        }
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
        val player = prefs.mode == Prefs.Mode.PLAYER
        request.put("mode", if (player) "player" else "sync")
        if (player) request.put("decodes", JSONArray(Formats.decodable()))
        // The format chosen here for lossless songs (the Mac's otherwise).
        prefs.encoding?.let { request.put("encoding", it) }
        val plan = client.sync(request)
        val session = plan.getString("session")
        // The download token (v2, over HTTPS): files without signing each request.
        val token = plan.optString("token").takeIf { it.isNotEmpty() }
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
                val size = download(client, folder, session, write.getInt("index"), path, token)
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
        // Player mode: the library from the Mac, for the songs now in the folder (other players need no media scan,
        // but it keeps the folder browsable in Files and player apps if the user switches).
        if (player && token != null) {
            progress(Progress(writes.length(), writes.length(), "Updating the library…"))
            missingCovers = updateLibrary(client, session, token, failedPaths = failed.map { it.substringBefore(": ") }.toSet(), tree = tree)
        }
        // The Mac's whole library, for browsing it here (only when it changed).
        if (player && prefs.tlsPort != 0) runCatching { Transfers.refreshCatalog(context, client, prefs) }
        folder.scanMedia(touched)
        progress(Progress(writes.length(), writes.length(), "Finishing…"))

        val result = JSONObject().put("written", written).put("deleted", deletions.length())
            .put("failed", JSONArray(failed)).put("available", folder.freeBytes)
        runCatching { client.done(session, result) }
        val summary = when {
            written == 0 && deletions.length() == 0 && failed.isEmpty() && missingCovers == 0 -> "Up to date"
            else -> buildList {
                if (written > 0) add("$written added")
                if (deletions.length() > 0) add("${deletions.length()} removed")
                if (failed.isNotEmpty()) add("${failed.size} failed")
                if (missingCovers > 0) add(if (missingCovers == 1) "1 album without a cover" else "$missingCovers albums without a cover")
            }.joinToString(", ").ifEmpty { "Up to date" }
        }
        prefs.lastResult = summary
        prefs.lastSync = System.currentTimeMillis()
        return summary
    }

    /**
     * Imports the plan's library snapshot and fetches the covers it needs (both checked against their SHA-256, and covers
     * against Android's decoder). Albums whose cover the Mac could not send get the one embedded in their songs, as
     * other players show. Returns how many albums are left without a cover.
     */
    private suspend fun updateLibrary(client: MacClient, session: String, token: String, failedPaths: Set<String>, tree: Uri): Int {
        val (data, hash) = client.snapshot(session, token)
        if (hash != null && sha256(data) != hash) throw MacError("The library from the Mac arrived damaged: sync again")
        val full = Snapshot.read(data.inputStream())
        // Songs that could not be written are left out (their playlist entries too).
        val tracks = full.tracks.filter { it.path !in failedPaths }
        val ids = tracks.map { it.id }.toSet()
        val keys = tracks.map { it.albumKey }.toSet()
        var snapshot = full.copy(albums = full.albums.filter { it.key in keys }, tracks = tracks, items = full.items.filter { it.trackId in ids },
            credits = full.credits.filter { it.albumKey in keys && (it.trackId == null || it.trackId in ids) })
        val artwork = ArtworkStore(context)
        // Covers kept from before that Android cannot show (CMYK ones older Macs sent) are fetched again.
        for (cover in snapshot.artworkHashes.filter { artwork.has(it) && !Covers.decodes(artwork.file(it)) }) artwork.file(cover).delete()
        for (cover in snapshot.artworkHashes.filter { !artwork.has(it) }) {
            runCatching {
                val (image, imageHash) = client.artwork(session, token, cover)
                // Every cover comes with its SHA-256: an empty or damaged one is not kept (the next sync asks again).
                if (image.isNotEmpty() && imageHash != null && sha256(image) == imageHash && Covers.decodes(image)) artwork.save(cover, image)
            }
        }
        snapshot = Covers.fillFromFiles(context, snapshot, artwork, tree)
        snapshot.importInto(LibraryDatabase.get(context))
        artwork.prune(keeping = snapshot.artworkHashes)
        return snapshot.albums.count { album -> album.artworkHash?.let(artwork::has) != true }
    }

    private fun sha256(data: ByteArray): String = Pairing.hexString(MessageDigest.getInstance("SHA-256").digest(data))

    /**
     * Downloads one file, resuming a partial copy; up to three tries when Wi-Fi drops. With the Mac's SHA-256 (v2),
     * the written file is read back and checked, and a damaged one is downloaded again. Returns its size.
     */
    private fun download(client: MacClient, folder: DeviceFolder, session: String, index: Int, path: String, token: String?): Long {
        var attempt = 0
        while (true) {
            attempt++
            val (output, offset) = folder.openPartial(path)
            var size = offset
            try {
                val (input, connection) = try {
                    client.download(session, index, offset, token)
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
                val expected = connection.getHeaderField("X-GL-SHA256")
                if (expected != null && folder.sha256(path) != expected) {
                    folder.delete(path)
                    throw IOException("the copy did not match the Mac's")
                }
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
