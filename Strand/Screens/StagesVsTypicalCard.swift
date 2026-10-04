import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Stages vs typical (#today-hosted-cards)
//
// The Sleep tab's "Stages vs typical" card, extracted into a standalone view so it can ALSO be hosted in
// the Today tab. Both the Sleep tab and the Today host render THIS view from the SAME `SleepModel`, so the
// per-stage last-night-vs-typical bars can never diverge between the two surfaces (the parity contract).
// The per-stage typical means are computed once in `SleepModel.build` and read here; the shares come from
// `SleepStageShares`, the one apportionment every stage percentage on the Sleep screen uses.

/// The "Stages vs typical" card. Renders last night's Deep/REM/Light against the wearer's personal
/// per-stage means from the shared [SleepModel], as shares of the time asleep on one common scale.
struct StagesVsTypicalCard: View {
    let model: SleepModel

    var body: some View {
        let s = model.night.stages
        let shares = SleepStageShares.asleepPercents(s)
        let typicalShares = SleepStageShares.typicalPercents(StageTypicals(model: model))
        let rows = [
            StageRow(stage: .deep, label: String(localized: "Deep"), minutes: s.deep, typicalMin: model.typicalDeepMin,
                     share: shares?.deep, typicalShare: typicalShares?.deep),
            StageRow(stage: .rem, label: String(localized: "REM"), minutes: s.rem, typicalMin: model.typicalRemMin,
                     share: shares?.rem, typicalShare: typicalShares?.rem),
            StageRow(stage: .light, label: String(localized: "Light"), minutes: s.light, typicalMin: model.typicalLightMin,
                     share: shares?.light, typicalShare: typicalShares?.light),
        ]
        let axisMax = Self.axisMax(rows)
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("Stages vs typical", captionKey: "Last night")
            NoopCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        if i > 0 { Rectangle().fill(NoopVisualStyle.divider).frame(height: 1) }
                        stageRow(row, axisMax: axisMax)
                            .padding(.top, i == 0 ? 2 : 14)
                            .padding(.bottom, 14)
                    }
                    axis(axisMax)
                        .padding(.top, 4)
                }
            }
        }
    }

    /// One stage, as it is about to be drawn.
    private struct StageRow {
        let stage: SleepStage
        let label: String
        let minutes: Double
        let typicalMin: Double?
        let share: Int?
        let typicalShare: Int?
    }

    /// The common scale every row is drawn against: 70 % of time asleep, widened to the next 10 % when a
    /// night or a typical runs past it, so the bars of different stages can be compared by length.
    private static func axisMax(_ rows: [StageRow]) -> Int {
        let top = rows.flatMap { [$0.share, $0.typicalShare] }.compactMap { $0 }.max() ?? 0
        return Swift.max(70, Int((Double(top) / 10).rounded(.up)) * 10)
    }

    /// One stage row: a swatch, the stage and its minutes against typical, then a bar of the night's share
    /// with the hatched typical mark ("solid = you, hatch = the context"), and the share and typical below.
    @ViewBuilder
    private func stageRow(_ row: StageRow, axisMax: Int) -> some View {
        let color = StrandPalette.sleepStageColor(row.stage)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                Text(verbatim: row.label)
                    .font(StrandFont.book(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                if let delta = deltaText(row) {
                    Text(verbatim: delta)
                        .font(StrandFont.light(13))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
            }
            StageShareBar(share: row.share, typicalShare: row.typicalShare, axisMax: axisMax, color: color)
                .padding(.top, 14)
            HStack(spacing: 8) {
                shareCaption(row)
                Spacer(minLength: 8)
                if let typical = row.typicalShare {
                    Text("Typical \(typical) %")
                }
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.top, 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stageRowAccessibilityLabel(row))
    }

    /// "24 % · 1:42 h", the share in secondary ink so it reads before the duration.
    private func shareCaption(_ row: StageRow) -> Text {
        let duration = Text(verbatim: " · \(hoursMinutes(row.minutes)) h")
        guard let share = row.share else { return duration }
        return Text(verbatim: "\(share) %").foregroundColor(StrandPalette.textSecondary) + duration
    }

    /// "+12m" / "−18m": last night's minutes against the personal mean for this stage.
    private func deltaText(_ row: StageRow) -> String? {
        guard let typical = row.typicalMin, typical > 0 else { return nil }
        let diff = row.minutes - typical
        return SleepTileCaption.signed(diff, durationText(Swift.abs(diff)))
    }

    private func axis(_ axisMax: Int) -> some View {
        HStack {
            Text(verbatim: "0 %")
            Spacer()
            Text(verbatim: "\(axisMax / 2) %")
            Spacer()
            Text("\(axisMax) % of time asleep")
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .accessibilityHidden(true)
    }

    /// Whole-string VoiceOver label for a stage row: one key per variant, never a stitched tail fragment.
    private func stageRowAccessibilityLabel(_ row: StageRow) -> String {
        let share = row.share ?? 0
        if let typical = row.typicalMin, typical > 0 {
            return String(localized: "\(row.label): \(durationText(row.minutes)) last night, \(share) percent of time asleep, typical \(durationText(typical))")
        }
        return String(localized: "\(row.label): \(durationText(row.minutes)) last night, \(share) percent of time asleep")
    }

    /// Minutes → "H:MM", the v2 duration form ("1:42").
    private func hoursMinutes(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    /// Minutes → "Xm" / "Yh Zm" (verbatim of `SleepView.durationText`). Kept local to the card so it renders
    /// identically whether hosted in Today or shown in the Sleep tab.
    private func durationText(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return String(localized: "\(m)m") }
        return String(localized: "\(m / 60)h \(m % 60)m")
    }
}

/// A stage's share bar: the night's share as a solid fill in the stage colour on a slim track, with the
/// hatched mark at the typical share on top of it. Both are fractions of the card's common `axisMax`.
private struct StageShareBar: View {
    let share: Int?
    let typicalShare: Int?
    let axisMax: Int
    let color: Color

    private let height: CGFloat = 12
    /// The typical mark's width: a mean, not a range (see `SleepHatchWindow`).
    private let markWidth: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(NoopVisualStyle.raised)
                if let share, share > 0 {
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: Swift.max(height, w * fraction(share)))
                }
                if let typicalShare {
                    SleepHatchWindow(cornerRadius: 5)
                        .frame(width: markWidth, height: height + 8)
                        .offset(x: Swift.min(Swift.max(w * fraction(typicalShare) - markWidth / 2, 0), w - markWidth))
                }
            }
            .frame(width: w, height: height)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func fraction(_ pct: Int) -> CGFloat {
        CGFloat(Swift.min(Swift.max(Double(pct) / Double(Swift.max(axisMax, 1)), 0), 1))
    }
}
