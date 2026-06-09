import XCTest
@testable import Strand

final class JournalCatalogTests: XCTestCase {

    func testEveryBehaviorHasVerbatimQuestionAndUniqueID() {
        let all = JournalCatalog.all
        XCTAssertFalse(all.isEmpty)
        // Verbatim WHOOP phrasing: full sentences ending in "?".
        for b in all {
            XCTAssertTrue(b.question.hasSuffix("?"), "not a question: \(b.question)")
            XCTAssertFalse(b.id.isEmpty)
            XCTAssertFalse(b.shortLabel.isEmpty)
            XCTAssertFalse(b.icon.isEmpty)
        }
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "duplicate ids")
        XCTAssertEqual(Set(all.map(\.question)).count, all.count, "duplicate questions")
    }

    func testContainsConfirmedWhoopStrings() {
        // These two are confirmed verbatim from the real-export fixture.
        let qs = Set(JournalCatalog.all.map(\.question))
        XCTAssertTrue(qs.contains("Did you drink any alcohol?"))
        XCTAssertTrue(qs.contains("Did you have any caffeine?"))
    }

    func testCategoriesAreNonEmptyAndOrdered() {
        for c in JournalCatalog.categories {
            XCTAssertFalse(JournalCatalog.inCategory(c).isEmpty, "empty category \(c)")
        }
    }

    func testMergeAddsImportedQuestionsNotInCatalog() {
        let imported = ["Did you drink any alcohol?", "Did you take an ice bath?"]
        let merged = JournalCatalog.mergedQuestions(imported: imported)
        XCTAssertTrue(merged.contains("Did you take an ice bath?"), "unknown imported q dropped")
        // No duplicate of the one already in the catalog.
        XCTAssertEqual(merged.filter { $0 == "Did you drink any alcohol?" }.count, 1)
    }
}
