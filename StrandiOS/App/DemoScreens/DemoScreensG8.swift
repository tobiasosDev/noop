#if DEBUG
import SwiftUI
import StrandDesign

extension DemoScreensV2 {
    /// Group 8 demo screens for `--demo-screen <name>` (lowercase names).
    static func group8(_ name: String) -> AnyView? {
        switch name {
        case "terms": return AnyView(G8ChromeHidden { TermsGateView(onAccept: {}) })
        case "terms3": return AnyView(G8ChromeHidden { TermsGateView(onAccept: {}, debugChecked: 3) })
        case "termsfull": return AnyView(G8ChromeHidden { TermsGateView(onAccept: {}, debugChecked: 0, debugShowPoints: true) })
        case "whatsnew": return AnyView(G8ChromeHidden { WhatsNewView(onClose: {}) })
        case "watchsetup": return AnyView(G8ChromeHidden { AppleWatchSetupView(onClose: {}) })
        case "watchabout": return AnyView(AppleWatchAboutView(onStartSetup: {}))
        case "adddevice": return AnyView(G8ChromeHidden { G8AddDeviceHost(startAt: nil) })
        case "adddevice-prep": return AnyView(G8ChromeHidden { G8AddDeviceHost(startAt: (.whoop4, .prep)) })
        case "adddevice-pick": return AnyView(G8ChromeHidden { G8AddDeviceHost(startAt: (.hrStrap, .pick)) })
        case "adddevice-pickdemo": return AnyView(G8ChromeHidden { AddDevicePickDemo() })
        case "adddevice-confirm": return AnyView(G8ChromeHidden { G8AddDeviceHost(startAt: (.hrStrap, .confirm)) })
        case "adddevice-oura": return AnyView(G8ChromeHidden { G8AddDeviceHost(startAt: (.oura, .prep)) })
        default:
            // The first-run wizard at one step: `ob-welcome` … `ob-done` (see `onboardingSteps`).
            if name.hasPrefix("ob-"), let i = onboardingSteps.firstIndex(of: String(name.dropFirst(3))) {
                return AnyView(G8ChromeHidden { OnboardingWizard(onFinished: {}, debugStartStep: i) })
            }
            return nil
        }
    }

    /// The wizard's steps in order, as demo-screen suffixes.
    private static let onboardingSteps = ["welcome", "what", "expect", "bluetooth", "wear", "scan", "connected",
                                          "profile", "history", "notify", "appearance", "done"]
}

/// The Add-a-device wizard at a given (type, step). A view body is main-actor, so it can hand the injected
/// LiveState to the wizard's `init(live:)`.
private struct G8AddDeviceHost: View {
    @EnvironmentObject var live: LiveState
    let startAt: (type: AddDeviceWizard.DeviceType, step: AddDeviceWizard.Step)?
    var body: some View { AddDeviceWizard(live: live, onClose: {}, startAt: startAt) }
}

/// The first-run screens are shown outside any navigation stack; the harness wraps every demo in one,
/// so hide its (empty) bar to render them the way a new install sees them.
private struct G8ChromeHidden<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().noopHidesSystemNavBar()
    }
}
#endif
