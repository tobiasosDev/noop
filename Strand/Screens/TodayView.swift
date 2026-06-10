import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Control Center (the home dashboard) — HomeDensity rewrite
//
// The owner's complaint was "cards then random space". This rebuild is a tight,
// GAPLESS dashboard grid: one column of uniform sections, every gap == NoopMetrics.gap,
// every section break == NoopMetrics.sectionGap, equal margins from ScreenScaffold.
//
// Composition (top → bottom):
//   (a) HERO  — full-width HStack that fills the width EQUALLY: RecoveryRing (left card)
//               + InsightCard "Today's Synthesis" (right card). No lone card, no gap.
//   (b) METRICS — one adaptive LazyVGrid of fixed-104pt StatTiles (Recovery, Strain,
//               Sleep, HRV, RHR, SpO2, Respiratory, Steps, Weight, Calories) each with
//               a 14-day sparkline so the grid tiles perfectly with no empty cells.
//   (c) LAST WORKOUTS — the SAME adaptive grid of fixed-104pt workout StatTiles.
//   (d) DATA SOURCES — one full-width NoopCard footer of SourceBadges + counts.
//
// Sparse series (weight) fall back to ALL history so a tile never shows an empty
// state when data exists. Only locked StrandDesign components are used.

struct TodayView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var goalStore: GoalStore

    // Strain Coach — intraday strain so far today (nil until ~10 min of HR exists).
    @State private var dayStrain: Double? = nil

    // Goals chips — steps series for the daily-steps goal evaluation.
    @State private var goalStepsByDay: [String: Double] = [:]

    // 14-day sparkline series, keyed by metric key. Loaded once in .task.
    @State private var sparks: [String: [Double]] = [:]
    @State private var workouts: [WorkoutRow] = []
    @State private var appleDays: [AppleDaily] = []

    // Today's heart rate as 5-minute bucket means (midnight → now), for the 24h trend chart.
    @State private var hrPoints: [TrendPoint] = []

    // Support sheet (donate + contact) — always reachable from the home toolbar.
    @State private var showingSupport = false

    // THE single grid definition — every tile group reuses it so margins line up.
    private let grid = [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)]

    /// Recovery cold-start: recovery is nil until the HRV baseline crosses the seed gate
    /// (Baselines.minNightsSeed valid nights). While calibrating, this is the count of nights
    /// banked so far — it drives an honest "Calibrating — N of 4 nights" on the recovery ring,
    /// the synthesis card and the Key Metrics tile instead of a bare empty state. It self-clears
    /// the moment recovery populates, and never claims "calibrating" at/above the seed gate.
    /// Mirrors Android TodayScreen.recoveryCalibrationNights (7b5f212).
    private var recoveryCalibration: Int? {
        RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv),
                                         hasRecovery: repo.today?.recovery != nil)
    }

    /// Synthesis-card copy while the recovery baseline calibrates; nil otherwise. Built as
    /// LocalizedStringKey literals so the String Catalog picks up the %lld patterns.
    private var calibrationStatus: LocalizedStringKey? {
        recoveryCalibration == nil ? nil : "Calibrating"
    }
    private var calibrationDetail: LocalizedStringKey? {
        guard let n = recoveryCalibration else { return nil }
        return "Learning your baseline — \(n) of \(Baselines.minNightsSeed) nights."
    }

    var body: some View {
        ScreenScaffold(title: "Control Center", subtitle: "\(dateLine)") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                HealthAlertBanner()
                MorningJournalCard()
                if repo.today?.recovery == nil {
                    // While the strap is mid-offload, say so — empty tiles read as final otherwise (#77).
                    if live.backfilling { SyncingHistoryNote(chunks: live.syncChunksThisSession) }
                    DataPendingNote(
                        title: "Live now. Your scores are building.",
                        message: "Your live heart rate is working from the strap, and recovery, strain and sleep build from it over your next few nights of wear, sharpening as it learns your baseline. Want your full history instantly? Import your WHOOP export in Data Sources and it backfills in about a minute."
                    )
                }
                heroSection
                strainCoachSection
                goalsSection
                heartRateTrendSection
                readinessSection
                metricsSection
                workoutsSection
                sourcesSection
            }
        }
        .task(id: repo.refreshSeq) { await loadAll() }
        .toolbar {
            ToolbarItem {
                Button { showingSupport = true } label: {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(StrandPalette.metricRose)
                        .attentionWiggle(period: 4)
                }
                .help("Support NOOP — donate or get in touch")
                .accessibilityLabel("Support NOOP — donate or get in touch")
            }
        }
        .overlay {
            if showingSupport {
                SupportModalOverlay(isPresented: $showingSupport)
            }
        }
        .animation(.easeOut(duration: 0.18), value: showingSupport)
    }

    // MARK: Readiness — on-device training-readiness synthesis (HRV / resting-HR / load).

    @ViewBuilder
    private var readinessSection: some View {
        let r = ReadinessEngine.evaluate(days: repo.days, today: Repository.localDayKey(Date()))
        if r.level != .insufficient {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Readiness", overline: "Should you push today?")
                NoopCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Circle().fill(readinessColor(r.level)).frame(width: 10, height: 10)
                            Text(r.headline).font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            if let acwr = r.acwr {
                                Text("load \(String(format: "%.2f", acwr))")
                                    .font(StrandFont.captionNumber)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .help("Acute (7-day) vs chronic (28-day) training load. 0.8–1.3 is the sweet spot.")
                            }
                        }
                        Text(r.summary).font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !r.signals.isEmpty {
                            Divider().overlay(StrandPalette.hairline)
                            ForEach(r.signals, id: \.key) { s in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle().fill(flagColor(s.flag)).frame(width: 7, height: 7)
                                        .padding(.top, 5)
                                    Text(s.label).font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                        .frame(width: 104, alignment: .leading)
                                    Text(s.detail).font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func readinessColor(_ l: ReadinessEngine.Level) -> Color {
        switch l {
        case .primed:       return StrandPalette.accent
        case .balanced:     return StrandPalette.statusPositive
        case .strained:     return StrandPalette.statusWarning
        case .rundown:      return StrandPalette.metricRose
        case .insufficient: return StrandPalette.textTertiary
        }
    }

    private func flagColor(_ f: ReadinessEngine.Flag) -> Color {
        switch f {
        case .good:    return StrandPalette.accent
        case .neutral: return StrandPalette.textTertiary
        case .watch:   return StrandPalette.statusWarning
        case .bad:     return StrandPalette.metricRose
        }
    }

    // MARK: (a) HERO — RecoveryRing + Synthesis, filling the width equally.

    @ViewBuilder
    private var heroSection: some View {
        let d = repo.today
        let score = d?.recovery
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Today’s Synthesis", overline: "At a glance",
                          trailing: greetingWord)
            // The ring is hard-framed at 168pt. On a wide (macOS/iPad) canvas the two
            // cards sit side-by-side, each with ample column width. On a compact iPhone
            // the half-width column is narrower than the ring, so ViewThatFits falls back
            // to stacking the cards vertically at full width where the ring fits cleanly.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: NoopMetrics.gap) {
                    heroRingCard(score: score, d: d)
                    heroInsightCard(score: score, d: d)
                }
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    heroRingCard(score: score, d: d)
                    heroInsightCard(score: score, d: d)
                }
            }
        }
    }

    /// Left: the signature ring in a card. When recovery is nil the ring's own center label
    /// (which would read "0 · DEPLETED") and hover are hidden and an honest overlay takes over:
    /// "Calibrating · N of 4 nights" while the baseline seeds, else "No Data". Mirrors Android
    /// TodayScreen.TodayRecoveryRing (7b5f212).
    @ViewBuilder
    private func heroRingCard(score: Double?, d: DailyMetric?) -> some View {
        NoopCard {
            ZStack {
                RecoveryRing(
                    score: score ?? 0,
                    supporting: ringSupporting(d),
                    diameter: 168,
                    showsLabel: score != nil,
                    showsHover: score != nil
                )
                if score == nil {
                    VStack(spacing: 4) {
                        if let n = recoveryCalibration {
                            Text("Calibrating")
                                .font(StrandFont.title2)
                                .foregroundStyle(StrandPalette.textTertiary)
                            Text("\(n) of \(Baselines.minNightsSeed) nights")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        } else {
                            Text("No data")
                                .font(StrandFont.title2)
                                .foregroundStyle(StrandPalette.textTertiary)
                            Text(ringSupporting(d))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Right: the plain-English read-out, equal width.
    @ViewBuilder
    private func heroInsightCard(score: Double?, d: DailyMetric?) -> some View {
        InsightCard(
            category: "Recovery",
            status: calibrationStatus ?? "\(synthesisWord(score))",
            detail: calibrationDetail ?? "\(synthesisDetail(d))",
            statusColor: score.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textTertiary
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Strain Coach — today's exertion target from recovery, filled live.

    @ViewBuilder
    private var strainCoachSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Strain Coach", overline: "Today's exertion target")
            NoopCard {
                if let recovery = repo.today?.recovery {
                    let band = StrainTarget.band(recovery: recovery)
                    let current = dayStrain ?? 0
                    // Wide: gauge + text side by side. Compact iPhone: stacked.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: NoopMetrics.gap * 2) {
                            strainCoachGauge(current: current)
                            strainCoachDetail(band: band, current: current)
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                            strainCoachGauge(current: current).frame(maxWidth: .infinity)
                            strainCoachDetail(band: band, current: current)
                        }
                    }
                } else {
                    Text("No recovery yet today — your strain target appears once last night is scored.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func strainCoachGauge(current: Double) -> some View {
        // While the score is still building (dayStrain == nil), the gauge renders as a
        // dimmed, unlabelled dial with an em-dash placeholder — an instrument warming
        // up — instead of claiming "0.0" as a real reading.
        let pending = dayStrain == nil
        return StrainGauge(strain: current, diameter: 132, lineWidth: 11,
                           showsLabel: !pending, showsHover: !pending)
            .opacity(pending ? 0.55 : 1)
            .overlay {
                if pending {
                    VStack(spacing: 2) {
                        Text(verbatim: "—")
                            .font(StrandFont.display(132 * 0.26))
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text("STRAIN")
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
            .frame(minWidth: 132)
    }

    @ViewBuilder
    private func strainCoachDetail(band: StrainTarget.Band, current: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Aim \(band.low, specifier: "%.1f")–\(band.high, specifier: "%.1f")")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            if dayStrain == nil {
                // No reading yet — only the building note, never a numeric state claim.
                Text("Building — needs about 10 minutes of heart-rate data.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let state = band.state(currentStrain: current)
                Text(strainCoachStateLine(state, current: current))
                    .font(StrandFont.subhead)
                    .foregroundStyle(strainCoachStateColor(state))
                    .fixedSize(horizontal: false, vertical: true)
                if !live.connected {
                    Text("Strap not connected — showing the last synced value.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// LocalizedStringKey (not String(format:)) so these lines land in the String Catalog.
    private func strainCoachStateLine(_ s: StrainTarget.State, current: Double) -> LocalizedStringKey {
        switch s {
        case .building:     return "\(current, specifier: "%.1f") now — room to push today."
        case .onTarget:     return "\(current, specifier: "%.1f") now — right in your target band."
        case .overreaching: return "\(current, specifier: "%.1f") now — beyond today's recommendation."
        }
    }

    private func strainCoachStateColor(_ s: StrainTarget.State) -> Color {
        switch s {
        case .building:     return StrandPalette.textSecondary
        case .onTarget:     return StrandPalette.accent
        case .overreaching: return StrandPalette.statusWarning
        }
    }

    // MARK: Goals — today's status per active goal. Hidden with no goals.

    @ViewBuilder
    private var goalsSection: some View {
        if !goalStore.goals.isEmpty {
            let weekDays = goalWeekDays()
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Goals", overline: "Today's score")
                NoopCard {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(goalStore.goals, id: \.id) { goal in
                            if let kind = GoalProgress.Kind(rawValue: goal.kind) {
                                goalChipRow(goal: goal, kind: kind, weekDays: weekDays)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func goalChipRow(goal: GoalRow, kind: GoalProgress.Kind, weekDays: [String]) -> some View {
        let p = GoalProgress.evaluate(
            kind: kind, target: goal.target,
            values: kind.weekValues(days: repo.days, stepsByDay: goalStepsByDay, weekDays: weekDays),
            weekDays: weekDays)
        HStack(spacing: 10) {
            Circle()
                .fill(goalChipColor(p, kind: kind))
                .frame(width: 9, height: 9)
            Text(kind.displayTitle)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            Text(goalChipStatus(p, kind: kind))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    /// .weeklyStrain scores the WEEK AVERAGE — per-day hit is advisory only
    /// (GoalProgress.swift header), so its chip goes green off the weekly average
    /// reaching target ("On track"), never off today's value alone.
    private func goalAchieved(_ p: GoalProgress.Progress, kind: GoalProgress.Kind) -> Bool {
        kind == .weeklyStrain ? p.percent >= 100 : p.todayHit
    }

    private func goalChipColor(_ p: GoalProgress.Progress, kind: GoalProgress.Kind) -> Color {
        if goalAchieved(p, kind: kind) { return StrandPalette.accent }
        if p.todayValue != nil { return StrandPalette.statusWarning }
        return StrandPalette.textTertiary
    }

    private func goalChipStatus(_ p: GoalProgress.Progress, kind: GoalProgress.Kind) -> LocalizedStringKey {
        if goalAchieved(p, kind: kind) {
            if kind == .weeklyStrain { return "On track" }
            return "Hit"
        }
        if p.todayValue != nil { return "In progress" }
        return "No data yet"
    }

    // MARK: HEART RATE — today's continuous HR, off the strap's own ~1Hz history.

    /// A full-width 24-hour heart-rate trend, plotted from 5-minute bucket means of the strap's
    /// `hrSample` history (offloaded even while the app was closed, so the day reads continuously).
    /// Hidden until there are at least two buckets — a strap-only user with no wear today sees nothing
    /// rather than an empty axis. Mirrored on Android (TodayScreen.kt HeartRateTrendCard).
    @ViewBuilder
    private var heartRateTrendSection: some View {
        if hrPoints.count > 1 {
            let v = hrPoints.map(\.value)
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Heart Rate", overline: "Today")
                ChartCard(
                    title: "Beats per minute",
                    subtitle: "5-minute average · since midnight",
                    trailing: v.last.map { "\(Int($0.rounded())) bpm" }
                ) {
                    TrendChart(
                        points: hrPoints,
                        gradient: Gradient(colors: [StrandPalette.metricRose.opacity(0.55), StrandPalette.metricRose]),
                        valueRange: hrRange(v),
                        showsArea: true,
                        height: NoopMetrics.chartHeight,
                        valueFormat: { "\(Int($0.rounded())) bpm" },
                        dateFormat: { Self.hrTimeFmt.string(from: $0) }
                    )
                } footer: {
                    ChartFooter([
                        ("Min", "\(Int((v.min() ?? 0).rounded()))"),
                        ("Avg", "\(Int((v.reduce(0, +) / Double(v.count)).rounded()))"),
                        ("Max", "\(Int((v.max() ?? 0).rounded()))"),
                    ])
                }
            }
        }
    }

    /// Padded HR axis range so the line never sits flush against an edge (mirrors MetricExplorer.valueRange).
    private func hrRange(_ v: [Double]) -> ClosedRange<Double> {
        guard let lo = v.min(), let hi = v.max() else { return 40...120 }
        if hi <= lo { return (lo - 5)...(hi + 5) }
        let span = hi - lo
        return (lo - span * 0.12)...(hi + span * 0.12)
    }

    // MARK: (b) METRICS — one uniform grid of 104pt StatTiles, every cell filled.

    @ViewBuilder
    private var metricsSection: some View {
        let d = repo.today
        let aLatest = appleDays.last
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Key Metrics", overline: "Today", trailing: "14-day trend")
            LazyVGrid(columns: grid, alignment: .leading, spacing: NoopMetrics.gap) {
                StatTile(
                    label: "Recovery",
                    value: d?.recovery.map { "\(Int($0.rounded()))%" }
                        ?? recoveryCalibration.map { "\($0)/\(Baselines.minNightsSeed)" } ?? "—",
                    caption: d?.recovery.map { StrandPalette.recoveryState($0).capitalized }
                        ?? recoveryCalibration.map { _ in "Calibrating" },
                    accent: d?.recovery.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                    sparkline: sparks["recovery"],
                    sparkColor: StrandPalette.accent
                )
                StatTile(
                    label: "Day Strain",
                    value: d?.strain.map { String(format: "%.1f", $0) } ?? "—",
                    caption: "of 21",
                    accent: d?.strain.map { StrandPalette.strainColor($0) } ?? StrandPalette.textPrimary,
                    sparkline: sparks["strain"],
                    sparkColor: StrandPalette.strain066
                )
                StatTile(
                    label: "Sleep",
                    value: sleepValue(d),
                    caption: d?.efficiency.map { String(format: "%.0f%% eff", $0) },
                    accent: StrandPalette.textPrimary,
                    sparkline: sparks["sleep_total_min"],
                    sparkColor: StrandPalette.metricPurple
                )
                StatTile(
                    label: "HRV",
                    value: d?.avgHrv.map { "\(Int($0.rounded()))" } ?? "—",
                    caption: "ms",
                    accent: StrandPalette.metricPurple,
                    sparkline: sparks["hrv"],
                    sparkColor: StrandPalette.metricPurple
                )
                StatTile(
                    label: "Resting HR",
                    value: d?.restingHr.map { "\($0)" } ?? "—",
                    caption: "bpm",
                    accent: StrandPalette.metricRose,
                    sparkline: sparks["rhr"],
                    sparkColor: StrandPalette.metricRose
                )
                StatTile(
                    label: "Blood Oxygen",
                    value: d?.spo2Pct.map { String(format: "%.0f%%", $0) } ?? "—",
                    caption: "SpO₂",
                    accent: StrandPalette.metricCyan,
                    sparkline: sparks["spo2"],
                    sparkColor: StrandPalette.metricCyan
                )
                StatTile(
                    label: "Respiratory",
                    value: d?.respRateBpm.map { String(format: "%.1f", $0) } ?? latestString("resp_rate", decimals: 1),
                    caption: "rpm",
                    accent: StrandPalette.accent,
                    sparkline: sparks["resp_rate"],
                    sparkColor: StrandPalette.accent
                )
                StatTile(
                    label: "Steps",
                    value: aLatest?.steps.map { intString(Double($0)) } ?? latestString("steps", decimals: 0),
                    caption: "today",
                    accent: StrandPalette.metricCyan,
                    sparkline: sparks["steps"],
                    sparkColor: StrandPalette.metricCyan
                )
                StatTile(
                    label: "Weight",
                    value: aLatest?.weightKg.map { String(format: "%.1f kg", $0) } ?? latestString("weight", decimals: 1, unit: "kg"),
                    caption: "latest",
                    accent: StrandPalette.accent,
                    sparkline: sparks["weight"],
                    sparkColor: StrandPalette.accent
                )
                StatTile(
                    label: "Calories",
                    value: caloriesValue(aLatest),
                    caption: "active",
                    accent: StrandPalette.metricAmber,
                    sparkline: sparks["active_kcal"],
                    sparkColor: StrandPalette.metricAmber
                )
            }
        }
    }

    // MARK: (c) LAST WORKOUTS — SAME grid, uniform 104pt workout tiles.

    @ViewBuilder
    private var workoutsSection: some View {
        if !workouts.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Last Workouts", overline: "Activity",
                              trailing: "\(workouts.count) total")
                LazyVGrid(columns: grid, alignment: .leading, spacing: NoopMetrics.gap) {
                    ForEach(Array(workouts.prefix(6).enumerated()), id: \.offset) { _, w in
                        StatTile(
                            label: "\(w.sport)",
                            value: workoutDuration(w),
                            caption: workoutCaption(w),
                            accent: StrandPalette.strainColor(w.strain ?? 0),
                            delta: w.energyKcal.map { "\(Int($0.rounded())) kcal" },
                            deltaColor: StrandPalette.metricAmber
                        )
                    }
                }
            }
        }
    }

    // MARK: (d) DATA SOURCES — one full-width footer card.

    @ViewBuilder
    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Data Sources", overline: "Provenance")
            NoopCard {
                VStack(alignment: .leading, spacing: 12) {
                    sourceRow(
                        badge: "Whoop",
                        tint: StrandPalette.accent,
                        present: !repo.days.isEmpty,
                        detail: "\(repo.days.count) days · \(repo.sleeps.count) sleeps"
                    )
                    Divider().overlay(StrandPalette.hairline)
                    sourceRow(
                        badge: "Apple Health",
                        tint: StrandPalette.metricCyan,
                        present: !appleDays.isEmpty,
                        detail: "\(appleDays.count) days · \(workouts.filter { $0.source == "apple-health" }.count) workouts"
                    )
                    Divider().overlay(StrandPalette.hairline)
                    strapSyncRow
                }
            }
        }
    }

    @ViewBuilder
    private func sourceRow(badge: String, tint: Color, present: Bool, detail: String) -> some View {
        HStack(spacing: 10) {
            SourceBadge("\(badge)", tint: present ? tint : StrandPalette.textTertiary)
            Spacer()
            Text(present ? detail : "Not connected")
                .font(StrandFont.captionNumber)
                .foregroundStyle(present ? StrandPalette.textSecondary : StrandPalette.textTertiary)
        }
    }

    /// Honest strap-sync outcome for a cloud-free app (ports the Android Live line, ed6a31d): the
    /// stalled-offload error when the last one died, else "History synced N ago". Hidden while an
    /// offload runs — SyncingHistoryNote already says so. TimelineView re-renders the relative label
    /// each minute so "5 min ago" can't go stale while the window sits open with no strap connected
    /// (LiveState publishes nothing then).
    @ViewBuilder
    private var strapSyncRow: some View {
        if !live.backfilling {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(alignment: .top, spacing: 10) {
                    SourceBadge("Strap sync",
                                tint: live.lastSyncError != nil ? StrandPalette.statusWarning
                                    : live.lastSyncedAt != nil ? StrandPalette.accent
                                    : StrandPalette.textTertiary)
                    Spacer()
                    if let error = live.lastSyncError {
                        Text(error)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let at = live.lastSyncedAt {
                        Text("History synced \(relativeAgo(at, now: context.date.timeIntervalSince1970))")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        Text("Not synced yet")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    // MARK: - Loading

    private func loadAll() async {
        // 14-day sparklines — Whoop.
        sparks["recovery"]        = await sparkValues("recovery", source: "my-whoop", window: 14)
        sparks["strain"]          = await sparkValues("strain", source: "my-whoop", window: 14)
        sparks["sleep_total_min"] = await sparkValues("sleep_total_min", source: "my-whoop", window: 14)
        sparks["hrv"]             = await sparkValues("hrv", source: "my-whoop", window: 14)
        sparks["rhr"]             = await sparkValues("rhr", source: "my-whoop", window: 14)
        sparks["spo2"]            = await sparkValues("spo2", source: "my-whoop", window: 14)

        // 14-day sparklines — Apple Health.
        sparks["resp_rate"]   = await sparkValues("resp_rate", source: "apple-health", window: 14)
        sparks["steps"]       = await sparkValues("steps", source: "apple-health", window: 14)
        sparks["weight"]      = await sparkValues("weight", source: "apple-health", window: 90)
        sparks["active_kcal"] = await sparkValues("active_kcal", source: "apple-health", window: 14)

        workouts = await repo.workoutRows()
        appleDays = await repo.appleDailyRows()

        // Today's HR trend — 5-minute bucket means from local midnight → now.
        let startOfToday = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let nowTs = Int(Date().timeIntervalSince1970)
        hrPoints = await repo.hrBuckets(from: startOfToday, to: nowTs, bucketSeconds: 300)
            .map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }

        // Strain Coach — intraday strain from today's raw HR.
        dayStrain = await DayStrain.compute(repo: repo, hrMax: profile.hrMax,
                                            sex: profile.sex,
                                            restingHr: repo.today?.restingHr)

        // Goals chips — weekly adherence only ever reads the current week, so query just that
        // (+2 days of timezone slack) instead of the full multi-year series.
        await goalStore.load()
        goalStepsByDay = Dictionary(
            await repo.series(key: "steps", source: "apple-health", days: 9).map { ($0.day, $0.value) },
            uniquingKeysWith: { _, new in new })
    }

    /// Trailing-window values for a metric — NO fall back to all history. The section is labelled a
    /// current trend ("14-day trend"), so a stale import must not render months-old points as if they
    /// were recent (same spirit as the #23 trailing-window fix). The window is generous enough that a
    /// genuinely sparse-but-recent series still renders — weight uses 90 days — and the Sparkline view
    /// already handles 0/1 points (empty / a single head dot), so no fallback is needed for layout.
    /// `latestString` reads `.last` of this windowed series, so a value older than the window shows
    /// "—" rather than a stale number under a Today tile (#49).
    private func sparkValues(_ key: String, source: String, window: Int) async -> [Double] {
        // Window the QUERY too (+2 days of timezone slack) — the trailing filter below still
        // defines the semantics, but fetching the full multi-year series for 10 keys per refresh
        // was pure waste (refreshSeq re-runs this every sync).
        let all = await repo.series(key: key, source: source, days: window + 2)
        guard !all.isEmpty else { return [] }
        return trailingWindow(all, days: window).map { $0.value }
    }

    /// Keep only points within the trailing `days` CALENDAR days ending TODAY (the phone's local date).
    /// Was anchored to the most-recent point, which on a stale import pinned the window to months-old
    /// data shown as a current trend (issue #23). ISO yyyy-MM-dd compares chronologically.
    private func trailingWindow(_ points: [(day: String, value: Double)], days: Int) -> [(day: String, value: Double)] {
        let cutoffKey = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date())
        return points.filter { $0.day >= cutoffKey }
    }

    /// Latest value of a loaded sparkline series, formatted — for tiles whose hero
    /// can't be read off `appleDailyRows` (e.g. respiratory from apple-health).
    private func latestString(_ key: String, decimals: Int, unit: String = "") -> String {
        guard let last = sparks[key]?.last else { return "—" }
        let n = decimals == 0 ? intString(last) : String(format: "%.\(decimals)f", last)
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    // MARK: - Derived text

    /// Greeting word used as the section's trailing label (no lone text block).
    private var greetingWord: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case ..<12:   return String(localized: "Good morning")
        case 12..<17: return String(localized: "Good afternoon")
        default:      return String(localized: "Good evening")
        }
    }

    private var dateLine: String {
        let f = DateFormatter()
        // Display date in the user's locale (German shows "Dienstag, 9. Juni"); parsing/keys stay POSIX.
        f.locale = Locale.current
        f.dateFormat = "EEEE, d MMMM"
        if let day = repo.today?.day, let date = Self.dayParser.date(from: day) {
            return f.string(from: date)
        }
        return f.string(from: Date())
    }

    /// A short recovery state word for the synthesis hero.
    private func synthesisWord(_ score: Double?) -> String {
        guard let s = score else { return String(localized: "No Data") }
        switch s {
        case ..<25:  return String(localized: "Depleted")
        case ..<50:  return String(localized: "Low")
        case ..<70:  return String(localized: "Steady")
        case ..<88:  return String(localized: "Primed")
        default:     return String(localized: "Peak")
        }
    }

    /// Plain-English synthesis of recovery + sleep.
    private func synthesisDetail(_ d: DailyMetric?) -> String {
        guard let d, let rec = d.recovery else {
            return String(localized: "No metrics yet. Import your Whoop export or wear the strap to begin.")
        }
        let recPart: String
        switch rec {
        case ..<50:  recPart = String(localized: "Recovery is low")
        case ..<70:  recPart = String(localized: "Recovery is steady")
        default:     recPart = String(localized: "Recovery is strong")
        }
        let sleepPart: String
        if let mins = d.totalSleepMin {
            let h = mins / 60.0
            sleepPart = h >= 7 ? String(localized: " and sleep was consistent") : String(localized: " but sleep ran short")
        } else {
            sleepPart = ""
        }
        return recPart + sleepPart + "."
    }

    private func ringSupporting(_ d: DailyMetric?) -> String {
        let hrv = d?.avgHrv.map { "\(Int($0.rounded())) ms" } ?? "— ms"
        let rhr = d?.restingHr.map { "\($0)" } ?? "—"
        return "HRV \(hrv) · RHR \(rhr)"
    }

    private func sleepValue(_ d: DailyMetric?) -> String {
        guard let m = d?.totalSleepMin else { return "—" }
        let h = Int(m) / 60, mm = Int(m) % 60
        return "\(h)h \(mm)m"
    }

    /// Active calories (Apple) for the latest day, falling back to the sparkline tail.
    private func caloriesValue(_ a: AppleDaily?) -> String {
        if let kcal = a?.activeKcal { return intString(kcal) }
        return latestString("active_kcal", decimals: 0)
    }

    private func workoutDuration(_ w: WorkoutRow) -> String {
        let secs = w.durationS ?? Double(max(w.endTs - w.startTs, 0))
        let mins = Int((secs / 60).rounded())
        if mins >= 60 { return "\(mins / 60)h \(mins % 60)m" }
        return "\(mins)m"
    }

    private func workoutCaption(_ w: WorkoutRow) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "d MMM"
        let date = f.string(from: Date(timeIntervalSince1970: TimeInterval(w.startTs)))
        if let hr = w.avgHr { return "\(date) · \(hr) bpm" }
        return date
    }

    /// Thousands-grouped integer string (steps / calories).
    private func intString(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(Int(v.rounded()))"
    }

    // MARK: - Date parsing (yyyy-MM-dd, en_US_POSIX, UTC)

    static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Local wall-clock time ("HH:mm") for the HR trend's x-axis / tooltip — the chart spans one day,
    /// so it must show times, not the day-granularity default ("EEE d MMM").
    static let hrTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - Morning journal prompt

/// Home-screen prompt to log yesterday's journal. Collapses to a "Journaled" confirmation
/// once today's morning log is done. Tapping opens the journal sheet via AppModel.journalRoute.
private struct MorningJournalCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var journal: JournalStore

    var body: some View {
        let done = journal.lastLoggedDay == Repository.localDayKey(Date())
        Button {
            model.journalRoute = JournalRoute(day: JournalView.yesterdayKey())
        } label: {
            NoopCard {
                HStack(spacing: NoopMetrics.gap) {
                    Image(systemName: done ? "checkmark.seal.fill" : "sun.max.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(done ? StrandPalette.accent : StrandPalette.statusWarning)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(done ? "Journaled" : "Good morning")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(done
                             ? "Yesterday's journal is logged."
                             : "How did yesterday go? Log your journal.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                    if !done {
                        Image(systemName: "chevron.right")
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Control Center") {
    let repo = Repository(deviceId: "preview")
    let cal = Calendar(identifier: .gregorian)
    let today = cal.startOfDay(for: Date())
    var sample: [DailyMetric] = []
    for i in stride(from: 39, through: 0, by: -1) {
        let date = cal.date(byAdding: .day, value: -i, to: today)!
        let day = Repository.dayString(date)
        let phase = Double(i)
        let rec = 48 + 34 * sin(phase / 5.0) + Double((i * 7) % 11)
        let strain = 8 + 7 * abs(sin(phase / 4.0))
        let total = 380 + 70 * sin(phase / 6.0)
        sample.append(DailyMetric(
            day: day, totalSleepMin: total, efficiency: 88 + 6 * sin(phase / 3.0),
            deepMin: 95, remMin: 110, lightMin: total - 200, disturbances: 4,
            restingHr: 50 + (i % 6), avgHrv: 58 + 16 * sin(phase / 4.0),
            recovery: min(max(rec, 8), 99), strain: strain, exerciseCount: i % 3,
            spo2Pct: 96, skinTempDevC: 33.4, respRateBpm: 14.6
        ))
    }
    repo.days = sample
    repo.loaded = true

    return TodayView()
        .environmentObject(repo)
        .frame(width: 920, height: 940)
        .preferredColorScheme(.dark)
}
#endif
