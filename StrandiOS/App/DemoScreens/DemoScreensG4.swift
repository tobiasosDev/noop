#if DEBUG
import SwiftUI
import StrandDesign
import WhoopStore

extension DemoScreensV2 {
    /// Group 4 demo screens for `--demo-screen <name>` (lowercase names).
    static func group4(_ name: String) -> AnyView? {
        switch name {
        // Live with a synthetic strap stream (the seeded demo has no live link), so the connected state
        // of the hero, physiology and strap cards can be captured.
        case "livestream": return AnyView(LiveStreamDemoHost(workout: false) { LiveView() })
        // The same, with a manual workout running (the Session section's active state).
        case "liveactive": return AnyView(LiveStreamDemoHost(workout: true) { LiveView() })
        // The in-exercise screen over the synthetic stream.
        case "liveworkout":
            return AnyView(LiveStreamDemoHost(workout: true) { LiveWorkoutView(onClose: {}) })
        case "sportpicker": return AnyView(StartWorkoutSheet { _ in })
        case "hrvreading":
            return AnyView(LiveStreamDemoHost(workout: false) { HRVSnapshotView(source: .chestStrap) })
        case "hrvcapture":
            return AnyView(LiveStreamDemoHost(workout: false) {
                HRVSnapshotView(source: .chestStrap, demoAutoStart: true)
            })
        case "workoutdetail": return AnyView(WorkoutDetailDemoHost(preferRun: true))
        case "workoutdetailnewest": return AnyView(WorkoutDetailDemoHost(preferRun: false))
        case "liftlog": return AnyView(LiftLogView())
        default: return nil
        }
    }
}

/// DEBUG-only: the detail of the newest seeded run (or the newest session when there is none).
private struct WorkoutDetailDemoHost: View {
    let preferRun: Bool
    @EnvironmentObject private var repo: Repository
    @State private var row: WorkoutRow?

    var body: some View {
        Group {
            if let row { WorkoutDetailView(row: row, demoSyntheticHR: true) } else { Color.clear }
        }
        .task {
            let rows = await repo.workoutRows(days: 120)
            row = (preferRun ? rows.first { $0.sport.localizedCaseInsensitiveContains("run") } : nil) ?? rows.first
        }
    }
}

/// DEBUG-only: drives `LiveState` with a synthetic, slowly drifting heart rate and R-R stream so the Live
/// screens render their streaming state in the simulator. Nothing here talks to a strap. `workout` starts
/// a manual Strength session (no GPS prompt) or discards a leftover one, so every capture is deterministic
/// even though an active workout is persisted across launches.
private struct LiveStreamDemoHost<Content: View>: View {
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var model: AppModel
    let workout: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .task {
                live.connected = true
                live.bonded = true
                live.encryptedBond = true
                live.setBattery(82)
                live.lastSyncedAt = Date().timeIntervalSince1970 - 240
                var t = 0.0
                tick(&t)
                if workout {
                    if model.activeWorkout == nil { model.startWorkout(sport: "Strength") }
                } else if model.activeWorkout != nil {
                    model.discardWorkout()
                }
                while !Task.isCancelled {
                    tick(&t)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
    }

    private func tick(_ t: inout Double) {
        t += 1
        // The simulator's BLE manager has no peripheral and may drop the flags; hold the demo link up.
        if !live.connected { live.connected = true }
        if !live.bonded { live.bonded = true }
        if !live.encryptedBond { live.encryptedBond = true }
        let hr = Int((122 + 6 * sin(t / 9) + 2 * sin(t / 2.3)).rounded())
        let rr = Int((60_000.0 / Double(hr)).rounded()) + Int(18 * sin(t * 1.7))
        live.heartRate = hr
        live.noteReadableHeartRate()
        // Several intervals per tick so the R-R strip is full even right after the simulator's BLE
        // manager clears the live buffers.
        live.setRRIntervals((0..<10).map { rr + Int(14 * sin(t * 2.1 + Double($0))) })
        live.lastFrameType = "RT"
        live.noteFrameRouted()
        live.lastEvent = "WRIST_ON"
        if Int(t) % 4 == 0 {
            live.append(log: AppModel.stamped("RT hr=\(hr) rr=[\(rr)] crc ok"))
        }
    }
}
#endif
