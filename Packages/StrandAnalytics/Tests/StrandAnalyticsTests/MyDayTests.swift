import XCTest
import WhoopStore
@testable import StrandAnalytics

final class MyDayTests: XCTestCase {
    // Fixed clock: 2026-06-10 12:00 UTC, UTC calendar — day = 2026-06-10.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let noon = Date(timeIntervalSince1970: 1_781_092_800) // 2026-06-10 12:00:00 UTC
    private let dayStart = 1_781_049_600                          // 2026-06-10 00:00:00 UTC

    private func sleep(start: Int, end: Int) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: end, efficiency: nil, restingHr: nil,
                           avgHrv: nil, stagesJSON: nil)
    }
    private func workout(start: Int) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + 1800, sport: "cycling", source: "my-whoop",
                   durationS: 1800, energyKcal: nil, avgHr: nil, maxHr: nil, strain: 6.5,
                   distanceM: nil, zonesJSON: nil, notes: nil)
    }

    func testSleepCountsWhenItEndsToday() {
        // Started yesterday 23:40, ended today 07:05 — counts.
        let s = sleep(start: dayStart - 1200, end: dayStart + 7 * 3600)
        let acts = MyDay.activities(sleeps: [s], workouts: [], now: noon, calendar: cal)
        XCTAssertEqual(acts.count, 1)
    }

    func testYesterdaysSleepExcluded() {
        let s = sleep(start: dayStart - 30 * 3600, end: dayStart - 1) // ended before midnight
        XCTAssertTrue(MyDay.activities(sleeps: [s], workouts: [], now: noon, calendar: cal).isEmpty)
    }

    func testWorkoutCountsWhenItStartsToday() {
        let w = workout(start: dayStart + 10 * 3600)
        XCTAssertEqual(MyDay.activities(sleeps: [], workouts: [w], now: noon, calendar: cal).count, 1)
    }

    func testYesterdaysWorkoutExcluded() {
        let w = workout(start: dayStart - 3600)
        XCTAssertTrue(MyDay.activities(sleeps: [], workouts: [w], now: noon, calendar: cal).isEmpty)
    }

    func testMergedSortedByStart() {
        let s = sleep(start: dayStart - 1200, end: dayStart + 7 * 3600)   // starts 23:40 yesterday
        let w = workout(start: dayStart + 10 * 3600)                       // 10:00 today
        let acts = MyDay.activities(sleeps: [s], workouts: [w], now: noon, calendar: cal)
        XCTAssertEqual(acts.count, 2)
        guard case .sleep = acts[0], case .workout = acts[1] else {
            return XCTFail("expected sleep then workout, got \(acts)")
        }
    }
}
