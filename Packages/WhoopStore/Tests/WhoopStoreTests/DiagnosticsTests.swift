import XCTest
import WhoopProtocol
@testable import WhoopStore

final class DiagnosticsTests: XCTestCase {
    func testSnapshotCountsSpansCursorsAndClockOffset() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "strap", mac: "AA", name: "WHOOP")

        // HR at ts 100 & 250; RR at 110; two events of one kind, one of another.
        let streams = Streams(
            hr: [HRSample(ts: 100, bpm: 60), HRSample(ts: 250, bpm: 62)],
            rr: [RRInterval(ts: 110, rrMs: 900)],
            events: [
                WhoopEvent(ts: 100, kind: "BATTERY_LEVEL(3)", payload: [:]),
                WhoopEvent(ts: 200, kind: "BATTERY_LEVEL(3)", payload: [:]),
                WhoopEvent(ts: 300, kind: "WRIST_ON", payload: [:]),
            ])
        _ = try await store.insert(streams, deviceId: "strap")

        try await store.setCursor("strap_trim", 5083)

        // A rawBatch whose strap clock trails wall time by 1000s → offsetSec == 1000.
        try await store.enqueueRawBatch(
            RawBatchMeta(batchId: "b1", deviceId: "strap",
                         clockRef: ClockRef(device: 1_000, wall: 2_000),
                         capturedAt: 2_000, startTs: 100, endTs: 300,
                         frameCount: 1, byteSize: 123),
            frames: [[0x01, 0x02]])

        let d = try await store.diagnosticsSnapshot()

        // ts-table stats.
        let hr = try XCTUnwrap(d.tsTables.first { $0.name == "hrSample" })
        XCTAssertEqual(hr.count, 2)
        XCTAssertEqual(hr.minTs, 100)
        XCTAssertEqual(hr.maxTs, 250)

        let rr = try XCTUnwrap(d.tsTables.first { $0.name == "rrInterval" })
        XCTAssertEqual(rr.count, 1)

        let ev = try XCTUnwrap(d.tsTables.first { $0.name == "event" })
        XCTAssertEqual(ev.count, 3)
        XCTAssertEqual(ev.minTs, 100)
        XCTAssertEqual(ev.maxTs, 300)

        // Empty stream → zero count, nil span.
        let spo2 = try XCTUnwrap(d.tsTables.first { $0.name == "spo2Sample" })
        XCTAssertEqual(spo2.count, 0)
        XCTAssertNil(spo2.minTs)

        // Per-device + event-kind aggregation.
        XCTAssertEqual(d.hrByDevice.first?.deviceId, "strap")
        XCTAssertEqual(d.hrByDevice.first?.count, 2)
        XCTAssertEqual(d.eventKinds.first?.kind, "BATTERY_LEVEL(3)")
        XCTAssertEqual(d.eventKinds.first?.count, 2)

        // Cursor round-trips into the snapshot.
        XCTAssertEqual(d.cursors.first { $0.name == "strap_trim" }?.value, 5083)

        // Clock offset surfaces the strap-vs-wall drift.
        let clock = try XCTUnwrap(d.latestClockRef)
        XCTAssertEqual(clock.offsetSec, 1_000)
        XCTAssertEqual(d.rawBatchCount, 1)
        XCTAssertEqual(d.rawBytes, 123)
    }

    func testHRHistogramAggregatesByBpm() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "d", mac: nil, name: nil)
        let s = Streams(hr: [
            HRSample(ts: 100, bpm: 60), HRSample(ts: 101, bpm: 60), HRSample(ts: 102, bpm: 60),
            HRSample(ts: 103, bpm: 75), HRSample(ts: 104, bpm: 75),
            HRSample(ts: 105, bpm: 142),
            HRSample(ts: 999, bpm: 50),   // outside the queried window
        ])
        _ = try await store.insert(s, deviceId: "d")

        let bins = try await store.hrHistogram(deviceId: "d", from: 100, to: 200)
        XCTAssertEqual(bins, [.init(bpm: 60, count: 3), .init(bpm: 75, count: 2), .init(bpm: 142, count: 1)])

        let empty = try await store.hrHistogram(deviceId: "d", from: 2000, to: 3000)
        XCTAssertTrue(empty.isEmpty)
    }

    func testSnapshotOnEmptyStore() async throws {
        let store = try await WhoopStore.inMemory()
        let d = try await store.diagnosticsSnapshot()
        XCTAssertEqual(d.schemaVersion, WhoopStoreInfo.schemaVersion)
        XCTAssertTrue(d.hrByDevice.isEmpty)
        XCTAssertTrue(d.eventKinds.isEmpty)
        XCTAssertNil(d.latestClockRef)
        XCTAssertEqual(d.tsTables.first { $0.name == "hrSample" }?.count, 0)
    }
}
