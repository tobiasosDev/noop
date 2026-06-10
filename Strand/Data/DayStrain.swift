import Foundation
import StrandAnalytics

/// Intraday ("so far today") strain from the raw 1 Hz HR stream. Shared by the
/// Today strain-coach card and the Live strip so the number can never disagree.
enum DayStrain {
    /// nil when under StrainScorer.minReadings (~10 min of samples) — callers show pending.
    static func compute(repo: Repository, hrMax: Int, sex: String, restingHr: Int?) async -> Double? {
        let startOfToday = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let nowTs = Int(Date().timeIntervalSince1970)
        // 1 Hz ⇒ up to 86 400 rows/day; the default 8 000 limit would silently truncate.
        let samples = await repo.hrSamples(from: startOfToday, to: nowTs, limit: 100_000)
        let resting = restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
        return StrainScorer.strain(samples, maxHR: Double(hrMax), restingHR: resting, sex: sex)
    }
}
