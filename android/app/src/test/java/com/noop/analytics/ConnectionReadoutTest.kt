package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Connection & Sync line formatters + readout parsers (Test Centre). Pure JVM - no Robolectric, no
 * Mockito/MockK, no BLE - so fixtures pin the exact line shapes the Kotlin and Swift emitters share.
 * Twin of the Swift ConnectionTraceTests / ConnectionReadoutTests.
 */
class ConnectionTraceTest {

    @Test fun clockDriftLineHealthy() {
        val newest = 1_782_475_200L            // 2026-06-26 12:00:00 UTC
        val oldest = newest - 2 * 86_400L
        val wall = newest + 600L               // wall 10 min ahead of the newest record
        val line = ConnectionTrace.clockDriftLine(oldestUnix = oldest, newestUnix = newest, wallNowUnix = wall)
        assertTrue(line, line.startsWith("clockDrift newest=2026-06-26 12:00:00 "))
        assertTrue(line, line.contains("newestVsWall=-600s"))
        assertTrue(line, line.contains("spanDays=2"))
        assertTrue(line, line.endsWith("clockOk"))
        assertFalse(line, line.contains("FUTURE"))
    }

    @Test fun clockDriftLineFutureDated() {
        val wall = 1_782_475_200L
        val newest = wall + 3 * 86_400L        // strap thinks it banked 3 days into the future
        val line = ConnectionTrace.clockDriftLine(oldestUnix = null, newestUnix = newest, wallNowUnix = wall)
        assertTrue(line, line.contains("newestVsWall=+${3 * 86_400}s"))
        assertTrue(line, line.contains("FUTURE-DATED"))
        assertFalse(line, line.contains("oldest="))   // half range reply: no lower bound
    }

    @Test fun clockDriftLineWithinToleranceIsOk() {
        val wall = 1_782_475_200L
        val newest = wall + 60L                // 1 min ahead, inside the 120s default tolerance
        val line = ConnectionTrace.clockDriftLine(oldestUnix = null, newestUnix = newest, wallNowUnix = wall)
        assertTrue(line, line.endsWith("clockOk"))
    }

    @Test fun firmwareLine() {
        assertEquals("firmware layout=v25 decodable", ConnectionTrace.firmwareLine(25, true))
        assertEquals("firmware layout=v30 UNMAPPED (no motion/HR decoded)", ConnectionTrace.firmwareLine(30, false))
    }

    @Test fun noCursorLine() {
        assertEquals(
            "offload trim=0xFFFFFFFF noCursor (strap has no banked history to offload)",
            ConnectionTrace.noCursorLine(),
        )
    }
}

class ConnectionReadoutTest {

    @Test fun uptimeLabelFromConnectMarker() {
        val tail = listOf("[connection] connect up gen=1 latencyMs=420 uptimeStart=1000")
        assertEquals("3m 12s", ConnectionReadout.uptimeLabel(tail, nowUnix = 1000 + 192))
    }

    @Test fun uptimeLabelDownAfterDisconnect() {
        val tail = listOf(
            "[connection] connect up gen=1 latencyMs=420 uptimeStart=1000",
            "[connection] connect down (uptime ends)",
        )
        assertEquals("not connected", ConnectionReadout.uptimeLabel(tail, nowUnix = 5000))
    }

    @Test fun uptimeLabelEmptyTail() {
        assertEquals("not connected", ConnectionReadout.uptimeLabel(emptyList(), nowUnix = 5000))
    }

    @Test fun reconnectCountTakesHighest() {
        val tail = listOf(
            "[connection] reconnect n=1 reason=connectionTimeout",
            "[connection] reconnect n=2 reason=connectionTimeout",
            "[connection] reconnect n=3 failedConnect reason=peerRemovedPairing",
        )
        assertEquals(3, ConnectionReadout.reconnectCount(tail))
    }

    @Test fun reconnectCountZeroWhenNone() {
        assertEquals(0, ConnectionReadout.reconnectCount(listOf("[connection] connect up gen=1 uptimeStart=1")))
    }

    @Test fun lastOffloadResult() {
        val tail = listOf(
            "[connection] offload progress trim=100 chunkRows=5 sessionRows=5 sessionMotion=2 nights=1",
            "[connection] offload result=complete rows=42 nights=2",
        )
        assertEquals("complete rows=42 nights=2", ConnectionReadout.lastOffloadResult(tail))
    }

    @Test fun lastOffloadResultStalled() {
        val tail = listOf("[connection] offload result=stalled (idle timeout, rows=12 so far)")
        assertEquals("stalled (idle timeout, rows=12 so far)", ConnectionReadout.lastOffloadResult(tail))
    }

    @Test fun lastOffloadResultNullWhenNone() {
        assertNull(ConnectionReadout.lastOffloadResult(listOf("[connection] connect up gen=1 uptimeStart=1")))
    }
}
