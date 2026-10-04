import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Trends
//
// The longitudinal view in the v2 kit: the week recap and its per-day grid, one range control, a Charge
// hero over the selected window, the daily signals as sparkline rows, training load, and a year of Charge
// as a heat calendar. One glow (the Charge hero); every other surface is a neutral card.

struct TrendsView: View {
    @EnvironmentObject var repo: Repository
    // NOTE: deliberately does NOT observe LiveState — Trends shows historical data only, and
    // observing it forced a full re-render of this subtree on every ~1 Hz live-HR tick.

    // The shared range control: W(7) / M(30) / 3M(90) / 6M(180) / 1Y(365) / ALL.
    enum Range: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 90, half = 180, year = 365, all = 0
        var id: Int { rawValue }
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
        /// Trailing-day window, or nil for "all history".
        var days: Int? { self == .all ? nil : rawValue }

        /// This range plus every LARGER range, ascending — the auto-expand search
        /// order when the selected window holds zero points.
        var widening: [Range] {
            let order: [Range] = [.week, .month, .quarter, .half, .year, .all]
            guard let i = order.firstIndex(of: self) else { return [.all] }
            return Array(order[i...])
        }
    }

    @State private var range: Range = .quarter

    // #436 — shareable offline trends report (PDF over a date range). The sheet owns its
    // own range picker; this just presents it with the loaded history.
    @State private var showingReport = false
    /// Current appearance, passed into the off-screen recap render so the shared PNG matches the app.
    @Environment(\.colorScheme) private var colorScheme

    /// Rest's per-day series, keyed by "yyyy-MM-dd". Rest is the sleep_performance COMPOSITE (the same
    /// number the Today Rest score + the Sleep Rest-detail plot, #614 follow-up) — NOT raw efficiency,
    /// which read differently under the same "Rest" label and made the Trends Rest graph disagree with
    /// the Today Rest score (#732). sleep_performance is a metricSeries, not a DailyMetric field, so load
    /// it once (mirroring TodayView's restScore source) and key by day for `resolve` below.
    @State private var sleepPerfByDay: [String: Double] = [:]

    // #710 — browse previous weeks in the Week-in-review digest. 0 = the week containing today; each step
    // back is one Mon–Sun week earlier. Clamped so it never runs past the earliest day we hold (see
    // `weekAnchorDay` / `stepWeek`). The Trends RANGE control below is independent of this — it scopes the
    // long-form charts; this only moves the weekly digest at the top.
    @State private var weekOffset = 0

    /// Measured width of the heat calendar, so a year of week columns fits the card exactly.
    @State private var heatWidth: CGFloat = 314

    /// The history-wide derivations `body` reads, kept between passes (see `TrendsMemo`). A reference
    /// held in `@State`, so filling it during `body` invalidates nothing.
    @State private var memo = TrendsMemo()

    // Effort display scale (#268) — routes the Effort small-multiple's numbers + unit. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    // Trend chart style (line vs bar) — display-only; flips every trend card between the gradient line
    // and value-ramp bars. Read here at the screen root so a Settings change re-renders on return.
    @AppStorage(UnitPrefs.trendChartStyleKey) private var trendChartStyleRaw = TrendChartStyle.line.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    // yyyy-MM-dd → Date (en_US_POSIX, UTC), per task spec.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private func date(_ day: String) -> Date? { Self.dayParser.date(from: day) }

    // MARK: Window selection (relative to the LATEST day, with auto-expand)

    /// Days for a given range, taken RELATIVE TO TODAY (the phone's local date) — not the latest
    /// recorded day, which on a stale import anchored W/M/3M to months-old data so it looked current
    /// (issue #23). Empty short windows auto-widen (see `resolve`), so old imports surface under a
    /// wider range / All history instead of masquerading as recent. `.all` returns everything.
    /// ISO yyyy-MM-dd compares chronologically.

    // MARK: Resolved metric (memoized per body)
    //
    // days(for:) / points each re-filter the full multi-year `repo.days` array,
    // and the subviews used to fan out to them many times per render (caption +
    // widened + windowPoints, ×4 metrics). `resolve(_:)` walks the widening order
    // ONCE per metric (the smallest range ≥ selected whose window holds ≥1 point,
    // else ALL), captures that window's points and its effective range, then
    // derives the caption / widened flag from those — so a single body evaluation
    // filters each metric's window once instead of dozens of times. Identical
    // results to the old per-helper (effectiveRange / windowPoints / caption /
    // widened) computation.
    private struct ResolvedMetric {
        var points: [TrendPoint]
        var effective: Range
        var widened: Bool
        var caption: String
    }

    /// The identity of the history every memoized derivation reads. `repo.days` is only reassigned by
    /// `Repository.refresh`, which bumps `refreshSeq` in the same main-actor turn, so (repository,
    /// refreshSeq) moves whenever the rows do. The count also covers a direct assignment (the previews).
    private var daysToken: TrendsDaysToken {
        TrendsDaysToken(repo: ObjectIdentifier(repo), refreshSeq: repo.refreshSeq, count: repo.days.count)
    }

    private func resolve(_ slot: TrendsMemo.Slot, _ value: (DailyMetric) -> Double?) -> ResolvedMetric {
        // Find the smallest range ≥ selected whose window has ≥1 point, keeping
        // that window's points so we don't re-filter to read them back.
        // The windowing lives in `HostedTrendData` so the Today host cards resolve EXACTLY as this tab
        // does. Shared rather than copied: the widening fallback is what a wearer with two weeks of
        // history depends on, and a second implementation would drift the moment either side was tuned.
        // Memoized per (data, range, local day): the window is anchored on today's local day and the
        // points parse every day string in it, so this only runs again when one of those changes.
        let selected = range
        let r = memo.value(slot, key: [daysToken, selected, Repository.localDayKey(Date())] as [AnyHashable]) {
            TrendsResolvedWindow(HostedTrendData.resolve(days: repo.days, selected: selected, value: value))
        }
        return ResolvedMetric(points: r.points, effective: r.effective,
                              widened: r.effective != range,
                              caption: caption(count: r.points.count, eff: r.effective))
    }

    /// Caption text from an already-resolved count + effective range. Mirrors
    /// `caption(_:)` exactly but takes precomputed inputs to avoid re-filtering.
    private func caption(count n: Int, eff: Range) -> String {
        if eff != range {
            return n == 1
                ? String(localized: "1 reading · sparse, widened to \(name(for: eff))")
                : String(localized: "\(n) readings · sparse, widened to \(name(for: eff))")
        }
        return n == 1
            ? String(localized: "1 reading · \(name(for: range))")
            : String(localized: "\(n) readings · \(name(for: range))")
    }

    /// A padded value range for a series so the line isn't flat against the axis.
    private func valueRange(_ pts: [TrendPoint], fallback: ClosedRange<Double>, pad: Double = 0.12) -> ClosedRange<Double> {
        HostedTrendData.valueRange(pts, fallback: fallback, pad: pad)
    }

    private func mean(_ pts: [TrendPoint]) -> Double? {
        guard !pts.isEmpty else { return nil }
        return pts.map(\.value).reduce(0, +) / Double(pts.count)
    }

    private func name(for r: Range) -> String {
        switch r {
        case .week:    return String(localized: "week")
        case .month:   return String(localized: "month")
        case .quarter: return String(localized: "3 months")
        case .half:    return String(localized: "6 months")
        case .year:    return String(localized: "year")
        case .all:     return String(localized: "all history")
        }
    }

    var body: some View {
        // The metric rows and the hero tap through to their MetricDetailView. On iOS each tab already
        // supplies a NavigationStack, so those pushes land in the ambient stack. On macOS the .trends detail
        // pane has NO enclosing NavigationStack (RootView), so — exactly like MetricExplorerView (#753) —
        // wrap the scaffold in one here so the pushes get Back chrome instead of hanging.
        #if os(macOS)
        // Register the value routes at THIS stack's root; on iOS the tab shell's stack registers
        // them instead (once per stack — a double registration double-pushes, #38).
        NavigationStack { scaffold.tabRouteDestinations() }
        #else
        scaffold
        #endif
    }

    private var scaffold: some View {
        // PERF (scroll): lazy column, every section a direct child so only the visible ones are built.
        ScreenScaffold(title: "Trends", subtitle: "The thread of you over time.",
                       onRefresh: { await repo.refresh() },
                       lazy: true) {
            if repo.days.isEmpty {
                ComingSoon(what: repo.loaded
                    ? "Trends need history to draw. Import your WHOOP export in Data Sources to see weeks, months and years instantly."
                    : "Loading your history…")
            } else {
                // Resolve each metric's window ONCE per body and pass the results down, instead of
                // re-filtering repo.days in every section on every render.
                let recovery = resolve(.recovery) { $0.recovery }
                let hrv = resolve(.hrv) { $0.avgHrv }
                let rhr = resolve(.rhr) { $0.restingHr.map(Double.init) }
                let strain = resolve(.strain) { $0.strain }
                // Week-in-review recap (#208) with prev/next week browsing (#710).
                weeklyDigestCard
                weekGridCard
                NoopSectionTitle("Over time", caption: windowLabel(recovery.effective))
                rangeControl(recovery)
                chargeHero(recovery)
                NoopSectionTitle("Daily signals", caption: signalsCaption(hrv.effective))
                signalsCard(hrv: hrv, rhr: rhr, strain: strain)
                // Long-horizon training load (CTL/ATL/TSB). Uses the FULL history, not the range window —
                // chronic load is inherently a 42-day horizon.
                NoopSectionTitle("Training load", captionKey: "Last 42 days")
                TrainingLoadCard(days: repo.days)
                yearSection
                exportReportRow
                    .padding(.top, 10)
                historyFooter
            }
        }
        // #436 — present the offline trends-report exporter (range picker + PDF export).
        .sheet(isPresented: $showingReport) {
            TrendsReportSheet(days: repo.days)
        }
        // #732 — load the resolved sleep_performance series so Rest shows the SAME composite the Today
        // Rest score uses (not raw efficiency). Keyed on the day count so a newly-scored night refreshes.
        .task(id: repo.days.count) {
            let s = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
            sleepPerfByDay = Dictionary(s.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        }
    }

    // MARK: Week-in-review recap with prev/next week browsing (#710)

    /// The earliest "yyyy-MM-dd" we hold (history is oldest → newest), used to clamp how far back the
    /// week stepper can go.
    private var earliestDay: String? { repo.days.first?.day }

    /// The most negative `weekOffset` allowed: the number of whole weeks between the earliest day's week
    /// and this week. Beyond that there's no data to digest, so the back chevron disables. 0 when history
    /// is empty or unparseable (so we stay on this week).
    private var minWeekOffset: Int {
        // Memoized per (earliest day, today): the walk below formats one day string per week of history,
        // and the pager reads this on every body pass.
        let earliest = earliestDay
        let today = Repository.localDayKey(Date())
        return memo.value(.minWeekOffset, key: [earliest, today] as [AnyHashable]) {
            Self.computeMinWeekOffset(earliest: earliest, today: today)
        }
    }

    /// The walk behind `minWeekOffset`. Internal (not private) so StrandTests can pin it against the
    /// pre-memo computation.
    static func computeMinWeekOffset(earliest: String?, today: String) -> Int {
        guard
            let earliest,
            let earliestMon = WeeklyDigestEngine.mondayOfWeek(containing: earliest),
            let thisMon = WeeklyDigestEngine.mondayOfWeek(containing: today)
        else { return 0 }
        // Walk weeks back from this Monday until we pass the earliest week. Bounded by history length.
        var off = 0
        var mon = thisMon
        while mon > earliestMon && off > -520 {           // hard cap ~10 years so a bad date can't spin
            mon = WeeklyDigestEngine.addDays(mon, -7)
            off -= 1
        }
        return off
    }

    /// The anchor day (any day in the target week) for the current `weekOffset`: today shifted back by
    /// `weekOffset` whole weeks. The engine snaps it to that week's Monday.
    private var weekAnchorDay: String {
        WeeklyDigestEngine.addDays(Repository.localDayKey(Date()), weekOffset * 7)
    }

    /// Move the digest one week earlier (-1) or later (+1), clamped to [minWeekOffset, 0] — never into a
    /// future week, never past the earliest week we hold.
    private func stepWeek(_ delta: Int) {
        let next = weekOffset + delta
        weekOffset = max(minWeekOffset, min(0, next))
    }

    /// The recap for the selected week, built straight from the shared `WeeklyDigestSource` (the same
    /// builder the standalone digest uses) so past weeks render in the identical format. An empty PAST
    /// week still shows the pager so the wearer can step to a week that does hold data.
    private var weeklyDigestCard: some View {
        // Memoized per (data, week, Effort scale): the digest walks the whole history and recomputes the
        // Rest composite for every day. The scale factor is read here, as the default argument read it.
        let anchor = weekAnchorDay
        let factor = UnitPrefs.currentEffortDisplayFactor()
        let digest = memo.value(.digest, key: [daysToken, anchor, factor] as [AnyHashable]) {
            WeeklyDigestSource.digest(from: repo.days, anchorDay: anchor, effortDisplayFactor: factor)
        }
        return NoopCard {
            VStack(alignment: .leading, spacing: 0) {
                // Longer languages do not fit the pager, the day count and the labelled share chip on one
                // line; the share action then folds to its icon so neither label is cut.
                ViewThatFits(in: .horizontal) {
                    recapHeaderRow(digest, iconOnlyShare: false)
                    recapHeaderRow(digest, iconOnlyShare: true)
                }
                Text("\(weeklyDigestRangeLabel(digest)) · weekly means vs last week")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.top, 4)
                if digest.isEmpty {
                    // This particular week had no readings — keep the pager above so the wearer can move on.
                    NoopInsightRow("No readings this week. Step to another week with the arrows above.", icon: "info")
                        .padding(.top, 14)
                } else {
                    WeeklyDigestLines(digest: digest, compact: true)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func recapHeaderRow(_ digest: WeeklyDigest, iconOnlyShare: Bool) -> some View {
        HStack(spacing: 8) {
            weekPager
            Text("\(digest.daysWithData)/7 days")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize()
                .padding(.leading, 4)
                .accessibilityLabel(Text("\(digest.daysWithData) of 7 days had data"))
            Spacer(minLength: 8)
            if !digest.isEmpty {
                // Share this week's recap as an image: the recap rendered off-screen to a PNG and
                // handed to the share sheet / Save panel (TrendsReport's ImageRenderer path).
                Button { shareRecap(digest) } label: {
                    if iconOnlyShare {
                        PhIcon("share-network", size: 14)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(NoopVisualStyle.inset))
                            .overlay(Circle().strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                            .contentShape(Rectangle().inset(by: -7))
                    } else {
                        NoopChip("Share recap", icon: "share-network").fixedSize()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Share recap"))
            }
        }
    }

    private func shareRecap(_ digest: WeeklyDigest) {
        let page = WeeklyDigestContent(digest: digest, compact: true, showsHeader: true)
            .frame(width: 380)
            .padding(24)
            .background(StrandPalette.surfaceBase)
            .environment(\.colorScheme, colorScheme)
        TrendsReportRenderer.exportPNG(page: page, suggestedName: "noop-recap-\(weekAnchorDay).png")
    }

    /// ‹ This week › — back is clamped at the earliest week we hold, forward at this week.
    private var weekPager: some View {
        let atOldest = weekOffset <= minWeekOffset
        let atNewest = weekOffset >= 0
        return HStack(spacing: 6) {
            Button { stepWeek(-1) } label: {
                // The glyph keeps its 16 pt lane; the hit area grows to a thumb-sized 40 × 44.
                PhIcon("caret-left", size: 16).frame(width: 16, height: 30)
                    .contentShape(Rectangle().inset(by: -12))
            }
            .buttonStyle(.plain)
            .disabled(atOldest)
            .opacity(atOldest ? 0.25 : 0.8)
            .accessibilityLabel("Previous week")
            Text(weekOffset == 0 ? String(localized: "This week") : weekOffsetLabel)
                .font(StrandFont.book(15, relativeTo: .body))
                .lineLimit(1)
                .fixedSize()
            Button { stepWeek(1) } label: {
                PhIcon("caret-right", size: 16).frame(width: 16, height: 30)
                    .contentShape(Rectangle().inset(by: -12))
            }
            .buttonStyle(.plain)
            .disabled(atNewest)
            .opacity(atNewest ? 0.25 : 0.8)
            .accessibilityLabel("Next week")
        }
        .foregroundStyle(StrandPalette.textPrimary)
    }

    /// "Last week" for -1, else the count of weeks back ("3 weeks ago") for the pager label.
    private var weekOffsetLabel: String {
        let n = -weekOffset
        if n == 1 { return String(localized: "Last week") }
        return String(localized: "\(n) weeks ago")
    }

    // MARK: Week in review — Charge / Effort / Rest per day

    /// Monday-first short weekday names in the app language.
    private var weekdaySymbols: [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = AppLanguage.activeLocale
        let s = cal.shortWeekdaySymbols
        return Array(s[1...]) + [s[0]]
    }

    /// The selected week's three daily scores as a brightness grid: Charge (recovery), Effort (on the
    /// wearer's display scale, #268) and Rest (the sleep_performance composite, #732).
    private var weekGridCard: some View {
        let monday = WeeklyDigestEngine.mondayOfWeek(containing: weekAnchorDay) ?? weekAnchorDay
        let keys = (0..<7).map { WeeklyDigestEngine.addDays(monday, $0) }
        let today = Repository.localDayKey(Date())
        // Memoized per (data, week): the filter walks the whole history for seven rows.
        let byDay = memo.value(.weekDays, key: [daysToken, keys[0]] as [AnyHashable]) {
            Dictionary(repo.days.filter { $0.day >= keys[0] && $0.day <= keys[6] }.map { ($0.day, $0) },
                       uniquingKeysWith: { _, last in last })
        }
        func row(_ label: String, _ value: (String) -> Double?, _ text: (Double) -> String) -> TrendsWeekRow {
            TrendsWeekRow(label: label, cells: keys.map { k in
                let v = k <= today ? value(k) : nil
                return TrendsWeekCell(text: v.map(text), level: v.map { $0 / 100 }, isToday: k == today)
            })
        }
        let whole = { (v: Double) in "\(Int(v.rounded()))" }
        let rows = [
            row(String(localized: "Charge"), { byDay[$0]?.recovery }, whole),
            row(String(localized: "Effort"), { byDay[$0]?.strain }, { UnitFormatter.effortDisplay($0, scale: effortScale) }),
            row(String(localized: "Rest"), { sleepPerfByDay[$0] }, whole),
        ]
        return NoopCard {
            VStack(alignment: .leading, spacing: 0) {
                NoopCardHeader("Week in review", captionKey: "Charge · Effort · Rest")
                    .padding(.bottom, 12)
                TrendsWeekGrid(weekdayLabels: weekdaySymbols, todayIndex: keys.firstIndex(of: today), rows: rows)
                Text("Brighter = higher. Today counts once the day closes.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.top, 12)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Range control

    /// "4 Sep – 3 Oct" for the trailing window ending today, or the whole span for all history.
    private func windowLabel(_ r: Range) -> String {
        let today = Repository.localDayKey(Date())
        if let n = r.days {
            return TrendsDayFormat.range(WeeklyDigestEngine.addDays(today, -(n - 1)), today)
        }
        guard let first = repo.days.first?.day, let a = TrendsDayFormat.date(first),
              let b = TrendsDayFormat.date(today) else { return String(localized: "All history") }
        return "\(TrendsDayFormat.monthYear(a)) – \(TrendsDayFormat.monthYear(b))"
    }

    private func rangeControl(_ recovery: ResolvedMetric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SegmentedPillControl(Range.allCases, selection: $range, fillsAvailableWidth: true) { $0.label }
            // A sparse window auto-widens (#23); say so, since the charts below then cover a longer span.
            if recovery.widened {
                Text(recovery.caption)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    // MARK: Charge hero

    /// "30-day average" / "All-time average" for the hero's window pill.
    private func averageLabel(_ r: Range) -> String {
        guard let n = r.days else { return String(localized: "All-time average") }
        return String(localized: "\(n)-day average")
    }

    /// The window mean against the equally long window before it: "Up 5 on the previous 30 days".
    /// nil for all history (there is no earlier window) or when the earlier window holds no Charge.
    private func comparisonLine(_ r: Range, mean avg: Double?) -> String? {
        guard let n = r.days, let avg else { return nil }
        let today = Repository.localDayKey(Date())
        // The earlier window's mean, memoized per (data, window, local day): it filters the whole history.
        let prevMean: Double? = memo.value(.comparison, key: [daysToken, n, today] as [AnyHashable]) {
            let end = WeeklyDigestEngine.addDays(today, -n)
            let start = WeeklyDigestEngine.addDays(today, -(2 * n - 1))
            let prev = repo.days.filter { $0.day >= start && $0.day <= end }.compactMap(\.recovery)
            guard !prev.isEmpty else { return nil }
            return prev.reduce(0, +) / Double(prev.count)
        }
        guard let prevMean else { return nil }
        let d = Int((avg - prevMean).rounded())
        if d > 0 { return String(localized: "Up \(d) on the previous \(n) days.") }
        if d < 0 { return String(localized: "Down \(abs(d)) on the previous \(n) days.") }
        return String(localized: "Level with the previous \(n) days.")
    }

    /// The longest run of consecutive days at PRIMED or better (≥ 70) inside the window, as point indices.
    private func peakRun(_ pts: [TrendPoint]) -> ClosedRange<Int>? {
        var best: ClosedRange<Int>?
        var start: Int?
        for i in pts.indices {
            let ok = pts[i].value >= 70
            let contiguous = i > 0 && pts[i].date.timeIntervalSince(pts[i - 1].date) <= 86_400 * 1.5
            if ok {
                if start == nil || !contiguous { start = i }
                if let s = start, (best?.count ?? 0) < i - s + 1 { best = s...i }
            } else {
                start = nil
            }
        }
        return (best?.count ?? 0) >= 3 ? best : nil
    }

    /// Axis captions under the hero chart: the window start, three evenly spaced dates and the latest day.
    private func heroXLabels(_ pts: [TrendPoint], _ r: Range) -> [(Double, String)] {
        guard pts.count > 1, let first = pts.first, let last = pts.last else { return [] }
        let spanDays = last.date.timeIntervalSince(first.date) / 86_400
        let mid: (Date) -> String = spanDays <= 31 ? TrendsDayFormat.dayOfMonth
            : (spanDays <= 200 ? TrendsDayFormat.dayMonth : TrendsDayFormat.month)
        var out: [(Double, String)] = [(0, spanDays <= 200 ? TrendsDayFormat.dayMonth(first.date) : TrendsDayFormat.monthYear(first.date))]
        for f in [0.25, 0.5, 0.75] {
            out.append((f, mid(pts[Int((Double(pts.count - 1) * f).rounded())].date)))
        }
        let isToday = TrendsDayFormat.date(Repository.localDayKey(Date())) == last.date
        out.append((1, isToday ? String(localized: "Today") : TrendsDayFormat.dayMonth(last.date)))
        return out
    }

    private func chargeHero(_ recovery: ResolvedMetric) -> some View {
        let pts = recovery.points
        let avg = mean(pts)
        // Tap the hero to open the full Charge (recovery) metric detail, like Today's card taps.
        return NavigationLink(value: TabRoute.metric("recovery")) {
            NoopHeroCard(glow: NoopGlow.charge(avg)) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        NoopIconBadge("Charge", icon: "lightning")
                        Spacer(minLength: 8)
                        NoopPill(verbatim: averageLabel(recovery.effective), compact: true)
                    }
                    // The tag stands on the digits' baseline, as in the frame.
                    HStack(alignment: .lastTextBaseline, spacing: 10) {
                        NoopDotNumber(avg.map { "\(Int($0.rounded()))" } ?? "—", unit: avg == nil ? nil : "%",
                                      size: 88, unitSize: 38)
                        Spacer(minLength: 8)
                        if let avg {
                            NoopTag(verbatim: StrandPalette.recoveryState(avg)).fixedSize()
                                .alignmentGuide(.lastTextBaseline) { $0[.bottom] }
                        }
                    }
                    .padding(.top, 22)
                    if let line = comparisonLine(recovery.effective, mean: avg) {
                        Text(verbatim: line)
                            .font(StrandFont.light(17, relativeTo: .headline))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 14)
                    }
                    heroChart(pts, mean: avg, range: recovery.effective)
                        .padding(.top, 14)
                    heroStats(pts)
                        .padding(.top, 16)
                }
                .multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityHint(Text(String(localized: "Opens the full Charge metric.")))
    }

    @ViewBuilder
    private func heroChart(_ pts: [TrendPoint], mean avg: Double?, range r: Range) -> some View {
        if pts.count >= 2 {
            let values = pts.map(\.value)
            let lo = max(0, (((values.min() ?? 0) - 5) / 10).rounded(.down) * 10)
            let hi = min(100, (((values.max() ?? 100) + 5) / 10).rounded(.up) * 10)
            let run = peakRun(pts)
            let n = Double(pts.count - 1)
            TrendsHeroChart(
                values: values, range: lo...max(hi, lo + 10), mean: avg,
                highlight: run.map { Double($0.lowerBound) / n...Double($0.upperBound) / n },
                highlightLabel: run.map { Text("Peak run · \($0.count) days") },
                bars: TrendChartStyle(rawValue: trendChartStyleRaw) == .bar,
                xLabels: heroXLabels(pts, r))
            .accessibilityElement()
            .accessibilityLabel(Text(String(localized: "Charge trend")))
        } else {
            Text("Not enough data for this window.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private func heroStats(_ pts: [TrendPoint]) -> some View {
        let hi = pts.max { $0.value < $1.value }
        let lo = pts.min { $0.value < $1.value }
        let primed = pts.filter { $0.value >= 70 }.count
        return HStack(alignment: .top, spacing: 0) {
            TrendsHeroStat(value: hi.map { "\(Int($0.value.rounded()))" } ?? "—", unit: hi == nil ? nil : "%",
                           caption: hi.map { String(localized: "High · \(TrendsDayFormat.dayMonth($0.date))") } ?? String(localized: "High"))
            TrendsHeroStat(value: lo.map { "\(Int($0.value.rounded()))" } ?? "—", unit: lo == nil ? nil : "%",
                           caption: lo.map { String(localized: "Low · \(TrendsDayFormat.dayMonth($0.date))") } ?? String(localized: "Low"))
            TrendsHeroStat(value: "\(primed)", unit: String(localized: "of \(pts.count)"),
                           caption: String(localized: "Days primed or better"))
        }
    }

    // MARK: Daily signals — HRV / Resting HR / Effort

    private func signalsCaption(_ r: Range) -> String {
        guard let n = r.days else { return String(localized: "All history · vs baseline") }
        return String(localized: "\(n) days · vs baseline")
    }

    private func signalsCard(hrv: ResolvedMetric, rhr: ResolvedMetric, strain: ResolvedMetric) -> some View {
        let whole = { (v: Double) in "\(Int(v.rounded()))" }
        return NoopCard {
            VStack(spacing: 0) {
                signalRow(key: "hrv", title: String(localized: "Heart rate variability"), m: hrv, unit: "ms",
                          fmt: whole, isFirst: true)
                signalRow(key: "rhr", title: String(localized: "Resting heart rate"), m: rhr, unit: "bpm",
                          fmt: whole, isFirst: false)
                // Points stay on the stored 0–100 scale; only the printed numbers follow the Effort toggle (#268).
                signalRow(key: "strain", title: String(localized: "Effort"), m: strain,
                          unit: String(localized: "of \(UnitFormatter.effortScaleMax(effortScale))"),
                          fmt: { UnitFormatter.effortDisplay($0, scale: effortScale) }, isFirst: false,
                          isAccumulating: true)
            }
            .padding(.bottom, -10)
        }
    }

    /// One daily signal: the latest reading against the window mean, with its sparkline. Taps through to
    /// the metric's full detail.
    private func signalRow(key: String, title: String, m: ResolvedMetric, unit: String,
                           fmt: @escaping (Double) -> String, isFirst: Bool,
                           isAccumulating: Bool = false) -> some View {
        let pts = m.points
        let avg = mean(pts)
        let latest = pts.last
        let caption: String = {
            guard let latest, let avg else { return String(localized: "No readings in this window") }
            if isAccumulating {
                let isToday = TrendsDayFormat.date(Repository.localDayKey(Date())) == latest.date
                return isToday ? String(localized: "Today so far · avg \(fmt(avg))") : String(localized: "Latest · avg \(fmt(avg))")
            }
            let d = Int((latest.value - avg).rounded())
            let signed = d > 0 ? "+\(d)" : (d < 0 ? "−\(abs(d))" : "±0")
            return String(localized: "Base \(fmt(avg)) · \(signed)")
        }()
        return NavigationLink(value: TabRoute.metric(key)) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: title)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(verbatim: latest.map { fmt($0.value) } ?? "—")
                            .font(StrandFont.value(24, weight: 300))
                            .tracking(-0.5)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(verbatim: unit).font(StrandFont.book(10)).foregroundStyle(StrandPalette.textSecondary)
                    }
                    .lineLimit(1)
                    .padding(.top, 6)
                    Text(verbatim: caption)
                        .font(StrandFont.light(10.5))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(2)
                        .padding(.top, 3)
                }
                .frame(width: 104, alignment: .leading)
                if pts.count >= 2 {
                    TrendsSignalSparkline(values: pts.map(\.value), baseline: avg)
                } else {
                    Text("Not enough data for this window.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
            }
            .padding(.top, isFirst ? 4 : 14)
            .padding(.bottom, 14)
            .overlay(alignment: .top) {
                if !isFirst { Rectangle().fill(NoopVisualStyle.border).frame(height: 1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(String(localized: "Opens the full \(title) metric.")))
    }

    // MARK: Charge · past year

    /// The heat calendar's cell size: fitted so a year spans the card, fixed (and scrolled) beyond that.
    private func heatCell(weeks: Int) -> CGFloat {
        let fitted = (heatWidth - CGFloat(max(weeks - 1, 0))) / CGFloat(max(weeks, 1))
        return max(4, min(12, fitted))
    }

    @ViewBuilder
    private var yearSection: some View {
        // Always show at least a full year for context; expand to all history on ALL.
        let stripDays = max(range.days ?? repo.days.count, 365)
        // Memoized per (data, strip length): parsing 365-4000 day strings and grouping them by month ran
        // on every body pass, the "lazy" column notwithstanding, since this section is built eagerly.
        let year = memo.value(.year, key: [daysToken, stripDays] as [AnyHashable]) { () -> TrendsYearData in
            let recent = repo.days.suffix(stripDays)
            let recoveryDays: [RecoveryDay] = recent.compactMap { d in
                guard let dt = date(d.day) else { return nil }
                return RecoveryDay(date: dt, score: d.recovery)
            }
            return TrendsYearData(recoveryDays: recoveryDays, months: Self.strongestAndWeakestMonths(recent))
        }
        let recoveryDays = year.recoveryDays
        let span: String? = {
            guard let a = recoveryDays.first?.date, let b = recoveryDays.last?.date else { return nil }
            return "\(TrendsDayFormat.monthYear(a)) – \(TrendsDayFormat.monthYear(b))"
        }()
        let allHistory = range == .all && repo.days.count > 365
        NoopSectionTitle(allHistory ? "Charge · all history" : "Charge · past year", caption: span)
        NoopCard {
            VStack(alignment: .leading, spacing: 0) {
                if recoveryDays.isEmpty {
                    Text("Not enough data for this window.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    heatCalendar(recoveryDays, stripDays: stripDays)
                    heatLegend.padding(.top, 14)
                    if let line = Self.strongestMonthLine(year.months) {
                        NoopInsightRow(verbatim: line)
                            .padding(.top, 14)
                            .overlay(alignment: .top) { Rectangle().fill(NoopVisualStyle.border).frame(height: 1) }
                            .padding(.top, 16)
                    }
                }
            }
        }
    }

    private func heatCalendar(_ days: [RecoveryDay], stripDays: Int) -> some View {
        let weeks = days.count / 7 + 2
        let cell = heatCell(weeks: weeks)
        // The strip lays out its week columns in `init` (two calendar lookups per day); keep the built value
        // per (data, strip length, cell size) so a body pass reuses it instead of laying it out again.
        let strip = memo.value(.heatStrip, key: [daysToken, stripDays, cell] as [AnyHashable]) {
            YearHeatStrip(days: days, cellSize: cell, spacing: 1, showsMonthLabels: true,
                          style: .v2)
        }
        return Group {
            if CGFloat(weeks) * (cell + 1) > heatWidth + 8 {
                // All history: a fixed cell size, scrolled to the latest weeks.
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            strip
                            Color.clear.frame(width: 1, height: 1).id("heat.end")
                        }
                    }
                    .onAppear { proxy.scrollTo("heat.end", anchor: .trailing) }
                }
            } else {
                strip
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { geo in
            Color.clear.onAppear { heatWidth = geo.size.width }
                .onChangeCompat(of: geo.size.width) { heatWidth = $0 }
        })
    }

    private var heatLegend: some View {
        HStack(spacing: 8) {
            Text("Depleted").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            HStack(spacing: 4) {
                ForEach([10.0, 40, 60, 80, 95], id: \.self) { v in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(YearHeatStrip.v2Color(v))
                        .frame(width: 10, height: 10)
                }
            }
            Text("Peaked").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(YearHeatStrip.v2NotWornStroke, lineWidth: 1)
                    .frame(width: 9, height: 9)
                Text("Not worn").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Charge scale, depleted to peaked")
    }

    /// The strongest and weakest calendar months in the strip, by mean Charge, with how many of their
    /// days reached PRIMED or better. Needs two months with at least ten scored days each.
    static func strongestMonthLine(_ months: TrendsMonthPair?) -> String? {
        guard let months,
              let bestDate = TrendsDayFormat.date(months.best.key + "-01"),
              let worstDate = TrendsDayFormat.date(months.worst.key + "-01") else { return nil }
        let best = months.best, worst = months.worst
        let bestName = TrendsDayFormat.monthName(bestDate), worstName = TrendsDayFormat.monthName(worstDate)
        return String(localized: "\(bestName) was your strongest month: \(best.primed) of \(best.n) days primed or better, against \(worst.primed) of \(worst.n) in \(worstName).")
    }

    /// The month statistics behind `strongestMonthLine`, split from its wording so the history walk can be
    /// memoized with the year strip while the sentence is still formatted per pass in the app language.
    /// Internal (not private), with `strongestMonthLine`, so StrandTests can pin the pair against the
    /// single function they replaced.
    static func strongestAndWeakestMonths(_ days: ArraySlice<DailyMetric>) -> TrendsMonthPair? {
        var byMonth: [String: [Double]] = [:]
        for d in days { if let r = d.recovery { byMonth[String(d.day.prefix(7)), default: []].append(r) } }
        let months = byMonth.filter { $0.value.count >= 10 }
            .map { TrendsMonthStat(key: $0.key, mean: $0.value.reduce(0, +) / Double($0.value.count),
                                   n: $0.value.count, primed: $0.value.filter { $0 >= 70 }.count) }
        guard months.count >= 2,
              let best = months.max(by: { $0.mean < $1.mean }),
              let worst = months.min(by: { $0.mean < $1.mean }),
              best.key != worst.key else { return nil }
        return TrendsMonthPair(best: best, worst: worst)
    }

    // MARK: Export + footer

    /// Opens the shareable-report sheet (#436).
    private var exportReportRow: some View {
        NoopList {
            Button { showingReport = true } label: {
                NoopRow("Export trends report", caption: "PDF · what changed and every metric",
                        icon: "file-text", chevron: true)
            }
            .buttonStyle(.plain)
        }
    }

    private var historyFooter: some View {
        let nights = memo.value(.nights, key: daysToken) {
            repo.days.reduce(0) { $0 + (($1.totalSleepMin ?? 0) > 0 ? 1 : 0) }
        }
        return Text("Computed on \(Platform.deviceNounPhrase) · \(nights) nights of history")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.top, 8)
    }
}

// MARK: - Body-pass memo

/// Keeps TrendsView's history-wide derivations between body passes.
///
/// The body re-runs on every `Repository` publish (a sync publishes many times), and every section is
/// built eagerly even in the lazy column, so each pass used to re-run four trend-window resolves (each
/// parsing every day string in its window), the weekly digest over the whole history, the year strip's
/// 365-4000 date parses and week layout, and several full-history filters: a main-thread hitch while
/// scrolling during a sync. Each slot keeps its most recent result together with the key it was computed
/// for, and recomputes when the key differs. The keys carry every input the computation reads, so a
/// hit returns exactly what a fresh computation would. A plain class held in `@State`: filling it during
/// `body` writes no observed state.
private final class TrendsMemo {
    enum Slot: Hashable {
        case recovery, hrv, rhr, strain, digest, weekDays, minWeekOffset, comparison, year, heatStrip, nights
    }

    private var entries: [Slot: (key: AnyHashable, value: Any)] = [:]

    func value<Key: Hashable, Value>(_ slot: Slot, key: Key, _ make: () -> Value) -> Value {
        let boxed = AnyHashable(key)
        if let entry = entries[slot], entry.key == boxed, let hit = entry.value as? Value { return hit }
        let made = make()
        entries[slot] = (boxed, made)
        return made
    }
}

/// See `TrendsView.daysToken`.
private struct TrendsDaysToken: Hashable {
    let repo: ObjectIdentifier
    let refreshSeq: Int
    let count: Int
}

/// `HostedTrendData.resolve`'s result, as a named type the memo can hold.
private struct TrendsResolvedWindow {
    let points: [TrendPoint]
    let effective: TrendsView.Range
    init(_ r: (points: [TrendPoint], effective: TrendsView.Range)) {
        points = r.points
        effective = r.effective
    }
}

/// The year section's parsed days and month statistics.
private struct TrendsYearData {
    let recoveryDays: [RecoveryDay]
    let months: TrendsMonthPair?
}

/// One calendar month's Charge summary for the strongest-month line.
struct TrendsMonthStat {
    let key: String
    let mean: Double
    let n: Int
    let primed: Int
}

/// The strongest and weakest months, as `strongestAndWeakestMonths` picked them.
struct TrendsMonthPair {
    let best: TrendsMonthStat
    let worst: TrendsMonthStat
}

#if DEBUG
@MainActor
private func previewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    let cal = Calendar(identifier: .gregorian)
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "UTC")
    fmt.dateFormat = "yyyy-MM-dd"
    let today = Date()
    var seeded: [DailyMetric] = []
    let span = 365 * 3
    for i in stride(from: span - 1, through: 0, by: -1) {
        guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
        let phase = Double(span - 1 - i)
        let rec = 55 + 28 * sin(phase / 11.0) + Double((Int(phase) * 31) % 17) - 8
        let hrv = 58 + 16 * sin(phase / 9.0) + Double((Int(phase) * 13) % 11) - 5
        let rhr = 52 + 4 * sin(phase / 7.0) + Double((Int(phase) * 7) % 5) - 2
        let strain = 9 + 6 * sin(phase / 5.0 + 1.2) + Double((Int(phase) * 5) % 4) - 2
        let gap = Int(phase) % 23 == 0
        seeded.append(DailyMetric(
            day: fmt.string(from: d),
            totalSleepMin: 420, efficiency: 0.9, deepMin: 90, remMin: 110, lightMin: 200,
            disturbances: 6, restingHr: gap ? nil : Int(rhr.rounded()),
            avgHrv: gap ? nil : max(15, hrv), recovery: gap ? nil : max(2, min(99, rec)),
            strain: gap ? nil : max(0, min(21, strain)), exerciseCount: 1
        ))
    }
    repo.days = seeded
    repo.loaded = true
    return repo
}

#Preview("Trends") {
    TrendsView()
        .environmentObject(previewRepo())
        .environmentObject(LiveState())
        .frame(width: 960, height: 960)
        .preferredColorScheme(.dark)
}
#endif
