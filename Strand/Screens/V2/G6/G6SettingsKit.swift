import SwiftUI
import StrandDesign

// MARK: - Group 6 v2 building blocks (Settings, More, Devices and the app-level screens)
//
// The row and block shapes the Settings pages share (`.li` with a value or a switch, the `.blk` block,
// the hub row with its 38 pt icon tile, the outline chip). Kept out of the screens so the pages read as
// layout, and so every Settings page lines its rows up on the same insets.

/// The hub/More row label: a 38 pt icon tile, a 15 pt title with an optional 12.5 pt caption, an optional
/// trailing hint, and a chevron (or the external-link arrow).
struct G6NavRowLabel: View {
    let title: Text
    var caption: Text? = nil
    var icon: String
    var trailing: Text? = nil
    var chevron: String = "caret-right"

    var body: some View {
        HStack(spacing: 14) {
            G6IconTile(icon: icon)
            VStack(alignment: .leading, spacing: 3) {
                title
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let caption {
                    caption
                        .font(StrandFont.light(12.5, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing {
                trailing
                    .font(StrandFont.light(13, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
            PhIcon(chevron, size: 15)
                .foregroundStyle(StrandPalette.textPrimary)
                .opacity(0.38)
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

/// The 38 pt icon tile of the hub rows: the raised grey square with a hairline edge.
struct G6IconTile: View {
    let icon: String
    var size: CGFloat = 38
    var body: some View {
        PhIcon(icon, size: size * 0.47)
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NoopVisualStyle.raised))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(NoopVisualStyle.border, lineWidth: 1))
    }
}

/// A settings `.li` row: title (+ caption) on the left, a value or control on the right.
struct G6Row<Trailing: View>: View {
    let title: Text
    var caption: Text? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: LocalizedStringKey, caption: Text? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = Text(title)
        self.caption = caption
        self.trailing = trailing
    }
    init(title: Text, caption: Text? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.caption = caption
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                title
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let caption {
                    caption
                        .font(StrandFont.light(12.5, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
    }
}

/// The trailing value of a `G6Row`: 15 pt light secondary ink with an optional small unit, then an
/// optional chevron.
struct G6Value: View {
    let value: String
    var unit: String? = nil
    var chevron: Bool = true

    var body: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: value)
                    .font(StrandFont.light(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textSecondary)
                if let unit {
                    Text(verbatim: unit)
                        .font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .lineLimit(1)
            if chevron {
                PhIcon("caret-right", size: 14)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .opacity(0.35)
            }
        }
    }
}

/// A settings row with a v2 switch.
struct G6ToggleRow: View {
    let title: Text
    var caption: Text? = nil
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, caption: Text? = nil, isOn: Binding<Bool>) {
        self.title = Text(title)
        self.caption = caption
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                title
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let caption {
                    caption
                        .font(StrandFont.light(12.5, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.noop)
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }
}

/// The `.blk` block inside a list: a 15 pt heading with a caption at the right, then content.
struct G6Block<Content: View>: View {
    let title: Text?
    var caption: Text? = nil
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey?, caption: Text? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title.map { Text($0) }
        self.caption = caption
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || caption != nil {
                HStack(alignment: .firstTextBaseline) {
                    title?
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    caption?
                        .font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
            }
            content()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An explanatory line under a list or inside a block: 12 pt light tertiary ink.
struct G6Footnote: View {
    let text: Text
    init(_ key: LocalizedStringKey) { text = Text(key) }
    init(text: Text) { self.text = text }
    init(verbatim s: String) { text = Text(verbatim: s) }
    var body: some View {
        text
            .font(StrandFont.light(12, relativeTo: .caption))
            .foregroundStyle(StrandPalette.textTertiary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The small outline chip (`.adv span`): 26 pt, 11.5 pt label, hairline edge, no fill.
struct G6OutlineChip: View {
    let title: Text
    var body: some View {
        title
            .font(StrandFont.book(11.5, relativeTo: .caption))
            .foregroundStyle(StrandPalette.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
    }
}

/// A hero metric (`.pm .m`): a 19 pt value with a small unit, a 10.5 pt label in 55 % white.
struct G6HeroMetric: View {
    let value: String
    var unit: String? = nil
    let label: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value)
                    .font(StrandFont.value(19))
                    .tracking(-0.38)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let unit {
                    Text(verbatim: unit)
                        .font(StrandFont.book(10))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            // Two lines rather than an ellipsis: a third-width column cannot hold the longer German labels
            // ("Hinweise während der Sitzung").
            label
                .font(StrandFont.light(10.5))
                .foregroundStyle(Color.white.opacity(0.55))
                .lineLimit(2)
                .minimumScaleFactor(0.9)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The search field under a page title: a capsule with a glass icon and a clear button.
struct G6SearchField: View {
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 10) {
            PhIcon("magnifying-glass", size: 17)
                .foregroundStyle(StrandPalette.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(StrandFont.book(15, relativeTo: .body))
                .foregroundStyle(StrandPalette.textPrimary)
                .autocorrectionDisabled()
                .focused(focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    PhIcon("x", size: 14).foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(Capsule(style: .continuous).fill(NoopVisualStyle.surface))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
    }
}

/// A row that discloses an inline editor (a stepper, a wheel) under itself when tapped. The trailing value
/// stays visible; the chevron turns down while the editor is open.
struct G6DisclosureRow<Editor: View>: View {
    let title: Text
    var caption: Text? = nil
    let value: String
    var unit: String? = nil
    @Binding var isOpen: Bool
    @ViewBuilder var editor: () -> Editor

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(StrandMotion.interactive) { isOpen.toggle() }
            } label: {
                G6Row(title: title, caption: caption) {
                    HStack(spacing: 10) {
                        G6Value(value: value, unit: unit, chevron: false)
                        PhIcon("caret-right", size: 14)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .opacity(0.35)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(verbatim: [value, unit].compactMap { $0 }.joined(separator: " ")))
            .accessibilityHint(isOpen ? Text("Double tap to close the editor") : Text("Double tap to edit"))
            if isOpen {
                HStack {
                    Spacer(minLength: 0)
                    editor()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
    }
}

/// Wraps its children onto as many lines as they need, left to right (the Advanced chips).
struct G6FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// A settings row whose value opens a menu of choices (the whole row is the tap target).
struct G6MenuRow<Selection: Hashable, Options: View>: View {
    let title: Text
    var caption: Text? = nil
    @Binding var selection: Selection
    let valueText: String
    @ViewBuilder var options: () -> Options

    var body: some View {
        Menu {
            Picker(selection: $selection) { options() } label: { title }
        } label: {
            G6Row(title: title, caption: caption) {
                G6Value(value: valueText)
            }
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: valueText))
    }
}

/// The value-and-caret menu for a row that already draws its own title (the Units card's `FormRow`s):
/// the v2 value type in place of the system picker's label, which renders in the system font.
struct G6MenuValue<Selection: Hashable, Options: View>: View {
    let title: Text
    @Binding var selection: Selection
    let valueText: String
    @ViewBuilder var options: () -> Options

    var body: some View {
        Menu {
            Picker(selection: $selection) { options() } label: { title }
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: valueText)
                    .font(StrandFont.light(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                PhIcon("caret-up-down", size: 13)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .opacity(0.4)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .fixedSize()
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel(title)
        .accessibilityValue(Text(verbatim: valueText))
    }
}
