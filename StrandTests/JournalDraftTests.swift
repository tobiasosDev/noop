import XCTest
@testable import Strand
import WhoopStore

@MainActor
final class JournalDraftTests: XCTestCase {

    func testDraftMapsToEntriesWithDayKeyAndAnswers() {
        // Day key uses the importer's convention: Repository.localDayKey(targetDate).
        let day = Repository.localDayKey(Date(timeIntervalSince1970: 1_717_800_000)) // a fixed date
        var draft = JournalDraft(day: day)
        draft.answers["Did you drink any alcohol?"] = false
        draft.answers["Did you have any caffeine?"] = true
        draft.notes["Did you have any caffeine?"] = "One coffee"

        let entries = draft.entries()
        XCTAssertEqual(Set(entries.map(\.day)), [day])
        let caffeine = entries.first { $0.question == "Did you have any caffeine?" }
        XCTAssertEqual(caffeine?.answeredYes, true)
        XCTAssertEqual(caffeine?.notes, "One coffee")
        let alcohol = entries.first { $0.question == "Did you drink any alcohol?" }
        XCTAssertEqual(alcohol?.answeredYes, false)
        XCTAssertNil(alcohol?.notes)   // empty notes → nil, not ""
    }

    func testUnansweredQuestionsAreOmitted() {
        var draft = JournalDraft(day: "2026-06-08")
        draft.answers["Did you meditate?"] = nil      // skipped (—)
        draft.answers["Did you exercise today?"] = true
        XCTAssertEqual(draft.entries().map(\.question), ["Did you exercise today?"])
    }
}
