#if DEBUG
import SwiftUI
import StrandDesign

extension DemoScreensV2 {
    /// Group 5 demo screens for `--demo-screen <name>` (lowercase names).
    static func group5(_ name: String) -> AnyView? {
        switch name {
        case "labbook":        return AnyView(LabBookDemoHost())
        case "labbook-marker": return AnyView(LabBookDemoHost(showsMarker: true))
        case "breathe":        return AnyView(BreathingView())
        case "rhythm":         return AnyView(RhythmDemoHost())
        case "rhythm-consent": return AnyView(RhythmDemoHost(showsConsent: true))
        default: return nil
        }
    }
}
#endif
