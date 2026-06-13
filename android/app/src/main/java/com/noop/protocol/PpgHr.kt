package com.noop.protocol

/**
 * Derive heart rate from the WHOOP 5.0/MG **v26** optical PPG waveform (#156).
 *
 * The strap's type-47 **layout v26** record is a 24 Hz PPG buffer — NOT a per-second biometric
 * summary like v18: **24 little-endian i16 samples at frame bytes [27:75]**, one record per second,
 * with the record's own unix u32 LE @15 (the same slot v18 uses). WHOOP does NOT store a per-second
 * HR in v26 — HR is PPG-derived on-device — so to recover HR we re-derive it here from the waveform,
 * exactly the way the Swift PPG->HR lane does. (Provenance: the concatenated waveform's
 * autocorrelation peaks at the heart rate; verified against HR as internal ground truth — lag 14 ≈
 * 102.9 bpm vs a measured 101.7 bpm. See WhoopProtocol/Interpreter.swift `decodeWhoop5HistoricalV26`
 * and tools/linux-capture/analyze_v26_waveform.py.)
 *
 * Algorithm (mirror of the Swift estimator — keep the constants in lockstep across platforms):
 *   • Sample rate 24 Hz, window 8 s (192 samples), hop 1 s (24 samples).
 *   • Per window: mean-remove (DC), then normalised autocorrelation; search the lag range that maps
 *     to **30…220 bpm**; pick the strongest non-trivial peak.
 *   • Confidence = the normalised autocorrelation value at that lag (0…1). Emit only when
 *     **conf >= 0.3** — a clean pulse autocorrelates strongly; noise does not, so a noisy/limp window
 *     yields nothing rather than a fabricated bpm.
 *   • bpm = 60 * fs / lag, rounded; the window's timestamp is its CENTRE second.
 *
 * Pure + side-effect-free so it is unit-testable on synthetic signals (see PpgHrTest).
 */
object PpgHr {
    /** PPG sample rate of the v26 waveform (Hz). */
    const val SAMPLE_RATE_HZ = 24

    /** HR estimation window length in seconds. */
    const val WINDOW_SECONDS = 8

    /** Window hop in seconds (one estimate per second of overlap-slid window). */
    const val HOP_SECONDS = 1

    /** Physiological HR search bounds (bpm). */
    const val MIN_BPM = 30.0
    const val MAX_BPM = 220.0

    /** Minimum normalised-autocorrelation confidence to emit an estimate. */
    const val MIN_CONFIDENCE = 0.3

    private const val WINDOW_SAMPLES = SAMPLE_RATE_HZ * WINDOW_SECONDS // 192
    private const val HOP_SAMPLES = SAMPLE_RATE_HZ * HOP_SECONDS       // 24

    /**
     * One concatenated, time-ordered PPG sample: its wall-clock second [ts] and raw ADC [value].
     * Built from contiguous v26 records (each record contributes 24 samples spanning one second).
     */
    data class Sample(val ts: Long, val value: Int)

    /** A derived HR estimate: [ts] = window-centre second, [bpm], [conf] in 0…1. */
    data class Estimate(val ts: Long, val bpm: Int, val conf: Double)

    /**
     * Slide an 8 s / 24 Hz window across the concatenated [samples] and emit one [Estimate] per
     * hop whose autocorrelation confidence clears [MIN_CONFIDENCE].
     *
     * [samples] MUST be in ascending time order and densely sampled at 24 Hz (gaps across record
     * boundaries are tolerated — the window simply spans whatever 192 consecutive samples it holds;
     * a window straddling a large time gap will autocorrelate poorly and be dropped by the
     * confidence gate). Each window's timestamp is the [ts] of its centre sample.
     */
    fun estimate(samples: List<Sample>): List<Estimate> {
        if (samples.size < WINDOW_SAMPLES) return emptyList()
        val out = ArrayList<Estimate>()
        var start = 0
        while (start + WINDOW_SAMPLES <= samples.size) {
            val window = DoubleArray(WINDOW_SAMPLES) { samples[start + it].value.toDouble() }
            val centreTs = samples[start + WINDOW_SAMPLES / 2].ts
            val est = estimateWindow(window, centreTs)
            if (est != null) out.add(est)
            start += HOP_SAMPLES
        }
        return out
    }

    /**
     * Estimate HR for a single mean-removed window via normalised autocorrelation. Returns null when
     * the window is flat (zero variance) or the best peak's confidence is below [MIN_CONFIDENCE].
     *
     * Lag range: a faster HR is a SHORTER lag, so [MAX_BPM] -> minLag and [MIN_BPM] -> maxLag.
     * maxLag is clamped to N-1 so the autocorrelation always has at least one overlapping sample.
     */
    private fun estimateWindow(window: DoubleArray, ts: Long): Estimate? {
        val n = window.size
        // DC removal: subtract the mean so the autocorrelation reflects the AC (pulsatile) component.
        var mean = 0.0
        for (v in window) mean += v
        mean /= n
        val x = DoubleArray(n) { window[it] - mean }

        // Zero-lag energy (the autocorrelation normaliser). A flat window has zero energy -> no HR.
        var energy = 0.0
        for (v in x) energy += v * v
        if (energy <= 0.0) return null

        val fs = SAMPLE_RATE_HZ.toDouble()
        // bpm = 60*fs/lag  =>  lag = 60*fs/bpm.  Higher bpm => smaller lag.
        val minLag = maxOf(1, Math.floor(60.0 * fs / MAX_BPM).toInt())
        val maxLag = minOf(n - 1, Math.ceil(60.0 * fs / MIN_BPM).toInt())
        if (minLag > maxLag) return null

        var bestLag = -1
        var bestCorr = 0.0
        for (lag in minLag..maxLag) {
            var acc = 0.0
            var i = 0
            val limit = n - lag
            while (i < limit) {
                acc += x[i] * x[i + lag]
                i++
            }
            val norm = acc / energy // normalised autocorrelation in [-1, 1]
            if (norm > bestCorr) {
                bestCorr = norm
                bestLag = lag
            }
        }
        if (bestLag < 0 || bestCorr < MIN_CONFIDENCE) return null

        val bpm = (60.0 * fs / bestLag).let { Math.round(it).toInt() }
        if (bpm < MIN_BPM.toInt() || bpm > MAX_BPM.toInt()) return null
        return Estimate(ts = ts, bpm = bpm, conf = bestCorr)
    }
}
