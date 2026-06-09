import XCTest
@testable import Strand

final class JournalReminderTests: XCTestCase {
    func testMinutesToDateComponents() {
        let c = JournalReminder.components(minutesSinceMidnight: 8 * 60 + 30)
        XCTAssertEqual(c.hour, 8)
        XCTAssertEqual(c.minute, 30)
    }
    func testClampsOutOfRange() {
        XCTAssertEqual(JournalReminder.components(minutesSinceMidnight: -5).hour, 0)
        XCTAssertEqual(JournalReminder.components(minutesSinceMidnight: -5).minute, 0)
        XCTAssertEqual(JournalReminder.components(minutesSinceMidnight: 99 * 60).hour, 23)
        XCTAssertEqual(JournalReminder.components(minutesSinceMidnight: 99 * 60).minute, 59)
    }
}
