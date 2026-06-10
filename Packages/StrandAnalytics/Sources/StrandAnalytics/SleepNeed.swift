import Foundation

// SleepNeed.swift — personal sleep need & debt. Single source of truth, extracted
// from SleepView's UI-side math (unchanged semantics) so the Sleep Planner and the
// Sleep screen can never disagree.

public enum SleepNeed {

    /// 7.5 h floor so debt/performance read sensibly even for a chronically short sleeper.
    public static let floorMin: Double = 450

    /// Personal need (minutes) = mean asleep across nights with data, never below the floor.
    /// Nights with 0/negative minutes are ignored; no data at all → the floor.
    public static func needMin(totalSleepMinsByNight: [Double]) -> Double {
        let vals = totalSleepMinsByNight.filter { $0 > 0 }
        guard !vals.isEmpty else { return floorMin }
        return Swift.max(floorMin, vals.reduce(0, +) / Double(vals.count))
    }

    /// Debt for one night = need − asleep, floored at 0 (no "credit" for oversleeping).
    public static func debtMin(needMin: Double, asleepMin: Double) -> Double {
        Swift.max(0, needMin - asleepMin)
    }

    /// Sleep performance % for the Home sleep ring = asleep ÷ need, capped at 100.
    /// nil when there is no positive sleep tonight or no positive need — the ring
    /// shows an honest empty state instead of a fake 0.
    public static func performancePct(needMin: Double, asleepMin: Double?) -> Double? {
        guard let asleep = asleepMin, asleep > 0, needMin > 0 else { return nil }
        return Swift.min(100, asleep / needMin * 100)
    }
}
