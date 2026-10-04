import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Coupled view (task #43), the optional classic coupled day read
//
// An optional, default-OFF day view that reads like the classic coupled home: one screen, three numbers,
// Recovery % / Day Strain on 0–21 / Sleep, for users who came across from another band and want the old
// glance back. NOOP's Today stays the default and is untouched.
//
// DISPLAY-ONLY, like the #268 Effort-scale toggle. This screen invents no score and stores nothing: it
// reads the SAME values Today already computes (recovery / Rest composite / Effort strain / readiness) and
// re-presents them in the coupled layout. The only new mapping is the OPTIMAL strain band, a pure
// display-only read of today's recovery to a suggested strain range (never fed back into scoring).
//
// v2: recovery is the hero (a ring in the Charge glow), Day Strain sits on a 0–21 track against the
// optimal band, and sleep performance reads slept against needed — all neutral cards under one glow. The
// word "WHOOP" appears in NO shipped UI string here (legal posture); the screen is called "Coupled view".
//
// Tap-throughs, matching the sibling screens' deep-link/back behaviour: the hero ring opens the Charge
// breakdown ("What shaped it", the same shared ChargeBreakdownSection content the Today ring opens, hosted
// here because TodayView's own sheet is view-private); the sleep row pushes the Sleep screen.

struct CoupledView: View {
    @EnvironmentObject var repo: Repository

    // Effort is stored 0–100; the coupled read is always the 0–21 Day-Strain axis regardless of the user's
    // #268 display toggle, so the gauge reads like the classic coupled home. Display-only conversion.
    private let strainScale: EffortScale = .whoop

    /// The Charge breakdown sheet, the hero ring's tap target. Its body builds LAZILY on presentation
    /// (the #819 pattern), reading drivers derived from the same displayed row the ring shows.
    @State private var showChargeBreakdown = false

    /// The learned habitual midsleep (local time-of-day seconds), loaded once so the bed→wake span
    /// resolves the SAME main-night pick the Sleep tab hero and the daily total use (#294). nil under
    /// the cold-start threshold, which keeps the broad overnight-band bonus.
    @State private var habitualMidsleepSec: Int? = nil

    /// Today's all-source workout count materialized onto the same physiological cycle as the other cards.
    @State private var workoutsToday: Int = 0

    init() {}

    #if DEBUG
    /// DEBUG screenshot harness: raise the Charge breakdown sheet as soon as the screen appears.
    private var demoOpensBreakdown = false

    init(demoOpensBreakdown: Bool) { self.demoOpensBreakdown = demoOpensBreakdown }
    #endif

    /// The day the coupled read describes, today's resolved row (the same `resolveToday` #304/#144 boundary
    /// Today anchors on), never a second store read.
    private var day: DailyMetric? { repo.today }

    /// Today's day key, tracking the resolved row when one exists (the Today idiom).
    private var todayKey: String { day?.day ?? Repository.logicalDayKey(Date()) }

    /// Recovery cold-start: nights banked so far while the HRV baseline still seeds, nil once recovery
    /// exists. The SAME pure helper Today's ring reads, so the two screens can't disagree.
    private var calibrationNights: Int? {
        RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv),
                                         dayKeys: repo.days.map(\.day),
                                         hasRecovery: day?.recovery != nil)
    }

    /// The last strictly-prior scored recovery day, so a just-rolled-over morning carries yesterday's read
    /// rather than blanking, exactly the anchor Today uses for readiness (#543).
    ///
    /// #1458: through the SAME selector Today uses, not a local re-derivation. This read
    /// `repo.days.last(where: { $0.recovery != nil && $0.day < todayKey })`, which has no `todayScored`
    /// guard — so on a day that HAS a score it still returned a prior day, and the hero's Charge sheet
    /// opened that older night while the card beside it showed today's number. It also skipped the
    /// calibrating gate, so a cold-start install could carry a value Today refuses. Reported on Android,
    /// but the defect was identical here: the twins agreed with each other and were both wrong.
    private var carriedRecoveryDay: DailyMetric? {
        TodayView.lastScoredRecoveryDay(
            days: repo.days, selectedDayKey: todayKey,
            isToday: true,   // the Coupled view has no day selector; it is always today
            todayScored: day?.recovery != nil,
            isCalibrating: calibrationNights != nil)
    }

    /// The recovery value the ring shows: today's if scored, else the carried prior day's (never fabricated).
    private var recovery: Double? { day?.recovery ?? carriedRecoveryDay?.recovery }

    /// True when the hero is showing the CARRIED prior score rather than today's own, which drives the
    /// dimmed ring + the "Last night · <date>" stamp so an old number is never passed off as new (#543/#779).
    private var isCarryingRecovery: Bool { day?.recovery == nil && carriedRecoveryDay?.recovery != nil }

    /// Effort strain on NOOP's 0–100 axis for the day (stored row; no live recompute here, this is a
    /// glance screen, not the primary Today hero). nil when the day has no scored Effort.
    private var strain100: Double? { day?.strain }

    /// Day strain mapped onto the 0–21 coupled axis via the SHIPPED formatter (UnitFormatter.effortValue),
    /// so the number matches every other Effort read-out's conversion factor exactly.
    private var dayStrain21: Double? { strain100.map { UnitFormatter.effortValue($0, scale: strainScale) } }

    /// Sleep performance % for the day, the SAME single source of truth the Today Rest score and the Sleep
    /// detail graph read: the imported figure when the export carried one, else the resolved Rest composite.
    /// Never a local hours-vs-need approximation (keeps the coupled read in agreement with Today's Rest).
    private var sleepPerformance: Double? {
        guard let d = day else { return nil }
        if let p = repo.importedSleep[d.day]?.performancePct { return p }
        return AnalyticsEngine.Rest.composite(daily: d)
    }

    /// On-device readiness, computed EXACTLY as Today does (ReadinessEngine.evaluate over the same rows,
    /// anchored on the last scored day ONLY when carrying), so the one-word pill matches the home screen's
    /// read. The carried anchor is gated on `isCarryingRecovery` (Today's `!todayScored` gate): on a normal
    /// scored day today's own key wins, so Coupled's pill can't diverge from Today's onto yesterday (#787).
    private var readiness: ReadinessEngine.Readiness {
        let anchor = (isCarryingRecovery ? carriedRecoveryDay?.day : day?.day) ?? Repository.logicalDayKey(Date())
        return ReadinessEngine.evaluate(days: repo.days, today: anchor)
    }

    var body: some View {
        // CoupledView is pushed from Today's card row. On iOS each tab supplies a NavigationStack, so the
        // sleep-row + breakdown pushes land in the ambient stack. On macOS this can render as a detail pane
        // with NO enclosing NavigationStack, so — exactly like MetricExplorerView / TrendsView (#753) —
        // wrap the scaffold in one here so the pushes get Back chrome instead of hanging. Same shared
        // scaffold renders on both.
        #if os(macOS)
        NavigationStack { scaffold }
        #else
        scaffold
        #endif
    }

    private var scaffold: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                NoopScreenHeader("Day") {
                    // The coupled read is always today; the pill names the day it describes.
                    NoopPill("Today")
                }
                heroCard
                    .padding(.top, 18)
                NoopSectionTitle("Day Strain · Effort", captionKey: "0-21 scale", topPadding: 30)
                    .padding(.bottom, 12)
                strainCard
                NoopSectionTitle("Sleep performance", captionKey: "Last night", topPadding: 30)
                    .padding(.bottom, 12)
                sleepCard
                breakdownRow_
                    .padding(.top, 12)
                footerCaption
                    .padding(.top, 20)
            }
            .padding(.horizontal, NoopMetrics.screenHPadding)
            .padding(.top, 6)
            .padding(.bottom, NoopMetrics.tabBarClearance)
            #if os(macOS)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            #endif
        }
        #if os(iOS)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        #if os(iOS) && DEBUG
        .modifier(DemoScrollAnchor())
        #endif
        .background(NoopVisualStyle.canvas.ignoresSafeArea())
        // The v2 header above names the screen; the system title only labels the macOS window bar.
        #if os(macOS)
        .navigationTitle("Day")
        #endif
        .noopHidesSystemNavBar()
        .sheet(isPresented: $showChargeBreakdown) { chargeBreakdownSheet }
        #if DEBUG
        .onAppear { if demoOpensBreakdown { showChargeBreakdown = true } }
        #endif
        // Loads the SAME learned habitual the Sleep tab hero threads into its main-night pick, so the
        // bed→wake span below resolves identically (#294). Re-runs on a sync/import refresh.
        .task(id: repo.refreshSeq) {
            habitualMidsleepSec = await repo.habitualMidsleepSec()
            workoutsToday = day?.exerciseCount ?? 0
        }
    }

    // MARK: 1. HERO, the recovery ring, coupled read (tap = the Charge breakdown)

    /// The recovery read in the Charge glow: a ring filled clockwise from the top to the recovery %, the number in
    /// dot matrix at its centre with "= Charge · readiness" under it, and one sentence. The whole hero
    /// opens the Charge breakdown, mirroring Today's Charge tap (A1).
    private var heroCard: some View {
        Button {
            showChargeBreakdown = true
        } label: {
            NoopHeroCard(glow: NoopGlow.charge(recovery), padding: 0) {
                VStack(spacing: 0) {
                    HStack {
                        NoopIconBadge("Recovery", icon: "lightning")
                        Spacer(minLength: 8)
                        NoopPill("Coupled read", compact: true)
                    }
                    ZStack {
                        G1bProgressRing(fraction: (recovery ?? 0) / 100,
                                        tint: NoopGlow.charge(recovery).accent, diameter: 200)
                            .opacity(isCarryingRecovery ? 0.85 : 1)
                        VStack(spacing: 10) {
                            NoopDotNumber(recovery.map { "\(Int($0.rounded()))" } ?? "–",
                                          unit: recovery == nil ? nil : "%", size: 88, unitSize: 38)
                                .fixedSize()
                                .padding(.vertical, -5)
                            if let line = heroSubline {
                                Text(verbatim: line)
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(Color.white.opacity(0.62))
                            }
                        }
                    }
                    .frame(width: 224, height: 224)
                    .padding(.top, 18)
                    heroCaption
                        .padding(.top, 8)
                    if let sentence = heroSentence {
                        Text(verbatim: sentence)
                            .font(StrandFont.light(14))
                            .foregroundStyle(Color.white.opacity(0.84))
                            .multilineTextAlignment(.center)
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 16)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
                .padding(.horizontal, 22)
                .padding(.bottom, 24)
            }
            .contentShape(RoundedRectangle(cornerRadius: NoopVisualStyle.heroRadius, style: .continuous))
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(heroAccessibilityLabel)
        .accessibilityHint("See what shaped your Charge")
    }

    /// "= Charge 78 · Push" — the same number under its NOOP name, with the one-word readiness read.
    private var heroSubline: String? {
        guard let r = recovery else { return nil }
        let charge = String(localized: "= Charge \(Int(r.rounded()))")
        guard let word = TodayView.readinessWord(readiness.level) else { return charge }
        return "\(charge) · \(word)"
    }

    /// "Green day. HRV 68 ms, resting HR 52 bpm." — the band and the two overnight vitals behind it. The
    /// "good side of your baseline" clause is added only when the readiness engine flags BOTH signals as
    /// good against the personal baseline, so the sentence never claims more than the scorer saw.
    private var heroSentence: String? {
        guard let r = recovery else { return nil }
        // Named from the hero's own glow band, so the sentence and the ring colour above it agree.
        let band: String
        switch NoopGlow.charge(r) {
        case .recovery: band = String(localized: "Green day.")
        case .moderate: band = String(localized: "Yellow day.")
        default: band = String(localized: "Red day.")
        }
        let row = isCarryingRecovery ? carriedRecoveryDay : day
        guard let hrv = row?.avgHrv, let rhr = row?.restingHr else { return band }
        let signals = readiness.signals
        let bothGood = signals.first { $0.key == "hrv" }?.flag == .good
            && signals.first { $0.key == "rhr" }?.flag == .good
        if bothGood {
            return band + " " + String(localized: "HRV \(Int(hrv.rounded())) ms and resting HR \(rhr) bpm both sit on the good side of your baseline.")
        }
        return band + " " + String(localized: "HRV \(Int(hrv.rounded())) ms, resting HR \(rhr) bpm.")
    }

    /// The honest state line under the ring: the "Last night · <date>" stamp when carrying a prior score
    /// (#543/#779, via the SAME pure caption Today uses), or the calibrating progress while the baseline
    /// seeds. Nothing when today's own score is showing.
    @ViewBuilder
    private var heroCaption: some View {
        if isCarryingRecovery, let prior = carriedRecoveryDay {
            Text(TodayView.carriedCaption(priorDayKey: prior.day, todayKey: todayKey))
                .font(StrandFont.footnote)
                .foregroundStyle(Color.white.opacity(0.62))
        } else if recovery == nil, let banked = calibrationNights {
            Text(ChargeBreakdownFormat.calibrationProgress(banked: banked, seed: Baselines.minNightsSeed))
                .font(StrandFont.footnote)
                .foregroundStyle(Color.white.opacity(0.62))
        }
    }

    private var heroAccessibilityLabel: String {
        if let r = recovery { return String(localized: "Recovery \(Int(r.rounded())) percent") }
        if let banked = calibrationNights {
            return String(localized: "Recovery calibrating, \(banked) of \(Baselines.minNightsSeed) nights")
        }
        return String(localized: "Recovery, no data yet")
    }

    // MARK: 2. STRAIN, the day's strain on the 0–21 axis against the optimal band

    private var strainCard: some View {
        let band = Self.optimalStrainRange(recovery: recovery)
        return NoopCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom, spacing: 12) {
                    NoopDotNumber(dayStrain21.map { String(format: "%.1f", locale: AppLanguage.activeLocale, $0) } ?? "–",
                                  size: 50)
                        .fixedSize()
                        .padding(.bottom, -4)   // the kit's 0.9 line height for dot numbers
                    Text("of 21")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.bottom, 6)
                    Spacer(minLength: 8)
                    if let s = strain100 {
                        Text(verbatim: String(localized: "≈ Effort \(Int(s.rounded()))"))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .padding(.bottom, 6)
                    }
                }
                strainTrack(band: band)
                    .padding(.top, 30)
                strainScaleLabels(band: band)
                    .padding(.top, 14)
                if let line = optimalLine(band: band) {
                    Text(verbatim: line)
                        .font(StrandFont.light(13))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                }
                Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
                    .padding(.top, 16)
                NoopMetricRow {
                    NoopMetric(value: day?.activeKcalEst.map { Int($0.rounded()).formatted(.number.locale(AppLanguage.activeLocale)) } ?? "—",
                               unit: day?.activeKcalEst == nil ? nil : "kcal",
                               labelText: String(localized: "Active calories"))
                    NoopMetric(value: "\(workoutsToday)", labelText: String(localized: "Workouts"))
                    NoopMetric(value: day?.steps.map { $0.formatted(.number.locale(AppLanguage.activeLocale)) } ?? "—",
                               labelText: String(localized: "Steps"))
                }
                .padding(.top, 16)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(strainAccessibilityLabel)
    }

    /// The 0–21 track with the day's fill, and — when there is a recovery to read a band from — the
    /// dashed OPTIMAL window around the band with its tag floating above it.
    private func strainTrack(band: ClosedRange<Int>?) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                NoopTrack(fraction: (dayStrain21 ?? 0) / 21, height: 10)
                if let band {
                    let lo = w * CGFloat(band.lowerBound) / 21
                    let hi = w * CGFloat(band.upperBound) / 21
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: max(8, hi - lo), height: 22)
                        .offset(x: lo, y: -6)
                    NoopTag("OPTIMAL", size: 11)
                        .fixedSize()
                        .position(x: (lo + hi) / 2, y: -20)
                }
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    /// 0 · 7 · 14 · 21 under the track plus the band's edges, with the day's value in ink at its own
    /// position. A scale number that would collide with the value label steps aside for it.
    private func strainScaleLabels(band: ClosedRange<Int>?) -> some View {
        var ticks = Set([0, 7, 14, 21])
        if let band { ticks.formUnion([band.lowerBound, band.upperBound]) }
        let shown = ticks.sorted().filter { v in dayStrain21.map { abs(Double(v) - $0) >= 1.6 } ?? true }
        return GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                ForEach(shown, id: \.self) { v in
                    label("\(v)", at: Double(v) / 21, width: w, ink: false)
                }
                if let s = dayStrain21 {
                    label(String(format: "%.1f", locale: AppLanguage.activeLocale, s), at: s / 21, width: w, ink: true)
                }
            }
        }
        .frame(height: 14)
    }

    private func label(_ text: String, at fraction: Double, width: CGFloat, ink: Bool) -> some View {
        let anchor: CGFloat = fraction <= 0 ? 0 : (fraction >= 1 ? 1 : 0.5)
        return Text(verbatim: text)
            .font(ink ? StrandFont.book(11) : StrandFont.footnote)
            .foregroundStyle(ink ? StrandPalette.textPrimary : StrandPalette.textTertiary)
            .fixedSize()
            .alignmentGuide(.leading) { d in d.width * anchor - width * CGFloat(min(max(fraction, 0), 1)) }
    }

    /// "Optimal for a 78 % recovery is 14 to 18. You are 2.7 short." — the approved band, and where the
    /// day's strain sits against it.
    private func optimalLine(band: ClosedRange<Int>?) -> String? {
        guard let band, let r = recovery else { return nil }
        let head = String(localized: "Optimal for a \(Int(r.rounded())) % recovery is \(Self.optimalStrainRangeText(recovery: r)).")
        guard let s = dayStrain21 else { return head }
        let fmt: (Double) -> String = { String(format: "%.1f", locale: AppLanguage.activeLocale, $0) }
        if s < Double(band.lowerBound) {
            return head + " " + String(localized: "You are \(fmt(Double(band.lowerBound) - s)) short.")
        }
        if s > Double(band.upperBound) {
            return head + " " + String(localized: "You are \(fmt(s - Double(band.upperBound))) over.")
        }
        return head + " " + String(localized: "You are inside it.")
    }

    private var strainAccessibilityLabel: String {
        guard let s = dayStrain21 else { return String(localized: "Day strain, no data yet") }
        return String(localized: "Day strain \(String(format: "%.1f", s)) of 21")
    }

    // MARK: 3. SLEEP, performance + slept vs needed (tap = Sleep)

    private var sleepCard: some View {
        NavigationLink {
            SleepView()
        } label: {
            NoopCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .bottom, spacing: 12) {
                        NoopDotNumber(sleepPerformance.map { "\(Int($0.rounded()))" } ?? "–", size: 50)
                            .fixedSize()
                            .padding(.bottom, -4)   // the kit's 0.9 line height for dot numbers
                        if sleepPerformance != nil {
                            NoopDotNumber("%", size: 24)
                                .fixedSize()
                                .padding(.bottom, 4)
                        }
                        Spacer(minLength: 8)
                        if let p = sleepPerformance {
                            // The same night under its NOOP name, as the hero's "= Charge" line does.
                            Text(verbatim: String(localized: "Rest \(Int(p.rounded())) · \(sleepWord(p))"))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .padding(.bottom, 6)
                        }
                    }
                    if let asleep = day?.totalSleepMin, asleep > 0 {
                        let need = sleepNeedForDay
                        let top = max(asleep, need, 1)
                        sleepBar(String(localized: "Slept"), minutes: asleep, fraction: asleep / top, filled: true)
                            .padding(.top, 18)
                        sleepBar(String(localized: "Needed"), minutes: need, fraction: need / top, filled: false)
                            .padding(.top, 12)
                    } else {
                        Text("No sleep tracked last night")
                            .font(StrandFont.light(13))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .padding(.top, 16)
                    }
                    if let span = bedWakeSpanText {
                        Text(verbatim: String(localized: "In bed \(span)"))
                            .font(StrandFont.light(13))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .padding(.top, 16)
                    }
                    Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
                        .padding(.top, 16)
                    NoopMetricRow {
                        NoopMetric(value: sleepDebtMetric?.value ?? "—", unit: sleepDebtMetric?.unit,
                                   labelText: String(localized: "Short of need"))
                        NoopMetric(value: day?.efficiency.map { "\(Int($0.rounded()))" } ?? "—",
                                   unit: day?.efficiency == nil ? nil : "%",
                                   labelText: String(localized: "Efficiency"))
                        NoopMetric(value: day?.disturbances.map { "\($0)" } ?? "—",
                                   labelText: String(localized: "Disturbances"))
                    }
                    .padding(.top, 16)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sleepAccessibilityLabel)
        .accessibilityHint("Open Sleep")
    }

    private func sleepBar(_ label: String, minutes: Double, fraction: Double, filled: Bool) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: label)
                .font(StrandFont.light(12))
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 62, alignment: .leading)
            NoopTrack(fraction: fraction, height: 10,
                      fill: filled ? [Color(hex: "#3C56D8"), Color(hex: "#6F87FF")]
                                   : [Color(light: "#C8C7C3", dark: "#3A3A40"), Color(light: "#C8C7C3", dark: "#3A3A40")])
            Text(verbatim: Self.hoursMinutes(minutes))
                .font(StrandFont.value(13))
                .foregroundStyle(filled ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 52, alignment: .trailing)
        }
    }

    /// The Sleep tab's Rest words, so the two screens name the same night the same way.
    private func sleepWord(_ score: Double) -> String {
        switch score {
        case ..<50:  return String(localized: "Poor")
        case ..<70:  return String(localized: "Fair")
        case ..<85:  return String(localized: "Good")
        default:     return String(localized: "Optimal")
        }
    }

    /// How far last night fell short of the need (0 when it met it), nil when there is no night. Under an
    /// hour it reads as a bare minute count with a "min" unit, as the metric row's other values carry units.
    private var sleepDebtMetric: (value: String, unit: String?)? {
        guard let asleep = day?.totalSleepMin, asleep > 0 else { return nil }
        let short = Swift.max(0, sleepNeedForDay - asleep)
        if short.rounded() < 60 { return ("\(Int(short.rounded()))", String(localized: "min")) }
        return (Self.hoursMinutes(short), nil)
    }

    /// A row opening the Charge breakdown — the method and today's drivers in one sheet.
    private var breakdownRow_: some View {
        Button { showChargeBreakdown = true } label: {
            NoopList {
                NoopRow("How Charge is calculated", caption: "HRV, resting HR, breathing and sleep",
                        icon: "calculator", chevron: true) { EmptyView() }
            }
        }
        .buttonStyle(LiquidPressStyle())
    }

    private var sleepAccessibilityLabel: String {
        guard let p = sleepPerformance else { return String(localized: "Sleep performance not available") }
        if let asleep = day?.totalSleepMin, asleep > 0 {
            return String(localized: "Sleep performance \(Int(p.rounded())) percent. \(Self.hoursMinutes(asleep)) slept, \(Self.hoursMinutes(sleepNeedForDay)) needed")
        }
        return String(localized: "Sleep performance \(Int(p.rounded())) percent")
    }

    /// The night's need (minutes) for the slept-vs-needed read: the imported per-day figure when the
    /// export carried one, else the shared ≥ 7.5h personal-mean floor (matches SleepView.sleepNeedMin).
    private var sleepNeedForDay: Double {
        if let need = day.flatMap({ repo.importedSleep[$0.day]?.needMin }), need > 0 { return need }
        return sleepNeedMin
    }

    /// The personal sleep need (minutes): the recent-mean total sleep, never below a 7.5h floor. Byte-for-byte
    /// the same rule as SleepView.sleepNeedMin so the two screens agree.
    private var sleepNeedMin: Double {
        let banked = repo.days.compactMap { $0.totalSleepMin }.filter { $0 > 0 }
        let mean = banked.isEmpty ? nil : banked.reduce(0, +) / Double(banked.count)
        return Swift.max(450, mean ?? 450)   // 450 min = 7.5h
    }

    /// Last night's bed → wake span, e.g. "23:41 – 07:23", from the day's bridged MAIN-night span
    /// (`SleepView.mainNightSpan`, the SAME resolver the Sleep tab hero and the daily total use), only
    /// when that night actually touches today's window (a days-old import is not "last night"). Was
    /// previously the screen's own "freshest-ending session" pick, which could name a different block —
    /// and so a different span — than the Sleep tab and Today's HR graph for a night stored as more than
    /// one block (#294).
    private var bedWakeSpanText: String? {
        let dayStart = Calendar.current.startOfDay(for: Repository.logicalDay(Date()))
        let windowStart = Int(dayStart.timeIntervalSince1970)
        let candidates = repo.sleeps.filter { $0.endTs > windowStart }
        guard let span = SleepView.mainNightSpan(candidates, habitualMidsleepSec: habitualMidsleepSec)
        else { return nil }
        return "\(clockString(span.start)) - \(clockString(span.end))"
    }

    // MARK: Footer

    // The brief quotes the footer with the brand word, but the hard legal / anonymity rule ("the word
    // never appears in a shipped UI string") wins over the illustrative copy: this keeps the exact intent
    // (a coupled read of NOOP's OWN scores, same data, different lens) without the branding word. The
    // matching Android caption is byte-identical.
    private var footerCaption: some View {
        NoopInsightRow("A classic one-glance read of NOOP's own scores. Same data, different lens.")
            .padding(.horizontal, 4)
    }

    // MARK: Charge breakdown sheet (the hero tap target)
    //
    // The same "What shaped it" content the Today Charge ring opens: the shared ChargeBreakdownSection over
    // drivers DERIVED from the displayed row (never a second store scan), the honest calibrating countdown
    // while the baseline seeds, and the "How Charge is calculated" method link. TodayView's own sheet is
    // view-private, so this hosts the SAME shared components with the same derivations, no engine work.

    /// The row the breakdown reads, mirroring the hero: today's own when scored, else the carried
    /// last-scored day, so the sheet always matches the ring above it.
    private var breakdownRow: DailyMetric? {
        if let t = day, t.recovery != nil { return t }
        return carriedRecoveryDay
    }

    /// The ordered Charge drivers for the displayed ring PLUS the confidence tier from the SAME folded HRV
    /// baseline — the exact TodayView derivation (pure engine scoring against the folded personal
    /// baselines). nil for a calibrating / cold-start night, which gates the sheet through to the countdown
    /// instead. PERF: mirrors TodayView.chargeBreakdown() — the old `chargeDrivers` property plus the
    /// sheet's inline confidence fold re-folded the full `repo.days` history four times per body eval of
    /// the open sheet; one call now folds each series exactly once, guards before any fold.
    private func chargeBreakdown() -> (drivers: [ChargeDriver], confidence: ScoreConfidence)? {
        guard let row = breakdownRow else { return nil }
        return ChargeBreakdownWiring.breakdown(days: repo.days, row: row, sleepPerfPercent: sleepPerformance,
                                               hrvBaselineEpoch: Baselines.hrvBaselineEpoch())
    }

    @ViewBuilder
    private var chargeBreakdownSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    breakdownSheetHeader
                    // One chargeBreakdown() call per sheet body eval: drivers + confidence share the same
                    // baseline folds (see chargeBreakdown's PERF note).
                    let breakdown = chargeBreakdown()
                    if let breakdown, !breakdown.drivers.isEmpty {
                        NoopCard {
                            ChargeBreakdownSection(
                                drivers: breakdown.drivers,
                                confidence: breakdown.confidence,
                                skinTempRel: RecoveryScorer.skinTempRelative(deviationC: breakdownRow?.skinTempDevC))
                        }
                    } else {
                        if let banked = calibrationNights {
                            calibrationCard(banked: banked)
                        } else {
                            NoopCard {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("No Charge breakdown yet")
                                        .font(StrandFont.book(15))
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    Text("Wear the strap overnight to score a night first.")
                                        .font(StrandFont.light(14))
                                        .foregroundStyle(StrandPalette.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    // The general METHOD behind the score, clearly separated from today's values, exactly
                    // the link the Today breakdown carries. Pushes within this sheet's own NavigationStack.
                    NavigationLink {
                        ScoringGuideView(initialSection: .charge, onClose: { showChargeBreakdown = false })
                    } label: {
                        NoopList {
                            NoopRow("How Charge is calculated",
                                    caption: "The method behind the score, not today's values.",
                                    icon: "calculator", chevron: true) { EmptyView() }
                        }
                    }
                    .buttonStyle(LiquidPressStyle())
                    .accessibilityLabel("How Charge is calculated. The method behind the score.")
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            #if os(iOS)
            // #697/#horizontal-swipe parity, see ScreenScaffold.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            .background(NoopSheetBackground())
            #if os(macOS)
            .navigationTitle("What shaped your Charge")
            #endif
            .noopHidesSystemNavBar()
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #endif
    }

    /// The sheet's `.shd` header: the title centred, a single "Done" on the right (the sheet only
    /// reads, so there is nothing to cancel).
    private var breakdownSheetHeader: some View {
        ZStack {
            Text("What shaped your Charge")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Spacer()
                Button("Done") { showChargeBreakdown = false }
                    .buttonStyle(.plain)
                    .font(StrandFont.medium(15))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
        }
        #if os(iOS)
        .padding(.top, 22)
        #else
        .padding(.top, 14)
        #endif
        .padding(.bottom, 4)
    }

    /// The calibrating countdown card, the same pure `ChargeBreakdownFormat` copy the Today sheet shows,
    /// so the two breakdowns read identically while the baseline seeds.
    private func calibrationCard(banked: Int) -> some View {
        let remaining = max(1, Baselines.minNightsSeed - banked)
        let countdown = ChargeBreakdownFormat.calibrationCountdown(nightsRemaining: remaining)
        let unlock = ChargeBreakdownFormat.calibrationUnlockCopy(scoreName: String(localized: "Charge"))
        let progress = ChargeBreakdownFormat.calibrationProgress(banked: banked, seed: Baselines.minNightsSeed)
        return NoopCard {
            HStack(alignment: .top, spacing: 14) {
                NoopIconTile("gauge")
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(countdown)
                            .font(StrandFont.book(15))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: 0)
                        ConfidenceTierChip(confidence: .calibrating)
                    }
                    Text(unlock)
                        .font(StrandFont.light(14))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(progress)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    // #731: when the countdown restarted because the user tapped "Recalibrate baseline",
                    // say so — otherwise the natural response to a fresh countdown is to tap it again,
                    // which resets it once more. nil (and no line) for anyone who never recalibrated.
                    if let restarted = ChargeBreakdownFormat.currentCalibrationRestartCause() {
                        Text(restarted)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Charge baseline calibrating. \(countdown), \(unlock). \(progress).")
    }

    // MARK: Shared helpers

    private func clockString(_ ts: Int) -> String {
        Self.clockFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// #1821: routed through AppClock so the Clock format setting reaches this label. Was a `static
    /// let`, which would have frozen the reader's choice at first use until the app relaunched.
    private static var clockFmt: DateFormatter { AppClock.hourMinuteFormatter() }

    /// "6h 42m" from a minutes count, for the slept-vs-needed read. Mirror EXACTLY in Kotlin.
    static func hoursMinutes(_ minutes: Double) -> String {
        let total = Swift.max(0, Int(minutes.rounded()))
        return "\(total / 60)h \(total % 60)m"
    }

    // MARK: - OPTIMAL strain range (task #43), pure display-only recovery→strain mapping
    //
    // The classic coupled read suggests a Day-Strain target BAND from today's recovery: a green day earns a
    // higher optimal band, a red day a lower one. This is PRESENTATION ONLY, it is never fed back into any
    // score or engine; it just tells the user where a "matched" strain would sit on the 0–21 axis. The bands
    // are the APPROVED mapping and MUST stay byte-identical to the Android `optimalStrainRange`:
    //
    //   recovery ≥ 67 (green)       → 14–18 of 21
    //   34 ≤ recovery ≤ 66 (yellow) → 10–14
    //   recovery < 34 (red)         → 4–10
    //
    // nil recovery (calibrating / unscored day) → nil, the caller renders a dash, never a guessed band.

    /// The pure recovery→optimal-strain band. Returns nil when recovery is unknown. Bands per the doc above.
    static func optimalStrainRange(recovery: Double?) -> ClosedRange<Int>? {
        guard let r = recovery else { return nil }
        switch r {
        case 67...:   return 14...18
        case 34..<67: return 10...14
        default:      return 4...10
        }
    }

    /// The optimal band as display text ("14 to 18" / "—"). Byte-identical formatting to Android.
    static func optimalStrainRangeText(recovery: Double?) -> String {
        guard let band = optimalStrainRange(recovery: recovery) else { return "—" }
        return String(localized: "\(band.lowerBound) to \(band.upperBound)")
    }
}

#if DEBUG
#Preview("Coupled view") {
    let repo = Repository(deviceId: "preview")
    repo.days = [
        DailyMetric(
            day: Repository.logicalDayKey(Date()),
            totalSleepMin: 402, efficiency: 92,
            deepMin: 84, remMin: 96, lightMin: 222, disturbances: 6,
            restingHr: 51, avgHrv: 68, recovery: 74, strain: 62,
            exerciseCount: 2,
            spo2Pct: 97, skinTempDevC: 0.1, respRateBpm: 14.4,
            steps: 8200, activeKcalEst: 640
        )
    ]
    repo.loaded = true
    return NavigationStack { CoupledView() }
        .environmentObject(repo)
        .frame(width: 900, height: 820)
        .preferredColorScheme(.dark)
}
#endif
