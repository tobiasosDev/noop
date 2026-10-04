import SwiftUI
import StrandDesign

/// #459: "Start Workout" used to live ONLY on the Live screen, so a user reaching Workouts (via the
/// Quick-action FAB or the tab) had no way to begin one from the obvious place. In v2 this is the Workouts
/// screen's "Add workout" row: it offers a live start (sport picker, then the in-exercise view) or a manual
/// log of a past session, and while a workout is recording it re-opens the live view instead.
///
/// PERF (chart-invalidation): this is the ONE place `WorkoutsView` needs live `AppModel` state
/// (`activeWorkout`) — everything else it needs (`hrMax`, `analyzeRecent()`) lives on sub-objects that
/// don't publish at live-tick frequency. `AppModel` publishes `bpm` at ~1 Hz (AppModel.swift:202), and
/// `@EnvironmentObject` subscribes to the WHOLE object's `objectWillChange`, so if `WorkoutsView` itself
/// held `model: AppModel`, every tick would re-evaluate its entire body (chart + grids + sorting) even
/// though only this row's label and its two presentations read `model`. Isolating it here (mirroring
/// `HealthView`'s live-observing-leaf pattern) means a tick re-renders only this small leaf. Owns its own
/// presentation state so nothing about it needs to live on the parent either.
struct WorkoutStartControl: View {
    @EnvironmentObject var model: AppModel
    /// Opens the parent's manual-log sheet (the "log one you forgot" path).
    var onLogManually: (() -> Void)? = nil
    @State private var showLiveWorkout = false
    @State private var showStartSport = false

    var body: some View {
        NoopList {
            if let workout = model.activeWorkout {
                Button { showLiveWorkout = true } label: {
                    row(title: Text("View active workout"),
                        caption: Text(workout.isPaused ? "Paused" : "Recording"),
                        icon: "timer")
                }
                .buttonStyle(LTPressStyle())
                .accessibilityLabel("View the active workout")
            } else {
                Menu {
                    // No active session → pick a named sport first (#519), then the sheet's onStart begins it
                    // and opens the in-exercise view.
                    Button { showStartSport = true } label: {
                        Label("Start a live workout", systemImage: "play")
                    }
                    if let onLogManually {
                        Button(action: onLogManually) {
                            Label("Log a past workout", systemImage: "square.and.pencil")
                        }
                    }
                } label: {
                    row(title: Text("Add workout"), caption: Text("Start live, or log one you forgot"), icon: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(LTPressStyle())
                .menuIndicator(.hidden)
                .accessibilityLabel("Add a workout")
            }
        }
        // #459: the in-exercise view, presented when a live start begins here (same screen LiveView shows).
        // activeWorkout is global on AppModel, so ending it from either surface stays in sync.
        .liveWorkoutCover(isPresented: $showLiveWorkout) {
            LiveWorkoutView(onClose: { showLiveWorkout = false })
                // Inject the shared live snapshot so the in-exercise sensor readout (speed/cadence/power)
                // resolves here too, matching how LiveView presents the same screen.
                .environmentObject(model.live)
        }
        // #519: name the sport before a live session starts, then open the in-exercise view directly
        // (same direct present as the row's already-active path — no cross-view auto-present race).
        .workoutSelectionCover(isPresented: $showStartSport) {
            StartWorkoutSheet { name in
                model.startWorkout(sport: name)
                showLiveWorkout = true
            }
        }
    }

    private func row(title: Text, caption: Text, icon: String) -> some View {
        NoopRow(title: title, caption: caption, icon: icon, chevron: true) { EmptyView() }
    }
}
