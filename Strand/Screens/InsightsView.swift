import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Insights
//
// The headline "interrogate what affects what" screen. Two halves:
//
//  1. BEHAVIOUR EFFECTS — split your logged journal answers (Alcohol, Caffeine,
//     Late meal, Meditation…) into the days each behaviour WAS logged vs NOT, then
//     compare a chosen outcome metric (Recovery / HRV / Sleep performance / RHR)
//     between the two groups. Ranked by effect size (Cohen's d) with significant
//     effects first; each card carries the plain-English sentence, the with/without
//     means, group counts, a significance pill, and the effect-size magnitude.
//     Tint is sign-aware: a behaviour that moves the outcome the "good" way
//     (respecting higherIsBetter) is positive/green, the "bad" way is critical/red.
//
//  2. METRIC RELATIONSHIPS — a curated set of Pearson correlations between daily
//     series (sleep ↔ recovery, today's strain ↔ next-day recovery via a 1-day lag,
//     HRV ↔ recovery, RHR ↔ recovery), each rendered as a one-line insight with r
//     and a plain-English reading of strength + direction.
//
// All math comes from StrandAnalytics (BehaviorInsights / CorrelationEngine); this
// view only loads the series, shapes them, and presents. Empty state via ComingSoon
// when there is no journal data to interrogate.

struct InsightsView: View {
    @EnvironmentObject var repo: Repository

    // MARK: Selected outcome (segmented)

    /// One interrogable outcome metric: how to fetch it and how to read its direction.
    enum Outcome: String, CaseIterable, Identifiable {
        case recovery, hrv, sleep, rhr
        var id: String { rawValue }

        /// Short segment label.
        var label: String {
            switch self {
            case .recovery: return "Recovery"
            case .hrv:      return "HRV"
            case .sleep:    return "Sleep"
            case .rhr:      return "RHR"
            }
        }
        /// The metricSeries key (source is always "my-whoop" for these).
        var key: String {
            switch self {
            case .recovery: return "recovery"
            case .hrv:      return "hrv"
            case .sleep:    return "sleep_performance"
            case .rhr:      return "rhr"
            }
        }
        /// The human outcome name used by BehaviorInsights.sentence.
        var outcomeName: String {
            switch self {
            case .recovery: return "Recovery"
            case .hrv:      return "HRV"
            case .sleep:    return "Sleep performance"
            case .rhr:      return "Resting HR"
            }
        }
        /// Whether a higher value is the "good" direction (drives tint).
        var higherIsBetter: Bool {
            switch self {
            case .recovery, .hrv, .sleep: return true
            case .rhr:                    return false
            }
        }
    }

    @State private var outcome: Outcome = .recovery
    /// Which behaviour row is expanded to its full breakdown (tap to toggle).
    @State private var expandedEffect: Int?

    // MARK: Loaded state

    /// behaviour question → set of days where it was answered yes.
    @State private var behaviours: [String: Set<String>] = [:]
    /// outcome key → [day: value].
    @State private var outcomeByKey: [String: [String: Double]] = [:]
    /// outcome key → ordered (day, value) series for correlations.
    @State private var seriesByKey: [String: [(day: String, value: Double)]] = [:]
    @State private var loaded = false

    // MARK: Memoized derived state
    //
    // The ranking and correlations are expensive (BehaviorInsights.rank +
    // four Pearson correlations) and were previously recomputed inside `body`
    // on EVERY render — including hover/animation/1Hz HR ticks. Cache them in
    // @State and recompute only when their inputs change.

    /// Ranked behaviour effects for the current outcome, recomputed via
    /// recomputeRanked() only when behaviours / outcomeByKey / outcome change.
    @State private var ranked: [BehaviorEffect] = []
    /// Curated metric relationships, recomputed via recomputeRelationships()
    /// only when the loaded series change.
    @State private var relationships: [Relationship] = []

    private let outcomeKeys = ["recovery", "hrv", "sleep_performance", "rhr"]

    var body: some View {
        ScreenScaffold(title: "Insights", subtitle: "Interrogate what affects what.") {
            if !loaded {
                ComingSoon(what: "Reading your journal and outcomes…")
            } else {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    if behaviours.isEmpty {
                        // No journal yet — explain, but still surface relationships if
                        // the loaded series are non-empty (data-display rule).
                        NoopCard {
                            Text("Insights read your journal and outcomes. Log behaviours in Journal — or import your WHOOP export, which includes your journal, in Data Sources — to unlock them.")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        behaviourSection
                    }
                    relationshipsSection
                }
            }
        }
        // Key on refreshSeq (not the one-shot `loaded`) so the screen reloads after a journal save
        // while it's on-screen — `refresh()` bumps refreshSeq, matching TodayView. (macOS keeps the
        // detail view alive across saves; iOS recreates it on push, but this is correct on both.)
        .task(id: repo.refreshSeq) { await load() }
        // Recompute the cached ranking only when the outcome selection changes.
        // (behaviours / outcomeByKey change only at load, which calls
        //  recomputeRanked() directly, so keying on `outcome` is sufficient.)
        .onChange(of: outcome) { _ in expandedEffect = nil; recomputeRanked() }
    }

    // MARK: - Load

    /// Friendly label for a behaviour key. The key is a verbatim journal question (possibly a
    /// German WHOOP export string); resolve it through the alias-aware catalog so impact rows read
    /// "Caffeine" rather than "Koffein konsumiert?". Falls back to the raw key if unresolved.
    func behaviorLabel(_ key: String) -> String {
        JournalCatalog.byQuestion(key)?.shortLabel ?? key
    }

    private func load() async {
        // Journal → behaviours map (only "yes" answers count as the behaviour occurring).
        // Merge question variants that resolve to the same behaviour — a German WHOOP import
        // ("Alkohol konsumiert?") and an English answer logged natively ("Did you drink any
        // alcohol?") are one behaviour — so each is ranked once over its full history (no
        // duplicate "Alcohol" rows). Key on the resolved canonical question; unresolved stay raw.
        let entries = await repo.journalEntries()
        var byBehaviour: [String: Set<String>] = [:]
        for e in entries where e.answeredYes {
            let key = JournalCatalog.byQuestion(e.question)?.question ?? e.question
            byBehaviour[key, default: []].insert(e.day)
        }

        // Outcome series (Whoop) → both [day:value] dictionaries and ordered series.
        var byKey: [String: [String: Double]] = [:]
        var seriesMap: [String: [(day: String, value: Double)]] = [:]
        for key in outcomeKeys {
            let s = await repo.series(key: key, source: "my-whoop")
            seriesMap[key] = s
            var dict: [String: Double] = [:]
            for row in s { dict[row.day] = row.value }
            byKey[key] = dict
        }

        await MainActor.run {
            self.behaviours = byBehaviour
            self.outcomeByKey = byKey
            self.seriesByKey = seriesMap
            self.loaded = true
            // Seed the memoized derived state from the freshly loaded inputs.
            self.recomputeRanked()
            self.recomputeRelationships()
        }
    }

    // MARK: - Memoized recomputation

    /// Rebuild the cached behaviour ranking for the current inputs.
    /// Called at load and whenever `outcome` changes — NOT in `body`.
    private func recomputeRanked() {
        let outcomeDays = outcomeByKey[outcome.key] ?? [:]
        ranked = BehaviorInsights.rank(
            behaviors: behaviours,
            outcomeByDay: outcomeDays,
            outcome: outcome.outcomeName
        )
    }

    /// Rebuild the cached metric relationships from the loaded series.
    /// Called at load only — the series don't change after that.
    private func recomputeRelationships() {
        relationships = computeRelationships()
    }

    // MARK: - Behaviour effects section

    private var behaviourSection: some View {
        // `ranked` is memoized in @State (see recomputeRanked()); reading it
        // here does no expensive work per render.
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // Header, then the ONE segmented pill control on its own full-width line — on the
            // narrow iPhone sheet the title + 4-segment control don't fit side by side.
            SectionHeader("Behaviour Effects",
                          overline: "What moves your \(outcome.outcomeName.lowercased())")
            SegmentedPillControl(Outcome.allCases, selection: $outcome) { $0.label }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Outcome metric")

            if ranked.isEmpty {
                noEffects
            } else {
                behaviorImpactSection
            }
        }
    }

    private var noEffects: some View {
        NoopCard {
            Text("Not enough overlap between your journal answers and \(outcome.outcomeName.lowercased()) "
                + "to measure an effect yet. Keep logging — effects need days both with and without each behaviour.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Metric relationships section

    private var relationshipsSection: some View {
        // `relationships` is memoized in @State (see recomputeRelationships());
        // the four Pearson correlations no longer run per render.
        let rels = relationships
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Metric Relationships", overline: "Pearson r")

            if rels.isEmpty {
                NoopCard {
                    Text("Not enough overlapping history to correlate your metrics yet.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                NoopCard {
                    VStack(spacing: 0) {
                        ForEach(Array(rels.enumerated()), id: \.element.id) { idx, rel in
                            relationshipRow(rel)
                            if idx < rels.count - 1 {
                                Divider().overlay(StrandPalette.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A curated metric relationship plus its computed correlation.
    private struct Relationship: Identifiable {
        let id: String
        let title: String        // "Sleep → Recovery"
        let blurb: String        // what the pairing probes
        let corr: Correlation
    }

    private func computeRelationships() -> [Relationship] {
        func series(_ key: String) -> [(day: String, value: Double)] { seriesByKey[key] ?? [] }
        var out: [Relationship] = []

        // Sleep performance ↔ recovery (same day).
        if let c = CorrelationEngine.pearson(
            CorrelationEngine.alignByDay(series("sleep_performance"), series("recovery"))) {
            out.append(.init(id: "sleep-rec",
                             title: "Sleep performance ↔ Recovery",
                             blurb: "How closely a good night tracks next-morning recovery.",
                             corr: c))
        }
        // HRV ↔ recovery (same day).
        if let c = CorrelationEngine.pearson(
            CorrelationEngine.alignByDay(series("hrv"), series("recovery"))) {
            out.append(.init(id: "hrv-rec",
                             title: "HRV ↔ Recovery",
                             blurb: "Heart-rate variability as the engine behind your recovery score.",
                             corr: c))
        }
        // Resting HR ↔ recovery (same day) — expected to be negative.
        if let c = CorrelationEngine.pearson(
            CorrelationEngine.alignByDay(series("rhr"), series("recovery"))) {
            out.append(.init(id: "rhr-rec",
                             title: "Resting HR ↔ Recovery",
                             blurb: "A lower resting heart rate usually means a higher recovery.",
                             corr: c))
        }
        // Today's recovery ↔ NEXT-day recovery (1-day lag) as a strain/carry-over proxy.
        // (Strain series isn't in the outcome set; recovery→next-day recovery shows
        //  how much yesterday carries into today.)
        if let c = CorrelationEngine.lagged(x: series("recovery"), y: series("recovery"), lagDays: 1) {
            out.append(.init(id: "rec-lag",
                             title: "Recovery → Next-day recovery",
                             blurb: "How much one day's recovery carries into the next.",
                             corr: c))
        }

        return out
    }

    private func relationshipRow(_ rel: Relationship) -> some View {
        let r = rel.corr.r
        let strength = correlationColor(r)
        // Build the reading sentence ONCE and reuse it for the visible copy and
        // the accessibility label (was computed twice per row).
        let sentence = relationshipSentence(rel)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(rel.title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(String(format: "r = %+.2f", r))
                    .font(StrandFont.number(16))
                    .foregroundStyle(strength)
                StatePill(rel.corr.pApprox < 0.05 ? "p < 0.05" : "n.s.",
                          tone: rel.corr.pApprox < 0.05 ? .accent : .neutral,
                          showsDot: false)
            }

            // r bar — visual magnitude/direction (hover reveals the exact value).
            rBar(r: r, color: strength, label: rel.title)

            Text(sentence)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(rel.blurb)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sentence)
    }

    /// A centred bar: zero in the middle, fills left (negative) or right (positive)
    /// proportional to |r|. Hovering reveals a tooltip with the exact r value, so the
    /// bar — like every Strand chart — is never an unexplained coloured shape.
    private func rBar(r: Double, color: Color, label: String) -> some View {
        RBar(r: r, color: color, label: label)
    }

    // MARK: - Formatting / interpretation helpers

    /// Format an outcome value with sensible units for the selected metric.
    private func formatOutcome(_ v: Double) -> String {
        switch outcome {
        case .recovery, .sleep: return "\(Int(v.rounded()))%"
        case .hrv:              return "\(Int(v.rounded())) ms"
        case .rhr:              return "\(Int(v.rounded())) bpm"
        }
    }

    /// Cohen's d → conventional magnitude word.
    private func effectMagnitudeWord(_ d: Double) -> String {
        switch abs(d) {
        case ..<0.2:  return "negligible"
        case ..<0.5:  return "small"
        case ..<0.8:  return "moderate"
        default:      return "large"
        }
    }

    /// |r| → strength word.
    private func strengthWord(_ r: Double) -> String {
        switch abs(r) {
        case ..<0.1:  return "no"
        case ..<0.3:  return "a weak"
        case ..<0.5:  return "a moderate"
        case ..<0.7:  return "a strong"
        default:      return "a very strong"
        }
    }

    /// Tint a correlation by strength, keyed on the recovery gradient so strong
    /// positive reads mint and strong negative reads red.
    private func correlationColor(_ r: Double) -> Color {
        // Map r∈[-1,1] → 0…1 of the recovery scale (−1 red, 0 gold, +1 mint).
        StrandPalette.sample(stops: StrandPalette.recoveryStops, at: (r + 1) / 2)
    }

    private func relationshipSentence(_ rel: Relationship) -> String {
        let r = rel.corr.r
        let dir = r > 0 ? "positive" : (r < 0 ? "negative" : "flat")
        let strength = strengthWord(r)
        return "\(strength.capitalizedFirst) \(dir) relationship "
            + "(r = \(String(format: "%.2f", r)), n = \(rel.corr.n))."
    }
}

// MARK: - Behaviour Effects · WHOOP-style HURTS ↔ HELPS impact list
//
// Replaces the old effect CARDS in the Behaviour Effects section with a calm,
// scannable vertical list of impact-slider rows, faithful to the WHOOP original
// rendered in NOOP's dark/mint language.
//
//   ┌ HURTS ▼ ─────────── % IMPACT ─────────── ▲ HELPS ┐
//   │                                                   │
//   │ READ IN BED                                  +21% │
//   │ ░░░░░░░░░░░░░░░░░░●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │  (mint fills right)
//   │                                                   │
//   │ WORK LATE                                     -6% │
//   │ ░░░░░░░░░░━━━━━━●░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │  (amber fills left)
//   └───────────────────────────────────────────────────┘
//
// Correctness lives in `behaviorImpactSection` (it can see `outcome`, `ranked`,
// `formatOutcome`); the row + track are PURE presentational subviews driven by
// primitives only — they never reach back into InsightsView.

extension InsightsView {

    /// The HURTS ↔ HELPS header overline followed by one impact row per behaviour.
    ///
    /// This is the drop-in replacement for the old `ForEach(ranked) { effectCard }`
    /// inside `behaviourSection` — the SectionHeader + outcome SegmentedPillControl
    /// stay where they are; this view only renders the header row and the list.
    var behaviorImpactSection: some View {
        // Dynamic normaliser shared by every row so positions are comparable.
        // Floor at 10 so a single tiny effect can't fill the whole bar.
        let maxAbs = max(10, ranked.map { abs($0.pctChange ?? $0.delta) }.max() ?? 1)

        return NoopCard {
            VStack(alignment: .leading, spacing: 0) {
                ImpactLegendHeader()
                    .padding(.bottom, 4)

                ForEach(ranked.indices, id: \.self) { i in
                    let e = ranked[i]

                    // HELPS vs HURTS is the "moved-good" axis — NOT the raw sign of
                    // delta. movedGood = (delta > 0) == higherIsBetter. delta == 0 → nil
                    // (neutral / centred / muted). (e.g. RHR higherIsBetter=false, so a
                    // positive delta HURTS.)
                    let movedGood: Bool? = {
                        if e.delta == 0 { return nil }
                        return (e.delta > 0) == outcome.higherIsBetter
                    }()

                    // Magnitude drives both the bar fraction and the label.
                    let mag = abs(e.pctChange ?? e.delta)
                    let fraction = min(mag / maxAbs, 1)

                    // Displayed value: a signed % when pctChange exists (sign follows
                    // movedGood, NOT the raw pct sign); otherwise the signed delta via
                    // formatOutcome — which only the parent can call.
                    let valueText: String = {
                        guard let good = movedGood else {
                            // Neutral: no signed direction to show.
                            if e.pctChange != nil { return "0%" }
                            return formatOutcome(e.meanWith - e.meanWithout)
                        }
                        if e.pctChange != nil {
                            return (good ? "+" : "-") + "\(Int(mag.rounded()))%"
                        }
                        // No pctChange → show the signed delta in outcome units.
                        return (good ? "+" : "-") + formatOutcome(mag)
                    }()

                    Button {
                        withAnimation(StrandMotion.fade) {
                            expandedEffect = (expandedEffect == i) ? nil : i
                        }
                    } label: {
                        VStack(spacing: 0) {
                            ImpactRow(
                                name: behaviorLabel(e.behavior),
                                valueText: valueText,
                                movedGood: movedGood,
                                fraction: fraction,
                                significant: e.significant
                            )
                            if expandedEffect == i {
                                impactDetail(e, movedGood: movedGood)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(impactAccessibilityLabel(
                        name: behaviorLabel(e.behavior), valueText: valueText,
                        movedGood: movedGood, significant: e.significant))

                    if i < ranked.count - 1 {
                        Divider()
                            .overlay(StrandPalette.hairline)
                            .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    /// Spoken description for one impact row.
    private func impactAccessibilityLabel(
        name: String, valueText: String, movedGood: Bool?, significant: Bool
    ) -> String {
        let dir: String = {
            switch movedGood {
            case .some(true):  return "helps"
            case .some(false): return "hurts"
            case .none:        return "no measurable effect"
            }
        }()
        let conf = significant ? "Significant." : "Exploratory."
        return "\(name) \(dir), \(valueText). \(conf)"
    }

    /// Tap-to-reveal breakdown for one behaviour: the plain-English sentence, with/without
    /// means, effect size and significance. In the extension so it can reach the parent's
    /// `formatOutcome` / `effectMagnitudeWord` / `BehaviorInsights.sentence`.
    fileprivate func impactDetail(_ e: BehaviorEffect, movedGood: Bool?) -> some View {
        let tint: Color = movedGood == nil
            ? StrandPalette.textTertiary
            : (movedGood! ? StrandPalette.accent : StrandPalette.statusWarning)
        return VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(StrandPalette.hairline)
            Text(BehaviorInsights.sentence(e, name: behaviorLabel(e.behavior)))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: NoopMetrics.gap) {
                StatTile(label: "With", value: formatOutcome(e.meanWith),
                         caption: "n = \(e.nWith)", accent: tint)
                StatTile(label: "Without", value: formatOutcome(e.meanWithout),
                         caption: "n = \(e.nWithout)", accent: StrandPalette.textPrimary)
            }
            HStack(spacing: 8) {
                Text("Effect size").strandOverline()
                Spacer()
                Text(String(format: "d = %.2f", e.cohensD))
                    .font(StrandFont.captionNumber).foregroundStyle(tint)
                Text(effectMagnitudeWord(e.cohensD))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                StatePill(e.significant ? "SIGNIFICANT" : "EXPLORATORY",
                          tone: e.significant ? .positive : .neutral, showsDot: false)
            }
        }
        .padding(.top, 12)
    }
}

// MARK: - Legend header (HURTS ▼ · % IMPACT · ▲ HELPS)

/// The three-column overline header above the impact list. HURTS amber with a
/// down-chevron on the left, "% IMPACT" tertiary in the centre, HELPS mint with an
/// up-chevron on the right — all small uppercase overline caps.
private struct ImpactLegendHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            // HURTS ▼
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                Text("HURTS")
            }
            .foregroundStyle(StrandPalette.statusWarning)
            .frame(maxWidth: .infinity, alignment: .leading)

            // % IMPACT
            Text("% IMPACT")
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)

            // ▲ HELPS
            HStack(spacing: 4) {
                Text("HELPS")
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(StrandPalette.accent)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(StrandFont.overline)
        .tracking(StrandFont.overlineTracking)
        .padding(.vertical, 3)
    }
}

// MARK: - One impact row

/// A single behaviour row: uppercase bold NAME on the left, big coloured signed %
/// on the right, and a full-width centred impact track beneath. Pure presentational
/// — every input is a primitive resolved by the parent section.
private struct ImpactRow: View {
    /// Behaviour name (rendered uppercased + bold).
    let name: String
    /// Pre-formatted signed value string ("+21%", "-6%", "0%", "+3 ms"…).
    let valueText: String
    /// true → HELPS (mint, right), false → HURTS (amber, left), nil → neutral.
    let movedGood: Bool?
    /// 0…1 position of the thumb out from centre.
    let fraction: Double
    /// true → vivid fill, false → muted (exploratory) fill.
    let significant: Bool

    /// Helps mint / hurts amber / neutral muted.
    private var color: Color {
        switch movedGood {
        case .some(true):  return StrandPalette.accent
        case .some(false): return StrandPalette.statusWarning
        case .none:        return StrandPalette.textTertiary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Text(name.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(valueText)
                    .font(StrandFont.number(15, weight: .bold))
                    .foregroundStyle(color)
                    .monospacedDigit()
            }

            ImpactTrack(
                fraction: CGFloat(fraction),
                fillsRight: movedGood ?? true,   // ignored when neutral (fraction ~ 0)
                isNeutral: movedGood == nil,
                color: color,
                vivid: significant
            )
            .frame(height: 16)
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Centred impact track (striped well + center-out fill + thumb)

/// A chunky, centred slider track. The unfilled well is a hatched/striped inset
/// capsule; a SOLID rounded fill grows from the CENTRE toward the thumb (right for
/// HELPS, left for HURTS); a prominent circular thumb with a soft shadow sits at the
/// end of the fill. `vivid` toggles full-strength (significant) vs muted (exploratory).
///
/// Math (let `half = width/2`, `thumbR = thumb radius`):
///   travel       = half - thumbR              // keep the thumb on-track at frac=1
///   reach        = fraction * travel
///   thumbCenterX = half ± reach               // + right, − left
///   fillWidth    = reach                       // fill meets the thumb centre
private struct ImpactTrack: View {
    let fraction: CGFloat
    let fillsRight: Bool
    let isNeutral: Bool
    let color: Color
    let vivid: Bool

    private let trackHeight: CGFloat = 6
    private let thumbDiameter: CGFloat = 14

    private var fillOpacity: Double { vivid ? 1.0 : 0.42 }
    private var thumbOpacity: Double { vivid ? 1.0 : 0.55 }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let midY = h / 2
            let half = w / 2
            let thumbR = thumbDiameter / 2
            let travel = max(half - thumbR, 0)
            let reach = fraction * travel
            let fillWidth = max(reach, isNeutral ? 0 : 0)

            ZStack(alignment: .leading) {
                // 1) Striped / hatched inset well — clipped to the capsule.
                StripedCapsule(height: trackHeight)
                    .frame(width: w, height: trackHeight)
                    .position(x: half, y: midY)

                // 2) Faint centre tick so "zero" is legible.
                Rectangle()
                    .fill(StrandPalette.hairlineStrong)
                    .frame(width: 1, height: trackHeight + 4)
                    .position(x: half, y: midY)

                // 3) Solid rounded fill, centre → thumb. Skipped when neutral.
                if !isNeutral && fillWidth > 0.5 {
                    let fw = max(fillWidth, trackHeight)
                    Capsule(style: .continuous)
                        .fill(color.opacity(fillOpacity))
                        .frame(width: fw, height: trackHeight)
                        .position(x: fillsRight ? half + fw / 2 : half - fw / 2, y: midY)
                }

                // 4) Circular thumb — drawn UNCLIPPED so it never gets sliced at the
                //    ends. Ring + soft shadow give it the WHOOP-style prominence.
                Circle()
                    .fill(isNeutral ? StrandPalette.surfaceRaised : color.opacity(thumbOpacity))
                    .overlay(
                        Circle().strokeBorder(
                            isNeutral ? StrandPalette.hairlineStrong : color.opacity(min(thumbOpacity + 0.2, 1)),
                            lineWidth: 2)
                    )
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    .position(x: isNeutral ? half : (fillsRight ? half + reach : half - reach), y: midY)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Striped capsule

/// A diagonally hatched capsule used for the unfilled portion of the impact track.
/// Drawn with a Canvas (cross-platform on macOS 13 / iOS 17, performant) and clipped
/// to a Capsule so the stripes read as an inset textured well, not loose lines.
private struct StripedCapsule: View {
    let height: CGFloat

    var body: some View {
        Capsule(style: .continuous)
            .fill(StrandPalette.surfaceInset)
            .overlay {
                Canvas { ctx, size in
                    let spacing: CGFloat = 6
                    let stripeColor = StrandPalette.hairline.opacity(0.9)
                    // 45° hatching: sweep diagonal lines across the bounding box.
                    var x = -size.height
                    while x < size.width + size.height {
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                        ctx.stroke(path, with: .color(stripeColor), lineWidth: 1.4)
                        x += spacing
                    }
                }
            }
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(StrandPalette.hairline, lineWidth: 1)
            )
            .clipShape(Capsule(style: .continuous))
            .frame(height: height)
    }
}

// MARK: - Correlation magnitude bar (hover-aware)

/// A centred correlation bar (zero in the middle, fills left/negative or
/// right/positive by |r|). On hover it shows the locked ChartTooltip with the exact
/// r value, matching the hover affordance every other Strand chart provides.
private struct RBar: View {
    let r: Double
    let color: Color
    let label: String

    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let mag = CGFloat(min(abs(r), 1.0)) * half
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.surfaceInset)
                // centre tick
                Rectangle()
                    .fill(StrandPalette.hairlineStrong)
                    .frame(width: 1)
                    .position(x: half, y: geo.size.height / 2)
                // value fill
                Capsule()
                    .fill(color)
                    .frame(width: mag, height: geo.size.height)
                    .offset(x: r >= 0 ? half : half - mag)
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        // Tooltip floats above the bar without affecting layout (overlays aren't
        // clipped), so the exact r value reads on hover — same affordance as charts.
        .overlay(alignment: .center) {
            if hovering {
                ChartTooltip(
                    value: String(format: "r = %+.2f", r),
                    label: label,
                    accent: color
                )
                .fixedSize()
                .offset(y: -26)
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active: hovering = true
            case .ended:  hovering = false
            }
        }
        .animation(StrandMotion.fade, value: hovering)
        .accessibilityHidden(true)
    }
}

private extension String {
    /// Capitalise only the first letter (keeps "a weak" → "A weak").
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func insightsPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Insights") {
    InsightsView()
        .environmentObject(insightsPreviewRepo())
        .frame(width: 920, height: 900)
        .preferredColorScheme(.dark)
}
#endif
