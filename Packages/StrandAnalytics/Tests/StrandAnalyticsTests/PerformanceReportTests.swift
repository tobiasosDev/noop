import XCTest
@testable import StrandAnalytics
import WhoopStore

final class PerformanceReportTests: XCTestCase {

    /// DailyMetric with only the fields the report reads.
    private func day(_ day: String, recovery: Double? = nil, strain: Double? = nil,
                     sleep: Double? = nil, hrv: Double? = nil, rhr: Int? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleep, efficiency: nil, deepMin: nil,
                    remMin: nil, lightMin: nil, disturbances: nil, restingHr: rhr,
                    avgHrv: hrv, recovery: recovery, strain: strain, exerciseCount: nil)
    }

    func testEmptyInputYieldsZeroCoverage() {
        let s = PerformanceReport.build(days: [], period: .weekly, today: "2026-06-10")
        XCTAssertEqual(s.coverage, 0)
        XCTAssertNil(s.recovery)
        XCTAssertNil(s.strain)
        XCTAssertNil(s.sleepMin)
    }

    func testWeeklyWindowSelectsTrailing7Days() {
        // 2026-06-04..2026-06-10 inclusive = the weekly window for today 2026-06-10.
        let days = [
            day("2026-06-03", recovery: 10),   // outside
            day("2026-06-04", recovery: 50),
            day("2026-06-10", recovery: 70),
        ]
        let s = PerformanceReport.build(days: days, period: .weekly, today: "2026-06-10")
        XCTAssertEqual(s.coverage, 2)
        XCTAssertEqual(s.fromDay, "2026-06-04")
        XCTAssertEqual(s.toDay, "2026-06-10")
        XCTAssertEqual(s.recovery?.value ?? -1, 60, accuracy: 1e-9)   // mean(50, 70)
    }

    func testDeltaAgainstPriorWindow() {
        // Prior week mean recovery 40, current week mean 60 → delta +20.
        let days = [
            day("2026-05-29", recovery: 40),   // prior window (05-28..06-03)
            day("2026-06-05", recovery: 60),
        ]
        let s = PerformanceReport.build(days: days, period: .weekly, today: "2026-06-10")
        XCTAssertEqual(s.recovery?.delta ?? -1, 20, accuracy: 1e-9)
    }

    func testDeltaNilWhenPriorWindowEmpty() {
        let s = PerformanceReport.build(days: [day("2026-06-05", recovery: 60)],
                                        period: .weekly, today: "2026-06-10")
        XCTAssertNil(s.recovery?.delta)
    }

    func testOverreachUnderreachCounting() {
        // recovery 50 → band 10.25...12.25. strain 14 = over, 5 = under, 11 = on target.
        let days = [
            day("2026-06-05", recovery: 50, strain: 14),
            day("2026-06-06", recovery: 50, strain: 5),
            day("2026-06-07", recovery: 50, strain: 11),
            day("2026-06-08", strain: 12),               // no recovery → not counted
        ]
        let s = PerformanceReport.build(days: days, period: .weekly, today: "2026-06-10")
        XCTAssertEqual(s.overreachDays, 1)
        XCTAssertEqual(s.underreachDays, 1)
    }

    func testBestWorstRecoveryDays() {
        let days = [
            day("2026-06-05", recovery: 30),
            day("2026-06-06", recovery: 90),
        ]
        let s = PerformanceReport.build(days: days, period: .weekly, today: "2026-06-10")
        XCTAssertEqual(s.bestRecoveryDay?.day, "2026-06-06")
        XCTAssertEqual(s.worstRecoveryDay?.day, "2026-06-05")
    }

    func testTakeawayForOverreach() {
        // Recovery 30 → band [7.35, 9.35]; strain 15 overreaches on all 6 window days.
        let days = (4...9).map { day("2026-06-0\($0)", recovery: 30, strain: 15) }
        let s = PerformanceReport.build(days: days, period: .weekly, today: "2026-06-10")
        XCTAssertTrue(s.takeaways.contains(.overreach(days: 6)))
    }

    func testTakeawayForRecoveryUp() {
        // Prior week mean recovery 40, current 60 → delta +20 ≥ +8 threshold.
        let days = [
            day("2026-05-29", recovery: 40),   // prior window (05-28..06-03)
            day("2026-06-05", recovery: 60),
        ]
        let s = PerformanceReport.build(days: days, period: .weekly, today: "2026-06-10")
        XCTAssertTrue(s.takeaways.contains(where: {
            if case .recoveryUp(let pct) = $0 { return abs(pct - 20) < 1e-9 }
            return false
        }))
    }

    func testTakeawayForRecoveryDown() {
        // Prior week mean recovery 60, current 40 → delta −20 ≤ −8 threshold; payload is the magnitude.
        let days = [
            day("2026-05-29", recovery: 60),   // prior window (05-28..06-03)
            day("2026-06-05", recovery: 40),
        ]
        let s = PerformanceReport.build(days: days, period: .weekly, today: "2026-06-10")
        XCTAssertTrue(s.takeaways.contains(where: {
            if case .recoveryDown(let pct) = $0 { return abs(pct - 20) < 1e-9 }
            return false
        }))
    }

    func testTakeawayForHRVDown() {
        // Prior week mean HRV 60, current 50 → delta −10 ≤ −3 threshold.
        let days = [
            day("2026-05-29", hrv: 60),        // prior window (05-28..06-03)
            day("2026-06-05", hrv: 50),
        ]
        let s = PerformanceReport.build(days: days, period: .weekly, today: "2026-06-10")
        XCTAssertTrue(s.takeaways.contains(.hrvDown))
    }

    func testTakeawayForHRVUp() {
        // Prior week mean HRV 50, current 60 → delta +10 ≥ +3 threshold.
        let days = [
            day("2026-05-29", hrv: 50),        // prior window (05-28..06-03)
            day("2026-06-05", hrv: 60),
        ]
        let s = PerformanceReport.build(days: days, period: .weekly, today: "2026-06-10")
        XCTAssertTrue(s.takeaways.contains(.hrvUp))
    }

    func testTakeawayForLowSleepPerformance() {
        // 300 min/night vs the 450-min need floor → 66.7% < 70% warn threshold.
        let days = (4...9).map { day("2026-06-0\($0)", sleep: 300) }
        let s = PerformanceReport.build(days: days, period: .weekly, today: "2026-06-10")
        XCTAssertTrue(s.takeaways.contains(where: {
            if case .lowSleepPerformance(let pct) = $0 { return abs(pct - 300.0 / 450.0 * 100.0) < 1e-9 }
            return false
        }))
    }
}
