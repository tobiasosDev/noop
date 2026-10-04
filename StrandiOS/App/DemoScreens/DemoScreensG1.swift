#if DEBUG
import SwiftUI
import StrandDesign

extension DemoScreensV2 {
    /// Group 1 demo screens for `--demo-screen <name>` (lowercase names).
    static func group1(_ name: String) -> AnyView? {
        switch name {
        case "quickactions": return AnyView(G1QuickActionsHost())
        case "scoringguide": return AnyView(G1SheetHost { ScoringGuideView(
                initialSection: nil,
                scores: ScoringGuideScores(charge: 78, effort: 54, rest: 91,
                                           dayLine: Date().formatted(.dateTime.weekday(.wide).day().month(.wide)
                                               .locale(AppLanguage.activeLocale)),
                                           source: "WHOOP"),
                onClose: {}) })
        case "scoringguide-effort": return AnyView(G1SheetHost { ScoringGuideView(initialSection: .effort, onClose: {}) })
        case "deeptimeline": return AnyView(FullDayChartView())
        case "coupled": return AnyView(CoupledView())
        case "metric-hrv": return G1MetricHost.view("hrv")
        case "metric-rhr": return G1MetricHost.view("rhr")
        case "metric-resp": return G1MetricHost.view("resp_rate")
        case "metric-recovery": return G1MetricHost.view("recovery")
        // The steps entry the demo store fills (the WHOOP 4.0 motion estimate), as Today's tile routes it.
        case "metric-steps": return G1MetricHost.view("steps_est", source: "my-whoop")
        case "metric-steps-empty": return G1MetricHost.view("steps", source: "apple-health")
        case "metric-skintemp": return G1MetricHost.view("skin_temp")
        case "todaycustomize": return AnyView(G1CustomizeHost(destination: .today))
        case "todaycustomize-keymetrics": return AnyView(G1CustomizeHost(destination: .keyMetrics))
        default: return nil
        }
    }
}

/// A metric's detail page by catalog key.
private enum G1MetricHost {
    static func view(_ key: String, source: String? = nil) -> AnyView? {
        guard let metric = MetricCatalog.all.first(where: { $0.key == key && (source == nil || $0.source == source) })
        else { return nil }
        return AnyView(MetricDetailView(metric: metric))
    }
}

/// Today with an arbitrary sheet raised over it (full height, as Today presents its sheets).
private struct G1SheetHost<Sheet: View>: View {
    @ViewBuilder let sheet: () -> Sheet
    @State private var shown = false
    var body: some View {
        LiquidTodayView()
            .onAppear { shown = true }
            .sheet(isPresented: $shown) { NavigationStack { sheet() } }
    }
}

/// Today with the Quick actions sheet raised over it, as the + button presents it.
private struct G1QuickActionsHost: View {
    @State private var shown = true
    var body: some View {
        LiquidTodayView()
            .sheet(isPresented: $shown) {
                QuickActionSheet(onPick: { _ in }, onUpdates: {})
                    .presentationDetents([.height(476)])
                    .presentationDragIndicator(.hidden)
                    .presentationBackground { NoopSheetBackground() }
                    .presentationCornerRadius(NoopVisualStyle.heroRadius)
            }
    }
}

/// Today with the Customize sheet raised over it, deep-linked to one editor.
private struct G1CustomizeHost: View {
    let destination: TodayCustomizationDestination
    @State private var shown: TodayCustomizationDestination?
    @AppStorage(TodayLayoutPrefs.orderKey) private var sectionOrderRaw = ""
    @AppStorage(TodayLayoutPrefs.hiddenKey) private var hiddenSectionsRaw = ""
    @AppStorage(KeyMetricPrefs.layoutKey) private var keyMetricsRaw = ""
    @AppStorage("today.keyMetricsDetailed") private var keyMetricsDetailed = false
    @AppStorage("today.keyMetricsWindowDays") private var keyMetricsWindowDays = 14
    @AppStorage(DashboardCardPrefs.selectionKey) private var dashboardCardsRaw = ""
    @AppStorage(HostedCardPrefs.selectionKey) private var hostedCardsRaw = ""

    var body: some View {
        LiquidTodayView()
            .onAppear { shown = destination }
            .sheet(item: $shown) { d in
                TodayCustomizationSheet(
                    initialDestination: d,
                    sectionOrderRaw: $sectionOrderRaw,
                    hiddenSectionsRaw: $hiddenSectionsRaw,
                    keyMetricsRaw: $keyMetricsRaw,
                    keyMetricsDetailed: $keyMetricsDetailed,
                    keyMetricsWindowDays: $keyMetricsWindowDays,
                    dashboardCardsRaw: $dashboardCardsRaw,
                    hostedCardsRaw: $hostedCardsRaw
                )
            }
    }
}
#endif
