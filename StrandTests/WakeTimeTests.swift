import XCTest
@testable import Strand

final class WakeTimeTests: XCTestCase {
    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testReturnsTodayWhenTimeStillAhead() {
        let c = cal()
        // now = 2026-06-21 06:00 UTC; wake at 07:00 → today 07:00
        let now = c.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 6))!
        let wake = WakeTime.next(minutesSinceMidnight: 7 * 60, from: now, calendar: c)
        XCTAssertEqual(wake, c.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 7))!)
    }

    func testRollsToTomorrowWhenTimeAlreadyPassed() {
        let c = cal()
        // now = 2026-06-21 08:00 UTC; wake at 07:00 → tomorrow 07:00
        let now = c.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 8))!
        let wake = WakeTime.next(minutesSinceMidnight: 7 * 60, from: now, calendar: c)
        XCTAssertEqual(wake, c.date(from: DateComponents(year: 2026, month: 6, day: 22, hour: 7))!)
    }

    func testExactEqualNowRollsToTomorrow() {
        let c = cal()
        let now = c.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 7))!
        let wake = WakeTime.next(minutesSinceMidnight: 7 * 60, from: now, calendar: c)
        XCTAssertEqual(wake, c.date(from: DateComponents(year: 2026, month: 6, day: 22, hour: 7))!)
    }
}
