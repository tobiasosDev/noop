import SwiftUI
import UniformTypeIdentifiers
import StrandDesign
import StrandAnalytics
import WhoopStore
import UserNotifications

// MARK: - OnboardingWizard
//
// A full-screen, paged onboarding + pairing flow for NOOP, in the v2 language: a black ground, a
// back circle + twelve progress dashes + "n / 12" across the top, one hero per step, and a single
// ink pill CTA pinned at the bottom.
//
// Steps:
//  1 Welcome           — NOOP + "all your data, none of the cloud"
//  2 What it does      — three promises
//  3 What to expect    — independent / experimental framing
//  4 Bluetooth priming — explain BEFORE the OS prompt
//  5 Wear & wake       — put your strap on, make sure it's charged
//  6 Scan              — find the strap; Scan retries via model.scan()
//  7 Bonding           — "You're connected." once live.bonded
//  8 Profile           — date of birth / sex / units / weight / height bound to ProfileStore
//  9 Import (optional) — WHOOP / Apple Health import from the wizard
// 10 Notifications     — wrist alerts priming; the OS prompt fires when leaving this step
// 11 Appearance        — System / Light / Dark
// 12 Done              — "Your thread starts here." → onFinished()
//
// Presentation is wired centrally; this view only calls onFinished() when complete.

public struct OnboardingWizard: View {

    /// Called when the user finishes (or skips to the end of) onboarding.
    public var onFinished: () -> Void

    public init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    #if DEBUG
    /// Screenshot harness only: open the wizard at the step with this zero-based index.
    init(onFinished: @escaping () -> Void, debugStartStep: Int) {
        self.onFinished = onFinished
        _step = State(initialValue: Step(rawValue: debugStartStep) ?? .welcome)
    }
    #endif

    // NOTE: the root deliberately does NOT observe the fast-updating model/live/profile
    // env objects — doing so re-rendered the whole animated wizard on every HR tick and
    // caused flicker. Child steps observe what they need; a hidden BondWatcher (below)
    // handles the bond→celebration transition without re-rendering the root.

    private enum Step: Int, CaseIterable {
        case welcome, what, expectations, bluetooth, wear, scan, bonded, profile, importData, notifications, appearance, done

        var isFirst: Bool { self == .welcome }
        var isLast: Bool { self == .done }
    }

    @State private var step: Step = .welcome

    public var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 20)
                .padding(.top, topInset)

            // The paged content.
            ZStack {
                switch step {
                case .welcome:    WelcomeStep()
                case .what:       WhatItDoesStep()
                case .expectations: ExpectationsStep()
                case .bluetooth:  BluetoothStep()
                case .wear:       WearStep()
                case .scan:       ScanStep(advance: advance)
                case .bonded:     BondedStep()
                case .profile:    ProfileStep()
                case .importData: ImportStep()
                case .notifications: NotificationsStep()
                case .appearance: AppearanceStep()
                case .done:       DoneStep()
                }
            }
            .frame(maxWidth: 620, maxHeight: .infinity)
            .transition(stepTransition)
            .id(step)                       // re-runs the transition per step

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NoopVisualStyle.canvas.ignoresSafeArea())
        // Isolated live observation — a hidden watcher slides Scan → celebration on bond
        // without subscribing the whole wizard to per-tick updates.
        .background(BondWatcher(onBonded: handleBond))
    }

    private var topInset: CGFloat {
        #if os(macOS)
        return 28
        #else
        return 4
        #endif
    }

    private func handleBond() {
        if step == .scan { withAnimation(StrandMotion.hero) { step = .bonded } }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            if !step.isFirst {
                NoopCircleButton("caret-left", accessibilityLabel: "Back", action: back)
            }
            StepDashes(count: Step.allCases.count, filled: step.rawValue + 1)
            Text("\(step.rawValue + 1) / \(Step.allCases.count)")
                .font(StrandFont.book(12, relativeTo: .caption))
                .tracking(0.24)
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(height: 50)
        .frame(maxWidth: 620)
    }

    // MARK: Footer (the one forward CTA)

    private var footer: some View {
        VStack(spacing: 12) {
            Button(action: primaryAction) { Text(ctaTitle) }
                .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                .keyboardShortcut(.defaultAction)
            if let ctaCaption {
                Text(ctaCaption)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 620)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, bottomInset)
        // The kit's `.fade`: the step's content dissolves into the pinned CTA instead of being cut.
        .background(alignment: .top) {
            LinearGradient(colors: [NoopVisualStyle.canvas.opacity(0), NoopVisualStyle.canvas],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 28)
                .offset(y: -28)
                .allowsHitTesting(false)
        }
    }

    private var bottomInset: CGFloat {
        #if os(macOS)
        return 32
        #else
        return 4
        #endif
    }

    private var ctaTitle: String {
        switch step {
        case .welcome:    return String(localized: "Get Started")
        case .what:       return String(localized: "Continue")
        case .expectations: return String(localized: "I understand")
        case .bluetooth:  return String(localized: "Continue")
        case .wear:       return String(localized: "I'm wearing it")
        case .scan:       return String(localized: "Continue")
        case .bonded:     return String(localized: "Continue")
        case .profile:    return String(localized: "Save & Continue")
        case .importData: return String(localized: "Continue")
        case .notifications: return String(localized: "Continue")
        case .appearance: return String(localized: "Continue")
        case .done:       return String(localized: "Enter NOOP")
        }
    }

    private var ctaCaption: String? {
        switch step {
        case .bonded: return String(localized: "Sync keeps going in the background.")
        default:      return nil
        }
    }

    private func primaryAction() {
        if step.isLast {
            onFinished()
        } else {
            advance()
        }
    }

    // MARK: Navigation

    /// Leaving the Notifications step is the one point in onboarding where we actually ask the OS for
    /// notification permission — everything before this only explained why (the `NotificationsStep`
    /// card). Without this, NOOP never showed up under Settings → Notifications at all unless a user
    /// later found and enabled one of the opt-in automations (wind-down, battery, illness) buried in
    /// More → Alarms/Automations, each of which lazily requests on its own toggle. Mirrors the Android
    /// onboarding's `OnboardingPage.Notifications` step (`OnboardingScreen.kt`): request only if not
    /// already determined (so a re-run/upgrade doesn't re-prompt), and advance once the OS dialog is
    /// dismissed either way — the per-feature toggles still handle a later denial on their own.
    private func advance() {
        guard step != .notifications else {
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                guard settings.authorizationStatus == .notDetermined else {
                    Task { @MainActor in advanceStep() }
                    return
                }
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                    Task { @MainActor in advanceStep() }
                }
            }
            return
        }
        advanceStep()
    }

    private func advanceStep() {
        guard let next = Step(rawValue: step.rawValue + 1) else { onFinished(); return }
        withAnimation(StrandMotion.gentle) { step = next }
    }

    private func back() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(StrandMotion.gentle) { step = prev }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }
}

/// Hidden, isolated observer — re-renders on live updates (it's just Color.clear, so no
/// visible cost) and fires `onBonded` when the strap bonds, keeping the main wizard body
/// out of the per-tick re-render path that caused flicker.
private struct BondWatcher: View {
    @EnvironmentObject private var live: LiveState
    let onBonded: () -> Void
    var body: some View {
        Color.clear.onChangeCompat(of: live.bonded) { newValue in if newValue { onBonded() } }
    }
}

// MARK: - Step 1 · Welcome

private struct WelcomeStep: View {
    @State private var appear = false
    var body: some View {
        StepShell {
            NoopHeroCard(glow: .recovery, padding: 22) {
                VStack(spacing: 0) {
                    HStack {
                        NoopIconBadge("On-device", icon: "lock-simple")
                        Spacer(minLength: 8)
                        NoopPill(verbatim: String(localized: "Version \(UpdateWatch.installedVersion)"), compact: true)
                    }
                    Spacer(minLength: 24)
                    Text(verbatim: "NOOP")
                        .font(StrandFont.dot(100))
                        .tracking(StrandFont.dotTracking(100))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.leading, 6)
                        .scaleEffect(appear ? 1 : 0.92)
                        .opacity(appear ? 1 : 0)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 24)
                    VStack(spacing: 6) {
                        Text("Your strap, your \(Platform.deviceNoun),")
                        HStack(spacing: 6) {
                            NoopTag("Nothing")
                            Text("in between.")
                        }
                    }
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(Color.white.opacity(0.84))
                    .opacity(appear ? 1 : 0)
                }
                .frame(height: 386)
                .frame(maxWidth: .infinity)
                .background(alignment: .top) {
                    WelcomeRings()
                        .frame(width: 420, height: 420)
                        .offset(y: 164 - 210)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: NoopVisualStyle.heroRadius, style: .continuous))
            .padding(.top, 8)

            StepTitle(title: String(localized: "All your data,\nnone of the cloud."),
                      subtitle: String(localized: "Pair your strap. Everything else happens on \(Platform.deviceNounPhrase)."),
                      size: 32, subtitleGap: 10)
                .padding(.top, 28)
        }
        .onAppear { withAnimation(StrandMotion.hero) { appear = true } }
    }
}

/// Three faint concentric rings behind the welcome wordmark (the middle one dashed).
private struct WelcomeRings: View {
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.10), lineWidth: 1).frame(width: 192, height: 192)
            Circle().stroke(Color.white.opacity(0.07), style: StrokeStyle(lineWidth: 1, dash: [2, 6]))
                .frame(width: 280, height: 280)
            Circle().stroke(Color.white.opacity(0.05), lineWidth: 1).frame(width: 372, height: 372)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Step 2 · What it does

private struct WhatItDoesStep: View {
    var body: some View {
        StepShell {
            StepTitle(title: String(localized: "Three quiet promises."),
                      subtitle: String(localized: "What NOOP does for you — and what it never does."))
                .padding(.top, 24)
            NoopHeroCard(glow: .ink, padding: 12) {
                VStack(spacing: 10) {
                    PromiseCard(index: 1,
                                title: String(localized: "See recovery, beautifully"),
                                message: String(localized: "Charge, Effort and Rest — one calm glance every morning.")) {
                        ZStack {
                            NoopRingGauge(fraction: 0.78, lineWidth: 4)
                                .frame(width: 52, height: 52)
                            PhIcon("lightning", size: 18).foregroundStyle(StrandPalette.textPrimary)
                        }
                    }
                    PromiseCard(index: 2,
                                title: String(localized: "Watch your heart, live"),
                                message: String(localized: "Beat-by-beat heart rate, streamed straight from the strap.")) {
                        PulseTrace()
                            .overlay(alignment: .topLeading) {
                                Text("Live")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .padding(.top, 9).padding(.leading, 10)
                            }
                    }
                    PromiseCard(index: 3,
                                title: String(localized: "Own your data, offline"),
                                message: String(localized: "No account, no server. Export the whole archive any time.")) {
                        VStack(spacing: 5) {
                            NoopDotNumber("0", size: 40).padding(.leading, 3)
                            Text("accounts")
                                .font(StrandFont.light(9.5, relativeTo: .caption2))
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
            }
            .padding(.top, 20)
        }
    }
}

/// One promise: a dot-matrix index, a title and one line, with a small illustration tile at the right.
private struct PromiseCard<Viz: View>: View {
    let index: Int
    let title: String
    let message: String
    @ViewBuilder var viz: () -> Viz
    @State private var shown = false

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: String(format: "%02d", index))
                    .font(StrandFont.dot(38))
                    .tracking(StrandFont.dotTracking(38))
                    .accessibilityHidden(true)
                Text(title)
                    .font(StrandFont.book(16, relativeTo: .headline))
                    .tracking(-0.16)
                    .padding(.top, 12)
                Text(message)
                    .font(StrandFont.light(12.5, relativeTo: .footnote))
                    .lineSpacing(2)
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            viz()
                .frame(width: 84, height: 84)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
                .accessibilityHidden(true)
        }
        .padding(.vertical, 20)
        .padding(.leading, 20)
        .padding(.trailing, 18)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.13), Color.white.opacity(0.08)],
                                             startPoint: .top, endPoint: .center), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 14)
        .onAppear {
            withAnimation(StrandMotion.gentle.delay(Double(index - 1) * 0.10)) { shown = true }
        }
    }
}

/// A single heartbeat trace ending in a white dot (the "watch your heart" tile).
private struct PulseTrace: View {
    var body: some View {
        Canvas { ctx, size in
            // The 84-pt tile's trace, in tile points.
            let raw: [(CGFloat, CGFloat)] = [(12, 48), (20, 48), (24, 44), (28, 48), (34, 48), (37, 30), (41, 60),
                                             (45, 42), (49, 48), (58, 48), (62, 45), (66, 48), (72, 48)]
            let pts = raw.map { CGPoint(x: $0.0 * size.width / 84, y: $0.1 * size.height / 84) }
            var path = Path()
            path.addLines(pts)
            ctx.stroke(path, with: .color(StrandPalette.textPrimary),
                       style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            if let end = pts.last {
                ctx.fill(Path(ellipseIn: CGRect(x: end.x - 2.6, y: end.y - 2.6, width: 5.2, height: 5.2)),
                         with: .color(.white))
            }
        }
    }
}

// MARK: - Step 3 · What to expect (independent / experimental / 5-MG framing)

private struct ExpectationsStep: View {
    @State private var shown = false
    var body: some View {
        StepShell {
            StepTitle(title: String(localized: "What to expect"),
                      subtitle: String(localized: "A few honest words, so nothing's a surprise."))
                .padding(.top, 24)
            NoopList {
                ForEach(AppChangelog.expectations, id: \.id) { e in
                    InfoRow(icon: Self.phosphor(for: e.icon), title: e.title, message: e.body)
                }
                #if os(iOS)
                // The iPhone-only reality: this is a sideloaded build, so set the re-sign + unlock
                // expectation up front rather than letting it surprise people later (#222 / cert expiry).
                InfoRow(icon: "device-mobile",
                        title: String(localized: "Installed outside the App Store"),
                        message: String(localized: "On iPhone this is a sideloaded build. Re-sign it about every 7 days on a free Apple ID (longer on a paid account). After your phone reboots, unlock it once so NOOP can read and sync its data."))
                #endif
            }
            .padding(.top, 20)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
        }
        .onAppear { withAnimation(StrandMotion.gentle) { shown = true } }
    }

    /// `AppChangelog.expectations` names SF Symbols (shared with surfaces that still use them); the
    /// wizard draws the matching Phosphor glyph.
    static func phosphor(for symbol: String) -> String {
        switch symbol {
        case "flask":         return "flask"
        case "checkmark.seal": return "seal-check"
        case "hourglass":     return "hourglass"
        case "lock.shield":   return "shield-check"
        default:              return PhIcon.exists(symbol) ? symbol : "info"
        }
    }
}

// MARK: - Step 4 · Bluetooth priming

private struct BluetoothStep: View {
    var body: some View {
        StepShell {
            StepTitle(title: String(localized: "A quick word before we connect"),
                      subtitle: String(localized: "\(Platform.deviceNoun) will ask for Bluetooth in a moment."))
                .padding(.top, 24)
            NoopHeroCard(glow: .ink, padding: 0) {
                PulsingGlyph(icon: "bluetooth")
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 20)
            NoopCard {
                VStack(alignment: .leading, spacing: 10) {
                    NoopCardHeader(verbatim: String(localized: "Nothing leaves your \(Platform.deviceNoun)"),
                                   icon: "lock-simple") { EmptyView() }
                    Text("NOOP talks to your strap directly over Bluetooth Low Energy. There's no server in the middle. The connection is local, and so is every reading it pulls in.")
                        .font(StrandFont.light(14, relativeTo: .subheadline))
                        .lineSpacing(3)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 12)
            Text("When the system prompt appears, choose Allow so NOOP can find your strap.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
                .padding(.horizontal, 4)
        }
    }
}

/// A glyph in a translucent disc with a slow ring pulsing out of it (Bluetooth, notifications).
private struct PulsingGlyph: View {
    let icon: String
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode / "Reduce motion in NOOP" pose these looping glows still too. Onboarding is
    /// first-run only, but a `repeatForever` is a `repeatForever` wherever it lives.
    @ObservedObject private var motion = NoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 1).frame(width: 150, height: 150)
            Circle().stroke(Color.white.opacity(0.32), lineWidth: 1).frame(width: 104, height: 104)
            Circle()
                .stroke(Color.white.opacity(0.5), lineWidth: 1)
                .frame(width: 104, height: 104)
                .scaleEffect(pulse ? 1.6 : 1)
                .opacity(pulse ? 0 : 0.8)
            PhIcon(icon, size: 26)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color.white.opacity(0.10)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }
        .accessibilityHidden(true)
        .onAppear { if !poseStill { withAnimation(StrandMotion.breathe) { pulse = true } } }
    }
}

// MARK: - Step 5 · Wear & wake

private struct WearStep: View {
    var body: some View {
        StepShell {
            StepTitle(title: String(localized: "Put your strap on"),
                      subtitle: String(localized: "And make sure it's charged."))
                .padding(.top, 24)
            NoopHeroCard(glow: .ink, padding: 0) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 1).frame(width: 150, height: 150)
                    Circle().stroke(Color.white.opacity(0.09), lineWidth: 1).frame(width: 210, height: 210)
                    StrapGlyph()
                }
                .frame(height: 220)
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 20)
            NoopList {
                TipRow(icon: "watch", text: String(localized: "Wear it snug on your wrist or bicep, sensor against skin."))
                TipRow(icon: "plug-charging", text: String(localized: "Give it a few minutes of charge if the battery is low."))
                TipRow(icon: "bluetooth", text: String(localized: "Keep it within about a metre of \(Platform.deviceNounPhrase)."))
            }
            .padding(.top, 12)
        }
    }
}

/// The strap drawn as a watch-like body between two band stubs, tilted, with a lit sensor dot.
private struct StrapGlyph: View {
    var body: some View {
        ZStack {
            band.offset(y: -42)
            band.offset(y: 42)
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(NoopVisualStyle.raised)
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.34), lineWidth: 1))
                .frame(width: 48, height: 60)
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(NoopVisualStyle.surface)
                .frame(width: 36, height: 48)
            Circle().fill(Color.white.opacity(0.14)).frame(width: 12, height: 12).offset(y: -9)
            Circle().fill(Color.white).frame(width: 4.4, height: 4.4).offset(y: -9)
            Capsule().fill(Color.white.opacity(0.22)).frame(width: 14, height: 1).offset(y: 10)
        }
        .rotationEffect(.degrees(-16))
        .accessibilityHidden(true)
    }

    private var band: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(NoopVisualStyle.inset)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            .frame(width: 32, height: 40)
    }
}

// MARK: - Step 6 · Scan

private enum ScanPhase: Int {
    case ready, searching, connecting, connected
}

private struct ScanStep: View {
    let advance: () -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    @State private var scanning = false
    @State private var hasScanned = false

    /// Which strap to look for — shared with the Live screen via the same key.
    @AppStorage("selectedWhoopModel") private var selectedModelRaw = WhoopModel.whoop4.rawValue
    private var selectedModel: WhoopModel { WhoopModel(rawValue: selectedModelRaw) ?? .whoop4 }

    private var phase: ScanPhase {
        if live.bonded { return .connected }
        if live.connected { return .connecting }
        if scanning { return .searching }
        return .ready
    }

    var body: some View {
        StepShell {
            StepTitle(title: String(localized: "Find your strap"),
                      subtitle: live.bonded
                        ? String(localized: "Bonded. You're set.")
                        : String(localized: "Hold it next to your \(Platform.deviceNoun). NOOP finds a strap that is awake and not busy with another \(Platform.deviceNoun)."))
                .padding(.top, 22)

            if !live.bonded { picker.padding(.top, 22) }

            ScanHero(phase: phase, scanning: scanning && !live.bonded)
                .padding(.top, 16)

            if phase == .ready {
                Button(action: { startScan() }) {
                    Label { Text(hasScanned ? "Try again" : "Scan") } icon: { PhIcon("bluetooth", size: 16) }
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                .padding(.top, 12)
            }

            if live.connected { foundNearby }

            if !live.bonded { help }
        }
        .onDisappear { scanning = false }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which strap are you pairing?")
                .font(StrandFont.book(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
            SegmentedPillControl(
                WhoopModel.allCases,
                selection: Binding(
                    get: { selectedModel },
                    set: { restartScan(for: $0) }
                ),
                fillsAvailableWidth: true,
                label: { $0.displayName }
            )
            // Proactive 5/MG guidance (#130): the strap bonds to one host at a time, so a scan
            // here finds nothing while it's still paired in the official WHOOP app.
            if selectedModel == .whoop5mg {
                Text("WHOOP 5.0/MG pairs with one app at a time. If nothing's found, unpair it in the official WHOOP app and fully close that app, then Scan.")
                    .font(StrandFont.caption)
                    .lineSpacing(2)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// The strap the link is up with. There is no scan list to show: NOOP connects to the first
    /// matching strap it hears, so this row appears once that link exists.
    private var foundNearby: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Found nearby")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text("1 strap")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.top, 26)
            NoopList {
                NoopRow(verbatim: live.advertisingName ?? selectedModel.displayName,
                        caption: live.bonded ? String(localized: "\(selectedModel.displayName) · bonded")
                                             : String(localized: "\(selectedModel.displayName) · connecting…"),
                        icon: "watch") { EmptyView() }
            }
            .overlay(RoundedRectangle(cornerRadius: NoopVisualStyle.listRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
            .padding(.top, 12)
        }
    }

    // The calm, never-alarmist "can't find it" guidance.
    private var help: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Don't see it? That's normal.")
                .font(StrandFont.book(15, relativeTo: .body))
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.top, 26)
            Text("WHOOP straps don't appear in your \(Platform.deviceNoun)'s Bluetooth settings. They advertise on a custom profile that only apps like NOOP can find, so there's nothing to pair there, and you shouldn't try.")
                .font(StrandFont.light(13, relativeTo: .footnote))
                .lineSpacing(2)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            NoopList {
                TipRow(icon: "device-mobile", text: String(localized: "It isn't held by the WHOOP phone app. Only one host at a time: close the app or turn off its Bluetooth."))
                TipRow(icon: "plug-charging", text: String(localized: "It's charged and worn. The sensor needs skin contact to wake."))
                TipRow(icon: "bluetooth", text: String(localized: "It's within about a metre of \(Platform.deviceNounPhrase)."))
            }
            .padding(.top, 12)
            // WHOOP is NOOP's primary band, so onboarding leads with it — but it isn't required.
            // Make that obvious so a non-WHOOP user doesn't feel stuck here: they can continue now
            // and pair a heart-rate strap or import data afterwards (in Devices / Data Sources).
            Text("No WHOOP? You can still continue. Pair a heart-rate strap (Polar, Wahoo, Coospo, Garmin HRM…) or a gym machine under Devices, or import from WHOOP, Apple Health, Oura, Fitbit, Garmin and more under Data Sources. You can do either any time.")
                .font(StrandFont.caption)
                .lineSpacing(2)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .padding(.horizontal, 4)
        }
    }

    private func startScan(model scanModel: WhoopModel? = nil) {
        let modelToScan = scanModel ?? selectedModel
        scanning = true
        hasScanned = true
        model.scan(model: modelToScan)
        // Fall back to the idle state (and the "Try again" button) if we haven't bonded after a calm beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            if !live.bonded {
                withAnimation(StrandMotion.gentle) { scanning = false }
            }
        }
    }

    private func restartScan(for newModel: WhoopModel) {
        selectedModelRaw = newModel.rawValue
        guard !live.bonded else { return }
        model.disconnect()
        startScan(model: newModel)
    }
}

/// The blue scan hero: concentric rings with a sweeping arc around the strap, the live state pill,
/// and the four-stop pairing progress along the bottom.
private struct ScanHero: View {
    let phase: ScanPhase
    let scanning: Bool

    var body: some View {
        NoopHeroCard(glow: .strain, padding: 0) {
            ZStack(alignment: .top) {
                ScanRings(sweeping: scanning)
                    .frame(width: 346, height: 300)
                VStack(spacing: 0) {
                    HStack {
                        NoopIconBadge(phase == .searching ? "Scanning" : "Bluetooth", icon: "bluetooth")
                        Spacer(minLength: 8)
                        statePill
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    Spacer(minLength: 0)
                    ScanStepsRow(current: phase.rawValue)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 22)
                }
            }
            .frame(height: 318)
            .frame(maxWidth: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: NoopVisualStyle.heroRadius, style: .continuous))
    }

    @ViewBuilder private var statePill: some View {
        switch phase {
        case .ready:      NoopPill("Ready to scan", compact: true)
        case .searching:  LiveDotPill(title: "Searching…")
        case .connecting: LiveDotPill(title: "Connecting…")
        case .connected:  NoopPill("Connected", compact: true)
        }
    }
}

/// Five concentric rings fading outwards, a bright arc on the second ring (sweeping while scanning),
/// and the strap at the centre.
private struct ScanRings: View {
    let sweeping: Bool
    @State private var angle: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode / "Reduce motion in NOOP" pose these looping glows still too. Onboarding is
    /// first-run only, but a `repeatForever` is a `repeatForever` wherever it lives.
    @ObservedObject private var motion = NoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }

    var body: some View {
        ZStack {
            ForEach(Array([(46.0, 0.5), (72.0, 0.32), (100.0, 0.18), (130.0, 0.09), (162.0, 0.04)].enumerated()),
                    id: \.offset) { _, ring in
                Circle().stroke(Color.white.opacity(ring.1), lineWidth: 1)
                    .frame(width: ring.0 * 2, height: ring.0 * 2)
            }
            Circle()
                .trim(from: 0, to: 0.084)
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 144, height: 144)
                .rotationEffect(.degrees(-62 + angle))
            StrapGlyph()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { if sweeping { startSweep() } }
        .onChangeCompat(of: sweeping) { isOn in
            if isOn { startSweep() } else { withAnimation(.easeOut(duration: 0.3)) { angle = 0 } }
        }
    }

    private func startSweep() {
        // Reduce Motion: keep the arc still (the rings and the "Searching…" pill still say it).
        guard !poseStill else { return }
        angle = 0
        withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { angle = 360 }
    }
}

/// Ready to scan → Searching → Connecting… → Connected, as four nodes on a line.
private struct ScanStepsRow: View {
    let current: Int
    private let labels: [LocalizedStringKey] = ["Ready to scan", "Searching", "Connecting…", "Connected"]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<labels.count, id: \.self) { i in
                VStack(spacing: 9) {
                    node(i)
                    Text(labels[i])
                        .font(StrandFont.light(10.5, relativeTo: .caption2))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(Color.white.opacity(i <= current ? 0.9 : 0.42))
                }
                .frame(maxWidth: .infinity)
                .background(alignment: .top) {
                    // The connector from the previous node to this one.
                    if i > 0 {
                        GeometryReader { geo in
                            Rectangle()
                                .fill(Color.white.opacity(i <= current ? 0.6 : 0.16))
                                .frame(width: geo.size.width, height: 1)
                                .offset(x: -geo.size.width / 2, y: 6)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(labels[min(max(current, 0), labels.count - 1)]))
    }

    @ViewBuilder private func node(_ i: Int) -> some View {
        if i < current {
            Circle().fill(Color.white.opacity(0.75)).frame(width: 13, height: 13)
        } else if i == current {
            Circle().fill(Color.white).frame(width: 13, height: 13)
                .background(Circle().fill(Color.white.opacity(0.16)).frame(width: 21, height: 21))
                .shadow(color: .white.opacity(0.7), radius: 7)
        } else {
            Circle().fill(Color.black.opacity(0.85))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                .frame(width: 13, height: 13)
        }
    }
}

/// A compact hero pill with a glowing white dot: something is happening right now.
private struct LiveDotPill: View {
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

// MARK: - Step 7 · Connected

private struct BondedStep: View {
    @EnvironmentObject private var live: LiveState
    @AppStorage("selectedWhoopModel") private var selectedModelRaw = WhoopModel.whoop4.rawValue
    @State private var bloom = false

    private var modelName: String { (WhoopModel(rawValue: selectedModelRaw) ?? .whoop4).displayName }

    var body: some View {
        StepShell {
            NoopHeroCard(glow: .recovery, padding: 0) {
                VStack(spacing: 0) {
                    HStack {
                        NoopIconBadge("Paired", icon: "bluetooth")
                        Spacer(minLength: 8)
                        NoopPill(verbatim: modelName, compact: true)
                    }
                    ConnectedDial(bloom: bloom)
                        .frame(width: 236, height: 236)
                        .padding(.top, 2)
                    VStack(spacing: 8) {
                        Text("You're connected.")
                            .font(StrandFont.title1)
                            .tracking(-0.56)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("\(live.advertisingName ?? modelName) · bonded to \(Platform.deviceNounPhrase)")
                            .font(StrandFont.light(12, relativeTo: .caption))
                            .foregroundStyle(Color.white.opacity(0.62))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 4)
                    .opacity(bloom ? 1 : 0)
                    NoopMetricRow { metrics }
                        .padding(.top, 26)
                }
                .padding(EdgeInsets(top: 20, leading: 22, bottom: 24, trailing: 22))
            }
            .padding(.top, 14)
            FirstSyncCard()
                .padding(.top, 12)
        }
        .onAppear { withAnimation(StrandMotion.hero) { bloom = true } }
    }

    @ViewBuilder private var metrics: some View {
        HeroMetric(value: live.batteryPct.map { "\(Int($0.rounded()))" } ?? "–",
                   unit: live.batteryPct == nil ? nil : "%",
                   label: String(localized: "Battery"))
        HeroMetric(value: live.strapFirmware ?? "–", unit: nil, label: String(localized: "Firmware"))
        if let days = strapDays {
            HeroMetric(value: "\(days)", unit: String(localized: "days"),
                       label: String(localized: "Stored on strap"))
        }
    }

    /// Days of history the strap holds right now, from its own data-range reply. nil until it lands.
    private var strapDays: Int? {
        guard let range = live.strapRange, let oldest = range.oldestUnix, range.newestUnix > oldest else { return nil }
        return max(1, Int((Double(range.newestUnix - oldest) / 86_400).rounded(.up)))
    }
}

/// A `.m` metric inside a hero: the label reads at 55 % white over the glow.
private struct HeroMetric: View {
    let value: String
    let unit: String?
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value)
                    .font(StrandFont.value(21))
                    .tracking(-0.42)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let unit {
                    Text(verbatim: unit)
                        .font(StrandFont.book(10))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text(label)
                .font(StrandFont.light(10.5, relativeTo: .caption2))
                .foregroundStyle(Color.white.opacity(0.55))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The paired dial: a 72-tick bezel, a soft wide ring under a thin ink ring with a knob at the top,
/// a faint dot field inside, and a dot-matrix check that blooms in.
private struct ConnectedDial: View {
    let bloom: Bool

    /// The check, as dot offsets from the centre on the 10-pt grid.
    private static let check: [CGPoint] = [(-30, 0), (-20, 10), (-10, 20), (0, 10), (10, 0), (20, -10), (30, -20)]
        .map { CGPoint(x: $0.0, y: $0.1) }

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let s = min(size.width, size.height) / 236
                for i in 0..<72 {
                    let major = i % 6 == 0
                    let a = (Double(i) * 5 - 90) * .pi / 180
                    let r1 = (major ? 100 : 102) * s, r2 = (major ? 108 : 106) * s
                    var p = Path()
                    p.move(to: CGPoint(x: c.x + r1 * CGFloat(cos(a)), y: c.y + r1 * CGFloat(sin(a))))
                    p.addLine(to: CGPoint(x: c.x + r2 * CGFloat(cos(a)), y: c.y + r2 * CGFloat(sin(a))))
                    ctx.stroke(p, with: .color(.white.opacity(major ? 0.5 : 0.22)), lineWidth: 1)
                }
                let ring = Path(ellipseIn: CGRect(x: c.x - 80 * s, y: c.y - 80 * s, width: 160 * s, height: 160 * s))
                ctx.stroke(ring, with: .color(.white.opacity(0.12)), lineWidth: 12 * s)
                ctx.stroke(ring, with: .color(StrandPalette.textPrimary), lineWidth: 2.5 * s)
                // The dot field inside the ring, leaving the check's own cells empty.
                for gx in stride(from: -60, through: 60, by: 10) {
                    for gy in stride(from: -60, through: 60, by: 10) {
                        let d = (Double(gx * gx + gy * gy)).squareRoot()
                        guard d <= 61, !Self.check.contains(CGPoint(x: gx, y: gy)) else { continue }
                        let x = c.x + CGFloat(gx) * s, y = c.y + CGFloat(gy) * s
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 1.5 * s, y: y - 1.5 * s, width: 3 * s, height: 3 * s)),
                                 with: .color(.white.opacity(0.13)))
                    }
                }
                let knob = CGPoint(x: c.x, y: c.y - 80 * s)
                ctx.fill(Path(ellipseIn: CGRect(x: knob.x - 11 * s, y: knob.y - 11 * s, width: 22 * s, height: 22 * s)),
                         with: .color(.white.opacity(0.18)))
                ctx.fill(Path(ellipseIn: CGRect(x: knob.x - 5 * s, y: knob.y - 5 * s, width: 10 * s, height: 10 * s)),
                         with: .color(.white))
            }
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let s = min(size.width, size.height) / 236
                for p in Self.check {
                    let x = c.x + p.x * s, y = c.y + p.y * s
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 4 * s, y: y - 4 * s, width: 8 * s, height: 8 * s)),
                             with: .color(.white))
                }
            }
            .scaleEffect(bloom ? 1 : 0.4)
            .opacity(bloom ? 1 : 0)
        }
        .accessibilityHidden(true)
    }
}

/// How the first history offload is going. The protocol never reveals how much is left, so this
/// says what is happening rather than inventing a percentage.
private struct FirstSyncCard: View {
    @EnvironmentObject private var live: LiveState

    private enum SyncState { case starting, syncing, paused, done }

    private var state: SyncState {
        if live.backfilling { return .syncing }
        if live.lastSyncError != nil { return .paused }
        if live.lastSyncedAt != nil { return .done }
        return .starting
    }

    var body: some View {
        NoopCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                NoopCardHeader("First sync", icon: "arrows-clockwise") { Text(caption) }
                Group {
                    if state == .done {
                        NoopTrack(fraction: 1, height: 8)
                    } else {
                        IndeterminateTrack(active: state == .syncing)
                    }
                }
                .padding(.top, 10)
                HStack(alignment: .firstTextBaseline) {
                    Text(detail)
                    Spacer(minLength: 8)
                    if state == .syncing, live.syncChunksThisSession > 0 {
                        Text("\(live.syncChunksThisSession) chunks")
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.top, 9)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
    }

    private var caption: String {
        switch state {
        case .starting: return String(localized: "Starting")
        case .syncing:  return String(localized: "Syncing")
        case .paused:   return String(localized: "Paused")
        case .done:     return String(localized: "Up to date")
        }
    }

    private var detail: String {
        switch state {
        case .starting: return String(localized: "History sync starts in a moment.")
        case .syncing:  return String(localized: "Pulling your history from the strap")
        case .paused:   return String(localized: "The strap went quiet. NOOP retries on its own.")
        case .done:     return String(localized: "Everything on the strap is on \(Platform.deviceNounPhrase).")
        }
    }
}

/// A `.track` whose fill slides back and forth while work of unknown length runs.
private struct IndeterminateTrack: View {
    let active: Bool
    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode / "Reduce motion in NOOP" pose these looping glows still too. Onboarding is
    /// first-run only, but a `repeatForever` is a `repeatForever` wherever it lives.
    @ObservedObject private var motion = NoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                NoopTrack(fraction: 0, height: 8)
                if active {
                    NoopTrack(fraction: 1, height: 8)
                        .frame(width: w * 0.28)
                        .offset(x: (w * 0.72) * phase)
                }
            }
        }
        .frame(height: 8)
        .onAppear { animate() }
        .onChangeCompat(of: active) { _ in animate() }
        .accessibilityHidden(true)
    }

    private func animate() {
        guard active, !poseStill else { phase = 0; return }
        phase = 0
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { phase = 1 }
    }
}

// MARK: - Step 8 · Profile

private struct ProfileStep: View {
    @EnvironmentObject private var profile: ProfileStore

    // The stored profile is always SI. Body measurements and exercise distance can follow the regional
    // conventions independently; an unset distance choice follows the body choice for compatibility.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(system: unitSystem, override: distanceSystemRaw)
    }
    private var distanceSystemBinding: Binding<String> {
        Binding(get: { distanceUnitSystem.rawValue }, set: { distanceSystemRaw = $0 })
    }

    private enum Field { case weight, height }
    @State private var editing: Field?

    private let sexes: [(String, String)] = [
        ("male", String(localized: "Male")), ("female", String(localized: "Female")),
        ("nonbinary", String(localized: "Other"))
    ]

    var body: some View {
        StepShell {
            StepTitle(title: String(localized: "About you"),
                      subtitle: String(localized: "Sets your heart-rate zones and calorie maths. None of it leaves \(Platform.deviceNounPhrase)."))
                .padding(.top, 22)
            NoopList {
                dateOfBirthRow
                // Inline when the title fits beside the three-way control; otherwise (German
                // "Geschlecht" beside "Männlich · Weiblich · Sonstiges") the control drops under it.
                ViewThatFits(in: .horizontal) {
                    FormRow(icon: "person", title: String(localized: "Sex"), titleFixed: true) { sexControl.frame(width: 210) }
                    VStack(alignment: .leading, spacing: 0) {
                        FormRow(icon: "person", title: String(localized: "Sex")) { EmptyView() }
                        sexControl
                            .padding(.leading, 64)
                            .padding(.trailing, 14)
                            .padding(.bottom, 12)
                    }
                }
                // Keep the two choices explicit here: "Metric/Imperial" alone cannot describe
                // common mixed conventions such as Canadian pounds with kilometres.
                FormRow(icon: "sliders-horizontal", title: String(localized: "Units"),
                        caption: String(localized: "Body measurements")) {
                    SegmentedPillControl([UnitSystem.metric.rawValue, UnitSystem.imperial.rawValue],
                                         selection: $unitSystemRaw, fillsAvailableWidth: true) {
                        $0 == UnitSystem.metric.rawValue ? String(localized: "Metric") : String(localized: "Imperial")
                    }
                    .frame(width: 172)
                }
                FormRow(icon: "map-trifold", title: String(localized: "Distance"),
                        caption: String(localized: "Exercise distance & pace")) {
                    SegmentedPillControl([UnitSystem.metric.rawValue, UnitSystem.imperial.rawValue],
                                         selection: distanceSystemBinding, fillsAvailableWidth: true) {
                        $0 == UnitSystem.metric.rawValue ? String(localized: "Kilometres") : String(localized: "Miles")
                    }
                    .frame(width: 172)
                }
                // Steppers, not sliders — the same ranges/steps as the Settings profile editor, so every
                // numeric profile field is consistent across onboarding and Settings on both platforms.
                measureRow(.weight, icon: "scales", title: String(localized: "Weight"),
                           value: UnitFormatter.massFromKilograms(profile.weightKg, system: unitSystem))
                if editing == .weight {
                    StepperRow(label: String(localized: "Weight"), value: $profile.weightKg, range: 30...250, step: 0.5)
                }
                measureRow(.height, icon: "ruler", title: String(localized: "Height"),
                           value: UnitFormatter.heightFromCentimeters(profile.heightCm, system: unitSystem))
                if editing == .height {
                    StepperRow(label: String(localized: "Height"), value: $profile.heightCm, range: 120...230, step: 1)
                }
            }
            .padding(.top, 20)
            MaxHeartRateCard(profile: profile)
                .padding(.top, 12)
        }
    }

    private var sexControl: some View {
        SegmentedPillControl(sexes.map(\.0), selection: $profile.sex, fillsAvailableWidth: true) { key in
            sexes.first { $0.0 == key }?.1 ?? key
        }
    }

    // #146: capture a date of birth so age advances on its own instead of going stale.
    private var dateOfBirthRow: some View {
        FormRow(icon: "calendar-blank", title: String(localized: "Date of birth"),
                caption: String(localized: "\(profile.age) yrs")) {
            DatePicker("Date of birth", selection: $profile.dateOfBirth,
                       in: ProfileStore.dateOfBirthRange, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(StrandPalette.textPrimary)
        }
    }

    private func measureRow(_ field: Field, icon: String, title: String, value: String) -> some View {
        Button {
            withAnimation(StrandMotion.gentle) { editing = editing == field ? nil : field }
        } label: {
            FormRow(icon: icon, title: title) {
                HStack(spacing: 8) {
                    Text(verbatim: value)
                        .font(StrandFont.light(15, relativeTo: .body))
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                    PhIcon("caret-right", size: 14)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .opacity(0.35)
                        .rotationEffect(.degrees(editing == field ? 90 : 0))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Adjust"))
    }
}

/// A profile form row (`.fm .li`): icon tile, a 15 pt title with an optional caption, and a control.
private struct FormRow<Trailing: View>: View {
    let icon: String
    let title: String
    var caption: String? = nil
    /// Keep the title at its full width, so a `ViewThatFits` around the row can see it overflow.
    var titleFixed = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            NoopIconTile(icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .fixedSize(horizontal: titleFixed, vertical: false)
                if let caption {
                    Text(caption)
                        .font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

/// The inline editor a weight/height row opens: the system stepper, so press-and-hold repeats.
private struct StepperRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Stepper(label, value: $value, in: range, step: step)
                .labelsHidden()
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// The ink card under the profile form: the max heart rate the zones are built from, its source, an
/// editor for a measured value, and the five zone starts.
private struct MaxHeartRateCard: View {
    @ObservedObject var profile: ProfileStore
    @State private var editing = false

    var body: some View {
        NoopHeroCard(glow: .ink, padding: 0, cornerRadius: 30) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.hrMaxOverride > 0 ? "Max heart rate" : "Estimated max heart rate")
                            .font(StrandFont.book(14, relativeTo: .subheadline))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(profile.hrMaxOverride > 0 ? "Measured by you" : "From your age · edit if you've measured higher")
                            .font(StrandFont.footnote)
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                    Spacer(minLength: 0)
                    Button { withAnimation(StrandMotion.gentle) { editing.toggle() } } label: {
                        PhIcon(editing ? "check" : "pencil-simple", size: 15)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Edit max heart rate"))
                }
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    NoopDotNumber("\(profile.hrMax)", size: 56)
                    Text("bpm")
                        .font(StrandFont.light(13, relativeTo: .footnote))
                        .foregroundStyle(Color.white.opacity(0.62))
                }
                .padding(.top, 14)
                if editing { editor.padding(.top, 12) }
                zones.padding(.top, 16)
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 20, trailing: 20))
        }
    }

    private var editor: some View {
        HStack(spacing: 10) {
            if profile.hrMaxOverride > 0 {
                Button("Use estimate") { profile.hrMaxOverride = 0 }
                    .buttonStyle(.plain)
                    .font(StrandFont.book(13, relativeTo: .footnote))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 0)
            Stepper("Max heart rate",
                    value: Binding(get: { profile.hrMax }, set: { profile.hrMaxOverride = $0 }),
                    in: 120...230)
                .labelsHidden()
                .fixedSize()
        }
    }

    private var zones: some View {
        let starts = profile.hrZoneSet.zones.map { Int($0.lower.rounded()) }
        let shades: [Double] = [0.16, 0.28, 0.42, 0.6, 0.85]
        return VStack(spacing: 7) {
            HStack(spacing: 3) {
                ForEach(0..<shades.count, id: \.self) { i in
                    Capsule().fill(Color.white.opacity(shades[i])).frame(height: 6)
                }
            }
            HStack(alignment: .top, spacing: 3) {
                ForEach(Array(starts.enumerated()), id: \.offset) { i, bpm in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "Z\(i + 1)")
                            .font(StrandFont.book(11, relativeTo: .caption2))
                            .foregroundStyle(Color.white.opacity(0.82))
                        Text(verbatim: i == starts.count - 1 ? "\(bpm)+" : "\(bpm)")
                            .font(StrandFont.light(10.5, relativeTo: .caption2))
                            .monospacedDigit()
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Step 9 · Import (optional)

private struct ImportStep: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingImporter = false
    @State private var importTarget: ImportTarget = .whoop

    var body: some View {
        StepShell {
            HistoryPreviewHero(imports: completedImports, summary: successSummary)
                .padding(.top, 14)
            StepTitle(title: String(localized: "Bring your history"),
                      subtitle: String(localized: "Optional. An export fills in the years before NOOP — read on \(Platform.deviceNounPhrase), never uploaded."))
                .padding(.top, 24)
            VStack(spacing: 10) {
                ImportCard(icon: "file-zip",
                           title: model.isImporting(.whoop) ? String(localized: "Importing…") : String(localized: "Import WHOOP export"),
                           caption: model.whoopImportSummary ?? String(localized: "The .zip from WHOOP's data export"),
                           failed: model.importFailed(.whoop),
                           done: succeeded(.whoop),
                           busy: model.isImporting(.whoop),
                           chips: [String(localized: "Charge"), String(localized: "Rest"), String(localized: "Effort"),
                                   String(localized: "Workouts"), String(localized: "Journal")]) {
                    presentImporter(.whoop)
                }
                ImportCard(icon: "heart",
                           title: model.isImporting(.appleHealth) ? String(localized: "Working…") : String(localized: "Import Apple Health export"),
                           caption: model.appleHealthImportSummary ?? String(localized: "export.zip from the Health app"),
                           failed: model.importFailed(.appleHealth),
                           done: succeeded(.appleHealth),
                           busy: model.isImporting(.appleHealth),
                           chips: [String(localized: "Heart rate"), String(localized: "Steps"), String(localized: "Weight"),
                                   String(localized: "Sleep"), String(localized: "Workouts")]) {
                    presentImporter(.appleHealth)
                }
            }
            .disabled(model.hasActiveImport)
            .padding(.top, 18)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: importTarget.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result, for: importTarget)
        }
    }

    private func succeeded(_ kind: DataSourceImportKind) -> Bool {
        let summary = kind == .whoop ? model.whoopImportSummary : model.appleHealthImportSummary
        return summary != nil && !model.importFailed(kind) && !model.isImporting(kind)
    }

    private var completedImports: Int {
        (succeeded(.whoop) ? 1 : 0) + (succeeded(.appleHealth) ? 1 : 0)
    }

    /// The summary of the import the user ran last in this step, when it succeeded.
    private var successSummary: String? {
        switch importTarget {
        case .whoop: return succeeded(.whoop) ? model.whoopImportSummary : nil
        case .appleHealth: return succeeded(.appleHealth) ? model.appleHealthImportSummary : nil
        }
    }

    private func presentImporter(_ target: ImportTarget) {
        importTarget = target
        showingImporter = true
    }

    private func handleImportResult(_ result: Result<[URL], Error>, for target: ImportTarget) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        switch target {
        case .whoop:
            model.importWhoop(url: url)
        case .appleHealth:
            model.importAppleHealth(url: url)
        }
    }

    private enum ImportTarget {
        case whoop
        case appleHealth

        var allowedContentTypes: [UTType] {
            // See DataSourcesView: `.folder` is a macOS-only affordance (pick an unzipped export
            // directory). On iOS it greys out the .zip in the Files picker (issue #179), so iOS
            // offers only the concrete file types.
            switch self {
            case .whoop:
                #if os(macOS)
                return [.zip, .folder]
                #else
                return [.zip]
                #endif
            case .appleHealth:
                #if os(macOS)
                return [.zip, .xml, .folder]
                #else
                return [.zip, .xml]
                #endif
            }
        }
    }
}

/// The ink history hero: how many days the strap holds (from its own data-range reply), the import
/// that just landed, and five years of week dots with the weeks the strap covers lit.
private struct HistoryPreviewHero: View {
    /// Observed here rather than by the whole step, so a heart-rate tick re-renders only this card.
    @EnvironmentObject private var live: LiveState
    let imports: Int
    let summary: String?

    private var strapRange: LiveState.StrapRange? { live.strapRange }

    private var strapDays: Int? {
        guard let r = strapRange, let oldest = r.oldestUnix, r.newestUnix > oldest else { return nil }
        return max(1, Int((Double(r.newestUnix - oldest) / 86_400).rounded(.up)))
    }

    var body: some View {
        NoopHeroCard(glow: .ink, padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge("History preview", icon: "clock-counter-clockwise")
                    Spacer(minLength: 8)
                    NoopPill(verbatim: importsLabel, compact: true)
                }
                headline.padding(.top, 22)
                // Equatable on the strap range, so the dot field redraws when the range changes and not
                // on every live tick that re-renders this card.
                WeekDotGrid(strapRange: strapRange)
                    .equatable()
                    .frame(height: 68)
                    .padding(.top, 20)
                HStack {
                    Text(verbatim: "\(WeekDotGrid.firstYear)")
                    Spacer(minLength: 4)
                    Text("each dot is one week")
                    Spacer(minLength: 4)
                    Text("Today").foregroundStyle(Color.white.opacity(0.85))
                }
                .font(StrandFont.light(10.5, relativeTo: .caption2))
                .foregroundStyle(Color.white.opacity(0.5))
                .padding(.leading, 34)
                .padding(.top, 8)
            }
            .padding(EdgeInsets(top: 20, leading: 20, bottom: 22, trailing: 20))
        }
    }

    private var importsLabel: String {
        switch imports {
        case 0: return String(localized: "Strap only")
        case 1: return String(localized: "From 1 export")
        default: return String(localized: "From \(imports) exports")
        }
    }

    @ViewBuilder private var headline: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let strapDays {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    NoopDotNumber("\(strapDays)", size: 60)
                    Text("days on your strap")
                        .font(StrandFont.light(13, relativeTo: .footnote))
                        .foregroundStyle(Color.white.opacity(0.62))
                }
            }
            if let summary {
                Text(verbatim: summary)
                    .font(StrandFont.light(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
            } else if strapDays == nil {
                Text("Nothing imported yet")
                    .font(StrandFont.light(15, relativeTo: .body))
                    .foregroundStyle(Color.white.opacity(0.62))
            }
        }
    }
}

/// Five rows of week dots (oldest year on top). Weeks the strap's data range covers are lit; the
/// current week carries a halo; weeks still to come are barely there.
private struct WeekDotGrid: View, Equatable {
    let strapRange: LiveState.StrapRange?

    static var firstYear: Int { Calendar.current.component(.year, from: Date()) - 4 }

    var body: some View {
        Canvas { ctx, size in
            let cal = Calendar.current
            let now = Date()
            let thisYear = cal.component(.year, from: now)
            let left: CGFloat = 34, right = size.width - 4
            let step = (right - left) / 52
            let lit: ClosedRange<Date>? = strapRange.flatMap { r -> ClosedRange<Date>? in
                guard let oldest = r.oldestUnix, r.newestUnix >= oldest else { return nil }
                return Date(timeIntervalSince1970: TimeInterval(oldest))...Date(timeIntervalSince1970: TimeInterval(r.newestUnix))
            }
            for row in 0..<5 {
                let year = thisYear - 4 + row
                let y = 8 + CGFloat(row) * 13
                ctx.draw(Text(verbatim: "\(year)")
                            .font(StrandFont.light(9.5))
                            .foregroundColor(Color.white.opacity(0.45)),
                         at: CGPoint(x: 0, y: y), anchor: .leading)
                guard let jan1 = cal.date(from: DateComponents(year: year, month: 1, day: 1)) else { continue }
                for col in 0..<53 {
                    guard let start = cal.date(byAdding: .day, value: col * 7, to: jan1),
                          cal.component(.year, from: start) == year,
                          let end = cal.date(byAdding: .day, value: 7, to: start) else { continue }
                    let x = left + CGFloat(col) * step
                    let isNow = start <= now && now < end
                    if isNow {
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10)),
                                 with: .color(.white.opacity(0.18)))
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 2.2, y: y - 2.2, width: 4.4, height: 4.4)),
                                 with: .color(.white))
                    } else if start > now {
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4)),
                                 with: .color(.white.opacity(0.05)))
                    } else if let lit, lit.overlaps(start...end) {
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)),
                                 with: .color(.white.opacity(0.88)))
                    } else {
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 1.4, y: y - 1.4, width: 2.8, height: 2.8)),
                                 with: .color(.white.opacity(0.13)))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// One import source (`.card.imp`): file tile, title + file caption, a done check or an add circle, and
/// the kinds of data it brings as small chips. The whole card opens the file picker.
private struct ImportCard: View {
    let icon: String
    let title: String
    let caption: String
    let failed: Bool
    let done: Bool
    let busy: Bool
    let chips: [String]
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    PhIcon(icon, size: 20)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: 42, height: 42)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LinearGradient(colors: [NoopVisualStyle.raised, NoopVisualStyle.inset],
                                                 startPoint: .top, endPoint: .bottom)))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(StrandFont.book(15, relativeTo: .body))
                            .foregroundStyle(StrandPalette.textPrimary)
                        HStack(spacing: 4) {
                            if failed { PhIcon("warning", size: 12) }
                            Text(caption).lineLimit(2)
                        }
                        .font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(failed ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    trailing
                }
                FlowLayout(spacing: 6) {
                    ForEach(chips, id: \.self) { chip in
                        Text(chip)
                            .font(StrandFont.book(11, relativeTo: .caption2))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .padding(.horizontal, 9)
                            .frame(height: 25)
                            .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
                            .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .noopPanel(cornerRadius: 26)
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(done ? 0.18 : 0), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled || busy ? 1 : 0.55)
    }

    @ViewBuilder private var trailing: some View {
        if busy {
            ProgressView().controlSize(.small).tint(StrandPalette.textPrimary)
                .frame(width: 30, height: 30)
        } else if done {
            PhIcon("check-circle", weight: .fill, size: 32)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 26, height: 26)
                .accessibilityLabel(Text("Imported"))
        } else {
            NoopCircleIcon("plus", size: 30)
        }
    }
}

/// Lays children out left to right, wrapping onto new lines (the import chips).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Step 10 · Notifications (wrist alerts priming)

private struct NotificationsStep: View {
    var body: some View {
        StepShell {
            StepTitle(title: String(localized: "Stay in the loop"),
                      subtitle: String(localized: "NOOP can tap your wrist when your \(Platform.deviceNoun) needs you. No glance at the screen required."))
                .padding(.top, 24)
            NoopHeroCard(glow: .ink, padding: 0) {
                PulsingGlyph(icon: "bell-ringing")
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 20)
            NoopCard {
                VStack(alignment: .leading, spacing: 10) {
                    NoopCardHeader("A buzz, not a banner", icon: "vibrate") { EmptyView() }
                    Text(message)
                        .font(StrandFont.light(14, relativeTo: .subheadline))
                        .lineSpacing(3)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 12)
            NoopList {
                ForEach(checklines, id: \.self) { line in
                    TipRow(icon: "check", text: line)
                }
            }
            .padding(.top, 12)
        }
    }

    // iOS gives an app no way to observe *other* apps' notifications, and the per-app picker behind it
    // is NSWorkspace-based (macOS-only). So iOS drops the cross-app relay claim and keeps only what it
    // genuinely does: NOOP's own strain nudges + smart alarm buzz the strap directly over BLE.
    private var message: String {
        #if os(iOS)
        String(localized: "NOOP taps your strap so an alert lands on your wrist instead of your screen. No need to reach for it. Everything stays on \(Platform.deviceNounPhrase).")
        #else
        String(localized: "When the \(Platform.deviceNoun) apps you choose send a notification, NOOP taps your strap: Slack, Calendar, Messages, whatever matters. Everything stays on \(Platform.deviceNounPhrase).")
        #endif
    }

    private var checklines: [String] {
        #if os(iOS)
        [String(localized: "Strain nudges and your smart alarm tap your wrist the moment they fire."),
         String(localized: "It all stays on your strap and \(Platform.deviceNounPhrase): no account, no cloud.")]
        #else
        [String(localized: "Pick which apps reach your wrist in Settings → Notifications."),
         String(localized: "Strain nudges and your smart alarm tap your wrist the same way.")]
        #endif
    }
}

// MARK: - Step 11 · Appearance

/// Lets a brand-new user pick the app's look up front (and learn it's changeable) — the same
/// System / Light / Dark setting that lives in Settings → Appearance. Selecting re-themes the whole
/// app live (the shared `@AppStorage(AppearanceMode.storageKey)` drives `preferredColorScheme`), so
/// the wizard itself IS the preview.
private struct AppearanceStep: View {
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.defaultMode.rawValue
    private var binding: Binding<AppearanceMode> {
        Binding(get: { AppearanceMode(rawValue: appearanceRaw) ?? .system },
                set: { appearanceRaw = $0.rawValue })
    }
    var body: some View {
        StepShell {
            StepTitle(title: String(localized: "Make it yours"),
                      subtitle: String(localized: "Choose how NOOP looks. The whole app updates as you tap. You can change this any time in Settings → Appearance."))
                .padding(.top, 24)
            NoopHeroCard(glow: .ink, padding: 0) {
                PhIcon("circle-half", size: 56)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 20)
            SegmentedPillControl(AppearanceMode.allCases, selection: binding, fillsAvailableWidth: true) { $0.label }
                .padding(.top, 16)
            Text("System follows your \(Platform.deviceNoun)'s light or dark setting.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.top, 12)
                .padding(.horizontal, 4)
        }
    }
}

// MARK: - Step 12 · Done

private struct DoneStep: View {
    @State private var appear = false
    var body: some View {
        StepShell {
            NoopHeroCard(glow: .recovery, padding: 22) {
                VStack(spacing: 0) {
                    HStack {
                        NoopIconBadge("Charge", icon: "lightning")
                        Spacer(minLength: 8)
                        ScoreStatePill(.calibrating)
                    }
                    ZStack {
                        // The unlit segments of a dot-matrix readout, with the empty value over them.
                        dotReadout("88", unitOpacity: 1).opacity(0.09)
                        dotReadout("--", unitOpacity: 0.5)
                    }
                    .frame(height: 96)
                    .padding(.top, 40)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("No Charge yet"))
                    NoopTickScale()
                        .opacity(0.4)
                        .padding(.top, 30)
                    HStack {
                        Text("Depleted")
                        Spacer()
                        Text("Peak")
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.top, 7)
                    Text("Your first Charge appears after a few nights of sleep.")
                        .font(StrandFont.light(14, relativeTo: .subheadline))
                        .lineSpacing(4)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.white.opacity(0.84))
                        .padding(.top, 22)
                        .padding(.horizontal, 30)
                }
                .opacity(appear ? 1 : 0)
            }
            .padding(.top, 14)
            StepTitle(title: String(localized: "Your thread starts here."),
                      subtitle: String(localized: "Wear the strap to bed. Your Charge arrives after a few nights; two weeks teach NOOP your baseline."),
                      size: 32)
                .padding(.top, 26)
            MilestoneCard()
                .padding(.top, 20)
        }
        .onAppear { withAnimation(StrandMotion.hero) { appear = true } }
    }

    private func dotReadout(_ value: String, unitOpacity: Double) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(verbatim: value)
                .font(StrandFont.dot(104))
                .tracking(StrandFont.dotTracking(104))
            Text(verbatim: "%")
                .font(StrandFont.dot(44))
                .tracking(StrandFont.dotTracking(44))
                .opacity(unitOpacity)
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .lineLimit(1)
        .frame(maxWidth: .infinity)
    }
}

/// Tonight → first Charge → a trusted baseline, dated from today with the baseline model's own
/// night counts (`Baselines.minNightsSeed` / `minNightsTrust`).
private struct MilestoneCard: View {
    var body: some View {
        NoopCard {
            HStack(alignment: .top, spacing: 0) {
                milestone(on: true, when: Text("Tonight"), title: Text("Sleep in it"))
                milestone(on: false, when: Text(verbatim: day(Baselines.minNightsSeed)), title: Text("First Charge"))
                milestone(on: false, when: Text(verbatim: day(Baselines.minNightsTrust)), title: Text("Baseline solid"))
            }
            .background(alignment: .topLeading) {
                GeometryReader { geo in
                    LinearGradient(colors: [Color.white.opacity(0.7), Color.white.opacity(0.12)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 2 / 3, height: 1)
                        .offset(x: 6, y: 5)
                }
            }
        }
    }

    private func day(_ nightsFromNow: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: nightsFromNow, to: Date()) ?? Date()
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func milestone(on: Bool, when: Text, title: Text) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if on {
                    Circle().fill(Color.white).frame(width: 11, height: 11)
                        .background(Circle().fill(Color.white.opacity(0.12)).frame(width: 19, height: 19))
                } else {
                    Circle().fill(NoopVisualStyle.canvas)
                        .overlay(Circle().strokeBorder(StrandPalette.textPrimary.opacity(0.35), lineWidth: 1))
                        .frame(width: 11, height: 11)
                }
            }
            when.font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.top, 12)
            title.font(StrandFont.book(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Step shell (shared layout for each page)

private struct StepShell<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        #if os(iOS)
        // #697/#horizontal-swipe parity, see ScreenScaffold. First-run wizard, every step routes
        // through this one shell, so a single fix here covers the whole onboarding flow.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        #if os(iOS) && DEBUG
        .modifier(DemoScrollAnchor())
        #endif
    }
}

/// A step's h1 (28 pt Light, or 32 on the bookend steps) and its 14 pt intro line.
private struct StepTitle: View {
    let title: String
    let subtitle: String?
    var size: CGFloat = 28
    var subtitleGap: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: subtitleGap) {
            Text(title)
                .font(StrandFont.light(size, relativeTo: .title))
                .tracking(-size * 0.02)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .lineSpacing(3)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The twelve progress dashes across the top bar; every step up to the current one is lit.
private struct StepDashes: View {
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

// MARK: - Reusable pieces

/// A list row carrying an explanation: icon tile, a 15 pt title and a secondary paragraph.
private struct InfoRow: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            NoopIconTile(icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(message)
                    .font(StrandFont.light(13, relativeTo: .footnote))
                    .lineSpacing(2)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .accessibilityElement(children: .combine)
    }
}

/// A `.tips .li` row: a small icon tile and one secondary sentence.
private struct TipRow: View {
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

// MARK: - Preview

#if DEBUG
private struct OnboardingPreview: View {
    @StateObject private var model = AppModel()
    var body: some View {
        OnboardingWizard(onFinished: {})
            .environmentObject(model)
            .environmentObject(model.live)
            .environmentObject(model.profile)
            .frame(width: 1100, height: 780)
    }
}

#Preview("Onboarding") { OnboardingPreview() }
#endif
