import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Weekly Digest (#208)
//
// A deterministic, offline "week in review". Reads the local DailyMetric history
// from the Repository, pulls each tracked metric into a day→value map, and feeds
// WeeklyDigestEngine (pure, in StrandAnalytics) to produce a Monday-anchored
// summary: per-metric this-week mean + week-over-week delta + vs-baseline, the
// biggest movers, a strain-vs-recovery balance read, and 1–2 plain-English focal
// points. No AI, no network — the engine is fully deterministic and unit-tested.
//
// Two surfaces are exposed so the orchestrator can wire whichever it wants:
//   • `WeeklyDigestCard` — an embeddable card (drop into Today / Trends).
//   • `WeeklyDigestView` — a full ScreenScaffold screen (for a sidebar `.digest`
//      case). Both share `WeeklyDigestContent`, so they never drift.
//
// Framing is informational and non-clinical, consistent with the app DISCLAIMER.

// MARK: - Shared digest builder (pure glue over the engine)

enum WeeklyDigestSource {

    /// Build the digest for the week containing today's local day from a DailyMetric
    /// history. Extracts each tracked metric into a "yyyy-MM-dd"→value map and hands
    /// it to the pure engine.
    static func digest(from days: [DailyMetric],
                       anchorDay: String,
                       effortDisplayFactor: Double = UnitPrefs.currentEffortDisplayFactor()) -> WeeklyDigest {
        var charge: [String: Double] = [:]
        var effort: [String: Double] = [:]
        var rest: [String: Double] = [:]
        var rhr: [String: Double] = [:]
        var hrv: [String: Double] = [:]
        for d in days {
            if let v = d.recovery { charge[d.day] = v }
            if let v = d.strain   { effort[d.day] = v }
            // Rest = the sleep-performance composite, recomputed on the persisted day.
            if let r = restScore(for: d) { rest[d.day] = r }
            if let v = d.restingHr { rhr[d.day] = Double(v) }
            if let v = d.avgHrv    { hrv[d.day] = v }
        }
        return WeeklyDigestEngine.build(
            byMetric: [.charge: charge, .effort: effort, .rest: rest, .rhr: rhr, .hrv: hrv],
            anchorDay: anchorDay,
            effortDisplayFactor: effortDisplayFactor)
    }

    /// The 0–100 Rest composite for a persisted day, via AnalyticsEngine's display-path
    /// helper (duration-vs-need / efficiency / restorative / consistency). Returns nil
    /// for a day with no in-bed sleep / missing efficiency, so non-sleep days are simply
    /// absent from the Rest series.
    private static func restScore(for d: DailyMetric) -> Double? {
        AnalyticsEngine.Rest.composite(daily: d)
    }
}

// MARK: - Embeddable card

/// The weekly digest as a single card (for Today / Trends). Renders nothing
/// (an empty view) when there's no data this week, so it's safe to always place.
struct WeeklyDigestCard: View {
    @EnvironmentObject var repo: Repository

    var body: some View {
        let digest = WeeklyDigestSource.digest(from: repo.days, anchorDay: Repository.localDayKey(Date()))
        if digest.isEmpty {
            EmptyView()
        } else {
            // Content owns its own frosted cards (the domain score row + the signals
            // card), so it's no longer wrapped in an outer NoopCard — that would double
            // the frost. The compact flag trims it to the three headline scores.
            WeeklyDigestContent(digest: digest, compact: true)
        }
    }
}

// MARK: - Full screen

/// The weekly digest as a full screen (for a sidebar `.digest` case).
struct WeeklyDigestView: View {
    @EnvironmentObject var repo: Repository

    var body: some View {
        ScreenScaffold(title: "Week in review",
                       subtitle: "Your Monday-to-Sunday, read in one glance.",
                       // PERF: chart-heavy column (per-score summary cards with gauges, the metric grid
                       // and the focal-points list, all inside WeeklyDigestContent). The LazyVStack path
                       // is byte-identical layout. The content is kept in its inner VStack(sectionGap=22)
                       // for pixel-identical spacing (the scaffold stack is 20pt), so the win is partial
                       // until those rows are promoted to direct children.
                       lazy: true) {
            if repo.days.isEmpty {
                ComingSoon(what: repo.loaded
                    ? "A weekly digest needs a few days of history. Wear your strap or import your WHOOP export in Data Sources."
                    : "Loading your history…")
            } else {
                let digest = WeeklyDigestSource.digest(from: repo.days, anchorDay: Repository.localDayKey(Date()))
                if digest.isEmpty {
                    DataPendingNote(
                        title: "No readings this week yet",
                        message: "Once this week has a day or two of data, your week-in-review appears here.")
                } else {
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                        WeeklyDigestContent(digest: digest, compact: false)
                    }
                }
            }
        }
    }
}

// MARK: - Shared content

/// Compact, localized range shared by the standalone digest card and the Trends week navigator
/// ("28 Sep – 4 Oct").
func weeklyDigestRangeLabel(_ digest: WeeklyDigest) -> String {
    TrendsDayFormat.range(digest.weekStart, digest.weekEnd)
}

/// The recap shared by the share image and the full screen: an optional header, then the recap lines.
/// `compact` keeps the four headline lines; the full screen adds resting heart rate and the footer.
struct WeeklyDigestContent: View {
    let digest: WeeklyDigest
    var compact: Bool = false
    var showsHeader: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            if showsHeader {
                VStack(alignment: .leading, spacing: 4) {
                    NoopOverline("Week in review")
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: weeklyDigestRangeLabel(digest))
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Text("\(digest.daysWithData)/7 days")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityLabel("\(digest.daysWithData) of 7 days had data this week")
                    }
                }
            }
            NoopCard {
                WeeklyDigestLines(digest: digest, compact: compact)
                    .padding(.vertical, -8)
            }
        }
    }
}

/// The recap as `.dl` lines: each week mean with its move against last week (Charge, Rest steadiness,
/// Effort, HRV; the full screen adds resting heart rate), a balance line when Effort and Charge pull
/// apart, and the full screen's footer. A ROUGH comparison (either week thin, #463) keeps the move but
/// drops the good/bad verdict, exactly like the chips it replaces.
struct WeeklyDigestLines: View {
    let digest: WeeklyDigest
    var compact: Bool = true

    /// The Effort display scale (#268), so the Effort line matches the Today tile and Trends.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    private struct Line: Identifiable {
        var id: String
        var icon: String
        var lead: String
        var rest: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                TrendsDigestLine(icon: line.icon, lead: line.lead, rest: line.rest)
                    .overlay(alignment: .top) {
                        if i > 0 { Rectangle().fill(NoopVisualStyle.border).frame(height: 1) }
                    }
            }
            if digest.daysWithData < WeeklyDigestEngine.minDaysForFocus {
                Text("Only \(digest.daysWithData) of 7 days so far, too early to call a trend.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.top, 4)
            }
            if !compact { footer }
        }
    }

    private var lines: [Line] {
        var out: [Line] = []
        if let s = digest.summary(.charge), s.thisWeek.n > 0 {
            let mean = Int(s.thisWeek.mean.rounded())
            out.append(Line(id: "charge", icon: "lightning",
                            lead: String(localized: "Charge averaged \(mean)"), rest: move(s, points: true)))
        }
        if let sd = digest.sleepConsistencySD {
            out.append(Line(id: "rest", icon: "moon-stars", lead: String(localized: "Sleep steadiness:"),
                            rest: String(localized: " Rest varied ±\(Int(sd.rounded())) pts.")))
        } else if let s = digest.summary(.rest), s.thisWeek.n > 0 {
            let mean = Int(s.thisWeek.mean.rounded())
            out.append(Line(id: "rest", icon: "moon-stars",
                            lead: String(localized: "Rest averaged \(mean)"), rest: move(s, points: true)))
        }
        if let s = digest.summary(.effort), s.thisWeek.n > 0 {
            // #463/#268: Effort is STORED 0–100; it reads on the wearer's chosen display scale.
            let mean = UnitFormatter.effortDisplay(s.thisWeek.mean, scale: effortScale)
            out.append(Line(id: "effort", icon: "fire",
                            lead: String(localized: "Effort averaged \(mean)"), rest: effortMove(s)))
        }
        if let s = digest.summary(.hrv), s.thisWeek.n > 0 {
            let mean = Int(s.thisWeek.mean.rounded())
            out.append(Line(id: "hrv", icon: "wave-sine",
                            lead: String(localized: "HRV averaged \(mean) ms"), rest: baselineMove(s, unit: "ms")))
        }
        if !compact, let s = digest.summary(.rhr), s.thisWeek.n > 0 {
            let mean = Int(s.thisWeek.mean.rounded())
            out.append(Line(id: "rhr", icon: "heartbeat",
                            lead: String(localized: "Resting HR averaged \(mean) bpm"), rest: baselineMove(s, unit: "bpm")))
        }
        if digest.balance == .overreaching || digest.balance == .underloaded {
            out.append(Line(id: "balance", icon: "scales", lead: "", rest: digest.balance.sentence))
        }
        return out
    }

    private func hasComparison(_ s: WeeklyMetricSummary) -> Bool {
        s.weekOverWeek.current.n > 0 && s.weekOverWeek.previous.n > 0
    }

    /// ", up 4 — a good sign." The verdict follows the metric's own direction (a Resting HR rise is worth a
    /// look) and is dropped for a rough comparison (#463).
    private func move(_ s: WeeklyMetricSummary, points: Bool) -> String {
        guard hasComparison(s) else { return String(localized: ", no comparison with last week yet.") }
        let d = Int(s.wowDelta.rounded())
        if d == 0 { return String(localized: ", level with last week.") }
        let verdict = WeeklyDigestChipStyle.dropsVerdictFrame(s) ? 0 : s.wowGoodness
        switch (d > 0, verdict) {
        case (true, 1):   return String(localized: ", up \(d) — a good sign.")
        case (true, -1):  return String(localized: ", up \(d) — worth a look.")
        case (true, _):   return String(localized: ", up \(d) on last week.")
        case (false, 1):  return String(localized: ", down \(abs(d)) — a good sign.")
        case (false, -1): return String(localized: ", down \(abs(d)) — worth a look.")
        case (false, _):  return String(localized: ", down \(abs(d)) on last week.")
        }
    }

    /// Effort's move without a verdict: more load is neither good nor bad on its own.
    private func effortMove(_ s: WeeklyMetricSummary) -> String {
        guard hasComparison(s) else { return String(localized: ", no comparison with last week yet.") }
        let d = UnitFormatter.effortValue(s.wowDelta, scale: effortScale)
        let text = UnitFormatter.effortDisplay(abs(s.wowDelta), scale: effortScale)
        if abs(d) < 0.5 { return String(localized: ", level with last week.") }
        return d > 0 ? String(localized: ", up \(text) — pushed harder.") : String(localized: ", down \(text) — eased off.")
    }

    /// A nightly signal against its four-week baseline, falling back to the week-over-week move.
    private func baselineMove(_ s: WeeklyMetricSummary, unit: String) -> String {
        guard let vs = s.vsBaseline else { return move(s, points: false) }
        let d = Int(vs.rounded())
        if d > 0 { return String(localized: ", \(d) \(unit) above your baseline.") }
        if d < 0 { return String(localized: ", \(abs(d)) \(unit) below your baseline.") }
        return String(localized: ", right on your baseline.")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(digest.balance.sentence)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Informational only, not medical advice.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(NoopVisualStyle.border).frame(height: 1) }
        .padding(.vertical, 8)
    }
}

// MARK: - Rough-comparison chip contract (#463, testable mirror of Android)

/// The display-side gate for a ROUGH week-over-week comparison (either side thin, engine's
/// `WeeklyMetricSummary.isRoughComparison`). Pulled out of the View's private helpers so it can be
/// pinned by a test without exposing the whole View: `chipTone`/`rowAccessibility` above delegate to
/// these, exactly as the Android WeeklyDigestCard chipTone/rowAccessibility gate on the same flag.
enum WeeklyDigestChipStyle {
    /// A rough comparison keeps its arrow + % but the chip stays grey regardless of direction, so it
    /// can't frame a green/rose verdict off 1-2 days (the #463 complaint).
    static func neutralizesTone(_ s: WeeklyMetricSummary) -> Bool { s.isRoughComparison }
    /// A rough comparison also drops the ", a good sign."/", worth a look." VoiceOver frame so the
    /// spoken row matches the neutral chip.
    static func dropsVerdictFrame(_ s: WeeklyMetricSummary) -> Bool { s.isRoughComparison }
}

#if DEBUG
private func previewDigest() -> WeeklyDigest {
    var charge: [String: Double] = [:], effort: [String: Double] = [:]
    var rest: [String: Double] = [:], hrv: [String: Double] = [:], rhr: [String: Double] = [:]
    // This week (Mon 2026-06-08 .. Sun 2026-06-14) trending up; last week lower.
    for (i, day) in (8...14).enumerated() {
        let k = String(format: "2026-06-%02d", day)
        charge[k] = 62 + Double(i) * 3
        effort[k] = 70 - Double(i)
        rest[k] = 82 + Double(i % 3)
        hrv[k] = 58 + Double(i)
        rhr[k] = 53 - Double(i % 2)
    }
    for day in 1...7 {
        let k = String(format: "2026-06-%02d", day)
        charge[k] = 55; effort[k] = 64; rest[k] = 80; hrv[k] = 52; rhr[k] = 55
    }
    return WeeklyDigestEngine.build(
        byMetric: [.charge: charge, .effort: effort, .rest: rest, .hrv: hrv, .rhr: rhr],
        anchorDay: "2026-06-13")
}

#Preview("Weekly digest – card") {
    WeeklyDigestContent(digest: previewDigest(), compact: true)
        .padding(24)
        .frame(width: 420)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}

#if os(iOS)
#Preview("Weekly digest – card · accessibility text") {
    WeeklyDigestContent(digest: previewDigest(), compact: true)
        .padding(24)
        .frame(width: 390)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility1)
}
#endif

#Preview("Weekly digest – full") {
    ScrollView {
        WeeklyDigestContent(digest: previewDigest(), compact: false)
            .padding(24)
    }
    .frame(width: 520, height: 680)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
