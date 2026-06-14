import Foundation

// MARK: - Lifting import (Hevy CSV / Liftosaur JSON) — source "lifting"
//
// Strength-training history from a lifting tracker, mapped onto the existing workout/Sport model
// as one "Strength Training" session per workout. The headline figure is a TRANSPARENT volume-load
// estimate — Σ(weight × reps) across the working sets — surfaced honestly as a training-volume
// estimate, NOT a measured cardiovascular strain. It deliberately does NOT feed the HR-based Effort
// score (the imported rows carry no `strain`), so lifting volume never double-counts as cardio load.
//
// Two on-device, fully-offline formats are recognised (no account, no API):
//   • Hevy CSV export        — one row per set (title, start_time, exercise_title, weight_kg, reps…),
//                              grouped into a session by (title + start_time).
//   • Liftosaur JSON export  — a `history` array of records, each with `startTime`/`endTime` (ms) and
//                              nested `entries[].sets[]` carrying weight + reps.
//
// Weights are normalised to **kilograms** (Hevy's `weight_kg` is already kg; `weight_lb`/lbs columns
// and Liftosaur's `lb` unit convert). The parser is tolerant in the house style: a malformed set or
// record is skipped and counted, never fatal.

/// One imported strength session — the shape the app layer maps 1:1 onto a `WorkoutRow`
/// (sport "Strength Training", source "lifting"). All weights are kilograms.
public struct LiftingSession: Sendable, Equatable {
    /// Session start (UTC). Primary key component for the workout row.
    public var start: Date
    /// Session end (UTC). Falls back to `start` when the export has no end.
    public var end: Date
    /// Transparent volume load = Σ(weight_kg × reps) across counted (non-warmup) sets.
    public var volumeLoadKg: Double
    /// Number of counted sets contributing to the volume load.
    public var setCount: Int
    /// Distinct exercise count in the session (surfaced in the note for context).
    public var exerciseCount: Int
    /// Total reps across counted sets.
    public var totalReps: Int
    /// Heaviest single-set weight seen (kg), for an honest "top set" note. nil when no weighted set.
    public var topSetKg: Double?
    /// Optional workout title from the export (e.g. "Push Day"). Surfaced in the note, never the sport.
    public var title: String?

    public init(
        start: Date,
        end: Date,
        volumeLoadKg: Double,
        setCount: Int,
        exerciseCount: Int,
        totalReps: Int,
        topSetKg: Double?,
        title: String?
    ) {
        self.start = start
        self.end = end
        self.volumeLoadKg = volumeLoadKg
        self.setCount = setCount
        self.exerciseCount = exerciseCount
        self.totalReps = totalReps
        self.topSetKg = topSetKg
        self.title = title
    }

    /// Duration in seconds, or nil when start == end (no real interval to claim).
    public var durationS: Double? {
        let d = end.timeIntervalSince(start)
        return d > 0 ? d : nil
    }
}

/// Result of parsing a lifting export: the sessions (oldest first), plus how many rows/records were
/// skipped and the date span. Mirrors the tolerant-summary ethos of the WHOOP / Apple importers.
public struct LiftingImportResult: Sendable, Equatable {
    /// Parsed sessions, oldest first.
    public var sessions: [LiftingSession]
    /// Source rows (Hevy) or records (Liftosaur) dropped: unparseable date, or no countable set.
    public var skipped: Int
    public var earliest: Date?
    public var latest: Date?

    public init(sessions: [LiftingSession], skipped: Int, earliest: Date?, latest: Date?) {
        self.sessions = sessions
        self.skipped = skipped
        self.earliest = earliest
        self.latest = latest
    }

    public var sessionCount: Int { sessions.count }
}

public enum LiftingImporter {

    /// Provenance/source id the app uses as the workout `source` column — classified as `.lifting`
    /// so the Workouts list shows an honest "Lifting" badge distinct from WHOOP/Apple/manual.
    public static let sourceId = "lifting"

    /// The sport name every imported lifting session is filed under (maps to the dumbbell icon).
    public static let sport = "Strength Training"

    /// Pounds → kilograms (exact avoirdupois definition), shared by the Hevy lb column and the
    /// Liftosaur `lb` unit.
    static let lbToKg = 0.45359237

    // MARK: - Format detection + dispatch

    public enum Format: Sendable, Equatable { case hevyCsv, liftosaurJson }

    /// Best-effort format sniff from raw bytes: a leading `{`/`[` (after whitespace) reads as JSON
    /// (Liftosaur); otherwise it's treated as a Hevy CSV. Callers that already know the format can
    /// skip this and call the typed entry points.
    public static func detectFormat(data: Data) -> Format {
        for byte in data.prefix(64) {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF: continue   // whitespace / UTF-8 BOM
            case UInt8(ascii: "{"), UInt8(ascii: "["): return .liftosaurJson
            default: return .hevyCsv
            }
        }
        return .hevyCsv
    }

    /// Parse raw bytes, auto-detecting Hevy CSV vs Liftosaur JSON.
    public static func parse(data: Data) -> LiftingImportResult {
        switch detectFormat(data: data) {
        case .hevyCsv:        return parseHevy(data: data)
        case .liftosaurJson:  return parseLiftosaur(data: data)
        }
    }

    // MARK: - Hevy CSV

    /// Parse a Hevy CSV export (one row per set) into one session per workout.
    public static func parseHevy(data: Data) -> LiftingImportResult {
        parseHevy(table: CSVTable(data: data))
    }

    /// Parse Hevy CSV text.
    public static func parseHevy(text: String) -> LiftingImportResult {
        parseHevy(table: CSVTable(text: text))
    }

    private static func parseHevy(table: CSVTable) -> LiftingImportResult {
        // A Hevy row is grouped into a session by (title, start_time). The start_time string is a
        // stable grouping key on its own; title disambiguates the rare same-second back-to-back logs.
        var order: [String] = []
        var byKey: [String: HevyAccumulator] = [:]
        var skipped = 0

        for row in table.rows {
            let startRaw = row.cell("start_time", "start", "date")
            guard let startRaw, let start = parseDate(startRaw) else { skipped += 1; continue }

            let title = row.cell("title", "workout_name", "name")
            let exercise = row.cell("exercise_title", "exercise_name", "exercise") ?? ""
            let setType = (row.cell("set_type", "type") ?? "").lowercased()

            // Weight: prefer kg; fall back to a lb column (convert). Bodyweight sets have no weight.
            let weightKg: Double? = row.double("weight_kg", "weight", "weight_kgs")
                ?? row.double("weight_lb", "weight_lbs", "weight_lbf").map { $0 * lbToKg }
            let reps = row.double("reps", "rep_count").map { Int($0) }

            let key = "\(title ?? "")|\(startRaw)"
            if byKey[key] == nil {
                byKey[key] = HevyAccumulator(start: start, title: title)
                order.append(key)
            }
            byKey[key]?.endRaw = row.cell("end_time", "end") ?? byKey[key]?.endRaw
            byKey[key]?.add(exercise: exercise, setType: setType, weightKg: weightKg, reps: reps)
        }

        return finish(order.compactMap { byKey[$0] }, skipped: skipped)
    }

    /// Mutable per-session tally while folding Hevy set rows.
    private final class HevyAccumulator {
        let start: Date
        let title: String?
        var endRaw: String?
        var volume = 0.0
        var sets = 0
        var reps = 0
        var top: Double?
        var exercises = Set<String>()

        init(start: Date, title: String?) {
            self.start = start
            self.title = title
        }

        /// Count a set into the volume load. Warm-up sets are excluded from the working-volume figure
        /// (Hevy marks them `set_type = "warmup"`); a set needs a positive weight AND reps to add
        /// volume, but a completed bodyweight/duration set still increments the set count for context.
        func add(exercise: String, setType: String, weightKg: Double?, reps: Int?) {
            if !exercise.isEmpty { exercises.insert(exercise.lowercased()) }
            if setType == "warmup" || setType == "warm_up" || setType == "warm-up" { return }
            sets += 1
            if let r = reps, r > 0 { self.reps += r }
            if let w = weightKg, w > 0 {
                top = max(top ?? 0, w)
                if let r = reps, r > 0 { volume += w * Double(r) }
            }
        }

        var session: LiftingSession? {
            guard sets > 0 else { return nil }
            let end = endRaw.flatMap { LiftingImporter.parseDate($0) } ?? start
            return LiftingSession(
                start: start,
                end: end >= start ? end : start,
                volumeLoadKg: volume,
                setCount: sets,
                exerciseCount: exercises.count,
                totalReps: reps,
                topSetKg: top,
                title: title
            )
        }
    }

    // MARK: - Liftosaur JSON

    /// Parse a Liftosaur JSON export into one session per history record.
    public static func parseLiftosaur(data: Data) -> LiftingImportResult {
        // JSONSerialization rejects a leading UTF-8 BOM, so strip it (the shared CSV helper).
        guard let obj = try? JSONSerialization.jsonObject(with: BOM.stripUTF8(data)) else {
            return LiftingImportResult(sessions: [], skipped: 0, earliest: nil, latest: nil)
        }
        // The export can be the storage object `{ "history": [...] }`, a wrapper `{ "storage": { … } }`,
        // or a bare array of records. Locate the history array wherever it sits.
        let history = liftosaurHistory(in: obj)

        var sessions: [LiftingSession] = []
        var skipped = 0
        for case let record as [String: Any] in history {
            if let s = liftosaurSession(record) { sessions.append(s) } else { skipped += 1 }
        }
        return finish(sessions, skipped: skipped)
    }

    /// Dig the `history` array out of a Liftosaur export, tolerating a couple of wrapper shapes.
    private static func liftosaurHistory(in obj: Any) -> [Any] {
        if let arr = obj as? [Any] { return arr }
        guard let dict = obj as? [String: Any] else { return [] }
        if let h = dict["history"] as? [Any] { return h }
        if let storage = dict["storage"] as? [String: Any], let h = storage["history"] as? [Any] { return h }
        return []
    }

    private static func liftosaurSession(_ record: [String: Any]) -> LiftingSession? {
        guard let start = liftosaurDate(record["startTime"] ?? record["date"] ?? record["ts"]) else { return nil }
        let end = liftosaurDate(record["endTime"]) ?? start

        var volume = 0.0
        var sets = 0
        var reps = 0
        var top: Double?
        var exercises = 0

        let entries = (record["entries"] as? [Any]) ?? []
        for case let entry as [String: Any] in entries {
            exercises += 1
            // Liftosaur entries carry a default unit; individual sets may override it.
            let entryUnit = (entry["unit"] as? String)?.lowercased()
            let setList = (entry["sets"] as? [Any]) ?? []
            for case let set as [String: Any] in setList {
                // A logged set has completed reps; templates carrying only planned `reps` (no
                // `completedReps`) are skipped — falling back to `reps` would count un-performed sets.
                guard let r = liftosaurInt(set["completedReps"]), r > 0 else { continue }
                sets += 1
                reps += r
                if let w = liftosaurWeightKg(set, entryUnit: entryUnit), w > 0 {
                    top = max(top ?? 0, w)
                    volume += w * Double(r)
                }
            }
        }

        guard sets > 0 else { return nil }
        return LiftingSession(
            start: start,
            end: end >= start ? end : start,
            volumeLoadKg: volume,
            setCount: sets,
            exerciseCount: exercises,
            totalReps: reps,
            topSetKg: top,
            title: (record["programName"] as? String) ?? (record["dayName"] as? String)
        )
    }

    /// Resolve a Liftosaur set's weight to kilograms. The weight may be a bare number or an object
    /// `{ "value": 100, "unit": "lb" }`; `lb` converts, everything else (kg / blank) is taken as kg.
    private static func liftosaurWeightKg(_ set: [String: Any], entryUnit: String?) -> Double? {
        let raw = set["weight"] ?? set["weightValue"]
        if let obj = raw as? [String: Any] {
            guard let v = liftosaurDouble(obj["value"]) else { return nil }
            let unit = (obj["unit"] as? String)?.lowercased() ?? entryUnit
            return unit == "lb" || unit == "lbs" ? v * lbToKg : v
        }
        guard let v = liftosaurDouble(raw) else { return nil }
        return entryUnit == "lb" || entryUnit == "lbs" ? v * lbToKg : v
    }

    // MARK: - JSON scalar coercion

    private static func liftosaurDouble(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func liftosaurInt(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) ?? Double(s).map { Int($0) } }
        return nil
    }

    /// Liftosaur timestamps are epoch milliseconds (number or numeric string). A plain ISO string is
    /// tolerated as a fallback.
    private static func liftosaurDate(_ any: Any?) -> Date? {
        if let ms = liftosaurDouble(any), ms > 0 {
            // Heuristic: a 13-digit value is ms; a 10-digit value is seconds.
            return ms > 1_000_000_000_000 ? Date(timeIntervalSince1970: ms / 1000)
                                           : Date(timeIntervalSince1970: ms)
        }
        if let s = any as? String { return parseDate(s) }
        return nil
    }

    // MARK: - Shared helpers

    /// Parse a Hevy date string. Hevy exports an English `d MMM yyyy, HH:mm` form
    /// (e.g. "12 Jun 2026, 18:30") as well as ISO; both are handled, plus the shared WHOOP parser
    /// for `yyyy-MM-dd HH:mm:ss` and ISO-8601-with-offset.
    static func parseDate(_ raw: String) -> Date? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let d = WhoopTime.parse(t, offsetMinutes: 0) { return d }
        for fmt in hevyFormatters {
            if let d = fmt.date(from: t) { return d }
        }
        return nil
    }

    /// Hevy's localized-looking but English-only timestamp formats, parsed at UTC (the export carries
    /// no zone, so UTC is the honest, stable choice rather than fabricating a local offset).
    private static let hevyFormatters: [DateFormatter] = {
        ["d MMM yyyy, HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss", "MM/dd/yyyy HH:mm:ss"].map { pattern in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = pattern
            f.isLenient = false
            return f
        }
    }()

    /// Build sessions from accumulators (Hevy) or finish a list (Liftosaur): sort oldest-first and
    /// compute the date span. Sessions with no countable set were already dropped/counted by callers.
    private static func finish(_ raw: [HevyAccumulator], skipped: Int) -> LiftingImportResult {
        var sessions = raw.compactMap { $0.session }
        let extraSkipped = raw.count - sessions.count
        sessions.sort { $0.start < $1.start }
        return LiftingImportResult(
            sessions: sessions,
            skipped: skipped + extraSkipped,
            earliest: sessions.first?.start,
            latest: sessions.last?.start
        )
    }

    /// Liftosaur overload: sessions are already built, just sort + span.
    private static func finish(_ raw: [LiftingSession], skipped: Int) -> LiftingImportResult {
        let sessions = raw.sorted { $0.start < $1.start }
        return LiftingImportResult(
            sessions: sessions,
            skipped: skipped,
            earliest: sessions.first?.start,
            latest: sessions.last?.start
        )
    }
}

// MARK: - Volume-load note

public extension LiftingSession {
    /// The honest one-line note stored on the workout row, e.g.
    /// "Strength · volume load 12,400 kg · 18 sets · 5 exercises". Explicitly a training-VOLUME
    /// estimate, not a measured strain — the workout row carries no `strain`, so it never feeds Effort.
    func volumeLoadNote(title includeTitle: Bool = true) -> String {
        var parts: [String] = []
        if volumeLoadKg > 0 {
            parts.append("volume load \(LiftingImporter.groupedKg(volumeLoadKg)) kg")
        }
        parts.append("\(setCount) set\(setCount == 1 ? "" : "s")")
        if exerciseCount > 0 { parts.append("\(exerciseCount) exercise\(exerciseCount == 1 ? "" : "s")") }
        var note = "Strength · " + parts.joined(separator: " · ")
        if includeTitle, let title, !title.isEmpty { note = "\(title) — " + note }
        return note
    }
}

extension LiftingImporter {
    /// Group an integer-kg figure with thousands separators for the note (e.g. 12400 → "12,400").
    public static func groupedKg(_ kg: Double) -> String {
        let n = Int(kg.rounded())
        return groupedFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        // en_US_POSIX carries no grouping separator, so force the English thousands comma
        // explicitly — the note is a fixed-English string and must group deterministically
        // (e.g. 12400 -> "12,400") regardless of host locale.
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.groupingSize = 3
        f.maximumFractionDigits = 0
        return f
    }()
}
