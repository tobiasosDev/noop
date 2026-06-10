import Foundation
import Combine
import WhoopStore
import StrandAnalytics

/// Active goals + CRUD over the WhoopStore `goal` table. App-side wrapper so
/// screens can bind; adherence math lives in StrandAnalytics.GoalProgress.
@MainActor
final class GoalStore: ObservableObject {
    @Published private(set) var goals: [GoalRow] = []
    @Published private(set) var loaded = false

    private let repo: Repository
    init(repo: Repository) { self.repo = repo }

    func load() async {
        guard let store = await repo.storeHandle() else { return }
        goals = (try? await store.activeGoals()) ?? []
        loaded = true
    }

    func save(kind: GoalProgress.Kind, target: Double) async {
        guard let store = await repo.storeHandle() else { return }
        _ = try? await store.saveGoal(kind: kind.rawValue, target: target,
                                      now: Int(Date().timeIntervalSince1970))
        await load()
    }

    func archive(id: Int64) async {
        guard let store = await repo.storeHandle() else { return }
        try? await store.archiveGoal(id: id, now: Int(Date().timeIntervalSince1970))
        await load()
    }
}
