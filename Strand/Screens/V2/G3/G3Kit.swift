import SwiftUI
import StrandDesign

// Small v2 pieces shared by the Coach and Insights screens that the StrandDesign kit does not carry:
// a wrapping chip row, the radio mark of a single-choice list, the input-field chrome and the
// hairline action capsule under a Coach reply.

/// Lays its children out left to right and wraps onto a new line when the width runs out (the kit's
/// `.chips` row: suggested prompts, signal pickers).
struct G3FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// The radio mark of a single-choice v2 list (`.rad` / `.rad.on`): a hollow 22 pt ring, or an ink disc
/// carrying a black check when selected.
struct G3RadioMark: View {
    let isOn: Bool
    var body: some View {
        ZStack {
            if isOn {
                Circle().fill(StrandPalette.textPrimary)
                CheckGlyph()
                    .stroke(NoopVisualStyle.canvas, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 11, height: 11)
            } else {
                Circle().strokeBorder(NoopVisualStyle.quaternaryText, lineWidth: 1.5)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// A bold check mark drawn as a stroke (the Phosphor set ships only light and fill weights).
private struct CheckGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.52))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.82))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.94, y: rect.minY + rect.height * 0.2))
        }
    }
}

/// The v2 input chrome (`.fld`): a 54 pt field on the list surface with a highlight hairline.
struct G3FieldChrome: ViewModifier {
    var minHeight: CGFloat = 54
    var radius: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .frame(minHeight: minHeight)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(NoopVisualStyle.surface))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
    }
}

extension View {
    /// Wrap a text field (plus its leading/trailing icons) in the v2 input chrome.
    func g3FieldChrome(minHeight: CGFloat = 54, radius: CGFloat = 18) -> some View {
        modifier(G3FieldChrome(minHeight: minHeight, radius: radius))
    }
}

/// The hairline action capsule under a Coach reply (`.acts span`): a 14 pt icon and a 12 pt label,
/// no fill.
struct G3ActionCapsule: View {
    let title: LocalizedStringKey
    let icon: String
    var body: some View {
        HStack(spacing: 6) {
            PhIcon(icon, size: 14).opacity(0.85)
            Text(title).font(StrandFont.book(12, relativeTo: .caption)).lineLimit(1)
        }
        .foregroundStyle(StrandPalette.textSecondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
        .contentShape(Capsule(style: .continuous))
    }
}

/// The plain-text pieces of a `.li` row used as a toggle/menu label: optional icon tile, a 15 pt Book
/// title and a 12 pt caption.
struct G3RowLabel: View {
    let title: Text
    var caption: Text? = nil
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 14) {
            if let icon { NoopIconTile(icon) }
            VStack(alignment: .leading, spacing: 2) {
                title.font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let caption {
                    caption.font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A `.li` row whose trailing control is the v2 switch.
struct G3ToggleRow: View {
    let title: Text
    var caption: Text? = nil
    var icon: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            G3RowLabel(title: title, caption: caption, icon: icon)
        }
        .toggleStyle(.noop)
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .frame(minHeight: 52)
    }
}

/// A suggested-prompt chip (`.chips .chip`): a 34 pt capsule with a 13 pt label and an optional icon.
struct G3PromptChip: View {
    let text: String
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 7) {
            if let icon { PhIcon(icon, size: 14) }
            Text(verbatim: text).font(StrandFont.book(13, relativeTo: .footnote)).lineLimit(1)
        }
        .foregroundStyle(StrandPalette.textSecondary)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
        .contentShape(Capsule(style: .continuous))
    }
}

/// The v2 card fill for a non-rectangular card (the Coach reply's speech-bubble corners): the kit's
/// grey-black ramp with a hairline edge.
struct G3CardSurface<S: InsettableShape>: View {
    let shape: S
    var body: some View {
        shape
            .fill(LinearGradient(colors: [NoopVisualStyle.surfaceTop, NoopVisualStyle.surfaceBottom],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(NoopVisualStyle.border, lineWidth: 1))
    }
}

extension String {
    /// The string with "↔" pinned to its text presentation. Without the variation selector iOS draws
    /// U+2194 from the emoji font, as a blue key-cap, inside a line of Hanken Grotesk.
    var g3TextArrows: String { replacingOccurrences(of: "↔", with: "↔\u{FE0E}") }
}
