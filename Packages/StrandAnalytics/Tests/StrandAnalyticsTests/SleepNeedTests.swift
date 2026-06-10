import XCTest
@testable import StrandAnalytics

final class SleepNeedTests: XCTestCase {

    func testFloorAppliesWhenMeanBelow() {
        // mean(400, 420) = 410 < 450 floor.
        XCTAssertEqual(SleepNeed.needMin(totalSleepMinsByNight: [400, 420]), 450, accuracy: 1e-9)
    }

    func testMeanWinsAboveFloor() {
        XCTAssertEqual(SleepNeed.needMin(totalSleepMinsByNight: [480, 500]), 490, accuracy: 1e-9)
    }

    func testZerosAndEmptyIgnored() {
        XCTAssertEqual(SleepNeed.needMin(totalSleepMinsByNight: []), 450, accuracy: 1e-9)
        XCTAssertEqual(SleepNeed.needMin(totalSleepMinsByNight: [0, 0, 480]), 480, accuracy: 1e-9)
        XCTAssertEqual(SleepNeed.needMin(totalSleepMinsByNight: [-30, 480]), 480, accuracy: 1e-9)
    }

    func testDebtFlooredAtZero() {
        XCTAssertEqual(SleepNeed.debtMin(needMin: 450, asleepMin: 400), 50, accuracy: 1e-9)
        XCTAssertEqual(SleepNeed.debtMin(needMin: 450, asleepMin: 500), 0, accuracy: 1e-9)
    }

    // MARK: performancePct

    func testPerformancePctNilWhenNoSleep() {
        XCTAssertNil(SleepNeed.performancePct(needMin: 450, asleepMin: nil))
        XCTAssertNil(SleepNeed.performancePct(needMin: 450, asleepMin: 0))
    }

    func testPerformancePctComputesRatio() {
        XCTAssertEqual(SleepNeed.performancePct(needMin: 450, asleepMin: 360)!, 80, accuracy: 0.01)
    }

    func testPerformancePctCapsAt100() {
        XCTAssertEqual(SleepNeed.performancePct(needMin: 450, asleepMin: 600)!, 100, accuracy: 0.01)
    }

    func testPerformancePctNilWhenNeedZero() {
        XCTAssertNil(SleepNeed.performancePct(needMin: 0, asleepMin: 400))
    }
}
