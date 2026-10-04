import WidgetKit
import SwiftUI
import StrandDesign

/// Timeline entry backed by the latest `WidgetSnapshot` the app published into the App Group.
struct NOOPEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct NOOPProvider: TimelineProvider {
    func placeholder(in context: Context) -> NOOPEntry {
        NOOPEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (NOOPEntry) -> Void) {
        let fallback: WidgetSnapshot = context.isPreview ? .placeholder : .unavailable
        completion(NOOPEntry(date: Date(), snapshot: WidgetSnapshot.load() ?? fallback))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NOOPEntry>) -> Void) {
        // Gallery previews use `placeholder(in:)` / getSnapshot's preview branch. A real timeline
        // with no shared snapshot must show missing data honestly, never plausible sample numbers.
        let snap = WidgetSnapshot.load() ?? .unavailable
        // Refresh roughly every 15 minutes; the app also forces a reload when it publishes fresh data.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [NOOPEntry(date: Date(), snapshot: snap)], policy: .after(next)))
    }
}

/// The glanceable widget — the iOS analogue of the macOS menu-bar extra.
/// Home Screen families mirror Today's hero trio (Charge · Effort · Rest): Charge as one ring on the
/// small widget, three rings beside the heart rate and battery on the medium one, the day with its
/// heart-rate trace on the large one. Lock Screen accessories are compact: a single line, the Charge
/// ring, or the rectangular trio of bars.
struct NOOPWidgetView: View {
    @Environment(\.widgetFamily) private var family
    /// `.fullColor` on the home screen and in the gallery; `.vibrant` or `.accented` on the lock screen,
    /// where the system desaturates any colour it is handed. The accessory cells check this rather than
    /// tinting unconditionally — see `accessoryScore`.
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: NOOPEntry

    private var snap: WidgetSnapshot { entry.snapshot }

    var body: some View {
        switch family {
        case .accessoryCircular:
            recoveryGauge
        case .accessoryInline:
            inline
        case .accessoryRectangular:
            rectangular
        case .systemLarge:
            large
        case .systemMedium:
            medium
        default:
            // systemSmall (and any future compact family)
            small
        }
    }

    // MARK: - Colours (match Today's GlowRing domain constants)

    private var chargeColor: Color {
        snap.recovery != nil ? StrandPalette.chargeColor : StrandPalette.textTertiary
    }

    /// Fixed domain accent — same as `TodayView.effortRing` (`StrandPalette.effortColor`), not the
    /// value-sampled `effortTint` ramp the old footer bolt used.
    private var effortColor: Color {
        snap.effort != nil ? StrandPalette.effortColor : StrandPalette.textTertiary
    }

    private var restColor: Color {
        snap.rest != nil ? StrandPalette.restColor : StrandPalette.textTertiary
    }

    /// Effort centre/accessory text: pre-formatted #313 display when present, else whole-number 0–100.
    private var effortText: String? {
        snap.effortDisplay ?? snap.effort.map(String.init)
    }

    /// The scores that are in, for the line above the lock-screen clock: "Charge 78% · Rest 91".
    private var inlineText: String? {
        var parts: [String] = []
        if let r = snap.recovery { parts.append("Charge \(r)%") }
        if let rest = snap.rest { parts.append("Rest \(rest)") }
        if parts.isEmpty, let b = snap.bpm { parts.append("\(b) bpm") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The wordmark in medium weight, then the scores: the line reads as NOOP's among the other inline
    /// widgets the clock carries.
    private var inline: Text {
        let mark = Text(verbatim: "NOOP").fontWeight(.medium)
        guard let detail = inlineText else { return mark }
        return mark + Text(verbatim: " " + detail)
    }

    /// The heart-rate series the large widget traces, pruned to the window at the entry's own date.
    private var hrSeries: [HrPoint] {
        HrTrace.prune(snap.hrSeries ?? [], nowSec: Int64(entry.date.timeIntervalSince1970))
    }

    /// The heart rate to print, age-checked the same way the heart-rate widget does it, so an hours-old
    /// reading is not shown as current.
    private var shownBpm: (bpm: Int?, stale: Bool) {
        HrDisplay.resolve(bpm: snap.bpm, newestPointTs: hrSeries.last?.ts, now: entry.date)
    }

    // MARK: - Lock Screen accessories

    /// The Charge ring on the lock screen: the system's translucent disc, a faint track, the arc with
    /// its knob and the number in the dot face. Rendered in the levels the vibrant lock screen maps
    /// (primary over a faint track), never in a domain colour it would desaturate anyway.
    private var recoveryGauge: some View {
        ZStack {
            AccessoryWidgetBackground()
            WidgetRing(text: snap.recovery.map(String.init),
                       fraction: snap.recovery.map { Double($0) / 100 },
                       color: renderingMode == .fullColor ? chargeColor : .white,
                       diameter: 57, lineWidth: 4.5, numberSize: 17, radius: 24)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Charge"))
        .accessibilityValue(Text(snap.recovery.map { "\($0) percent" } ?? "No data"))
    }

    /// Lock-Screen rectangular accessory: Charge · Effort · Rest as three labelled bars, the same trio
    /// as the Home Screen rings.
    private var rectangular: some View {
        // The lock screen gives this family roughly 72pt of height for everything, so there is no title
        // row restating which widget the user chose to add: the three scores get the entire area.
        // The rows sit on the system's translucent accessory panel, the same disc the circular family
        // carries, so the two read as a pair beside each other under the clock.
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 5) {
                accessoryScore("Charge", value: snap.recovery, text: snap.recovery.map(String.init), tint: chargeColor)
                accessoryScore("Effort", value: snap.effort, text: effortText, tint: effortColor)
                accessoryScore("Rest", value: snap.rest, text: snap.rest.map(String.init), tint: restColor)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
        }
    }

    /// One score row. On the LOCK SCREEN the domain tint is deliberately dropped; it survives only
    /// where the system actually renders full colour, which for this family means a gallery preview.
    ///
    /// Lock-screen widgets render in `.vibrant` (or `.accented`), where the system desaturates whatever
    /// colour it is given and maps it onto the wallpaper. A domain colour handed to it does not survive
    /// as that colour — it lands as an arbitrary grey whose luminance nobody chose, so Charge, Effort and
    /// Rest stopped being distinguishable AND stopped being legible. `.primary`/`.secondary` are the two
    /// levels the system is designed to map, so the bar and value read at full strength and the label
    /// recedes, which is the hierarchy the tint was there to express in the first place.
    private func accessoryScore(_ label: String, value: Int?, text: String?, tint: Color) -> some View {
        HStack(spacing: 7) {
            Text(label)
                .font(StrandFont.light(10.5))
                .foregroundStyle(HierarchicalShapeStyle.secondary)
                .lineLimit(1)
                .frame(width: 40, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(HierarchicalShapeStyle.quaternary)
                    if let value {
                        Capsule()
                            .fill(scoreStyle(hasValue: true, tint: tint))
                            .frame(width: max(4, geo.size.width * CGFloat(min(max(value, 0), 100)) / 100))
                    }
                }
            }
            .frame(height: 4)
            Text(verbatim: text ?? "–")
                .font(StrandFont.book(10.5))
                .foregroundStyle(scoreStyle(hasValue: text != nil, tint: tint))
                .monospacedDigit()
                .frame(width: 22, alignment: .trailing)
        }
        // Collapse the row to one element that still speaks "Charge, 68".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        // Plain literal, not String(localized:). This extension's sources are StrandiOSWidgets +
        // StrandiOSShared only — Strand/Resources/Localizable.xcstrings is NOT in the target, and
        // String(localized:) resolves against Bundle.main, which for an app extension is the extension's
        // own bundle. It would compile, look localized, and render English in every locale. Every other
        // string in this file is a bare literal for the same reason: the widget is not localized yet.
        .accessibilityValue(Text(text ?? "No data"))
    }

    private func scoreStyle(hasValue: Bool, tint: Color) -> AnyShapeStyle {
        // Spelled out rather than leaning on leading-dot inference through AnyShapeStyle's generic
        // init, which is the kind of expression that type-checks in a playground and not in a build.
        guard renderingMode == .fullColor else {
            return hasValue ? AnyShapeStyle(HierarchicalShapeStyle.primary)
                            : AnyShapeStyle(HierarchicalShapeStyle.secondary)
        }
        return hasValue ? AnyShapeStyle(tint) : AnyShapeStyle(StrandPalette.textTertiary)
    }

    // MARK: - Home Screen: systemSmall

    /// Charge as one large ring, with Effort and Rest named underneath so the smallest widget still
    /// carries all three scores.
    private var small: some View {
        VStack(spacing: 0) {
            WidgetHeader(icon: "lightning", title: Text("Charge")) {
                if snap.updated != .distantPast {
                    Text(snap.updated, format: .dateTime.hour().minute())
                }
            }
            Spacer(minLength: 4)
            WidgetRing(text: snap.recovery.map(String.init),
                       fraction: snap.recovery.map { Double($0) / 100 },
                       color: chargeColor, diameter: 90, lineWidth: 6, numberSize: 28, unit: "%", radius: 37.5)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Charge"))
                .accessibilityValue(Text(snap.recovery.map { "\($0) out of 100" } ?? "unavailable"))
            Spacer(minLength: 4)
            Text(verbatim: smallCaption)
                .font(StrandFont.light(11))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// "Effort 54 · Rest 91", with a dash for a score that is not in yet.
    private var smallCaption: String {
        "Effort \(effortText ?? "–") · Rest \(snap.rest.map(String.init) ?? "–")"
    }

    // MARK: - Home Screen: systemMedium

    /// The three score rings, a hairline, then the heart rate and the strap battery.
    private var medium: some View {
        HStack(spacing: 0) {
            scoreRings(diameter: 62, lineWidth: 4.5, numberSize: 17, radius: 26)
                .fixedSize()
                .layoutPriority(1)
            Rectangle()
                .fill(NoopVisualStyle.borderHighlight)
                .frame(width: 1)
                .padding(.vertical, 4)
                .padding(.horizontal, 14)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    // "Live" only while the reading is current; a dimmed carried-over number is just "HR".
                    WidgetHeader(icon: "heart", title: Text(shownBpm.bpm != nil && !shownBpm.stale ? "Live" : "HR"),
                                 size: 11)
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(verbatim: shownBpm.bpm.map(String.init) ?? "–")
                            .font(StrandFont.dot(26))
                            .tracking(StrandFont.dotTracking(26))
                            .foregroundStyle(shownBpm.stale ? StrandPalette.textSecondary : StrandPalette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if shownBpm.bpm != nil {
                            Text("bpm").font(StrandFont.light(10)).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Heart rate"))
                .accessibilityValue(Text(shownBpm.bpm.map { "\($0) beats per minute" } ?? "No data"))
                VStack(alignment: .leading, spacing: 4) {
                    WidgetHeader(icon: "battery-high", title: Text("Strap"), size: 11)
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(verbatim: snap.batteryPct.map(String.init) ?? "–")
                            .font(StrandFont.book(16))
                            .foregroundStyle(StrandPalette.textPrimary)
                        if snap.batteryPct != nil {
                            Text(verbatim: "%").font(StrandFont.light(10)).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Strap battery"))
                .accessibilityValue(Text(snap.batteryPct.map { "\($0) percent" } ?? "No data"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Home Screen: systemLarge

    /// The day at a glance: the three scores in the dot face, the last three hours of heart rate, then a
    /// footer line with HRV, resting heart rate, the strap battery and when the numbers were published.
    private var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            largeHeader
            largeScores
                .padding(.top, 20)
            heartRateChart
                .padding(.top, 22)
            Spacer(minLength: 8)
            largeFooter
        }
    }

    /// Charge · Effort · Rest on a 1.25 : 1 : 1 grid, so the Charge column has room for its unit and the
    /// other two still start on fixed lanes whatever their digits.
    private var largeScores: some View {
        GeometryReader { geo in
            let unit = geo.size.width / 3.25
            HStack(alignment: .top, spacing: 0) {
                bigScore("Charge", text: snap.recovery.map(String.init), unit: "%")
                    .frame(width: unit * 1.25, alignment: .leading)
                bigScore("Effort", text: effortText, unit: nil)
                    .frame(width: unit, alignment: .leading)
                bigScore("Rest", text: snap.rest.map(String.init), unit: nil)
                    .frame(width: unit, alignment: .leading)
            }
        }
        .frame(height: 64)
    }

    /// HRV, resting heart rate and the strap battery as one quiet line over a hairline, with the publish
    /// time at the right.
    private var largeFooter: some View {
        HStack(spacing: 6) {
            footStat("HRV", value: snap.hrv.map { "\($0)" }, unit: "ms",
                     name: "Heart rate variability", spoken: snap.hrv.map { "\($0) milliseconds" })
            footDot
            footStat("RHR", value: snap.restingHr.map { "\($0)" }, unit: "bpm",
                     name: "Resting heart rate", spoken: snap.restingHr.map { "\($0) beats per minute" })
            footDot
            footStat("Strap", value: snap.batteryPct.map { "\($0)" }, unit: "%",
                     name: "Strap battery", spoken: snap.batteryPct.map { "\($0) percent" })
            Spacer(minLength: 6)
            if snap.updated != .distantPast {
                Text("Updated \(snap.updated, format: .dateTime.hour().minute())")
            }
        }
        .font(StrandFont.light(11))
        .foregroundStyle(StrandPalette.textTertiary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
        }
    }

    private var footDot: some View {
        Text(verbatim: "·").accessibilityHidden(true)
    }

    private var largeHeader: some View {
        HStack(spacing: 8) {
            Text(verbatim: "NOOP")
                .font(StrandFont.dot(14))
                .tracking(14 * 0.06)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(entry.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .font(StrandFont.light(11))
                .foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: 4)
            HStack(spacing: 7) {
                Circle()
                    .fill(snap.bonded ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .frame(width: 6, height: 6)
                Text(snap.bonded ? "Connected" : "Disconnected")
                    .font(StrandFont.light(11))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .overlay(Capsule().strokeBorder(NoopVisualStyle.border, lineWidth: 1))
        }
    }

    /// One of the large widget's three scores: the value in the dot face over its name.
    private func bigScore(_ label: String, text: String?, unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(verbatim: text ?? "–")
                    .font(StrandFont.dot(44))
                    .tracking(StrandFont.dotTracking(44))
                if let unit, text != nil {
                    Text(verbatim: unit).font(StrandFont.dot(20))
                }
            }
            .foregroundStyle(text == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Text(label)
                .font(StrandFont.light(11))
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(text ?? "No data"))
    }

    /// The last three hours of heart rate, or one honest line when there is nothing to draw.
    @ViewBuilder private var heartRateChart: some View {
        let series = hrSeries
        if let stats = HrTrace.stats(series) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Heart rate · last 3 hours")
                    Spacer(minLength: 4)
                    Text(verbatim: "\(stats.min)–\(stats.max) bpm")
                }
                .font(StrandFont.light(11))
                .foregroundStyle(StrandPalette.textTertiary)
                WidgetHrTrace(series: series)
                    .frame(height: 104)
                    .padding(.top, 10)
                WidgetHrTimeAxis(series: series)
                    .padding(.top, 6)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Heart rate, last 3 hours"))
            .accessibilityValue(Text("\(stats.min) to \(stats.max) beats per minute"))
        } else {
            Text("No heart rate in the last 3 hours")
                .font(StrandFont.light(11))
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: - Shared pieces

    /// The Today hero trio as static score rings (widget-safe: no draw-in animation / onAppear race).
    /// Order matches TodayView: Charge · Effort · Rest. Each cell is honest-null ("–") until scored.
    private func scoreRings(diameter: CGFloat, lineWidth: CGFloat, numberSize: CGFloat,
                            radius: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ringCell("Charge", text: snap.recovery.map(String.init),
                     fraction: snap.recovery.map { Double($0) / 100 }, color: chargeColor,
                     diameter: diameter, lineWidth: lineWidth, numberSize: numberSize, radius: radius, outOf: 100)
            // Fill is always the stored 0–100 axis so WHOOP 0–21 and native 0–100 agree on arc length.
            ringCell("Effort", text: effortText,
                     fraction: snap.effort.map { Double($0) / 100 }, color: effortColor,
                     diameter: diameter, lineWidth: lineWidth, numberSize: numberSize, radius: radius,
                     outOf: (snap.effortWhoop == true) ? 21 : 100)
            ringCell("Rest", text: snap.rest.map(String.init),
                     fraction: snap.rest.map { Double($0) / 100 }, color: restColor,
                     diameter: diameter, lineWidth: lineWidth, numberSize: numberSize, radius: radius, outOf: 100)
        }
    }

    private func ringCell(_ label: String, text: String?, fraction: Double?, color: Color,
                          diameter: CGFloat, lineWidth: CGFloat, numberSize: CGFloat, radius: CGFloat,
                          outOf: Int) -> some View {
        VStack(spacing: 6) {
            WidgetRing(text: text, fraction: fraction, color: color,
                       diameter: diameter, lineWidth: lineWidth, numberSize: numberSize, radius: radius)
            Text(label)
                .font(StrandFont.light(10))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(text.map { "\($0) out of \(outOf)" } ?? "unavailable"))
    }

    /// One stat in the large widget's footer line: "HRV 68 ms", the value a step brighter than its label.
    ///
    /// `name` and `spoken` exist because the on-screen label is abbreviated for width and the unit is a
    /// separate run: read as-is, VoiceOver produces "HRV", "68", "ms" — three fragments, with "ms" and
    /// "bpm" spelled out letter by letter. Collapsing to one element lets the stat speak "Heart rate
    /// variability, 68 milliseconds". `spoken` falls back to the rendered value rather than to "No data",
    /// so a caller that omits it degrades to the plain reading instead of lying.
    private func footStat(_ label: String, value: String?, unit: String? = nil,
                          name: String? = nil, spoken: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(label)
            Text(verbatim: value ?? "–")
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textSecondary)
            if let unit, value != nil {
                Text(verbatim: unit)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name ?? label))
        .accessibilityValue(Text(spoken ?? value ?? "No data"))
    }
}

// MARK: - The large widget's heart-rate trace

/// The heart-rate trace in the app's chart style: the area under each contiguous run, the line, and a
/// white dot on the newest reading. Gaps stay gaps (`HrTrace.runs`); a lone reading is a dot.
private struct WidgetHrTrace: View {
    let series: [HrPoint]

    var body: some View {
        GeometryReader { geo in
            let pts = HrTrace.points(series, width: geo.size.width, height: geo.size.height)
            let runs = HrTrace.runs(pts)
            ZStack(alignment: .topLeading) {
                Path { path in
                    for run in runs where run.lowerBound != run.upperBound {
                        path.move(to: CGPoint(x: pts[run.lowerBound].x, y: geo.size.height))
                        for i in run { path.addLine(to: CGPoint(x: pts[i].x, y: pts[i].y)) }
                        path.addLine(to: CGPoint(x: pts[run.upperBound].x, y: geo.size.height))
                        path.closeSubpath()
                    }
                }
                .fill(WidgetChartStyle.fill)
                Path { path in
                    for run in runs where run.lowerBound != run.upperBound {
                        path.move(to: CGPoint(x: pts[run.lowerBound].x, y: pts[run.lowerBound].y))
                        for i in run.dropFirst() { path.addLine(to: CGPoint(x: pts[i].x, y: pts[i].y)) }
                    }
                }
                .stroke(WidgetChartStyle.line, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                if let last = pts.last {
                    Circle().fill(Color.white)
                        .frame(width: 6, height: 6)
                        .position(x: min(max(last.x, 3), geo.size.width - 3), y: last.y)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct WidgetHrTimeAxis: View {
    let series: [HrPoint]

    var body: some View {
        let ticks = HrTrace.timeTicks(series)
        // One instant pinned to the left edge reads as a stray rather than an axis, so it waits for a
        // span to label.
        if ticks.count >= 2 {
            HStack {
                ForEach(Array(ticks.enumerated()), id: \.offset) { i, ts in
                    Text(Date(timeIntervalSince1970: TimeInterval(ts)), format: .dateTime.hour().minute())
                        .font(StrandFont.light(9.5))
                        .foregroundStyle(i == ticks.count - 1 ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                    if i < ticks.count - 1 { Spacer(minLength: 0) }
                }
            }
        }
    }
}

struct NOOPWidget: Widget {
    let kind = "NOOPWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPProvider()) { entry in
            if #available(iOS 17.0, *) {
                NOOPWidgetView(entry: entry)
                    .containerBackground(for: .widget) { WidgetCardBackground() }
            } else {
                NOOPWidgetView(entry: entry)
                    .padding()
                    .background(WidgetCardBackground())
            }
        }
        .configurationDisplayName("NOOP")
        .description("Charge, Effort and Rest as score rings, plus live HR and strap battery at a glance.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryInline, .accessoryRectangular
        ])
    }
}
