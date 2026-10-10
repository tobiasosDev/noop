import XCTest
import WhoopStore
@testable import Strand

/// Known WHOOP and starter questions resolve to a stable English display key and a real icon.
/// The localized string follows the app language at runtime. These tests pin the English key.
final class JournalQuestionDisplayTests: XCTestCase {

    private func item(_ canonical: String, rename: String? = nil,
                      group: JournalGroup = .other) -> JournalCatalogItem {
        JournalCatalogItem(canonical: canonical, displayName: rename, kind: .bool,
                           group: group, sortIndex: 0, hidden: false, custom: false)
    }

    func testListedQuestionsResolveToEnglishAndASpecificIcon() {
        let cases: [(raw: String, english: String, icon: String)] = [
            ("Im Bett auf ein Gerät mit Bildschirm geschaut?", "Did you view a screen device in bed?", "device-mobile"),
            ("Unter Stress gestanden?", "Did you experience stress?", "lightning"),
            ("Probiotikum eingenommen?", "Did you take a probiotic?", "flask"),
            ("Kreatin eingenommen?", "Did you take creatine?", "barbell"),
            ("Koffein konsumiert?", "Did you have caffeine?", "coffee"),
            ("Im Home Office gearbeitet?", "Did you work from home?", "house"),
            ("Etwas Interessantes oder Wichtiges gelernt?", "Did you learn something interesting or important?", "lightbulb"),
            ("im Bett gelesen (kein Gerät mit Bildschirm)?", "Did you read in bed (not a screen device)?", "book-open"),
            ("Hast du ein Dampfbad benutzt?", "Did you use a steam room?", "cloud"),
            ("Milchprodukte konsumiert?", "Did you have dairy?", "cheese"),
            ("Genug Wasser getrunken?", "Did you drink enough water?", "drop"),
            ("Eiweiß eingenommen?", "Did you have protein?", "egg"),
            ("Kontakt mit Familie oder Freunden gehabt?", "Did you spend time with family or friends?", "users-three"),
            ("Hast du Kopfschmerzen gehabt?", "Did you have a headache?", "brain"),
            ("Eine Hitzewallung im Schlaf gehabt?", "Did you have a hot flash while sleeping?", "fire"),
            ("Zur Arbeit gependelt?", "Did you commute to work?", "car"),
            ("Zusätzlichen Zucker konsumiert?", "Did you have added sugar?", "cube"),
            ("Mich nervös oder ängstlich gefühlt?", "Did you feel nervous or anxious?", "smiley-nervous"),
            ("Den ganzen Tag über voller Energie gefühlt?", "Did you feel full of energy all day?", "battery-high"),
            ("Hast du deine Beleuchtung nach Sonnenuntergang gedimmt?", "Did you dim your lights after sunset?", "lightbulb-filament"),
            ("Hast du alle deine Mahlzeiten tagsüber eingenommen?", "Did you eat all your meals during daylight?", "fork-knife"),
            ("Beim Aufwachen direktes Sonnenlicht gesehen?", "Did you see direct sunlight when you woke up?", "sun"),
            ("Ein entzündungshemmenden Medikaments (NSAID) eingenommen?", "Did you take an anti-inflammatory (NSAID)?", "pill"),
            ("Verschreibungspflichtige Schlafmittel eingenommen?", "Did you take a prescription sleeping pill?", "moon"),
            ("Kalzium zu dir genommen?", "Did you take calcium?", "pill"),
            ("Ein Melatoninpräparat eingenommen?", "Did you take a melatonin supplement?", "moon-stars"),
            ("Mit dem Flugzeug gereist?", "Did you travel by plane?", "airplane"),
            ("Eine kalte Dusche genommen?", "Did you take a cold shower?", "shower"),
            ("Did you view a screen in bed?", "Did you view a screen in bed?", "device-mobile"),
            ("Did you use a sauna?", "Did you use a sauna?", "thermometer-hot"),
            ("Did you take magnesium?", "Did you take magnesium?", "pill"),
            ("Did you share your bed?", "Did you share your bed?", "users"),
            ("Did you read before bed?", "Did you read before bed?", "book-open"),
            ("Did you have caffeine late in the day?", "Did you have caffeine late in the day?", "coffee"),
            ("Did you eat close to bedtime?", "Did you eat close to bedtime?", "fork-knife"),
            ("Did you drink any alcohol?", "Did you drink any alcohol?", "wine"),
            ("Did you feel stressed?", "Did you feel stressed?", "lightning"),
            ("Did you feel sick or ill?", "Did you feel sick or ill?", "first-aid-kit"),
            ("Did you feel bloated?", "Did you feel bloated?", "wind"),
            ("Did you have an injury or wound?", "Did you have an injury or wound?", "bandaids"),
            // Identity already merges these onto the English starter. They are not a second behaviour.
            ("Blähungen gehabt?", "Did you feel bloated?", "wind"),
            ("Alkohol konsumiert?", "Did you drink any alcohol?", "wine"),
            ("Dein Bett geteilt?", "Did you share your bed?", "users"),
            ("Dich krank gefühlt?", "Did you feel sick or ill?", "first-aid-kit"),
            ("Hast du eine Sauna benutzt?", "Did you use a sauna?", "thermometer-hot"),
            ("Eine Verletzung oder Wunde haben?", "Did you have an injury or wound?", "bandaids"),
        ]
        for row in cases {
            XCTAssertEqual(JournalQuestionDisplay.englishKey(forCanonical: row.raw), row.english, row.raw)
            XCTAssertEqual(JournalQuestionDisplay.iconName(forCanonical: row.raw), row.icon, row.raw)
            let icon = JournalLogCard.icon(for: item(row.raw))
            XCTAssertEqual(icon, row.icon, row.raw)
            XCTAssertNotEqual(icon, "notebook", row.raw)
        }
    }

    func testSimilarQuestionsStaySeparate() {
        XCTAssertNotEqual(
            JournalQuestionDisplay.englishKey(forCanonical: "Koffein konsumiert?"),
            JournalQuestionDisplay.englishKey(forCanonical: "Did you have caffeine late in the day?"))
        XCTAssertNotEqual(
            JournalQuestionDisplay.englishKey(forCanonical: "im Bett gelesen (kein Gerät mit Bildschirm)?"),
            JournalQuestionDisplay.englishKey(forCanonical: "Did you read before bed?"))
        XCTAssertNotEqual(
            JournalQuestionDisplay.englishKey(forCanonical: "Im Bett auf ein Gerät mit Bildschirm geschaut?"),
            JournalQuestionDisplay.englishKey(forCanonical: "Did you view a screen in bed?"))
    }

    func testRenameStaysVerbatimAndIconFollowsCanonical() {
        let row = item("Koffein konsumiert?", rename: "My coffee")
        XCTAssertEqual(JournalQuestionDisplay.label(for: row), "My coffee")
        XCTAssertEqual(JournalLogCard.icon(for: row), "coffee")
    }

    func testUnknownQuestionStaysVerbatimWithTheFallbackIcon() {
        let raw = "Did you have a great sunset?"
        XCTAssertNil(JournalQuestionDisplay.englishKey(forCanonical: raw))
        XCTAssertEqual(JournalQuestionDisplay.label(forCanonical: raw), raw)
        // "sun" inside "sunset" and "eat" inside "great" must not steal an icon.
        XCTAssertEqual(JournalLogCard.icon(for: item(raw)), "notebook")
    }
}
