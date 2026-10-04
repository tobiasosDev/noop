import SwiftUI
import Foundation
import AVFoundation
import Combine
import StrandDesign
import StrandAnalytics

/// HRV haptic breathing biofeedback trainer — Strand's flagship novel feature, now a closed-loop
/// biofeedback instrument with three layers (v5 "the strap that breathes you down").
///
/// The strap both *measures* HRV (via R-R intervals) and *buzzes* (haptic strap motor), so we can pace
/// the user's breath with a felt cue and watch their HRV respond in real time — and now also *find* the
/// user's personal resonance pace (L1) and offer a below-HR "Calm me" metronome (L2). A passive stress
/// check-in card (L3) surfaces when the shipped StressOnsetDetector fires. All layers are opt-in,
/// user-stoppable, and quiet-hours-aware.
///
/// Mode switch:
///  • **Breathe** — the shipped fixed-pace trainer (presets + the locked resonance pill), unchanged.
///  • **Resonance** — the one-time "find your pace" sweep + the dated result card.
///  • **Calm me** — the L2 below-HR relaxation metronome.
///
/// Public entry point keeps its zero-arg init (every existing call site — RootView, RootTabView,
/// StressView — constructs `BreathingView()`), then defers to `BreathingContent` once the environment's
/// `AppModel`/`LiveState` are available so the `BiofeedbackController` `@StateObject` can be built from
/// them. The L3 `StressNudgeCenter` is OPTIONAL via the environment: Wave 3 injects a shared instance;
/// absent that we fall back to a local one, so the view always compiles + the card surface always exists.
struct BreathingView: View {
    var body: some View { BreathingContent() }
}

private struct BreathingContent: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    /// When the user has Reduce Motion on, the large repeating inhale/exhale orb zoom is
    /// suppressed — the breath is cued by the phase word + haptics instead. (a11y)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The L1/L2 session controller (walks the engines, fires the buzz path). View-owned, created lazily
    /// from the environment model + live state on first appear (a `@StateObject` can't read the
    /// environment at init, so we build it in `.onAppear`). Self-contained — the spec's view-specific
    /// controller; it never edits the shared AppModel.
    @StateObject private var controllerBox = ControllerBox()
    /// The L3 passive-nudge surface — Wave 3 injects a shared instance; this local fallback keeps the
    /// card surface present whether or not central wiring has landed.
    @StateObject private var fallbackNudge = StressNudgeCenter()
    @Environment(\.stressNudgeCenter) private var injectedNudge

    private var controller: BiofeedbackController { controllerBox.controller(model: model, live: live) }
    private var nudgeCenter: StressNudgeCenter { injectedNudge ?? fallbackNudge }

    // MARK: Mode

    private enum Mode: Hashable, CaseIterable {
        case breathe, resonance, calm
        var label: String {
            switch self {
            case .breathe:   return String(localized: "Breathe")
            case .resonance: return String(localized: "Resonance")
            case .calm:      return String(localized: "Calm me")
            }
        }
    }
    @State private var mode: Mode = .breathe

    // MARK: Pace presets (catalog + locked resonance)

    private enum PaceSelection: Hashable {
        case catalog(String)
        case resonance

        var label: String {
            switch self {
            case .catalog(let id):
                return String(localized: String.LocalizationValue(
                    BreathProtocolCatalog.protocolById(id)?.title ?? id))
            case .resonance:
                return String(localized: "Resonance")
            }
        }
    }

    private enum SessionLength: Hashable, CaseIterable {
        case open, five, ten, fifteen

        var label: String {
            switch self {
            case .open: return String(localized: "Open")
            case .five: return String(localized: "5 min")
            case .ten: return String(localized: "10 min")
            case .fifteen: return String(localized: "15 min")
            }
        }

        var targetSeconds: Int? {
            switch self {
            case .open: return nil
            case .five: return 5 * 60
            case .ten: return 10 * 60
            case .fifteen: return 15 * 60
            }
        }

        static func from(recommendedMs: Int) -> SessionLength {
            switch recommendedMs {
            case ..<(7 * 60_000): return .five
            case ..<(12 * 60_000): return .ten
            default: return .fifteen
            }
        }
    }

    private enum Phase { case inhale, hold, exhale, textOnly }

    // MARK: State (fixed-pace Breathe — catalog-driven)

    @State private var pace: PaceSelection = .catalog("coherence_5_5")
    @State private var sessionLength: SessionLength = .ten
    @State private var showEdu = false
    @State private var running = false

    /// 0 = fully contracted, 1 = fully expanded. Drives the orb scale.
    @State private var orbProgress: CGFloat = 0
    @State private var phase: Phase = .inhale
    @State private var phaseLabel: String? = nil
    @State private var stageIndex: Int = 0
    @State private var phaseDeadline: Date = .distantFuture

    @State private var sessionSeconds: Int = 0
    @State private var breathCount: Int = 0

    /// Rolling buffer of the most recent R-R intervals (ms) for RMSSD.
    @State private var rrBuffer: [Int] = []
    @State private var rmssd: Double? = nil

    @State private var baselineRmssd: Double? = nil
    @State private var sessionRmssdSum: Double = 0
    @State private var sessionRmssdCount: Int = 0
    @State private var sessionRmssdPeak: Double = 0
    @State private var endedOutcome: String? = nil

    @AppStorage("breathe.lastOutcome") private var lastStoredOutcome = ""

    /// Opt-in audio pacer — a soft tone at each phase change (rising on the inhale, falling on the
    /// exhale). Default OFF (manual-first). The tones go through an ambient session category, so the
    /// iOS silent switch mutes them like any other ambient sound. Persists across launches.
    @AppStorage("breathe.audioCues") private var audioCues = false
    /// The strap's breathing-pacer buzz (default on) — the same key the Automations toggle writes, so the
    /// two switches are one setting.
    @AppStorage(HapticPrefs.breathing) private var breathingHaptic = true
    /// The on-device tone player. View-owned, lazily wired the first time the pacer is enabled, torn
    /// down on disappear so we never hold the audio session when off-screen.
    @StateObject private var tonePlayer = BreathTonePlayer()

    private let phaseTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    private let secondTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private let rrWindow = 30

    /// The user's locked resonance pace, read fresh each render (set by the sweep).
    private var lockedBpm: Double? { BiofeedbackPrefs.lockedPace }

    private var selectedProtocol: BreathProtocol? {
        if case .catalog(let id) = pace { return BreathProtocolCatalog.protocolById(id) }
        return nil
    }

    private var isGuided: Bool { selectedProtocol?.mode == .guided }

    private var selectedBpm: Double {
        if case .resonance = pace {
            return lockedBpm ?? ResonanceEngine.fallbackBpm
        }
        guard let proto = selectedProtocol, proto.cycleDurationMs > 0 else { return 0 }
        return 60_000.0 / Double(proto.cycleDurationMs)
    }

    private var selectedTagline: String {
        if case .resonance = pace {
            return String(localized: "Your locked pace · \(Self.decimal(lockedBpm ?? ResonanceEngine.fallbackBpm)) br/min")
        }
        return String(localized: String.LocalizationValue(selectedProtocol?.subtitle ?? ""))
    }

    var body: some View {
        ScreenScaffold(title: nil) {
            header
            modeSwitch
                .padding(.top, 6)
            StressCheckInCard(center: nudgeCenter) { startOneMinuteCue() }

            switch mode {
            case .breathe:   breatheMode
            case .resonance: ResonanceModeView(controller: controller, live: live, lockedBpm: lockedBpm)
            case .calm:      CalmModeView(controller: controller, live: live, model: model)
            }
        }
        .noopHidesSystemNavBar()
        .onReceive(phaseTimer) { now in
            guard running else { return }
            advance(now: now)
        }
        .onReceive(secondTimer) { _ in
            guard running else { return }
            sessionSeconds += 1
            if let target = sessionLength.targetSeconds, sessionSeconds >= target {
                stop()
            }
        }
        // rrSeq-keyed: equal consecutive packets both count (see RRPacketObserver.swift).
        .onRRPackets(live) { rr in
            ingest(rr)
        }
        .onChangeCompat(of: pace) { newPace in
            if running { stop() }
            if case .catalog(let id) = newPace,
               let proto = BreathProtocolCatalog.protocolById(id) {
                sessionLength = SessionLength.from(recommendedMs: proto.recommendedDurationMs)
            }
        }
        .sheet(isPresented: $showEdu) {
            breathEduSheet
        }
        .onChangeCompat(of: mode) { _ in
            // Leaving a mode stops any session it owns so two clocks never run at once.
            if running { stop() }
            controller.stop()
        }
        .onChangeCompat(of: audioCues) { on in
            // Spin the audio engine up the moment the user opts in (so the first phase tone isn't
            // swallowed by start-up latency); tear it back down when they switch it off.
            on ? tonePlayer.activate() : tonePlayer.deactivate()
        }
        .onAppear {
            model.startRealtimeHR()
            controllerBox.prepare(model: model, live: live)
            if audioCues { tonePlayer.activate() }
        }
        .onDisappear { model.stopRealtimeHR(); stop(); controller.stop(); tonePlayer.deactivate() }
    }

    // MARK: - Header + mode switch

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoopScreenHeader(verbatim: "") {
                NoopCircleButton("info", accessibilityLabel: "Protocol info") { showEdu = true }
            }
            .padding(.bottom, 18)
            Text("Breathe")
                .font(StrandFont.title1)
                .tracking(-0.56)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Haptic-paced breathing · find your pace · calm down")
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.top, 6)
        }
    }

    private var modeSwitch: some View {
        SegmentedPillControl(Mode.allCases, selection: $mode, fillsAvailableWidth: true) { $0.label }
            .accessibilityLabel("Breathe mode")
    }

    // MARK: - Breathe mode (the shipped fixed-pace trainer)

    @ViewBuilder private var breatheMode: some View {
        settingsRow(title: "Protocol", caption: protocolCaption)
            .padding(.top, 14)
        pacePills
        settingsRow(title: "Session length", caption: sessionCaption)
            .padding(.top, 14)
        durationPills
        orbHero
            .padding(.top, 8)
        readoutRow
        coherenceCard
        optionsList
        controlButton
            .padding(.top, 8)
        footnote
    }

    /// A small settings label row: a 14 pt secondary label and a caption at the right.
    private func settingsRow(title: LocalizedStringKey, caption: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(StrandFont.book(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Text(verbatim: caption)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
        }
    }

    /// "5.5 breaths a minute" for a paced protocol, "Guided" for a timer-only one.
    private var protocolCaption: String {
        if selectedBpm > 0 { return String(localized: "\(Self.decimal(selectedBpm)) breaths a minute") }
        return isGuided ? String(localized: "Guided") : ""
    }

    /// The live session clock while running ("03:12 / 10:00 · 17 breaths"); before a session, roughly how
    /// many breaths the chosen length holds at this pace (blank for an open or guided session).
    private var sessionCaption: String {
        guard running || sessionSeconds > 0 else {
            guard let target = sessionLength.targetSeconds, selectedBpm > 0 else { return "" }
            return String(localized: "about \(Int((selectedBpm * Double(target) / 60).rounded())) breaths")
        }
        let clock = sessionLength.targetSeconds.map { "\(timeString(sessionSeconds)) / \(timeString($0))" }
            ?? timeString(sessionSeconds)
        return "\(clock) · " + String(localized: "\(breathCount) breaths")
    }

    /// Start a one-minute haptic breathing cue at the user's locked resonance pace when "Use my resonance
    /// pace" is on (else the 5.5 fallback) — the L3 card's "Breathe now" action. Switches to
    /// Resonance/Breathe context and runs the controller.
    private func startOneMinuteCue() {
        if running { stop() }
        let bpm = BiofeedbackPrefs.checkInLockedPace(useResonance: BiofeedbackPrefs.useResonancePace,
                                                     locked: lockedBpm) ?? ResonanceEngine.fallbackBpm
        let cycles = max(1, Int((60.0 * bpm / 60.0).rounded()))   // ~1 minute of breaths
        controller.startResonanceSession(bpm: bpm, cycles: cycles)
    }

    // MARK: - The orb hero

    private var orbHero: some View {
        NoopHeroCard(glow: .stress, padding: 22) {
            VStack(spacing: 0) {
                HStack {
                    NoopIconBadge(verbatim: pace.label, icon: "wind")
                    Spacer(minLength: 8)
                    NoopPill(verbatim: paceCaption, compact: true)
                }
                breathingOrb
                    .frame(height: 300)
                    .padding(.top, 12)
                Text(running ? phaseWord : String(localized: "Ready"))
                    .font(StrandFont.light(21, relativeTo: .title3))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .animation(.easeInOut(duration: 0.2), value: phaseWord)
                    .padding(.top, 4)
                Text(verbatim: running ? sessionCaption : selectedTagline)
                    .font(StrandFont.footnote)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, -2)
            .padding(.bottom, 2)
        }
    }

    private var availablePaces: [PaceSelection] {
        var items = BreathProtocolCatalog.pickerProtocols.map { PaceSelection.catalog($0.id) }
        if lockedBpm != nil { items.append(.resonance) }
        return items
    }

    private var pacePills: some View {
        // The chips run to the screen edge (the column's gutter moves inside the scroll content).
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availablePaces, id: \.self) { p in
                    Button { pace = p } label: { NoopChip(verbatim: p.label, isOn: p == pace) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, NoopMetrics.screenHPadding)
        }
        .padding(.horizontal, -NoopMetrics.screenHPadding)
        .accessibilityLabel("Protocol")
    }

    private var durationPills: some View {
        SegmentedPillControl(SessionLength.allCases, selection: $sessionLength, fillsAvailableWidth: true) { $0.label }
            .disabled(running)
            .accessibilityLabel("Session length")
    }

    private var phaseWord: String {
        if let phaseLabel, !phaseLabel.isEmpty {
            return String(localized: String.LocalizationValue(phaseLabel))
        }
        switch phase {
        case .inhale: return String(localized: "Breathe in…")
        case .hold: return String(localized: "Hold…")
        case .exhale: return String(localized: "Breathe out…")
        case .textOnly: return String(localized: "Follow the cue…")
        }
    }

    private var breathEduSheet: some View {
        VStack(spacing: 0) {
            NoopSheetHeader("About this pace", cancelTitle: "Done", doneTitle: nil, onCancel: { showEdu = false })
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let proto = selectedProtocol {
                        Text(String(localized: String.LocalizationValue(proto.title)))
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(String(localized: String.LocalizationValue(proto.subtitle)))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                        if proto.category == .presence {
                            Text(String(localized: String.LocalizationValue(BreathProtocolCatalog.presenceIntroTitle)))
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(String(localized: String.LocalizationValue(BreathProtocolCatalog.presenceIntroBody)))
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Text(String(localized: String.LocalizationValue(proto.edu)))
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                        if let hint = proto.sessionHint {
                            Text(String(localized: String.LocalizationValue(hint)))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        if let caution = proto.caution {
                            NoopInsightRow(verbatim: String(localized: String.LocalizationValue(caution)), icon: "warning")
                        }
                        Text(String(localized: "Estimate only — not medical advice. Stop if you feel unwell."))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    } else {
                        Text(String(localized: "Your locked resonance pace from the Resonance sweep."))
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // #697 parity: this sheet builds its OWN ScrollView rather than going through ScreenScaffold,
            // so it carries the scaffold's horizontal-bounce suppression itself. (#1532 follow-up)
            #if os(iOS)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
        }
        .background(NoopSheetBackground())
        #if os(iOS)
        .noopSheetPresentation(largeFirst: false)
        #else
        .frame(width: 480, height: 560)
        #endif
    }

    /// The pacer: three soft concentric rings, a core that swells on the inhale and settles on the
    /// exhale (`orbProgress`), the session-progress ring with its knob, and in the centre the seconds left
    /// in this phase while running (the live heart rate at rest). Under Reduce Motion `orbProgress` parks
    /// at a steady mid-level (no pulsing) and the phase word + haptics carry the pace.
    private var breathingOrb: some View {
        let accent = NoopGlow.stress.accent
        let progress: Double? = sessionLength.targetSeconds.map { min(Double(sessionSeconds) / Double($0), 1) }
        return ZStack {
            ForEach([(296.0, 0.07, 0.08), (236.0, 0.11, 0.13), (178.0, 0.18, 0.2)], id: \.0) { d, fill, stroke in
                Circle()
                    .fill(RadialGradient(colors: [accent.opacity(0), accent.opacity(fill)],
                                         center: .center, startRadius: d * 0.28, endRadius: d / 2))
                    .overlay(Circle().strokeBorder(Color.white.opacity(stroke * 0.8), lineWidth: 1))
                    .frame(width: d, height: d)
            }
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.5), accent.opacity(0.55), NoopGlow.stress.deep.opacity(0.85)],
                                     center: UnitPoint(x: 0.5, y: 0.38), startRadius: 0, endRadius: 63))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                .shadow(color: accent.opacity(0.45), radius: 35)
                .frame(width: 126, height: 126)
                .scaleEffect(0.82 + 0.36 * orbProgress)
            // Session progress ring with a knob at its head.
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 1.5)
                if let progress, progress > 0 {
                    Circle().trim(from: 0, to: progress)
                        .stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Circle().fill(Color.white).frame(width: 9, height: 9)
                        .background(Circle().fill(Color.white.opacity(0.18)).frame(width: 18, height: 18))
                        .offset(y: -102)
                        .rotationEffect(.degrees(360 * progress))
                }
            }
            .frame(width: 204, height: 204)
            centreReadout
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(running ? Text(phaseWord) : Text("Ready"))
    }

    /// The seconds left in the current phase while a paced session runs; the live heart rate otherwise.
    @ViewBuilder private var centreReadout: some View {
        if running && !isGuided {
            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                let left = max(0, Int(ceil(phaseDeadline.timeIntervalSince(ctx.date))))
                NoopDotNumber("\(left)", size: 84)
            }
        } else {
            VStack(spacing: 2) {
                NoopDotNumber(model.bpm.map { "\($0)" } ?? "—", size: 56)
                Text(String(localized: "BPM"))
                    .font(StrandFont.footnote)
                    .tracking(0.8)
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        }
    }

    // MARK: - Controls

    private var controlButton: some View {
        Button {
            running ? stop() : start()
        } label: {
            HStack(spacing: 8) {
                PhIcon(running ? "stop" : "play", weight: .fill, size: 15)
                if running {
                    Text("Stop session")
                } else if let target = sessionLength.targetSeconds {
                    Text("Start · \(target / 60) min")
                } else {
                    Text("Start session")
                }
            }
        }
        .buttonStyle(NoopButtonStyle(running ? .secondary : .primary, fullWidth: true))
    }

    /// Haptic pacing, the opt-in audio pacer and the strap test buzz.
    private var optionsList: some View {
        NoopList {
            NoopRow(title: Text("Haptic pacing"),
                    caption: live.bonded ? Text("Your strap buzzes at each turn") : Text("Visual only"),
                    icon: "vibrate") {
                Toggle("", isOn: $breathingHaptic).labelsHidden().toggleStyle(.noop).fixedSize()
                    .accessibilityLabel("Haptic pacing")
            }
            // Opt-in audio pacer: default off; flipping it primes/tears down the tone engine via the
            // onChange hook above.
            NoopRow(title: Text("Audio cues"), caption: Text("Soft tone on each phase · respects silent mode"),
                    icon: audioCues ? "speaker-high" : "speaker-slash") {
                Toggle("", isOn: $audioCues).labelsHidden().toggleStyle(.noop).fixedSize()
                    .accessibilityLabel("Audio cues")
            }
            Button { model.buzz(loops: 1) } label: {
                NoopRow(title: Text("Test buzz"),
                        caption: live.bonded ? nil : Text("Requires a bonded connection"),
                        icon: "wave-sine", chevron: false) { EmptyView() }
            }
            .buttonStyle(.plain)
            .disabled(!live.bonded)
            .opacity(live.bonded ? 1 : 0.5)
            .help("Fire a single haptic pulse on the strap (requires a bonded connection)")
        }
    }

    /// The strap hint when nothing is bonded; otherwise nothing.
    @ViewBuilder private var footnote: some View {
        if !live.bonded {
            Text("Connect your strap for haptic guidance. You'll feel one pulse on the inhale, two on the exhale, so you can breathe with your eyes closed.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
        }
    }

    // MARK: - Session outcome

    private var outcomeLine: String? {
        if running { return nil }
        if let endedOutcome {
            return endedOutcome == "—" ? String(localized: "No RMSSD · not enough R-R data")
                                       : String(localized: "RMSSD \(endedOutcome)")
        }
        if !lastStoredOutcome.isEmpty { return String(localized: "Last session: \(lastStoredOutcome)") }
        return nil
    }

    // MARK: - Readouts

    private var readoutRow: some View {
        HStack(spacing: 10) {
            readoutTile(label: String(localized: "Heart rate"), icon: "heart",
                        value: model.bpm.map { "\($0)" } ?? "—",
                        unit: "bpm",
                        caption: live.worn ? String(localized: "Live") : String(localized: "Strap not worn"))

            readoutTile(label: String(localized: "HRV (RMSSD)"), icon: "wave-sine",
                        value: rmssd.map { String(format: "%.0f", $0) } ?? "—",
                        unit: "ms",
                        caption: rrBuffer.isEmpty ? String(localized: "Waiting for R-R") : String(localized: "Last \(rrBuffer.count) beats"))

            readoutTile(label: String(localized: "Pace"), icon: "metronome",
                        value: selectedBpm > 0 ? Self.decimal(selectedBpm) : "—",
                        unit: "br/min",
                        caption: paceCaption)
        }
    }

    private var paceCaption: String {
        if case .resonance = pace {
            let cycle = 60.0 / (lockedBpm ?? ResonanceEngine.fallbackBpm)
            let inn = cycle * BreathPacer.defaultInhaleFraction
            let out = cycle * (1 - BreathPacer.defaultInhaleFraction)
            return String(format: "%.0f / %.0fs", inn, out)
        }
        guard let proto = selectedProtocol, !proto.stages.isEmpty else {
            return isGuided ? String(localized: "Guided timer") : "—"
        }
        let parts = proto.stages.map { Self.decimal(Double($0.durationMs) / 1000.0) }
        return parts.joined(separator: " · ") + "\u{00A0}s"
    }

    /// One decimal in the app language's own separator ("5,5" in German), for the pace readouts.
    static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.activeLocale))
    }

    private func readoutTile(label: String, icon: String, value: String, unit: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                PhIcon(icon, size: 14).opacity(0.9)
                Text(verbatim: label).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(StrandFont.book(12, relativeTo: .caption))
            .foregroundStyle(StrandPalette.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value)
                    .font(StrandFont.value(24, weight: 300))
                    .tracking(-0.48)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .contentTransition(.numericText())
                Text(verbatim: unit)
                    .font(StrandFont.book(10))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.top, 10)
            Text(verbatim: caption)
                .font(StrandFont.light(10.5, relativeTo: .caption2))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 3)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .noopPanel(cornerRadius: 22)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Coherence estimate

    /// The four coherence steps the RMSSD estimate moves through, lit up to the current one.
    private var coherenceSteps: [String] {
        [String(localized: "Building"), String(localized: "Settling"),
         String(localized: "Coherent"), String(localized: "Deep calm")]
    }

    /// Index of the current coherence step (nil without a reading), banded as `coherenceLabel` is.
    private var coherenceStep: Int? {
        guard let r = rmssd else { return nil }
        switch r {
        case ..<20:  return 0
        case ..<45:  return 1
        case ..<80:  return 2
        default:     return 3
        }
    }

    private var coherenceCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Coherence estimate")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    NoopTag(verbatim: coherenceLabel, size: 12).fixedSize()
                }
                HStack(alignment: .top, spacing: 6) {
                    ForEach(Array(coherenceSteps.enumerated()), id: \.offset) { i, name in
                        let current = i == coherenceStep
                        let passed = (coherenceStep ?? -1) > i
                        VStack(alignment: .leading, spacing: 8) {
                            Capsule(style: .continuous)
                                .fill(current ? NoopGlow.stress.accent
                                      : (passed ? NoopGlow.stress.accent.opacity(0.45) : Color.white.opacity(0.12)))
                                .frame(height: 8)
                                .shadow(color: current ? NoopGlow.stress.accent.opacity(0.5) : .clear, radius: 6)
                            Text(verbatim: name)
                                .font(StrandFont.footnote)
                                .foregroundStyle(current ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 16)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Coherence estimate")
                .accessibilityValue(coherenceLabel)
                VStack(alignment: .leading, spacing: 8) {
                    if let line = outcomeLine {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: line)
                                .font(StrandFont.light(12.5, relativeTo: .footnote))
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            if let chip = outcomeTrend {
                                NoopTag(verbatim: chip, size: 10.5).fixedSize()
                            }
                        }
                    }
                    Text("Estimate only: a higher RMSSD while paced usually means your parasympathetic \"rest\" branch is engaging. It is not a clinical reading; trends over a session matter more than any single number.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 12)
                .overlay(alignment: .top) { Rectangle().fill(NoopVisualStyle.border).frame(height: 1) }
                .padding(.top, 14)
            }
        }
    }

    /// "+12% HRV" from the session outcome string, when it carries a leading signed percent.
    private var outcomeTrend: String? {
        guard let source = endedOutcome ?? (lastStoredOutcome.isEmpty ? nil : lastStoredOutcome),
              source != "—",
              let pct = Self.leadingSignedPercent(source) else { return nil }
        let sign = pct >= 0 ? "+" : "−"
        return "\(sign)\(abs(pct))% HRV"
    }

    private static func leadingSignedPercent(_ s: String) -> Int? {
        guard let pctRange = s.range(of: "%") else { return nil }
        let head = s[s.startIndex..<pctRange.lowerBound]
            .replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Int(head)
    }

    private var coherenceLabel: String {
        guard let r = rmssd else { return String(localized: "No data") }
        switch r {
        case ..<20:  return String(localized: "Building")
        case ..<45:  return String(localized: "Settling")
        case ..<80:  return String(localized: "Coherent")
        default:     return String(localized: "Deep calm")
        }
    }

    // MARK: - Session control (catalog stages + guided timer)

    private func start() {
        running = true
        ScreenIdle.keepAwake(true)
        sessionSeconds = 0
        breathCount = 0
        stageIndex = 0
        phaseLabel = nil
        endedOutcome = nil
        baselineRmssd = rmssd
        sessionRmssdSum = 0
        sessionRmssdCount = 0
        sessionRmssdPeak = 0
        if isGuided {
            phase = .textOnly
            phaseLabel = selectedProtocol?.title
            phaseDeadline = .distantFuture
            if !reduceMotion { orbProgress = reducedSteadyOrb }
        } else {
            armCurrentStage(from: Date(), buzz: true)
        }
    }

    private func stop() {
        let wasRunning = running
        running = false
        ScreenIdle.keepAwake(false)
        phaseDeadline = .distantFuture
        phaseLabel = nil
        // #769: this trainer fires per-phase buzzes (armPhase -> model.buzz). Stopping halts NEW pulses but
        // can't recall one the strap is mid-pattern on, which could wedge the strap if the link drops. Tell
        // the strap to stop haptics too (best-effort; no-op when unbonded / on a 5/MG). Only when we were
        // actually buzzing, so a stop on an idle trainer stays silent.
        if wasRunning { model.stopHaptics() }
        if wasRunning { captureOutcome() }
        if reduceMotion {
            orbProgress = 0
        } else {
            withAnimation(.easeInOut(duration: 0.8)) {
                orbProgress = 0
            }
        }
    }

    private let reducedSteadyOrb: CGFloat = 0.5

    private func captureOutcome() {
        guard sessionSeconds >= 120 else { return }
        guard let base = baselineRmssd, base > 0, sessionRmssdCount > 0 else {
            endedOutcome = "—"
            return
        }
        let mean = sessionRmssdSum / Double(sessionRmssdCount)
        let pct = Int(((mean - base) / base * 100).rounded())
        let pctStr = String(format: "%+d%%", pct)
        let peakStr = String(format: "%.0f", sessionRmssdPeak)
        let core = String(localized: "\(pctStr) vs start · peak \(peakStr) ms")
        endedOutcome = core
        lastStoredOutcome = core
    }

    private func resonanceStages() -> [BreathStage] {
        let bpm = lockedBpm ?? ResonanceEngine.fallbackBpm
        let cycleMs = Int((60_000.0 / bpm).rounded())
        let inhaleMs = Int((Double(cycleMs) * BreathPacer.defaultInhaleFraction).rounded())
        let exhaleMs = max(1, cycleMs - inhaleMs)
        return [
            BreathStage(type: .inhale, durationMs: inhaleMs),
            BreathStage(type: .exhale, durationMs: exhaleMs),
        ]
    }

    private func currentStages() -> [BreathStage] {
        if case .resonance = pace { return resonanceStages() }
        return selectedProtocol?.stages.filter { $0.durationMs > 0 } ?? []
    }

    private func armCurrentStage(from now: Date, buzz: Bool) {
        let stages = currentStages()
        guard !stages.isEmpty else { return }
        let stage = stages[stageIndex % stages.count]
        let mapped: Phase
        switch stage.type {
        case .inhale: mapped = .inhale
        case .hold: mapped = .hold
        case .exhale: mapped = .exhale
        case .textOnly: mapped = .textOnly
        }
        phase = mapped
        phaseLabel = stage.label
        let duration = Double(stage.durationMs) / 1000.0
        phaseDeadline = now.addingTimeInterval(duration)

        if reduceMotion {
            orbProgress = reducedSteadyOrb
        } else {
            withAnimation(.easeInOut(duration: duration)) {
                switch mapped {
                case .inhale: orbProgress = 1.0
                case .exhale: orbProgress = 0.0
                case .hold, .textOnly: break // keep current fill
                }
            }
        }

        if buzz {
            let loops = BreathProtocolPlayer.loops(for: stage.type)
            if loops > 0 {
                model.buzz(loops: UInt8(clamping: loops), gate: HapticPrefs.breathing)
            }
            if audioCues {
                switch mapped {
                case .inhale: tonePlayer.play(.inhale)
                case .exhale: tonePlayer.play(.exhale)
                case .hold, .textOnly: break
                }
            }
        }
    }

    private func advance(now: Date) {
        guard !isGuided else { return }
        guard now >= phaseDeadline else { return }
        let stages = currentStages()
        guard !stages.isEmpty else { return }
        let completed = stages[stageIndex % stages.count]
        stageIndex += 1
        if completed.type == .exhale {
            breathCount += 1
        }
        armCurrentStage(from: now, buzz: true)
    }

    // MARK: - HRV (RMSSD)

    private func ingest(_ rr: [Int]) {
        guard !rr.isEmpty else { return }
        rrBuffer.append(contentsOf: rr)
        if rrBuffer.count > rrWindow {
            rrBuffer.removeFirst(rrBuffer.count - rrWindow)
        }
        rmssd = computeRMSSD(rrBuffer)
        if running, let r = rmssd {
            if baselineRmssd == nil && sessionSeconds <= 60 { baselineRmssd = r }
            sessionRmssdSum += r
            sessionRmssdCount += 1
            sessionRmssdPeak = max(sessionRmssdPeak, r)
        }
    }

    private func computeRMSSD(_ intervals: [Int]) -> Double? {
        guard intervals.count >= 2 else { return nil }
        var sumSq = 0.0
        for i in 1..<intervals.count {
            let d = Double(intervals[i] - intervals[i - 1])
            sumSq += d * d
        }
        let meanSq = sumSq / Double(intervals.count - 1)
        return meanSq.squareRoot()
    }

    // MARK: - Formatting

    private func timeString(_ total: Int) -> String {
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Lazy controller holder

/// Holds the `BiofeedbackController` so it can be created from the environment model/live on first
/// appear (a `@StateObject`'s value can't read the environment at init). `prepare` is idempotent.
@MainActor
private final class ControllerBox: ObservableObject {
    private var made: BiofeedbackController?
    func prepare(model: AppModel, live: LiveState) {
        if made == nil { made = BiofeedbackController(model: model, live: live) }
    }
    func controller(model: AppModel, live: LiveState) -> BiofeedbackController {
        if let made { return made }
        let c = BiofeedbackController(model: model, live: live)
        made = c
        return c
    }
}

// MARK: - Audio pacer (opt-in soft phase tones)

/// A tiny on-device tone player for the opt-in audio pacer. It synthesises a short, soft sine "ding"
/// for each phase (a higher note on the inhale, a lower one on the exhale) and plays it through an
/// **ambient** audio session, so the iOS silent switch mutes it like any other ambient sound and it
/// never interrupts other audio. No bundled assets — the buffers are generated once and reused.
///
/// Self-contained and view-owned: `activate()` spins the engine up when the user opts in, `deactivate()`
/// tears it down when they switch off or leave the screen, so we hold the audio session only while it's
/// actually wanted.
@MainActor
final class BreathTonePlayer: ObservableObject {

    enum Tone { case inhale, exhale }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var inhaleBuffer: AVAudioPCMBuffer?
    private var exhaleBuffer: AVAudioPCMBuffer?
    private var active = false

    /// Phase tone frequencies (Hz). A gentle rising/falling pair — a soft cue, not a chime.
    private let inhaleHz: Double = 440   // A4, brighter for "in"
    private let exhaleHz: Double = 330   // E4, lower for "out"
    private let toneSeconds: Double = 0.45
    private let sampleRate: Double = 44_100

    /// Bring the engine and audio session up. Idempotent — safe to call on every appear.
    func activate() {
        guard !active else { return }
#if os(iOS)
        // Ambient: obeys the silent switch and mixes politely with anything else playing.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
#endif
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        guard let format else { return }

        if inhaleBuffer == nil { inhaleBuffer = makeTone(frequency: inhaleHz, format: format) }
        if exhaleBuffer == nil { exhaleBuffer = makeTone(frequency: exhaleHz, format: format) }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            player.play()
            active = true
        } catch {
            // Audio is a nicety, never load-bearing — if it can't start we just stay silent.
            active = false
        }
    }

    /// Stop and release the engine + session so nothing lingers when the pacer is off.
    func deactivate() {
        guard active else { return }
        player.stop()
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.detach(player)
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
#endif
        active = false
    }

    /// Play the phase tone. No-op if the engine isn't up (e.g. start-up race) — the haptic + visual cues
    /// still carry the pace, so a missed tone is harmless.
    func play(_ tone: Tone) {
        guard active else { return }
        let buffer = (tone == .inhale) ? inhaleBuffer : exhaleBuffer
        guard let buffer else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    /// Generate a single soft sine tone with a short attack/decay envelope so it fades in and out rather
    /// than clicking. Built once per frequency and reused.
    private func makeTone(frequency: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(toneSeconds * sampleRate)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount

        let total = Int(frameCount)
        let attack = Int(0.02 * sampleRate)
        let release = Int(0.18 * sampleRate)
        let peak: Float = 0.28   // kept quiet — a gentle cue, not a beep

        for i in 0..<total {
            let t = Double(i) / sampleRate
            let sample = Float(sin(2.0 * Double.pi * frequency * t))
            // Linear attack, sustain, then a longer linear release so the tail is soft.
            var env: Float = 1.0
            if i < attack {
                env = Float(i) / Float(max(attack, 1))
            } else if i > total - release {
                env = Float(total - i) / Float(max(release, 1))
            }
            channel[i] = sample * env * peak
        }
        return buffer
    }
}

// MARK: - L3 nudge-center environment key (optional injection point for Wave 3)

private struct StressNudgeCenterKey: EnvironmentKey {
    static let defaultValue: StressNudgeCenter? = nil
}
extension EnvironmentValues {
    /// The shared L3 nudge center. Wave 3 sets this (`.environment(\.stressNudgeCenter, model.stressNudge)`)
    /// from the same instance its BLEManager hook posts to; nil → BreathingView uses a local fallback.
    var stressNudgeCenter: StressNudgeCenter? {
        get { self[StressNudgeCenterKey.self] }
        set { self[StressNudgeCenterKey.self] = newValue }
    }
}

// MARK: - L1: Resonance mode (the "find my pace" sweep + result)

/// The L1 surface: an explainer, the full/quick sweep start, a live "Testing 5.5 br/min…" label + RSA
/// progress while sweeping, and the dated result card (locked pace + per-pace RSA curve, or the honest
/// "couldn't lock today" fallback). Self-contained — drives the shared `BiofeedbackController`.
private struct ResonanceModeView: View {
    @ObservedObject var controller: BiofeedbackController
    @ObservedObject var live: LiveState
    let lockedBpm: Double?

    private var sweeping: Bool {
        if case .resonanceSweep = controller.session { return true }
        return false
    }

    var body: some View {
        VStack(spacing: NoopMetrics.gap) {
            explainerCard
            if sweeping { sweepProgressCard } else { startCard }
            if let result = controller.lastSweep { resultCard(result) }
            else if let bpm = lockedBpm { lockedCard(bpm) }
            if !live.bonded { connectHint }
        }
        .padding(.top, 2)
    }

    private var explainerCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                NoopCardHeader("Find your resonance pace", icon: "wave-sine") {
                    live.bonded ? Text("Haptics on") : Text("Visual only")
                }
                Text("Everyone has a breathing pace (usually between 4.5 and 7 breaths a minute) where the heart's rhythm swings the most with each breath. We pace you through a few candidate paces, measure how your HRV responds, and lock the one that resonates best for you.")
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Estimate from PPG-derived R-R: relaxation guidance, not a clinical reading. Your pace drifts, so we date it and you can re-measure anytime.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var startCard: some View {
        VStack(spacing: 10) {
            Button { controller.startSweep(quick: false) } label: {
                HStack(spacing: 8) { PhIcon("heartbeat", size: 17); Text("Full sweep · ~13 min") }
            }
            .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))

            Button { controller.startSweep(quick: true) } label: {
                HStack(spacing: 8) { PhIcon("lightning", size: 17); Text("Quick sweep · ~7 min") }
            }
            .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))

            Text("Sit still and breathe with the buzz. You can stop anytime; a stopped sweep won't lock a pace.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sweepProgressCard: some View {
        NoopHeroCard(glow: .stress, padding: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    NoopIconBadge(verbatim: controller.sweepLabel ?? String(localized: "Sweeping…"), icon: "wave-sine")
                    Spacer(minLength: 8)
                    G5LivePill(text: Text("Live"), live: true)
                }
                NoopDotNumber("\(Int((controller.sweepProgress * 100).rounded()))", unit: "%", size: 72)
                NoopTrack(fraction: controller.sweepProgress, height: 10,
                          fill: [NoopGlow.stress.accent.opacity(0.55), NoopGlow.stress.accent])
                    .accessibilityLabel("Sweep progress")
                    .accessibilityValue("\(Int(controller.sweepProgress * 100)) percent")
                Button { controller.stop() } label: {
                    HStack(spacing: 8) { PhIcon("stop", weight: .fill, size: 15); Text("Stop sweep") }
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
            }
        }
    }

    private func resultCard(_ result: ResonanceEngine.SweepResult) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                NoopCardHeader(result.didLock ? "Your resonance pace" : "Couldn't lock today", icon: "metronome") {
                    result.didLock ? Text("Locked") : Text("Fallback")
                }

                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    NoopDotNumber(String(format: "%.1f", result.lockedBpm), size: 58)
                    Text("br/min")
                        .font(StrandFont.light(13, relativeTo: .footnote))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .padding(.bottom, 4)
                }

                if !result.didLock {
                    Text("Not enough clean beat data to lock a pace today. Try again rested, sitting still with the strap snug. For now we'll pace you at 5.5 br/min (coherence).")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                rsaCurve(result.scores)

                if let date = BiofeedbackPrefs.lockedPaceDate, result.didLock {
                    Text("Locked \(date.formatted(date: .abbreviated, time: .omitted)) · paces drift, re-measure anytime.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private func lockedCard(_ bpm: Double) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                NoopCardHeader("Your locked pace", icon: "metronome") { Text("Locked") }
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    NoopDotNumber(String(format: "%.1f", bpm), size: 52)
                    Text("br/min")
                        .font(StrandFont.light(13, relativeTo: .footnote))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .padding(.bottom, 4)
                }
                if let date = BiofeedbackPrefs.lockedPaceDate {
                    Text("Locked \(date.formatted(date: .abbreviated, time: .omitted)). Switch to Breathe to use it, or re-measure above.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A compact text + bar summary of the RSA-amplitude per pace (the resonance curve). The text summary
    /// is the a11y win; the bars are decorative. Unscored paces read "—".
    private func rsaCurve(_ scores: [ResonanceEngine.PaceScore]) -> some View {
        let maxRsa = scores.compactMap(\.rsaAmplitude).max() ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            NoopOverline("RSA RESPONSE BY PACE")
            ForEach(scores, id: \.bpm) { s in
                HStack(spacing: 10) {
                    Text(verbatim: BreathingContent.decimal(s.bpm))
                        .font(StrandFont.book(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 34, alignment: .leading)
                    NoopTrack(fraction: (s.rsaAmplitude ?? 0) / max(maxRsa, 0.0001), height: 8,
                              fill: s.scored ? [NoopGlow.stress.accent.opacity(0.55), NoopGlow.stress.accent]
                                             : [Color.white.opacity(0.18), Color.white.opacity(0.18)])
                    Text(verbatim: s.rsaAmplitude.map { BreathingContent.decimal($0) } ?? "—")
                        .font(StrandFont.book(12, relativeTo: .caption))
                        .foregroundStyle(s.scored ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("RSA response by pace")
        .accessibilityValue(rsaTextSummary(scores))
    }

    private func rsaTextSummary(_ scores: [ResonanceEngine.PaceScore]) -> String {
        scores.map { s in
            let v = s.rsaAmplitude.map { BreathingContent.decimal($0) } ?? String(localized: "unscored")
            return String(localized: "\(BreathingContent.decimal(s.bpm)) breaths per minute: \(v)")
        }.joined(separator: ", ")
    }

    private var connectHint: some View {
        NoopInsightRow("Connect your strap for the felt cue. The sweep paces you with one buzz on the inhale, two on the exhale.",
                       icon: "vibrate")
            .padding(.horizontal, 4)
    }
}

// MARK: - L2: "Calm me" mode (below-HR relaxation metronome)

/// The L2 surface: a "Calm me · 3 min" button that runs `HRDownPacer`, a minimal live "HR 78 → settling"
/// readout, a stop control, and an honest outcome line. Haptic-first → disabled (not faked) when the
/// encrypted channel isn't up. Self-contained — drives the shared `BiofeedbackController`.
private struct CalmModeView: View {
    @ObservedObject var controller: BiofeedbackController
    @ObservedObject var live: LiveState
    @ObservedObject var model: AppModel

    private var running: Bool {
        if case .calmMe = controller.session { return true }
        return false
    }

    var body: some View {
        VStack(spacing: NoopMetrics.gap) {
            explainerCard
            if running { liveCard } else { startCard }
            if let outcome = controller.calmOutcome, !running { outcomeCard(outcome) }
        }
        .padding(.top, 2)
    }

    private var explainerCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                NoopCardHeader("Calm me", icon: "heart") {
                    canRun ? Text("Ready") : Text("Strap needed")
                }
                Text("The strap buzzes a gentle rhythm just below your current heart rate, a felt metronome to relax toward. It trails your heart down rather than yanking it, and stops on its own.")
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A relaxation rhythm, not cardiac control. It never paces below a safe rate and you can stop anytime. If your heart rate doesn't settle, we'll say so plainly.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// L2 needs the encrypted channel (haptic-first) and a resting-band HR to read H₀.
    private var canRun: Bool { controller.canBuzz && (model.bpm.map { $0 >= 55 && $0 <= 120 } ?? false) }

    private var startCard: some View {
        VStack(spacing: 10) {
            Button { controller.startCalmMe() } label: {
                HStack(spacing: 8) { PhIcon("heart", weight: .fill, size: 16); Text("Calm me · 3 min") }
            }
            .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
            .disabled(!canRun)   // the kit style dims a disabled button itself

            if !controller.canBuzz {
                Text("Connect your strap. Calm me is a felt rhythm on the wrist, so it needs a bonded connection.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !canRun {
                Text("Waiting for a resting heart rate. Start a live reading first, or come back when you're still.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var liveCard: some View {
        NoopHeroCard(glow: .stress, padding: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    NoopIconBadge("Settling", icon: "heart")
                    Spacer(minLength: 8)
                    G5LivePill(text: Text("Live"), live: true)
                }

                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    NoopDotNumber(model.bpm.map { "\($0)" } ?? "—", size: 84)
                    PhIcon("arrow-right", size: 18)
                        .foregroundStyle(Color.white.opacity(0.55))
                        .accessibilityHidden(true)
                        .padding(.bottom, 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("target")
                            .font(StrandFont.footnote)
                            .foregroundStyle(Color.white.opacity(0.55))
                        Text(controller.calmTargetBpm.map { String(format: "%.0f", $0) } ?? "—")
                            .font(StrandFont.value(24, weight: 300))
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .padding(.bottom, 8)
                    Spacer(minLength: 0)
                }

                if let h0 = controller.calmStartHR {
                    Text("Started at \(h0) bpm · the rhythm trails your heart down.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(Color.white.opacity(0.55))
                }

                Button { controller.stop() } label: {
                    HStack(spacing: 8) { PhIcon("stop", weight: .fill, size: 15); Text("Stop") }
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
            }
        }
    }

    private func outcomeCard(_ line: String) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                NoopInsightRow(verbatim: line, icon: controller.calmDidNotFall ? "minus-circle" : "check-circle")
                if controller.calmDidNotFall {
                    Text("That's normal. A paced breath often settles things when a metronome alone doesn't.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.leading, 30)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
