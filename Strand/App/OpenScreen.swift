import SwiftUI

// OpenScreen.swift — cross-platform "take me to screen X" hook for Home elements
// (ring taps, activity rows). TodayView is shared by the macOS sidebar shell and the
// iOS tab shell, which navigate differently — so Home publishes intent through this
// environment closure and each shell supplies its own handler. Default is a no-op
// (previews, screenshot harness).

enum HomeDestination: String, Identifiable {
    case sleep, insights, workouts, trends
    var id: String { rawValue }
}

private struct OpenScreenKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (HomeDestination) -> Void = { _ in }
}

extension EnvironmentValues {
    var openScreen: @MainActor @Sendable (HomeDestination) -> Void {
        get { self[OpenScreenKey.self] }
        set { self[OpenScreenKey.self] = newValue }
    }
}
