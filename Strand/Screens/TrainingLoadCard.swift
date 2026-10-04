import Foundation
import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Training Load card (CTL / ATL / TSB)
//
// The first UI surface for the long-horizon training-load model (TrainingLoadEngine, added with the
// paired `ReadinessEngine.evaluateWithTrainingLoad`). It overlays chronic load (CTL, the 42-day
// fitness proxy) and acute load (ATL, the 7-day fatigue proxy); the gap between the two lines IS the
// TSB / "form" (CTL − ATL), surfaced as the headline number and a footer stat.
//
// Descriptive only: CTL/ATL/TSB never feed the Readiness level or any score, and the loads are NOOP's
// daily Effort/strain — NOT TRIMP. Long-horizon by nature, so the card models the full history rather
// than the Trends range window (14+ contiguous days are needed before anything is drawn).
//
// Isolated in its own file on purpose: TrendsView already sits near the iOS type-check budget, so this
// keeps its own inference cost out of that body.
struct TrainingLoadCard: View {
    let days: [DailyMetric]

    // yyyy-MM-dd → Date (en_US_POSIX, UTC) — same keying TrendsView uses so the x-axis matches.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// `internal` (not `private`): `TrainingLoadChart` (its own file) plots these.
    struct Row: Identifiable {
        let date: Date
        let ctl: Double
        let atl: Double
        var id: Date { date }
    }

    /// One modelled point per day of the contiguous suffix the engine returned.
    private func rows(from result: TrainingLoadEngine.Result) -> [Row] {
        result.points.compactMap { p in
            guard let d = Self.dayParser.date(from: p.day) else { return nil }
            return Row(date: d, ctl: p.chronicLoad, atl: p.acuteLoad)
        }
    }

    /// PERF: `result` used to be a plain computed property re-running `TrainingLoadEngine.evaluate`
    /// (a full-history EWMA scan) from scratch on every access — and `body` hit it TWICE per render
    /// (`let tl = result` here, then again via the old `rows`/`chart` computed properties), so opening
    /// this card ran the model twice per render, including on animation/hover frames and, before the
    /// `WorkoutsView`/`HealthView` AppModel-isolation fixes elsewhere, on every ~1 Hz live-HR tick.
    /// Mirrors the `modelCache`/`modelCacheKey` idiom `CompareView` already uses for its own memoized
    /// chart model (CompareView.swift:741-742): cached value + fingerprint, refreshed via `onAppear`/
    /// `onChange` rather than mutated mid-body.
    @State private var resultCache: TrainingLoadEngine.Result = Self.computeResult(days: [])
    @State private var resultCacheKey: String = ""

    /// Fingerprint of `days`. `days` is `Repository.days` (TrendsView.swift) — the SAME live-updating
    /// array `HealthView`/`TrendsView` observe, whose latest entry keeps accumulating strain through the
    /// day. That's why this can't copy `CompareView.modelKey`'s count+endpoints idiom verbatim (a fixed
    /// count/date range with a changing LAST value would never invalidate the cache): the key covers the
    /// total count (so a backfill/import that lengthens history always invalidates) plus every
    /// `(day, strain)` pair in the trailing `establishedDays` window the model actually weighs at anything
    /// more than a couple of percent (42-day EWMA — older days are exponentially near-zero weight).
    /// `internal` (not `private`), matching the MotionTrace-peak precedent (#2288) of the minimum a test
    /// can reach, so `StrandTests` can pin it without rendering the chart.
    static func modelKey(for days: [DailyMetric]) -> String {
        let tail = days.suffix(TrainingLoadEngine.Configuration.standard.establishedDays)
        return "\(days.count)|" + tail.map { "\($0.day):\($0.strain ?? -1)" }.joined(separator: ",")
    }

    /// Model straight from the training-load engine — NOT the paired `evaluateWithTrainingLoad`, which
    /// would also run the full Readiness synthesis this card never uses. `DailyMetric.strain` is the load.
    private static func computeResult(days: [DailyMetric]) -> TrainingLoadEngine.Result {
        let loads = days.map { TrainingLoadEngine.DailyLoad(day: $0.day, load: $0.strain) }
        return TrainingLoadEngine.evaluate(days: loads)
    }

    /// Cached accessor used by `body`. Mirrors `CompareView.currentModel`: returns the memoized result
    /// when the inputs match, else computes for THIS render (without mutating state mid-body); the
    /// matching `.onAppear`/`.onChange` then persist it so subsequent hover/animation frames hit the cache.
    private var result: TrainingLoadEngine.Result {
        Self.modelKey(for: days) == resultCacheKey ? resultCache : Self.computeResult(days: days)
    }

    /// Rebuild the result cache if (and only if) the fingerprint changed.
    private func refreshResult() {
        let key = Self.modelKey(for: days)
        guard key != resultCacheKey else { return }
        resultCacheKey = key
        resultCache = Self.computeResult(days: days)
    }

    private static let established = TrainingLoadEngine.Configuration.standard.establishedDays
    private static let minimum = TrainingLoadEngine.Configuration.standard.minimumDays

    private func whole(_ v: Double) -> String { "\(Int(v.rounded()))" }
    private func signed(_ v: Double) -> String {
        let n = Int(v.rounded())
        return n > 0 ? "+\(n)" : (n < 0 ? "−\(abs(n))" : "0")
    }

    /// The form scale the marker sits on: TSB from −30 (deep fatigue) to +25 (fully fresh).
    private static let formScale: ClosedRange<Double> = -30...25

    var body: some View {
        let tl = result
        NoopCard {
            if !tl.isAvailable {
                unavailable(contiguousDays: tl.contiguousDays)
            } else {
                established(tl)
            }
        }
        // Persist the memoized result into `@State` (mirrors `CompareView`'s `.onAppear { refreshModel() }`
        // / `.onChangeCompat(of: modelKey)` pair) so the NEXT render's `result` access hits the cache
        // instead of recomputing — `body` itself never mutates `@State` mid-evaluation.
        .onAppear { refreshResult() }
        .onChangeCompat(of: Self.modelKey(for: days)) { _ in refreshResult() }
    }

    @ViewBuilder
    private func established(_ tl: TrainingLoadEngine.Result) -> some View {
        let latest = tl.points.last
        // The chart shows the last 42 modelled days (the chronic horizon); the loads themselves are
        // modelled over the whole contiguous history.
        let rows = Array(rows(from: tl).suffix(Self.established))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                loadTile("CTL · Fitness", value: latest.map { whole($0.chronicLoad) } ?? "—", dashed: false)
                loadTile("ATL · Fatigue", value: latest.map { whole($0.acuteLoad) } ?? "—", dashed: true)
            }
            TrainingLoadChart(rows: rows)
                .frame(height: 84)
                .padding(.top, 16)
            axisLabels(rows).padding(.top, 6)
            Text(subtitle(for: tl))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.top, 12)
            if let latest {
                form(latest.balance)
                    .padding(.top, 14)
                    .overlay(alignment: .top) { Rectangle().fill(NoopVisualStyle.border).frame(height: 1) }
                    .padding(.top, 14)
            }
        }
    }

    /// A `.tl` tile: caption, the latest load and a legend stroke matching its line in the chart.
    private func loadTile(_ title: LocalizedStringKey, value: String, dashed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            HStack(spacing: 8) {
                Text(verbatim: value)
                    .font(StrandFont.value(30, weight: 300))
                    .tracking(-0.6)
                    .foregroundStyle(StrandPalette.textPrimary)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 4))
                    p.addLine(to: CGPoint(x: 22, y: 4))
                }
                .stroke(dashed ? StrandPalette.textPrimary : StrandPalette.metricCyan,
                        style: StrokeStyle(lineWidth: dashed ? 1.4 : 1.6, dash: dashed ? [3, 3] : []))
                .frame(width: 22, height: 8)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(NoopVisualStyle.inset))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private static let axisFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()

    private func axisLabels(_ rows: [Row]) -> some View {
        let isToday = rows.last.map { Self.dayParser.string(from: $0.date) == Repository.localDayKey(Date()) } ?? false
        return HStack {
            Text(verbatim: rows.first.map { Self.axisFormatter.string(from: $0.date) } ?? "")
            Spacer()
            Text(verbatim: rows.isEmpty ? "" : Self.axisFormatter.string(from: rows[rows.count / 2].date))
            Spacer()
            Group {
                if isToday { Text("Today") } else { Text(verbatim: rows.last.map { Self.axisFormatter.string(from: $0.date) } ?? "") }
            }
            .foregroundStyle(StrandPalette.textPrimary)
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .accessibilityHidden(true)
    }

    /// Form (TSB = CTL − ATL) with its position on the fatigue-to-fresh scale.
    private func form(_ balance: Double) -> some View {
        let f = (balance - Self.formScale.lowerBound) / (Self.formScale.upperBound - Self.formScale.lowerBound)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Form").font(StrandFont.book(14)).foregroundStyle(StrandPalette.textPrimary)
                    Text("Fitness minus fatigue").font(StrandFont.light(10.5)).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 8)
                Text(verbatim: signed(balance))
                    .font(StrandFont.value(30, weight: 300))
                    .tracking(-0.6)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .accessibilityElement(children: .combine)
            NoopTickScale(marker: min(max(f, 0), 1), height: 18)
                .padding(.top, 14)
            HStack {
                Text("Overreaching")
                Spacer()
                Text("Productive")
                Spacer()
                Text("Fresh")
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.top, 6)
            .accessibilityHidden(true)
        }
    }

    private func subtitle(for tl: TrainingLoadEngine.Result) -> String {
        switch tl.state {
        case .established:
            return String(localized: "42-day fitness vs 7-day fatigue")
        case .building:
            return String(localized: "Building — \(tl.contiguousDays) of \(Self.established) days")
        case .unavailable:
            return ""
        }
    }

    // Honest empty state: name exactly how many consecutive Effort days are still needed.
    private func unavailable(contiguousDays: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NoopCardHeader("Chronic vs acute load", icon: "chart-line")
            Text("Needs \(Self.minimum)+ consecutive days of Effort to begin. \(contiguousDays) so far.")
                .font(StrandFont.light(14))
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
