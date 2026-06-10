import XCTest
@testable import StrandAnalytics

final class SleepPlannerTests: XCTestCase {

    func testPeakWithDefaultsWrapsAcrossMidnight() {
        // wake 07:00 (420), need 450, no debt, default efficiency 0.90:
        // inBed = 450/0.9 = 500 → bed = 420 − 500 = −80 → wraps to 1360 (22:40).
        let r = SleepPlanner.recommend(wakeMinutes: 420, baseNeedMin: 450, debtMin: 0,
                                       efficiency: nil, goal: .peak)
        XCTAssertEqual(r.bedMinutes, 1360)
        XCTAssertEqual(r.inBedMin, 500, accuracy: 0.5)
        XCTAssertTrue(r.usedDefaults)
    }

    func testGetByLandsAfterMidnight() {
        // getBy = 70%: goalSleep = 315, inBed = 350 → bed = 420 − 350 = 70 (01:10).
        let r = SleepPlanner.recommend(wakeMinutes: 420, baseNeedMin: 450, debtMin: 0,
                                       efficiency: nil, goal: .getBy)
        XCTAssertEqual(r.bedMinutes, 70)
        XCTAssertFalse(r.bedMinutes < 0)
    }

    func testDebtRepaymentAddsToNeed() {
        // need = 480 + 0.3·60 = 498.
        let r = SleepPlanner.recommend(wakeMinutes: 420, baseNeedMin: 480, debtMin: 60,
                                       efficiency: 0.9, goal: .peak)
        XCTAssertEqual(r.needMin, 498, accuracy: 1e-9)
        XCTAssertFalse(r.usedDefaults)
    }

    func testEfficiencyFloorClamps() {
        // efficiency 0.5 clamps to 0.75: inBed = 450/0.75 = 600.
        let r = SleepPlanner.recommend(wakeMinutes: 420, baseNeedMin: 450, debtMin: 0,
                                       efficiency: 0.5, goal: .peak)
        XCTAssertEqual(r.inBedMin, 600, accuracy: 0.5)
    }

    func testGoalFractions() {
        XCTAssertEqual(SleepPlanner.Goal.peak.fraction, 1.0)
        XCTAssertEqual(SleepPlanner.Goal.perform.fraction, 0.85)
        XCTAssertEqual(SleepPlanner.Goal.getBy.fraction, 0.70)
    }
}
