#if DEBUG
import SwiftUI
import StrandDesign

extension DemoScreensV2 {
    /// Group 3 demo screens for `--demo-screen <name>` (lowercase names).
    static func group3(_ name: String) -> AnyView? {
        switch name {
        case "coach", "coachconnect": return AnyView(CoachDemoHost(mode: .connect))
        case "coachchat": return AnyView(CoachDemoHost(mode: .chat))
        case "coachthinking": return AnyView(CoachDemoHost(mode: .thinking))
        case "coachsettings": return AnyView(CoachDemoHost(mode: .settings))
        case "coachquickask": return AnyView(CoachDemoHost(mode: .quickAsk))
        case "insightshub", "whatmovesyou": return AnyView(InsightsHubView())
        case "intelligence": return AnyView(IntelligenceDemoHost())
        case "insightslog": return AnyView(ScreenScaffold(title: nil) { MindSection(); CaffeineLogCard() })
        default: return nil
        }
    }
}

/// DEBUG-only: the seeded demo history carries daily scores but no raw strap streams, so the engine has
/// nothing to score. This host folds the seeded days into the engine's published results (display only,
/// nothing is persisted) so the forecast and the scores table can be captured.
private struct IntelligenceDemoHost: View {
    @EnvironmentObject private var intelligence: IntelligenceEngine
    @EnvironmentObject private var repo: Repository
    var body: some View {
        IntelligenceView()
            .task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                intelligence.note = nil
                intelligence.results = repo.days.suffix(30).reversed().map { d in
                    IntelligenceEngine.Computed(day: d.day, recovery: d.recovery, strain: d.strain,
                                                sleepMin: d.totalSleepMin, hrv: d.avgHrv, rhr: d.restingHr)
                }
            }
    }
}

/// DEBUG-only: puts the shared `AICoachEngine` into a known state before showing a Coach screen, so the
/// connect screen, a conversation, the settings sheet and the quick-ask sheet can each be captured
/// without a provider key. It only assigns the engine's published state (no request is ever made):
/// the conversation is "connected" through the keyless Custom provider flag, which `isConfigured`
/// reads, and the messages are assigned directly.
private struct CoachDemoHost: View {
    enum Mode { case connect, chat, thinking, settings, quickAsk }
    let mode: Mode
    @EnvironmentObject private var coach: AICoachEngine
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var router: NavRouter
    @State private var ready = false

    var body: some View {
        Group {
            if ready {
                switch mode {
                case .connect, .chat, .thinking:
                    CoachView()
                case .settings:
                    CoachSettingsView()
                case .quickAsk:
                    StrandPalette.surfaceBase.ignoresSafeArea()
                        .sheet(isPresented: .constant(true)) {
                            CoachLauncherSheet()
                                .environmentObject(coach)
                                .environmentObject(router)
                        }
                }
            } else {
                Color.clear
            }
        }
        .onAppear(perform: prepare)
    }

    private func prepare() {
        switch mode {
        case .connect:
            coach.customConnected = false
            coach.provider = .anthropic
            coach.messages = []
        case .chat, .thinking, .settings, .quickAsk:
            coach.provider = .custom
            coach.model = "llama3.1:8b"
            coach.customConnected = true
            coach.dataConsent = true
            coach.messages = Self.sampleConversation
            if mode == .thinking {
                coach.messages.append(ChatMessage(role: .user,
                    text: "My legs still feel heavy from yesterday's run. Swap to the bike?"))
                coach.sending = true
            }
        }
        ready = true
    }

    private static let sampleConversation: [ChatMessage] = [
        ChatMessage(role: .user, text: "What should today's training look like?"),
        ChatMessage(role: .assistant, text: """
            A good day to push. Charge is **78 %** and HRV sits at **68 ms** against your 62 ms \
            baseline, the third night running above it. The one drag is **38 min** of sleep debt.

            - **Tempo session, 50–60 min**: hold Effort 60–75 with 20 min at threshold.
            - **Bed by 22:50**: clears most of the debt tonight.
            """),
    ]
}
#endif
