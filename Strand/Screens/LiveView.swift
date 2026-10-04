import SwiftUI
#if os(macOS)
import AppKit
#endif
import StrandDesign
import StrandAnalytics
import WhoopProtocol
import WhoopStore
import OuraProtocol

/// Live — the connected strap in real time (v2). One heart-glow hero carries the live heart rate, its
/// zone and the last minute of beats; below it sit the beat-by-beat physiology, the signal-trust rail,
/// the session controls, the strap itself and its log.
///
/// LiveState (which publishes at ~1 Hz while a strap streams) is observed ONLY in leaf views
/// (`LiveHeartHero`, `LivePhysiology`, `LiveSignalTrustRail`, `LiveStrapSummary`, `ActiveWorkoutLive`,
/// `LiveLogCard`, …) — the Today pattern — so a fresh HR / R-R / frame notify re-renders just that leaf,
/// never the whole screen. The parent only observes the coarse connection transitions it needs to re-arm
/// the stream and gate the layout.
struct LiveView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    /// Cross-screen navigation — drives the "Manage devices" affordance to the first-class Devices
    /// manager (where bands are paired / switched). The shell (sidebar on macOS, a sheet on iOS) routes
    /// the request; LiveView never needs to know which.
    @EnvironmentObject private var router: NavRouter

    /// Which strap the user is pairing — persists across launches. Drives which
    /// BLE service we scan for so a WHOOP 4.0 scan never hangs on a WHOOP 5 wrist.
    @AppStorage("selectedWhoopModel") private var selectedModelRaw = WhoopModel.whoop4.rawValue
    private var selectedModel: WhoopModel { WhoopModel(rawValue: selectedModelRaw) ?? .whoop4 }

    /// "Card transparency" (0–100, default 100): fades the live console cards in lockstep with the frosted
    /// cards; content stays readable. Mirrors Kotlin `NoopPrefs.cardOpacityPercent`.
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }

    /// Maps the picked strap model to the HRV-reading source so the spot caveat is honest (#537): a
    /// WHOOP 5/MG's R-R is optical PPG (noisier), a WHOOP 4 is electrical R-R. Mirrors the Android
    /// `LiveScreen` mapping.
    private var hrvSnapshotSource: SpotHrvReading.Source {
        switch selectedModel {
        case .whoop5mg: return .opticalPPG
        case .whoop4:   return .chestStrap
        }
    }

    /// Effort display scale (#268) — routes the live + saved workout Effort read-outs. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// Whether the ACTIVE registry device is a WHOOP, resolved once and handed to the leaves.
    private var activeIsWhoop: Bool {
        LiveConsoleReadout.activeIsWhoop(
            devices: model.deviceRegistry?.devices ?? [],
            activeId: model.deviceRegistry?.activeDeviceId,
        )
    }

    /// Whether the ACTIVE registry device is an Oura ring (#2305) — the ring-only affordances below.
    private var activeIsOura: Bool {
        LiveConsoleReadout.activeIsOura(
            devices: model.deviceRegistry?.devices ?? [],
            activeId: model.deviceRegistry?.activeDeviceId,
        )
    }

    /// The live ring's link phase, mirrored off the Oura source (#2305). Meaningful only under
    /// `activeIsOura`; `.disconnected` otherwise.
    private var ringPhase: OuraLiveSource.LinkPhase { model.ouraLinkPhase }

    /// A trusted WHOOP link, for the console readouts and the bond-only controls.
    ///
    /// Gated on the active device actually BEING a WHOOP (#2075). `LiveState` is one object that every
    /// live source writes into, so `connected && bonded` stays true for a bonded strap while an Oura
    /// ring is the device on screen. That showed the WHOOP pill, the WHOOP charge and live WHOOP-only
    /// controls under the ring's name, and made the pill's own ring branch unreachable, because this one
    /// is tested first.
    private var activeConnection: Bool { activeIsWhoop && live.connected && live.bonded }

    /// A non-WHOOP live source (the Oura ring) that is connected and actively streaming live HR. It
    /// authenticates and streams but never reaches a WHOOP encrypted bond, so `bonded` stays false and
    /// `activeConnection` never trips — which left the console reading "stream not yet trusted" for a
    /// perfectly good ring stream. The status copy below treats this as a trusted live stream; the
    /// bond-only feature gates (buzz, alarm, HRV snapshot) keep keying off `activeConnection`. (#69 twin.)
    private var ringStreaming: Bool { live.connected && live.streamingLiveHR }

    /// The display name of the active device from the registry ("WHOOP", a strap's nickname, …) — what
    /// the user is connected to, or would connect to. Falls back to "WHOOP" before the registry opens or
    /// when none is resolvable, keeping the WHOOP-first tone. Drives the active-device readout + copy.
    private var activeDeviceName: String {
        guard let registry = model.deviceRegistry,
              let active = registry.devices.first(where: { $0.id == registry.activeDeviceId })
        else { return "WHOOP" }
        return active.displayName
    }

    /// Live workout mode (#238) — presents the full in-exercise screen while a manual workout is
    /// active. Auto-opens when a workout begins; closing just hides it (the workout keeps recording).
    @State private var showLiveWorkout = false
    @State private var showStartSport = false
    @State private var confirmingEndWorkout = false

    /// Manual HRV snapshot (#127) — presents the "Take an HRV reading" screen as a sheet. Entry sits in
    /// the Session console and is only enabled while bonded (the reading needs the live R-R stream).
    @State private var showHRVSnapshot = false

    var body: some View {
        ScreenScaffold(title: nil) {
            NoopScreenHeader("Live") { moreMenu }
                .padding(.bottom, 6)
            LiveHeartHero(activeIsWhoop: activeIsWhoop, activeIsOura: activeIsOura)
            notices
            NoopSectionTitle("Live physiology", captionKey: "Beat by beat")
            LivePhysiology(activeIsWhoop: activeIsWhoop, cardOpacity: cardOpacity)
            LiveSignalTrustRail(activeConnection: activeConnection, activeIsWhoop: activeIsWhoop,
                                cardOpacity: cardOpacity)
            sessionSection
            strapSection
        }
        .noopHidesSystemNavBar()
        .onAppear { refreshLiveSession(); consumeActiveWorkoutRequest() }
        .onDisappear { model.stopRealtimeHR() }
        // A fresh bond/connection re-arms the BLE stream (Apple must re-send startRealtime on a new
        // connection) WITHOUT bumping the ref-count — `refreshLiveSession`'s `startRealtimeHR` already
        // counted this screen once on `.onAppear`, balanced by the single `stopRealtimeHR` above.
        // Re-counting here (multiple bonded/connected events per appearance, one disappear) would leave
        // the stream stuck armed after leaving Live (#681 ref-count balance).
        .onChangeCompat(of: live.bonded) { _ in reconnectLiveSession() }
        .onChangeCompat(of: live.connected) { _ in reconnectLiveSession() }
        // Live workout mode (#238): open the in-exercise screen the moment a workout starts.
        .onChangeCompat(of: model.activeWorkout != nil) { active in if active { showLiveWorkout = true } }
        .liveWorkoutCover(isPresented: $showLiveWorkout) {
            LiveWorkoutView(onClose: { showLiveWorkout = false })
                .environmentObject(model)
                .environmentObject(live)
        }
        // Pick a named sport before starting (#519) — the live workout view then opens
        // off the activeWorkout change above, so no extra navigation is needed here.
        .workoutSelectionCover(isPresented: $showStartSport) {
            StartWorkoutSheet { name in model.startWorkout(sport: name) }
        }
        // Manual HRV snapshot (#127) — a still, seated 60s R-R reading.
        .sheet(isPresented: $showHRVSnapshot) {
            // Tell the reading where its R-R is coming from so the caveat is honest (#537): a WHOOP 5/MG
            // derives R-R from the optical pulse signal (noisier) while a WHOOP 4 / chest strap is
            // electrical R-R. Driven off the picked strap model, mirroring the Android twin.
            HRVSnapshotView(onClose: { showHRVSnapshot = false }, source: hrvSnapshotSource)
                .environmentObject(model)
                .environmentObject(live)
        }
        .alert("End this workout?", isPresented: $confirmingEndWorkout) {
            Button("Cancel", role: .cancel) { }
            Button("End workout", role: .destructive) {
                model.endWorkout()
            }
        } message: {
            Text("This stops recording and saves what's captured so far. It can't be resumed.")
        }
    }

    // MARK: - Header menu

    /// The header's overflow: the actions that used to sit as loose buttons (Refresh, Re-scan) plus the
    /// Devices shortcut, so the screen body stays the frame's single column.
    private var moreMenu: some View {
        Menu {
            Button { model.getBattery() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(!activeConnection)
            if activeIsWhoop && live.connected {
                Button { model.scan(model: selectedModel) } label: {
                    Label("Re-scan", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
            Button { router.openDevices() } label: {
                Label("Manage devices", systemImage: "badge.plus.radiowaves.right")
            }
        } label: {
            NoopCircleIcon("dots-three")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("More"))
    }

    // MARK: - Notices and connect callouts

    /// Guidance that only appears when something needs the user: the re-pair steps, the bond-refused
    /// how-to, the low-bandwidth note and the above-the-fold connect affordances. Sits directly under the
    /// hero so it is seen before the readouts it explains.
    @ViewBuilder private var notices: some View {
        // Can't-connect-at-all guidance: the strap wiped its bond (firmware update / WHOOP app
        // re-bond), so connects loop on "Peer removed pairing information". Show the re-pair steps
        // right here instead of silently retrying. (5/MG firmware reset, 2026-06)
        if let guide = live.reconnectGuide { reconnectGuideBanner(guide) }
        // Bond-refused guidance, shown right here on Live where people actually connect (it
        // also appears in Settings). A 5/MG strap still bonded to the WHOOP app refuses pairing
        // with "Encryption is insufficient" — this tells the user to free it and re-pair.
        if let hint = live.pairingHint { pairingHintBanner(hint) }
        // Primary Connect affordance, surfaced above the fold whenever there's no link. Gated purely on
        // `!live.connected`, so it disappears the instant the radio connects.
        // WHOOP only (#2305): under a ring this card named the ring over a button that ran a
        // WHOOP scan — the #2303 reporter's Re-scan ran a full 5/MG handshake with the ring active.
        if activeIsWhoop, !live.connected { offlineConnectCallout }
        // The ring's own above-the-fold affordance: its link phase and a reconnect, shown until
        // `auth OK` — the same "no link yet" slot the WHOOP callout fills.
        if activeIsOura, ringPhase != .authenticated { ringConnectCallout }
        // Low-bandwidth fallback note (#80): the radio couldn't sustain the WHOOP 4 R10/R11 raw
        // realtime burst, so live HR is riding the standard BLE Heart-Rate profile instead. Live HR
        // still works — this is informational, not an error.
        if Self.shouldShowStandardHRNote(live.standardHRMode) {
            standardHRNote(live.standardHRMode ?? "")
        }
    }

    /// One v2 notice card: an icon, a 15 pt title and the explanation in secondary ink. No coloured
    /// border — the icon carries the state.
    private func noticeCard(icon: String, title: Text, detail: Text, footnote: Text? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PhIcon(icon, size: 18)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                title.font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                detail.font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let footnote {
                    footnote.font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .ltCard(opacity: cardOpacity)
        .accessibilityElement(children: .combine)
    }

    private func reconnectGuideBanner(_ guide: String) -> some View {
        noticeCard(icon: "warning",
                   title: Text("Can't connect: your strap's pairing was reset"),
                   detail: Text(guide))
            .accessibilityLabel("Reconnect help: \(guide)")
    }

    private func pairingHintBanner(_ hint: String) -> some View {
        noticeCard(icon: "warning",
                   title: Text("Live HR works. Free the strap to unlock buzz, alarms & sync"),
                   detail: Text(hint))
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

    /// Calm inline note for the #80 low-bandwidth fallback. Unlike the pairing/reconnect notices this is
    /// NOT a warning — live HR is working — so it carries a broadcast glyph rather than the warning one.
    private func standardHRNote(_ detail: String) -> some View {
        noticeCard(icon: "broadcast",
                   title: Text("Standard HR mode (low bandwidth)"),
                   detail: Text(detail),
                   footnote: Text("Other metrics (R-R, frames, battery, history) need a full sync."))
            .accessibilityLabel("Standard HR mode, low bandwidth. \(detail)")
    }

    /// The above-the-fold primary Connect affordance, shown only while `!live.connected`: names the band
    /// Scan will connect to and carries the same `scanButton` the Strap card shows, so the offline state
    /// has an obvious action up top.
    private var offlineConnectCallout: some View {
        VStack(alignment: .leading, spacing: 14) {
            NoopCardHeader("Start a live stream", icon: "bluetooth")
            // Name the band Scan will connect to, and point pairing/switching at Devices — so
            // an offline user knows both what this button does and where to add a different band.
            Text("Scan connects to \(activeDeviceName). To pair or switch bands, open Devices.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            scanButton
        }
        .ltCard(opacity: cardOpacity)
    }

    /// The ring's above-the-fold card while it is not yet authenticated: the honest phase line and the
    /// only ring reconnect in the app. Same slot and shape as `offlineConnectCallout`, which is WHOOP-only.
    private var ringConnectCallout: some View {
        VStack(alignment: .leading, spacing: 14) {
            NoopCardHeader(verbatim: LiveRingCopy.status(ringPhase, streaming: false), icon: "bluetooth") {
                EmptyView()
            }
            Text("Reconnect drops the current link, if any, and connects to the ring again. To pair or switch bands, open Devices.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ringReconnectButton
        }
        .ltCard(opacity: cardOpacity)
    }

    // MARK: - Session (record / inspect the current stream)

    private var sessionCaption: LocalizedStringKey {
        guard let w = model.activeWorkout else { return "No workout running" }
        return w.isPaused ? "Paused" : "Recording"
    }

    @ViewBuilder private var sessionSection: some View {
        NoopSectionTitle("Session", captionKey: sessionCaption)
        if let w = model.activeWorkout {
            activeWorkoutCard(w)
        }
        sessionTiles
        if model.activeWorkout == nil, let last = model.lastWorkout {
            workoutSavedRow(last)
        }
    }

    /// The 2 × 2 session grid. The lead tile starts a workout, or pauses / resumes the running one; the
    /// End tile is only live while there is something to end, and sits away from the lead tile so a
    /// destructive tap is never adjacent to a routine one.
    private var sessionTiles: some View {
        let workout = model.activeWorkout
        return Grid(horizontalSpacing: NoopMetrics.gap, verticalSpacing: NoopMetrics.gap) {
            GridRow {
                if let w = workout {
                    LTActionTile(w.isPaused ? "Resume" : "Pause",
                                 caption: w.isPaused ? "Recording is paused" : "Recording",
                                 icon: w.isPaused ? "play" : "pause", primary: true) {
                        model.toggleWorkoutPause()
                    }
                } else {
                    LTActionTile("Start workout",
                                 caption: activeConnection ? "Pick a sport" : "Connect a strap first",
                                 icon: "play", primary: true) {
                        showStartSport = true
                    }
                    .disabled(!activeConnection)
                    .help("Track a workout manually. Records heart rate and effort until you end it.")
                }
                // Manual HRV snapshot (#127) — a still, seated 60s R-R reading. Needs the live R-R
                // stream, so it's gated on a bonded connection just like the workout action.
                LTActionTile("HRV reading", caption: "60 s seated", icon: "heart-half") {
                    showHRVSnapshot = true
                }
                .disabled(!activeConnection)
                .help(activeConnection
                      ? "Take a 60-second seated HRV reading from the live R-R stream."
                      : "Connect your strap first. The reading needs the live R-R stream.")
            }
            GridRow {
                // Re-open the full live workout screen (#238) after it's been dismissed.
                LTActionTile("Open live view", caption: "Full screen", icon: "arrows-out-simple") {
                    showLiveWorkout = true
                }
                .disabled(workout == nil)
                LTActionTile("End workout",
                             caption: workout == nil ? "Nothing to end" : "Saves what's captured",
                             icon: "stop-circle") {
                    confirmingEndWorkout = true
                }
                .disabled(workout == nil)
            }
        }
    }

    private func activeWorkoutCard(_ w: AppModel.ActiveWorkout) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(w.isPaused ? StrandPalette.textTertiary : NoopGlow.heart.tint)
                    .frame(width: 7, height: 7)
                // "RECORDING" is a factual claim, and while paused nothing IS being recorded — the
                // sample capture drops every reading. So the label swaps rather than gaining a tag
                // beside it, which would leave the card asserting both at once. Reuses the "Paused"
                // string #1533 already localized.
                Text(w.isPaused ? "Paused" : "RECORDING WORKOUT")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                // Re-render once a second so the elapsed clock ticks without a manual Timer.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(ActiveWorkoutClock.clock(Int(w.elapsed(at: context.date))))
                        .font(StrandFont.value(17))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
            }
            // Live HR / avg / peak / effort — the leaf owns the active workout + AppModel so the 1 Hz
            // stat refresh re-renders only these values, plus the effort track under them.
            ActiveWorkoutLive(workout: w, effortScale: effortScale)
        }
        .ltCard(opacity: cardOpacity)
    }

    private func workoutSavedRow(_ row: WorkoutRow) -> some View {
        let mins = Int((row.durationS ?? 0) / 60)
        let parts = [String(localized: "\(mins) min"), row.avgHr.map { String(localized: "\($0) avg bpm") },
                     row.strain.map { String(localized: "effort \(UnitFormatter.effortDisplay($0, scale: effortScale))") }].compactMap { $0 }
        return HStack(spacing: 8) {
            PhIcon("check-circle", size: 16).foregroundStyle(StrandPalette.textPrimary)
            Text("Workout saved · \(parts.joined(separator: " · "))")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Strap

    @ViewBuilder private var strapSection: some View {
        NoopSectionTitle("Strap") { Text(pairedCaption) }
        strapCard
        LiveLogCard()
        Text("Everything here stays on this phone")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.top, 10)
    }

    /// "1 paired" — how many devices the registry holds.
    private var pairedCaption: String {
        String(localized: "\(model.deviceRegistry?.devices.count ?? 0) paired")
    }

    /// The strap card: which device, its link and charge, the strap-family picker while not streaming,
    /// the connect / buzz / disconnect controls (or the ring's reconnect) and the Devices link.
    private var strapCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            LiveStrapSummary(activeConnection: activeConnection, activeIsWhoop: activeIsWhoop,
                             activeIsOura: activeIsOura, deviceName: activeDeviceName)
            // Show the strap picker whenever we're not actively streaming, so a user with both a
            // WHOOP 4 and a 5/MG can switch between them. (It used to hide once `bonded`, which is
            // sticky across disconnects — so after the first pairing the picker vanished for good.)
            // WHOOP only (#2305): `activeConnection` is false for a ring BY CONSTRUCTION, so without
            // the brand gate the WHOOP picker was shown MORE readily under a ring than under a strap.
            if activeIsWhoop, !activeConnection {
                modelPicker.padding(.top, 18)
            }
            // Scan / Buzz / Disconnect are the WHOOP path (`model.scan` → `BLEManager.connect`, the
            // explicit user-connect that bypasses the #1881 active-device gate on purpose). A ring
            // gets its own row; any other brand keeps the Devices row alone.
            if activeIsWhoop {
                controls.padding(.top, 18)
            } else if activeIsOura {
                ringControls.padding(.top, 18)
            }
            manageDevicesRow.padding(.top, 16)
        }
        .ltCard(opacity: cardOpacity)
    }

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
                    fillsAvailableWidth: true,
                    label: { $0.displayName }
                )
            }
            // Proactive 5/MG guidance: the strap bonds to one host at a time, so if it's still paired in
            // the official WHOOP app a scan here finds nothing. Shown the moment 5/MG is picked — not only
            // after a failed scan (#130) or a bond-refusal (which is the separate `pairingHint` notice).
            if selectedModel == .whoop5mg { whoop5PairingNote }
        }
    }

    private var whoop5PairingNote: some View {
        HStack(alignment: .top, spacing: 8) {
            PhIcon("info", size: 16).foregroundStyle(StrandPalette.textSecondary)
            Text("WHOOP 5.0/MG pairs with one app at a time. If a scan finds nothing, unpair it in the official WHOOP app and fully close that app, then Scan again.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Connected: Buzz + Disconnect side by side (Re-scan lives in the header menu). Offline: the full
    /// width Scan & connect.
    @ViewBuilder private var controls: some View {
        if live.connected {
            HStack(spacing: 10) {
                buzzButton
                disconnectButton
            }
        } else {
            scanButton
        }
    }

    /// The ring's row in the `controls` slot: one primary action. No Buzz (the ring has no haptic) and no
    /// Disconnect (a stopped ring source would not reconnect for the night; Devices is where a ring is
    /// deactivated).
    private var ringControls: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
            Text(LiveRingCopy.status(ringPhase, streaming: ringStreaming))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ringReconnectButton
        }
    }

    /// Drops the current ring link, if any, and connects again — `OuraLiveSource.reconnect()` through the
    /// coordinator, so it can only reach the ring that is the live source. Enabled in every phase: a ring
    /// parked in `.authenticating` (#2303) is exactly the case this exists for.
    private var ringReconnectButton: some View {
        LTActionButton("Reconnect ring", icon: "arrow-clockwise", kind: .primary, height: 46, fontSize: 14) {
            model.reconnectOuraRing()
        }
    }

    private var scanButton: some View {
        LTActionButton(live.connected ? "Re-scan" : "Scan & connect", icon: "bluetooth", kind: .primary,
                       height: 46, fontSize: 14) {
            model.scan(model: selectedModel)
        }
    }

    private var buzzButton: some View {
        LTActionButton("Buzz strap", icon: "vibrate", height: 46, fontSize: 14) {
            // #921: the confirmed one-shot sequence (pattern + RUN_ALARM, acked). A bare pattern
            // write here was the same silent no-buzz path the Siri shortcut hit on a WHOOP 4.0.
            model.buzzStrapOnce()
        }
        .disabled(!activeConnection)
        .help("Fire a test haptic buzz on the strap (requires an active strap connection)")
    }

    private var disconnectButton: some View {
        LTActionButton("Disconnect", icon: "bluetooth-slash", height: 46, fontSize: 14) {
            model.disconnect()
        }
        .disabled(!live.connected)
    }

    /// A persistent "where to pair / switch bands" row at the foot of the strap card. It sends the user to
    /// the first-class Devices manager and stays one tap away in every connection state. The shell routes
    /// the request via `NavRouter` — macOS selects the Devices sidebar item, iOS presents the Devices screen.
    private var manageDevicesRow: some View {
        Button { router.openDevices() } label: {
            HStack(spacing: 6) {
                Text("Manage devices")
                    .font(StrandFont.book(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                Text("Pairing, firmware info")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                PhIcon("caret-right", size: 16)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .opacity(0.5)
            }
            .padding(.top, 14)
            .overlay(alignment: .top) { LTHairline() }
            .contentShape(Rectangle())
        }
        .buttonStyle(LTPressStyle())
        .accessibilityLabel("Manage devices")
        .accessibilityValue(Text(manageDevicesDetail))
        .accessibilityHint("Opens the Devices screen, where you pair and switch bands.")
    }

    /// Names the active band and reads correctly whether it's the live link ("Connected to …") or just the
    /// band Scan would target ("… is your active band"). Spoken as the Manage-devices row's value.
    private var manageDevicesDetail: String {
        activeConnection
            ? String(localized: "Connected to \(activeDeviceName). Pair or switch bands in Devices.")
            : String(localized: "\(activeDeviceName) is your active band. Pair or switch bands in Devices.")
    }

    // MARK: - Stream lifecycle

    /// Live tab appeared: take a ref-count on the realtime stream (arms it on the 0→1 edge) and pull a
    /// battery reading. Balanced by the single `stopRealtimeHR()` on `.onDisappear`.
    private func refreshLiveSession() {
        guard activeConnection else { return }
        model.startRealtimeHR()
        model.getBattery()
    }

    /// Honour a one-shot "Return to workout" from the Today indicator card: present the in-exercise screen
    /// for an already-running workout, then clear the flag. The #238 "a workout just started" transition
    /// trigger never fires for a session that is already in flight, so this is the path that re-opens it.
    /// Guarded on a live `activeWorkout` so a stale flag can never present an empty live-workout sheet, and
    /// it sets the SAME `showLiveWorkout` one-shot the manual re-open button uses (no new sheet machinery).
    private func consumeActiveWorkoutRequest() {
        guard router.presentActiveWorkout else { return }
        router.presentActiveWorkout = false
        if model.activeWorkout != nil { showLiveWorkout = true }
    }

    /// A fresh bond/connection landed while the Live tab is up: re-arm the BLE stream (Apple re-sends
    /// startRealtime on a new connection) and refresh battery — WITHOUT taking another ref-count, since
    /// these events can fire several times per appearance against the single `.onDisappear` release.
    private func reconnectLiveSession() {
        guard activeConnection else { return }
        model.rearmRealtimeIfWanted()
        model.getBattery()
    }
}

// MARK: - Live leaves (each owns LiveState so a 1 Hz notify re-renders only the leaf — the Today pattern)

/// The heart-glow hero: the live heart rate in the dot-matrix face, its zone and how long it has held
/// it, the last 60 seconds of beats and their average / peak / low. Owns LiveState and AppModel so the
/// ~1 Hz HR notify re-renders only this leaf.
///
/// The minute trace is kept here, in view state, by sampling the smoothed `AppModel.bpm` once a second
/// while a stream is up. It is a display buffer only, plotted by the time each sample was taken: samples
/// age out after 60 s and a dropout stays a visible gap, so the chart never draws a minute it did not see.
private struct LiveHeartHero: View {
    /// Resolved by the parent (#2075); this leaf does not re-derive it.
    let activeIsWhoop: Bool
    /// Resolved by the parent (#2305), same reason.
    let activeIsOura: Bool
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    /// One smoothed sample per second while streaming, oldest first, none older than 60 s.
    @State private var trace: [LiveMinuteSample] = []
    /// The sampling clock — the chart's "now".
    @State private var clock = Date()
    @State private var trackedZone = 0
    @State private var zoneSince: Date?

    /// Smoothed, spike-filtered live HR from AppModel (median over a short window).
    private var displayHR: Int? { model.bpm }
    private var activeConnection: Bool { activeIsWhoop && live.connected && live.bonded }
    private var ringStreaming: Bool { live.connected && live.streamingLiveHR }
    private var streaming: Bool { activeConnection || ringStreaming }

    /// The live HR zone (presentation only). 0 = below Zone 1.
    private var liveZone: Int {
        guard let bpm = displayHR else { return 0 }
        return model.profile.hrZoneSet.zoneNumber(forBPM: Double(bpm))
    }

    var body: some View {
        NoopHeroCard(glow: displayHR == nil ? .ink : .heart, padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge("Heart rate", icon: "heartbeat")
                    Spacer(minLength: 8)
                    statusPill
                }
                number.padding(.top, 30)
                zoneLine.padding(.top, 18)
                LiveMinuteChart(trace: trace, now: clock).frame(height: 96).padding(.top, 18)
                axis.padding(.top, 6)
                minuteStats.padding(.top, 20)
            }
            .padding(.bottom, 2)
        }
        .task { await sample() }
        .onAppear { syncZone() }
        .onChangeCompat(of: liveZone) { _ in syncZone() }
    }

    /// "● Live" while a heart rate is streaming, otherwise where the link stands.
    private var statusPill: some View {
        let isLive = streaming && displayHR != nil
        let label: LocalizedStringKey = isLive ? "Live" : (live.connected ? "Connected" : "Offline")
        return HStack(spacing: 7) {
            Circle()
                .fill(isLive ? Color.white : StrandPalette.textTertiary)
                .frame(width: 6, height: 6)
                .shadow(color: .white.opacity(isLive ? 0.9 : 0), radius: 4)
            Text(label).font(StrandFont.book(12, relativeTo: .caption))
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.18)))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
    }

    private var number: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            Text(verbatim: displayHR.map { "\($0)" } ?? "—")
                .font(StrandFont.dot(104))
                .tracking(StrandFont.dotTracking(104))
                .foregroundStyle(displayHR == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.4), value: displayHR)
            Text("bpm")
                .font(StrandFont.dot(26))
                .tracking(StrandFont.dotTracking(26))
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayHR.map { "Heart rate \($0) beats per minute" } ?? "Heart rate not available")
    }

    /// The zone tag and how long the heart rate has sat in it; before Zone 1 (or with no stream) the
    /// line says what the console can and cannot see instead.
    @ViewBuilder private var zoneLine: some View {
        if liveZone >= 1 {
            HStack(spacing: 10) {
                NoopTag("ZONE \(liveZone)")
                Text(zoneDetail)
                    .font(StrandFont.light(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.86))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        } else {
            Text(signalTrustSummary)
                .font(StrandFont.light(15, relativeTo: .body))
                .foregroundStyle(StrandPalette.textPrimary.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var zoneDetail: String {
        let name = LiveWorkoutView.zoneName(liveZone)
        guard let since = zoneSince else { return name }
        return String(localized: "\(name) · since \(since.formatted(date: .omitted, time: .shortened))")
    }

    private var axis: some View {
        HStack {
            Text("−60 s").foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text("now").foregroundStyle(StrandPalette.textPrimary)
        }
        .overlay { Text("−30 s").foregroundStyle(StrandPalette.textSecondary) }
        .font(StrandFont.footnote)
        .accessibilityHidden(true)
    }

    private var minuteStats: some View {
        let values = trace.map(\.bpm)
        let avg = values.isEmpty ? nil : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
        return HStack(alignment: .top, spacing: 0) {
            heroStat(avg, label: "60 s average")
            heroStat(values.max(), label: "60 s peak")
            heroStat(values.min(), label: "60 s low")
        }
    }

    private func heroStat(_ value: Int?, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value.map { "\($0)" } ?? "—")
                    .font(StrandFont.value(21))
                    .tracking(-0.4)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("bpm")
                    .font(StrandFont.book(10))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Text(label)
                .font(StrandFont.light(10.5))
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Bank one smoothed sample a second while a stream is up and a heart rate is present, and age out
    /// anything older than the 60 s window. No stream or no heart rate banks nothing, which the chart
    /// draws as a gap.
    private func sample() async {
        while !Task.isCancelled {
            let now = Date()
            clock = now
            if streaming, let bpm = model.bpm {
                trace.append(LiveMinuteSample(at: now, bpm: bpm))
            }
            if let first = trace.first, now.timeIntervalSince(first.at) > 60 {
                trace.removeAll { now.timeIntervalSince($0.at) > 60 }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Restart the "since" clock when the zone changes.
    private func syncZone() {
        guard liveZone != trackedZone || zoneSince == nil else { return }
        trackedZone = liveZone
        zoneSince = liveZone >= 1 ? Date() : nil
    }

    private var signalTrustSummary: String {
        if activeConnection && live.encryptedBond { return String(localized: "Encrypted stream: deep controls and history sync available.") }
        if activeConnection { return String(localized: "Live heart rate is flowing; full strap controls need an encrypted bond.") }
        // A ring reads its OWN phase (#2305, #2304): `live.connected` here is whichever source last
        // wrote it, and under a ring parked in the nonce handshake it read "Connected, waiting for a
        // streaming state" for an hour (#2303). The ring's phase is what the console should say.
        if activeIsOura { return LiveRingCopy.status(model.ouraLinkPhase, streaming: live.connected && live.streamingLiveHR) }
        if live.connected { return String(localized: "Connected, waiting for a streaming state.") }
        // The actionable "Scan and connect…" CTA lives in `offlineConnectCallout` below the hero, so this
        // caption stays a calm empty-state descriptor rather than a second, competing CTA.
        return String(localized: "Live heart rate appears here once a strap is connected.")
    }
}

/// One banked heart-rate sample of the hero's minute trace.
private struct LiveMinuteSample: Equatable {
    let at: Date
    let bpm: Int
}

/// The hero's 60-second trace: three faint guides, a white line over a soft white fill, and a dashed
/// "now" cursor with a white dot. Samples sit at their true age on the −60 s … now axis; a gap of more
/// than a few seconds breaks the line rather than bridging it.
private struct LiveMinuteChart: View {
    let trace: [LiveMinuteSample]
    let now: Date

    /// Seconds without a sample after which the line breaks.
    private static let gap: TimeInterval = 4

    var body: some View {
        Canvas { ctx, size in
            for y in [0.29, 0.583, 0.875] {
                ctx.fill(Path(CGRect(x: 0, y: size.height * y, width: size.width, height: 1)),
                         with: .color(.white.opacity(0.08)))
            }
            let segments = self.segments(in: CGSize(width: size.width - 4, height: size.height * 0.94))
            let floorY = size.height * 0.94
            for points in segments where points.count > 1 {
                var fill = Path()
                fill.move(to: CGPoint(x: points[0].x, y: floorY))
                points.forEach { fill.addLine(to: $0) }
                fill.addLine(to: CGPoint(x: points[points.count - 1].x, y: floorY))
                fill.closeSubpath()
                ctx.fill(fill, with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.28), .white.opacity(0)]),
                    startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: floorY)))
                var line = Path()
                line.addLines(points)
                ctx.stroke(line, with: .color(.white),
                           style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
            // The cursor marks the newest sample only while it is current.
            if let last = segments.last?.last, let newest = trace.last, now.timeIntervalSince(newest.at) < Self.gap {
                var cursor = Path()
                cursor.move(to: last)
                cursor.addLine(to: CGPoint(x: last.x, y: floorY))
                ctx.stroke(cursor, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                ctx.fill(Path(ellipseIn: CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7)),
                         with: .color(.white))
            }
        }
        .accessibilityHidden(true)
    }

    /// The samples as runs of points, split wherever consecutive samples are further apart than `gap`.
    private func segments(in size: CGSize) -> [[CGPoint]] {
        guard !trace.isEmpty else { return [] }
        let range = self.range
        let span = max(range.upperBound - range.lowerBound, 1)
        var runs: [[CGPoint]] = []
        var previous: Date?
        for sample in trace {
            let age = min(max(now.timeIntervalSince(sample.at), 0), 60)
            let x = size.width * CGFloat(1 - age / 60)
            let y = size.height * CGFloat(1 - (Double(sample.bpm) - range.lowerBound) / span)
            let point = CGPoint(x: x, y: y)
            if let previous, sample.at.timeIntervalSince(previous) <= Self.gap, !runs.isEmpty {
                runs[runs.count - 1].append(point)
            } else {
                runs.append([point])
            }
            previous = sample.at
        }
        return runs
    }

    /// Headroom above the peak and more room below the low, so the line sits in the upper half like the
    /// design and a steady heart rate does not read as a cliff.
    private var range: ClosedRange<Double> {
        let values = trace.map { Double($0.bpm) }
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let spread = max(hi - lo, 6)
        return (lo - spread * 1.1)...(hi + spread * 0.35)
    }
}

/// The beat-by-beat card: a rolling RMSSD, the last ten R-R intervals as bars, and the freshness line
/// (last frame, last event). Owns LiveState so the ~1 Hz R-R / frame notifies re-render only this leaf.
private struct LivePhysiology: View {
    @EnvironmentObject private var live: LiveState
    /// Resolved by the parent (#2075). Passed rather than observed so this leaf keeps owning only
    /// LiveState, which is what makes the ~1 Hz R-R / frame notifies re-render it alone.
    let activeIsWhoop: Bool
    let cardOpacity: Double

    private var activeConnection: Bool { activeIsWhoop && live.connected && live.bonded }
    /// Oura ring actively streaming live HR — trusted stream without a WHOOP bond (see LiveView.ringStreaming).
    private var ringStreaming: Bool { live.connected && live.streamingLiveHR }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoopCardHeader("Heart rate variability", icon: "wave-sine") { Text(rmssdCaption) }
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(verbatim: rollingRMSSD.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(StrandFont.dot(50))
                    .tracking(StrandFont.dotTracking(50))
                    .foregroundStyle(rollingRMSSD == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                Text("ms").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                Spacer(minLength: 8)
                Text("Live indicator,\nnot a scored HRV")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.top, 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rollingRMSSD.map { "Rolling RMSSD \(Int($0.rounded())) milliseconds" }
                                ?? String(localized: "Waiting for R-R intervals."))
            Text("Recent R-R intervals · ms")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.top, 20)
            rrBars.padding(.top, 16)
            freshness.padding(.top, 16)
        }
        .ltCard(opacity: cardOpacity)
    }

    private var rmssdCaption: String {
        let n = min(12, live.rrRecent.count)
        return n >= 3 ? String(localized: "RMSSD · last \(n) intervals") : String(localized: "RMSSD")
    }

    /// The last ten R-R intervals, scaled between their own min and max; the newest bar carries the
    /// screen's heart accent. Fewer than ten leave the leading slots empty so the bars never stretch.
    private var rrBars: some View {
        let values = Array(live.rrRecent.suffix(10))
        let lo = Double(values.min() ?? 0), hi = Double(values.max() ?? 1)
        let span = max(hi - lo, 1)
        let padCount = max(0, 10 - values.count)
        return ZStack {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<padCount, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    let isNow = i == values.count - 1
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isNow ? NoopGlow.heart.tint : NoopGlow.ink.deep)
                            .frame(height: 10 + 46 * CGFloat((Double(v) - lo) / span))
                        Text(verbatim: "\(v)")
                            .font(StrandFont.light(9.5))
                            .foregroundStyle(isNow ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if values.isEmpty {
                Text("Waiting for R-R intervals.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(height: 74, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(values.isEmpty
            ? String(localized: "Waiting for R-R intervals.")
            : String(localized: "Recent intervals: \(values.suffix(5).map { String($0) }.joined(separator: " · ")) ms"))
    }

    /// Proof the console is current: how long ago the last frame arrived and which event came last. A
    /// glowing dot while a trusted stream is up.
    private var freshness: some View {
        let isLive = activeConnection || ringStreaming
        return HStack(spacing: 8) {
            Circle()
                .fill(isLive ? StrandPalette.textPrimary : NoopVisualStyle.quaternaryText)
                .frame(width: 6, height: 6)
                .shadow(color: .white.opacity(isLive ? 0.7 : 0), radius: 4)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(freshnessLeading(now: context.date))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            Text(freshnessTrailing)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { LTHairline() }
        .accessibilityElement(children: .combine)
    }

    private func freshnessLeading(now: Date) -> String {
        guard activeConnection else { return connectionModeDetail }
        let frame = live.lastFrameType ?? "—"
        guard let at = live.lastFrameAtUnix else { return String(localized: "Frame \(frame)") }
        let ago = max(0, Int(now.timeIntervalSince1970) - at)
        return String(localized: "Frame \(frame) · \(ago) s ago")
    }

    private var freshnessTrailing: String {
        guard activeConnection else { return String(localized: "Offline") }
        return String(localized: "Event \(live.lastEvent ?? "—")")
    }

    /// A "feel" RMSSD over the recent R-R buffer — time-gap-unaware on purpose (a live indicator, not a
    /// clinical figure; it's blanked on disconnect by clearBiometrics). nil until ≥3 intervals land.
    private var rollingRMSSD: Double? {
        let values = Array(live.rrRecent.suffix(12)).map(Double.init)
        guard values.count >= 3 else { return nil }
        let diffs = zip(values.dropFirst(), values).map { $0 - $1 }
        let meanSquare = diffs.map { $0 * $0 }.reduce(0, +) / Double(diffs.count)
        return sqrt(meanSquare)
    }

    private var connectionModeDetail: String {
        if activeConnection && live.encryptedBond { return String(localized: "Full strap stream is active.") }
        if activeConnection || ringStreaming { return String(localized: "Heart rate stream is active.") }
        if live.connected { return String(localized: "Radio connected, stream not yet trusted.") }
        return String(localized: "No live stream.")
    }
}

/// The Signal-trust card: one rail segment per signal that has to be current for the console to be
/// trustworthy (HR, R-R, connection, history sync, battery, wear), a one-line summary, and the full
/// per-signal readout behind the header. Owns LiveState so its 1 Hz refresh re-renders only the card.
private struct LiveSignalTrustRail: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    let activeConnection: Bool
    /// Resolved by the parent (#2075): the battery signal below must describe the ACTIVE device.
    let activeIsWhoop: Bool
    let cardOpacity: Double

    @State private var showsDetails = false

    /// The ACTIVE device's charge, or nil when it has not reported one.
    private var activeBatteryPct: Int? {
        LiveConsoleReadout.batteryPercent(
            activeIsWhoop: activeIsWhoop, whoopPct: live.batteryPct, ringPct: live.ouraBatteryPct,
        )
    }

    private var displayHR: Int? { model.bpm }
    /// Oura ring actively streaming live HR — trusted stream without a WHOOP bond (see LiveView.ringStreaming).
    private var ringStreaming: Bool { live.connected && live.streamingLiveHR }
    /// #218: a live link for the wear stat = a WHOOP bond OR an Oura HR stream. Oura streams only while worn
    /// (PPG needs skin contact) and stops when removed, so `ringStreaming` doubles as its wear signal.
    private var liveLink: Bool { activeConnection || ringStreaming }
    /// Streaming ⟹ worn: keeps a stale `worn=false` (from a prior WHOOP WRIST_OFF, never reset on a source
    /// switch) from reading "Off wrist" while an Oura ring streams. For WHOOP `ringStreaming` is always
    /// false, so this is just `live.worn`. #218.
    private var wornNow: Bool {
        // An Oura ring reports a precise live wear/charge state (live-HR presence + charger STATE + a
        // removal watchdog), so prefer it — it drops to not-worn the moment the ring is off the finger or
        // on the charger, unlike `ringStreaming`, which lingers. WHOOP has no such signal (ouraWearState
        // stays nil), so it keeps the bond-worn / stream fallback. #218.
        if let w = live.ouraWearState { return w == .worn }
        return live.worn || ringStreaming
    }

    var body: some View {
        let signals = self.signals
        let current = signals.filter(\.ok).count
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(StrandMotion.interactive) { showsDetails.toggle() }
            } label: {
                NoopCardHeader("Signal trust", icon: "shield-check") {
                    HStack(spacing: 6) {
                        Text(summary(current: current, total: signals.count))
                            .foregroundStyle(current == signals.count ? StrandPalette.textPrimary
                                                                      : StrandPalette.textSecondary)
                        PhIcon("caret-down", size: 12)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .rotationEffect(.degrees(showsDetails ? 180 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(summary(current: current, total: signals.count)))
            .accessibilityHint(Text(showsDetails ? "Double tap to collapse" : "Double tap to expand"))
            HStack(spacing: 5) {
                ForEach(signals) { signal in
                    Capsule(style: .continuous)
                        .fill(signal.ok ? StrandPalette.textPrimary : NoopGlow.ink.deep)
                        .frame(height: 10)
                }
            }
            .padding(.top, 16)
            .accessibilityHidden(true)
            HStack {
                Text(verbatim: "\(wearSignal.value) · \(connectionSignal.value)")
                Spacer(minLength: 8)
                Text(verbatim: historySignal.value)
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.top, 10)
            if showsDetails {
                VStack(spacing: 0) {
                    ForEach(signals) { signal in
                        LTHairline()
                        signalRow(signal)
                    }
                }
                .padding(.top, 14)
                .transition(.opacity)
            }
        }
        .ltCard(opacity: cardOpacity)
    }

    private func summary(current: Int, total: Int) -> String {
        if current == total { return String(localized: "All signals current") }
        if current == 0 { return String(localized: "No live signal") }
        return String(localized: "\(current) of \(total) current")
    }

    private func signalRow(_ signal: Signal) -> some View {
        HStack(spacing: 12) {
            PhIcon(signal.icon, size: 16)
                .foregroundStyle(signal.ok ? StrandPalette.textPrimary : StrandPalette.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: signal.title)
                    .font(StrandFont.book(13.5, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: signal.detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(verbatim: signal.value)
                .font(StrandFont.caption)
                .foregroundStyle(signal.ok ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(signal.title): \(signal.value). \(signal.detail)")
    }

    private var rollingRMSSD: Double? {
        let values = Array(live.rrRecent.suffix(12)).map(Double.init)
        guard values.count >= 3 else { return nil }
        let diffs = zip(values.dropFirst(), values).map { $0 - $1 }
        let meanSquare = diffs.map { $0 * $0 }.reduce(0, +) / Double(diffs.count)
        return sqrt(meanSquare)
    }

    private var syncDetail: String {
        if let err = live.lastSyncError { return err }
        if live.backfilling { return String(localized: "\(live.decodedChunksThisSession) decoded, \(live.consoleChunksThisSession) console") }
        return live.lastSyncedAt == nil ? String(localized: "No completed offload yet") : String(localized: "Last offload completed")
    }

    struct Signal: Identifiable {
        let title: String
        let value: String
        let detail: String
        let icon: String
        /// Whether this signal is current enough for the console to be trusted.
        let ok: Bool
        var id: String { title }
    }

    private var connectionSignal: Signal {
        .init(title: String(localized: "Connection"),
              value: activeConnection && live.encryptedBond ? String(localized: "Encrypted") : activeConnection ? String(localized: "Partial") : ringStreaming ? String(localized: "Streaming") : live.connected ? String(localized: "Connected") : String(localized: "Offline"),
              detail: activeConnection && live.encryptedBond ? String(localized: "Controls unlocked") : ringStreaming ? String(localized: "Authenticated ring stream") : String(localized: "Standard HR is not a full bond"),
              icon: "lock-simple",
              ok: (activeConnection && live.encryptedBond) || ringStreaming)
    }

    private var historySignal: Signal {
        .init(title: String(localized: "History sync"),
              value: live.backfilling ? String(localized: "\(live.syncChunksThisSession) chunks") : LiveSyncFormat.lastSyncLabel(live.lastSyncedAt),
              detail: syncDetail,
              icon: "clock-counter-clockwise",
              ok: live.lastSyncError == nil && (live.backfilling || live.lastSyncedAt != nil))
    }

    // Wear is only trustworthy on a live link: `worn` defaults true (LiveState) and is only
    // updated by WRIST_ON/OFF events, so while OFFLINE it would otherwise read a false-green
    // "On wrist". Gate the value AND state on a live link (triage fix for PR#191).
    // #218: `liveLink` includes an Oura HR stream, not just a WHOOP bond — an Oura ring streams
    // with no bond, so this read "Unknown" mid-stream. Oura emits PPG HR only while worn (and stops
    // when removed), so the stream itself is the wear signal; `worn` stays at its default true for
    // Oura until its WEAR_EVENT is wired to `worn` (follow-up).
    private var wearSignal: Signal {
        .init(title: String(localized: "Wear state"),
              value: liveLink ? (wornNow ? String(localized: "On wrist") : String(localized: "Off wrist")) : String(localized: "Unknown"),
              detail: liveLink ? (wornNow ? String(localized: "Eligible for live physiology") : String(localized: "Wear the strap for scoring")) : String(localized: "Connect to read wear state"),
              icon: "hand",
              ok: liveLink && wornNow)
    }

    private var signals: [Signal] {
        [
            .init(title: String(localized: "Heart rate"),
                  value: displayHR.map { "\($0) bpm" } ?? String(localized: "Missing"),
                  detail: (activeConnection || ringStreaming) ? String(localized: "Streaming now") : String(localized: "No active stream"),
                  icon: "heartbeat",
                  ok: displayHR != nil),
            .init(title: String(localized: "R-R intervals"),
                  value: live.rrRecent.isEmpty ? String(localized: "Missing") : String(localized: "\(live.rrRecent.count) recent"),
                  detail: rollingRMSSD.map { String(localized: "RMSSD \(Int($0.rounded())) ms") } ?? String(localized: "Needs interval frames"),
                  icon: "wave-sine",
                  ok: !live.rrRecent.isEmpty),
            connectionSignal,
            historySignal,
            .init(title: String(localized: "Battery"),
                  value: activeBatteryPct.map { "\($0)%" } ?? String(localized: "Unknown"),
                  // "by strap" only when a strap is what reported it (#2075).
                  detail: live.charging == true ? String(localized: "Charging")
                          : activeIsWhoop ? String(localized: "Last reported by strap")
                          : String(localized: "Last reported by the ring"),
                  icon: "battery-medium",
                  ok: (activeBatteryPct ?? 0) > 15),
            wearSignal,
        ]
    }
}

/// The strap card's identity row: the device, its link state and last sync, and its charge on a ring.
/// Owns LiveState so battery / sync updates re-render only this row.
private struct LiveStrapSummary: View {
    @EnvironmentObject private var live: LiveState
    let activeConnection: Bool
    /// Resolved by the parent (#2075), so the charge below can belong to the device being named.
    let activeIsWhoop: Bool
    let activeIsOura: Bool
    let deviceName: String
    /// Oura ring actively streaming live HR — trusted stream without a WHOOP bond (see LiveView.ringStreaming).
    private var ringStreaming: Bool { live.connected && live.streamingLiveHR }

    /// The ACTIVE device's charge (#2075). A non-WHOOP active device never falls back to the strap's
    /// number: nothing is drawn, where the strap's charge under the ring's name is a confident lie, and
    /// was exactly what the report saw.
    private var batteryPct: Int? {
        LiveConsoleReadout.batteryPercent(
            activeIsWhoop: activeIsWhoop, whoopPct: live.batteryPct, ringPct: live.ouraBatteryPct,
        )
    }

    /// Distinguish a GENUINE encrypted bond from the 5/MG live-HR shortcut that flips `bonded` true over
    /// the unbonded standard profile (#69): "Bonded · streaming" only when encryptedBond, "Live HR (not
    /// fully paired)" otherwise. The pairing notice gives the how-to.
    private var linkLabel: String {
        (activeConnection && live.encryptedBond) ? String(localized: "Bonded · streaming")
            : activeConnection ? String(localized: "Live HR (not fully paired)")
            : ringStreaming ? String(localized: "Streaming")
            : live.connected ? String(localized: "Connected")
            : live.encryptedBond ? String(localized: "Paired · idle")
            : String(localized: "Disconnected")
    }

    private var syncLabel: String {
        if live.backfilling { return String(localized: "Syncing \(live.syncChunksThisSession) chunks") }
        return String(localized: "Last sync \(LiveSyncFormat.lastSyncLabel(live.lastSyncedAt))")
    }

    var body: some View {
        HStack(spacing: 14) {
            PhIcon(activeIsOura ? "circle" : "watch", size: 18)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NoopVisualStyle.raised))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: deviceName)
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                (Text(verbatim: linkLabel).foregroundColor(StrandPalette.textPrimary)
                 + Text(verbatim: " · \(syncLabel)").foregroundColor(StrandPalette.textTertiary))
                    .font(StrandFont.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let pct = batteryPct {
                HStack(spacing: 8) {
                    NoopRingGauge(fraction: Double(pct) / 100, lineWidth: 3, showsKnob: false)
                        .frame(width: 34, height: 34)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(verbatim: "\(pct)").font(StrandFont.value(17))
                        Text(verbatim: "%").font(StrandFont.book(10)).foregroundStyle(StrandPalette.textSecondary)
                    }
                    .foregroundStyle(StrandPalette.textPrimary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Battery"))
                .accessibilityValue(Text(verbatim: live.charging == true ? "\(pct)%, " + String(localized: "Charging") : "\(pct)%"))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The active-workout live stats (HR / avg / peak / effort) + the effort track. Owns AppModel so the
/// 1 Hz HR/effort refresh re-renders only this block.
private struct ActiveWorkoutLive: View {
    @EnvironmentObject private var model: AppModel
    let workout: AppModel.ActiveWorkout
    let effortScale: EffortScale

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NoopMetricRow {
                NoopMetric(value: model.bpm.map { "\($0)" } ?? "—", unit: "bpm", label: "HR")
                NoopMetric(value: workout.avgHr > 0 ? "\(workout.avgHr)" : "—", unit: "bpm", label: "Avg")
                NoopMetric(value: workout.peakHr > 0 ? "\(workout.peakHr)" : "—", unit: "bpm", label: "Peak")
                NoopMetric(value: UnitFormatter.effortDisplay(workout.liveStrain, scale: effortScale), label: "Effort")
            }
            // The live effort as a fraction of the 0–100 strain axis.
            NoopTrack(fraction: max(0, min(1, workout.liveStrain / 100)), height: 10)
        }
    }
}

/// The strap log + export controls + Test Centre link.
///
/// This observes `LiveState` rather than scoping anything: a published change there invalidates every
/// observer, so what this card controls is the COST of its own re-evaluation, not whether it happens.
private struct LiveLogCard: View {
    /// How many trailing lines the card RENDERS. The buffer stays `LiveState.maxLogLines` (5,000) and Copy /
    /// Save / the export still read all of it, so nothing is lost by drawing less.
    ///
    /// #2521: this card used to render the whole buffer in a non-lazy `VStack`, so every appended line built
    /// and diffed up to 5,000 rows while the visible viewport is a handful of lines. A history drain plus a
    /// re-score burst emits hundreds of lines a minute, and the 80%-of-a-core CPU limit is per process, so
    /// that cost landed on the main thread and the app was killed with `cpu_resource_fatal` while it was not
    /// even frontmost.
    private static let renderedTailLines = 200
    /// The log viewport: about six wrapped lines of 11 pt mono.
    private static let logHeight: CGFloat = 112

    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var model: AppModel
    /// Backgrounded, nothing is on screen to keep current, and a `LiveState` publish still re-evaluates this
    /// body because an `ObservableObject` invalidates every observer on ANY published change, not only the
    /// property a view reads. So what is cut is the COST of that re-evaluation, which is what the CPU limit
    /// measures: roughly fifteen built rows instead of five thousand, and none at all here.
    ///
    /// Not free, to be exact about what remains: the header, the divider and the `NavigationLink` are still
    /// built per line, and `NavigationLink(destination:)` constructs `TestCentreView()` eagerly, which
    /// evaluates its `@State` defaults (three `UserDefaults` reads). Microseconds against the five thousand
    /// `Text` views this removes, but the place to look first if a background cost survives this.
    ///
    /// Gated on `.background` rather than `!= .active` deliberately: `.inactive` is also when iOS takes the
    /// app-switcher snapshot, and blanking the log there would be visible for no benefit. The kill needs
    /// sustained non-frontmost CPU, which is `.background`.
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Export the log so people can attach it to a bug report (issue #17 — macOS users had no way
            // to share it). Copy → clipboard; Save… → a .txt file. Where the labels are long (German) the
            // pills drop their icons rather than truncate the words.
            ViewThatFits(in: .horizontal) {
                logHeader(showsIcons: true)
                logHeader(showsIcons: false)
            }
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.bottom, 14)
            if scenePhase == .background {
                // Same height so returning to the app does not shift the card's layout.
                Color.clear.frame(height: Self.logHeight)
            } else {
                logScroller
            }

            // Users look on Live first when something's wrong (#507/#509), so link straight into the
            // Test Centre diagnostic home, one tap from the log.
            NavigationLink(destination: TestCentreView()) {
                HStack(spacing: 8) {
                    PhIcon("test-tube", size: 16)
                    Text("Open Test Centre to report a bug")
                        .font(StrandFont.book(14, relativeTo: .subheadline))
                    Spacer(minLength: 8)
                    PhIcon("caret-right", size: 16).opacity(0.5)
                }
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.top, 14)
                .overlay(alignment: .top) { LTHairline() }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
            .accessibilityLabel("Open Test Centre")
        }
        .ltCard(opacity: cardOpacity)
    }

    private func logHeader(showsIcons: Bool) -> some View {
        HStack(spacing: 8) {
            PhIcon("terminal-window", size: 16).opacity(0.9)
            Text("Strap log").font(StrandFont.book(14, relativeTo: .subheadline)).lineLimit(1)
            Spacer(minLength: 8)
            LTSmallButton("Copy", icon: showsIcons ? "copy" : nil) { copyStrapLog() }
            LTSmallButton("Save…", icon: showsIcons ? "download-simple" : nil) { saveStrapLog() }
        }
    }

    /// The tail of the log, lazily.
    ///
    /// The slice comes from `LiveState.renderedTail`, which snapshots the buffer so a lazily-realized row
    /// cannot index a trimmed array. Its indices are ABSOLUTE positions in `live.log`, which is what makes
    /// them usable as identity: BETWEEN trims, appending a line leaves every other row's id alone, so SwiftUI adds one row
    /// and drops one instead of re-identifying the list. A trim still renumbers, because `Array.removeFirst`
    /// shifts every element down, but that is once per `LiveState.trimSlack` lines and now touches 200 ids
    /// rather than rebuilding 5,000 rows.
    ///
    /// The old `id: \.offset` over `Array(live.log.enumerated())` paid on every line instead: a fresh
    /// 5,000-element array allocated per body evaluation, and a non-lazy `VStack` that built every row even
    /// though the viewport shows a handful.
    ///
    /// `scrollTo` still addresses the true last index, which is always inside the tail.
    private var logScroller: some View {
        let tail = LiveState.renderedTail(live.log, tailLines: Self.renderedTailLines)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(tail.indices, id: \.self) { idx in
                        Text(tail[idx]).font(StrandFont.mono(11))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                }
            }
            #if os(iOS)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            .frame(height: Self.logHeight)
            // On `logRevision`, not `log.count` (#2547). The revision is monotonic and ticks exactly once per
            // coalesced publish; the count plateaus while the ring trims, so it can stay equal across an
            // append and skip a scroll.
            .onChangeCompat(of: live.logRevision) { _ in
                if let last = live.log.indices.last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    // MARK: - Strap-log export (issue #17 — let macOS users share the log for bug reports)

    // The strap-log text builder lives on LiveState (`exportableLogText()`) so the macOS Settings
    // shortcut shares the exact same output (#17 / #507). These stay as thin wrappers.
    private func copyStrapLog() {
        PlatformPasteboard.copy(live.exportableLogText())
    }

    private func saveStrapLog() {
        Task {
            // Settings (#507) and Test Centre fetch these extras before exporting; without them this
            // site wrote a same-named file silently missing the "Strap & data" + funnel sections, so
            // which button someone pressed changed what a triager received.
            let extra = await DebugDataDiagnostics.dynamicLines(repo: model.repo)
            FileExport.exportText(live.exportableLogText(extraHeaderLines: extra),
                                  suggestedName: FileExport.timestampedName("noop-strap-log", ext: "txt"))
        }
    }
}

// MARK: - Shared sync-label formatting

/// The "last sync" relative-time label — shared between the strap summary and the Signal-trust card so
/// both read identically.
private enum LiveSyncFormat {
    static func lastSyncLabel(_ ts: TimeInterval?) -> String {
        guard let ts else { return String(localized: "Never") }
        let date = Date(timeIntervalSince1970: ts)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Ring status copy (#2305)

/// One line per ring link phase, shared by the hero caption, the above-the-fold callout and the controls
/// row so the three never disagree about what the ring is doing.
enum LiveRingCopy {
    static func status(_ phase: OuraLiveSource.LinkPhase, streaming: Bool) -> String {
        switch phase {
        case .disconnected:   return String(localized: "Ring not connected.")
        case .connecting:     return String(localized: "Connecting to the ring…")
        case .authenticating: return String(localized: "Connected, authenticating…")
        case .authenticated:
            return streaming
                ? String(localized: "Live heart rate is flowing from the ring.")
                : String(localized: "Connected, waiting for live heart rate.")
        }
    }
}
