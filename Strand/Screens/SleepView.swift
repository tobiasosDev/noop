import SwiftUI
import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - SleepView
//
// Whoop-sleep clarity on the locked Noop component system. Score answers "how did I
// sleep?" first. Scannable in two seconds:
//   0. HERO — sleep performance ring (RecoveryRing, score overridden with "PERFORMANCE"
//      label, supporting = asleep + need; no-data path shows "—").
//   1. Night timeline ChartCard "Last night" — the stage breakdown (Hypnogram if
//      intervals reconstruct from stagesJSON, else a clean proportional stacked stage
//      bar), trailing = total asleep, footer = REM/Deep/Light/Awake each "Xh Ym · NN%".
//   2. "Stages vs typical" NoopCard — Deep/REM/Light as horizontal bars, last-night
//      minutes with a marker at the personal typical (mean) so highs/lows pop.
//   3. A uniform grid of six fixed StatTiles, each with a sparkline and a "vs typical"
//      caption: Performance, Efficiency, Consistency, Hours vs Needed, Restorative,
//      Respiratory.
//   4. A 30-day asleep-hours ChartCard trend.
//   5. "Sleep Planner" NoopCard — tonight's plan: goal chips, the one number ("In bed
//      by HH:MM"), the need→goal→in-bed breakdown, the wake source (strap alarm or
//      manual stepper) and, on iOS, the wind-down reminder toggle. Renders AFTER the
//      data sections in BOTH branches — even with no nights yet it falls back to
//      defaults and says so.
//
// Every surface is a NoopCard / StatTile / ChartCard — no hand-sized cards, one grid,
// equal margins. Data wiring is preserved from the previous screen (stagesJSON =
// minutes for light/deep/rem/awake; typical = mean of repo.days).

struct SleepView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState
    @EnvironmentObject private var behavior: BehaviorStore

    // The standard tile grid: ONE adaptive column set, used for every tile group.
    private let tileColumns = [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)]

    /// Memoized snapshot of every expensive derivation (latest Night with its intervals
    /// resolved once, the seven metric series, the trend points, the typical means). Rebuilt
    /// only when the underlying repo data actually changes — NOT on hover/animation/1Hz HR
    /// ticks that merely re-evaluate `body`. `nil` until first build or when there's no night.
    @State private var model: SleepModel?
    /// The repo signature the cached `model` was built from. Cheap to compute every render;
    /// when it differs from the current inputs we rebuild the model.
    @State private var modelKey: SleepInputKey?

    var body: some View {
        // Resolve the memoized model for THIS render. `SleepInputKey(repo:)` is O(1)-ish
        // (counts + last-row identity), so comparing it every render is cheap. When it matches the cached key we
        // reuse the cached model untouched — the many body re-evaluations from hover/animation/
        // 1Hz HR ticks pay nothing. When it differs (or on first render) we build once, here,
        // synchronously, so the very first frame already shows content (no empty-state flash).
        let key = SleepInputKey(repo: repo)
        let resolved: SleepModel? = (key == modelKey) ? model : SleepModel.build(repo: repo)
        ScreenScaffold(title: "Sleep", subtitle: "Last night, read in two seconds.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if let resolved {
                    sleepHero(resolved)
                    nightTimeline(resolved)
                    stagesVsTypical(resolved)
                    metricGrid(resolved)
                    durationTrend(resolved)
                } else {
                    emptyState
                }
                // The planner closes BOTH branches — even with no nights it answers
                // "when should I go to bed tonight?" from defaults (and says so).
                plannerSection
            }
            // Persist the freshly-built model so subsequent renders with the same inputs hit
            // the cache. Writing State during body is not allowed, so commit it after layout;
            // `resolved` already drives THIS frame, so there is no flash and no extra rebuild.
            .onChange(of: key) { newKey in
                modelKey = newKey
                model = SleepModel.build(repo: repo)
            }
            .onAppear {
                if modelKey != key {
                    modelKey = key
                    model = resolved
                }
            }
        }
    }

    // MARK: - 0. HERO — sleep performance ring

    @ViewBuilder
    private func sleepHero(_ model: SleepModel) -> some View {
        let night = model.night
        // model.needMin is precomputed in SleepModel.build — no per-render repo pass here.
        // SleepNeed.needMin floors at ~7.5h, so the need is always present.
        let supporting = "\(durationText(night.stages.asleep)) asleep · \(durationText(model.needMin)) needed"
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Last night", overline: "Sleep",
                          trailing: "\(night.dateLabel) · \(night.onsetText)–\(night.wakeText)")
            NoopCard {
                // Wide (mac): ring left, details right. Narrow (iPhone): stacked, centered.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 28) {
                        heroRing(model, supporting: supporting)
                        Text(heroSubline(model))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    VStack(spacing: 10) {
                        heroRing(model, supporting: supporting)
                        Text(heroSubline(model))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Ring with score, or a zero-fill track with "—" when no performance value exists.
    @ViewBuilder
    private func heroRing(_ model: SleepModel, supporting: String) -> some View {
        if let perf = model.performance.latest {
            RecoveryRing(score: perf, supporting: supporting,
                         diameter: 180, lineWidth: 14,
                         centerText: "\(Int(perf.rounded()))%",
                         stateText: String(localized: "PERFORMANCE"),
                         valueFormat: { "\(String(localized: "Performance")) \(Int($0.rounded()))%" })
        } else {
            RecoveryRing(score: 0, supporting: supporting,
                         diameter: 180, lineWidth: 14, showsHover: false,
                         centerText: "—", stateText: String(localized: "PERFORMANCE"))
        }
    }

    /// "8h 01m in bed · 90% efficiency[ · stages approximate (on-device)]"
    private func heroSubline(_ model: SleepModel) -> String {
        var parts = ["\(durationText(model.night.timeInBed)) in bed",
                     "\(efficiencyText(model.night)) efficiency"]
        if model.isPersistedHypnogram { parts.append(String(localized: "stages approximate (on-device)")) }
        return parts.joined(separator: " · ")
    }

    // MARK: - 1. Night timeline — stage breakdown

    @ViewBuilder
    private func nightTimeline(_ model: SleepModel) -> some View {
        let night = model.night
        let s = night.stages
        // Intervals are reconstructed ONCE in the model build, not on every body pass
        // (Night.intervals is a computed property and was previously evaluated twice here).
        let intervals = model.intervals
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            ChartCard(
                title: "Stage breakdown",
                trailing: durationText(s.asleep),
                height: NoopMetrics.chartHeight,
                chart: {
                    if intervals.count >= 2 {
                        Hypnogram(intervals: intervals,
                                  height: NoopMetrics.chartHeight,
                                  showsStageAxis: true,
                                  nightStart: night.onsetDate)
                    } else {
                        stageBar(s)
                    }
                },
                footer: { stageChips(s) }
            )
        }
    }

    /// REM/Deep/Light/Awake duration+percent chips — replaces the ChartFooter rows.
    @ViewBuilder
    private func stageChips(_ s: Stages) -> some View {
        WrapLayout(spacing: 8) {
            stageChip(.rem,   s.rem,   s.total)
            stageChip(.deep,  s.deep,  s.total)
            stageChip(.light, s.light, s.total)
            stageChip(.awake, s.awake, s.total)
        }
    }

    private func stageChip(_ stage: SleepStage, _ minutes: Double, _ total: Double) -> some View {
        HStack(spacing: 5) {
            Circle().fill(StrandPalette.sleepStageColor(stage)).frame(width: 7, height: 7)
            Text(stage.label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Text(verbatim: "\(durationText(minutes)) · \(pct(minutes, total))%")
                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(StrandPalette.surfaceInset, in: Capsule(style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stage.label): \(durationText(minutes)), \(pct(minutes, total)) percent")
    }

    /// Full-width proportional stacked stage bar (fallback when no intervals).
    @ViewBuilder
    private func stageBar(_ s: Stages) -> some View {
        let total = max(1, s.total)
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    segment(.deep, s.deep, total, geo.size.width)
                    segment(.light, s.light, total, geo.size.width)
                    segment(.rem, s.rem, total, geo.size.width)
                    segment(.awake, s.awake, total, geo.size.width)
                }
            }
            .frame(height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sleep stage breakdown: deep \(pct(s.deep, s.total)) percent, light \(pct(s.light, s.total)) percent, REM \(pct(s.rem, s.total)) percent, awake \(pct(s.awake, s.total)) percent")
            HStack(spacing: 16) {
                legend(.deep, "Deep")
                legend(.light, "Light")
                legend(.rem, "REM")
                legend(.awake, "Awake")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func segment(_ stage: SleepStage, _ minutes: Double, _ total: Double, _ width: CGFloat) -> some View {
        let w = CGFloat(minutes / total) * width
        Rectangle()
            .fill(StrandPalette.sleepStageColor(stage))
            .frame(width: max(0, w))
    }

    @ViewBuilder
    private func legend(_ stage: SleepStage, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(StrandPalette.sleepStageColor(stage))
                .frame(width: 9, height: 9)
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: - 2. Stages vs typical

    @ViewBuilder
    private func stagesVsTypical(_ model: SleepModel) -> some View {
        let s = model.night.stages
        // Per-stage typical means are computed ONCE in the model build (each a full pass
        // over repo.days) and read here.
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Stages vs typical", overline: "Last night",
                          trailing: "marker = your mean")
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    stageRow("Deep",  last: s.deep,  typical: model.typicalDeepMin,  color: StrandPalette.sleepDeep)
                    Divider().overlay(StrandPalette.hairline)
                    stageRow("REM",   last: s.rem,   typical: model.typicalRemMin,   color: StrandPalette.sleepREM)
                    Divider().overlay(StrandPalette.hairline)
                    stageRow("Light", last: s.light, typical: model.typicalLightMin, color: StrandPalette.sleepLight)
                }
            }
        }
    }

    /// One stage bar: last-night minutes filled, with a vertical marker at the typical mean.
    @ViewBuilder
    private func stageRow(_ label: String, last: Double, typical: Double?, color: Color) -> some View {
        // Scale both values against a shared per-row max so the marker is meaningful.
        let scaleMax = max(last, typical ?? 0) * 1.18
        let max = scaleMax > 0 ? scaleMax : 1
        let deltaText: String = {
            guard let typical, typical > 0 else { return "" }
            let diff = last - typical
            let sign = diff >= 0 ? "+" : "−"
            return "\(sign)\(durationText(abs(diff))) vs typ"
        }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label.uppercased()).strandOverline()
                Spacer()
                Text(durationText(last)).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                if !deltaText.isEmpty {
                    Text(deltaText)
                        .font(StrandFont.footnote)
                        .foregroundStyle(last >= (typical ?? last) ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                }
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    // track
                    Capsule(style: .continuous)
                        .fill(StrandPalette.surfaceInset)
                    // last-night fill
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: w * CGFloat(min(1, last / max)))
                    // typical marker
                    if let typical, typical > 0 {
                        Rectangle()
                            .fill(StrandPalette.textPrimary)
                            .frame(width: 2, height: 16)
                            .position(x: w * CGFloat(min(1, typical / max)), y: 5)
                    }
                }
            }
            .frame(height: 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label): \(durationText(last)) last night\(typical.map { ", typical \(durationText($0))" } ?? "")")
        }
    }

    // MARK: - 3. Metric grid (UNIFORM fixed-height StatTiles, each with sparkline)

    @ViewBuilder
    private func metricGrid(_ model: SleepModel) -> some View {
        // Per-tile latest value + history series (for the sparkline) + typical mean.
        // All seven series are computed ONCE in the model build (each is a full pass over
        // repo.days/repo.sleeps) — here we only read the memoized results.
        let perf  = model.performance
        let eff   = model.efficiency
        let cons  = model.consistency
        let need  = model.hoursVsNeeded
        let rest  = model.restorative
        let resp  = model.respiratory
        let debt  = model.sleepDebt

        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Night detail", overline: "Metrics", trailing: "vs typical")
            LazyVGrid(columns: tileColumns, alignment: .leading, spacing: NoopMetrics.gap) {

                StatTile(
                    label: "Sleep Performance",
                    value: pctValue(perf.latest),
                    caption: vsTypical(perf.latest, perf.typical, suffix: "%"),
                    accent: perf.latest.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                    sparkline: spark(perf.series),
                    sparkColor: StrandPalette.accent)

                StatTile(
                    label: "Efficiency",
                    value: pctValue(eff.latest),
                    caption: vsTypical(eff.latest, eff.typical, suffix: "%"),
                    accent: StrandPalette.statusPositive,
                    sparkline: spark(eff.series),
                    sparkColor: StrandPalette.statusPositive)

                StatTile(
                    label: "Consistency",
                    value: pctValue(cons.latest),
                    caption: vsTypical(cons.latest, cons.typical, suffix: "%"),
                    accent: cons.latest.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                    sparkline: spark(cons.series),
                    sparkColor: StrandPalette.metricCyan)

                StatTile(
                    label: "Hours vs Needed",
                    value: pctValue(need.latest),
                    caption: vsTypical(need.latest, need.typical, suffix: "%"),
                    accent: need.latest.map { StrandPalette.recoveryColor(min(100, $0)) } ?? StrandPalette.textPrimary,
                    sparkline: spark(need.series),
                    sparkColor: StrandPalette.accent)

                StatTile(
                    label: "Restorative",
                    value: pctValue(rest.latest),
                    caption: vsTypical(rest.latest, rest.typical, suffix: "%"),
                    accent: StrandPalette.sleepREM,
                    sparkline: spark(rest.series),
                    sparkColor: StrandPalette.sleepREM)

                StatTile(
                    label: "Respiratory",
                    value: rrValue(resp.latest),
                    caption: vsTypical(resp.latest, resp.typical, suffix: " rpm", decimals: 1),
                    accent: StrandPalette.metricPurple,
                    sparkline: spark(resp.series),
                    sparkColor: StrandPalette.metricPurple)

                StatTile(
                    label: "Sleep Debt",
                    value: debt.latest.map { durationText($0) } ?? "—",
                    caption: debtCaption(debt.latest),
                    accent: debtColor(debt.latest),
                    sparkline: spark(debt.series),
                    sparkColor: StrandPalette.metricRose)
            }
        }
    }

    // MARK: - 4. 30-day asleep-hours trend (duration trend)

    @ViewBuilder
    private func durationTrend(_ model: SleepModel) -> some View {
        // Trailing-30 trend points and the typical total are precomputed in the model build
        // (full passes over repo.days) — read here, not recomputed per render.
        let pts = model.trendPoints
        let avg = model.typicalTotalMin.map { $0 / 60.0 }
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Asleep duration", overline: "Trend", trailing: "Last 30 days")
            ChartCard(
                title: "Hours asleep",
                subtitle: "Per night, trailing 30 days",
                trailing: avg.map { String(format: "%.1f h avg", $0) },
                height: NoopMetrics.chartHeight,
                chart: {
                    if pts.count >= 2 {
                        TrendChart(points: pts,
                                   gradient: StrandPalette.recoveryGradient,
                                   valueRange: trendRange(pts),
                                   showsArea: true,
                                   height: NoopMetrics.chartHeight,
                                   valueFormat: { String(format: "%.1f h", $0) })
                    } else {
                        sparsePlaceholder
                    }
                },
                footer: {
                    ChartFooter([
                        ("Avg",    avg.map { String(format: "%.1f h", $0) } ?? "—"),
                        ("Min",    pts.map(\.value).min().map { String(format: "%.1f h", $0) } ?? "—"),
                        ("Max",    pts.map(\.value).max().map { String(format: "%.1f h", $0) } ?? "—"),
                        ("Nights", "\(pts.count)"),
                    ])
                }
            )
        }
    }

    private func trendRange(_ pts: [TrendPoint]) -> ClosedRange<Double> {
        let vals = pts.map(\.value)
        let lo = Swift.max(0, (vals.min() ?? 0) - 1)
        let hi = (vals.max() ?? 9) + 1
        return lo...Swift.max(hi, lo + 1)
    }

    // MARK: - 5. Sleep Planner — tonight's plan (bottom; renders in both branches)

    @ViewBuilder
    private var plannerSection: some View {
        let rec = plannerRecommendation
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep Planner", overline: "Tonight's plan")
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    // Goal chips — how much of tonight's need to bank.
                    SegmentedPillControl(SleepPlanner.Goal.allCases,
                                         selection: Binding(
                                            get: { plannerGoal },
                                            set: { behavior.plannerGoalRaw = $0.rawValue }),
                                         label: { goalLabel($0) })
                    // The one number to walk away with.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("In bed by")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Text(verbatim: Self.clock(rec.bedMinutes))
                            .font(StrandFont.number(44))
                            .foregroundStyle(StrandPalette.accent)
                    }
                    // Breakdown: need → goal → in-bed.
                    VStack(alignment: .leading, spacing: 4) {
                        plannerRow("Sleep need", minutesText(rec.needMin))
                        plannerRow("Goal (\(goalLabel(plannerGoal)))", minutesText(rec.goalSleepMin))
                        plannerRow("Time in bed", minutesText(rec.inBedMin))
                        if rec.usedDefaults {
                            Text("Based on defaults — sharpens after a few nights.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    Divider().overlay(StrandPalette.hairline)
                    // Wake time: the strap alarm wins; manual stepper otherwise.
                    if behavior.smartAlarmEnabled {
                        HStack(spacing: 8) {
                            Image(systemName: "alarm.fill")
                                .foregroundStyle(StrandPalette.accent)
                            Text("Wake \(Self.clock(behavior.smartAlarmMinutes)) — from your strap alarm")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text("Wake time")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                            Stepper(value: Binding(
                                        get: { behavior.plannerWakeMinutes },
                                        set: { behavior.plannerWakeMinutes = (($0 % 1440) + 1440) % 1440 }),
                                    in: 0...1439, step: 15) {
                                Text(verbatim: Self.clock(behavior.plannerWakeMinutes))
                                    .font(StrandFont.headline.monospacedDigit())
                                    .foregroundStyle(StrandPalette.textPrimary)
                            }
                        }
                    }
                    #if os(iOS)
                    Toggle("Remind me 30 min before bedtime", isOn: $behavior.bedtimeReminderEnabled)
                        .font(StrandFont.subhead)
                        .tint(StrandPalette.accent)
                    #endif
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        #if os(iOS)
        .onChange(of: behavior.bedtimeReminderEnabled) { _ in syncBedtimeReminder() }
        .onChange(of: plannerRecommendation) { _ in syncBedtimeReminder() }
        .onAppear { syncBedtimeReminder() }
        #endif
    }

    private var plannerGoal: SleepPlanner.Goal { SleepPlannerInputs.goal(behavior) }
    private var plannerRecommendation: SleepPlanner.Recommendation {
        SleepPlannerInputs.recommendation(repo: repo, behavior: behavior)
    }

    private func goalLabel(_ g: SleepPlanner.Goal) -> String {
        switch g {
        case .peak:    return String(localized: "Peak")
        case .perform: return String(localized: "Perform")
        case .getBy:   return String(localized: "Get By")
        }
    }

    /// "7h 30m" — duration text; non-linguistic, rendered verbatim (matches durationText).
    private func minutesText(_ m: Double) -> String {
        let h = Int(m) / 60, r = Int(m) % 60
        return "\(h)h \(String(format: "%02d", r))m"
    }

    private func plannerRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            Text(verbatim: value).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    #if os(iOS)
    private func syncBedtimeReminder() {
        BedtimeReminderScheduler.shared.apply(enabled: behavior.bedtimeReminderEnabled,
                                              bedMinutes: plannerRecommendation.bedMinutes)
    }
    #endif

    // MARK: - Empty / sparse states

    @ViewBuilder
    private var emptyState: some View {
        // While the strap is mid-offload, say so — "No nights" reads as final otherwise (#77).
        if live.backfilling { SyncingHistoryNote(chunks: live.syncChunksThisSession) }
        if repo.loaded {
            ComingSoon(what: "No nights here yet. Import your WHOOP export in Data Sources to see every night, your sleep stages and trends straight away. Or open Intelligence to see last night computed from the strap after you wear it to bed.")
        } else {
            ComingSoon(what: "Loading your sleep history…")
        }
    }

    private var sparsePlaceholder: some View {
        Text("Not enough nights yet.")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Formatting helpers

    private func pct(_ minutes: Double, _ total: Double) -> Int {
        total > 0 ? Int((minutes / total * 100).rounded()) : 0
    }

    private func pctValue(_ v: Double?) -> String {
        v.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    private func rrValue(_ v: Double?) -> String {
        v.map { String(format: "%.1f", $0) } ?? "—"
    }

    /// "+12% vs typical" / "−0.4 rpm vs typical" — the latest-vs-mean caption every tile carries.
    private func vsTypical(_ latest: Double?, _ typical: Double?, suffix: String, decimals: Int = 0) -> String {
        guard let latest, let typical, typical != 0 else { return "vs typical —" }
        let diff = latest - typical
        let sign = diff >= 0 ? "+" : "−"
        let mag = abs(diff)
        let num = decimals == 0 ? "\(Int(mag.rounded()))" : String(format: "%.\(decimals)f", mag)
        return "\(sign)\(num)\(suffix) vs typical"
    }

    private func debtCaption(_ debt: Double?) -> String {
        guard let debt else { return "vs need" }
        return debt < 15 ? "On target" : "Below need"
    }

    private func debtColor(_ debt: Double?) -> Color {
        guard let debt else { return StrandPalette.textPrimary }
        switch debt {
        case ..<15:  return StrandPalette.statusPositive
        case ..<60:  return StrandPalette.statusWarning
        default:     return StrandPalette.statusCritical
        }
    }

    private func efficiencyText(_ night: Night) -> String {
        let e = efficiencyPct(night)
        return e.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    /// Efficiency in percent. Prefer the stored session value, else asleep / time-in-bed.
    private func efficiencyPct(_ night: Night) -> Double? {
        if let stored = night.session.efficiency ?? repo.today?.efficiency {
            return stored <= 1.0 ? stored * 100 : stored
        }
        let bed = night.timeInBed
        guard bed > 0 else { return nil }
        return Swift.min(100, night.stages.asleep / bed * 100)
    }

    private func durationText(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    /// "HH:MM" from minutes-since-midnight — non-linguistic, rendered verbatim.
    private static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    /// A sparkline needs at least two points; otherwise return nil so the tile stays clean.
    private func spark(_ series: [Double]) -> [Double]? {
        let tail = Array(series.suffix(30))
        return tail.count > 1 ? tail : nil
    }

}

// MARK: - Preview

#if DEBUG
#Preview("Sleep") {
    SleepView()
        .environmentObject(Repository.previewSleep())
        .environmentObject(LiveState())
        .environmentObject(BehaviorStore())
        .frame(width: 980, height: 1180)
        .preferredColorScheme(.dark)
}

@MainActor
private extension Repository {
    /// Sample repository populated with imported-style nights for previews.
    static func previewSleep() -> Repository {
        let repo = Repository(deviceId: "preview")
        let cal = Calendar.current
        let now = Date()

        var days: [DailyMetric] = []
        var sleeps: [CachedSleepSession] = []
        let fmt: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()

        for i in (0..<30).reversed() {
            let date = cal.date(byAdding: .day, value: -i, to: now)!
            let jitter = Double((i * 23) % 11) - 5
            let light = 210.0 + jitter
            let deep = 80.0 + jitter * 0.5
            let rem = 95.0 + jitter * 0.7
            let awake = 25.0 + Double((i * 7) % 9)
            let asleep = light + deep + rem
            let stagesJSON = "{\"light\":\(light),\"deep\":\(deep),\"rem\":\(rem),\"awake\":\(awake)}"

            days.append(DailyMetric(
                day: fmt.string(from: date),
                totalSleepMin: asleep,
                efficiency: 88 + jitter * 0.3,
                deepMin: deep, remMin: rem, lightMin: light,
                disturbances: Int(awake / 6), restingHr: 50 + (i % 4),
                avgHrv: 65 - Double(i % 5), recovery: 60 + jitter,
                strain: 10 + Double(i % 6), exerciseCount: i % 2,
                spo2Pct: 96, skinTempDevC: 33.4, respRateBpm: 14.6 + jitter * 0.1))

            var onset = cal.date(bySettingHour: 22, minute: 50 + Int(jitter), second: 0, of: date) ?? date
            onset = cal.date(byAdding: .day, value: -1, to: onset) ?? onset
            let end = onset.addingTimeInterval((asleep + awake) * 60)
            sleeps.append(CachedSleepSession(
                startTs: Int(onset.timeIntervalSince1970),
                endTs: Int(end.timeIntervalSince1970),
                efficiency: 88 + jitter * 0.3,
                restingHr: 50 + (i % 4),
                avgHrv: 65 - Double(i % 5),
                stagesJSON: stagesJSON))
        }

        repo.days = days
        repo.sleeps = sleeps
        repo.loaded = true
        return repo
    }
}
#endif
