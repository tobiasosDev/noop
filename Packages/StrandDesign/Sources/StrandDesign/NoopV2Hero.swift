import SwiftUI

// MARK: - v2 hero: one glow per screen
//
// The hero card is the only coloured surface on a v2 screen. Its colour rises from below the bottom
// edge like a lit dial seen through smoked glass (CSS: `radial-gradient(130% 75% at 50% 112%, accent 0%,
// deep 45%, floor 85%)`), a faint 9 pt dot grid sits over the upper half, and the edge is a GLASS RIM —
// a 1 pt white ring whose opacity follows the glow (~7 % over the dark part, ~20 % where the colour
// sits). Never a coloured border: a coloured hairline along a lit card reads as a mistake.

/// The colour worlds a hero can glow in.
public enum NoopGlow: Sendable, Hashable {
    case recovery      // Charge ≥ 67 %
    case moderate      // Charge 34–66 %
    case low           // Charge ≤ 33 %, health alerts
    case sleep
    case strain
    case stress
    case heart
    case ink           // neutral: settings, data, coach, onboarding

    /// The glow for a Charge score. The bands follow the Charge state words the same hero prints
    /// (`StrandPalette.recoveryState`): DEPLETED/LOW (< 50) red, MODERATE (50–69) amber, PRIMED/PEAK
    /// (≥ 70) green, so a glow can never contradict the word beside it.
    public static func charge(_ score: Double?) -> NoopGlow {
        guard let score else { return .ink }
        if score >= 70 { return .recovery }
        if score >= 50 { return .moderate }
        return .low
    }

    /// The bright accent — the colour at the bottom of the glow, and the screen's one accent.
    public var accent: Color { Self.accentTable[self] ?? .clear }

    /// The deep mid-stop of the glow.
    public var deep: Color { Self.deepTable[self] ?? .clear }

    /// The near-black the glow fades into at the top of the card.
    public var floor: Color { Self.floorTable[self] ?? .clear }

    /// The readable accent for text, ticks and chart strokes in this world (the heart glow's fill is a
    /// deep red; its legible accent is the rose heart colour).
    public var tint: Color {
        switch self {
        case .heart: return Self.heartTint
        case .low:   return Self.lowTint
        case .ink:   return Self.inkTint
        default:     return accent
        }
    }

    // Parsed once: these are read on every render of every hero.
    private static let accentTable: [NoopGlow: Color] = [
        .recovery: Color(hex: "#56D08A"),
        .moderate: Color(hex: "#E8B44C"),
        .low: Color(hex: "#EF4B55"),
        .sleep: Color(hex: "#9A55E6"),
        .strain: Color(hex: "#5872F2"),
        .stress: Color(hex: "#A9C94C"),
        .heart: Color(hex: "#C9303D"),
        .ink: Color(hex: "#C3C4CC"),
    ]
    private static let deepTable: [NoopGlow: Color] = [
        .recovery: Color(hex: "#0D3A22"),
        .moderate: Color(hex: "#4A3210"),
        .low: Color(hex: "#5C0F18"),
        .sleep: Color(hex: "#341258"),
        .strain: Color(hex: "#14247A"),
        .stress: Color(hex: "#2C4210"),
        .heart: Color(hex: "#5C0F18"),
        .ink: Color(hex: "#2A2A31"),
    ]
    private static let floorTable: [NoopGlow: Color] = [
        .recovery: Color(hex: "#030504"),
        .moderate: Color(hex: "#050403"),
        .low: Color(hex: "#060203"),
        .sleep: Color(hex: "#040207"),
        .strain: Color(hex: "#020309"),
        .stress: Color(hex: "#030402"),
        .heart: Color(hex: "#0A0203"),
        .ink: Color(hex: "#050505"),
    ]
    private static let heartTint = Color(hex: "#E2566A")
    private static let lowTint = Color(hex: "#DD3A45")
    private static let inkTint = Color(hex: "#F3F2EF")
}

/// The glow fill of a hero: the bottom-rising elliptical gradient (or the heart card's top-down wash).
public struct NoopGlowFill: View {
    public var glow: NoopGlow
    public init(_ glow: NoopGlow) { self.glow = glow }

    public var body: some View {
        if glow == .heart {
            LinearGradient(
                stops: [
                    .init(color: glow.accent, location: 0),
                    .init(color: glow.deep, location: 0.48),
                    .init(color: glow.floor, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        } else {
            Canvas { ctx, size in
                // radial-gradient(130% 75% at 50% 112%): an ellipse with radii 1.3 W × 0.75 H centred
                // just below the bottom edge. Drawn as a circle of radius ry, stretched horizontally.
                let rx = max(size.width * 1.3, 1), ry = max(size.height * 0.75, 1)
                ctx.translateBy(x: size.width * 0.5, y: size.height * 1.12)
                ctx.scaleBy(x: rx / ry, y: 1)
                let gradient = Gradient(stops: [
                    .init(color: glow.accent, location: 0),
                    .init(color: glow.deep, location: 0.45),
                    .init(color: glow.floor, location: 0.85),
                ])
                // Fill exactly the view's bounds, expressed in the transformed space (x shrinks by rx/ry).
                let k = rx / ry
                let bounds = CGRect(x: -size.width * 0.5 / k, y: -size.height * 1.12,
                                    width: size.width / k, height: size.height)
                ctx.fill(Path(bounds), with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: ry))
            }
        }
    }
}

/// The faint 9 pt dot grid over a hero, strongest in the upper middle and fading out (CSS: 1 px dots at
/// 22 % white, masked by `radial-gradient(120% 70% at 50% 35%)`, layer opacity 35 %).
public struct NoopDotGrid: View {
    public var spacing: CGFloat
    public var strength: Double
    public init(spacing: CGFloat = 9, strength: Double = 1) {
        self.spacing = spacing
        self.strength = strength
    }

    public var body: some View {
        Canvas { ctx, size in
            let cx = size.width * 0.5, cy = size.height * 0.35
            let rx = max(size.width * 1.2, 1), ry = max(size.height * 0.7, 1)
            let base = 0.22 * 0.35 * strength
            // The mask fades continuously, but ten opacity steps are indistinguishable at these alphas.
            // Collecting the dots into one path per step turns ~1,700 fills per hero into ten.
            let steps = 10
            var paths = Array(repeating: Path(), count: steps)
            let r: CGFloat = 1.1
            var y = spacing / 2
            while y < size.height {
                var x = spacing / 2
                while x < size.width {
                    let dx = (x - cx) / rx, dy = (y - cy) / ry
                    let mask = max(0, 1 - (dx * dx + dy * dy).squareRoot() / 0.7)
                    if mask > 0.01 {
                        let step = min(steps - 1, Int(mask * Double(steps)))
                        paths[step].addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    }
                    x += spacing
                }
                y += spacing
            }
            for (step, path) in paths.enumerated() where !path.isEmpty {
                let mask = (Double(step) + 0.5) / Double(steps)
                ctx.fill(path, with: .color(.white.opacity(base * mask)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The glass rim: a 1 pt white ring whose opacity follows the glow — faint at the top, brightest at the
/// lit bottom (inverted for the heart card, which is lit from the top).
public struct NoopGlassRim<S: InsettableShape>: View {
    public var shape: S
    public var glow: NoopGlow
    public init(_ shape: S, glow: NoopGlow) {
        self.shape = shape
        self.glow = glow
    }

    public var body: some View {
        let stops: [Gradient.Stop] = glow == .heart
            ? [.init(color: .white.opacity(0.20), location: 0),
               .init(color: .white.opacity(0.05), location: 0.40),
               .init(color: .white.opacity(0.02), location: 1)]
            : [.init(color: .white.opacity(0.07), location: 0),
               .init(color: .white.opacity(0.025), location: 0.30),
               .init(color: .white.opacity(0.035), location: 0.62),
               .init(color: .white.opacity(0.20), location: 1)]
        shape.strokeBorder(LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom), lineWidth: 1)
            .allowsHitTesting(false)
    }
}

/// The complete hero surface — glow, dot grid and glass rim — for use as a background.
/// `bleed` squares the top corners so a hero can run under the status bar (Sleep, Stress details).
public struct NoopHeroSurface: View {
    public var glow: NoopGlow
    public var cornerRadius: CGFloat
    public var bleed: Bool
    public var showsDotGrid: Bool

    public init(glow: NoopGlow, cornerRadius: CGFloat = NoopVisualStyle.heroRadius,
                bleed: Bool = false, showsDotGrid: Bool = true) {
        self.glow = glow
        self.cornerRadius = cornerRadius
        self.bleed = bleed
        self.showsDotGrid = showsDotGrid
    }

    public var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: bleed ? 0 : cornerRadius,
            bottomLeadingRadius: cornerRadius,
            bottomTrailingRadius: cornerRadius,
            topTrailingRadius: bleed ? 0 : cornerRadius,
            style: .continuous
        )
        ZStack {
            NoopGlowFill(glow)
            if showsDotGrid { NoopDotGrid() }
        }
        .clipShape(shape)
        .overlay(NoopGlassRim(shape, glow: glow))
        .accessibilityHidden(true)
    }
}

/// A v2 hero card: content laid over the glow surface. The content is always rendered in the dark
/// colour scheme — a hero is a lit instrument in both appearances — so the regular text tokens read
/// light-on-dark inside it even when the rest of the app is light.
public struct NoopHeroCard<Content: View>: View {
    public var glow: NoopGlow
    public var padding: CGFloat
    public var cornerRadius: CGFloat
    public var bleed: Bool
    public var minHeight: CGFloat?
    @ViewBuilder public var content: () -> Content

    public init(glow: NoopGlow, padding: CGFloat = NoopVisualStyle.heroPadding,
                cornerRadius: CGFloat = NoopVisualStyle.heroRadius, bleed: Bool = false,
                minHeight: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.glow = glow
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.bleed = bleed
        self.minHeight = minHeight
        self.content = content
    }

    public var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background { NoopHeroSurface(glow: glow, cornerRadius: cornerRadius, bleed: bleed) }
            .environment(\.colorScheme, .dark)
    }
}

/// A small coloured tile with the same glow treatment (design-system swatches, peeking carousel edges,
/// accent tiles).
public struct NoopGlowTile: View {
    public var glow: NoopGlow
    public var cornerRadius: CGFloat
    public init(glow: NoopGlow, cornerRadius: CGFloat = NoopVisualStyle.cardRadius) {
        self.glow = glow
        self.cornerRadius = cornerRadius
    }
    public var body: some View {
        NoopHeroSurface(glow: glow, cornerRadius: cornerRadius, showsDotGrid: false)
    }
}

#if DEBUG
#Preview("Hero glows") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach([NoopGlow.recovery, .moderate, .low, .sleep, .strain, .stress, .heart, .ink], id: \.self) { g in
                NoopHeroCard(glow: g, minHeight: 150) {
                    Text(verbatim: "\(g)").font(StrandFont.book(15)).foregroundStyle(StrandPalette.textPrimary)
                }
            }
        }
        .padding(20)
    }
    .frame(width: 400, height: 700)
    .background(Color.black)
    .preferredColorScheme(.dark)
}

#endif
