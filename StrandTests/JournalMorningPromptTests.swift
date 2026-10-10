import XCTest
@testable import Strand

/// The morning journal sheet is a pure decision: 04:00 inclusive through 12:00 exclusive,
/// once per local calendar day, and only when yesterday is still unanswered.
final class JournalMorningPromptTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private let today = "2026-10-10"

    private func at(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: hour, minute: minute))!
    }

    private func decide(_ date: Date, shown: String? = nil, answered: Bool = false) -> Bool {
        JournalMorningPrompt.shouldPresent(
            now: date, calendar: calendar, shownDay: shown,
            todayKey: today, yesterdayAnswered: answered)
    }

    func testWindowEdgesAndGuards() {
        XCTAssertFalse(decide(at(3, 59)))
        XCTAssertTrue(decide(at(4, 0)))
        XCTAssertTrue(decide(at(11, 59)))
        XCTAssertFalse(decide(at(12, 0)))
        XCTAssertFalse(decide(at(8, 0), shown: today))
        XCTAssertTrue(decide(at(8, 0), shown: "2026-10-09"))
        XCTAssertFalse(decide(at(8, 0), answered: true))
    }
}
