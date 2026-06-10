import Foundation
import WhoopStore

// MyDay.swift — the Home "Today's Activities" timeline. Pure merge/filter so the
// view stays declarative and the day-boundary rules are unit-tested.

public enum MyDay {

    public enum Activity: Equatable {
        case sleep(CachedSleepSession)
        case workout(WorkoutRow)

        public var startTs: Int {
            switch self {
            case .sleep(let s):   return s.startTs
            case .workout(let w): return w.startTs
            }
        }
    }

    /// Today's timeline: sleep sessions count when they END today (the night you woke
    /// from this morning, even though it started yesterday evening); workouts count when
    /// they START today. Merged chronologically by start time.
    public static func activities(sleeps: [CachedSleepSession], workouts: [WorkoutRow],
                                  now: Date = Date(),
                                  calendar: Calendar = .current) -> [Activity] {
        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let lo = Int(dayStart.timeIntervalSince1970)
        let hi = Int(dayEnd.timeIntervalSince1970)
        let s = sleeps.filter { $0.endTs >= lo && $0.endTs < hi }.map(Activity.sleep)
        let w = workouts.filter { $0.startTs >= lo && $0.startTs < hi }.map(Activity.workout)
        return (s + w).sorted { $0.startTs < $1.startTs }
    }
}
