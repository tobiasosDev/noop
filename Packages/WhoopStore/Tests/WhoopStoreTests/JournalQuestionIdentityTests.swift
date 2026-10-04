import Foundation
import XCTest
@testable import WhoopStore

final class JournalQuestionIdentityTests: XCTestCase {
    func testStandaloneOraclePinsEveryAliasAndDistinctQuestions() throws {
        let json = #"["Did you drink any alcohol?", "Did you drink alcohol?", "Alkohol konsumiert?", "Alkohol getrunken?", "Hast du Alkohol konsumiert?", "Hast du Alkohol getrunken?", "Did you have caffeine late in the day?", "Spät am Tag Koffein konsumiert?", "Koffein spät am Tag konsumiert?", "Hast du spät am Tag Koffein konsumiert?", "Did you view a screen in bed?", "Einen Bildschirm im Bett angesehen?", "Im Bett auf einen Bildschirm geschaut?", "Bildschirm im Bett genutzt?", "Hast du im Bett auf einen Bildschirm geschaut?", "Did you eat close to bedtime?", "Kurz vor dem Schlafengehen gegessen?", "Kurz vor dem Zubettgehen gegessen?", "Hast du kurz vor dem Schlafengehen gegessen?", "Did you feel stressed?", "Dich gestresst gefühlt?", "Gestresst gefühlt?", "Hast du dich gestresst gefühlt?", "Did you use a sauna?", "Eine Sauna benutzt?", "Eine Sauna genutzt?", "In der Sauna gewesen?", "Hast du eine Sauna benutzt?", "Did you share your bed?", "Dein Bett geteilt?", "Das Bett geteilt?", "Hast du dein Bett geteilt?", "Did you feel sick or ill?", "Did you feel sick?", "Dich krank gefühlt?", "Krank gefühlt?", "Hast du dich krank gefühlt?", "Did you take magnesium?", "Magnesium eingenommen?", "Hast du Magnesium eingenommen?", "Did you read before bed?", "Vor dem Schlafengehen gelesen?", "Vor dem Zubettgehen gelesen?", "Hast du vor dem Schlafengehen gelesen?", "Did you feel bloated?", "Did you experience bloating?", "Blähungen gehabt?", "Hast du Blähungen gehabt?", "Did you have an injury or wound?", "Eine Verletzung oder Wunde haben?", "Eine Verletzung oder Wunde gehabt?", "Hast du eine Verletzung oder Wunde gehabt?", "  MAGNESIUM EINGENOMMEN?\n", "DICH KRANK GEFÜHLT?", "Koffein konsumiert?", "Did you have caffeine?", "Did you drink any alcohol yesterday?", "  My custom question  ", ""]"#
        let inputs = try JSONDecoder().decode([String].self, from: Data(json.utf8))
        let actual = inputs.map {
            JournalQuestionIdentity.canonical($0).replacingOccurrences(of: "\n", with: "\\n") + "|" + JournalQuestionIdentity.key($0)
        }.joined(separator: "\n")
        // The same standalone Swift stdout is embedded verbatim in the Kotlin twin.
        let expected = """
            Did you drink any alcohol?|did you drink any alcohol?
            Did you drink any alcohol?|did you drink any alcohol?
            Did you drink any alcohol?|did you drink any alcohol?
            Did you drink any alcohol?|did you drink any alcohol?
            Did you drink any alcohol?|did you drink any alcohol?
            Did you drink any alcohol?|did you drink any alcohol?
            Did you have caffeine late in the day?|did you have caffeine late in the day?
            Did you have caffeine late in the day?|did you have caffeine late in the day?
            Did you have caffeine late in the day?|did you have caffeine late in the day?
            Did you have caffeine late in the day?|did you have caffeine late in the day?
            Did you view a screen in bed?|did you view a screen in bed?
            Did you view a screen in bed?|did you view a screen in bed?
            Did you view a screen in bed?|did you view a screen in bed?
            Did you view a screen in bed?|did you view a screen in bed?
            Did you view a screen in bed?|did you view a screen in bed?
            Did you eat close to bedtime?|did you eat close to bedtime?
            Did you eat close to bedtime?|did you eat close to bedtime?
            Did you eat close to bedtime?|did you eat close to bedtime?
            Did you eat close to bedtime?|did you eat close to bedtime?
            Did you feel stressed?|did you feel stressed?
            Did you feel stressed?|did you feel stressed?
            Did you feel stressed?|did you feel stressed?
            Did you feel stressed?|did you feel stressed?
            Did you use a sauna?|did you use a sauna?
            Did you use a sauna?|did you use a sauna?
            Did you use a sauna?|did you use a sauna?
            Did you use a sauna?|did you use a sauna?
            Did you use a sauna?|did you use a sauna?
            Did you share your bed?|did you share your bed?
            Did you share your bed?|did you share your bed?
            Did you share your bed?|did you share your bed?
            Did you share your bed?|did you share your bed?
            Did you feel sick or ill?|did you feel sick or ill?
            Did you feel sick or ill?|did you feel sick or ill?
            Did you feel sick or ill?|did you feel sick or ill?
            Did you feel sick or ill?|did you feel sick or ill?
            Did you feel sick or ill?|did you feel sick or ill?
            Did you take magnesium?|did you take magnesium?
            Did you take magnesium?|did you take magnesium?
            Did you take magnesium?|did you take magnesium?
            Did you read before bed?|did you read before bed?
            Did you read before bed?|did you read before bed?
            Did you read before bed?|did you read before bed?
            Did you read before bed?|did you read before bed?
            Did you feel bloated?|did you feel bloated?
            Did you feel bloated?|did you feel bloated?
            Did you feel bloated?|did you feel bloated?
            Did you feel bloated?|did you feel bloated?
            Did you have an injury or wound?|did you have an injury or wound?
            Did you have an injury or wound?|did you have an injury or wound?
            Did you have an injury or wound?|did you have an injury or wound?
            Did you have an injury or wound?|did you have an injury or wound?
            Did you take magnesium?|did you take magnesium?
            Did you feel sick or ill?|did you feel sick or ill?
            Koffein konsumiert?|koffein konsumiert?
            Did you have caffeine?|did you have caffeine?
            Did you drink any alcohol yesterday?|did you drink any alcohol yesterday?
              My custom question  |my custom question
            |
            """
        XCTAssertEqual(actual, expected)
    }

    func testExperimentCandidatesDeduplicateTranslationsAndRespectHiddenAliases() {
        let candidates = JournalQuestionIdentity.candidates(
            logged: ["Did you share your bed?", "Did you drink any alcohol?"],
            imported: ["Dein Bett geteilt?", "Dich krank gefühlt?", "Did you feel sick or ill?"],
            hidden: ["Alkohol konsumiert?"], saved: "Dich krank gefühlt?")
        XCTAssertEqual(candidates, ["Did you share your bed?", "Did you feel sick or ill?"])
        XCTAssertEqual(JournalQuestionIdentity.candidates(logged: [], imported: [], hidden: [], saved: ""), [])
    }

    func testCanonicalAnswerWinsOverLegacyAliasRegardlessOfOrder() {
        let alias = JournalEntry(day: "2026-10-01", question: "Magnesium eingenommen?",
                                 answeredYes: false, notes: "legacy")
        let canonical = JournalEntry(day: alias.day, question: "Did you take magnesium?",
                                     answeredYes: true, notes: "native", numericValue: 200)
        for rows in [[alias, canonical], [canonical, alias]] {
            XCTAssertEqual(JournalEntry.canonicalEntries(rows), [canonical])
        }
        let nextDay = JournalEntry(day: "2026-10-02", question: alias.question,
                                   answeredYes: false, notes: alias.notes)
        let result = JournalEntry.canonicalEntries([canonical, nextDay])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1].question, canonical.question)
        XCTAssertEqual(result[1].answeredYes, false)
        XCTAssertEqual(result[1].notes, "legacy")
    }

    func testSaveAndClearReplaceAliasesWithinSourceAndDayOnly() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-10-01"
        let alias = JournalEntry(day: day, question: "Magnesium eingenommen?", answeredYes: true, notes: "imported")
        let english = JournalEntry(day: day, question: "Did you take magnesium?", answeredYes: false, notes: nil)
        let other = JournalEntry(day: day, question: "Did you read before bed?", answeredYes: false, notes: nil)
        let previous = JournalEntry(day: "2026-09-30", question: alias.question, answeredYes: true, notes: nil)
        try await store.upsertJournal([alias, english, other, previous], deviceId: "noop-journal")
        try await store.upsertJournal([alias], deviceId: "my-whoop")
        let replacement = JournalEntry(day: day, question: alias.question, answeredYes: true, notes: "edited", numericValue: 200)
        try await store.saveJournalAnswer(replacement, deviceId: "noop-journal")
        let saved = try await store.journalEntries(deviceId: "noop-journal", from: day, to: day)
        XCTAssertEqual(saved.count, 2)
        let answer = saved.first { $0.question == english.question }
        XCTAssertEqual(answer?.notes, "edited")
        XCTAssertEqual(answer?.numericValue, 200)
        XCTAssertEqual(answer?.answeredYes, true)
        // Simulate a legacy backup restoring an alias beside the canonical answer.
        try await store.upsertJournal([alias], deviceId: "noop-journal")
        let deleted = try await store.deleteJournal(deviceId: "noop-journal", day: day, question: alias.question)
        XCTAssertEqual(deleted, 2)
        let remaining = try await store.journalEntries(deviceId: "noop-journal", from: "2026-09-30", to: day)
        XCTAssertEqual(remaining, [previous, other])
        let imported = try await store.journalEntries(deviceId: "my-whoop", from: day, to: day)
        XCTAssertEqual(imported, [alias])
    }
}
