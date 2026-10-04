import SwiftUI
import StrandDesign
import WhoopStore
import Foundation

// MARK: - Xiaomi Smart Band (Mi Band) — per-source page, v2
//
// A full-bleed sleep-glow hero with the last imported night's hypnogram, ONE range control, the band's
// headline tiles, then two-up sparkline cards per section. Everything reads from the "xiaomi-band"
// source — the data imported from the Mi Fitness app in Data Sources. ALL history is loaded once and
// the range control windows it client-side, RELATIVE TO THE LATEST data point (not "now"); a sparse
// series auto-widens to the smallest range that holds data.

struct XiaomiBandView: View {
    @EnvironmentObject var repo: Repository
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(
            system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
            override: distanceSystemRaw)
    }

    /// Per-source partition key — matches `XiaomiImporter.deviceId`.
    private static let source = "xiaomi-band"

    /// Optional pre-seeded data for previews and the DEBUG screenshot harness; when set, the store
    /// load is skipped. Production leaves it nil.
    private let previewData: PreviewData?

    init() { self.previewData = nil }
    #if DEBUG
    init(previewSeries: [String: [(day: String, value: Double)]], previewSleeps: [CachedSleepSession]) {
        self.previewData = PreviewData(series: previewSeries, sleeps: previewSleeps)
    }
    #endif

    /// In-memory bundle that bypasses the store-backed load.
    private struct PreviewData {
        var series: [String: [(day: String, value: Double)]]
        var sleeps: [CachedSleepSession]
    }

    @State private var loaded = false
    @State private var series: [String: [(day: String, value: Double)]] = [:]
    @State private var range: RangeWindow = .quarter
    @State private var windowCache: [String: ResolvedSeries] = [:]

    /// Imported Mi sleep sessions (carry the per-epoch hypnogram in `stagesJSON`).
    @State private var sleeps: [CachedSleepSession] = []

    private struct ResolvedSeries {
        var effective: RangeWindow
        var rows: [(day: String, value: Double)]
    }

    /// The metricSeries keys written by `XiaomiImporter`.
    private static let seriesKeys = [
        "steps", "distance_m", "energy_kcal", "intensity_min",
        "rhr", "avg_hr", "max_hr", "spo2",
        "sleep_total_min", "sleep_deep_min", "sleep_rem_min", "sleep_light_min", "sleep_score",
        "stress", "vitality",
    ]

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    // Display formatters: the reader's locale (a POSIX locale printed English months in every language),
    // UTC like `dayParser` so a day key never shifts a day west of Greenwich.
    private static let spanFormatter: DateFormatter = {
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: "UTC"); f.setLocalizedDateFormatFromTemplate("dMMMyyyy"); return f
    }()
    private static let asOfFormatter: DateFormatter = {
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: "UTC"); f.setLocalizedDateFormatFromTemplate("dMMM"); return f
    }()
    private static let groupedIntFmt: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return f
    }()

    private func date(_ day: String) -> Date? { Self.dayParser.date(from: day) }

    // MARK: - Range control (W / M / 3M / 6M / 1Y / ALL)

    enum RangeWindow: String, CaseIterable, Identifiable {
        case week, month, quarter, half, year, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .week: return String(localized: "W"); case .month: return String(localized: "M"); case .quarter: return String(localized: "3M")
            case .half: return String(localized: "6M"); case .year: return String(localized: "1Y"); case .all: return String(localized: "ALL")
            }
        }
        var days: Int? {
            switch self {
            case .week: return 7; case .month: return 30; case .quarter: return 90
            case .half: return 180; case .year: return 365; case .all: return nil
            }
        }
        var caption: String {
            switch self {
            case .week: return String(localized: "7 DAYS"); case .month: return String(localized: "30 DAYS"); case .quarter: return String(localized: "90 DAYS")
            case .half: return String(localized: "180 DAYS"); case .year: return String(localized: "365 DAYS"); case .all: return String(localized: "ALL TIME")
            }
        }
        var name: String {
            switch self {
            case .week: return String(localized: "week"); case .month: return String(localized: "month"); case .quarter: return String(localized: "3 months")
            case .half: return String(localized: "6 months"); case .year: return String(localized: "year"); case .all: return String(localized: "all history")
            }
        }
        /// The sentence-case span a section title carries ("90 days", "All time").
        var sectionCaption: String {
            switch self {
            case .week: return String(localized: "7 days"); case .month: return String(localized: "30 days"); case .quarter: return String(localized: "90 days")
            case .half: return String(localized: "180 days"); case .year: return String(localized: "365 days"); case .all: return String(localized: "All time")
            }
        }
        var widening: [RangeWindow] {
            let order: [RangeWindow] = [.week, .month, .quarter, .half, .year, .all]
            guard let i = order.firstIndex(of: self) else { return [.all] }
            return Array(order[i...])
        }
    }

    var body: some View {
        ScreenScaffold(title: nil, onRefresh: { await repo.refresh() }, lazy: loaded && hasAnyData) {
            hero
            if loaded && !hasAnyData {
                emptyNote
            } else if !loaded {
                loadingState
            } else {
                // Flat children (no wrapping VStack) so the scaffold's LazyVStack can defer each
                // off-screen section instead of building every card at once.
                rangeControl
                NoopSectionTitle("From the band", caption: String(localized: "Latest · averages over \(range.name)"))
                SourceCardGrid(items: bandTiles) { tileCard($0) }
                NoopInsightRow("Sleep score, stress and vitality are on Xiaomi's own 0–100 scales, so they are shown here as the band reported them.")
                    .padding(.horizontal, 4)
                    .padding(.top, 10)
                ForEach(trendSections) { section in
                    NoopSectionTitle(section.title, caption: range.sectionCaption)
                    SourceCardGrid(items: section.specs) { trendCard($0) }
                }
                NoopSectionTitle("Mi Band", captionKey: "Via Mi Fitness export")
                NoopList {
                    NoopRow(title: Text("Mi Fitness import"), caption: Text(importCaption), icon: "watch") {
                        EmptyView()
                    }
                }
            }
            footer
        }
        .noopHidesSystemNavBar()
        .task(id: repo.refreshSeq) { await load() }
        .onChangeCompat(of: range) { _ in rebuildWindowCache() }
    }

    // MARK: - Hero (last night's hypnogram)

    /// The sleep-glow hero, run full-bleed under the status bar on iPhone: the header, the
    /// experimental badge, and the most recent imported night that carries a per-epoch hypnogram.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoopScreenHeader("Mi Band")
                .padding(.horizontal, -2)
            NoopPill("Experimental · Mi Fitness import", icon: "flask", compact: true)
                .padding(.top, 18)
            lastNight
        }
        .padding(.horizontal, 22)
        .padding(.top, Self.heroBleeds ? 12 : 22)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            #if os(iOS)
            // The glow runs on up under the status bar (the scroll view's top inset).
            NoopHeroSurface(glow: .sleep, bleed: true)
                .padding(.top, -90)
            #else
            NoopHeroSurface(glow: .sleep)
            #endif
        }
        .environment(\.colorScheme, .dark)
        #if os(iOS)
        // Full-bleed: out to the screen edges and up to the top of the scroll content.
        .padding(.horizontal, -NoopMetrics.screenHPadding)
        .padding(.top, -8)
        #endif
    }

    private static var heroBleeds: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    @ViewBuilder private var lastNight: some View {
        if let night = sleeps.last(where: { ($0.stagesJSON?.count ?? 0) > 2 }),
           let decoded = decodeStages(night.stagesJSON, sessionStart: night.startTs),
           decoded.intervals.count >= 2 {
            let s = decoded.stages
            let start = Date(timeIntervalSince1970: TimeInterval(night.startTs))
            let end = Date(timeIntervalSince1970: TimeInterval(night.endTs))
            NoopIconBadge("Last sleep · Hypnogram", icon: "moon-stars")
                .padding(.top, 26)
            HStack(alignment: .bottom, spacing: 10) {
                NoopDotNumber(Self.clock(s.asleepMin), size: 84)
                VStack(alignment: .leading, spacing: 2) {
                    Text("asleep")
                    Text(verbatim: "\(Self.nightSpanFormatter.string(from: start)) – \(Self.nightSpanFormatter.string(from: end))")
                    Text(nightCaption(night))
                }
                .font(StrandFont.light(13, relativeTo: .footnote))
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.bottom, 8)
            }
            .padding(.top, 20)
            Hypnogram(intervals: decoded.intervals,
                      height: 96,
                      showsStageAxis: true,
                      nightStart: start,
                      showsTimeAxis: true)
                .padding(.top, 20)
            NoopMetricRow {
                NoopMetric(value: Self.clock(s.deep), unit: "h", label: "Deep", labelColor: NoopMetric.heroLabel)
                NoopMetric(value: Self.clock(s.rem), unit: "h", label: "REM", labelColor: NoopMetric.heroLabel)
                NoopMetric(value: Self.clock(s.light), unit: "h", label: "Light", labelColor: NoopMetric.heroLabel)
                NoopMetric(value: Self.clock(s.awake), unit: "h", label: "Awake", labelColor: NoopMetric.heroLabel)
            }
            .padding(.top, 22)
        } else if loaded {
            Text("No imported night carries sleep stages yet. Once one does, its hypnogram shows here.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)
        }
    }

    /// "7h 41m in bed · 92% efficiency" — the old stage card's subtitle, folded into the hero.
    private func nightCaption(_ night: CachedSleepSession) -> String {
        let inBed = durationString(Double(night.endTs - night.startTs) / 60)
        if let eff = night.efficiency {
            return String(localized: "\(inBed) in bed · \(Int(eff.rounded()))% efficiency")
        }
        return String(localized: "\(inBed) in bed")
    }

    /// Minutes as "7:04" (hours:minutes), the way the hero and its stage row read a night.
    private static func clock(_ minutes: Double) -> String {
        let total = max(0, Int(minutes.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static let nightSpanFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        return f
    }()

    // MARK: - Range control

    private var rangeControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            SegmentedPillControl(RangeWindow.allCases, selection: $range, fillsAvailableWidth: true) { $0.label }
            Text(rangeSummaryCaption)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.horizontal, 4)
        }
        .padding(.top, 18)
    }

    private var rangeSummaryCaption: String {
        let anyWidened = Self.seriesKeys.contains { !raw($0).isEmpty && effectiveRange($0) != range }
        let base = range.name
        return anyWidened ? String(localized: "\(base) · some sparse series widened") : base
    }

    /// The import's span across every loaded series ("1 Jan 2024 → 3 Oct 2026"), with the night count.
    private var importCaption: String {
        let allDays = series.values.flatMap { $0 }.map(\.day)
        guard let first = allDays.min(), let last = allDays.max(),
              let lo = date(first), let hi = date(last) else {
            return String(localized: "Steps, heart rate, sleep, SpO₂ and stress, imported from Mi Fitness, read locally on \(Platform.deviceNounPhrase).")
        }
        let loS = Self.spanFormatter.string(from: lo)
        let hiS = Self.spanFormatter.string(from: hi)
        let span = loS == hiS ? loS : "\(loS) → \(hiS)"
        return sleeps.count == 1
            ? String(localized: "1 night · \(span)")
            : String(localized: "\(sleeps.count) nights · \(span)")
    }

    // MARK: - Empty / loading / footer

    private var emptyNote: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                NoopCardHeader("No Mi Band data yet", icon: "watch")
                Text("Nothing imported yet. In Data Sources, choose your Mi Fitness export (a .zip of the Mi Fitness app folder from the Files app) to bring in your steps, heart rate, sleep stages, SpO₂ and stress.")
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 18)
    }

    private var loadingState: some View {
        NoopCard {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .tint(StrandPalette.textSecondary)
                Text("Reading your Mi Band history…")
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 18)
    }

    private var footer: some View {
        Text("Experimental: decoded from your own export file. Values can differ from what the Mi Fitness app shows.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 10)
    }

    private func rebuildWindowCache() {
        var cache: [String: ResolvedSeries] = [:]
        cache.reserveCapacity(Self.seriesKeys.count)
        for key in Self.seriesKeys {
            let eff = computeEffectiveRange(key)
            cache[key] = ResolvedSeries(effective: eff, rows: slice(key, eff))
        }
        windowCache = cache
    }

    private var hasAnyData: Bool { series.values.contains { !$0.isEmpty } }

    // MARK: - Load

    private func load() async {
        if let pd = previewData {
            series = pd.series
            sleeps = pd.sleeps
            rebuildWindowCache()
            loaded = true
            return
        }
        var fetched: [String: [(day: String, value: Double)]] = [:]
        for key in Self.seriesKeys {
            fetched[key] = await repo.series(key: key, source: Self.source)
        }
        var loadedSleeps: [CachedSleepSession] = []
        if let store = await repo.storeHandle() {
            let far = Int(Date.distantFuture.timeIntervalSince1970)
            loadedSleeps = (try? await store.sleepSessions(deviceId: Self.source, from: 0, to: far, limit: 4000)) ?? []
        }
        await MainActor.run {
            series = fetched
            sleeps = loadedSleeps
            rebuildWindowCache()
            loaded = true
        }
    }

    // MARK: - Last sleep decode

    private struct MiStages { var awake = 0.0; var light = 0.0; var deep = 0.0; var rem = 0.0
        var asleepMin: Double { light + deep + rem } }

    /// Reconstruct `[SleepInterval]` (seconds from onset) + stage totals from the verbatim
    /// `[{start,end,stage}]` hypnogram JSON the importer stores. Mirrors `SleepView.decodeSegments`.
    private func decodeStages(_ json: String?, sessionStart: Int) -> (stages: MiStages, intervals: [SleepInterval])? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], !arr.isEmpty
        else { return nil }
        var stages = MiStages()
        var intervals: [SleepInterval] = []
        for seg in arr {
            guard let start = (seg["start"] as? NSNumber)?.intValue,
                  let end = (seg["end"] as? NSNumber)?.intValue, end > start,
                  let name = seg["stage"] as? String else { continue }
            let mins = Double(end - start) / 60.0
            let stage: SleepStage
            switch name {
            case "wake", "awake": stage = .awake; stages.awake += mins
            case "light": stage = .light; stages.light += mins
            case "deep": stage = .deep; stages.deep += mins
            case "rem": stage = .rem; stages.rem += mins
            default: continue
            }
            intervals.append(SleepInterval(stage: stage,
                                           start: TimeInterval(start - sessionStart),
                                           end: TimeInterval(end - sessionStart)))
        }
        return stages.asleepMin > 0 ? (stages, intervals) : nil
    }

    // MARK: - Band tiles + trend sections

    /// How a tile's value is derived from its window.
    private enum Aggregate { case latest, mean }

    /// One "From the band" tile: series key, title, glyph, aggregate, and how the value splits into a
    /// number and a unit.
    private struct TileSpec: Identifiable {
        let key: String
        let title: LocalizedStringKey
        let icon: String
        let aggregate: Aggregate
        let parts: (Double) -> (String, String?)
        var id: String { key }
    }

    private var bandTiles: [TileSpec] {
        let of100 = String(localized: "of 100")
        return [
            TileSpec(key: "steps", title: "Steps", icon: "footprints", aggregate: .latest) { (intString($0), nil) },
            TileSpec(key: "rhr", title: "Resting HR", icon: "heartbeat", aggregate: .latest) { ("\(Int($0.rounded()))", "bpm") },
            TileSpec(key: "sleep_total_min", title: "Sleep avg", icon: "moon", aggregate: .mean) { (durationString($0), nil) },
            TileSpec(key: "sleep_score", title: "Sleep score", icon: "star", aggregate: .latest) { ("\(Int($0.rounded()))", of100) },
            TileSpec(key: "spo2", title: "Blood oxygen", icon: "drop", aggregate: .latest) { (String(format: "%.0f", $0), "%") },
            TileSpec(key: "stress", title: "Stress avg", icon: "wave-sine", aggregate: .mean) { ("\(Int($0.rounded()))", of100) },
            TileSpec(key: "avg_hr", title: "Avg HR", icon: "heart", aggregate: .mean) { ("\(Int($0.rounded()))", "bpm") },
            TileSpec(key: "vitality", title: "Vitality", icon: "heart-half", aggregate: .latest) { ("\(Int($0.rounded()))", of100) },
        ]
    }

    /// A band tile. Sparse-safe: the window auto-widens (see `resolvedWindow`); a latest value says
    /// "as of <date>", a mean says how many days it averages.
    private func tileCard(_ spec: TileSpec) -> some View {
        let rows = resolvedWindow(spec.key)
        let values = rows.map(\.value)
        var number = "—"
        var unit: String?
        var caption = String(localized: "No readings recorded.")
        if let last = values.last {
            switch spec.aggregate {
            case .latest:
                (number, unit) = spec.parts(last)
                caption = rows.last.flatMap { date($0.day) }
                    .map { String(localized: "as of \(Self.asOfFormatter.string(from: $0))") } ?? ""
            case .mean:
                (number, unit) = spec.parts(mean(values) ?? last)
                caption = String(localized: "avg · \(values.count)d")
            }
        }
        return SourceMetricCard(title: spec.title, icon: spec.icon, number: number, unit: unit, caption: caption)
    }

    /// One sparkline card's recipe.
    private struct TrendSpec: Identifiable {
        let key: String
        let title: LocalizedStringKey
        let icon: String
        let parts: (Double) -> (String, String?)
        var id: String { key }
    }

    private struct TrendSection: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let specs: [TrendSpec]
    }

    /// Every series the importer writes, grouped as the old chart sections were.
    private var trendSections: [TrendSection] {
        let bpm: (Double) -> (String, String?) = { ("\(Int($0.rounded()))", "bpm") }
        return [
            TrendSection(id: "heart", title: "Heart & vitals", specs: [
                TrendSpec(key: "rhr", title: "Resting heart rate", icon: "heartbeat", parts: bpm),
                TrendSpec(key: "avg_hr", title: "Average heart rate", icon: "heart", parts: bpm),
                TrendSpec(key: "max_hr", title: "Peak heart rate", icon: "chart-line-up", parts: bpm),
                TrendSpec(key: "spo2", title: "Blood oxygen", icon: "drop") { (String(format: "%.0f", $0), "%") },
            ]),
            TrendSection(id: "sleep", title: "Sleep", specs: [
                TrendSpec(key: "sleep_total_min", title: "Time asleep", icon: "moon-stars") { (durationString($0), nil) },
                TrendSpec(key: "sleep_deep_min", title: "Deep sleep", icon: "moon") { (durationString($0), nil) },
                TrendSpec(key: "sleep_rem_min", title: "REM sleep", icon: "eye") { (durationString($0), nil) },
                TrendSpec(key: "sleep_score", title: "Sleep score", icon: "star") { ("\(Int($0.rounded()))", nil) },
            ]),
            TrendSection(id: "activity", title: "Activity & energy", specs: [
                TrendSpec(key: "steps", title: "Steps", icon: "footprints") { (intString($0), nil) },
                TrendSpec(key: "distance_m", title: "Distance", icon: "path") {
                    Self.splitUnit(UnitFormatter.distanceFromMeters($0, system: distanceUnitSystem))
                },
                TrendSpec(key: "energy_kcal", title: "Active energy", icon: "fire") { (intString($0), "kcal") },
                TrendSpec(key: "intensity_min", title: "Intensity minutes", icon: "timer") { ("\(Int($0.rounded()))", "min") },
            ]),
            TrendSection(id: "wellbeing", title: "Wellbeing", specs: [
                TrendSpec(key: "stress", title: "Stress", icon: "wave-sine") { ("\(Int($0.rounded()))", nil) },
                TrendSpec(key: "vitality", title: "Vitality", icon: "heart-half") { ("\(Int($0.rounded()))", nil) },
            ]),
        ]
    }

    /// One sparkline card: the latest reading, the resolved window's line, and its average and range
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

    /// "5.2 km" → ("5.2", "km"); a string without a space comes back whole.
    private static func splitUnit(_ s: String) -> (String, String?) {
        guard let space = s.lastIndex(of: " ") else { return (s, nil) }
        return (String(s[..<space]), String(s[s.index(after: space)...]))
    }

    // MARK: - Series helpers (sparse-data fallback to ALL)

    private func raw(_ key: String) -> [(day: String, value: Double)] { series[key] ?? [] }

    private func latestDate(_ key: String) -> Date? {
        guard let d = raw(key).last?.day else { return nil }
        return date(d)
    }

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

    private func effectiveRange(_ key: String) -> RangeWindow {
        windowCache[key]?.effective ?? computeEffectiveRange(key)
    }

    private func computeEffectiveRange(_ key: String) -> RangeWindow {
        guard !raw(key).isEmpty else { return range }
        for r in range.widening where !slice(key, r).isEmpty { return r }
        return .all
    }

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
        if abs(n) >= 1000 { return Self.groupedIntFmt.string(from: NSNumber(value: n)) ?? "\(n)" }
        return "\(n)"
    }

    private func durationString(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let h = total / 60, m = total % 60
        return h > 0 ? String(localized: "\(h)h \(m)m") : String(localized: "\(m)m")
    }
}
