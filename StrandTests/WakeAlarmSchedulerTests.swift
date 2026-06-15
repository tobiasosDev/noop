import XCTest
@testable import Strand

final class WakeAlarmSchedulerTests: XCTestCase {
    private let wake = Date(timeIntervalSince1970: 1_781_148_600)   // a fixed wake instant
    private let lead = WakeAlarmScheduler.windowLead
    private let grace = WakeAlarmScheduler.fireGrace

    func testNoTargetIsIdle() {
        XCTAssertEqual(
            WakeAlarmScheduler.decide(wakeTarget: nil, now: wake, lastFiredWake: nil), .idle)
    }

    func testFarBeforeWindowIsIdle() {
        let now = wake.addingTimeInterval(-lead - 60)   // just before the keep-alive window opens
        XCTAssertEqual(
            WakeAlarmScheduler.decide(wakeTarget: wake, now: now, lastFiredWake: nil), .idle)
    }

    func testInsideWindowOpensKeepAlive() {
        let now = wake.addingTimeInterval(-lead + 60)   // inside the lead window, before wake
        XCTAssertEqual(
            WakeAlarmScheduler.decide(wakeTarget: wake, now: now, lastFiredWake: nil),
            .openKeepAliveWindow)
    }

    func testAtTargetFires() {
        XCTAssertEqual(
            WakeAlarmScheduler.decide(wakeTarget: wake, now: wake, lastFiredWake: nil), .fire)
    }

    func testWithinGraceFires() {
        let now = wake.addingTimeInterval(grace - 1)
        XCTAssertEqual(
            WakeAlarmScheduler.decide(wakeTarget: wake, now: now, lastFiredWake: nil), .fire)
    }

    func testPastGraceDoesNotFire() {
        let now = wake.addingTimeInterval(grace + 1)
        XCTAssertEqual(
            WakeAlarmScheduler.decide(wakeTarget: wake, now: now, lastFiredWake: nil), .idle)
    }

    func testAlreadyFiredIsIdle() {
        // Same wake instant already fired (persisted across a state restoration) → never re-fire.
        XCTAssertEqual(
            WakeAlarmScheduler.decide(wakeTarget: wake, now: wake, lastFiredWake: wake), .idle)
    }

    func testNextDayWakeFiresAgain() {
        // A fired record for a DIFFERENT (previous) wake must not suppress today's alarm.
        let yesterday = wake.addingTimeInterval(-86_400)
        XCTAssertEqual(
            WakeAlarmScheduler.decide(wakeTarget: wake, now: wake, lastFiredWake: yesterday), .fire)
    }
}
