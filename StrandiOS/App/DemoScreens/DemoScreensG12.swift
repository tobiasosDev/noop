#if DEBUG
import SwiftUI
import StrandDesign
import WhoopStore
import StrandAnalytics

extension DemoScreensV2 {
    /// Group 12 demo screens for `--demo-screen <name>` (lowercase names).
    static func group12(_ name: String) -> AnyView? {
        switch name {
        case "marker-editor":
            return AnyView(G12SheetHost { MarkerEditorView { _ in } })
        case "marker-editor-value":
            return AnyView(G12SheetHost { MarkerEditorView(demoMarkerKey: "vitamin_d", value: "38") { _ in } })
        case "marker-editor-ldl":
            return AnyView(G12SheetHost { MarkerEditorView(demoMarkerKey: "ldl", value: "3.1") { _ in } })
        case "marker-editor-bp":
            return AnyView(G12SheetHost {
                MarkerEditorView(demoMarkerKey: "bp_systolic", value: "118", secondValue: "76") { _ in }
            })
        case "marker-editor-custom":
            return AnyView(G12SheetHost { MarkerEditorView(demoCustomName: "Magnesium", unit: "mmol/L") { _ in } })
        case "manual-workout":
            return AnyView(G12SheetHost { ManualWorkoutSheet { _, _ in } })
        case "manual-workout-edit":
            return AnyView(G12SheetHost {
                ManualWorkoutSheet(editing: WorkoutRow(
                    startTs: Int(Date().timeIntervalSince1970) - 5400, endTs: Int(Date().timeIntervalSince1970) - 1500,
                    sport: "Running", source: "manual", durationS: 3900, energyKcal: 612,
                    avgHr: 148, maxHr: 176, strain: 12.4, distanceM: 8400, zonesJSON: nil, notes: nil, steps: nil)) { _, _ in }
            })
        case "sleep-customize":
            return AnyView(G12SheetHost { G12SleepCustomizeHost() })
        case "hosted-trends":
            return AnyView(G12HostedTrendsHost())
        case "cycle-tracker":
            return AnyView(G12SheetHost { G12CycleTrackerHost() })
        default: return nil
        }
    }
}

/// The Sleep Arrange sheet over local bindings, with one card hidden so both lists show.
private struct G12SleepCustomizeHost: View {
    @State private var order = SleepLayoutPrefs.encode(SleepSection.defaultOrder)
    @State private var hidden = SleepLayoutPrefs.encodeHidden([.stagesVsTypical])
    var body: some View {
        SleepCustomizationSheet(sectionOrderRaw: $order, hiddenSectionsRaw: $hidden)
    }
}

/// The three hosted Trends cards over the seeded history, stacked as Today's "Added cards" stacks them.
private struct G12HostedTrendsHost: View {
    @EnvironmentObject var repo: Repository
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                ForEach([HostedCard.trendHRV, .trendRestingHR, .trendEffort], id: \.self) { card in
                    HostedTrendCard(card: card, days: repo.days, effortScale: .hundred)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)
            .padding(.bottom, 120)
        }
        .background(Color.black)
    }
}

/// The cycle tracker with a mid-cycle estimate and three logged starts (seeded into the demo store once).
private struct G12CycleTrackerHost: View {
    @EnvironmentObject var repo: Repository
    @State private var ready = false
    var body: some View {
        let cal = Calendar.current
        let day = { (offset: Int) in Repository.localDayKey(cal.date(byAdding: .day, value: offset, to: Date()) ?? Date()) }
        let result = CyclePhaseEngine.Result(
            phase: .luteal, confidence: .building, cycleDayLow: 18, cycleDayHigh: 20, cycleLengthDays: 29,
            nextPeriodWindow: .init(earliestDay: day(8), latestDay: day(12)), shiftMarkers: [],
            note: "Temperature has stayed raised for several nights.")
        let curve = (0..<40).map { i in 0.3 * sin(Double(i) / 6.0) + (i > 22 ? 0.35 : 0) }
        Group {
            if ready {
                CycleTrackerView(result: result, curve: curve)
            } else {
                Color.black
            }
        }
        .task {
            if await repo.periodStarts().isEmpty {
                for offset in [-19, -48, -77] { await repo.logPeriodStart(day: day(offset)) }
            }
            ready = true
        }
    }
}

/// A sheet presented over a black canvas, as the wearer sees it rise.
private struct G12SheetHost<Sheet: View>: View {
    @ViewBuilder var sheet: () -> Sheet
    @State private var shown = false
    var body: some View {
        Color.black.ignoresSafeArea()
            .sheet(isPresented: $shown) { sheet() }
            .task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                shown = true
            }
    }
}
#endif
