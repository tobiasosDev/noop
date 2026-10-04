import XCTest
import Combine
import Foundation
import WhoopStore
import WhoopProtocol
@testable import Strand

/// The post-sync dashboard cascade publishes ONCE, over the full window.
///
/// It used to open with `repo.refresh(days: 120)` and then re-score, and the re-score ends in its own
/// `refresh()` (4000 days). `refresh` publishes whenever its merge differs from the caches, and a 120-day
/// merge never equals a longer cached history, so each sync published a 120-day `days` (Trends and the
/// streaks lost everything older for a moment) and then the full window again: `refreshSeq` moved twice and
/// every reload keyed on it ran twice. These tests drive `AppModel.refreshDashboardAfterSync` against an
/// in-memory store with a history longer than 120 days, using a stand-in for the re-score.
@MainActor
final class SyncCascadeRefreshTests: XCTestCase {

    private let importedId = Repository.whoopSource
    /// Longer than the 120-day window the cascade used to refresh, so the old shape is observable.
    private let historyDays = 200

    private func dayKey(_ offset: Int, from now: Date = Date()) -> String {
        Repository.dayString(now.addingTimeInterval(-Double(offset) * 86_400))
    }

    private func metric(day: String, strain: Double) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 420, efficiency: 90, deepMin: 90, remMin: 100, lightMin: 230,
                    disturbances: 2, restingHr: 52, avgHrv: 70, recovery: 66, strain: strain, exerciseCount: 0,
                    spo2Pct: nil, skinTempDevC: nil, respRateBpm: 14, steps: nil, activeKcalEst: nil)
    }

    /// A store holding `historyDays` days of history, and a repository that has already loaded it.
    private func loadedRepository() async throws -> (Repository, WhoopStore) {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: importedId, mac: nil, name: "WHOOP")
        try await store.upsertDevice(id: importedId + "-noop", mac: nil, name: "WHOOP")
        let rows = (0..<historyDays).map { metric(day: dayKey($0), strain: 8) }
        _ = try await store.upsertDailyMetrics(rows, deviceId: importedId)
        let repo = Repository(deviceId: importedId)
        repo.setStoreForTesting(store)
        await repo.refresh()
        XCTAssertTrue(repo.loaded)
        XCTAssertEqual(repo.days.count, historyDays, "the seed must sit entirely inside the full window")
        return (repo, store)
    }

    /// Records every `days` value the repository publishes from now on (not the current one).
    private func recordDayCounts(_ repo: Repository) -> (AnyCancellable, () -> [Int]) {
        var counts: [Int] = []
        let sub = repo.$days.dropFirst().sink { counts.append($0.count) }
        return (sub, { counts })
    }

    /// The common case: the re-score persists a changed score and ends in its own full refresh. The cascade
    /// publishes exactly once and never a window shorter than the one on screen.
    func testRescoreThatRefreshesPublishesOnceOverTheFullWindow() async throws {
        let (repo, store) = try await loadedRepository()
        let seqBefore = repo.refreshSeq
        let (sub, published) = recordDayCounts(repo)
        defer { sub.cancel() }

        await AppModel.refreshDashboardAfterSync(repo: repo) {
            // Stand-in for analyzeRecent: persist today's new Effort, then refresh the way its tail does.
            _ = try? await store.upsertDailyMetrics([self.metric(day: self.dayKey(0), strain: 14)],
                                                   deviceId: self.importedId)
            await repo.refresh()
        }

        XCTAssertEqual(repo.refreshSeq, seqBefore + 1, "one sync, one publish")
        XCTAssertEqual(published(), [historyDays], "the only publish carries the whole history")
        XCTAssertEqual(repo.days.last?.strain, 14)
    }

    /// The re-score did not refresh (skipped as unchanged, queued behind a running pass, deferred to a
    /// background task, or persisted no day), but the sync itself wrote a row the caches show. The trailing
    /// refresh surfaces it at once, still as a single full-window publish.
    func testRescoreThatDoesNotRefreshStillSurfacesTheSyncOnce() async throws {
        let (repo, store) = try await loadedRepository()
        let seqBefore = repo.refreshSeq
        let (sub, published) = recordDayCounts(repo)
        defer { sub.cancel() }

        await AppModel.refreshDashboardAfterSync(repo: repo) {
            _ = try? await store.upsertDailyMetrics([self.metric(day: self.dayKey(1), strain: 11)],
                                                   deviceId: self.importedId)
        }

        XCTAssertEqual(repo.refreshSeq, seqBefore + 1)
        XCTAssertEqual(published(), [historyDays])
        XCTAssertEqual(repo.days.first(where: { $0.day == dayKey(1) })?.strain, 11)
    }

    /// An empty offload with a skipped re-score changes nothing, so nothing is published at all.
    func testSyncThatChangedNothingPublishesNothing() async throws {
        let (repo, _) = try await loadedRepository()
        let seqBefore = repo.refreshSeq
        let (sub, published) = recordDayCounts(repo)
        defer { sub.cancel() }

        await AppModel.refreshDashboardAfterSync(repo: repo) {}

        XCTAssertEqual(repo.refreshSeq, seqBefore)
        XCTAssertEqual(published(), [])
    }

    /// Why the cascade must not refresh a partial window: over a longer cached history a 120-day refresh is
    /// never "unchanged", so it publishes a SHORTER `days`, and the full refresh behind it publishes again.
    /// This is the sequence the cascade used to run; the assertions are the two symptoms it produced.
    func testPartialWindowRefreshIsWhatShrankTheCacheAndDoubledThePublish() async throws {
        let (repo, store) = try await loadedRepository()
        let seqBefore = repo.refreshSeq
        let (sub, published) = recordDayCounts(repo)
        defer { sub.cancel() }

        await repo.refresh(days: 120)
        _ = try await store.upsertDailyMetrics([metric(day: dayKey(0), strain: 14)], deviceId: importedId)
        await repo.refresh()

        XCTAssertEqual(repo.refreshSeq, seqBefore + 2)
        XCTAssertLessThan(published().min() ?? historyDays, historyDays)
    }

    /// The publish diff now runs inside the detached merge. Its decisions are unchanged: the first refresh
    /// of an empty store still publishes (`loaded` flips), an identical re-read publishes nothing, and a
    /// change confined to the sleep cache still publishes.
    func testOffMainDiffKeepsThePublishDecisions() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: importedId, mac: nil, name: "WHOOP")
        let repo = Repository(deviceId: importedId)
        repo.setStoreForTesting(store)

        await repo.refresh()
        XCTAssertTrue(repo.loaded)
        XCTAssertEqual(repo.refreshSeq, 1, "the first refresh publishes even with nothing to show")

        await repo.refresh()
        XCTAssertEqual(repo.refreshSeq, 1, "an identical re-read is not a publish")

        let end = Int(Date().timeIntervalSince1970) - 3_600
        let night = CachedSleepSession(startTs: end - 8 * 3_600, endTs: end, efficiency: 0.9, restingHr: 50,
                                       avgHrv: 60, stagesJSON: "[]")
        _ = try await store.upsertSleepSessions([night], deviceId: importedId)
        await repo.refresh()
        XCTAssertEqual(repo.refreshSeq, 2, "a sleep-only change still publishes")
        XCTAssertEqual(repo.sleeps.count, 1)

        await repo.refresh()
        XCTAssertEqual(repo.refreshSeq, 2)
    }
}
