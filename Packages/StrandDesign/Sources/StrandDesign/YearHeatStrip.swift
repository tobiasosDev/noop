#if !os(watchOS)
// YearHeatStrip uses .onContinuousHover + .help() tooltips (unavailable on watchOS); the watch
// never shows the year heat strip, so the whole view is excluded there. iOS/macOS unchanged.
import SwiftUI

// MARK: - Year Heat Strip (§9.4 Trends)
//
// A GitHub-style year grid: columns = weeks, rows = weekdays. Each cell is tinted
// by that day's recovery score via the signature recovery gradient. Empty days
// (no data) render as a faint inset square. Hover shows a tooltip via SwiftUI's
// built-in help.

/// A day's recovery datum for the heat strip.
public struct RecoveryDay: Identifiable, Sendable {
    /// The day itself. Stable across inits: the old `UUID()` was regenerated every time the Trends body
    /// rebuilt its 365-4000 days, which also made two identical strips never compare equal.
    public var id: Date { date }
    public var date: Date
    /// Recovery 0...100, or nil if no data for that day.
    public var score: Double?

    public init(date: Date, score: Double?) {
        self.date = date
        self.score = score
    }
}

public struct YearHeatStrip: View {

    /// `.classic` is the original grid (weekday gutter, month labels above, the recovery gradient).
    /// `.v2` is the v2 heat calendar: no gutter, month captions below, the five-step Charge ramp and an
    /// outlined square for a day the strap was not worn.
    public enum Style: Sendable { case classic, v2 }

    public var days: [RecoveryDay]
    public var style: Style
    public var cellSize: CGFloat
    public var spacing: CGFloat
    public var showsMonthLabels: Bool
    /// Whether hovering a cell highlights it with a ring and shows a tooltip
    /// (date + score + recovery state word). Defaults on.
    public var showsHover: Bool
    /// Formats a day's score for the tooltip's bold line.
    public var valueFormat: (Double) -> String

    /// The week-column layout, built ONCE here in `init` from the sorted days rather than on every
    /// `body` eval. `buildWeeks()` reads `.component` for up to 365 days, and `body` re-ran on every
    /// hover (which mutates `@State hoverCell`) — so the layout was being recomputed on each pointer
    /// move. Since the struct is only re-created when `days` actually changes, computing it here
    /// memoizes the layout on `days` identity for free, with no behaviour change.
    private let weeks: [Week]

    public init(
        days: [RecoveryDay],
        cellSize: CGFloat = 12,
        spacing: CGFloat = 3,
        showsMonthLabels: Bool = true,
        showsHover: Bool = true,
        valueFormat: @escaping (Double) -> String = { "Recovery \(Int($0.rounded()))" },
        style: Style = .classic
    ) {
        let sorted = days.sorted { $0.date < $1.date }
        self.days = sorted
        self.style = style
        self.cellSize = cellSize
        self.spacing = spacing
        self.showsMonthLabels = showsMonthLabels
        self.showsHover = showsHover
        self.valueFormat = valueFormat
        self.weeks = YearHeatStrip.buildWeeks(from: sorted)
    }

    // The grid layout constants used both for drawing and hover hit-testing.
    private var gutterWidth: CGFloat { style == .v2 ? 0 : 24 }
    private var monthLabelHeight: CGFloat { style == .v2 ? 14 : 10 }

    /// The v2 Charge ramp, five steps on the recovery-state bands (DEPLETED · LOW · MODERATE · PRIMED · PEAK).
    public static func v2Color(_ score: Double) -> Color {
        switch score {
        case ..<25: return V2Ramp.depleted
        case ..<50: return V2Ramp.low
        case ..<70: return V2Ramp.moderate
        case ..<88: return V2Ramp.primed
        default:    return V2Ramp.peak
        }
    }

    // The five ramp colours, built once. `v2Color` runs per cell per body pass (365 cells, thousands on
    // "All history"), and each `Color(light:dark:)` parses two hex strings and allocates a new dynamic
    // provider that never compares equal to the previous pass's, so the old per-call construction was
    // main-thread work on every Trends pass. Same hexes, same dynamic light/dark resolution.
    private enum V2Ramp {
        static let depleted = Color(light: "#D9D8D4", dark: "#232328")
        static let low = Color(light: "#BFDCCB", dark: "#20402F")
        static let moderate = Color(light: "#8CC7A4", dark: "#27603F")
        static let primed = Color(light: "#4FAE76", dark: "#349055")
        static let peak = Color(light: "#2E9A5E", dark: "#56D08A")
    }

    /// The outline of a day that exists in the history but carries no Charge (strap not worn).
    public static let v2NotWornStroke = Color(light: "#C9C8C4", dark: "#3A3A42")

    /// Hovered cell as (weekIndex, row), or nil.
    @State private var hoverCell: (week: Int, row: Int)? = nil

    // A fixed Monday-first Gregorian calendar, stored once as a constant rather than a computed
    // property. `buildWeeks()` runs on every render (including each hover, which mutates @State)
    // and reads `.component` for up to 365 days, so the old computed form allocated a fresh
    // Calendar on every one of those ~730 accesses per render.
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // Monday-first columns read nicely
        return c
    }()

    // Group days into week columns. weekday 0 = Monday ... 6 = Sunday.
    // `id` is the column index, assigned in `buildWeeks`. It was `UUID()`, regenerated on every init, so
    // each Trends pass tore down and rebuilt every column and cell (~371, thousands on "All history").
    private struct Week: Identifiable {
        var id: Int
        var cells: [RecoveryDay?] // length 7, indexed by weekday row
        var monthLabel: String?
    }

    /// Pure: group the (already-sorted) days into Monday-first week columns. Static so it can run once
    /// from `init` (no instance state is read — only the static calendar + formatter cache).
    private static func buildWeeks(from days: [RecoveryDay]) -> [Week] {
        guard let first = days.first?.date else { return [] }
        var weeks: [Week] = []
        var current = Week(id: 0, cells: Array(repeating: nil, count: 7), monthLabel: nil)
        var lastMonth = -1
        // Pad the first week so the first day lands on its weekday row.
        let firstRow = weekdayRow(first)
        var filledThisWeek = 0
        for _ in 0..<firstRow { filledThisWeek += 1 }

        for day in days {
            let row = weekdayRow(day.date)
            if row == 0 && filledThisWeek > 0 {
                weeks.append(current)
                current = Week(id: weeks.count, cells: Array(repeating: nil, count: 7), monthLabel: nil)
                filledThisWeek = 0
            }
            current.cells[row] = day
            // tag month label at the first cell of a new month
            let month = calendar.component(.month, from: day.date)
            if month != lastMonth {
                current.monthLabel = monthShort(day.date)
                lastMonth = month
            }
            filledThisWeek += 1
        }
        if filledThisWeek > 0 { weeks.append(current) }
        return weeks
    }

    private static func weekdayRow(_ date: Date) -> Int {
        // Map Calendar weekday (1=Sun...7=Sat) to Monday-first 0...6.
        let wd = calendar.component(.weekday, from: date)
        return (wd + 5) % 7
    }

    private static func monthShort(_ date: Date) -> String {
        let f = DateFormatterCache.month
        return f.string(from: date)
    }

    private let rowLabels = ["Mon", "", "Wed", "", "Fri", "", "Sun"]

    public var body: some View {
        // `weeks` is the layout built ONCE in init (see the stored property), not rebuilt per body eval.
        // Total drawn size, so the hover overlay can be laid over the grid and
        // a tooltip can be clamped within bounds.
        let gridWidth = gridOriginX + CGFloat(weeks.count) * (cellSize + spacing) - spacing
        let gridHeight = gridOriginY + 7 * (cellSize + spacing) - spacing
            + (style == .v2 && showsMonthLabels ? 8 + monthLabelHeight : 0)

        VStack(alignment: .leading, spacing: style == .v2 ? 8 : spacing) {
            if showsMonthLabels && style == .classic {
                // #1021: month labels were each boxed to ONE cell width (~12pt), so a 3-letter month
                // ("Jul"/"May") truncated to "J…"/"M…". A month marker also needs to sit at the exact x of
                // the week column where the month starts. Positioning each label absolutely (topLeading +
                // .offset) at its column x, and letting it render at its natural width (.fixedSize), gives
                // the full month name room to overflow to the right — the ~4 empty columns before the next
                // month absorb it, and the grid cells below stay column-aligned (they're in their own HStack).
                ZStack(alignment: .topLeading) {
                    // Reserve the row's height + full grid width so the ZStack lays out over the columns.
                    Color.clear.frame(width: gridWidth, height: monthLabelHeight)
                    ForEach(Array(weeks.enumerated()), id: \.element.id) { weekIndex, week in
                        if let label = week.monthLabel, !label.isEmpty {
                            Text(label)
                                .font(.system(size: 8))
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize()
                                .offset(x: gridOriginX + CGFloat(weekIndex) * (cellSize + spacing))
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: spacing) {
                // weekday gutter
                if style == .classic {
                    VStack(alignment: .trailing, spacing: spacing) {
                        ForEach(0..<7, id: \.self) { r in
                            Text(rowLabels[r])
                                .font(.system(size: 8))
                                .foregroundStyle(StrandPalette.textTertiary)
                                .frame(width: gutterWidth, height: cellSize, alignment: .trailing)
                        }
                    }
                }
                // week columns
                ForEach(Array(weeks.enumerated()), id: \.element.id) { weekIndex, week in
                    VStack(spacing: spacing) {
                        ForEach(0..<7, id: \.self) { row in
                            cell(week.cells[row], isHovered: isHovered(weekIndex, row))
                        }
                    }
                }
            }
            if showsMonthLabels && style == .v2 {
                v2MonthLabels(gridWidth: gridWidth)
            }
        }
        .frame(width: gridWidth, height: gridHeight, alignment: .topLeading)
        .overlay(hoverOverlay(weeks: weeks, gridSize: CGSize(width: gridWidth, height: gridHeight)))
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard showsHover else { return }
            switch phase {
            case .active(let location):
                hoverCell = cellIndex(at: location, weekCount: weeks.count)
            case .ended:
                hoverCell = nil
            }
        }
        // ONE collapsed VoiceOver element for the whole calendar. The 365 coloured cells are pure shapes
        // (hover is dead on touch), and emitting one a11y node PER scored day (the old `cell` did) built
        // an O(days) semantics subtree the accessibility walk re-copied on every scroll — a #707 OOM
        // contributor. `children: .ignore` collapses the grid to this single summary at O(1) node cost.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(axSummary))
    }

    /// A spoken one-line summary of the whole strip for VoiceOver.
    private var axSummary: String {
        let scored = days.compactMap { $0.score }
        guard let lo = scored.min(), let hi = scored.max() else {
            return String(localized: "Recovery calendar, no data", bundle: .module)
        }
        let avg = scored.reduce(0, +) / Double(scored.count)
        return String(localized: "Recovery calendar, \(scored.count) days, average \(Int(avg.rounded())), low \(Int(lo.rounded())), high \(Int(hi.rounded()))", bundle: .module)
    }

    // MARK: Grid geometry

    /// x of the first week column (after the weekday gutter + HStack spacing).
    private var gridOriginX: CGFloat { style == .v2 ? 0 : gutterWidth + spacing }
    /// y of the first cell row (below the optional month-label row; the v2 labels sit under the grid).
    private var gridOriginY: CGFloat { showsMonthLabels && style == .classic ? monthLabelHeight + spacing : 0 }

    /// v2 month captions under the grid, each at the column where its month starts. A caption that would
    /// crowd the previous one is skipped, so a fitted year reads every other month.
    private func v2MonthLabels(gridWidth: CGFloat) -> some View {
        var lastX = -CGFloat.infinity
        var placed: [(x: CGFloat, text: String)] = []
        for (i, week) in weeks.enumerated() {
            guard let label = week.monthLabel, !label.isEmpty else { continue }
            let x = CGFloat(i) * (cellSize + spacing)
            if x - lastX >= 40 && x + 16 <= gridWidth {
                placed.append((x, label))
                lastX = x
            }
        }
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(width: gridWidth, height: monthLabelHeight)
            ForEach(placed.indices, id: \.self) { i in
                Text(verbatim: placed[i].text)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize()
                    .offset(x: placed[i].x)
            }
        }
        .accessibilityHidden(true)
    }

    private func isHovered(_ week: Int, _ row: Int) -> Bool {
        guard let h = hoverCell else { return false }
        return h.week == week && h.row == row
    }

    /// Map a local cursor location to a (week, row) cell, or nil if outside the
    /// grid or in the inter-cell gaps.
    private func cellIndex(at point: CGPoint, weekCount: Int) -> (week: Int, row: Int)? {
        let stride = cellSize + spacing
        let lx = point.x - gridOriginX
        let ly = point.y - gridOriginY
        guard lx >= 0, ly >= 0 else { return nil }
        let week = Int(lx / stride)
        let row = Int(ly / stride)
        guard week >= 0, week < weekCount, row >= 0, row < 7 else { return nil }
        // Reject hits in the spacing gutter between cells.
        let withinX = lx - CGFloat(week) * stride
        let withinY = ly - CGFloat(row) * stride
        guard withinX <= cellSize, withinY <= cellSize else { return nil }
        return (week, row)
    }

    /// Centre of a cell in local coordinates.
    private func cellCenter(week: Int, row: Int) -> CGPoint {
        let stride = cellSize + spacing
        return CGPoint(
            x: gridOriginX + CGFloat(week) * stride + cellSize / 2,
            y: gridOriginY + CGFloat(row) * stride + cellSize / 2
        )
    }

    // MARK: Hover overlay (ring + tooltip)

    @ViewBuilder
    private func hoverOverlay(weeks: [Week], gridSize: CGSize) -> some View {
        if showsHover, let h = hoverCell, h.week < weeks.count,
           let day = weeks[h.week].cells[h.row], let score = day.score {
            let center = cellCenter(week: h.week, row: h.row)
            ZStack(alignment: .topLeading) {
                // subtle highlight ring on the hovered cell
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(StrandPalette.hairlineStrong, lineWidth: 1.5)
                    .frame(width: cellSize + 3, height: cellSize + 3)
                    .position(center)
                PositionedTooltip(
                    anchor: center,
                    container: gridSize,
                    tooltip: ChartTooltip(
                        value: valueFormat(score),
                        label: "\(DateFormatterCache.day.string(from: day.date)) · \(StrandPalette.recoveryState(score))",
                        accent: StrandPalette.recoveryColor(score)
                    )
                )
            }
            .animation(StrandMotion.fade, value: h.week)
            .animation(StrandMotion.fade, value: h.row)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func cell(_ day: RecoveryDay?, isHovered: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: style == .v2 ? cellSize * 0.28 : 2.5)
        if style == .v2, let day, day.score == nil {
            shape
                .strokeBorder(Self.v2NotWornStroke, lineWidth: 0.75)
                .frame(width: cellSize, height: cellSize)
        } else if let day, let score = day.score {
            shape
                .fill(style == .v2 ? Self.v2Color(score) : StrandPalette.recoveryColor(score))
                .frame(width: cellSize, height: cellSize)
                .opacity(isHovered ? 1.0 : (hoverCell == nil ? 1.0 : 0.78))
                .help("\(DateFormatterCache.day.string(from: day.date)) · recovery \(Int(score.rounded()))")
                // No per-cell a11y element: the whole strip is one collapsed VoiceOver element (see the
                // `children: .ignore` summary on the body), so per-day detail no longer builds an O(days)
                // semantics subtree. The `.help` above stays — it's a macOS pointer tooltip, not an a11y node.
        } else if day != nil {
            shape
                .fill(StrandPalette.surfaceInset)
                .overlay(shape.stroke(StrandPalette.hairline.opacity(0.6), lineWidth: 0.5))
                .frame(width: cellSize, height: cellSize)
        } else {
            shape
                .fill(Color.clear)
                .frame(width: cellSize, height: cellSize)
        }
    }
}

// Small cached formatters (creating DateFormatter is expensive).
private enum DateFormatterCache {
    static let month: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM"; return f
    }()
    static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()
}

#if DEBUG
private func sampleYear() -> [RecoveryDay] {
    let cal = Calendar.current
    let today = Date()
    return (0..<365).map { i in
        let date = cal.date(byAdding: .day, value: -(364 - i), to: today)!
        // Some gaps + a wavy recovery profile.
        let gap = (i % 23 == 0)
        let v = 55 + 28 * sin(Double(i) / 11.0) + Double((i * 31) % 17) - 8
        return RecoveryDay(date: date, score: gap ? nil : max(2, min(99, v)))
    }
}

#Preview("YearHeatStrip") {
    VStack(alignment: .leading, spacing: 12) {
        Text("Recovery — past year").strandOverline()
        Text("Hover a cell: ring + date, score and recovery-state tooltip.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        YearHeatStrip(days: sampleYear())
    }
    .padding(28)
    .frame(width: 900, height: 240)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
#endif
