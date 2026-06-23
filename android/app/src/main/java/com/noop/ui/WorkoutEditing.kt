package com.noop.ui

import com.noop.data.DismissedWorkout
import com.noop.data.WorkoutRow

/*
 * WorkoutEditing.kt — pure, Compose-free workout-editing logic (manual add/edit, detected-bout
 * re-label / dismiss). Kotlin mirror of macOS Strand/Data/WorkoutSource.swift, kept free of Room /
 * Compose so the unit test can pin it without an instrumented harness.
 *
 * Android's WorkoutRow carries deviceId; we still classify on `source` to stay byte-for-byte aligned
 * with the macOS read model (which has no deviceId), so a cache moved between platforms classifies
 * the same way.
 */

/** Origin of a workout row, classified from its stored `source` column. */
enum class WorkoutSource { WHOOP, APPLE, DETECTED, MANUAL, LIFTING, ACTIVITY_FILE }

object WorkoutEditing {

    /**
     * Classify a row's origin from its `source`. Order matters: the computed detected source
     * "<id>-noop" also contains "whoop", so the "-noop" suffix is checked FIRST — otherwise a
     * detected bout would read as an imported WHOOP row and become un-dismissable.
     */
    fun classify(source: String): WorkoutSource {
        val s = source.lowercase()
        return when {
            s.endsWith("-noop") -> WorkoutSource.DETECTED // BEFORE whoop: "my-whoop-noop" contains "whoop"
            s == "manual" -> WorkoutSource.MANUAL
            s == "lifting" -> WorkoutSource.LIFTING       // imported Hevy / Liftosaur strength session
            s == "activity-file" -> WorkoutSource.ACTIVITY_FILE // imported GPX / TCX / FIT activity file
            s.contains("whoop") -> WorkoutSource.WHOOP
            else -> WorkoutSource.APPLE
        }
    }

    /**
     * Sport-cell text. "detected" reads as a neutral "Activity". WHOOP sport names arrive as
     * concatenated camelCase (e.g. "TraditionalStrengthTraining"), which reads as one long
     * unbreakable word and truncates badly — split it into words on the lower→Upper boundary so it
     * renders "Traditional Strength Training". Already-spaced labels (manual/edited) pass through. (#175)
     */
    fun displaySport(sport: String): String {
        if (sport == "detected") return "Activity"
        if (sport.isEmpty() || sport.contains(" ")) return sport
        val out = StringBuilder()
        var prev: Char? = null
        for (ch in sport) {
            val p = prev
            if (p != null && ch.isUpperCase() && !p.isUpperCase()) out.append(' ')
            out.append(ch)
            prev = ch
        }
        return out.toString()
    }

    // MARK: - Dismissed detected bouts (durable across re-detection)

    /**
     * Read-time filter: a DETECTED row is hidden when it OVERLAPS any dismissed marker's
     * [startTs, endTs] span. Span-overlap (not an exact-key match) survives the small startTs drift a
     * bout's boundary can take as more HR arrives, matching the macOS dismissed-span semantics exactly.
     * Imported / manual rows are never auto-hidden (the user deletes those outright). Half-open overlap
     * test: `row.start < span.end && span.start < row.end`. (#107)
     */
    fun isDismissed(row: WorkoutRow, markers: List<DismissedWorkout>): Boolean =
        classify(row.source) == WorkoutSource.DETECTED &&
            markers.any { row.startTs < it.endTs && it.startTs < row.endTs }

    /** The durable marker for a detected [row] (caller inserts it into `dismissedWorkout`). */
    fun dismissedMarker(row: WorkoutRow): DismissedWorkout =
        DismissedWorkout(deviceId = row.deviceId, startTs = row.startTs, endTs = row.endTs)

    /**
     * Filter dismissed detected bouts out of a loaded list. Centralised so every caller agrees,
     * exactly like macOS Repository.workoutRows applies the span filter once.
     */
    fun filterDismissed(rows: List<WorkoutRow>, markers: List<DismissedWorkout>): List<WorkoutRow> {
        if (markers.isEmpty()) return rows
        return rows.filter { !isDismissed(it, markers) }
    }

    // MARK: - Cross-source dedup (#687)
    //
    // The SAME activity can land twice: once live, Bluetooth-tracked under the strap (rich — real HR
    // trace, strain, zones, route), and once imported from Health Connect / Apple Health for the same
    // window (thin — usually just duration + calories). They sit under different deviceIds/sources, so
    // the workout list shows both as separate sessions. Collapse a pair that is clearly the same bout
    // (overlapping time window + same sport) to a single richer entry. Mirrors macOS WorkoutSource
    // dedupCrossSource bound-for-bound.

    /**
     * Normalised sport key for cross-source matching. Folds the WHOOP camelCase token and a
     * human-readable import label to the same key ("TraditionalStrengthTraining" and
     * "Traditional Strength Training" -> "traditionalstrengthtraining"), case- and space-insensitive.
     */
    fun sportKey(sport: String): String =
        displaySport(sport).lowercase().filter { !it.isWhitespace() }

    /**
     * How many "rich" captured signals a row carries — the tiebreak for which duplicate to keep. A
     * live-tracked strap session scores high (HR trace, peak, strain, zones, distance); a thin import
     * scores low. Energy is the most commonly-present import field so it is weighted lowest.
     */
    fun richness(row: WorkoutRow): Int {
        var n = 0
        if (row.avgHr != null) n++
        if (row.maxHr != null) n++
        if (row.strain != null) n++
        if (!row.zonesJSON.isNullOrEmpty()) n++
        if ((row.distanceM ?: 0.0) > 0.0) n++
        if ((row.energyKcal ?: 0.0) > 0.0) n++
        return n
    }

    /**
     * True when two rows are the SAME activity from different sources: same normalised sport AND their
     * time windows overlap by more than half of the shorter session. The >50%-of-shorter test keeps two
     * genuinely back-to-back same-sport sessions distinct while still catching the small start/end drift
     * between a live capture and its import.
     */
    fun sameActivity(a: WorkoutRow, b: WorkoutRow): Boolean {
        if (sportKey(a.sport) != sportKey(b.sport)) return false
        val overlap = minOf(a.endTs, b.endTs) - maxOf(a.startTs, b.startTs)
        if (overlap <= 0) return false
        val shorter = maxOf(1L, minOf(a.endTs - a.startTs, b.endTs - b.startTs))
        return overlap.toDouble() > 0.5 * shorter.toDouble()
    }

    /**
     * Of two same-activity rows, the one to KEEP. Prefer the richer (more captured signals); on a tie
     * prefer the strap-native source (live/manual/detected/whoop carry the real trace) over a thin
     * import (Apple Health / Health Connect); final tie -> the longer session, then [a] (stable).
     */
    fun preferred(a: WorkoutRow, b: WorkoutRow): WorkoutRow {
        val ra = richness(a)
        val rb = richness(b)
        if (ra != rb) return if (ra > rb) a else b
        val ia = classify(a.source) == WorkoutSource.APPLE
        val ib = classify(b.source) == WorkoutSource.APPLE
        if (ia != ib) return if (ia) b else a // keep the non-import on a richness tie
        val da = a.endTs - a.startTs
        val db = b.endTs - b.startTs
        if (da != db) return if (da > db) a else b
        return a
    }

    /**
     * Collapse cross-source duplicates of the same activity, keeping the richer row of each pair.
     * Order-stable: walks the input once, and a row that duplicates one already kept is dropped (with
     * the kept row swapped for the richer of the two). Single-source lists pass through unchanged.
     */
    fun dedupCrossSource(rows: List<WorkoutRow>): List<WorkoutRow> {
        val kept = ArrayList<WorkoutRow>(rows.size)
        outer@ for (row in rows) {
            for (i in kept.indices) {
                if (sameActivity(kept[i], row)) {
                    kept[i] = preferred(kept[i], row)
                    continue@outer
                }
            }
            kept.add(row)
        }
        return kept
    }

    // MARK: - Building / preserving rows

    /**
     * Carry the captured fields the add/edit sheet does NOT expose (maxHr, strain, distanceM,
     * zonesJSON, notes, routePolyline) over from the row being edited. A live-tracked session has real
     * captured strain/maxHr/route; rebuilding from the sheet's inputs alone would wipe them on an edit.
     * No-op for a fresh add (old == null).
     */
    fun preservingCaptured(row: WorkoutRow, old: WorkoutRow?): WorkoutRow {
        if (old == null) return row
        return row.copy(
            maxHr = old.maxHr,
            strain = old.strain,
            distanceM = old.distanceM,
            zonesJSON = old.zonesJSON,
            notes = old.notes,
            routePolyline = old.routePolyline,
        )
    }

    /**
     * Build a retroactive manual workout (source "manual", written under the strap [deviceId] by the
     * caller — where live sessions land). Returns null when the input can't make an honest row.
     * strain/zones stay null: with no captured HR window an APPROXIMATE strain is never fabricated.
     * Mirrors macOS WorkoutSource.buildManualRow validation bound-for-bound.
     *
     * @param startSeconds workout start, unix seconds.
     * @param nowSeconds wall-clock now (unix seconds); injectable for tests.
     */
    fun buildManualRow(
        deviceId: String,
        startSeconds: Long,
        durationMin: Int,
        sport: String,
        avgHr: Int?,
        energyKcal: Double?,
        nowSeconds: Long = System.currentTimeMillis() / 1000L,
    ): WorkoutRow? {
        if (durationMin <= 0 || durationMin > 24 * 60) return null
        val trimmed = sport.trim()
        if (trimmed.isEmpty() || startSeconds > nowSeconds || startSeconds <= 0) return null
        if (avgHr != null && avgHr !in 25..250) return null
        if (energyKcal != null && (energyKcal < 0 || energyKcal > 20_000)) return null
        return WorkoutRow(
            deviceId = deviceId,
            startTs = startSeconds,
            endTs = startSeconds + durationMin * 60L,
            sport = trimmed,
            source = "manual",
            durationS = durationMin * 60.0,
            energyKcal = energyKcal,
            avgHr = avgHr,
            maxHr = null,
            strain = null,
            distanceM = null,
            zonesJSON = null,
            notes = null,
            routePolyline = null,
        )
    }

    /** Common sports offered when re-labelling a detected bout (the user can fine-tune via Edit). */
    val relabelSports: List<String> = listOf(
        "Running", "Walking", "Cycling", "Strength Training", "Swimming", "Rowing", "Yoga", "HIIT",
        "CrossFit", "Hiking", "Tennis",
    )
}
