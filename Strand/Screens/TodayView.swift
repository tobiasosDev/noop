import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Home — "Today" (HomeCompact rewrite, spec 2026-06-10)
//
// WHOOP-style compact dashboard, iPhone-first (layout B of the design spec):
//   (1) triple-ring hero       — Sleep performance / Recovery / Day Strain, tappable
//   (2) live HR strip          — today's 5-min HR buckets + live bpm when connected
//   (3) monitor 2-up           — Readiness + Strain Coach, tap to expand detail inline
//   (4) goals chips            — one wrapping chip row, hidden with no goals
//   (5) My Day                 — today-only sleep + workout timeline (MyDay.activities)
//
// Relocated off Home: Key-Metrics tile grid (→ Trends/Explore), Data Sources footer
// (→ Data Sources screen), morning-journal card (→ toolbar sun icon), all-time workout
// grid (→ Workouts). Cold-start honesty notes stay. Only locked StrandDesign components.

struct TodayView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var goalStore: GoalStore

    @Environment(\.openScreen) private var openScreen
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var journal: JournalStore

    // Monitor-card inline disclosures.
    @State private var readinessExpanded = false
    @State private var strainExpanded = false

    // Strain Coach — intraday strain so far today (nil until ~10 min of HR exists).
    @State private var dayStrain: Double? = nil

    // Goals chips — steps series for the daily-steps goal evaluation.
    @State private var goalStepsByDay: [String: Double] = [:]

    @State private var workouts: [WorkoutRow] = []

    // Today's heart rate as 5-minute bucket means (midnight → now), for the HR strip.
    @State private var hrPoints: [TrendPoint] = []

    // Support sheet (donate + contact) — always reachable from the home toolbar.
    @State private var showingSupport = false

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

    var body: some View {
        ScreenScaffold(title: "Today", subtitle: "\(dateLine)") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                HealthAlertBanner()
                if repo.today?.recovery == nil {
                    // While the strap is mid-offload, say so — empty tiles read as final otherwise (#77).
                    if live.backfilling { SyncingHistoryNote(chunks: live.syncChunksThisSession) }
                    DataPendingNote(
                        title: "Live now. Your scores are building.",
                        message: "Your live heart rate is working from the strap, and charge, effort and rest build from it over your next few nights of wear, sharpening as it learns your baseline. Want your full history instantly? Import your WHOOP export in Data Sources and it backfills in about a minute."
                    )
                }
                ringsSection
                heartRateStrip
                monitorSection
                goalsSection
                myDaySection
                // Honest, dismissible 12-hourly donation ask — a card in the flow, never a modal.
                DonationNudgeCard()
            }
        } trailing: {
            HStack(spacing: 14) {
                batteryPill
                journalButton
                Button { showingSupport = true } label: {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(StrandPalette.metricRose)
                }
                .buttonStyle(.plain)
                .help("Support NOOP — donate or get in touch")
                .accessibilityLabel("Support NOOP — donate or get in touch")
            }
        }
        .task(id: repo.refreshSeq) { await loadAll() }
        .overlay {
            if showingSupport {
                SupportModalOverlay(isPresented: $showingSupport)
            }
        }
        .animation(.easeOut(duration: 0.18), value: showingSupport)
    }

    /// Strap battery, only while connected — mirrors the WHOOP top-bar pill.
    @ViewBuilder
    private var batteryPill: some View {
        if live.connected, let pct = live.batteryPct {
            HStack(spacing: 4) {
                Image(systemName: live.charging == true ? "bolt.fill" : "applewatch")
                    .font(.system(size: 11))
                Text(verbatim: "\(Int(pct))%")
                    .font(StrandFont.captionNumber)
            }
            .foregroundStyle(pct <= 15 ? StrandPalette.statusWarning : StrandPalette.textSecondary)
            .accessibilityLabel("Strap battery \(Int(pct)) percent")
        }
    }

    /// Morning journal moved off the card stack: a sun icon that wiggles until
    /// yesterday is logged, then turns into a quiet checkmark entry point.
    private var journalButton: some View {
        let done = journal.lastLoggedDay == Repository.localDayKey(Date())
        return Button {
            model.journalRoute = JournalRoute(day: JournalView.yesterdayKey())
        } label: {
            if done {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(StrandPalette.accent)
            } else {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(StrandPalette.statusWarning)
                    .attentionWiggle(period: 4)
            }
        }
        .buttonStyle(.plain)
        .help(done ? "Open yesterday's journal" : "Log yesterday's journal")
        .accessibilityLabel(done ? "Open yesterday's journal" : "Log yesterday's journal")
    }

    // MARK: (1) Triple-ring hero — Sleep / Recovery / Strain.

    /// Sleep performance for the sleep ring: personal need from the last 30 nights vs
    /// tonight's sleep. nil (empty ring) when tonight has no sleep yet.
    private var sleepPerformance: Double? {
        let need = SleepNeed.needMin(
            totalSleepMinsByNight: repo.days.suffix(30).compactMap(\.totalSleepMin))
        return SleepNeed.performancePct(needMin: need, asleepMin: repo.today?.totalSleepMin)
    }

    private var ringsSection: some View {
        let d = repo.today
        let recovery = d?.recovery
        let strain = dayStrain ?? d?.strain
        return NoopCard {
            HStack(alignment: .top, spacing: NoopMetrics.gap) {
                ringButton(.sleep) {
                    MiniRing(
                        label: "Sleep",
                        value: sleepPerformance.map { "\(Int($0.rounded()))%" } ?? "—",
                        progress: sleepPerformance.map { $0 / 100 },
                        gradient: Gradient(colors: [StrandPalette.metricPurple.opacity(0.55),
                                                    StrandPalette.metricPurple]),
                        diameter: 86
                    )
                }
                ringButton(.insights) {
                    MiniRing(
                        label: "Recovery",
                        value: recovery.map { "\(Int($0.rounded()))%" }
                            ?? recoveryCalibration.map { "\($0)/\(Baselines.minNightsSeed)" } ?? "—",
                        progress: recovery.map { $0 / 100 },
                        gradient: Gradient(colors: [
                            (recovery.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.accent).opacity(0.55),
                            recovery.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.accent,
                        ]),
                        caption: recovery == nil && recoveryCalibration != nil ? "calibrating" : nil,
                        diameter: 86
                    )
                }
                ringButton(.workouts) {
                    MiniRing(
                        label: "Strain",
                        value: strain.map { String(format: "%.1f", $0) } ?? "—",
                        progress: strain.map { $0 / 21 },
                        gradient: StrandPalette.strainGradient,
                        caption: "of 21",
                        diameter: 86
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func ringButton<R: View>(_ dest: HomeDestination, @ViewBuilder ring: () -> R) -> some View {
        Button { openScreen(dest) } label: { ring() }
            .buttonStyle(.plain)
    }

    // MARK: (2) Live HR strip — today's continuous HR + live bpm.

    @ViewBuilder
    private var heartRateStrip: some View {
        if hrPoints.count > 1 {
            let v = hrPoints.map(\.value)
            ChartCard(
                title: "Heart Rate",
                subtitle: liveSubtitle,
                trailing: hrTrailing(v),
                height: 72
            ) {
                TrendChart(
                    points: hrPoints,
                    gradient: Gradient(colors: [StrandPalette.metricRose.opacity(0.55), StrandPalette.metricRose]),
                    valueRange: hrRange(v),
                    showsArea: true,
                    height: 72,
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

    /// "live" while the strap streams; otherwise an honest provenance note.
    private var liveSubtitle: String {
        live.connected ? String(localized: "Today · live")
                       : String(localized: "Today · last synced")
    }

    private func hrTrailing(_ v: [Double]) -> String? {
        if live.connected, let bpm = live.heartRate { return "● \(bpm) bpm" }
        return v.last.map { "\(Int($0.rounded())) bpm" }
    }

    /// Padded HR axis range so the line never sits flush against an edge (mirrors MetricExplorer.valueRange).
    private func hrRange(_ v: [Double]) -> ClosedRange<Double> {
        guard let lo = v.min(), let hi = v.max() else { return 40...120 }
        if hi <= lo { return (lo - 5)...(hi + 5) }
        let span = hi - lo
        return (lo - span * 0.12)...(hi + span * 0.12)
    }

    // MARK: (3) Monitor 2-up — Readiness + Strain Coach, expandable in place.

    private var monitorSection: some View {
        // Logical-day anchor (rolls at 04:00, #144) so the small hours after midnight still read
        // yesterday's row rather than an empty new-calendar-day one. Adopted from upstream's
        // readiness section (v2.6 logicalDay rollover).
        let r = ReadinessEngine.evaluate(days: repo.days, today: Repository.logicalDayKey(Date()))
        let hasReadiness = r.level != .insufficient
        // Wide canvas: side by side. Compact: stacked full-width.
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: NoopMetrics.gap) {
                if hasReadiness { readinessCard(r) }
                strainCoachCard
            }
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                if hasReadiness { readinessCard(r) }
                strainCoachCard
            }
        }
    }

    private func readinessCard(_ r: ReadinessEngine.Readiness) -> some View {
        Button { withAnimation(.easeOut(duration: 0.18)) { readinessExpanded.toggle() } } label: {
            NoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Readiness").strandOverline()
                        Spacer()
                        Image(systemName: readinessExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    HStack(spacing: 8) {
                        Circle().fill(readinessColor(r.level)).frame(width: 9, height: 9)
                        Text(r.headline).font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(readinessExpanded ? nil : 1)
                    }
                    if let acwr = r.acwr {
                        Text("load \(String(format: "%.2f", acwr))")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    if readinessExpanded {
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private var strainCoachCard: some View {
        Button { withAnimation(.easeOut(duration: 0.18)) { strainExpanded.toggle() } } label: {
            NoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Strain Coach").strandOverline()
                        Spacer()
                        Image(systemName: strainExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    if let recovery = repo.today?.recovery {
                        let band = StrainTarget.band(recovery: recovery)
                        let current = dayStrain ?? 0
                        Text("Aim \(band.low, specifier: "%.1f")–\(band.high, specifier: "%.1f")")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        if dayStrain == nil {
                            Text("Building — needs about 10 minutes of heart-rate data.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            let state = band.state(currentStrain: current)
                            Text(strainCoachStateLine(state, current: current))
                                .font(StrandFont.caption)
                                .foregroundStyle(strainCoachStateColor(state))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if strainExpanded {
                            Divider().overlay(StrandPalette.hairline)
                            HStack {
                                Spacer()
                                strainCoachGauge(current: current)
                                Spacer()
                            }
                            if !live.connected, dayStrain != nil {
                                Text("Strap not connected — showing the last synced value.")
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else {
                        Text("No recovery yet today — your strain target appears once last night is scored.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
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

    /// Pre-formatted so the catalog key carries a stable %@ for the one-decimal strain value.
    private func strainCoachStateLine(_ s: StrainTarget.State, current: Double) -> String {
        let v = String(format: "%.1f", current)
        switch s {
        case .building:     return String(localized: "\(v) now — room to push today.")
        case .onTarget:     return String(localized: "\(v) now — right in your target band.")
        case .overreaching: return String(localized: "\(v) now — beyond today's recommendation.")
        }
    }

    private func strainCoachStateColor(_ s: StrainTarget.State) -> Color {
        switch s {
        case .building:     return StrandPalette.textSecondary
        case .onTarget:     return StrandPalette.accent
        case .overreaching: return StrandPalette.statusWarning
        }
    }

    // MARK: (4) Goals — one wrapping chip row. Hidden with no goals.

    @ViewBuilder
    private var goalsSection: some View {
        if !goalStore.goals.isEmpty {
            let weekDays = goalWeekDays()
            NoopCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Goals — Today").strandOverline()
                    WrapLayout(spacing: 8) {
                        ForEach(goalStore.goals, id: \.id) { goal in
                            if let kind = GoalProgress.Kind(rawValue: goal.kind) {
                                goalChip(goal: goal, kind: kind, weekDays: weekDays)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func goalChip(goal: GoalRow, kind: GoalProgress.Kind, weekDays: [String]) -> some View {
        let p = GoalProgress.evaluate(
            kind: kind, target: goal.target,
            values: kind.weekValues(days: repo.days, stepsByDay: goalStepsByDay, weekDays: weekDays),
            weekDays: weekDays)
        return HStack(spacing: 6) {
            Circle().fill(goalChipColor(p, kind: kind)).frame(width: 6, height: 6)
            Text(kind.displayTitle).font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(goalChipStatus(p, kind: kind)).font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(StrandPalette.surfaceInset, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
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

    // MARK: (5) My Day — today-only sleep + workout timeline.

    private var myDaySection: some View {
        let acts = MyDay.activities(sleeps: repo.sleeps, workouts: workouts)
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("My Day", overline: "Today's activities")
            NoopCard {
                if acts.isEmpty {
                    Text("Nothing logged yet today.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(acts.enumerated()), id: \.offset) { i, act in
                            activityRow(act)
                            if i < acts.count - 1 { Divider().overlay(StrandPalette.hairline) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func activityRow(_ act: MyDay.Activity) -> some View {
        switch act {
        case .sleep(let s):
            Button { openScreen(.sleep) } label: {
                activityRowBody(
                    badge: sleepDurationLabel(s),
                    badgeTint: StrandPalette.metricPurple,
                    icon: "moon.fill",
                    name: Text("Sleep"),
                    start: s.startTs, end: s.endTs
                )
            }
            .buttonStyle(.plain)
        case .workout(let w):
            Button { openScreen(.workouts) } label: {
                activityRowBody(
                    badge: w.strain.map { String(format: "%.1f", $0) } ?? workoutDuration(w),
                    badgeTint: StrandPalette.strainColor(w.strain ?? 0),
                    icon: "bolt.fill",
                    name: Text(verbatim: w.sport.capitalized),
                    start: w.startTs, end: w.endTs
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// `name` is a prebuilt Text: localized UI copy for sleep ("Sleep"), verbatim for
    /// workout sport names — those are data-model strings, never localization keys.
    private func activityRowBody(badge: String, badgeTint: Color, icon: String,
                                 name: Text, start: Int, end: Int) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(badge).font(StrandFont.captionNumber)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(badgeTint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(badgeTint)
            name
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(Self.clockFmt.string(from: Date(timeIntervalSince1970: TimeInterval(start))))
                Text(Self.clockFmt.string(from: Date(timeIntervalSince1970: TimeInterval(end))))
            }
            .font(StrandFont.captionNumber)
            .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "7h 12m" — duration asleep for the sleep badge (matches workoutDuration's format).
    private func sleepDurationLabel(_ s: CachedSleepSession) -> String {
        let mins = max(0, s.endTs - s.startTs) / 60
        if mins >= 60 { return "\(mins / 60)h \(mins % 60)m" }
        return "\(mins)m"
    }

    // MARK: - Loading

    private func loadAll() async {
        workouts = await repo.workoutRows()

        // Today's HR trend — 5-minute bucket means from the LOGICAL day's local midnight → now. The
        // logical day rolls at 04:00 (Repository.logicalDayStart), so in the small hours after midnight
        // the window still starts at yesterday's midnight and the chart keeps the evening's curve rather
        // than blanking to an empty new-calendar-day axis (#144).
        let startOfToday = Int(Repository.logicalDayStart(Date()).timeIntervalSince1970)
        let nowTs = Int(Date().timeIntervalSince1970)
        hrPoints = await repo.hrBuckets(from: startOfToday, to: nowTs, bucketSeconds: 300)
            .map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }

        // Strain Coach + strain ring — intraday strain from today's raw HR.
        dayStrain = await DayStrain.compute(repo: repo, hrMax: profile.hrMax,
                                            sex: profile.sex,
                                            restingHr: repo.today?.restingHr)

        // Goals chips — current week only (+2 days timezone slack).
        await goalStore.load()
        goalStepsByDay = Dictionary(
            await repo.series(key: "steps", source: "apple-health", days: 9).map { ($0.day, $0.value) },
            uniquingKeysWith: { _, new in new })
    }

    // MARK: - Derived text

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

    private func workoutDuration(_ w: WorkoutRow) -> String {
        let secs = w.durationS ?? Double(max(w.endTs - w.startTs, 0))
        let mins = Int((secs / 60).rounded())
        if mins >= 60 { return "\(mins / 60)h \(mins % 60)m" }
        return "\(mins)m"
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
    /// so it must show times, not the day-granularity default ("EEE d MMM"). Also formats the
    /// workout-tile caption's time range (#157).
    static let hrTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Locale-aware wall-clock time for activity start/end labels (respects 12/24h).
    static let clockFmt: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}

// MARK: - Preview

#if DEBUG
#Preview("Today") {
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
