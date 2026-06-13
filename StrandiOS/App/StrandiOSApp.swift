#if os(iOS)
import SwiftUI
import UserNotifications

/// iOS entry point. Unlike the macOS app (which adds a `MenuBarExtra` scene), iOS uses a single
/// `WindowGroup`; the glanceable menu-bar role is filled by the Home/Lock-Screen widget instead.
@main
struct StrandiOSApp: App {
    @StateObject private var model: AppModel
    @StateObject private var health: HealthKitBridge
    /// Observe the SAME JournalStore instance the model owns, so changing the reminder time in
    /// settings reschedules the local notification reactively (onChange below).
    @StateObject private var journal: JournalStore
    @State private var liveActivity = LiveActivityController()
    @Environment(\.scenePhase) private var scenePhase

    /// Strongly held: UNUserNotificationCenter.delegate is weak, so the app must retain it.
    private let journalReminder = JournalReminderScheduler()

    init() {
        WidgetSnapshot.assertGroupProvisioned()
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        _health = StateObject(wrappedValue: HealthKitBridge(
            repo: model.repo,
            appleDeviceId: model.appleDeviceId,
            noopDeviceId: model.deviceId
        ))
        _journal = StateObject(wrappedValue: model.journal)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.live)
                .environmentObject(model.repo)
                .environmentObject(model.goalStore)
                .environmentObject(model.profile)
                .environmentObject(model.behavior)
                .environmentObject(model.journal)
                .environmentObject(model.intelligence)
                .environmentObject(model.coach)
                .environmentObject(health)
                .preferredColorScheme(.dark)
                .task {
                    #if targetEnvironment(simulator)
                    // Screenshot harness (NOOP_SCREEN): the HealthKit permission sheet
                    // would cover every captured screen — skip auth/sync entirely.
                    if ProcessInfo.processInfo.environment["NOOP_SCREEN"] != nil { return }
                    #endif
                    await health.requestAuthorization()
                    await health.sync()
                }
                .task {
                    UNUserNotificationCenter.current().delegate = journalReminder
                    journalReminder.apply(enabled: journal.reminderEnabled,
                                          minutesSinceMidnight: journal.reminderMinutes)
                }
                .onChange(of: journal.reminderEnabled) { _, on in
                    journalReminder.apply(enabled: on, minutesSinceMidnight: journal.reminderMinutes)
                }
                .onChange(of: journal.reminderMinutes) { _, m in
                    journalReminder.apply(enabled: journal.reminderEnabled, minutesSinceMidnight: m)
                }
                .onReceive(NotificationCenter.default.publisher(for: .noopPendingIntentEnqueued)
                    .receive(on: RunLoop.main)) { _ in
                    // Drain immediately if we're foreground; background enqueues still drain on the
                    // next scenePhase `.active` (handled below).
                    if scenePhase == .active { model.drainPendingIntents() }
                }
                .onReceive(model.live.$heartRate) { _ in
                    liveActivity.update(
                        bpm: model.bpm ?? model.live.heartRate,
                        recovery: model.repo.days.last(where: { $0.recovery != nil })?
                            .recovery.map { Int($0.rounded()) },
                        bonded: model.live.bonded
                    )
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.drainPendingIntents()
                model.resumeRealtimeAfterForeground()
                Task {
                    await health.sync()
                    WidgetSnapshot.publish(from: model)
                }
            } else if phase == .background {
                // Overnight-data-loss fix: if the user fell asleep on the Live tab, the R10/R11 raw
                // stream is armed; left armed across the suspend-then-drop it blocks the strap from
                // banking the night (PR #13). Disarm it here so the strap banks to flash and the next
                // connect+offload recovers the night. The link + wake keep-alive are unaffected.
                model.pauseRealtimeForBackground()
                // #155: refresh the Documents/noop_sync.txt drop file the user's Siri Shortcut logs
                // into Apple Health. Gated inside writeIfEnabled on the opt-in default (OFF) — a
                // no-op until the user turns on Shortcuts Export.
                Task { await ShortcutHealthExport.writeIfEnabled(repo: model.repo) }
            }
        }
    }
}
#endif
