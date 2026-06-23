package com.noop.ui

import com.noop.data.DismissedWorkout
import com.noop.data.WorkoutRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the pure workout-editing logic (manual add/edit, detected-bout re-label / dismiss). Kotlin
 * mirror of the macOS WorkoutSourceTests case-for-case: source classification, the durable
 * dismissed-marker filter that keeps a re-detected bout hidden (#107), manual-row validation, and
 * field preservation on edit.
 */
class WorkoutEditingTest {

    private fun row(
        deviceId: String,
        start: Long,
        end: Long,
        sport: String,
        source: String,
        avgHr: Int? = null,
        maxHr: Int? = null,
        strain: Double? = null,
    ) = WorkoutRow(
        deviceId = deviceId, startTs = start, endTs = end, sport = sport, source = source,
        durationS = (end - start).toDouble(), energyKcal = null, avgHr = avgHr, maxHr = maxHr,
        strain = strain,
    )

    // MARK: - classify

    @Test
    fun classify_ordersNoopBeforeWhoop() {
        // "my-whoop-noop" contains "whoop" — the -noop suffix MUST win, else a detected bout would
        // classify as imported WHOOP and become un-dismissable.
        assertEquals(WorkoutSource.DETECTED, WorkoutEditing.classify("my-whoop-noop"))
        assertEquals(WorkoutSource.WHOOP, WorkoutEditing.classify("whoop"))
        assertEquals(WorkoutSource.MANUAL, WorkoutEditing.classify("manual"))
        assertEquals(WorkoutSource.LIFTING, WorkoutEditing.classify("lifting"))
        assertEquals(WorkoutSource.ACTIVITY_FILE, WorkoutEditing.classify("activity-file"))
        assertEquals(WorkoutSource.APPLE, WorkoutEditing.classify("apple-health"))
        assertEquals(WorkoutSource.APPLE, WorkoutEditing.classify("Apple Health"))
    }

    @Test
    fun displaySport_renamesDetectedToken() {
        assertEquals("Activity", WorkoutEditing.displaySport("detected"))
        assertEquals("Running", WorkoutEditing.displaySport("Running"))
    }

    // MARK: - dismissed markers (durable #107 filter)

    @Test
    fun isDismissed_onlyHidesOverlappingDetectedRows() {
        val markers = listOf(DismissedWorkout("my-whoop-noop", 1000, 2000))
        val detectedOverlap = row("my-whoop-noop", 1500, 2500, "detected", "my-whoop-noop")
        val detectedClear = row("my-whoop-noop", 3000, 4000, "detected", "my-whoop-noop")
        val manualOverlap = row("my-whoop", 1500, 2500, "Running", "manual")
        assertTrue(WorkoutEditing.isDismissed(detectedOverlap, markers))
        assertFalse(WorkoutEditing.isDismissed(detectedClear, markers))
        // A manual (or imported) row is NEVER auto-hidden by a marker — only detected bouts.
        assertFalse(WorkoutEditing.isDismissed(manualOverlap, markers))
    }

    @Test
    fun isDismissed_survivesStartTsDrift() {
        // A re-detected bout whose boundary drifted a little still overlaps the dismissed span.
        val markers = listOf(DismissedWorkout("my-whoop-noop", 1000, 2000))
        val drifted = row("my-whoop-noop", 1040, 2030, "detected", "my-whoop-noop")
        assertTrue(WorkoutEditing.isDismissed(drifted, markers))
    }

    @Test
    fun filterDismissed_removesOnlyMarkedDetected() {
        val detectedA = row("my-whoop-noop", 1000, 2000, "detected", "my-whoop-noop")
        val detectedB = row("my-whoop-noop", 3000, 4000, "detected", "my-whoop-noop")
        val imported = row("my-whoop", 1000, 2000, "Running", "whoop")
        val markers = listOf(WorkoutEditing.dismissedMarker(detectedA))
        val out = WorkoutEditing.filterDismissed(listOf(detectedA, detectedB, imported), markers)
        // detectedA is hidden; detectedB and the imported row survive.
        assertEquals(listOf(detectedB, imported), out)
    }

    @Test
    fun filterDismissed_noMarkers_isIdentity() {
        val rows = listOf(row("my-whoop-noop", 1000, 2000, "detected", "my-whoop-noop"))
        assertEquals(rows, WorkoutEditing.filterDismissed(rows, emptyList()))
    }

    @Test
    fun dismissedMarker_capturesSpan() {
        val r = row("my-whoop-noop", 1_700_000_000, 1_700_003_600, "detected", "my-whoop-noop")
        val m = WorkoutEditing.dismissedMarker(r)
        assertEquals(DismissedWorkout("my-whoop-noop", 1_700_000_000, 1_700_003_600), m)
    }

    // MARK: - cross-source dedup (#687)

    // A live strap session: HR trace, peak, strain, zones, distance, energy all captured.
    private fun richRow(start: Long, end: Long, sport: String, source: String) = WorkoutRow(
        deviceId = "my-whoop", startTs = start, endTs = end, sport = sport, source = source,
        durationS = (end - start).toDouble(), energyKcal = 600.0, avgHr = 150, maxHr = 178,
        strain = 14.0, distanceM = 10_000.0, zonesJSON = "{\"z1\":10}",
    )

    // A thin Health Connect / Apple import: only duration + calories.
    private fun thinImport(start: Long, end: Long, sport: String, source: String) = WorkoutRow(
        deviceId = "health-connect", startTs = start, endTs = end, sport = sport, source = source,
        durationS = (end - start).toDouble(), energyKcal = 590.0,
    )

    @Test
    fun sportKey_foldsCamelCaseAndSpacing() {
        assertEquals(
            WorkoutEditing.sportKey("TraditionalStrengthTraining"),
            WorkoutEditing.sportKey("Traditional Strength Training"),
        )
        assertEquals(WorkoutEditing.sportKey("Running"), WorkoutEditing.sportKey("running"))
        assertNotEquals(WorkoutEditing.sportKey("Running"), WorkoutEditing.sportKey("Cycling"))
    }

    @Test
    fun sameActivity_requiresSportAndMajorityOverlap() {
        val live = richRow(1000, 4600, "Running", "whoop")              // 60 min
        val importDrift = thinImport(1040, 4570, "Running", "health-connect")
        assertTrue(WorkoutEditing.sameActivity(live, importDrift))       // same sport, near-full overlap
        // Different sport in the same window is NOT the same activity.
        val otherSport = thinImport(1040, 4570, "Cycling", "health-connect")
        assertFalse(WorkoutEditing.sameActivity(live, otherSport))
        // Back-to-back same-sport sessions that only touch at the edge stay distinct (<50% overlap).
        val nextRun = richRow(4500, 8100, "Running", "whoop")
        assertFalse(WorkoutEditing.sameActivity(live, nextRun))
    }

    @Test
    fun dedupCrossSource_collapsesLiveAndImportKeepingRicher() {
        val live = richRow(1000, 4600, "Running", "whoop")
        val hc = thinImport(1030, 4580, "Running", "health-connect")
        // Order shouldn't matter — the richer (live) row always survives.
        val a = WorkoutEditing.dedupCrossSource(listOf(live, hc))
        val b = WorkoutEditing.dedupCrossSource(listOf(hc, live))
        assertEquals(1, a.size)
        assertEquals(1, b.size)
        assertEquals("whoop", a.first().source)
        assertEquals("whoop", b.first().source)
        assertEquals(14.0, a.first().strain!!, 1e-9) // kept the row with the captured trace
    }

    @Test
    fun dedupCrossSource_keepsNonImportOnRichnessTie() {
        // Two equally-thin rows: a strap "manual" live row and a Health Connect import. Keep the strap one.
        val manual = thinImport(1000, 4600, "Walking", "manual")
        val hc = thinImport(1010, 4590, "Walking", "health-connect")
        val out = WorkoutEditing.dedupCrossSource(listOf(hc, manual))
        assertEquals(1, out.size)
        assertEquals("manual", out.first().source)
    }

    @Test
    fun dedupCrossSource_leavesDistinctSessionsAndIsStable() {
        val run = richRow(1000, 4600, "Running", "whoop")
        val lift = richRow(5000, 8600, "Strength Training", "whoop")
        val hcRun = thinImport(1020, 4580, "Running", "health-connect")
        val out = WorkoutEditing.dedupCrossSource(listOf(run, lift, hcRun))
        // The run pair collapses to one; the lift is untouched. Two sessions, original order preserved.
        assertEquals(2, out.size)
        assertEquals("Running", out[0].sport)
        assertEquals("Strength Training", out[1].sport)
    }

    // MARK: - buildManualRow validation

    @Test
    fun buildManualRow_happyPath() {
        val now = 1_700_003_600L
        val r = WorkoutEditing.buildManualRow(
            deviceId = "my-whoop", startSeconds = 1_700_000_000L, durationMin = 45,
            sport = "  Running ", avgHr = 150, energyKcal = 540.0, nowSeconds = now,
        )
        requireNotNull(r)
        assertEquals("Running", r.sport)        // trimmed
        assertEquals("manual", r.source)
        assertEquals("my-whoop", r.deviceId)
        assertEquals(45 * 60.0, r.durationS!!, 1e-9)
        assertEquals(r.startTs + 45 * 60L, r.endTs)
        assertEquals(150, r.avgHr)
        assertNull(r.strain)                      // never fabricated without a captured HR window
    }

    @Test
    fun buildManualRow_rejectsBadInput() {
        val start = 1_700_000_000L
        val now = start + 3600
        assertNull(WorkoutEditing.buildManualRow("my-whoop", start, 0, "Run", null, null, now))
        assertNull(WorkoutEditing.buildManualRow("my-whoop", start, 25 * 60, "Run", null, null, now))
        assertNull(WorkoutEditing.buildManualRow("my-whoop", start, 30, "   ", null, null, now))
        // Future start.
        assertNull(WorkoutEditing.buildManualRow("my-whoop", now + 60, 30, "Run", null, null, now))
        // Out-of-range HR / kcal.
        assertNull(WorkoutEditing.buildManualRow("my-whoop", start, 30, "Run", 10, null, now))
        assertNull(WorkoutEditing.buildManualRow("my-whoop", start, 30, "Run", null, 99_999.0, now))
    }

    // MARK: - preservingCaptured

    @Test
    fun preservingCaptured_carriesUnexposedFieldsOnEdit() {
        val old = row("my-whoop", 100, 3700, "Workout", "manual", avgHr = 130, maxHr = 175, strain = 13.5)
        val rebuilt = row("my-whoop", 100, 3700, "Running", "manual", avgHr = 140)
        val merged = WorkoutEditing.preservingCaptured(rebuilt, old)
        assertEquals("Running", merged.sport) // edited field kept
        assertEquals(140, merged.avgHr)       // edited field kept
        assertEquals(175, merged.maxHr)       // carried over
        assertEquals(13.5, merged.strain!!, 1e-9) // carried over
    }

    @Test
    fun preservingCaptured_noOpForFreshAdd() {
        val rebuilt = row("my-whoop", 100, 3700, "Running", "manual", avgHr = 140)
        assertEquals(rebuilt, WorkoutEditing.preservingCaptured(rebuilt, null))
    }
}
