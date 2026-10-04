import StrandDesign
import SwiftUI
import WidgetKit

/// Home-screen widget: the live heart rate with the last `HrTrace.windowSec` drawn as a trace (#1957).
///
/// Swift twin of the Android `HrGlanceWidget`, but the drawing is NOT a port. Glance compiles to
/// RemoteViews and cannot draw, so Android renders the trace to a Bitmap under a payload budget and a
/// reduced pixel depth. WidgetKit is SwiftUI: the trace is a stroked `Path`, resolution-independent,
/// with no bitmap to size and nothing to budget. What IS shared is `HrTrace` — the retention rule, the
/// normalisation and the tick choices — because those are the same reading of the same heart.
///
/// Honest-blank throughout, matching the twin: no reading shows an em dash and no chart, never a flat
/// line at zero. A single point draws a dot, because a widget added this minute has exactly one.
struct HeartRateEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot?
}

struct HeartRateProvider: TimelineProvider {
    func placeholder(in context: Context) -> HeartRateEntry {
        HeartRateEntry(date: Date(), snap: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (HeartRateEntry) -> Void) {
        completion(HeartRateEntry(date: Date(), snap: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HeartRateEntry>) -> Void) {
        let entry = HeartRateEntry(date: Date(), snap: WidgetSnapshot.load())
        // The app reloads timelines when the heart rate moves, so this is only the safety net for when
        // it is not running. Fifteen minutes rather than the trace's one-minute bucket: a widget cannot
        // outrun its publisher, and asking more often spends budget WidgetKit would decline anyway.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())
            ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

/// The trace itself: a stroked path with a fill beneath it.
///
/// Takes its size from the geometry rather than a guess, which is the whole advantage over the Android
/// twin — there is no bitmap, so nothing has to predict the box or survive being stretched into it.
private struct HrTraceShape: Shape {
    let series: [HrPoint]
    /// When true, close the path down to the baseline for the gradient fill.
    let filled: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let pts = HrTrace.points(series, width: rect.width, height: rect.height)
        guard let first = pts.first else { return path }
        if pts.count == 1 {
            // One reading is not a line. A dot says "one reading"; an empty box says "no data", and
            // those are different things.
            guard !filled else { return path }
            let r: CGFloat = 2.5
            path.addEllipse(in: CGRect(x: max(first.x, r) - r, y: first.y - r, width: r * 2, height: r * 2))
            return path
        }
        // Draw a run at a time, lifting the pen across the gaps. x is mapped by TIME, so a gap already
        // occupies its true width; it was only the line drawn across it that was never measured.
        for run in HrTrace.runs(pts) {
            let head = pts[run.lowerBound]
            guard run.lowerBound != run.upperBound else {
                // A lone reading between two gaps is not a line either, and gets the same dot the
                // single-point series above does.
                if !filled {
                    // Held a full dot inside the box: the likeliest lone run of all is the NEWEST
                    // reading after a long disconnect, which sits exactly on the right edge.
                    let dot: CGFloat = 2.5
                    let cx = min(max(head.x, dot), max(rect.maxX - dot, dot))
                    path.addEllipse(in: CGRect(x: cx - dot, y: head.y - dot,
                                               width: dot * 2, height: dot * 2))
                }
                continue
            }
            // Each run closes its own area, so the gradient stops at the gap along with the line.
            if filled {
                path.move(to: CGPoint(x: head.x, y: rect.maxY))
                path.addLine(to: CGPoint(x: head.x, y: head.y))
            } else {
                path.move(to: CGPoint(x: head.x, y: head.y))
            }
            for i in (run.lowerBound + 1)...run.upperBound {
                path.addLine(to: CGPoint(x: pts[i].x, y: pts[i].y))
            }
            if filled {
                path.addLine(to: CGPoint(x: pts[run.upperBound].x, y: rect.maxY))
                path.closeSubpath()
            }
        }
        return path
    }
}

struct HeartRateWidgetView: View {
    let entry: HeartRateEntry

    /// Pruned on the way OUT as well as on the way in, matching the Kotlin twin. A widget rendered
    /// hours after the last publish would otherwise draw a trace whose newest point is long stale, under
    /// a time axis implying it is current — and WidgetKit renders an entry at ITS date, which is why the
    /// window is measured from `entry.date` rather than from `Date()`.
    private var series: [HrPoint] {
        HrTrace.prune(entry.snap?.hrSeries ?? [], nowSec: Int64(entry.date.timeIntervalSince1970))
    }
    private var stats: HrTrace.Stats? { HrTrace.stats(series) }
    /// Age-checked, so an hours-old reading is not printed as current. Without this the prune above made
    /// the card incoherent: the trace emptied while the headline kept its confident number.
    private var shown: (bpm: Int?, stale: Bool) {
        HrDisplay.resolve(bpm: entry.snap?.bpm, newestPointTs: series.last?.ts, now: entry.date)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                WidgetHeader(icon: "heart", title: Text("Heart rate"))
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(verbatim: shown.bpm.map(String.init) ?? "—")
                        .font(StrandFont.dot(42))
                        .tracking(StrandFont.dotTracking(42))
                        .foregroundStyle(shown.stale ? StrandPalette.textSecondary : StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if shown.bpm != nil {
                        Text("bpm")
                            .font(StrandFont.light(11))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .padding(.top, 14)
                Spacer(minLength: 4)
                if let stats {
                    Text("Min \(stats.min) • Max \(stats.max)")
                        .font(StrandFont.light(11))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(width: 112, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                if let updated = entry.snap?.updated, updated != .distantPast {
                    Text("Updated \(updated, format: .dateTime.hour().minute())")
                        .font(StrandFont.light(11))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 0)
                if !series.isEmpty {
                    HrTraceChart(series: series, stats: stats)
                        .frame(height: 70)
                    HrTimeAxis(series: series)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// One spoken sentence rather than a run of loose numbers. The Android twin had to settle for
    /// per-label descriptions because Glance cannot mark a Text decorative; SwiftUI can combine the
    /// whole card, so it does. Staleness is not encoded in colour here at all, so nothing needs saying
    /// about it.
    private var accessibilityText: String {
        // String(localized:) rather than bare literals. The audit DOES scan `.accessibilityLabel(`, but
        // it matches a literal sitting immediately after the paren — and this is a computed property, so
        // extracting the sentence here hid it from the check. Hardcoded English would have shipped to
        // every locale with the gate green, which is the same trap the Kotlin twin records for copy
        // written inside a semantics {} lambda.
        guard let bpm = shown.bpm else { return String(localized: "Heart rate, no reading") }
        guard let stats else { return String(localized: "Heart rate \(bpm) bpm") }
        return String(localized: "Heart rate \(bpm) bpm, minimum \(stats.min), maximum \(stats.max)")
    }
}

/// The trace in the app's chart style: Effort-blue fill, the periwinkle line, a dashed rule down from the
/// peak, and the newest reading's dot (drawn by `HrTraceShape` itself for lone readings).
private struct HrTraceChart: View {
    let series: [HrPoint]
    let stats: HrTrace.Stats?

    var body: some View {
        GeometryReader { geo in
            let pts = HrTrace.points(series, width: geo.size.width, height: geo.size.height)
            ZStack(alignment: .topLeading) {
                if let stats, stats.max > stats.min, let peak = pts.min(by: { $0.y < $1.y }) {
                    // The peak, marked the way the app's charts mark a cursor: a dashed rule to the base.
                    Path { p in
                        p.move(to: CGPoint(x: peak.x, y: peak.y))
                        p.addLine(to: CGPoint(x: peak.x, y: geo.size.height))
                    }
                    .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                HrTraceShape(series: series, filled: true)
                    .fill(WidgetChartStyle.fill)
                HrTraceShape(series: series, filled: false)
                    .stroke(WidgetChartStyle.line, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                if pts.count > 1, let last = pts.last {
                    Circle().fill(Color.white)
                        .frame(width: 6, height: 6)
                        .position(x: min(max(last.x, 3), geo.size.width - 3), y: last.y)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct HrTimeAxis: View {
    let series: [HrPoint]

    var body: some View {
        let ticks = HrTrace.timeTicks(series)
        // One instant pinned to the left edge reads as a stray rather than an axis, so it waits for a
        // span to label — matching the twin.
        if ticks.count >= 2 {
            HStack {
                ForEach(Array(ticks.enumerated()), id: \.offset) { i, ts in
                    Text(Date(timeIntervalSince1970: TimeInterval(ts)),
                         format: .dateTime.hour().minute())
                        .font(StrandFont.light(9.5))
                        .foregroundStyle(i == ticks.count - 1 ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                    if i < ticks.count - 1 { Spacer(minLength: 0) }
                }
            }
        }
    }
}

struct HeartRateWidget: Widget {
    static let kind = "HeartRateWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: HeartRateProvider()) { entry in
            if #available(iOS 17.0, *) {
                HeartRateWidgetView(entry: entry)
                    .containerBackground(for: .widget) { WidgetCardBackground() }
            } else {
                HeartRateWidgetView(entry: entry)
                    .padding()
                    .background(WidgetCardBackground())
            }
        }
        .configurationDisplayName("Heart Rate")
        .description("Live heart rate with the last three hours as a trace.")
        .supportedFamilies([.systemMedium])
    }
}
