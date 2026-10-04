import SwiftUI
import Foundation
import StrandDesign

/// Silent haptic HIIT interval timer.
///
/// Train hands-free: the strap buzzes every transition so you never have to look
/// at the screen. Strong triple-buzz at the start of each WORK block, a short
/// single buzz into REST, a 3-2-1 tick on the last seconds of every phase, and a
/// long 5-loop buzz when the whole session finishes. With no strap bonded it still
/// works as a big glanceable visual timer (just without haptics).
struct IntervalTimerView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    // MARK: Config (persisted only in-view)

    @State private var workSeconds: Int = 30
    @State private var restSeconds: Int = 15
    @State private var rounds: Int = 8

    // MARK: Run state

    private enum Phase { case work, rest, done
        var label: String {
            switch self {
            case .work: return String(localized: "WORK")
            case .rest: return String(localized: "REST")
            case .done: return String(localized: "DONE")
            }
        }
    }

    @State private var phase: Phase = .work
    @State private var currentRound: Int = 1
    @State private var remaining: Int = 30          // seconds left in the current phase
    @State private var running: Bool = false
    @State private var elapsed: Int = 0             // total elapsed seconds across the session

    // MARK: iPhone haptics (iOS only)
    //
    // The strap buzz (`buzz`) only fires when a strap is bonded; on iPhone the device in
    // the user's hand has a Taptic Engine, so we mirror every transition cue with native
    // haptics that fire regardless of bond state. A monotonically-bumped Int token drives a
    // single `.sensoryFeedback`, so even a repeated cue (the 3-2-1 tick three seconds running)
    // re-fires because the trigger value always changes.
    #if os(iOS)
    private enum HapticCue { case work, rest, tick, done }
    @State private var lastHaptic: HapticCue = .work
    @State private var hapticTick: Int = 0
    #endif

    #if DEBUG
    /// Screenshot harness only: open mid-session (round 3 of 8, 40 s work / 20 s rest) so the running
    /// state can be captured without waiting through two rounds.
    var demoRunning = false
    #endif

    // 1Hz tick.
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

    /// Total planned session length in seconds (work*rounds + rest*(rounds-1)).
    private var totalPlanned: Int {
        guard rounds > 0 else { return 0 }
        return workSeconds * rounds + restSeconds * max(0, rounds - 1)
    }

    private var isFinished: Bool { phase == .done }

    /// The strap's interval cues, the same stored switch as Settings › Haptics (default on).
    @AppStorage(HapticPrefs.intervals) private var strapCues = true

    // MARK: Body

    var body: some View {
        ScreenScaffold(title: nil) {
            NoopScreenHeader("Interval timer")
                .padding(.bottom, 6)
            titleBlock
            stageHero.padding(.top, 6)
            statusRow.padding(.top, 4)
            sessionCard
            controls.padding(.top, 6)
            configSection
            footnote
        }
        .noopHidesSystemNavBar()
        .onReceive(ticker) { _ in tick() }
        .onChangeCompat(of: workSeconds) { _ in if !running { resetToStart() } }
        .onChangeCompat(of: restSeconds) { _ in if !running { resetToStart() } }
        .onChangeCompat(of: rounds) { _ in
            if currentRound > rounds { currentRound = rounds }
            if !running { resetToStart() }
        }
        .onAppear {
            if remaining == 0 { resetToStart() }
            #if DEBUG
            if demoRunning {
                running = true
                workSeconds = 40
                restSeconds = 20
                rounds = 8
                currentRound = 3
                phase = .work
                remaining = 24
                elapsed = 136
            }
            #endif
        }
        // Keep the screen awake while a session runs (no-op on macOS). One onChange covers
        // every running→false transition — manual pause, auto-finish, and reset — and the
        // onDisappear is a safety net so navigating away mid-run never leaves the idle timer
        // disabled app-wide.
        .onChangeCompat(of: running) { ScreenIdle.keepAwake($0) }
        .onDisappear { ScreenIdle.keepAwake(false) }
        #if os(iOS)
        // iPhone haptics: one modifier emits a different feel per cue, re-firing on every
        // token bump. Fires regardless of strap bond so the timer is fully usable unstrapped.
        .sensoryFeedback(trigger: hapticTick) { _, _ in
            switch lastHaptic {
            case .work: return .impact(weight: .heavy)      // strong cue into WORK
            case .rest: return .impact(weight: .light)      // soft cue into REST
            case .tick: return .selection                   // 3-2-1 countdown tick
            case .done: return .success                     // session complete
            }
        }
        #endif
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Interval timer")
                .font(StrandFont.title1)
                .tracking(-0.56)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Silent haptic HIIT: the strap buzzes the transitions")
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Hero — the phase dial

    /// The running interval on the effort glow: the round, the phase dial with the countdown at its
    /// centre, and one segment per round.
    private var stageHero: some View {
        NoopHeroCard(glow: .strain, padding: 22) {
            VStack(spacing: 0) {
                HStack {
                    Text(isFinished ? String(localized: "Session done")
                                    : String(localized: "Round \(min(currentRound, rounds)) / \(rounds)"))
                        .font(StrandFont.book(12, relativeTo: .caption))
                        .tracking(1.44)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.white.opacity(0.8))
                    Spacer(minLength: 8)
                    if let then = thenCaption {
                        Text(verbatim: then)
                            .font(StrandFont.light(12, relativeTo: .caption))
                            .foregroundStyle(NoopMetric.heroLabel)
                    }
                }
                phaseDial
                    .frame(width: 250, height: 250)
                    .padding(.top, 16)
                roundsBar.padding(.top, 22)
                HStack {
                    Text(String(localized: "\(roundsDone) rounds done"))
                        .foregroundStyle(NoopMetric.heroLabel)
                    Spacer(minLength: 8)
                    Text(String(localized: "\(roundsToGo) to go"))
                        .foregroundStyle(Color.white)
                }
                .font(StrandFont.light(11, relativeTo: .caption))
                .padding(.top, 10)
            }
            .padding(.bottom, 2)
        }
    }

    /// "Then 20 s rest" during work, "Then 40 s work" during rest, "Last round" on the final work block.
    private var thenCaption: String? {
        switch phase {
        case .work: return currentRound >= rounds ? String(localized: "Last round")
                                                  : String(localized: "Then \(restSeconds) s rest")
        case .rest: return String(localized: "Then \(workSeconds) s work")
        case .done: return nil
        }
    }

    private var roundsDone: Int { isFinished ? rounds : max(0, currentRound - 1) }
    private var roundsToGo: Int { isFinished ? 0 : max(0, rounds - currentRound) }

    /// The phase dial: 40 ticks and a ring whose bright part is the phase still to run, a white knob where
    /// it has got to, and the phase, the countdown and its length at the centre.
    private var phaseDial: some View {
        let f = isFinished ? 1 : intervalProgress
        return ZStack {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let scale = size.width / 250
                for i in 0..<40 {
                    let t = Double(i) / 40
                    let a = Angle.degrees(-90 + 360 * t).radians
                    let rIn = 104 * scale, rOut = (i % 10 == 0 ? 114 : 111) * scale
                    var p = Path()
                    p.move(to: CGPoint(x: c.x + rIn * CGFloat(cos(a)), y: c.y + rIn * CGFloat(sin(a))))
                    p.addLine(to: CGPoint(x: c.x + rOut * CGFloat(cos(a)), y: c.y + rOut * CGFloat(sin(a))))
                    ctx.stroke(p, with: .color(.white.opacity(t >= f || isFinished ? 0.9 : 0.18)),
                               style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
            }
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 7)
                .padding(29)
            if !isFinished {
                Circle()
                    .trim(from: CGFloat(f), to: 1)
                    .rotation(.degrees(-90))
                    .stroke(StrandPalette.metricCyan, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .padding(29)
                    .animation(.snappy, value: f)
                GeometryReader { geo in
                    let r = geo.size.width / 2 - 29
                    let a = Angle.degrees(-90 + 360 * f).radians
                    Circle().fill(Color.white)
                        .frame(width: 14, height: 14)
                        .position(x: geo.size.width / 2 + r * CGFloat(cos(a)),
                                  y: geo.size.height / 2 + r * CGFloat(sin(a)))
                }
            }
            VStack(spacing: 0) {
                NoopTag(verbatim: phase.label)
                Text(verbatim: timeString(isFinished ? elapsed : remaining))
                    .font(StrandFont.dot(66))
                    .tracking(StrandFont.dotTracking(66))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .padding(.top, 14)
                Text(isFinished ? String(localized: "in total") : String(localized: "of \(phaseDuration) s"))
                    .font(StrandFont.light(12, relativeTo: .caption))
                    .foregroundStyle(NoopMetric.heroLabel)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 44)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isFinished ? "Session done" : "\(remaining) seconds remaining in \(phase.label)")
    }

    /// One segment per round: done rounds bright, the current one filling as it runs (work, then rest),
    /// the rest dim.
    private var roundsBar: some View {
        HStack(spacing: 5) {
            ForEach(1...max(1, rounds), id: \.self) { round in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(round <= roundsDone ? 0.85 : 0.12))
                        if round == currentRound && !isFinished {
                            Capsule(style: .continuous).fill(Color.white)
                                .frame(width: geo.size.width * currentRoundProgress)
                        }
                    }
                }
                .frame(height: 8)
            }
        }
        .accessibilityHidden(true)
    }

    /// Progress through the current round, work and the rest after it together.
    private var currentRoundProgress: Double {
        let last = currentRound >= rounds
        let length = Double(workSeconds + (last ? 0 : restSeconds))
        guard length > 0 else { return 0 }
        let done = phase == .work ? Double(workSeconds - remaining)
                                  : Double(workSeconds + restSeconds - remaining)
        return min(1, max(0, done / length))
    }

    // MARK: Status row

    private var statusRow: some View {
        HStack(spacing: 8) {
            stateChip
            if live.bonded {
                NoopChip(strapCues ? "Buzz cues on" : "Buzz cues off", icon: "vibrate")
            } else {
                NoopChip("Connect strap for buzz cues", icon: "vibrate")
            }
            Spacer(minLength: 0)
            // Heart rate comes from the strap, so it is shown only with one bonded.
            if live.bonded { LiftHeartRatePill() }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private var stateChip: some View {
        HStack(spacing: 6) {
            if running { Circle().fill(StrandPalette.goldDeepText).frame(width: 6, height: 6) }
            // Before the first second it is "Ready": "Paused" would claim a session that never started.
            Text(running ? "Running" : (isFinished ? "Complete" : (elapsed == 0 ? "Ready" : "Paused")))
                .font(StrandFont.book(12, relativeTo: .caption))
        }
        .foregroundStyle(running ? StrandPalette.goldDeepText : StrandPalette.textSecondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule(style: .continuous).fill(running ? StrandPalette.gold : NoopVisualStyle.inset))
        .overlay(Capsule(style: .continuous).strokeBorder(running ? Color.clear : NoopVisualStyle.border, lineWidth: 1))
        .fixedSize()
    }

    // MARK: Session card — elapsed / planned

    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            NoopCardHeader("Session elapsed", icon: "clock") {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(verbatim: timeString(elapsed))
                        .font(StrandFont.value(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(verbatim: " / \(timeString(totalPlanned))")
                        .font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            NoopTrack(fraction: sessionProgress, height: 12)
                .accessibilityElement()
                .accessibilityLabel("Session progress")
                .accessibilityValue("\(Int((sessionProgress * 100).rounded())) percent")
            HStack {
                Text(String(localized: "\(rounds) × \(timeString(workSeconds + restSeconds)) rounds"))
                Spacer(minLength: 8)
                if running {
                    Text(String(localized: "Ends \(Date().addingTimeInterval(TimeInterval(max(0, totalPlanned - elapsed))).formatted(date: .omitted, time: .shortened))"))
                } else {
                    Text(String(localized: "\(timeString(max(0, totalPlanned - elapsed))) left"))
                }
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .lineLimit(1)
        }
        .ltCard()
    }

    private var sessionProgress: Double {
        guard totalPlanned > 0 else { return 0 }
        return min(1, max(0, Double(elapsed) / Double(totalPlanned)))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                if isFinished { resetToStart() }
                toggleRunning()
            } label: {
                HStack(spacing: 8) {
                    PhIcon(running ? "pause" : (isFinished ? "arrow-counter-clockwise" : "play"),
                           weight: isFinished ? .light : .fill, size: 18)
                    Text(running ? "Pause" : (isFinished ? "Restart" : "Start"))
                }
            }
            .buttonStyle(LTPillStyle(kind: .primary))

            Button {
                stopAndReset()
            } label: {
                HStack(spacing: 8) {
                    PhIcon("stop", size: 18)
                    Text("Stop")
                }
            }
            .buttonStyle(LTPillStyle(kind: .ghost))
            .disabled(!running && remaining == phaseDuration && currentRound == 1 && phase == .work && elapsed == 0)
        }
    }

    // MARK: Configure

    @ViewBuilder private var configSection: some View {
        NoopSectionTitle("Configure") {
            if running { Text("Pause to change") }
        }
        NoopList {
            configStepper(title: "Work", caption: "Effort phase", unit: String(localized: "s"),
                          value: $workSeconds, range: 5...600, step: 5)
            configStepper(title: "Rest", caption: "Easy phase", unit: String(localized: "s"),
                          value: $restSeconds, range: 5...600, step: 5)
            configStepper(title: "Rounds", caption: "Work + rest", unit: nil,
                          value: $rounds, range: 1...30, step: 1)
        }
        .disabled(running)
        .opacity(running ? 0.5 : 1)
        NoopList {
            Toggle(isOn: $strapCues) {
                HStack(spacing: 14) {
                    NoopIconTile("vibrate")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Strap buzz cues")
                            .font(StrandFont.book(15, relativeTo: .body))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("3 into work · 1 into rest · a tick on the last 3 seconds")
                            .font(StrandFont.light(12, relativeTo: .caption))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(.noop)
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
        }
    }

    /// One setting with − value + (`.stp`): 34 pt circle steps either side of the value.
    private func configStepper(title: LocalizedStringKey, caption: LocalizedStringKey, unit: String?,
                               value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        NoopRow(title, caption: caption) {
            HStack(spacing: 10) {
                stepButton("minus", enabled: value.wrappedValue > range.lowerBound) {
                    value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(verbatim: "\(value.wrappedValue)")
                        .font(StrandFont.value(17, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                    if let unit {
                        Text(verbatim: unit).font(StrandFont.book(10)).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .frame(minWidth: 52)
                stepButton("plus", enabled: value.wrappedValue < range.upperBound) {
                    value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: "\(value.wrappedValue)\(unit.map { " \($0)" } ?? "")"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
            case .decrement: value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
            @unknown default: break
            }
        }
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PhIcon(icon, size: 15)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(NoopVisualStyle.raised))
                .overlay(Circle().strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(LTPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.38)
    }

    @ViewBuilder private var footnote: some View {
        if !live.bonded {
            Text("Bond your strap on the Live screen to feel the transitions hands-free.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
        }
    }

    // MARK: Timer logic

    private func tick() {
        guard running, !isFinished else { return }

        // Optional 3-2-1 countdown tick on the last seconds of the current phase.
        if remaining <= 3 && remaining >= 1 {
            buzz(loops: 1)
            #if os(iOS)
            haptic(.tick)
            #endif
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
                // Into rest.
                phase = .rest
                remaining = max(1, restSeconds)
                buzz(loops: 1)              // short cue into rest
                #if os(iOS)
                haptic(.rest)
                #endif
            }
        case .rest:
            // Rest done → next round's work.
            currentRound += 1
            phase = .work
            remaining = max(1, workSeconds)
            buzz(loops: 3)                  // strong cue into work
            #if os(iOS)
            haptic(.work)
            #endif
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
        buzz(loops: 5)                      // long completion cue
        #if os(iOS)
        haptic(.done)
        #endif
    }

    private func toggleRunning() {
        if isFinished { return }
        if running {
            running = false
        } else {
            // Starting fresh from a clean reset → fire the opening WORK cue.
            let startingFresh = (phase == .work && currentRound == 1
                                 && remaining == max(1, workSeconds) && elapsed == 0)
            running = true
            if startingFresh {
                buzz(loops: 3)
                #if os(iOS)
                haptic(.work)
                #endif
            }
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

    /// Fire a strap buzz (no-op when not bonded — `buzz` already guards, but we
    /// also skip the call entirely so this stays a pure visual tool when unbonded).
    private func buzz(loops: UInt8) {
        guard live.bonded else { return }
        model.buzz(loops: loops, gate: HapticPrefs.intervals)
    }

    #if os(iOS)
    /// Fire an iPhone haptic cue. Additive to `buzz` and unguarded by bond state, so the
    /// timer gives tactile feedback even with no strap. Bumping the token re-triggers
    /// `.sensoryFeedback` even when the same cue repeats.
    private func haptic(_ cue: HapticCue) {
        lastHaptic = cue
        hapticTick &+= 1
    }
    #endif

    // MARK: Formatting

    private func timeString(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }
}

#if DEBUG
#Preview("Interval Timer") {
    IntervalTimerView()
        .environmentObject(AppModel())
        .environmentObject(LiveState())
        .frame(width: 720, height: 900)
        .preferredColorScheme(.dark)
}
#endif
