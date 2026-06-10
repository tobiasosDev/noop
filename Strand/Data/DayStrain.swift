import Foundation
import StrandAnalytics
import WhoopStore

/// Intraday ("so far today") strain from the raw 1 Hz HR stream. Shared by the
/// Today strain-coach card and the Live strip so the number can never disagree.
enum DayStrain {
    /// nil when under StrainScorer.minReadings (~10 min of samples) — callers show pending.
    /// The day is aggregated to a bpm histogram in SQL (≤ ~200 bins) instead of loading the
    /// up-to-86k raw 1 Hz rows; a 2-row fetch preserves the array path's cadence inference, so
    /// the result is identical. Both views re-run this on every sync (refreshSeq), making the
    /// row volume here the dominant dashboard-refresh cost.
    static func compute(repo: Repository, hrMax: Int, sex: String, restingHr: Int?) async -> Double? {
        let startOfToday = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let nowTs = Int(Date().timeIntervalSince1970)
        let bins = await repo.hrHistogram(from: startOfToday, to: nowTs)
        guard !bins.isEmpty else { return nil }
        let firstTwo = await repo.hrSamples(from: startOfToday, to: nowTs, limit: 2)
        let resting = restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
        return StrainScorer.strain(histogram: bins.map { ($0.bpm, $0.count) },
                                   sampleDurationMin: StrainScorer.sampleDurationMinutes(firstTwo),
                                   maxHR: Double(hrMax), restingHR: resting, sex: sex)
    }
}
