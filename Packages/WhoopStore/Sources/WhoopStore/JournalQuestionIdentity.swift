import Foundation

/// Explicit equivalents of journal questions. Unknown/custom questions retain their original key;
/// no fuzzy or keyword matching may combine questions about different behaviours or time windows.
/// Mirrors Android JournalQuestionIdentity. Imported rows are left intact on disk; callers resolve
/// their identity when building the catalog, reading answers, and grouping history for analysis.
public enum JournalQuestionIdentity {
    /// Stable English identity for a known question; otherwise the original string, unchanged.
    /// Kotlin twin: `JournalQuestionIdentity.canonical`.
    public static func canonical(_ question: String) -> String {
        switch normalise(question) {
        case "did you drink any alcohol?", "did you drink alcohol?", "alkohol konsumiert?", "alkohol getrunken?", "hast du alkohol konsumiert?", "hast du alkohol getrunken?":
            return "Did you drink any alcohol?"
        case "did you have caffeine late in the day?", "spät am tag koffein konsumiert?", "koffein spät am tag konsumiert?", "hast du spät am tag koffein konsumiert?":
            return "Did you have caffeine late in the day?"
        case "did you view a screen in bed?", "einen bildschirm im bett angesehen?", "im bett auf einen bildschirm geschaut?", "bildschirm im bett genutzt?", "hast du im bett auf einen bildschirm geschaut?":
            return "Did you view a screen in bed?"
        case "did you eat close to bedtime?", "kurz vor dem schlafengehen gegessen?", "kurz vor dem zubettgehen gegessen?", "hast du kurz vor dem schlafengehen gegessen?":
            return "Did you eat close to bedtime?"
        case "did you feel stressed?", "dich gestresst gefühlt?", "gestresst gefühlt?", "hast du dich gestresst gefühlt?":
            return "Did you feel stressed?"
        case "did you use a sauna?", "eine sauna benutzt?", "eine sauna genutzt?", "in der sauna gewesen?", "hast du eine sauna benutzt?":
            return "Did you use a sauna?"
        case "did you share your bed?", "dein bett geteilt?", "das bett geteilt?", "hast du dein bett geteilt?":
            return "Did you share your bed?"
        case "did you feel sick or ill?", "did you feel sick?", "dich krank gefühlt?", "krank gefühlt?", "hast du dich krank gefühlt?":
            return "Did you feel sick or ill?"
        case "did you take magnesium?", "magnesium eingenommen?", "hast du magnesium eingenommen?":
            return "Did you take magnesium?"
        case "did you read before bed?", "vor dem schlafengehen gelesen?", "vor dem zubettgehen gelesen?", "hast du vor dem schlafengehen gelesen?":
            return "Did you read before bed?"
        case "did you feel bloated?", "did you experience bloating?", "blähungen gehabt?", "hast du blähungen gehabt?":
            return "Did you feel bloated?"
        case "did you have an injury or wound?", "eine verletzung oder wunde haben?", "eine verletzung oder wunde gehabt?", "hast du eine verletzung oder wunde gehabt?":
            return "Did you have an injury or wound?"
        default: return question
        }
    }

    /// Catalog identity includes the existing case/whitespace deduplication for custom questions.
    /// Kotlin twin: `JournalQuestionIdentity.key`.
    public static func key(_ question: String) -> String {
        normalise(canonical(question))
    }

    /// Eligible experiment questions share the same identity as history and catalog hiding.
    /// Kotlin twin: `JournalQuestionIdentity.candidates`.
    public static func candidates(logged: [String], imported: [String], hidden: [String], saved: String) -> [String] {
        let hiddenKeys = Set(hidden.map(key))
        var seen = Set<String>()
        var result: [String] = []
        for question in logged.sorted() + imported + [saved] {
            let value = canonical(question.trimmingCharacters(in: .whitespacesAndNewlines))
            let identity = key(value)
            if !value.isEmpty, !hiddenKeys.contains(identity), seen.insert(identity).inserted {
                result.append(value)
            }
        }
        return result
    }

    /// Kotlin twin: `JournalQuestionIdentity.normalise`.
    private static func normalise(_ question: String) -> String {
        question.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}
