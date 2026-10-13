package dev.irwingbraga.groovelight.sync

import org.junit.Assert.assertEquals
import org.junit.Test

/** The same vector as WirelessSyncTests on the Mac: both sides must derive the same code, key and signatures. */
class PairingTest {
    private val devicePrivate = ByteArray(32) { (it + 1).toByte() }
    private val macPublic = "WGmv9FBUlzLLqu1eXfmzCm2jHLDldCutWtShp2jxpns="

    @Test
    fun matchesTheMac() {
        val (private, public) = Pairing.keyPair(devicePrivate)
        assertEquals("B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=", Pairing.base64(public))
        val mac = Pairing.fromBase64(macPublic)
        val (key, code) = Pairing.derive(private, mac, public, mac)
        assertEquals("328727", code)
        assertEquals("lpDhU3RKuAhlJ1Osb2X4F88i0R6pUe5J//UAaIQxHFs=",
            Pairing.signature("post", "/sync", 1_700_000_000, "n1", "{}".toByteArray(), key))
    }

    @Test
    fun freshKeysAgree() {
        val device = Pairing.newKeyPair()
        val mac = Pairing.newKeyPair()
        val devicePublic = Pairing.rawPublic(device)
        val macPublic = Pairing.rawPublic(mac)
        val (deviceKey, deviceCode) = Pairing.derive(device.private, macPublic, devicePublic, macPublic)
        // The Mac's side of the same exchange.
        val (macKey, macCode) = Pairing.derive(mac.private, devicePublic, devicePublic, macPublic)
        assertEquals(deviceCode, macCode)
        assertEquals(deviceKey.toList(), macKey.toList())
    }
}
