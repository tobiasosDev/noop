import XCTest
@testable import WhoopStore

final class GoalsTests: XCTestCase {

    func testV11CreatesGoalTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("goal"))
    }

    func testSaveAndReadActiveGoal() async throws {
        let store = try await WhoopStore.inMemory()
        let id = try await store.saveGoal(kind: "sleepDuration", target: 450, now: 1000)
        let goals = try await store.activeGoals()
        XCTAssertEqual(goals.count, 1)
        XCTAssertEqual(goals[0].id, id)
        XCTAssertEqual(goals[0].kind, "sleepDuration")
        XCTAssertEqual(goals[0].target, 450, accuracy: 1e-9)
        XCTAssertNil(goals[0].archivedAt)
    }

    func testSaveSameKindArchivesPrevious() async throws {
        // Max one active goal per kind: saving a new sleepDuration target archives the old one.
        let store = try await WhoopStore.inMemory()
        _ = try await store.saveGoal(kind: "sleepDuration", target: 450, now: 1000)
        _ = try await store.saveGoal(kind: "sleepDuration", target: 480, now: 2000)
        let goals = try await store.activeGoals()
        XCTAssertEqual(goals.count, 1)
        XCTAssertEqual(goals[0].target, 480, accuracy: 1e-9)
    }

    func testDifferentKindsCoexist() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.saveGoal(kind: "sleepDuration", target: 450, now: 1000)
        _ = try await store.saveGoal(kind: "dailySteps", target: 10000, now: 1000)
        let goals = try await store.activeGoals()
        XCTAssertEqual(goals.count, 2)
    }

    func testArchiveRemovesFromActive() async throws {
        let store = try await WhoopStore.inMemory()
        let id = try await store.saveGoal(kind: "weeklyStrain", target: 14, now: 1000)
        try await store.archiveGoal(id: id, now: 2000)
        let goals = try await store.activeGoals()
        XCTAssertTrue(goals.isEmpty)
    }
}
