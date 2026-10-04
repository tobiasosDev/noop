import SwiftUI
import StrandDesign

// MARK: - Shared pieces of the Today detail screens (Coupled view, Hydration, Live Session)

/// A v2 progress ring: a faint track, the arc clockwise from the top in the screen's accent, and a white
/// knob with a soft halo where the arc ends. Heavier than `NoopRingGauge` (an 8 pt stroke and a haloed
/// knob), which is how the Coupled view and Hydration heroes draw their rings.
struct G1bProgressRing: View {
    var fraction: Double
    var tint: Color
    var diameter: CGFloat
    var lineWidth: CGFloat = 8
    var knob: CGFloat = 14
    var halo: CGFloat = 26

    var body: some View {
        let f = min(max(fraction, 0), 1)
        let r = diameter / 2
        let a = Angle.degrees(-90 + 360 * f).radians
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.09), lineWidth: lineWidth)
                .frame(width: diameter, height: diameter)
            if f > 0 {
                Circle()
                    .trim(from: 0, to: f)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: diameter, height: diameter)
                ZStack {
                    Circle().fill(Color.white.opacity(0.18)).frame(width: halo, height: halo)
                    Circle().fill(Color.white).frame(width: knob, height: knob)
                }
                .offset(x: r * CGFloat(cos(a)), y: r * CGFloat(sin(a)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A centred metric for a glowing hero (`.mrow` with `text-align:center`): a 21 pt value with an inline
/// 10 pt unit, and a 10.5 pt caption in the hero label ink.
struct G1bCenteredMetric: View {
    var value: String
    var unit: String? = nil
    var label: Text
    var labelColor: Color = NoopMetric.heroLabel

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value)
                    .font(StrandFont.value(21))
                    .tracking(-0.42)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let unit {
                    Text(verbatim: unit)
                        .font(StrandFont.book(10))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            label
                .font(StrandFont.light(10.5))
                .foregroundStyle(labelColor)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
