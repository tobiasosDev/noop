import Foundation

// SleepPlanner.swift — "go to bed at X": when to be in bed to hit tonight's sleep
// need for a chosen performance goal, given the planned wake time. Pure math; the
// wake time comes from the strap alarm or a manual planner setting (app layer).

public enum SleepPlanner {

    public enum Goal: String, CaseIterable, Equatable, Sendable {
        case peak, perform, getBy
        /// Fraction of tonight's need the goal aims to bank.
        public var fraction: Double {
            switch self {
            case .peak:    return 1.0
            case .perform: return 0.85
            case .getBy:   return 0.70
            }
        }
    }

    /// Share of accumulated debt repaid in a single night (gradual, WHOOP-style).
    public static let debtRepayFraction: Double = 0.3
    /// Used when no personal efficiency history exists yet.
    public static let defaultEfficiency: Double = 0.90
    /// Personal efficiency below this is treated as this (guards absurd inBed times).
    public static let efficiencyFloor: Double = 0.75

    public struct Recommendation: Equatable, Sendable {
        /// Recommended bedtime, minutes since local midnight (0..<1440), wrapped.
        public let bedMinutes: Int
        /// Tonight's total need (base + debt repayment), minutes asleep.
        public let needMin: Double
        /// Need scaled by the goal fraction.
        public let goalSleepMin: Double
        /// Time in bed after the efficiency adjustment.
        public let inBedMin: Double
        /// True when no personal efficiency was available (defaults used).
        public let usedDefaults: Bool
    }

    /// - Parameters:
    ///   - wakeMinutes: planned wake, minutes since local midnight.
    ///   - baseNeedMin: personal need (SleepNeed.needMin).
    ///   - debtMin: latest accumulated debt (SleepNeed.debtMin of the last night).
    ///   - efficiency: personal typical sleep efficiency 0–1; nil → default.
    public static func recommend(wakeMinutes: Int,
                                 baseNeedMin: Double,
                                 debtMin: Double,
                                 efficiency: Double?,
                                 goal: Goal) -> Recommendation {
        let usedDefaults = efficiency == nil
        let eff = Swift.max(efficiencyFloor, Swift.min(1.0, efficiency ?? defaultEfficiency))
        let need = baseNeedMin + debtRepayFraction * debtMin
        let goalSleep = need * goal.fraction
        let inBed = goalSleep / eff
        var bed = Double(wakeMinutes) - inBed
        while bed < 0 { bed += 1440 }            // wrap across midnight
        return Recommendation(bedMinutes: Int(bed.rounded()) % 1440,
                              needMin: need,
                              goalSleepMin: goalSleep,
                              inBedMin: inBed,
                              usedDefaults: usedDefaults)
    }
}
