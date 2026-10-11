import Foundation
import WhoopStore

/// Display-only labels and icons for journal questions.
///
/// Stored keys, `JournalQuestionIdentity.canonical`, and the database stay as they are.
/// A known question maps to one English catalog key, then `String(localized:)`, so the app
/// language can translate it. A user rename and any unknown question stay verbatim.
enum JournalQuestionDisplay {
    /// `canonical` is the string `JournalQuestionIdentity.canonical` returns. German questions
    /// that identity already merges are listed under that English result. German questions it
    /// leaves alone are listed under their stored wording, which is a different behaviour.
    private struct KnownQuestion {
        let canonical: String
        let english: String
        let icon: String
    }

    private static let known: [KnownQuestion] = [
        KnownQuestion(canonical: "Probiotikum eingenommen?",
                      english: "Did you take a probiotic?", icon: "flask"),
        KnownQuestion(canonical: "Kreatin eingenommen?",
                      english: "Did you take creatine?", icon: "barbell"),
        KnownQuestion(canonical: "Im Home Office gearbeitet?",
                      english: "Did you work from home?", icon: "house"),
        KnownQuestion(canonical: "Etwas Interessantes oder Wichtiges gelernt?",
                      english: "Did you learn something interesting or important?", icon: "lightbulb"),
        KnownQuestion(canonical: "Hast du ein Dampfbad benutzt?",
                      english: "Did you use a steam room?", icon: "cloud"),
        KnownQuestion(canonical: "Milchprodukte konsumiert?",
                      english: "Did you have dairy?", icon: "cheese"),
        KnownQuestion(canonical: "Genug Wasser getrunken?",
                      english: "Did you drink enough water?", icon: "drop"),
        KnownQuestion(canonical: "Eiweiß eingenommen?",
                      english: "Did you have protein?", icon: "egg"),
        KnownQuestion(canonical: "Kontakt mit Familie oder Freunden gehabt?",
                      english: "Did you spend time with family or friends?", icon: "users-three"),
        KnownQuestion(canonical: "Hast du Kopfschmerzen gehabt?",
                      english: "Did you have a headache?", icon: "brain"),
        KnownQuestion(canonical: "Eine Hitzewallung im Schlaf gehabt?",
                      english: "Did you have a hot flash while sleeping?", icon: "fire"),
        KnownQuestion(canonical: "Zur Arbeit gependelt?",
                      english: "Did you commute to work?", icon: "car"),
        KnownQuestion(canonical: "Zusätzlichen Zucker konsumiert?",
                      english: "Did you have added sugar?", icon: "cube"),
        KnownQuestion(canonical: "Mich nervös oder ängstlich gefühlt?",
                      english: "Did you feel nervous or anxious?", icon: "smiley-nervous"),
        KnownQuestion(canonical: "Den ganzen Tag über voller Energie gefühlt?",
                      english: "Did you feel full of energy all day?", icon: "battery-high"),
        KnownQuestion(canonical: "Hast du deine Beleuchtung nach Sonnenuntergang gedimmt?",
                      english: "Did you dim your lights after sunset?", icon: "lightbulb-filament"),
        KnownQuestion(canonical: "Hast du alle deine Mahlzeiten tagsüber eingenommen?",
                      english: "Did you eat all your meals during daylight?", icon: "fork-knife"),
        KnownQuestion(canonical: "Beim Aufwachen direktes Sonnenlicht gesehen?",
                      english: "Did you see direct sunlight when you woke up?", icon: "sun"),
        KnownQuestion(canonical: "Ein entzündungshemmenden Medikaments (NSAID) eingenommen?",
                      english: "Did you take an anti-inflammatory (NSAID)?", icon: "pill"),
        KnownQuestion(canonical: "Verschreibungspflichtige Schlafmittel eingenommen?",
                      english: "Did you take a prescription sleeping pill?", icon: "moon"),
        KnownQuestion(canonical: "Kalzium zu dir genommen?",
                      english: "Did you take calcium?", icon: "pill"),
        KnownQuestion(canonical: "Ein Melatoninpräparat eingenommen?",
                      english: "Did you take a melatonin supplement?", icon: "moon-stars"),
        KnownQuestion(canonical: "Mit dem Flugzeug gereist?",
                      english: "Did you travel by plane?", icon: "airplane"),
        KnownQuestion(canonical: "Eine kalte Dusche genommen?",
                      english: "Did you take a cold shower?", icon: "shower"),
        KnownQuestion(canonical: "Did you drink any alcohol?",
                      english: "Did you drink any alcohol?", icon: "wine"),
        KnownQuestion(canonical: "Did you have caffeine late in the day?",
                      english: "Did you have caffeine late in the day?", icon: "coffee"),
        KnownQuestion(canonical: "Did you view a screen in bed?",
                      english: "Did you view a screen in bed?", icon: "device-mobile"),
        KnownQuestion(canonical: "Did you eat close to bedtime?",
                      english: "Did you eat close to bedtime?", icon: "fork-knife"),
        KnownQuestion(canonical: "Did you feel stressed?",
                      english: "Did you feel stressed?", icon: "lightning"),
        KnownQuestion(canonical: "Did you use a sauna?",
                      english: "Did you use a sauna?", icon: "thermometer-hot"),
        KnownQuestion(canonical: "Did you share your bed?",
                      english: "Did you share your bed?", icon: "users"),
        KnownQuestion(canonical: "Did you feel sick or ill?",
                      english: "Did you feel sick or ill?", icon: "first-aid-kit"),
        KnownQuestion(canonical: "Did you take magnesium?",
                      english: "Did you take magnesium?", icon: "pill"),
        KnownQuestion(canonical: "Did you read before bed?",
                      english: "Did you read before bed?", icon: "book-open"),
        KnownQuestion(canonical: "Did you feel bloated?",
                      english: "Did you feel bloated?", icon: "wind"),
        KnownQuestion(canonical: "Did you have an injury or wound?",
                      english: "Did you have an injury or wound?", icon: "bandaids"),
    ]

    private static let byFolded: [String: KnownQuestion] = {
        var map: [String: KnownQuestion] = [:]
        for row in known { map[fold(row.canonical)] = row }
        return map
    }()

    private static let iconByEnglish: [String: String] = {
        var map: [String: String] = [:]
        for row in known { map[row.english] = row.icon }
        return map
    }()

    /// English catalog key after identity canonicalisation. Nil for a custom or unknown question.
    static func englishKey(forCanonical canonical: String) -> String? {
        let resolved = JournalQuestionIdentity.canonical(canonical)
        return byFolded[fold(resolved)]?.english
    }

    /// Phosphor glyph for a known question, matched on the English key. Nil when the question is unknown.
    static func iconName(forCanonical canonical: String) -> String? {
        guard let english = englishKey(forCanonical: canonical) else { return nil }
        return iconByEnglish[english]
    }

    /// Localized label for a stored question. Unknown questions come back trimmed and unchanged.
    static func label(forCanonical canonical: String) -> String {
        let trimmed = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let english = englishKey(forCanonical: trimmed) else { return trimmed }
        return localized(english)
    }

    /// What a row shows. A non-empty rename stays verbatim. Otherwise the localized known question.
    static func label(for item: JournalCatalogItem) -> String {
        if let name = item.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return label(forCanonical: item.canonical)
    }

    /// POSIX case fold so a German question matches regardless of the casing that arrived first.
    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    /// Every arm is a catalog literal so the string audit can see the key. Unknown keys return as-is.
    private static func localized(_ english: String) -> String {
        switch english {
        case "Did you take a probiotic?":
            return String(localized: "Did you take a probiotic?")
        case "Did you take creatine?":
            return String(localized: "Did you take creatine?")
        case "Did you work from home?":
            return String(localized: "Did you work from home?")
        case "Did you learn something interesting or important?":
            return String(localized: "Did you learn something interesting or important?")
        case "Did you use a steam room?":
            return String(localized: "Did you use a steam room?")
        case "Did you have dairy?":
            return String(localized: "Did you have dairy?")
        case "Did you drink enough water?":
            return String(localized: "Did you drink enough water?")
        case "Did you have protein?":
            return String(localized: "Did you have protein?")
        case "Did you spend time with family or friends?":
            return String(localized: "Did you spend time with family or friends?")
        case "Did you have a headache?":
            return String(localized: "Did you have a headache?")
        case "Did you have a hot flash while sleeping?":
            return String(localized: "Did you have a hot flash while sleeping?")
        case "Did you commute to work?":
            return String(localized: "Did you commute to work?")
        case "Did you have added sugar?":
            return String(localized: "Did you have added sugar?")
        case "Did you feel nervous or anxious?":
            return String(localized: "Did you feel nervous or anxious?")
        case "Did you feel full of energy all day?":
            return String(localized: "Did you feel full of energy all day?")
        case "Did you dim your lights after sunset?":
            return String(localized: "Did you dim your lights after sunset?")
        case "Did you eat all your meals during daylight?":
            return String(localized: "Did you eat all your meals during daylight?")
        case "Did you see direct sunlight when you woke up?":
            return String(localized: "Did you see direct sunlight when you woke up?")
        case "Did you take an anti-inflammatory (NSAID)?":
            return String(localized: "Did you take an anti-inflammatory (NSAID)?")
        case "Did you take a prescription sleeping pill?":
            return String(localized: "Did you take a prescription sleeping pill?")
        case "Did you take calcium?":
            return String(localized: "Did you take calcium?")
        case "Did you take a melatonin supplement?":
            return String(localized: "Did you take a melatonin supplement?")
        case "Did you travel by plane?":
            return String(localized: "Did you travel by plane?")
        case "Did you take a cold shower?":
            return String(localized: "Did you take a cold shower?")
        case "Did you drink any alcohol?":
            return String(localized: "Did you drink any alcohol?")
        case "Did you have caffeine late in the day?":
            return String(localized: "Did you have caffeine late in the day?")
        case "Did you view a screen in bed?":
            return String(localized: "Did you view a screen in bed?")
        case "Did you eat close to bedtime?":
            return String(localized: "Did you eat close to bedtime?")
        case "Did you feel stressed?":
            return String(localized: "Did you feel stressed?")
        case "Did you use a sauna?":
            return String(localized: "Did you use a sauna?")
        case "Did you share your bed?":
            return String(localized: "Did you share your bed?")
        case "Did you feel sick or ill?":
            return String(localized: "Did you feel sick or ill?")
        case "Did you take magnesium?":
            return String(localized: "Did you take magnesium?")
        case "Did you read before bed?":
            return String(localized: "Did you read before bed?")
        case "Did you feel bloated?":
            return String(localized: "Did you feel bloated?")
        case "Did you have an injury or wound?":
            return String(localized: "Did you have an injury or wound?")
        default:
            return english
        }
    }
}
