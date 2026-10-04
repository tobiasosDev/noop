import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics

// MARK: - WatchBreatheView — wrist-native catalog-driven breathing
//
// Reimplements the phone Breathe trainer on-watch: [BreathProtocolCatalog.watchSubset] protocols,
// stage-accurate inhale/hold/exhale pacing, session length Open/5/10/15 with auto-stop, and Taptic cues
// (one tap inhale, double exhale; holds silent). Zero-arg init; nav lane wires it by name.

struct WatchBreatheView: View {

    private enum SessionLength: Hashable, CaseIterable {
        case open, five, ten, fifteen

        var label: String {
            switch self {
            case .open: return String(localized: "Open")
            case .five: return String(localized: "5m")
            case .ten: return String(localized: "10m")
            case .fifteen: return String(localized: "15m")
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var protocolId: String = "coherence_5_5"
    @State private var sessionLength: SessionLength = .ten
    @State private var running = false

    @State private var ringProgress: CGFloat = 0
    @State private var phase: Phase = .inhale
    @State private var phaseLabel: String? = nil
    @State private var stageIndex: Int = 0
    @State private var phaseDeadline: Date = .distantFuture
    @State private var phaseStart: Date = Date()
    @State private var phaseRemaining: Int = 0

    @State private var breathCount = 0
    @State private var sessionSeconds = 0

    private let phaseTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    private let secondTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private let reducedSteadyRing: CGFloat = 0.5

    /// Starts a session as soon as the page appears. Only the DEBUG screenshot aid sets it (a simulator
    /// cannot tap Start); the page itself always opens idle.
    private var startsOnAppear = false

    init() {}

    #if DEBUG
    init(startsOnAppear: Bool) {
        self.startsOnAppear = startsOnAppear
    }
    #endif

    private var protocols: [BreathProtocol] { BreathProtocolCatalog.watchSubset }

    private var selectedProtocol: BreathProtocol? {
        BreathProtocolCatalog.protocolById(protocolId)
    }

    private var isGuided: Bool { selectedProtocol?.mode == .guided }

    private var selectedBpm: Double {
        guard let proto = selectedProtocol, proto.cycleDurationMs > 0 else { return 0 }
        return 60_000.0 / Double(proto.cycleDurationMs)
    }

    var body: some View {
        // One screen, no scrolling. Idle carries the setup (session length, pace, Start) around a small orb;
        // a running session clears the setup away and gives the face to the orb, as the board draws it.
        GeometryReader { geo in
            Group {
                if running {
                    runningFace(size: geo.size)
                } else {
                    idleFace(size: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .padding(.horizontal, 4)
        // The page's one glow: Breathe lives in the Stress colour world on the phone too.
        .background(WatchGlowBackground(glow: .stress, strength: running ? 0.55 : 0.4))
        .onReceive(phaseTimer) { now in
            guard running else { return }
            advance(now: now)
            updateCountdown(now: now)
        }
        .onReceive(secondTimer) { _ in
            guard running else { return }
            sessionSeconds += 1
            if let target = sessionLength.targetSeconds, sessionSeconds >= target {
                stop()
            }
        }
        .onChange(of: protocolId) { newId in
            if running { stop() }
            if let proto = BreathProtocolCatalog.protocolById(newId) {
                sessionLength = SessionLength.from(recommendedMs: proto.recommendedDurationMs)
            }
        }
        .onAppear { if startsOnAppear, !running { start() } }
        .onDisappear { stop() }
    }

    // MARK: - Faces

    /// Ready to breathe: the page title, session length, the resting orb, the pace and Start.
    private func idleFace(size: CGSize) -> some View {
        let spacing: CGFloat = 4
        let reserved = Self.headerHeight + 26 + 28 + 36 + spacing * 4
        let side = min(max(size.height - reserved, 40), size.width, 120)
        return VStack(spacing: spacing) {
            header
            sessionLengthPicker
                .frame(height: 26)
            orb(diameter: side * 0.8, halo: side)
            Spacer(minLength: 0)
            pacePicker
                .frame(height: 28)
            control
                .frame(height: 36)
        }
    }

    /// A session in progress: the orb breathing at the centre inside its two halos, the protocol and the
    /// time over the breath count and pace. Stop sits in the header, the one control a running session
    /// needs.
    private func runningFace(size: CGSize) -> some View {
        let textBlock: CGFloat = 34
        let largest = min(118, size.width / 1.37, size.height - Self.headerHeight - textBlock - 12)
        let minScale: CGFloat = 0.6
        let scale = minScale + (1.0 - minScale) * ringProgress
        return VStack(spacing: 0) {
            header
            Spacer(minLength: 4)
            ZStack {
                Circle()
                    .strokeBorder(NoopGlow.stress.tint.opacity(0.12), lineWidth: 1)
                    .frame(width: largest + 44, height: largest + 44)
                orb(diameter: largest * scale, halo: largest + 20)
            }
            .frame(width: largest, height: largest)
            .frame(maxWidth: .infinity)
            Spacer(minLength: 8)
            VStack(spacing: 3) {
                Text(runningTitle)
                    .font(StrandFont.book(13))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(runningDetail)
                    .font(StrandFont.light(10))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(height: textBlock)
        }
    }

    private static let headerHeight: CGFloat = 28

    /// The page title in the Stress colour, with Stop at the right while a session runs.
    private var header: some View {
        HStack(spacing: 6) {
            Text("Breathe")
                .font(StrandFont.book(12))
                .foregroundStyle(NoopGlow.stress.tint)
                .lineLimit(1)
            Spacer(minLength: 4)
            if running {
                Button {
                    stop()
                } label: {
                    PhIcon("stop", weight: .fill, size: 10)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(NoopVisualStyle.raised))
                        .overlay(Circle().strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                        .contentShape(Circle().inset(by: -6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Stop session"))
            }
        }
        .padding(.leading, 4)
        .frame(height: Self.headerHeight)
    }

    /// "Coherence · 4:12": the protocol, then the time left in a timed session or the time so far in an
    /// open one.
    private var runningTitle: String {
        let title = selectedProtocol.map { watchLabel(for: $0) } ?? protocolId
        let seconds = sessionLength.targetSeconds.map { max($0 - sessionSeconds, 0) } ?? sessionSeconds
        return String(localized: "\(title) · \(timeString(seconds))")
    }

    /// "12 breaths · 6.0 br/min", or the guided protocol's own label.
    private var runningDetail: String {
        if isGuided { return String(localized: "Guided") }
        return String(localized: "\(breathCount) breaths · \(paceText)")
    }

    /// The protocol's pace, "6.0 br/min".
    private var paceText: String {
        String(format: String(localized: "%@ br/min"), String(format: "%.1f", selectedBpm))
    }

    // MARK: - Orb

    /// The breathing orb: a lit sphere in the Stress glow (bright at its upper centre, darkening and
    /// fading at the rim) inside a faint halo ring. The cue sits on the orb in dark ink.
    private func orb(diameter: CGFloat, halo: CGFloat) -> some View {
        let glow = NoopGlow.stress
        // The board's gradient reaches transparent at 72 % of the farthest-corner radius, measured from
        // a centre 42 % down: about 0.76 of the orb's diameter.
        let reach = diameter * 0.76
        return ZStack {
            Circle()
                .strokeBorder(glow.tint.opacity(0.25), lineWidth: 1)
                .frame(width: halo, height: halo)
            Circle()
                .fill(RadialGradient(
                    stops: [
                        .init(color: glow.accent, location: 0.26),
                        .init(color: glow.deep, location: 0.62),
                        .init(color: glow.deep.opacity(0), location: 0.72),
                    ],
                    center: .init(x: 0.5, y: 0.42), startRadius: 0, endRadius: reach))
                .overlay(Circle().fill(RadialGradient(
                    colors: [Color.white.opacity(0.45), Color.white.opacity(0)],
                    center: .init(x: 0.5, y: 0.42), startRadius: 0, endRadius: reach * 0.26)))
                .frame(width: diameter, height: diameter)
            centerLabel
                .frame(width: diameter * 0.8)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var centerLabel: some View {
        let ink = NoopGlow.stress.floor
        VStack(spacing: 2) {
            if running {
                Text(phaseWord)
                    .font(StrandFont.book(14))
                    .foregroundStyle(ink)
                    .animation(.easeInOut(duration: 0.2), value: phase)
                if !isGuided {
                    Text("\(max(phaseRemaining, 0))")
                        .font(StrandFont.dot(18))
                        .foregroundStyle(ink)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            } else {
                Text(selectedProtocol.map { watchLabel(for: $0) } ?? String(localized: "Breathe"))
                    .font(StrandFont.book(13))
                    .foregroundStyle(ink)
                if selectedBpm > 0 {
                    Text(paceText)
                        .font(StrandFont.light(10))
                        .foregroundStyle(ink.opacity(0.75))
                } else if isGuided {
                    Text(String(localized: "Guided"))
                        .font(StrandFont.light(10))
                        .foregroundStyle(ink.opacity(0.75))
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.55)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(running ? phaseAccessibilityLabel : String(localized: "Ready to breathe"))
    }

    private var phaseWord: String {
        if let phaseLabel, !phaseLabel.isEmpty {
            return phaseLabel
        }
        switch phase {
        case .inhale: return String(localized: "Breathe in")
        case .hold: return String(localized: "Hold")
        case .exhale: return String(localized: "Breathe out")
        case .textOnly: return String(localized: "Follow cue")
        }
    }

    private var phaseAccessibilityLabel: String {
        let secs = max(phaseRemaining, 0)
        switch phase {
        case .inhale: return String(localized: "Breathe in for \(secs) seconds")
        case .hold: return String(localized: "Hold for \(secs) seconds")
        case .exhale: return String(localized: "Breathe out for \(secs) seconds")
        case .textOnly: return String(localized: "Follow the guided cue")
        }
    }

    // MARK: - Pickers

    private var sessionLengthPicker: some View {
        HStack(spacing: 2) {
            ForEach(SessionLength.allCases, id: \.self) { len in
                Button {
                    StrandHaptic.selection.play()
                    sessionLength = len
                } label: {
                    Text(len.label)
                        .font(StrandFont.book(11))
                        .foregroundStyle(len == sessionLength ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            Capsule(style: .continuous)
                                .fill(len == sessionLength ? NoopVisualStyle.raised : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .disabled(running)
            }
        }
        .padding(2)
        .background(Capsule(style: .continuous).fill(NoopVisualStyle.surface.opacity(0.8)))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
    }

    private var pacePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(protocols, id: \.id) { proto in
                    let on = proto.id == protocolId
                    Button {
                        StrandHaptic.selection.play()
                        protocolId = proto.id
                    } label: {
                        Text(watchLabel(for: proto))
                            .font(StrandFont.book(11))
                            .foregroundStyle(on ? StrandPalette.goldDeepText : StrandPalette.textSecondary)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Capsule(style: .continuous)
                                .fill(on ? StrandPalette.textPrimary : NoopVisualStyle.inset))
                            .overlay(Capsule(style: .continuous)
                                .strokeBorder(on ? Color.clear : NoopVisualStyle.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func watchLabel(for proto: BreathProtocol) -> String {
        switch proto.id {
        case "relax_4_6": return String(localized: "Relax")
        case "coherence_5_5": return String(localized: "Coherence")
        case "box_4_4_4_4": return String(localized: "Box")
        case "deep_4_2_6": return String(localized: "Deep")
        case "four_seven_eight": return String(localized: "4-7-8")
        case "coherent_6_6": return String(localized: "6-6")
        case "presence_regular": return String(localized: "Regular")
        case "presence_mid": return String(localized: "Mid")
        case "presence_punching": return String(localized: "Push")
        default:
            return String(proto.title.split(separator: " ").first ?? Substring(proto.title))
        }
    }

    // MARK: - Control

    private var control: some View {
        Button {
            running ? stop() : start()
        } label: {
            HStack(spacing: 6) {
                PhIcon(running ? "stop" : "play", weight: .fill, size: 12)
                Text(running ? String(localized: "Stop") : String(localized: "Start"))
            }
        }
        .buttonStyle(WatchPillButtonStyle(primary: !running))
        .accessibilityLabel(running ? String(localized: "Stop session") : String(localized: "Start session"))
    }

    // MARK: - Session engine

    private func currentStages() -> [BreathStage] {
        selectedProtocol?.stages.filter { $0.durationMs > 0 } ?? []
    }

    private func start() {
        running = true
        sessionSeconds = 0
        breathCount = 0
        stageIndex = 0
        phaseLabel = nil
        StrandHaptic.success.play()
        if isGuided {
            phase = .textOnly
            phaseLabel = selectedProtocol?.title
            phaseDeadline = .distantFuture
            if reduceMotion { ringProgress = reducedSteadyRing } else { ringProgress = reducedSteadyRing }
        } else {
            armCurrentStage(from: Date(), buzz: true)
        }
    }

    private func stop() {
        guard running else { return }
        running = false
        phaseDeadline = .distantFuture
        phaseLabel = nil
        StrandHaptic.commit.play()
        if reduceMotion {
            ringProgress = 0
        } else {
            withAnimation(.easeInOut(duration: 0.7)) { ringProgress = 0 }
        }
    }

    private func armCurrentStage(from now: Date, buzz: Bool) {
        let stages = currentStages()
        guard !stages.isEmpty else { return }
        let stage = stages[stageIndex % stages.count]
        switch stage.type {
        case .inhale: phase = .inhale
        case .hold: phase = .hold
        case .exhale: phase = .exhale
        case .textOnly: phase = .textOnly
        }
        phaseLabel = stage.label
        let duration = Double(stage.durationMs) / 1000.0
        phaseStart = now
        phaseDeadline = now.addingTimeInterval(duration)
        phaseRemaining = Int(duration.rounded(.up))

        if reduceMotion {
            ringProgress = reducedSteadyRing
        } else {
            withAnimation(.easeInOut(duration: duration)) {
                switch phase {
                case .inhale: ringProgress = 1.0
                case .exhale: ringProgress = 0.0
                case .hold, .textOnly: break
                }
            }
        }

        if buzz {
            let loops = BreathProtocolPlayer.loops(for: stage.type)
            if loops > 0 {
                StrandHaptic.light.play()
                if loops >= 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        StrandHaptic.light.play()
                    }
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
        if completed.type == .exhale { breathCount += 1 }
        armCurrentStage(from: now, buzz: true)
    }

    private func updateCountdown(now: Date) {
        let left = phaseDeadline.timeIntervalSince(now)
        phaseRemaining = max(0, Int(left.rounded(.up)))
    }

    private func timeString(_ total: Int) -> String {
        String(format: "%d:%02d", total / 60, total % 60)
    }
}
