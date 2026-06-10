import Foundation
import WhoopStore

// PerformanceReport.swift — periodized performance assessment over a trailing
// window (weekly = 7 days, monthly = 28), with Δ vs the immediately-prior window
// when that window has data. Pure aggregation over [DailyMetric]; ReportView renders.

public enum PerformanceReport {

    public enum Period: String, CaseIterable, Equatable, Sendable {
        case weekly, monthly
        public var days: Int { self == .weekly ? 7 : 28 }
    }

    /// Takeaway thresholds — named so the rules read as policy, not magic numbers.
    public static let takeawayOverreachMinDays: Int = 2
    public static let takeawayHRVDeltaThreshold: Double = 3.0
    public static let takeawayRecoveryDeltaThreshold: Double = 8.0
    public static let takeawaySleepPerformanceWarnPct: Double = 70.0
    public static let sleepPerformanceCap: Double = 125.0

    public struct Average: Equatable, Sendable {
        public let value: Double
        /// Δ vs the prior window; nil when the prior window has no data for this metric.
        public let delta: Double?
    }

    public struct DayValue: Equatable, Sendable {
        public let day: String
        public let value: Double
    }

    /// Structured takeaway facts. The engine emits cases (data, not prose) so the UI
    /// layer can render each one as a localizable sentence — keeps the package free
    /// of user-facing language. Hashable so views can use them as ForEach ids.
    public enum Takeaway: Equatable, Hashable, Sendable {
        case overreach(days: Int)
        case hrvUp
        case hrvDown
        case recoveryUp(pct: Double)
        case recoveryDown(pct: Double)
        case lowSleepPerformance(pct: Double)
    }

    public struct Summary: Equatable, Sendable {
        public let period: Period
        public let fromDay: String
        public let toDay: String
        /// Days in the window with at least one of recovery/strain/sleep present.
        public let coverage: Int

        public let recovery: Average?
        public let bestRecoveryDay: DayValue?
        public let worstRecoveryDay: DayValue?
        public let hrv: Average?
        public let rhr: Average?

        public let sleepMin: Average?
        public let sleepNeedMin: Double
        /// Mean asleep / need × 100 over the window (nil without sleep data).
        public let sleepPerformancePct: Double?

        public let strain: Average?
        public let totalStrain: Double?
        public let overreachDays: Int
        public let underreachDays: Int

        public let takeaways: [Takeaway]
    }

    /// ISO day-key calendar math (yyyy-MM-dd, en_US_POSIX — matches Repository).
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date) -> String { fmt.string(from: date) }
    static func shift(_ day: String, by days: Int) -> String {
        guard let d = fmt.date(from: day) else { return day }
        return dayKey(d.addingTimeInterval(Double(days) * 86_400))
    }

    public static func build(days: [DailyMetric], period: Period, today: String) -> Summary {
        let from = shift(today, by: -(period.days - 1))
        let priorFrom = shift(from, by: -period.days)
        let priorTo = shift(from, by: -1)

        let window = days.filter { $0.day >= from && $0.day <= today }
        let prior = days.filter { $0.day >= priorFrom && $0.day <= priorTo }

        func mean(_ vals: [Double]) -> Double? {
            vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
        }
        /// Window mean + Δ vs the prior window's mean for the same field.
        func avg(_ key: (DailyMetric) -> Double?) -> Average? {
            guard let v = mean(window.compactMap(key)) else { return nil }
            return Average(value: v, delta: mean(prior.compactMap(key)).map { v - $0 })
        }

        let coverage = window.filter {
            $0.recovery != nil || $0.strain != nil || $0.totalSleepMin != nil
        }.count

        // Recovery extremes.
        let recDays = window.compactMap { d in d.recovery.map { DayValue(day: d.day, value: $0) } }
        let best = recDays.max(by: { $0.value < $1.value })
        let worst = recDays.min(by: { $0.value < $1.value })

        // Sleep (need over the FULL history passed in, matching SleepView).
        let need = SleepNeed.needMin(totalSleepMinsByNight: days.compactMap { $0.totalSleepMin })
        let sleepAvg = avg { $0.totalSleepMin }
        let perfPct = sleepAvg.map { min(sleepPerformanceCap, $0.value / need * 100) }

        // Strain vs the per-day recovery-derived target band.
        var over = 0, under = 0
        for d in window {
            guard let r = d.recovery, let s = d.strain else { continue }
            switch StrainTarget.band(recovery: r).state(currentStrain: s) {
            case .overreaching: over += 1
            case .building:     under += 1
            case .onTarget:     break
            }
        }
        let strainVals = window.compactMap { $0.strain }
        let strainAvg = avg { $0.strain }
        let recoveryAvg = avg { $0.recovery }
        let hrvAvg = avg { $0.avgHrv }

        // Rule-based takeaways (structured facts; the UI renders localized sentences).
        var notes: [Takeaway] = []
        if over >= takeawayOverreachMinDays {
            notes.append(.overreach(days: over))
        }
        if let hrvD = hrvAvg?.delta {
            if hrvD >= takeawayHRVDeltaThreshold { notes.append(.hrvUp) }
            if hrvD <= -takeawayHRVDeltaThreshold { notes.append(.hrvDown) }
        }
        if let recD = recoveryAvg?.delta {
            if recD >= takeawayRecoveryDeltaThreshold {
                notes.append(.recoveryUp(pct: recD))
            }
            if recD <= -takeawayRecoveryDeltaThreshold {
                notes.append(.recoveryDown(pct: abs(recD)))
            }
        }
        if let p = perfPct, p < takeawaySleepPerformanceWarnPct {
            notes.append(.lowSleepPerformance(pct: p))
        }

        return Summary(period: period, fromDay: from, toDay: today, coverage: coverage,
                       recovery: recoveryAvg, bestRecoveryDay: best, worstRecoveryDay: worst,
                       hrv: hrvAvg, rhr: avg { $0.restingHr.map(Double.init) },
                       sleepMin: sleepAvg, sleepNeedMin: need, sleepPerformancePct: perfPct,
                       strain: strainAvg,
                       totalStrain: strainVals.isEmpty ? nil : strainVals.reduce(0, +),
                       overreachDays: over, underreachDays: under,
                       takeaways: notes)
    }
}
