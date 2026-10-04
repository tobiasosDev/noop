import SwiftUI
import StrandDesign

/// Backup & Sync (folder destination). The Apple mirror of the Android `BackupSyncScreen`: pick a
/// folder, turn on daily auto-backup (an on-launch catch-up), back up now, or restore from a snapshot
/// already in that folder. Snapshots are the existing `.noopbak` whole-DB format. Point the folder at
/// Google Drive / iCloud / Dropbox for off-device sync with no in-app cloud account.
struct BackupSyncView: View {
    @EnvironmentObject var model: AppModel

    @State private var auto = FolderBackup.autoEnabled
    @State private var folderLabel = FolderBackup.folderLabel()
    @State private var lastMs = FolderBackup.lastBackupMs
    @State private var keep = FolderBackup.keepCount
    @State private var busy = false

    // Result alert (backup outcome / restore outcome).
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false

    // Restore-from-folder flow (must-fix #1 + #2): a sheet lists the folder's snapshots; choosing one
    // arms a destructive confirmation; only confirming runs the overwrite.
    @State private var showRestoreSheet = false
    @State private var snapshots: [FolderBackup.Snapshot] = []
    @State private var pendingRestore: FolderBackup.Snapshot?
    @State private var confirmRestore = false

    var body: some View {
        ScreenScaffold(title: nil) {
            NoopScreenHeader("Backup & sync")
                .padding(.bottom, 6)
            hero
            NoopSectionTitle("Automatic backup") { Text(verbatim: ".noopbak") }
            settingsList
            notes
            if !snapshots.isEmpty {
                NoopSectionTitle("Recent snapshots",
                                 caption: String(localized: "\(min(4, snapshots.count)) of \(snapshots.count)"))
                snapshotList
            }
            actions
            Text(".noopbak files are plain archives you own. Open them on any NOOP install: iPhone, Mac or Android.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 10)
        }
        .noopHidesSystemNavBar()
        // The folder's snapshots, for the hero count and the recent list (re-read after every backup,
        // folder change and restore pick).
        .task(id: "\(folderLabel ?? "")|\(lastMs)") { snapshots = FolderBackup.listSnapshots() }
        // Result of a backup or a restore.
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: { Text(alertMessage) }
        // Pick which snapshot to restore - the folder's own snapshots, newest first (must-fix #1).
        .sheet(isPresented: $showRestoreSheet) {
            RestorePickerSheet(snapshots: snapshots) { chosen in
                showRestoreSheet = false
                pendingRestore = chosen
                if chosen != nil { confirmRestore = true }
            }
            #if os(iOS)
            .noopSheetPresentation(largeFirst: false)
            #endif
        }
        // Explicit in-app destructive confirmation BEFORE any overwrite (must-fix #2).
        .alert("Restore this backup?", isPresented: $confirmRestore, presenting: pendingRestore) { snap in
            Button("Replace all data", role: .destructive) { runRestore(snap) }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: { snap in
            // A hand-named file with no resolved date (timeMs 0) confirms by NAME, not "1 Jan 1970".
            Text(snap.timeMs > 0
                ? "Replace all current data with the backup from \(absoluteTime(snap.timeMs))? This cannot be undone."
                : "Replace all current data with the backup \(snap.name)? This cannot be undone.")
        }
    }

    // MARK: - Hero

    /// The ink hero: when the last backup ran, where it went, and what the folder holds.
    private var hero: some View {
        NoopHeroCard(glow: .ink, padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge("Last backup", icon: "archive")
                    Spacer(minLength: 8)
                    NoopPill(auto && folderLabel != nil ? "Auto-backup on" : "Auto-backup off",
                             icon: auto && folderLabel != nil ? "check" : nil, compact: true)
                }
                if lastMs > 0 {
                    NoopDotNumber(Self.clockTime(lastMs), size: 92)
                        .padding(.top, 30)
                    Text("Last backup: \(relativeTime(lastMs))")
                        .font(StrandFont.light(19, relativeTo: .title3))
                        .tracking(-0.2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                } else {
                    Text("No backup yet.")
                        .font(StrandFont.light(19, relativeTo: .title3))
                        .tracking(-0.2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.top, 30)
                }
                Text(folderLabel.map { String(localized: "Saving to: \($0)") }
                     ?? String(localized: "No folder chosen yet. Pick one your cloud app already syncs, or any local folder."))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                NoopMetricRow {
                    NoopMetric(value: "\(snapshots.count)", label: "In the folder", labelColor: NoopMetric.heroLabel)
                    NoopMetric(value: "\(keep)", label: "Snapshots kept", labelColor: NoopMetric.heroLabel)
                }
                .padding(.top, 20)
            }
            .padding(.bottom, 2)
        }
    }

    // MARK: - Settings

    private var settingsList: some View {
        NoopList {
            Button { chooseFolder() } label: {
                NoopRow(title: Text("Backup folder"),
                        caption: Text(folderLabel ?? String(localized: "No folder chosen yet")),
                        icon: "folder-simple", chevron: true) {
                    Text(folderLabel == nil ? "Choose folder" : "Change folder")
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .buttonStyle(.plain)
            .disabled(busy)
            #if os(iOS)
            // #52: some iOS 26 users can't select a folder in the system picker (its "Open" button
            // never fires). This backs up inside NOOP's own Files-visible folder instead — no picker.
            if !FolderBackup.useInternalFolder {
                Button { useNoopFolder() } label: {
                    NoopRow(title: Text("Use NOOP's own folder (browse in Files)"), icon: "device-mobile",
                            chevron: true) { EmptyView() }
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
            #endif
            Toggle(isOn: $auto) {
                rowLabel("Daily auto-backup", icon: "clock-counter-clockwise",
                         caption: Text("Backs up to your folder about once a day and keeps the latest \(keep). On this platform it runs when you next open NOOP."))
            }
            .toggleStyle(.noop)
            .disabled(folderLabel == nil)
            .opacity(folderLabel == nil ? 0.5 : 1)
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .onChangeCompat(of: auto) { on in FolderBackup.autoEnabled = on }
            // Retention: how many dated snapshots to keep. Wired to FolderBackup.keepCount; the next
            // backup prunes the oldest beyond this count (BackupSync.snapshotsToPrune, unchanged).
            // The long caption runs under the stepper row at full width; beside the 110 pt stepper it
            // squeezed into a six-line column in German.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 14) {
                    NoopIconTile("stack")
                    Text("Keep last snapshots")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    KeepStepper(value: $keep, options: FolderBackup.keepOptions)
                }
                Text("Older backups beyond this many are pruned, oldest first (≈ that many days). If data ever corrupts, restore the newest.")
                    .font(StrandFont.light(12, relativeTo: .caption))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 48)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .onChangeCompat(of: keep) { n in FolderBackup.keepCount = n }
        }
    }

    /// The leading part of a settings row: icon tile, title, caption.
    private func rowLabel(_ title: LocalizedStringKey, icon: String, caption: Text) -> some View {
        HStack(spacing: 14) {
            NoopIconTile(icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                caption
                    .font(StrandFont.light(12, relativeTo: .caption))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The tip and the honest warnings that belong next to the folder choice.
    @ViewBuilder private var notes: some View {
        VStack(alignment: .leading, spacing: 12) {
            NoopInsightRow("Tip: choose a folder in iCloud Drive and your backups sync to all your Apple devices automatically, no account setup needed.",
                           icon: "info")
            // #644: these .noopbak snapshots are a plain, unencrypted ZIP — pointing this folder at
            // a cloud sync app (per the tip above) also uploads that readable file there. Say so
            // plainly next to the folder picker, before anyone turns auto-backup on.
            NoopInsightRow("These backups are unencrypted too. If this folder syncs to Drive, Dropbox or iCloud, the readable file goes there as well — only point it at a service you trust.",
                           icon: "warning")
            // Auto is ON but the last SUCCESSFUL backup is stale — the on-launch catch-up isn't landing
            // (a moved/disconnected cloud folder stops backups silently, or NOOP hasn't been opened).
            // Surface it so a silently-failing auto-backup is visible, not discovered only at restore.
            // `lastMs > 0` excludes the never-backed-up state (the hero's "No backup yet." owns that,
            // and it would otherwise false-fire the moment auto is switched on, before the first backup).
            if auto, folderLabel != nil, lastMs > 0,
               BackupSync.isBackupStale(lastBackupMs: lastMs,
                                        nowMs: Int(Date().timeIntervalSince1970 * 1000.0)) {
                G13WarnNote("Auto-backup hasn't run in a few days. Check the backup folder is still available — a moved or disconnected cloud folder stops backups silently.")
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }

    // MARK: - Snapshots + actions

    private var snapshotList: some View {
        NoopList {
            ForEach(snapshots.prefix(4)) { snap in
                // A hand-named file whose date lookup failed has timeMs 0; show its name as the
                // headline rather than "1 Jan 1970", and only repeat the filename under a real date.
                NoopRow(title: Text(snap.timeMs > 0 ? absoluteTime(snap.timeMs) : snap.name),
                        caption: snap.timeMs > 0 ? Text(verbatim: snap.name) : nil,
                        icon: "file-zip") { EmptyView() }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button { backupNow() } label: {
                HStack(spacing: 8) {
                    PhIcon("archive", size: 17)
                    Text(busy ? "Working…" : "Back up now")
                }
            }
            .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
            .disabled(folderLabel == nil || busy)
            NoopButton("Restore from a backup…", kind: .secondary, fullWidth: true) {
                openRestorePicker()
            }
            .disabled(folderLabel == nil || busy)
            Text("Replace this device's data with one of the backups in your folder. This overwrites current data, so back up first if you're unsure.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 4)
        }
        .padding(.top, 12)
    }

    // MARK: - Actions

    private func chooseFolder() {
        #if os(macOS)
        if FolderBackup.pickFolder() != nil { folderLabel = FolderBackup.folderLabel() }
        #else
        // #1000a assumed the iOS picker was refusing to ENABLE its Select button, leaving the user with
        // only Cancel. #2356 disproved that for at least one case: a reporter's log shows the delegate
        // firing after they picked an iCloud folder and pressed Open, so the button worked and iOS
        // declined the grant instead. Both still arrive here as nil, and UIKit gives us nothing to tell
        // them apart, which is exactly why the alert below describes the outcome rather than a cause.
        // Keep it that way: the previous guess is what sent the last investigation at the wrong failure.
        // Mildly chatty on a genuine Cancel; honest and actionable whenever no folder comes back.
        // `busy` guards against a double-tap stacking a second picker presentation on top of the first.
        busy = true
        Task {
            // Clear in a `defer` so it clears on ANY exit. It matters more here than elsewhere: every
            // control on this screen is `.disabled(busy)`, so a pick that never returned wedged the whole
            // screen — including the "Use NOOP's own folder" escape hatch. DocumentPicker now guarantees
            // the continuation resumes, but the flag must not depend on that promise holding.
            defer { busy = false }
            let picked = await FolderBackup.pickFolder()
            if picked != nil {
                folderLabel = FolderBackup.folderLabel()
            } else if !FolderBackup.useInternalFolder {
                // Only nag when there's no working destination. If the internal fallback is already
                // active, a cancelled picker changed nothing — and the button the message points at is
                // hidden, so alerting here would send the user chasing a control that isn't shown.
                alertTitle = String(localized: "No folder selected")
                alertMessage = String(localized: "NOOP didn't get a folder back from the picker. If the Open button won't do anything, tap \"Use NOOP's own folder\" below to back up inside NOOP instead — you can read those backups from the Files app.")
                showAlert = true
            }
        }
        #endif
    }

    #if os(iOS)
    // #52: picker-free fallback. Back up inside NOOP's own Files-visible folder (On My iPhone → NOOP →
    // Backups). No folder picker, no security-scoped bookmark — works even where the picker won't select.
    private func useNoopFolder() {
        FolderBackup.useNoopFolder()
        folderLabel = FolderBackup.folderLabel()
        alertTitle = String(localized: "Using NOOP's folder")
        alertMessage = String(localized: "Backups will be saved inside NOOP. Open the Files app → On My iPhone → NOOP → Backups to see them, or drag that folder into iCloud Drive to read it on your Mac. To use a different folder later, tap Change folder.")
        showAlert = true
    }
    #endif

    private func backupNow() {
        busy = true
        Task {
            defer { busy = false }   // any exit, incl. cancellation — see chooseFolder
            let ok = await FolderBackup.backupNow(checkpoint: { await model.repo.checkpointForBackup() })
            await MainActor.run {
                lastMs = FolderBackup.lastBackupMs
                alertTitle = ok ? String(localized: "Backed up") : String(localized: "Backup problem")
                alertMessage = ok
                    ? String(localized: "Saved a backup to your folder.")
                    : String(localized: "Backup failed - re-pick the folder and try again.")
                showAlert = true
            }
        }
    }

    private func openRestorePicker() {
        snapshots = FolderBackup.listSnapshots()
        if snapshots.isEmpty {
            alertTitle = String(localized: "No backups found")
            alertMessage = String(localized: "There are no NOOP backups in your folder yet. Use Back up now first.")
            showAlert = true
        } else {
            showRestoreSheet = true
        }
    }

    private func runRestore(_ snap: FolderBackup.Snapshot) {
        pendingRestore = nil
        busy = true
        Task {
            defer { busy = false }   // any exit, incl. cancellation — see chooseFolder
            // The restore is synchronous file I/O; run it off the main actor so the UI stays responsive
            // for a large store, then report on the main actor.
            let result = await Task.detached(priority: .userInitiated) {
                FolderBackup.restore(snapshotNamed: snap.name)
            }.value
            await MainActor.run {
                switch result {
                case .imported:
                    alertTitle = String(localized: "Restored")
                    alertMessage = String(localized: "Fully quit and reopen NOOP to load it.")
                case .failure(let m):
                    alertTitle = String(localized: "Restore problem"); alertMessage = m
                case .restoreTooLarge(let name, let limit):
                    // #1807: recoverable, but not from here — this view restores a snapshot directly and
                    // has no confirm step to hang the override on. Point at the path that does, rather
                    // than leaving the user with a refusal and nowhere to go.
                    let cap = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
                    alertTitle = String(localized: "Backup problem")
                    alertMessage = String(localized: "\(name) is larger than the \(cap) NOOP restores without asking. You can still restore it from Settings → Backup & restore → Import, which will ask you to confirm.")
                case .cancelled, .exported, .exportedOversize:
                    alertTitle = String(localized: "Restore problem"); alertMessage = String(localized: "Couldn't restore that backup.")
                }
                showAlert = true
            }
        }
    }

    // MARK: - Formatting

    private func relativeTime(_ ms: Int) -> String {
        let f = RelativeDateTimeFormatter()
        return f.localizedString(for: Date(timeIntervalSince1970: Double(ms) / 1000.0), relativeTo: Date())
    }

    private func absoluteTime(_ ms: Int) -> String {
        let f = DateFormatter()
        // #1821: localized DATE style untouched; only the hour cycle is the reader's.
        f.locale = AppClock.formattingLocale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
    }

    /// The last backup's wall-clock time ("03:00") for the hero's dot-matrix figure.
    static func clockTime(_ ms: Int) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000.0).formatted(.dateTime.hour().minute())
    }
}
/// The `.stp` stepper (− 7 +) for the retention count: steps through the allowed options only.
private struct KeepStepper: View {
    @Binding var value: Int
    let options: [Int]

    private var index: Int { options.firstIndex(of: value) ?? options.firstIndex(where: { $0 >= value }) ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            Button { step(-1) } label: {
                PhIcon("minus", size: 14).frame(width: 34, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(index == 0)
            .opacity(index == 0 ? 0.35 : 1)
            .accessibilityLabel(Text("Fewer"))
            Text(verbatim: "\(value)")
                .font(StrandFont.value(16))
                .frame(minWidth: 22)
            Button { step(1) } label: {
                PhIcon("plus", size: 14).frame(width: 34, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(index >= options.count - 1)
            .opacity(index >= options.count - 1 ? 0.35 : 1)
            .accessibilityLabel(Text("More"))
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .frame(height: 34)
        .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Keep last snapshots"))
        .accessibilityValue(Text(verbatim: "\(value)"))
    }

    private func step(_ delta: Int) {
        let i = min(max(index + delta, 0), options.count - 1)
        value = options[i]
    }
}

/// The snapshot chooser shown before a restore (must-fix #1: pick from the folder, newest first).
/// Reports the chosen snapshot (or nil if dismissed) back to the host, which then arms the destructive
/// confirmation.
private struct RestorePickerSheet: View {
    let snapshots: [FolderBackup.Snapshot]
    let onChoose: (FolderBackup.Snapshot?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            NoopSheetHeader("Choose a backup", doneTitle: nil, onCancel: { onChoose(nil) })
            ScrollView {
                NoopList {
                    ForEach(snapshots) { snap in
                        Button { onChoose(snap) } label: {
                            // A hand-named file whose date lookup failed has timeMs 0; show its name as the
                            // primary line rather than "1 Jan 1970". The filename subtitle then only repeats
                            // when we DO have a real date to head the row.
                            NoopRow(title: Text(primaryLabel(snap)),
                                    caption: snap.timeMs > 0 ? Text(verbatim: snap.name) : nil,
                                    icon: "file-zip", chevron: true) { EmptyView() }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(accessibilityLabel(snap))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background(NoopSheetBackground())
        // A macOS `.sheet` sizes to its content's ideal height, and a scroll view reports a near-zero
        // intrinsic height there — so without an explicit frame the sheet collapses to just the title +
        // Cancel and clips every row, leaving the user an empty "Choose a backup" with backups that ARE
        // in the folder (the caller only opens this sheet when the list is non-empty). Give it a real
        // size, the same way `AddDeviceWizard`/`HealthView` frame their macOS sheets with a fixed size.
        // iOS/iPadOS sheets already take a sensible height, so the frame is macOS-only. A longer backup
        // list scrolls; a short one leaves trailing space. (#1093)
        #if os(macOS)
        .frame(width: 460, height: 420)
        #endif
    }

    /// The row's headline: a friendly date when we resolved one, else the filename (never the epoch date).
    private func primaryLabel(_ snap: FolderBackup.Snapshot) -> String {
        snap.timeMs > 0 ? absoluteTime(snap.timeMs) : snap.name
    }

    /// VoiceOver label: reads the resolved date when we have one, else the filename (no epoch date).
    private func accessibilityLabel(_ snap: FolderBackup.Snapshot) -> String {
        snap.timeMs > 0 ? String(localized: "Restore backup from \(absoluteTime(snap.timeMs))")
                        : String(localized: "Restore backup \(snap.name)")
    }

    private func absoluteTime(_ ms: Int) -> String {
        let f = DateFormatter()
        // #1821: localized DATE style untouched; only the hour cycle is the reader's. Second copy of
        // this helper in the file - a single-shot replace fixed only the first, which the sweep caught.
        f.locale = AppClock.formattingLocale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
    }
}
