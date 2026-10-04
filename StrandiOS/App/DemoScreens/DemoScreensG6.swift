#if DEBUG
import SwiftUI
import StrandDesign

extension DemoScreensV2 {
    /// Group 6 demo screens for `--demo-screen <name>` (lowercase names).
    static func group6(_ name: String) -> AnyView? {
        switch name {
        case "more": return AnyView(G6RefreshingHost { MoreIndexView() })
        case "settings-hub": return AnyView(G6RefreshingHost { SettingsView() })
        case "settings-profile": return AnyView(G6RefreshingHost { SettingsView(page: .profile) })
        case "settings-appearance": return AnyView(G6RefreshingHost { SettingsView(page: .appearance) })
        case "settings-units": return AnyView(SettingsView(page: .units))
        case "settings-strap": return AnyView(SettingsView(page: .strap))
        case "settings-experimental": return AnyView(SettingsView(page: .experimental))
        case "settings-about": return AnyView(SettingsView(page: .about))
        case "settings-updates": return AnyView(SettingsView(page: .updates))
        case "automations": return AnyView(AutomationsView())
        case "powersaving": return AnyView(PowerSavingView())
        case "testcentre": return AnyView(TestCentreView())
        case "updates": return AnyView(UpdatesInboxView(onClose: {}))
        case "updates-sample": return AnyView(G6UpdatesSampleHost())
        case "siri": return AnyView(SiriShortcutsSettingsView())
        case "shortcutsexport": return AnyView(ShortcutExportSettingsView())
        default: return nil
        }
    }
}

/// The Updates inbox with a few posted items, so the hero and the list render (DEBUG harness only; the
/// items land in the simulator's own inbox).
private struct G6UpdatesSampleHost: View {
    @EnvironmentObject private var updateStore: UpdateStore
    var body: some View {
        UpdatesInboxView(onClose: {})
            .onAppear {
                // Keyed on a sample title, not on an empty inbox: launch already posts the release's
                // What's-new item, which kept the samples from ever landing.
                guard !updateStore.items.contains(where: { $0.title == "History synced" }) else { return }
                let now = Date()
                updateStore.post(UpdateItem(kind: .reading, title: "History synced",
                                            message: "New nights arrived from your strap. Your trends are up to date.",
                                            date: now.addingTimeInterval(-3_600), deepLink: "trends"))
                updateStore.post(UpdateItem(kind: .whatsNew, title: "What's new in NOOP",
                                            message: "A calmer look across every screen.",
                                            date: now.addingTimeInterval(-86_400)))
                updateStore.post(UpdateItem(kind: .strapAlert, title: "Strap battery low",
                                            message: "Top it up before tonight so sleep is recorded.",
                                            date: now.addingTimeInterval(-3 * 86_400), read: true))
            }
    }
}

/// Loads the seeded history before showing a screen that only reads it (the shell normally refreshes the
/// repository at launch; the single-screen harness does not).
private struct G6RefreshingHost<Content: View>: View {
    @EnvironmentObject private var repo: Repository
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().task { await repo.refresh() }
    }
}
#endif
