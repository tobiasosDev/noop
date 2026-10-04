import SwiftUI
import StrandDesign
import WhoopStore
import OuraProtocol

// MARK: - Add a device — guided, branching wizard
//
// Different bands pair COMPLETELY differently, so this wizard asks the device TYPE first, then gives
// type-specific prep guidance and runs the RIGHT scan/connect for that type:
//
//   • WHOOP 4.0 / WHOOP 5.0 (MG)  → BLEManager's present-scan (`scanForWhoops`), targeted at the
//     chosen WHOOP family via `model.presentWhoopScan(model:)`. Lists nearby straps from
//     `ble.discoveredWhoops` (a present-only mode that never auto-connects).
//   • Heart-rate strap (Polar / Wahoo / Coospo / Garmin HRM / Amazfit Helio broadcast) → its OWN
//     isolated `StandardHRSource` scanning the standard 0x180D HR service. Lists from `discovered`.
//
// Registration goes through `model.registerDevice(_:makeActive:)` → DeviceRegistry; the
// SourceCoordinator reacts to the active-device change and connects. The wizard never touches
// BLEManager directly — only the AppModel pass-throughs. WHOOP-FIRST: WHOOP is the primary band; the
// type list shows it first and a footer reiterates it. Renders cleanly with nothing nearby (the type
// picker, every prep step, and the searching/empty pick state all need no hardware).

struct AddDeviceWizard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    let onClose: () -> Void

    // MARK: Flow

    /// What the user is adding. Drives the prep copy AND which scan/register path runs.
    enum DeviceType: Identifiable, Hashable {
        case whoop5mg
        case whoop4
        case hrStrap
        case gymEquipment
        // EXPERIMENTAL tier — best-effort, clean-room, can't be hardware-verified here. Each fails to an
        // honest message and never fabricates data.
        case amazfit       // Amazfit / Zepp incl. Helio (Huami custom or standard HR)
        case miBand        // Xiaomi Mi Band (Huami; no-auth live HR path, honest message if auth needed)
        case garmin        // Garmin watch (standard Broadcast HR path + an enable hint)
        case oura          // Oura ring (factory-reset-and-adopt: NOOP installs its own key, becomes owner)
        var id: Self { self }

        var isWhoop: Bool { self == .whoop4 || self == .whoop5mg }
        var whoopModel: WhoopModel? {
            switch self {
            case .whoop4:   return .whoop4
            case .whoop5mg: return .whoop5mg
            default:        return nil
            }
        }

        /// True for the EXPERIMENTAL tier (shown under a clearly-labelled "Experimental" heading).
        var isExperimental: Bool {
            switch self {
            case .amazfit, .miBand, .garmin, .oura: return true
            default:                                return false
            }
        }

        /// The experimental-tier brand this type registers as, or nil for the non-experimental types
        /// (WHOOP / generic strap / gym). Bridges the wizard's type picker to the `DeviceBrandCatalog`
        /// facts (stored brand string, `sourceKind`, id prefix) so those are no longer hardcoded per branch.
        var experimentalBrand: ExperimentalBrand? {
            switch self {
            case .amazfit: return .amazfit
            case .miBand:  return .miBand
            case .garmin:  return .garmin
            case .oura:    return .oura
            default:       return nil
            }
        }
    }

    enum Step { case type, prep, pick, confirm }

    /// The Oura factory-reset-and-adopt sub-flow's own step machine (section 2 of the onboarding UX spec).
    /// The Oura type does NOT use the generic prep/pick/confirm shape: it owns this machine, entered from the
    /// type list. PARITY: byte-for-byte the same step set + copy as the Android `OuraStep`.
    ///   - gate     What you get / what you lose + the irreversible red consent gate (or the Advanced key field).
    ///   - prep     Factory-reset the ring in the Oura app first (single-owner warning).
    ///   - pick     Live scan + pick a ring; an unreset ring surfaces honestly.
    ///   - confirm  Detected generation + per-gen capability checklist + the SECOND destructive "Take over" gate.
    ///   - adopting Honest key-install progress (no fake percent), driven by the live source's adopt phase.
    ///   - failed   An honest dead-end when adoption fails, with the file-import + Advanced-key fallbacks.
    enum OuraStep { case gate, prep, pick, confirm, adopting, failed }

    @State private var step: Step = .type
    @State private var type: DeviceType?
    /// The Oura sub-flow step (only meaningful while `type == .oura`). Reset to `.gate` on each Oura entry.
    @State private var ouraStep: OuraStep = .gate
    /// The destructive "Take over this ring?" confirm alert (the SECOND irreversible gate, after the consent
    /// tick). Mirrors the Android `ouraConfirmAdopt`. Only the standard adopt path raises it; the Advanced
    /// key path is non-destructive and skips it.
    @State private var ouraConfirmAdopt = false

    // The chosen strap, in whichever shape its path produces.
    /// A WHOOP picked from `discoveredWhoops` (uuid / advertised name / rssi).
    @State private var pickedWhoop: (uuid: String, name: String, rssi: Int)?
    /// A generic HR strap picked from the StandardHRSource scan.
    @State private var pickedStrap: StandardHRSource.DiscoveredStrap?
    /// An FTMS gym machine picked from the FTMSSource scan.
    @State private var pickedMachine: FTMSSource.DiscoveredMachine?
    /// An EXPERIMENTAL Huami device (Amazfit / Zepp / Mi Band) picked from the HuamiHRSource scan.
    @State private var pickedHuami: HuamiHRSource.DiscoveredDevice?
    /// An EXPERIMENTAL Oura ring picked from the OuraLiveSource scan, plus its detected generation
    /// (best-effort from the advertised name; the user confirms by picking). The `gen` here defaults to
    /// `.gen3` when the scan couldn't guess one, so the registered command set is always usable.
    @State private var pickedOura: (ring: OuraLiveSource.DiscoveredRing, gen: OuraRingGen)?

    @State private var nameDraft = ""
    /// After registering, ask whether to make the new device active.
    @State private var askMakeActive = false

    /// The mandatory irreversible-consent gate (Oura factory-reset-and-adopt). The user must tick this
    /// before the wizard will scan, because adoption installs NOOP's key and the Oura app stops working
    /// with the ring. Mirrors the spec's red `statusCritical` gate. Reset whenever the type changes.
    @State private var ouraConsented = false
    /// The Advanced "I already have my ring's key" power-user path: when true, the prep step swaps to a
    /// hex-key field and we authenticate with the supplied key WITHOUT a factory reset (the Oura app keeps
    /// working). Off by default; only the small Advanced link on the gate turns it on.
    @State private var ouraAdvancedKeyMode = false
    /// The 32-hex-character ring key typed on the Advanced path. Validated to 16 bytes before scan.
    @State private var ouraKeyDraft = ""

    /// Discovery-only HR source for the strap path. Never persists (no-op closure) and is never asked
    /// to `connect` — we only read its `@Published discovered` / `scanning` while scanning. Built once.
    @StateObject private var hrScanner: StandardHRSource
    /// Discovery-only FTMS source for the gym-equipment path. `feedsLive: false` so it never writes
    /// LiveState; we only read its `discovered` / `scanning` while scanning. Built once.
    @StateObject private var ftmsScanner: FTMSSource
    /// Discovery-only EXPERIMENTAL Huami scanner (Amazfit / Zepp / Mi Band). `feedsLive: false`, never
    /// persists; the wizard only reads its `discovered` / `scanning`. Built once.
    @StateObject private var huamiScanner: HuamiHRSource
    /// Discovery-only EXPERIMENTAL Oura scanner. A real `OuraLiveSource` built in discovery-only mode
    /// (`feedsLive: false`, deviceId "scan-preview", no-op persist, no install key), so the wizard only reads
    /// its `@Published discovered` / `scanning` / `needsPairing` while scanning. The chosen ring is adopted
    /// for real on `finishAdd`, where the registered `PairedDevice` carries the ring generation. Built once.
    @StateObject private var ouraScanner: OuraLiveSource

    /// - Parameter startAt: DEBUG-only deep-link into a specific (type, step) so a seeded simulator build
    ///   can screenshot one wizard step deterministically (e.g. the Oura onboarding gate) without tapping
    ///   through. nil in production: the wizard starts on the type list. Pre-seeds the `@State` so the first
    ///   render is already on that step.
    init(live: LiveState, onClose: @escaping () -> Void,
         startAt: (type: DeviceType, step: Step)? = nil) {
        self.onClose = onClose
        if let startAt {
            _type = State(initialValue: startAt.type)
            _step = State(initialValue: startAt.step)
        }
        // Route each throwaway scanner's diagnostics into the SAME exported strap log the active source
        // path uses (issue #421 parity), so a tester's wizard scan, including the Oura discovery scan and
        // any honest needs-pairing outcome, is captured in a shared debug bundle. The sources already
        // self-prefix their lines ("HR-strap: " / "FTMS: " / "Huami: " / "Oura: "); we add the same
        // "[HH:mm:ss]" stamp AppModel's `straplog` uses so wizard lines read identically. Each source is
        // @MainActor and only calls this from the main actor, so the forward into @MainActor LiveState is
        // safe. Privacy-safe: statuses / service UUIDs / counts only, never a device address.
        let wizardLog: (String) -> Void = { line in
            MainActor.assumeIsolated {
                live.append(log: "[\(AppModel.logTimeFormatter.string(from: Date()))] \(line)")
            }
        }
        _hrScanner = StateObject(wrappedValue: StandardHRSource(
            live: live, deviceId: "scan-preview", persist: { _ in }, log: wizardLog))
        _ftmsScanner = StateObject(wrappedValue: FTMSSource(live: live, log: wizardLog, feedsLive: false))
        _huamiScanner = StateObject(wrappedValue: HuamiHRSource(
            live: live, deviceId: "scan-preview", log: wizardLog, feedsLive: false))
        // Discovery-only Oura source: gen defaults to gen3 for the scan-preview command clamp (the real
        // gen is fixed once the user picks), no install key (we never auth during discovery), and
        // `feedsLive: false` so it never writes LiveState or persists. Same shared strap-log sink (#421).
        _ouraScanner = StateObject(wrappedValue: OuraLiveSource(
            live: live, deviceId: "scan-preview", ringGen: .gen3, authKey: { nil },
            persist: { _ in }, log: wizardLog, feedsLive: false))
    }

    /// The device type ticked on the first step; `Next` commits it (a radio list with a pinned CTA).
    @State private var pendingType: DeviceType?
    /// The device ticked in a pick list; `Next` runs its commit — the same selection the row used to run
    /// on tap (record the pick, stop that scan, advance).
    @State private var pendingPick: PendingPick?

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 20)
                .padding(.top, topInset)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    titleBlock
                        .padding(.top, 22)
                    VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                        if type == .oura {
                            // The Oura type runs its OWN step machine (gate -> prep -> pick -> confirm ->
                            // adopting/failed), NOT the generic prep/pick/confirm. Parity with the Android flow.
                            ouraFlow
                        } else {
                            switch step {
                            case .type:    typeStep
                            case .prep:    prepStep
                            case .pick:    pickStep
                            case .confirm: confirmStep
                            }
                        }
                    }
                    .padding(.top, 18)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            #if os(iOS)
            // #697/#horizontal-swipe parity, see ScreenScaffold.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            #if os(iOS) && DEBUG
            .modifier(DemoScrollAnchor())
            #endif
            if let cta = footerCTA { footer(cta) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NoopVisualStyle.canvas.ignoresSafeArea())
        // Stop whichever scan is live whenever the sheet goes away (belt-and-braces alongside the
        // per-transition stops below) so neither central keeps scanning after dismiss.
        .onDisappear { stopAllScans() }
        // After adding, offer to make the new device active (generic non-Oura paths only).
        .alert("Make this your active device?",
               isPresented: $askMakeActive) {
            Button("Not now", role: .cancel) { finishAdd(makeActive: false) }
            Button("Make active") { finishAdd(makeActive: true) }
        } message: {
            Text("Make \(confirmName) your active device now? It will provide your live data. You can change this any time.")
        }
        // The SECOND irreversible gate (after the consent tick): the destructive "Take over this ring?"
        // confirm. Tapping Take over grants adopt consent + registers the ring active (the live source then
        // runs the one-time key install), and moves the wizard to its honest Adopting step. Cancel returns.
        .alert("Take over this ring?", isPresented: $ouraConfirmAdopt) {
            Button("Cancel", role: .cancel) { }
            Button("Take over", role: .destructive) { commitOuraAdopt() }
        } message: {
            Text("NOOP will install its own key on the ring and become its owner. The Oura app will no longer control this ring. This is intended and it cannot be undone from NOOP.")
        }
        // Drive the Adopting step to success (the live source reached streaming -> close the wizard) or to a
        // REACHABLE honest Failed step (the live source announced needs-pairing). Only acts while Adopting,
        // so a later steady-state needs-pairing on the device card never reopens this.
        .onChange(of: model.ouraAdoptPhase) { phase in
            guard type == .oura, ouraStep == .adopting else { return }
            switch phase {
            case .streaming:        stopAllScans(); onClose()   // adoption complete: the ring is the live source now
            case .failed:           ouraStep = .failed
            case .idle, .installingKey: break
            }
        }
        .onChange(of: model.ouraNeedsPairing) { msg in
            // A needs-pairing message during the Adopting step is an honest failure too (covers the no-ack /
            // ack!=OK paths that surface via needsPairing rather than a phase flip alone).
            guard type == .oura, ouraStep == .adopting, msg != nil else { return }
            ouraStep = .failed
        }
    }

    // MARK: Header

    private var topInset: CGFloat {
        #if os(macOS)
        return 24
        #else
        return 4
        #endif
    }

    private var bottomInset: CGFloat {
        #if os(macOS)
        return 24
        #else
        return 4
        #endif
    }

    /// Back circle, four progress dashes and "n / 4". The first step (and the Oura key install, which has
    /// no meaningful back) leads with Close instead.
    private var topBar: some View {
        HStack(spacing: 14) {
            // Back is offered on every step except the very first (the type list), AND, on the Oura adopt
            // flow, except the Adopting progress (no meaningful back while a key install is in flight). This
            // re-enables back/cancel everywhere else so the user is never trapped on the Failed state.
            if showBack {
                NoopCircleButton("caret-left", accessibilityLabel: "Back", action: goBack)
            } else {
                NoopCircleButton("x", accessibilityLabel: "Close", action: close)
            }
            WizardDashes(count: 4, filled: stepNumber)
            Text("\(stepNumber) / 4")
                .font(StrandFont.book(12, relativeTo: .caption))
                .tracking(0.24)
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textSecondary)
            #if os(macOS)
            // A Mac sheet has no swipe-to-dismiss, so Close stays one click away on every step.
            if showBack {
                NoopCircleButton("x", size: 34, accessibilityLabel: "Close", action: close)
            }
            #endif
        }
        .frame(height: 50)
    }

    private func close() {
        stopAllScans()
        onClose()
    }

    /// Back is shown on every step except the very first (the type list) and, on the Oura adopt flow, the
    /// Adopting progress (no back while a key install is in flight). Parity with the Android `showBack`.
    private var showBack: Bool {
        if type == .oura { return ouraStep != .adopting }
        return step != .type
    }

    /// Which of the four stops the progress dashes light: type, get ready, pick, confirm.
    private var stepNumber: Int {
        if type == .oura {
            switch ouraStep {
            case .gate, .prep: return 2
            case .pick:        return 3
            case .confirm, .adopting, .failed: return 4
            }
        }
        switch step {
        case .type:    return 1
        case .prep:    return 2
        case .pick:    return 3
        case .confirm: return 4
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headerTitle)
                .font(StrandFont.title1)
                .tracking(-0.56)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let sub = headerSubtitle {
                Text(sub)
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .lineSpacing(3)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerTitle: LocalizedStringKey {
        if type == .oura {
            switch ouraStep {
            case .gate:     return ouraAdvancedKeyMode ? "Advanced: use your own key" : "Oura ring"
            case .prep:     return "Get your ring ready"
            case .pick:     return "Pick the ring"
            case .confirm:  return "Your ring"
            case .adopting: return "Taking over your ring"
            case .failed:   return "Could not take over"
            }
        }
        switch step {
        case .type:    return "What are you adding?"
        case .prep:    return LocalizedStringKey(type.map(typeTitle) ?? String(localized: "Add a device"))
        case .pick:    return "Tap the one that's yours."
        case .confirm: return "Name & confirm"
        }
    }

    private var headerSubtitle: LocalizedStringKey? {
        if type == .oura {
            switch ouraStep {
            case .gate:    return ouraAdvancedKeyMode ? "Power users only." : "Take it over locally. Beta."
            case .prep:    return "Reset it in the Oura app first."
            case .pick:    return "Tap the one that's yours."
            case .confirm, .adopting, .failed: return nil
            }
        }
        switch step {
        case .type:    return "NOOP reads several sources at once and picks the best one for each number."
        case .prep:    return "Get it ready, then scan."
        case .pick:    return pickHint
        case .confirm: return nil
        }
    }

    /// What wakes the chosen kind of device, under the pick step's title.
    private var pickHint: LocalizedStringKey {
        switch type {
        case .hrStrap?:      return "Wet the electrodes and put it on — most straps only wake up on skin."
        case .garmin?:       return "Turn on Broadcast Heart Rate on the watch, then pick it below."
        case .gymEquipment?: return "Start moving so the machine wakes its Bluetooth."
        default:             return "Make sure it's awake and not connected elsewhere."
        }
    }

    // MARK: Footer (the one forward CTA)

    private struct FooterCTA {
        let title: LocalizedStringKey
        let enabled: Bool
        var accessibilityLabel: Text?
        let action: () -> Void
    }

    /// The pinned primary action for steps that move forward with one button. The Oura gate / prep /
    /// confirm / adopting / failed faces keep their own inline actions (their gates sit next to them).
    private var footerCTA: FooterCTA? {
        if type == .oura {
            guard ouraStep == .pick else { return nil }
            return FooterCTA(title: "Next", enabled: pendingPick != nil) { pendingPick?.commit() }
        }
        switch step {
        case .type:
            return FooterCTA(title: "Next", enabled: pendingType != nil) {
                if let pendingType { choose(pendingType) }
            }
        case .prep:
            guard let type else { return nil }
            return FooterCTA(title: "Scan", enabled: true,
                             accessibilityLabel: Text("Scan for \(typeTitle(type))")) {
                startScan(for: type)
                step = .pick
            }
        case .pick:
            return FooterCTA(title: "Next", enabled: pendingPick != nil) { pendingPick?.commit() }
        case .confirm:
            return FooterCTA(title: "Add",
                             enabled: !nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                askMakeActive = true
            }
        }
    }

    private func footer(_ cta: FooterCTA) -> some View {
        Button(action: cta.action) { Text(cta.title) }
            .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
            .disabled(!cta.enabled)
            .accessibilityLabel(cta.accessibilityLabel ?? Text(cta.title))
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, bottomInset)
            // The kit's `.fade`: the list dissolves into the pinned CTA instead of being cut.
            .background(alignment: .top) {
                LinearGradient(colors: [NoopVisualStyle.canvas.opacity(0), NoopVisualStyle.canvas],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                    .offset(y: -28)
                    .allowsHitTesting(false)
            }
    }

    // MARK: Step 1 — type picker

    @ViewBuilder private var typeStep: some View {
        if let registry = model.deviceRegistry {
            SourcesHero(registry: registry, batteryPct: live.batteryPct,
                        adding: pendingType.map { (typeTitle($0), typeIcon($0)) },
                        icon: deviceIcon)
        }
        NoopList {
            typeRow(.whoop5mg,
                    title: "WHOOP 5.0 / MG",
                    subtitle: String(localized: "Newer WHOOP band with live data and history sync"))
            typeRow(.whoop4,
                    title: "WHOOP 4.0",
                    subtitle: String(localized: "NOOP's primary, fully-supported band"))
            typeRow(.hrStrap,
                    title: String(localized: "Heart-rate strap"),
                    subtitle: String(localized: "Polar, Wahoo, Coospo, Garmin HRM, Amazfit Helio broadcast"))
            typeRow(.gymEquipment,
                    title: String(localized: "Gym equipment"),
                    subtitle: String(localized: "Treadmill, indoor bike, rower or cross-trainer (Bluetooth FTMS)"))
        }
        .padding(.top, 8)

        // EXPERIMENTAL tier — clearly labelled, opt-in, best-effort. Each is honest about what it can
        // actually read; none fabricates data.
        HStack(alignment: .firstTextBaseline) {
            NoopOverline("Experimental")
            Spacer(minLength: 8)
            Text("Best-effort")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 14)
        NoopList {
            typeRow(.oura,
                    title: String(localized: "Oura ring"),
                    subtitle: String(localized: "Take over your ring locally. Beta. This replaces the Oura app."))
            typeRow(.amazfit,
                    title: "Amazfit / Zepp",
                    subtitle: String(localized: "Incl. Helio. Live heart rate where the band exposes it. Help us test."))
            typeRow(.miBand,
                    title: "Xiaomi Mi Band",
                    subtitle: String(localized: "Live heart rate on bands that don't need pairing. Help us test."))
            typeRow(.garmin,
                    title: String(localized: "Garmin watch"),
                    subtitle: String(localized: "Uses the watch's Broadcast Heart Rate. We'll show you how."))
        }
        .padding(.top, -2)
        experimentalTierCaption
        whoopFirstNote
    }

    private func typeRow(_ t: DeviceType, title: String, subtitle: String) -> some View {
        let selected = pendingType == t
        return Button {
            withAnimation(StrandMotion.interactive) { pendingType = t }
        } label: {
            HStack(spacing: 13) {
                WizardIconTile(icon: typeIcon(t), size: t.isExperimental ? 38 : 42)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(StrandFont.book(15, relativeTo: .body))
                            .foregroundStyle(t.isExperimental ? StrandPalette.textSecondary : StrandPalette.textPrimary)
                        if t.isExperimental { BetaTag() }
                    }
                    Text(subtitle)
                        .font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                RadioMark(on: selected)
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .padding(.vertical, t.isExperimental ? 11 : 12)
            .background(StrandPalette.textPrimary.opacity(selected ? 0.045 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(subtitle)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Commit the ticked type: the Oura type enters its own gated sub-flow, every other type its prep step.
    private func choose(_ t: DeviceType) {
        type = t
        nameDraft = ""
        pendingPick = nil
        // The Oura factory-reset-and-adopt gate is destructive, so every fresh entry into the Oura flow
        // re-requires the irreversible-consent tick and clears any stale Advanced-key / adopt state, and
        // enters the Oura sub-flow at its gate rather than the generic prep step.
        if t == .oura {
            ouraConsented = false
            ouraAdvancedKeyMode = false
            ouraKeyDraft = ""
            ouraConfirmAdopt = false
            pickedOura = nil
            ouraStep = .gate
        } else {
            step = .prep
        }
    }

    /// The Phosphor glyph for a registered device, by how it streams.
    private func deviceIcon(_ d: PairedDevice) -> String {
        switch d.sourceKind {
        case .ftms: return "bicycle"
        case .oura: return "circle"
        case .liveAppleWatch: return "watch"
        default: return d.brand == "WHOOP" ? "watch" : "heartbeat"
        }
    }

    // MARK: Step 2 — type-specific prep + guidance

    @ViewBuilder private var prepStep: some View {
        if let type, type != .oura {
            if type == .whoop5mg {
                experimentalNote
            } else if type.isExperimental {
                experimentalTierNote
            }

            // A6 , the one-phone-at-a-time WHOOP warning, surfaced BEFORE the user scans so the most common
            // pairing failure (the official app still holding the link) is pre-empted, not discovered after
            // a failed scan. WHOOP-only: the single-link constraint is specific to the WHOOP band's bonding,
            // not the generic HR / FTMS paths.
            if type.isWhoop {
                singleConnectionWarning
            }

            NoopList {
                ForEach(Array(prepInstructions(type).enumerated()), id: \.offset) { _, line in
                    WizardTipRow(icon: "check", text: line)
                }
            }
        }
    }

    /// Type-specific "get it ready" guidance — the point of the branching wizard.
    private func prepInstructions(_ t: DeviceType) -> [String] {
        switch t {
        case .whoop4:
            return [
                String(localized: "Put your WHOOP 4.0 on your wrist and make sure it's awake."),
                String(localized: "Make sure it's NOT connected to the official WHOOP app right now."),
                String(localized: "NOOP will look for it nearby."),
            ]
        case .whoop5mg:
            return [
                String(localized: "WHOOP 5.0 / MG bonds to one device at a time. Unpair it from the official WHOOP app first."),
                String(localized: "Put the band into pairing mode, on your wrist and awake."),
                String(localized: "NOOP will look for it nearby."),
            ]
        case .hrStrap:
            return [
                String(localized: "Wake your strap. Put it on, or dampen the contacts."),
                String(localized: "Make sure it isn't connected to another app (a bike computer, the brand's own app…)."),
                String(localized: "NOOP will look for it nearby."),
            ]
        case .gymEquipment:
            return [
                String(localized: "Wake the machine. Start pedalling, walking or rowing so it powers on its Bluetooth."),
                String(localized: "Make sure it isn't already connected to another app (Zwift, the gym's app, a bike computer…)."),
                String(localized: "NOOP looks for machines that broadcast the standard Bluetooth Fitness Machine service."),
            ]
        case .amazfit:
            return [
                String(localized: "Wake your Amazfit / Zepp band and make sure it isn't connected to the Zepp app right now."),
                String(localized: "NOOP reads live heart rate when the band exposes it. Some bands need a pairing we can't do yet. If so, we'll say so honestly."),
                String(localized: "Experimental: this is best-effort. If live doesn't work, you can export from Zepp and import the file."),
            ]
        case .miBand:
            return [
                String(localized: "Wake your Mi Band and make sure it isn't connected to the Mi Fitness / Zepp Life app right now."),
                String(localized: "NOOP reads live heart rate on bands that don't require pairing. Newer bands need an auth handshake we can't do yet."),
                String(localized: "Experimental: if your band needs pairing, we'll tell you honestly rather than show a fake reading."),
            ]
        case .garmin:
            return GarminBroadcast.broadcastHint
        case .oura:
            // The factory-reset-and-adopt checklist, shown only AFTER the irreversible-consent gate. NOOP
            // installs its own key on a reset ring and becomes its sole owner (clean-room facts, see
            // docs/OURA_PROTOCOL.md s3 on the install-key + reset-clears-owner model).
            return [
                String(localized: "Open the official Oura app and remove this ring (Oura calls it \"factory reset\" or \"unpair and reset\"). This wipes the ring's owner so NOOP can take it over."),
                String(localized: "Keep the ring on the charger or on your finger so it stays awake."),
                String(localized: "Make sure the Oura app is fully closed. A ring answers one owner at a time."),
                String(localized: "When the ring is reset and waking, tap Scan below."),
            ]
        }
    }

    // MARK: Step 2 (Oura) - destructive factory-reset-and-adopt sub-flow

    /// The Oura adopt sub-flow, routed by `ouraStep`. Faithful parity with the Android `OuraFlow`:
    ///   - gate     irreversible-consent gate ("This replaces Oura") OR the Advanced key field.
    ///   - prep     factory-reset checklist + single-owner warning + Scan.
    ///   - pick     live scan + pick a ring (honest needs-pairing fallback).
    ///   - confirm  detected generation + per-gen capability checklist + the SECOND destructive "Take over".
    ///   - adopting honest key-install progress (no fake percent).
    ///   - failed   honest dead-end with Try again + Use file import.
    /// All copy is honest, US-neutral, no em-dashes (spec docs/superpowers/specs/2026-06-29-oura-onboarding-ux.md).
    @ViewBuilder private var ouraFlow: some View {
        switch ouraStep {
        case .gate:     if ouraAdvancedKeyMode { ouraAdvancedKeyFace } else { ouraConsentGateFace }
        case .prep:     ouraResetChecklistFace
        case .pick:     ouraPickFace
        case .confirm:  ouraConfirmFace
        case .adopting: ouraAdoptingFace
        case .failed:   ouraFailedFace
        }
    }

    /// Face 1, the honest gate. Beta banner, a "what you get / what you lose" card, the irreversible line
    /// with a mandatory checkbox, then Continue (disabled until ticked) plus the two always-available escape
    /// lanes (file import, Advanced key).
    @ViewBuilder private var ouraConsentGateFace: some View {
        ouraBetaBanner

        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    NoopOverline("What you get")
                    ouraBullet(String(localized: "Your ring talks to NOOP only, fully offline, no Oura account."))
                    ouraBullet(String(localized: "Live heart rate, and HRV when the ring can measure it."))
                    ouraBullet(String(localized: "Overnight sleep staging, resting heart rate, skin-temperature trend, motion and battery, read straight off the ring."))
                    ouraBullet(String(localized: "NOOP's own Charge, Effort and Rest, computed on your device from published methods."))
                }
                Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
                VStack(alignment: .leading, spacing: 8) {
                    NoopOverline("What you lose")
                    ouraBullet(String(localized: "The Oura app and your Oura account stop working with this ring. This is the point. You are replacing Oura."))
                    ouraBullet(String(localized: "Oura's own Readiness and Sleep scores. NOOP does not copy them. It computes its own."))
                    ouraBullet(String(localized: "Anything that needs Oura's cloud (web dashboard, Oura's coaching, shared circles)."))
                    ouraBullet(String(localized: "Likely your Oura warranty and support, because the ring is no longer paired to Oura. Treat this as permanent."))
                }
            }
        }

        // The irreversible line, with the mandatory tick drawn in the critical colour.
        Button {
            ouraConsented.toggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ConsentBox(on: ouraConsented)
                Text("I understand this disconnects the ring from Oura and that NOOP cannot undo it for me. To go back to Oura I would factory-reset the ring again and set it up in the Oura app.")
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .lineSpacing(2)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .noopPanel(cornerRadius: 20)
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(ouraConsented ? NoopVisualStyle.borderHighlight : NoopVisualStyle.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("I understand this disconnects the ring from Oura and that NOOP cannot undo it for me.")
        .accessibilityAddTraits(ouraConsented ? [.isSelected] : [])

        // Primary: continue to the reset checklist. Disabled until the box is ticked.
        Button {
            ouraStep = .prep   // tick confirmed: advance to the factory-reset checklist face
        } label: {
            Text("Continue")
        }
        .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
        .disabled(!ouraConsented)
        .accessibilityHint("Continue to get your ring ready")
        .padding(.top, 4)

        // Secondary: keep the Oura app, import a file instead (non-destructive, always one tap away).
        Button {
            stopAllScans()
            onClose()   // routes to the existing Data Sources / file-import lane
        } label: {
            Text("Keep the Oura app instead (import a file)")
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
        .accessibilityLabel("Keep the Oura app instead, import a file")

        // Tertiary: Advanced power-user key path (no reset, Oura app keeps working).
        Button("Advanced: I already have my ring's key") {
            ouraAdvancedKeyMode = true
        }
        .font(StrandFont.book(13, relativeTo: .footnote))
        .buttonStyle(.plain)
        .foregroundStyle(StrandPalette.textSecondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
        .accessibilityLabel("Advanced. I already have my ring's key.")
    }

    /// Face 2, the factory-reset checklist + the single-owner warning + Scan. Reached after the consent box
    /// is ticked.
    @ViewBuilder private var ouraResetChecklistFace: some View {
        // One-owner heads-up (mirrors the WHOOP single-connection warning).
        NoticeCard(icon: "warning", tint: StrandPalette.statusWarning,
                   title: "A ring talks to one owner at a time.",
                   message: "If the Oura app is still running it will hold the ring and adoption will fail. Force-quit Oura, then scan.")

        NoopList {
            ForEach(Array(prepInstructions(.oura).enumerated()), id: \.offset) { _, line in
                WizardTipRow(icon: "check", text: line)
            }
        }

        Button {
            startScan(for: .oura)
            ouraStep = .pick
        } label: {
            Label { Text("Scan for your ring") } icon: { PhIcon("bluetooth", size: 16) }
        }
        .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
        .accessibilityLabel("Scan for your Oura ring")
        .padding(.top, 4)
    }

    /// Face 3, the Advanced "use your own key" power-user path. Authenticates with a supplied 16-byte key
    /// WITHOUT a factory reset, so the Oura app keeps working too. Validates 32 hex chars before Scan.
    @ViewBuilder private var ouraAdvancedKeyFace: some View {
        NoticeCard(icon: "key", tint: StrandPalette.statusWarning, title: nil,
                   message: "If you extracted your ring's 16-byte key from a previous Oura setup, NOOP can talk to the ring with that key without resetting it, so the Oura app keeps working too. NOOP does not extract keys for you and cannot help you find one. If you do not know what this means, go back and use the standard setup or file import.")

        NoopOverline("Ring key (32 hex characters)")
            .padding(.horizontal, 4)
            .padding(.top, 6)
        TextField("0123456789abcdef0123456789abcdef", text: $ouraKeyDraft)
            .textFieldStyle(.plain)
            .font(StrandFont.mono(14))
            .foregroundStyle(StrandPalette.textPrimary)
            .autocorrectionDisabled(true)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .wizardField()
            .accessibilityLabel("Ring key, 32 hexadecimal characters")
        if !ouraKeyDraft.isEmpty && ouraKeyBytes == nil {
            Text("That is not a 32-character hex key.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusCritical)
                .padding(.horizontal, 4)
        }
        Text("NOOP stores this key only on this device, in the same place it stores your paired bands.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)

        Button {
            startScan(for: .oura)
            ouraStep = .pick
        } label: {
            Label { Text("Scan for your ring") } icon: { PhIcon("bluetooth", size: 16) }
        }
        .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
        .disabled(ouraKeyBytes == nil)
        .accessibilityLabel("Scan for your Oura ring")
        .padding(.top, 4)

        Button("Back to standard setup") {
            ouraAdvancedKeyMode = false
            ouraKeyDraft = ""
        }
        .font(StrandFont.book(13, relativeTo: .footnote))
        .buttonStyle(.plain)
        .foregroundStyle(StrandPalette.textSecondary)
        .frame(maxWidth: .infinity)
    }

    // MARK: Step 3 (Oura) - pick the ring

    /// The Oura pick face. Observes the discovery-only `OuraLiveSource`; ticking a ring and tapping Next
    /// confirms its best-effort generation and advances to the capability/confirm face. An honest
    /// needs-pairing fallback (the ring is still Oura-owned / not reset) routes to file import. Mirrors the
    /// Android `OuraPickStep`.
    @ViewBuilder private var ouraPickFace: some View {
        OuraPickList(scanner: ouraScanner,
                     selectedId: pendingPick?.id,
                     onSelect: { ring in
                         pendingPick = PendingPick(id: ring.id.uuidString) {
                             let gen = ring.detectedGen ?? .gen3
                             pickedOura = (ring: ring, gen: gen)
                             clearOtherPicks(except: .oura)
                             nameDraft = String(localized: "Oura ring")
                             ouraScanner.stopScan()
                             pendingPick = nil
                             ouraStep = .confirm
                         }
                     },
                     onRescan: { ouraScanner.scan() },
                     onUseImport: {
                         ouraScanner.stop()
                         onClose()   // honest non-destructive fallback: head to file import
                     })
    }

    // MARK: Step 4 (Oura) - confirm: detected gen + per-gen capability checklist + the SECOND gate

    /// The Oura confirm face: the identified ring (gen name + Beta tag), the per-gen capability checklist
    /// (tick / * estimate / dash not-available), a name field, then the adopt action. On the standard adopt
    /// path the action is "Take over this ring" (which raises the SECOND irreversible confirm); on the
    /// non-destructive Advanced-key path it is a plain "Connect to this ring" that registers without a key
    /// install. Mirrors the Android `OuraConfirmStep`.
    @ViewBuilder private var ouraConfirmFace: some View {
        let gen = pickedOura?.gen ?? .gen3
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    WizardIconTile(icon: "circle", size: 38)
                    Text(gen.displayName)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    BetaTag()
                }
                ForEach(Array(ouraCapabilityRows(for: gen).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 8) {
                        Text(row.mark)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 14, alignment: .leading)
                        Text(row.label)
                            .font(StrandFont.light(13, relativeTo: .footnote))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Beta. * is an on-device estimate. Skin temp is a trend versus your own baseline, steps are a raw motion count, and HRV needs you to be still. No Oura Readiness or SpO2 percentage comes off the ring (import an Oura file for those).")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        NoopOverline("Name")
            .padding(.horizontal, 4)
            .padding(.top, 6)
        TextField("Oura ring", text: $nameDraft)
            .textFieldStyle(.plain)
            .font(StrandFont.light(15, relativeTo: .body))
            .foregroundStyle(StrandPalette.textPrimary)
            .wizardField()
            .accessibilityLabel("Device name")

        if ouraAdvancedKeyMode {
            // Non-destructive: the user's own key authenticates without resetting the ring, so this reads
            // as a plain connect and skips the destructive confirm.
            Button {
                finishAdvancedOura()
            } label: {
                Text("Connect to this ring")
            }
            .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
            .accessibilityLabel("Connect to this ring")
            .padding(.top, 4)
            Text("Both NOOP and the Oura app can use a ring you own by key, but only one can hold the Bluetooth link at a time.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        } else {
            // Destructive (key install): raise the SECOND irreversible "Take over this ring?" confirm.
            Button {
                ouraConfirmAdopt = true
            } label: {
                Text("Take over this ring")
            }
            .buttonStyle(NoopButtonStyle(.destructive, fullWidth: true))
            .accessibilityLabel("Take over this ring")
            .padding(.top, 4)
        }
    }

    // MARK: Step 5 (Oura) - adopting: honest key-install progress (no fake percent)

    /// The Adopting face: an honest "Installing NOOP's key" progress card shown ONLY while a real key install
    /// is in flight (the standard adopt path; the Advanced path never lands here). Driven to success/Failed by
    /// the live source's `adoptPhase` (see the body `.onChange`). Mirrors the Android `OuraAdoptingStep`.
    @ViewBuilder private var ouraAdoptingFace: some View {
        NoopCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ProgressView().tint(StrandPalette.textPrimary)
                    Text("Taking over your ring")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text("Installing NOOP's key and confirming the ring answers only to NOOP. Keep the ring close and do not open the Oura app.")
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .lineSpacing(2)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Step 5 (Oura, failure) - honest dead-end, never a fabricated success

    /// The Failed face: an honest dead-end with the live source's needs-pairing message (when present) and the
    /// two reachable fallbacks (Try again -> back to pick; Use file import -> close to Data Sources). Re-enables
    /// the user's exits so they are never trapped. Mirrors the Android `OuraFailedStep`.
    @ViewBuilder private var ouraFailedFace: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("We could not take over this ring.")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(model.ouraNeedsPairing ?? "The most common cause is the ring was not fully reset in the Oura app, or the Oura app is still running. Reset the ring again, force-quit Oura, then try once more. If it keeps failing, your ring may be a generation NOOP cannot adopt yet. The ring is not bricked: re-pair it in the Oura app to recover it. You can still use file import.")
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .lineSpacing(2)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        pickedOura = nil
                        pendingPick = nil
                        ouraScanner.scan()
                        ouraStep = .pick
                    } label: {
                        Text("Try again")
                    }
                    .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                    .accessibilityLabel("Try again")

                    Button {
                        ouraScanner.stop()
                        onClose()   // honest non-destructive fallback: head to file import
                    } label: {
                        Text("Use file import")
                    }
                    .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                    .accessibilityLabel("Use file import")
                }
                .padding(.top, 4)
            }
        }
    }

    /// The per-generation capability checklist (section 3 of the onboarding UX spec). Each row is a (mark,
    /// label): a tick for decoded-and-used, * for a best-effort on-device estimate, a dash for
    /// not-available-off-the-ring. gen3/gen4 are the verified path; gen5's live HR + firmware reads are
    /// least proven so they read as estimates. PARITY: the marks match the Android `ouraCapabilityRows`
    /// exactly. No Oura Readiness/Sleep score or absolute SpO2 % ever comes off the ring.
    private func ouraCapabilityRows(for gen: OuraRingGen) -> [(mark: String, label: String)] {
        let live = (gen == .gen5) ? "*" : "✓"   // newer rings: live HR is best-effort
        let firm = (gen == .gen5) ? "*" : "✓"   // resting HR / sleep / battery
        return [
            (live, String(localized: "Live heart rate")),
            ("*", "HRV (rMSSD)"),
            (firm, String(localized: "Resting heart rate")),
            (firm, String(localized: "Sleep staging")),
            ("*", String(localized: "Skin-temperature trend")),
            ("*", String(localized: "Steps / motion")),
            (firm, String(localized: "Battery")),
            ("-", String(localized: "Blood oxygen (SpO2 %)")),
            ("-", String(localized: "Oura Readiness / Sleep score")),
        ]
    }

    /// The shared Oura Beta heads-up, reused at the top of the consent gate.
    private var ouraBetaBanner: some View {
        NoticeCard(icon: "flask", tint: StrandPalette.statusWarning,
                   title: "Beta. Read this first.",
                   message: "Local Oura support is new and we cannot test every ring here. It may not connect on your ring, and it can change between updates. NOOP never makes up a number. If something does not work, it will tell you plainly.")
    }

    /// One "·"-free bullet line for the get/lose columns.
    private func ouraBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(StrandPalette.textTertiary)
                .frame(width: 4, height: 4)
                .padding(.top, 7)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.light(13.5, relativeTo: .subheadline))
                .lineSpacing(2)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The Advanced key field parsed into 16 raw bytes, or nil when it is not exactly 32 hex characters.
    /// Used to gate the Advanced Scan button and to seed the install-key store on adoption.
    private var ouraKeyBytes: Data? {
        let hex = ouraKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hex.count == OuraKeyStore.keyLength * 2 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(OuraKeyStore.keyLength)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return Data(bytes)
    }

    /// Phosphor glyph for a device type — the type list tiles, the sources slot and the pick rows.
    private func typeIcon(_ t: DeviceType) -> String {
        switch t {
        case .whoop4, .whoop5mg: return "watch"
        case .hrStrap:           return "heartbeat"
        case .gymEquipment:      return "bicycle"
        case .amazfit:           return "watch"
        case .miBand:            return "activity"
        case .garmin:            return "compass"
        case .oura:              return "circle"
        }
    }

    // MARK: Step 3 — pick from the live scan

    @ViewBuilder private var pickStep: some View {
        if let type {
            if type.isWhoop {
                // Observe BLEManager directly so the list updates as `discoveredWhoops` grows. The
                // subview holds the @ObservedObject; the wizard owns selection + scan lifecycle.
                WhoopPickList(ble: model.ble, selectedId: pendingPick?.id) { strap in
                    pendingPick = PendingPick(id: strap.uuid) {
                        pickedWhoop = strap
                        pickedStrap = nil
                        pickedMachine = nil
                        pickedHuami = nil
                        nameDraft = strap.name.isEmpty ? typeTitle(type) : strap.name
                        model.stopWhoopScan()
                        pendingPick = nil
                        step = .confirm
                    }
                } onRescan: {
                    model.presentWhoopScan(model: type.whoopModel ?? .whoop4)
                }
            } else if type == .gymEquipment {
                FTMSPickList(scanner: ftmsScanner, selectedId: pendingPick?.id) { machine in
                    pendingPick = PendingPick(id: machine.id.uuidString) {
                        pickedMachine = machine
                        clearOtherPicks(except: .gymEquipment)
                        nameDraft = machine.name
                        ftmsScanner.stopScan()
                        pendingPick = nil
                        step = .confirm
                    }
                } onRescan: {
                    ftmsScanner.scan()
                }
            } else if type == .amazfit || type == .miBand {
                // EXPERIMENTAL Huami pick list (Amazfit / Zepp / Mi Band).
                HuamiPickList(scanner: huamiScanner, selectedId: pendingPick?.id) { dev in
                    pendingPick = PendingPick(id: dev.id.uuidString) {
                        pickedHuami = dev
                        clearOtherPicks(except: type)
                        nameDraft = dev.name
                        huamiScanner.stopScan()
                        pendingPick = nil
                        step = .confirm
                    }
                } onRescan: {
                    huamiScanner.scan()
                }
            } else {
                // Heart-rate strap AND Garmin (Broadcast HR is the standard 0x180D path).
                HRPickList(scanner: hrScanner, selectedId: pendingPick?.id) { strap in
                    pendingPick = PendingPick(id: strap.id.uuidString) {
                        pickedStrap = strap
                        clearOtherPicks(except: type)
                        nameDraft = strap.name
                        hrScanner.stopScan()
                        pendingPick = nil
                        step = .confirm
                    }
                } onRescan: {
                    hrScanner.scan()
                }
            }
        }
    }

    /// Clear every "picked" selection except the one for `keep`'s path, so re-entering the pick step or
    /// switching device types never leaves a stale pick of another shape.
    private func clearOtherPicks(except keep: DeviceType) {
        if keep.isWhoop == false { pickedWhoop = nil }
        switch keep {
        case .hrStrap, .garmin:    pickedHuami = nil; pickedMachine = nil; pickedOura = nil
        case .gymEquipment:        pickedStrap = nil; pickedHuami = nil; pickedOura = nil
        case .amazfit, .miBand:    pickedStrap = nil; pickedMachine = nil; pickedOura = nil
        case .oura:                pickedStrap = nil; pickedMachine = nil; pickedHuami = nil
        default:                   pickedStrap = nil; pickedMachine = nil; pickedHuami = nil; pickedOura = nil
        }
    }

    // MARK: Step 4 — name + confirm

    @ViewBuilder private var confirmStep: some View {
        NoopList {
            HStack(spacing: 13) {
                WizardIconTile(icon: type.map(typeIcon) ?? "bluetooth", size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(confirmAdvertisedName)
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(confirmBrand)
                        .font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                WizardSignalBars(rssi: confirmRSSI)
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .padding(.vertical, 13)
        }

        NoopOverline("Name")
            .padding(.horizontal, 4)
            .padding(.top, 6)
        TextField("Device name", text: $nameDraft)
            .textFieldStyle(.plain)
            .font(StrandFont.light(15, relativeTo: .body))
            .foregroundStyle(StrandPalette.textPrimary)
            .wizardField()
            .accessibilityLabel("Device name")
    }

    // MARK: Confirm-step derived values

    private var confirmName: String {
        let n = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? confirmAdvertisedName : n
    }
    private var confirmAdvertisedName: String {
        if let pickedWhoop { return pickedWhoop.name.isEmpty ? (type.map(typeTitle) ?? String(localized: "Device")) : pickedWhoop.name }
        if let pickedStrap { return pickedStrap.name }
        if let pickedMachine { return pickedMachine.name }
        if let pickedHuami { return pickedHuami.name }
        if let pickedOura { return pickedOura.ring.name }
        return type.map(typeTitle) ?? String(localized: "Device")
    }
    private var confirmBrand: String {
        if type?.isWhoop == true { return "WHOOP" }
        if type == .gymEquipment { return String(localized: "Gym equipment") }
        // Experimental non-Oura types (Amazfit / Mi Band / Garmin) take their stored brand string straight
        // from the catalog via the type→brand bridge. Oura falls through to its detected-generation label.
        if let brand = type?.experimentalBrand, brand != .oura { return brand.displayBrand }
        // Oura confirms with the detected generation name + a Beta marker so the user sees what NOOP
        // identified before adopting (the gen is best-effort from the scan, fixed by this pick).
        if let pickedOura { return String(localized: "\(pickedOura.gen.displayName) · Beta") }
        if let pickedStrap { return brandGuess(from: pickedStrap.name) }
        return String(localized: "Heart-rate strap")
    }
    private var confirmRSSI: Int {
        pickedWhoop?.rssi ?? pickedStrap?.rssi ?? pickedMachine?.rssi ?? pickedHuami?.rssi ?? pickedOura?.ring.rssi ?? -70
    }

    // MARK: Actions

    private func goBack() {
        // The Oura type walks its own step machine; back falls out to the type list from the gate.
        if type == .oura {
            ouraGoBack()
            return
        }
        switch step {
        case .type:    break
        case .prep:    step = .type
        case .pick:    stopAllScans(); pendingPick = nil; step = .prep
        case .confirm:
            // Re-enter the pick step and restart its scan so the user can choose a different device.
            if let type { startScan(for: type) }
            pickedWhoop = nil; pickedStrap = nil; pickedMachine = nil; pickedHuami = nil; pickedOura = nil
            step = .pick
        }
    }

    /// Back inside the Oura adopt sub-flow. Adopting has no meaningful back (a key install is in flight, and
    /// `showBack` already hides it there); from Failed, back returns to the pick step to try again, so the
    /// user is never trapped. Mirrors the Android `ouraGoBack`.
    private func ouraGoBack() {
        switch ouraStep {
        case .gate:
            // From the Advanced key field, back returns to the standard consent gate; from the standard gate,
            // back exits to the device-type list.
            if ouraAdvancedKeyMode {
                ouraAdvancedKeyMode = false
                ouraKeyDraft = ""
            } else {
                type = nil
                ouraConsented = false
            }
        case .prep:
            ouraStep = .gate
        case .pick:
            ouraScanner.stop()
            pickedOura = nil
            pendingPick = nil
            ouraStep = ouraAdvancedKeyMode ? .gate : .prep
        case .confirm:
            ouraScanner.scan()
            pickedOura = nil
            pendingPick = nil
            ouraStep = .pick
        case .adopting, .failed:
            ouraScanner.scan()
            pickedOura = nil
            pendingPick = nil
            ouraStep = .pick
        }
    }

    private func startScan(for type: DeviceType) {
        pendingPick = nil   // a fresh scan starts with nothing ticked
        switch type {
        case .whoop4, .whoop5mg: model.presentWhoopScan(model: type.whoopModel ?? .whoop4)
        case .gymEquipment:      ftmsScanner.scan()
        case .amazfit, .miBand:  huamiScanner.scan()
        case .oura:              ouraScanner.scan()
        // Heart-rate strap AND Garmin both use the standard 0x180D scanner (Garmin Broadcast HR).
        case .hrStrap, .garmin:  hrScanner.scan()
        }
    }

    private func stopAllScans() {
        model.stopWhoopScan()
        hrScanner.stopScan()
        ftmsScanner.stopScan()
        huamiScanner.stopScan()
        ouraScanner.stop()
    }

    /// Build the right `PairedDevice` for the chosen path, register it, optionally activate, then close.
    private func finishAdd(makeActive: Bool) {
        stopAllScans()
        let now = Int(Date().timeIntervalSince1970)
        let name = confirmName
        let device: PairedDevice

        if let pickedWhoop, let type, let wm = type.whoopModel {
            // WHOOP: honest live capability set (no calibrated SpO₂ % — import-only; #548);
            // id namespaced by uuid; model "4.0" / "5.0 MG". Steps only on 5.0/MG.
            let modelLabel = (wm == .whoop4) ? "4.0" : "5.0 MG"
            device = PairedDevice(
                id: "whoop-\(pickedWhoop.uuid)",
                brand: "WHOOP",
                model: modelLabel,
                nickname: name,
                peripheralId: pickedWhoop.uuid,
                sourceKind: .liveBLE,
                capabilities: WhoopLiveCapabilities.metrics(forModel: modelLabel),
                status: .paired,
                addedAt: now, lastSeenAt: now)
        } else if let pickedStrap {
            // Generic HR strap OR a Garmin broadcasting standard HR. Garmin's brand + id prefix come from
            // the catalog (via the type→brand bridge); it still stores `.liveBLE` (its live HR IS the
            // standard 0x180D path). A non-Garmin strap keeps the advertised-name brand guess + "strap"
            // prefix. Both are HR + HRV.
            let garmin = (type == .garmin) ? ExperimentalBrand.garmin : nil
            device = PairedDevice(
                id: "\(garmin?.idPrefix ?? "strap")-\(pickedStrap.id.uuidString)",
                brand: garmin?.displayBrand ?? brandGuess(from: pickedStrap.name),
                model: pickedStrap.name,
                nickname: name == pickedStrap.name ? nil : name,
                peripheralId: pickedStrap.id.uuidString,
                sourceKind: .liveBLE,
                capabilities: [.hr, .hrv],
                status: .paired,
                addedAt: now, lastSeenAt: now)
        } else if let pickedHuami {
            // EXPERIMENTAL Amazfit / Zepp / Mi Band. Brand string, id prefix, and the `.huami` routing all
            // come from the catalog via the type→brand bridge (was: `(type == .miBand) ? "Mi Band" : …`).
            // HR only (the Huami custom characteristic carries no R-R).
            let brand = type?.experimentalBrand ?? .amazfit
            device = PairedDevice(
                id: "\(brand.idPrefix)-\(pickedHuami.id.uuidString)",
                brand: brand.displayBrand,
                model: pickedHuami.name,
                nickname: name == pickedHuami.name ? nil : name,
                peripheralId: pickedHuami.id.uuidString,
                sourceKind: brand.sourceKind,
                capabilities: [.hr],
                status: .paired,
                addedAt: now, lastSeenAt: now)
        } else if let pickedMachine {
            // FTMS gym machine: a live machine + (when reported) HR session, recorded via the existing
            // live-workout path. sourceKind `.ftms` routes the SourceCoordinator to the FTMSSource.
            device = PairedDevice(
                id: "ftms-\(pickedMachine.id.uuidString)",
                brand: "Gym equipment",
                model: pickedMachine.name,
                nickname: name == pickedMachine.name ? nil : name,
                peripheralId: pickedMachine.id.uuidString,
                sourceKind: .ftms,
                capabilities: [.hr],
                status: .paired,
                addedAt: now, lastSeenAt: now)
        } else {
            // The Oura type commits through its own `commitOuraAdopt` / `finishAdvancedOura`, never here.
            onClose(); return
        }

        model.registerDevice(device, makeActive: makeActive)
        onClose()
    }

    // MARK: Oura commit (the two Oura paths, NOT the generic finishAdd)

    /// Build the `.oura` `PairedDevice` for the picked ring. sourceKind `.oura` routes the SourceCoordinator
    /// to the OuraLiveSource (its OWN central, never the WHOOP path). The generation rides `model`
    /// (OuraRingGen.from(model:) recovers it), and the capability set is gen-filtered. NOOP computes its own
    /// Charge/Rest from the ring's raw signals; it never reads Oura's encrypted readiness/sleep scores, and a
    /// signal it can't read stays "-" (honest-data invariant). Returns nil when no ring is picked.
    private func buildOuraDevice() -> PairedDevice? {
        guard let pickedOura else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        let gen = pickedOura.gen
        let uuid = pickedOura.ring.id.uuidString
        let name = confirmName
        // Brand string, id prefix, and the `.oura` routing come from the catalog via the type→brand bridge.
        let oura = ExperimentalBrand.oura
        return PairedDevice(
            id: "\(oura.idPrefix)-\(uuid)",
            brand: oura.displayBrand,
            model: gen.displayName,
            nickname: name == String(localized: "Oura ring") ? nil : name,
            peripheralId: uuid,
            sourceKind: oura.sourceKind,
            capabilities: ouraCapabilities(for: gen),
            status: .paired,
            addedAt: now, lastSeenAt: now)
    }

    /// COMMIT the standard destructive adopt: reached ONLY from the "Take over" confirm (the SECOND
    /// irreversible gate, after the consent tick). It grants the coordinator adopt consent for THIS ring and
    /// registers it active; the live source then runs the one-time key install (s3.2). The wizard moves to its
    /// honest Adopting step, which the live source's adopt phase drives to success (close) or Failed. NO key is
    /// stored here: the live install persists NOOP's freshly-generated key only on an OK `0x25` ack.
    private func commitOuraAdopt() {
        guard let device = buildOuraDevice() else { onClose(); return }
        stopAllScans()
        ouraStep = .adopting
        model.adoptOuraRing(device)   // grants adopt consent + registers active; never prompts make-active
    }

    /// COMMIT the non-destructive Advanced-key path: persist the user-supplied 16-byte key, register the ring
    /// active (it authenticates with that key, no reset, no install), then close. This path NEVER installs a
    /// key and NEVER passes through the Adopting/Take-over gates. Validates the key first (the Scan button was
    /// already gated on a valid key, so this is belt-and-braces).
    private func finishAdvancedOura() {
        guard let device = buildOuraDevice(), let key = ouraKeyBytes else { onClose(); return }
        stopAllScans()
        OuraKeyStore.save(key, deviceId: device.id)
        // The user supplied their own key; this is their new live source. Register active (no adopt consent,
        // so the live source can NEVER install a key on this path).
        model.registerDevice(device, makeActive: true)
        onClose()
    }

    /// Map the protocol package's per-gen `OuraMetric` set onto the app's `Metric` set for registration.
    /// Gen3+ all expose the same dictionary, so this is currently uniform, but it is gen-filtered so a
    /// future gen-specific gate is a one-line change (per OURA_PROTOCOL.md s7.2). SpO2 registers as the
    /// `.spo2` capability for the RAW ADC signal only; NO absolute SpO2 percentage is ever claimed.
    private func ouraCapabilities(for gen: OuraRingGen) -> Set<Metric> {
        var caps: Set<Metric> = []
        for m in gen.capabilities {
            switch m {
            case .hr:       caps.insert(.hr)
            case .hrv:      caps.insert(.hrv)
            case .spo2:     caps.insert(.spo2)
            case .skinTemp: caps.insert(.skinTemp)
            case .sleep:    caps.insert(.sleep)
            }
        }
        return caps
    }

    // MARK: Copy / helpers

    private func typeTitle(_ t: DeviceType) -> String {
        switch t {
        case .whoop5mg:     return "WHOOP 5.0 / MG"
        case .whoop4:       return "WHOOP 4.0"
        case .hrStrap:      return String(localized: "Heart-rate strap")
        case .gymEquipment: return String(localized: "Gym equipment")
        case .amazfit:      return "Amazfit / Zepp"
        case .miBand:       return "Xiaomi Mi Band"
        case .garmin:       return String(localized: "Garmin watch")
        case .oura:         return String(localized: "Oura ring")
        }
    }

    /// A shared "this tier is experimental" note shown on every experimental prep step. Honest, US-neutral,
    /// no em-dashes.
    private var experimentalTierNote: some View {
        NoticeCard(icon: "flask", tint: StrandPalette.statusWarning, title: nil,
                   message: "Experimental, best-effort support. We're still testing these, so they might not connect on every device. They never make up data, and they'll tell you honestly when live isn't possible.")
    }

    /// The same note as a quiet caption under the experimental list on the type step.
    private var experimentalTierCaption: some View {
        Text("Experimental, best-effort support. We're still testing these, so they might not connect on every device. They never make up data, and they'll tell you honestly when live isn't possible.")
            .font(StrandFont.light(11.5, relativeTo: .caption2))
            .lineSpacing(3)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private var experimentalNote: some View {
        NoticeCard(icon: "flask", tint: StrandPalette.statusWarning, title: nil,
                   message: "WHOOP 5.0 / MG supports live data and strap history. Protocol-research tools are available separately in Test Centre.")
    }

    /// A6 , the "one phone at a time" warning shown before a WHOOP scan. A failed pairing is most often the
    /// official WHOOP app still holding the band's single BLE link; saying so up front (with the concrete
    /// fix) is the honest, frustration-saving move. The warning glyph carries the amber so it reads as
    /// "heads-up", not "error".
    private var singleConnectionWarning: some View {
        NoticeCard(icon: "warning", tint: StrandPalette.statusWarning,
                   title: "Your WHOOP only talks to one phone at a time.",
                   message: "Force-quit the official WHOOP app first, or pairing may fail.")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Heads-up. Your WHOOP only talks to one phone at a time. Force-quit the official WHOOP app first, or pairing may fail.")
    }

    private var whoopFirstNote: some View {
        HStack(alignment: .top, spacing: 10) {
            PhIcon("info", size: 14)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.top, 1)
            Text("WHOOP is NOOP's primary, fully-supported band. Other heart-rate straps stream live heart rate and HRV, but not WHOOP's deeper sleep and recovery data.")
                .font(StrandFont.light(11.5, relativeTo: .caption2))
                .lineSpacing(3)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    /// Best-effort brand from the advertised name; neutral fallback for unknown straps. Delegates to the
    /// pure `DeviceBrandCatalog` (single source of truth), so the token table lives once.
    private func brandGuess(from name: String) -> String {
        DeviceBrandCatalog.spec(forAdvertisedName: name)?.brand ?? String(localized: "Heart-rate strap")
    }
}

/// A ticked scan result waiting for `Next`: the row's id, and the selection it commits.
private struct PendingPick {
    let id: String
    let commit: () -> Void
}

// MARK: - WHOOP pick list (observes BLEManager's present-scan)

/// The WHOOP family pick step. Holds `@ObservedObject ble` so the list re-renders as the present-scan
/// surfaces straps in `discoveredWhoops`. Pure UI — selection + scan lifecycle live in the wizard.
private struct WhoopPickList: View {
    @ObservedObject var ble: BLEManager
    let selectedId: String?
    let onSelect: ((uuid: String, name: String, rssi: Int)) -> Void
    let onRescan: () -> Void

    var body: some View {
        let found = ble.discoveredWhoops.sorted { $0.rssi > $1.rssi }
        PickPanel(items: found.map { PickItem(id: $0.uuid, name: $0.name.isEmpty ? "WHOOP" : $0.name,
                                              subtitle: "WHOOP", rssi: $0.rssi, icon: "watch") },
                  searching: true, selectedId: selectedId, onRescan: onRescan,
                  onSelect: { item in if let strap = found.first(where: { $0.uuid == item.id }) { onSelect(strap) } },
                  note: nil) {
            SearchingCard(whoopHint: true)
        }
    }
}

// MARK: - HR strap pick list (observes its own StandardHRSource)

private struct HRPickList: View {
    @ObservedObject var scanner: StandardHRSource
    let selectedId: String?
    let onSelect: (StandardHRSource.DiscoveredStrap) -> Void
    let onRescan: () -> Void

    var body: some View {
        let found = scanner.discovered.sorted { $0.rssi > $1.rssi }
        PickPanel(items: found.map { PickItem(id: $0.id.uuidString, name: $0.name,
                                              subtitle: brandGuess(from: $0.name), rssi: $0.rssi, icon: "heartbeat") },
                  searching: scanner.scanning, selectedId: selectedId, onRescan: onRescan,
                  onSelect: { item in if let strap = found.first(where: { $0.id.uuidString == item.id }) { onSelect(strap) } },
                  note: String(localized: "Not listed? Disconnect it from your watch or bike computer first — straps pair with one device at a time.")) {
            SearchingCard()
        }
    }

    private func brandGuess(from name: String) -> String {
        DeviceBrandCatalog.spec(forAdvertisedName: name)?.brand ?? String(localized: "Heart-rate strap")
    }
}

// MARK: - FTMS gym-equipment pick list (observes its own FTMSSource)

private struct FTMSPickList: View {
    @ObservedObject var scanner: FTMSSource
    let selectedId: String?
    let onSelect: (FTMSSource.DiscoveredMachine) -> Void
    let onRescan: () -> Void

    var body: some View {
        let found = scanner.discovered.sorted { $0.rssi > $1.rssi }
        PickPanel(items: found.map { PickItem(id: $0.id.uuidString, name: $0.name,
                                              subtitle: String(localized: "Gym equipment"), rssi: $0.rssi, icon: "bicycle") },
                  searching: scanner.scanning, selectedId: selectedId, onRescan: onRescan,
                  onSelect: { item in if let m = found.first(where: { $0.id.uuidString == item.id }) { onSelect(m) } },
                  note: nil) {
            SearchingCard()
        }
    }
}

// MARK: - Huami experimental pick list (Amazfit / Zepp / Mi Band)

private struct HuamiPickList: View {
    @ObservedObject var scanner: HuamiHRSource
    let selectedId: String?
    let onSelect: (HuamiHRSource.DiscoveredDevice) -> Void
    let onRescan: () -> Void

    var body: some View {
        let found = scanner.discovered.sorted { $0.rssi > $1.rssi }
        PickPanel(items: found.map { PickItem(id: $0.id.uuidString, name: $0.name,
                                              subtitle: String(localized: "Experimental"), rssi: $0.rssi, icon: "watch") },
                  searching: scanner.scanning, selectedId: selectedId, onRescan: onRescan,
                  onSelect: { item in if let d = found.first(where: { $0.id.uuidString == item.id }) { onSelect(d) } },
                  note: nil) {
            SearchingCard()
        }
    }
}

// MARK: - Oura experimental pick list (real live scan → adopt, honest needs-pairing fallback)

/// The Oura ring pick step. Observes the discovery-only `OuraLiveSource` and lists found rings as real
/// rows (like `HuamiPickList`). Ticking a ring and tapping Next proceeds to confirm + adopt rather than
/// dead-ending. When the source reports `needsPairing` (the ring is still owned by Oura, was not reset, or
/// the key was rejected), the honest message + a "Use file import" fallback replaces the list, so the
/// non-destructive lane is always one tap away (spec docs/superpowers/specs/2026-06-29-oura-onboarding-ux.md).
private struct OuraPickList: View {
    @ObservedObject var scanner: OuraLiveSource
    let selectedId: String?
    let onSelect: (OuraLiveSource.DiscoveredRing) -> Void
    let onRescan: () -> Void
    /// Tapped when the user takes the honest non-destructive fallback and heads to file import.
    let onUseImport: () -> Void

    var body: some View {
        let found = scanner.needsPairing == nil ? scanner.discovered.sorted { $0.rssi > $1.rssi } : []
        PickPanel(items: found.map { ring in
                      PickItem(id: ring.id.uuidString, name: ring.name,
                               subtitle: String(localized: "\(ring.detectedGen?.displayName ?? String(localized: "Oura ring")) · Beta"),
                               rssi: ring.rssi, icon: "circle")
                  },
                  searching: scanner.scanning, selectedId: selectedId, onRescan: onRescan,
                  onSelect: { item in if let r = found.first(where: { $0.id.uuidString == item.id }) { onSelect(r) } },
                  note: nil) {
            if let msg = scanner.needsPairing {
                // Honest needs-pairing state: the ring won't answer (still Oura-owned / not reset). Never a
                // fabricated reading: point at the file-import lane instead.
                NoopCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            PhIcon("info", size: 16)
                                .foregroundStyle(StrandPalette.statusWarning)
                                .padding(.top, 1)
                            Text(msg)
                                .font(StrandFont.light(14, relativeTo: .subheadline))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button { onUseImport() } label: { Text("Use file import") }
                            .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                            .accessibilityLabel("Use file import for Oura")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    SearchingCard()
                    Text("Not showing up? Make sure you reset the ring in the Oura app and force-quit it, then tap Rescan. A ring still owned by Oura will not list here.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }
        }
    }
}

// MARK: - Shared pick-step pieces

/// One scan result, in the shape the shared pick panel draws.
private struct PickItem: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let rssi: Int
    let icon: String
}

/// The pick step: the radar hero with every result placed by signal strength, then the results as a
/// radio list (strongest first). `empty` stands in for the list while nothing has been heard.
private struct PickPanel<Empty: View>: View {
    let items: [PickItem]
    let searching: Bool
    let selectedId: String?
    let onRescan: () -> Void
    let onSelect: (PickItem) -> Void
    let note: String?
    @ViewBuilder var empty: () -> Empty

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickRadar(items: items, selectedId: selectedId, searching: searching, onRescan: onRescan)
            if items.isEmpty {
                empty().padding(.top, 12)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(items.count) nearby")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Text("Strongest signal first")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(.top, 24)
                NoopList {
                    ForEach(items) { item in
                        PickRow(item: item, selected: item.id == selectedId) { onSelect(item) }
                    }
                }
                .padding(.top, 12)
            }
            if let note {
                Text(note)
                    .font(StrandFont.light(11.5, relativeTo: .caption2))
                    .lineSpacing(3)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 12)
            }
        }
    }
}

/// One scan result row: type tile, name, kind + live signal, bars, and a radio that becomes an ink check.
private struct PickRow: View {
    let item: PickItem
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 13) {
                WizardIconTile(icon: item.icon, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Text(String(localized: "\(item.subtitle) · \(item.rssi) dBm"))
                        .font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                WizardSignalBars(rssi: item.rssi)
                if selected {
                    PhIcon("check-circle", weight: .fill, size: 29.5)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: 24, height: 24)
                } else {
                    Circle()
                        .strokeBorder(StrandPalette.textPrimary.opacity(0.24), lineWidth: 1.5)
                        .frame(width: 24, height: 24)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .padding(.vertical, 13)
            .background(StrandPalette.textPrimary.opacity(selected ? 0.05 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.name), signal \(SignalBars.level(for: item.rssi)) of 4")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The blue radar hero of the pick step: arcs around the phone at the bottom edge, every heard device
/// as a dot whose distance follows its signal, the scan state and Rescan.
private struct PickRadar: View {
    let items: [PickItem]
    let selectedId: String?
    let searching: Bool
    let onRescan: () -> Void

    var body: some View {
        NoopHeroCard(glow: .strain, padding: 0) {
            ZStack(alignment: .bottom) {
                RadarField(items: Array(items.prefix(8)), selectedId: selectedId)
                    .frame(height: 236)
                PhIcon("device-mobile", size: 18)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .opacity(0.9)
                    .padding(.bottom, 6)
                VStack {
                    HStack {
                        if searching {
                            RadarLivePill(title: "Searching…")
                        } else {
                            NoopPill("Idle", compact: true)
                        }
                        Spacer(minLength: 8)
                        Button(action: onRescan) {
                            HStack(spacing: 6) {
                                PhIcon("arrows-clockwise", size: 13)
                                Text("Rescan").font(StrandFont.book(12, relativeTo: .caption))
                            }
                            .foregroundStyle(StrandPalette.textPrimary)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
                            .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .padding(22)
            }
            .frame(height: 262)
            .frame(maxWidth: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: NoopVisualStyle.heroRadius, style: .continuous))
    }
}

/// Arcs centred on the bottom edge and one dot per device. A stronger signal sits nearer the phone; each
/// device keeps a stable bearing derived from its id so the dots don't shuffle as readings update.
private struct RadarField: View {
    let items: [PickItem]
    let selectedId: String?

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height)
            let rings: [(CGFloat, Double, Bool)] = [(62, 0.42, false), (112, 0.26, false), (162, 0.15, true), (212, 0.08, false)]
            for (r, o, dashed) in rings {
                let path = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                ctx.stroke(path, with: .color(.white.opacity(o)),
                           style: StrokeStyle(lineWidth: 1, dash: dashed ? [2, 5] : []))
            }
            let bearings = Self.spreadBearings(items.map(\.id))
            var points: [String: CGPoint] = [:]
            for item in items {
                let r = min(max(62 + CGFloat(-45 - item.rssi) * 3.5, 74), 205)
                let a = (bearings[item.id] ?? Self.bearing(item.id)) * .pi / 180
                let p = CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y - r * CGFloat(sin(a)))
                points[item.id] = p
                if item.id == selectedId {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28)),
                             with: .color(.white.opacity(0.12)))
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)),
                               with: .color(.white.opacity(0.5)), lineWidth: 1)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.white))
                } else {
                    let weak = item.rssi < -80
                    let d: CGFloat = weak ? 3 : 3.4
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - d, y: p.y - d, width: d * 2, height: d * 2)),
                             with: .color(.white.opacity(weak ? 0.4 : 0.75)))
                }
            }
            // Labels after the dots, the selected one first, then strongest first: each takes the first
            // free spot (its usual side, the other side, then a line above or below), so two names never
            // print over each other. Labels on the right half hang to the left of their dot.
            // Every dot counts as taken too, so a name never prints across another device's dot.
            var placed: [CGRect] = points.values.map { CGRect(x: $0.x - 5, y: $0.y - 5, width: 10, height: 10) }
            let order = items.sorted { a, b in
                if (a.id == selectedId) != (b.id == selectedId) { return a.id == selectedId }
                return a.rssi > b.rssi
            }
            for item in order {
                guard let p = points[item.id] else { continue }
                let selected = item.id == selectedId
                let weak = item.rssi < -80
                let text = Text(verbatim: String(item.name.prefix(14)))
                    .font(StrandFont.light(selected ? 10.5 : 10))
                    .foregroundColor(.white.opacity(selected ? 1 : (weak ? 0.4 : 0.62)))
                let resolved = ctx.resolve(text)
                let m = resolved.measure(in: CGSize(width: size.width, height: 40))
                let gap: CGFloat = selected ? 14 : 9
                let y = selected ? p.y - 10 : p.y
                let preferLeft = p.x > size.width * 0.62
                func rect(left: Bool, dy: CGFloat) -> CGRect {
                    CGRect(x: left ? p.x - gap - m.width : p.x + gap, y: y + dy - m.height / 2,
                           width: m.width, height: m.height)
                }
                let candidates = [rect(left: preferLeft, dy: 0), rect(left: !preferLeft, dy: 0),
                                  rect(left: preferLeft, dy: -(m.height + 2)), rect(left: preferLeft, dy: m.height + 2)]
                let fits: (CGRect) -> Bool = { r in
                    r.minX >= 4 && r.maxX <= size.width - 4 && !placed.contains { $0.insetBy(dx: -3, dy: -1).intersects(r) }
                }
                let chosen = candidates.first(where: fits) ?? candidates[0]
                placed.append(chosen)
                ctx.draw(resolved, at: CGPoint(x: chosen.midX, y: chosen.midY), anchor: .center)
            }
            let phone = Path(ellipseIn: CGRect(x: c.x - 24, y: c.y - 26, width: 48, height: 48))
            ctx.fill(phone, with: .color(NoopVisualStyle.surface))
            ctx.stroke(phone, with: .color(.white.opacity(0.35)), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    /// A bearing between 25° and 155° (0° = right, counter-clockwise), from an FNV-1a hash of the id.
    static func bearing(_ id: String) -> Double {
        var h: UInt32 = 2_166_136_261
        for u in id.utf16 { h = (h ^ UInt32(u)) &* 16_777_619 }
        return 25 + Double(h % 130)
    }

    /// The hashed bearings pushed at least `minGap`° apart, in bearing order (so a device keeps its place
    /// relative to the others): two hashes a few degrees apart otherwise stack their dots and labels.
    static func spreadBearings(_ ids: [String], minGap: Double = 24) -> [String: Double] {
        let sorted = ids.map { ($0, bearing($0)) }.sorted { $0.1 < $1.1 }
        guard sorted.count > 1 else { return Dictionary(sorted, uniquingKeysWith: { a, _ in a }) }
        let gap = min(minGap, 130 / Double(sorted.count - 1))
        var out = sorted.map(\.1)
        for i in 1..<out.count where out[i] - out[i - 1] < gap { out[i] = out[i - 1] + gap }
        if out[out.count - 1] > 155 {
            // Pushed past the right-hand edge: walk the run back from 155°.
            out[out.count - 1] = 155
            for i in stride(from: out.count - 2, through: 0, by: -1) where out[i + 1] - out[i] < gap {
                out[i] = out[i + 1] - gap
            }
        }
        return Dictionary(zip(sorted.map(\.0), out), uniquingKeysWith: { a, _ in a })
    }
}

/// A compact hero pill with a glowing white dot: the scan is running.
private struct RadarLivePill: View {
    let title: LocalizedStringKey
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.white).frame(width: 7, height: 7)
                .background(Circle().fill(Color.white.opacity(0.14)).frame(width: 15, height: 15))
                .shadow(color: .white.opacity(0.8), radius: 6)
            Text(title).font(StrandFont.book(12, relativeTo: .caption)).lineLimit(1)
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
    }
}

private struct SearchingCard: View {
    /// A6 , honest phase copy. WHOOP scans add the single-link reminder under the generic line, since a
    /// stuck scan there is almost always the official app still holding the band. Defaults off so the HR /
    /// FTMS / Huami / Oura pick lists keep their existing copy unchanged.
    var whoopHint: Bool = false
    var body: some View {
        NoopCard(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView().tint(StrandPalette.textPrimary)
                    Text("Searching…")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text("Make sure it's awake and not connected elsewhere.")
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if whoopHint {
                    HStack(alignment: .top, spacing: 8) {
                        PhIcon("warning", size: 14)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .padding(.top, 1)
                        Text("Not showing up? The official WHOOP app may still be holding it. Force-quit that app, then tap Rescan.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: - Wizard pieces

/// The four progress dashes across the top bar.
private struct WizardDashes: View {
    let count: Int
    let filled: Int
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(i < filled ? StrandPalette.textPrimary : StrandPalette.textPrimary.opacity(0.14))
                    .frame(height: 3)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(StrandMotion.gentle, value: filled)
        .accessibilityHidden(true)
    }
}

/// The rounded device tile of the type and pick lists (a raised gradient square behind a hairline).
private struct WizardIconTile: View {
    let icon: String
    var size: CGFloat = 42
    var body: some View {
        PhIcon(icon, size: size * 0.48)
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size / 3, style: .continuous)
                .fill(LinearGradient(colors: [NoopVisualStyle.raised, NoopVisualStyle.inset],
                                     startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: size / 3, style: .continuous)
                .strokeBorder(NoopVisualStyle.border, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// The type list's radio: an empty ring, or an ink ring around an ink dot.
private struct RadioMark: View {
    let on: Bool
    var body: some View {
        ZStack {
            Circle().strokeBorder(on ? StrandPalette.textPrimary : StrandPalette.textPrimary.opacity(0.24), lineWidth: 1.5)
            if on { Circle().fill(StrandPalette.textPrimary).frame(width: 10, height: 10) }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// The small hairline "Beta" capsule beside an experimental source.
private struct BetaTag: View {
    var body: some View {
        Text("Beta")
            .font(StrandFont.book(10, relativeTo: .caption2))
            .tracking(0.2)
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
    }
}

/// The Oura consent tick: an empty rounded square, or a filled one with a check, in the critical colour.
private struct ConsentBox: View {
    let on: Bool
    var body: some View {
        PhIcon(on ? "check-square" : "square", weight: on ? .fill : .light, size: 22)
            .foregroundStyle(StrandPalette.statusCritical)
            .accessibilityHidden(true)
    }
}

/// Signal strength as four rising bars (`SignalBars.level` thresholds), lit in ink.
private struct WizardSignalBars: View {
    let rssi: Int
    var body: some View {
        let level = SignalBars.level(for: rssi)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                    .fill(i < level ? StrandPalette.textPrimary : StrandPalette.textPrimary.opacity(0.2))
                    .frame(width: 4, height: 5 + CGFloat(i) * 3.67)
            }
        }
        .frame(width: 22, height: 16, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// A heads-up card: a tinted glyph beside an optional title and a secondary paragraph.
private struct NoticeCard: View {
    let icon: String
    let tint: Color
    let title: LocalizedStringKey?
    let message: LocalizedStringKey

    var body: some View {
        NoopCard(padding: 16) {
            HStack(alignment: .top, spacing: 12) {
                PhIcon(icon, size: 16)
                    .foregroundStyle(tint)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    if let title {
                        Text(title)
                            .font(StrandFont.book(14, relativeTo: .subheadline))
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Text(message)
                        .font(StrandFont.light(13, relativeTo: .footnote))
                        .lineSpacing(2)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A `.tips .li` row: a small icon tile and one secondary sentence.
private struct WizardTipRow: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PhIcon(icon, size: 15)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(NoopVisualStyle.raised))
            Text(text)
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .lineSpacing(3)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 5)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}

/// "Your sources": the active device already feeding NOOP, a plus, and a dashed slot for the device being
/// added. Observes the registry so a just-registered device shows the moment it lands.
private struct SourcesHero: View {
    @ObservedObject var registry: DeviceRegistry
    let batteryPct: Double?
    let adding: (title: String, icon: String)?
    let icon: (PairedDevice) -> String

    private var sources: [PairedDevice] {
        registry.devices.filter { $0.status != .archived && !$0.isImportSource && $0.sourceKind != .activityFile }
    }

    private var lead: PairedDevice? {
        sources.first { $0.id == registry.activeDeviceId } ?? sources.first
    }

    var body: some View {
        NoopHeroCard(glow: .ink, padding: 16, cornerRadius: 30) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your sources")
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .textCase(.uppercase)
                    Spacer(minLength: 8)
                    Text("\(sources.count) paired")
                        .font(StrandFont.footnote)
                }
                .foregroundStyle(Color.white.opacity(0.55))
                .padding(.horizontal, 2)
                HStack(spacing: 8) {
                    if let lead {
                        SourceSlot(icon: icon(lead), title: lead.displayName, caption: caption(for: lead), dashed: false)
                        PhIcon("plus", size: 14)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .opacity(0.5)
                    }
                    SourceSlot(icon: adding?.icon ?? "plus",
                               title: adding?.title ?? String(localized: "New source"),
                               caption: adding == nil ? String(localized: "Pick one below") : String(localized: "Adding now"),
                               dashed: true)
                }
                // Both slots take the taller one's height when a caption wraps.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func caption(for d: PairedDevice) -> String {
        guard d.id == registry.activeDeviceId else { return String(localized: "Paired") }
        if let batteryPct { return String(localized: "\(Int(batteryPct.rounded())) % · active") }
        return String(localized: "Active")
    }
}

/// One slot in "Your sources" (a translucent capsule card; dashed for the one being added).
private struct SourceSlot: View {
    let icon: String
    let title: String
    let caption: String
    let dashed: Bool

    var body: some View {
        HStack(spacing: 8) {
            PhIcon(icon, size: 16)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StrandFont.book(13.5, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                // Two lines: the German caption ("Wähle unten einen aus") overruns a half-width slot.
                Text(caption)
                    .font(StrandFont.light(11, relativeTo: .caption2))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(dashed ? Color.black.opacity(0.25) : Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Color.white.opacity(dashed ? 0.3 : 0.1),
                          style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : [])))
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// The wizard's text field chrome: an inset rounded field behind a hairline.
    func wizardField() -> some View {
        self
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(NoopVisualStyle.inset))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(NoopVisualStyle.border, lineWidth: 1))
    }
}

#if DEBUG
/// Screenshot harness only: the pick step's radar and list filled with three made-up straps, so the
/// populated layout can be checked without hardware nearby.
struct AddDevicePickDemo: View {
    var body: some View {
        ScrollView {
            PickPanel(items: [
                PickItem(id: "a", name: "Polar H10 4E21", subtitle: "Polar", rssi: -52, icon: "heartbeat"),
                PickItem(id: "b", name: "HRM-Pro 0912", subtitle: "Garmin", rssi: -67, icon: "heartbeat"),
                PickItem(id: "c", name: "HR strap", subtitle: "Heart-rate strap", rssi: -81, icon: "question"),
            ], searching: true, selectedId: "a", onRescan: {}, onSelect: { _ in },
               note: String(localized: "Not listed? Disconnect it from your watch or bike computer first — straps pair with one device at a time.")) {
                EmptyView()
            }
            .padding(20)
        }
        .background(NoopVisualStyle.canvas.ignoresSafeArea())
    }
}
#endif

// MARK: - Preview

#if DEBUG
#Preview("Add device wizard") {
    let model = AppModel()
    return AddDeviceWizard(live: model.live, onClose: {})
        .environmentObject(model)
        .environmentObject(model.live)
        .frame(width: 480, height: 760)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}
#endif
