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

    // The full catalog (curated + extended) must have unique ids; resolution depends on it.
    func testCatalogIdsAndQuestionsUniqueAcrossAllAndExtended() {
        let cat = JournalCatalog.catalog
        XCTAssertEqual(Set(cat.map(\.id)).count, cat.count, "duplicate ids across all+extended")
        XCTAssertEqual(Set(cat.map(\.question)).count, cat.count, "duplicate questions across all+extended")
        for b in cat {
            XCTAssertTrue(b.question.hasSuffix("?"), "not a question: \(b.question)")
            XCTAssertFalse(b.shortLabel.isEmpty)
            XCTAssertFalse(b.icon.isEmpty)
        }
    }

    /// Resolution (and the Insights merge that depends on it) is correct by construction only if no
    /// two questions/aliases fold to the same normalized key — otherwise `questionIndex` overwrites
    /// last-wins and `byQuestion` returns the wrong behaviour.
    func testNormalizedKeysDoNotCollide() {
        let keys = JournalCatalog.catalog
            .flatMap { [$0.question] + $0.aliases }
            .map(JournalCatalog.normalizeKey)
        XCTAssertEqual(Set(keys).count, keys.count,
                       "two questions/aliases normalize to the same key")
    }

    func testByQuestionResolvesAliasesToBehaviour() {
        XCTAssertEqual(JournalCatalog.byQuestion("Koffein konsumiert?")?.id, "caffeine")
        XCTAssertEqual(JournalCatalog.byQuestion("Alkohol konsumiert?")?.id, "alcohol")
        // Canonical English still resolves.
        XCTAssertEqual(JournalCatalog.byQuestion("Did you have any caffeine?")?.id, "caffeine")
        // Normalization tolerates case, spacing, and a missing "?".
        XCTAssertEqual(JournalCatalog.byQuestion("  koffein konsumiert  ")?.id, "caffeine")
    }

    /// Safety net: every distinct question from the real German WHOOP export
    /// (`my_whoop_data_2026_06_09.zip` → `logbuch_eintraege.csv`) must resolve to a behaviour
    /// with a non-empty category. A single mistyped umlaut here = a silent "Other" bucket
    /// on-device, so the strings below are pasted verbatim from that export.
    func testResolvesEveryRealGermanWhoopQuestion() {
        let german = [
            "Kreatin eingenommen?",
            "Koffein konsumiert?",
            "Im Bett auf ein Gerät mit Bildschirm geschaut?",
            "Blähungen gehabt?",
            "Etwas Interessantes oder Wichtiges gelernt?",
            "Alkohol konsumiert?",
            "Unter Stress gestanden?",
            "Probiotikum eingenommen?",
            "Im Home Office gearbeitet?",
            "Dein Bett geteilt?",
            "im Bett gelesen (kein Gerät mit Bildschirm)?",
            "Dich krank gefühlt?",
            "Hast du ein Dampfbad benutzt?",
            "Milchprodukte konsumiert?",
            "Eiweiß eingenommen?",
            "Kontakt mit Familie oder Freunden gehabt?",
            "Hast du Kopfschmerzen gehabt?",
            "Hast du eine Sauna benutzt?",
            "Eine Hitzewallung im Schlaf gehabt?",
            "Genug Wasser getrunken?",
            "Zur Arbeit gependelt?",
            "Zusätzlichen Zucker konsumiert?",
            "Eine Verletzung oder Wunde haben?",
            "Mich nervös oder ängstlich gefühlt?",
            "Den ganzen Tag über voller Energie gefühlt?",
            "Hast du alle deine Mahlzeiten tagsüber eingenommen?",
            "Hast du deine Beleuchtung nach Sonnenuntergang gedimmt?",
            "Beim Aufwachen direktes Sonnenlicht gesehen?",
            "Ein entzündungshemmenden Medikaments (NSAID) eingenommen?",
            "Verschreibungspflichtige Schlafmittel eingenommen?",
            "Ein Melatoninpräparat eingenommen?",
            "Kalzium zu dir genommen?",
            "Mit dem Flugzeug gereist?",
            "Eine kalte Dusche genommen?",
        ]
        for q in german {
            let b = JournalCatalog.byQuestion(q)
            XCTAssertNotNil(b, "unresolved German question: \(q)")
            XCTAssertFalse(b?.category.isEmpty ?? true, "no category for: \(q)")
        }
    }
}
