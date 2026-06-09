import Foundation

/// One journalable behaviour. `question` is the canonical key and MUST match WHOOP's
/// exported question text verbatim so natively-logged answers unify with imported ones
/// on the journal table's natural key (deviceId, day, question). `aliases` holds localized
/// variants of that question (e.g. WHOOP's German export strings) so an imported answer in
/// another language still resolves to this behaviour for display — while the stored key
/// stays the verbatim imported string. `goodWhenYes` is a display hint for tinting only — it
/// is NOT analysis input (Insights derives direction from the outcome via Cohen's d).
struct JournalBehavior: Identifiable, Hashable {
    let id: String          // stable slug, e.g. "alcohol"
    let question: String    // verbatim WHOOP text, e.g. "Did you drink any alcohol?"
    let shortLabel: String  // compact UI label, e.g. "Alcohol"
    let category: String
    let icon: String        // SF Symbol
    let goodWhenYes: Bool?   // true = healthy when yes, false = unhealthy, nil = neutral
    var aliases: [String] = []  // localized/variant question strings that map to this behaviour
}

/// Curated WHOOP-aligned behaviour catalog. Mirrors `MetricCatalog`.
/// Verbatim strings anchored to the real-export fixture
/// (`journal_entries.csv`: "Did you drink any alcohol?", "Did you have any caffeine?").
///
/// `all` is the curated, trackable default set (what Settings → Journal offers as toggles).
/// `extended` covers the remaining WHOOP journal questions — surfaced only to *display and
/// group imported* answers (e.g. a German export), never shown as a tracking toggle, so an
/// English user's Settings list stays curated. German aliases are WHOOP's official export
/// localization, so they apply to any German import — not just one user.
enum JournalCatalog {
    static let categories = ["Substances", "Nutrition", "Activity", "Mind & Sleep", "Environment"]

    static let all: [JournalBehavior] = [
        // ── Substances
        b("alcohol",  "Did you drink any alcohol?",                          "Alcohol",        "Substances",  "wineglass",            false, ["Alkohol konsumiert?"]),
        b("caffeine", "Did you have any caffeine?",                          "Caffeine",       "Substances",  "cup.and.saucer",       nil,   ["Koffein konsumiert?"]),
        b("nicotine", "Did you have any nicotine?",                          "Nicotine",       "Substances",  "smoke",                false),
        b("thc",      "Did you have any THC?",                               "THC",            "Substances",  "leaf",                 nil),
        b("cbd",      "Did you have any CBD?",                               "CBD",            "Substances",  "leaf.fill",            nil),
        b("melatonin","Did you take any melatonin?",                         "Melatonin",      "Substances",  "pills",                nil,   ["Ein Melatoninpräparat eingenommen?"]),
        b("magnesium","Did you take any magnesium?",                         "Magnesium",      "Substances",  "pills.fill",           true),

        // ── Nutrition
        b("late_meal","Did you eat a meal within 3 hours of going to sleep?","Late meal",      "Nutrition",   "fork.knife",           false),
        b("hydrated", "Did you stay hydrated today?",                        "Hydrated",       "Nutrition",   "drop",                 true,  ["Genug Wasser getrunken?"]),
        b("sugar",    "Did you have any added sugar?",                       "Added sugar",    "Nutrition",   "cube",                 false, ["Zusätzlichen Zucker konsumiert?"]),
        b("fasting",  "Did you fast today?",                                 "Fasting",        "Nutrition",   "timer",                nil),

        // ── Activity
        b("exercise", "Did you exercise today?",                             "Exercise",       "Activity",    "figure.run",           true),
        b("stretch",  "Did you spend time stretching?",                      "Stretching",     "Activity",    "figure.cooldown",      true),
        b("steps",    "Did you take a walk today?",                          "Walk",           "Activity",    "figure.walk",          true),
        b("outdoors", "Did you spend time outdoors?",                        "Outdoors",       "Activity",    "sun.max",              true),

        // ── Mind & Sleep
        b("meditate", "Did you meditate?",                                   "Meditation",     "Mind & Sleep","brain.head.profile",   true),
        b("read",     "Did you read while in bed?",                          "Read in bed",    "Mind & Sleep","book",                 true,  ["im Bett gelesen (kein Gerät mit Bildschirm)?"]),
        b("screens",  "Did you view a screen device while in bed?",          "Screens in bed", "Mind & Sleep","iphone",               false, ["Im Bett auf ein Gerät mit Bildschirm geschaut?"]),
        b("stress",   "Did you feel stressed today?",                        "Felt stressed",  "Mind & Sleep","bolt.heart",           false, ["Unter Stress gestanden?"]),
        b("nap",      "Did you take a nap today?",                           "Nap",            "Mind & Sleep","zzz",                  nil),

        // ── Environment
        b("share_bed","Did you share your bed?",                             "Shared bed",     "Environment", "person.2",             nil,   ["Dein Bett geteilt?"]),
        b("own_bed",  "Did you sleep in your own bed?",                      "Own bed",        "Environment", "bed.double",           true),
        b("travel",   "Did you travel today?",                               "Travel",         "Environment", "airplane",             nil,   ["Mit dem Flugzeug gereist?"]),
        b("sick",     "Did you feel sick today?",                            "Felt sick",      "Environment", "thermometer.medium",   false, ["Dich krank gefühlt?"]),
    ]

    /// WHOOP journal questions beyond the curated trackable set. Used only to resolve + group
    /// imported answers (their German alias is the real DB key); never offered as a toggle.
    static let extended: [JournalBehavior] = [
        // ── Substances / supplements
        b("creatine",   "Did you take any creatine?",                  "Creatine",      "Substances",   "pills.fill",  nil,   ["Kreatin eingenommen?"]),
        b("probiotic",  "Did you take a probiotic?",                   "Probiotic",     "Substances",   "pills",       nil,   ["Probiotikum eingenommen?"]),
        b("calcium",    "Did you take any calcium?",                   "Calcium",       "Substances",   "pills",       nil,   ["Kalzium zu dir genommen?"]),
        b("nsaid",      "Did you take an anti-inflammatory (NSAID)?",  "Anti-inflammatory","Substances","cross.case",  nil,   ["Ein entzündungshemmenden Medikaments (NSAID) eingenommen?"]),
        b("sleep_aid",  "Did you take a prescription sleep aid?",      "Sleep aid",     "Substances",   "moon.zzz.fill", nil, ["Verschreibungspflichtige Schlafmittel eingenommen?"]),

        // ── Nutrition
        b("protein",    "Did you consume protein?",                    "Protein",       "Nutrition",    "fork.knife",  true,  ["Eiweiß eingenommen?"]),
        b("dairy",      "Did you consume dairy?",                      "Dairy",         "Nutrition",    "cup.and.saucer.fill", nil, ["Milchprodukte konsumiert?"]),
        b("ate_meals",  "Did you eat all your meals during the day?",  "Ate all meals", "Nutrition",    "fork.knife",  true,  ["Hast du alle deine Mahlzeiten tagsüber eingenommen?"]),

        // ── Activity / recovery
        b("sauna",      "Did you use a sauna?",                        "Sauna",         "Activity",     "flame",       true,  ["Hast du eine Sauna benutzt?"]),
        b("steam",      "Did you use a steam room?",                   "Steam room",    "Activity",     "humidity",    true,  ["Hast du ein Dampfbad benutzt?"]),
        b("cold_shower","Did you take a cold shower?",                 "Cold shower",   "Activity",     "snowflake",   true,  ["Eine kalte Dusche genommen?"]),

        // ── Mind & Sleep
        b("learned",    "Did you learn something interesting or important?", "Learned something", "Mind & Sleep", "lightbulb",  true, ["Etwas Interessantes oder Wichtiges gelernt?"]),
        b("connected",  "Did you connect with family or friends?",     "Saw loved ones","Mind & Sleep", "person.2.fill", true, ["Kontakt mit Familie oder Freunden gehabt?"]),
        b("anxious",    "Did you feel nervous or anxious?",            "Felt anxious",  "Mind & Sleep", "wind",        false, ["Mich nervös oder ängstlich gefühlt?"]),
        b("energized",  "Did you feel energized throughout the day?",  "Felt energized","Mind & Sleep", "bolt.fill",   true,  ["Den ganzen Tag über voller Energie gefühlt?"]),
        b("dimmed_lights","Did you dim your lights after sunset?",     "Dimmed lights", "Mind & Sleep", "moon.stars",  true,  ["Hast du deine Beleuchtung nach Sonnenuntergang gedimmt?"]),
        b("morning_sun","Did you see direct sunlight when you woke up?","Morning sunlight","Mind & Sleep","sunrise",   true,  ["Beim Aufwachen direktes Sonnenlicht gesehen?"]),

        // ── Environment
        b("wfh",        "Did you work from home?",                     "Worked from home","Environment","house",       nil,   ["Im Home Office gearbeitet?"]),
        b("commute",    "Did you commute to work?",                    "Commute",       "Environment",  "car",         nil,   ["Zur Arbeit gependelt?"]),

        // ── Body (symptoms) — grouping-only category, not in `categories`
        b("bloated",    "Did you feel bloated?",                       "Bloated",       "Body",         "circle.dashed", false, ["Blähungen gehabt?"]),
        b("headache",   "Did you have a headache?",                    "Headache",      "Body",         "brain.head.profile", false, ["Hast du Kopfschmerzen gehabt?"]),
        b("injury",     "Do you have an injury or wound?",             "Injury",        "Body",         "bandage.fill", false, ["Eine Verletzung oder Wunde haben?"]),
        b("hot_flash",  "Did you have a hot flash in your sleep?",     "Hot flash",     "Body",         "thermometer.medium", false, ["Eine Hitzewallung im Schlaf gehabt?"]),
    ]

    /// Every known behaviour: the curated trackable set plus the WHOOP-extended set.
    static let catalog: [JournalBehavior] = all + extended

    /// Default tracked subset for a fresh install (ids).
    static let defaultTrackedIDs: Set<String> = [
        "alcohol", "caffeine", "late_meal", "exercise", "meditate", "screens", "hydrated", "read",
    ]

    static func inCategory(_ c: String) -> [JournalBehavior] { all.filter { $0.category == c } }
    static func byID(_ id: String) -> JournalBehavior? { catalog.first { $0.id == id } }

    /// Resolve a question (any language/variant) to its behaviour. Matches the canonical
    /// `question` or any `alias`, on a normalized key (diacritic/case-insensitive, trimmed,
    /// trailing "?" stripped) so a stray umlaut or spacing difference still resolves. Callers
    /// must persist the *verbatim* question, never `behaviour.question` — see `JournalView.save`.
    static func byQuestion(_ q: String) -> JournalBehavior? { questionIndex[normalizeKey(q)] }

    /// Normalized lookup key for resolution. Folds diacritics, lowercases, trims, drops "?".
    static func normalizeKey(_ q: String) -> String {
        q.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "?", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let questionIndex: [String: JournalBehavior] = {
        var idx: [String: JournalBehavior] = [:]
        for behaviour in catalog {
            idx[normalizeKey(behaviour.question)] = behaviour
            for alias in behaviour.aliases { idx[normalizeKey(alias)] = behaviour }
        }
        return idx
    }()

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
                          _ category: String, _ icon: String, _ goodWhenYes: Bool?,
                          _ aliases: [String] = []) -> JournalBehavior {
        JournalBehavior(id: id, question: question, shortLabel: shortLabel,
                        category: category, icon: icon, goodWhenYes: goodWhenYes, aliases: aliases)
    }
}
