import SwiftUI
import StrandDesign

// MARK: - Live & training v2 helpers
//
// Small pieces the Live, workout and lift screens share that the StrandDesign kit does not carry as-is:
// a pill button that takes a Phosphor icon and a custom height (the kit's `NoopButton` takes SF Symbols
// at a fixed 52 pt), the 96 pt action tile of the Live "Session" grid, and the 30 pt inline action of a
// card header (Copy / Save…).

/// The on-screen name of a stored sport label. The stored name is data: it round-trips through exports
/// and cross-source dedup, so it is never translated. Screens show its `sport.<name>` catalogue entry
/// instead, and fall back to the readable stored text (camelCase split, "detected" as "Activity") for a
/// free-text or imported name the catalogue does not carry.
enum SportName {
    static func display(_ stored: String) -> String {
        for key in [stored, WorkoutSource.editableSport(stored)] {
            let value = Bundle.main.localizedString(forKey: "sport." + key, value: missing, table: "Localizable")
            if value != missing { return value }
        }
        return WorkoutSource.displaySport(stored)
    }

    /// A value no catalogue entry can hold, so a miss is told apart from a hit.
    private static let missing = "\u{1}"
}

/// A v2 pill button with an optional Phosphor icon. `.primary` is the ink pill with black text,
/// `.ghost` the raised grey pill with a hairline (`.btn` / `.btn.ghost`).
struct LTActionButton: View {
    enum Kind { case primary, ghost }

    private let title: Text
    var icon: String?
    var kind: Kind
    var height: CGFloat
    var fontSize: CGFloat
    var fullWidth: Bool
    let action: () -> Void

    init(_ title: LocalizedStringKey, icon: String? = nil, kind: Kind = .ghost, height: CGFloat = 52,
         fontSize: CGFloat = 15, fullWidth: Bool = true, action: @escaping () -> Void) {
        self.title = Text(title)
        self.icon = icon
        self.kind = kind
        self.height = height
        self.fontSize = fontSize
        self.fullWidth = fullWidth
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { PhIcon(icon, size: 18) }
                title.lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .buttonStyle(LTPillStyle(kind: kind, height: height, fontSize: fontSize, fullWidth: fullWidth))
    }
}

/// The chrome of `LTActionButton`, usable on any `Button` (a `Menu` label, a `NavigationLink`).
struct LTPillStyle: ButtonStyle {
    var kind: LTActionButton.Kind = .ghost
    var height: CGFloat = 52
    var fontSize: CGFloat = 15
    var fullWidth: Bool = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let primary = kind == .primary
        configuration.label
            .font(StrandFont.medium(fontSize, relativeTo: .body))
            .foregroundStyle(primary ? StrandPalette.goldDeepText : StrandPalette.textPrimary)
            .padding(.horizontal, 18)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .background(Capsule(style: .continuous).fill(primary ? StrandPalette.gold : NoopVisualStyle.inset))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(primary ? Color.clear : NoopVisualStyle.borderHighlight, lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.38)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(StrandMotion.interactive, value: configuration.isPressed)
    }
}

/// The 96 pt action tile of a 2 × 2 grid (`.ct2`): an icon at the top, a 15 pt title and an 11 pt
/// caption at the bottom. `primary` is the ink tile with black text; a disabled tile fades to 38 %.
struct LTActionTile: View {
    private let title: Text
    private let caption: Text
    var icon: String
    var primary: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: LocalizedStringKey, caption: LocalizedStringKey, icon: String, primary: Bool = false,
         action: @escaping () -> Void) {
        self.title = Text(title)
        self.caption = Text(caption)
        self.icon = icon
        self.primary = primary
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                PhIcon(icon, size: 20)
                Spacer(minLength: 8)
                title.font(StrandFont.book(15, relativeTo: .body)).lineLimit(1).minimumScaleFactor(0.8)
                caption.font(StrandFont.footnote)
                    .foregroundStyle(primary ? StrandPalette.goldDeepText.opacity(0.5) : StrandPalette.textTertiary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.top, 2)
            }
            .foregroundStyle(primary ? StrandPalette.goldDeepText : StrandPalette.textPrimary)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: NoopVisualStyle.listRadius, style: .continuous)
                .fill(primary ? StrandPalette.gold : NoopVisualStyle.surface))
            .overlay(RoundedRectangle(cornerRadius: NoopVisualStyle.listRadius, style: .continuous)
                .strokeBorder(primary ? Color.clear : NoopVisualStyle.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: NoopVisualStyle.listRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.38)
        }
        .buttonStyle(LTPressStyle())
    }
}

/// The 30 pt inline action of a card header (`.sbtn`): a 14 pt icon and a 12 pt label.
struct LTSmallButton: View {
    private let title: Text
    var icon: String?
    let action: () -> Void

    init(_ title: LocalizedStringKey, icon: String? = nil, action: @escaping () -> Void) {
        self.title = Text(title)
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { PhIcon(icon, size: 14) }
                title.font(StrandFont.book(12, relativeTo: .caption)).lineLimit(1)
            }
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
            .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
            .fixedSize()
        }
        .buttonStyle(LTPressStyle())
    }
}

/// A press response for custom-chrome buttons: a slight dim and scale, no colour change.
struct LTPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(StrandMotion.interactive, value: configuration.isPressed)
    }
}

/// A 1 pt hairline divider in the v2 border ink.
struct LTHairline: View {
    var body: some View {
        Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
    }
}

extension View {
    /// The v2 neutral card (`.card`) with the user's card-transparency preference applied to the surface.
    func ltCard(padding: CGFloat = NoopVisualStyle.cardPadding, opacity: Double = 1) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .noopPanel(surfaceOpacity: opacity)
    }
}

/// A hero trace on a glow: a white 1.2 pt line over a soft white fill and a faint floor rule, with an
/// optional dashed cursor and white dot at the newest point, and an optional dashed reference level (an
/// average). `points` are in unit space (x 0…1 left to right, y 0…1 bottom to top), so the caller decides
/// the time axis and the value range.
struct LTHeroTrace: View {
    let points: [CGPoint]
    var showsCursor: Bool = true
    /// Draw the white dot at the newest point even without the cursor rule.
    var showsEndDot: Bool = false
    var showsFloor: Bool = true
    /// A dashed horizontal reference at this unit-space height.
    var reference: CGFloat? = nil

    var body: some View {
        Canvas { ctx, size in
            let floorY = size.height - 2
            if showsFloor {
                ctx.fill(Path(CGRect(x: 0, y: floorY, width: size.width, height: 1)),
                         with: .color(.white.opacity(0.12)))
            }
            if let reference {
                var ref = Path()
                let y = floorY * (1 - reference)
                ref.move(to: CGPoint(x: 0, y: y))
                ref.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(ref, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
            let pts = points.map { CGPoint(x: size.width * $0.x, y: floorY * (1 - $0.y)) }
            guard let first = pts.first, let last = pts.last else { return }
            if pts.count > 1 {
                var fill = Path()
                fill.move(to: CGPoint(x: first.x, y: floorY))
                pts.forEach { fill.addLine(to: $0) }
                fill.addLine(to: CGPoint(x: last.x, y: floorY))
                fill.closeSubpath()
                ctx.fill(fill, with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.26), .white.opacity(0)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: floorY)))
                var line = Path()
                line.addLines(pts)
                ctx.stroke(line, with: .color(.white),
                           style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
            if showsCursor {
                var cursor = Path()
                cursor.move(to: last)
                cursor.addLine(to: CGPoint(x: last.x, y: floorY))
                ctx.stroke(cursor, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            if showsCursor || showsEndDot {
                ctx.fill(Path(ellipseIn: CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7)),
                         with: .color(.white))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A step chip of a short flow (`Ready — Capturing — Reading complete`): done steps carry a check,
/// the current one is the ink chip, later ones are dim.
struct LTStepChip: View {
    enum State { case done, current, upcoming }
    private let title: Text
    let state: State
    /// A done step shows only its check, for a row that would not fit its full labels.
    var compact = false

    init(_ title: LocalizedStringKey, state: State, compact: Bool = false) {
        self.title = Text(title)
        self.state = state
        self.compact = compact
    }

    var body: some View {
        HStack(spacing: 6) {
            if state == .done { PhIcon("check", size: 14) }
            if !(compact && state == .done) {
                title.font(StrandFont.book(12, relativeTo: .caption)).lineLimit(1)
            }
        }
        .foregroundStyle(state == .current ? StrandPalette.goldDeepText
                         : state == .done ? StrandPalette.textSecondary : StrandPalette.textTertiary)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Capsule(style: .continuous).fill(state == .current ? StrandPalette.gold : NoopVisualStyle.inset))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(state == .current ? Color.clear : NoopVisualStyle.border, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(state == .current ? .isSelected : [])
    }
}
