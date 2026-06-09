import Foundation

/// One journalable behaviour. `question` is the canonical key and MUST match WHOOP's
/// exported question text verbatim so natively-logged answers unify with imported ones
/// on the journal table's natural key (deviceId, day, question). `goodWhenYes` is a
/// display hint for tinting only — it is NOT analysis input (Insights derives direction
/// from the outcome via Cohen's d).
struct JournalBehavior: Identifiable, Hashable {
    let id: String          // stable slug, e.g. "alcohol"
    let question: String    // verbatim WHOOP text, e.g. "Did you drink any alcohol?"
    let shortLabel: String  // compact UI label, e.g. "Alcohol"
    let category: String
    let icon: String        // SF Symbol
    let goodWhenYes: Bool?   // true = healthy when yes, false = unhealthy, nil = neutral
}

/// Curated WHOOP-aligned behaviour catalog. Mirrors `MetricCatalog`.
/// Verbatim strings anchored to the real-export fixture
/// (`journal_entries.csv`: "Did you drink any alcohol?", "Did you have any caffeine?").
enum JournalCatalog {
    static let categories = ["Substances", "Nutrition", "Activity", "Mind & Sleep", "Environment"]

    static let all: [JournalBehavior] = [
        // ── Substances
        b("alcohol",  "Did you drink any alcohol?",                          "Alcohol",        "Substances",  "wineglass",            false),
        b("caffeine", "Did you have any caffeine?",                          "Caffeine",       "Substances",  "cup.and.saucer",       nil),
        b("nicotine", "Did you have any nicotine?",                          "Nicotine",       "Substances",  "smoke",                false),
        b("thc",      "Did you have any THC?",                               "THC",            "Substances",  "leaf",                 nil),
        b("cbd",      "Did you have any CBD?",                               "CBD",            "Substances",  "leaf.fill",            nil),
        b("melatonin","Did you take any melatonin?",                         "Melatonin",      "Substances",  "pills",                nil),
        b("magnesium","Did you take any magnesium?",                         "Magnesium",      "Substances",  "pills.fill",           true),

        // ── Nutrition
        b("late_meal","Did you eat a meal within 3 hours of going to sleep?","Late meal",      "Nutrition",   "fork.knife",           false),
        b("hydrated", "Did you stay hydrated today?",                        "Hydrated",       "Nutrition",   "drop",                 true),
        b("sugar",    "Did you have any added sugar?",                       "Added sugar",    "Nutrition",   "cube",                 false),
        b("fasting",  "Did you fast today?",                                 "Fasting",        "Nutrition",   "timer",                nil),

        // ── Activity
        b("exercise", "Did you exercise today?",                             "Exercise",       "Activity",    "figure.run",           true),
        b("stretch",  "Did you spend time stretching?",                      "Stretching",     "Activity",    "figure.cooldown",      true),
        b("steps",    "Did you take a walk today?",                          "Walk",           "Activity",    "figure.walk",          true),
        b("outdoors", "Did you spend time outdoors?",                        "Outdoors",       "Activity",    "sun.max",              true),

        // ── Mind & Sleep
        b("meditate", "Did you meditate?",                                   "Meditation",     "Mind & Sleep","brain.head.profile",   true),
        b("read",     "Did you read while in bed?",                          "Read in bed",    "Mind & Sleep","book",                 true),
        b("screens",  "Did you view a screen device while in bed?",          "Screens in bed", "Mind & Sleep","iphone",               false),
        b("stress",   "Did you feel stressed today?",                        "Felt stressed",  "Mind & Sleep","bolt.heart",           false),
        b("nap",      "Did you take a nap today?",                           "Nap",            "Mind & Sleep","zzz",                  nil),

        // ── Environment
        b("share_bed","Did you share your bed?",                             "Shared bed",     "Environment", "person.2",             nil),
        b("own_bed",  "Did you sleep in your own bed?",                      "Own bed",        "Environment", "bed.double",           true),
        b("travel",   "Did you travel today?",                               "Travel",         "Environment", "airplane",             nil),
        b("sick",     "Did you feel sick today?",                            "Felt sick",      "Environment", "thermometer.medium",   false),
    ]

    /// Default tracked subset for a fresh install (ids).
    static let defaultTrackedIDs: Set<String> = [
        "alcohol", "caffeine", "late_meal", "exercise", "meditate", "screens", "hydrated", "read",
    ]

    static func inCategory(_ c: String) -> [JournalBehavior] { all.filter { $0.category == c } }
    static func byID(_ id: String) -> JournalBehavior? { all.first { $0.id == id } }
    static func byQuestion(_ q: String) -> JournalBehavior? { all.first { $0.question == q } }

    /// Union the catalog's questions with any distinct questions already imported,
    /// so a logged answer always shares a key with the WHOOP export. Catalog order first,
    /// then unknown imported questions appended (de-duplicated, stable).
    static func mergedQuestions(imported: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for q in all.map(\.question) where seen.insert(q).inserted { out.append(q) }
        for q in imported where seen.insert(q).inserted { out.append(q) }
        return out
    }

    private static func b(_ id: String, _ question: String, _ shortLabel: String,
                          _ category: String, _ icon: String, _ goodWhenYes: Bool?) -> JournalBehavior {
        JournalBehavior(id: id, question: question, shortLabel: shortLabel,
                        category: category, icon: icon, goodWhenYes: goodWhenYes)
    }
}
