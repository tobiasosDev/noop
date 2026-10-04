import SwiftUI
import StrandDesign

// MARK: - Wrist-sized v2 pieces
//
// The watch draws the same v2 language as the phone (dot-matrix numerals, a hairline ink ramp, one glow per
// screen) at wrist scale. These are the few pieces every watch page shares.

/// A score ring: a faint full track, the coloured arc from the top, a small white knob at the arc's end,
/// and the value in the dot-matrix face. `nil` draws the empty track with a dash and a small "cal" marker:
/// a score the phone has not earned (or one that has gone stale) never shows a number.
struct WatchScoreRing: View {
    let value: Double?
    let tint: Color
    /// The ring's square footprint in the layout.
    var diameter: CGFloat = 54
    var lineWidth: CGFloat = 4.5
    var numberSize: CGFloat = 15

    /// Radius of the stroke's centre line: the board draws the ring a few points inside its box
    /// (r 22 in a 54 box).
    private var radius: CGFloat { diameter * 22 / 54 }

    var body: some View {
        let f = min(max((value ?? 0) / 100, 0), 1)
        ZStack {
            Group {
                Circle().stroke(Color.white.opacity(0.10), lineWidth: lineWidth)
                if value != nil, f > 0 {
                    Circle()
                        .trim(from: 0, to: f)
                        .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: radius * 2, height: radius * 2)
            if value != nil, f > 0 {
                knob(fraction: f)
            }
            if let value {
                Text(verbatim: "\(Int(value.rounded()))")
                    .font(StrandFont.dot(numberSize))
                    .tracking(StrandFont.dotTracking(numberSize))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.leading, 2)
                    .minimumScaleFactor(0.6)
            } else {
                VStack(spacing: 0) {
                    Text(verbatim: "–")
                        .font(StrandFont.dot(numberSize))
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text("cal")
                        .font(StrandFont.book(8))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func knob(fraction f: Double) -> some View {
        let r = radius
        let a = Angle.degrees(-90 + 360 * f).radians
        let d = lineWidth * 1.25
        return Circle()
            .fill(Color.white)
            .frame(width: d, height: d)
            .offset(x: r * CGFloat(cos(a)), y: r * CGFloat(sin(a)))
    }
}

/// The small white "live" dot with its faint halo.
struct WatchLiveDot: View {
    var color: Color = .white
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .background(Circle().fill(Color.white.opacity(0.12)).frame(width: 12, height: 12))
            .accessibilityHidden(true)
    }
}

/// A dot-matrix status pill (`WORK`, `REST`, `Z3`) at wrist size.
struct WatchDotTag: View {
    let text: String
    var size: CGFloat = 11
    var body: some View {
        Text(verbatim: text)
            .font(StrandFont.dot(size, weight: 700))
            .tracking(size * 0.08)
            .textCase(.uppercase)
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 3)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
    }
}

/// A watch page's glow: `glow`'s colour rising from below the bottom edge of the screen (the hero
/// treatment, stretched to the whole face).
struct WatchGlowBackground: View {
    let glow: NoopGlow
    var strength: Double = 0.55
    var body: some View {
        RadialGradient(
            stops: [
                .init(color: glow.accent.opacity(strength), location: 0),
                .init(color: glow.deep.opacity(strength * 0.7), location: 0.45),
                .init(color: .black, location: 0.82),
            ],
            center: UnitPoint(x: 0.5, y: 1.12),
            startRadius: 0,
            endRadius: 220
        )
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The watch's pill buttons: ink for the primary action, a raised grey for the secondary one.
struct WatchPillButtonStyle: ButtonStyle {
    var primary: Bool = true
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StrandFont.medium(14))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(primary ? StrandPalette.goldDeepText : (tint ?? StrandPalette.textPrimary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule(style: .continuous)
                .fill(primary ? StrandPalette.textPrimary : NoopVisualStyle.raised))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(primary ? Color.clear : NoopVisualStyle.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}
