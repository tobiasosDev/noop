//  TodayV2Components.swift
//  NOOP v2 · the building blocks of the Today screen (frame "Today" on the v2 canvas).
//
//  Pure presentation: every value arrives already resolved by the Today view that owns the data, so
//  the Liquid Today and the classic Today can share one look without sharing their loaders.

import SwiftUI
import StrandDesign

// MARK: - Hero carousel

/// One page of the Charge / Rest / Effort hero carousel, fully resolved for display.
struct TodayHeroPage: Identifiable {
    enum Kind: Int { case rest, charge, effort }

    /// One run of the hero's closing sentence: plain words, or a dot-matrix status tag.
    enum Segment: Hashable {
        case text(String)
        case tag(String)
    }

    let kind: Kind
    let glow: NoopGlow
    let title: String
    let icon: String
    /// The small pill at the top right ("Solid", "Last night", "7h 42m").
    let pill: String?
    /// The dot-matrix number, nil for the honest empty state.
    let value: String?
    let unit: String?
    /// The three captions above the tick scale (low end, the reading's word, high end).
    let lowCaption: String
    let midCaption: String
    let highCaption: String
    /// Where the glowing marker sits on the tick scale (0…1), nil when there is no reading.
    let marker: Double?
    /// Number labels under the scale, as (fraction, label).
    let scaleLabels: [(Double, String)]
    /// Up to two centred lines under the scale.
    let sentence: [[Segment]]
    /// The label the dots row shows for this page while another page is selected ("Rest 91").
    let dotsLabel: String
    /// Where tapping the big number goes.
    let detailRoute: TabRoute?
    /// What VoiceOver reads for the number.
    let spokenValue: String

    var id: Int { kind.rawValue }
}

/// The swipeable hero: three glow cards side by side, the neighbours peeking in at the screen edges,
/// and the dots row underneath naming the other two scores. Swiping changes the page only; the Today
/// day-swipe excludes this frame (see `TodayHeroFrameKey`).
struct TodayHeroCarousel: View {
    let pages: [TodayHeroPage]
    var height: CGFloat = 396
    /// The badge opens the scoring guide for that page.
    var onGuide: (TodayHeroPage.Kind) -> Void

    /// The page in view. Starts on Charge, the middle page, which is also the scroll's centre anchor.
    @State private var scrolledID: Int? = Self.initialPage.rawValue
    @State private var fallbackSelection = Self.initialPage.rawValue

    private var selectedID: Int { scrolledID ?? fallbackSelection }

    var body: some View {
        VStack(spacing: 0) {
            pager
            dots
                .padding(.top, 16)
        }
    }

    @ViewBuilder private var pager: some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 11) {
                    ForEach(pages) { page in
                        heroCard(page)
                            .containerRelativeFrame(.horizontal)
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                // A neighbour shrinks towards the 34 pt insets of the frame's edge
                                // peeks, so only a lit sliver of its glow shows at the screen edge.
                                content.scaleEffect(x: 1, y: 1 - 0.17 * min(1, abs(phase.value)))
                            }
                            .id(page.id)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, NoopMetrics.screenHPadding, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrolledID)
            // Three equal pages: the centred offset is exactly the middle (Charge) page.
            .defaultScrollAnchor(Self.initialAnchor)
            .frame(height: height)
        } else {
            // macOS 13: no scroll-target paging. The selected page stands alone; the dots switch it.
            if let page = pages.first(where: { $0.id == fallbackSelection }) ?? pages.first {
                heroCard(page)
                    .padding(.horizontal, NoopMetrics.screenHPadding)
            }
        }
    }

    /// The page the pager opens on: Charge, the middle page. DEBUG screenshots can open on Rest or Effort
    /// with `--demo-hero-page rest|effort`.
    private static var initialPage: TodayHeroPage.Kind {
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--demo-hero-page"), i + 1 < args.count {
            switch args[i + 1] {
            case "rest": return .rest
            case "effort": return .effort
            default: break
            }
        }
        #endif
        return .charge
    }

    /// The scroll anchor that lands on `initialPage` (three equal pages: leading, centre, trailing).
    private static var initialAnchor: UnitPoint {
        switch initialPage {
        case .rest: return .leading
        case .charge: return .center
        case .effort: return .trailing
        }
    }

    private var dots: some View {
        HStack(spacing: 16) {
            ForEach(pages) { page in
                let selected = page.id == selectedID
                Button {
                    withAnimation(StrandMotion.interactive) {
                        scrolledID = page.id
                        fallbackSelection = page.id
                    }
                } label: {
                    Text(verbatim: selected ? page.title : page.dotsLabel)
                        .font(selected ? StrandFont.book(11) : StrandFont.light(11))
                        .tracking(11 * 0.08)
                        .textCase(.uppercase)
                        .foregroundStyle(selected ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                        .lineLimit(1)
                        // A 44 pt tall tap target around the 11 pt label, laid out as zero.
                        .padding(.vertical, 15)
                        .contentShape(Rectangle())
                        .padding(.vertical, -15)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: page.title))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func heroCard(_ page: TodayHeroPage) -> some View {
        NoopHeroCard(glow: page.glow, padding: 22, minHeight: height) {
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    Button { onGuide(page.kind) } label: {
                        NoopIconBadge(verbatim: page.title, icon: page.icon)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("\(page.title), \(page.spokenValue). See how it is scored."))
                    Spacer(minLength: 8)
                    if let pill = page.pill {
                        NoopPill(verbatim: pill, compact: true)
                    }
                }
                heroNumber(page)
                    .padding(.top, 30)
                TodayHeroScale(low: page.lowCaption, mid: page.midCaption, high: page.highCaption,
                               marker: page.marker, labels: page.scaleLabels)
                    .padding(.top, 18)
                if !page.sentence.isEmpty {
                    TodayHeroSentence(lines: page.sentence)
                        .padding(.top, 16)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
    }

    @ViewBuilder private func heroNumber(_ page: TodayHeroPage) -> some View {
        // The dot face's line box is taller than the CSS `line-height: .9` the frame sets; trim it so the
        // scale below sits where the design puts it.
        let number = NoopDotNumber(page.value ?? "–", unit: page.value == nil ? nil : page.unit,
                                   size: 104, unitSize: 44)
            .fixedSize()
            .padding(.vertical, -10)
            .frame(maxWidth: .infinity)
        if let route = page.detailRoute {
            NavigationLink(value: route) { number.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(page.title), \(page.spokenValue)"))
                .accessibilityHint(Text("Opens the trend and readings"))
        } else {
            number
        }
    }
}

/// The hero's tick scale: three captions above, the faded tick band with a glowing marker, and number
/// labels pinned under their positions.
struct TodayHeroScale: View {
    let low: String
    let mid: String
    let high: String
    let marker: Double?
    let labels: [(Double, String)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: low).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                Spacer(minLength: 6)
                Text(verbatim: mid).font(StrandFont.book(13)).foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                Text(verbatim: high).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
            NoopTickScale(marker: marker)
                .padding(.top, 10)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { _, item in
                        let anchor: CGFloat = item.0 <= 0 ? 0 : (item.0 >= 1 ? 1 : 0.5)
                        Text(verbatim: item.1)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize()
                            .alignmentGuide(.leading) { d in d.width * anchor - geo.size.width * item.0 }
                    }
                }
            }
            .frame(height: 14)
            .padding(.top, 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: mid))
    }
}

/// The hero's closing sentence: centred lines of light text with inline dot-matrix tags.
struct TodayHeroSentence: View {
    let lines: [[TodayHeroPage.Segment]]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 0) {
                    ForEach(Array(line.enumerated()), id: \.offset) { index, segment in
                        Group {
                            switch segment {
                            case .text(let s):
                                Text(verbatim: s)
                                    .font(StrandFont.light(14))
                                    .foregroundStyle(Color.white.opacity(0.84))
                            case .tag(let s):
                                NoopTag(verbatim: s)
                            }
                        }
                        .padding(.leading, index == 0 ? 0 : Self.gap(before: segment))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// A word gap between runs, but closing punctuation sits right against the tag before it
    /// ("resting HR [STEADY]." rather than "[STEADY] .").
    private static func gap(before segment: TodayHeroPage.Segment) -> CGFloat {
        if case .text(let s) = segment, let first = s.first, ".,;:!?".contains(first) { return 2 }
        return 5
    }
}

extension View {
    /// Grows a small text control's tap area to about 44 pt without moving anything: the margin is added
    /// for hit-testing and taken back out of the layout. For the section titles' "Edit" links.
    func todayTapTarget() -> some View {
        padding(.vertical, 14)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .padding(.vertical, -14)
            .padding(.horizontal, -6)
    }
}

/// Measures the hero carousel in the Today day-swipe coordinate space, so a swipe that starts on the
/// carousel pages the scores instead of changing the day.
struct TodayHeroFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull { value = next }
    }
}

// MARK: - Header

/// The 42 pt profile disc: the user's own photo when one is set, else the neutral v2 avatar disc. The
/// app keeps no profile name, so there are no initials to show.
struct TodayV2Avatar: View {
    let imageData: Data?
    var size: CGFloat = 42

    var body: some View {
        if let imageData, let platform = PlatformImage(data: imageData) {
            Image(platformImage: platform)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
        } else {
            PhIcon("user", size: size * 0.42)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(RadialGradient(colors: [Color(hex: "#3A3A40"), Color(hex: "#121214")],
                                                 center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0,
                                                 endRadius: size * 0.75))
                )
                .overlay(Circle().strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
        }
    }
}

/// The strap pill's 22 pt battery ring: a dark track and the charge arc from the top.
struct TodayStrapRing: View {
    /// 0…1, nil for "no reading" (track only).
    let fraction: Double?
    let tint: Color
    var spinning: Bool = false
    @State private var angle = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode and the in-app "Reduce motion in NOOP" toggle: a never-settling spin waits on them
    /// as well as on the system setting.
    @ObservedObject private var motion = NoopMotionState.shared

    var body: some View {
        ZStack {
            Circle().stroke(Color(light: "#D8D7D3", dark: "#2A2A2F"), lineWidth: 2.5)
            if spinning {
                Circle().trim(from: 0, to: 0.28)
                    .stroke(StrandPalette.textPrimary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(angle - 90))
                    .onAppear {
                        guard !motion.poseStill(reduceMotion) else { return }
                        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { angle = 360 }
                    }
            } else if let fraction, fraction > 0 {
                Circle().trim(from: 0, to: min(1, max(0.02, fraction)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 17, height: 17)
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

// MARK: - Cards

/// The `.card.mini` dashboard tile: icon + title, a 26 pt light value with a small unit, a caption.
struct TodayMiniCard: View {
    let title: String
    let icon: String
    let value: String?
    var unit: String? = nil
    var caption: String? = nil
    /// An optional trailing-window sparkline (Key metrics "detailed" tiles).
    var spark: [Double]? = nil
    var showsSparkSlot: Bool = false
    var surfaceOpacity: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoopCardHeader(verbatim: title, icon: icon) { EmptyView() }
            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: value)
                        .font(StrandFont.light(26))
                        .tracking(-0.52)
                        .foregroundStyle(StrandPalette.textPrimary)
                    if let unit, !unit.isEmpty, value != LiquidTodayView.noValueDash {
                        Text(verbatim: unit)
                            .font(StrandFont.light(11))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 14)
            }
            if let caption, !caption.isEmpty {
                Text(verbatim: caption)
                    .font(StrandFont.light(10.5))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, value == nil ? 10 : 3)
            }
            if showsSparkSlot {
                Group {
                    if let spark, spark.count >= 2 {
                        NoopAreaChart(values: spark, line: StrandPalette.metricCyan, fill: StrandPalette.effortColor)
                    } else {
                        Color.clear
                    }
                }
                .frame(height: 24)
                .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .padding(NoopVisualStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .noopPanel(cornerRadius: NoopVisualStyle.cardRadius, surfaceOpacity: surfaceOpacity)
        .contentShape(RoundedRectangle(cornerRadius: NoopVisualStyle.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A day trace drawn as the v2 area chart, broken wherever the series has a hole (#2082) so sparse live
/// windows never read as one continuous day.
struct TodaySegmentedAreaChart: View {
    let values: [Double]
    /// Line identity per value; a change starts a new run. Empty or mismatched = one run.
    let segments: [String]
    var line: Color = StrandPalette.metricCyan
    var fill: Color = StrandPalette.effortColor

    private var runs: [Range<Int>] {
        guard segments.count == values.count, !values.isEmpty else { return [0..<values.count] }
        var out: [Range<Int>] = []
        var start = 0
        for i in 1..<max(values.count, 1) where segments[i] != segments[i - 1] {
            out.append(start..<i)
            start = i
        }
        out.append(start..<values.count)
        return out
    }

    /// Where value `index` is drawn: evenly spaced across the width, scaled into the series' own extent
    /// with 2 units of headroom either side. Shared with scrub readouts so a crosshair lands on the line.
    static func point(index: Int, values: [Double], size: CGSize) -> CGPoint {
        let lo = (values.min() ?? 0) - 2
        let hi = (values.max() ?? 1) + 2
        let span = max(hi - lo, 1)
        let n = max(values.count - 1, 1)
        return CGPoint(x: size.width * CGFloat(index) / CGFloat(n),
                       y: size.height * (1 - CGFloat((values[index] - lo) / span)))
    }

    /// The index drawn nearest to `x`.
    static func nearestIndex(toX x: CGFloat, count: Int, width: CGFloat) -> Int {
        guard count > 1, width > 0 else { return 0 }
        let i = Int((x / width * CGFloat(count - 1)).rounded())
        return min(max(i, 0), count - 1)
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let point: (Int) -> CGPoint = { i in Self.point(index: i, values: values, size: geo.size) }
            ZStack {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    if run.count >= 2 {
                        Path { p in
                            p.move(to: CGPoint(x: point(run.lowerBound).x, y: h))
                            for i in run { p.addLine(to: point(i)) }
                            p.addLine(to: CGPoint(x: point(run.upperBound - 1).x, y: h))
                            p.closeSubpath()
                        }
                        .fill(LinearGradient(colors: [fill.opacity(0.5), fill.opacity(0)],
                                             startPoint: .top, endPoint: .bottom))
                        Path { p in
                            p.move(to: point(run.lowerBound))
                            for i in run.dropFirst() { p.addLine(to: point(i)) }
                        }
                        .stroke(line, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    } else if run.count == 1 {
                        Circle().fill(line).frame(width: 3, height: 3).position(point(run.lowerBound))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A quiet centred text link at the end of a section ("Show all metrics", "Customize Today").
struct TodayFooterLink: View {
    let title: LocalizedStringKey
    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            PhIcon("caret-right", size: 11)
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - Icons

enum TodayV2Icons {
    /// A Phosphor glyph for a stored sport label. Labels are free text (#519), so this matches on
    /// keywords and falls back to a heartbeat rather than guessing a specific sport.
    static func sport(_ name: String) -> String {
        let s = name.lowercased()
        if s.contains("run") || s.contains("jog") { return "person-simple-run" }
        if s.contains("walk") { return "person-simple-walk" }
        if s.contains("hik") { return "person-simple-hike" }
        if s.contains("cycl") || s.contains("bike") || s.contains("spin") { return "person-simple-bike" }
        if s.contains("swim") { return "person-simple-swim" }
        if s.contains("strength") || s.contains("weight") || s.contains("lift") || s.contains("bodybuild")
            || s.contains("gym") || s.contains("crossfit") { return "barbell" }
        if s.contains("yoga") || s.contains("pilates") || s.contains("stretch") { return "person-simple-tai-chi" }
        if s.contains("tennis") || s.contains("squash") || s.contains("badminton") || s.contains("padel") {
            return "tennis-ball"
        }
        if s.contains("soccer") || s.contains("football") { return "soccer-ball" }
        if s.contains("basketball") { return "basketball" }
        if s.contains("golf") { return "golf" }
        if s.contains("row") || s.contains("kayak") || s.contains("canoe") { return "boat" }
        if s.contains("hiit") || s.contains("interval") { return "timer" }
        return "heartbeat"
    }
}

extension DashboardCard {
    /// The Phosphor glyph for the v2 mini card.
    var phIcon: String {
        switch self {
        case .hrv:         return "heartbeat"
        case .restingHr:   return "heart"
        case .respiratory: return "wind"
        case .steps, .stepsAverage30: return "sneaker-move"
        case .stress:      return "wave-sine"
        case .fitnessAge:  return "hourglass"
        case .vo2max:      return "gauge"
        case .vitality:    return "heart-half"
        case .bloodOxygen: return "drop"
        case .skinTemp:    return "thermometer-simple"
        case .sleep:       return "bed"
        case .calories:    return "fire"
        case .hydration:   return "drop-half"
        case .coupled:     return "intersect"
        case .coach:       return "sparkle"
        }
    }
}

extension KeyMetric {
    /// The Phosphor glyph for the v2 Key-metrics tile.
    var phIcon: String {
        switch self {
        case .charge:      return "lightning"
        case .effort:      return "fire"
        case .rest:        return "moon"
        case .hrv:         return "heartbeat"
        case .restingHr:   return "heart"
        case .bloodOxygen: return "drop"
        case .respiratory: return "wind"
        case .steps:       return "sneaker-move"
        case .weight:      return "scales"
        case .calories:    return "flame"
        case .skinTemp:    return "thermometer-simple"
        }
    }
}

// MARK: - Layout helpers

extension View {
    /// The 20 pt screen gutter for a Today section. The hero carousel stays full width so its
    /// neighbours can peek in at the screen edges; every other section carries this.
    func todayGutter() -> some View {
        padding(.horizontal, NoopMetrics.screenHPadding)
    }
}

// MARK: - 30-day steps mini card

/// The "30-day step average" Your-cards tile as a v2 mini card. Same calendar-window calculation and
/// source resolution as `RollingStepsAverageCard` (`RollingStepsAverage.calculate` over
/// `Repository.resolvedSteps`), loading only while the card is on Today.
struct TodayRollingStepsMiniCard: View {
    let day: String
    var surfaceOpacity: Double = 1
    @EnvironmentObject private var repo: Repository
    @State private var result: RollingStepsAverage?
    @State private var resultDay: String?

    var body: some View {
        let current = resultDay == day ? result : nil
        let card = DashboardCard.stepsAverage30
        NavigationLink(value: TabRoute.metricSourced(key: "steps", source: MetricCatalog.combinedStepsSource)) {
            TodayMiniCard(
                title: card.title, icon: card.phIcon,
                value: current?.mean.map {
                    $0.formatted(.number.locale(AppLanguage.activeLocale).precision(.fractionLength(0)))
                } ?? LiquidTodayView.noValueDash,
                caption: current.map { String(localized: "\($0.observedDays) of 30 days") } ?? card.subtitle,
                surfaceOpacity: surfaceOpacity)
        }
        .buttonStyle(LiquidPressStyle())
        .task(id: "\(day)|\(repo.refreshSeq)") {
            guard let start = RollingStepsAverage.startDay(ending: day) else { return }
            let readings = await repo.resolvedSteps(from: start, to: day)
            guard !Task.isCancelled else { return }
            result = RollingStepsAverage.calculate(readings: readings.values, ending: day)
            resultDay = day
        }
    }
}

// MARK: - Effort target

/// Today's suggested Effort window: the approved recovery→strain mapping (`CoupledView.optimalStrainRange`,
/// on the 0–21 axis) applied to a Charge. The ONE resolver every v2 surface that prints the window goes
/// through (the Effort hero, the Effort card, Quick actions), so they cannot drift apart.
enum TodayEffortTarget {
    /// The window as a 0…1 range of the Effort axis, nil while Charge is unknown.
    static func range(recovery: Double?) -> ClosedRange<Double>? {
        guard let band = CoupledView.optimalStrainRange(recovery: recovery) else { return nil }
        return (Double(band.lowerBound) / 21)...(Double(band.upperBound) / 21)
    }

    /// The same window on the displayed Effort scale ("67–86" on 0–100, "14–18" on 0–21).
    static func text(recovery: Double?, scale: EffortScale) -> String? {
        guard let range = range(recovery: recovery) else { return nil }
        let top = scale == .whoop ? 21.0 : 100.0
        return "\(Int((range.lowerBound * top).rounded()))–\(Int((range.upperBound * top).rounded()))"
    }
}

// MARK: - Chip flow

/// Wraps chips onto as many rows as they need, left-aligned, `spacing` between chips and rows.
struct TodayChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
