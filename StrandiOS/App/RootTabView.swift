#if os(iOS)
import SwiftUI
import StrandDesign

/// iOS navigation shell. macOS uses a `NavigationSplitView` sidebar (`RootView`); on iPhone the
/// natural analogue is a `TabView` with the most-used screens as tabs and everything else under a
/// "More" list. Every screen is the same `StrandDesign`-built view the macOS app uses.
struct RootTabView: View {
    @EnvironmentObject private var repo: Repository

    private enum Tab: Hashable { case today, trends, live, sleep, more }
    @State private var tabSelection: Tab = .today
    @State private var sheetDestination: HomeDestination?

    var body: some View {
        TabView(selection: $tabSelection) {
            tab(TodayView(), "Today", "circle.hexagongrid.fill").tag(Tab.today)
            tab(TrendsView(), "Trends", "chart.xyaxis.line").tag(Tab.trends)
            tab(LiveView(), "Live", "waveform.path.ecg").tag(Tab.live)
            tab(SleepView(), "Sleep", "bed.double.fill").tag(Tab.sleep)
            moreTab.tag(Tab.more)
        }
        .tint(StrandPalette.accent)
        .preferredColorScheme(.dark)
        .task { await repo.refresh() }
        .environment(\.openScreen) { dest in
            switch dest {
            case .sleep:  tabSelection = .sleep
            case .trends: tabSelection = .trends
            case .insights, .workouts: sheetDestination = dest
            }
        }
        .sheet(item: $sheetDestination) { dest in
            NavigationStack {
                Group {
                    switch dest {
                    case .insights: InsightsView()
                    case .workouts: WorkoutsView()
                    case .sleep:    SleepView()
                    case .trends:   TrendsView()
                    }
                }
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(StrandPalette.surfaceBase, for: .navigationBar)
            }
            .preferredColorScheme(.dark)
        }
    }

    private func tab<V: View>(_ view: V, _ title: LocalizedStringKey, _ icon: String) -> some View {
        view
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .tabItem { Label(title, systemImage: icon) }
    }

    private var moreTab: some View {
        NavigationStack {
            List {
                Section("Insights") {
                    link("Journal", "book.pages.fill") { JournalView() }
                    link("Intelligence", "brain.head.profile") { IntelligenceView() }
                    link("Coach", "sparkles") { CoachView() }
                    link("Insights", "lightbulb.fill") { InsightsView() }
                    link("Explore", "square.grid.2x2.fill") { MetricExplorerView() }
                    link("Compare", "rectangle.split.2x1.fill") { CompareView() }
                    link("Report", "doc.text.below.ecg") { ReportView() }
                    link("Goals", "target") { GoalsView() }
                }
                Section("Body") {
                    link("Workouts", "figure.run") { WorkoutsView() }
                    link("Health", "heart.text.square.fill") { HealthView() }
                    link("Stress", "bolt.heart.fill") { StressView() }
                    link("Breathe", "wind") { BreathingView() }
                    link("Intervals", "timer") { IntervalTimerView() }
                }
                Section("Data") {
                    link("Apple Health", "heart.fill") { AppleHealthView() }
                    link("Data Sources", "externaldrive.fill") { DataSourcesView() }
                }
                Section("App") {
                    link("Automations", "wand.and.stars") { AutomationsView() }
                    link("Settings", "gearshape.fill") { SettingsView() }
                    link("Support", "hands.clap.fill") { SupportView() }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("More")
        }
        .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
    }

    private func link<V: View>(_ title: LocalizedStringKey, _ icon: String, @ViewBuilder _ dest: @escaping () -> V) -> some View {
        NavigationLink {
            dest()
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(StrandPalette.surfaceBase, for: .navigationBar)
        } label: {
            Label(title, systemImage: icon)
        }
        .listRowBackground(StrandPalette.surfaceRaised)
    }
}

#if targetEnvironment(simulator)
/// Screenshot harness. When the app is launched with the `NOOP_SCREEN` environment variable
/// set, `ContentView` renders this host instead of the tab shell / onboarding, so each screen
/// can be captured deterministically on the simulator without UI navigation. Each screen is
/// wrapped exactly as the iOS "More" links present it (NavigationStack + inline title + surface
/// toolbar) so a capture matches the real in-app layout. Gated to the simulator so it is never
/// compiled into a device or release build; only the screenshot tooling ever sets the env var.
struct DebugScreenHost: View {
    let key: String

    /// Returns the host if `NOOP_SCREEN` is set to a non-empty value, else nil.
    static func fromEnvironment() -> DebugScreenHost? {
        guard let v = ProcessInfo.processInfo.environment["NOOP_SCREEN"],
              !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return DebugScreenHost(key: v)
    }

    var body: some View {
        NavigationStack {
            screen
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(StrandPalette.surfaceBase, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var screen: some View {
        switch key.lowercased() {
        case "today": TodayView()
        case "intelligence": IntelligenceView()
        case "coach": CoachView()
        case "live": LiveView()
        case "breathe": BreathingView()
        case "intervals": IntervalTimerView()
        case "explore": MetricExplorerView()
        case "compare": CompareView()
        case "insights": InsightsView()
        case "journal": JournalView()
        case "sleep": SleepView()
        case "trends": TrendsView()
        case "report": ReportView()
        case "goals": GoalsView()
        case "workouts": WorkoutsView()
        case "health": HealthView()
        case "stress": StressView()
        case "applehealth": AppleHealthView()
        case "datasources": DataSourcesView()
        case "automations": AutomationsView()
        case "settings": SettingsView()
        case "support": SupportView()
        default: Text(verbatim: "Unknown NOOP_SCREEN: \(key)")
        }
    }
}
#endif
#endif
