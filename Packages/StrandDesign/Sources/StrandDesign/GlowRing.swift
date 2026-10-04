import SwiftUI

// MARK: - GlowRing — the v2 score ring
//
// A faint full-circle track, the score's arc from 12 o'clock in its accent, and a white knob with a soft
// glow at the arc's end (the kit's ring gauge), with the number in the dot-matrix face at the centre. The
// arc springs in on appear and re-animates when the value changes (day nav). Motion gated on Reduce
// Motion; macOS-13 / iOS-17 safe.

public struct GlowRing: View {

    /// Target fill, 0...1.
    public var fraction: Double
    /// The number shown in the centre — rolls up to this.
    public var value: Double
    /// Formats the (animated) value into the centre string.
    public var format: (Double) -> String
    /// The arc colour (solid, saturated — the domain accent).
    public var color: Color
    public var diameter: CGFloat
    public var lineWidth: CGFloat

    public init(fraction: Double, value: Double, format: @escaping (Double) -> String,
                color: Color, diameter: CGFloat, lineWidth: CGFloat) {
        self.fraction = fraction
        self.value = value
        self.format = format
        self.color = color
        self.diameter = diameter
        self.lineWidth = lineWidth
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// The centre-number font for a ring of the given diameter — the dot-matrix face at `diameter * 0.32`.
    /// Exposed so an EMPTY / carried / "No data" ring (which doesn't draw a `GlowRing`) can render its
    /// centre text in the EXACT same size as a filled ring, keeping the hero trio's three centre read-outs
    /// visually consistent regardless of state.
    public static func centerFont(diameter: CGFloat) -> Font {
        StrandFont.dot(diameter * 0.32)
    }

    private var clamped: CGFloat { CGFloat(min(max(fraction, 0), 1)) }
    private var filled: CGFloat { appeared ? clamped : 0 }
    private var shown: Double { appeared ? value : 0 }
    private var drawSpring: Animation { .spring(response: 0.9, dampingFraction: 0.86) }

    public var body: some View {
        ZStack {
            // The faint full-circle track, so the arc reads as a fraction of a circle.
            Circle()
                .stroke(StrandPalette.textPrimary.opacity(0.10),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            arc.stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // The white knob at the arc's end, with the kit's soft glow.
            if filled > 0.001 {
                let r = (diameter - lineWidth) / 2
                let a = Angle.degrees(-90 + 360 * Double(filled)).radians
                Circle().fill(Color.white)
                    .frame(width: lineWidth * 2.4, height: lineWidth * 2.4)
                    .shadow(color: .white.opacity(0.8), radius: 4)
                    .offset(x: r * CGFloat(cos(a)), y: r * CGFloat(sin(a)))
            }

            // Centred rolling number.
            Text(format(shown))
                .font(Self.centerFont(diameter: diameter))
                .tracking(StrandFont.dotTracking(diameter * 0.32))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .padding(.horizontal, lineWidth + 4)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.85), value: shown)
        }
        .frame(width: diameter, height: diameter)
        .animation(reduceMotion ? nil : drawSpring, value: filled)
        .onAppear { appeared = true }
    }

    /// The trimmed arc, drawn from 12 o'clock clockwise.
    private var arc: some Shape {
        Circle().trim(from: 0, to: max(0.0001, filled)).rotation(.degrees(-90))
    }
}
