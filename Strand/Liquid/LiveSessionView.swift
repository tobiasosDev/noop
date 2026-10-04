//  LiveSessionView.swift
//  NOOP · Live Sessions (silent guardian) — the in-session screen + summary sheet.
//
//  Deliberately near-empty: one gauge in the hero glow, the band it guards and why, three plain reads,
//  an End button. The gauge is the whole language — the knob rides the engine's smoothed position
//  across the scale, the lit arc is today's band, the glow turns hot above it and grey when the stream
//  is stale (coaching paused, nothing claimed). NO live HR number by default; a long-press on the gauge
//  reveals the engine's smoothed bpm (until then its centre carries the time held in band). Every value
//  on screen is the engine's `Output`, verbatim — this file renders, it never decides.
//
//  Design contract: docs/superpowers/specs/2026-07-04-live-sessions-design.md.

import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

struct LiveSessionView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode / the in-app quiet-motion toggle. The guardian breath is a `repeatForever`
    /// animation that never settles, so it belongs behind the same gate as the liquid surfaces.
    /// The Android twin gated `LiveSessionScreen`'s breath under battery saver in #911.
    @ObservedObject private var motion = NoopMotionState.shared

    /// The strap-cue opt-in (#1115), the same key the Haptics settings bind. The header's vibrate circle
    /// flips it mid-session; the runner reads it at each cue, so the wrist goes quiet from the next one
    /// while cues keep counting toward the session record.
    @AppStorage(HapticPrefs.liveSession) private var strapCuesEnabled = true

    /// One runner per presentation — created here, started on appear, never restarted.
    @StateObject private var runner = LiveSessionRunner()
    let onClose: () -> Void

    /// Long-press reveal for the live (smoothed) bpm — off by default, per the contract.
    @State private var showBpm = false
    /// Caller-owned gauge position: eases to each new smoothed position. HOLDS the last position while
    /// stale — the grey glow says "no reading"; snapping to zero would invent a collapse.
    @State private var ringFraction: Double = 0
    /// False until the engine has produced its first smoothed reading: the knob only appears once there
    /// is a position to show, rather than parking at the scale's start as if that were one.
    @State private var hasReading = false
    /// The slow in-band breathing scale (the only motion on screen).
    @State private var breathe = false
    @State private var showSummary = false
    /// "N sessions guarded" for the summary streak line, read from the store when the session ends.
    @State private var guardedCount: Int?

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    #if DEBUG
    /// DEBUG screenshot harness: start with the bpm already revealed.
    init(onClose: @escaping () -> Void, demoRevealBpm: Bool) {
        self.onClose = onClose
        _showBpm = State(initialValue: demoRevealBpm)
    }
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                titleRow
                    .padding(.top, 10)
                hero
                    .padding(.top, 20)
                statsRow
                    .padding(.top, 22)
                Text(guardianLine)
                    .font(StrandFont.light(13))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
                    .padding(.horizontal, 12)
                endButton
                    .padding(.top, 20)
            }
            .padding(.horizontal, NoopMetrics.screenHPadding)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }
        #if os(iOS)
        .scrollBounceBehavior(.basedOnSize)
        #endif
        #if os(iOS) && DEBUG
        .modifier(DemoScrollAnchor())
        #endif
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NoopVisualStyle.canvas.ignoresSafeArea())
        .noopHidesTabBar()
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 640)
        #endif
        .onAppear {
            runner.start(model: model, repo: repo, ble: model.ble, profile: profile)
        }
        // Left without ending (a dismissed sheet on macOS, a shell teardown): end cleanly so the
        // realtime-HR arm is balanced and the row's totals are banked. Guarded — a normal End already set
        // finalRow, so this only catches the escape paths.
        .onDisappear {
            if runner.finalRow == nil { runner.end() }
        }
        // Both end paths (the End tap and the 10-min stale auto-end) land here: load the streak count,
        // then raise the summary.
        .onChangeCompat(of: runner.finalRow) { row in
            guard row != nil else { return }
            loadGuardedCount()
            showSummary = true
        }
        .onChangeCompat(of: runner.output) { out in advance(to: out) }
        .summaryPresentation(isPresented: $showSummary, onDismiss: { onClose() }) {
            if let row = runner.finalRow {
                LiveSessionSummarySheet(row: row, guardedCount: guardedCount) {
                    showSummary = false   // onDismiss closes the whole session screen
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // A cover has no back gesture; the close circle ends the session the same way End does, so
            // leaving always banks the totals and shows the summary.
            NoopCircleButton("x", accessibilityLabel: "End session") { endSession() }
            Spacer(minLength: 8)
            NoopOverline("Silent guardian")
            Spacer(minLength: 8)
            NoopCircleButton("vibrate", accessibilityLabel: "Strap cues") { strapCuesEnabled.toggle() }
                .opacity(strapCuesEnabled ? 1 : 0.4)
                .accessibilityValue(strapCuesEnabled ? Text("On") : Text("Off"))
        }
    }

    private var titleRow: some View {
        HStack(spacing: 10) {
            Text("Live Session")
                .font(StrandFont.title1)
                .tracking(-0.56)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            NoopTag("BETA", size: 12)
                .accessibilityLabel("Beta feature")
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Hero (the gauge)

    /// The glow carries the engine's position: the Effort blue on track or under, hot above the band,
    /// the neutral glow while there is no reading.
    private var heroGlow: NoopGlow {
        guard let out = runner.output, out.smoothedBpm != nil else { return .ink }
        return out.position == .above ? .low : .strain
    }

    private var hero: some View {
        NoopHeroCard(glow: heroGlow, padding: 0, minHeight: 442) {
            VStack(spacing: 0) {
                gauge
                Text(bandLineText)
                    .font(StrandFont.light(13))
                    .foregroundStyle(Color.white.opacity(0.66))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    .padding(.horizontal, 12)
                HStack(spacing: 8) {
                    PhIcon("hand-tap", size: 18)
                    Text("Long press to show or hide your heart rate.")
                        .font(StrandFont.light(13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color.white.opacity(0.84))
                .padding(.top, 22)
                .padding(.horizontal, 12)
                .accessibilityHidden(true)   // the gauge carries the same hint for VoiceOver
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 30)
            .padding(.horizontal, 10)
            .padding(.bottom, 22)
        }
        .animation(.easeInOut(duration: 0.6), value: heroGlow)
    }

    /// The whole instrument: the scale with today's band lit, the knob at the smoothed position, the
    /// bpm (or, until revealed, the time held in band) at its centre. Breathes only while in band and
    /// active. Long-press toggles the bpm read-out.
    private var gauge: some View {
        let scale = gaugeScale
        return GuardianGauge(
            scaleLow: scale.lowerBound, scaleHigh: scale.upperBound,
            band: (runner.output?.band ?? runner.baseBand).map { ($0.floorBpm, $0.ceilingBpm) },
            fraction: hasReading ? ringFraction : nil,
            live: runner.output?.smoothedBpm != nil
        ) {
            VStack(spacing: 12) {
                NoopDotNumber(showBpm ? bpmText : heldText, size: showBpm ? 96 : 72)
                    .fixedSize()
                    .padding(.vertical, -6)
                // Stays inside the ring: on one line when it fits, else the tag drops under the words
                // (German "im Zielbereich gehalten ·" ran over the scale's ticks).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { gaugeCaption(stacked: false); NoopTag(verbatim: stateTag, size: 12) }
                    VStack(spacing: 6) { gaugeCaption(stacked: true); NoopTag(verbatim: stateTag, size: 12) }
                }
                .frame(maxWidth: 210)
            }
        }
        .frame(width: 330, height: 275)
        .scaleEffect(breathe ? 1.03 : 1.0)
        .contentShape(Rectangle())
        .onLongPressGesture { showBpm.toggle() }
        .onChangeCompat(of: isBreathing) { on in setBreathing(on) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ringAccessibilityLabel))
        .accessibilityValue(showBpm ? Text(verbatim: "\(bpmText) bpm") : Text(verbatim: ""))
        .accessibilityHint(Text("Long press to show or hide your heart rate."))
        .accessibilityAction(named: Text("Show or hide heart rate")) { showBpm.toggle() }
    }

    /// "bpm ·" / "held in band ·"; stacked over the tag, the joining dot has nothing to join and goes.
    private func gaugeCaption(stacked: Bool) -> some View {
        let text = showBpm ? String(localized: "bpm ·") : String(localized: "held in band ·")
        return Text(verbatim: stacked ? text.trimmingCharacters(in: CharacterSet(charactersIn: "· ")) : text)
            .font(StrandFont.light(14))
            .foregroundStyle(Color.white.opacity(0.7))
            .fixedSize()
    }

    /// The bpm range the gauge spans: the classic 60–200 face, widened (in steps of ten) only when
    /// today's band sits closer than 20 bpm to either end.
    private var gaugeScale: ClosedRange<Double> {
        guard let band = runner.output?.band ?? runner.baseBand else { return 60...200 }
        let lo = min(60, ((band.floorBpm - 20) / 10).rounded(.down) * 10)
        let hi = max(200, ((band.ceilingBpm + 20) / 10).rounded(.up) * 10)
        return lo...hi
    }

    /// Breathing is the "on track" signal: only in band, only once active, never when anything is
    /// asking for quiet (Reduce Motion, Low Power Mode, or "Reduce motion in NOOP").
    private var isBreathing: Bool {
        !motion.poseStill(reduceMotion)
            && runner.output?.status == .active
            && runner.output?.position == .inBand
    }

    private func setBreathing(_ on: Bool) {
        if on {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { breathe = true }
        } else {
            withAnimation(.easeOut(duration: 0.5)) { breathe = false }
        }
    }

    /// The engine's smoothed bpm, only when revealed and only when it exists — a stale stream shows a
    /// dash, never a held or guessed number.
    private var bpmText: String {
        guard let s = runner.output?.smoothedBpm else { return "—" }
        return "\(Int(s.rounded()))"
    }

    /// Time held in band so far (m:ss), the engine's own accrual.
    private var heldText: String {
        LiveSessionSummarySheet.clock(runner.output?.inBandSeconds ?? 0)
    }

    /// The one-word state on the gauge, honest per engine status: a stale stream never claims a position.
    private var stateTag: String {
        guard let out = runner.output, out.smoothedBpm != nil else { return String(localized: "No reading") }
        if out.status == .warmup { return String(localized: "Warming up") }
        switch out.position {
        case .inBand: return String(localized: "In band")
        case .below:  return String(localized: "Below")
        case .above:  return String(localized: "Above")
        }
    }

    private var ringAccessibilityLabel: String {
        guard let out = runner.output, out.smoothedBpm != nil else {
            return String(localized: "No live reading. Coaching is paused.")
        }
        switch out.position {
        case .inBand: return String(localized: "In your band. On track.")
        case .below:  return String(localized: "Below your band.")
        case .above:  return String(localized: "Above your band.")
        }
    }

    /// Ease the knob to each new smoothed position across the gauge's scale; hold while stale.
    private func advance(to out: LiveSessionEngine.Output?) {
        guard let out, let s = out.smoothedBpm else { return }
        let scale = gaugeScale
        let f = min(max((s - scale.lowerBound) / (scale.upperBound - scale.lowerBound), 0), 1)
        if !hasReading {
            ringFraction = f
            hasReading = true
        } else {
            withAnimation(.easeOut(duration: 0.9)) { ringFraction = f }
        }
    }

    // MARK: - Lines

    /// The screen's one line of intent, honest per engine status — a stale stream never claims guarding.
    private var guardianLine: String {
        switch runner.output?.status {
        case .stale, .none:
            return String(localized: "No live reading. Coaching is paused until the strap comes back.")
        case .warmup:
            return String(localized: "Warming up. Cues stay quiet for the first minute.")
        case .active:
            return String(localized: "Guarding your session. Silence means you're on track.")
        }
    }

    /// What the band is and why — today's Charge, or the careful default when none is banked.
    private var bandLineText: String {
        guard let band = runner.output?.band ?? runner.baseBand else { return "" }
        let floor = Int(band.floorBpm.rounded()), ceiling = Int(band.ceilingBpm.rounded())
        if let charge = runner.chargeAtStart {
            return String(localized: "Band \(floor)–\(ceiling) bpm, set by today's Charge \(Int(charge.rounded())) %")
        }
        return String(localized: "Band \(floor)–\(ceiling) bpm, a careful middle course with no Charge banked today")
    }

    // MARK: - Stats

    /// Elapsed · cues · time in band, ticking once a second off the wall clock.
    private var statsRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = runner.startTs > 0
                ? max(0, context.date.timeIntervalSince1970 - Double(runner.startTs)) : 0
            let inBand = runner.output?.inBandSeconds ?? 0
            HStack(spacing: 0) {
                G1bCenteredMetric(value: Self.hms(elapsed), label: Text("Elapsed"),
                                  labelColor: StrandPalette.textTertiary)
                divider
                G1bCenteredMetric(value: "\(runner.pushCount + runner.easeCount)",
                                  unit: String(localized: "cues"),
                                  label: Text(verbatim: cueBreakdown),
                                  labelColor: StrandPalette.textTertiary)
                divider
                G1bCenteredMetric(value: elapsed >= 1 ? "\(Int((min(inBand / elapsed, 1) * 100).rounded()))" : "—",
                                  unit: elapsed >= 1 ? "%" : nil,
                                  label: Text("Time in band"),
                                  labelColor: StrandPalette.textTertiary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var divider: some View {
        Rectangle().fill(NoopVisualStyle.border).frame(width: 1)
    }

    private var cueBreakdown: String {
        if runner.pushCount == 0 && runner.easeCount == 0 { return String(localized: "None yet") }
        var parts: [String] = []
        if runner.pushCount > 0 { parts.append(String(localized: "\(runner.pushCount) push")) }
        if runner.easeCount > 0 { parts.append(String(localized: "\(runner.easeCount) ease-off")) }
        return parts.joined(separator: " · ")
    }

    /// "00:18:40".
    static func hms(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    // MARK: - End

    private var endButton: some View {
        Button { endSession() } label: {
            HStack(spacing: 8) {
                PhIcon("stop", weight: .fill, size: 16)
                Text("End session")
            }
        }
        .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
    }

    private func endSession() {
        runner.end()   // finalRow lands via onChangeCompat → summary
    }

    /// "N sessions guarded" — completed sessions in the recent look-back, this one included (its final
    /// row is upserted before `finalRow` publishes).
    private func loadGuardedCount() {
        let deviceId = repo.deviceId
        Task {
            guard let store = await repo.storeHandle() else { return }
            let rows = (try? await store.recentLiveSessions(deviceId: deviceId, limit: 50)) ?? []
            guardedCount = rows.filter { $0.endTs != nil }.count
        }
    }
}

private extension View {
    /// The summary takes the whole screen on iOS (the session itself is a cover); macOS has no
    /// fullScreenCover, so it is a sheet there.
    @ViewBuilder
    func summaryPresentation<Content: View>(isPresented: Binding<Bool>, onDismiss: @escaping () -> Void,
                                            @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #else
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }
}

// MARK: - Gauge

/// The guardian gauge: a 270° scale of 61 ticks (every tenth longer) over a hairline track, today's band
/// as a lit arc with its edges labelled above, the scale's ends labelled below, and a haloed white knob at
/// the current position. `centre` is laid over the middle of the dial.
private struct GuardianGauge<Centre: View>: View {
    let scaleLow: Double
    let scaleHigh: Double
    let band: (floor: Double, ceiling: Double)?
    /// The knob's position on the scale (0…1); nil draws no knob.
    let fraction: Double?
    let live: Bool
    @ViewBuilder var centre: () -> Centre

    /// The kit's band arc ink: a pale Effort blue that reads on the blue glow.
    private static var bandInk: Color { Color(light: "#5872F2", dark: "#B9C6FF") }

    private static var start: Double { 135 }
    private static var sweep: Double { 270 }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let k = w / 360                       // the frame's 360-unit drawing, scaled to fit
            let c = CGPoint(x: 180 * k, y: 170 * k)
            let r = 125 * k
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    drawTicks(ctx, c: c, k: k)
                    var track = Path()
                    track.addArc(center: c, radius: r, startAngle: .degrees(Self.start),
                                 endAngle: .degrees(Self.start + Self.sweep), clockwise: false)
                    ctx.stroke(track, with: .color(.white.opacity(0.12)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    if let band {
                        var arc = Path()
                        arc.addArc(center: c, radius: r, startAngle: angle(band.floor),
                                   endAngle: angle(band.ceiling), clockwise: false)
                        ctx.stroke(arc, with: .color(Self.bandInk), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    }
                    if let fraction {
                        let a = Angle.degrees(Self.start + Self.sweep * min(max(fraction, 0), 1)).radians
                        let p = CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 15, y: p.y - 15, width: 30, height: 30)),
                                 with: .color(.white.opacity(live ? 0.16 : 0.06)))
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)),
                                 with: .color(.white.opacity(live ? 1 : 0.35)))
                    }
                }
                // Scale ends, below the dial.
                label("\(Int(scaleLow))", at: CGPoint(x: (34.7 + 30) * k, y: (266 + 20) * k), strong: false)
                label("\(Int(scaleHigh))", at: CGPoint(x: (265.3 + 30) * k, y: (266 + 20) * k), strong: false)
                // Band edges, just outside the arc.
                if let band {
                    bandLabel(band.floor, c: c, r: r + 30 * k, nudge: -3)
                    bandLabel(band.ceiling, c: c, r: r + 30 * k, nudge: 3)
                }
                centre()
                    .frame(width: w)
                    .position(x: c.x, y: 159 * k)
            }
        }
        .accessibilityHidden(true)
    }

    private func angle(_ bpm: Double) -> Angle {
        let f = min(max((bpm - scaleLow) / max(scaleHigh - scaleLow, 1), 0), 1)
        return .degrees(Self.start + Self.sweep * f)
    }

    private func drawTicks(_ ctx: GraphicsContext, c: CGPoint, k: CGFloat) {
        for i in 0...60 {
            let deg = Self.start + 4.5 * Double(i)
            let a = Angle.degrees(deg).radians
            let major = i % 10 == 0
            let bpm = scaleLow + (scaleHigh - scaleLow) * Double(i) / 60
            let inBand = band.map { bpm >= $0.floor && bpm <= $0.ceiling } ?? false
            let r0 = 137 * k, r1 = (major ? 147 : 143) * k
            var p = Path()
            p.move(to: CGPoint(x: c.x + r0 * CGFloat(cos(a)), y: c.y + r0 * CGFloat(sin(a))))
            p.addLine(to: CGPoint(x: c.x + r1 * CGFloat(cos(a)), y: c.y + r1 * CGFloat(sin(a))))
            let opacity = inBand ? 0.7 : (major ? 0.45 : 0.22)
            ctx.stroke(p, with: .color(.white.opacity(opacity)), lineWidth: 1)
        }
    }

    private func label(_ text: String, at p: CGPoint, strong: Bool) -> some View {
        Text(verbatim: text)
            .font(StrandFont.light(12))
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(strong ? 0.9 : 0.55))
            .fixedSize()
            .position(p)
    }

    private func bandLabel(_ bpm: Double, c: CGPoint, r: CGFloat, nudge: Double) -> some View {
        let a = (angle(bpm).degrees + nudge) * .pi / 180
        return label("\(Int(bpm.rounded()))",
                     at: CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a))), strong: true)
    }
}

// MARK: - Summary

/// The end-of-session read-out: the session's length and how much of it sat inside the band, the cues
/// sent, the band and where it came from, how the time split, a plain verdict, and the streak line.
/// Everything comes off the banked `LiveSessionRow` — the same record the look-back reads, so this
/// screen and history can never disagree.
struct LiveSessionSummarySheet: View {
    let row: LiveSessionRow
    let guardedCount: Int?
    let onDone: () -> Void
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }

    /// Seconds the strap actually tracked (in, below or above the band).
    private var trackedSec: Double { row.inBandSec + row.belowSec + row.aboveSec }
    /// The session's length: start to end on the wall clock, never shorter than the tracked time. Every
    /// share on this screen divides by this one figure, so the hero, the cards and the bar agree.
    private var sessionSec: Double {
        let wall = row.endTs.map { Double($0 - row.startTs) } ?? 0
        return max(wall, trackedSec)
    }
    /// Time inside the session with no reading (stale stream), which no bucket accrues.
    private var unreadSec: Double { max(0, sessionSec - trackedSec) }

    private func share(_ seconds: Double) -> Int {
        sessionSec > 0 ? Int((seconds / sessionSec * 100).rounded()) : 0
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    statGrid
                    NoopSectionTitle("Band adherence", captionKey: "Whole session")
                    adherenceCard
                    NoopInsightRow(verbatim: Self.verdict(row: row))
                        .padding(.top, 8)
                        .padding(.horizontal, 4)
                    if let n = guardedCount, n > 0 {
                        Text(n == 1 ? String(localized: "1 session guarded")
                                    : String(localized: "\(n) sessions guarded"))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
        #if os(iOS)
        .scrollBounceBehavior(.basedOnSize)
        #endif
        #if os(iOS) && DEBUG
        .modifier(DemoScrollAnchor())
        #endif
        .background(NoopVisualStyle.canvas.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            NoopButton("Done", kind: .primary, fullWidth: true) { onDone() }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.top, 24)
                .padding(.bottom, 8)
                .background(
                    LinearGradient(colors: [NoopVisualStyle.canvas.opacity(0), NoopVisualStyle.canvas],
                                   startPoint: .top, endPoint: .center)
                        .ignoresSafeArea(edges: .bottom)
                )
        }
        .noopHidesTabBar()
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    // MARK: Hero

    /// The bleed hero: the glow runs up under the status bar, the session length in dot matrix, and the
    /// one sentence that matters (minutes inside the band).
    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Text("Session summary")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                HStack {
                    NoopCircleButton("x", accessibilityLabel: "Close") { onDone() }
                    Spacer()
                }
            }
            .padding(.horizontal, -2)
            HStack {
                NoopIconBadge("Live session", icon: "heartbeat")
                Spacer(minLength: 8)
                NoopTag("BETA", size: 12)
            }
            .padding(.top, 30)
            HStack(alignment: .bottom, spacing: 10) {
                NoopDotNumber(Self.clock(sessionSec), size: 80)
                    .fixedSize()
                    .padding(.bottom, -6)
                Text("min")
                    .font(StrandFont.light(14))
                    .foregroundStyle(Color.white.opacity(0.66))
                    .padding(.bottom, 8)
            }
            .padding(.top, 24)
            .accessibilityElement(children: .combine)
            Text(verbatim: String(localized: "\(Int((row.inBandSec / 60).rounded())) of \(Int((sessionSec / 60).rounded())) minutes inside your band."))
                .font(StrandFont.light(19))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            Text(verbatim: heroCaption)
                .font(StrandFont.light(13))
                .foregroundStyle(Color.white.opacity(0.62))
                .padding(.top, 8)
        }
        .padding(.top, 6)
        .padding(.horizontal, 22)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            NoopHeroSurface(glow: .strain, bleed: true)
                .ignoresSafeArea(edges: .top)
        }
        .environment(\.colorScheme, .dark)
    }

    /// "Today · silent guardian · band from Charge 78 %".
    private var heroCaption: String {
        let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
        let day: String
        if Calendar.current.isDateInToday(start) {
            day = String(localized: "Today")
        } else if Calendar.current.isDateInYesterday(start) {
            day = String(localized: "Yesterday")
        } else {
            day = start.formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale))
        }
        let source = row.chargeAtStart.map { String(localized: "band from Charge \(Int($0.rounded())) %") }
            ?? String(localized: "no Charge banked")
        return "\(day) · \(String(localized: "silent guardian")) · \(source)"
    }

    // MARK: Cards

    private var statGrid: some View {
        VStack(spacing: NoopMetrics.gap) {
            HStack(spacing: NoopMetrics.gap) {
                statCard("Cues sent", icon: "vibrate", value: "\(row.pushCount + row.easeCount)", unit: nil,
                         caption: cueLine)
                statCard("Band", icon: "target",
                         value: "\(Int(row.floorBpm.rounded()))–\(Int(row.ceilingBpm.rounded()))", unit: "bpm",
                         caption: row.chargeAtStart.map { String(localized: "Gated on Charge \(Int($0.rounded())) %") }
                            ?? String(localized: "No Charge banked"))
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: NoopMetrics.gap) {
                statCard("Time in band", icon: "check-circle", value: "\(share(row.inBandSec))", unit: "%",
                         caption: Self.minSec(row.inBandSec))
                statCard("Out of band", icon: "arrows-down-up", value: "\(share(row.belowSec + row.aboveSec))",
                         unit: "%",
                         caption: String(localized: "\(Self.clock(row.belowSec)) below · \(Self.clock(row.aboveSec)) above"))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statCard(_ title: LocalizedStringKey, icon: String, value: String, unit: String?,
                          caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The kit's card title, allowed a second line: half-width tiles cut German titles
            // ("Gesendete Hi…", "Außerhalb de…"). Each row's pair stretches to the taller tile.
            HStack(alignment: .top, spacing: 8) {
                PhIcon(icon, size: 16).opacity(0.9).padding(.top, 1)
                Text(title)
                    .font(StrandFont.book(14, relativeTo: .subheadline))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value)
                    .font(StrandFont.light(26))
                    .tracking(-0.52)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let unit {
                    Text(verbatim: unit)
                        .font(StrandFont.book(11))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.top, 12)
            Text(verbatim: caption)
                .font(StrandFont.light(10.5))
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .noopPanel(surfaceOpacity: cardOpacity)
        .accessibilityElement(children: .combine)
    }

    /// How the session's time split: one bar in session order of size (in band, above, below, and any
    /// stretch with no reading), with its legend.
    private var adherenceCard: some View {
        let parts: [(label: String, sec: Double, color: Color)] = [
            (String(localized: "In band"), row.inBandSec, NoopGlow.strain.accent),
            (String(localized: "Above"), row.aboveSec, StrandPalette.textPrimary),
            (String(localized: "Below"), row.belowSec, StrandPalette.textTertiary),
            (String(localized: "No reading"), unreadSec, NoopGlow.ink.deep),
        ].filter { share($0.sec) >= 1 }
        return VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(parts.indices, id: \.self) { i in
                        Rectangle()
                            .fill(parts[i].color)
                            .frame(width: sessionSec > 0 ? geo.size.width * CGFloat(parts[i].sec / sessionSec) : 0)
                    }
                }
            }
            .frame(height: 12)
            .background(NoopGlow.ink.deep)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            // Three keys fit one line; a fourth (time with no reading) wraps the legend onto two.
            let rows = parts.count > 3 ? [Array(parts.indices.prefix(2)), Array(parts.indices.dropFirst(2))]
                                       : [Array(parts.indices)]
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 14) {
                        ForEach(rows[r], id: \.self) { i in
                            legendKey(parts[i].label, share: share(parts[i].sec), color: parts[i].color)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .noopPanel(surfaceOpacity: cardOpacity)
        .accessibilityElement(children: .combine)
    }

    private func legendKey(_ label: String, share: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(verbatim: "\(label) \(share) %")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var cueLine: String {
        if row.pushCount == 0 && row.easeCount == 0 {
            return String(localized: "None — silence, start to finish")
        }
        var parts: [String] = []
        if row.pushCount > 0 { parts.append(String(localized: "\(row.pushCount) push")) }
        if row.easeCount > 0 { parts.append(String(localized: "\(row.easeCount) ease-off")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Verdict (pure + honest — fractions of the banked totals, no editorialising beyond them)

    static func verdict(row: LiveSessionRow) -> String {
        let total = row.inBandSec + row.belowSec + row.aboveSec
        guard total >= 300 else {
            return String(localized: "Too short to judge — the band needs a few minutes to mean anything.")
        }
        let inFrac = row.inBandSec / total
        if inFrac >= 0.7 {
            return String(localized: "You held the band. Right where today wanted you.")
        }
        if inFrac >= 0.4 {
            return String(localized: "In and out, but the band won more than it lost.")
        }
        return row.belowSec >= row.aboveSec
            ? String(localized: "Mostly under the band — there was more in the tank today.")
            : String(localized: "Mostly over the band — harder than today's Charge could pay for.")
    }

    /// m:ss off the banked seconds (sessions are an hour-scale affair; no hour arithmetic needed).
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "27 min 05 s".
    static func minSec(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(localized: "\(s / 60) min \(String(format: "%02d", s % 60)) s")
    }
}
