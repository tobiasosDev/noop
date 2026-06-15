import Foundation
import UserNotifications

/// Layer 1 of the live-fire alarm: a local notification at the wake instant — the most reliable
/// layer. It fires on the phone even when the BLE link is down, the app is suspended, or the
/// strap's firmware alarm is wedged (see `whoop4-deep-discharge-state`). With the time-sensitive
/// entitlement it breaks through a sleep/Do-Not-Disturb Focus, but it is still a best-effort phone
/// alert — it respects the ringer switch/volume and needs notification permission (a true can't-miss
/// alarm would require the Apple-approved Critical Alerts entitlement). The live wrist buzz
/// (RUN_ALARM over BLE, driven by `WakeAlarmScheduler` in `BLEManager`) is the opportunistic
/// Layer 2 on top of this; the firmware cmd-66 alarm is the free Layer 3 backstop.
///
/// On-device only in practice (notifications need authorization); time math is in the pure
/// `WakeAlarmScheduler`. Single notification id, re-scheduled each time the alarm is (re)armed.
enum WakeAlarmNotifier {
    static let notificationID = "wake.alarm"

    /// Ask for notification permission up front (called when the smart alarm is enabled) so the
    /// system dialog appears at a predictable moment, not at the first 5 a.m. fire.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// (Re)schedule the wake notification for an absolute instant. Replaces any pending wake
    /// notification first, so re-arming on every reconnect never stacks duplicates.
    static func schedule(at date: Date) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = "Wake up"
            content.body = "Good morning — time to start your day."
            content.sound = .default
            // Break through Focus/Do-Not-Disturb without the Critical-alert entitlement.
            content.interruptionLevel = .timeSensitive
            // Fixed-instant trigger: exact year→second components so it fires once, on time.
            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            center.add(UNNotificationRequest(
                identifier: notificationID, content: content, trigger: trigger))
        }
    }

    /// Cancel the pending wake notification (alarm disabled).
    static func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [notificationID])
    }
}
