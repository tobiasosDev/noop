import Foundation
import Combine

/// Settings for the strap's physical inputs and the Mac/coaching automations built on top of the
/// live event + biometric stream. UserDefaults-backed (single-user, on-device).
@MainActor
final class BehaviorStore: ObservableObject {

    // MARK: Double-tap → Mac action
    @Published var doubleTapAction: MacActionKind { didSet { d.set(doubleTapAction.rawValue, forKey: K.dtAction) } }
    @Published var doubleTapShortcut: String { didSet { d.set(doubleTapShortcut, forKey: K.dtShortcut) } }

    // MARK: Wear automation
    /// Lock the Mac when the strap comes off the wrist.
    @Published var autoLockOnWristOff: Bool { didSet { d.set(autoLockOnWristOff, forKey: K.autoLock) } }
    /// Run a Shortcut when the strap comes off (presence automation: Focus, pause media, set away…).
    @Published var wristOffShortcut: String { didSet { d.set(wristOffShortcut, forKey: K.wristOffShortcut) } }
    /// Run a Shortcut when the strap goes back on the wrist.
    @Published var wristOnShortcut: String { didSet { d.set(wristOnShortcut, forKey: K.wristOnShortcut) } }

    // MARK: HR-zone haptic coaching (during a live session)
    @Published var zoneCoaching: Bool { didSet { d.set(zoneCoaching, forKey: K.zoneCoaching) } }
    /// Experimental: gentle buzz when a resting stress spike is detected (HRV drops while HR is calm).
    @Published var stressNudge: Bool { didSet { d.set(stressNudge, forKey: K.stress) } }

    // MARK: Smart alarm
    @Published var smartAlarmEnabled: Bool { didSet { d.set(smartAlarmEnabled, forKey: K.alarmOn) } }
    /// Target wake time, minutes since local midnight.
    @Published var smartAlarmMinutes: Int { didSet { d.set(smartAlarmMinutes, forKey: K.alarmTime) } }
    /// Light-sleep window before the target, in minutes (wake early if a light phase is detected).
    @Published var smartAlarmWindow: Int { didSet { d.set(smartAlarmWindow, forKey: K.alarmWindow) } }

    // MARK: Sleep planner
    /// Manual wake time (minutes since local midnight) when the strap alarm is off.
    @Published var plannerWakeMinutes: Int { didSet { d.set(plannerWakeMinutes, forKey: K.plannerWake) } }
    /// SleepPlanner.Goal rawValue ("peak" / "perform" / "getBy").
    @Published var plannerGoalRaw: String { didSet { d.set(plannerGoalRaw, forKey: K.plannerGoal) } }
    /// iOS: schedule a wind-down notification 30 min before the recommended bedtime.
    @Published var bedtimeReminderEnabled: Bool { didSet { d.set(bedtimeReminderEnabled, forKey: K.bedtimeReminder) } }

    // MARK: Illness early-warning
    @Published var illnessWatch: Bool { didSet { d.set(illnessWatch, forKey: K.illness) } }

    private let d = UserDefaults.standard
    private enum K {
        static let dtAction = "behavior.doubleTapAction"
        static let dtShortcut = "behavior.doubleTapShortcut"
        static let autoLock = "behavior.autoLockOnWristOff"
        static let wristOffShortcut = "behavior.wristOffShortcut"
        static let wristOnShortcut = "behavior.wristOnShortcut"
        static let zoneCoaching = "behavior.zoneCoaching"
        static let stress = "behavior.stressNudge"
        static let alarmOn = "behavior.smartAlarmEnabled"
        static let alarmTime = "behavior.smartAlarmMinutes"
        static let alarmWindow = "behavior.smartAlarmWindow"
        static let illness = "behavior.illnessWatch"
        static let plannerWake = "planner.wakeMinutes"
        static let plannerGoal = "planner.goal"
        static let bedtimeReminder = "planner.bedtimeReminderEnabled"
    }

    init() {
        doubleTapAction = MacActionKind(rawValue: d.string(forKey: K.dtAction) ?? "") ?? .none
        doubleTapShortcut = d.string(forKey: K.dtShortcut) ?? ""
        autoLockOnWristOff = d.object(forKey: K.autoLock) as? Bool ?? false
        wristOffShortcut = d.string(forKey: K.wristOffShortcut) ?? ""
        wristOnShortcut = d.string(forKey: K.wristOnShortcut) ?? ""
        zoneCoaching = d.object(forKey: K.zoneCoaching) as? Bool ?? false
        stressNudge = d.object(forKey: K.stress) as? Bool ?? false
        smartAlarmEnabled = d.object(forKey: K.alarmOn) as? Bool ?? false
        smartAlarmMinutes = d.object(forKey: K.alarmTime) as? Int ?? 7 * 60       // 07:00
        smartAlarmWindow = d.object(forKey: K.alarmWindow) as? Int ?? 30          // wake up to 30m early
        illnessWatch = d.object(forKey: K.illness) as? Bool ?? false
        plannerWakeMinutes = d.object(forKey: K.plannerWake) as? Int ?? 7 * 60     // 07:00
        plannerGoalRaw = d.string(forKey: K.plannerGoal) ?? "perform"
        bedtimeReminderEnabled = d.object(forKey: K.bedtimeReminder) as? Bool ?? false
    }
}
