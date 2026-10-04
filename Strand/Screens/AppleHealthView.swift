import SwiftUI
import StrandDesign
import WhoopStore
import Foundation

// MARK: - Apple Health (per-source page) — v2
//
// A heart-glow hero (connection state, last sync, what has been read), ONE range control, a 3-up grid
// of summary tiles, then two-up sparkline cards per section — Heart & vitals, Activity & energy, Body
// composition, Sleep.
//
// Everything reads from the "apple-health" source. ALL history is loaded once; the
// range control simply windows it client-side, RELATIVE TO THE LATEST data point
// (not "now"). Per the data contract a series may be SPARSE (weight/body-fat are
// weekly): if the selected window holds ≥1 point we SHOW THAT WINDOW (so W/M/3M stay
// visibly distinct); only when it holds ZERO points do we auto-expand to the smallest
// larger range that does. Tiles show the LATEST point, with "as of <date>" when it is older
// than the newest day on record.

/// #833/v7.7.2 (Apple Health per-source freeze): the snapshot AppleHealthView.load() builds, parked on the
/// long-lived Repository so a re-mount (macOS keys the NavigationSplitView detail with `.id`, so every sidebar
/// switch cold-mounts the screen) can RESTORE it in-memory instead of re-running the whole apple-health history
/// read on the @MainActor. The exact twin of `InsightsLoadCache` for #833; holds load()'s three `@State`
/// outputs. Consumed only when the seq AND the dayKey still match (see `Repository.appleHealthLoadedSeq` /
/// `appleHealthLoadedDayKey`).
struct AppleHealthLoadCache {
    let appleRows: [AppleDaily]
    let workoutCount: Int
    let series: [String: [(day: String, value: Double)]]
}

/// #833/v7.7.2: `.task(id:)` key for the Apple Health load, the data-refresh seq PLUS today's local day-key, so
/// the load re-runs both on a data change AND on a calendar-day rollover while the screen stays mounted across
/// midnight (keying on `refreshSeq` alone left the inside-load dayKey guard unreachable). The exact twin of
/// InsightsView's `InsightsLoadKey`.
struct AppleHealthLoadKey: Equatable {
    let seq: Int
    let dayKey: String
}

struct AppleHealthView: View {
    @EnvironmentObject var repo: Repository

    // iOS-only: the live two-way HealthKit bridge, injected at StrandiOSApp. macOS has no HealthKit
    // (HealthKitBridge is `#if os(iOS)` in its own file and isn't in the macOS environment), so this
    // property and every `health.*` use below MUST stay inside `#if os(iOS)`.
    #if os(iOS)
    @EnvironmentObject private var health: HealthKitBridge
    @EnvironmentObject private var model: AppModel
    #endif

    // Imperial/Metric display preference (D#103). Weight and lean mass (stored kg) re-label to lb here;
    // every other Apple Health metric is unit-agnostic. Display-only.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    /// kg value → the active mass unit, full string with label (e.g. "74.5 kg" / "164.2 lb").
    private func massLabel(_ kg: Double) -> String { UnitFormatter.massFromKilograms(kg, system: unitSystem) }

    /// Optional pre-seeded data for previews; when set, the async store load is
    /// skipped (store-backed reads can't be seeded in a preview). Production leaves
    /// this nil and loads from the repository in `.task`.
    private let previewData: PreviewData?

    init() { self.previewData = nil }
    fileprivate init(previewData: PreviewData) { self.previewData = previewData }

    // Loaded state.
    @State private var loaded = false
    @State private var appleRows: [AppleDaily] = []
    @State private var workoutCount = 0

    // Raw series (day, value) keyed by metric — ALL history, ascending by day.
    @State private var series: [String: [(day: String, value: Double)]] = [:]

    // The active range window. The data goes back years — never hard-cap.
    @State private var range: RangeWindow = .quarter

    /// Memoized per-metric resolved window. Resolving a key (effective range +
    /// trimmed rows) re-slices the full multi-year series and, on auto-widen, slices
    /// it once per candidate range. The view body asks for the same key many times
    /// per render (every summary tile, every trend card, plus the range caption), and
    /// SwiftUI re-evaluates the body on hover / animation / 1Hz HR ticks. The inputs
    /// (`series`, `range`) only change on load or pill tap, so we compute once and
    /// cache, recomputing via .onChangeCompat(of:) when an input actually changes.
    @State private var windowCache: [String: ResolvedSeries] = [:]

    /// Memoized per-day rows trimmed to the active window. Read by
    /// `rangeSummaryCaption` every render; depends only on
    /// `appleRows` + `range`, so it's cached alongside `windowCache`.
    @State private var windowedRowsCache: [AppleDaily] = []

    /// A key's resolved (possibly auto-widened) window: the effective range plus the
    /// rows trimmed to it.
    private struct ResolvedSeries {
        var effective: RangeWindow
        var rows: [(day: String, value: Double)]
    }

    // The series keys this page pulls from the apple-health source.
    private static let seriesKeys = [
        "steps", "active_kcal", "vo2max",
        "resting_hr", "hrv", "spo2", "resp_rate", "asleep_min",
        "weight", "body_fat", "lean_mass", "bmi"
    ]

    // yyyy-MM-dd → Date (en_US_POSIX / UTC), per the project's date contract.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "4 Oct" / "4. Okt.": the reader's locale (a POSIX locale printed English months in every language),
    /// and UTC like `dayParser`, so a day key never shifts a day west of Greenwich.
    private static let asOfFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()

    /// Thousands-grouped integer formatter (steps / calories). Static so it isn't reallocated
    /// per tile on every render. (perf plan Q3)
    private static let groupedIntFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    private func date(_ day: String) -> Date? { Self.dayParser.date(from: day) }

    // MARK: - Range control (W / M / 3M / 6M / 1Y / ALL) — the ONE pill control.

    enum RangeWindow: String, CaseIterable, Identifiable {
        case week, month, quarter, half, year, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .week:    return String(localized: "W")
            case .month:   return String(localized: "M")
            case .quarter: return String(localized: "3M")
            case .half:    return String(localized: "6M")
            case .year:    return String(localized: "1Y")
            case .all:     return String(localized: "ALL")
            }
        }
        /// Number of trailing days; nil = everything.
        var days: Int? {
            switch self {
            case .week:    return 7
            case .month:   return 30
            case .quarter: return 90
            case .half:    return 180
            case .year:    return 365
            case .all:     return nil
            }
        }
        var caption: String {
            switch self {
            case .week:    return String(localized: "7 DAYS")
            case .month:   return String(localized: "30 DAYS")
            case .quarter: return String(localized: "90 DAYS")
            case .half:    return String(localized: "180 DAYS")
            case .year:    return String(localized: "365 DAYS")
            case .all:     return String(localized: "ALL TIME")
            }
        }
        var name: String {
            switch self {
            case .week:    return String(localized: "week")
            case .month:   return String(localized: "month")
            case .quarter: return String(localized: "3 months")
            case .half:    return String(localized: "6 months")
            case .year:    return String(localized: "year")
            case .all:     return String(localized: "all history")
            }
        }
        /// The sentence-case span a section title carries ("90 days", "All time").
        var sectionCaption: String {
            switch self {
            case .week:    return String(localized: "7 days")
            case .month:   return String(localized: "30 days")
            case .quarter: return String(localized: "90 days")
            case .half:    return String(localized: "180 days")
            case .year:    return String(localized: "365 days")
            case .all:     return String(localized: "All time")
            }
        }
        /// This range plus every LARGER range, ascending — the auto-expand search
        /// order when the selected window holds zero points.
        var widening: [RangeWindow] {
            let order: [RangeWindow] = [.week, .month, .quarter, .half, .year, .all]
            guard let i = order.firstIndex(of: self) else { return [.all] }
            return Array(order[i...])
        }
    }

    var body: some View {
        ScreenScaffold(title: nil,
                       onRefresh: { await repo.refresh() },
                       // PERF: chart-heavy column (the tile grid plus the heart / activity / body / sleep
                       // sections, each carrying its own sparklines). Every section is a run of direct
                       // children of the scaffold's LazyVStack, so off-screen sections build on demand.
                       lazy: true) {
            NoopScreenHeader("Apple Health")
                .padding(.bottom, 6)
            hero
            if loaded && !hasAnyData {
                emptyNote
            } else if !loaded {
                loadingState
            } else {
                rangeControl
                summarySection
                trendSection("Heart & vitals", specs: heartSpecs)
                trendSection("Activity & energy", specs: activitySpecs)
                trendSection("Body composition", specs: bodySpecs)
                trendSection("Sleep", specs: sleepSpecs)
            }
            #if os(iOS)
            if health.auth == .authorized { syncList }
            #endif
            footer
        }
        .noopHidesSystemNavBar()
        .task(id: AppleHealthLoadKey(seq: repo.refreshSeq, dayKey: Repository.localDayKey(Date()))) { await load(allowCache: true) }
        .onChangeCompat(of: range) { _ in rebuildWindowCache() }
    }

    /// Rebuild the per-metric resolved-window cache from scratch. Called once after
    /// load and again whenever `range` changes — never inside the render path.
    private func rebuildWindowCache() {
        var cache: [String: ResolvedSeries] = [:]
        cache.reserveCapacity(Self.seriesKeys.count)
        for key in Self.seriesKeys {
            let eff = computeEffectiveRange(key)
            cache[key] = ResolvedSeries(effective: eff, rows: slice(key, eff))
        }
        windowCache = cache
        windowedRowsCache = computeWindowedRows()
    }

    /// True if ANY series or per-day row holds data (drives the empty state).
    private var hasAnyData: Bool {
        if !appleRows.isEmpty { return true }
        return series.values.contains { !$0.isEmpty }
    }

    // MARK: - Load

    private func load(allowCache: Bool = false) async {
        // Previews inject data directly (store-backed reads can't be seeded). Stays ABOVE the cache path so a
        // preview never touches the repo.
        if let pd = previewData {
            appleRows = pd.rows.sorted { $0.day < $1.day }
            workoutCount = pd.workoutCount
            series = pd.series
            rebuildWindowCache()
            loaded = true
            return
        }

        // #833/v7.7.2: the whole heavy load, cache short-circuit, DEBUG fire tally, and write-back live on the
        // long-lived repo (`performAppleHealthLoad`, a headless-testable seam) so a re-mount RESTORES the prior
        // snapshot in-memory instead of re-running the whole apple-health history read on the @MainActor, which
        // is the freeze fix. `allowCache` is true ONLY on the `.task(id:)`-driven path (a re-mount / data refresh
        // / day rollover); the direct load() sites (Enable / Sync now) leave it false so a live sync always
        // re-reads. The seam owns the cache; this view just copies the snapshot into its `@State`.
        let snapshot = await repo.performAppleHealthLoad(seriesKeys: Self.seriesKeys, allowCache: allowCache)
        appleRows = snapshot.appleRows
        workoutCount = snapshot.workoutCount
        series = snapshot.series
        rebuildWindowCache()
        loaded = true
    }

    // MARK: - Range control

    /// The one range control (W / M / 3M / 6M / 1Y / ALL) with its window caption beneath. Every
    /// section below windows its series by it.
    private var rangeControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            SegmentedPillControl(RangeWindow.allCases, selection: $range, fillsAvailableWidth: true) { $0.label }
            Text(rangeSummaryCaption)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.horizontal, 4)
                .accessibilityLabel(rangeSummaryCaption)
        }
        .padding(.top, 18)
    }

    /// Window-level caption near the control: how many days the per-day rows span in
    /// the selected range, plus a flag if any tracked series had to auto-widen.
    private var rangeSummaryCaption: String {
        let n = windowedRows.count
        let anyWidened = Self.seriesKeys.contains { !raw($0).isEmpty && effectiveRange($0) != range }
        // Whole-phrase variants per count so translators see complete sentences (never a stitched plural).
        if anyWidened {
            return n == 1
                ? String(localized: "1 day · \(range.name) · some sparse series widened")
                : String(localized: "\(n) days · \(range.name) · some sparse series widened")
        }
        return n == 1
            ? String(localized: "1 day · \(range.name)")
            : String(localized: "\(n) days · \(range.name)")
    }

    /// AppleDaily rows trimmed to the active window (for the range caption), taken
    /// RELATIVE TO THE LATEST recorded day rather than "now". Served from the
    /// per-render cache; recomputed only when `appleRows`/`range` change.
    private var windowedRows: [AppleDaily] {
        loaded ? windowedRowsCache : computeWindowedRows()
    }

    /// The actual windowing of the per-day rows. Called only from
    /// rebuildWindowCache and the not-yet-loaded fallback — never per render.
    private func computeWindowedRows() -> [AppleDaily] {
        guard let n = range.days else { return appleRows }
        guard let lastDay = appleRows.last?.day, let last = date(lastDay) else { return [] }
        let cutoff = last.addingTimeInterval(-Double(n - 1) * 86_400)
        return appleRows.filter { row in
            guard let d = date(row.day) else { return false }
            return d >= cutoff
        }
    }

    // MARK: - Hero

    /// The heart-glow hero: connection state, the last sync (or the history on record), and the
    /// shape of what has been read. On iOS it also carries the opt-in for the live HealthKit bridge;
    /// macOS has no HealthKit, so every `health.*` reference stays inside `#if os(iOS)`.
    private var hero: some View {
        NoopHeroCard(glow: .heart, padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                heroIdentity
                heroBody
                if loaded && hasAnyData {
                    NoopMetricRow {
                        NoopMetric(value: "\(metricsWithData)", label: "Metrics read", labelColor: NoopMetric.heroLabel)
                        NoopMetric(value: "\(workoutCount)", label: "Workouts", labelColor: NoopMetric.heroLabel)
                        NoopMetric(value: latestDayLabel ?? "—", label: "Latest day", labelColor: NoopMetric.heroLabel)
                    }
                    .padding(.top, 20)
                }
            }
            .padding(.bottom, 2)
        }
    }

    private var heroIdentity: some View {
        HStack(spacing: 12) {
            PhIcon("heart", size: 22)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.white.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Apple Health")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    if isLive { NoopTag("Live", size: 11) }
                }
                statusLine
                    .font(StrandFont.light(12, relativeTo: .caption))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// True when the live HealthKit bridge is connected (iOS only).
    private var isLive: Bool {
        #if os(iOS)
        return health.auth == .authorized
        #else
        return false
        #endif
    }

    private var statusLine: Text {
        #if os(iOS)
        switch health.auth {
        case .authorized:
            return health.syncing ? Text("Syncing…") : Text("Connected · reading in the background")
        case .unknown:            return Text("Not connected yet")
        case .denied:             return Text("Access is turned off")
        case .entitlementMissing: return Text("Can't connect in this install")
        case .unavailable:        return Text("Not available on \(Platform.deviceNounPhrase)")
        }
        #else
        return Text("Imported from a Health export")
        #endif
    }

    @ViewBuilder private var heroBody: some View {
        #if os(iOS)
        switch health.auth {
        case .authorized:
            if let last = health.lastSync {
                NoopDotNumber(last.formatted(.dateTime.hour().minute()), size: 84)
                    .padding(.top, 30)
                Text("Last synced \(relativeAgo(last.timeIntervalSince1970)).")
                    .font(StrandFont.light(19, relativeTo: .title3))
                    .tracking(-0.2)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.top, 16)
            } else {
                heroNote("Connected. New strap data is written automatically, with periodic background refresh when iOS allows it.")
            }

        case .unknown, .denied:
            heroNote("Read your heart rate, HRV, blood oxygen, respiratory rate, sleep, steps and energy straight from Apple Health, and write NOOP's strap data back: sleep with full stages, continuous heart rate, workouts, and nightly vitals. Everything stays on \(Platform.deviceNounPhrase).")
            NoopButton("Enable Apple Health", kind: .primary, fullWidth: true) {
                Task {
                    await health.requestAuthorization()
                    await HealthSyncRefreshCoordinator.run(
                        sync: { await health.sync() },
                        refresh: {
                            await model.refreshAfterAppleHealthSync(
                                authorized: health.auth == .authorized)
                        }
                    )
                    await load()
                }
            }
            .padding(.top, 18)
            if health.auth == .denied {
                Text("If you don't see the prompt, enable NOOP under Settings › Health › Data Access & Devices.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

        case .entitlementMissing:
            // #348 / #930: the sideload was re-signed WITHOUT the HealthKit entitlement (free
            // Apple IDs always lack it; some paid reseller certs do too), so "Enable Apple Health"
            // can never work and the app can never appear under Settings › Health › Data Access
            // & Devices. Give the honest path instead of impossible Settings instructions: bring
            // data in via a file import or the HealthKit-free Shortcuts export.
            heroNote("This install can't connect to Apple Health directly. It was signed with a profile that doesn't include Apple's Health permission, so there's nothing to enable, and NOOP won't appear under Settings › Health.")
            Text("To get your Apple Health data in anyway: import a Health export .zip in Data Sources, or turn on Shortcuts Export to feed your strap data into Health without the entitlement. (A build installed from the App Store or signed with a paid Apple Developer account connects directly.)")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

        case .unavailable:
            heroNote("Apple Health isn't available on \(Platform.deviceNounPhrase).")
        }
        if let err = health.lastError {
            Text(err)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusCritical)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        #else
        if loaded && hasAnyData {
            NoopDotNumber("\(appleRows.count)", size: 84)
                .padding(.top, 30)
            Text("days of Apple Health history on \(Platform.deviceNounPhrase).")
                .font(StrandFont.light(19, relativeTo: .title3))
                .tracking(-0.2)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
        }
        #endif
    }

    private func heroNote(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 22)
    }

    /// How many of the page's series hold at least one reading.
    private var metricsWithData: Int {
        Self.seriesKeys.filter { !raw($0).isEmpty }.count
    }

    /// The newest day on record ("3 Oct"), from the per-day rows.
    private var latestDayLabel: String? {
        appleRows.last.flatMap { date($0.day) }.map { Self.asOfFormatter.string(from: $0) }
    }

    // MARK: - Empty / loading

    private var emptyNote: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                NoopCardHeader("No Apple Health data yet", icon: "heart")
                Group {
                    #if os(iOS)
                    // #348 — when the build can't carry the HealthKit entitlement there's no "Enable"
                    // button to tap, so the empty-state copy must point at the file/Shortcuts path
                    // instead of telling the user to tap a control that isn't shown.
                    if health.auth == .entitlementMissing {
                        Text("Nothing here yet. This sideloaded install can't read Apple Health directly. Import a Health export .zip in Data Sources, or turn on Shortcuts Export to bring your strap data into Health.")
                    } else {
                        Text("Nothing here yet. Tap Enable Apple Health above to read your data live, or import a Health export .zip in Data Sources.")
                    }
                    #else
                    Text("Nothing imported yet. On an iPhone: Health app, tap your photo, Export All Health Data, then import the .zip here in Data Sources.")
                    #endif
                }
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var loadingState: some View {
        NoopCard {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .tint(StrandPalette.textSecondary)
                Text("Reading your Apple Health history…")
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Summary tiles

    /// How a tile's hero value is derived from its window.
    private enum Aggregate { case latest, mean }

    @ViewBuilder private var summarySection: some View {
        NoopSectionTitle("Summary", caption: String(localized: "Latest · sleep averaged over \(range.name)"))
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                summaryTile(key: "steps", label: "Steps") { (intString($0), nil) }
                summaryTile(key: "resting_hr", label: "Resting HR") { ("\(Int($0.rounded()))", "bpm") }
                summaryTile(key: "hrv", label: "HRV") { ("\(Int($0.rounded()))", "ms") }
            }
            GridRow {
                summaryTile(key: "vo2max", label: "VO₂ Max") { (String(format: "%.1f", $0), nil) }
                summaryTile(key: "weight", label: "Weight") { massParts($0) }
                summaryTile(key: "body_fat", label: "Body Fat") { (String(format: "%.1f", $0), "%") }
            }
            GridRow {
                summaryTile(key: "lean_mass", label: "Lean Mass") { massParts($0) }
                summaryTile(key: "asleep_min", label: "Asleep avg", aggregate: .mean) { (durationString($0), nil) }
                SourceStatTile(number: "\(workoutCount)", unit: nil, label: Text("Workouts"),
                                  caption: workoutCount > 0 ? String(localized: "Apple-logged") : nil)
            }
        }
    }

    /// One summary tile. Sparse-safe: the window auto-widens (see `resolvedWindow`); the value is the
    /// LATEST point unless a mean is asked for, and a latest point older than the newest day on record
    /// says "as of <date>" so a weekly weigh-in doesn't read as today's.
    private func summaryTile(key: String, label: LocalizedStringKey, aggregate: Aggregate = .latest,
                             parts: (Double) -> (String, String?)) -> some View {
        let rows = resolvedWindow(key)
        let values = rows.map(\.value)
        var number = "—"
        var unit: String?
        var caption: String?
        if let last = values.last {
            switch aggregate {
            case .latest:
                (number, unit) = parts(last)
                if let day = rows.last?.day, day != appleRows.last?.day, let d = date(day) {
                    caption = String(localized: "as of \(Self.asOfFormatter.string(from: d))")
                }
            case .mean:
                (number, unit) = parts(mean(values) ?? last)
            }
        }
        return SourceStatTile(number: number, unit: unit, label: Text(label), caption: caption)
    }

    /// kg → the active mass unit, split into number and unit ("74.5" + "kg" / "164.2" + "lb").
    private func massParts(_ kg: Double) -> (String, String?) {
        let full = massLabel(kg)
        guard let space = full.lastIndex(of: " ") else { return (full, nil) }
        return (String(full[..<space]), String(full[full.index(after: space)...]))
    }

    // MARK: - Trend sections (two-up cards with a sparkline)

    /// One metric card's recipe: the series key, its title and glyph, and how its value splits into
    /// a number and a unit.
    private struct TrendSpec: Identifiable {
        let key: String
        let title: LocalizedStringKey
        let icon: String
        let parts: (Double) -> (String, String?)
        var id: String { key }
    }

    private var heartSpecs: [TrendSpec] {
        [
            TrendSpec(key: "resting_hr", title: "Resting HR", icon: "heartbeat") { ("\(Int($0.rounded()))", "bpm") },
            TrendSpec(key: "hrv", title: "HRV", icon: "wave-sine") { ("\(Int($0.rounded()))", "ms") },
            TrendSpec(key: "spo2", title: "Blood oxygen", icon: "drop") { (String(format: "%.1f", $0), "%") },
            TrendSpec(key: "resp_rate", title: "Respiratory rate", icon: "wind") { (String(format: "%.1f", $0), "rpm") },
        ]
    }

    private var activitySpecs: [TrendSpec] {
        [
            TrendSpec(key: "steps", title: "Steps", icon: "footprints") { (intString($0), nil) },
            TrendSpec(key: "active_kcal", title: "Active energy", icon: "fire") { (intString($0), "kcal") },
        ]
    }

    private var bodySpecs: [TrendSpec] {
        [
            TrendSpec(key: "weight", title: "Weight", icon: "scales") { massParts($0) },
            TrendSpec(key: "body_fat", title: "Body fat", icon: "drop-half") { (String(format: "%.1f", $0), "%") },
            TrendSpec(key: "lean_mass", title: "Lean body mass", icon: "person-simple") { massParts($0) },
            TrendSpec(key: "bmi", title: "BMI", icon: "gauge") { (String(format: "%.1f", $0), nil) },
        ]
    }

    private var sleepSpecs: [TrendSpec] {
        [TrendSpec(key: "asleep_min", title: "Asleep", icon: "moon-stars") { (durationString($0), nil) }]
    }

    /// A section title plus its cards two-up; an odd card out runs the full width.
    @ViewBuilder
    private func trendSection(_ title: LocalizedStringKey, specs: [TrendSpec]) -> some View {
        NoopSectionTitle(title, caption: range.sectionCaption)
        SourceCardGrid(items: specs) { trendCard($0) }
    }

    /// One card: the latest reading, a sparkline over the resolved window, and its average and range
    /// (flagging an auto-widen when a sparse series needed one).
    private func trendCard(_ spec: TrendSpec) -> some View {
        let rows = resolvedWindow(spec.key)
        let values = rows.map(\.value)
        let (number, unit) = values.last.map(spec.parts) ?? ("—", nil)
        var caption: String
        if let avg = mean(values), let lo = values.min(), let hi = values.max() {
            caption = values.count == 1
                ? String(localized: "Latest reading")
                : String(localized: "Avg \(spec.parts(avg).0) · \(spec.parts(lo).0)–\(spec.parts(hi).0)")
            let eff = effectiveRange(spec.key)
            if eff != range { caption += "\n" + String(localized: "Widened to \(eff.name)") }
        } else {
            caption = String(localized: "No readings recorded.")
        }
        return SourceMetricCard(title: spec.title, icon: spec.icon, number: number, unit: unit,
                                values: SourceSparkline.downsample(values), caption: caption)
    }

    // MARK: - Sync (iOS) + footer

    #if os(iOS)
    private var syncList: some View {
        NoopList {
            Button {
                Task {
                    await HealthSyncRefreshCoordinator.run(
                        sync: { await health.sync() },
                        refresh: {
                            await model.refreshAfterAppleHealthSync(
                                authorized: health.auth == .authorized)
                        }
                    )
                    await load()
                }
            } label: {
                NoopRow("Sync now", caption: "Read new Health data and write NOOP's strap data back",
                        icon: "arrows-clockwise") {
                    if health.syncing {
                        ProgressView().controlSize(.small).tint(StrandPalette.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(health.syncing)
        }
        .padding(.top, 12)
    }
    #endif

    private var footer: some View {
        Group {
            #if os(iOS)
            Text("Read on \(Platform.deviceNounPhrase) through HealthKit · never uploaded")
            #else
            Text("Stored on \(Platform.deviceNounPhrase) · never uploaded")
            #endif
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    // MARK: - Series helpers (sparse-data fallback to ALL)

    /// All-history rows for a key (ascending by day).
    private func raw(_ key: String) -> [(day: String, value: Double)] { series[key] ?? [] }

    /// The latest recorded day for a key (anchors its windows).
    private func latestDate(_ key: String) -> Date? {
        guard let d = raw(key).last?.day else { return nil }
        return date(d)
    }

    /// Rows for a key over a given range, taken RELATIVE TO THE LATEST data point
    /// (not "now"); `.all` returns everything.
    private func slice(_ key: String, _ r: RangeWindow) -> [(day: String, value: Double)] {
        let all = raw(key)
        guard let n = r.days else { return all }
        guard let last = latestDate(key) else { return [] }
        let cutoff = last.addingTimeInterval(-Double(n - 1) * 86_400)
        return all.filter { row in
            guard let d = date(row.day) else { return false }
            return d >= cutoff
        }
    }

    /// The range actually shown for a key: the SELECTED range whenever its window
    /// holds ≥1 point, otherwise the smallest LARGER range that does — so switching
    /// ranges stays visibly distinct and only sparse windows widen. Served from the
    /// per-render cache; falls back to a fresh compute on a cache miss.
    private func effectiveRange(_ key: String) -> RangeWindow {
        windowCache[key]?.effective ?? computeEffectiveRange(key)
    }

    /// The actual effective-range computation (re-slices the series, once per widening
    /// candidate). Called only from rebuildWindowCache and the cache-miss fallback —
    /// never repeatedly within a single render.
    private func computeEffectiveRange(_ key: String) -> RangeWindow {
        guard !raw(key).isEmpty else { return range }
        for r in range.widening where !slice(key, r).isEmpty { return r }
        return .all
    }

    /// Rows for a key trimmed to its resolved (possibly widened) window. Served from
    /// the per-render cache; falls back to a fresh compute on a cache miss.
    private func resolvedWindow(_ key: String) -> [(day: String, value: Double)] {
        if let cached = windowCache[key]?.rows { return cached }
        return slice(key, computeEffectiveRange(key))
    }

    private func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func intString(_ v: Double) -> String {
        let n = Int(v.rounded())
        if abs(n) >= 1000 {
            return Self.groupedIntFmt.string(from: NSNumber(value: n)) ?? "\(n)"
        }
        return "\(n)"
    }

    private func durationString(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let h = total / 60, m = total % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// MARK: - Preview seam

extension AppleHealthView {
    /// In-memory bundle that bypasses the store-backed async load for previews.
    fileprivate struct PreviewData {
        var rows: [AppleDaily]
        var workoutCount: Int
        var series: [String: [(day: String, value: Double)]]
    }
}

#if DEBUG
@MainActor
private func appleHealthPreviewData() -> AppleHealthView.PreviewData {
    let cal = Calendar(identifier: .gregorian)
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "UTC")
    fmt.dateFormat = "yyyy-MM-dd"
    let today = Date()

    var rows: [AppleDaily] = []
    var series: [String: [(day: String, value: Double)]] = [
        "steps": [], "active_kcal": [], "vo2max": [],
        "resting_hr": [], "hrv": [], "spo2": [], "resp_rate": [], "asleep_min": [],
        "weight": [], "body_fat": [], "lean_mass": [], "bmi": []
    ]

    // Seed ~2 years so the range control has real depth to window into.
    for i in stride(from: 729, through: 0, by: -1) {
        guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
        let day = fmt.string(from: d)
        let phase = Double(729 - i)
        let steps  = 8000 + 3200 * sin(phase / 6.0) + Double((Int(phase) * 53) % 1800)
        let active = 420 + 180 * sin(phase / 5.0 + 0.6) + Double((Int(phase) * 17) % 90)
        let rhr    = 53 + 4 * sin(phase / 8.0) + Double((Int(phase) * 7) % 4) - 2
        let hrv    = 58 + 16 * sin(phase / 9.0) + Double((Int(phase) * 13) % 11) - 5
        let spo2   = 96 + 1.4 * sin(phase / 4.0) + Double((Int(phase) * 3) % 2)
        let resp   = 14.5 + 1.2 * sin(phase / 7.0)
        let vo2    = 47 + 2.2 * sin(phase / 21.0)
        let asleep = 410 + 55 * sin(phase / 5.0 + 1.1) + Double((Int(phase) * 11) % 30) - 15
        // Slow body-composition drift over the two years (measured WEEKLY → sparse).
        let weight = 78.0 - 5.0 * sin(phase / 220.0) + 0.6 * sin(phase / 13.0)
        let bodyFat = 18.0 - 3.0 * sin(phase / 240.0) + 0.4 * sin(phase / 11.0)
        let lean   = weight * (1.0 - bodyFat / 100.0)
        let bmi    = weight / (1.78 * 1.78)

        rows.append(AppleDaily(
            day: day,
            steps: Int(steps.rounded()),
            activeKcal: max(120, active),
            basalKcal: 1600,
            vo2max: vo2,
            avgHr: 72,
            maxHr: 148,
            walkingHr: 96,
            weightKg: weight))

        series["steps"]?.append((day, max(0, steps)))
        series["active_kcal"]?.append((day, max(80, active)))
        series["vo2max"]?.append((day, vo2))
        series["resting_hr"]?.append((day, max(40, rhr)))
        series["hrv"]?.append((day, max(15, hrv)))
        series["spo2"]?.append((day, min(100, spo2)))
        series["resp_rate"]?.append((day, resp))
        series["asleep_min"]?.append((day, max(180, asleep)))
        // Body composition is logged once a week → deliberately sparse, to exercise
        // the trailing-window → ALL fallback (a W/M view would otherwise be empty).
        if Int(phase) % 7 == 0 {
            series["weight"]?.append((day, weight))
            series["body_fat"]?.append((day, bodyFat))
            series["lean_mass"]?.append((day, lean))
            series["bmi"]?.append((day, bmi))
        }
    }

    return .init(rows: rows, workoutCount: 124, series: series)
}

extension AppleHealthView {
    /// DEBUG screenshot harness: the page on two years of seeded series (the demo store carries Apple
    /// daily rows but no Apple metric series).
    @MainActor static func seededPreview() -> AppleHealthView {
        AppleHealthView(previewData: appleHealthPreviewData())
    }
}

#Preview("Apple Health — seeded") {
    AppleHealthView(previewData: appleHealthPreviewData())
        .environmentObject(Repository(deviceId: "preview"))
        .frame(width: 920, height: 980)
        .preferredColorScheme(.dark)
}

#Preview("Apple Health — empty") {
    AppleHealthView(previewData: .init(rows: [], workoutCount: 0, series: [:]))
        .environmentObject(Repository(deviceId: "preview"))
        .frame(width: 920, height: 600)
        .preferredColorScheme(.dark)
}
#endif
