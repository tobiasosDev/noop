import SwiftUI
import StrandDesign

/// Root — the sidebar shell, with the first-run onboarding/pairing wizard overlaid until complete,
/// and a "What's New" changelog sheet shown automatically after an update.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("noop.onboarded") private var onboarded = false
    @AppStorage("noop.lastSeenChangelogVersion") private var lastSeenChangelog = ""
    @AppStorage("noop.acceptedTermsVersion") private var acceptedTerms = ""
    @State private var showWhatsNew = false

    var body: some View {
        #if os(iOS) && targetEnvironment(simulator)
        // Screenshot harness (simulator-only): when launched with NOOP_SCREEN set, render that
        // single screen directly (bypassing the tab shell + onboarding) for deterministic capture.
        if let host = DebugScreenHost.fromEnvironment() {
            return AnyView(host)
        }
        #endif
        return AnyView(mainContent)
    }

    private var mainContent: some View {
        ZStack {
            #if os(macOS)
            RootView()
            #else
            RootTabView()
            #endif
            if !onboarded {
                OnboardingWizard(onFinished: {
                    onboarded = true
                    // A brand-new user just saw the expectations in onboarding — don't also pop the
                    // changelog at them; mark them current.
                    lastSeenChangelog = AppChangelog.currentVersion
                })
                .transition(.opacity)
                .zIndex(1)
            }
            // Terms acknowledgment gate — over EVERYTHING (before onboarding/pairing/Bluetooth) until
            // the current terms version is accepted; re-appears if the terms materially change.
            if acceptedTerms != Terms.currentVersion {
                TermsGateView(onAccept: { acceptedTerms = Terms.currentVersion })
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: onboarded)
        .animation(.easeInOut(duration: 0.35), value: acceptedTerms)
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(onClose: {
                lastSeenChangelog = AppChangelog.currentVersion
                showWhatsNew = false
            })
        }
        // Journal log sheet — opened from the Today morning card or a tapped morning
        // notification. Shared root so it works on both the macOS and iOS shells.
        .sheet(item: $model.journalRoute) { route in
            NavigationStack {
                JournalView(initialDay: route.day)
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
            }
            .preferredColorScheme(.dark)
        }
        .onAppear {
            // Existing users who updated: their last-seen version is behind the current one.
            if onboarded && lastSeenChangelog != AppChangelog.currentVersion {
                showWhatsNew = true
            }
        }
    }
}
