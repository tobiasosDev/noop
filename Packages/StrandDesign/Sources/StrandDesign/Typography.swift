import SwiftUI

// MARK: - Strand Typography (v2)
//
// Two bundled faces (see `NoopFonts`):
// - Hanken Grotesk — every word in the app. Light (300) for headlines and body, Book (400) for titles
//   and values, Medium (500) for buttons. Weights requested through the old `Font.Weight` API are
//   shifted one step lighter (regular → 300, medium/semibold → 400, bold → 500), which is what turns the
//   existing call sites into the v2 voice without touching each of them.
// - Doto — the dot-matrix face, for hero numbers (score, %, strain, stress level) and the inline status
//   tags. Always weight 600–700 with fully round dots.
//
// Named text styles scale with Dynamic Type (`relativeTo:`). Numeric styles request tabular figures so
// live values never reflow. SF Mono stays reserved for logs.

public enum StrandFont {

    // MARK: Weight mapping

    /// The v2 Hanken weight for a legacy `Font.Weight`: one step lighter than the name says.
    static func sansWeight(_ weight: Font.Weight) -> CGFloat {
        switch weight {
        case .ultraLight, .thin: return 200
        case .light, .regular:   return 300
        case .medium, .semibold: return 400
        case .bold, .heavy:      return 500
        case .black:             return 600
        default:                 return 300
        }
    }

    private static func sans(_ size: CGFloat, _ weight: CGFloat, relativeTo style: Font.TextStyle? = nil,
                             tabular: Bool = false) -> Font {
        NoopFonts.font(.sans, size: size, weight: weight, relativeTo: style, tabular: tabular)
    }

    // MARK: v2 faces — reach for these in new layouts

    /// Hanken Grotesk Light (300): headlines, body copy, captions.
    public static func light(_ size: CGFloat, relativeTo style: Font.TextStyle? = nil) -> Font {
        sans(size, 300, relativeTo: style)
    }

    /// Hanken Grotesk Book (400): card titles, list-row titles, metric values.
    public static func book(_ size: CGFloat, relativeTo style: Font.TextStyle? = nil) -> Font {
        sans(size, 400, relativeTo: style)
    }

    /// Hanken Grotesk Medium (500): buttons and the few emphasised labels.
    public static func medium(_ size: CGFloat, relativeTo style: Font.TextStyle? = nil) -> Font {
        sans(size, 500, relativeTo: style)
    }

    /// Hanken Grotesk at an explicit v2 weight (300/400/500) with tabular figures — live numbers.
    public static func value(_ size: CGFloat, weight: CGFloat = 400, relativeTo style: Font.TextStyle? = nil) -> Font {
        sans(size, weight, relativeTo: style, tabular: true)
    }

    /// Doto, the dot-matrix face, with round dots: hero numbers (44–112 pt) at weight 600.
    public static func dot(_ size: CGFloat, weight: CGFloat = 600) -> Font {
        NoopFonts.font(.dot, size: size, weight: weight)
    }

    /// The dot-matrix letter spacing (+0.04 em) that the hero numbers carry.
    public static func dotTracking(_ size: CGFloat) -> CGFloat { size * 0.04 }

    // MARK: Scale (legacy names, v2 values)

    /// Display — the hero score number, now set in the dot-matrix face. Pair with `displayTracking`.
    public static func display(_ size: CGFloat = 72) -> Font {
        dot(size)
    }

    /// Tracking for `display(_:)` — the dot face reads best slightly open (+0.04 em).
    public static func displayTracking(_ size: CGFloat = 72) -> CGFloat {
        dotTracking(size)
    }

    /// A numeric style at an arbitrary size/weight — Hanken, tabular, one weight step lighter.
    public static func rounded(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        sans(size, sansWeight(weight), tabular: true)
    }

    /// Large title for tab roots ("Trends", "More") — 34 / Light.
    public static var largeTitle: Font { sans(34, 300, relativeTo: .largeTitle) }

    /// Title1 — 28 / Light (the v2 `h1`). Scales with Dynamic Type.
    public static var title1: Font { sans(28, 300, relativeTo: .title) }

    /// Title2 — 21 / Book (the v2 section title). Scales with Dynamic Type.
    public static var title2: Font { sans(21, 400, relativeTo: .title2) }

    /// Headline — 17 / Book (the v2 nav title). Scales with Dynamic Type.
    public static var headline: Font { sans(17, 400, relativeTo: .headline) }

    /// Body — 15 / Light. Scales with Dynamic Type.
    public static var body: Font { sans(15, 300, relativeTo: .body) }

    /// Subhead — 13.5 / Light (insight sentences, card copy). Scales with Dynamic Type.
    public static var subhead: Font { sans(13.5, 300, relativeTo: .subheadline) }

    /// Caption — 12 / Light. Scales with Dynamic Type.
    public static var caption: Font { sans(12, 300, relativeTo: .caption) }

    /// Footnote — 11 / Light (the v2 `cap`). Scales with Dynamic Type.
    public static var footnote: Font { sans(11, 300, relativeTo: .footnote) }

    /// Overline — 11 / Book, worn uppercase with +0.12 em tracking (`strandOverline()` does both).
    ///
    /// Also the face for compact status copy in constrained chrome (the Today header's sync capsule),
    /// used there WITHOUT the tracking — that is sentence case, not an overline, and the letter-spacing
    /// is what makes an overline read as one.
    public static var overline: Font { sans(11, 400, relativeTo: .caption2) }

    /// `overline` at a custom point size — same face, weight and Dynamic-Type scaling (relative to
    /// `.caption2`). Lets a caller shrink an ALL-CAPS label to fit a small container.
    public static func overlineScaled(_ size: CGFloat) -> Font {
        sans(size, 400, relativeTo: .caption2)
    }

    /// Mono 13 (SF Mono) — raw / log views. Tabular by nature.
    public static let mono = Font.system(size: 13, weight: .regular, design: .monospaced)

    // MARK: Numeric variants (tabular digits)

    /// A numeric style at an arbitrary size/weight for live values — Hanken, tabular figures.
    public static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        sans(size, sansWeight(weight), tabular: true)
    }

    /// Body number — inline live values beside `body` labels. Scales with Dynamic Type.
    public static var bodyNumber: Font { sans(15, 400, relativeTo: .body, tabular: true) }

    /// Caption number — small live values (sparklines, chips). Scales with Dynamic Type.
    public static var captionNumber: Font { sans(12, 400, relativeTo: .caption, tabular: true) }

    /// Mono at an arbitrary size.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// The tracking for overline text (wide ALL-CAPS labels, ≈ 0.12 em at 11 pt).
    public static let overlineTracking: CGFloat = 1.3
}

// MARK: - Text helpers

public extension Text {
    /// Style as an overline label: ALL-CAPS, Book 11, +0.12 em tracking, tertiary ink (the v2 `.over`).
    func strandOverline() -> some View {
        self.font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .textCase(.uppercase)
            .foregroundStyle(StrandPalette.textTertiary)
    }
}

public extension View {
    /// Convenience: an overline-styled label string.
    static func strandOverline(_ string: String) -> some View {
        Text(string).strandOverline()
    }
}

#if DEBUG
#Preview("Typography") {
    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("78").font(StrandFont.dot(104)).tracking(StrandFont.dotTracking(104))
                Text("%").font(StrandFont.dot(44))
            }
            .foregroundStyle(StrandPalette.textPrimary)
            Text("Recovered and ready.").font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
            Text("Health parameters").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text("Sleep").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text("Body / Light 15 — the thread of you, read in full.")
                .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
            Text("Subhead 13.5").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Text("Caption 12").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Text("Footnote 11").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Text("Overline").strandOverline()
            Text("0xAA 41 00 1c crc32=f3a1  mono 13").font(StrandFont.mono).foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 520, height: 680)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
