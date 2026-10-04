import XCTest
@testable import Strand

final class HeartRateWritebackDeltaTests: XCTestCase {
    private func value(_ bpm: Double = 60, end: Int) -> HeartRateWritebackDelta.Value {
        .init(bpm: bpm, endTs: end)
    }

    func testFirstPassReconcilesEntireWindowAndIdenticalPassDoesNothing() {
        let snapshot = [120: value(end: 180), 180: value(end: 240)]
        XCTAssertEqual(HeartRateWritebackDelta.changedRange(previous: nil, current: snapshot,
                                                           window: 0..<300), 0..<300)
        XCTAssertNil(HeartRateWritebackDelta.changedRange(previous: snapshot, current: snapshot,
                                                         window: 0..<360))
    }

    func testNewMinuteDoesNotRewriteHistoricalMinutes() {
        let previous = [120: value(end: 180), 180: value(end: 240)]
        var current = previous
        current[240] = value(70, end: 260)
        XCTAssertEqual(HeartRateWritebackDelta.changedRange(previous: previous, current: current,
                                                           window: 0..<320), 240..<300)
    }

    func testCorrectionRemovalAndPartialMinuteEndAreReconciled() {
        let previous = [120: value(end: 180), 180: value(end: 240), 240: value(end: 250)]
        var current = previous
        current[120] = value(65, end: 180)
        XCTAssertEqual(HeartRateWritebackDelta.changedRange(previous: previous, current: current,
                                                           window: 0..<320), 120..<180)
        current = previous
        current[180] = nil
        XCTAssertEqual(HeartRateWritebackDelta.changedRange(previous: previous, current: current,
                                                           window: 0..<320), 180..<240)
        current = previous
        current[240] = value(end: 270)
        XCTAssertEqual(HeartRateWritebackDelta.changedRange(previous: previous, current: current,
                                                           window: 0..<330), 240..<300)
    }

    func testExpiredBucketsArePreservedInHealthAndRemovedFromComparison() {
        let previous = [120: value(end: 180), 180: value(end: 240)]
        let current = [180: value(end: 240)]
        XCTAssertNil(HeartRateWritebackDelta.changedRange(previous: previous, current: current,
                                                         window: 180..<360))
    }

    func testEmptyInitialReadDoesNotDeleteUnknownHealthData() {
        XCTAssertNil(HeartRateWritebackDelta.changedRange(previous: nil, current: [:], window: 0..<360))
        XCTAssertEqual(HeartRateWritebackDelta.changedRange(previous: [120: value(end: 180)],
                                                           current: [:], window: 0..<360), 120..<180)
    }

    func testInvalidatedCacheRetriesFullWindowAfterPartialFailure() {
        let current = [120: value(end: 180), 240: value(end: 300)]
        XCTAssertEqual(HeartRateWritebackDelta.changedRange(previous: nil, current: current,
                                                           window: 0..<360), 0..<360)
    }

    @MainActor
    func testPartialSaveFailureDoesNotCommitAndRetryStartsWithDeletion() async throws {
        enum Failure: Error { case save }
        var events: [String] = []
        var cursor = 0
        do {
            try await HeartRateWritebackDelta.replace(sampleCount: 5, chunkSize: 2, delete: {
                events.append("delete")
            }, save: { range in
                events.append("save:\(range.lowerBound)-\(range.upperBound)")
                if range.lowerBound == 2 { throw Failure.save }
            }, commit: { cursor = 300 })
            XCTFail("Expected failed second chunk")
        } catch Failure.save { }
        XCTAssertEqual(cursor, 0)
        XCTAssertEqual(events, ["delete", "save:0-2", "save:2-4"])
        events = []
        try await HeartRateWritebackDelta.replace(sampleCount: 5, chunkSize: 2, delete: {
            events.append("delete")
        }, save: { range in
            events.append("save:\(range.lowerBound)-\(range.upperBound)")
        }, commit: { cursor = 300; events.append("commit") })
        XCTAssertEqual(cursor, 300)
        XCTAssertEqual(events, ["delete", "save:0-2", "save:2-4", "save:4-5", "commit"])
    }

    @MainActor
    func testDeleteFailureDoesNotSaveOrCommit() async throws {
        enum Failure: Error { case delete }
        var saved = false
        var committed = false
        do {
            try await HeartRateWritebackDelta.replace(sampleCount: 1, delete: {
                throw Failure.delete
            }, save: { _ in saved = true }, commit: { committed = true })
            XCTFail("Expected failed delete")
        } catch Failure.delete { }
        XCTAssertFalse(saved)
        XCTAssertFalse(committed)
    }

}
