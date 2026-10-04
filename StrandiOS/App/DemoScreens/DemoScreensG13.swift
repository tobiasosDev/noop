#if DEBUG
import SwiftUI
import StrandDesign

extension DemoScreensV2 {
    /// Group 13 demo screens for `--demo-screen <name>` (lowercase names).
    static func group13(_ name: String) -> AnyView? {
        switch name {
        case "probe-battery": return AnyView(ProbeSheetDemoScreen(kind: .battery))
        case "probe-ecg": return AnyView(ProbeSheetDemoScreen(kind: .ecg))
        case "probe-waiting": return AnyView(ProbeSheetDemoScreen(kind: .waiting))
        case "ecg-wrist": return AnyView(ProbeSheetDemoScreen(kind: .wrist))
        case "diagnostics-sheet": return AnyView(DiagnosticsSheetDemoScreen())
        case "report-review": return AnyView(ReportReviewDemoScreen())
        case "rawdata": return AnyView(G13RawDataHost())
        case "steps-calibration": return AnyView(G13StepsCalibrationHost())
        case "settings-backup": return AnyView(SettingsView(page: .backup))
        case "settings-diagnostics": return AnyView(SettingsView(page: .diagnostics))
        case "settings-recovery": return AnyView(SettingsView(page: .recovery))
        case "settings-hrv": return AnyView(SettingsView(page: .hrv))
        case "settings-sync": return AnyView(SettingsView(page: .sync))
        case "settings-features": return AnyView(SettingsView(page: .features))
        case "settings-streak": return AnyView(SettingsView(page: .streak))
        case "settings-livenotifications": return AnyView(SettingsView(page: .liveNotifications))
        case "settings-strap13": return AnyView(SettingsView(page: .strap))
        case "settings-units13": return AnyView(SettingsView(page: .units))
        case "settings-experimental13": return AnyView(SettingsView(page: .experimental))
        case "settings-about13": return AnyView(SettingsView(page: .about))
        case "settings-updates13": return AnyView(SettingsView(page: .updates))
        case "settings-profile13": return AnyView(SettingsView(page: .profile))
        case "settings-appearance13": return AnyView(SettingsView(page: .appearance))
        case "backupsync": return AnyView(BackupSyncView())
        case "pending-notes": return AnyView(G13PendingNotesHost())
        default: return nil
        }
    }
}

/// The steps-estimate calibration sheet over an empty screen (it normally opens from Profile or the
/// Today steps tile).
private struct G13StepsCalibrationHost: View {
    @EnvironmentObject private var model: AppModel
    @State private var shown = true
    var body: some View {
        Color.clear.sheet(isPresented: $shown) {
            StepsCalibrationSheet(repo: model.repo, onClose: {})
                .environmentObject(model.profile)
        }
    }
}

/// The raw-data collector with one seeded historical session (comment + marker), so the session card
/// renders. The session lands in the simulator's own collector folder.
private struct G13RawDataHost: View {
    @State private var ready = false
    var body: some View {
        Group {
            if ready { RawDataCollectorView() } else { Color.clear }
        }
        .task {
            let store = RawDataSessionStore()
            if store.sessions.isEmpty,
               let session = store.createHistorical(deviceId: "demo", from: Date().addingTimeInterval(-5_400),
                                                    to: Date().addingTimeInterval(-3_600)) {
                _ = store.addMarker(sessionId: session.id, at: Date().addingTimeInterval(-4_800),
                                    type: "start", text: "Warm-up walk")
                store.setComment("Treadmill walk, 5 km/h", sessionId: session.id)
            }
            ready = true
        }
    }
}
/// The shared empty / pending helpers from ScreenScaffold side by side.
private struct G13PendingNotesHost: View {
    var body: some View {
        ScreenScaffold(title: "Pending states", subtitle: "The shared empty and syncing helpers") {
            SyncingHistoryNote(chunks: 14)
            DataPendingNote(title: "Live now. Your scores are building.",
                            message: "Heart rate is streaming. Charge and Sleep fill in after your first night.")
            DataPendingNote(title: "Sleep result updated", message: "Last night was re-scored with the newer staging.",
                            symbol: "checkmark.circle")
            ComingSoon(what: "Loading your sleep history…")
        }
    }
}
#endif
