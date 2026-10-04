import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Explore (Metric Explorer + Detail)
//
// The catalog-driven "Explore" surface. The root is a grouped list — one
// SectionHeader per MetricCatalog.category, then a row per metric — pushing a
// MetricDetailView. The detail is a uniform analytic dossier built ONLY from the
// locked StrandDesign components (NoopCard / ChartCard / StatTile / InsightCard /
// SegmentedPillControl). No custom card heights, paddings, or surfaces anywhere.
//
// Sparse-metric rule (owner saw "no data" on metrics that HAVE data): a series may
// be sampled weekly (weight / body fat). The window is taken RELATIVE TO THE LATEST
// data point — not "now" — so a stale-but-present series still resolves. If the
// selected window holds ≥1 point we SHOW THAT WINDOW (so W/M/3M stay visibly
// distinct); only when it holds ZERO points do we auto-expand to the smallest larger
// range that does. The hero always shows the latest available point + "as of <date>".

// yyyy-MM-dd → Date, fixed UTC / en_US_POSIX (per task spec).
let strandDayParser: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

func parseDay(_ day: String) -> Date? { strandDayParser.date(from: day) }

/// Localized long date for the hero "as of" line, with a fixed calendar-day time zone.
func longDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = AppLanguage.activeLocale
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "d MMM yyyy"
    return f.string(from: d)
}

/// The category accent (colour communicates category only — never decoration).
func metricAccent(_ m: MetricDescriptor) -> Color {
    switch m.key {
    case "recovery", "sleep_performance", "hours_vs_needed_pct", "sleep_consistency",
         "restorative_pct", "restorative_min", "sleep_efficiency", "sleep_total_min",
         "sleep_deep_min", "sleep_rem_min":
        return StrandPalette.accent
    case "strain", "hr_zones45_min", "hr_zones_all_min", "strength_min", "hr_zones13_min":
        return StrandPalette.strainColor(14)              // mid-strain hue
    case "hrv", "vo2max", "lean_mass":
        return StrandPalette.metricPurple
    case "rhr", "stress", "sleep_debt_min", "body_fat", "max_hr":
        return StrandPalette.metricRose
    case "spo2", "steps":
        return StrandPalette.metricCyan
    case "energy_kcal", "active_kcal":
        return StrandPalette.metricAmber
    default:
        switch m.source {
        case "apple-health": return StrandPalette.metricCyan
        case "xiaomi-band":  return StrandPalette.metricAmber
        default:             return StrandPalette.textPrimary
        }
    }
}

/// The gradient for a metric's trend line — strain/recovery ride their data scales;
/// everything else uses a flat tint of its category accent.
func metricGradient(_ m: MetricDescriptor) -> Gradient {
    if m.category == "Effort" { return StrandPalette.strainGradient }
    if m.key == "recovery" { return StrandPalette.recoveryGradient }
    let c = metricAccent(m)
    return Gradient(colors: [c.opacity(0.55), c])
}

/// The Bevel colour world a metric's detail hero belongs to — the catalog's category
/// already names it (Charge / Rest / Effort), and Heart/Health/Nutrition/Mind metrics
/// fall back to the world that best fits their accent. Drives the ScenicHeroBackground
/// tint + the hero gauge/number glow.
func metricDomain(_ m: MetricDescriptor) -> DomainTheme {
    switch m.category {
    case "Charge":            return .charge
    case "Effort":            return .effort
    case "Rest", "Mind":      return .rest
    default:
        // Heart / Health / Nutrition: lean on the metric's own world. RHR-style risk
        // metrics read as Stress (teal); everything else rides the Charge green chrome.
        switch m.key {
        case "rhr", "max_hr", "stress", "body_fat": return .stress
        default:                                    return .charge
        }
    }
}

/// A 0–100 score that reads naturally as a layered ring gauge in the hero (vs a bare
/// headline number). Recovery / Rest / Blood-oxygen sit on a clean 0–100 axis.
func metricGaugeFraction(_ m: MetricDescriptor, value: Double) -> Double? {
    switch m.key {
    case "recovery", "sleep_performance", "spo2", "hours_vs_needed_pct",
         "sleep_consistency", "restorative_pct", "sleep_efficiency":
        return min(max(value / 100.0, 0), 1)
    default:
        return nil
    }
}

// MARK: - Range

/// The W/2W/3W/M/3M/6M/1Y/ALL window, driving the single SegmentedPillControl.
enum ExploreRange: Int, CaseIterable, Identifiable, Hashable {
    case week = 7, twoWeeks = 14, threeWeeks = 21, month = 30, quarter = 90, half = 180, year = 365, all = 0
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .twoWeeks: return String(localized: "2W"); case .threeWeeks: return String(localized: "3W")
        case .week: return String(localized: "W"); case .month: return String(localized: "M"); case .quarter: return String(localized: "3M")
        case .half: return String(localized: "6M"); case .year: return String(localized: "1Y"); case .all: return String(localized: "ALL")
        }
    }
    var name: String {
        switch self {
        case .twoWeeks: return String(localized: "2 weeks"); case .threeWeeks: return String(localized: "3 weeks")
        case .week: return String(localized: "week"); case .month: return String(localized: "month"); case .quarter: return String(localized: "quarter")
        case .half: return String(localized: "6 months"); case .year: return String(localized: "year"); case .all: return String(localized: "all time")
        }
    }
    /// Trailing days the window spans (nil = everything).
    var days: Int? { self == .all ? nil : rawValue }

    /// This range plus every LARGER range, ascending — the auto-expand search order
    /// when the selected window holds zero points. ALW always terminates the chain.
    var widening: [ExploreRange] {
        let order: [ExploreRange] = [.week, .month, .quarter, .half, .year, .all]
        guard let i = order.firstIndex(of: self) else { return [.all] }
        return Array(order[i...])
    }
}

/// The steps-specific adapter between the shared calendar projection and this screen. Keeping the
/// policy pure makes the renderer consume one authoritative bucket series for its chart, headline,
/// statistics and accessibility text while the readings table can continue to show daily inputs.
enum MetricDetailSteps {
    enum Resolution: Equatable {
        case daily
        case weekly
        case monthly
    }

    struct Presentation {
        let buckets: [StepsDetailBucket]
        let resolution: Resolution

        var series: [(day: String, value: Double)] {
            buckets.map { (day: $0.displayDay, value: Double($0.mean)) }
        }

        var accessibilitySummary: String {
            guard let latest = buckets.last else { return String(localized: "Steps chart, no data") }
            let noun = buckets.count == 1 ? String(localized: "bar") : String(localized: "bars")
            let period = MetricDetailSteps.periodLabel(day: latest.displayDay, resolution: resolution)
            switch resolution {
            case .daily:
                return String(localized: "Steps chart, \(buckets.count) daily \(noun), latest \(latest.mean) steps, \(period)")
            case .weekly:
                return String(localized: "Steps chart, \(buckets.count) weekly \(noun), latest \(latest.mean) average steps per observed day, \(period)")
            case .monthly:
                return String(localized: "Steps chart, \(buckets.count) monthly \(noun), latest \(latest.mean) average steps per observed day, \(period)")
            }
        }
    }

    static func isMetric(_ metricKey: String) -> Bool {
        metricKey == "steps" || metricKey == "steps_est"
    }

    static func range(_ range: ExploreRange) -> StepsDetailRange {
        switch range {
        case .week: return .week
        case .twoWeeks: return .twoWeeks
        case .threeWeeks: return .threeWeeks
        case .month: return .month
        case .quarter: return .threeMonths
        case .half: return .sixMonths
        case .year: return .year
        case .all: return .all
        }
    }

    static func resolution(for range: ExploreRange) -> Resolution {
        switch range {
        case .week, .twoWeeks, .threeWeeks, .month: return .daily
        case .quarter: return .weekly
        case .half, .year, .all: return .monthly
        }
    }

    static func widening(from range: ExploreRange) -> [ExploreRange] {
        let order = ExploreRange.allCases
        guard let index = order.firstIndex(of: range) else { return [.all] }
        return Array(order[index...])
    }

    static func presentation(readings: [(day: String, value: Double)], range: ExploreRange,
                             anchorDay: String? = nil) -> Presentation {
        let buckets = StepsDetailDensity.project(
            readings: readings.map { StepsDetailReading(day: $0.day, value: $0.value) },
            range: self.range(range), anchorDay: anchorDay)
        return Presentation(buckets: buckets, resolution: resolution(for: range))
    }

    static func latestValidDay(readings: [(day: String, value: Double)]) -> String? {
        StepsDetailDensity.project(
            readings: readings.map { StepsDetailReading(day: $0.day, value: $0.value) },
            range: .week).last?.displayDay
    }

    /// The finite comparison window ends one day before the current window and has the same number
    /// of local calendar days. The shared projector then applies the same daily/weekly/monthly fold.
    static func previousPresentation(readings: [(day: String, value: Double)], range: ExploreRange,
                                     currentAnchorDay: String) -> Presentation {
        let parts = currentAnchorDay.split(separator: "-")
        guard let dayCount = range.days, parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return Presentation(buckets: [], resolution: resolution(for: range))
        }
        let previousAnchor = LocalCalendarDate(year: year, month: month, day: day)
            .adding(days: -dayCount).key
        return presentation(readings: readings, range: range,
                            anchorDay: previousAnchor)
    }

    static func showsBars(metricKey: String, preferredStyleRaw: String) -> Bool {
        isMetric(metricKey) || TrendChartStyle(rawValue: preferredStyleRaw) == .bar
    }

    static func requiresFullHistory(metricKey: String, range: ExploreRange) -> Bool {
        isMetric(metricKey) && range == .all
    }

    static func loadIdentity(metricID: String, refreshSequence: Int,
                             skinTemperatureStyle: String, range: ExploreRange) -> String {
        let metricKey = metricID.split(separator: ":").last.map(String.init) ?? metricID
        let rangeIdentity = isMetric(metricKey)
            ? "|\(range.rawValue)" : ""
        return "\(metricID)|\(refreshSequence)|\(skinTemperatureStyle)\(rangeIdentity)"
    }

    static func periodLabel(day: String, resolution: Resolution) -> String {
        guard let date = parseDay(day) else { return day }
        switch resolution {
        case .daily:
            return String(localized: "as of \(longDate(date))")
        case .weekly:
            return String(localized: "week of \(longDate(date))")
        case .monthly:
            let formatter = DateFormatter()
            formatter.locale = AppLanguage.activeLocale
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: date)
        }
    }

    static func countCaption(count: Int, resolution: Resolution, rangeName: String) -> String {
        let noun = count == 1 ? String(localized: "bar") : String(localized: "bars")
        switch resolution {
        case .daily:
            return String(localized: "\(count) daily \(noun) · \(rangeName)")
        case .weekly:
            return String(localized: "\(count) weekly \(noun) · average per observed day · \(rangeName)")
        case .monthly:
            return String(localized: "\(count) monthly \(noun) · average per observed day · \(rangeName)")
        }
    }

    static func valueLabel(_ value: Double, resolution: Resolution) -> String {
        let formatted = value.formatted(.number.locale(AppLanguage.activeLocale).precision(.fractionLength(0)))
        switch resolution {
        case .daily:
            return String(localized: "\(formatted) steps")
        case .weekly, .monthly:
            return String(localized: "\(formatted) average steps per observed day")
        }
    }
}

/// Pure #943 chip-coercion rule, extracted so it can be pinned by a test (the Swift twin of Android's
/// `coercedVitalRange` in HealthScreen.kt). Resolves a stored selection NON-DESTRUCTIVELY: an unlocked
/// selection is kept verbatim; a LOCKED one renders as the largest unlocked range with a real finite
/// window (`days != nil`, so never ALL) whose rawValue is <= the selection, else `.week`. Coercing a
/// locked default to ALL would jump a calibrating user to the everything view, so it is excluded.
enum ExploreRangeGating {
    static func coerced(selection: ExploreRange, isUnlocked: (ExploreRange) -> Bool) -> ExploreRange {
        if isUnlocked(selection) { return selection }
        return [ExploreRange.year, .half, .quarter, .month, .threeWeeks, .twoWeeks, .week]
            .first { $0.days != nil && $0.rawValue <= selection.rawValue && isUnlocked($0) } ?? .week
    }
}

// MARK: - Readings table projection (task #8)

/// One windowed reading behind a vital's detail chart: its day ("YYYY-MM-DD"), the value, and the RAW
/// source id it came from (a strap id, the "-noop" computed sibling, "apple-health", or "health-connect").
/// The readings TABLE and the "N readings" caption both derive from this ONE windowed list, so they can
/// never disagree; the raw source maps to a human label via `TodayView.provenanceDisplayLabel` — the SAME
/// resolver Today uses, so no source vocabulary is invented. Swift twin of Android's `VitalReading`.
struct VitalReading: Equatable {
    let day: String
    let value: Double
    let source: String
}

/// Attribute the skin-temperature column the explorer actually displays. An absolute from
/// `skinTempC` takes precedence over an imported absolute in `skinTempDevC`, even when the
/// latter's source has higher row priority. Within one column, imported wins over computed.
func skinTempSourceByDay(_ rows: [SourcedDailyMetric], leadsAbsolute: Bool) -> [String: String] {
    var sources: [String: String] = [:]
    let priority: [DailyMetricSource] = [.whoopImport, .noopComputed, .localCache]
    let columns = leadsAbsolute ? [0, 1] : [1]
    for column in columns {
        for source in priority {
            for row in rows where row.source == source && sources[row.metric.day] == nil {
                let value: Double?
                if column == 0 {
                    value = row.metric.skinTempC
                } else if leadsAbsolute {
                    value = row.metric.skinTempDevC.flatMap { VitalBands.isAbsoluteSkinTemp($0) ? $0 : nil }
                } else {
                    value = row.metric.skinTempDevC.flatMap { !VitalBands.isAbsoluteSkinTemp($0) ? $0 : nil }
                }
                guard value != nil else { continue }
                switch source {
                case .whoopImport:  sources[row.metric.day] = FusionSource.whoopImport.rawValue
                case .noopComputed: sources[row.metric.day] = FusionSource.noopComputed.rawValue
                case .localCache:   sources[row.metric.day] = FusionSource.localCache.rawValue
                case .appleHealth:  break // Skin-temperature series never includes Apple Health.
                }
            }
        }
    }
    return sources
}

let vo2MaxAttributionPrefix = "vo2max-estimator:"

/// #103/queue-11a follow-up: a display-source token for a `spo2` reading that came from the
/// `spo2_candidate` fallback (WHOOP `spo2_candidate_82` or Oura ceiling@100 `0x6F`, device-conditional)
/// rather than a calibrated `spo2Pct` import. Every OTHER surface that shows this fallback (Today's Key
/// Metrics tile, `VitalSignsSummary`, `LiquidTodayView`) already labels it "strap estimate (unverified)"
/// — this Explorer/"Your Cards" drill-down had no candidate fallback at all until now (found 2026-08-24:
/// an Oura-only or WHOOP-4.0-only install with the toggle ON saw nothing here past the last calibrated
/// import, even though the Key Metrics tile right next to it showed a real number). Same
/// prefix-token idiom as `vo2MaxAttributionSource` just below, so the existing readings-table plumbing
/// needs no new machinery — only `TodayView.provenanceDisplayLabel` gains one more case.
let spo2CandidateAttributionSource = "spo2-candidate-estimate"

/// A display-source token that keeps the existing readings-table plumbing while naming the estimator.
/// `nil` is deliberately preserved as `unknown`; a legacy point must never inherit today's profile method.
func vo2MaxAttributionSource(_ estimator: Vo2MaxEstimator?) -> String {
    vo2MaxAttributionPrefix + (estimator?.rawValue ?? "unknown")
}

/// Will the chart show a visible break in this VO₂max trend?
///
/// Derived from `vo2MaxTrendSegmentIds` rather than recomputed, so the caption and the segmentation can
/// never disagree. A GAP IN DAYS under one estimator is still a single segment and draws no break, so it
/// correctly gets no caption: a break means the readings were not produced alike, not that the data
/// paused. Named for the BREAK: an untagged legacy reading resolves to "...estimator:unknown", so an
/// unknown -> Nes transition splits the line while the method itself may never have changed.
/// Kotlin twin `vo2MaxTrendHasBreak`.
func vo2MaxTrendHasBreak(days: [String], sourceByDay: [String: String]) -> Bool {
    Set(vo2MaxTrendSegmentIds(days: days, sourceByDay: sourceByDay)).count > 1
}

/// Sequential segment ids for the VO₂max trend. The counter matters when a user changes Nes → Uth → Nes:
/// using the method name alone would reconnect the two non-adjacent Nes runs across the Uth interval.
func vo2MaxTrendSegmentIds(days: [String], sourceByDay: [String: String]) -> [String] {
    var previous: String?
    var group = -1
    return days.map { day in
        let source = sourceByDay[day] ?? vo2MaxAttributionSource(nil)
        if source != previous { group += 1; previous = source }
        return "\(group):\(source)"
    }
}

func vo2MaxEstimatorDisplayName(_ estimator: Vo2MaxEstimator?) -> String {
    switch estimator {
    case .nes: return "Nes 2011"
    case .uth: return "Uth 2004"
    case nil:  return String(localized: "Unknown")
    }
}

/// One row of a vital detail's readings table: the reading's day (localized), its formatted value with
/// unit, and a human source label. Plain strings so the view is a thin renderer and the projection stays
/// unit-testable. Swift twin of Android's `VitalReadingRow`.
struct VitalReadingRow: Equatable {
    let time: String
    let value: String
    let source: String
}

/// Project a vital's windowed `readings` into table rows, NEWEST FIRST — the same list (so the same count)
/// the "N readings" caption shows, guaranteeing the two never drift. Each row pairs the reading's DAY
/// (these vital series carry one aggregated reading per night, so a row's "time" is its localized calendar
/// date; the date always shows since a charted window spans 2+ days) with the model's own `format`ted
/// value + `unit` and the source label from `TodayView.provenanceDisplayLabel` (a strap id → "Whoop", its
/// "-noop" sibling → "On-device", "apple-health" → "Apple Health", "health-connect" → "Health Connect").
/// `strapDeviceId` is the active strap id the resolver needs. Byte-identical projection to Android's
/// `vitalReadingRows`.
func vitalReadingRows(readings: [VitalReading], unit: String, strapDeviceId: String,
                      now: Date = Date(), format: (Double) -> String) -> [VitalReadingRow] {
    readings.reversed().map { reading in
        let value = format(reading.value)
        return VitalReadingRow(
            time: vitalReadingDateLabel(reading.day, now: now),
            value: unit.isEmpty ? value : "\(value) \(unit)",
            source: TodayView.provenanceDisplayLabel(rawSource: reading.source, deviceId: strapDeviceId)
        )
    }
}

/// Include the weekday so recovery readings can be matched to training days. UTC-fixed and localized;
/// Today/Yesterday remain visible beside the date. Swift twin of Android's `vitalReadingDateLabel`.
func vitalReadingDateLabel(_ day: String, now: Date = Date(), locale: Locale = AppLanguage.activeLocale) -> String {
    guard let date = parseDay(day) else { return day }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "EEE d MMM"
    let dated = formatter.string(from: date)
    formatter.dateFormat = "EEE"
    let weekday = formatter.string(from: date)
    if cal.isDate(date, inSameDayAs: now) { return "\(String(localized: "Today")) · \(weekday)" }
    if let yesterday = cal.date(byAdding: .day, value: -1, to: now),
       cal.isDate(date, inSameDayAs: yesterday) { return "\(String(localized: "Yesterday")) · \(weekday)" }
    return dated
}

// MARK: - Skin-temp explorer notes (#1847 / #1848)

/// Whether the skin-temp explorer must explain that it fell back to deviations despite the
/// user's Settings choice asking for temperatures. Twin of Android's `shouldExplainSkinTempFallback`.
///
/// True only when the user asked for absolute, the screen is NOT leading with absolutes, and NO
/// night in the window carries one — so the fallback is total, not partial. A window with one
/// stored temperature and twenty deltas still leads with temperatures (the #1850 window-wide rule),
/// so this note stays silent there; it fires only when the setting genuinely cannot be honoured.
func shouldExplainSkinTempFallback(prefer: SkinTempDisplay.Kind, leadsAbsolute: Bool,
                                   anyAbsoluteInWindow: Bool) -> Bool {
    prefer == .absolute && !leadsAbsolute && !anyAbsoluteInWindow
}

/// Whether the skin-temp explorer must explain that deviation-only nights were dropped from the
/// series when leading with absolutes. Twin of Android's `shouldExplainShortenedSkinTempSeries`.
///
/// True ONLY when leading with the absolute — the deviation-led branch also drops rows (calibrating
/// nights that have only an absolute, and the #622 bimodal partition), but those are the OPPOSITE
/// kind, so this note's sentence would be precisely backwards there. True only when rows were
/// actually dropped, so a complete series stays silent.
func shouldExplainShortenedSkinTempSeries(leadsAbsolute: Bool, shownReadings: Int,
                                          rowsWithEitherNumber: Int) -> Bool {
    leadsAbsolute && shownReadings < rowsWithEitherNumber
}

// MARK: - Root: categorized list

/// The "Explore" picker — categories as sections, metrics as rows, each pushing a
/// MetricDetailView. Metrics whose series is empty read "No data yet".
struct MetricExplorerView: View {
    @EnvironmentObject var repo: Repository
    /// metric.id → whether its series is empty. Filled INCREMENTALLY by `probeEmptiness()`; a metric
    /// absent from the map simply has no empty marker yet (rows never wait on it — see `MetricRow`).
    @State private var emptyByID: [String: Bool] = [:]
    @State private var probedRefreshSeq: Int?
    /// True while the empty-dot probe is still running its first pass. Drives a small inline progress
    /// hint, never gating the rows: the catalog is static, so every row's label/icon/unit must paint
    /// immediately even before any series read returns (#199).
    @State private var probing = true
    /// Narrows the catalog by title; empty shows everything.
    @State private var query = ""

    var body: some View {
        #if os(macOS)
        // macOS: Explore is a standalone detail pane, so it owns its NavigationStack.
        NavigationStack { exploreScaffold }
            .task(id: repo.refreshSeq) { await probeEmptiness(refreshSeq: repo.refreshSeq) }
        #else
        // iOS: Explore is pushed INSIDE the More tab's NavigationStack. A nested NavigationStack made
        // tapping a metric bounce straight back to the More list (#199) — so use the ambient stack; the
        // rows push their detail with a direct closure-based NavigationLink (#38).
        exploreScaffold
            .task(id: repo.refreshSeq) { await probeEmptiness(refreshSeq: repo.refreshSeq) }
        #endif
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func metrics(in category: String) -> [MetricDescriptor] {
        let all = MetricCatalog.inCategory(category)
        guard !trimmedQuery.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    private var exploreScaffold: some View {
        // PERF (scroll): lazy column. Explore's content is a flat list of sibling sections (the header,
        // the Deep Timeline hero, then a long per-category ForEach), so LazyVStack genuinely builds the
        // off-screen category lists on demand.
        ScreenScaffold(title: nil, onRefresh: { await repo.refresh() }, lazy: true) {
            NoopScreenHeader(verbatim: "") {
                // A quiet, non-blocking hint while the empty-marker probe runs its first pass. The rows
                // render in full immediately regardless (#199).
                if probing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Scanning your data…")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
            .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 6) {
                Text("Explore")
                    .font(StrandFont.title1)
                    .tracking(-0.56)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Every signal, one tap deep.")
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            searchField
                .padding(.top, 6)
            if trimmedQuery.isEmpty {
                // The headline tap-through (#575): a full-day, full-resolution, zoomable timeline. Sits above
                // the per-metric catalog because it's a different kind of view — every second of one day
                // rather than one number per day. Closure-based NavigationLink, matching the rows (#38/#199).
                NavigationLink {
                    FullDayChartView()
                } label: {
                    deepTimelineHero
                }
                .buttonStyle(LiquidPressStyle())
                #if os(iOS)
                .simultaneousGesture(TapGesture().onEnded { StrandHaptic.selection.play() })
                #endif
                .padding(.top, 2)
            }

            ForEach(MetricCatalog.categories, id: \.self) { category in
                let metrics = metrics(in: category)
                if !metrics.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        // Localized at the render site only; `category` itself stays the raw English
                        // identifier that `inCategory` filters on.
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: MetricCatalog.categoryDisplayName(category))
                                .font(StrandFont.overline)
                                .tracking(StrandFont.overlineTracking)
                                .textCase(.uppercase)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                            Text(metrics.count == 1 ? "1 signal" : "\(metrics.count) signals")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .padding(.horizontal, 6)
                        NoopList {
                            ForEach(metrics) { metric in
                                // Push the detail directly (closure-based), like every other More-tab
                                // screen. The old value + .navigationDestination(for:) pairing resolved
                                // against TWO registered destinations and double-pushed — the detail
                                // flashed then popped straight back (#38).
                                NavigationLink {
                                    MetricDetailView(metric: metric)
                                } label: {
                                    MetricRow(metric: metric, isEmpty: emptyByID[metric.id] ?? false)
                                }
                                // Full-row press-down feedback: a transform, so it works edge-to-edge with
                                // the dividers between rows.
                                .buttonStyle(LiquidPressStyle())
                                #if os(iOS)
                                // Light selection tick on tap; the simultaneousGesture leaves the
                                // NavigationLink push intact.
                                .simultaneousGesture(TapGesture().onEnded {
                                    StrandHaptic.selection.play()
                                })
                                #endif
                            }
                        }
                    }
                    .padding(.top, 14)
                }
            }

            Text(verbatim: sourceSummary)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }
        .noopHidesSystemNavBar()
        // Rows push MetricDetailView directly (closure-based NavigationLink above) — no value/destination
        // pairing, which is what double-pushed (#38). Nothing else registers a MetricDescriptor destination.
    }

    /// `.srch`: the catalog filter.
    private var searchField: some View {
        HStack(spacing: 10) {
            PhIcon("magnifying-glass").opacity(0.6)
            TextField(String(localized: "Search \(MetricCatalog.all.count) signals"), text: $query)
                .textFieldStyle(.plain)
                .font(StrandFont.light(14.5, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textPrimary)
                .disableAutocorrection(true)
                .accessibilityLabel("Search signals")
            if !query.isEmpty {
                Button { query = "" } label: {
                    PhIcon("x-circle", size: 16).opacity(0.6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .padding(.horizontal, 18)
        .frame(height: 46)
        .background(Capsule(style: .continuous).fill(NoopVisualStyle.surface))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
    }

    /// The hero entry that opens the Deep Timeline (#575), in the effort glow.
    private var deepTimelineHero: some View {
        NoopHeroCard(glow: .strain, padding: 20, cornerRadius: 32) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge("Deep Timeline", icon: "waveform")
                    Spacer(minLength: 8)
                    PhIcon("caret-right", size: 15)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(StrandPalette.textPrimary.opacity(0.10)))
                        .overlay(Circle().strokeBorder(StrandPalette.textPrimary.opacity(0.14), lineWidth: 1))
                }
                Text("Every second of your day")
                    .font(StrandFont.light(21, relativeTo: .title2))
                    .tracking(-0.2)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.top, 18)
                Text("One metric across the whole day, zoomable down to the raw per-second signal.")
                    .font(StrandFont.light(13, relativeTo: .footnote))
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.66))
                    .padding(.top, 4)
            }
            .foregroundStyle(StrandPalette.textPrimary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Deep Timeline, every second of your day, zoomable")
        .accessibilityAddTraits(.isButton)
    }

    /// "47 from Whoop · 12 from Apple Health …": how the catalog splits across its sources.
    private var sourceSummary: String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for m in MetricCatalog.all {
            if counts[m.sourceLabel] == nil { order.append(m.sourceLabel) }
            counts[m.sourceLabel, default: 0] += 1
        }
        return order.map { String(localized: "\(counts[$0] ?? 0) from \($0)") }.joined(separator: " · ")
    }

    /// One lightweight pass to learn which metrics have no series, so rows can flag them. Failures
    /// default to "has data" (no marker).
    ///
    /// #199 originally fixed this by publishing PER METRIC rather than in one final batch, because the
    /// sweep ran ~60 sequential `exploreSeries` reads — each hopping back to the @MainActor Repository —
    /// and the freshly-pushed list painted blank until it finished. That made the symptom bearable
    /// without addressing the cost: the sweep still read sixty full histories, built sixty dictionaries
    /// and sorted them, only to keep sixty booleans.
    ///
    /// `Repository.nonEmptyMetricIDs` asks the cheap question instead — one DISTINCT-key query per
    /// source plus one in-memory pass — so the whole probe is now a single await. Rows still render their
    /// label / icon / unit without waiting on this — the map only ever ADDS an empty marker.
    private func probeEmptiness(refreshSeq: Int) async {
        guard probedRefreshSeq != refreshSeq || emptyByID.isEmpty else { probing = false; return }
        probedRefreshSeq = refreshSeq
        probing = true
        let nonEmpty = await repo.nonEmptyMetricIDs(MetricCatalog.all)
        guard !Task.isCancelled else { return }
        emptyByID = Dictionary(uniqueKeysWithValues: MetricCatalog.all.map { ($0.id, !nonEmpty.contains($0.id)) })
        probing = false
    }
}

// MARK: - One catalog row

private struct MetricRow: View {
    let metric: MetricDescriptor
    let isEmpty: Bool

    // Trailing unit chip follows the Imperial/Metric preference (kg→lb, °C→°F) and the Effort scale
    // (/100→/21, #268).
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var unitLabel: String {
        let system = UnitSystem(rawValue: unitSystemRaw) ?? .metric
        let temp = UnitPrefs.resolveTemperature(system: system, override: temperatureRaw)
        let effort = UnitPrefs.resolveEffortScale(effortScaleRaw)
        let unit = metric.displayUnit(system: system, temperature: temp, effortScale: effort)
        // The catalog carries a couple of word units ("yrs", "steps") as data; symbols pass through.
        switch unit {
        case "yrs":   return String(localized: "yrs")
        case "steps": return String(localized: "steps")
        default:      return unit
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            NoopIconTile(Self.phosphorIcon(metric), size: 32)
                .opacity(isEmpty ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.title)
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(isEmpty ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(isEmpty ? String(localized: "No data yet") : metric.sourceLabel)
                    .font(StrandFont.light(12, relativeTo: .caption))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !unitLabel.isEmpty {
                Text(unitLabel)
                    .font(StrandFont.book(10.5, relativeTo: .caption2))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 52, minHeight: 24)
                    .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
                    .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
            }
            PhIcon("caret-right", size: 14)
                .foregroundStyle(StrandPalette.textPrimary)
                .opacity(0.35)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        // Whole-string key per variant (never a concatenated localized tail on an a11y label).
        .accessibilityLabel(isEmpty
            ? "\(metric.title), \(unitLabel.isEmpty ? MetricCatalog.categoryDisplayName(metric.category) : unitLabel), no data"
            : "\(metric.title), \(unitLabel.isEmpty ? MetricCatalog.categoryDisplayName(metric.category) : unitLabel)")
        .accessibilityAddTraits(.isButton)
    }

    /// The catalog names SF Symbols; the v2 rows draw the matching Phosphor glyph, by category when a
    /// symbol has no counterpart.
    static func phosphorIcon(_ m: MetricDescriptor) -> String {
        switch m.icon {
        case "heart", "heart.fill", "heart.text.square": return "heart"
        case "bolt.heart":                        return "trend-up"
        case "flame", "flame.fill":               return "flame"
        case "lungs", "lungs.fill":               return "wind"
        case "figure.run":                        return "person-simple-run"
        case "sparkles":                          return "sparkle"
        case "figure.stand", "figure":            return "person"
        case "heart.circle":                      return "lightning"
        case "waveform.path.ecg":                 return "heartbeat"
        case "drop":                              return "drop"
        case "thermometer":                       return "thermometer"
        case "moon.stars":                        return "moon-stars"
        case "bed.double", "bed.double.fill":     return "bed"
        case "moon.zzz", "moon.fill", "moon":     return "moon"
        case "moon.haze":                         return "cloud-moon"
        case "gauge.medium", "gauge":             return "gauge"
        case "calendar":                          return "calendar-blank"
        case "exclamationmark.circle":            return "hourglass"
        case "figure.walk", "figure.walk.motion": return "footprints"
        case "dumbbell":                          return "barbell"
        case "scalemass":                         return "scales"
        case "percent":                           return "percent"
        case "figure.arms.open":                  return "person-arms-spread"
        case "gauge.with.dots.needle.50percent":  return "wave-sine"
        case "fork.knife":                        return "fork-knife"
        case "p.circle", "c.circle", "f.circle":  return "bowl-food"
        case "face.smiling":                      return "smiley"
        default:
            switch m.category {
            case "Heart":     return "heart"
            case "Charge":    return "lightning"
            case "Rest":      return "moon"
            case "Effort":    return "flame"
            case "Nutrition": return "fork-knife"
            case "Mind":      return "smiley"
            default:          return "chart-line"
            }
        }
    }
}
// MARK: - Preview

#if DEBUG
@MainActor
private func explorerPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Explore") {
    MetricExplorerView()
        .environmentObject(explorerPreviewRepo())
        .frame(width: 900, height: 820)
        .preferredColorScheme(.dark)
}

#Preview("Metric Detail") {
    let repo = explorerPreviewRepo()
    return NavigationStack {
        MetricDetailView(metric: MetricCatalog.all.first { $0.key == "recovery" }!)
    }
    .environmentObject(repo)
    .environmentObject(ProfileStore())
    .environmentObject(IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: "preview"))
    .frame(width: 900, height: 820)
    .preferredColorScheme(.dark)
}
#endif
