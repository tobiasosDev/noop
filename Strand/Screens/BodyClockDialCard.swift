import SwiftUI
import StrandAnalytics
import StrandDesign

/// A 24 h dial comparing the night actually slept against the chronotype-ideal window (#1680).
///
/// One ring, two readings: the hatched window is where the body clock wanted the night, the solid arc
/// laid along it is where it happened. Overlap is the whole message — the card exists so "was last
/// night's timing right" is answerable at a glance, which the existing text-only `BodyClockCard` on Health
/// cannot do.
///
/// VOCABULARY. The caption measures `sleepWindowOffsetHours` — the distance between the two ARCS DRAWN —
/// and NOT `offsetVsScheduleMinutes`, which compares the clock to the wearer's habitual schedule and is
/// what the Health card already reports. The two disagree exactly when someone keeps a consistent
/// schedule that does not suit their clock, and that is the case this dial exists to show, so captioning
/// it with the other number would contradict the picture. For the same reason the hatched window is
/// labelled "Your clock", never "Usual".
///
/// Nothing here computes a metric: the window, the offset and the chronotype all come from
/// `CircadianEngine`, byte-identical with the Kotlin twin. Only the drawing is per-platform.
struct BodyClockDialCard: View {
    let estimate: CircadianEngine.PhaseEstimate
    /// The night's own bed/wake clock hours (0..<24, fractional), from the scored session.
    let actualBedHour: Double
    let actualWakeHour: Double

    /// The card's one accent: the night actually slept. The window it is read against stays in ink, told
    /// apart by its hatch rather than by a second colour.
    private var hue: Color { NoopGlow.sleep.accent }

    /// The dial's side. Leaves the summary column beside it room for a two-line verdict on a phone.
    private let dialSide: CGFloat = 164

    /// The night's length, taken the long way round the clock when it crosses midnight.
    private var durationHours: Double {
        let d = (actualWakeHour - actualBedHour).truncatingRemainder(dividingBy: 24)
        return d <= 0 ? d + 24 : d
    }

    private var ideal: (bedHour: Double, wakeHour: Double)? {
        CircadianEngine.idealSleepWindow(tempMinHour: estimate.tempMinHour, durationHours: durationHours)
    }

    private var offsetHours: Double {
        CircadianEngine.sleepWindowOffsetHours(tempMinHour: estimate.tempMinHour,
                                               actualWakeHour: actualWakeHour)
    }

    var body: some View {
        // `ideal` is nil exactly when the night's length is non-positive or a full day — the same input
        // that makes `sweep` wrap to 24 h and draw the actual arc as a complete ring. Rendering a full
        // circle with no ideal window beside it would state something false about the night, so the card
        // stands down instead. Twin of the Kotlin guard.
        if let ideal {
            NoopCard {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    HStack(alignment: .center, spacing: 16) {
                        dial
                            .frame(width: dialSide, height: dialSide)
                            .accessibilityElement(children: .ignore)
                            // Label only. The verdict is the caption Text beside it, a separate element, so
                            // giving the dial the same string as its VALUE made VoiceOver announce it twice.
                            .accessibilityLabel(Text("Body clock dial"))
                        summary(ideal)
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// The badge and, once the fit is strong enough to name one, the chronotype.
    private var header: some View {
        HStack {
            NoopIconBadge("Body clock", icon: "clock-countdown")
            Spacer(minLength: 8)
            if let chronotype = CircadianEngine.chronotype(estimate) {
                NoopTag(verbatim: chronotypeText(chronotype), size: 12)
            }
        }
    }

    private func summary(_ ideal: (bedHour: Double, wakeHour: Double)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(alignmentText)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Last night against your clock")
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            legend(ideal)
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Midnight at the top, clocking round to the right — the orientation every 24 h dial uses, so the
    /// ring reads without a legend. SwiftUI's zero angle is at 3 o'clock, hence the −90.
    private func angle(_ hour: Double) -> Angle { .degrees(hour / 24 * 360 - 90) }

    /// Sweep from `from` to `to` going clockwise, always positive so an arc crossing midnight still draws.
    private func sweep(_ from: Double, _ to: Double) -> Double {
        let d = (to - from).truncatingRemainder(dividingBy: 24)
        return d <= 0 ? d + 24 : d
    }

    /// The ring geometry, resolved once. Explicitly typed and hoisted out of the drawing closure: an
    /// 84-line `Canvas` body of inferred `CGFloat` arithmetic exceeded the Swift type-checker's budget
    /// and failed the macOS build outright ("unable to type-check this expression in reasonable time"),
    /// which only app-build compiles — the same trap `DevicesView`'s gates hit.
    ///
    /// The radii are NAMED BANDS. From the rim inwards: the quarter-hour ticks, the ring (the hatched
    /// window and the night arc share it on purpose — the night is read against the window it sits
    /// in), the onset bed, and the hour numerals. The numerals sit INSIDE the ring, clear of the ticks
    /// that #2350 showed they collide with, and the bed shares their band only away from them (see
    /// `drawHourLabels`).
    private struct DialGeometry {
        let centre: CGPoint
        let scale: CGFloat
        let outer: CGFloat
        let ring: CGFloat
        let glyphRadius: CGFloat
        let labelRadius: CGFloat

        /// The rim the band offsets were tuned against: a 184 pt dial, so `side / 2 - 2`.
        static let tunedRim: CGFloat = 90
        static let majorTick: CGFloat = 10
        static let hourTick: CGFloat = 6
        static let minorTick: CGFloat = 4
        static let ringWidth: CGFloat = 16
        static let nightWidth: CGFloat = 6
        static let knob: CGFloat = 5.5
        static let glyph: CGFloat = 11

        /// The band offsets are a FRACTION of the available radius, not fixed subtractions, so a narrow
        /// card keeps the tuned proportions instead of driving the inner bands through the centre. The
        /// factor is exactly 1 at rim 90, and every band stays positive for any rim.
        init(size: CGSize) {
            let side: CGFloat = min(size.width, size.height)
            centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let rim: CGFloat = side / 2 - 2
            scale = rim / DialGeometry.tunedRim
            outer = rim
            ring = rim - 22 * scale
            glyphRadius = rim - 38 * scale
            labelRadius = rim - 46.5 * scale
        }
    }

    private var dial: some View {
        Canvas { ctx, size in
            let g = DialGeometry(size: size)
            drawTicks(ctx, g)
            drawRing(ctx, g)
            drawWindow(ctx, g)
            drawNight(ctx, g)
            drawHourLabels(ctx, g)
            drawOnset(ctx, g)
        } symbols: {
            PhIcon("bed", size: DialGeometry.glyph)
                .foregroundStyle(StrandPalette.textPrimary)
                .tag(Self.bedSymbol)
        }
        .overlay { inBed }
    }

    private static let bedSymbol = 0

    /// The night's length at the centre of the dial. Fixed point sizes: the text sits in a fixed-radius
    /// canvas and must not grow into the numerals at large Dynamic Type sizes.
    private var inBed: some View {
        VStack(spacing: 2) {
            Text(verbatim: durationText(durationHours * 60))
                .font(StrandFont.light(17))
                .foregroundStyle(StrandPalette.textPrimary)
            Text("in bed")
                .font(StrandFont.light(10))
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: dialSide * 0.42)
        .accessibilityElement(children: .combine)
    }

    /// Quarter-hour ticks round the rim: the four six-hour marks longest and brightest, the hours next,
    /// the quarters faint. Midnight is the one at the top; the numerals inside name all four.
    private func drawTicks(_ ctx: GraphicsContext, _ g: DialGeometry) {
        for i in 0..<96 {
            let isMajor: Bool = i % 24 == 0
            let isHour: Bool = i % 4 == 0
            let a: Double = angle(Double(i) / 4).radians
            let len: CGFloat = (isMajor ? DialGeometry.majorTick : isHour ? DialGeometry.hourTick
                                : DialGeometry.minorTick) * g.scale
            let cosA: CGFloat = cos(a)
            let sinA: CGFloat = sin(a)
            var p = Path()
            p.move(to: CGPoint(x: g.centre.x + cosA * (g.outer - len), y: g.centre.y + sinA * (g.outer - len)))
            p.addLine(to: CGPoint(x: g.centre.x + cosA * g.outer, y: g.centre.y + sinA * g.outer))
            let tint: Color = isMajor ? StrandPalette.textPrimary.opacity(0.75)
                : isHour ? StrandPalette.textTertiary : NoopVisualStyle.quaternaryText
            ctx.stroke(p, with: .color(tint), lineWidth: isMajor ? 1.2 : 1)
        }
    }

    /// The full-day ring the window and the night are laid on: a faint band, so the highlighted spans
    /// read as portions of a whole day rather than as free-floating strokes.
    private func drawRing(_ ctx: GraphicsContext, _ g: DialGeometry) {
        let rect = CGRect(x: g.centre.x - g.ring, y: g.centre.y - g.ring, width: g.ring * 2, height: g.ring * 2)
        ctx.stroke(Path(ellipseIn: rect), with: .color(StrandPalette.textPrimary.opacity(0.10)),
                   lineWidth: DialGeometry.ringWidth * g.scale)
    }

    /// The body clock's window as a hatched span of the ring. A hatch rather than a dash: a dashed 7 pt
    /// stroke read as radial hash marks once its dashes were shorter than it was wide (#2350), and it
    /// washed out over a custom background; a hatched band under a solid arc keeps both legible.
    private func drawWindow(_ ctx: GraphicsContext, _ g: DialGeometry) {
        guard let ideal else { return }
        let band: Path = arcPath(g, radius: g.ring, from: ideal.bedHour, to: ideal.wakeHour)
            .strokedPath(StrokeStyle(lineWidth: DialGeometry.ringWidth * g.scale, lineCap: .butt))
        ctx.drawLayer { layer in
            layer.clip(to: band)
            layer.fill(band, with: .color(StrandPalette.textPrimary.opacity(0.04)))
            let hatch = DiagonalHatch(spacing: 5).path(in: band.boundingRect.insetBy(dx: -4, dy: -4))
            layer.stroke(hatch, with: .color(StrandPalette.textTertiary), lineWidth: 1.4)
        }
    }

    /// The night actually slept: a solid arc in the accent along the window's ring, with a glowing knob
    /// at each end.
    private func drawNight(_ ctx: GraphicsContext, _ g: DialGeometry) {
        let arc: Path = arcPath(g, radius: g.ring, from: actualBedHour, to: actualWakeHour)
        ctx.stroke(arc, with: .color(hue),
                   style: StrokeStyle(lineWidth: DialGeometry.nightWidth * g.scale, lineCap: .round))
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: StrandPalette.textPrimary.opacity(0.8), radius: 4))
            for hour in [actualBedHour, actualWakeHour] {
                let a: Double = angle(hour).radians
                let r: CGFloat = DialGeometry.knob * g.scale
                let c = CGPoint(x: g.centre.x + cos(a) * g.ring, y: g.centre.y + sin(a) * g.ring)
                layer.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                           with: .color(StrandPalette.textPrimary))
            }
        }
    }

    private func arcPath(_ g: DialGeometry, radius: CGFloat, from: Double, to: Double) -> Path {
        let startAngle: Angle = angle(from)
        let sweepDegrees: Double = sweep(from, to) / 24 * 360
        var p = Path()
        p.addArc(center: g.centre, radius: radius, startAngle: startAngle,
                 endAngle: .degrees(startAngle.degrees + sweepDegrees), clockwise: false)
        return p
    }

    /// Hour numerals at 00, 06, 12 and 18, inside the ring.
    ///
    /// The numerals leave no time unreadable: the card's own caption claims a night is "2.6 h later than
    /// your body clock", and without them there was no way to check that against the picture (#2350).
    /// They settle the 12-versus-24-hour question by answering it, in the 24-hour form a dial uses. A
    /// numeral within 45 minutes of onset gives way to the bed, which shares its band.
    private func drawHourLabels(_ ctx: GraphicsContext, _ g: DialGeometry) {
        for hour in stride(from: 0.0, to: 24.0, by: 6.0) {
            if hoursApart(hour, actualBedHour) < 0.75 { continue }
            let a: Double = angle(hour).radians
            let x: CGFloat = g.centre.x + cos(a) * g.labelRadius
            let y: CGFloat = g.centre.y + sin(a) * g.labelRadius
            // A FIXED point size: the numerals sit in a fixed-radius canvas, and a Dynamic Type text style
            // would grow them into the ring at accessibility sizes. The dial is a diagram, and its geometry
            // does not scale, so neither may its labels.
            // Colour via the RESOLVED text's shading, NOT via `.foregroundStyle` on the `Text`. That
            // overload returns `Text` only from macOS 14, and this target is macOS 13, so there the
            // expression is a `View` and `resolve` has no matching overload.
            var numeral = ctx.resolve(Text(String(format: "%02d", Int(hour))).font(StrandFont.light(10)))
            numeral.shading = .color(StrandPalette.textSecondary)
            ctx.draw(numeral, at: CGPoint(x: x, y: y), anchor: .center)
        }
    }

    /// The shorter way round the clock between two hours, in 0...12.
    private func hoursApart(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 24)
        return d > 12 ? 24 - d : d
    }

    /// A bed at sleep ONSET. Without it the night arc has two indistinguishable ends and the reader must
    /// work out which way round the day runs before the picture means anything — the marker turns
    /// "somewhere in this band" into "it started here". Set just inside the ring so it points at the
    /// start without covering the knob that marks it.
    private func drawOnset(_ ctx: GraphicsContext, _ g: DialGeometry) {
        guard let bed = ctx.resolveSymbol(id: Self.bedSymbol) else { return }
        let onset: Double = angle(actualBedHour).radians
        let x: CGFloat = g.centre.x + cos(onset) * g.glyphRadius
        let y: CGFloat = g.centre.y + sin(onset) * g.glyphRadius
        ctx.draw(bed, at: CGPoint(x: x, y: y), anchor: .center)
    }

    /// Which span is which, with the clock times of each. The swatches are drawn in the SAME style as the
    /// dial (solid accent, hatched window) so the mapping cannot drift apart from the drawing.
    private func legend(_ ideal: (bedHour: Double, wakeHour: Double)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            legendItem(label: String(localized: "Last night"),
                       times: clockRange(actualBedHour, actualWakeHour)) {
                Capsule(style: .continuous).fill(hue).frame(width: 16, height: 4)
            }
            legendItem(label: String(localized: "Your clock"),
                       times: clockRange(ideal.bedHour, ideal.wakeHour)) {
                SleepHatchWindow(cornerRadius: 2).frame(width: 16, height: 9)
            }
        }
    }

    private func legendItem<Swatch: View>(label: String, times: String,
                                          @ViewBuilder swatch: () -> Swatch) -> some View {
        HStack(alignment: .center, spacing: 8) {
            swatch()
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: label)
                    .font(StrandFont.light(11))
                    .foregroundStyle(StrandPalette.textTertiary)
                Text(verbatim: times)
                    .font(StrandFont.light(11.5))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    /// "22:32 – 06:16" in the reader's clock format.
    private func clockRange(_ from: Double, _ to: Double) -> String {
        "\(clockText(from)) – \(clockText(to))"
    }

    private func clockText(_ hour: Double) -> String {
        let h = hour.truncatingRemainder(dividingBy: 24)
        let seconds = (h < 0 ? h + 24 : h) * 3600
        let date = Calendar.current.startOfDay(for: Date()).addingTimeInterval(seconds.rounded())
        return AppClock.hourMinuteFormatter().string(from: date)
    }

    /// Minutes → "Xm" / "Yh Zm" (verbatim of `SleepView.durationText`).
    private func durationText(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return String(localized: "\(m)m") }
        return String(localized: "\(m / 60)h \(m % 60)m")
    }

    /// Rounded to five minutes: the underlying phase is an activity fit, so a to-the-minute caption would
    /// imply a precision the estimate does not carry.
    private var alignmentText: String {
        let minutes = Int((offsetHours * 60 / 5).rounded()) * 5
        if abs(minutes) < 30 { return String(localized: "In sync with your body clock") }
        let hours = abs(Double(minutes)) / 60
        // Locale-formatted, NOT String(format:). That is C-locale, so it prints "1.5 h" for a German
        // reader while the Android twin's String.format prints "1,5 h" from the default locale — the two
        // platforms disagreeing on a decimal separator in the same sentence.
        let amount = hours >= 1
            ? "\(hours.formatted(.number.precision(.fractionLength(1)))) h"
            : "\(abs(minutes)) min"
        return minutes > 0
            ? String(localized: "\(amount) later than your body clock")
            : String(localized: "\(amount) earlier than your body clock")
    }

    private func chronotypeText(_ c: CircadianEngine.Chronotype) -> String {
        switch c {
        case .morning:      return String(localized: "Morning type")
        case .intermediate: return String(localized: "Intermediate type")
        case .evening:      return String(localized: "Evening type")
        }
    }
}
