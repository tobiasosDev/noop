import Foundation

// ScoreConfidence.swift — per-score certainty tier for Charge / Effort / Rest.
//
// Each daily score rides a confidence tier so a sparse 5/MG day (or a cold-start
// baseline) reads truthfully instead of faking a number. Surfaced as a small
// label/dot under each score; the score itself stays nil-honest where it can't
// compute at all.
//
// Tiers (ordered lowest → highest):
//   .calibrating — the baseline/seed isn't usable yet, or the core input window is
//                  absent (no HR window for Effort, no in-bed data for Rest, HRV
//                  baseline not yet usable for Charge). The number, if shown, is a
//                  placeholder.
//   .building    — usable but thin: enough to compute, but the baseline is still
//                  provisional or the inputs are partial (e.g. a day backed mostly by
//                  PPG-derived HR, or a short baseline history).
//   .solid       — full inputs present and the baseline is trusted.
//
// Kept deliberately small and dependency-free so the Kotlin mirror is byte-identical.
public enum ScoreConfidence: String, Equatable, Sendable, Codable {
    case calibrating
    case building
    case solid

    // MARK: - Derivations (one per score; mirror the Android helpers exactly)

    /// Charge (recovery) confidence.
    /// - calibrating: no score (HRV baseline not usable / cold-start) → the number is absent.
    /// - solid:       a score exists AND the HRV baseline is fully trusted.
    /// - building:    a score exists but the HRV baseline is only provisional.
    public static func charge(recovery: Double?, hrvBaseline: BaselineState?) -> ScoreConfidence {
        guard recovery != nil, let b = hrvBaseline, b.usable else { return .calibrating }
        return b.trusted ? .solid : .building
    }

    /// Effort (strain) confidence.
    /// - calibrating: no score (no usable HR window) → absent.
    /// - solid:       a score exists AND the HR window is dense (≥ solidReadings samples).
    /// - building:    a score exists but the HR window is thin (PPG-backed / short day).
    public static let solidEffortReadings: Int = 3600  // ~1 h at 1 Hz of HR coverage
    public static func effort(strain: Double?, hrSampleCount: Int) -> ScoreConfidence {
        guard strain != nil else { return .calibrating }
        return hrSampleCount >= solidEffortReadings ? .solid : .building
    }

    /// Rest (sleep) confidence.
    /// - calibrating: no in-bed data (no matched session) → absent.
    /// - solid:       a session exists AND every Rest component had real input
    ///                (staged sleep present so restorative + efficiency are real).
    /// - building:    a session exists but stages/inputs are partial.
    public static func rest(hasSession: Bool, hasStagedSleep: Bool) -> ScoreConfidence {
        guard hasSession else { return .calibrating }
        return hasStagedSleep ? .solid : .building
    }
}
