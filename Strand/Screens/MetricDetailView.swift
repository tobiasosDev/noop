import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Detail / drill-down

/// The full analytic dossier for one metric: a glow hero with the latest reading against the personal
/// baseline, the range control, the trend chart, the Average / Min / Max / Latest / Δ card, the readings
/// table with provenance, and "What correlates".
struct MetricDetailView: View {
    let metric: MetricDescriptor
    @EnvironmentObject var repo: Repository
    /// Custom background image (#custom-background): when active it overrides the sky in the backdrop.
    @ObservedObject private var backgroundStore = BackgroundImageStore.shared
    // Profile basics for the Fitness Age not-ready countdown (age/sex gate its readiness lead). Injected
    // app-wide at the root; previews supply their own. Only read on the fitness_age empty-state path.
    @EnvironmentObject var profile: ProfileStore
    // Drives the fitness_age not-ready "refresh" button (force an immediate recompute). App-wide injected.
    @EnvironmentObject var intelligence: IntelligenceEngine
    /// True while a manual Fitness Age refresh runs (spinner on the not-ready empty state).
    @State private var refreshing = false

    // Imperial/Metric display preference (D#103). Display-only: weight (kg) and skin temp (°C) re-label
    // here; everything else is unit-agnostic and renders unchanged.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    // Effort display scale (#268) — routes the Effort metric's numbers + unit; display-only, the plotted
    // series stays 0–100. Every other metric is scale-agnostic (see MetricDescriptor.format).
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    /// Line vs bar for the hero chart, the same preference `TrendsView` reads. This view had never
    /// consulted it, so a chosen `bar` drew a line here while the trend chart for the SAME metric drew
    /// bars. Display-only: nothing about the plotted series changes.
    @AppStorage(UnitPrefs.trendChartStyleKey) private var trendChartStyleRaw = TrendChartStyle.line.rawValue
    /// #1846/#1848: which skin-temp number the explorer leads with — absent/`""` = a temperature
    /// (the default), or `SkinTempDisplay.Kind.deviation.rawValue` to lead with the ±baseline move.
    /// Same key as Today/Health/Settings; display-only, nothing stored ever changes.
    @AppStorage(UnitPrefs.skinTempDisplayKey) private var skinTempDisplayRaw = ""
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    private var skinTempPreferred: SkinTempDisplay.Kind {
        SkinTempDisplay.Kind(rawValue: skinTempDisplayRaw) ?? .absolute
    }
    private func fmt(_ v: Double) -> String {
        if isStepsDetail { return MetricDetailSteps.valueLabel(v, resolution: .daily) }
        return metric.format(v, system: unitSystem, temperature: temperatureUnit, effortScale: effortScale)
    }

    @State private var range: ExploreRange = .month
    /// The readings table shows the five newest until opened.
    @State private var showAllReadings = false
    /// Full ascending series for this metric — ALL history.
    @State private var series: [(day: String, value: Double)] = []
    /// day → the RAW source id that supplied that day's value (task #8). Loaded from `resolvedSeries`
    /// alongside `series` and used ONLY for the readings-table provenance column, so the plotted line
    /// (which rides `series`/`exploreSeries`) is never changed by adding source labels.
    @State private var sourceByDay: [String: String] = [:]
    /// Every OTHER catalog series, loaded once for the correlation scan.
    ///
    /// Filled by a SECOND load phase, after the screen is already on screen — see `load()`. Nothing above
    /// the correlation card reads it, so nothing above the correlation card waits for it.
    @State private var others: [(metric: MetricDescriptor, series: [(day: String, value: Double)])] = []
    /// True once THIS metric's own series is in — the gate for the whole screen (hero, chart, stats,
    /// readings). Deliberately not "everything is in": see `load()`.
    @State private var loaded = false
    /// True once the cross-catalog scan behind the correlation card has finished. Only that one card
    /// reads it, so it can lag the rest of the screen by a second without anyone noticing.
    @State private var correlationsLoaded = false

    /// #1848: the skin-temp explorer's explanatory note (nil when none is needed). Set in `load()`
    /// alongside the series, from the same `repo.days` scan that decides which kind to lead with.
    /// Two notes, mutually exclusive: (1) the user asked for temperatures but the window has none,
    /// so deviations are shown instead; (2) leading with absolutes dropped deviation-only nights
    /// from the series. Both are real on Apple — the same two cases the Android twin carries.
    @State private var skinTempNote: String? = nil

    /// Cached correlation scan, keyed by its inputs (selected range + the metric id),
    /// so the full cross-catalog Pearson sweep runs ONLY when those change — not on
    /// every body re-eval (hover / 1 Hz HR ticks / animation). Recomputed from
    /// `recomputeCorrelations(...)` after load and on range change.
    @State private var correlationCache: [CorrRow] = []
    /// The (metricID, range) the cache was built for; nil means "not yet computed".
    @State private var correlationKey: String? = nil
    private var loadTaskID: String {
        MetricDetailSteps.loadIdentity(metricID: metric.id, refreshSequence: repo.refreshSeq,
                                       skinTemperatureStyle: skinTempDisplayRaw, range: range)
    }

    // MARK: Derived

    /// The trailing-N-days slice for a given range, taken RELATIVE TO THE LATEST data
    /// point (not "now") — `.all` returns everything.
    private func slice(for r: ExploreRange) -> [(day: String, value: Double)] {
        guard let days = r.days else { return series }
        guard let lastDay = series.last?.day, let last = parseDay(lastDay) else { return [] }
        let cutoff = last.addingTimeInterval(-Double(days - 1) * 86_400)
        return series.filter { row in
            guard let d = parseDay(row.day) else { return false }
            return d >= cutoff
        }
    }

    private var isStepsDetail: Bool { MetricDetailSteps.isMetric(metric.key) }

    /// The one series every visible steps summary consumes. Non-step metrics retain their existing raw
    /// daily window unchanged.
    private func presentedSeries(for r: ExploreRange) -> [(day: String, value: Double)] {
        guard isStepsDetail else { return slice(for: r) }
        return MetricDetailSteps.presentation(readings: series, range: r).series
    }

    /// The range actually shown: the SELECTED range whenever its window holds ≥1
    /// point, otherwise the smallest LARGER range that does. So switching ranges is
    /// always visibly distinct when data allows, and only sparse windows widen.
    /// The range the chips + caption ACTUALLY describe, resolved NON-DESTRUCTIVELY from the stored
    /// `range` (#943, true cross-platform lockstep with Android's effectiveVitalRange). We never
    /// overwrite the @State selection - a locked default (`range == .month` with under a week of
    /// history) simply RENDERS as the largest unlocked range with a real finite window that is <= the
    /// selection, else `.week`. NOT `.all`: coercing a locked default to ALL would jump a calibrating
    /// user to the everything view. When the stored range is itself unlocked it is used verbatim, so
    /// once history grows the selection un-coerces on its own with no snap-back.
    private var coercedSelection: ExploreRange {
        ExploreRangeGating.coerced(selection: range, isUnlocked: isUnlocked)
    }

    /// The pill's selection binding: it HIGHLIGHTS the coerced selection (so a locked default shows the
    /// unlocked chip that is actually rendering) but a user tap writes straight to the stored @State
    /// `range`. Reads never mutate state, so this stays non-destructive.
    private var selectionBinding: Binding<ExploreRange> {
        Binding(get: { coercedSelection }, set: { range = $0 })
    }

    private var effectiveRange: ExploreRange {
        guard !series.isEmpty else { return coercedSelection }
        let candidates = isStepsDetail
            ? MetricDetailSteps.widening(from: coercedSelection)
            : coercedSelection.widening
        for r in candidates where !presentedSeries(for: r).isEmpty { return r }
        return .all
    }

    /// Whole days between the first and last reading (0 for a single point). The
    /// UTC-fixed day parser makes the Int truncation exact.
    private var historySpanDays: Int {
        guard let firstDay = series.first?.day, let lastDay = series.last?.day,
              let first = parseDay(firstDay), let last = parseDay(lastDay) else { return 0 }
        return Int(last.timeIntervalSince(first) / 86_400)
    }

    /// Whether a range chip is selectable (#943, reimplemented from ryanbr's PR): a longer
    /// range only unlocks once the history span EXCEEDS the previous window, i.e. once it
    /// would actually show more than the range below it. Before that, every window is taken
    /// relative to the latest point, so thin history sat inside all of them and the six chips
    /// drew byte-identical charts (a week of data stretched full-width under a 1Y label).
    /// W (the shortest) and ALL (the honest everything view) are never gated, so a calibrating
    /// user always has a selectable range; until the series loads (or with no history at all)
    /// nothing is gated, since the empty state deliberately keeps the full range bar for context.
    private func isUnlocked(_ r: ExploreRange) -> Bool {
        guard loaded, !series.isEmpty else { return true }
        switch r {
        case .week, .all: return true
        case .twoWeeks:   return historySpanDays > ExploreRange.week.rawValue
        case .threeWeeks: return historySpanDays > ExploreRange.twoWeeks.rawValue
        case .month:      return historySpanDays > ExploreRange.threeWeeks.rawValue
        case .quarter:    return historySpanDays > ExploreRange.month.rawValue
        case .half:       return historySpanDays > ExploreRange.quarter.rawValue
        case .year:       return historySpanDays > ExploreRange.half.rawValue
        }
    }

    /// True when at least one range chip is locked; drives the one-line unlock hint under
    /// the caption, so the dimmed chips read as "not yet" rather than broken.
    private var hasLockedRanges: Bool { !ExploreRange.allCases.allSatisfy(isUnlocked) }

    /// The window immediately preceding the active one (equal length, by day count).
    private func previousWindow(effectiveRange: ExploreRange,
                                windowed: [(day: String, value: Double)]) -> [(day: String, value: Double)] {
        guard effectiveRange != .all else { return [] }
        if isStepsDetail, let anchorDay = MetricDetailSteps.latestValidDay(readings: series) {
            return MetricDetailSteps.previousPresentation(
                readings: series, range: effectiveRange, currentAnchorDay: anchorDay).series
        }
        let size = windowed.count
        guard size > 0 else { return [] }
        // Index of the active window's first row, then step back `size` rows.
        guard let firstDay = windowed.first?.day,
              let lo = series.firstIndex(where: { $0.day == firstDay }) else { return [] }
        let prevLo = max(0, lo - size)
        guard prevLo < lo else { return [] }
        return Array(series[prevLo..<lo])
    }

    private func trendPoints(_ windowed: [(day: String, value: Double)]) -> [TrendPoint] {
        let segmentIds = metric.key == "vo2max_est"
            ? vo2MaxTrendSegmentIds(days: windowed.map(\.day), sourceByDay: sourceByDay)
            : Array(repeating: "default", count: windowed.count)
        return windowed.enumerated().compactMap { index, row in
            guard let d = parseDay(row.day) else { return nil }
            return TrendPoint(date: d, value: row.value, segment: segmentIds[index])
        }
    }

    /// The personal baseline to annotate the chart with, or nil when there is not one worth drawing.
    ///
    /// HRV and resting HR only: both are levels whose absolute number means little without the reader's
    /// own normal, while the daily scores are already interpretable on their own ranges and skin
    /// temperature has its own signed-deviation view. Folded over the FULL history rather than the
    /// visible window, because the reference is the reader's normal and does not change because they
    /// narrowed the range. Nil until the state is TRUSTED, which is at least fourteen valid nights and
    /// not stale: a rule folded from four would be a guess wearing the authority of a reference line.
    ///
    /// Same fold `VitalBands` bands against, so a reading the grid calls out of range cannot sit on the
    /// comfortable side of the rule. Twin of Kotlin `vitalBaseline`.
    private var personalBaseline: Double? {
        let cfg: MetricCfg?
        switch metric.key {
        case "hrv": cfg = Baselines.hrvCfg
        case "rhr": cfg = Baselines.restingHRCfg
        default: cfg = nil
        }
        guard let cfg else { return nil }
        let state = Baselines.foldHistory(series.map { $0.value }, cfg: cfg)
        return state.trusted ? state.baseline : nil
    }

    /// Padded value range so the line never sits flush against an axis.
    private func valueRange(_ windowValues: [Double]) -> ClosedRange<Double> {
        let v = windowValues
        guard let lo = v.min(), let hi = v.max() else { return 0...1 }
        if hi <= lo { return (lo - 1)...(hi + 1) }
        let span = hi - lo
        return (lo - span * 0.12)...(hi + span * 0.12)
    }

    private func latest(in presented: [(day: String, value: Double)]) -> (day: String, value: Double)? {
        isStepsDetail ? presented.last : series.last
    }

    // MARK: Body

    var body: some View {
        // Compute the heavy window derivations ONCE per body eval, then hand them to
        // the subviews — instead of every subview re-deriving `effectiveRange` /
        // `windowed` (each of which re-parses + re-filters the full history).
        let effRange = effectiveRange
        let rawWin = slice(for: effRange)
        let win = presentedSeries(for: effRange)
        let fellBack = effRange != range
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isVital {
                    vitalHero(windowed: win)
                        .padding(.horizontal, NoopMetrics.screenHPadding)
                        .padding(.top, 6)
                } else {
                    hero(windowed: win, effectiveRange: effRange)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if isVital && loaded && !win.isEmpty {
                        vitalBody(effectiveRange: effRange, windowed: win, rawWindowed: rawWin,
                                  windowFellBack: fellBack)
                    } else {
                        nonVitalBody(effectiveRange: effRange, windowed: win, rawWindowed: rawWin,
                                     windowFellBack: fellBack)
                    }
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.bottom, NoopMetrics.tabBarClearance)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // #697 parity: this screen builds its OWN ScrollView rather than going through
        // ScreenScaffold, so it never inherited the scaffold's horizontal-bounce suppression and
        // could still rubber-band left-right on a purely vertical scroll. Same modifier, same
        // guard. (#1532 follow-up)
        #if os(iOS)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        #if os(iOS) && DEBUG
        .modifier(DemoScrollAnchor())
        #endif
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                NoopVisualStyle.canvas
                // Custom background image (#custom-background) still overrides the ground, full-bleed.
                if backgroundStore.isActive {
                    BackgroundImageBackdrop()
                }
            }
            .ignoresSafeArea()
        }
        // The v2 header names the metric; the system title only labels the macOS window bar.
        #if os(macOS)
        .navigationTitle(metric.title)
        #endif
        .noopHidesSystemNavBar()
        .task(id: loadTaskID) { await load() }
        // Range changes the window, hence the correlation inputs — recompute the
        // cached scan rather than letting the correlation section run it inside body.
        .onChangeCompat(of: range) { _ in recomputeCorrelations() }
    }

    /// Two phases, because the screen used to wait for data it does not draw.
    ///
    /// PERF: `loaded` gates the ENTIRE screen — hero, chart, stat tiles, readings table — and it used to be
    /// set only after the cross-catalog scan had read all 59 OTHER metrics in the catalog, one sequential
    /// `exploreSeries` each. Every one of those walks `repo.days` and sorts on the main actor
    /// (`Repository` is `@MainActor`), and none of them feeds anything above the correlation card at the
    /// very bottom. So opening any metric detail paid ~60 full-history reads before drawing its first
    /// pixel, to satisfy one card most readers never scroll to.
    ///
    /// Phase 1 is this metric's own series + provenance — everything the visible screen needs. `loaded`
    /// flips there. Phase 2 is the catalog scan, awaited afterwards, and only the correlation card waits
    /// on it. Same reads, same results, same order; only the gate moved.
    private func load() async {
        // Phase 1 — what the screen actually draws.
        let requestedRange = range
        let resolution: MetricSeriesResolution
        let loadedSeries: [(day: String, value: Double)]
        if isStepsDetail {
            // Steps have one authoritative daily input for values and provenance. ALL deliberately reads
            // the store-backed full-history resolver instead of the bounded in-memory Explore cache.
            let fullHistory = MetricDetailSteps.requiresFullHistory(
                metricKey: metric.key, range: requestedRange)
            if metric.source == MetricCatalog.combinedStepsSource {
                resolution = await repo.resolvedSteps(from: "0000-01-01", to: "9999-12-31")
            } else {
                resolution = await repo.resolvedSeries(
                    key: metric.key, source: metric.source, fullHistory: fullHistory)
            }
            loadedSeries = resolution.values
        } else {
            // Preserve the generic explorer's established value path and load order.
            loadedSeries = await repo.exploreSeries(key: metric.key, source: metric.source)
            resolution = await repo.resolvedSeries(key: metric.key, source: metric.source)
        }
        // A range tap changes the task identity. Do not let a cancelled bounded read overwrite a newer
        // full-history ALL read (or vice versa) if the underlying store await completes late.
        guard !Task.isCancelled, !isStepsDetail || requestedRange == range else { return }
        series = loadedSeries
        // Per-day provenance for the readings table (task #8). resolvedSeries names the source that
        // actually supplied each day (imported strap / on-device / Apple Health / Health Connect).
        if metric.key == "vo2max_est" {
            var attributed: [String: String] = [:]
            for point in resolution.points {
                let tag = await repo.scoreProvenanceTag(
                    resolvedSource: point.source, day: point.day, metricKey: metric.key)
                attributed[point.day] = vo2MaxAttributionSource(tag.flatMap { Vo2MaxEstimator(rawValue: $0) })
            }
            sourceByDay = attributed
        } else {
            sourceByDay = Dictionary(resolution.points.map { ($0.day, $0.source) },
                                     uniquingKeysWith: { first, _ in first })
        }
        // #103/queue-11a follow-up: fill in the spo2 candidate fallback for any day this Explorer's
        // calibrated `spo2` series has no reading for — the SAME fallback Today's Key Metrics tile,
        // `VitalSignsSummary`, and `LiquidTodayView` already show, which this generic catalog-driven
        // screen never got when #1568 added it everywhere else (found 2026-08-24: an Oura-only or
        // WHOOP-4.0-only install with the toggle ON saw a real number on the tile but an empty/stale
        // screen here). Calibrated days always win — this only ADDS days the calibrated series is
        // missing, never overwrites one. Gated on the same toggle every other candidate site checks.
        //
        // The source is part of the gate, not just the key. The catalog carries TWO `spo2` descriptors —
        // `my-whoop` and `xiaomi-band` — and `MetricDescriptor.id` is `source + ":" + key`, so they are
        // different metrics that happen to share a key. Only the WHOOP/Oura partition has a candidate
        // series behind it; without this a Xiaomi Band's Blood Oxygen card would be asking for a strap
        // estimate that is not its own.
        if metric.key == "spo2", metric.source == "my-whoop", PuffinExperiment.spo2CandidateDisplayEnabled {
            let candidateSeries = await repo.exploreSeries(key: "spo2_candidate", source: metric.source)
            if !candidateSeries.isEmpty {
                // `uniquingKeysWith`, matching the `sourceByDay` build above — NOT
                // `uniqueKeysWithValues`, which TRAPS on a duplicate day. `exploreSeries` collapses by day
                // on the `my-whoop` path it takes here, but `series(key:source:)` — the path every other
                // source falls through to — ends `pts.map { … }` with no collapsing at all, so the
                // guarantee is the caller's, not the type's. The Kotlin twin uses `.toMap()`, which keeps
                // the last value silently; a trap here would mean the same input crashes one platform and
                // not the other.
                var byDay = Dictionary(series.map { ($0.day, $0.value) },
                                       uniquingKeysWith: { first, _ in first })
                for point in candidateSeries where byDay[point.day] == nil {
                    byDay[point.day] = point.value
                    sourceByDay[point.day] = spo2CandidateAttributionSource
                }
                series = byDay.sorted { $0.key < $1.key }.map { (day: $0.key, value: $0.value) }
            }
        }
        // #1848: skin-temp explorer — give it a skin-temp-specific branch mirroring the Android
        // `buildVitalDetail` "skin" case, rather than the shared `dailyColumn` → `skinTempDevC` path.
        //
        // The shared mapper returns `skinTempDevC` only, so the explorer never leads with the measured
        // absolute (`skinTempC`) and ignores the Settings choice (#1846). Repointing `dailyColumn`'s
        // `skin_temp` case would change which series Trends plots and what the band is computed against
        // (its callers include the trend series and the metric-catalog availability check), so the fix
        // is a branch HERE, not a change to the shared mapper.
        //
        // The preference applies across the WINDOW (#1850), not just the newest row: a wearer with
        // twenty stored temperatures and one recent night without saw twenty-three deltas — the setting
        // says Temperature and the app HAS temperatures. `leadReading`'s rule lifted to the window: the
        // chosen kind wins whenever any night carries it, the other is still the fallback, so a choice
        // can never empty the screen.
        //
        // An absolute may live in EITHER column (#622: a WHOOP CSV import writes absolute °C into
        // `skinTempDevC`), so both count here and in the series below.
        skinTempNote = nil
        if metric.key == "skin_temp" {
            let days = repo.days
            let anyAbsolute = days.contains { row in
                row.skinTempC != nil
                    || row.skinTempDevC.map(VitalBands.isAbsoluteSkinTemp) == true
            }
            let anyDeviation = days.contains { row in
                row.skinTempDevC.map { !VitalBands.isAbsoluteSkinTemp($0) } == true
            }
            if anyAbsolute || anyDeviation {
                let leadsAbsolute: Bool
                switch skinTempPreferred {
                case .absolute:   leadsAbsolute = anyAbsolute
                case .deviation:  leadsAbsolute = !anyDeviation && anyAbsolute
                }
                if leadsAbsolute {
                    // An absolute-led series takes EVERY absolute reading, whichever column holds it.
                    // `skinTempC` is the on-device computed absolute; `skinTempDevC` may hold a CSV-imported
                    // absolute (#622 bimodal). Mixing is only unsound ACROSS scales; these are the same scale.
                    series = days.compactMap { row in
                        let v = row.skinTempC
                            ?? row.skinTempDevC.flatMap { VitalBands.isAbsoluteSkinTemp($0) ? $0 : nil }
                        return v.map { (day: row.day, value: $0) }
                    }.sorted { $0.day < $1.day }
                } else {
                    // Genuine deviations only — an imported absolute sitting in `skinTempDevC` belongs to
                    // the other scale and is excluded, exactly as before.
                    series = days.compactMap { row in
                        row.skinTempDevC.flatMap { !VitalBands.isAbsoluteSkinTemp($0) ? $0 : nil }
                            .map { (day: row.day, value: $0) }
                    }.sorted { $0.day < $1.day }
                }
                // The merged `days` cache supplies values but no provenance. Resolve the matching
                // column from the source-tagged rows already used by the vital cards (#2603).
                sourceByDay = skinTempSourceByDay(repo.vitalMetricRows, leadsAbsolute: leadsAbsolute)
                // The two #1847 notes — both cases exist on Apple too:
                // (1) Settings asked for a temperature and none of these nights has one → say so, because
                //     silently falling back is why the setting reads as broken. Nights scored before
                //     `skinTempC` shipped kept only the deviation; a scoring pass refills them.
                // (2) Leading with the absolute drops deviation-only nights from the series — which can
                //     now include the most recent one. Say why rather than letting history look like it
                //     vanished. (Deviation-led drops are the OPPOSITE kind, so the note is gated to
                //     absolute-led only — see `shouldExplainShortenedSkinTempSeries`.)
                let shownReadings = series.count
                let rowsWithEither = days.count { $0.skinTempC != nil || $0.skinTempDevC != nil }
                if shouldExplainSkinTempFallback(prefer: skinTempPreferred, leadsAbsolute: leadsAbsolute,
                                                 anyAbsoluteInWindow: anyAbsolute) {
                    skinTempNote = String(localized: "No measured temperature for these nights — showing the difference from your baseline instead. A re-score refills temperatures for nights that have one.")
                } else if shouldExplainShortenedSkinTempSeries(leadsAbsolute: leadsAbsolute,
                                                                shownReadings: shownReadings,
                                                                rowsWithEitherNumber: rowsWithEither) {
                    skinTempNote = String(localized: "Only nights with a measured temperature are shown — the others only have a baseline difference.")
                }
            }
        }
        // #943 selection seam: a locked default (.month with under a week of history) no longer
        // OVERWRITES @State range - it renders through `coercedSelection` instead (non-destructive,
        // recomputed every body eval), so a shrinking history re-coerces and a growing one un-coerces
        // with no snap-back. See `coercedSelection`.
        loaded = true

        // Phase 2 — the cross-catalog scan behind the correlation card, now that the screen is up.
        // `Task.isCancelled` is checked per metric so navigating away mid-scan stops it: the task is
        // bound to `loadTaskID`, and without the check a quick in-and-out would keep 59 main-actor
        // merges running for a screen nobody is looking at.
        // The scan itself is memoized on the Repository (`exploreAllSeries`), keyed by active strap +
        // `refreshSeq`. It is the SAME data whichever metric is open — this view only drops its own
        // descriptor — so opening five metric details used to pay the whole cross-catalog scan five
        // times. Cancellation semantics are unchanged: the memo checks `Task.isCancelled` per metric and
        // returns nil rather than caching a partial scan, so a quick in-and-out still stops the work and
        // cannot leave a half-filled catalog frozen in for the rest of the generation.
        guard let allSeries = await repo.exploreAllSeries() else { return }
        var loadedOthers: [(metric: MetricDescriptor, series: [(day: String, value: Double)])] = []
        for other in MetricCatalog.all where other.id != metric.id {
            guard !Task.isCancelled else { return }
            if let s = allSeries[other.id], !s.isEmpty { loadedOthers.append((other, s)) }
        }
        guard !Task.isCancelled else { return }
        others = loadedOthers
        correlationsLoaded = true
        // First correlation build, now that `series`/`others` exist.
        recomputeCorrelations()
    }

    /// "N readings · <range>" near the control, flagging an auto-widen when one happened.
    /// Whole-phrase variants per count so translators never see a stitched plural.
    private func rangeCaption(effectiveRange: ExploreRange,
                              windowed: [(day: String, value: Double)],
                              windowFellBack: Bool) -> String {
        guard loaded, !windowed.isEmpty else { return "—" }
        let n = windowed.count
        if isStepsDetail {
            let name = windowFellBack
                ? String(localized: "sparse, widened to \(effectiveRange.name)")
                : effectiveRange.name
            return MetricDetailSteps.countCaption(
                count: n, resolution: MetricDetailSteps.resolution(for: effectiveRange), rangeName: name)
        }
        if windowFellBack {
            return n == 1
                ? String(localized: "1 reading · sparse, widened to \(effectiveRange.name)")
                : String(localized: "\(n) readings · sparse, widened to \(effectiveRange.name)")
        }
        return n == 1
            ? String(localized: "1 reading · \(range.name)")
            : String(localized: "\(n) readings · \(range.name)")
    }

    private func latestCaption(windowed: [(day: String, value: Double)],
                               effectiveRange: ExploreRange) -> String? {
        guard let day = latest(in: windowed)?.day else { return nil }
        if isStepsDetail {
            return MetricDetailSteps.periodLabel(
                day: day, resolution: MetricDetailSteps.resolution(for: effectiveRange))
        }
        guard let d = parseDay(day) else { return nil }
        return longDate(d)
    }

    private func statisticCountCaption(count: Int, effectiveRange: ExploreRange) -> String {
        guard isStepsDetail else {
            return count == 1 ? String(localized: "1 day") : String(localized: "\(count) days")
        }
        switch MetricDetailSteps.resolution(for: effectiveRange) {
        case .daily:
            return count == 1 ? String(localized: "1 observed day") : String(localized: "\(count) observed days")
        case .weekly:
            return count == 1
                ? String(localized: "1 week · averages per observed day")
                : String(localized: "\(count) weeks · averages per observed day")
        case .monthly:
            return count == 1
                ? String(localized: "1 month · averages per observed day")
                : String(localized: "\(count) months · averages per observed day")
        }
    }

    /// The HRV-style dossier under the bleed hero (also the loading and empty states for every metric).
    @ViewBuilder
    private func nonVitalBody(effectiveRange: ExploreRange, windowed: [(day: String, value: Double)],
                              rawWindowed: [(day: String, value: Double)], windowFellBack: Bool) -> some View {
        rangeControl(effectiveRange: effectiveRange, windowed: windowed, windowFellBack: windowFellBack)
            .padding(.top, 20)
        if loaded && windowed.isEmpty {
            emptyState
                .padding(.top, 22)
        } else if !loaded {
            NoopInsightRow(verbatim: String(localized: "Reading your \(metric.title.lowercased())…"))
                .padding(.top, 22)
        } else {
            chart(effectiveRange: effectiveRange, windowed: windowed)
                .padding(.top, 22)
            // #1848: the skin-temp explorer's explanatory note (nil for every other metric and
            // for a skin-temp screen that needs no explanation), read as context for the series.
            if let note = skinTempNote {
                NoopInsightRow(verbatim: note, icon: "info")
                    .padding(.top, 16)
                    .padding(.horizontal, 4)
            }
            statCard(effectiveRange: effectiveRange, windowed: windowed)
                .padding(.top, 22)
            if let line = windowComparisonLine(effectiveRange: effectiveRange, windowed: windowed) {
                NoopInsightRow(verbatim: line)
                    .padding(.top, 18)
                    .padding(.horizontal, 4)
            }
            // Steps chart summaries are bucketed, but the provenance table deliberately remains
            // one row per underlying observed day.
            readingsSection(windowed: isStepsDetail ? rawWindowed : windowed)
            correlationSection(effectiveRange: effectiveRange)
        }
    }

    // MARK: Hero

    /// The glow this metric's hero takes: the score's own world for the three scores, the heart world
    /// for heart metrics, stress for stress, the neutral ink glow for everything else.
    private var glow: NoopGlow {
        switch metric.key {
        case "recovery": return NoopGlow.charge(series.last?.value)
        case "strain": return .strain
        case "hrv", "rhr", "max_hr", "avg_hr", "hrr": return .heart
        case "stress": return .stress
        default:
            switch metric.category {
            case "Charge": return .recovery
            case "Effort": return .strain
            case "Rest", "Mind": return .sleep
            default: return .ink
            }
        }
    }

    /// The Phosphor glyph for the hero badge.
    private var icon: String {
        switch metric.key {
        case "hrv": return "heartbeat"
        case "rhr", "max_hr", "avg_hr": return "heart"
        case "recovery": return "lightning"
        case "strain": return "fire"
        case "spo2", "spo2_candidate": return "drop"
        case "resp_rate": return "wind"
        case "skin_temp": return "thermometer-simple"
        case "steps", "steps_est": return "sneaker-move"
        case "weight": return "scales"
        case "energy_kcal", "active_kcal": return "flame"
        case "stress": return "wave-sine"
        default:
            switch metric.category {
            case "Rest", "Mind": return "moon"
            case "Effort": return "fire"
            case "Charge": return "lightning"
            default: return "chart-line"
            }
        }
    }

    /// The hero badge names the metric itself, with the window it is read over where that is fixed
    /// ("HRV · overnight"). The catalog group it used to show read as a different score: "Charge" over an
    /// HRV reading.
    private var heroBadgeTitle: String {
        switch metric.key {
        case "hrv": return String(localized: "HRV · overnight")
        default: return metric.title
        }
    }

    /// The hero: the header row, the metric's badge and the source of its latest reading, the latest
    /// value in dot matrix against the personal baseline, and the three read-outs under it. The glow runs
    /// up under the status bar.
    private func hero(windowed: [(day: String, value: Double)], effectiveRange: ExploreRange) -> some View {
        let latestPoint = latest(in: windowed)
        let baseline = personalBaseline
        return VStack(alignment: .leading, spacing: 0) {
            NoopScreenHeader(verbatim: metric.title)
                .padding(.horizontal, -2)
            HStack(alignment: .center) {
                NoopIconBadge(verbatim: heroBadgeTitle, icon: icon)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                if let day = latestPoint?.day, let source = latestSourceLabel(day: day) {
                    NoopPill(verbatim: source, compact: true)
                }
            }
            .padding(.top, 30)
            heroValue(latestPoint: latestPoint, baseline: baseline)
                .padding(.top, 24)
            // No reading yet: the dot dash already says so; a lone "—" line under it read as broken.
            if latestPoint != nil {
                Text(verbatim: asOfLine(latestPoint: latestPoint, baseline: baseline, effectiveRange: effectiveRange))
                    .font(StrandFont.light(13))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .padding(.top, 14)
            }
            heroMetrics(latestPoint: latestPoint, baseline: baseline)
                .padding(.top, 20)
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // Extended upward so the glow fills the status-bar band at rest and while overscrolling.
            NoopHeroSurface(glow: glow, bleed: true)
                .padding(.top, -400)
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func heroValue(latestPoint: (day: String, value: Double)?, baseline: Double?) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            if let point = latestPoint {
                // The dot face carries the number; the unit sits beside it in the body face, as the
                // design sets it. Metrics whose formatter bakes the unit in (temperatures, Effort on
                // the 0–21 axis, steps) print the whole read-out.
                let parts = splitValue(point.value)
                NoopDotNumber(parts.number, size: parts.number.count > 6 ? 48
                                                 : (parts.number.count > 4 ? 64 : (parts.number.count > 3 ? 88 : 104)))
                    .fixedSize()
                    .padding(.vertical, -10)
                if let unit = parts.unit {
                    Text(verbatim: unit)
                        .font(StrandFont.light(17))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .fixedSize()
                        .padding(.bottom, 8)
                }
                Spacer(minLength: 8)
                if let baseline, let word = baselineWord(point.value, baseline: baseline) {
                    NoopTag(verbatim: word)
                        .padding(.bottom, 8)
                }
            } else {
                NoopDotNumber("–", size: 104)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: latestPoint.map { fmt($0.value) } ?? String(localized: "no data yet")))
    }

    /// Splits a formatted value into its number and a trailing unit word, when the formatter ends in the
    /// metric's own unit; otherwise the whole read-out stays the number.
    private func splitValue(_ value: Double) -> (number: String, unit: String?) {
        splitReadout(fmt(value))
    }

    /// `splitValue` for an already formatted read-out (a signed delta, the stat card's cells).
    private func splitReadout(_ text: String) -> (number: String, unit: String?) {
        guard !isStepsDetail, metric.key != "strain" else { return (text, nil) }
        let unit = metric.unit
        if !unit.isEmpty, text.hasSuffix(" " + unit) {
            return (String(text.dropLast(unit.count + 1)), unit)
        }
        // A formatter that relabels the unit (skin temperature's "Δ°C" deviation, °F) still ends in a
        // digit-free word; split that off too, so the dot face carries only the number. Whole, the
        // read-out was wider than the hero and pushed the screen past both edges.
        if let space = text.lastIndex(of: " ") {
            let tail = text[text.index(after: space)...]
            if !tail.isEmpty, !tail.contains(where: \.isNumber) {
                return (String(text[..<space]), String(tail))
            }
        }
        return (text, nil)
    }

    /// "Above" / "Below" the personal baseline, when there is one worth naming (HRV, resting HR).
    private func baselineWord(_ value: Double, baseline: Double) -> String? {
        let delta = value - baseline
        if abs(delta) < 0.5 { return String(localized: "At baseline") }
        return delta > 0 ? String(localized: "Above") : String(localized: "Below")
    }

    private func asOfLine(latestPoint: (day: String, value: Double)?, baseline: Double?,
                          effectiveRange: ExploreRange) -> String {
        guard let day = latestPoint?.day else { return "—" }
        let asOf: String
        if isStepsDetail {
            asOf = MetricDetailSteps.periodLabel(day: day, resolution: MetricDetailSteps.resolution(for: effectiveRange))
        } else if let d = parseDay(day) {
            asOf = String(localized: "as of \(heroDate(d))")
        } else {
            asOf = "—"
        }
        guard let baseline else { return asOf }
        return String(localized: "\(asOf) · baseline \(fmt(baseline))")
    }

    /// vs baseline (or vs the previous reading) · the current run of rising or falling readings · your
    /// normal range, when the baseline is trusted.
    @ViewBuilder
    private func heroMetrics(latestPoint: (day: String, value: Double)?, baseline: Double?) -> some View {
        let values = series.map(\.value)
        let run = Self.trailingRun(values)
        let band = normalRange
        NoopMetricRow {
            if let latest = latestPoint?.value, let baseline {
                heroMetric(signed(latest - baseline), label: String(localized: "vs baseline"))
            } else if values.count >= 2, let latest = values.last {
                heroMetric(signed(latest - values[values.count - 2]), label: String(localized: "vs previous reading"))
            }
            if run.count >= 2 {
                heroMetric("\(run.count)",
                           unit: String(localized: "in a row"),
                           label: run.rising ? String(localized: "Rising") : String(localized: "Falling"))
            }
            if let band {
                heroMetric("\(splitValue(band.lowerBound).number)–\(splitValue(band.upperBound).number)",
                           unit: splitValue(band.upperBound).unit,
                           label: String(localized: "Your normal range"))
            }
        }
    }

    private func heroMetric(_ value: String, unit: String? = nil, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value).font(StrandFont.value(21)).tracking(-0.42)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let unit {
                    Text(verbatim: unit).font(StrandFont.book(10)).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Text(verbatim: label)
                .font(StrandFont.light(10.5))
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The trailing run of strictly rising or strictly falling readings, counted in readings.
    static func trailingRun(_ values: [Double]) -> (count: Int, rising: Bool) {
        guard values.count >= 2 else { return (0, false) }
        let rising = values[values.count - 1] > values[values.count - 2]
        var count = 1
        var i = values.count - 1
        while i > 0 {
            let step = values[i] - values[i - 1]
            guard step != 0, (step > 0) == rising else { break }
            count += 1
            i -= 1
        }
        return (count > 1 ? count : 0, rising)
    }

    /// The range `VitalBands` calls in-range against the trusted personal baseline (|z| ≤ sigmaK) — the
    /// same fold `personalBaseline` draws, so the hero's range and the chart's rule cannot disagree.
    /// Solved from the engine's own deviation, which is linear in the value. nil without a trusted fold.
    private var normalRange: ClosedRange<Double>? {
        let cfg: MetricCfg?
        switch metric.key {
        case "hrv": cfg = Baselines.hrvCfg
        case "rhr": cfg = Baselines.restingHRCfg
        default: cfg = nil
        }
        guard let cfg else { return nil }
        let state = Baselines.foldHistory(series.map { $0.value }, cfg: cfg)
        guard state.trusted else { return nil }
        let unitZ = Baselines.deviation(state.baseline + 1, state: state).z
        guard unitZ.isFinite, unitZ > 0 else { return nil }
        let half = VitalBands.sigmaK / unitZ
        return (state.baseline - half)...(state.baseline + half)
    }

    /// The source label of one day's reading, as the readings table words it.
    private func latestSourceLabel(day: String) -> String? {
        guard let raw = sourceByDay[day] else { return nil }
        return TodayView.provenanceDisplayLabel(rawSource: raw, deviceId: repo.deviceId)
    }

    // MARK: Vital layout

    /// Overnight vitals read as one reading against your range: respiratory rate, SpO₂, skin temperature
    /// and resting heart rate. Everything else uses the trend dossier.
    private var isVital: Bool {
        ["resp_rate", "spo2", "rhr", "skin_temp"].contains(metric.key)
    }

    /// The vital's band for the latest reading, judged EXACTLY as the Health vitals grid judges it
    /// (`VitalBandSpec` + `VitalBands.band` over the calendar-padded history before that night), plus the
    /// range that verdict is drawn from: the personal |z| ≤ sigmaK window while the baseline is trusted,
    /// else the population range.
    private func vitalBand(latest: (day: String, value: Double)?) -> (result: VitalBands.Result, range: ClosedRange<Double>)? {
        guard let latest, let spec = VitalBandSpec.forMetric(key: metric.key, value: latest.value) else { return nil }
        let history = VitalBands.calendarSeries(series.filter { $0.day < latest.day }.map { ($0.day, Optional($0.value)) })
        let result = VitalBands.band(value: latest.value, history: history,
                                     populationRange: spec.population, cfg: spec.cfg)
        if result.basis == .personal, let cfg = spec.cfg {
            let state = Baselines.foldHistory(history, cfg: cfg)
            let unitZ = Baselines.deviation(state.baseline + 1, state: state).z
            if state.trusted, unitZ.isFinite, unitZ > 0 {
                let half = VitalBands.sigmaK / unitZ
                return (result, (state.baseline - half)...(state.baseline + half))
            }
        }
        return (result, spec.population)
    }

    /// What the vital is, in the hero badge.
    private var vitalBadge: LocalizedStringKey {
        switch metric.key {
        case "resp_rate": return "Breaths per minute"
        case "spo2": return "Oxygen saturation"
        case "rhr": return "Beats per minute"
        default: return "Skin temperature"
        }
    }

    /// The vital hero card: the latest night in dot matrix, IN RANGE / OUT OF RANGE against your range,
    /// the range slider with the reading's knob, then the window's average, lowest and highest nights.
    private func vitalHero(windowed: [(day: String, value: Double)]) -> some View {
        let latestPoint = latest(in: windowed)
        let band = vitalBand(latest: latestPoint)
        let values = windowed.map(\.value)
        let lowest = windowed.min { $0.value < $1.value }
        let highest = windowed.max { $0.value < $1.value }
        return VStack(alignment: .leading, spacing: 0) {
            NoopScreenHeader(verbatim: metric.title)
            NoopHeroCard(glow: .heart, padding: 22) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        NoopIconBadge(vitalBadge, icon: icon)
                        Spacer(minLength: 8)
                        if let day = latestPoint?.day {
                            NoopPill(verbatim: nightLabel(day), compact: true)
                        }
                    }
                    heroValue(latestPoint: latestPoint, baseline: nil)
                        .padding(.top, 26)
                    if let band, latestPoint != nil {
                        HStack(spacing: 10) {
                            NoopTag(verbatim: band.result.band == .inRange ? String(localized: "In range")
                                                                            : String(localized: "Out of range"))
                            Text(verbatim: String(localized: "Your range \(splitValue(band.range.lowerBound).number)–\(splitValue(band.range.upperBound).number)"))
                                .font(StrandFont.light(15))
                                .foregroundStyle(Color.white.opacity(0.85))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .padding(.top, 18)
                        if let value = latestPoint?.value {
                            VitalRangeSlider(range: band.range, value: value, format: { splitValue($0).number })
                                .padding(.top, 24)
                        }
                    }
                    NoopMetricRow {
                        if !values.isEmpty {
                            let avg = splitValue(values.reduce(0, +) / Double(values.count))
                            heroMetric(avg.number, unit: avg.unit,
                                       label: String(localized: "\(values.count)-night average"))
                        }
                        if let lowest {
                            let low = splitValue(lowest.value)
                            heroMetric(low.number, unit: low.unit,
                                       label: String(localized: "Lowest · \(shortDay(lowest.day))"))
                        }
                        if let highest {
                            let high = splitValue(highest.value)
                            heroMetric(high.number, unit: high.unit,
                                       label: String(localized: "Highest · \(shortDay(highest.day))"))
                        }
                    }
                    .padding(.top, 20)
                }
            }
            .padding(.top, 18)
        }
    }

    /// The vital dossier: one honest line about last night, the nights chart with the range control, each
    /// night against your range, and what correlates.
    @ViewBuilder
    private func vitalBody(effectiveRange: ExploreRange, windowed: [(day: String, value: Double)],
                           rawWindowed: [(day: String, value: Double)], windowFellBack: Bool) -> some View {
        let values = windowed.map(\.value)
        let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        if let latest = latest(in: windowed)?.value, let average {
            let delta = latest - average
            // The sentence carries the direction, so the amount is unsigned ("5 bpm below", not "−5 bpm below").
            let amount = metric.formatDelta(abs(delta), system: unitSystem, temperature: temperatureUnit,
                                            effortScale: effortScale)
            NoopInsightRow(verbatim: abs(delta) < 0.05
                           ? String(localized: "The latest night sits on your \(values.count)-night average.")
                           : (delta > 0
                              ? String(localized: "The latest night sat \(amount) above your \(values.count)-night average.")
                              : String(localized: "The latest night sat \(amount) below your \(values.count)-night average.")))
                .padding(.top, 20)
                .padding(.horizontal, 4)
        }
        NoopSectionTitle(verbatim: String(localized: "\(windowed.count) nights"), topPadding: 30) {
            if let first = windowed.first?.day, let last = windowed.last?.day {
                Text(verbatim: "\(shortDay(first)) – \(shortDay(last))")
            }
        }
        rangeControl(effectiveRange: effectiveRange, windowed: windowed, windowFellBack: windowFellBack)
            .padding(.top, 14)
        chart(effectiveRange: effectiveRange, windowed: windowed)
            .padding(.top, 22)
        if let note = skinTempNote {
            NoopInsightRow(verbatim: note, icon: "info")
                .padding(.top, 16)
                .padding(.horizontal, 4)
        }
        if let average {
            nightsSection(windowed: windowed, average: average)
        }
        correlationSection(effectiveRange: effectiveRange)
    }

    /// Each night against your range: the date and that night's sleep, a mini bar (your range in grey,
    /// the window average as a tick, the night as a dot), the value and its distance from the average.
    /// The seven newest show; the rest open in place. The source of each night rides its caption.
    private func nightsSection(windowed: [(day: String, value: Double)], average: Double) -> some View {
        let range = vitalBand(latest: latest(in: windowed))?.range
        let values = windowed.map(\.value)
        let lo = min(values.min() ?? average, range?.lowerBound ?? average)
        let hi = max(values.max() ?? average, range?.upperBound ?? average)
        let pad = max((hi - lo) * 0.15, 0.1)
        let scale = (lo - pad)...(hi + pad)
        let rows = Array(windowed.reversed())
        let shown = showAllReadings ? rows : Array(rows.prefix(7))
        // One source for every shown night is named once under the list; per-row source only when the
        // nights actually differ. In German "7h 39m geschlafen · WHOOP" did not fit the date column.
        let sources = Set(shown.compactMap { latestSourceLabel(day: $0.day) })
        let perRowSource = sources.count > 1
        return VStack(alignment: .leading, spacing: 14) {
            NoopSectionTitle(verbatim: String(localized: "Nights"), topPadding: 30) {
                Text(verbatim: String(localized: "vs \(fmt(average)) average"))
            }
            NoopList {
                ForEach(shown, id: \.day) { night in
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: nightLabel(night.day))
                                .font(StrandFont.book(15))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text(verbatim: nightCaption(night.day, includeSource: perRowSource))
                                .font(StrandFont.light(11.5))
                                .foregroundStyle(StrandPalette.textTertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(width: 104, alignment: .leading)
                        NightRangeBar(scale: scale, band: range, average: average, value: night.value)
                            .frame(height: 14)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(verbatim: splitValue(night.value).number)
                                .font(StrandFont.book(15))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(verbatim: abs(night.value - average) < 0.05 ? "±0" : signed(night.value - average))
                                .font(StrandFont.light(11))
                                .foregroundStyle(StrandPalette.textTertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(width: 74, alignment: .trailing)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .accessibilityElement(children: .combine)
                }
                if rows.count > 7 {
                    Button { withAnimation(StrandMotion.interactive) { showAllReadings.toggle() } } label: {
                        HStack {
                            Text(showAllReadings ? String(localized: "Show the newest 7")
                                                 : String(localized: "Show all \(rows.count) nights"))
                            Spacer()
                            PhIcon(showAllReadings ? "caret-up" : "caret-right", size: 16).opacity(0.5)
                        }
                        .font(StrandFont.light(14))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(verbatim: [range == nil ? String(localized: "The tick marks your average for the window.")
                                         : String(localized: "Grey band = your range. The tick marks your average for the window."),
                            perRowSource ? nil : sources.first.map { String(localized: "Every night from \($0).") }]
                .compactMap { $0 }.joined(separator: " "))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.horizontal, 4)
        }
    }

    /// "Last night", else the reading's weekday and date.
    private func nightLabel(_ day: String) -> String {
        if day == Repository.logicalDayKey(Date()) { return String(localized: "Last night") }
        return vitalReadingDateLabel(day)
    }

    /// "7h 12m asleep · Whoop": that night's sleep and, when the nights mix sources, the source of the
    /// reading.
    private func nightCaption(_ day: String, includeSource: Bool) -> String {
        var parts: [String] = []
        if let minutes = repo.days.last(where: { $0.day == day })?.totalSleepMin, minutes > 0 {
            parts.append(String(localized: "\(CoupledView.hoursMinutes(minutes)) asleep"))
        }
        if includeSource, let source = latestSourceLabel(day: day) { parts.append(source) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// "26 Sep" for a day key.
    private func shortDay(_ day: String) -> String {
        guard let d = parseDay(day) else { return day }
        return Self.dayFormatter(template: "d MMM").string(from: d)
    }

    /// "4 Oct 2026" / "4. Okt. 2026": the hero's as-of date in the reader's own date order. A fixed
    /// "d MMM yyyy" pattern dropped the German day period.
    private func heroDate(_ d: Date) -> String {
        Self.dayFormatter(template: "d MMM yyyy").string(from: d)
    }

    /// Day-key dates are UTC midnights (see `parseDay`). One formatter per template, rebuilt only when the
    /// app language changes, instead of a new DateFormatter per row on every body pass.
    private static var dayFormatters: [String: DateFormatter] = [:]
    private static func dayFormatter(template: String) -> DateFormatter {
        let locale = AppLanguage.activeLocale
        let key = template + "|" + locale.identifier
        if let f = dayFormatters[key] { return f }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate(template)
        dayFormatters[key] = f
        return f
    }

    // MARK: Range control

    private func rangeControl(effectiveRange: ExploreRange,
                              windowed: [(day: String, value: Double)],
                              windowFellBack: Bool) -> some View {
        let caption = rangeCaption(effectiveRange: effectiveRange, windowed: windowed, windowFellBack: windowFellBack)
        return VStack(alignment: .leading, spacing: 8) {
            SegmentedPillControl(ExploreRange.allCases, selection: selectionBinding,
                                 fillsAvailableWidth: true,
                                 isEnabled: isUnlocked) { $0.label }
            // Stacked, not side by side: in German the unlock hint wraps to two lines and squeezed the
            // count into a ragged column beside it.
            VStack(alignment: .leading, spacing: 2) {
                // No readings in the window: the empty state below says so; a lone dash here read as a glitch.
                if caption != "—" {
                    Text(caption)
                        .foregroundStyle(windowFellBack ? StrandPalette.statusWarning : StrandPalette.textTertiary)
                }
                // The subtle reason the dimmed chips exist (#943); shown only while some are locked.
                if hasLockedRanges {
                    Text("Longer ranges unlock as more history builds.")
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(StrandFont.footnote)
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Chart

    private func chart(effectiveRange: ExploreRange, windowed: [(day: String, value: Double)]) -> some View {
        let stepsAccessibility = isStepsDetail
            ? MetricDetailSteps.presentation(readings: series, range: effectiveRange).accessibilitySummary
            : nil
        let stepsResolution = MetricDetailSteps.resolution(for: effectiveRange)
        let baseline = personalBaseline
        let tint = isVital ? NoopGlow.heart.tint : (glow == .ink ? StrandPalette.metricCyan : glow.tint)
        // The shaded band behind the line: the trusted normal range (HRV), or for an overnight vital the
        // same range its hero judges the night against. The axis widens to hold it, so the band is never
        // cut off at a window whose readings all sit inside it.
        let band: ClosedRange<Double>? = isVital ? vitalBand(latest: latest(in: windowed))?.range : normalRange
        let axisValues = windowed.map(\.value) + (band.map { [$0.lowerBound, $0.upperBound] } ?? [])
        return VStack(alignment: .leading, spacing: 12) {
            TrendChart(
                points: trendPoints(windowed),
                gradient: Gradient(colors: [tint.opacity(0.75), tint]),
                valueRange: valueRange(axisValues),
                showsArea: true,
                // The chart-style setting, the same one `TrendsView` reads. Steps deliberately override it
                // because their calendar buckets are discrete daily/weekly/monthly observations.
                showsBars: MetricDetailSteps.showsBars(metricKey: metric.key,
                                                       preferredStyleRaw: trendChartStyleRaw),
                baselineValue: baseline,
                normalBand: band,
                height: 170 + (isStepsDetail ? 70 : 0),
                valueFormat: { value in
                    isStepsDetail
                        ? MetricDetailSteps.valueLabel(value, resolution: stepsResolution)
                        : fmt(value)
                },
                dateFormat: { date in
                    isStepsDetail
                        ? MetricDetailSteps.periodLabel(
                            day: strandDayParser.string(from: date), resolution: stepsResolution)
                        : TrendChart.defaultDateString(date)
                },
                accessibilityLabel: stepsAccessibility,
                yAxisStep: isStepsDetail ? 5000 : nil,
                showsBarValues: isStepsDetail && (effectiveRange == .week || effectiveRange == .twoWeeks),
                largeSelection: isStepsDetail
            )
            if baseline != nil || band != nil {
                HStack(spacing: 18) {
                    if let baseline {
                        HStack(spacing: 6) {
                            Path { p in p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: 16, y: 1)) }
                                .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .frame(width: 16, height: 2)
                            Text(verbatim: String(localized: "Baseline \(fmt(baseline))"))
                        }
                    }
                    if let band {
                        let lo = splitValue(band.lowerBound).number, hi = splitValue(band.upperBound).number
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Color.white.opacity(0.16))
                                .frame(width: 12, height: 8)
                            Text(verbatim: isVital ? String(localized: "Your range \(lo)–\(hi)")
                                                   : String(localized: "Normal band \(lo)–\(hi)"))
                        }
                    }
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.leading, 4)
            }
            // #1662: the VO₂max line is SPLIT on purpose wherever the estimator changes, so two
            // non-adjacent Nes runs are never joined across an incompatible Uth stretch. Shown only when
            // a break actually exists, so it explains the chart in front of the reader.
            if metric.key == "vo2max_est",
               vo2MaxTrendHasBreak(days: windowed.map(\.day), sourceByDay: sourceByDay) {
                Text("The line breaks where the estimation method changed or was not recorded.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.leading, 4)
            }
        }
    }

    // MARK: Stats

    /// Average · Min · Max · Latest · Δ vs the previous equal window, in one card.
    private func statCard(effectiveRange: ExploreRange, windowed: [(day: String, value: Double)]) -> some View {
        let windowValues = windowed.map(\.value)
        let latestPoint = latest(in: windowed)
        let s = ComparisonEngine.stat(windowValues)
        let cmp = ComparisonEngine.compare(current: windowValues,
                                           previous: previousWindow(effectiveRange: effectiveRange,
                                                                    windowed: windowed).map(\.value))
        let hasDelta = cmp.current.n > 0 && cmp.previous.n > 0
        return NoopCard(padding: 0) {
            HStack(spacing: 0) {
                statCell(fmt(s.mean), label: String(localized: "Average"), first: true)
                statCell(fmt(s.min), label: String(localized: "Min"))
                statCell(fmt(s.max), label: String(localized: "Max"))
                statCell(latestPoint.map { fmt($0.value) } ?? "—", label: String(localized: "Latest"))
                statCell(hasDelta ? signed(cmp.delta) : "—", label: String(localized: "Δ vs prev"))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(verbatim: statisticCountCaption(count: s.n, effectiveRange: effectiveRange)))
    }

    private func statCell(_ value: String, label: String, first: Bool = false) -> some View {
        // The unit rides small beside the number, as the frame's `.m` cells set it ("63 ms"), so five
        // read-outs fit one row without shrinking the numbers.
        let split = splitReadout(value)
        return HStack(spacing: 0) {
            if !first {
                Rectangle().fill(NoopVisualStyle.border).frame(width: 1)
                    .padding(.trailing, 10)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(verbatim: split.number)
                        .font(StrandFont.value(19))
                        .tracking(-0.38)
                        .foregroundStyle(StrandPalette.textPrimary)
                    if let u = split.unit {
                        Text(verbatim: u)
                            .font(StrandFont.book(10))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                Text(verbatim: label)
                    .font(StrandFont.light(10.5))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "Average over this month is 5 ms higher than the month before." from the same window comparison
    /// the Δ cell prints. nil without a previous window to compare against.
    private func windowComparisonLine(effectiveRange: ExploreRange,
                                      windowed: [(day: String, value: Double)]) -> String? {
        guard effectiveRange != .all else { return nil }
        let cmp = ComparisonEngine.compare(current: windowed.map(\.value),
                                           previous: previousWindow(effectiveRange: effectiveRange,
                                                                    windowed: windowed).map(\.value))
        guard cmp.current.n > 0, cmp.previous.n > 0 else { return nil }
        let amount = metric.formatDelta(abs(cmp.delta), system: unitSystem, temperature: temperatureUnit,
                                        effortScale: effortScale)
        let name = effectiveRange.name
        switch cmp.direction {
        case 1: return String(localized: "Your average over this \(name) is \(amount) higher than the \(name) before.")
        case -1: return String(localized: "Your average over this \(name) is \(amount) lower than the \(name) before.")
        default: return String(localized: "Your average over this \(name) matches the \(name) before.")
        }
    }

    // MARK: Readings

    /// The per-reading breakdown, so the provenance behind the trend is visible — whether each reading
    /// came from the WHOOP strap, a Health Connect / Apple Health import, or the on-device pipeline. Rows
    /// derive from the SAME `windowed` slice the caption counts (so the two never disagree), NEWEST
    /// FIRST, and reuse `TodayView.provenanceDisplayLabel` for the source words. The five newest show;
    /// the rest open in place. Swift twin of Android's `VitalReadingsTable`.
    @ViewBuilder
    private func readingsSection(windowed: [(day: String, value: Double)]) -> some View {
        let readings = windowed.map {
            VitalReading(day: $0.day, value: $0.value,
                         source: sourceByDay[$0.day]
                             ?? (metric.key == "skin_temp" ? FusionSource.localCache.rawValue : metric.source))
        }
        // The unit is passed EMPTY on purpose (#1942): every `MetricDescriptor.format` overload already
        // ends in the CONVERTED unit, so appending `metric.unit` printed "33 % %" and "182.0 lb kg".
        let rows = vitalReadingRows(readings: readings, unit: "",
                                    strapDeviceId: repo.deviceId, format: fmt)
        if !rows.isEmpty {
            let sources = Set(rows.map(\.source)).count
            let shown = showAllReadings ? rows : Array(rows.prefix(5))
            VStack(alignment: .leading, spacing: 14) {
                NoopSectionTitle("Readings", topPadding: 30) {
                    Text(verbatim: sources == 1
                         ? String(localized: "\(rows.count) readings · 1 source")
                         : String(localized: "\(rows.count) readings · \(sources) sources"))
                }
                NoopList {
                    HStack(spacing: 12) {
                        Text("Date").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Value").frame(width: 92, alignment: .leading)
                        Text("Source").frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(StrandFont.book(10.5))
                    .tracking(0.84)
                    .textCase(.uppercase)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 12) {
                            Text(verbatim: row.time)
                                .font(StrandFont.book(14))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(verbatim: row.value)
                                .font(StrandFont.book(14))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(width: 92, alignment: .leading)
                            HStack(spacing: 6) {
                                PhIcon(sourceIcon(row.source), size: 14).opacity(0.7)
                                Text(verbatim: row.source).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .font(StrandFont.light(12))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(row.time), \(row.value), \(row.source)")
                    }
                    if rows.count > 5 {
                        Button { withAnimation(StrandMotion.interactive) { showAllReadings.toggle() } } label: {
                            HStack {
                                Text(showAllReadings ? String(localized: "Show the newest 5")
                                                     : String(localized: "Show all \(rows.count) readings"))
                                Spacer()
                                PhIcon(showAllReadings ? "caret-up" : "caret-right", size: 16).opacity(0.5)
                            }
                            .font(StrandFont.light(14))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// A glyph for a provenance label: a watch for wearables, a half heart for Apple Health / Health
    /// Connect imports, a chip for the on-device pipeline.
    private func sourceIcon(_ label: String) -> String {
        switch label {
        case "Apple Health", "Health Connect", "Apple Watch": return "heart-half"
        case "Whoop", "WHOOP": return "watch"
        default: return label.lowercased().contains("device") ? "cpu" : "watch"
        }
    }

    // MARK: Correlations

    private struct CorrRow: Identifiable {
        let id: String
        let metric: MetricDescriptor
        let r: Double
        let n: Int
    }

    /// Top |r| catalog metrics over a given window (|r| ≥ 0.30, n ≥ 10). Pure — takes
    /// the window so the heavy scan can be driven from `recomputeCorrelations()` into
    /// the `@State` cache instead of running inside `body`.
    private func computeCorrelationRows(windowed: [(day: String, value: Double)]) -> [CorrRow] {
        let myDays = Set(windowed.map(\.day))
        guard !myDays.isEmpty else { return [] }
        var rows: [CorrRow] = []
        for entry in others {
            let otherWindowed = entry.series.filter { myDays.contains($0.day) }
            let pairs = CorrelationEngine.alignByDay(windowed, otherWindowed)
            guard pairs.count >= 10, let c = CorrelationEngine.pearson(pairs) else { continue }
            if abs(c.r) >= 0.3 {
                rows.append(CorrRow(id: entry.metric.id, metric: entry.metric, r: c.r, n: c.n))
            }
        }
        rows.sort { abs($0.r) > abs($1.r) }
        return Array(rows.prefix(6))
    }

    /// Rebuild the cached correlation scan for the CURRENT effective window, but only
    /// when its key (metric id + selected range) actually changed — so re-evals that
    /// don't alter the inputs (hover / HR ticks) are no-ops.
    private func recomputeCorrelations() {
        // `others.count` belongs in the key, not just the metric and range. The catalog scan now lands
        // AFTER the screen (see `load()`), so a range change during the scan would otherwise compute
        // against a still-empty `others`, cache that empty result under this key, and then skip the
        // recompute the scan itself triggers — leaving the card permanently blank.
        let key = "\(metric.id)|\(range.rawValue)|\(others.count)"
        guard correlationKey != key else { return }
        correlationKey = key
        correlationCache = computeCorrelationRows(windowed: slice(for: effectiveRange))
    }

    private func correlationSection(effectiveRange: ExploreRange) -> some View {
        let rows = correlationCache
        return VStack(alignment: .leading, spacing: 14) {
            NoopSectionTitle("What correlates", topPadding: 30) {
                Text(verbatim: String(localized: "Pearson r · \(effectiveRange.name)"))
            }
            NoopCard {
                VStack(alignment: .leading, spacing: 0) {
                    if !correlationsLoaded {
                        // The scan lands after the rest of the screen, so this card has a real "still
                        // working" state. Without it the card would assert "nothing correlates" for the
                        // second or two before the catalog is in — a confident, wrong answer.
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Scanning the catalog…")
                        }
                        .font(StrandFont.light(13))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    } else if rows.isEmpty {
                        Text("Nothing in the catalog moves clearly with \(metric.title.lowercased()) over this window. Widen the range to surface relationships.")
                            .font(StrandFont.light(13))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                            if idx > 0 {
                                Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
                            }
                            correlationRowView(row)
                        }
                        HStack(spacing: 12) {
                            Spacer(minLength: 0)
                            HStack {
                                Text(verbatim: "−1"); Spacer(); Text(verbatim: "0"); Spacer(); Text(verbatim: "+1")
                            }
                            .frame(width: 128)
                            Color.clear.frame(width: 46, height: 1)
                        }
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.top, 6)
                    }
                }
            }
            Text("|r| ≥ 0.30 over at least 10 shared days in the visible window. Correlation shows what moves together, not what causes what.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    /// One `.cor` row: the metric and its category · n, a centred −1…+1 bar (ink positive, grey
    /// negative), and r.
    private func correlationRowView(_ row: CorrRow) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // One line, scaled: a single long German word ("Herzfrequenzvariabilität") otherwise
                // breaks mid-word in this narrow column.
                Text(row.metric.title)
                    .font(StrandFont.book(14))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(MetricCatalog.categoryDisplayName(row.metric.category)) · n = \(row.n)")
                    .font(StrandFont.light(11.5))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                Rectangle().fill(NoopVisualStyle.borderHighlight).frame(width: 1, height: 26)
                HStack(spacing: 0) {
                    let half: CGFloat = 64
                    let w = half * CGFloat(min(abs(row.r), 1))
                    if row.r < 0 {
                        Spacer(minLength: 0)
                        Capsule().fill(Color(light: "#9A9AA2", dark: "#6B6B73")).frame(width: w, height: 8)
                        Color.clear.frame(width: half)
                    } else {
                        Color.clear.frame(width: half)
                        Capsule().fill(StrandPalette.textPrimary).frame(width: w, height: 8)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(width: 128, height: 18)
            .accessibilityHidden(true)
            Text("\(row.r >= 0 ? "+" : "−")\(String(format: "%.2f", abs(row.r)))")
                .font(StrandFont.value(14))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.metric.title), correlation \(String(format: "%.2f", row.r)), \(row.n) days")
    }

    // MARK: Empty state

    @ViewBuilder
    private var emptyState: some View {
        if metric.key == "fitness_age" {
            // Fitness Age is COMPUTED on-device from resting HR + activity — not imported — so the generic
            // "import your history" copy was wrong (and a dead end) here. Lead with the same "N more nights
            // of wear" countdown the Health hub shows (parity with Android's VitalDetailScreen fix).
            VStack(alignment: .leading, spacing: 14) {
                NoopInsightRow(verbatim: fitnessReadyLeadCopy(rhrDays: repo.days.suffix(7).compactMap { $0.restingHr }.count,
                                                              hasAge: profile.age > 0, hasSex: !profile.sex.isEmpty))
                // Force the weekly recompute NOW from stored data (works offline), then re-read.
                if refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    NoopButton("Refresh Fitness Age", kind: .secondary) {
                        guard !refreshing else { return }
                        refreshing = true
                        Task {
                            _ = await intelligence.recomputeFitnessAgeOnly()
                            await load()
                            refreshing = false
                        }
                    }
                }
            }
        } else {
            NoopInsightRow("Import your history first. A WHOOP export in Data Sources fills every metric you can explore here in about a minute.")
        }
    }

    // MARK: Helpers

    private func signed(_ delta: Double) -> String {
        // A difference between two readings: route through the delta formatter so a temperature Δ
        // scales without the +32 offset.
        (delta >= 0 ? "+" : "−") + metric.formatDelta(abs(delta), system: unitSystem, temperature: temperatureUnit, effortScale: effortScale)
    }
}

/// The vital hero's range slider: the scale's ends, your range lit, and a glowing knob at the reading.
private struct VitalRangeSlider: View {
    let range: ClosedRange<Double>
    let value: Double
    let format: (Double) -> String

    private var scale: ClosedRange<Double> {
        let span = max(range.upperBound - range.lowerBound, 0.1)
        let lo = min(range.lowerBound - span * 0.8, value - span * 0.1)
        let hi = max(range.upperBound + span * 0.8, value + span * 0.1)
        return lo...hi
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let s = scale
            let x: (Double) -> CGFloat = { CGFloat(($0 - s.lowerBound) / (s.upperBound - s.lowerBound)) * w }
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(Color.black.opacity(0.35))
                        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    Capsule(style: .continuous).fill(Color.white.opacity(0.2))
                        .frame(width: max(4, x(range.upperBound) - x(range.lowerBound)))
                        .offset(x: x(range.lowerBound))
                    Circle().fill(Color.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .white.opacity(0.8), radius: 7)
                        .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 4).frame(width: 22, height: 22))
                        .offset(x: x(value) - 7)
                }
                .frame(height: 12)
                ZStack(alignment: .topLeading) {
                    // Pins the stack to the full width so each label's guide is measured from x = 0.
                    Color.clear.frame(width: w, height: 1)
                    tick(format(range.lowerBound), at: x(range.lowerBound), width: w)
                    tick(format(range.upperBound), at: x(range.upperBound), width: w)
                }
                .frame(height: 14)
            }
        }
        .frame(height: 35)
        .accessibilityHidden(true)
    }

    private func tick(_ text: String, at x: CGFloat, width: CGFloat) -> some View {
        Text(verbatim: text)
            .font(StrandFont.footnote)
            .foregroundStyle(Color.white.opacity(0.55))
            .fixedSize()
            .alignmentGuide(.leading) { d in d.width / 2 - min(max(x, d.width / 2), width - d.width / 2) }
    }
}

/// One night's mini bar: the scale track, your range in grey, the window average as a tick and the night
/// as a white dot.
private struct NightRangeBar: View {
    let scale: ClosedRange<Double>
    let band: ClosedRange<Double>?
    let average: Double
    let value: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x: (Double) -> CGFloat = {
                CGFloat(min(max(($0 - scale.lowerBound) / (scale.upperBound - scale.lowerBound), 0), 1)) * w
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Color(light: "#E2E1DD", dark: "#1F1F24")).frame(height: 6)
                if let band {
                    Capsule().fill(Color.white.opacity(0.12))
                        .frame(width: max(4, x(band.upperBound) - x(band.lowerBound)), height: 6)
                        .offset(x: x(band.lowerBound))
                }
                Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 14)
                    .offset(x: x(average))
                Circle().fill(StrandPalette.textPrimary).frame(width: 8, height: 8)
                    .offset(x: x(value) - 4)
            }
            .frame(height: geo.size.height)
        }
        .accessibilityHidden(true)
    }
}
