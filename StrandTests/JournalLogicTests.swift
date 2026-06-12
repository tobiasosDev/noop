import XCTest
import WhoopStore
@testable import Strand

/// Pins the native-journal merge logic, mirroring the Android JournalLogTest value-for-value so the
/// two platforms merge catalogs and entries identically — question strings are opaque exact-match
/// keys to the effects engines on both sides.
@MainActor
final class JournalLogicTests: XCTestCase {

    private func e(_ day: String, _ q: String, _ yes: Bool) -> JournalEntry {
        JournalEntry(day: day, question: q, answeredYes: yes, notes: nil)
    }

    func testNativeWinsOnCollision() {
        let imported = [e("2026-06-09", "Did you drink any alcohol?", false)]
        let native = [e("2026-06-09", "Did you drink any alcohol?", true)]
        let merged = Repository.mergeJournal(imported: imported, native: native)
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].answeredYes)
    }

    func testDisjointKeysUnionAndSort() {
        let imported = [e("2026-06-09", "B?", true)]
        let native = [e("2026-06-10", "A?", false), e("2026-06-09", "A?", true)]
        let merged = Repository.mergeJournal(imported: imported, native: native)
        XCTAssertEqual(merged.count, 3)
        // Sorted day ASC then question ASC — matches the DAO/store read order.
        XCTAssertEqual(merged.map(\.question), ["A?", "B?", "A?"])
        XCTAssertEqual(merged.map(\.day), ["2026-06-09", "2026-06-09", "2026-06-10"])
    }

    @MainActor
    func testCatalogAdoptsImportedCasing() {
        let cat = JournalCatalogStore.mergeCatalog(imported: ["DID YOU DRINK ANY ALCOHOL?"], custom: [])
        XCTAssertEqual(cat.first, "DID YOU DRINK ANY ALCOHOL?")
        // The starter alcohol question deduped case-insensitively: 9 starters survive + 1 imported.
        XCTAssertEqual(cat.count, JournalCatalogStore.starterQuestions.count)
    }

    @MainActor
    func testCustomsAppendAndBlanksDrop() {
        let cat = JournalCatalogStore.mergeCatalog(imported: [],
                                                   custom: ["  ", "Did you nap?", "did you NAP?"])
        XCTAssertEqual(Array(cat.prefix(JournalCatalogStore.starterQuestions.count)),
                       JournalCatalogStore.starterQuestions)
        XCTAssertEqual(cat.last, "Did you nap?")
        XCTAssertEqual(cat.count, JournalCatalogStore.starterQuestions.count + 1)
    }

    @MainActor
    func testHiddenQuestionsFilteredOutCaseInsensitively() {
        // Hide one starter (different casing) + one custom; both must drop from the merged catalog.
        let cat = JournalCatalogStore.mergeCatalog(
            imported: [],
            custom: ["Did you nap?"],
            hidden: ["did you drink any alcohol?", "DID YOU NAP?"])
        XCTAssertFalse(cat.contains { $0.caseInsensitiveCompare("Did you drink any alcohol?") == .orderedSame })
        XCTAssertFalse(cat.contains { $0.caseInsensitiveCompare("Did you nap?") == .orderedSame })
        XCTAssertEqual(cat.count, JournalCatalogStore.starterQuestions.count - 1)
    }

    // MARK: - Behaviour-id-aware hiding (Journal screen curation)

    func testIsHiddenMatchesAcrossLanguageVariants() {
        // Hiding either language variant hides the whole behaviour: both strings resolve to the
        // "alcohol" behaviour id via the alias-aware catalog, so the German WHOOP export string
        // and the English canonical question hide together — never one visible orphan row.
        XCTAssertTrue(JournalCatalogStore.isHidden("Did you drink any alcohol?",
                                                   hidden: ["Alkohol konsumiert?"]))
        XCTAssertTrue(JournalCatalogStore.isHidden("Alkohol konsumiert?",
                                                   hidden: ["Did you drink any alcohol?"]))
        // A different behaviour stays visible.
        XCTAssertFalse(JournalCatalogStore.isHidden("Did you have any caffeine?",
                                                    hidden: ["Alkohol konsumiert?"]))
    }

    func testIsHiddenVerbatimFallbackForUnresolvedQuestions() {
        // Questions outside the catalog hide by normalized (trimmed, case-insensitive) match only.
        XCTAssertTrue(JournalCatalogStore.isHidden("My custom question?",
                                                   hidden: ["  MY CUSTOM QUESTION?  "]))
        XCTAssertFalse(JournalCatalogStore.isHidden("My custom question?",
                                                    hidden: ["Another custom question?"]))
    }
}
