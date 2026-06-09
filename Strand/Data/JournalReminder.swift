import Foundation

/// Platform-neutral helpers for the journal morning reminder, so the time math is unit-tested
/// on macOS; the `UNUserNotificationCenter` scheduling itself is iOS-only (JournalReminderScheduler).
enum JournalReminder {
    static let notificationID = "journal.morning.reminder"

    /// Minutes-since-local-midnight → hour/minute components for a calendar trigger. Clamped to a
    /// valid time of day so a malformed pref can never produce an invalid trigger.
    static func components(minutesSinceMidnight m: Int) -> DateComponents {
        let clamped = max(0, min(23 * 60 + 59, m))
        return DateComponents(hour: clamped / 60, minute: clamped % 60)
    }
}
