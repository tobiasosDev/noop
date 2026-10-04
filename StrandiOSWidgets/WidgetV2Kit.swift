import SwiftUI
import StrandDesign

// MARK: - v2 widget pieces
//
// The home-screen widgets draw the v2 language at widget scale: a near-black card ramp, a 12 pt header
// (Phosphor glyph + title + caption), score rings with a white knob and the value in the dot-matrix
// face, and the one chart style of the app (a thin periwinkle line over an Effort-blue fill that fades
// out, ending in a white dot).

/// The card fill every home-screen widget sits on (`.wg`): a near-black vertical ramp.
struct WidgetCardBackground: View {
    var body: some View {
        LinearGradient(colors: [NoopVisualStyle.surfaceTop, NoopVisualStyle.surfaceBottom],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// The widget header (`.wh`): a 13 pt glyph, a 12 pt title (11 pt for the sub-headers inside a widget)
/// and an optional caption at the right.
struct WidgetHeader<Trailing: View>: View {
    let icon: String
    let title: Text
    var size: CGFloat = 12
    @ViewBuilder var trailing: () -> Trailing

    init(icon: String, title: Text, size: CGFloat = 12, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.icon = icon
        self.title = title
        self.size = size
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 6) {
            PhIcon(icon, size: 13)
            title
                .font(StrandFont.book(size))
                .lineLimit(1)
            Spacer(minLength: 4)
            trailing()
                .font(StrandFont.light(11))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
        }
        .foregroundStyle(StrandPalette.textSecondary)
    }
}

extension WidgetHeader where Trailing == EmptyView {
    init(icon: String, title: Text, size: CGFloat = 12) {
        self.init(icon: icon, title: title, size: size) { EmptyView() }
    }
}

/// A static, widget-safe score ring: a faint full track, the coloured arc from the top with a white
/// knob at its end, and the value in the dot-matrix face. Deliberately animation-free — WidgetKit
/// timelines don't reliably fire `onAppear`, so an animated ring can freeze empty until the next
/// rebuild. `fraction == nil` draws the empty track only (unscored) under a dash.
struct WidgetRing: View {
    /// Centre read-out already formatted (whole number, or one-decimal WHOOP Effort).
    let text: String?
    /// Arc fill 0…1; nil draws the empty track only.
    let fraction: Double?
    let color: Color
    /// The ring's square footprint in the layout.
    let diameter: CGFloat
    let lineWidth: CGFloat
    var numberSize: CGFloat
    var unit: String? = nil
    /// Radius of the stroke's centre line. Defaults to the largest that keeps the stroke inside
    /// `diameter`; the board draws most rings a few points inside their box.
    var radius: CGFloat? = nil

    var body: some View {
        let f = CGFloat(min(max(fraction ?? 0, 0), 1))
        let r = radius ?? (diameter - lineWidth) / 2
        let a = Angle.degrees(-90 + 360 * Double(f)).radians
        ZStack {
            Group {
                Circle().stroke(StrandPalette.textPrimary.opacity(0.10), lineWidth: lineWidth)
                if fraction != nil {
                    Circle()
                        // A genuine zero still draws a round-cap bead so scored-0 reads as data, not absence.
                        .trim(from: 0, to: max(0.0001, f))
                        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: r * 2, height: r * 2)
            if fraction != nil {
                Circle()
                    .fill(Color.white)
                    .frame(width: lineWidth * 1.2, height: lineWidth * 1.2)
                    .offset(x: r * CGFloat(cos(a)), y: r * CGFloat(sin(a)))
            }
            HStack(alignment: .lastTextBaseline, spacing: 1) {
                Text(verbatim: text ?? "–")
                    .font(StrandFont.dot(numberSize))
                    .tracking(StrandFont.dotTracking(numberSize))
                if let unit, text != nil {
                    Text(verbatim: unit)
                        .font(StrandFont.dot(numberSize * 0.46))
                }
            }
            .foregroundStyle(text == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.leading, 2)
            .frame(maxWidth: max(r * 2 - lineWidth - 4, 1))
        }
        .frame(width: diameter, height: diameter)
    }
}

/// The app's chart stroke and fill, for the widget traces.
enum WidgetChartStyle {
    /// The 1.2 pt periwinkle line.
    static var line: Color { StrandPalette.metricCyan }
    /// The fill under the line: Effort blue fading to clear.
    static var fill: LinearGradient {
        LinearGradient(colors: [StrandPalette.effortColor.opacity(0.45), StrandPalette.effortColor.opacity(0)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// A dot-matrix status pill (`LOW`, `PRIMED`) at widget size.
struct WidgetDotTag: View {
    let text: String
    var body: some View {
        Text(verbatim: text)
            .font(StrandFont.dot(11, weight: 700))
            .tracking(11 * 0.08)
            .textCase(.uppercase)
            .lineLimit(1)
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, 7)
            .padding(.top, 1)
            .padding(.bottom, 2)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
    }
}
