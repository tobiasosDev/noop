import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

/// The shared explanation for an activity-masked gap on the Stress screen and hosted Today cards.
/// Whole-phrase singular/plural variants keep the sentence natural in every catalog locale.
func stressActivityMaskedHoursCaption(_ count: Int) -> String? {
    guard count > 0 else { return nil }
    return count == 1
        ? String(localized: "1 hour excluded — you were moving.")
        : String(localized: "\(count) hours excluded — you were moving.")
}

// MARK: - Stress Monitor
//
// A clear, Whoop-style "Stress Monitor": one 0–3 number, a band (LOW/MEDIUM/HIGH),
// and a single plain-English line on *why*. The score is a transparent proxy for
// autonomic load.
//
// Source of the daily 0–3 value, in priority order:
//   1. The persisted `stress` metric series ("my-whoop") via `repo.series` — if a
//      day has a stored stress value we trust it.
//   2. Otherwise we DERIVE it from how today's resting HR / HRV sit against a
//      personal 30-day baseline. Stress shows up as HIGHER resting HR and LOWER
//      HRV, so we sum two z-scores and squash onto 0–3 with a logistic curve:
//
//        zRHR = (todayRHR − meanRHR) / sdRHR        // positive when RHR is UP
//        zHRV = (meanHRV − todayHRV) / sdHRV        // positive when HRV is DOWN
//        raw  = zRHR + zHRV                          // combined autonomic load
//        stress = 3 / (1 + e^(−raw))                // 0 calm · 1.5 baseline · 3 high
//
// Bands:  0–1 LOW · 1–2 MEDIUM · 2–3 HIGH.
//
// Everything is computed live from `repo.days` (+ the stored series), so the math
// is fully inspectable — see the "How this is computed" card at the bottom.

struct StressView: View {
    @EnvironmentObject var repo: Repository

    /// The stored 0–3 stress series ("my-whoop"), oldest→newest. Empty → derive.
    @State private var storedSeries: [(day: String, value: Double)] = []
    @State private var loaded = false
    /// Trend window for the chart (W/M/3M/6M/1Y/ALL).
    @State private var range: ExploreRange = .month

    /// Today's intraday stress read (hourly timeline + sustained-high flag), computed
    /// from the day's banked HR + R-R via the SAME 0–3 proxy the daily score uses. Nil
    /// until the async read completes; `.empty` when the day has no usable intraday HR.
    @State private var daytime: DaytimeStress.Result?
    /// Whether TODAY's intraday timeline is scored against the PERSONAL cross-day daytime baseline
    /// (`.baselineRelative`, once enough worn history exists) instead of the day's own calm hours
    /// (`.dayRelative`). Drives only the explanatory copy — the 0–3 scale + bands are identical either way.
    @State private var daytimeUsesPersonalBaseline = false

    /// The screen's drill-downs, as ONE item-driven sheet (stacked `.sheet` modifiers race on macOS):
    /// the Breathe trainer from the sustained-stress suggestion, the range-controlled trend, and the
    /// "How this is computed" note.
    private enum StressSheet: String, Identifiable {
        case breathe, trend, method
        var id: String { rawValue }
    }
    @State private var sheet: StressSheet?

    /// ADDITIVE, on-demand advanced readouts, computed live from the SAME day's R-R the
    /// daytime timeline already reads. These do NOT feed the 0..3 score or the timeline; they
    /// are two extra, clearly-labelled HRV lenses surfaced in their own card. Nil until the
    /// async read completes, and individually nil when their span/beat gates are not met.
    /// Baevsky Stress Index components (si / Mo / AMo / MxDMn).
    @State private var stressIndex: StressIndex.Components?
    /// Frequency-domain HRV bands (LF / HF / LF-HF / total power).
    @State private var freqHRV: HRVFreqDomain.Bands?

    /// Cached StressModel + the input signature it was built from. Rebuilding the
    /// model is expensive (z-score derivation + per-day date parsing over the full
    /// history), so we recompute it only when its inputs actually change — NOT on
    /// every body re-eval (hover / animation / 1 Hz HR ticks).
    @State private var model: StressModel?
    @State private var modelSignature: StressInputs?

    var body: some View {
        ScreenScaffold(title: nil,
                       // PERF (scroll): lazy column; the content is one inner eager VStack, so this only
                       // defers building that stack until it scrolls in.
                       lazy: true) {
            if let model {
                content(model)
            } else {
                NoopScreenHeader("Stress")
                    .padding(.bottom, 8)
                if !loaded {
                    G5EmptyCard(icon: "wave-sine",
                                message: Text("Reading your heart-rate variability and resting heart rate…"))
                } else {
                    emptyState
                }
            }
        }
        .noopHidesSystemNavBar()
        .onAppear { rebuildModelIfNeeded() }
        .onChangeCompat(of: repo.days) { _ in rebuildModelIfNeeded() }
        .task(id: repo.refreshSeq) { await load() }
        .sheet(item: $sheet) { which in
            switch which {
            case .breathe:
                // The sustained-stress suggestion opens the existing Breathe trainer — in-app and
                // passive (no alert / notification), inheriting the app environment.
                // BreathingView draws its own v2 header; its back circle closes this sheet.
                NavigationStack {
                    BreathingView()
                }
                #if os(macOS)
                .frame(width: 520, height: 760)
                #else
                .noopSheetPresentation(largeFirst: true)
                #endif
            case .trend:
                if let model { StressTrendSheet(model: model, range: $range) }
            case .method:
                if let model { StressMethodSheet(model: model) }
            }
        }
    }

    private func load() async {
        storedSeries = await repo.series(key: "stress", source: "my-whoop")
        loaded = true
        rebuildModelIfNeeded()
        await loadDaytime()
    }

    /// Read TODAY's banked HR + R-R and build the intraday stress timeline. Local-day
    /// window [midnight, now]; the helper buckets it into waking hours and reuses the
    /// daily score's math, so this is the same proxy at a finer grain — never a new score.
    private func loadDaytime() async {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        let from = Int(startOfDay.timeIntervalSince1970)
        let to = Int(Date().timeIntervalSince1970)
        let tz = TimeZone.current.secondsFromGMT(for: Date())

        let hr = await repo.hrSamples(from: from, to: to, limit: 200_000)
        // Too few HR samples: empty the timeline AND clear the advanced readouts in lockstep. Without this
        // reset a later refresh that hits this path would leave the Advanced HRV card showing stale values
        // next to an empty timeline (the readouts are only recomputed past this guard).
        guard hr.count >= DaytimeStress.minHourHRSamples else {
            daytime = .empty
            stressIndex = nil
            freqHRV = nil
            return
        }
        let rr = await repo.rrIntervals(from: from, to: to, limit: 200_000)
        // Wrist accelerometer for the motion gate: an ambulatory hour is EXERTION, not stress, so it
        // is masked rather than scored (DaytimeStress). Same store read as R-R; empty on hardware or
        // imports with no gravity, which is exactly the "no masking, prior behaviour" degradation.
        let gravity = await repo.gravitySamplesUnion(from: from, to: to, limit: 200_000)

        // Score today's hours against the PERSONAL cross-day daytime baseline ONLY when the user has
        // opted in (Settings → Experimental) AND enough worn history exists (Oura-style
        // `.baselineRelative`), else the day's own calm hours (`.dayRelative`, the default). The opt-in
        // gate is deliberate: the validated r≈0.6 margin is single-subject so far (#463), so this stays a
        // chooseable lens, not a silent default. The mode is resolved only AFTER the HR-count guard above,
        // so the trailing-history reads are never paid on a day with no scorable timeline — and are never
        // paid at all while the toggle is OFF (the default), keeping the read byte-identical to before.
        let mode = await DaytimeStressMode.selected(
            repo: repo,
            startOfToday: startOfDay,
            calendar: cal,
            personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled
        )
        if case .baselineRelative = mode { daytimeUsesPersonalBaseline = true }
        else { daytimeUsesPersonalBaseline = false }
        // includeTimeline: the SLIDING read, so the screen's line moves in half-hours instead of
        // stepping through whole clock hours (#2144). The scored unit is still a full hour; this only
        // decides how often that hour is re-read. Twin of the Kotlin change.
        // #2181: this is pure, database-free computation over a whole local day of samples, and it used
        // to run inline on this view's (main) actor. `analyze` memoises behind a lock-guarded
        // `AnalyticsMemoCache`, so it is safe off the main actor and the Today card already reads its own
        // stress the same way. Moving it here is what lets the timeline be published — and drawn — before
        // the advanced readouts below are started.
        //
        // `runUnescalated`, NOT `await Task.detached(...).value`: awaiting a task from a @MainActor
        // caller makes it a child and hands it the caller's priority, so a `.utility` label on a
        // detached task is decorative and the work races the UI for cores anyway. StressDayCurve
        // learned that on this same issue; the continuation in UnescalatedWork is what keeps the
        // priority honest.
        daytime = await runUnescalated(priority: .userInitiated) {
            DaytimeStress.analyze(hr: hr, rr: rr, gravity: gravity, tzOffsetSeconds: tz, mode: mode,
                                  includeTimeline: true)
        }

        // ADDITIVE advanced readouts, computed on-demand from the SAME `rr` (no extra fetch, no
        // DB / schema change, and no effect on the 0..3 score above). Each engine returns nil when
        // its own gate is not met (Baevsky needs >= 20 clean beats; freq-HRV needs >= 60 s span),
        // in which case its row is simply hidden.
        // A SECOND hop on purpose (#2181). `HRVFreqDomain` is a Lomb-Scargle periodogram: its cost is
        // (clean beats x frequency-grid steps) with a transcendental per step, and it takes whatever beat
        // count the day's read returned. Run inline it held the main thread for seconds, which is why the
        // screen stayed blank rather than drawing the timeline it already had. Both engines are pure statics
        // over the same `rr`, so they compute together off the main actor and publish when done; their card
        // is hidden until then, exactly as it is when a gate is unmet.
        let advanced = await runUnescalated {
            (index: StressIndex.components(rr: rr), freq: HRVFreqDomain.freqDomain(rr: rr))
        }
        stressIndex = advanced.index
        freqHRV = advanced.freq
    }

    /// Recompute the cached `StressModel` only when (repo.days, storedSeries)
    /// actually changed since the last build. Equality is an O(n) value compare,
    /// far cheaper than the model rebuild it guards.
    private func rebuildModelIfNeeded() {
        let signature = StressInputs(days: repo.days, stored: storedSeries)
        guard signature != modelSignature else { return }
        modelSignature = signature
        model = StressModel(days: repo.days, stored: storedSeries)
    }

    // MARK: Loaded content

    @ViewBuilder
    private func content(_ model: StressModel) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // 1. HERO — the arc gauge, the 0–3 number and the tagged read of why. Bleeds under the
            //    status bar.
            StressHero(model: model)

            // The plain-English line on why, with its advice.
            NoopInsightRow(verbatim: model.explanation)
                .padding(.horizontal, 4)
                .padding(.top, 12)

            // 2. Today's intraday timeline — when in the day stress ran high, + a passive Breathe
            //    suggestion when the recent hours stay elevated.
            // #2535: THREE states, not two. `daytime` is nil only while the read is still running, and this
            // used to render nothing then, so a fold that takes seconds looked exactly like a day with no
            // data. An empty `scored` after the read is a fact about the day and still stays silent.
            if daytime == nil {
                daytimeLoading()
            } else if let daytime, !daytime.scored.isEmpty {
                daytimeSection(daytime)
            }

            // 3. Today's numbers vs the 30-day baseline.
            NoopSectionTitle("Markers", caption: String(localized: "vs 30-day baseline"))
            markerGrid(model)

            // Sustained-high suggestion — only when the recent run stays in the HIGH band.
            if let daytime, daytime.sustainedHigh { sustainedBreatheCard(daytime) }

            // 4. ADVANCED HRV readouts (additive, on-demand), only when at least one engine returned a
            //    value. They never alter the score, the markers or the timeline.
            if hasAdvancedReadouts {
                NoopSectionTitle("Advanced HRV", caption: String(localized: "on demand · today's R-R"))
                advancedReadoutsCard()
            }

            // 5. The trend and the method, each one tap away.
            NoopList {
                Button { sheet = .trend } label: {
                    NoopRow(title: Text("Stress Trend"), caption: trendCaption(model), icon: "chart-line-up",
                            chevron: true) { EmptyView() }
                }
                .buttonStyle(.plain)
                Button { sheet = .method } label: {
                    NoopRow(title: Text("How this is computed"),
                            caption: model.usingStored ? Text("Today's value is your recorded daily stress score (0-3).")
                                                       : Text("Stress is derived from two autonomic signals."),
                            icon: "info", chevron: true) { EmptyView() }
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 18)
        }
    }

    /// "History · avg 1.1 · 30 days" for the trend row.
    private func trendCaption(_ model: StressModel) -> Text {
        let recent = model.fullTrend.suffix(30)
        guard recent.count >= 2 else { return Text("History") }
        let avg = recent.map(\.value).reduce(0, +) / Double(recent.count)
        return Text("History") + Text(verbatim: " · ") + Text("avg \(StressTrace.formatLevel(avg))")
            + Text(verbatim: " · ") + Text("\(recent.count) days")
    }

    // MARK: 2 · Daytime timeline (intraday, same 0–3 proxy)

    /// The intraday timeline while its read is still running (#2535).
    ///
    /// Deliberately NOT the "no stress history" note: that is a conclusion, this says the answer is still
    /// being computed, which is what a caller waiting on the thirty-day fold needs to see. Twin of the
    /// Kotlin `StressDaytimeLoading`.
    @ViewBuilder
    private func daytimeLoading() -> some View {
        NoopCard {
            Text("Reading today's heart rate…")
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 22)
    }

    @ViewBuilder
    private func daytimeSection(_ day: DaytimeStress.Result) -> some View {
        StressDayChart(points: day.timeline, hourLabel: hourLabel)
            .padding(.top, 22)

        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                NoopCardHeader("Today's Timeline", icon: "wave-sine") { Text(verbatim: timelineTrailing(day)) }
                // The Calm / Moderate / High split — how many waking hours sat in each band.
                StressTotalsBar(totals: StressTotals(hours: day.hours))
                Text(daytimeTimelineCaption)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let maskedCaption = stressActivityMaskedHoursCaption(day.activityMaskedHours) {
                    Text(maskedCaption)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 6)
    }

    /// "avg 1.4 · 9h" summary for the timeline header, from the scored hours.
    private func timelineTrailing(_ day: DaytimeStress.Result) -> String {
        let n = day.scored.count
        guard let mean = day.dayMean else { return String(localized: "\(n)h") }
        return String(localized: "avg \(StressTrace.formatLevel(mean)) · \(n)h")
    }

    /// The timeline's explanatory line, honest about WHICH reference each hour was scored against —
    /// the personal cross-day baseline (`.baselineRelative`) or the day's own calm hours (`.dayRelative`).
    /// Explicit `LocalizedStringKey` so BOTH variants stay in the string catalog (a ternary inside
    /// `Text(_:)` would resolve to the verbatim, non-localized `String` overload).
    private var daytimeTimelineCaption: LocalizedStringKey {
        daytimeUsesPersonalBaseline
            ? "The line is each waking hour's 0-3 proxy, scored against your personal daytime baseline (how your own days usually run). The bar below splits your day into calm, moderate and high stress time."
            : "The line is each waking hour's 0-3 proxy, scored against your own calm hours today. The bar below splits your day into calm, moderate and high stress time."
    }

    /// A passive, in-app nudge to run a Breathe session after a sustained high-stress run.
    /// No notification — just a card with a CTA that opens the existing trainer.
    private func sustainedBreatheCard(_ day: DaytimeStress.Result) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    PhIcon("warning-circle", size: 18)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(NoopVisualStyle.raised))
                        .overlay(Circle().strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sustained high stress")
                            .font(StrandFont.book(16, relativeTo: .body))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Your last \(day.sustainedRun) hours have stayed in the high band. A few minutes of paced breathing can help downshift your nervous system.")
                            .font(StrandFont.light(13.5, relativeTo: .subheadline))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button { sheet = .breathe } label: {
                    HStack(spacing: 8) {
                        PhIcon("wind", size: 18)
                        Text("Start a Breathe session")
                    }
                }
                .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
            }
        }
        .softCardTransition()
    }

    /// Hour-of-day label following the device's locale + 12-/24-hour preference ("2 PM" / "14 Uhr"),
    /// instead of a hard-coded English "am/pm" (which read "3 pm" for 24-hour locales like German).
    private func hourLabel(_ hour: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        let date = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    // MARK: 4 · Advanced HRV readouts (additive, on-demand)
    //
    // Extra, clearly-labelled lenses on the SAME day's R-R the timeline already reads, surfaced in their
    // own card so they are visibly separate from the 0..3 monitor. Each readout is shown only when its
    // engine produced a value (the engines self-gate on clean-beat count / record span), and the whole
    // card is gated by `hasAdvancedReadouts`. Nothing here feeds the score.

    /// True when at least one advanced readout is presentable (an SI value, or an LF/HF ratio, or
    /// at least the HF power). Drives whether the advanced card is shown at all.
    private var hasAdvancedReadouts: Bool {
        if stressIndex != nil { return true }
        if let f = freqHRV, f.lfhf != nil || f.hf > 0 { return true }
        return false
    }

    @ViewBuilder
    private func advancedReadoutsCard() -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 0) {
                NoopMetricRow {
                    // Baevsky Stress Index, a whole number; higher means a more rigid, stressed rhythm.
                    if let si = stressIndex {
                        NoopMetric(value: "\(Int(si.si.rounded()))", label: "Baevsky Stress Index")
                            .accessibilityHint("Autonomic rigidity from your heart-rate rhythm. Higher means a more rigid, stressed rhythm.")
                    }
                    // Frequency-domain HRV: the LF/HF ratio when the span allowed LF, and the HF (rest)
                    // band power whenever it read.
                    if let f = freqHRV {
                        if let ratio = f.lfhf {
                            NoopMetric(value: StressTrace.formatRatio(ratio), label: "Autonomic balance (LF/HF)")
                                .accessibilityHint("Sympathetic vs parasympathetic tone from frequency-domain HRV. Higher leans sympathetic (stress-ward).")
                        }
                        if f.hf > 0 {
                            NoopMetric(value: "\(Int(f.hf.rounded()))", unit: "ms²", label: "HF power")
                                .accessibilityHint("Parasympathetic (rest) band of your HRV.")
                        }
                    }
                }
                Text("These are extra, on-demand HRV lenses computed from today's R-R intervals. They are informational and do not change the stress score above.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .overlay(alignment: .top) { Rectangle().fill(NoopVisualStyle.border).frame(height: 1) }
                    .padding(.top, 14)
            }
        }
    }

    // MARK: 3 · Markers (2 × 2 tiles vs the 30-day baseline)

    private func markerGrid(_ model: StressModel) -> some View {
        Grid(horizontalSpacing: NoopMetrics.gap, verticalSpacing: NoopMetrics.gap) {
            GridRow {
                // Today's stress value, with its band as the chip.
                StressMarkerTile(label: "Stress", icon: "wave-sine",
                                 value: StressTrace.formatLevel(model.score), unit: String(localized: "of 3"),
                                 chip: model.band.title, chipIcon: nil)
                // Resting HR — an INCREASE is the stressful direction.
                markerTile(label: "Resting HR", icon: "heart",
                           value: model.rhrToday.map { "\($0)" }, unit: "bpm",
                           delta: model.rhrDelta, deltaUnit: "bpm")
            }
            GridRow {
                // HRV — a DECREASE is the stressful direction.
                markerTile(label: "HRV", icon: "heartbeat",
                           value: model.hrvToday.map { "\(Int($0.rounded()))" }, unit: "ms",
                           delta: model.hrvDelta, deltaUnit: "ms")
                // Estimated calm time — share of recent days spent in the LOW band.
                StressMarkerTile(label: "Calm time", icon: "leaf", value: model.calmTimeValue, unit: nil,
                                 chip: model.calmTimeCaption, chipIcon: nil)
            }
        }
    }

    /// A vs-baseline marker tile. The chip states the move against the 30-day baseline.
    private func markerTile(label: LocalizedStringKey, icon: String, value: String?, unit: String,
                            delta: Double?, deltaUnit: String) -> some View {
        let chip: String?
        let chipIcon: String?
        // NO CHIP for a missing delta, rather than a claim we cannot make (#2145). It is nil when
        // today has no reading or there is no 30-day baseline to stand one against, and both fell
        // through to the at-baseline chip: a tile with no reading read "— at baseline", and a
        // first-week tile put a reading exactly on a baseline that did not exist yet.
        if delta == nil {
            chip = nil
            chipIcon = nil
        } else if let delta, abs(delta) >= 0.5 {
            let up = delta > 0
            chip = "\(up ? "+" : "−")\(Int(abs(delta).rounded())) \(deltaUnit)"
            chipIcon = up ? "arrow-up" : "arrow-down"
        } else {
            chip = String(localized: "at baseline")
            chipIcon = nil
        }
        return StressMarkerTile(label: label, icon: icon, value: value ?? "—", unit: value == nil ? nil : unit,
                                chip: chip, chipIcon: chipIcon)
    }

    // MARK: Empty state

    private var emptyState: some View {
        G5EmptyCard(icon: "wave-sine",
                    message: Text("No stress history yet. Import your WHOOP export in Data Sources to see it."))
    }
}

// MARK: - Stress hero (bleeds under the status bar)

/// The Stress hero: the screen header, the 0–3 arc gauge across the top of the glow, the dot-matrix
/// score, the scored day, and a tagged read of why (band, resting HR and HRV against baseline).
private struct StressHero: View {
    let model: StressModel

    /// The scored day as a LOCAL date (a UTC parse would render the previous day west of Greenwich).
    private var dayDate: Date? { Self.localDayParser.date(from: model.day) }
    private static let localDayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private var isToday: Bool { model.day == Repository.localDayKey(Date()) }

    var body: some View {
        VStack(spacing: 0) {
            NoopScreenHeader("Stress") {
                if let dayDate {
                    NoopPill(verbatim: dayDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
                        .locale(AppLanguage.activeLocale)))
                }
            }
            NoopDotNumber(StressTrace.formatLevel(model.score), size: 96)
                .padding(.top, 146)
                .accessibilityLabel(String(localized: "Stress \(StressTrace.formatLevel(model.score)) of 3"))
            Text(captionText)
                .font(StrandFont.light(13, relativeTo: .footnote))
                .foregroundStyle(Color.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.top, 12)
            VStack(spacing: 2) {
                G5TaggedSentence(bandSentence, tag: model.band.title)
                if let rhr = model.rhrDelta {
                    G5TaggedSentence(String(localized: "Resting HR was \(G5TaggedSentence.slot) your baseline."),
                                     tag: Self.relation(rhr))
                }
                if let hrv = model.hrvDelta {
                    G5TaggedSentence(String(localized: "HRV was \(G5TaggedSentence.slot) your baseline."),
                                     tag: Self.relation(hrv))
                }
            }
            .padding(.top, 22)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity, minHeight: 466, alignment: .top)
        .background(alignment: .top) {
            StressArcGauge(fraction: model.score / 3)
                .frame(height: 300)
                .allowsHitTesting(false)
        }
        // The glow runs on up under the status bar (the scroll view's top inset).
        .background(alignment: .bottom) {
            NoopHeroSurface(glow: .stress, bleed: true)
                .padding(.top, -90)
        }
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, -NoopMetrics.screenHPadding)
        .padding(.top, -8)
    }

    /// "Thu 1 Oct · from resting HR and HRV vs your baseline" — which day was scored and how.
    private var captionText: String {
        let day = dayDate.map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
            .locale(AppLanguage.activeLocale)) } ?? model.day
        return model.usingStored
            ? String(localized: "\(day) · your recorded daily score")
            : String(localized: "\(day) · resting HR and HRV vs your baseline")
    }

    private var bandSentence: String {
        if isToday { return String(localized: "Your stress ran \(G5TaggedSentence.slot) today.") }
        let weekday = dayDate.map { $0.formatted(.dateTime.weekday(.wide).locale(AppLanguage.activeLocale)) } ?? model.day
        return String(localized: "Your stress ran \(G5TaggedSentence.slot) on \(weekday).")
    }

    /// The tag word for a reading against its baseline, with the same ±1 dead band the explanation uses.
    private static func relation(_ delta: Double) -> String {
        if delta > 1 { return String(localized: "above") }
        if delta < -1 { return String(localized: "below") }
        return String(localized: "at")
    }
}

/// The hero arc: a wide 72° sweep near the top of the glow, a ruler of ticks inside it, the filled part
/// lit in the stress accent up to `fraction` (0…1 of the 0–3 scale), and a glowing knob with a short
/// needle at the value.
private struct StressArcGauge: View {
    let fraction: Double

    /// Radius of the sweep, in points; the centre sits this far below the arc's crest.
    private static let radius: CGFloat = 352
    /// The crest of the arc, measured from the top of the hero content.
    private static let crestY: CGFloat = 126
    private static let start = -125.9, end = -54.1   // degrees, 0 = +x, clockwise

    var body: some View {
        Canvas { ctx, size in
            let r = Self.radius
            let c = CGPoint(x: size.width / 2, y: Self.crestY + r)
            let f = min(max(fraction, 0), 1)
            let valueAngle = Self.start + (Self.end - Self.start) * f
            func point(_ deg: Double, _ radius: CGFloat) -> CGPoint {
                let a = Angle.degrees(deg).radians
                return CGPoint(x: c.x + radius * CGFloat(cos(a)), y: c.y + radius * CGFloat(sin(a)))
            }
            let accent = NoopGlow.stress.accent

            // Ruler: 120 small ticks inside the arc and a long one every 20th, brighter before the value.
            let tickStart = -121.6, tickEnd = -58.4
            for i in 0...120 {
                let t = Double(i) / 120
                let deg = tickStart + (tickEnd - tickStart) * t
                let long = i % 20 == 0
                let lit = deg <= valueAngle
                var opacity: Double
                if long {
                    opacity = lit ? (i == 0 ? 0.3 : 0.85) : (i == 120 ? 0.15 : 0.42)
                } else {
                    opacity = lit ? min(0.5, 0.2 + t * 2.5) : max(0.08, 0.2 - (t - f) * 0.4)
                }
                var p = Path()
                p.move(to: point(deg, long ? 325 : 337.6))
                p.addLine(to: point(deg, long ? 354.5 : 348.6))
                ctx.stroke(p, with: .color(.white.opacity(opacity)), lineWidth: long ? 1.4 : 1)
            }

            // The unlit remainder of the sweep.
            var rest = Path()
            rest.addArc(center: c, radius: r, startAngle: .degrees(valueAngle), endAngle: .degrees(Self.end + 9),
                        clockwise: false)
            ctx.stroke(rest, with: .color(.white.opacity(0.16)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

            // The lit sweep: a soft glow under a crisp line, fading in from the left.
            var lit = Path()
            lit.addArc(center: c, radius: r, startAngle: .degrees(Self.start - 9), endAngle: .degrees(valueAngle),
                       clockwise: false)
            let litShading = GraphicsContext.Shading.linearGradient(
                Gradient(stops: [.init(color: accent.opacity(0.05), location: 0),
                                 .init(color: accent.opacity(0.55), location: 0.45),
                                 .init(color: accent, location: 0.85),
                                 .init(color: .white, location: 1)]),
                startPoint: point(Self.start - 9, r), endPoint: point(valueAngle, r))
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 5))
                l.opacity = 0.35
                l.stroke(lit, with: litShading, lineWidth: 12)
            }
            ctx.stroke(lit, with: litShading, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))

            // Needle + knob at the value.
            let knob = point(valueAngle, r)
            var needle = Path()
            needle.move(to: knob)
            needle.addLine(to: point(valueAngle, r - 66))
            ctx.stroke(needle, with: .linearGradient(Gradient(colors: [.white, .white.opacity(0)]),
                                                     startPoint: knob, endPoint: point(valueAngle, r - 66)),
                       style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: knob.x - 22, y: knob.y - 22, width: 44, height: 44)),
                     with: .radialGradient(Gradient(colors: [.white.opacity(0.9), accent.opacity(0.35), accent.opacity(0)]),
                                           center: knob, startRadius: 0, endRadius: 22))
            let core = Path(ellipseIn: CGRect(x: knob.x - 8, y: knob.y - 8, width: 16, height: 16))
            ctx.fill(core, with: .color(.white))
            ctx.stroke(core, with: .color(accent.opacity(0.9)), lineWidth: 3)
        }
        .accessibilityHidden(true)
    }
}

/// One marker tile: an icon + label header, the value with its unit, and a neutral chip (the move
/// against baseline, or the band).
private struct StressMarkerTile: View {
    let label: LocalizedStringKey
    let icon: String
    let value: String
    let unit: String?
    let chip: String?
    let chipIcon: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                PhIcon(icon, size: 15).opacity(0.9)
                Text(label).font(StrandFont.book(13, relativeTo: .footnote)).lineLimit(1)
            }
            .foregroundStyle(StrandPalette.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value)
                    .font(StrandFont.value(27, weight: 300))
                    .tracking(-0.54)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let unit {
                    Text(verbatim: unit)
                        .font(StrandFont.book(11))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.top, 12)
            if let chip {
                HStack(spacing: 4) {
                    if let chipIcon { PhIcon(chipIcon, size: 11) }
                    Text(verbatim: chip).lineLimit(1).minimumScaleFactor(0.75)
                }
                .font(StrandFont.book(12, relativeTo: .caption))
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(NoopVisualStyle.raised))
                .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .noopPanel()
        .accessibilityElement(children: .combine)
    }
}

/// The intraday stress chart: a 0–3 scale on the left, the HIGH band floor dashed at 2.0, the day's
/// scored stretches as a line + fill in the stress accent (a gap where an hour has no reading), the peak
/// hour highlighted and labelled, and a cursor on the latest reading.
private struct StressDayChart: View {
    let points: [DaytimeStress.HourPoint]
    let hourLabel: (Int) -> String

    private var peak: DaytimeStress.HourPoint? {
        points.filter { $0.level != nil }.max { ($0.level ?? 0) < ($1.level ?? 0) }
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading) {
                    Text(verbatim: "3.0"); Spacer(); Text(verbatim: "2.0"); Spacer()
                    Text(verbatim: "1.0"); Spacer(); Text(verbatim: "0")
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 28, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.top, 6)
                GeometryReader { geo in
                    plot(size: geo.size)
                }
            }
            .frame(height: 176)
            hourAxis
                .padding(.leading, 28)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func y(_ level: Double, _ h: CGFloat) -> CGFloat {
        let top: CGFloat = 10, bottom = h - 10
        return bottom - (bottom - top) * CGFloat(min(max(level / 3, 0), 1))
    }

    private func x(_ i: Int, _ w: CGFloat) -> CGFloat {
        points.count <= 1 ? w / 2 : w * CGFloat(i) / CGFloat(points.count - 1)
    }

    /// Contiguous runs of scored points, so a hole in the day stays a hole.
    private func runs(_ size: CGSize) -> [[CGPoint]] {
        var out: [[CGPoint]] = [], run: [CGPoint] = []
        for (i, p) in points.enumerated() {
            guard let level = p.level else {
                if !run.isEmpty { out.append(run); run = [] }
                continue
            }
            run.append(CGPoint(x: x(i, size.width), y: y(level, size.height)))
        }
        if !run.isEmpty { out.append(run) }
        return out
    }

    @ViewBuilder
    private func plot(size: CGSize) -> some View {
        let w = size.width, h = size.height
        let accent = NoopGlow.stress.accent
        let segs = runs(size)
        ZStack(alignment: .topLeading) {
            ForEach([3.0, 1.0, 0.0], id: \.self) { lv in
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).offset(y: y(lv, h))
            }
            Path { p in
                p.move(to: CGPoint(x: 0, y: y(2, h)))
                p.addLine(to: CGPoint(x: w, y: y(2, h)))
            }
            .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            Text("High zone")
                .font(StrandFont.light(9.5))
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: w, alignment: .trailing)
                .offset(y: y(2, h) - 14)
            if let peak, let lvl = peak.level, let i = points.firstIndex(of: peak) {
                let px = x(i, w)
                let bandW = max(w / CGFloat(max(points.count, 1)), 14)
                Rectangle().fill(Color.white.opacity(0.06))
                    .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.6)).frame(height: 1) }
                    .frame(width: bandW, height: h - 20)
                    .offset(x: min(max(px - bandW / 2, 0), w - bandW), y: 10)
                Text("peak \(StressTrace.formatLevel(lvl)) · \(hourLabel(peak.hour))")
                    .font(StrandFont.light(10))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize()
                    .position(x: min(max(px, 50), w - 50), y: -4)
            }
            ForEach(Array(segs.enumerated()), id: \.offset) { _, seg in
                if seg.count >= 2 {
                    Path { p in
                        p.move(to: CGPoint(x: seg[0].x, y: h - 10))
                        seg.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: seg[seg.count - 1].x, y: h - 10))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [accent.opacity(0.42), accent.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { p in p.addLines(seg) }
                        .stroke(LinearGradient(colors: [accent.opacity(0.6), accent, .white.opacity(0.9)],
                                               startPoint: .leading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
                } else if let only = seg.first {
                    Circle().fill(accent).frame(width: 5, height: 5).position(only)
                }
            }
            if let last = segs.last?.last {
                Path { p in
                    p.move(to: last)
                    p.addLine(to: CGPoint(x: last.x, y: h - 10))
                }
                .stroke(Color.white.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                Circle().fill(Color.white).frame(width: 6, height: 6).position(last)
                Circle().fill(Color.white).frame(width: 7, height: 7).position(x: last.x, y: h - 10)
            }
        }
    }

    /// First, a middle and the last covered hour under the plot.
    private var hourAxis: some View {
        HStack {
            if let lo = points.first?.hour, let hi = points.last?.hour {
                Text(verbatim: hourLabel(lo))
                Spacer()
                Text(verbatim: hourLabel((lo + hi) / 2))
                Spacer()
                Text(verbatim: hourLabel(hi)).foregroundStyle(StrandPalette.textPrimary)
            }
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
    }

    private var accessibilitySummary: String {
        let scored = points.compactMap { p in p.level.map { (p.hour, $0) } }
        guard !scored.isEmpty else { return String(localized: "No intraday stress data yet today.") }
        let parts = scored.map { "\($0.0):00 \(StressTrace.formatLevel($0.1))" }
        return String(localized: "Autonomic load today: \(parts.joined(separator: ", "))")
    }
}

/// The range-controlled daily stress trend, one tap from the Stress screen.
private struct StressTrendSheet: View {
    let model: StressModel
    @Binding var range: ExploreRange
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let points = windowedTrend
        VStack(spacing: 0) {
            NoopSheetHeader("Stress Trend", cancelTitle: "Done", doneTitle: nil, onCancel: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    if points.count >= 2 {
                        let avg = points.map(\.value).reduce(0, +) / Double(points.count)
                        // Axis top = highest reading rounded up, plus a little headroom, so a peak curve and
                        // the top axis label clear the plot clip (#974). Floor of 1 keeps a flat calm history
                        // from collapsing to a zero-height axis.
                        let peak = (points.map(\.value).max() ?? 3).rounded(.up)
                        let yTop = max(1, peak + 0.3)
                        NoopCard {
                            VStack(alignment: .leading, spacing: 14) {
                                NoopCardHeader("Stress · \(range.label)", icon: "chart-line-up") {
                                    Text("avg \(StressTrace.formatLevel(avg))")
                                }
                                TrendChart(
                                    points: points,
                                    gradient: Gradient(colors: [NoopGlow.stress.accent.opacity(0.6), NoopGlow.stress.accent]),
                                    valueRange: 0...3,
                                    showsArea: true,
                                    height: NoopMetrics.chartHeight,
                                    valueFormat: { StressTrace.formatLevel($0) },
                                    accessibilityLabel: String(localized: "Stress trend"),
                                    yDomain: 0...yTop
                                )
                                NoopMetricRow {
                                    NoopMetric(value: StressTrace.formatLevel(model.score), label: "Today")
                                    NoopMetric(value: StressTrace.formatLevel(avg), label: "Average")
                                    NoopMetric(value: "\(points.count)", label: "Days")
                                }
                                Text("Daily 0-3 proxy")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        SegmentedPillControl(ExploreRange.allCases, selection: $range,
                                             adaptsToAvailableWidth: true) { $0.label }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        G5EmptyCard(icon: "chart-line-up",
                                    message: Text("Not enough recent days to chart a trend yet. Import a history or keep wearing your strap."))
                    }
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.bottom, 30)
            }
        }
        .background(NoopSheetBackground())
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #else
        .frame(width: 560, height: 640)
        #endif
    }

    /// The full daily proxy trend, sliced to the selected trailing window. Falls
    /// back to ALL when the trailing slice holds < 2 points.
    private var windowedTrend: [TrendPoint] {
        let all = model.fullTrend
        guard let days = range.days, let last = all.last?.date else { return all }
        let cutoff = last.addingTimeInterval(-Double(days - 1) * 86_400)
        let slice = all.filter { $0.date >= cutoff }
        return slice.count >= 2 ? slice : all
    }
}

/// "How this is computed": the transparency note, one tap from the Stress screen.
private struct StressMethodSheet: View {
    let model: StressModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            NoopSheetHeader("How this is computed", cancelTitle: "Done", doneTitle: nil, onCancel: { dismiss() })
            ScrollView {
                NoopCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(model.usingStored
                             ? "Today's value is your recorded daily stress score (0-3)."
                             : "Stress is derived from two autonomic signals.")
                            .font(StrandFont.book(15, relativeTo: .body))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("We compare today's resting heart rate and HRV to your own 30-day baseline. A higher-than-usual resting HR and a lower-than-usual HRV both push the score up, classic signs the body is activated. The combined shift is mapped onto a 0-3 scale: 0 is calm, 1.5 sits at your baseline, 3 is highly activated.")
                            .font(StrandFont.light(14, relativeTo: .subheadline))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
                        HStack(spacing: 0) {
                            bandLegend("0-1", String(localized: "LOW"))
                            bandLegend("1-2", String(localized: "MEDIUM"))
                            bandLegend("2-3", String(localized: "HIGH"))
                        }
                    }
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.bottom, 30)
            }
        }
        .background(NoopSheetBackground())
        #if os(iOS)
        .noopSheetPresentation(largeFirst: false)
        #else
        .frame(width: 520, height: 420)
        #endif
    }

    private func bandLegend(_ range: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            NoopTag(verbatim: label, size: 11).fixedSize()
            Text(verbatim: range).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Stress band

enum StressBand {
    case low, medium, high

    init(score: Double) {
        switch score {
        case ..<1.0: self = .low
        case ..<2.0: self = .medium
        default:     self = .high
        }
    }

    var title: String {
        switch self {
        case .low:    return String(localized: "LOW")
        case .medium: return String(localized: "MEDIUM")
        case .high:   return String(localized: "HIGH")
        }
    }

    var tone: StrandTone {
        switch self {
        case .low:    return .positive
        case .medium: return .warning
        case .high:   return .critical
        }
    }
}

// MARK: - Stress ramp (the WHOOP Stress sweep: blue → green → amber)
//
// The Stress screen's one ramp. WHOOP has NO gold: calm reads as the link blue, a
// balanced day as positive green, and a high-stress day as warning amber. The
// semicircle gauge fill, the day autonomic-load line, the Calm/Moderate/High totals bar
// and the trend all sample this SAME ramp, so the colour language is identical across
// the screen. Never the gold or red→green recovery ramp.

enum StressRamp {
    /// Band anchors, lifted from the shared palette (no hard-coded hex). These are the
    /// blue / green / amber the totals legend and band dots use, kept in lock-step with
    /// the gauge gradient below.
    static let calm    = StrandPalette.accent         // #60A0E0 — calm WHOOP blue
    static let steady  = StrandPalette.statusPositive // #03E095 — balanced WHOOP green
    static let tense   = StrandPalette.statusWarning  // #F0A020 — high WHOOP amber

    /// The 3-stop gauge ramp, evenly spaced (blue → green → amber).
    static let stops: [Gradient.Stop] = [
        .init(color: calm,   location: 0.00),
        .init(color: steady, location: 0.50),
        .init(color: tense,  location: 1.00),
    ]

    /// The blue→green→amber gauge gradient, built from the WHOOP band anchors above.
    static let gradient = Gradient(stops: stops)

    /// Sample the ramp at a 0–3 stress score.
    static func color(_ score: Double) -> Color {
        StrandPalette.sample(stops: stops, at: min(max(score / 3.0, 0), 1))
    }
}

// MARK: - Stress model inputs (cache key)

/// An `Equatable` snapshot of everything `StressModel.init` reads, used to decide
/// when the cached model must be rebuilt. `DailyMetric` is already `Equatable`;
/// the stored series is a tuple array (not `Equatable`), so we mirror it into an
/// `Equatable` shape. Comparison is O(n) — cheap versus rebuilding the model.
private struct StressInputs: Equatable {
    let days: [DailyMetric]
    let stored: [StoredPoint]

    struct StoredPoint: Equatable {
        let day: String
        let value: Double
    }

    init(days: [DailyMetric], stored: [(day: String, value: Double)]) {
        self.days = days
        self.stored = stored.map { StoredPoint(day: $0.day, value: $0.value) }
    }
}

// MARK: - Stress model (transparent: stored value OR z-score derivation)

struct StressModel {
    /// The day key (`yyyy-MM-dd`) whose signal was scored — today, or the newest day carrying any (#543).
    let day: String
    let score: Double            // 0–3 (today)
    let band: StressBand
    let explanation: String
    let rhrToday: Int?
    let hrvToday: Double?
    let rhrDelta: Double?        // today − baseline mean (bpm)
    let hrvDelta: Double?        // today − baseline mean (ms)
    let fullTrend: [TrendPoint]  // entire daily proxy history, oldest→newest
    let calmTimeValue: String    // e.g. "58%"
    let calmTimeCaption: String  // e.g. "of last 30 days"
    let usingStored: Bool        // true when today's value came from the stored series

    /// Last up-to-14 trend values, for the hero tile sparkline.
    var sparkValues: [Double] { Array(fullTrend.suffix(14)).map(\.value) }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Build from oldest→newest daily metrics plus any stored "stress" series.
    /// Returns nil only when there is no usable signal at all.
    init?(days: [DailyMetric], stored: [(day: String, value: Double)]) {
        // Stored values keyed by day, clamped to 0–3.
        let storedByDay: [String: Double] = Dictionary(
            stored.map { ($0.day, min(max($0.value, 0), 3)) },
            uniquingKeysWith: { _, b in b }
        )

        // Carry (#543): today's own row is often vitals-less until the overnight is analyzed —
        // especially right after an app update relaunches and re-runs the pass — so score the NEWEST
        // day that actually carries usable signal (RHR/HRV, or a stored/imported stress value) instead of
        // calibrating, the same last-night carry every other Today vital uses. The predicate mirrors the
        // storedToday||derived gate below, so an imported stress-only latest day is still honored (not
        // skipped). Falls back to the last row when no day has any signal (cold start).
        guard let idx = days.lastIndex(where: {
            $0.restingHr != nil || $0.avgHrv != nil || storedByDay[$0.day] != nil
        }) ?? days.indices.last
        else { return nil }   // no days at all
        let today = days[idx]

        // Baseline window: up to 30 days ending the day BEFORE the scored day, so it's measured
        // against its own recent past rather than itself.
        let baseline = idx > 0 ? Array(days[0..<idx].suffix(30)) : []

        let rhrBase = baseline.compactMap { $0.restingHr }.map(Double.init)
        let hrvBase = baseline.compactMap { $0.avgHrv }

        let meanRHR = StressMath.mean(rhrBase)
        let sdRHR   = StressMath.std(rhrBase, mean: meanRHR)
        let meanHRV = StressMath.mean(hrvBase)
        let sdHRV   = StressMath.std(hrvBase, mean: meanHRV)

        let rhrT = today.restingHr.map(Double.init)
        let hrvT = today.avgHrv

        // Resolve today's score: prefer a stored value, else derive.
        let derivedAvailable = (rhrT != nil && meanRHR != nil) || (hrvT != nil && meanHRV != nil)
        let storedToday = storedByDay[today.day]
        guard storedToday != nil || derivedAvailable else { return nil }

        let derivedToday: Double? = derivedAvailable
            ? StressMath.squash(StressMath.rawScore(
                rhrToday: rhrT, meanRHR: meanRHR, sdRHR: sdRHR,
                hrvToday: hrvT, meanHRV: meanHRV, sdHRV: sdHRV))
            : nil

        let s = storedToday ?? derivedToday ?? 1.5
        self.day = today.day
        self.usingStored = storedToday != nil
        self.score = s
        self.band = StressBand(score: s)
        self.rhrToday = today.restingHr
        self.hrvToday = hrvT
        self.rhrDelta = (rhrT != nil && meanRHR != nil) ? (rhrT! - meanRHR!) : nil
        self.hrvDelta = (hrvT != nil && meanHRV != nil) ? (hrvT! - meanHRV!) : nil

        self.explanation = StressMath.explanation(
            band: self.band,
            rhrDelta: self.rhrDelta,
            hrvDelta: self.hrvDelta,
            usingStored: self.usingStored
        )

        // Full daily proxy history: stored value if present for the day, else the
        // z-score derivation against the SAME baseline so the line is comparable.
        var pts: [TrendPoint] = []
        for d in days {
            guard let date = Self.dayParser.date(from: d.day) else { continue }
            if let v = storedByDay[d.day] {
                pts.append(TrendPoint(date: date, value: v))
                continue
            }
            let dRHR = d.restingHr.map(Double.init)
            let dHRV = d.avgHrv
            guard (dRHR != nil && meanRHR != nil) || (dHRV != nil && meanHRV != nil) else { continue }
            let r = StressMath.rawScore(
                rhrToday: dRHR, meanRHR: meanRHR, sdRHR: sdRHR,
                hrvToday: dHRV, meanHRV: meanHRV, sdHRV: sdHRV
            )
            pts.append(TrendPoint(date: date, value: StressMath.squash(r)))
        }
        self.fullTrend = pts

        // "Calm time": share of the last 30 charted days that sat in the LOW band.
        let recent = Array(pts.suffix(30))
        if recent.isEmpty {
            self.calmTimeValue = "—"
            self.calmTimeCaption = String(localized: "needs history")
        } else {
            let calm = recent.filter { $0.value < 1.0 }.count
            let pct = Int((Double(calm) / Double(recent.count) * 100).rounded())
            self.calmTimeValue = "\(pct)%"
            self.calmTimeCaption = String(localized: "low-stress days · \(recent.count)d")
        }
    }
}

// MARK: - Stress math (pure, testable helpers)

enum StressMath {
    static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Population standard deviation; 0 when there's no spread.
    static func std(_ xs: [Double], mean m: Double?) -> Double {
        guard let m, xs.count > 1 else { return 0 }
        let v = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)
        return v.squareRoot()
    }

    /// Combined autonomic z-score. RHR-up and HRV-down both push it positive.
    static func rawScore(
        rhrToday: Double?, meanRHR: Double?, sdRHR: Double,
        hrvToday: Double?, meanHRV: Double?, sdHRV: Double
    ) -> Double {
        var sum = 0.0
        if let r = rhrToday, let m = meanRHR, sdRHR > 0.0001 {
            sum += (r - m) / sdRHR            // up = stress
        }
        if let h = hrvToday, let m = meanHRV, sdHRV > 0.0001 {
            sum += (m - h) / sdHRV            // down = stress
        }
        return sum
    }

    /// Logistic squash of the raw z-sum onto 0–3 (baseline 0 → 1.5).
    static func squash(_ raw: Double) -> Double {
        let s = 3.0 / (1.0 + exp(-raw))
        return min(max(s, 0), 3)
    }

    static func explanation(band: StressBand, rhrDelta: Double?, hrvDelta: Double?, usingStored: Bool) -> String {
        let rhrUp = (rhrDelta ?? 0) > 1.0
        let rhrDn = (rhrDelta ?? 0) < -1.0
        let hrvUp = (hrvDelta ?? 0) > 1.0
        let hrvDn = (hrvDelta ?? 0) < -1.0

        switch band {
        case .high:
            if rhrUp && hrvDn {
                return String(localized: "Resting HR is elevated and HRV is below your baseline, both classic signs of high activation. Prioritise rest, hydration and an easy day.")
            } else if hrvDn {
                return String(localized: "HRV has dropped well below your baseline, pointing to elevated stress or fatigue. Ease off and give your body time to recover.")
            } else if rhrUp {
                return String(localized: "Resting heart rate is running high versus your norm. Your body is under load today. Keep effort light.")
            }
            return String(localized: "Your autonomic markers are skewed toward stress today. Treat it as a recovery-focused day.")
        case .medium:
            if rhrUp || hrvDn {
                return rhrUp
                    ? String(localized: "Slightly off baseline (resting HR is a touch high), so you're moderately activated. Nothing alarming; just don't overreach.")
                    : String(localized: "Slightly off baseline (HRV is a little low), so you're moderately activated. Nothing alarming; just don't overreach.")
            }
            return String(localized: "You're sitting around your typical autonomic baseline: moderate stress, a normal, balanced day.")
        case .low:
            if rhrDn && hrvUp {
                return String(localized: "Resting heart rate is low and HRV is up. Your nervous system looks well-recovered and calm. A great day to push if you want to.")
            } else if hrvUp {
                return String(localized: "HRV is above baseline, a sign of a relaxed, well-recovered nervous system. Stress is low.")
            }
            return String(localized: "Resting heart rate and HRV are sitting at or below baseline: low physiological stress. You're in a calm, recovered state.")
        }
    }
}

// MARK: - Daytime autonomic-load line (README screen-9)
//
// The day's intraday stress proxy drawn as a smooth LINE across the waking hours, filled
// under the curve and stroked with the SAME 3-stop blue→green→amber WHOOP ramp as
// the gauge. Only scored hours contribute points (no-data hours are skipped, never a
// guessed value); the smooth line connects the ones we have. The y-axis is the 0–3 scale
// and a faint dashed mid-line marks the 1.5 baseline.

struct DaytimeLoadLine: View {
    let hours: [DaytimeStress.HourPoint]

    private let chartHeight: CGFloat = 78

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // y maps a 0–3 level into the chart (0 at bottom), for the baseline rule below. The x
            // placement moved into `scoredRuns`, which needs it per point anyway.
            // (a closure, not a `func` — a `@ViewBuilder` closure can't contain declarations)
            let y: (Double) -> CGFloat = { level in h - h * CGFloat(min(max(level / 3.0, 0), 1)) }

            // Contiguous runs of scored hours. Built in a method, not here: this is a
            // `@ViewBuilder` closure and cannot hold statements.
            let runs = scoredRuns(width: w, height: h)

            ZStack {
                // Baseline (1.5 of 3) reference line.
                Path { p in
                    let yb = y(1.5)
                    p.move(to: CGPoint(x: 0, y: yb))
                    p.addLine(to: CGPoint(x: w, y: yb))
                }
                .stroke(StrandPalette.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                // The ramp runs DOWN the chart, not across the day.
                //
                // It used to be `.leading` to `.trailing`, which painted the stress band colours along
                // the x-axis: a calm 9pm hour rendered amber and a tense 7am one blue, so the colour
                // said nothing about the score while looking exactly as though it did. Because y maps
                // the 0-3 level onto the chart, a vertical ramp makes vertical position the level, which
                // is what the Kotlin twin does and what the legend claims. Amber at the top, blue at the
                // bottom: `StressRamp.gradient` runs calm-first, so it is reversed here.
                let levelRamp = LinearGradient(
                    gradient: Gradient(colors: Array(StressRamp.stops.map(\.color).reversed())),
                    startPoint: .top, endPoint: .bottom
                )
                ForEach(Array(runs.enumerated()), id: \.offset) { _, seg in
                    if seg.count >= 2 {
                        // Closed PER RUN, so the wash cannot spread under an hour that was never scored
                        // and undo the gap the broken line just drew.
                        areaPath(seg, width: w, height: h)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        StressRamp.calm.opacity(0.22),
                                        StressRamp.calm.opacity(0.02),
                                    ]),
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                        linePath(seg)
                            .stroke(levelRamp,
                                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    } else if let only = seg.first {
                        // A run of one scored hour: a dot rather than a line. Coloured by the level it
                        // actually carries — it used to be hardcoded to the mid colour, so a lone HIGH
                        // hour drew as an ordinary one.
                        Circle()
                            .fill(StressRamp.color(level(at: only.1, height: h)))
                            .frame(width: 6, height: 6)
                            .position(x: only.0, y: only.1)
                    }
                }
            }
        }
        .frame(height: chartHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// CONTIGUOUS RUNS of scored hours, in chart coordinates.
    ///
    /// The old path `compactMap`-ed the unscored hours away and stroked a smooth curve through whatever
    /// was left, which draws a reading straight across an hour that has none — the one thing the caption
    /// promises it will not do. Splitting into runs lets each be stroked and filled separately, so a
    /// hole in the day stays a hole. The Kotlin twin has always broken the line here.
    private func scoredRuns(width w: CGFloat, height h: CGFloat) -> [[(CGFloat, CGFloat)]] {
        let n = max(hours.count, 1)
        var out: [[(CGFloat, CGFloat)]] = []
        var run: [(CGFloat, CGFloat)] = []
        for (i, p) in hours.enumerated() {
            guard let level = p.level else {
                if !run.isEmpty { out.append(run); run = [] }
                continue
            }
            let px = n <= 1 ? w / 2 : w * CGFloat(i) / CGFloat(n - 1)
            let py = h - h * CGFloat(min(max(level / 3.0, 0), 1))
            run.append((px, py))
        }
        if !run.isEmpty { out.append(run) }
        return out
    }

    /// The 0-3 level a chart y-position represents: the inverse of the `y` mapping above, so a lone
    /// point can be coloured by what it actually reads rather than by a fixed guess.
    private func level(at yPos: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        return Double((height - yPos) / height) * 3.0
    }

    /// A smooth (Catmull-Rom-ish) stroke through the scored points.
    private func linePath(_ pts: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for i in 1..<pts.count {
            let prev = pts[i - 1]
            let cur = pts[i]
            let midX = (prev.0 + cur.0) / 2
            path.addCurve(
                to: CGPoint(x: cur.0, y: cur.1),
                control1: CGPoint(x: midX, y: prev.1),
                control2: CGPoint(x: midX, y: cur.1)
            )
        }
        return path
    }

    private func areaPath(_ pts: [(CGFloat, CGFloat)], width: CGFloat, height: CGFloat) -> Path {
        var path = linePath(pts)
        if let last = pts.last, let first = pts.first {
            path.addLine(to: CGPoint(x: last.0, y: height))
            path.addLine(to: CGPoint(x: first.0, y: height))
            path.closeSubpath()
        }
        return path
    }

    private var accessibilitySummary: String {
        let scored = hours.compactMap { p in p.level.map { (p.hour, $0) } }
        guard !scored.isEmpty else { return String(localized: "No intraday stress data yet today.") }
        let parts = scored.map { "\($0.0):00 \(StressTrace.formatLevel($0.1))" }
        return String(localized: "Autonomic load today: \(parts.joined(separator: ", "))")
    }
}

// MARK: - Stress totals (Calm / Moderate / High) split for the day

/// Splits the day's SCORED waking hours into the three stress bands and exposes each
/// band's share + duration. Each intraday bucket is one hour (`DaytimeStress.bucketSeconds`),
/// so the band's hour-count is its duration. Calm = 0–1, Moderate = 1–2, High = 2–3.
struct StressTotals {
    let calmHours: Int
    let moderateHours: Int
    let highHours: Int

    init(hours: [DaytimeStress.HourPoint]) {
        var c = 0, m = 0, hi = 0
        for p in hours {
            guard let lvl = p.level else { continue }
            switch StressBand(score: lvl) {
            case .low:    c += 1
            case .medium: m += 1
            case .high:   hi += 1
            }
        }
        calmHours = c; moderateHours = m; highHours = hi
    }

    var total: Int { calmHours + moderateHours + highHours }

    /// 0...1 share of the scored day spent in each band (0 when no scored hours).
    func fraction(_ band: StressBand) -> Double {
        guard total > 0 else { return 0 }
        switch band {
        case .low:    return Double(calmHours) / Double(total)
        case .medium: return Double(moderateHours) / Double(total)
        case .high:   return Double(highHours) / Double(total)
        }
    }

    func hours(_ band: StressBand) -> Int {
        switch band {
        case .low:    return calmHours
        case .medium: return moderateHours
        case .high:   return highHours
        }
    }
}

// MARK: - Stress totals bar
//
// The Calm / Moderate / High split of the scored day: three labelled tracks, each filled to that band's
// SHARE of the scored day, with the band name and its duration above it. One accent (the stress glow's),
// so the split reads by length, not by colour. A day with no scored hours leaves all three tracks empty
// (no fabricated fill).

struct StressTotalsBar: View {
    let totals: StressTotals

    private struct Band: Identifiable {
        let id = UUID()
        let band: StressBand
        let label: String
    }

    private var bands: [Band] {
        [
            Band(band: .low,    label: String(localized: "Calm")),
            Band(band: .medium, label: String(localized: "Moderate")),
            Band(band: .high,   label: String(localized: "High")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(bands) { b in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(b.label)
                            .font(StrandFont.book(13, relativeTo: .footnote))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Text(durationLabel(totals.hours(b.band)))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    NoopTrack(fraction: totals.fraction(b.band), height: 8,
                              fill: [NoopGlow.stress.accent.opacity(0.55), NoopGlow.stress.accent])
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(localized: "Today's stress split: calm \(durationLabel(totals.calmHours)), moderate \(durationLabel(totals.moderateHours)), high \(durationLabel(totals.highHours)).")
        )
    }

    /// "—" when a band had no scored hours, else "Nh" (each scored bucket is one hour).
    private func durationLabel(_ hours: Int) -> String {
        hours <= 0 ? "—" : String(localized: "\(hours)h")
    }
}

// MARK: - Preview

#if DEBUG
private func sampleStressTrend(_ n: Int) -> [TrendPoint] {
    let cal = Calendar.current
    let today = Date()
    return (0..<n).map { i in
        let date = cal.date(byAdding: .day, value: -(n - 1 - i), to: today)!
        let v = 1.4 + 0.9 * sin(Double(i) / 2.4) + Double((i * 13) % 5) * 0.12
        return TrendPoint(date: date, value: min(max(v, 0), 3))
    }
}

/// A sample waking-hour timeline (06:00→22:00) for the preview, with a couple of
/// no-signal gaps so the line break reads honestly.
private func sampleDaytimeHours() -> [DaytimeStress.HourPoint] {
    let base = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
    return (DaytimeStress.wakingStartHour...DaytimeStress.wakingEndHour).map { h in
        let curve = 1.3 + 1.1 * sin(Double(h - 6) / 3.2)
        // Drop two hours to show the gap behaviour.
        let level: Double? = (h == 11 || h == 17) ? nil : min(max(curve, 0), 3)
        return DaytimeStress.HourPoint(hour: h, startTs: base + h * 3600,
                                       level: level, meanHR: 64, rmssd: 38)
    }
}

private struct StressPreviewHarness: View {
    let score: Double
    @State private var range: ExploreRange = .month
    var body: some View {
        let band = StressBand(score: score)
        let hours = sampleDaytimeHours()
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                Text("Stress").font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)

                // Screen-9 day autonomic-load line + Calm/Moderate/High totals bar.
                NoopCard(tint: StressRamp.calm) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Autonomic load through the day").strandOverline()
                        DaytimeLoadLine(hours: hours)
                        Divider().overlay(StrandPalette.hairline)
                        StressTotalsBar(totals: StressTotals(hours: hours))
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
                          alignment: .leading, spacing: NoopMetrics.gap) {
                    StatTile(label: "Stress", value: StressTrace.formatLevel(score),
                             caption: "of 3 · \(band.title)", accent: StressRamp.color(score))
                    StatTile(label: "Resting HR", value: "54 bpm", accent: StrandPalette.metricRose,
                             delta: "+3 vs base", deltaColor: StrandPalette.statusWarning)
                    StatTile(label: "HRV", value: "48 ms", accent: StrandPalette.metricPurple,
                             delta: "−8 vs base", deltaColor: StrandPalette.statusWarning)
                    StatTile(label: "Calm time", value: "58%", caption: "low-stress days · 30d",
                             accent: StressRamp.calm)
                }

                ChartCard(title: "Stress · M", subtitle: "Daily 0-3 proxy", trailing: "avg 1.5") {
                    TrendChart(points: sampleStressTrend(30), gradient: StressRamp.gradient,
                               valueRange: 0...3, showsArea: true, height: NoopMetrics.chartHeight,
                               valueFormat: { StressTrace.formatLevel($0) })
                } footer: {
                    ChartFooter([("Today", StressTrace.formatLevel(score)), ("Average", "1.5"), ("Days", "30")])
                }
                SegmentedPillControl(ExploreRange.allCases, selection: $range,
                                     adaptsToAvailableWidth: true) { $0.label }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase)
    }
}

#Preview("Stress — HIGH") {
    StressPreviewHarness(score: 2.4)
        .frame(width: 720, height: 1000)
        .preferredColorScheme(.dark)
}

#Preview("Stress — LOW") {
    StressPreviewHarness(score: 0.6)
        .frame(width: 720, height: 1000)
        .preferredColorScheme(.dark)
}
#endif
