import XCTest
@testable import StrandAnalytics

final class GoalProgressTests: XCTestCase {

    private let week = ["2026-06-04", "2026-06-05", "2026-06-06", "2026-06-07",
                        "2026-06-08", "2026-06-09", "2026-06-10"]

    func testSleepDurationDailyHitsAndStreak() {
        // Hit on 06-07, 06-09, 06-10 → 3 hits / 5 days with data = 60%; streak 2 (09+10).
        let values = ["2026-06-05": 400.0, "2026-06-06": 430.0, "2026-06-07": 460.0,
                      "2026-06-09": 480.0, "2026-06-10": 470.0]
        let p = GoalProgress.evaluate(kind: .sleepDuration, target: 450,
                                      values: values, weekDays: week)
        XCTAssertEqual(p.week.count, 7)
        XCTAssertEqual(p.percent, 60, accuracy: 1e-9)
        XCTAssertEqual(p.streak, 2)
        XCTAssertEqual(p.todayValue ?? -1, 470, accuracy: 1e-9)
        XCTAssertTrue(p.todayHit)
    }

    func testStreakSkipsTodayWithoutData() {
        // No value for today (06-10); hits on 08+09 → streak 2 must survive.
        let values = ["2026-06-08": 12000.0, "2026-06-09": 11000.0]
        let p = GoalProgress.evaluate(kind: .dailySteps, target: 10000,
                                      values: values, weekDays: week)
        XCTAssertEqual(p.streak, 2)
        XCTAssertNil(p.todayValue)
        XCTAssertFalse(p.todayHit)
    }

    func testMissedDayBreaksStreak() {
        // 06-08 miss (below target) between hits → streak counts only 09+10.
        let values = ["2026-06-07": 12000.0, "2026-06-08": 4000.0,
                      "2026-06-09": 11000.0, "2026-06-10": 10500.0]
        let p = GoalProgress.evaluate(kind: .dailySteps, target: 10000,
                                      values: values, weekDays: week)
        XCTAssertEqual(p.streak, 2)
    }

    func testWeeklyStrainUsesWeekAverage() {
        // avg(10, 14) = 12 vs target 14 → 85.7%; no streak for weeklyStrain.
        let values = ["2026-06-09": 10.0, "2026-06-10": 14.0]
        let p = GoalProgress.evaluate(kind: .weeklyStrain, target: 14,
                                      values: values, weekDays: week)
        XCTAssertEqual(p.percent, 12.0 / 14.0 * 100, accuracy: 1e-6)
        XCTAssertEqual(p.streak, 0)
    }

    func testMissTodayBreaksStreakImmediately() {
        // Today has data but is a miss -> streak 0 despite prior hits.
        let values = ["2026-06-08": 12000.0, "2026-06-09": 11000.0, "2026-06-10": 3000.0]
        let p = GoalProgress.evaluate(kind: .dailySteps, target: 10000,
                                      values: values, weekDays: week)
        XCTAssertEqual(p.streak, 0)
        XCTAssertFalse(p.todayHit)
    }

    func testEmptyWeekDaysDoesNotTrap() {
        // Contract violation guard: empty weekDays must not crash.
        let p = GoalProgress.evaluate(kind: .dailySteps, target: 10000,
                                      values: [:], weekDays: [])
        XCTAssertEqual(p.streak, 0)
        XCTAssertEqual(p.percent, 0)
        XCTAssertNil(p.todayValue)
    }

    func testNoDataAtAll() {
        let p = GoalProgress.evaluate(kind: .sleepDuration, target: 450,
                                      values: [:], weekDays: week)
        XCTAssertEqual(p.percent, 0)
        XCTAssertEqual(p.streak, 0)
        XCTAssertNil(p.todayValue)
    }
}
