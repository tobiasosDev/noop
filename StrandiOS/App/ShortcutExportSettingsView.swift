#if os(iOS)
import SwiftUI
import StrandDesign

/// #155 — the opt-in surface for the Apple-Health-free export. Sideloaded installs (free 7-day
/// signing) can't carry the HealthKit entitlement, so HealthKitBridge never runs for them; this
/// toggle instead has NOOP rewrite Documents/noop_sync.txt on every background transition, and the
/// user's Siri Shortcut reads the file and logs the rows into Apple Health. Default OFF.
struct ShortcutExportSettingsView: View {
    @AppStorage(ShortcutHealthExport.enabledKey) private var enabled = false

    var body: some View {
        ScreenScaffold(title: nil) {
            NoopScreenHeader("Shortcuts Export")
                .padding(.bottom, 6)
            Text("Strap data into Apple Health without HealthKit, for sideloaded installs.")
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
            exportCard
        }
        // The screen draws its own v2 header.
        .noopHidesSystemNavBar()
    }

    private var exportCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                NoopCardHeader("Shortcuts file export", icon: "export")
                Toggle(isOn: $enabled) {
                    Text("Export for Shortcuts (Apple Health)")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.noop)
                Text("When this is on, NOOP rewrites a plain-text file (On My iPhone › NOOP › noop_sync.txt) each time you leave the app: one line per 15 minutes of heart rate, HRV and steps, read straight from your strap. Pair it with the Siri Shortcut that reads the file and logs everything into Apple Health (no HealthKit entitlement needed), so it works on sideloaded installs. The setup guide and the pre-built Shortcut live in the project wiki on GitHub.")
                    .font(StrandFont.light(12.5, relativeTo: .caption))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
#endif
