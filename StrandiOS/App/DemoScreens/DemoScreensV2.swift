#if DEBUG
import SwiftUI
import StrandDesign

/// DEBUG-only extension of the `--demo-screen <name>` harness for the v2 redesign. Each screen group owns
/// one `groupN` lookup in its own file (`DemoScreensG1.swift` …), so the groups never edit the same switch.
/// Names are lowercase. Stripped from Release.
enum DemoScreensV2 {
    static func lookup(_ name: String) -> AnyView? {
        // A plain loop: a long `??` chain of optional AnyViews exceeds the type checker's time budget.
        let groups: [(String) -> AnyView?] = [group1, group2, group3, group4, group5, group6,
                                              group7, group8, group9, group10, group11,
                                              group12, group13, group14]
        for group in groups {
            if let view = group(name) { return view }
        }
        return nil
    }

    /// `--demo-tab <0…4>`: the floating tab bar over a demo screen, with that item active.
    @ViewBuilder static var tabBarOverlay: some View {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--demo-tab"), i + 1 < args.count, let tab = Int(args[i + 1]) {
            ZStack(alignment: .bottom) {
                NoopTabBarFade()
                NoopFloatingTabBar(
                    items: [
                        NoopTabItem(id: 0, title: "Today", icon: "squares-four"),
                        NoopTabItem(id: 1, title: "Trends", icon: "chart-line-up"),
                        NoopTabItem(id: 2, title: "Sleep", icon: "bed"),
                        NoopTabItem(id: 3, title: "Coach", icon: "sparkle"),
                        NoopTabItem(id: 4, title: "More", icon: "dots-three"),
                    ],
                    selection: tab, onSelect: { _ in }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 22)
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    /// `--demo-anchor top|center|bottom|<0…1>`: where a demo screen's scroll view starts, so a screen taller
    /// than the simulator can be captured in three shots. nil when the argument is absent.
    static var scrollAnchor: UnitPoint? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo-anchor"), i + 1 < args.count else { return nil }
        // A fraction (0.33) reaches the bands between top, center and bottom on very tall screens.
        if let f = Double(args[i + 1]) { return UnitPoint(x: 0.5, y: max(0, min(1, f))) }
        switch args[i + 1].lowercased() {
        case "center", "middle": return .center
        case "bottom": return .bottom
        default: return .top
        }
    }
}
#endif
