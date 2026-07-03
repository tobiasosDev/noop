package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * #797: the bounded dashboard merge ([WhoopRepository.recentDaysMergedFlow]) caps each source to the
 * most-recent RECENT_DAYS_CAP rows via a `ORDER BY day DESC LIMIT` read, then merges. This pins the
 * correctness guarantee that makes that safe: [WhoopRepository.mergeDaily] is INPUT-ORDER-INDEPENDENT and
 * always returns oldest-first, so feeding it the newest-first (DESC) page still emits the SAME oldest-first
 * order every dashboard consumer expects. Pure (no Room): exercises the companion merge directly.
 */
class RecentDaysMergeOrderTest {

    private fun row(day: String, source: String, asleep: Double) =
        DailyMetric(deviceId = source, day = day, totalSleepMin = asleep)

    @Test
    fun mergeDailyReturnsOldestFirstRegardlessOfInputOrder() {
        // Simulate the DESC LIMIT read: rows arrive NEWEST-first (as recentDaysFlow returns them).
        val importedDesc = listOf(
            row("2026-06-14", "my-whoop", 540.0),
            row("2026-06-13", "my-whoop", 530.0),
            row("2026-06-12", "my-whoop", 520.0),
        )
        val merged = WhoopRepository.mergeDaily(imported = importedDesc, computed = emptyList())
        assertEquals(listOf("2026-06-12", "2026-06-13", "2026-06-14"), merged.map { it.day })
    }

    @Test
    fun computedGapFillsWithinTheBoundedWindowOldestFirst() {
        // A bounded window where the import covers only the newest day and the computed source fills the
        // rest. Order out is still oldest-first, and the import wins its day.
        val importedDesc = listOf(row("2026-06-14", "my-whoop", 540.0))
        val computedDesc = listOf(
            row("2026-06-14", "my-whoop-noop", 999.0), // shadowed by the import on this day
            row("2026-06-13", "my-whoop-noop", 470.0),
            row("2026-06-12", "my-whoop-noop", 460.0),
        )
        val merged = WhoopRepository.mergeDaily(imported = importedDesc, computed = computedDesc)
        assertEquals(listOf("2026-06-12", "2026-06-13", "2026-06-14"), merged.map { it.day })
        // Import wins its covered day; computed fills the others.
        assertEquals(540.0, merged.first { it.day == "2026-06-14" }.totalSleepMin)
        assertEquals(460.0, merged.first { it.day == "2026-06-12" }.totalSleepMin)
    }

    @Test
    fun recentDaysCapIsAGenerousBound() {
        // Guards against an accidental too-small cap that would drop the deepest Trends range. ~2 years.
        assert(WhoopRepository.RECENT_DAYS_CAP >= 730) {
            "RECENT_DAYS_CAP must cover the deepest dashboard range"
        }
    }
}
