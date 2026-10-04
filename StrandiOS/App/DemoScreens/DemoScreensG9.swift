#if DEBUG
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

extension DemoScreensV2 {
    /// Group 9 demo screens for `--demo-screen <name>` (lowercase names).
    static func group9(_ name: String) -> AnyView? {
        switch name {
        // The Coupled view with its Charge breakdown sheet raised (the plain screen is "coupled", G1).
        case "coupled-breakdown": return AnyView(CoupledView(demoOpensBreakdown: true))
        case "hydration": return AnyView(G9HydrationHost())
        // The in-session screen over a synthetic heart-rate stream, bpm revealed / hidden.
        case "livesession": return AnyView(G9LiveStreamHost { LiveSessionView(onClose: {}, demoRevealBpm: true) })
        case "livesession-hidden": return AnyView(G9LiveStreamHost { LiveSessionView(onClose: {}) })
        case "livesession-summary": return AnyView(G9SummaryHost())
        default: return nil
        }
    }
}

/// DEBUG-only: seeds a plausible hydration week (six earlier days and five drinks today at spread-out
/// times) the first time it runs, then shows the Hydration screen. Writes through the same store calls the
/// quick-add buttons use; only the per-drink timestamps are back-dated so the list reads like a real day.
private struct G9HydrationHost: View {
    @EnvironmentObject private var repo: Repository
    @State private var ready = false

    var body: some View {
        Group {
            if ready { HydrationView() } else { Color.clear }
        }
        .task {
            if repo.hydrationEntries().isEmpty {
                let earlier = [2_300, 2_050, 2_700, 1_600, 2_400, 3_100]
                for (i, ml) in earlier.enumerated() {
                    let day = Repository.localDayKey(Date().addingTimeInterval(-Double(6 - i) * 86_400))
                    _ = await repo.logHydration(amountMl: ml, day: day)
                }
                let today: [(ml: Int, minutesAgo: Double)] = [
                    (HydrationGoal.bottleML, 250), (HydrationGoal.cupML, 160), (HydrationGoal.bottleML, 95),
                    (HydrationGoal.sipML, 40), (HydrationGoal.cupML, 12),
                ]
                for drink in today { _ = await repo.logHydration(amountMl: drink.ml) }
                let dayKey = Repository.localDayKey(Date())
                var entries = repo.hydrationEntries()
                for i in entries.indices where i < today.count {
                    entries[i].loggedAt = Date().addingTimeInterval(-today[i].minutesAgo * 60)
                }
                if let data = try? JSONEncoder().encode(entries) {
                    UserDefaults.standard.set(data, forKey: HydrationStore.entriesKey(forDay: dayKey))
                }
            }
            ready = true
        }
    }
}

/// DEBUG-only: drives `LiveState` with a synthetic, slowly drifting heart rate so the Live Session screen
/// renders a guarded session in the simulator. Nothing here talks to a strap.
private struct G9LiveStreamHost<Content: View>: View {
    @EnvironmentObject private var live: LiveState
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .task {
                var t = 0.0
                while !Task.isCancelled {
                    t += 1
                    if !live.connected { live.connected = true }
                    if !live.bonded { live.bonded = true }
                    let drift: Double = 5 * sin(t / 9) + 2 * sin(t / 2.3)
                    live.heartRate = Int((139 + drift).rounded())
                    live.noteReadableHeartRate()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
    }
}

/// DEBUG-only: the session summary over a synthetic banked row (32 min, mostly in band, three cues).
private struct G9SummaryHost: View {
    var body: some View {
        let end = Int(Date().timeIntervalSince1970) - 600
        let row = LiveSessionRow(startTs: end - 1_935, endTs: end, chargeAtStart: 67,
                                 floorBpm: 118, ceilingBpm: 142,
                                 inBandSec: 1_625, belowSec: 190, aboveSec: 110,
                                 pushCount: 1, easeCount: 2, hrSource: "whoop")
        LiveSessionSummarySheet(row: row, guardedCount: 4, onDone: {})
    }
}
#endif
