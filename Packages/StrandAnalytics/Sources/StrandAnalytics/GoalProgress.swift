import Foundation

// GoalProgress.swift — goal adherence math. Pure: per-day metric values in,
// weekly progress out. Persistence (the goal table) lives in WhoopStore; the
// screens fetch values from Repository and call evaluate().

public enum GoalProgress {

    public enum Kind: String, CaseIterable, Equatable, Sendable {
        case sleepDuration   // minutes asleep per night, daily hit/miss
        case weeklyStrain    // average day strain over the week vs target
        case dailySteps      // steps per day, daily hit/miss

        public var isDaily: Bool { self != .weeklyStrain }
    }

    public struct DayStatus: Equatable, Sendable {
        public let day: String
        public let value: Double?
        public let hit: Bool
    }

    public struct Progress: Equatable, Sendable {
        public let kind: Kind
        public let target: Double
        /// One entry per weekDay, oldest→newest (always weekDays.count entries).
        public let week: [DayStatus]
        /// Daily kinds: hits / days-with-data × 100. weeklyStrain: week-avg / target × 100.
        public let percent: Double
        /// Consecutive hit days ending at the latest day WITH data (daily kinds; 0 otherwise).
        public let streak: Int
        public let todayValue: Double?
        public let todayHit: Bool
    }

    /// - Parameters:
    ///   - values: day-key → metric value (sleep minutes / day strain / steps).
    ///   - weekDays: trailing 7 day-keys ending today, oldest→newest (the caller
    ///     derives these from Repository.localDayKey so calendar logic stays in one place).
    public static func evaluate(kind: Kind, target: Double,
                                values: [String: Double],
                                weekDays: [String]) -> Progress {
        let week = weekDays.map { day -> DayStatus in
            let v = values[day]
            return DayStatus(day: day, value: v, hit: v.map { $0 >= target } ?? false)
        }
        let withData = week.filter { $0.value != nil }

        let percent: Double
        switch kind {
        case .weeklyStrain:
            let vals = withData.compactMap { $0.value }
            let avg = vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
            percent = target > 0 ? avg / target * 100 : 0
        case .sleepDuration, .dailySteps:
            let hits = withData.filter { $0.hit }.count
            percent = withData.isEmpty ? 0 : Double(hits) / Double(withData.count) * 100
        }

        // Streak: walk newest→oldest; a data-less TODAY doesn't break it (the day
        // isn't over), but any other data-less or missed day does.
        var streak = 0
        if kind.isDaily {
            var entries = Array(week.reversed())
            if entries.first?.value == nil { entries.removeFirst() }
            for e in entries {
                if e.hit { streak += 1 } else { break }
            }
        }

        let today = week.last
        return Progress(kind: kind, target: target, week: week, percent: percent,
                        streak: streak, todayValue: today?.value ?? nil,
                        todayHit: today?.hit ?? false)
    }
}
