package dev.irwingbraga.groovelight.sync

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Mac reached away from home: Tailscale's addresses, as the Mac's `AwayNetwork` knows them. */
class AwayTest {
    @Test fun tailscaleAddresses() {
        assertTrue(isTailscale("100.109.215.46"))
        assertTrue(isTailscale("100.127.255.1"))
        assertTrue(isTailscale("fd7a:115c:a1e0::e401:d7a3"))
        assertFalse(isTailscale("100.128.0.1"))
        assertFalse(isTailscale("192.168.1.20"))
        assertFalse(isTailscale("fe80::1"))
    }
}
