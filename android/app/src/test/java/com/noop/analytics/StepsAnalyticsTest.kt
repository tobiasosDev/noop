package com.noop.analytics

import com.noop.data.StepSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Unit tests for the daily-steps derivation in AnalyticsEngine.analyzeDay: cumulative-counter
 * delta summation, u16 wraparound, sub-2-sample and cross-day filtering, and null-when-no-movement.
 * No DB; pure-function test. step_motion_counter@57 is a CUMULATIVE u16 counter, so the daily total
 * is the sum of positive consecutive deltas (APPROXIMATE — @57 semantics unverified vs the app).
 */
class StepsAnalyticsTest {

    private val profile = UserProfile()

    // A timestamp safely inside UTC day 2026-01-02 (2026-01-02T12:00:00Z = 1767355200).
    private val dayUtc = "2026-01-02"
    private val noonUtc = 1_767_355_200L

    private fun step(tsOffsetSec: Long, counter: Int) =
        StepSample(deviceId = "my-whoop", ts = noonUtc + tsOffsetSec, counter = counter)

    private fun stepsFor(samples: List<StepSample>): Int? =
        AnalyticsEngine.analyzeDay(day = dayUtc, steps = samples, profile = profile).daily.steps

    @Test
    fun sumsPositiveConsecutiveDeltas() {
        // counters 100 -> 150 -> 220 => deltas 50 + 70 = 120
        val s = listOf(step(0, 100), step(60, 150), step(120, 220))
        assertEquals(120, stepsFor(s))
    }

    @Test
    fun handlesU16Wraparound() {
        // 65500 -> 30 wraps: delta = 30 - 65500 = -65470, +65536 => 66 real steps; then 30 -> 90 => 60.
        val s = listOf(step(0, 65_500), step(60, 30), step(120, 90))
        assertEquals(66 + 60, stepsFor(s))
    }

    @Test
    fun fewerThanTwoSamplesIsNull() {
        assertNull(stepsFor(emptyList()))
        assertNull(stepsFor(listOf(step(0, 500))))
    }

    @Test
    fun noForwardMovementIsNull() {
        // Flat counter across the day => no positive delta => null (not 0).
        val s = listOf(step(0, 1_000), step(60, 1_000), step(120, 1_000))
        assertNull(stepsFor(s))
    }

    @Test
    fun dropsImplausibleResetDeltaAsReboot() {
        // 100 -> 1000 (=900 real steps), then 1000 -> 50 is a counter reset/reboot: the
        // wrap-corrected delta is 64586, implausibly large, so it is dropped rather than
        // injecting tens of thousands of phantom steps. Only the 900 counts.
        val s = listOf(step(0, 100), step(60, 1_000), step(120, 50))
        assertEquals(900, stepsFor(s))
    }

    @Test
    fun ignoresSamplesOutsideTheTargetDay() {
        // One sample 36h before the day (in the analytics window but a different UTC day) must be excluded.
        val s = listOf(step(-36 * 3_600, 5_000), step(0, 100), step(60, 300))
        assertEquals(200, stepsFor(s)) // only the in-day 100 -> 300 delta counts
    }

    @Test
    fun daySteps_overrideCountsFullCalendarDay() {
        // The night-window `steps` only sees the early part of the day; the full calendar-day stream
        // `daySteps` also carries the late-evening samples. When daySteps is supplied the daily total
        // must come from it, so late-day movement is NOT dropped (the past-day undercount fix).
        val nightWindow = listOf(step(0, 100), step(60, 300)) // early only
        val fullDay = listOf(
            step(0, 100), step(60, 300),       // morning: 200
            step(10 * 3_600, 1_000),           // evening samples present only in the full-day stream
            step(11 * 3_600, 1_700),
        )
        val total = AnalyticsEngine.analyzeDay(
            day = dayUtc, steps = nightWindow, daySteps = fullDay, profile = profile,
        ).daily.steps
        // deltas over the full day: 100->300=200, 300->1000=700, 1000->1700=700 => 1600.
        assertEquals(1_600, total)
    }

    @Test
    fun daySteps_nullFallsBackToWindowSteps() {
        // No calendar-day stream supplied (pure-function callers / old tests) -> total falls back to
        // the night-window `steps` exactly as before.
        val s = listOf(step(0, 100), step(60, 150), step(120, 220)) // 50 + 70 = 120
        assertEquals(120, AnalyticsEngine.analyzeDay(day = dayUtc, steps = s, profile = profile).daily.steps)
    }

    // MARK: - Step-scale calibration (#139). Mirrors the Swift StepsDailyTests vectors.

    private fun stepsFor(samples: List<StepSample>, ticksPerStep: Double): Int? =
        AnalyticsEngine.analyzeDay(
            day = dayUtc, steps = samples, profile = UserProfile(stepTicksPerStep = ticksPerStep),
        ).daily.steps

    @Test
    fun ticksPerStepTwoHalvesTheTotal() {
        // 120 raw ticks at 2.0 ticks/step => 60 steps.
        val s = listOf(step(0, 100), step(60, 150), step(120, 220))
        assertEquals(60, stepsFor(s, ticksPerStep = 2.0))
    }

    @Test
    fun ticksPerStepHalvingRoundsToNearest() {
        // 121 raw ticks at 2.0 => 60.5, rounded to nearest => 61.
        val s = listOf(step(0, 100), step(60, 150), step(120, 221))
        assertEquals(61, stepsFor(s, ticksPerStep = 2.0))
    }

    @Test
    fun ticksPerStepDefaultIsRawPassThrough() {
        // Default 1.0 (and an explicit 1.0) must leave the total untouched — no behavior
        // change until the user calibrates.
        val s = listOf(step(0, 100), step(60, 150), step(120, 220))
        assertEquals(120, stepsFor(s))
        assertEquals(120, stepsFor(s, ticksPerStep = 1.0))
    }

    @Test
    fun ticksPerStepClampsAtFloor() {
        // A divisor below the 0.5 floor clamps: it can at most double the total, never
        // explode it. 120 / 0.5 = 240 even when the profile says 0.1.
        val s = listOf(step(0, 100), step(60, 150), step(120, 220))
        assertEquals(240, stepsFor(s, ticksPerStep = 0.1))
    }
}
