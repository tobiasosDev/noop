import XCTest
@testable import Strand

final class WakeAlarmNotifierTests: XCTestCase {
    func testFireComponents_areHourAndMinuteOnly() {
        let comps = WakeAlarmNotifier.fireComponents(minutesSinceMidnight: 7 * 60 + 30)
        XCTAssertEqual(comps.hour, 7)
        XCTAssertEqual(comps.minute, 30)
        XCTAssertNil(comps.day, "calendar trigger should match time-of-day, not a fixed date")
    }

    func testIdentifierIsStable() {
        XCTAssertEqual(WakeAlarmNotifier.identifier, "noop.wakeAlarm")
    }
}
