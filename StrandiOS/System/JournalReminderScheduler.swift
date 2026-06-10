#if os(iOS)
import Foundation
import UserNotifications

/// Schedules the daily morning journal reminder and routes a tap to the log sheet via the
/// existing `PendingIntents` queue (drained by AppModel on scenePhase `.active`). Owned by
/// `StrandiOSApp` and registered as the notification-center delegate.
final class JournalReminderScheduler: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    /// Enable/disable and (re)schedule the repeating reminder for the given local time.
    /// Requesting authorization is a no-op if already decided; if denied, nothing is scheduled
    /// and the always-visible Today card remains the fallback prompt.
    func apply(enabled: Bool, minutesSinceMidnight: Int) {
        center.removePendingNotificationRequests(withIdentifiers: [JournalReminder.notificationID])
        guard enabled else { return }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard granted, let self else { return }
            let content = UNMutableNotificationContent()
            content.title = "Good morning"
            content.body = "How did yesterday go? Log your journal."
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: JournalReminder.components(minutesSinceMidnight: minutesSinceMidnight),
                repeats: true)
            self.center.add(UNNotificationRequest(identifier: JournalReminder.notificationID,
                                                  content: content, trigger: trigger))
        }
    }

    // Tap → enqueue; AppModel.drainPendingIntents() (scenePhase .active) opens the log sheet.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == JournalReminder.notificationID {
            PendingIntents.append(.openJournal)
        }
        completionHandler()
    }

    // Show the banner even if the app is foregrounded at the reminder time.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
#endif
