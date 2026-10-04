import SwiftUI

// MARK: - NOOP visual foundation (v2 — dot-matrix dark)
//
// These tokens describe the visual treatment used by NOOP's views. They deliberately contain no
// navigation, state, or domain semantics: screens keep their hierarchy and data bindings, while cards,
// gauges, typography, and chrome share one maintainable source of truth.
//
// v2 is an instrument panel at night: a true-black ground, cards that are a quiet grey-black vertical
// gradient behind a 1 px hairline, light grotesk text in three ink strengths, and colour reserved for
// the one glowing hero per screen. Dark is the designed appearance; the light values are a paper
// variant that keeps the same structure so the Appearance setting still works.

public enum NoopVisualStyle {
    // Ground and surfaces. `canvas` is the screen ground; `surfaceTop`→`surfaceBottom` is the card ramp
    // (light at the top); `inset` is a raised control (circle buttons, pills); `raised` an icon tile.
    public static let canvas = Color(light: "#F2F1EE", dark: "#000000")
    public static let surface = Color(light: "#FFFFFF", dark: "#0B0B0C")
    public static let surfaceTop = Color(light: "#FFFFFF", dark: "#151517")
    public static let surfaceBottom = Color(light: "#F7F6F3", dark: "#0A0A0B")
    public static let inset = Color(light: "#E9E8E4", dark: "#141416")
    public static let raised = Color(light: "#E2E1DD", dark: "#1C1C1F")

    // Hairlines: `border` is the card edge and divider (7 % white), `borderHighlight` the stronger edge
    // used on chips, pills and the tab bar (13 % white).
    public static let border = Color(light: "#0000001A", dark: "#FFFFFF12")
    public static let borderHighlight = Color(light: "#00000026", dark: "#FFFFFF21")
    public static let divider = Color(light: "#00000014", dark: "#FFFFFF12")
    /// The inner top highlight a v2 card carries instead of a drop shadow.
    public static let topHighlight = Color(light: "#FFFFFFB3", dark: "#FFFFFF12")

    // Ink: primary, 62 % and 36 % strengths, plus a 16 % ink for inactive dots and empty tracks.
    public static let primaryText = Color(light: "#121214", dark: "#F3F2EF")
    public static let secondaryText = Color(light: "#1214149E", dark: "#F3F2EF9E")
    public static let tertiaryText = Color(light: "#12121473", dark: "#F3F2EF5C")
    public static let quaternaryText = Color(light: "#12121429", dark: "#F3F2EF29")

    // The chrome accent world (the Mint preset). Used for the one active state, never for text blocks.
    public static let mint = Color(light: "#149A78", dark: "#5FD3B8")
    public static let mintDeep = Color(light: "#0D765C", dark: "#13A982")
    public static let mintGlow = Color(light: "#38C99E", dark: "#7BE3CB")

    // Shape and spacing (v2): hero 38, card 28, list 24, pills fully round; 20 pt screen gutter,
    // 18 pt card padding, 12 pt between stacked cards, ~30 pt before a section title.
    public static let heroRadius: CGFloat = 38
    public static let cardRadius: CGFloat = 28
    public static let listRadius: CGFloat = 24
    public static let compactRadius: CGFloat = 24
    public static let tileRadius: CGFloat = 11
    public static let pillRadius: CGFloat = 999
    public static let pagePadding: CGFloat = 20
    public static let cardPadding: CGFloat = 18
    public static let heroPadding: CGFloat = 22
    public static let itemGap: CGFloat = 12
    public static let sectionGap: CGFloat = 30

    /// Heart-rate zone fills for zone strips and bars on a strain screen: one cool ramp (blue → indigo →
    /// purple → rose) instead of five unrelated accents, so a zone strip never adds a second colour world.
    /// `zone` is 1...5 (clamped).
    public static func zoneFill(_ zone: Int) -> Color {
        zoneFills[min(max(zone, 1), 5) - 1]
    }
    private static let zoneFills: [Color] = [
        Color(hex: "#22315F"), Color(hex: "#2F3A86"), Color(hex: "#4B3FA6"), Color(hex: "#5A2F72"), Color(hex: "#5C2433"),
    ]
}

/// Shared card/panel treatment: the v2 grey-black vertical ramp behind a 1 px hairline and an inner top
/// highlight. No drop shadow and no accent wash — colour belongs to the hero, not to neutral cards.
/// `tint` and `elevated` are kept for source compatibility; `tint` only adds a barely-there top glaze so
/// a domain card is not indistinguishable from a plain one when a caller insists on it.
public struct NoopPanelSurface: View {
    public var tint: Color?
    public var cornerRadius: CGFloat
    public var elevated: Bool
    public var surfaceOpacity: Double

    public init(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopVisualStyle.cardRadius,
        elevated: Bool = false,
        surfaceOpacity: Double = 1
    ) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.elevated = elevated
        self.surfaceOpacity = surfaceOpacity
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(
                LinearGradient(
                    colors: [NoopVisualStyle.surfaceTop, NoopVisualStyle.surfaceBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                if let tint {
                    shape.fill(
                        LinearGradient(
                            colors: [tint.opacity(0.025), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                }
            }
            .overlay(shape.strokeBorder(NoopVisualStyle.border, lineWidth: 1))
            .overlay(
                // The inset top highlight (CSS `inset 0 1px 0`): a 1 px light edge that fades out
                // within the first few points, so the card reads as lit from above.
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: NoopVisualStyle.topHighlight, location: 0),
                            .init(color: .clear, location: 0.08),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .opacity(surfaceOpacity)
    }
}

/// Shared edge-to-edge chrome for sheet and split-view headers. Unlike a card it has no
/// rounded outline, but it uses the same surface ramp and divider token.
public struct NoopChromeSurface: View {
    public init() {}

    public var body: some View {
        LinearGradient(
            colors: [NoopVisualStyle.surfaceTop, NoopVisualStyle.surfaceBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NoopVisualStyle.divider)
                .frame(height: 0.5)
        }
    }
}

public extension View {
    func noopPanel(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopVisualStyle.cardRadius,
        elevated: Bool = false,
        surfaceOpacity: Double = 1
    ) -> some View {
        background {
            NoopPanelSurface(
                tint: tint,
                cornerRadius: cornerRadius,
                elevated: elevated,
                surfaceOpacity: surfaceOpacity
            )
        }
    }
}
