import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Manual HRV snapshot — "Take an HRV reading" (#127).
///
/// A short, deliberate seated capture: the user sits still and breathes normally while the strap's
/// live R-R intervals (the reliable 0x2A37 stream) accumulate for ~60 s. We then run the full
/// HRVAnalyzer cleaning pipeline (range filter → Malik ectopic rejection → ≥minBeats) and surface the
/// headline RMSSD plus SDNN, mean HR and the beats used. Saving banks the RMSSD as a single point in
/// the generic metric series ("hrv_snapshot", source "manual-hrv") so it sits beside every other
/// source for the explorer/trends.
///
/// The live ingest uses the shared `onRRPackets` observer; the capture buffer is uncapped (unlike
/// Breathe's rolling 30) because the analysis wants every clean beat. The window is a monotonic
/// 60-second deadline — countdown display and ingest cutoff both derive from it.
struct HRVSnapshotView: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    /// Optional dismissal hook when presented as a sheet (Live → "Take an HRV reading").
    var onClose: (() -> Void)? = nil

    /// Where the live R-R is coming from, so the methodology caveat is honest (#537): a WHOOP 5/MG
    /// derives R-R from the optical pulse signal (noisier) while a WHOOP 4 / chest strap is electrical
    /// R-R. Defaults to `.unknown` for callers that do not pass a strap model, matching the Android twin.
    var source: SpotHrvReading.Source = .unknown

    #if DEBUG
    /// Screenshot harness only: begin a capture as soon as the screen appears.
    var demoAutoStart = false
    #endif

    // MARK: - Capture phase

    private enum Phase: Equatable {
        case idle           // not yet started (or finished and reset)
        case capturing      // accumulating R-R, counting down
        case done           // analysis complete — showing the result
    }

    /// Length of a capture in seconds. Long enough to collect ≥minBeats clean intervals at a resting
    /// rate (≈60 beats at 60 bpm) with headroom for ectopic/range rejection.
    static let captureSeconds = 60

    // MARK: - State

    @State private var phase: Phase = .idle

    /// Every R-R interval (ms) collected during the active capture window — uncapped on purpose; the
    /// analyzer wants the whole window.
    @State private var captureBuffer: [Int] = []
    @State private var secondsRemaining = HRVSnapshotView.captureSeconds

    /// Monotonic start of the active capture — the single time base for the countdown display, the
    /// ingest cutoff, and the finish deadline. Nil outside a capture.
    @State private var captureStart: ContinuousClock.Instant? = nil

    /// Live RMSSD over the beats gathered so far (a running indicator while capturing; the final
    /// figure comes from the cleaned `HRVAnalyzer.analyze`).
    @State private var runningRMSSD: Double? = nil

    /// The completed analysis (nil until `.done`).
    @State private var result: HRVAnalyzer.HRVResult? = nil

    /// Whether the just-finished snapshot has been saved (drives the Save button → "Saved").
    @State private var saved = false

    /// The running RMSSD sampled once a second during the capture (seconds since start, ms), drawn as
    /// the hero trace. View state only; the saved figure comes from the cleaned analysis.
    @State private var rmssdTrace: [(second: Int, rmssd: Double)] = []

    /// Saved readings (newest first) for the "Past readings" list, read from the metric series the Save
    /// button writes.
    @State private var pastReadings: [MetricPoint] = []

    private let secondTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var bonded: Bool { live.bonded }

    var body: some View {
        ScreenScaffold(title: nil) {
            NoopScreenHeader("HRV reading")
                .padding(.bottom, 6)
            titleBlock
            steps.padding(.top, 8)
            captureHero.padding(.top, 6)
            NoopInsightRow(text: Text(instruction), icon: "hand")
                .padding(.horizontal, 4)
                .padding(.top, 8)
            controlRow.padding(.top, 8)
            if phase == .done, let result { resultSection(result) }
            if !pastReadings.isEmpty { pastReadingsSection }
            methodologyCard
            if !bonded { notBondedHint }
        }
        .noopHidesSystemNavBar()
        #if os(iOS)
        // Presented from Live as a sheet: the v2 sheet surface; the header's back circle closes it. A
        // presentation modifier is inert when the screen is pushed instead.
        .noopSheetPresentation(largeFirst: true)
        #endif
        // rrSeq-keyed: equal consecutive packets both count (see RRPacketObserver.swift).
        .onRRPackets(live) { rr in
            ingest(rr)
        }
        // Capture countdown — only ticks while capturing.
        .onReceive(secondTimer) { _ in
            guard phase == .capturing else { return }
            tick()
        }
        .task {
            #if DEBUG
            if demoAutoStart, phase == .idle {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                start()
            }
            #endif
            await loadPastReadings()
        }
        .onDisappear {
            ScreenIdle.keepAwake(false)
        }
    }

    // MARK: - Title and steps

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HRV reading")
                .font(StrandFont.title1)
                .tracking(-0.56)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("A 60-second seated capture.")
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    /// Ready — Capturing — Reading complete, with the current phase as the ink chip. When the labels do
    /// not fit one row (German), finished steps collapse to their check instead of pushing the row, and
    /// with it the whole column, wider than the screen.
    private var steps: some View {
        ViewThatFits(in: .horizontal) {
            stepRow(compact: false)
            stepRow(compact: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func stepRow(compact: Bool) -> some View {
        HStack(spacing: 6) {
            LTStepChip("Ready", state: phase == .idle ? .current : .done, compact: compact)
            stepLine
            LTStepChip("Capturing", state: phase == .capturing ? .current : phase == .done ? .done : .upcoming,
                       compact: compact)
            stepLine
            LTStepChip("Reading complete", state: phase == .done ? .current : .upcoming, compact: compact)
        }
    }

    private var stepLine: some View {
        Rectangle().fill(NoopVisualStyle.borderHighlight).frame(minWidth: 8, maxWidth: .infinity).frame(height: 1)
    }

    // MARK: - Capture hero

    private var captureHero: some View {
        NoopHeroCard(glow: .strain, padding: 22) {
            VStack(spacing: 0) {
                HStack {
                    NoopIconBadge("Seated capture", icon: "heartbeat")
                    Spacer(minLength: 8)
                    Text(heroPill)
                        .font(StrandFont.book(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.07)))
                        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                }
                captureDial
                    .frame(width: 260, height: 260)
                    .padding(.top, 22)
                HStack(alignment: .firstTextBaseline) {
                    Text("Live RMSSD")
                        .font(StrandFont.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(verbatim: runningRMSSD.map { String(format: "%.0f", $0) } ?? "—")
                            .font(StrandFont.value(17))
                        Text("ms").font(StrandFont.book(10)).foregroundStyle(Color.white.opacity(0.62))
                    }
                    .foregroundStyle(StrandPalette.textPrimary)
                }
                .padding(.top, 22)
                LTHeroTrace(points: tracePoints, showsCursor: phase == .capturing && !tracePoints.isEmpty)
                    .frame(height: 64)
                    .padding(.top, 8)
                HStack {
                    Text(verbatim: "0:00")
                    Spacer()
                    Text(verbatim: "1:00")
                }
                .overlay { Text(verbatim: "0:30") }
                .font(StrandFont.footnote)
                .foregroundStyle(Color.white.opacity(0.6))
                .padding(.top, 6)
                .accessibilityHidden(true)
            }
            .padding(.bottom, 2)
        }
    }

    /// Beats so far while capturing; the beats the analysis used once done; the link state before.
    private var heroPill: String {
        switch phase {
        case .idle:      return bonded ? String(localized: "Strap live") : String(localized: "Not connected")
        case .capturing: return String(localized: "\(captureBuffer.count) beats")
        case .done:      return String(localized: "\(result?.nClean ?? 0) beats")
        }
    }

    /// The running-RMSSD trace in unit space: x is the second of the minute, y spans the trace's own
    /// range with headroom so a steady value sits mid-chart.
    private var tracePoints: [CGPoint] {
        guard !rmssdTrace.isEmpty else { return [] }
        let values = rmssdTrace.map(\.rmssd)
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let spread = max(hi - lo, 8)
        let bottom = lo - spread * 0.6, top = hi + spread * 0.4
        return rmssdTrace.map {
            CGPoint(x: Double($0.second) / Double(Self.captureSeconds), y: ($0.rmssd - bottom) / (top - bottom))
        }
    }

    /// The centre dial: sixty ticks around the minute (lit as it elapses), the progress ring with its
    /// knob, and the elapsed clock — or, once done, the headline RMSSD.
    private var captureDial: some View {
        ZStack {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let lit = Int((captureFraction * 60).rounded(.down))
                for i in 0..<60 {
                    let a = Angle.degrees(-90 + Double(i) * 6).radians
                    let rIn: CGFloat = 114, rOut: CGFloat = 124
                    var p = Path()
                    p.move(to: CGPoint(x: c.x + rIn * CGFloat(cos(a)), y: c.y + rIn * CGFloat(sin(a))))
                    p.addLine(to: CGPoint(x: c.x + rOut * CGFloat(cos(a)), y: c.y + rOut * CGFloat(sin(a))))
                    ctx.stroke(p, with: .color(.white.opacity(i < lit ? 0.9 : 0.18)),
                               style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
            }
            Circle().stroke(Color.white.opacity(0.10), lineWidth: 7).frame(width: 200, height: 200)
            Circle()
                .trim(from: 0, to: captureFraction)
                .stroke(StrandPalette.metricCyan, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 200, height: 200)
                .animation(.easeInOut(duration: 0.4), value: captureFraction)
            if captureFraction > 0 {
                let a = Angle.degrees(-90 + 360 * Double(captureFraction)).radians
                Circle().fill(Color.white).frame(width: 14, height: 14)
                    .offset(x: 100 * CGFloat(cos(a)), y: 100 * CGFloat(sin(a)))
                    .animation(.easeInOut(duration: 0.4), value: captureFraction)
            }
            VStack(spacing: 12) {
                Text(verbatim: dialValue)
                    .font(StrandFont.dot(72))
                    .tracking(StrandFont.dotTracking(72))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: dialValue)
                Text(dialCaption)
                    .font(StrandFont.caption)
                    .foregroundStyle(Color.white.opacity(0.62))
            }
            .frame(width: 180)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dialAccessibilityLabel)
    }

    /// 0…1 capture progress, driving the ring trim.
    private var captureFraction: CGFloat {
        switch phase {
        case .idle:      return 0
        case .capturing: return CGFloat(Self.captureSeconds - secondsRemaining) / CGFloat(Self.captureSeconds)
        case .done:      return 1
        }
    }

    private var dialValue: String {
        switch phase {
        case .idle:
            return "0:00"
        case .capturing:
            let elapsed = Self.captureSeconds - secondsRemaining
            return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        case .done:
            return result?.rmssd.map { String(format: "%.0f", $0) } ?? "—"
        }
    }

    private var dialCaption: String {
        switch phase {
        case .idle:      return String(localized: "of 1:00")
        case .capturing: return String(localized: "of 1:00 · \(secondsRemaining) s left")
        case .done:      return String(localized: "ms RMSSD")
        }
    }

    private var instruction: String {
        switch phase {
        case .idle:
            return bonded
                ? String(localized: "Sit still and breathe normally. Tap below to take a 60-second reading.")
                : String(localized: "Connect your strap on the Live screen to take a reading.")
        case .capturing:
            return String(localized: "Sit still, breathe normally. Keep your wrist relaxed and steady.")
        case .done:
            if let r = result, r.rmssd == nil {
                return String(localized: "Not enough clean beats. Sit still and try again.")
            }
            return String(localized: "Done. Save this reading to keep it in your trends.")
        }
    }

    private var dialAccessibilityLabel: String {
        switch phase {
        case .idle:      return String(localized: "HRV reading not started")
        case .capturing: return String(localized: "Capturing. \(secondsRemaining) seconds remaining, \(captureBuffer.count) beats collected.")
        case .done:
            return result?.rmssd.map { String(localized: "RMSSD \(Int($0.rounded())) milliseconds") } ?? String(localized: "Reading incomplete")
        }
    }

    // MARK: - Controls

    @ViewBuilder private var controlRow: some View {
        switch phase {
        case .capturing:
            HStack(spacing: 10) {
                LTActionButton("Cancel") { cancel() }
                LTActionButton("Restart", icon: "arrow-counter-clockwise") { start() }
            }
        case .idle, .done:
            LTActionButton(phase == .idle ? "Take an HRV reading" : "Take another reading",
                           icon: "heart-half", kind: .primary) { start() }
                .disabled(!bonded)
                .help(bonded
                      ? "Take a 60-second seated HRV reading from the live R-R stream."
                      : "Connect your strap first. The reading needs the live R-R stream.")
        }
    }

    // MARK: - Result

    @ViewBuilder private func resultSection(_ result: HRVAnalyzer.HRVResult) -> some View {
        NoopSectionTitle("Result", captionKey: "Seated · 60 s")
        VStack(alignment: .leading, spacing: 0) {
            NoopOverline("Your reading")
            if let rmssd = result.rmssd {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(verbatim: String(format: "%.0f", rmssd))
                        .font(StrandFont.dot(56))
                        .tracking(StrandFont.dotTracking(56))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("ms RMSSD").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    Spacer(minLength: 8)
                    if let morning = morningHRV {
                        NoopTag(verbatim: comparisonWord(rmssd, morning), size: 13)
                    }
                }
                .padding(.top, 12)
                comparisonBars(rmssd).padding(.top, 18)
                if let morning = morningHRV {
                    Text(comparisonSentence(rmssd, morning))
                        .font(StrandFont.light(13, relativeTo: .subheadline))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                }
                NoopMetricRow {
                    NoopMetric(value: Self.format(result.sdnn, "%.0f"), unit: "ms", label: "SDNN")
                    NoopMetric(value: Self.format(Self.meanHR(meanNN: result.meanNN), "%.0f"), unit: "bpm",
                               label: "Mean HR")
                    NoopMetric(value: "\(result.nClean)", unit: String(localized: "used"), label: "Beats")
                }
                .padding(.top, 16)
                HStack(spacing: 10) {
                    LTActionButton(saved ? "Saved" : "Save reading", icon: saved ? "check" : nil, kind: .primary,
                                   height: 46, fontSize: 14) { save(result) }
                        .disabled(saved)
                    LTActionButton("Discard", height: 46, fontSize: 14) { discard() }
                        .disabled(saved)
                }
                .padding(.top, 16)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    PhIcon("warning", size: 18).foregroundStyle(StrandPalette.textPrimary)
                    Text("Not enough clean beats. Sit still and try again. \(result.nClean) of \(result.nInput) beats survived filtering (need \(HRVAnalyzer.minBeats)).")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 12)
            }
        }
        .ltCard()
    }

    /// This morning's overnight RMSSD (the day's banked HRV), when one exists.
    private var morningHRV: Double? { model.repo.today?.avgHrv }

    /// The mean overnight RMSSD over the last 30 banked days.
    private var thirtyDayHRV: Double? {
        let values = model.repo.days.suffix(30).compactMap(\.avgHrv)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func comparisonWord(_ value: Double, _ morning: Double) -> String {
        let diff = value - morning
        if abs(diff) < 3 { return String(localized: "Level") }
        return diff > 0 ? String(localized: "Above") : String(localized: "Below")
    }

    private func comparisonSentence(_ value: Double, _ morning: Double) -> String {
        let diff = Int((value - morning).rounded())
        let head: String
        if abs(diff) < 3 {
            head = String(localized: "In line with this morning's overnight value.")
        } else if diff > 0 {
            head = String(localized: "\(diff) ms above this morning's overnight value.")
        } else {
            head = String(localized: "\(-diff) ms below this morning's overnight value.")
        }
        return head + " " + String(localized: "A seated reading is taken awake, so compare readings with each other rather than with the night.")
    }

    /// This reading beside this morning's overnight value and the 30-day base, on one shared scale.
    private func comparisonBars(_ rmssd: Double) -> some View {
        let rows: [(LocalizedStringKey, Double?, Bool)] = [
            ("This reading", rmssd, true), ("Morning", morningHRV, false), ("30-day base", thirtyDayHRV, false),
        ]
        let scale = max(100, (rows.compactMap(\.1).max() ?? 0) * 1.15)
        return VStack(spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if let value = row.1 {
                    HStack(spacing: 12) {
                        Text(row.0)
                            .font(StrandFont.light(13, relativeTo: .subheadline))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(width: 84, alignment: .leading)
                        // This reading keeps the kit's effort gradient; the references are neutral.
                        if row.2 {
                            NoopTrack(fraction: value / scale, height: 10)
                        } else {
                            NoopTrack(fraction: value / scale, height: 10,
                                      fill: [NoopVisualStyle.quaternaryText, NoopVisualStyle.quaternaryText])
                        }
                        Text(verbatim: "\(Int(value.rounded())) ms")
                            .font(StrandFont.book(13, relativeTo: .subheadline))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Past readings

    @ViewBuilder private var pastReadingsSection: some View {
        NoopSectionTitle("Past readings") { Text(String(localized: "\(pastReadings.count) saved")) }
        NoopList {
            ForEach(Array(pastReadings.prefix(5).enumerated()), id: \.offset) { _, point in
                NoopRow(title: Text(verbatim: Self.readingDayLabel(point.day)),
                        caption: Text("Seated · 60 s"), icon: "heart-half") {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(verbatim: "\(Int(point.value.rounded()))")
                            .font(StrandFont.value(16))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("ms")
                    }
                }
            }
        }
    }

    /// Parses the stored YYYY-MM-DD day; built once rather than per row.
    private static let dayParser: DateFormatter = {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()

    /// "Thu 1 Oct" for a stored YYYY-MM-DD day.
    private static func readingDayLabel(_ day: String) -> String {
        guard let date = dayParser.date(from: day) else { return day }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func loadPastReadings() async {
        guard let store = await model.repo.storeHandle() else { return }
        let points = (try? await store.metricSeries(deviceId: HRVSnapshot.sourceId, key: HRVSnapshot.metricKey,
                                                     from: "0000-00-00", to: "9999-99-99")) ?? []
        pastReadings = points.reversed()
    }

    // MARK: - Methodology

    /// Source-aware methodology (#537): the first line states the spot RMSSD uses the SAME cleaned
    /// Task-Force math as the nightly HRV (so the number is comparable to your overnight figure), then
    /// `SpotHrvReading.caveatFor` adds the honest limits — including the noisier optical-PPG note on a
    /// WHOOP 5/MG. Single-sourced with Android via the shared helper, no em-dashes.
    private var methodologyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            NoopCardHeader("How this is measured", icon: "info")
            Text("A 60-second snapshot of your beat-to-beat (R-R) intervals from the strap, cleaned (range and ectopic-beat filtering) before computing RMSSD the same way your overnight HRV is computed.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            Text(SpotHrvReading.caveatFor(source))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .ltCard()
        .padding(.top, 18)
    }

    // MARK: - Not-bonded hint

    private var notBondedHint: some View {
        HStack(alignment: .top, spacing: 12) {
            PhIcon("bluetooth-slash", size: 18)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("An HRV reading needs the live R-R stream. Open the Live screen and connect your strap, then come back.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .ltCard()
    }

    // MARK: - Capture control

    private func start() {
        guard bonded else { return }
        captureStart = ContinuousClock().now
        phase = .capturing
        captureBuffer.removeAll()
        secondsRemaining = Self.captureSeconds
        runningRMSSD = nil
        rmssdTrace = []
        result = nil
        saved = false
        ScreenIdle.keepAwake(true)      // hold the screen awake through the hands-still capture (no-op on macOS)
    }

    private func cancel() {
        phase = .idle
        captureStart = nil
        secondsRemaining = Self.captureSeconds
        runningRMSSD = nil
        rmssdTrace = []
        ScreenIdle.keepAwake(false)
    }

    /// Drop a finished, unsaved reading and return to Ready.
    private func discard() {
        cancel()
        result = nil
        saved = false
    }

    /// Milliseconds of monotonic time since the capture started (nil outside a capture).
    private func captureElapsedMs() -> Int? {
        guard let start = captureStart else { return nil }
        let c = (ContinuousClock().now - start).components
        return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }

    /// Derive the countdown from the monotonic clock — a late timer fire jumps to the correct
    /// remaining value instead of stretching the window (the old per-callback decrement did).
    private func tick() {
        guard let ms = captureElapsedMs() else { return }
        secondsRemaining = Self.remainingSeconds(elapsedMs: ms)
        if let rmssd = runningRMSSD {
            rmssdTrace.append((second: min(Self.captureSeconds, ms / 1000), rmssd: rmssd))
        }
        if secondsRemaining == 0 {
            finish()
        }
    }

    /// End the capture and run the full cleaning analysis over everything collected.
    private func finish() {
        ScreenIdle.keepAwake(false)
        let captureMs = captureElapsedMs() ?? Self.captureSeconds * 1000
        captureStart = nil
        let raw = captureBuffer.map(Double.init)
        // A capture whose collected beat time exceeds the wall clock it ran for held duplicated
        // beats (e.g. overlapping live sources) — refuse the number rather than publish it.
        if HRVAnalyzer.spotCaptureOverCounted(beatTimeMs: raw.reduce(0, +),
                                              captureMs: Double(captureMs)) {
            result = HRVAnalyzer.HRVResult(rmssd: nil, sdnn: nil, meanNN: nil, pnn50: nil,
                                           nInput: raw.count, nClean: 0)
            phase = .done
            return
        }
        // HRV & Autonomic test mode (Group G): when the mode is on, emit the cleaning trace (nInput /
        // nClean / rejected fraction, the range + Malik ectopic counts, the minBeats + spot gates,
        // RMSSD/SDNN/meanNN) tagged `.hrv`. analyzeTrace returns the SAME HRVResult `analyze` would
        // (it reuses analyze verbatim), so the headline RMSSD is byte-identical with the trace on or off.
        // Zero cost when off: the gate is one UserDefaults bool read and analyzeTrace is never called, so
        // the plain `analyze` path below runs untouched.
        if TestCentre.active(.hrv) {
            let (traced, lines) = HRVAnalyzer.analyzeTrace(
                rawRR: raw, maxRejectedFraction: HRVAnalyzer.defaultSpotMaxRejectedFraction, path: "spot")
            for line in lines { live.append(log: line, domain: .hrv) }
            result = traced
        } else {
            result = HRVAnalyzer.analyze(rawRR: raw,
                                         maxRejectedFraction: HRVAnalyzer.defaultSpotMaxRejectedFraction)
        }
        phase = .done
    }

    // MARK: - Live R-R ingest (mirrors BreathingView)

    /// Append newly-arrived R-R intervals to the capture buffer (only while capturing) and refresh the
    /// running RMSSD indicator. The published `rr` is the latest set of intervals.
    private func ingest(_ rr: [Int]) {
        guard phase == .capturing, !rr.isEmpty,
              let ms = captureElapsedMs(), Self.captureWindowOpen(elapsedMs: ms) else { return }
        captureBuffer.append(contentsOf: rr)
        runningRMSSD = HRVAnalyzer.rmssdRaw(captureBuffer.map(Double.init))
    }

    // MARK: - Save

    /// Persist the snapshot's RMSSD as a single metric point (key "hrv_snapshot", source "manual-hrv",
    /// today's day). Idempotent on (deviceId, day, key) — a second reading the same day overwrites the
    /// earlier one, matching every other importer's upsert semantics.
    private func save(_ result: HRVAnalyzer.HRVResult) {
        guard let rmssd = result.rmssd else { return }
        let day = Repository.dayString(Date())
        let point = MetricPoint(day: day, key: HRVSnapshot.metricKey, value: rmssd)
        saved = true                    // optimistic — the write is local + idempotent
        Task {
            guard let store = await model.repo.storeHandle() else {
                saved = false
                return
            }
            do {
                try await store.upsertMetricSeries([point], deviceId: HRVSnapshot.sourceId)
                await model.repo.refresh()
                await loadPastReadings()
            } catch {
                saved = false
            }
        }
    }

    // MARK: - Pure formatting helpers (shared with the tests)

    static func format(_ value: Double?, _ fmt: String) -> String {
        guard let value else { return "—" }
        return String(format: fmt, value)
    }

    /// Mean heart rate (bpm) from the mean NN interval (ms): 60000 / meanNN. nil when meanNN is missing
    /// or non-positive.
    static func meanHR(meanNN: Double?) -> Double? {
        guard let meanNN, meanNN > 0 else { return nil }
        return 60_000.0 / meanNN
    }

    /// Whole seconds left for a monotonic elapsed time, never negative. Mirrors Android
    /// `remainingCaptureSeconds`.
    static func remainingSeconds(elapsedMs: Int) -> Int {
        max(0, captureSeconds - elapsedMs / 1000)
    }

    /// The ingest gate: intervals on or after the 60-second deadline stay out, however late the
    /// countdown timer fires. Mirrors Android `captureWindowOpen`.
    static func captureWindowOpen(elapsedMs: Int) -> Bool {
        elapsedMs < captureSeconds * 1000
    }
}

/// Snapshot-write constants — the metric-series key + source id the manual HRV reading banks under.
/// Kept as a tiny namespace so the source id ("manual-hrv") and key ("hrv_snapshot") are single-sourced
/// and match the Android side value-for-value.
enum HRVSnapshot {
    /// Generic metric-series key for a manual HRV reading.
    static let metricKey = "hrv_snapshot"
    /// Source id this manual reading is stored under — its own source so it sits beside WHOOP / Apple
    /// for the per-source explorer, exactly like the other manual/imported sources.
    static let sourceId = "manual-hrv"
}
