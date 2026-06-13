import Foundation
import Combine
import WhoopStore
import WhoopProtocol

/// Per-day sleep figures the WHOOP export carried verbatim (metricSeries rows written by
/// WhoopImporter under the imported deviceId). SleepView prefers these over its on-device
/// APPROXIMATE recomputations.
struct ImportedSleepFigures: Equatable {
    var performancePct: Double?   // "sleep_performance", 0–100
    var consistencyPct: Double?   // "sleep_consistency", 0–100
    var needMin: Double?          // "sleep_need_min", minutes
    var debtMin: Double?          // "sleep_debt_min", minutes
}

/// Read model over the on-device WhoopStore. Opens its own handle (WAL + busy-timeout makes the
/// two-handle BLEManager+Repository pattern safe) and publishes the dashboard caches the screens bind to.
@MainActor
final class Repository: ObservableObject {
    let deviceId: String
    /// Source id for on-device computed scores (recovery/strain/sleep derived from the raw strap
    /// streams by IntelligenceEngine). Merged UNDER the imported `deviceId` rows at read time, so a
    /// real WHOOP import always wins and the strap-only user still gets a populated dashboard.
    private var computedDeviceId: String { deviceId + "-noop" }
    /// Source id Apple Health data lands under (matches `AppModel.appleDeviceId`). Merged at the
    /// LOWEST priority so an Apple-Watch-only iPhone — which has no strap or computed rows for the
    /// recent window — still gets populated Trends/Sleep for the metrics Health provides
    /// (HRV / resting HR / SpO₂ / respiratory rate / sleep duration). Recovery & strain remain a
    /// strap-only signal, so those stay empty without a WHOOP.
    let appleDeviceId: String
    private var store: WhoopStore?

    /// Daily metrics (recovery/strain/sleep/HRV/RHR…) over the recent window, oldest→newest.
    @Published var days: [DailyMetric] = []
    /// Cached sleep sessions over the recent window, oldest→newest.
    @Published var sleeps: [CachedSleepSession] = []
    /// Imported (export-verbatim) sleep figures by day. Empty until a WHOOP import lands.
    @Published var importedSleep: [String: ImportedSleepFigures] = [:]
    @Published var loaded = false
    /// Monotonic counter bumped on every successful `refresh()`. Intraday-updating views key their
    /// data load on this so they reload when fresh strap data lands — `today?.day` alone is a stable
    /// date string within a day and would freeze e.g. the Today HR trend until the date rolls over.
    @Published private(set) var refreshSeq = 0

    init(deviceId: String, appleDeviceId: String = "apple-health") {
        self.deviceId = deviceId
        self.appleDeviceId = appleDeviceId
    }

    /// Today's row, by the device's LOGICAL local day — NOT just the newest stored row, which after a
    /// historical import was months-old data shown as today's hero (issue #23). The logical day rolls at
    /// 04:00 local (see `logicalDayKey`), so between midnight and 4am we keep resolving the prior logical
    /// day's row instead of an empty new-calendar-day row that blanks the dashboard (#144). nil if no row
    /// for that day yet (the dashboard then shows its empty/pending state). Presentation-only — stored
    /// row keys are untouched.
    var today: DailyMetric? {
        let key = Repository.logicalDayKey(Date())
        return days.last(where: { $0.day == key })
    }
    /// The trailing 7 CALENDAR days ending today (for the week strip), oldest→newest — not the last 7
    /// stored rows, which on a stale import were old data. ISO yyyy-MM-dd compares chronologically.
    var week: [DailyMetric] {
        let cutoff = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date())
        return days.filter { $0.day >= cutoff }
    }

    /// `yyyy-MM-dd` in the device's local zone, matching how `DailyMetric.day` is stored.
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static func localDayKey(_ date: Date) -> String { dayKeyFormatter.string(from: date) }

    /// The hour the LOGICAL day rolls (04:00 local). Between midnight and this hour, "Today" stays put.
    static let logicalDayRolloverHour = 4

    /// The LOGICAL local day for `now` — the calendar date of `now - rolloverHour hours`. Rolls at
    /// 04:00 local rather than midnight, so the small hours after midnight still resolve to the prior
    /// calendar date's row instead of an empty new-calendar-day row (#144). Pure + injectable so the
    /// boundary is testable (23:59 → same day, 01:00 → previous day, 04:01 → new day). Presentation-only:
    /// used solely to pick which stored row is Today and to anchor the Today HR-trend window start; stored
    /// row keys are never rewritten.
    static func logicalDay(_ now: Date, rolloverHour: Int = logicalDayRolloverHour) -> Date {
        now.addingTimeInterval(-Double(rolloverHour) * 3_600)
    }

    /// `yyyy-MM-dd` key for the logical day of `now` (see `logicalDay`).
    static func logicalDayKey(_ now: Date, rolloverHour: Int = logicalDayRolloverHour) -> String {
        localDayKey(logicalDay(now, rolloverHour: rolloverHour))
    }

    /// Start of the logical day (its real calendar midnight) for `now`, in `calendar`'s zone — the anchor
    /// for the Today HR-trend window so it spans from the logical day's 00:00 rather than restarting at the
    /// new calendar midnight while we're still showing yesterday's logical day in the small hours (#144).
    static func logicalDayStart(_ now: Date, calendar: Calendar = .current,
                                rolloverHour: Int = logicalDayRolloverHour) -> Date {
        calendar.startOfDay(for: logicalDay(now, rolloverHour: rolloverHour))
    }

    private func ensureStore() async -> WhoopStore? {
        if let store { return store }
        guard let path = try? StorePaths.defaultDatabasePath() else { return nil }
        let s = try? await WhoopStore(path: path)
        if let s { try? await s.upsertDevice(id: deviceId, mac: nil, name: "WHOOP") }
        store = s
        return s
    }

    /// Expose the shared store handle (used by the importer to persist mapped rows).
    func storeHandle() async -> WhoopStore? { await ensureStore() }

    /// Checkpoint the WAL into the main DB file if the store is already open, so a file-level
    /// backup captures everything. No-op (returns false) if no handle exists yet — the caller
    /// then copies the on-disk files as-is, which still includes the -wal sidecar.
    func checkpointForBackup() async -> Bool {
        guard let store else { return false }
        do { try await store.checkpointWAL(); return true } catch { return false }
    }

    /// Reload the dashboard caches over the last `nDays`, merging imported history with the
    /// on-device computed scores so a strap-only user still gets a populated dashboard.
    func refresh(days nDays: Int = 4000) async {
        guard let store = await ensureStore() else { return }
        let now = Date()
        let fromDay = Self.dayString(now.addingTimeInterval(-Double(nDays) * 86_400))
        let toDay = Self.dayString(now.addingTimeInterval(86_400))
        let nowTs = Int(now.timeIntervalSince1970)
        let lo = nowTs - nDays * 86_400, hi = nowTs + 86_400

        let imported = (try? await store.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay)) ?? []
        let computed = (try? await store.dailyMetrics(deviceId: computedDeviceId, from: fromDay, to: toDay)) ?? []
        let apple = (try? await store.dailyMetrics(deviceId: appleDeviceId, from: fromDay, to: toDay)) ?? []
        let impSleep = (try? await store.sleepSessions(deviceId: deviceId, from: lo, to: hi, limit: 4000)) ?? []
        let compSleep = (try? await store.sleepSessions(deviceId: computedDeviceId, from: lo, to: hi, limit: 4000)) ?? []

        // Export-verbatim sleep figures (long-format metricSeries rows from WhoopImporter).
        // SleepView prefers these per day over its APPROXIMATE recomputations.
        let perf = (try? await store.metricSeries(deviceId: deviceId, key: "sleep_performance", from: fromDay, to: toDay)) ?? []
        let cons = (try? await store.metricSeries(deviceId: deviceId, key: "sleep_consistency", from: fromDay, to: toDay)) ?? []
        let need = (try? await store.metricSeries(deviceId: deviceId, key: "sleep_need_min", from: fromDay, to: toDay)) ?? []
        let debt = (try? await store.metricSeries(deviceId: deviceId, key: "sleep_debt_min", from: fromDay, to: toDay)) ?? []
        var fig: [String: ImportedSleepFigures] = [:]
        for p in perf { fig[p.day, default: ImportedSleepFigures()].performancePct = p.value }
        for p in cons { fig[p.day, default: ImportedSleepFigures()].consistencyPct = p.value }
        for p in need { fig[p.day, default: ImportedSleepFigures()].needMin = p.value }
        for p in debt { fig[p.day, default: ImportedSleepFigures()].debtMin = p.value }

        self.importedSleep = fig   // assigned BEFORE days/sleeps: one consistent publish per refresh
        // Keep the fork's three-source merge (apple-health fills days neither strap source has).
        self.days = Self.mergeDaily(imported: imported, computed: computed, apple: apple)
        self.sleeps = Self.mergeSleep(imported: impSleep, computed: compSleep)
        self.loaded = true
        self.refreshSeq += 1
    }

    /// Strap import wins per day; computed scores fill the days the import doesn't cover; Apple Health
    /// fills any day neither strap source has — so an Apple-Watch-only iPhone still gets a populated
    /// dashboard for the metrics Health provides. `internal` (not `private`) so the merge precedence
    /// is unit-testable; `apple` defaults to empty so existing two-source callers are unaffected.
    static func mergeDaily(imported: [DailyMetric], computed: [DailyMetric], apple: [DailyMetric] = []) -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for d in apple    { byDay[d.day] = d }   // Apple Health: lowest priority…
        for d in computed { byDay[d.day] = d }   // …computed overwrites Apple…
        for d in imported { byDay[d.day] = d }   // …and a real WHOOP import always wins
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Same precedence for sleep sessions, keyed by the day the night ends on.
    private static func mergeSleep(imported: [CachedSleepSession], computed: [CachedSleepSession]) -> [CachedSleepSession] {
        func endDay(_ s: CachedSleepSession) -> String {
            dayString(Date(timeIntervalSince1970: TimeInterval(s.endTs)))
        }
        var byDay: [String: CachedSleepSession] = [:]
        for s in computed { byDay[endDay(s)] = s }
        for s in imported { byDay[endDay(s)] = s }
        return byDay.values.sorted { $0.startTs < $1.startTs }
    }

    // MARK: - Detail passthroughs

    func dailyMetrics(fromDay: String, toDay: String) async -> [DailyMetric] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay)) ?? []
    }

    func hrSamples(from: Int, to: Int, limit: Int = 8000) async -> [HRSample] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.hrSamples(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
    }

    /// Downsampled HR (mean bpm per `bucketSeconds`) for the strap, for a Today/24h trend chart.
    /// Aggregated in SQL so a full day never loads the raw ~1 Hz rows.
    func hrBuckets(from: Int, to: Int, bucketSeconds: Int = 300) async -> [HRBucket] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.hrBuckets(deviceId: deviceId, from: from, to: to, bucketSeconds: bucketSeconds)) ?? []
    }

    /// bpm → sample-count histogram for the strap (SQL-aggregated), for TRIMP-based strain.
    func hrHistogram(from: Int, to: Int) async -> [WhoopStore.HRBin] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.hrHistogram(deviceId: deviceId, from: from, to: to)) ?? []
    }


    func sleepSessions(from: Int, to: Int, limit: Int = 100) async -> [CachedSleepSession] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.sleepSessions(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
    }

    /// Every sleep BLOCK across BOTH sources, UN-deduplicated — so a split-sleep day (a nap
    /// + a main sleep, or any night recorded as multiple blocks) keeps ALL of its blocks.
    /// `sleeps` collapses each day to a single winner for the dashboard; this does not.
    ///
    /// Crucially this reads the on-device COMPUTED source (`computedDeviceId`) directly, not
    /// just the imported `deviceId`. A Bluetooth-only user (no WHOOP/Apple-Health import) has
    /// every block under the computed source, so a loader that only un-dedupes the imported
    /// device sees nothing to expand and silently falls back to the deduped one-per-day list —
    /// hiding the day's extra blocks. Imported blocks still win on any day they cover (matching
    /// the dashboard's imported-wins merge); computed blocks fill days with no import.
    /// Oldest→newest by onset.
    func allSleepSessions(days: Int = 4000) async -> [CachedSleepSession] {
        guard let store = await ensureStore() else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        let lo = now - days * 86_400, hi = now + 86_400
        let imported = (try? await store.sleepSessions(deviceId: deviceId, from: lo, to: hi, limit: 4000)) ?? []
        let computed = (try? await store.sleepSessions(deviceId: computedDeviceId, from: lo, to: hi, limit: 4000)) ?? []
        let cal = Calendar.current
        func endDay(_ s: CachedSleepSession) -> Date {
            cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
        }
        var importedDays = Set<Date>()
        for s in imported { importedDays.insert(endDay(s)) }
        let computedKept = computed.filter { !importedDays.contains(endDay($0)) }
        return (imported + computedKept).sorted { $0.startTs < $1.startTs }
    }

    // MARK: - Metric explorer reads (generic substrate)

    /// Daily series for any metric key from a given source ("my-whoop" / "apple-health").
    func series(key: String, source: String, days: Int = 4000) async -> [(day: String, value: Double)] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        let from = Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = Self.dayString(now.addingTimeInterval(86_400))
        let pts = (try? await store.metricSeries(deviceId: source, key: key, from: from, to: to)) ?? []
        return pts.map { ($0.day, $0.value) }
    }

    func availableKeys(source: String) async -> [String] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.metricKeys(deviceId: source)) ?? []
    }

    /// Native journal answers live under this dedicated source id. The journal table has no
    /// `source` column (PK is (deviceId, day, question)), so writing native answers under the
    /// imported `deviceId` would let a CSV re-import silently overwrite them — and clears could
    /// then delete imported rows. A separate device id keeps the two streams independent.
    static let journalDeviceId = "noop-journal"

    /// Logged behaviours (imported WHOOP journal ∪ native noop-journal) for correlation insights.
    func journalEntries(days: Int = 4000) async -> [JournalEntry] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        let from = Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = Self.dayString(now.addingTimeInterval(86_400))
        let imported = (try? await store.journalEntries(deviceId: deviceId, from: from, to: to)) ?? []
        let native = (try? await store.journalEntries(deviceId: Self.journalDeviceId,
                                                      from: from, to: to)) ?? []
        return Self.mergeJournal(imported: imported, native: native)
    }

    /// Reconcile a single day's journal (Journal screen save): upsert the answered `write` rows
    /// under the native source (so they win the merge and survive re-imports) and delete the
    /// `delete` question keys from BOTH sources — native (an answer the user cleared; the merge
    /// gives native rows priority, so leaving one behind would
    /// silently resurrect it) and imported (duplicate question variants the Journal collapsed onto
    /// a single representative). Refreshes caches once.
    func reconcileJournalDay(_ day: String, write: [JournalEntry], delete: [String]) async {
        guard let store = await ensureStore() else { return }
        if !write.isEmpty { _ = try? await store.upsertJournal(write, deviceId: Self.journalDeviceId) }
        if !delete.isEmpty {
            _ = try? await store.deleteJournal(deviceId: Self.journalDeviceId, day: day, questions: delete)
            _ = try? await store.deleteJournal(deviceId: deviceId, day: day, questions: delete)
        }
        if !write.isEmpty || !delete.isEmpty { await refresh() }
    }

    /// Distinct journal question strings already present (e.g. from a WHOOP import), so the
    /// Journal can absorb them into the tracked set and guarantee key unification.
    func importedJournalQuestions(days: Int = 4000) async -> [String] {
        let entries = await journalEntries(days: days)
        var seen = Set<String>(); var out: [String] = []
        for e in entries where seen.insert(e.question).inserted { out.append(e.question) }
        return out
    }


    /// Union; the NATIVE row wins per (day, question) — the in-app answer is the user's most recent
    /// explicit action and stays editable, unlike the immutable imported history.
    static func mergeJournal(imported: [JournalEntry], native: [JournalEntry]) -> [JournalEntry] {
        var byKey: [String: JournalEntry] = [:]
        for e in imported { byKey[e.day + "\u{1F}" + e.question] = e }
        for e in native { byKey[e.day + "\u{1F}" + e.question] = e }
        return byKey.values.sorted { ($0.day, $0.question) < ($1.day, $1.question) }
    }


    /// All workouts (Whoop + Apple Health + on-device detected bouts), newest first.
    ///
    /// Detected bouts are surfaced with an honest "Detected" badge so the user can see — and
    /// dismiss or re-label — a duplicate the auto-detector created (#107). Dismissed detected spans
    /// are filtered HERE so every consumer (Workouts screen, Today, Coach context) agrees: the engine
    /// re-derives the detected rows each run, so a plain delete would resurrect them; the dismissed
    /// span list is the durable "not a workout" record.
    func workoutRows(days: Int = 4000) async -> [WorkoutRow] {
        guard let store = await ensureStore() else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        let lo = now - days * 86_400, hi = now + 86_400
        var rows = (try? await store.workouts(deviceId: deviceId, from: lo, to: hi, limit: 5000)) ?? []
        rows += (try? await store.workouts(deviceId: "apple-health", from: lo, to: hi, limit: 5000)) ?? []
        rows += (try? await store.workouts(deviceId: computedDeviceId, from: lo, to: hi, limit: 5000)) ?? []
        let spans = WorkoutSource.parseDismissedSpans(dismissedDetectedSpans)
        return rows.filter { !WorkoutSource.isDismissed($0, spans: spans) }
            .sorted { $0.startTs > $1.startTs }
    }

    // MARK: - Workout editing (manual add/edit · relabel · dismiss · delete)
    //
    // Manual workouts live under the strap source (deviceId == `deviceId`, source "manual") — the same
    // place v1.67's live-tracked sessions already land (AppModel.endWorkout). Detected bouts live under
    // the computed `computedDeviceId` with sport "detected" and are wiped + re-derived each engine run,
    // so the only durable way to keep one hidden after a re-detect is the dismissed-span list below.

    /// The persisted dismissed detected spans ("startTs:endTs"). Read straight off UserDefaults so the
    /// read path and the write path share one source of truth (the engine never sees this — it always
    /// re-derives; only the read filter and these mutators consult it).
    private var dismissedDetectedSpans: [String] {
        get { UserDefaults.standard.stringArray(forKey: WorkoutSource.dismissedDefaultsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: WorkoutSource.dismissedDefaultsKey) }
    }

    /// Persist a retroactive / edited manual workout under the strap source. `replacing` is the row the
    /// edit started from:
    ///  - editing a DETECTED bout ("Edit details…") replaces it with this manual row — the detected
    ///    original is dismissed durably so the re-detector doesn't bring it back (else both would show);
    ///  - editing a MANUAL row whose natural key (startTs/sport) changed deletes the stale strap row
    ///    first (the (deviceId, startTs, sport) PK upsert would otherwise orphan it);
    ///  - an IMPORTED row is never passed here as `replacing` (duplicating one is a pure add), so its
    ///    history is never touched.
    func saveManualWorkout(_ row: WorkoutRow, replacing old: WorkoutRow? = nil) async {
        guard let store = await ensureStore() else { return }
        if let old, WorkoutSource.classify(old.source) == .detected {
            await dismissDetected(old)
        } else if let old, old.startTs != row.startTs || old.sport != row.sport {
            _ = try? await store.deleteWorkouts(deviceId: deviceId, sport: old.sport,
                                                from: old.startTs, to: old.startTs)
        }
        _ = try? await store.upsertWorkouts([row], deviceId: deviceId)
    }

    /// Re-label a detected bout: copy it to a manual strap row with the chosen sport, then delete the
    /// detected original. This survives analyzeRecent — the engine wipes + re-derives only sport
    /// "detected" rows under the computed id AND skips any re-derived bout overlapping a real strap
    /// workout, which this copy now is — so the same session is never re-created as a duplicate. (#107)
    func relabelDetected(_ row: WorkoutRow, sport: String) async {
        guard let store = await ensureStore() else { return }
        let trimmed = sport.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let manual = WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: trimmed, source: "manual",
                                durationS: row.durationS, energyKcal: row.energyKcal,
                                avgHr: row.avgHr, maxHr: row.maxHr, strain: row.strain,
                                distanceM: row.distanceM, zonesJSON: row.zonesJSON, notes: row.notes)
        _ = try? await store.upsertWorkouts([manual], deviceId: deviceId)
        _ = try? await store.deleteWorkouts(deviceId: computedDeviceId, sport: "detected",
                                            from: row.startTs, to: row.startTs)
    }

    /// Dismiss a DETECTED bout the user says isn't a workout. Records its span in the durable dismissed
    /// list (so a re-detect that recreates the same span stays hidden) AND deletes the current row so it
    /// disappears immediately. Idempotent: a span already present isn't duplicated. (#107)
    func dismissDetected(_ row: WorkoutRow) async {
        guard WorkoutSource.classify(row.source) == .detected else { return }
        let token = WorkoutSource.dismissedToken(for: row)
        var spans = dismissedDetectedSpans
        if !spans.contains(token) { spans.append(token); dismissedDetectedSpans = spans }
        guard let store = await ensureStore() else { return }
        _ = try? await store.deleteWorkouts(deviceId: computedDeviceId, sport: row.sport,
                                            from: row.startTs, to: row.startTs)
    }

    /// Delete ONE workout by natural key. The read model has no deviceId, so reconstruct it from the
    /// source: detected rows live under the computed id (and also get their span dismissed so they don't
    /// come back); everything else the screen can delete (manual) lives under the strap id.
    func deleteWorkout(_ row: WorkoutRow) async {
        if WorkoutSource.classify(row.source) == .detected { await dismissDetected(row); return }
        guard let store = await ensureStore() else { return }
        _ = try? await store.deleteWorkouts(deviceId: deviceId, sport: row.sport,
                                            from: row.startTs, to: row.startTs)
    }

    /// Apple Health daily aggregates (steps/energy/vo2/hr).
    func appleDailyRows(days: Int = 4000) async -> [AppleDaily] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        return (try? await store.appleDaily(
            deviceId: "apple-health",
            from: Self.dayString(now.addingTimeInterval(-Double(days) * 86_400)),
            to: Self.dayString(now.addingTimeInterval(86_400)))) ?? []
    }

    // MARK: - Diagnostics (remote troubleshooting export)

    /// UTC `yyyy-MM-dd HH:mm` for rendering unix-second spans in the diagnostics report.
    private static let utcStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
    private static func stamp(_ ts: Int?) -> String {
        guard let ts, ts > 0 else { return "—" }
        return utcStampFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts))) + "Z"
    }

    /// A human-readable on-device diagnostics report plus the raw JSON snapshot, for the Live
    /// screen's Copy/Save buttons. Read-only. A "no strain / no recovery / no stress" report is
    /// almost always one upstream cause (no HR/RR rows, or a frozen strap RTC); this surfaces the
    /// row counts, timestamp spans, sync cursors and clock offset that pin down which.
    func diagnosticsText() async -> String {
        guard let store = await ensureStore() else { return "NOOP diagnostics — store unavailable" }
        guard let d = try? await store.diagnosticsSnapshot() else {
            return "NOOP diagnostics — snapshot failed"
        }
        let now = Date()
        let nowTs = Int(now.timeIntervalSince1970)

        func lpad16(_ s: String) -> String { s.padding(toLength: 16, withPad: " ", startingAt: 0) }
        func rpad7(_ n: Int) -> String {
            let s = String(n); return s.count >= 7 ? s : String(repeating: " ", count: 7 - s.count) + s
        }
        func num(_ v: Double?, _ places: Int = 0) -> String {
            guard let v else { return "—" }
            return String(format: "%.\(places)f", v)
        }

        var out = ""
        out += "NOOP diagnostics — \(Self.stamp(nowTs))\n"
        out += "strap deviceId: \(deviceId)\n"
        out += "computed id:    \(computedDeviceId)\n"
        out += "apple id:       \(appleDeviceId)\n"
        out += "today key:      \(Self.localDayKey(now))   schema: v\(d.schemaVersion)\n"
        out += String(repeating: "-", count: 48) + "\n"

        out += "STREAM ROWS  (count | first → last, UTC):\n"
        for t in d.tsTables {
            let span = t.count == 0 ? "—" : "\(Self.stamp(t.minTs)) → \(Self.stamp(t.maxTs))"
            out += "  \(lpad16(t.name)) \(rpad7(t.count)) | \(span)\n"
        }
        out += "DAY CACHES  (count | first → last):\n"
        for t in d.dayTables {
            let span = t.count == 0 ? "—" : "\(t.minDay ?? "?") → \(t.maxDay ?? "?")"
            out += "  \(lpad16(t.name)) \(rpad7(t.count)) | \(span)\n"
        }

        if !d.hrByDevice.isEmpty {
            out += "HR by device: " + d.hrByDevice.map { "\($0.deviceId)=\($0.count)" }.joined(separator: ", ") + "\n"
        }
        if !d.rrByDevice.isEmpty {
            out += "RR by device: " + d.rrByDevice.map { "\($0.deviceId)=\($0.count)" }.joined(separator: ", ") + "\n"
        }
        if !d.eventKinds.isEmpty {
            out += "EVENT kinds: " + d.eventKinds.prefix(12).map { "\($0.kind)=\($0.count)" }.joined(separator: ", ") + "\n"
        }
        out += "CURSORS: " + (d.cursors.isEmpty ? "—" : d.cursors.map { "\($0.name)=\($0.value)" }.joined(separator: ", ")) + "\n"
        out += "DEVICES: " + (d.devices.isEmpty ? "—" : d.devices.map { "\($0.id)(\($0.name ?? "?")) seen \(Self.stamp($0.lastSeen))" }.joined(separator: "; ")) + "\n"
        out += "RAW outbox: \(d.rawBatchCount) batches, \(d.rawBytes) bytes\n"
        if let c = d.latestClockRef {
            let days = Double(c.offsetSec) / 86_400.0
            out += "CLOCK (latest rawBatch): device=\(Self.stamp(c.deviceClockRef)) wall=\(Self.stamp(c.wallClockRef)) offset=\(c.offsetSec)s (\(num(days, 1)) days)\n"
        }
        if !d.recentDailyMetrics.isEmpty {
            out += "RECENT dailyMetric:\n"
            for r in d.recentDailyMetrics.prefix(7) {
                out += "  \(r.day) [\(r.deviceId)] rec=\(num(r.recovery)) strain=\(num(r.strain, 1)) hrv=\(num(r.avgHrv)) rhr=\(r.restingHr.map(String.init) ?? "—")\n"
            }
        }

        // Verdict hints — the most common "no data" causes, derived from the counts above.
        out += String(repeating: "-", count: 48) + "\nREADING:\n"
        let hr = d.tsTables.first { $0.name == "hrSample" }
        let rr = d.tsTables.first { $0.name == "rrInterval" }
        let ev = d.tsTables.first { $0.name == "event" }
        if (hr?.count ?? 0) == 0 {
            out += "  • 0 HR samples → strain, recovery AND stress all blank (all need HR/HRV).\n"
        }
        if (rr?.count ?? 0) == 0 {
            out += "  • 0 RR intervals → no HRV → recovery & stress can't compute even with HR.\n"
        }
        if let ev, ev.count > 0, let mx = ev.maxTs {
            let lagDays = (nowTs - mx) / 86_400
            if lagDays > 2 {
                out += "  • Newest event is \(lagDays) days old → strap RTC likely frozen/stale (deep-discharge).\n"
            }
        }
        if let c = d.latestClockRef, abs(c.offsetSec) > 86_400 {
            out += "  • Clock offset \(c.offsetSec / 86_400) days → strap RTC not synced to real time.\n"
        }

        out += String(repeating: "-", count: 48) + "\n--- raw JSON ---\n"
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(d), let json = String(data: data, encoding: .utf8) {
            out += json + "\n"
        }
        return out
    }

    /// Shared formatter — created once. Hot read path (called per series window / refresh);
    /// allocating a DateFormatter per call was a measurable waste. Read-only use is thread-safe.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayString(_ d: Date) -> String { dayFormatter.string(from: d) }
}
