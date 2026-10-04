import XCTest
@testable import Strand

/// The backfill idle watchdog keeps ONE pending check and moves a progress stamp per offload frame,
/// instead of cancelling and re-scheduling a 60 s `asyncAfter` item on every frame (main-thread hitch: a
/// cancelled item stays queued until its deadline, so a long drain left thousands of them on the main
/// queue). The session must still time out when it did before: `backfillIdleTimeoutSeconds` after the
/// last frame. Both shapes are replayed here over the same frame arrivals.
@MainActor
final class BackfillTimeoutRecheckTests: XCTestCase {

    private var timeout: Int { BLEManager.backfillIdleTimeoutSeconds }
    /// Far from zero: `DispatchTime(uptimeNanoseconds: 0)` means "now".
    private let base: UInt64 = 1_000_000_000_000

    private func at(_ seconds: Double) -> DispatchTime {
        DispatchTime(uptimeNanoseconds: base + UInt64(seconds * 1e9))
    }

    /// The old shape: every frame re-armed the deadline, so the session timed out at the first frame
    /// that was followed by a full window of silence.
    private func oldTimeout(frames: [Double]) -> Double {
        for (i, f) in frames.enumerated() where i + 1 == frames.count || frames[i + 1] >= f + Double(timeout) {
            return f + Double(timeout)
        }
        return .nan
    }

    /// The new shape, driven exactly as `BLEManager` drives it: the first frame arms one check; a frame
    /// only moves the stamp; a check that runs early re-arms at the date `backfillTimeoutRecheck` names.
    private func newTimeout(frames: [Double]) -> (firedAt: DispatchTime, checks: Int) {
        var lastProgress = at(frames[0])
        var check = lastProgress + .seconds(timeout)
        var checks = 1
        var next = 1
        while true {
            while next < frames.count, at(frames[next]) < check {
                lastProgress = at(frames[next])
                next += 1
            }
            guard let recheck = BLEManager.backfillTimeoutRecheck(now: check, lastProgress: lastProgress,
                                                                  timeoutSeconds: timeout) else {
                return (check, checks)
            }
            check = recheck
            checks += 1
        }
    }

    private func assertSameTimeout(_ frames: [Double], file: StaticString = #filePath, line: UInt = #line) {
        let expected = at(oldTimeout(frames: frames)).uptimeNanoseconds
        let actual = newTimeout(frames: frames).firedAt.uptimeNanoseconds
        let drift = expected > actual ? expected - actual : actual - expected
        XCTAssertLessThan(drift, 1_000_000, "timed out \(drift) ns away from the old deadline", file: file, line: line)
    }

    func testASingleFrameTimesOutOneWindowLater() {
        assertSameTimeout([0])
    }

    /// A long, dense drain: the old shape scheduled one work item per frame (6,000 here); the new one
    /// re-checks about once per window and still times out a full window after the last frame.
    func testADenseDrainTimesOutAWindowAfterItsLastFrame() {
        let frames = (0..<6_000).map { Double($0) * 0.05 }
        assertSameTimeout(frames)
        XCTAssertLessThanOrEqual(newTimeout(frames: frames).checks, 300 / timeout + 2)
    }

    /// Lulls just under, at and just over the window, the shapes the 60 s choice was tuned for.
    func testLullsAroundTheWindowEndTheSessionWhereTheyDidBefore() {
        let w = Double(timeout)
        assertSameTimeout([0, 1, 2, w + 1.9, w + 2.5])
        assertSameTimeout([0, 10, 10 + w - 0.001, 10 + 2 * w - 0.002])
        assertSameTimeout([0, 10, 10 + w + 0.5, 11 + w])
        assertSameTimeout([0, 0.5, 30, 30.25, 89.9, 149.8, 150, 209.99])
    }

    func testRecheckTimesOutOnlyOnceTheWholeWindowIsSilent() {
        let last = at(100)
        XCTAssertEqual(BLEManager.backfillTimeoutRecheck(now: at(100 + Double(timeout) - 0.001), lastProgress: last,
                                                         timeoutSeconds: timeout),
                       last + .seconds(timeout))
        XCTAssertNil(BLEManager.backfillTimeoutRecheck(now: last + .seconds(timeout), lastProgress: last,
                                                       timeoutSeconds: timeout))
        XCTAssertNil(BLEManager.backfillTimeoutRecheck(now: at(500), lastProgress: last, timeoutSeconds: timeout))
    }
}
