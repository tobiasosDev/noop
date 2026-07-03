package com.noop.analytics

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

// ConnectionReadout.kt - Kotlin twin of ConnectionReadout.swift. Pure values + line formatters for the
// Connection & Sync test mode: the clock-drift summary line (strap-reported banked-record range vs wall
// clock with a future-date flag), the firmware-layout line, the no-cursor / trim sentinel line, and the
// tagged-tail parsers for the three liveReadout ids. No state, no IO, no em-dashes. Byte-aligned with the
// Swift line shapes so a shared report reads identically on either platform.

object ConnectionTrace {

    /**
     * The CLOCK-DRIFT summary line (#767 / #754 cluster): the strap-reported banked-record window
     * [oldest, newest] against the wall clock, with a FUTURE-DATE flag when the strap's newest record is
     * dated ahead of wall-now. Promoted from the buried raw GET_DATA_RANGE frames to one upfront
     * .connection line. All timestamps are unix seconds in the same wall domain. [oldestUnix] is optional
     * (a half/short range reply gives only the upper bound). Mirrors the Swift formatter exactly.
     */
    fun clockDriftLine(
        oldestUnix: Long?,
        newestUnix: Long,
        wallNowUnix: Long,
        futureToleranceSeconds: Long = 120L,
    ): String {
        val iso = isoDate(newestUnix)
        val aheadSeconds = newestUnix - wallNowUnix
        val future = aheadSeconds > futureToleranceSeconds
        val sb = StringBuilder()
        sb.append("clockDrift newest=").append(iso)
            .append(" wall=").append(isoDate(wallNowUnix))
            .append(" newestVsWall=").append(signed(aheadSeconds)).append("s")
        if (oldestUnix != null) {
            val spanDays = maxOf(0L, newestUnix - oldestUnix) / 86_400L
            sb.append(" oldest=").append(isoDate(oldestUnix)).append(" spanDays=").append(spanDays)
        }
        sb.append(if (future) " FUTURE-DATED (strap clock ahead of wall)" else " clockOk")
        return sb.toString()
    }

    /** The firmware-layout line for a HEALTHY sync: which historical record layout the strap emits
     *  (v18/v24/v25/v26). Mirrors the Swift formatter. */
    fun firmwareLine(version: Int, decodable: Boolean): String =
        "firmware layout=v$version " +
            if (decodable) "decodable" else "UNMAPPED (no motion/HR decoded)"

    /** The trim / no-cursor sentinel line: the strap reported trim=0xFFFFFFFF, its "no valid flash
     *  cursor" marker (a clock/charge state, not a decode bug). Mirrors the Swift formatter. */
    fun noCursorLine(): String =
        "offload trim=0xFFFFFFFF noCursor (strap has no banked history to offload)"

    /** Compact ISO-8601 date-time (no fractional seconds), UTC, matching the Swift line. */
    internal fun isoDate(unix: Long): String {
        val fmt = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
        fmt.timeZone = TimeZone.getTimeZone("UTC")
        return fmt.format(Date(unix * 1000L))
    }

    /** Sign-prefixed integer so the newest-vs-wall delta reads as a signed offset. */
    internal fun signed(n: Long): String = if (n >= 0) "+$n" else "$n"
}

/**
 * Pure values for the Connection & Sync live-readout panel. Kotlin twin of the Swift ConnectionReadout.
 * Each parses the CONNECTION-tagged log tail the Connection emitters write. No state, no IO, no em-dashes.
 */
object ConnectionReadout {

    /** Connection uptime for the `connectionUptime` id, parsed from the most recent connect / disconnect
     *  line. [nowUnix] is injected so the readout is testable without a live clock. Mirrors the Swift parser. */
    fun uptimeLabel(taggedTail: List<String>, nowUnix: Long): String {
        for (line in taggedTail.asReversed()) {
            if (line.contains("connect down")) return "not connected"
            val start = longField(line, "uptimeStart=")
            if (start != null) {
                val secs = maxOf(0L, nowUnix - start)
                return durationLabel(secs)
            }
        }
        return "not connected"
    }

    /** Reconnect count for the `reconnectCount` id: the highest `reconnect n=<count>` seen in the tail.
     *  0 when no reconnect line is present. Mirrors the Swift parser. */
    fun reconnectCount(taggedTail: List<String>): Int {
        var maxN = 0
        for (line in taggedTail) {
            if (!line.contains("reconnect ")) continue
            val n = longField(line, "n=")
            if (n != null) maxN = maxOf(maxN, n.toInt())
        }
        return maxN
    }

    /** Last offload result for the `lastOffloadResult` id: the most recent "offload result=<...>"
     *  fragment. null when no offload has finished this session. Mirrors the Swift parser. */
    fun lastOffloadResult(taggedTail: List<String>): String? {
        for (line in taggedTail.asReversed()) {
            val i = line.indexOf("offload result=")
            if (i >= 0) {
                val frag = line.substring(i + "offload result=".length).trim()
                if (frag.isNotEmpty()) return frag
            }
        }
        return null
    }

    /** Parse a `key=<long>` field out of a line (value runs to the next space). null when absent/non-numeric. */
    internal fun longField(line: String, key: String): Long? {
        val i = line.indexOf(key)
        if (i < 0) return null
        val token = line.substring(i + key.length).takeWhile { it != ' ' }
        return token.toLongOrNull()
    }

    /** Short "Xm Ys" / "Xs" / "Xh Ym" duration label for the uptime readout. Mirrors the Swift labeller. */
    internal fun durationLabel(seconds: Long): String = when {
        seconds < 60 -> "${seconds}s"
        seconds < 3600 -> "${seconds / 60}m ${seconds % 60}s"
        else -> "${seconds / 3600}h ${(seconds % 3600) / 60}m"
    }
}
