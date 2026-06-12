package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** #137 — the pure re-score logic: recompute an under-sampled manual workout's metrics from the
 *  denser HR now available for its window, conservatively and idempotently. */
class ManualWorkoutRescoreTest {

    private val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 30.0, sex = "male")
    private fun window(n: Int, bpm: Int) = (0 until n).map { HrSample("my-whoop", 1_000L + it, bpm) }

    @Test fun scoresDenseWindow() {
        val s = ManualWorkoutRescore.scored(window(1200, 140), profile, hrMax = 190.0)
        assertNotNull(s); s!!
        assertEquals(140, s.avgHr)
        assertEquals(140, s.maxHr)
        assertNotNull(s.kcal)
        assertTrue("a 20-min Z3 bout burns well over 50 kcal", (s.kcal ?: 0.0) > 50.0)
        assertNotNull(s.strain)
    }

    @Test fun tooFewSamplesReturnsNull() {
        assertNull(ManualWorkoutRescore.scored(window(1, 130), profile, 190.0))
        assertNull(ManualWorkoutRescore.scored(emptyList(), profile, 190.0))
    }

    @Test fun looksUnderScoredGate() {
        assertTrue(ManualWorkoutRescore.looksUnderScored(null))
        assertTrue(ManualWorkoutRescore.looksUnderScored(1.0))   // the "1 kcal" symptom
        assertTrue(ManualWorkoutRescore.looksUnderScored(5.0))
        assertFalse(ManualWorkoutRescore.looksUnderScored(5.01))
        assertFalse(ManualWorkoutRescore.looksUnderScored(250.0))
    }

    @Test fun improvesIsStrictAndMonotonic() {
        val big = ManualWorkoutRescore.Scored(avgHr = 140, maxHr = 150, strain = 12.0, kcal = 220.0)
        assertTrue(ManualWorkoutRescore.improves(big, null))
        assertTrue(ManualWorkoutRescore.improves(big, 1.0))
        assertFalse(ManualWorkoutRescore.improves(big, 220.0))   // already this good → no churn
        assertFalse(ManualWorkoutRescore.improves(big, 219.5))   // within margin → no churn

        val none = ManualWorkoutRescore.Scored(avgHr = 0, maxHr = 0, strain = null, kcal = null)
        assertFalse(ManualWorkoutRescore.improves(none, 1.0))    // no recompute ⇒ never replace
    }

    @Test fun underScoredWorkoutGetsRescoredAndIsIdempotent() {
        val stored = 1.0
        assertTrue(ManualWorkoutRescore.looksUnderScored(stored))
        val s = ManualWorkoutRescore.scored(window(900, 150), profile, 190.0)!!
        assertTrue(ManualWorkoutRescore.improves(s, stored))
        assertFalse(ManualWorkoutRescore.improves(s, s.kcal))   // re-running over the good value is a no-op
    }
}
