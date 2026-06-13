import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Live — the connected strap in real time. Built on the shared design system
/// (ScreenScaffold chrome, StrandPalette, StrandFont) so it lines up pixel-for-pixel
/// with every other screen instead of the old standalone Milestone-1 layout.
struct LiveView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore

    /// Strain Coach strip — intraday strain so far today (nil until ~10 min of HR exists).
    @State private var dayStrain: Double? = nil

    /// Inline preview of the diagnostics report (everything before the raw-JSON dump). Loaded on
    /// appear and refreshed after each completed sync so the counts stay current without a tap.
    @State private var diagPreview: String = ""

    /// Which strap the user is pairing — persists across launches. Drives which
    /// BLE service we scan for so a WHOOP 4.0 scan never hangs on a WHOOP 5 wrist.
    @AppStorage("selectedWhoopModel") private var selectedModelRaw = WhoopModel.whoop4.rawValue
    private var selectedModel: WhoopModel { WhoopModel(rawValue: selectedModelRaw) ?? .whoop4 }

    /// Smoothed, spike-filtered live HR from AppModel (median over a short window).
    private var displayHR: Int? { model.bpm }
    private var activeConnection: Bool { live.connected && live.bonded }

    var body: some View {
        ScreenScaffold(title: "Live",
                       subtitle: "Your strap in real time — heart rate and frames as they arrive.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                connectionRow
                // Can't-connect-at-all guidance: the strap wiped its bond (firmware update / WHOOP app
                // re-bond), so connects loop on "Peer removed pairing information". Show the re-pair steps
                // right here instead of silently retrying. (5/MG firmware reset, 2026-06)
                if let guide = live.reconnectGuide { reconnectGuideBanner(guide) }
                // Bond-refused guidance, shown right here on Live where people actually connect (it
                // also appears in Settings). A 5/MG strap still bonded to the WHOOP app refuses pairing
                // with "Encryption is insufficient" — this tells the user to free it and re-pair.
                if let hint = live.pairingHint { pairingHintBanner(hint) }
                heartRateCard
                // Low-bandwidth fallback note (#80): the radio couldn't sustain the WHOOP 4 R10/R11 raw
                // realtime burst, so live HR is riding the standard BLE Heart-Rate profile instead. Live HR
                // still works — this is informational, not an error — so it sits right under the readout in
                // a calm accent treatment rather than the amber warning banners above.
                if Self.shouldShowStandardHRNote(live.standardHRMode) {
                    standardHRNote(live.standardHRMode ?? "")
                }
                statusGrid
                workoutSection
                // Show the strap picker whenever we're not actively streaming, so a user with both a
                // WHOOP 4 and a 5/MG can switch between them. (It used to hide once `bonded`, which is
                // sticky across disconnects — so after the first pairing the picker vanished for good.)
                if !activeConnection { modelPicker }
                controls
                logCard
                diagnosticsCard
            }
        }
        .onAppear { refreshLiveSession() }
        .task(id: repo.refreshSeq) {
            dayStrain = await DayStrain.compute(repo: repo, hrMax: profile.hrMax,
                                                sex: profile.sex,
                                                restingHr: repo.today?.restingHr)
        }
        .task(id: live.lastSyncedAt) { diagPreview = await previewText() }
        .onDisappear { model.stopRealtimeHR() }
        .onChange(of: live.bonded) { _ in refreshLiveSession() }
        .onChange(of: live.connected) { _ in refreshLiveSession() }
    }

    // MARK: - Connection

    private var connectionRow: some View {
        HStack {
            connectionPill
            Spacer()
        }
    }

    private var connectionPill: some View {
        // Distinguish a GENUINE encrypted bond from the 5/MG live-HR shortcut that flips `bonded` true
        // over the unbonded standard profile (#69): green "Bonded · streaming" only when encryptedBond,
        // amber "Live HR (not fully paired)" otherwise. The pairingHintBanner below gives the how-to.
        let (label, color): (String, Color) =
            (activeConnection && live.encryptedBond) ? ("Bonded · streaming", StrandPalette.accent)
            : activeConnection ? ("Live HR (not fully paired)", StrandPalette.statusWarning)
            : live.connected ? ("Connected", StrandPalette.statusWarning)
            : live.encryptedBond ? ("Paired · idle", StrandPalette.statusWarning)
            : ("Disconnected", StrandPalette.metricRose)
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(StrandPalette.surfaceRaised, in: Capsule())
    }

    // MARK: - Heart rate

    private var heartRateCard: some View {
        NoopCard {
            VStack(spacing: 6) {
                Text("HEART RATE").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(displayHR.map(String.init) ?? "—")
                    .font(.system(size: 96, weight: .semibold).monospacedDigit())
                    .foregroundStyle(displayHR == nil ? StrandPalette.textTertiary : StrandPalette.accent)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: displayHR)
                Text("bpm").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                if !live.rr.isEmpty {
                    Text("R-R: " + live.rr.suffix(4).map(String.init).joined(separator: " · ") + " ms")
                        .font(StrandFont.mono).foregroundStyle(StrandPalette.textTertiary)
                }
                if let s = dayStrain, let recovery = repo.today?.recovery {
                    let band = StrainTarget.band(recovery: recovery)
                    Text("Day strain \(s, specifier: "%.1f") / target \(band.low, specifier: "%.1f")–\(band.high, specifier: "%.1f")")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 20)
        }
    }

    // MARK: - Status tiles

    private var statusGrid: some View {
        // Wide canvas (macOS/iPad): the three tiles sit edge-to-edge in one row, exactly as before
        // (ViewThatFits picks this child when it fits). Narrow iPhone: the row can't fit at the
        // tiles' ~150pt min, so it falls back to a wrapping 2-up adaptive grid instead of squeezing
        // each tile below its design intent. (Was a fixed 3-column HStack.)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NoopMetrics.gap) { statusTiles }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: NoopMetrics.gap)],
                      spacing: NoopMetrics.gap) { statusTiles }
        }
    }

    @ViewBuilder private var statusTiles: some View {
        // minWidth floors the tiles so the single-row HStack reports its true ~474pt ideal width
        // and ViewThatFits correctly rejects it on iPhone; on the wide canvas the cards still
        // expand to fill (maxWidth .infinity), so the row is unchanged on macOS.
        stat("Battery", live.batteryPct.map { "\(Int($0))%" } ?? "—").frame(minWidth: 150, maxWidth: .infinity)
        stat("Last frame", live.lastFrameType ?? "—").frame(minWidth: 150, maxWidth: .infinity)
        stat("Last event", live.lastEvent ?? "—").frame(minWidth: 150, maxWidth: .infinity)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased()).font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(value).font(StrandFont.headline).monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Manual workout

    @ViewBuilder private var workoutSection: some View {
        if let w = model.activeWorkout {
            activeWorkoutCard(w)
        } else {
            if activeConnection {
                Button { model.startWorkout() } label: {
                    Label("Start workout", systemImage: "figure.run")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                .help("Track a workout manually — records heart rate and effort until you end it.")
            }
            if let last = model.lastWorkout {
                workoutSavedRow(last)
            }
        }
    }

    private func activeWorkoutCard(_ w: AppModel.ActiveWorkout) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(StrandPalette.metricRose).frame(width: 8, height: 8)
                    Text("RECORDING WORKOUT").font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking).foregroundStyle(StrandPalette.metricRose)
                    Spacer()
                    // Re-render once a second so the elapsed clock ticks without a manual Timer.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(Self.elapsed(since: w.start)).font(StrandFont.headline).monospacedDigit()
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                HStack(spacing: NoopMetrics.gap) {
                    workoutStat("HR", model.bpm.map { "\($0)" } ?? "—")
                    workoutStat("Avg", w.avgHr > 0 ? "\(w.avgHr)" : "—")
                    workoutStat("Peak", w.peakHr > 0 ? "\(w.peakHr)" : "—")
                    workoutStat("Effort", String(format: "%.1f", w.liveStrain))
                }
                Button(role: .destructive) { model.endWorkout() } label: {
                    Label("End workout", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).tint(StrandPalette.metricRose)
            }
        }
    }

    private func workoutStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(value).font(StrandFont.headline).monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func workoutSavedRow(_ row: WorkoutRow) -> some View {
        let mins = Int((row.durationS ?? 0) / 60)
        let parts = ["\(mins) min", row.avgHr.map { "\($0) avg bpm" },
                     row.strain.map { String(format: "effort %.1f", $0) }].compactMap { $0 }
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(StrandPalette.accent)
            Text("Workout saved · \(parts.joined(separator: " · "))")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private static func elapsed(since start: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func reconnectGuideBanner(_ guide: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Can't connect — your strap's pairing was reset")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text(guide)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(StrandPalette.statusWarning.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reconnect help: \(guide)")
    }

    private func pairingHintBanner(_ hint: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Live HR works — free the strap to unlock buzz, alarms & sync")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text(hint)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(StrandPalette.statusWarning.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pairing help: \(hint)")
    }

    /// Whether the low-bandwidth standard-HR fallback note should render. The note explains that live HR
    /// is coming over the standard BLE Heart-Rate profile because the radio couldn't sustain the full
    /// stream (#80). Shown only when LiveState carries a non-empty note string; pure so it's unit-testable
    /// without standing up a SwiftUI view.
    static func shouldShowStandardHRNote(_ note: String?) -> Bool {
        guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    /// Calm inline note for the #80 low-bandwidth fallback. Unlike the amber pairing/reconnect banners this
    /// is NOT a warning — live HR is working — so it uses the accent (health-green) treatment with a signal
    /// glyph. Mirrors the banner layout (icon + headline + one-line explanation) for visual consistency.
    private func standardHRNote(_ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(StrandPalette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Standard HR mode (low bandwidth)")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text(detail)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Other metrics (R-R, frames, battery, history) need a full sync.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(StrandPalette.accent.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Standard HR mode, low bandwidth. \(detail)")
    }

    // MARK: - Strap picker

    /// Pick the strap family to scan for. Switching the selection drops the current strap's bond so the
    /// newly-picked one connects fresh — letting a user move between a WHOOP 4 and a 5/MG.
    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Strap").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                SegmentedPillControl(
                    WhoopModel.allCases,
                    selection: Binding(
                        get: { selectedModel },
                        set: { newModel in
                            guard newModel.rawValue != selectedModelRaw else { return }
                            selectedModelRaw = newModel.rawValue
                            // Clear the previous strap's sticky bond/connection so the next scan targets the
                            // new family's service and bonds it fresh.
                            model.prepareStrapSwitch()
                        }
                    ),
                    label: { $0.displayName }
                )
                Spacer()
            }
            // Proactive 5/MG guidance: the strap bonds to one host at a time, so if it's still paired in
            // the official WHOOP app a scan here finds nothing. Shown the moment 5/MG is picked — not only
            // after a failed scan (#130) or a bond-refusal (which is the separate `pairingHint` banner).
            if selectedModel == .whoop5mg { whoop5PairingNote }
        }
    }

    private var whoop5PairingNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(StrandPalette.accent)
            Text("WHOOP 5.0/MG pairs with one app at a time. If a scan finds nothing, unpair it in the official WHOOP app and fully close that app, then Scan again.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        // Wide canvas (macOS) keeps the three buttons in a single row; on the narrow iPhone width
        // where the labels would hyphenate/wrap ("Scan & Con-nect", "Dis-con-nect"), they stack
        // full-width vertically instead. Each button already uses .frame(maxWidth:.infinity), so
        // both branches expand cleanly. Buttons are factored into computed properties so the two
        // branches stay in sync. The labels also shrink-to-fit (lineLimit(1)+minimumScaleFactor)
        // so even when the single-row HStack wins on a tight-but-fitting width, no label wraps
        // mid-word. (#175)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                scanButton
                buzzButton
                disconnectButton
            }
            VStack(spacing: 12) {
                scanButton
                buzzButton
                disconnectButton
            }
        }
    }

    private var scanButton: some View {
        Button { model.scan(model: selectedModel) } label: {
            Label(live.connected ? "Re-scan" : "Scan & Connect",
                  systemImage: "antenna.radiowaves.left.and.right")
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
    }

    private var buzzButton: some View {
        Button { model.buzz() } label: {
            Label("Buzz strap", systemImage: "waveform.path")
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.bordered).tint(StrandPalette.accent)
        .disabled(!activeConnection)
        .help("Fire a test haptic buzz on the strap (requires an active strap connection)")
    }

    private var disconnectButton: some View {
        Button(role: .destructive) { model.disconnect() } label: {
            Label("Disconnect", systemImage: "xmark.circle")
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .disabled(!live.connected)
    }

    private func refreshLiveSession() {
        guard activeConnection else { return }
        model.startRealtimeHR()
        model.getBattery()
    }

    // MARK: - Strap log

    private var logCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("STRAP LOG").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    // Export the log so people can attach it to a bug report (issue #17 — macOS users
                    // had no way to share it). Copy → clipboard; Save… → a .txt file.
                    // Pad + contentShape so the tap region clears 44pt on iPhone touch without
                    // changing the visible mono-text glyphs (macOS pointer hit area is unaffected).
                    Button("Copy") { copyStrapLog() }
                        .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                        .padding(.vertical, 8).padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    Button("Save…") { saveStrapLog() }
                        .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                        .padding(.vertical, 8).padding(.horizontal, 4)
                        .contentShape(Rectangle())
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(live.log.enumerated()), id: \.offset) { idx, line in
                                Text(line).font(StrandFont.mono)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                    }
                    .frame(height: 200)
                    .onChange(of: live.log.count) { _ in
                        if let last = live.log.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
    }

    // MARK: - Strap-log export (issue #17 — let macOS users share the log for bug reports)

    private func strapLogText() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        #if os(iOS)
        let osName = "iOS"
        #else
        let osName = "macOS"
        #endif
        let header = "NOOP strap log — \(osName)\nApp: \(v)\n\(osName): "
            + ProcessInfo.processInfo.operatingSystemVersionString + "\n"
            + String(repeating: "-", count: 40) + "\n"
        return header + live.log.joined(separator: "\n")
    }

    private func copyStrapLog() {
        PlatformPasteboard.copy(strapLogText())
    }

    private func saveStrapLog() {
        FileExport.exportText(strapLogText(), suggestedName: "noop-strap-log.txt")
    }

    // MARK: - Diagnostics export (remote troubleshooting — DB row counts, cursors, strap clock)
    // A "no strain / recovery / stress" report is almost always one upstream cause (no HR/RR rows,
    // or a frozen strap RTC). This dumps the on-device row counts + timestamp spans + sync cursors
    // so it can be diagnosed from a shared file, without physical access to the device.

    private var diagnosticsCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("DIAGNOSTICS").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Button("Copy") { exportDiagnostics(save: false) }
                        .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                        .padding(.vertical, 8).padding(.horizontal, 4).contentShape(Rectangle())
                    Button("Save…") { exportDiagnostics(save: true) }
                        .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                        .padding(.vertical, 8).padding(.horizontal, 4).contentShape(Rectangle())
                }
                Text("On-device DB row counts, sync cursors and strap clock offset — share this if strain / recovery / stress look empty.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !diagPreview.isEmpty {
                    ScrollView {
                        Text(diagPreview).font(StrandFont.mono)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 180)
                }
            }
        }
    }

    /// The report up to (but not including) the raw-JSON dump — the readable part, for inline display.
    private func previewText() async -> String {
        let full = await repo.diagnosticsText()
        if let r = full.range(of: "--- raw JSON ---") {
            return String(full[full.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return full
    }

    /// Recompute the full report on tap (cheap, read-only) so the export reflects current state.
    private func exportDiagnostics(save: Bool) {
        Task { @MainActor in
            let text = await repo.diagnosticsText()
            if save {
                FileExport.exportText(text, suggestedName: "noop-diagnostics.txt")
            } else {
                PlatformPasteboard.copy(text)
            }
        }
    }
}
