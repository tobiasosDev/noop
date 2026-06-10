import Foundation
import Combine
import WhoopStore
import WhoopProtocol

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
    @Published var loaded = false
    /// Monotonic counter bumped on every successful `refresh()`. Intraday-updating views key their
    /// data load on this so they reload when fresh strap data lands — `today?.day` alone is a stable
    /// date string within a day and would freeze e.g. the Today HR trend until the date rolls over.
    @Published private(set) var refreshSeq = 0

    init(deviceId: String, appleDeviceId: String = "apple-health") {
        self.deviceId = deviceId
        self.appleDeviceId = appleDeviceId
    }

    /// Today's row, by the device's ACTUAL local calendar date — NOT just the newest stored row, which
    /// after a historical import was months-old data shown as today's hero (issue #23). nil if no row
    /// for today yet (the dashboard then shows its empty/pending state).
    var today: DailyMetric? {
        let key = Repository.localDayKey(Date())
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

    /// Logged behaviours (Whoop journal) for correlation insights.
    func journalEntries(days: Int = 4000) async -> [JournalEntry] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        return (try? await store.journalEntries(
            deviceId: deviceId,
            from: Self.dayString(now.addingTimeInterval(-Double(days) * 86_400)),
            to: Self.dayString(now.addingTimeInterval(86_400)))) ?? []
    }

    /// Persist natively-logged journal answers under the strap deviceId — the SAME source the
    /// importer writes to and `InsightsView` reads — so logged + imported entries unify on
    /// (deviceId, day, question). Refreshes the dashboard caches so Insights/history reload.
    func saveJournal(_ rows: [JournalEntry]) async {
        guard let store = await ensureStore(), !rows.isEmpty else { return }
        _ = try? await store.upsertJournal(rows, deviceId: deviceId)
        await refresh()
    }

    /// Reconcile a single day's journal: upsert the answered `write` rows and delete the `delete`
    /// question keys (rows the user cleared, or duplicate variants now collapsed onto a single
    /// representative). Keyed by (deviceId, day, question). Refreshes caches once.
    func reconcileJournalDay(_ day: String, write: [JournalEntry], delete: [String]) async {
        guard let store = await ensureStore() else { return }
        if !write.isEmpty { _ = try? await store.upsertJournal(write, deviceId: deviceId) }
        if !delete.isEmpty { _ = try? await store.deleteJournal(deviceId: deviceId, day: day, questions: delete) }
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

    /// All workouts (Whoop + Apple Health), newest first.
    func workoutRows(days: Int = 4000) async -> [WorkoutRow] {
        guard let store = await ensureStore() else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        let lo = now - days * 86_400, hi = now + 86_400
        var rows = (try? await store.workouts(deviceId: deviceId, from: lo, to: hi, limit: 5000)) ?? []
        rows += (try? await store.workouts(deviceId: "apple-health", from: lo, to: hi, limit: 5000)) ?? []
        return rows.sorted { $0.startTs > $1.startTs }
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
