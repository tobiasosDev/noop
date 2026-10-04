import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Asleep duration trend (#today-hosted-cards)
//
// The Sleep tab's "Asleep duration" card, extracted into a standalone view so it can ALSO be hosted in
// the Today tab. Both the Sleep tab and the Today host render THIS view from the SAME `AsleepDurationData`,
// so the number can never diverge between the two surfaces (the parity contract). The data builder is a
// verbatim lift of `SleepView.durationTrendPoints` + `typicalTotalMin`; the card draws them as the v2
// per-night bar chart with the dashed sleep-need line.

/// Pure inputs for the asleep-duration card: trailing-30-night sleep hours + the typical mean minutes.
/// Built identically by the Sleep tab and by a Today host so the two never diverge.
struct AsleepDurationData {
    let points: [TrendPoint]
    let typicalTotalMin: Double?
    /// The per-night sleep need (minutes) the chart draws its dashed line at, the same need the debt
    /// ledger measures against. Nil omits the line and the "need" caption.
    var needMin: Double? = nil

    /// yyyy-MM-dd → Date (en_US_POSIX, UTC) — matches `SleepView.dayParser`.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Trailing 30 days of total sleep in HOURS, falling back to all nights with data when the trailing
    /// window is too sparse (verbatim of `SleepView.durationTrendPoints`). `typicalTotalMin` is the mean
    /// asleep minutes across nights with data (verbatim of `SleepView.typicalTotalMin`). `needMin` is the
    /// debt need (`SleepModel.debtNeedMin`), so a Today host draws the line the Sleep tab draws.
    static func build(days: [DailyMetric]) -> AsleepDurationData {
        func mk(_ slice: ArraySlice<DailyMetric>) -> [TrendPoint] {
            slice.compactMap { d -> TrendPoint? in
                guard let mins = d.totalSleepMin, mins > 0,
                      let date = dayParser.date(from: d.day) else { return nil }
                return TrendPoint(date: date, value: mins / 60.0)
            }
        }
        let recent = mk(days.suffix(30))
        let points = recent.count >= 2 ? recent : mk(days[...])
        let totals = days.compactMap { $0.totalSleepMin }.filter { $0 > 0 }
        let typical = totals.isEmpty ? nil : totals.reduce(0, +) / Double(totals.count)
        return AsleepDurationData(points: points, typicalTotalMin: typical,
                                  needMin: totals.isEmpty ? nil : SleepModel.debtNeedMin(days: days))
    }

    /// "yyyy-MM-dd" of a point's date, in the parser's own (UTC) calendar.
    static func dayKey(_ date: Date) -> String { dayParser.string(from: date) }
}

/// The "Asleep duration" trend card: the average as the headline, last night and the need beside it, then
/// one bar per night with the dashed need line and last night in the sleep accent.
struct AsleepDurationCard: View {
    let data: AsleepDurationData

    var body: some View {
        let pts = data.points
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("Asleep duration", captionKey: "Trend")
            NoopCard {
                VStack(alignment: .leading, spacing: 0) {
                    header(pts)
                    if pts.count >= 2 {
                        AsleepDurationBars(values: pts.map(\.value), needHours: data.needMin.map { $0 / 60 })
                            .padding(.top, 18)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text("Hours asleep trend"))
                            .accessibilityValue(Text(verbatim: Self.chartSummary(pts, avg: averageHours)))
                        dateAxis(pts)
                            .padding(.top, 8)
                    } else {
                        Self.sparsePlaceholder
                            .padding(.top, 18)
                    }
                    footer(pts)
                        .padding(.top, 12)
                }
            }
        }
    }

    private var averageHours: Double? { data.typicalTotalMin.map { $0 / 60.0 } }

    /// "7:06 h avg" on the left; "Last night 7:12 · need 7:50" on the right.
    private func header(_ pts: [TrendPoint]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: averageHours.map(Self.clock) ?? "—")
                    .font(StrandFont.value(27, weight: 300))
                    .tracking(-0.54)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("h avg")
                    .font(StrandFont.book(11))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            latestCaption(pts)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func latestCaption(_ pts: [TrendPoint]) -> Text {
        var parts: [Text] = []
        if let last = pts.last {
            let figure = Text(verbatim: Self.clock(last.value)).foregroundColor(StrandPalette.textPrimary)
            parts.append(Self.isLastNight(last.date)
                ? Text("Last night \(figure)")
                : Text(verbatim: "\(Self.dayMonth(last.date)) ") + figure)
        }
        if let need = data.needMin {
            parts.append(Text("need \(Self.clock(need / 60))"))
        }
        guard let first = parts.first else { return Text(verbatim: "") }
        return parts.dropFirst().reduce(first) { $0 + Text(verbatim: " · ") + $1 }
    }

    /// The first, middle and last night under the bars, the last one named "Last night" when it is.
    private func dateAxis(_ pts: [TrendPoint]) -> some View {
        let first = pts.first.map { Self.dayMonth($0.date) } ?? ""
        let mid = Self.dayMonth(pts[pts.count / 2].date)
        let lastDate = pts.last?.date
        return HStack {
            Text(verbatim: first)
            Spacer(minLength: 4)
            if pts.count >= 3 { Text(verbatim: mid) }
            Spacer(minLength: 4)
            Group {
                if let lastDate, Self.isLastNight(lastDate) {
                    Text("Last night")
                } else {
                    Text(verbatim: lastDate.map(Self.dayMonth) ?? "")
                }
            }
            .foregroundStyle(StrandPalette.textPrimary)
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .padding(.trailing, AsleepDurationBars.labelGutter)
        .accessibilityHidden(true)
    }

    /// What the bars are, and the movement between the earlier and the recent half of them.
    private func footer(_ pts: [TrendPoint]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Hours asleep, per night, trailing 30 days")
            Spacer(minLength: 8)
            if let delta = Self.durationTrendChange(pts) {
                Text("Trend \(Self.signedHours(delta))")
                    .accessibilityLabel(Text(verbatim: "\(String(localized: "Trend")): \(Self.signedHours(delta))"))
            }
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
    }

    private static var sparsePlaceholder: some View {
        Text("Not enough nights yet.")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, minHeight: AsleepDurationBars.height, alignment: .center)
    }

    /// The figures the old chart footer printed (avg, shortest, longest, nights), for VoiceOver.
    private static func chartSummary(_ pts: [TrendPoint], avg: Double?) -> String {
        let vals = pts.map(\.value)
        let fmt: (Double?) -> String = { $0.map { String(format: "%.1f h", $0) } ?? "—" }
        return String(localized: "Average \(fmt(avg)), shortest \(fmt(vals.min())), longest \(fmt(vals.max())), \(pts.count) nights")
    }

    /// Recent-half mean minus earlier-half mean (verbatim of `SleepView.durationTrendChange`). Direction
    /// is neutral: more sleep isn't automatically better, so the caption conveys movement without a verdict.
    private static func durationTrendChange(_ points: [TrendPoint]) -> Double? {
        guard points.count >= 4 else { return nil }
        let midpoint = points.count / 2
        let earlier = points.prefix(midpoint).map(\.value)
        let recent = points.suffix(points.count - midpoint).map(\.value)
        guard !earlier.isEmpty, !recent.isEmpty else { return nil }
        return recent.reduce(0, +) / Double(recent.count)
            - earlier.reduce(0, +) / Double(earlier.count)
    }

    private static func signedHours(_ delta: Double) -> String {
        // A move that rounds to nothing reads as level, never as "−0.0".
        let tenths = (delta * 10).rounded()
        if tenths == 0 { return "±0.0 h" }
        return "\(tenths > 0 ? "+" : "−")\(String(format: "%.1f h", abs(tenths) / 10))"
    }

    /// Hours → "H:MM" ("7:06").
    static func clock(_ hours: Double) -> String {
        let m = Swift.max(0, Int((hours * 60).rounded()))
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    /// True when the point is the night that ended this morning (its wake-day key is today's).
    private static func isLastNight(_ date: Date) -> Bool {
        AsleepDurationData.dayKey(date) == todayKeyFormatter.string(from: Date())
    }

    private static func dayMonth(_ date: Date) -> String { dayMonthFormatter.string(from: date) }

    private static let todayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let dayMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()
}

/// One bar per night on a scale of whole hours, faint gridlines every two hours, the dashed need line,
/// and the hour labels in a right-hand gutter. Last night carries the sleep accent; the rest stay neutral.
private struct AsleepDurationBars: View {
    let values: [Double]
    let needHours: Double?

    static let height: CGFloat = 110
    static let labelGutter: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            let scale = Scale(values: values, need: needHours)
            let plotW = Swift.max(geo.size.width - Self.labelGutter, 1)
            ZStack(alignment: .topLeading) {
                gridlines(scale, width: plotW)
                bars(scale, width: plotW)
                if let needHours {
                    Path { p in
                        let y = scale.y(needHours, height: Self.height)
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: plotW, y: y))
                    }
                    .stroke(StrandPalette.textSecondary, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                labels(scale, x: geo.size.width)
            }
        }
        .frame(height: Self.height)
    }

    /// Whole-hour bounds around every night and the need, the floor half an hour below the lowest label
    /// so the shortest night still shows a bar.
    private struct Scale {
        let top: Double
        let lowLabel: Double
        let floor: Double

        init(values: [Double], need: Double?) {
            let all = values + [need].compactMap { $0 }
            let hi = (all.max() ?? 9).rounded(.up)
            var lo = (all.min() ?? 5).rounded(.down)
            if hi - lo < 2 { lo = hi - 2 }
            top = hi
            lowLabel = Swift.max(lo, 0)
            floor = Swift.max(lowLabel - 0.5, 0)
        }

        func y(_ hours: Double, height: CGFloat) -> CGFloat {
            let f = (hours - floor) / Swift.max(top - floor, 0.5)
            return height * CGFloat(1 - Swift.min(Swift.max(f, 0), 1))
        }

        /// Every second hour from the top down to the lowest label.
        var gridHours: [Double] { Array(stride(from: top, through: lowLabel, by: -2)) }
    }

    private func gridlines(_ s: Scale, width: CGFloat) -> some View {
        Path { p in
            for h in s.gridHours {
                let y = s.y(h, height: Self.height)
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: width, y: y))
            }
        }
        .stroke(NoopVisualStyle.divider, lineWidth: 1)
    }

    private func bars(_ s: Scale, width: CGFloat) -> some View {
        let slot = width / CGFloat(Swift.max(values.count, 1))
        let barW = Swift.max(2, slot * 0.7)
        return ForEach(Array(values.enumerated()), id: \.offset) { i, v in
            let top = s.y(v, height: Self.height)
            let h = Swift.max(2, Self.height - top)
            RoundedRectangle(cornerRadius: Swift.min(3, barW / 2), style: .continuous)
                .fill(i == values.count - 1 ? NoopGlow.sleep.accent : NoopGlow.ink.deep)
                .frame(width: barW, height: h)
                .position(x: slot * (CGFloat(i) + 0.5), y: Self.height - h / 2)
        }
    }

    /// The top and lowest whole hours, and the need, right-aligned in the gutter. A bound that would
    /// collide with the need label gives way to it.
    @ViewBuilder
    private func labels(_ s: Scale, x: CGFloat) -> some View {
        let needY = needHours.map { s.y($0, height: Self.height) }
        let clear: (CGFloat) -> Bool = { y in needY.map { Swift.abs($0 - y) > 12 } ?? true }
        let topY = s.y(s.top, height: Self.height)
        let lowY = s.y(s.lowLabel, height: Self.height)
        if clear(topY) { label(Text("\(Int(s.top))h"), y: topY, x: x, color: StrandPalette.textTertiary) }
        if clear(lowY) { label(Text("\(Int(s.lowLabel))h"), y: lowY, x: x, color: StrandPalette.textTertiary) }
        if let needHours, let needY {
            label(Text(verbatim: AsleepDurationCard.clock(needHours)), y: needY, x: x, color: StrandPalette.textSecondary)
        }
    }

    private func label(_ text: Text, y: CGFloat, x: CGFloat, color: Color) -> some View {
        text.font(StrandFont.light(10))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .frame(width: Self.labelGutter, alignment: .trailing)
            .position(x: x - Self.labelGutter / 2, y: y)
    }
}
