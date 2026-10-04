#if os(iOS)
import SwiftUI
import AppIntents
import StrandDesign

/// Surfaces NOOP's already-registered App Intents (see StrandiOS/System/NOOPAppIntents.swift) in the
/// UI so users discover them. `NOOPShortcuts` auto-registers "Sync Strap", "Buzz Strap" and "Mark a Moment" with
/// Siri/Spotlight/Shortcuts, but nothing in-app advertised them — this is the iOS analogue of the
/// Mac's strap-double-tap-runs-a-Shortcut feature. Apple's `SiriTipView`/`ShortcutsLink` (iOS 16+)
/// do exactly that: tip the user on the spoken phrase and deep-link into the Shortcuts app, scoped to
/// this app automatically.
struct SiriShortcutsSettingsView: View {
    var body: some View {
        ScreenScaffold(title: nil) {
            NoopScreenHeader("Siri & Shortcuts")
                .padding(.bottom, 6)
            Text("Run NOOP actions hands-free.")
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.horizontal, 4)
            tips
            shortcutsCard
        }
        // The screen draws its own v2 header.
        .noopHidesSystemNavBar()
    }

    private var tips: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                NoopCardHeader("Ready-made actions", icon: "microphone")
                Text("Sync your strap, buzz it or mark a moment from Siri, Spotlight, the Shortcuts app, or a Back-Tap / automation. No setup needed.")
                    .font(StrandFont.light(13, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                SiriTipView(intent: SyncStrapIntent(), isVisible: .constant(true))
                    .siriTipViewStyle(.dark)
                SiriTipView(intent: BuzzStrapIntent(), isVisible: .constant(true))
                    .siriTipViewStyle(.dark)
                SiriTipView(intent: MarkMomentIntent(), isVisible: .constant(true))
                    .siriTipViewStyle(.dark)
            }
        }
    }

    private var shortcutsCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                NoopCardHeader("Build your own", icon: "stack")
                Text("Wire NOOP's actions into a Back-Tap, a focus automation, or a longer Shortcut. For example, double-tap the back of your iPhone to buzz the strap.")
                    .font(StrandFont.light(13, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ShortcutsLink()
            }
        }
    }
}
#endif
