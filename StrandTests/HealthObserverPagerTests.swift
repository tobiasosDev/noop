import XCTest
@testable import Strand

final class HealthObserverPagerTests: XCTestCase {
    func testBootstrapCoversFullSupportedWindowAcrossDaylightSavingChange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 5, hour: 17))!
        let cutoff = HealthObserverPager.bootstrapCutoff(now: now, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour], from: cutoff),
                       DateComponents(year: 2026, month: 3, day: 5, hour: 0))
        XCTAssertEqual(calendar.dateComponents([.day], from: cutoff, to: calendar.startOfDay(for: now)).day, 31)
    }

    func testWalksAllPagesIncludingShortRepliesAndKeepsOldestDate() async throws {
        var cursors: [Int?] = []
        let oldest = Date(timeIntervalSince1970: 100)
        let window = try await HealthObserverPager.scan(from: Optional<Int>.none) { cursor, limit in
            XCTAssertEqual(limit, 500)
            cursors.append(cursor)
            switch cursor {
            case nil:
                return .init(oldest: Date(timeIntervalSince1970: 200), sampleCount: 500, deletedCount: 0, anchor: 1)
            case 1:
                return .init(oldest: oldest, sampleCount: 2, deletedCount: 0, anchor: 2)
            case 2:
                return .init(oldest: nil, sampleCount: 0, deletedCount: 1, anchor: 3)
            default:
                return .init(oldest: nil, sampleCount: 0, deletedCount: 0, anchor: 4)
            }
        }
        XCTAssertEqual(cursors, [nil, 1, 2, 3])
        XCTAssertEqual(window.oldest, oldest)
        XCTAssertTrue(window.hasDeletions)
        XCTAssertEqual(window.anchor, 4)
    }

    func testLaterPageFailureDoesNotReturnPartialCursor() async {
        enum Failure: Error { case query }
        var calls = 0
        do {
            _ = try await HealthObserverPager.scan(from: 10) { cursor, _ in
                calls += 1
                if cursor == 10 {
                    return HealthObserverPager.Page(oldest: Date(), sampleCount: 500, deletedCount: 0, anchor: 11)
                }
                throw Failure.query
            }
            XCTFail("A failed traversal must not expose a committable cursor")
        } catch {
            XCTAssertTrue(error is Failure)
        }
        XCTAssertEqual(calls, 2)
    }

    func testEmptyHistoryReturnsCursorWithoutIngestionWindow() async throws {
        let window = try await HealthObserverPager.scan(from: 2) { _, _ in
            HealthObserverPager.Page(oldest: nil, sampleCount: 0, deletedCount: 0, anchor: 3)
        }
        XCTAssertNil(window.oldest)
        XCTAssertFalse(window.hasDeletions)
        XCTAssertEqual(window.anchor, 3)
    }

    func testDuplicateWakesShareBatchAndEveryCompletionRunsOnce() {
        var queue = HealthObserverDeliveryQueue<String>()
        var completions = 0
        XCTAssertTrue(queue.enqueue(id: "hr", payload: "hr") { completions += 1 })
        XCTAssertFalse(queue.enqueue(id: "hr", payload: "hr") { completions += 1 })
        XCTAssertFalse(queue.enqueue(id: "sleep", payload: "sleep") { completions += 1 })
        let batch = queue.nextBatch()!
        XCTAssertEqual(batch.count, 2)
        for delivery in batch { delivery.completions.forEach { $0() } }
        XCTAssertEqual(completions, 3)
        XCTAssertNil(queue.nextBatch())
    }

    func testWakeDuringQueryBelongsToNextBatchAndRestartsAfterDrain() {
        var queue = HealthObserverDeliveryQueue<String>()
        var completed: [String] = []
        XCTAssertTrue(queue.enqueue(id: "hr", payload: "hr") { completed.append("first") })
        let first = queue.nextBatch()!
        XCTAssertFalse(queue.enqueue(id: "hr", payload: "hr") { completed.append("during read") })
        first[0].completions.forEach { $0() }
        XCTAssertEqual(completed, ["first"])
        let next = queue.nextBatch()!
        next[0].completions.forEach { $0() }
        XCTAssertEqual(completed, ["first", "during read"])
        XCTAssertNil(queue.nextBatch())
        XCTAssertTrue(queue.enqueue(id: "hr", payload: "hr") {})
    }

}
