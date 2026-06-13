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
//      caption: Efficiency, Consistency, Hours vs Needed, Restorative, Respiratory,
//      Sleep Debt.
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
    // 164pt min → two columns on ≥396pt iPhones (e.g. 16 Pro: 346pt content, 164×2+12=340;
    // 390–393pt devices stay 1-col), more on mac. 168 missed Pro-width 2-col by 2pt.
    private let tileColumns = [GridItem(.adaptive(minimum: 164), spacing: NoopMetrics.gap)]

    /// Memoized snapshot of every expensive derivation (latest Night with its intervals
    /// resolved once, the seven metric series, the trend points, the typical means). Rebuilt
    /// only when the underlying repo data actually changes — NOT on hover/animation/1Hz HR
    /// ticks that merely re-evaluate `body`. `nil` until first build or when there's no night.
    @State private var model: SleepModel?
    /// The repo signature the cached `model` was built from. Cheap to compute every render;
    /// when it differs from the current inputs we rebuild the model.
    @State private var modelKey: SleepInputKey?

    /// Which night the hero hypnogram shows: 0 = last night, N = N sleep-sessions back.
    /// Snaps back to 0 whenever the data key changes — a stale offset would silently point
    /// at a different session after a sync. The memoized trend `model` stays cached since
    /// the trends are night-independent. (#160)
    @State private var nightOffset = 0
    /// Memoized decode of the NAVIGATED night (nil when `nightOffset == 0` — the hero reads
    /// `model.night` then). Rebuilt only in the `nightOffset` / data-key onChange handlers;
    /// `decodedNight` JSON-decodes, which must never run per body pass (1Hz HR ticks). (#160)
    @State private var navNight: Night?

    /// Every sleep BLOCK across both sources, UN-deduplicated (`repo.allSleepSessions`) — `repo.sleeps`
    /// keeps one winner per night for the dashboard, collapsing split-sleep days (a nap + a main
    /// sleep on the same day) into a single block. The hero groups these by day (`navDays`) and
    /// merges each day into one Night, so a split day reads as one correctly-totalled night with the
    /// gaps preserved. Oldest→newest. Falls back to `repo.sleeps` until loaded. (#170)
    @State private var allSessions: [CachedSleepSession] = []

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
            // `resolved` already drives THIS frame AND is what we persist — the closure captures
            // this render's freshly-built value, so a key change costs exactly one build.
            .onChange(of: key) { newKey in
                modelKey = newKey
                model = resolved
                // New data invalidates a navigated offset — the same offset would silently
                // point at a different session. Snap back to last night. (#160)
                nightOffset = 0
                navNight = nil
            }
            // The navigated night is decoded once per ◀/▶ press, never per body pass —
            // `decodedNight` JSON-decodes and body re-evaluates at 1Hz while HR streams. (#160)
            .onChange(of: nightOffset) { newOffset in
                navNight = newOffset == 0 ? nil : decodedNight(at: newOffset)
            }
            .onAppear {
                if modelKey != key {
                    modelKey = key
                    model = resolved
                    nightOffset = 0
                    navNight = nil
                }
            }
            // Load EVERY sleep block across BOTH sources (un-deduplicated) so the hero's ◀/▶ can
            // browse split-sleep days the dashboard collapses — including Bluetooth-only nights,
            // whose blocks live under the computed source. Re-runs whenever a sync/import bumps
            // refreshSeq; snaps back to the newest day and rebuilds the model so offset 0 reflects
            // the freshly-loaded blocks. (#170)
            .task(id: repo.refreshSeq) {
                allSessions = await repo.allSleepSessions()
                nightOffset = 0
                navNight = nil
                modelKey = SleepInputKey(repo: repo)
                model = SleepModel.build(repo: repo)
            }
        }
    }

    // MARK: - 0. HERO — sleep performance ring

    private func sleepHero(_ model: SleepModel) -> some View {
        // Offset 0 reads the memoized latest night; navigated offsets read the cached
        // `navNight` — never a fresh decode here (this runs on every 1Hz HR tick). When a
        // navigated day decoded to no usable stages, the header stays on that REAL day's
        // date/times with an honest placeholder — never the latest night silently rendered
        // under a navigated label. The ◀/▶ header browses split-sleep days (#160, #170);
        // the RecoveryRing + supporting line is our fork's hero redesign.
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            if nightOffset == 0 {
                nightNavHeader(trailing: headerLine(model.night))
                heroCard(model.night, performance: model.performance,
                         needMin: model.needMin, isPersisted: model.isPersistedHypnogram)
            } else if let night = navNight {
                nightNavHeader(trailing: headerLine(night))
                // A navigated night has no per-night performance %; show the honest no-score
                // ring with its own asleep/need supporting line.
                heroCard(night, performance: model.performance,
                         needMin: model.needMin, isPersisted: (night.realSegments?.count ?? 0) >= 2,
                         showsPerformance: false)
            } else if let session = sessionRow(at: nightOffset) {
                // Stage-less stub purely to reuse Night's date/time formatting.
                let stub = Night(session: session, stages: Stages(awake: 0, light: 0, deep: 0, rem: 0))
                nightNavHeader(trailing: headerLine(stub))
                NoopCard {
                    noStagePlaceholder
                        .frame(maxWidth: .infinity)
                        .frame(height: NoopMetrics.chartHeight)
                }
            }
        }
    }

    /// Our fork's hero card: the sleep-performance RecoveryRing left/top, the supporting
    /// asleep/need line and the detail subline. Fed by whichever Night the ◀/▶ nav selected.
    @ViewBuilder
    private func heroCard(_ night: Night, performance: SleepModel.Metric,
                          needMin: Double, isPersisted: Bool, showsPerformance: Bool = true) -> some View {
        // model.needMin is precomputed in SleepModel.build — no per-render repo pass here.
        // SleepNeed.needMin floors at ~7.5h, so the need is always present.
        // Non-breaking spaces inside each duration so the line never wraps mid-duration ("7h / 30m").
        let asleepText = durationText(night.stages.asleep).replacingOccurrences(of: " ", with: "\u{00A0}")
        let needText = durationText(needMin).replacingOccurrences(of: " ", with: "\u{00A0}")
        let supporting = String(localized: "\(asleepText) asleep · \(needText) needed")
        let perf = showsPerformance ? performance.latest : nil
        NoopCard {
            // Wide (mac): ring left, details right. Narrow (iPhone): stacked, centered.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 28) {
                    heroRing(perf, supporting: supporting)
                    Text(heroSubline(night, performance: performance, isPersisted: isPersisted,
                                     showsPerformance: showsPerformance))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                VStack(spacing: 10) {
                    heroRing(perf, supporting: supporting)
                    Text(heroSubline(night, performance: performance, isPersisted: isPersisted,
                                     showsPerformance: showsPerformance))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Ring with score, or a zero-fill track with "—" when no performance value exists.
    @ViewBuilder
    private func heroRing(_ perf: Double?, supporting: String) -> some View {
        if let perf {
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

    /// "8h 01m in bed · 90% efficiency[ · performance +3% vs typical][ · stages approximate (on-device)]"
    private func heroSubline(_ night: Night, performance: SleepModel.Metric,
                             isPersisted: Bool, showsPerformance: Bool) -> String {
        var parts = [String(localized: "\(durationText(night.timeInBed)) in bed"),
                     String(localized: "\(efficiencyText(night)) efficiency")]
        // The dropped Sleep Performance tile carried a "vs typical" caption — zero
        // information loss: it lives here now (only for the latest night, which has a perf %).
        if showsPerformance, let perf = performance.latest, let typical = performance.typical, typical != 0 {
            parts.append(String(localized: "performance \(vsTypical(perf, typical, suffix: "%"))"))
        }
        if isPersisted { parts.append(String(localized: "stages approximate (on-device)")) }
        return parts.joined(separator: " · ")
    }

    // MARK: - 1. Night timeline — stage breakdown

    @ViewBuilder
    private func nightTimeline(_ model: SleepModel) -> some View {
        // Feed the timeline from whichever Night the ◀/▶ nav selected: offset 0 uses the
        // memoized latest night + intervals; a navigated night uses its own decoded timeline.
        // A navigated day with no usable stages is already handled by the hero placeholder, so
        // here we simply skip the timeline. (#160, #170)
        if nightOffset == 0 {
            nightTimelineCard(model.night, intervals: model.intervals)
        } else if let night = navNight {
            nightTimelineCard(night, intervals: night.intervals)
        }
    }

    @ViewBuilder
    private func nightTimelineCard(_ night: Night, intervals: [SleepInterval]) -> some View {
        let s = night.stages
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

    /// "date · onset–wake" — the nav header's trailing line. A day whose sleep crosses midnight
    /// (onset and wake on different calendar dates) shows the span, e.g. "Fri 13 → Sat 14 Jun".
    private func headerLine(_ night: Night) -> String {
        "\(spanLabel(night)) · \(night.onsetText)–\(night.wakeText)"
    }

    /// Date label that becomes a span when the night crosses midnight (onset on a different
    /// calendar day from wake) — e.g. "Fri 13 → Sat 14 Jun" — otherwise a single date. Computed
    /// here because the shared `Night` (Strand/Data/SleepModel.swift) carries totals-only
    /// formatting; this lets an aggregated split-sleep day read honestly. (#170)
    private func spanLabel(_ night: Night) -> String {
        let onsetDay = Date(timeIntervalSince1970: TimeInterval(night.session.startTs))
        let wakeDay  = Date(timeIntervalSince1970: TimeInterval(night.session.endTs))
        let cal = Calendar.current
        if cal.isDate(onsetDay, inSameDayAs: wakeDay) { return night.dateLabel }
        return "\(SleepView.spanFmt.string(from: onsetDay)) → \(SleepView.dateFmt.string(from: wakeDay))"
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
                          trailing: String(localized: "marker = your mean"))
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
        // Six series are read here, each computed ONCE in the model build (full passes over
        // repo.days/repo.sleeps). A seventh model series (performance) feeds the hero ring, not this grid.
        let eff   = model.efficiency
        let cons  = model.consistency
        let need  = model.hoursVsNeeded
        let rest  = model.restorative
        let resp  = model.respiratory
        let debt  = model.sleepDebt

        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Night detail", overline: "Metrics", trailing: String(localized: "vs typical"))
            LazyVGrid(columns: tileColumns, alignment: .leading, spacing: NoopMetrics.gap) {

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
            SectionHeader("Asleep duration", overline: "Trend", trailing: String(localized: "Last 30 days"))
            ChartCard(
                title: "Hours asleep",
                subtitle: String(localized: "Per night, trailing 30 days"),
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

    // MARK: - Past-night navigation (split-sleep aware) (#160, #170)

    /// The browsable block list: every sleep session un-deduplicated (incl. same-day naps / split
    /// sleep). Falls back to `repo.sleeps` (one-per-night) until the fuller list loads, so the hero
    /// is never empty during the first frame. (#170)
    private var navSessions: [CachedSleepSession] {
        allSessions.isEmpty ? repo.sleeps : allSessions
    }

    /// The browsable DAY list: every block grouped by the calendar day it ENDS on (matching the
    /// dashboard's per-night merge), newest day first, blocks within a day oldest→newest. Each day
    /// is ONE ◀/▶ stop, so a split-sleep day reads as a single night and the "N nights ago" label
    /// stays truthful — two blocks of the same day are never "1 night ago" AND "2 nights ago". (#170)
    private var navDays: [[CachedSleepSession]] {
        let cal = Calendar.current
        func endDay(_ s: CachedSleepSession) -> Date {
            cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
        }
        let groups = Dictionary(grouping: navSessions, by: endDay)
        return groups.keys.sorted(by: >).map { key in
            (groups[key] ?? []).sorted { $0.startTs < $1.startTs }
        }
    }

    /// Merge all of a day's blocks into ONE `Night`: stage minutes summed, each block's timeline
    /// concatenated onto a single axis with the REAL gap between blocks preserved, efficiency
    /// recomputed over time-in-bed (carried on the synthetic session so a navigated day never
    /// borrows `repo.today`'s efficiency). Returns nil if no block decodes to usable stages. (#170)
    private func mergeDay(_ sessions: [CachedSleepSession]) -> Night? {
        guard let first = sessions.first,
              let last = sessions.max(by: { $0.endTs < $1.endTs }) else { return nil }
        let onset = first.startTs, wake = last.endTs
        var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        var segs: [SleepInterval] = []
        for s in sessions {
            let shift = TimeInterval(s.startTs - onset)
            if let seg = decodeSegments(s.stagesJSON, sessionStart: s.startTs), seg.stages.total > 0 {
                stages.awake += seg.stages.awake; stages.light += seg.stages.light
                stages.deep  += seg.stages.deep;  stages.rem   += seg.stages.rem
                for iv in seg.intervals {
                    segs.append(SleepInterval(stage: iv.stage, start: iv.start + shift, end: iv.end + shift))
                }
            } else if let st = decodeStages(s.stagesJSON), st.total > 0 {
                stages.awake += st.awake; stages.light += st.light
                stages.deep  += st.deep;  stages.rem   += st.rem
            }
        }
        guard stages.asleep > 0 else { return nil }
        let eff = stages.total > 0 ? stages.asleep / stages.total : nil   // fraction ≤ 1
        let synth = CachedSleepSession(startTs: onset, endTs: wake, efficiency: eff,
                                       restingHr: nil, avgHrv: nil, stagesJSON: nil)
        let realSegs = segs.count >= 2 ? segs.sorted { $0.start < $1.start } : nil
        return Night(session: synth, stages: stages, realSegments: realSegs)
    }

    /// The merged Night for the DAY `offset` stops back from the most recent (0 = last night).
    /// Backs the hero's ◀/▶ navigation via the `navNight` cache — JSON-decodes, so it only runs
    /// from the onChange handlers, never per render. (#160, #170)
    private func decodedNight(at offset: Int) -> Night? {
        let days = navDays
        guard offset >= 0, offset < days.count else { return nil }
        return mergeDay(days[offset])
    }

    /// A synthetic session spanning the DAY `offset` stops back (onset of its first block → wake of
    /// its last), for the honest no-stage-data header when a day's blocks don't decode to usable
    /// stages. (#160, #170)
    private func sessionRow(at offset: Int) -> CachedSleepSession? {
        let days = navDays
        guard offset >= 0, offset < days.count,
              let first = days[offset].first,
              let last = days[offset].max(by: { $0.endTs < $1.endTs }) else { return nil }
        return CachedSleepSession(startTs: first.startTs, endTs: last.endTs,
                                  efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
    }

    /// Header above the hero with ◀/▶ to browse past nights. ◀ goes older (increasing offset),
    /// ▶ goes newer; each is disabled at its bound. The canonical SectionHeader carries the
    /// hierarchy so the hero reads like every other section. (#160)
    @ViewBuilder
    private func nightNavHeader(trailing: String) -> some View {
        let lastIndex = max(navDays.count - 1, 0)
        let title: LocalizedStringKey = nightOffset == 0 ? "Last night"
            : (nightOffset == 1 ? "1 night ago" : "\(nightOffset) nights ago")
        HStack(spacing: 12) {
            Button { if nightOffset < lastIndex { nightOffset += 1 } } label: {
                Image(systemName: "chevron.left")
                    .font(StrandFont.headline)
                    .foregroundStyle(nightOffset >= lastIndex ? StrandPalette.textTertiary : StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .disabled(nightOffset >= lastIndex)
            .accessibilityLabel("Previous night")

            SectionHeader(title, overline: "Sleep", trailing: trailing)

            Button { if nightOffset > 0 { nightOffset -= 1 } } label: {
                Image(systemName: "chevron.right")
                    .font(StrandFont.headline)
                    .foregroundStyle(nightOffset == 0 ? StrandPalette.textTertiary : StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .disabled(nightOffset == 0)
            .accessibilityLabel("Next night")
        }
    }

    // MARK: - Stage decoding (for the navigated split-sleep merge)
    //
    // The shared SleepModel layer (Strand/Data/SleepModel.swift) owns the same decoders for the
    // dashboard's latest-night build; these instance copies back `mergeDay`, which assembles a
    // navigated day's blocks here in the view.

    /// Decode the imported stagesJSON dict of MINUTES {"light","deep","rem","awake"}.
    private func decodeStages(_ json: String?) -> Stages? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        func val(_ key: String) -> Double {
            if let n = dict[key] as? NSNumber { return n.doubleValue }
            if let d = dict[key] as? Double { return d }
            if let i = dict[key] as? Int { return Double(i) }
            return 0
        }
        let s = Stages(awake: val("awake"), light: val("light"),
                       deep: val("deep"), rem: val("rem"))
        return s.total > 0 ? s : nil
    }

    /// Decode the COMPUTED stagesJSON segment array [{"start":epoch,"end":epoch,"stage":"wake"|
    /// "light"|"deep"|"rem"}] into stage totals plus the real timeline (seconds relative to the
    /// session start, the Hypnogram's domain). The on-device SleepStager calls awake "wake". (#77)
    private func decodeSegments(
        _ json: String?, sessionStart: Int
    ) -> (stages: Stages, intervals: [SleepInterval])? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !arr.isEmpty else { return nil }
        var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        var intervals: [SleepInterval] = []
        for seg in arr {
            guard let start = (seg["start"] as? NSNumber)?.intValue,
                  let end = (seg["end"] as? NSNumber)?.intValue, end > start,
                  let name = seg["stage"] as? String else { continue }
            let minutes = Double(end - start) / 60.0
            let stage: SleepStage
            switch name {
            case "wake", "awake": stage = .awake; stages.awake += minutes
            case "light": stage = .light; stages.light += minutes
            case "deep": stage = .deep; stages.deep += minutes
            case "rem": stage = .rem; stages.rem += minutes
            default: continue
            }
            intervals.append(SleepInterval(
                stage: stage,
                start: TimeInterval(start - sessionStart),
                end: TimeInterval(end - sessionStart)))
        }
        return stages.total > 0 ? (stages, intervals) : nil
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

    /// Hero chart slot for a NAVIGATED session with no decodable stages — honest about the
    /// gap instead of rendering the latest night under a navigated label. (#160)
    private var noStagePlaceholder: some View {
        Text("No stage data recorded for this night.")
            .font(StrandFont.footnote)
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
        guard let latest, let typical, typical != 0 else { return String(localized: "vs typical —") }
        let diff = latest - typical
        let sign = diff >= 0 ? "+" : "−"
        let mag = abs(diff)
        let num = decimals == 0 ? "\(Int(mag.rounded()))" : String(format: "%.\(decimals)f", mag)
        return String(localized: "\(sign)\(num)\(suffix) vs typical")
    }

    private func debtCaption(_ debt: Double?) -> String {
        guard let debt else { return String(localized: "vs need") }
        return debt < 15 ? String(localized: "On target") : String(localized: "Below need")
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

    // MARK: - Date formatting for the nav header's cross-midnight span
    //
    // The shared `Night` (Strand/Data/SleepModel.swift) formats a single onset date; an
    // aggregated split-sleep day can cross midnight, so `spanLabel(_:)` above formats the span
    // with these. `EEE d MMM` matches Night.dateLabel's wake side; `EEE d` is the onset side. (#170)
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()
    /// Onset side of a cross-midnight span — no month (the wake side carries it): "Fri 13".
    private static let spanFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d"; return f
    }()
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
