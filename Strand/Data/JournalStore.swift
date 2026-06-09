import Foundation
import Combine

/// Journal capture preferences (single-user, on-device), mirroring `BehaviorStore`'s
/// UserDefaults pattern. `defaults` is injectable so tests use an isolated suite.
@MainActor
final class JournalStore: ObservableObject {
    /// Behaviour ids the user is actively tracking.
    @Published private(set) var trackedIDs: Set<String> { didSet { persistTracked() } }
    @Published var reminderEnabled: Bool { didSet { d.set(reminderEnabled, forKey: K.remOn) } }
    /// Reminder time, minutes since local midnight.
    @Published var reminderMinutes: Int { didSet { d.set(reminderMinutes, forKey: K.remMin) } }
    /// Last day key the user logged (YYYY-MM-DD), to collapse the Today prompt once done.
    @Published var lastLoggedDay: String? { didSet { d.set(lastLoggedDay, forKey: K.last) } }

    private let d: UserDefaults
    private enum K {
        static let tracked = "journal.trackedIDs"
        static let remOn   = "journal.reminderEnabled"
        static let remMin  = "journal.reminderMinutes"
        static let last    = "journal.lastLoggedDay"
    }

    init(defaults: UserDefaults = .standard) {
        self.d = defaults
        if let arr = defaults.array(forKey: K.tracked) as? [String] {
            trackedIDs = Set(arr)
        } else {
            trackedIDs = JournalCatalog.defaultTrackedIDs
        }
        reminderEnabled = defaults.object(forKey: K.remOn) as? Bool ?? false
        reminderMinutes = defaults.object(forKey: K.remMin) as? Int ?? 8 * 60
        lastLoggedDay   = defaults.string(forKey: K.last)
    }

    /// Tracked catalog behaviours, in catalog order.
    var trackedBehaviors: [JournalBehavior] {
        JournalCatalog.all.filter { trackedIDs.contains($0.id) }
    }

    func isTracked(_ id: String) -> Bool { trackedIDs.contains(id) }

    func setTracked(_ id: String, _ on: Bool) {
        if on { trackedIDs.insert(id) } else { trackedIDs.remove(id) }
    }

    private func persistTracked() { d.set(Array(trackedIDs), forKey: K.tracked) }
}
