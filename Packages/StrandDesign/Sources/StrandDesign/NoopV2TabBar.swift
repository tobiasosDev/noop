import SwiftUI

// MARK: - v2 floating tab bar
//
// The v2 tab bar is a floating black-glass capsule inset 16 pt from the screen edges and 22 pt from the
// bottom: five items, a 22 pt Phosphor icon over a 10 pt label, the active item in full ink and the rest
// at 36 % (icon 45 %). Beneath it a 150 pt fade carries the scrolling content into the ground so cards
// never collide with the bar.

/// One tab-bar item.
public struct NoopTabItem: Identifiable, Hashable {
    public var id: Int
    public var title: LocalizedStringKey
    public var icon: String

    public init(id: Int, title: LocalizedStringKey, icon: String) {
        self.id = id
        self.title = title
        self.icon = icon
    }

    public static func == (a: NoopTabItem, b: NoopTabItem) -> Bool { a.id == b.id && a.icon == b.icon }
    public func hash(into h: inout Hasher) { h.combine(id); h.combine(icon) }
}

/// The floating capsule itself. `onSelect` receives the tapped item's id, including a re-tap of the
/// active item (the shell turns that into pop-to-root / scroll-to-top).
public struct NoopFloatingTabBar: View {
    public var items: [NoopTabItem]
    public var selection: Int
    public var onSelect: (Int) -> Void

    public init(items: [NoopTabItem], selection: Int, onSelect: @escaping (Int) -> Void) {
        self.items = items
        self.selection = selection
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let on = item.id == selection
                Button {
                    if !on { StrandHaptic.selection.play() }
                    onSelect(item.id)
                } label: {
                    VStack(spacing: 4) {
                        PhIcon(item.icon, size: 22)
                            .opacity(on ? 1 : 0.45)
                        Text(item.title)
                            .font(StrandFont.book(10, relativeTo: .caption2))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(on ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 66)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 66)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(Capsule(style: .continuous).fill(Color(light: "#FFFFFFD9", dark: "#121214DB")))
                .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
                .overlay(
                    Capsule(style: .continuous).strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.06), .clear], startPoint: .top, endPoint: .center),
                        lineWidth: 1
                    )
                )
                .shadow(color: .black.opacity(0.6), radius: 20, x: 0, y: 12)
        }
        .environment(\.colorScheme, .dark)
    }
}

/// The fade under the floating bar: transparent → ground at 70 %, 150 pt tall, ignoring touches.
public struct NoopTabBarFade: View {
    public var height: CGFloat
    public init(height: CGFloat = 150) { self.height = height }
    public var body: some View {
        LinearGradient(
            stops: [.init(color: NoopVisualStyle.canvas.opacity(0), location: 0),
                    .init(color: NoopVisualStyle.canvas, location: 0.7)],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Floating tab bar") {
    ZStack(alignment: .bottom) {
        Color.black.ignoresSafeArea()
        NoopTabBarFade()
        NoopFloatingTabBar(
            items: [
                .init(id: 0, title: "Today", icon: "squares-four"),
                .init(id: 1, title: "Trends", icon: "chart-line-up"),
                .init(id: 2, title: "Sleep", icon: "bed"),
                .init(id: 3, title: "Coach", icon: "sparkle"),
                .init(id: 4, title: "More", icon: "dots-three"),
            ],
            selection: 0, onSelect: { _ in }
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 22)
    }
    .frame(width: 390, height: 300)
    .preferredColorScheme(.dark)
}
#endif

// MARK: - Hiding the floating bar

/// Set by a screen that needs the full height (a running workout, a full-screen chart); the iOS shell
/// hides the floating bar while any visible screen reports `true`.
public struct NoopTabBarHiddenKey: PreferenceKey {
    public static let defaultValue = false
    public static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

public extension View {
    /// Hide the v2 floating tab bar while this view is on screen.
    func noopHidesTabBar(_ hidden: Bool = true) -> some View {
        preference(key: NoopTabBarHiddenKey.self, value: hidden)
    }
}
