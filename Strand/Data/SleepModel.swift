import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - SleepInputKey

/// Cheap, Equatable fingerprint of the repo inputs SleepView derives from. Two snapshots are
/// equal iff the data the screen reads is unchanged, so the heavy `SleepModel` rebuild is
/// skipped on the many `body` re-evaluations that don't touch sleep data.
struct SleepInputKey: Equatable {
    let loaded: Bool
    let daysCount: Int
    let sleepsCount: Int
    let firstDay: String?
    let lastDay: String?
    /// Newest day row (Equatable) — catches in-place edits to the latest day's values.
    let lastDayUpdated: DailyMetric?
    /// Newest sleep session (Equatable) — catches a re-import of the latest night.
    let lastSleep: CachedSleepSession?
    /// Bumped on every Repository.refresh — catches a re-import that changes only the
    /// imported metricSeries figures (importedSleep) without touching days/sleeps.
    let refreshSeq: Int

    @MainActor
    init(repo: Repository) {
        loaded = repo.loaded
        daysCount = repo.days.count
        sleepsCount = repo.sleeps.count
        firstDay = repo.days.first?.day
        lastDay = repo.days.last?.day
        lastDayUpdated = repo.days.last
        lastSleep = repo.sleeps.last
        refreshSeq = repo.refreshSeq
    }
}

// MARK: - SleepModel

/// Memoized result of every expensive SleepView derivation. Built once per data change in
/// `SleepModel.build(repo:)` and read by the subviews, so full passes over repo.days / repo.sleeps and
/// the Night.intervals reconstruction no longer run on every render.
struct SleepModel {
    /// (latest, typical mean, full history) per metric.
    typealias Metric = (latest: Double?, typical: Double?, series: [Double])

    let night: Night
    /// Stage intervals for the hypnogram — computed once (Night.intervals is a computed
    /// property; it was previously re-derived on each access during render).
    let intervals: [SleepInterval]
    /// True when `intervals` are the stager's persisted per-epoch segments (on-device
    /// APPROXIMATE staging), not the synthesized architecture.
    let isPersistedHypnogram: Bool
    /// Sleep need (minutes) for the latest night — the imported WHOOP need for that day
    /// when the export carried one (so the hero's supporting line can't contradict the
    /// export-verbatim performance %), else the personal-mean fallback. Stored here so
    /// reading it per render is free (sleepNeedMin is a full pass over repo.days).
    let needMin: Double

    let performance: Metric
    let efficiency: Metric
    let consistency: Metric
    let hoursVsNeeded: Metric
    let restorative: Metric
    let respiratory: Metric
    let sleepDebt: Metric

    let typicalTotalMin: Double?
    let typicalDeepMin: Double?
    let typicalRemMin: Double?
    let typicalLightMin: Double?

    let trendPoints: [TrendPoint]

    /// Build every expensive derivation exactly once. Called only when `SleepInputKey` changes,
    /// so each full pass over repo.days / repo.sleeps runs once per data change rather than
    /// once per render. Returns nil when there is no usable latest night (renders empty state).
    @MainActor
    static func build(repo: Repository) -> SleepModel? {
        guard let night = latestNight(repo) else { return nil }
        // The personal-mean need is a full pass over repo.days — compute it ONCE here and
        // thread it into the three series that previously each recomputed it. The latest
        // night's need prefers the imported WHOOP figure (when positive) so the hero's
        // supporting line can't contradict the export-verbatim performance %; the fallback
        // is floored at 7.5h (SleepNeed.floorMin), so needMin is always positive.
        let personalNeed = sleepNeedMin(repo)
        let latestNeed = repo.days.last
            .flatMap { repo.importedSleep[$0.day]?.needMin }
            .flatMap { $0 > 0 ? $0 : nil } ?? personalNeed
        return SleepModel(
            night: night,
            intervals: night.intervals,
            isPersistedHypnogram: (night.realSegments?.count ?? 0) >= 2,
            needMin: latestNeed,
            performance: performanceSeries(repo, needMin: personalNeed),
            efficiency: efficiencySeries(repo),
            consistency: consistencySeries(repo),
            hoursVsNeeded: hoursVsNeededSeries(repo, needMin: personalNeed),
            restorative: restorativeSeries(repo),
            respiratory: respiratorySeries(repo),
            sleepDebt: sleepDebtSeries(repo, needMin: personalNeed),
            typicalTotalMin: typicalTotalMin(repo),
            typicalDeepMin: typicalStageMin(repo, \.deepMin),
            typicalRemMin: typicalStageMin(repo, \.remMin),
            typicalLightMin: typicalStageMin(repo, \.lightMin),
            trendPoints: durationTrendPoints(repo))
    }

    // MARK: - Derived model

    /// The most recent sleep, decoded into stage durations. TWO stagesJSON formats exist:
    /// imported nights store a dict of MINUTES {"light","deep","rem","awake"}; on-device computed
    /// nights store a SEGMENT ARRAY [{start,end,stage}] (AnalyticsEngine.encodeStages). Only the
    /// dict was decoded before, so a Bluetooth-only user's night vanished from this tab entirely
    /// while Intelligence showed it (#77). Computed nights also carry their REAL timeline now —
    /// the hypnogram draws genuine segments instead of the synthetic reconstruction.
    @MainActor
    private static func latestNight(_ repo: Repository) -> Night? {
        guard let s = repo.sleeps.last else { return nil }
        if let stages = decodeStages(s.stagesJSON), stages.total > 0 {
            return Night(session: s, stages: stages)
        }
        if let seg = decodeSegments(s.stagesJSON, sessionStart: s.startTs), seg.stages.total > 0 {
            return Night(session: s, stages: seg.stages, realSegments: seg.intervals)
        }
        return nil
    }

    /// Mean total sleep duration (minutes) across nights with data — the "typical".
    @MainActor
    private static func typicalTotalMin(_ repo: Repository) -> Double? {
        mean(repo.days.compactMap { $0.totalSleepMin }.filter { $0 > 0 })
    }

    /// Mean of a per-stage minutes column across days with data.
    @MainActor
    private static func typicalStageMin(_ repo: Repository, _ key: KeyPath<DailyMetric, Double?>) -> Double? {
        mean(repo.days.compactMap { $0[keyPath: key] }.filter { $0 > 0 })
    }

    // MARK: - Per-tile series (latest, typical mean, sparkline history)

    /// Build a metric from a per-day transform, keeping only finite positive-ish values.
    @MainActor
    private static func metric(_ repo: Repository, _ transform: (DailyMetric) -> Double?) -> Metric {
        let series = repo.days.compactMap(transform).filter { $0.isFinite }
        return (series.last, mean(series), series)
    }

    /// Sleep performance %: the imported WHOOP figure (sleep_performance, 0–100) when the
    /// export carried one for that day; else the APPROXIMATE fallback (asleep / personal
    /// need, capped 100) so strap-only days after the import horizon stay populated.
    @MainActor
    static func performanceSeries(_ repo: Repository, needMin: Double? = nil) -> Metric {
        let imported = repo.importedSleep
        let need = needMin ?? sleepNeedMin(repo)
        return metric(repo) { d in
            if let p = imported[d.day]?.performancePct { return p }   // export-verbatim
            guard let asleep = d.totalSleepMin, asleep > 0, need > 0 else { return nil }
            return min(100, asleep / need * 100)   // APPROXIMATE fallback
        }
    }

    @MainActor
    private static func efficiencySeries(_ repo: Repository) -> Metric {
        metric(repo) { d in
            guard let e = d.efficiency else { return nil }
            return e <= 1.0 ? e * 100 : e
        }
    }

    /// Consistency: prefer the imported sleep_consistency series, but only when it covers
    /// the latest night — otherwise "latest" would silently be a months-old import-era
    /// value. Fallback is the APPROXIMATE rolling bedtime-spread score (per session, lower
    /// spread → higher score, same SD→score mapping).
    @MainActor
    private static func consistencySeries(_ repo: Repository) -> Metric {
        let imported = repo.importedSleep
        if let lastDay = repo.days.last?.day, imported[lastDay]?.consistencyPct != nil {
            let series = repo.days.compactMap { imported[$0.day]?.consistencyPct }
            return (series.last, mean(series), series)
        }
        let cal = Calendar.current
        func bedMinutes(_ s: CachedSleepSession) -> Double {
            let d = Date(timeIntervalSince1970: TimeInterval(s.startTs))
            let comps = cal.dateComponents([.hour, .minute], from: d)
            var m = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
            if m < 12 * 60 { m += 24 * 60 }   // wrap evening onsets into one continuous scale
            return m
        }
        let mins = repo.sleeps.map(bedMinutes)
        guard mins.count >= 3 else { return (nil, nil, []) }
        var scores: [Double] = []
        for i in mins.indices {
            let lo = Swift.max(0, i - 13)
            let window = Array(mins[lo...i])
            guard window.count >= 3 else { continue }
            let m = window.reduce(0, +) / Double(window.count)
            let variance = window.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(window.count)
            let sd = variance.squareRoot()
            scores.append(Swift.max(0, Swift.min(100, 100 * (1 - sd / 120))))
        }
        return (scores.last, mean(scores), scores)
    }

    /// Hours vs needed % = asleep / need (can exceed 100 on a long night). The imported
    /// sleep_need_min wins per day; else the APPROXIMATE personal-mean need.
    @MainActor
    private static func hoursVsNeededSeries(_ repo: Repository, needMin: Double? = nil) -> Metric {
        let imported = repo.importedSleep
        let fallbackNeed = needMin ?? sleepNeedMin(repo)
        return metric(repo) { d in
            guard let asleep = d.totalSleepMin, asleep > 0 else { return nil }
            let need = imported[d.day]?.needMin ?? fallbackNeed
            guard need > 0 else { return nil }
            return asleep / need * 100
        }
    }

    /// Restorative % = (deep + REM) / asleep — the share of the night that does the work.
    @MainActor
    private static func restorativeSeries(_ repo: Repository) -> Metric {
        metric(repo) { d in
            guard let deep = d.deepMin, let rem = d.remMin,
                  let asleep = d.totalSleepMin, asleep > 0 else { return nil }
            return (deep + rem) / asleep * 100
        }
    }

    @MainActor
    private static func respiratorySeries(_ repo: Repository) -> Metric {
        metric(repo) { $0.respRateBpm }
    }

    /// Sleep debt (minutes): the imported sleep_debt_min when the export carried it; else
    /// the APPROXIMATE per-night need − asleep, floored at 0 (no "credit").
    @MainActor
    static func sleepDebtSeries(_ repo: Repository, needMin: Double? = nil) -> Metric {
        let imported = repo.importedSleep
        let need = needMin ?? sleepNeedMin(repo)
        let series = repo.days.compactMap { d -> Double? in
            if let debt = imported[d.day]?.debtMin { return debt }   // minutes, export-verbatim
            guard let asleep = d.totalSleepMin, asleep > 0, need > 0 else { return nil }
            return SleepNeed.debtMin(needMin: need, asleepMin: asleep)   // APPROXIMATE fallback
        }
        return (series.last, mean(series), series)
    }

    /// The personal sleep need (minutes) — shared math with the Sleep Planner (SleepNeed).
    @MainActor
    static func sleepNeedMin(_ repo: Repository) -> Double {
        SleepNeed.needMin(totalSleepMinsByNight: repo.days.compactMap { $0.totalSleepMin })
    }

    /// Personal typical efficiency as 0–1, nil without history.
    @MainActor
    static func typicalEfficiency(_ repo: Repository) -> Double? {
        let vals = repo.days.compactMap { $0.efficiency }.map { $0 <= 1.0 ? $0 : $0 / 100 }
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    // MARK: - Trend points

    /// Trailing 30 days of total sleep, plotted in HOURS. Falls back to all nights with
    /// data if the trailing window is too sparse.
    @MainActor
    private static func durationTrendPoints(_ repo: Repository) -> [TrendPoint] {
        let fmt = dayParser
        func build(_ slice: ArraySlice<DailyMetric>) -> [TrendPoint] {
            slice.compactMap { d -> TrendPoint? in
                guard let mins = d.totalSleepMin, mins > 0,
                      let date = fmt.date(from: d.day) else { return nil }
                return TrendPoint(date: date, value: mins / 60.0)
            }
        }
        let recent = build(repo.days.suffix(30))
        if recent.count >= 2 { return recent }
        return build(repo.days[...])
    }

    // MARK: - Helpers

    private static func mean(_ vals: [Double]) -> Double? {
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    // MARK: - Stage decoding

    /// Decode the imported stagesJSON dict of MINUTES {"light","deep","rem","awake"}.
    private static func decodeStages(_ json: String?) -> Stages? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        func val(_ key: String) -> Double {
            if let n = dict[key] as? NSNumber { return n.doubleValue }
            if let d = dict[key] as? Double { return d }
            if let i = dict[key] as? Int { return Double(i) }
            return 0
        }
        let s = Stages(awake: val("awake"), light: val("light"),
                       deep: val("deep"), rem: val("rem"))
        return s.total > 0 ? s : nil
    }

    /// Decode the COMPUTED stagesJSON segment array [{"start":epoch,"end":epoch,"stage":"wake"|
    /// "light"|"deep"|"rem"}] into stage totals plus the real timeline (seconds relative to the
    /// session start, the Hypnogram's domain). The on-device SleepStager calls awake "wake". (#77)
    private static func decodeSegments(
        _ json: String?, sessionStart: Int
    ) -> (stages: Stages, intervals: [SleepInterval])? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !arr.isEmpty else { return nil }
        var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        var intervals: [SleepInterval] = []
        for seg in arr {
            guard let start = (seg["start"] as? NSNumber)?.intValue,
                  let end = (seg["end"] as? NSNumber)?.intValue, end > start,
                  let name = seg["stage"] as? String else { continue }
            let minutes = Double(end - start) / 60.0
            let stage: SleepStage
            switch name {
            case "wake", "awake": stage = .awake; stages.awake += minutes
            case "light": stage = .light; stages.light += minutes
            case "deep": stage = .deep; stages.deep += minutes
            case "rem": stage = .rem; stages.rem += minutes
            default: continue
            }
            intervals.append(SleepInterval(
                stage: stage,
                start: TimeInterval(start - sessionStart),
                end: TimeInterval(end - sessionStart)))
        }
        return stages.total > 0 ? (stages, intervals) : nil
    }

    /// yyyy-MM-dd → Date (en_US_POSIX, UTC), per task spec.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Stages

struct Stages {
    var awake: Double
    var light: Double
    var deep: Double
    var rem: Double
    /// All stages (includes awake) — total time-in-bed minutes.
    var total: Double { awake + light + deep + rem }
    /// Asleep time = total minus awake.
    var asleep: Double { light + deep + rem }
}

// MARK: - Night

struct Night {
    let session: CachedSleepSession
    let stages: Stages
    /// The REAL per-segment timeline for on-device computed nights (nil for imported nights,
    /// whose export carries totals only — those keep the synthetic reconstruction below). (#77)
    var realSegments: [SleepInterval]? = nil

    /// Total time in bed in minutes (from reconstructed stages).
    var timeInBed: Double { stages.total }

    /// The wall-clock start of the night (for the Hypnogram's clock labels).
    var onsetDate: Date { Date(timeIntervalSince1970: TimeInterval(session.startTs)) }

    /// Stage intervals laid end-to-end across the night, in seconds from start.
    /// On-device computed nights use their REAL timeline; imported nights are reconstructed
    /// from durations only (the export has no per-epoch timeline).
    var intervals: [SleepInterval] {
        if let real = realSegments, real.count >= 2 { return real }
        var t: TimeInterval = 0
        var out: [SleepInterval] = []
        func add(_ stage: SleepStage, _ minutes: Double) {
            guard minutes > 0 else { return }
            let secs = minutes * 60
            out.append(SleepInterval(stage: stage, start: t, end: t + secs))
            t += secs
        }
        // A plausible architecture: deep early, REM later, awake last.
        add(.light, stages.light * 0.4)
        add(.deep, stages.deep)
        add(.light, stages.light * 0.3)
        add(.rem, stages.rem)
        add(.light, stages.light * 0.3)
        add(.awake, stages.awake)
        return out
    }

    var onsetText: String { Night.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.startTs))) }
    var wakeText: String { Night.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.endTs))) }
    var dateLabel: String { Night.dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.startTs))) }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()
}

// MARK: - Planner inputs

enum SleepPlannerInputs {
    @MainActor
    static func goal(_ behavior: BehaviorStore) -> SleepPlanner.Goal {
        SleepPlanner.Goal(rawValue: behavior.plannerGoalRaw) ?? .perform
    }

    /// Strap alarm wins when enabled; manual planner time otherwise.
    @MainActor
    static func wakeMinutes(_ behavior: BehaviorStore) -> Int {
        behavior.smartAlarmEnabled ? behavior.smartAlarmMinutes : behavior.plannerWakeMinutes
    }

    @MainActor
    static func recommendation(repo: Repository, behavior: BehaviorStore) -> SleepPlanner.Recommendation {
        let lastDebt = SleepModel.sleepDebtSeries(repo).latest ?? 0
        return SleepPlanner.recommend(wakeMinutes: wakeMinutes(behavior),
                                      baseNeedMin: SleepModel.sleepNeedMin(repo),
                                      debtMin: lastDebt,
                                      efficiency: SleepModel.typicalEfficiency(repo),
                                      goal: goal(behavior))
    }
}
