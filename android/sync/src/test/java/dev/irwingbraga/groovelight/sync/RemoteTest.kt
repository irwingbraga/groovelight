package dev.irwingbraga.groovelight.sync

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Playing music on the Mac: the state and commands as the Mac writes and reads them. */
class RemoteTest {
    /** The state this device reports when other devices play on it reads back as it was (as the Mac reads it). */
    @Test
    fun relayedStateRoundTrips() {
        val state = RemoteState(
            item = RemoteState.Item(8, "Song", "Band", "LP", "band\u001flp", null, 200.0),
            playing = true, positionSeconds = 42.5, rate = 1.0, volume = 1.0, shuffle = false, repeatMode = "all",
            queue = listOf(7, 8, 9), queueIndex = 1, version = "",
        )
        val json = state.toJson()
        assertTrue(json.isNull("item").not())
        assertTrue(json.getJSONObject("item").isNull("artworkHash"))
        assertEquals(state, RemoteState.from(json))
        val idle = RemoteState(null, false, 0.0, 1.0, 1.0, false, "off", emptyList(), null, "")
        assertEquals(idle, RemoteState.from(idle.toJson()))
        assertEquals(RemoteDevice("phone-2", "Pixel"), RemoteDevice.from(JSONObject("""{"id":"phone-2","name":"Pixel"}""")))
    }

    @Test
    fun readsTheMacsState() {
        val state = RemoteState.from(JSONObject("""
            {"item":{"album":"LP","albumKey":"band\u001flp","artist":"Band","artworkHash":"abc","duration":200.5,"id":8,"title":"Two"},
             "playing":true,"position":42.25,"queue":[7,8,9],"queueIndex":1,"rate":1,"repeatMode":"all","shuffle":false,
             "version":"8|p|1800000000","volume":0.8}
        """.trimIndent()))
        assertEquals(8L, state.item?.id)
        assertEquals("Two", state.item?.title)
        assertEquals("abc", state.item?.artworkHash)
        assertEquals(200.5, state.item!!.durationSeconds, 0.0)
        assertTrue(state.playing)
        assertEquals(42.25, state.positionSeconds, 0.0)
        assertEquals(listOf(7L, 8L, 9L), state.queue)
        assertEquals(1, state.queueIndex)
        assertEquals("all", state.repeatMode)

        val idle = RemoteState.from(JSONObject("""{"playing":false,"position":0,"queue":[],"rate":1,"repeatMode":"off","shuffle":false,"version":"-","volume":1}"""))
        assertNull(idle.item)
        assertNull(idle.queueIndex)
    }

    /** The same objects the Mac's `RemoteControlTests.commandsAreFlatJSON` reads. */
    @Test
    fun writesFlatCommands() {
        assertSame("""{"command":"seek","position":42.5}""", RemoteCommand.seek(42.5))
        assertSame("""{"command":"play","songIds":[7,8],"startAt":1,"position":3.0,"shuffle":false}""", RemoteCommand.play(listOf(7, 8), 1, 3.0))
        assertSame("""{"command":"pause"}""", RemoteCommand.pause())
        assertSame("""{"command":"shuffle","on":true}""", RemoteCommand.shuffle(true))
        assertSame("""{"command":"repeatMode","mode":"all"}""", RemoteCommand.repeatMode("all"))
    }

    /** The same fields and values, in any order. */
    private fun assertSame(expected: String, actual: JSONObject) {
        fun fields(json: JSONObject) = json.keys().asSequence().associateWith { json.get(it).toString() }
        assertEquals(fields(JSONObject(expected)), fields(actual))
    }

    /**
     * Against a running Groovelight (the `wireless` debug tour with `-GLDebugAutoPair YES -GLDebugAllowRemote YES`):
     * pairs, pins the certificate, plays a song there from 3 seconds in, follows a pause, and stops.
     * Runs only with GL_MAC_PORT set.
     */
    @Test
    fun playsOnTheMac() {
        val port = System.getenv("GL_MAC_PORT")?.toIntOrNull()
        assumeTrue("Groovelight is not running for this test", port != null)
        val deviceId = "jvm-remote-" + System.nanoTime()
        val keys = Pairing.newKeyPair()
        val devicePublic = Pairing.rawPublic(keys)
        val open = MacClient("127.0.0.1", port!!, deviceId, null)
        val tlsPort = open.info().getInt("tlsPort")
        val macPublic = Pairing.fromBase64(open.pair("JVM Remote", "Desktop JVM", devicePublic).getString("publicKey"))
        val (key, _) = Pairing.derive(keys.private, macPublic, devicePublic, macPublic)
        repeat(20) { if (open.pairStatus() == "pending") Thread.sleep(250) }
        val fingerprint = MacClient("127.0.0.1", port, deviceId, key).pinnedCertificate()
        val client = MacClient("127.0.0.1", port, deviceId, key, MacClient.Tls(tlsPort, fingerprint))

        val songs = JSONObject(client.catalog(null)!!.first.decodeToString()).getJSONArray("songs")
        val ids = (0 until minOf(songs.length(), 3)).map { songs.getJSONObject(it).getLong("id") }
        client.remote(RemoteCommand.volume(0.0))
        val playing = RemoteState.from(client.remote(RemoteCommand.play(ids, 0, 3.0)))
        assertEquals(ids[0], playing.item?.id)
        assertTrue(playing.playing)
        Thread.sleep(1500)
        val now = RemoteState.from(client.remoteState())
        assertTrue("at ${now.positionSeconds} s", now.positionSeconds >= 3.5)
        assertEquals(ids, now.queue.take(ids.size))

        // Waiting on its version: answered once it pauses (asked from elsewhere), not before.
        val waiter = Thread { Thread.sleep(800); client.remote(RemoteCommand.pause()) }.apply { start() }
        val started = System.nanoTime()
        val paused = RemoteState.from(client.remoteState(after = now.version))
        waiter.join()
        assertFalse(paused.playing)
        assertNotEquals(now.version, paused.version)
        assertTrue((System.nanoTime() - started) / 1_000_000 >= 700)
        client.remote(RemoteCommand.stop())
        client.remote(RemoteCommand.volume(0.8))
    }

    /**
     * Plays on another device through the Mac, against a running Groovelight (`GL_MAC_PORT`) and another device with
     * Groovelight open there (`GL_RELAY_DEVICE`: its name, as the iOS simulator's "iPad Pro 13-inch (M5)").
     */
    @Test
    fun playsOnAnotherDevice() {
        val port = System.getenv("GL_MAC_PORT")?.toIntOrNull()
        val name = System.getenv("GL_RELAY_DEVICE")
        assumeTrue("No Groovelight and other device for this test", port != null && name != null)
        val client = pairedClient(port!!)
        val device = client.remoteDevices().firstOrNull { it.name == name }
        assertTrue("$name is not listed: ${client.remoteDevices()}", device != null)

        val songs = JSONObject(client.catalog(null)!!.first.decodeToString()).getJSONArray("songs")
        val ids = (0 until minOf(songs.length(), 3)).map { songs.getJSONObject(it).getLong("id") }
        val playing = RemoteState.from(client.remote(RemoteCommand.play(ids, 1, 2.0), device!!.id))
        assertEquals(ids[1], playing.item?.id)
        assertTrue(playing.playing)
        assertTrue("at ${playing.positionSeconds} s", playing.positionSeconds >= 2.0)

        val waiter = Thread { Thread.sleep(800); client.remote(RemoteCommand.pause(), device.id) }.apply { start() }
        val paused = RemoteState.from(client.remoteState(after = playing.version, device = device.id))
        waiter.join()
        assertFalse(paused.playing)
        assertEquals(ids[1], paused.item?.id)
    }

    private fun pairedClient(port: Int): MacClient {
        val deviceId = "jvm-remote-" + System.nanoTime()
        val keys = Pairing.newKeyPair()
        val devicePublic = Pairing.rawPublic(keys)
        val open = MacClient("127.0.0.1", port, deviceId, null)
        val tlsPort = open.info().getInt("tlsPort")
        val macPublic = Pairing.fromBase64(open.pair("JVM Remote", "Desktop JVM", devicePublic).getString("publicKey"))
        val (key, _) = Pairing.derive(keys.private, macPublic, devicePublic, macPublic)
        repeat(20) { if (open.pairStatus() == "pending") Thread.sleep(250) }
        val fingerprint = MacClient("127.0.0.1", port, deviceId, key).pinnedCertificate()
        return MacClient("127.0.0.1", port, deviceId, key, MacClient.Tls(tlsPort, fingerprint))
    }
}
