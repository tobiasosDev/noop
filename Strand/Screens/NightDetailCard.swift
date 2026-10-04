import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Night detail (#today-hosted-cards)
//
// The Sleep tab's "Night detail" metric grid, extracted into a standalone view so it can ALSO be hosted
// in the Today tab. Both the Sleep tab and the Today host render THIS view from the SAME `SleepModel`, so
// the per-metric latest value / typical caption can never diverge between the two surfaces (the parity
// contract). The value and caption helpers (`pctValue` / `rrValue` / `tileCaption`) are a lift of the
// former `SleepView.metricGrid` helpers; the seven series are computed once in `SleepModel.build` and read
// here. The tile language (`SleepMetricTile`, `SleepRangeBar`, `SleepHatchWindow`) is shared with the
// single-metric Today cards and the Stages-vs-typical card.

/// The "Night detail" card. A two-column grid of v2 tiles (Sleep debt, Rest, Efficiency, Consistency,
/// Hours vs needed, Restorative), each with its latest value and a signed delta against the wearer's
/// typical, then a full-width Respiratory rate tile that places the latest rate on a scale of recent
/// nights, rendered from the shared [SleepModel].
struct NightDetailCard: View {
    let model: SleepModel

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("Night detail", captionKey: "Metrics · vs typical")
            VStack(spacing: NoopMetrics.rowSpacing) {
                tileGrid
                respiratoryTile
            }
        }
    }

    /// Six peer metrics in the frame's 2 × 3 order. A `Grid` rather than a `LazyVGrid` so every tile in a
    /// row takes the row's height: a carried-date caption that wraps must not leave its neighbour short.
    private var tileGrid: some View {
        // All seven series are computed ONCE in the model build (each a full pass over repo.days /
        // repo.sleeps) — here we only read the memoized results.
        let perf = model.performance
        let eff  = model.efficiency
        let cons = model.consistency
        let need = model.hoursVsNeeded
        let rest = model.restorative
        let debt = model.sleepDebt
        return Grid(horizontalSpacing: NoopMetrics.rowSpacing, verticalSpacing: NoopMetrics.rowSpacing) {
            GridRow {
                SleepMetricTile(title: "Sleep debt", icon: "hourglass-medium",
                                value: debtValue(debt.latest).value, unit: debtValue(debt.latest).unit,
                                caption: debtCaption(debt))
                SleepMetricTile(title: "Rest", icon: "moon-stars",
                                value: wholeValue(perf.latest), unit: nil,
                                caption: tileCaption(perf))
            }
            GridRow {
                SleepMetricTile(title: "Efficiency", icon: "funnel-simple",
                                value: wholeValue(eff.latest), unit: eff.latest.map { _ in "%" },
                                caption: tileCaption(eff))
                SleepMetricTile(title: "Consistency", icon: "calendar-check",
                                value: wholeValue(cons.latest), unit: cons.latest.map { _ in "%" },
                                caption: tileCaption(cons))
            }
            GridRow {
                SleepMetricTile(title: "Hours vs needed", icon: "target",
                                value: wholeValue(need.latest), unit: need.latest.map { _ in "%" },
                                caption: tileCaption(need))
                SleepMetricTile(title: "Restorative", icon: "leaf",
                                value: wholeValue(rest.latest), unit: rest.latest.map { _ in "%" },
                                caption: tileCaption(rest))
            }
        }
    }

    private var respiratoryTile: some View {
        let resp = model.respiratory
        return SleepMetricTile(title: "Respiratory rate", icon: "wind",
                               value: rrValue(resp.latest), unit: resp.latest.map { _ in String(localized: "rpm") },
                               caption: tileCaption(resp, decimals: 1)) {
            if let scale = SleepRangeBar.respiratoryScale(resp) {
                scale.frame(width: 150)
            }
        }
    }

    // MARK: - Tile formatting (lifted from the metricGrid-only SleepView helpers)

    /// A whole-number value, or an em dash when there is none.
    private func wholeValue(_ v: Double?) -> String {
        v.map { "\(Int($0.rounded()))" } ?? "—"
    }

    private func rrValue(_ v: Double?) -> String {
        v.map { String(format: "%.1f", $0) } ?? "—"
    }

    /// Sleep debt split into the number and its unit: "38" + "m" below an hour, "1:12" + "h" above it.
    private func debtValue(_ minutes: Double?) -> (value: String, unit: String?) {
        guard let minutes else { return ("—", nil) }
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return ("\(m)", String(localized: "m")) }
        return (String(format: "%d:%02d", m / 60, m % 60), String(localized: "h"))
    }

    private func tileCaption(_ metric: SleepModel.Metric, decimals: Int = 0) -> SleepTileCaption {
        SleepTileCaption.make(latestDay: metric.latestDay, latest: metric.latest, typical: metric.typical) { diff in
            decimals == 0 ? "\(Int(diff.rounded()))" : String(format: "%.\(decimals)f", diff)
        }
    }

    /// The debt delta prints in minutes ("−9m", "+1h 5m"), the unit the debt itself is read in.
    private func debtCaption(_ metric: SleepModel.Metric) -> SleepTileCaption {
        SleepTileCaption.make(latestDay: metric.latestDay, latest: metric.latest, typical: metric.typical) {
            durationText($0)
        }
    }

    /// Minutes → "Xm" / "Yh Zm" (verbatim of `SleepView.durationText`). Kept local to the card so it
    /// renders identically whether hosted in Today or shown in the Sleep tab.
    private func durationText(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return String(localized: "\(m)m") }
        return String(localized: "\(m / 60)h \(m % 60)m")
    }
}

func nightDetailDebtCaption(_ debt: Double?) -> String {
    guard let debt else { return String(localized: "vs need") }
    return debt < SleepDebt.onTargetBandMin ? String(localized: "On target") : String(localized: "Below need")
}

func nightDetailDebtColor(_ debt: Double?) -> Color {
    guard let debt else { return StrandPalette.textPrimary }
    switch debt {
    case ..<SleepDebt.onTargetBandMin: return StrandPalette.statusPositive
    case ..<60: return StrandPalette.statusWarning
    default: return StrandPalette.statusCritical
    }
}

// MARK: - Shared v2 tile language

/// The v2 `.tile` geometry: a smaller radius and tighter inset than a full card, so a grid of them reads
/// as one block of figures rather than a stack of cards.
enum SleepTileMetrics {
    static let radius: CGFloat = 22
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 14
}

/// What a tile prints under its value.
enum SleepTileCaption {
    /// #1946: the value was carried from a prior day, stamped "Carried · <date>" so it is never passed
    /// off as tonight's read.
    case carried(String)
    /// The signed difference from the wearer's typical ("+6", "−9m"), shown before "vs typical".
    case delta(String)
    /// No typical to compare against yet.
    case noTypical

    /// The carry stamp wins; otherwise the signed latest-minus-typical delta, with `magnitude` formatting
    /// the absolute difference. A zero typical has nothing meaningful to compare against.
    static func make(latestDay: String?, latest: Double?, typical: Double?,
                     magnitude: (Double) -> String) -> SleepTileCaption {
        if let carried = SleepModel.carriedMetricCaption(latestDay: latestDay, latest: latest) {
            return .carried(carried)
        }
        guard let latest, let typical, typical != 0 else { return .noTypical }
        let diff = latest - typical
        return .delta(signed(diff, magnitude(Swift.abs(diff))))
    }

    /// A sign before the formatted magnitude, dropped when the magnitude rounds to zero so a −0.3 never
    /// prints as "−0".
    static func signed(_ diff: Double, _ formatted: String) -> String {
        if formatted.filter(\.isNumber).allSatisfy({ $0 == "0" }) { return formatted }
        return (diff >= 0 ? "+" : "−") + formatted
    }

    /// The caption as one localizable line, the delta set in ink and the rest in tertiary ink.
    var text: Text {
        switch self {
        case .carried(let stamp):
            return Text(verbatim: stamp)
        case .delta(let delta):
            let figure = Text(verbatim: delta)
                .font(StrandFont.book(11))
                .foregroundColor(StrandPalette.textPrimary)
            return Text("\(figure) vs typical")
        case .noTypical:
            return Text(verbatim: String(localized: "vs typical - "))
        }
    }
}

/// One v2 metric tile: a 15 pt icon and title, a 27 pt light value with a small unit, and a caption line.
/// An optional accessory sits to the right of the figures (the full-width tiles use it for a scale).
struct SleepMetricTile<Accessory: View>: View {
    let title: LocalizedStringKey
    let icon: String
    let value: String
    let unit: String?
    let caption: SleepTileCaption
    @ViewBuilder var accessory: () -> Accessory

    init(title: LocalizedStringKey, icon: String, value: String, unit: String?, caption: SleepTileCaption,
         @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.icon = icon
        self.value = value
        self.unit = unit
        self.caption = caption
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                titleRow
                valueRow.padding(.top, 12)
                caption.text
                    .font(StrandFont.light(11))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory()
        }
        .padding(.horizontal, SleepTileMetrics.horizontalPadding)
        .padding(.vertical, SleepTileMetrics.verticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NoopPanelSurface(cornerRadius: SleepTileMetrics.radius))
        .accessibilityElement(children: .combine)
    }

    private var titleRow: some View {
        HStack(spacing: 7) {
            PhIcon(icon, size: 15)
                .foregroundStyle(StrandPalette.textPrimary)
                .opacity(0.85)
            Text(title)
                .font(StrandFont.book(12.5, relativeTo: .caption))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(verbatim: value)
                .font(StrandFont.value(27, weight: 300))
                .tracking(-0.54)
                .foregroundStyle(StrandPalette.textPrimary)
            if let unit {
                Text(verbatim: unit)
                    .font(StrandFont.book(11))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

extension SleepMetricTile where Accessory == EmptyView {
    init(title: LocalizedStringKey, icon: String, value: String, unit: String?, caption: SleepTileCaption) {
        self.init(title: title, icon: icon, value: value, unit: unit, caption: caption) { EmptyView() }
    }
}

/// The hatched "typical" mark of the v2 kit: a 45° hatch inside a faint outline. It marks the wearer's
/// typical MEAN, not a range — the model carries one personal mean per metric, so the mark has a fixed
/// width and its caption names a single value.
struct SleepHatchWindow: View {
    var cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(NoopVisualStyle.inset.opacity(0.4))
            .overlay(
                DiagonalHatch(spacing: 5)
                    .stroke(NoopVisualStyle.quaternaryText, lineWidth: 1.2)
                    .clipShape(shape)
            )
            .overlay(shape.strokeBorder(StrandPalette.textTertiary, lineWidth: 1))
    }
}

/// A compact horizontal scale for one value: a slim track, the hatched typical mark, a glowing white
/// marker at the latest value, and the scale ends plus the typical as captions underneath.
struct SleepRangeBar: View {
    let lower: Double
    let upper: Double
    let value: Double?
    let typical: Double?
    let lowerLabel: String
    let upperLabel: String
    let typicalLabel: String?

    /// Width of the typical mark, in points (see `SleepHatchWindow`: a mean, not a range).
    private let typicalMarkWidth: CGFloat = 24

    var body: some View {
        VStack(spacing: 7) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(NoopVisualStyle.raised)
                    if let typical {
                        SleepHatchWindow(cornerRadius: NoopMetrics.indicatorTrackHeight / 2)
                            .frame(width: typicalMarkWidth)
                            .offset(x: clampedX(typical, width: w) - typicalMarkWidth / 2)
                    }
                    if let value {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(StrandPalette.textPrimary)
                            .frame(width: 2, height: NoopMetrics.indicatorTrackHeight + 8)
                            .shadow(color: StrandPalette.textPrimary.opacity(0.7), radius: 4)
                            .offset(x: clampedX(value, width: w) - 1)
                    }
                }
                .frame(width: w, height: NoopMetrics.indicatorTrackHeight)
            }
            .frame(height: NoopMetrics.indicatorTrackHeight)
            HStack(spacing: 4) {
                Text(verbatim: lowerLabel)
                Spacer(minLength: 0)
                if let typicalLabel { Text(verbatim: typicalLabel).lineLimit(1).minimumScaleFactor(0.8) }
                Spacer(minLength: 0)
                Text(verbatim: upperLabel)
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityHidden(true)   // the tile's own value and caption carry the reading
    }

    /// The value's x on the track, kept clear of the rounded ends.
    private func clampedX(_ v: Double, width: CGFloat) -> CGFloat {
        let span = Swift.max(upper - lower, .ulpOfOne)
        let f = CGFloat(Swift.min(Swift.max((v - lower) / span, 0), 1))
        return Swift.min(Swift.max(f * width, typicalMarkWidth / 2), width - typicalMarkWidth / 2)
    }

    /// The respiratory scale: whole-number ends that enclose every one of the last 30 nights, the latest
    /// and the typical, at least 2 rpm apart. Nil when there is nothing to place.
    static func respiratoryScale(_ m: SleepModel.Metric) -> SleepRangeBar? {
        let recent = Array(m.series.suffix(30)) + [m.latest, m.typical].compactMap { $0 }
        guard let lo = recent.min(), let hi = recent.max() else { return nil }
        var lower = (lo - 0.5).rounded(.down)
        var upper = (hi + 0.5).rounded(.up)
        if upper - lower < 2 { lower -= 1; upper += 1 }
        return SleepRangeBar(
            lower: lower, upper: upper, value: m.latest, typical: m.typical,
            lowerLabel: "\(Int(lower))", upperLabel: "\(Int(upper))",
            typicalLabel: m.typical.map { String(localized: "Typical \(String(format: "%.1f", $0))") })
    }

    /// A 0–100 % scale (extended past 100 when the value or typical runs over), for the percentage cards.
    static func percentScale(_ m: SleepModel.Metric) -> SleepRangeBar? {
        guard m.latest != nil || m.typical != nil else { return nil }
        let top = [m.latest, m.typical].compactMap { $0 }.max() ?? 100
        let upper = Swift.max(100, (top / 10).rounded(.up) * 10)
        return SleepRangeBar(
            lower: 0, upper: upper, value: m.latest, typical: m.typical,
            lowerLabel: "0", upperLabel: "\(Int(upper)) %",
            typicalLabel: m.typical.map { String(localized: "Typical \(Int($0.rounded())) %") })
    }
}
