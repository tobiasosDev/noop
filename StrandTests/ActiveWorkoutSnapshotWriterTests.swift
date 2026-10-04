import XCTest
import Foundation
import WhoopProtocol
@testable import Strand

/// `ActiveWorkoutSnapshotWriter`: off-main writes, byte-identical to `ActiveWorkoutPersistence.store`, and a
/// clear that a write still in flight can never undo.
final class ActiveWorkoutSnapshotWriterTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ActiveWorkoutSnapshotWriterTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func snapshot(samples n: Int) -> ActiveWorkoutPersistence.Snapshot {
        ActiveWorkoutPersistence.Snapshot(
            startSec: 1_700_000_000, sport: "Tennis",
            samples: (0..<n).map { HRSample(ts: 1_700_000_000 + $0, bpm: 100 + $0 % 60) },
            avgHr: 120, peakHr: 159, liveStrain: 6.5, pausedAtSec: nil, pausedDurationSec: 0)
    }

    func testWritesTheSameBytesAsTheSynchronousStore() {
        let writer = ActiveWorkoutSnapshotWriter(defaults: defaults)
        let snap = snapshot(samples: 300)
        writer.store(snap)
        writer.waitForPendingWrites()

        let reference = UserDefaults(suiteName: suiteName + "-ref")!
        defer { reference.removePersistentDomain(forName: suiteName + "-ref") }
        ActiveWorkoutPersistence.store(snap, into: reference)
        XCTAssertEqual(defaults.data(forKey: ActiveWorkoutPersistence.defaultsKey),
                       reference.data(forKey: ActiveWorkoutPersistence.defaultsKey))
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults), snap)
    }

    func testTheNewestSnapshotWins() {
        let writer = ActiveWorkoutSnapshotWriter(defaults: defaults)
        for n in 1...200 { writer.store(snapshot(samples: n)) }
        writer.waitForPendingWrites()
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults), snapshot(samples: 200))
    }

    func testClearIsNeverUndoneByAWriteInFlight() {
        let writer = ActiveWorkoutSnapshotWriter(defaults: defaults)
        for round in 0..<50 {
            writer.store(snapshot(samples: 2_000 + round))
            writer.clear()
            writer.waitForPendingWrites()
            XCTAssertNil(ActiveWorkoutPersistence.load(from: defaults), "round \(round)")
        }
    }

    func testAStoreAfterAClearIsKept() {
        let writer = ActiveWorkoutSnapshotWriter(defaults: defaults)
        writer.store(snapshot(samples: 10))
        writer.clear()
        writer.store(snapshot(samples: 20))
        writer.waitForPendingWrites()
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults), snapshot(samples: 20))
    }
}
