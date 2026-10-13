package dev.irwingbraga.groovelight.sync

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.io.FileOutputStream

/**
 * Talks to a running Groovelight (the `wireless` debug tour, with automatic pairing) the way the app does: pairs,
 * syncs into a folder (resuming one download halfway), reports back, then syncs again and finds nothing to do.
 * Runs only with GL_MAC_PORT set: `GL_MAC_PORT=52300 ./gradlew testDebugUnitTest`.
 */
class MacIntegrationTest {
    @Test
    fun pairsAndSyncsWithTheMac() {
        val port = System.getenv("GL_MAC_PORT")?.toIntOrNull()
        assumeTrue("Groovelight is not running for this test", port != null)
        val deviceId = "jvm-test-" + System.nanoTime()
        val folder = File(System.getProperty("java.io.tmpdir"), "groovelight-android-$deviceId").apply { mkdirs() }

        // Pairing.
        val keys = Pairing.newKeyPair()
        val devicePublic = Pairing.rawPublic(keys)
        val open = MacClient("127.0.0.1", port!!, deviceId, null)
        assertTrue(open.info().getString("name").isNotEmpty())
        val answer = open.pair("JVM Test", "Desktop JVM", devicePublic)
        val macPublic = Pairing.fromBase64(answer.getString("publicKey"))
        val (key, code) = Pairing.derive(keys.private, macPublic, devicePublic, macPublic)
        val macCode = File(System.getProperty("java.io.tmpdir"), "groovelight-pair-code").takeIf { it.exists() }?.readText()
        var status = "pending"
        repeat(20) { if (status == "pending") { status = open.pairStatus(); Thread.sleep(250) } }
        assertEquals("accepted", status)
        if (macCode != null) assertEquals(macCode, code)
        val client = MacClient("127.0.0.1", port, deviceId, key)
        assertTrue(client.status().has("syncRequested"))

        // First sync: everything is new. One download is cut off and resumed with a range request.
        Thread.sleep(500)
        val first = sync(client, folder, cutFirstDownload = true)
        println("first sync: $first")
        assertTrue("songs were written", first.first > 0)
        assertEquals(0, first.second)
        val manifest = JSONObject(File(folder, SyncEngine.MANIFEST).readText())
        assertEquals(first.first, manifest.getJSONObject("entries").length())

        // Second sync: nothing changed.
        val second = sync(client, folder, cutFirstDownload = false)
        println("second sync: $second")
        assertEquals(0 to 0, second)
        folder.deleteRecursively()
    }

    /** The engine's steps on plain files; returns (written, deleted). */
    private fun sync(client: MacClient, folder: File, cutFirstDownload: Boolean): Pair<Int, Int> {
        val manifestFile = File(folder, SyncEngine.MANIFEST)
        val manifest = if (manifestFile.exists()) JSONObject(manifestFile.readText()) else JSONObject().put("entries", JSONObject())
        val entries = manifest.getJSONObject("entries")
        val files = folder.walkTopDown().filter { it.isFile && it.name != SyncEngine.MANIFEST }.map { it.relativeTo(folder).path }.toList()
        val plan = client.sync(JSONObject().put("manifest", manifest).put("files", JSONArray(files))
            .put("capacity", 1_000_000_000L).put("available", 900_000_000L).put("model", "Desktop JVM").put("name", "JVM Test")
            .put("volumes", Storage.json(listOf(
                Storage.Volume("Internal storage", false, 64_000_000_000L, 20_000_000_000L, null, false),
                Storage.Volume("SanDisk SD card", true, 128_000_000_000L, 90_000_000_000L, null, true)))))
        val session = plan.getString("session")
        val writes = plan.getJSONArray("writes")
        val deletions = plan.getJSONArray("deletions")
        for (i in 0 until deletions.length()) { File(folder, deletions.getString(i)).delete(); entries.remove(deletions.getString(i)) }
        plan.optJSONObject("unchanged")?.let { unchanged -> for (path in unchanged.keys()) entries.put(path, unchanged.get(path)) }
        manifest.put("profile", plan.opt("profile"))
        for (i in 0 until writes.length()) {
            val write = writes.getJSONObject(i)
            val target = File(folder, write.getString("path")).apply { parentFile.mkdirs() }
            val partial = File(target.parentFile, ".${target.name}.partial")
            if (cutFirstDownload && i == 0) {
                // Only the first half arrives, as if Wi-Fi dropped.
                val (input, connection) = client.download(session, write.getInt("index"), 0)
                FileOutputStream(partial).use { out -> out.write(input.readNBytes((write.getLong("size") / 2).toInt())) }
                connection.disconnect()
            }
            val (input, connection) = client.download(session, write.getInt("index"), if (partial.exists()) partial.length() else 0)
            FileOutputStream(partial, true).use { out -> input.use { it.copyTo(out) } }
            connection.disconnect()
            if (write.getJSONObject("entry").getString("kind") == "song") assertEquals(write.getLong("size"), partial.length())
            partial.renameTo(target)
            entries.put(write.getString("path"), write.getJSONObject("entry").put("size", target.length()))
        }
        manifest.put("lastSync", java.time.Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS).toString())
        manifestFile.writeText(manifest.toString(1))
        client.done(session, JSONObject().put("written", writes.length()).put("deleted", deletions.length())
            .put("failed", JSONArray()).put("available", 900_000_000L))
        return writes.length() to deletions.length()
    }
}
