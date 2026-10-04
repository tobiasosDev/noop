import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Insights Hub (v5)
//
// The headline n-of-1 "what actually moves YOUR recovery" surface. Two halves, both
// pure association on the user's own logged days — never advice, diagnosis, or cause:
//
//  1. WHAT MOVES YOUR CHARGE — the unified, LAG-AWARE EffectRanker feed. For each
//     journal behaviour × the selected outcome it keeps the strongest honest lag
//     ({0,+1,+2} days), so each row reads "shows up the next morning" rather than
//     pretending everything is same-day. Each card carries the sign-aware sentence,
//     with/without means, a lead/lag chip, the effect-size word, and a Solid /
//     Building / Calibrating confidence pill — NOT a bare "significant" stamp.
//
//  2. ALCOHOL / CAFFEINE DOSE-RESPONSE — the personal DoseResponseEngine curve. A
//     per-user slope that SHRINKS toward a documented population prior until enough
//     nights accrue. The card plots the shrunk curve, states "each extra drink ≈ −N
//     for you" (honest when still prior-dominated, or when YOUR data contradicts the
//     prior), and an evening "damage forecast" preview — "a 2nd drink tonight ≈ −X
//     Charge tomorrow" — composed from the curve's per-unit Δ on the latest Charge.
//
// SELF-CONTAINED: this screen owns its own load/derive (InsightsHubViewModel) and takes
// the Repository via @EnvironmentObject — it does NOT edit AppModel / the central nav.
// Wave 3 surfaces it as the head of the Insights hub (see 'wiringNeeded').
//
// All maths lives in StrandAnalytics (EffectRanker / DoseResponseEngine / DoseResponsePriors);
// this view loads the series, shapes the engine inputs, and presents honestly.

struct InsightsHubView: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = InsightsHubViewModel()

    /// The currently-selected outcome for the ranked feed (Charge / HRV / Rest / RHR).
    @State private var outcome: InsightsHubViewModel.Outcome = .recovery

    var body: some View {
        // PERF (scroll): lazy column — the content is a few inner eager stacks, so the staggered mover
        // reveal is unchanged; this only defers building them until they scroll in.
        ScreenScaffold(title: nil, lazy: true) {
            NoopScreenHeader("What moves you") { outcomeMenu }
                .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 6) {
                Text("Insights")
                    .font(StrandFont.title1)
                    .tracking(-0.56)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Patterns in your own data: association, not cause.")
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .padding(.bottom, 8)
            if !model.loaded {
                NoopCard(padding: 18) {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Reading your journal and outcomes…")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            } else {
                if let top = model.ranked.first { topFinding(top) }
                moversSection
                doseSection
                // Method / honesty note.
                NoopInsightRow(text: Text(String(localized: "Everything here is a pattern in your own logged days: an association with an effect size and confidence, never a cause or a diagnosis. Population patterns are shown as \u{201C}typical\u{201D} and are always overridden by your own data once you have enough of it. Approximations, not WHOOP\u{2019}s scores; not a medical device.")))
                    .padding(.horizontal, 4)
                    .padding(.top, 10)
            }
        }
        .noopHidesSystemNavBar()
        .task(id: repo.refreshSeq) { await model.load(repo: repo) }
        .onChangeCompat(of: outcome) { model.rankFor($0) }
    }

    /// The outcome the feed ranks against (Charge / HRV / Rest / RHR), behind the header's circle.
    private var outcomeMenu: some View {
        Menu {
            Picker("Outcome metric", selection: $outcome) {
                ForEach(InsightsHubViewModel.Outcome.allCases) { o in
                    Text(o.label).tag(o)
                }
            }
        } label: {
            NoopCircleIcon("dots-three")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Outcome metric")
    }

    /// The hero glow follows the outcome being ranked.
    private var glow: NoopGlow {
        switch outcome {
        case .recovery:  return .recovery
        case .sleep:     return .sleep
        case .hrv, .rhr: return .heart
        }
    }

    // MARK: - Top finding

    /// The strongest ranked effect for the selected outcome, as the screen's hero.
    private func topFinding(_ r: RankedEffect) -> some View {
        let e = r.effect
        let total = e.nWith + e.nWithout
        return NoopHeroCard(glow: glow, padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge("Top finding", icon: "trophy")
                    Spacer(minLength: 8)
                    NoopPill(verbatim: String(localized: "\(total) days"), compact: true)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    NoopDotNumber(Self.signedWhole(e.delta), size: 92)
                    NoopTag(Self.scoreState(r.confidence).label)
                        .padding(.bottom, 8)
                }
                .padding(.top, 26)
                Text(r.sentence())
                    .font(StrandFont.light(17, relativeTo: .title3))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
                NoopMetricRow {
                    NoopMetric(value: outcome.valueText(e.meanWith), unit: outcome.unitText,
                               labelText: String(localized: "\(outcome.outcomeName) with"))
                    NoopMetric(value: outcome.valueText(e.meanWithout), unit: outcome.unitText,
                               labelText: String(localized: "\(outcome.outcomeName) without"))
                    NoopMetric(value: "\(e.nWith)", unit: String(localized: "of \(total)"),
                               labelText: String(localized: "Days with it"))
                }
                .padding(.top, 20)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(r.sentence()) Cohen's d \(String(format: "%.2f", e.cohensD)). \(Self.scoreState(r.confidence).accessibilityWord)"))
    }

    // MARK: - What moves your Charge (ranked, lag-aware)

    @ViewBuilder private var moversSection: some View {
        NoopSectionTitle("What moves your \(outcome.outcomeName)", captionKey: "Ranked")
        if model.ranked.isEmpty {
            NoopCard(padding: 18) {
                Text(String(localized: "Not enough overlap between your journal answers and \(outcome.outcomeName) yet. Keep logging. Each behaviour needs days both with and without it before NOOP can read its effect."))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            rankedCard
            Text(String(localized: "\(outcome.outcomeName) on days with / without each behaviour, at the lag where it shows most."))
                .font(StrandFont.light(11.5, relativeTo: .caption))
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, -2)
        }
    }

    /// The ranked feed as one card: behaviour + with/without, a diverging bar around zero, the effect.
    private var rankedCard: some View {
        let scale = Self.niceScale(model.ranked.map { abs($0.effect.delta) }.max() ?? 1)
        return VStack(spacing: 0) {
            MoverGrid {
                Text("Behaviour · with / without")
                    .font(StrandFont.light(10.5, relativeTo: .caption2))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } bar: {
                HStack {
                    Text(verbatim: "−\(Int(scale))")
                    Spacer()
                    Text(verbatim: "0")
                    Spacer()
                    Text(verbatim: "+\(Int(scale))")
                }
                .font(StrandFont.light(10, relativeTo: .caption2))
                .foregroundStyle(StrandPalette.textTertiary)
            } value: {
                Text(outcome.effectUnit)
                    .font(StrandFont.light(10.5, relativeTo: .caption2))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.bottom, 10)
            ForEach(Array(model.ranked.enumerated()), id: \.offset) { i, r in
                Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
                moverRow(index: i, r, scale: scale)
                    .padding(.vertical, 13)
                    .staggeredAppear(index: i)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 6)
        .noopPanel()
    }

    /// One ranked, lag-aware mover row. Sign-aware colour: did this behaviour move the outcome the GOOD
    /// way (green) or the bad way (red)?
    private func moverRow(index: Int, _ r: RankedEffect, scale: Double) -> some View {
        let e = r.effect
        let movedGood = (e.delta > 0) == outcome.higherIsBetter
        return MoverGrid {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(verbatim: "\(index + 1)")
                        .font(StrandFont.book(11, relativeTo: .caption2))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(width: 12, alignment: .leading)
                    // Behaviours are the journal's own question text, often a full sentence: three
                    // lines before truncating.
                    Text(r.behavior)
                        .font(StrandFont.book(14.5, relativeTo: .subheadline))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(3)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
                (Text(verbatim: outcome.valueText(e.meanWith)).foregroundColor(StrandPalette.textSecondary)
                 + Text(verbatim: " / \(outcome.valueText(e.meanWithout)) \(outcome.unitText) · ")
                 + Text(Self.effectMagnitudeWord(e.cohensD)))
                    .font(StrandFont.light(11, relativeTo: .caption2))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.leading, 20)
            }
        } bar: {
            DivergingEffectBar(fraction: e.delta / scale, good: e.delta == 0 ? nil : movedGood)
        } value: {
            Text(verbatim: Self.signedWhole(e.delta))
                .font(StrandFont.value(17))
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .accessibilityElement(children: .combine)
        // One whole-string key; the args are complete sentences, never concatenated tails.
        .accessibilityLabel(String(localized: "\(r.sentence()) Cohen's d \(String(format: "%.2f", e.cohensD)). \(Self.scoreState(r.confidence).accessibilityWord)"))
    }

    // MARK: - Alcohol / caffeine dose-response

    @ViewBuilder private var doseSection: some View {
        NoopSectionTitle("Dose-response", captionKey: "Personal curve")
        if model.doseCards.isEmpty {
            NoopCard(padding: 18) {
                Text(String(localized: "Log alcohol or late caffeine with an amount and NOOP fits a personal dose curve: how much each extra unit tends to move your numbers. Until then it shows typical patterns, clearly labelled as not yet yours."))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ForEach(Array(model.doseCards.enumerated()), id: \.element.id) { index, card in
                DoseResponseCardView(card: card, accent: glow.tint)
                    .staggeredAppear(index: index)
            }
        }
    }

    // MARK: - Helpers

    /// "−14" / "+6" / "0" with a true minus sign.
    static func signedWhole(_ v: Double) -> String {
        let n = Int(v.rounded())
        if n < 0 { return "−\(abs(n))" }
        return n > 0 ? "+\(n)" : "0"
    }

    /// A round axis bound at or above `v`: 5, 10, 15, 20, 30, 50, 100…
    static func niceScale(_ v: Double) -> Double {
        for step in [5.0, 10, 15, 20, 30, 50, 100, 200] where v <= step { return step }
        return (v / 100).rounded(.up) * 100
    }

    /// Map the engine's ScoreConfidence tier to the design-system ScoreState pill.
    static func scoreState(_ c: ScoreConfidence) -> ScoreState {
        switch c {
        case .solid:       return .solid
        case .building:    return .building
        case .calibrating: return .calibrating
        }
    }

    /// Cohen's d → conventional magnitude word.
    static func effectMagnitudeWord(_ d: Double) -> String {
        switch abs(d) {
        case ..<0.2: return String(localized: "negligible")
        case ..<0.5: return String(localized: "small")
        case ..<0.8: return String(localized: "moderate")
        default:     return String(localized: "large")
        }
    }
}

private extension ScoreState {
    /// VoiceOver-only certainty phrase for a mover row.
    var accessibilityWord: String {
        switch self {
        case .solid:       return String(localized: "Solid signal.")
        case .building:    return String(localized: "Building. Keep logging.")
        case .calibrating: return String(localized: "Calibrating. Too thin to read yet.")
        case .live:        return ""
        }
    }
}

private extension InsightsHubViewModel.Outcome {
    /// The bare number for a mean ("58").
    func valueText(_ v: Double) -> String { "\(Int(v.rounded()))" }
    /// The unit beside it ("%", "ms", "bpm").
    var unitText: String {
        switch self {
        case .recovery, .sleep: return "%"
        case .hrv:              return "ms"
        case .rhr:              return "bpm"
        }
    }
    /// The unit of an effect (a with − without difference).
    var effectUnit: LocalizedStringKey {
        switch self {
        case .recovery, .sleep: return "Pts"
        case .hrv:              return "ms"
        case .rhr:              return "bpm"
        }
    }
}

/// The three columns of the ranked feed (`.rk`): behaviour, the diverging bar, the effect.
private struct MoverGrid<Label: View, Bar: View, Value: View>: View {
    @ViewBuilder var label: () -> Label
    @ViewBuilder var bar: () -> Bar
    @ViewBuilder var value: () -> Value
    var body: some View {
        HStack(spacing: 10) {
            label().frame(width: 132, alignment: .leading)
            bar().frame(maxWidth: .infinity)
            value().frame(width: 40, alignment: .trailing)
        }
    }
}

/// A bar growing left (negative) or right (positive) of a zero rule (`.eb`): green when the move is the
/// good direction for the outcome, red when it is the bad one.
private struct DivergingEffectBar: View {
    /// Signed share of the half-width, −1…1.
    let fraction: Double
    let good: Bool?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, half = w / 2
            let f = min(max(fraction, -1), 1)
            let len = f == 0 ? 0 : max(abs(CGFloat(f)) * half, 6)
            let tint: Color = {
                guard let good else { return StrandPalette.textTertiary }
                return good ? NoopGlow.recovery.accent : NoopGlow.low.tint
            }()
            ZStack(alignment: .topLeading) {
                Capsule().fill(NoopVisualStyle.raised)
                    .frame(width: w, height: 2)
                    .offset(y: 10)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: f < 0 ? [tint.opacity(0.44), tint.opacity(0.18)]
                                                       : [tint.opacity(0.16), tint.opacity(0.4)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: len, height: 12)
                    .offset(x: f < 0 ? half - len : half, y: 5)
                Rectangle().fill(StrandPalette.textPrimary.opacity(0.22))
                    .frame(width: 1, height: 28)
                    .offset(x: half, y: -3)
            }
        }
        .frame(height: 22)
        .accessibilityHidden(true)
    }
}

// MARK: - Dose-response card
//
// The headline alcohol/caffeine surface: the prior-shrunk curve, the per-unit read,
// the confidence word, the honesty note, and an evening "damage forecast" preview
// driven by a tiny dose stepper. The forecast is a what-if on the user's own latest
// Charge — "a 2nd drink tonight tends to line up with about −7 on tomorrow's Charge
// for you" — never a recommendation to drink or abstain.

private struct DoseResponseCardView: View {
    let card: InsightsHubViewModel.DoseCard
    /// The screen's one accent (the hero glow's), for the curve.
    let accent: Color

    /// The "what if I have one more" preview dose, defaulting to one above the typical
    /// starting point so the headline reads as a 2nd-drink forecast out of the box.
    @State private var previewDose: Int = 2

    var body: some View {
        let r = card.response
        VStack(alignment: .leading, spacing: 12) {
            NoopCard(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    NoopCardHeader(verbatim: card.title, icon: card.icon) {
                        Text(InsightsHubView.scoreState(r.confidence).label)
                    }
                    // The engine's honest read sentence (prior / yours / contradicts-prior).
                    Text(r.sentence())
                        .font(StrandFont.light(14, relativeTo: .subheadline))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)

                    // The prior-shrunk curve (dose on x, modelled outcome Δ on y).
                    DoseCurveChart(points: r.curve, accent: accent, cursorDose: previewDose,
                                   doseLabel: { card.doseChoiceLabel($0) })
                        .frame(height: 150)
                        .padding(.top, 6)
                        .accessibilityLabel(curveAccessibilityLabel(r))
                    Text(card.axisCaption)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.leading, 24)

                    if r.priorDominated {
                        NoopInsightRow(verbatim: card.priorDominatedNote,
                                       icon: "info")
                    } else if r.contradictsPrior {
                        NoopInsightRow(verbatim: String(localized: "In your data so far, this doesn\u{2019}t move your \(card.outcomeLabel) the way it typically does."),
                                       icon: "info")
                    }
                    if card.timingProxy {
                        Text("\u{201C}Dose\u{201D} here is timing (later in the day = stronger), not milligrams.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
                    forecastControls(r)
                }
            }
            forecastTiles(r)
        }
    }

    // MARK: Evening damage forecast (what-if on the user's latest Charge)

    /// The Δ of going from the typical starting dose (1) to the previewed dose.
    private func forecastDelta(_ r: DoseResponse) -> Double { r.delta(fromDose: 1, toDose: previewDose) }
    /// That Δ applied to the user's most recent outcome value as an honest "where you'd likely land".
    private func projected(_ r: DoseResponse) -> Double? {
        card.latestOutcome.map { max(0, min(card.outcomeCeiling, $0 + forecastDelta(r))) }
    }
    private var stepLabel: String {
        previewDose <= 1 ? String(localized: "no extra") : card.stepLabel(previewDose)
    }

    @ViewBuilder private func forecastControls(_ r: DoseResponse) -> some View {
        NoopOverline(verbatim: card.forecastOverline)
        SegmentedPillControl(card.doseChoices, selection: $previewDose, fillsAvailableWidth: true) {
            card.doseChoiceLabel($0)
        }
        .accessibilityLabel("Preview dose")
        Text(forecastSentence(delta: forecastDelta(r)))
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func forecastTiles(_ r: DoseResponse) -> some View {
        let p = projected(r)
        return HStack(alignment: .top, spacing: 12) {
            forecastTile(icon: "clock-countdown",
                         title: Text("Per extra \(card.unitNoun)"),
                         value: signed(r.perUnit),
                         unit: card.outcomeUnit,
                         caption: r.priorDominated ? String(localized: "typical") : String(localized: "your data"))
            forecastTile(icon: "lightning",
                         title: Text("Tomorrow\u{2019}s \(card.outcomeLabel)"),
                         value: p.map { "\(Int($0.rounded()))" } ?? "—",
                         unit: p == nil ? nil : card.outcomeUnit,
                         caption: p != nil ? String(localized: "projected · \(stepLabel)") : String(localized: "needs a recent day"))
        }
    }

    private func forecastTile(icon: String, title: Text, value: String, unit: String?, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                PhIcon(icon, size: 16).opacity(0.9)
                // Two lines rather than "Pro zusätzlichem spä…" in longer languages.
                title.font(StrandFont.book(14, relativeTo: .subheadline))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(StrandPalette.textPrimary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value)
                    .font(StrandFont.light(26, relativeTo: .title2))
                    .tracking(-0.5)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let unit {
                    Text(verbatim: unit)
                        .font(StrandFont.book(11, relativeTo: .caption2))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .padding(.top, 12)
            Text(verbatim: caption)
                .font(StrandFont.light(10.5, relativeTo: .caption2))
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .noopPanel()
        .accessibilityElement(children: .combine)
    }

    /// Whole sentences per behaviour and direction, then the basis as its own sentence, so no translation
    /// has to inflect a stitched-in noun ("beim morgigen charge", "deiner getränk Tage"). The comparison is
    /// named: the preview is measured against one drink, or against caffeine by noon.
    private func forecastSentence(delta: Double) -> String {
        let outcome = card.outcomeLabel
        if previewDose <= 1 {
            return card.behavior == .caffeine
                ? String(localized: "Caffeine by noon: your \(outcome) forecast stays where it is.")
                : String(localized: "No extra tonight. Your \(outcome) forecast stays where it is.")
        }
        let magText = "\(Int(abs(delta).rounded()))\(card.outcomeSuffix)"
        let lower = delta <= 0
        let move: String
        switch card.behavior {
        case .alcohol:
            move = lower
                ? String(localized: "\(stepLabel) tonight instead of one: about \(magText) lower \(outcome) tomorrow.")
                : String(localized: "\(stepLabel) tonight instead of one: about \(magText) higher \(outcome) tomorrow.")
        case .caffeine:
            let late = previewDose >= DoseResponseEngine.maxCurveDose
                ? String(localized: "Evening caffeine") : String(localized: "Caffeine after 2pm")
            move = lower
                ? String(localized: "\(late) instead of by noon: about \(magText) lower \(outcome) tomorrow.")
                : String(localized: "\(late) instead of by noon: about \(magText) higher \(outcome) tomorrow.")
        }
        return "\(move) \(card.basisSentence)"
    }

    // MARK: Bits

    private func signed(_ v: Double) -> String {
        let mag = abs(v)
        let rounded = (mag * 10).rounded() / 10
        let sign = v < 0 ? "−" : (v > 0 ? "+" : "")
        // Show whole numbers without a trailing .0 for the small Charge magnitudes.
        let body = rounded == rounded.rounded() ? "\(Int(rounded))" : String(format: "%.1f", rounded)
        return "\(sign)\(body)"
    }

    /// Whole-string key per variant (never a concatenated localized tail on an a11y label).
    private func curveAccessibilityLabel(_ r: DoseResponse) -> String {
        let perUnit = signed(r.perUnit) + card.outcomeSuffix
        return r.priorDominated
            ? String(localized: "Dose-response curve. Each extra \(card.unitNoun) lines up with about \(perUnit) on \(card.outcomeLabel), typical patterns.")
            : String(localized: "Dose-response curve. Each extra \(card.unitNoun) lines up with about \(perUnit) on \(card.outcomeLabel), your own data.")
    }
}

// MARK: - Dose curve chart
//
// The prior-shrunk curve: dose on x (0…max), the modelled outcome DELTA on y, in the v2 chart idiom
// (1.2 pt line over a fading fill, hairline grid at the top, zero and bottom, the previewed dose marked
// with a dashed cursor and a white dot). Symmetric around zero so the sign reads honestly.

private struct DoseCurveChart: View {
    let points: [DoseCurvePoint]
    let accent: Color
    let cursorDose: Int
    let doseLabel: (Int) -> String

    var body: some View {
        let deltas = points.map(\.outcomeDelta)
        let maxAbs = max(1.0, (deltas.map(abs).max() ?? 1.0)).rounded(.up)
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading) {
                    Text(verbatim: "+\(Int(maxAbs))")
                    Spacer()
                    Text(verbatim: "0")
                    Spacer()
                    Text(verbatim: "−\(Int(maxAbs))")
                }
                .font(StrandFont.light(10, relativeTo: .caption2))
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 18, alignment: .leading)
                plot(maxAbs: maxAbs)
            }
            HStack {
                ForEach(points.indices, id: \.self) { i in
                    Text(verbatim: doseLabel(points[i].dose))
                        .foregroundStyle(points[i].dose == cursorDose ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    if i < points.count - 1 { Spacer(minLength: 0) }
                }
            }
            .font(StrandFont.light(11, relativeTo: .caption2))
            .padding(.leading, 24)
        }
        .accessibilityElement()
    }

    private func plot(maxAbs: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let yFor: (Double) -> CGFloat = { d in h - CGFloat((d / maxAbs + 1) / 2) * h }
            let n = max(1, points.count - 1)
            let xFor: (Int) -> CGFloat = { i in CGFloat(i) / CGFloat(n) * w }
            let zeroY = yFor(0)
            let cursorIndex = points.firstIndex { $0.dose == cursorDose }

            ZStack(alignment: .topLeading) {
                // Hairline grid at the top, the zero line and the bottom.
                ForEach([CGFloat(0), zeroY, h - 1], id: \.self) { y in
                    Rectangle().fill(StrandPalette.textPrimary.opacity(y == zeroY ? 0.1 : 0.05))
                        .frame(width: w, height: 1)
                        .offset(y: y)
                }
                // Filled area between the curve and the zero line.
                Path { p in
                    guard !points.isEmpty else { return }
                    p.move(to: CGPoint(x: xFor(0), y: zeroY))
                    for (i, pt) in points.enumerated() {
                        p.addLine(to: CGPoint(x: xFor(i), y: yFor(pt.outcomeDelta)))
                    }
                    p.addLine(to: CGPoint(x: xFor(points.count - 1), y: zeroY))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [accent.opacity(0.34), accent.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
                // The curve line.
                Path { p in
                    for (i, pt) in points.enumerated() {
                        let point = CGPoint(x: xFor(i), y: yFor(pt.outcomeDelta))
                        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                    }
                }
                .stroke(accent.opacity(0.85), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                // Dose markers.
                ForEach(points.indices, id: \.self) { i in
                    Circle()
                        .fill(StrandPalette.textPrimary.opacity(0.28))
                        .frame(width: 4.4, height: 4.4)
                        .position(x: xFor(i), y: yFor(points[i].outcomeDelta))
                }
                // The previewed dose.
                if let c = cursorIndex {
                    let p = CGPoint(x: xFor(c), y: yFor(points[c].outcomeDelta))
                    Path { path in
                        path.move(to: p)
                        path.addLine(to: CGPoint(x: p.x, y: h))
                    }
                    .stroke(StrandPalette.textPrimary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    Circle().fill(StrandPalette.textPrimary).frame(width: 7, height: 7).position(p)
                }
            }
        }
    }
}

// MARK: - View-model
//
// Self-contained: loads the journal (behaviour → days), dose rows (under the dedicated
// noop-journal-dose source), and the outcome series (imported metricSeries ∪ DailyMetric
// fallback, exactly as InsightsView), then runs EffectRanker for the ranked feed and
// DoseResponseEngine for each dosed behaviour the user has data for. No edits to AppModel.

@MainActor
final class InsightsHubViewModel: ObservableObject {

    // MARK: Outcome

    enum Outcome: String, CaseIterable, Identifiable {
        case recovery, hrv, sleep, rhr
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recovery: return String(localized: "Charge")
            case .hrv:      return "HRV"
            case .sleep:    return String(localized: "Rest")
            case .rhr:      return "RHR"
            }
        }
        /// metricSeries key.
        var key: String {
            switch self {
            case .recovery: return "recovery"
            case .hrv:      return "hrv"
            case .sleep:    return "sleep_performance"
            case .rhr:      return "rhr"
            }
        }
        /// The engine's outcome label (carried onto each RankedEffect).
        var outcomeName: String {
            switch self {
            case .recovery: return String(localized: "Charge")
            case .hrv:      return "HRV"
            case .sleep:    return String(localized: "Rest")
            case .rhr:      return String(localized: "Resting HR")
            }
        }
        var higherIsBetter: Bool { self != .rhr }
        var domain: DomainTheme {
            switch self {
            case .recovery: return .charge
            case .hrv, .sleep: return .rest
            case .rhr: return .stress
            }
        }
        func format(_ v: Double) -> String {
            switch self {
            case .recovery, .sleep: return "\(Int(v.rounded()))%"
            case .hrv:              return "\(Int(v.rounded())) ms"
            case .rhr:              return "\(Int(v.rounded())) bpm"
            }
        }
    }

    // MARK: Published state

    @Published private(set) var loaded = false
    @Published private(set) var ranked: [RankedEffect] = []
    @Published private(set) var doseCards: [DoseCard] = []

    // MARK: Loaded inputs (kept so the outcome segmented control can re-rank cheaply)

    private var behaviours: [String: Set<String>] = [:]
    /// Per behaviour, the days it was logged NO — the only legitimate control group.
    private var controls: [String: Set<String>] = [:]
    private var outcomeByKey: [String: [String: Double]] = [:]
    private var currentOutcome: Outcome = .recovery

    /// The source id dose rows are parked under (mirrors MoodStore's noop-mood isolation).
    static let doseSource = "noop-journal-dose"

    private let outcomeKeys = ["recovery", "hrv", "sleep_performance", "rhr"]

    // MARK: Load

    func load(repo: Repository) async {
        // Journal → behaviour → days (only "yes" answers count as the behaviour occurring).
        let entries = await repo.journalEntries()
        // Yes days and NO days, kept apart. A day with no journal row for the question lands in
        // neither, so an unanswered day is never counted as a No (BehaviorInsights.effect).
        var byBehaviour: [String: Set<String>] = [:]
        var controlsByBehaviour: [String: Set<String>] = [:]
        for e in entries {
            if e.answeredYes { byBehaviour[e.question, default: []].insert(e.day) }
            else { controlsByBehaviour[e.question, default: []].insert(e.day) }
        }

        // Outcome series: imported metricSeries ∪ the DailyMetric column fallback so an
        // account-free (strap-only) user still gets effects — the exact contract InsightsView uses.
        let mergedDays = repo.days
        var byKey: [String: [String: Double]] = [:]
        for key in outcomeKeys {
            let s = await repo.series(key: key, source: "my-whoop")
            var dict: [String: Double] = [:]
            for row in s { dict[row.day] = row.value }
            for d in mergedDays where dict[d.day] == nil {
                if let v = Self.dailyOutcome(key: key, day: d) { dict[d.day] = v }
            }
            byKey[key] = dict
        }

        // Dose rows per dosed behaviour, under the dedicated dose source, keyed by the
        // behaviour's storage key. A logged "yes" with no dose row reads as dose = 1
        // (back-compatible), so we union the behaviour's logged days at dose 1 with any
        // explicit dose rows (explicit wins).
        var doseByBehaviour: [DosedBehavior: [String: Int]] = [:]
        for behavior in DosedBehavior.allCases {
            let key = Self.doseKey(for: behavior)
            let rows = await repo.series(key: key, source: Self.doseSource)
            var doses: [String: Int] = [:]
            // Back-compat: any logged "yes" day for a matching journal question starts at dose 1.
            for (question, days) in byBehaviour where Self.matches(behavior, question: question) {
                for day in days { doses[day] = max(doses[day] ?? 0, 1) }
            }
            // Explicit dose rows override.
            for row in rows { doses[row.day] = Int(row.value.rounded()) }
            if !doses.isEmpty { doseByBehaviour[behavior] = doses }
        }

        // Build the dose cards from the engine (alcohol first, then caffeine).
        var cards: [DoseCard] = []
        for behavior in DosedBehavior.allCases {
            guard let doses = doseByBehaviour[behavior] else { continue }
            let outcomeName = DoseResponsePriors.defaultOutcome(for: behavior)
            let outcomeKey = Self.outcomeKey(forEngineName: outcomeName)
            let outcomeDays = byKey[outcomeKey] ?? [:]
            guard let response = DoseResponseEngine.estimate(behavior: behavior,
                                                             doseByDay: doses,
                                                             outcomeByDay: outcomeDays) else { continue }
            let latest = outcomeDays.keys.max().flatMap { outcomeDays[$0] }
            cards.append(DoseCard(behavior: behavior, response: response, latestOutcome: latest))
        }

        self.behaviours = byBehaviour
        self.controls = controlsByBehaviour
        self.outcomeByKey = byKey
        self.doseCards = cards
        self.loaded = true
        rankFor(currentOutcome)
    }

    /// Re-rank the mover feed for a (possibly new) outcome selection — cheap, no DB.
    func rankFor(_ outcome: Outcome) {
        currentOutcome = outcome
        let outcomeDays = outcomeByKey[outcome.key] ?? [:]
        ranked = EffectRanker.rank(behaviors: behaviours,
                                   controls: controls,
                                   outcomeByDay: outcomeDays,
                                   outcome: outcome.outcomeName)
    }

    // MARK: Static shaping helpers

    /// The merged DailyMetric column backing an outcome key (strap-only fallback). sleep_performance
    /// has no daily column, so it stays import-only — never seeded here (matches InsightsView).
    private static func dailyOutcome(key: String, day d: DailyMetric) -> Double? {
        switch key {
        case "recovery": return d.recovery
        case "hrv":      return d.avgHrv
        case "rhr":      return d.restingHr.map(Double.init)
        default:         return nil
        }
    }

    /// The metricSeries key a DoseResponsePriors outcome NAME maps to ("Charge"→recovery, "HRV"→hrv).
    static func outcomeKey(forEngineName name: String) -> String {
        switch name {
        case "Charge": return "recovery"
        case "HRV":    return "hrv"
        case "Rest":   return "sleep_performance"
        case "Resting HR": return "rhr"
        default:       return "recovery"
        }
    }

    /// The dose storage key for a behaviour (its raw enum value — the stable, cross-platform key).
    static func doseKey(for behavior: DosedBehavior) -> String { "dose_\(behavior.rawValue)" }

    /// Whether a journal question is the dosed behaviour (so its yes-days back-fill dose = 1).
    static func matches(_ behavior: DosedBehavior, question: String) -> Bool {
        let q = question.lowercased()
        switch behavior {
        case .alcohol:  return q.contains("alcohol") || q.contains("drink")
        case .caffeine: return q.contains("caffeine") || q.contains("coffee")
        }
    }

    // MARK: Dose card view-data

    struct DoseCard: Identifiable {
        let behavior: DosedBehavior
        let response: DoseResponse
        /// The user's most recent outcome value (for the evening damage forecast anchor).
        let latestOutcome: Double?

        var id: String { behavior.rawValue }
        /// The engine's outcome name ("Charge", "HRV"): an identifier, compared below for units.
        var outcomeName: String { response.outcome }
        /// The outcome as the reader's language names it, for every printed sentence.
        var outcomeLabel: String {
            switch outcomeName {
            case "Charge":     return String(localized: "Charge")
            case "Rest":       return String(localized: "Rest")
            case "Resting HR": return String(localized: "Resting HR")
            default:           return outcomeName
            }
        }
        /// What the forecast stands on, as its own sentence.
        var basisSentence: String {
            if response.priorDominated { return String(localized: "Based on typical patterns.") }
            switch behavior {
            case .alcohol:  return String(localized: "Based on \(response.nUser) of your drinking days.")
            case .caffeine: return String(localized: "Based on \(response.nUser) of your late-caffeine days.")
            }
        }
        /// The prior-dominated note, whole per behaviour for the same reason.
        var priorDominatedNote: String {
            switch behavior {
            case .alcohol:
                return String(localized: "Based mostly on typical patterns, not yet yours. Log a few more drinking days and this becomes yours.")
            case .caffeine:
                return String(localized: "Based mostly on typical patterns, not yet yours. Log a few more late-caffeine days and this becomes yours.")
            }
        }

        var title: String {
            switch behavior {
            case .alcohol:  return String(localized: "Alcohol")
            case .caffeine: return String(localized: "Caffeine")
            }
        }
        /// The Phosphor icon on the card header.
        var icon: String {
            switch behavior {
            case .alcohol:  return "wine"
            case .caffeine: return "coffee"
            }
        }
        /// The outcome unit beside a tile value ("%", "ms").
        var outcomeUnit: String { outcomeName == "HRV" ? "ms" : "%" }
        /// The chart's axis caption: what runs along the bottom, and what the curve measures.
        var axisCaption: String {
            switch behavior {
            case .alcohol:  return String(localized: "Drinks → change in tomorrow\u{2019}s \(outcomeLabel)")
            case .caffeine: return String(localized: "Last caffeine, earlier to later → change in tomorrow\u{2019}s \(outcomeLabel)")
            }
        }
        /// The unit shown in copy ("drink" / "later step").
        var unitNoun: String {
            switch behavior {
            case .alcohol:  return String(localized: "drink")
            case .caffeine: return String(localized: "later step")
            }
        }
        var timingProxy: Bool { behavior == .caffeine }

        /// Outcome units suffix for the forecast tiles.
        var outcomeSuffix: String { outcomeName == "HRV" ? " ms" : "%" }
        /// Clamp ceiling for the projected outcome (Charge/Rest are 0–100; HRV uncapped-ish).
        var outcomeCeiling: Double { outcomeName == "HRV" ? 400 : 100 }

        var forecastOverline: String {
            switch behavior {
            case .alcohol:  return String(localized: "Tonight\u{2019}s forecast")
            case .caffeine: return String(localized: "Timing forecast")
            }
        }

        /// The dose choices the evening stepper offers (0/1/2/3 → 0…maxCurveDose).
        var doseChoices: [Int] { Array(0...DoseResponseEngine.maxCurveDose) }
        func doseChoiceLabel(_ d: Int) -> String {
            switch behavior {
            case .alcohol:  return d >= DoseResponseEngine.maxCurveDose ? "\(d)+" : "\(d)"
            case .caffeine:
                // Timing buckets, not counts.
                switch d {
                case 0: return String(localized: "AM")
                case 1: return String(localized: "Noon")
                case 2: return String(localized: "2pm+")
                default: return String(localized: "Eve")
                }
            }
        }
        /// The whole dose phrase for forecast copy (alcohol counts; caffeine names its timing bucket, as
        /// the stepper does, rather than the bare bucket index). Whole-string keys per variant, never a
        /// stitched "+ drinks" suffix.
        func stepLabel(_ d: Int) -> String {
            switch behavior {
            case .alcohol:
                return d >= DoseResponseEngine.maxCurveDose ? String(localized: "\(d)+ drinks")
                                                            : String(localized: "\(d) drinks")
            case .caffeine:
                return doseChoiceLabel(d)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func hubPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Insights Hub") {
    InsightsHubView()
        .environmentObject(hubPreviewRepo())
        .frame(width: 920, height: 980)
        .preferredColorScheme(.dark)
}
#endif
