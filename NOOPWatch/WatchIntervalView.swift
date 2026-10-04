import SwiftUI
import StrandDesign

// MARK: - WatchIntervalView — silent haptic HIIT, on the wrist
//
// The watch-native sibling of the phone's Interval Timer (Strand/Screens/IntervalTimerView.swift). Same
// model: a WORK / REST state machine over a number of rounds with the session total derived from
// work*rounds + rest*(rounds-1). The difference is where the buzz lands. On the phone the strap (or the
// phone's own Taptic engine) cues the transitions; here the watch IS on your wrist, so we fire WatchKit
// haptics through StrandHaptic at every WORK<->REST flip and round change. Train hands-free and let the
// wrist tell you when to switch, never looking at the face.
//
// Defaults match the phone: 30s work / 15s rest / 8 rounds. Scaled for the watch: one big countdown ring
// is the whole screen (faint track + the phase arc with a knob, the time left in the dot face), with the
// WORK/REST tag above it, the round count and round bars under it, and compact Start/Pause + Reset below.
// No config steppers up here on the small face — the wrist is for running the session, the phone owns setup.
struct WatchIntervalView: View {

    // Cross-lane contract: a no-arg init, fully self-contained.
    init() {}

    #if DEBUG
    /// DEBUG screenshot aid: begin the session as soon as the page appears (a simulator cannot tap Start).
    init(startsOnAppear: Bool) {
        self.startsOnAppear = startsOnAppear
    }
    #endif

    /// Set only by the DEBUG screenshot aid above; the page itself always opens on a clean start.
    private var startsOnAppear = false

    // MARK: Config (the phone's defaults — fixed on the watch, run-only surface)

    private let workSeconds = 30
    private let restSeconds = 15
    private let rounds = 8

    // MARK: Run state

    private enum Phase {
        case work, rest, done
        var label: String {
            switch self {
            case .work: return String(localized: "WORK")
            case .rest: return String(localized: "REST")
            case .done: return String(localized: "DONE")
            }
        }
    }

    @State private var phase: Phase = .work
    @State private var currentRound = 1
    @State private var remaining = 30      // seconds left in the current phase
    @State private var running = false
    @State private var elapsed = 0         // total elapsed seconds across the session

    // 1Hz tick, same cadence as the phone.
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // MARK: Derived

    private var phaseDuration: Int {
        switch phase {
        case .work: return max(1, workSeconds)
        case .rest: return max(1, restSeconds)
        case .done: return 1
        }
    }

    /// 0...1 progress through the current interval.
    private var intervalProgress: Double {
        guard phaseDuration > 0 else { return 0 }
        let done = Double(phaseDuration - remaining)
        return min(1, max(0, done / Double(phaseDuration)))
    }

    /// The arc colour: ink while working, the Rest colour while resting, the positive green once done.
    private var phaseColor: Color {
        switch phase {
        case .work: return StrandPalette.textPrimary
        case .rest: return StrandPalette.restColor
        case .done: return StrandPalette.statusPositive
        }
    }

    private var isFinished: Bool { phase == .done }

    // MARK: Body

    var body: some View {
        // One-screen fit: no ScrollView. A fixed compact header + the round row + a fixed control row
        // top-and-tail the face, and the countdown ring takes exactly the space left between them, so
        // Start/Pause + Reset are always on screen, on a 41mm right up to an Ultra.
        GeometryReader { geo in
            let spacing: CGFloat = 6
            let headerHeight: CGFloat = 22
            let roundsHeight: CGFloat = 30
            let controlsHeight: CGFloat = 34
            let available = geo.size.height
                - headerHeight - roundsHeight - controlsHeight
                - spacing * 3
            let ringSpace = min(geo.size.width, max(available, 64))
            let diameter = max(64, min(ringSpace, 140))

            VStack(spacing: spacing) {
                header
                    .frame(height: headerHeight)
                heroRing(diameter: diameter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                roundsRow
                    .frame(height: roundsHeight)
                controls
                    .frame(height: controlsHeight)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, 4)
        // The page's one glow, in the Effort world while the session runs.
        .background(WatchGlowBackground(glow: .strain, strength: running ? 0.45 : 0.25))
        .onReceive(ticker) { _ in tick() }
        .onAppear {
            if remaining == 0 { resetToStart() }
            if startsOnAppear, !running { toggleRunning() }
        }
    }

    // MARK: Header — the phase tag

    private var header: some View {
        HStack {
            WatchDotTag(text: phase.label)
            Spacer(minLength: 6)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Hero ring — the countdown

    /// The phase countdown: a faint track, the arc for the time spent in this interval with a white knob,
    /// and m:ss left in the dot face over "of m:ss". The diameter comes from the body's GeometryReader so
    /// the ring soaks up whatever vertical space is left, keeping every control on one screen.
    private func heroRing(diameter: CGFloat) -> some View {
        let lineWidth: CGFloat = max(4, min(6, diameter * 0.04))
        let fraction = isFinished ? 1 : intervalProgress
        let r = diameter / 2
        let a = Angle.degrees(-90 + 360 * fraction).radians
        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.0001, CGFloat(min(max(fraction, 0), 1))))
                .rotation(.degrees(-90))
                .stroke(phaseColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .animation(.snappy, value: fraction)
            Circle()
                .fill(Color.white)
                .frame(width: lineWidth * 1.7, height: lineWidth * 1.7)
                .offset(x: r * CGFloat(cos(a)), y: r * CGFloat(sin(a)))
                .animation(.snappy, value: fraction)
            VStack(spacing: 6) {
                Text(verbatim: isFinished ? "✓" : Self.clock(remaining))
                    .font(StrandFont.dot(diameter * 0.3))
                    .tracking(StrandFont.dotTracking(diameter * 0.3))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                Text(isFinished ? String(localized: "DONE") : String(localized: "of \(Self.clock(phaseDuration))"))
                    .font(StrandFont.light(10))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .padding(.horizontal, lineWidth + 6)
        }
        .frame(width: diameter, height: diameter)
        .animation(.snappy, value: remaining)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isFinished ? String(localized: "Session done")
                                        : String(localized: "\(remaining) seconds remaining in \(phase.label)"))
    }

    /// "Round n/N" and one short bar per round: done rounds dimmed, the current one lit.
    private var roundsRow: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Round \(min(currentRound, rounds))/\(rounds)")
                    .font(StrandFont.book(12.5))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            HStack(spacing: 5) {
                ForEach(1...rounds, id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(roundFill(i))
                        .frame(height: 4)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Round \(min(currentRound, rounds)) of \(rounds)")
    }

    private func roundFill(_ i: Int) -> Color {
        if isFinished || i < currentRound { return Color.white.opacity(0.55) }
        if i == currentRound { return Color.white }
        return Color.white.opacity(0.12)
    }

    /// m:ss for a number of seconds.
    private static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }

    // MARK: Controls — Start/Pause + Reset

    private var controls: some View {
        HStack(spacing: 6) {
            Button {
                if isFinished { resetToStart() }
                toggleRunning()
            } label: {
                HStack(spacing: 5) {
                    PhIcon(running ? "pause" : "play", weight: .fill, size: 12)
                    Text(running ? String(localized: "Pause")
                                 : (isFinished ? String(localized: "Restart") : String(localized: "Start")))
                }
            }
            .buttonStyle(WatchPillButtonStyle(primary: !running))

            Button {
                stopAndReset()
            } label: {
                PhIcon("arrow-counter-clockwise", size: 15)
            }
            .buttonStyle(WatchPillButtonStyle(primary: false))
            .frame(width: 52)
            .accessibilityLabel("Reset")
            .disabled(isCleanStart)
            .opacity(isCleanStart ? 0.4 : 1)
        }
    }

    /// True when nothing has run yet — disables Reset so it never looks active on a fresh session.
    private var isCleanStart: Bool {
        !running && phase == .work && currentRound == 1
            && remaining == max(1, workSeconds) && elapsed == 0
    }

    // MARK: Timer logic (reimplemented to match the phone's parameters)

    private func tick() {
        guard running, !isFinished else { return }

        // 3-2-1 countdown tick on the last seconds of the current phase — a light wrist tap.
        if remaining <= 3 && remaining >= 1 {
            StrandHaptic.selection.play()
        }

        if remaining > 1 {
            remaining -= 1
            elapsed += 1
            return
        }

        // remaining hits 0 — advance to the next phase/round.
        elapsed += 1
        advancePhase()
    }

    private func advancePhase() {
        switch phase {
        case .work:
            if currentRound >= rounds {
                // Last work block finished → session complete.
                finishSession()
            } else {
                // Into rest — a soft single cue.
                phase = .rest
                remaining = max(1, restSeconds)
                StrandHaptic.light.play()
            }
        case .rest:
            // Rest done → next round's work — a strong cue so you feel it without looking.
            currentRound += 1
            phase = .work
            remaining = max(1, workSeconds)
            StrandHaptic.commit.play()
        case .done:
            break
        }
    }

    private func finishSession() {
        withAnimation(.snappy) {
            phase = .done
            remaining = 0
            running = false
        }
        StrandHaptic.success.play()         // long completion cue
    }

    private func toggleRunning() {
        if isFinished { return }
        if running {
            running = false
        } else {
            // Starting fresh from a clean reset → fire the opening WORK cue, like the phone does.
            let startingFresh = isCleanStart
            running = true
            if startingFresh { StrandHaptic.commit.play() }
        }
    }

    private func stopAndReset() {
        running = false
        resetToStart()
    }

    /// Reset run state back to round 1 / start of work, using current config.
    private func resetToStart() {
        phase = .work
        currentRound = 1
        remaining = max(1, workSeconds)
        elapsed = 0
    }
}

#if DEBUG
#Preview("Watch Interval") {
    WatchIntervalView()
}
#endif
