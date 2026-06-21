import Foundation
import UserNotifications

/// Phone-notification backstop for the smart alarm. Scheduled whenever smart alarm is ON, regardless
/// of whether the strap firmware arm confirmed — the strap buzz is primary, this is the safety net.
/// System-owned, so it fires even if NOOP is force-quit. Mirrors `IllnessNotifier`/`BatteryNotifier`.
enum WakeAlarmNotifier {
    static let identifier = "noop.wakeAlarm"

    /// Ask up front (when smart alarm is first enabled) so the system prompt appears predictably.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Hour/minute-only components for a time-of-day calendar trigger (fires at the next occurrence).
    static func fireComponents(minutesSinceMidnight: Int) -> DateComponents {
        DateComponents(hour: minutesSinceMidnight / 60, minute: minutesSinceMidnight % 60)
    }

    /// Schedule (replacing any prior) a one-shot wake notification at the given time of day.
    static func schedule(minutesSinceMidnight: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = "Wake up"
            content.body = "Phone backup for your strap alarm — your WHOOP should have buzzed too."
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: fireComponents(minutesSinceMidnight: minutesSinceMidnight),
                repeats: false)
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        }
    }

    /// Cancel the pending backup (smart alarm disabled).
    static func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
