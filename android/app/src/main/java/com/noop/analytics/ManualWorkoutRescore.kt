package com.noop.analytics

import com.noop.data.HrSample

/**
 * Re-score a manual workout's HR-derived metrics (avg/peak HR, strain, calories) from the HR samples
 * now available for its time window.
 *
 * Why: a manually-started workout is scored at *save* time from the live HR captured during the
 * session. On a WHOOP 5.0/MG the live stream is sparse, so only a handful of samples land in the
 * window — calories collapse toward ~1 kcal, the average is off, and strain is empty (#137). The strap
 * banks its own HR to flash and offloads it on the next sync; once that denser HR covers the window,
 * this recomputes from it.
 *
 * Pure + deterministic (no DB, no I/O) so it's unit-tested directly. The caller (the post-sync scoring
 * pass) decides which workouts to feed it — under-scored `manual` ones — reads the window's HR, and
 * only persists a genuine improvement. The formulas mirror `AppViewModel.endWorkout` exactly (same
 * [StrainScorer] + [Calories.estimateBoutCalories]).
 */
object ManualWorkoutRescore {

    data class Scored(val avgHr: Int, val maxHr: Int, val strain: Double?, val kcal: Double?)

    /** At/under this many kcal a manual workout looks like the #137 symptom (no/negligible energy). */
    const val UNDER_SCORED_KCAL_THRESHOLD = 5.0
    /** A rescore must beat the stored calories by at least this to be persisted — so a still-sparse
     *  window (recompute ≈ current) is a no-op and the pass is idempotent. */
    const val IMPROVEMENT_MARGIN_KCAL = 1.0

    /** Does this manual workout currently look under-scored? The gate the post-sync pass uses so a
     *  well-scored workout (a 4.0's dense live HR) is never touched. */
    fun looksUnderScored(currentKcal: Double?): Boolean =
        (currentKcal ?: 0.0) <= UNDER_SCORED_KCAL_THRESHOLD

    /** Recompute avg/peak HR, strain and calories from [windowSamples] (the HR now stored for the
     *  workout's [start, end]). Returns null when there are too few samples to score meaningfully. */
    fun scored(windowSamples: List<HrSample>, profile: UserProfile, hrMax: Double): Scored? {
        if (windowSamples.size < 2) return null
        val bpms = windowSamples.map { it.bpm }
        // Integer mean, matching AppViewModel.endWorkout (Android truncates; iOS rounds — each mirrors
        // its own platform's save-time formula).
        val avg = bpms.sum() / bpms.size
        val peak = bpms.maxOrNull() ?: 0
        val strain = StrainScorer.strain(windowSamples, maxHR = hrMax, sex = profile.sex)
        val kcalRaw = Calories.estimateBoutCalories(windowSamples, profile, hrMax, null).first
        return Scored(avg, peak, strain, if (kcalRaw > 0) kcalRaw else null)
    }

    /** Is [scored] a worthwhile improvement over the stored calories? Strictly more energy (denser HR
     *  ⇒ higher), so a sparse-window recompute that lands ≈ current is rejected — idempotent, and it
     *  can never *lower* a workout's numbers. */
    fun improves(scored: Scored, currentKcal: Double?): Boolean {
        val newK = scored.kcal ?: return false
        return newK > (currentKcal ?: 0.0) + IMPROVEMENT_MARGIN_KCAL
    }
}
