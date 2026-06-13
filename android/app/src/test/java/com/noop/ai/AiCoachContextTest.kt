package com.noop.ai

import com.noop.data.DailyMetric
import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

/**
 * Pins the #124 fix: the coach grounds itself in the MERGED raw+computed daily view
 * ([WhoopRepository.daysMerged]) — the same per-field-coalesce path every screen reads — so a
 * strap-only user whose scores live under the computed "my-whoop-noop" source gets real numbers
 * in the context instead of the no-data sentinel.
 *
 * Exercises the pure [AiCoach.buildContext] on lists shaped by the real
 * [WhoopRepository.Companion.mergeDaily]. The repository behind the coach is a throwing stub,
 * which doubles as proof the context builder never touches storage.
 */
class AiCoachContextTest {

    /** AiCoach whose repository throws on ANY dao call — buildContext must stay pure. */
    private fun coach(): AiCoach {
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, _ ->
            throw UnsupportedOperationException("buildContext must not touch the repo (${method.name})")
        } as WhoopDao
        return AiCoach(WhoopRepository(dao))
    }

    /** A fully populated on-device computed day — what IntelligenceEngine writes for strap-only users. */
    private fun computedRow(day: String) = DailyMetric(
        deviceId = "my-whoop-noop",
        day = day,
        totalSleepMin = 450.0, // 7.5h
        restingHr = 52,
        avgHrv = 65.0,
        recovery = 67.0,
        strain = 12.3,
    )

    /** Consecutive June days, oldest first (lexicographic = chronological for YYYY-MM-DD). */
    private fun june(dayOfMonth: Int) = "2026-06-%02d".format(dayOfMonth)

    /**
     * The #124 shape: a live-strap user has NO imported rows at all; every score sits under the
     * computed source. The merged list must carry those numbers into the context — never the
     * "no synced days" sentinel the raw read used to produce.
     */
    @Test
    fun computedOnlyMergedDaysGroundTheCoachInRealNumbers() {
        val merged = WhoopRepository.mergeDaily(
            imported = emptyList(),
            computed = (1..14).map { computedRow(june(it)) },
        )
        assertEquals(14, merged.size)

        val ctx = coach().buildContext(merged)

        // Real figures, exactly as buildContext formats them.
        assertTrue("daily recovery", ctx.contains("charge 67%"))
        assertTrue("daily strain", ctx.contains("effort 12.3"))
        assertTrue("daily sleep", ctx.contains("rest 7.5h"))
        assertTrue("daily HRV", ctx.contains("HRV 65ms"))
        assertTrue("daily RHR", ctx.contains("RHR 52bpm"))
        assertTrue(
            "latest snapshot",
            ctx.contains("Most recent day (${june(14)}): charge 67%, effort 12.3."),
        )
        // The #124 symptom: with data present the no-data sentinel must NOT appear.
        assertFalse("no-data sentinel leaked", ctx.contains("No wearable data is available yet"))
    }

    /**
     * Sparse import, no computed source: sleep is recorded but recovery/strain/HRV/RHR never are.
     * Missing values must render as dashes / "n/a" — the context must not invent a score.
     */
    @Test
    fun sparseRawOnlyDaysRenderDashesNotInventedNumbers() {
        val merged = WhoopRepository.mergeDaily(
            imported = (1..14).map {
                DailyMetric(deviceId = "my-whoop", day = june(it), totalSleepMin = 420.0) // 7h
            },
            computed = emptyList(),
        )

        val ctx = coach().buildContext(merged)

        // Sleep is real; everything unrecorded is a dash on every daily line.
        assertTrue("daily dashes", ctx.contains("charge -, effort -, rest 7h, HRV -, RHR -"))
        assertTrue("latest snapshot n/a", ctx.contains("charge n/a, effort n/a"))
        // Never an invented score: no digit ever follows "recovery " or "HRV ".
        assertFalse("invented charge", Regex("charge \\d").containsMatchIn(ctx))
        assertFalse("invented HRV", Regex("HRV \\d").containsMatchIn(ctx))
        // Data exists (sleep), so the no-data sentinel is still wrong here.
        assertFalse("no-data sentinel leaked", ctx.contains("No wearable data is available yet"))
    }
}
