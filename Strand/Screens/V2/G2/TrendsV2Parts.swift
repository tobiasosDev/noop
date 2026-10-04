import SwiftUI
import StrandDesign

// MARK: - Trends v2 building blocks
//
// Small presentation pieces the v2 Trends screen composes: the week grid, the Charge hero chart with its
// axes, the signal sparkline and the hero stat. Pure views over values the screen already resolved; no
// data access here, so the screen keeps one source for every number it shows.

/// Day keys are banked as `yyyy-MM-dd` in UTC; parsing and formatting them in any other zone shifts a
/// label by a day for wearers west of Greenwich.
enum TrendsDayFormat {
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ day: String) -> Date? { parser.date(from: day) }

    /// Formatters are costly to build and these run for every axis tick and caption on each render, so
    /// one is kept per template and locale (the locale key lets an in-app language switch take effect).
    private static var cache: [String: DateFormatter] = [:]
    private static let cacheLock = NSLock()

    private static func formatter(_ template: String) -> DateFormatter {
        let locale = AppLanguage.activeLocale
        let key = "\(locale.identifier)|\(template)"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        cache[key] = f
        return f
    }

    /// "4 Sep" / "Sep 4", per locale.
    static func dayMonth(_ date: Date) -> String { formatter("dMMM").string(from: date) }
    /// "11" — the day of month alone, for dense axis ticks.
    static func dayOfMonth(_ date: Date) -> String { formatter("d").string(from: date) }
    /// "Sep".
    static func month(_ date: Date) -> String { formatter("MMM").string(from: date) }
    /// "Oct 2025".
    static func monthYear(_ date: Date) -> String { formatter("MMMyyyy").string(from: date) }
    /// "September" — for sentences.
    static func monthName(_ date: Date) -> String { formatter("MMMM").string(from: date) }

    static func dayMonth(_ day: String) -> String { date(day).map(dayMonth) ?? day }

    /// "4 Sep – 3 Oct".
    static func range(_ from: String, _ to: String) -> String {
        "\(dayMonth(from)) – \(dayMonth(to))"
    }
}

// MARK: Week grid

/// One cell of the week-in-review grid.
struct TrendsWeekCell: Hashable {
    /// The printed value, nil for a day without a reading.
    var text: String?
    /// 0…1 brightness of the fill (the value on its 0–100 scale).
    var level: Double?
    var isToday: Bool
}

/// A labelled row of seven day cells.
struct TrendsWeekRow: Identifiable {
    var id: String { label }
    var label: String
    var cells: [TrendsWeekCell]
}

/// The `.pr` grid: a 52 pt label column and seven equal day columns; brighter cells read higher.
struct TrendsWeekGrid: View {
    let weekdayLabels: [String]
    let todayIndex: Int?
    let rows: [TrendsWeekRow]

    private let columns = [GridItem(.fixed(52), spacing: 5, alignment: .leading)]
        + Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
            Color.clear.frame(height: 14)
            ForEach(weekdayLabels.indices, id: \.self) { i in
                Text(verbatim: weekdayLabels[i])
                    .font(StrandFont.footnote)
                    .foregroundStyle(i == todayIndex ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            ForEach(rows) { row in
                Text(verbatim: row.label)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                ForEach(row.cells.indices, id: \.self) { i in
                    cell(row.cells[i])
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ c: TrendsWeekCell) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if let text = c.text, let level = c.level {
            Text(verbatim: text)
                .font(StrandFont.value(11.5))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                // Brightness follows the square of the value so the top of the scale separates.
                .background(shape.fill(StrandPalette.textPrimary.opacity(0.42 * pow(min(max(level, 0), 1), 2))))
                .overlay(shape.strokeBorder(c.isToday ? StrandPalette.textPrimary.opacity(0.7)
                                                      : Color.white.opacity(0.04), lineWidth: 1))
        } else {
            shape.strokeBorder(NoopVisualStyle.quaternaryText, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .frame(height: 28)
                .accessibilityHidden(true)
        }
    }
}

// MARK: Charge hero chart

/// The hero's chart: y-axis captions at the top, middle and bottom of the range, two hairline rules, a
/// dotted mean rule, an optional highlighted run, the line (or bars) and a cursor on the latest day.
struct TrendsHeroChart: View {
    let values: [Double]
    let range: ClosedRange<Double>
    let mean: Double?
    let highlight: ClosedRange<Double>?
    let highlightLabel: Text?
    let bars: Bool
    /// (0…1 position, caption) pairs under the plot; the last one is drawn in full ink.
    let xLabels: [(Double, String)]

    private let gutter: CGFloat = 24
    private let plotHeight: CGFloat = 124

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 0) {
                yAxis.frame(width: gutter, height: plotHeight)
                plot.frame(height: plotHeight)
            }
            .padding(.top, highlight == nil ? 0 : 14)
            xAxis.padding(.leading, gutter)
        }
        .accessibilityHidden(true)
    }

    private func y(_ v: Double, _ h: CGFloat) -> CGFloat {
        let span = max(range.upperBound - range.lowerBound, 0.0001)
        return h * (1 - CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span))
    }

    private var yAxis: some View {
        GeometryReader { geo in
            let mid = (range.lowerBound + range.upperBound) / 2
            ForEach([range.upperBound, mid, range.lowerBound], id: \.self) { v in
                Text(verbatim: "\(Int(v.rounded()))")
                    .font(StrandFont.light(10))
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.45))
                    .fixedSize()
                    .position(x: 9, y: y(v, geo.size.height))
            }
        }
    }

    private var plot: some View {
        GeometryReader { geo in
            let h = geo.size.height, w = geo.size.width
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).offset(y: h - 1)
                if let mean {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y(mean, h)))
                        p.addLine(to: CGPoint(x: w, y: y(mean, h)))
                    }
                    .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
                }
                if bars {
                    barMarks(width: w, height: h)
                } else {
                    NoopAreaChart(values: values, range: range,
                                  line: StrandPalette.textPrimary, fill: Color.white.opacity(0.64),
                                  highlight: highlight, highlightLabel: highlightLabel,
                                  cursor: values.count > 1 ? 1 : nil)
                }
            }
        }
    }

    /// The bar variant of the same series, for wearers who chose bar trend charts in Settings.
    private func barMarks(width w: CGFloat, height h: CGFloat) -> some View {
        Canvas { ctx, _ in
            guard !values.isEmpty else { return }
            let step = w / CGFloat(values.count)
            let bw = max(1, step * 0.55)
            for (i, v) in values.enumerated() {
                let top = y(v, h)
                let rect = CGRect(x: CGFloat(i) * step + (step - bw) / 2, y: top, width: bw, height: max(1, h - top))
                ctx.fill(Path(roundedRect: rect, cornerRadius: bw / 2),
                         with: .color(i == values.count - 1 ? .white : .white.opacity(0.55)))
            }
        }
    }

    private var xAxis: some View {
        GeometryReader { geo in
            ForEach(xLabels.indices, id: \.self) { i in
                let (pos, text) = xLabels[i]
                let isLast = i == xLabels.count - 1
                Text(verbatim: text)
                    .font(StrandFont.light(10))
                    .foregroundStyle(isLast ? StrandPalette.textPrimary : StrandPalette.textPrimary.opacity(0.5))
                    .fixedSize()
                    .frame(width: geo.size.width, alignment: pos <= 0 ? .leading : (pos >= 1 ? .trailing : .center))
                    .offset(x: pos <= 0 || pos >= 1 ? 0 : geo.size.width * (pos - 0.5))
            }
        }
        .frame(height: 12)
    }
}

/// A hero stat: a 21 pt value with an inline unit, and a caption in the hero's lighter secondary ink.
struct TrendsHeroStat: View {
    let value: String
    let unit: String?
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value).font(StrandFont.value(21)).tracking(-0.4)
                if let unit {
                    Text(verbatim: unit).font(StrandFont.book(10)).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text(verbatim: caption)
                .font(StrandFont.light(10.5))
                .foregroundStyle(Color.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Signal sparkline

/// The daily-signal sparkline: a dotted baseline rule at the window mean, a soft blue area, the chart
/// line and a white dot on the latest reading.
struct TrendsSignalSparkline: View {
    let values: [Double]
    let baseline: Double?

    private var range: ClosedRange<Double> {
        var all = values
        if let baseline { all.append(baseline) }
        guard let lo = all.min(), let hi = all.max() else { return 0...1 }
        if hi <= lo { return (lo - 1)...(hi + 1) }
        let pad = (hi - lo) * 0.15
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 6, h = geo.size.height
            let r = range
            let span = max(r.upperBound - r.lowerBound, 0.0001)
            let yOf = { (v: Double) in h * (1 - CGFloat((v - r.lowerBound) / span)) }
            ZStack(alignment: .topLeading) {
                if let baseline {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: yOf(baseline)))
                        p.addLine(to: CGPoint(x: geo.size.width, y: yOf(baseline)))
                    }
                    .stroke(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                NoopAreaChart(values: values, range: r, line: StrandPalette.metricCyan,
                              fill: StrandPalette.effortColor, lineWidth: 1.1)
                    .frame(width: w)
                if let last = values.last, values.count > 1 {
                    Circle().fill(Color.white).frame(width: 5.2, height: 5.2)
                        .position(x: w, y: yOf(last))
                }
            }
        }
        .frame(height: 40)
        .accessibilityHidden(true)
    }
}

// MARK: Digest line

/// One `.dl` line of the weekly recap: a 28 pt icon disc, a sentence whose lead phrase is in full ink.
struct TrendsDigestLine: View {
    let icon: String
    let lead: String
    let rest: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PhIcon(icon, size: 14)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(NoopVisualStyle.raised))
                .padding(.top, -4)
            (Text(verbatim: lead).font(StrandFont.book(14)).foregroundColor(StrandPalette.textPrimary)
             + Text(verbatim: rest).font(StrandFont.light(14)).foregroundColor(StrandPalette.textSecondary))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
