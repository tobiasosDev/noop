#if os(iOS)
import Foundation
import UserNotifications

/// Schedules tonight's wind-down nudge 30 min before the recommended bedtime.
/// Non-repeating — re-scheduled whenever the recommendation or toggle changes
/// (SleepView drives it), so it always reflects tonight's need.
final class BedtimeReminderScheduler {
    static let shared = BedtimeReminderScheduler()
    static let notificationID = "noop.bedtime.reminder"
    private let center = UNUserNotificationCenter.current()

    /// minutes-since-midnight of the recommended bedtime.
    func apply(enabled: Bool, bedMinutes: Int) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        guard enabled else { return }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard granted, let self else { return }
            var remind = bedMinutes - 30
            if remind < 0 { remind += 1440 }   // wrap across midnight
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Wind down")
            content.body = String(localized: "Bedtime in 30 minutes to hit tonight's sleep goal.")
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: DateComponents(hour: remind / 60, minute: remind % 60),
                repeats: false)
            self.center.add(UNNotificationRequest(identifier: Self.notificationID,
                                                  content: content, trigger: trigger))
        }
    }
}
#endif
