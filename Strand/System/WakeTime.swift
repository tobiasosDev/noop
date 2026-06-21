import Foundation

/// Single source of truth for "the next Date at a given local time of day".
/// Used by both the strap firmware alarm (epoch) and the phone-notification backup so they
/// never disagree about which instant the user asked to wake at.
enum WakeTime {
    /// The next future Date whose local wall-clock time is `minutesSinceMidnight`.
    /// Rolls to tomorrow if today's occurrence is already at or before `now`.
    static func next(minutesSinceMidnight: Int, from now: Date = Date(), calendar: Calendar = .current) -> Date {
        let hour = minutesSinceMidnight / 60
        let minute = minutesSinceMidnight % 60
        var next = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        if next <= now { next = calendar.date(byAdding: .day, value: 1, to: next) ?? next }
        return next
    }
}
