//  LiquidTodayView.swift
//  NOOP · Liquid design language — the Today screen, rebuilt in the liquid finish.
//
//  This is the FULL Today, re-created faithfully from the locked mockup
//  (scratchpad/liquid-metal-home.html): sky title + record/add/battery controls,
//  the three scores as liquid vessels with a card-level source badge, the live heart-rate
//  thread, the five "your cards" as liquid chips, a greeting + readiness pills,
//  Synthesis, Recovery Vitals, a Key Metrics grid (incl. steps), Last Workouts
//  and Data Sources. Every value binds to the SAME real data the classic
//  TodayView reads (accessors verified against TodayView.swift), and every tap
//  routes to the same public destination. The sky is a fixed, full-bleed
//  background (edge-to-edge under the status bar, does not scroll).

import SwiftUI
import StrandDesign
import WhoopStore
import StrandAnalytics
import WhoopProtocol

struct LiquidTodayView: View {
    @AppStorage(DayCycleMode.storageKey) private var dayCycleModeRaw = DayCycleMode.sleepOnset.rawValue
    private var dayCycleMode: DayCycleMode { DayCycleMode.persisted(dayCycleModeRaw) }
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var router: NavRouter
    @EnvironmentObject var profile: ProfileStore
    // For the pull-to-sync gesture (#334): a pull kicks a manual strap history offload via ble.syncNow().
    // Observe BLEManager, NOT AppModel — AppModel @Publishes `bpm` on the ~1 Hz HR tick, so observing it
    // would re-render all of Today every second (the exact churn the LiveState leaves isolate). BLEManager
    // only publishes connect/discovery state, never HR. Injected at the app roots beside .environmentObject(model).
    @EnvironmentObject var ble: BLEManager

    /// Shared with the real Today's card-customise editor so the two stay in sync.
    @AppStorage(DashboardCardPrefs.selectionKey) private var dashboardCardsRaw = ""
    /// #today-hosted-cards: the ordered Trends/Sleep cards the user has hosted in Today. Empty by default
    /// (opt-in); rendered by the `.addedCards` section. Shared @AppStorage key with Android.
    @AppStorage(HostedCardPrefs.selectionKey) private var hostedCardsRaw = ""
    /// #989 parity with classic Today + Android: the hydration card is opt-in twice over — the feature
    /// toggle AND an explicit add in CUSTOMISE. Liquid filtered on neither, so a user who added the card
    /// and later switched the feature off kept a permanently-blank row.
    /// The Coach master switch (`noop.coachEnabled`, shared by name with Android). Default ON. Gates the
    /// Today launcher card here; the tab and the daily brief read the same key.
    @AppStorage("noop.coachEnabled") private var coachEnabled = true
    @AppStorage(HydrationStore.enabledKey) private var hydrationEnabled = false
    /// Today's hydration total + goal (ml), resolved in `load()`. nil → the card shows "—".
    @State private var hydrationTotalML: Double?
    @State private var hydrationGoalML: Int?

    // async-loaded via the confirmed Repository accessors
    @State private var restScore: Double?          // sleep_performance, day-keyed
    /// Input providers for the three scores, keyed by recovery / strain / sleep_performance.
    @State private var heroProviderByMetric: [String: ScoreInputProvider] = [:]
    @State private var stress: Double?             // StressModel(...).score, 0–3
    @State private var fitnessAge: Double?         // exploreSeries("fitness_age").last
    @State private var vo2max: Double?             // exploreSeries("vo2max_est").last (#1391)
    @State private var vitality: Double?           // exploreSeries("vitality").last
    // Queue 11a: day-keyed "spo2_candidate" metricSeries (WHOOP `spo2_candidate_82` or Oura
    // ceiling@100 `0x6F`, device-conditional — see `IntelligenceEngine`). Empty when the
    // experimental toggle is OFF (the engine writes nothing) or the owner has no in-band reading.
    // Read unconditionally like the classic TodayView's `spo2CandidateSpark` — always empty when
    // the toggle is off, so no separate gate is needed at fetch time.
    @State private var spo2CandidateByDay: [String: Double] = [:]
    @State private var stepsEst: Double?           // steps_est, day-keyed to the selected day (fallback)
    @State private var importedStepsDay: Int?      // Apple Health steps for the selected day (middle tier)
    @State private var importedActiveKcalDay: Double?  // #616: Apple Health active energy for the day (calorie fallback)
    @State private var weightKg: Double?           // #204: Apple Health weight ?: profile fallback
    @State private var hrValues: [Double] = []     // hrBuckets since midnight → 5-min means
    /// Line identity for [hrValues], from the bucket timestamps this used to discard (#2082).
    ///
    /// A bucket with no samples is simply absent from the aggregate, so mapping straight to `bpm` closed
    /// every hole up and drew a day of sparse live windows as one continuous line. That bites hardest on a
    /// strap whose history never offloads, where heart rate exists ONLY for the windows it was connected.
    @State private var hrSegments: [String] = []
    @State private var workouts: [WorkoutRow] = [] // newest-first
    /// #today-hosted-cards: the shared SleepModel that backs every SleepModel-derived hosted sleep card
    /// (Stages vs typical today; more to follow). Built ONCE in `load()` from the SAME inputs the Sleep tab
    /// uses (`SleepModel.build`), and only when a sleep-origin card is actually hosted — so a Today with no
    /// hosted sleep card pays none of the extra Repository work. nil until (and unless) it's built.
    @State private var hostedSleepModel: SleepModel? = nil

    // #2040: today's scored stress for the hosted curve card. Loaded only when that card is hosted, the
    // same "hosting none pays nothing" rule the sleep model follows. `StressDayCurve` self-gates on a
    // cheap heart-rate fingerprint and memoises, so the widget, this shell and the other Today view all
    // share one computation rather than scoring the day three times.
    @State private var hostedStressHours: [DaytimeStress.HourPoint] = []
    @State private var hostedStressActivityMaskedHours = 0

    // sheets / expanders
    @State private var guideSection: ScoreSection?
    @State private var customizationDestination: TodayCustomizationDestination?
    /// #1862: the optional Coach launcher sheet. Presentation state only — opening it requests nothing.
    @State private var showCoachLauncher = false
    @State private var showSettings = false
    @State private var synthesisExpanded = false
    @State private var showLiveSession = false

    /// Live Sessions (silent guardian) beta gate — the SAME key the Settings toggle writes. Default ON
    /// (the entry is BETA-labelled in-UI); off removes the Start-session control entirely.
    @AppStorage(LiveSessionPrefs.betaKey) private var liveSessionsBeta = true
    // #today-layout (parity with Android): the user-chosen section order, persisted under the byte-identical
    // "today.sectionOrder" key the Android TodayLayoutPrefs uses. Reordered via the Arrange sheet (native
    // drag-to-reorder rows); every section always renders (decode inserts a missing one at its default spot).
    @AppStorage(TodayLayoutPrefs.orderKey) private var sectionOrderRaw = ""
    @AppStorage(TodayLayoutPrefs.hiddenKey) private var hiddenSectionsRaw = ""
    private var sectionOrder: [TodaySection] {
        TodayLayoutPrefs.visibleOrder(orderRaw: sectionOrderRaw, hiddenRaw: hiddenSectionsRaw)
    }
    // #430 parity: the Key-Metrics grid honours the SAME editor selection/order + Detailed-tiles switch as
    // Android (byte-identical @AppStorage keys). `kSparks` holds the trailing-30-day series the detailed
    // tiles graph (keyed by metric-catalog key), filled by the loader alongside everything else.
    @AppStorage(KeyMetricPrefs.layoutKey) private var keyMetricsRaw = ""
    @AppStorage("today.keyMetricsDetailed") private var keyMetricsDetailed = false
    /// The detailed graphs' trailing window — 1 week / 2 weeks / 1 month (shared key with Android). The
    /// loader banks a day-keyed 30-day superset; render filters down, so a window change applies instantly.
    @AppStorage("today.keyMetricsWindowDays") private var keyMetricsWindowDays = 14
    @State private var kSparks: [String: [(String, Double)]] = [:]
    private var enabledKeyMetrics: [KeyMetric] { KeyMetricPrefs.decodeEnabled(keyMetricsRaw) }

    /// #1001: TODAY's in-progress Effort, scored live in `load()` over the same window this view already
    /// resolves for its other reads. nil for a navigated past day, and nil when the scorer has too few
    /// readings — every Effort read-out then falls back to the stored row rather than a fabricated value.
    @State private var liveTodayStrain: Double?
    /// Minutes in heart-rate zones 2–5 over the selected day's window, resolved in `load()`.
    @State private var zoneMinutes2to5: Double?

    // day navigation (0 = today, 1 = yesterday, …)
    @State private var selectedDayOffset = 0
    @State private var showDayPicker = false
    @State private var heartRateCardFrame: CGRect = .null
    /// The hero carousel's frame: a horizontal swipe that starts on it pages the scores, not the day.
    @State private var heroCarouselFrame: CGRect = .null
    private static let daySwipeSpace = "liquidTodayDaySwipeSpace"

    // PERF: the body was rescanning repo.days (599 days) ~23× per pass for displayDay and ~3× for
    // readiness on EVERY re-render (every HR notify, every canvas frame that invalidates, every scroll).
    // Resolve both ONCE per data/day change in load() and read the cache in body (O(1)).
    @State private var cachedDisplayDay: DailyMetric?
    @State private var cachedReadiness: ReadinessEngine.Readiness?
    /// The recovery-INDEPENDENT prior-day vitals carry (HRV / RHR / respiratory), resolved ONCE in load()
    /// alongside cachedDisplayDay. Fixes the v8 rollover blank: after 04:00, before tonight's sleep scores,
    /// today's row has no vitals yet, so these fall back to the last night that recorded them. Never
    /// resolved in body — body rescans repo.days ~23× per pass, and this cache keeps that read O(1).
    @State private var cachedVitalsDay: DailyMetric?
    @State private var cachedRespDay: DailyMetric?
    @State private var cachedHrvDay: DailyMetric?
    @State private var cachedRestingHrDay: DailyMetric?
    @State private var cachedSkinTempReadingDay: DailyMetric?
    /// The Charge hero's resolved state (#543 carry + the honest label), resolved ONCE in load() alongside
    /// the other caches. It composes `TodayView.lastScoredRecoveryDay`, which is O(days) — exactly the scan
    /// this cache exists to keep out of body. Never resolved in body.
    @State private var cachedChargeDisplay: ChargeDisplay = .noData
    /// Active WHOOP 5 R-R policy bounds for the selected night's missing Charge explanation.
    @State private var whoop5StrictRR = false
    @State private var firstRecordedRRDay: String?
    @State private var firstScorableRRDay: String?

    // Custom liquid pull-to-refresh: a vessel that FILLS as you drag, releases into a refresh (replaces
    // the system spinner). Driven by the scroll's top overscroll offset.
    @State private var pullY: CGFloat = 0
    @State private var refreshArmed = false
    @State private var refreshing = false
    @State private var pullHaptic = 0
    private let pullThreshold: CGFloat = 80

    /// "Card transparency" (0–100, default 100): fades every liquid card surface here — the hero, the
    /// session-start row, the metric tiles and the `card` helper — in lockstep with the frosted cards.
    /// Content sits above the surface so it stays readable. Mirrors Kotlin `NoopPrefs.cardOpacityPercent`.
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }
    /// Day-cycle scene backdrop (#698). Default ON. When off, the liquid Today drops the sky for the plain
    /// dark canvas — parity with Android and the classic TodayView, which already honour this pref. Mirrors
    /// Kotlin `NoopPrefs.showDayCycleBackground`.
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var showDayCycleBackground = true
    /// Custom background image (#custom-background): when active it overrides the sky in the backdrop below.
    @ObservedObject private var backgroundStore = BackgroundImageStore.shared

    // MARK: - Day navigation (ported from classic Today: swipe + calendar, day-keyed reads)

    /// The logical day the selector resolves to (offset 0 = today's logical day, rolls at 04:00).
    private var selectedLogicalDay: Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: base) ?? base
    }
    /// The day key the day-scoped read-outs key on. At offset 0 follows repo.today?.day.
    private var selectedDayKey: String {
        if selectedDayOffset == 0, let todayKey = repo.today?.day { return todayKey }
        return Repository.localDayKey(selectedLogicalDay)
    }
    /// The DailyMetric shown for the selected day — read from the cache resolved in load() (was an
    /// O(days) `.last(where:)` scan referenced ~23× per body pass; now O(1)).
    private var displayDay: DailyMetric? { cachedDisplayDay }
    /// The prior-day vitals carry (see `cachedVitalsDay`), read O(1) from the cache. Non-nil only at
    /// offset 0 (today); a navigated past day carries nothing (its own row is the whole story).
    private var vitalsDay: DailyMetric? { cachedVitalsDay }
    /// The prior-day RESPIRATORY carry (#1331): staleness-bounded, so a recent missed night reads the last
    /// real value while a weeks-old one honestly shows "No Data". Non-nil only at offset 0.
    private var respDay: DailyMetric? { cachedRespDay }

    /// PER-FIELD HRV / resting-HR carries (#1842), read O(1) from the cache like `vitalsDay`. `vitalsDay`'s
    /// predicate is an OR across HRV / resting-HR / respiratory, so it resolves the freshest row with ANY of
    /// them — a respiratory-only row blanks HRV and Resting HR on both the vitals card and the Key Metrics
    /// tiles. Twins of `DailyMetric.lastHrvDay` / `lastRestingHrDay`; mirror the Android per-field rows.
    private var hrvDay: DailyMetric? { cachedHrvDay }

    private var restingHrDay: DailyMetric? { cachedRestingHrDay }

    /// The skin-temp reading these cards LEAD with (#1844): today's row if it holds either number, else the
    /// vitals carry, else the freshest prior row with either. Both numbers come off the SAME row, so an
    /// absolute is never paired with another night's deviation. Twin of `TodayView.skinTempLeadReading`.
    private var skinTempLeadReading: SkinTempDisplay.Reading? {
        let row = [displayDay, vitalsDay, cachedSkinTempReadingDay]
            .compactMap { $0 }
            .first { $0.skinTempC != nil || $0.skinTempDevC != nil }
        return SkinTempDisplay.leadReading(absC: row?.skinTempC, devC: row?.skinTempDevC,
                                           prefer: SkinTempDisplay.Kind(rawValue: skinTempDisplayRaw) ?? .absolute)
    }
    /// The Charge hero's resolved state (see `cachedChargeDisplay`), read O(1) from the cache.
    private var chargeDisplay: ChargeDisplay { cachedChargeDisplay }

    /// Match classic Today's existing legacy-night judgement, including its selected-day gate.
    private var chargeLegacyRRGap: Bool {
        guard let day = displayDay, day.recovery == nil else { return false }
        return Whoop5RR.legacyUnscorableNight(
            strictWhoop5: whoop5StrictRR, day: day.day,
            firstRecordedDay: firstRecordedRRDay, firstScorableDay: firstScorableRRDay,
            avgHrv: day.avgHrv, totalSleepMin: day.totalSleepMin)
    }

    /// The actual O(days) resolution. Offset 0 prefers live repo.today; past offsets look up. Run ONCE
    /// per data/day change from load(), never from body.
    private func resolveDisplayDay() -> DailyMetric? {
        if selectedDayOffset == 0 {
            return repo.today ?? repo.days.last(where: { $0.day == selectedDayKey })
        }
        return repo.days.last(where: { $0.day == selectedDayKey })
    }
    /// How far back navigation can go (whole days from the earliest banked day to today).
    private var earliestDayOffset: Int {
        Self.maxDayOffset(earliestDayKey: repo.freshness.earliestDay,
                          todayKey: Repository.logicalDayKey(Date()))
    }
    /// The big header title: Today / Yesterday / weekday for older days.
    private var dayTitle: String {
        switch selectedDayOffset {
        // #1013: these must localize — the header showed English "Today"/"Yesterday"/weekday even when the
        // system UI (tab bar etc.) was another language. "Today"/"Yesterday" go through String(localized:)
        // (matching the classic TodayView.dayNavLabel), and the weekday name is formatted in the user's
        // locale, not the en_US_POSIX one used only for machine day-keys.
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Yesterday")
        default:
            return selectedLogicalDay.formatted(.dateTime.weekday(.wide).locale(AppLanguage.activeLocale))
        }
    }
    /// Two-way binding for the graphical calendar: reads the shown day, writes back an offset.
    private var dayPickerBinding: Binding<Date> {
        Binding(
            get: { selectedLogicalDay },
            set: { newValue in
                selectedDayOffset = Self.pickedDayOffset(pickedDate: newValue,
                                                         anchorLogicalDay: Repository.logicalDay(Date()))
                showDayPicker = false
            }
        )
    }
    /// Horizontal swipe between days (right = older, left = newer — `TodayView.daySwipeDelta`, #2378),
    /// clamped to [today, earliest].
    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .named(Self.daySwipeSpace))
            .onEnded { value in
                guard !heartRateCardFrame.contains(value.startLocation),
                      !heroCarouselFrame.contains(value.startLocation) else { return }
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 50 else { return }
                let delta = TodayView.daySwipeDelta(dx: dx)
                let next = Self.clampedDayOffset(current: selectedDayOffset, delta: delta,
                                                 maxOffset: earliestDayOffset)
                guard next != selectedDayOffset else { return }
                withAnimation(StrandMotion.interactive) { selectedDayOffset = next }
            }
    }

    static func clampedDayOffset(current: Int, delta: Int, maxOffset: Int) -> Int {
        min(max(0, maxOffset), max(0, current + delta))
    }
    static func maxDayOffset(earliestDayKey: String?, todayKey: String) -> Int {
        guard let earliestKey = earliestDayKey,
              let earliest = dayKeyParser.date(from: earliestKey),
              let today = dayKeyParser.date(from: todayKey) else { return 0 }
        let gap = Calendar.current.dateComponents([.day],
                                                  from: Calendar.current.startOfDay(for: earliest),
                                                  to: Calendar.current.startOfDay(for: today)).day ?? 0
        return max(0, gap)
    }
    static func pickedDayOffset(pickedDate: Date, anchorLogicalDay: Date) -> Int {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: pickedDate),
                                      to: cal.startOfDay(for: anchorLogicalDay)).day ?? 0
        return max(0, days)
    }
    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Scroll-to-top on an at-root Today re-tap (#198 follow-up); default 0 so macOS/other contexts stay inert.
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal
    private static let topAnchorID = "liquidToday.top"

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 0) {
                // Zero-height scroll-to-top anchor (#198 follow-up): the target for an at-root Today re-tap.
                Color.clear.frame(height: 0).id(Self.topAnchorID)
                // Scroll-offset probe at the very top (before padding), so its minY in the scroll's
                // coordinate space reads the top OVERSCROLL: ~0 at rest, positive as you pull down.
                GeometryReader { g in
                    Color.clear.preference(key: PullOffsetKey.self,
                                           value: g.frame(in: .named(Self.pullSpace)).minY)
                }
                .frame(height: 0)

                liquidRefreshIndicator   // grows in the revealed space; a ring filling with the pull

                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    header
                        .todayGutter()
                    // The strain/illness early-warning banner, dropped in the liquid Home rewrite. Liquid is
                    // the DEFAULT Today on both platforms (RootTabView.swift's liquidTodayEnabled = true,
                    // RootView.swift likewise), so while this was unmounted a RAISED health alert had no
                    // home-screen surface at all: it survived only as one push at the moment it fired
                    // (IllnessNotifier.post) and as HeadsUpCard two taps deep in More → Health. Pinned ABOVE
                    // the reorderable block — the same position classic TodayView uses on both platforms and
                    // the same one Android pins it to (TodayScreen.kt) — so a warning cannot be reordered
                    // below the fold. Renders nothing when model.healthAlert is nil.
                    HealthAlertBanner()
                        .todayGutter()
                    // #105: the live "workout in progress" card, dropped in the liquid Home rewrite. Restored
                    // here as the SAME leaf the classic TodayView renders (and Android's WorkoutInProgressCard),
                    // pinned above the reorderable block so an active manual workout is immediately visible
                    // and taps straight through to Live. Renders nothing when no workout is active.
                    ActiveWorkoutIndicatorSection()
                        .todayGutter()
                    // #today-layout (parity with Android): every Today section — the Charge/Effort/Rest hero
                    // and Start-session included — renders in the user's saved order. Reorder via the Arrange
                    // sheet (the header's up/down button; native drag rows); the order persists under the
                    // byte-identical "today.sectionOrder" key Android uses. A gated-off Start-session renders
                    // nothing and keeps its slot in the saved order.
                    ForEach(sectionOrder) { section in
                        switch section {
                        case .hero:
                            // Full width: the carousel draws its own 20 pt content margins so the
                            // neighbouring scores can peek in at the screen edges.
                            heroCarousel
                            if chargeLegacyRRGap { ChargeLegacyRRGapNote().todayGutter() }
                        case .liveSession: if liveSessionsBeta { liveSessionStartRow.todayGutter() }
                        case .synthesis: synthesisSection.todayGutter()
                        case .keyMetrics: keyMetricsSection.todayGutter()
                        case .workouts: lastWorkoutsSection.todayGutter()
                        case .heartRate: heartRateSection.todayGutter()
                        case .recoveryVitals: recoveryVitalsSection.todayGutter()
                        case .yourCards: yourCardsSection.todayGutter()
                        case .menstrualCycle:
                            if selectedDayOffset == 0 { MenstrualCycleHomeCard().todayGutter() }
                        // #656: the persistent journal widget (last-7-days strip + tap-through). Now a
                        // reorderable section like the others — the Arrange sheet moves it. Today only;
                        // the card self-hides when the reminder toggle is off (an empty branch renders
                        // nothing yet keeps its slot). Twin of Android TodayScreen's JOURNAL arm.
                        case .journal: if selectedDayOffset == 0 { JournalReminderCard().todayGutter() }
                        // #today-hosted-cards: cards the user pulled in from the Trends/Sleep tabs, in the
                        // order they arranged. Empty (renders nothing) until they add one in Customise.
                        // Today-only, matching Android's addedCards section gate + the classic TodayView.
                        case .addedCards: if selectedDayOffset == 0 { hostedCardsSection.todayGutter() }
                        }
                    }
                    // Opt-in "looks like a workout?" suggestion, dropped in the liquid Home rewrite. Its
                    // Settings toggle (PuffinExperiment.autoDetectWorkoutsKey) had no visible effect on the
                    // DEFAULT screen: the card's only mount was classic TodayView, so a user could switch
                    // auto-detect on and never be shown a single suggestion. Same position classic uses
                    // (after the cards block, before Data Sources) and the same leaf Android renders.
                    // Self-gates on the toggle AND on the detector finding an unsaved, un-dismissed window,
                    // so it renders nothing by default.
                    AutoWorkoutCard()
                        .todayGutter()
                    dataSourcesSection
                        .todayGutter()
                        .padding(.top, 10)
                    Color.clear.frame(height: NoopMetrics.tabBarClearance) // floating tab-bar clearance
                }
                .padding(.top, 6)
            }
            #if os(macOS)
            // Keep the phone-shaped column readable + centred on the wide mac detail pane. The sky is a
            // ScrollView background (full-bleed), so constraining the content column here doesn't touch it.
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            #endif
        }
        .coordinateSpace(name: Self.pullSpace)
        #if os(iOS)
        // #697 parity: ScreenScaffold already stops a vertical scroll from drifting/bouncing the
        // screen left-right on every other tab. Liquid Today runs its own ScrollView (not
        // ScreenScaffold) and never got the fix, so it was the one screen left with the spurious
        // horizontal rubber-band/swipe. `.basedOnSize` only permits horizontal bounce when content
        // genuinely overflows the width (it does not here, the column is width-capped), so this
        // brings Today's scroll behaviour in line with the rest of the app without touching the
        // vertical pull-to-refresh gesture above.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        .onPreferenceChange(PullOffsetKey.self) { handlePull($0) }
        #if os(iOS) && DEBUG
        // DEBUG screenshot harness: `--demo-anchor top|center|bottom` starts the scroll there.
        .modifier(DemoScrollAnchor())
        #endif
        // The v2 ground: true black, a FIXED full-bleed backdrop behind the scroll content, edge-to-edge
        // under the status bar. A ScrollView background does not scroll with the content.
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                NoopVisualStyle.canvas
                // Custom background image (#custom-background): a picked photo OVERRIDES the ground,
                // filling the whole backdrop (same cached image as every other tab, so it's seamless).
                if backgroundStore.isActive {
                    BackgroundImageBackdrop()
                }
                // Day-cycle background (#698): v2 no longer paints a sky; the setting lets the ground warm
                // slightly after sunset, the same treatment every scaffolded tab uses.
                else if showDayCycleBackground {
                    V2GroundWarmth(height: 340)
                }
            }
            .ignoresSafeArea()
        }
        .coordinateSpace(name: Self.daySwipeSpace)
        .onPreferenceChange(LiquidHeartRateCardFrameKey.self) { heartRateCardFrame = $0 }
        .onPreferenceChange(TodayHeroFrameKey.self) { heroCarouselFrame = $0 }
        // Swipe left/right to change DAYS (WHOOP-style). Tab-swipe is disabled on Today in RootTabView so
        // this owns the horizontal gesture here.
        .simultaneousGesture(daySwipeGesture)
        // A light tick when the day changes (swipe or calendar pick) — the WHOOP-style day nav should
        // feel physical ("every tiny little thing").
        .liquidSelectionHaptic(trigger: selectedDayOffset)
        // A firm tick when the pull passes the release threshold (the custom liquid refresh).
        .liquidMediumHaptic(trigger: pullHaptic)
        // hydrationSeq joins the id so logging a drink re-reads the card immediately, the same trigger set
        // classic TodayView's reloadHydration() uses.
        .task(id: "\(repo.refreshSeq)-\(selectedDayOffset)-\(repo.hydrationSeq)-\(hydrationEnabled)-\(dayCycleModeRaw)") {
            DashboardCardPrefs.migrateLegacyStepsAverage()
            await load()
        }
        .sheet(item: $guideSection) { section in
            NavigationStack {
                ScoringGuideView(initialSection: section, scores: guideScores, onClose: { guideSection = nil })
            }
        }
        .sheet(item: $customizationDestination) { destination in
            TodayCustomizationSheet(
                initialDestination: destination,
                sectionOrderRaw: $sectionOrderRaw,
                hiddenSectionsRaw: $hiddenSectionsRaw,
                keyMetricsRaw: $keyMetricsRaw,
                keyMetricsDetailed: $keyMetricsDetailed,
                keyMetricsWindowDays: $keyMetricsWindowDays,
                dashboardCardsRaw: $dashboardCardsRaw,
                hostedCardsRaw: $hostedCardsRaw
            )
        }
        .sheet(isPresented: $showCoachLauncher) {
            CoachLauncherSheet()
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .liquidSheetDoneChrome { showSettings = false }
            }
        }
        // Live Session (silent guardian, beta): the in-session screen owns the whole display — full
        // screen on iOS (nothing should compete with the ring mid-workout), a sheet on macOS where
        // fullScreenCover doesn't exist.
        .liveSessionCover(isPresented: $showLiveSession)
        #if os(macOS)
        // Hide the mac window toolbar's vibrant material so the full-bleed day-of-sky reads dark + edge-to-edge
        // at the top instead of the white scroll-under-titlebar wash.
        .toolbarBackground(.hidden, for: .windowToolbar)
        #endif
        #if os(iOS)
        // Scroll-to-top on an at-root Today re-tap (#198 follow-up); iOS-only — the tab shell is the only driver.
        .onChange(of: scrollToTopSignal) { _, _ in
            withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo(Self.topAnchorID, anchor: .top) }
        }
        #endif
        }
    }

    // MARK: - Liquid pull-to-refresh

    static let pullSpace = "liqTodayScroll"

    /// Reserves the revealed space at the top and shows a vessel that fills with the pull, then sloshes
    /// while the refresh runs. A plain computed property (not a LiveState-isolated leaf) — it doesn't read
    /// LiveState itself, so it's cheap to re-evaluate as part of the main body. It hands the actual
    /// visibility decision to `LiquidRefreshIndicator` below, which DOES own LiveState.
    private var liquidRefreshIndicator: some View {
        LiquidRefreshIndicator(pullY: pullY, pullThreshold: pullThreshold, refreshing: refreshing)
    }

    /// Arm the refresh once the pull passes the threshold; FIRE it when the finger releases (the pull
    /// springs back toward zero). Guarded so it can't double-fire or re-trigger mid-refresh.
    private func handlePull(_ y: CGFloat) {
        pullY = max(0, y)
        guard !refreshing else { return }
        // #1748 twin: gate the ARM, not the release. `syncNow()`'s own gate checks connected + bonded, and
        // `bonded` is set by the live-HR path for a 5/MG that has never completed a handshake — so the pull
        // was accepted and then declined in silence. `historyReady` is the client's OWN precondition, so
        // this cannot withhold a sync that would have run.
        //
        // On the ARM specifically: gating the RELEASE below would leave `refreshArmed` stuck true for the
        // rest of the gesture, since that branch is the only thing that clears it — a worse failure than
        // the silent one being fixed. Not arming also withholds the haptic, which is the honest signal
        // that the gesture is unavailable rather than unresponsive.
        if pullY >= pullThreshold, !refreshArmed, ble.state.historyReady {
            refreshArmed = true
            pullHaptic &+= 1
        }
        if refreshArmed, pullY < 6 {
            refreshArmed = false
            refreshing = true
            Task {
                // #334 (iOS twin of Android #426): a pull requests a fresh strap history offload, not just
                // a UI reload. syncNow() is internally gated (connected + bonded + not-already-backfilling),
                // so a pull while disconnected or mid-offload safely no-ops. The sync status chip owns the
                // ongoing offload progress; the pull spinner stays short (the reload below).
                ble.syncNow()
                await repo.refresh()
                await load()
                try? await Task.sleep(nanoseconds: 350_000_000)   // let the fill read as "done"
                withAnimation(.easeOut(duration: 0.25)) { refreshing = false }
            }
        }
    }

    // MARK: - Header (avatar, greeting + date, strap pill, quick actions)

    private var header: some View {
        HStack(spacing: 12) {
            // Profile photo (the one set in Settings) → opens Settings, matching the classic Today.
            Button { showSettings = true } label: {
                TodayV2Avatar(imageData: profile.avatarImageData)
            }
            .buttonStyle(LiquidPressStyle())
            .accessibilityLabel("Profile and settings")
            Button { showDayPicker = true } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: headerTitle)
                        .font(StrandFont.headline)
                        .tracking(-0.17)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(dateLine)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(dayTitle). Tap to pick a day, swipe to change day.")
            .popover(isPresented: $showDayPicker) {
                DatePicker("", selection: dayPickerBinding, in: ...Repository.logicalDay(Date()),
                           displayedComponents: [.date])
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(12)
                    .frame(minWidth: 320, minHeight: 360)
                    .liquidPopoverAdaptation()
            }
            LiquidBatteryButton()
            LiquidAddButton()
        }
        // The kit's 18 pt between header and hero, less the column's 12 pt gap.
        .padding(.bottom, 6)
    }

    /// The selected day's scores for the Scoring guide's hero — the same resolved values the carousel shows.
    private var guideScores: ScoringGuideScores {
        ScoringGuideScores(charge: chargeDisplay.pct, effort: effortStrain(displayDay), rest: restScore,
                           dayLine: dateLine, source: heroSourceLabel)
    }

    /// The header's first line: the greeting on today, the day's name once the user has paged back. The
    /// app keeps no profile name, so the greeting is never personalised with one.
    private var headerTitle: String {
        selectedDayOffset == 0 ? greeting : dayTitle
    }

    /// One-tap Live Session start (silent guardian, beta) as a v2 list row with its BETA tag.
    private var liveSessionStartRow: some View {
        NoopList {
            Button { showLiveSession = true } label: {
                HStack(spacing: 14) {
                    NoopIconTile("play")
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Start session")
                                .font(StrandFont.book(15, relativeTo: .body))
                                .foregroundStyle(StrandPalette.textPrimary)
                            NoopTag("BETA", size: 10)
                        }
                        Text("Silent strap coaching against today's Charge")
                            .font(StrandFont.light(12, relativeTo: .caption))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    PhIcon("caret-right", size: 14).foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
                .contentShape(Rectangle())
            }
            .buttonStyle(LiquidPressStyle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Start a live session. Beta. Silent strap coaching against today's Charge.")
    }

    // MARK: - Hero carousel (Rest · Charge · Effort)

    private var heroCarousel: some View {
        TodayHeroCarousel(pages: [restPage, chargePage, effortPage]) { kind in
            switch kind {
            case .charge: guideSection = .charge
            case .effort: guideSection = .effort
            case .rest: guideSection = .rest
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: TodayHeroFrameKey.self,
                                       value: geometry.frame(in: .named(Self.daySwipeSpace)))
            }
        }
        // The kit's 22 pt between the dots row and the first section, less the 12 pt column gap.
        .padding(.bottom, 10)
    }

    /// #543 carry: an unscored today shows the last scored night's REAL Charge (labelled by the pill)
    /// rather than an empty page, matching the classic Today, the widget/watch/Live Activity and Android.
    private var chargePage: TodayHeroPage {
        let pct = chargeDisplay.pct
        let label = String(localized: "Charge")
        return TodayHeroPage(
            kind: .charge, glow: NoopGlow.charge(pct), title: label, icon: "lightning",
            pill: chargeDisplay.stateLabel,
            value: pct.map { String(Int($0.rounded())) }, unit: "%",
            lowCaption: String(localized: "Depleted"), midCaption: chargeMidCaption,
            highCaption: String(localized: "Peak"),
            marker: frac(pct),
            // The Charge state-word edges (Low 25 · Moderate 50 · Primed 70 · Peak 88), as the frame marks
            // them; the glow changes at 50 and 70, so the scale and the hero colour agree.
            scaleLabels: [(0, "0"), (0.25, "25"), (0.5, "50"), (0.7, "70"), (0.88, "88"), (1, "100")],
            sentence: chargeSentence,
            dotsLabel: "\(label) \(intText(pct))",
            detailRoute: .metric(HeroRingMetric.charge),
            spokenValue: pct.map { "\(Int($0.rounded())) %" } ?? String(localized: "no data yet"))
    }

    /// The word on the Charge scale: the readiness read when there is one, else the Charge band.
    private var chargeMidCaption: String {
        switch readiness.level {
        case .primed: return String(localized: "Primed · ready to push")
        case .balanced: return String(localized: "Balanced · good to train")
        case .strained: return String(localized: "Strained · keep it easy")
        case .rundown: return String(localized: "Run down · prioritise rest")
        case .insufficient:
            guard let pct = chargeDisplay.pct else { return chargeDisplay.stateLabel }
            // The same band the hero glow is drawn in, so the word and the colour cannot disagree.
            switch NoopGlow.charge(pct) {
            case .recovery: return String(localized: "High charge")
            case .moderate: return String(localized: "Mid charge")
            default: return String(localized: "Low charge")
            }
        }
    }

    /// "HRV is ABOVE baseline, resting HR STEADY." — composed from the readiness signals that scored the
    /// selected day. A signal the engine could not score (thin baseline) is left out, never guessed.
    private var chargeSentence: [[TodayHeroPage.Segment]] {
        let hrv = readiness.signals.first { $0.key == "hrv" }?.flag
        let rhr = readiness.signals.first { $0.key == "rhr" }?.flag
        var lines: [[TodayHeroPage.Segment]] = []
        if let hrv {
            let word: String
            switch hrv {
            case .good: word = String(localized: "Above")
            case .neutral: word = String(localized: "At")
            case .watch: word = String(localized: "Below")
            case .bad: word = String(localized: "Well below")
            }
            lines.append([.text(String(localized: "HRV is")), .tag(word),
                          .text(rhr == nil ? String(localized: "baseline.") : String(localized: "baseline,"))])
        }
        if let rhr {
            let word: String
            switch rhr {
            case .good, .neutral: word = String(localized: "Steady")
            case .watch: word = String(localized: "Up")
            case .bad: word = String(localized: "High")
            }
            lines.append([.text(hrv == nil ? String(localized: "Resting HR") : String(localized: "resting HR")),
                          .tag(word), .text(".")])
        }
        return lines
    }

    private var restPage: TodayHeroPage {
        let label = String(localized: "Rest")
        let asleep = displayDay?.totalSleepMin
        var sentence: [[TodayHeroPage.Segment]] = []
        if let deep = displayDay?.deepMin, let rem = displayDay?.remMin {
            sentence = [[.text(String(localized: "Deep")), .tag(CoupledView.hoursMinutes(deep)),
                         .text(String(localized: "· REM")), .tag(CoupledView.hoursMinutes(rem))]]
        }
        return TodayHeroPage(
            kind: .rest, glow: .sleep, title: label, icon: "moon",
            pill: asleep == nil ? nil : String(localized: "Last night"),
            value: restScore.map { String(Int($0.rounded())) }, unit: "%",
            lowCaption: String(localized: "Short"),
            midCaption: asleep.map { String(localized: "\(CoupledView.hoursMinutes($0)) asleep") }
                ?? String(localized: "No sleep recorded"),
            highCaption: String(localized: "Full"),
            marker: frac(restScore),
            scaleLabels: [(0, "0"), (0.25, "25"), (0.5, "50"), (0.75, "75"), (1, "100")],
            sentence: sentence,
            dotsLabel: "\(label) \(intText(restScore))",
            detailRoute: .metric(HeroRingMetric.rest),
            spokenValue: restScore.map { "\(Int($0.rounded())) %" } ?? String(localized: "no data yet"))
    }

    private var effortPage: TodayHeroPage {
        let label = String(localized: "Effort")
        let strain = effortStrain(displayDay)
        let whoop = effortScale == .whoop
        let target = effortTargetText
        let sentence: [[TodayHeroPage.Segment]]
        if let target {
            sentence = [[.text(String(localized: "Aim for")), .tag(target), .text(String(localized: "today."))]]
        } else {
            sentence = []
        }
        return TodayHeroPage(
            kind: .effort, glow: .strain, title: label, icon: "fire",
            pill: effortBandWord(strain),
            value: strain.map { effortNumber($0) }, unit: nil,
            lowCaption: String(localized: "Rest day"),
            midCaption: target.map { String(localized: "Target \($0)") }
                ?? String(localized: "of \(UnitFormatter.effortScaleMax(effortScale))"),
            highCaption: String(localized: "All out"),
            marker: frac(strain),
            scaleLabels: whoop
                ? [(0, "0"), (1.0 / 3, "7"), (2.0 / 3, "14"), (1, "21")]
                : [(0, "0"), (0.25, "25"), (0.5, "50"), (0.75, "75"), (1, "100")],
            sentence: sentence,
            dotsLabel: "\(label) \(strain.map { effortNumber($0) } ?? Self.noValueDash)",
            detailRoute: .metric(HeroRingMetric.effort),
            spokenValue: strain.map { effortNumber($0) } ?? String(localized: "no data yet"))
    }

    // MARK: - Heart rate · Live

    private var heartRateSection: some View {
        // #979: the whole-day HR trend (Deep Timeline) still exists but was buried behind Metrics →
        // Show all → Deep Timeline. The whole live HR card remains a one-tap route into it.
        NavigationLink(value: TabRoute.fullDayChart) {
            // Isolated leaf: it observes LiveState so the ~1 Hz HR notifies re-render ONLY this card,
            // never the whole Today. Shows the current bpm live with a rolling beat-by-beat trace; falls
            // back to today's banked 5-minute trace when idle.
            LiquidLiveHR(fallback: hrValues, fallbackSegments: hrSegments,
                         showsFallback: !sectionOrder.contains(.recoveryVitals))
                .padding(NoopVisualStyle.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .noopPanel(cornerRadius: NoopVisualStyle.cardRadius, surfaceOpacity: cardOpacity)
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityHint("Opens the full-day heart rate timeline")
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: LiquidHeartRateCardFrameKey.self,
                                       value: geometry.frame(in: .named(Self.daySwipeSpace)))
            }
        }
    }

    // MARK: - Your cards

    private var yourCardsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("Your cards", topPadding: 6) {
                Button { customizationDestination = .yourCards } label: { Text("Edit").todayTapTarget() }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit Your Cards")
            }
            // Data-driven off the SAME @AppStorage the CUSTOMISE editor writes, so add / remove /
            // reorder in Customise reflects on the home screen live. The hydration filter mirrors classic
            // TodayView's `enabledDashboardCards` and Android's `it != HYDRATION || hydrationEnabled`.
            LazyVGrid(columns: Self.twoColumns, spacing: NoopMetrics.gap) {
                ForEach(DashboardCardPrefs.decodeEnabled(dashboardCardsRaw)
                            .filter { hydrationEnabled || $0 != .hydration }
                            // Coach off means the AI is off, so the launcher card goes with the tab: leaving
                            // it on Today would offer a feature the wearer has just switched off. Same gate
                            // shape as hydration, so a card they had added keeps its place on re-enable.
                            .filter { coachEnabled || $0 != .coach }) { card in
                    liquidCard(for: card)
                }
            }
        }
    }

    /// The two equal columns of the v2 mini-card grids.
    private static let twoColumns = [GridItem(.flexible(), spacing: NoopMetrics.gap, alignment: .top),
                                     GridItem(.flexible(), spacing: NoopMetrics.gap, alignment: .top)]

    // MARK: - Added cards (#today-hosted-cards)

    /// The Trends/Sleep cards the user hosted in Today, in their arranged order. Data-driven off the SAME
    /// @AppStorage the Customise editor writes, so add / remove / reorder reflects live. Each hosted card
    /// is the SAME view its home tab renders (a mirror, not a copy) and carries its own header, so this
    /// section adds no header of its own. Renders nothing until the user hosts a card.
    @ViewBuilder
    private var hostedCardsSection: some View {
        let cards = HostedCardPrefs.decodeEnabled(hostedCardsRaw)
        if !cards.isEmpty {
            VStack(spacing: NoopMetrics.gap) {
                ForEach(cards) { card in
                    if let route = card.route {
                        NavigationLink(value: route) { hostedCard(for: card) }
                            .buttonStyle(.plain)
                    } else {
                        hostedCard(for: card)
                    }
                }
            }
        }
    }

    /// Dispatch a hosted card id to its native view. Each case renders the exact view the originating tab
    /// uses, so the Today copy and the home-tab copy never diverge. P0 hosts only Sleep marks.
    @ViewBuilder
    private func hostedCard(for card: HostedCard) -> some View {
        switch card {
        case .sleepMarks: SleepMarkCard()
        case .trendHRV, .trendRestingHR, .trendEffort:
            // The Trends charts, drawn by the tab's own ChartCard + TrendChart from the SAME resolved
            // points. `HostedTrendData` walks the `days` already in hand, so unlike the sleep model and
            // the stress curve there is no read behind these and nothing to gate.
            HostedTrendCard(card: card, days: repo.days, effortScale: effortScale)
        case .stressToday:
            // READ-ONLY, like `stages`: the Stress tab keeps the interactive timeline and this mirrors
            // only the display. `DaytimeLoadLine` is the tab's OWN line, so the host cannot drift into
            // a second drawing of the same day.
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    NoopCardHeader("Stress through the day", icon: "wave-sine")
                    if hostedStressHours.contains(where: { $0.level != nil }) {
                        DaytimeLoadLine(hours: hostedStressHours)
                    } else {
                        // The honest blank: only waking hours score and an hour needs enough heart
                        // rate, so early morning is empty by construction rather than by failure.
                        Text("Calibrating")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
                    }
                    if let maskedCaption = stressActivityMaskedHoursCaption(hostedStressActivityMaskedHours) {
                        Text(maskedCaption)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .asleepDuration: AsleepDurationCard(data: AsleepDurationData.build(days: repo.days))
        case .stagesVsTypical:
            // Renders from the shared SleepModel built in load() (same inputs as the Sleep tab). Until that
            // async build lands — or on a device with no usable latest night — show the graceful placeholder
            // rather than a half-built card, mirroring how AsleepDuration degrades on no data.
            if let m = hostedSleepModel {
                StagesVsTypicalCard(model: m)
            } else {
                hostedSleepPlaceholder
            }
        case .nightDetail:
            // Renders from the same shared SleepModel built in load(). Until that async build lands — or on a
            // device with no usable latest night — show the graceful placeholder, mirroring stagesVsTypical.
            if let m = hostedSleepModel {
                NightDetailCard(model: m)
            } else {
                hostedNightDetailPlaceholder
            }
        case .sleepDebt:
            // Renders from the same shared SleepModel built in load(). Until that async build lands — or on a
            // device with no usable latest night — show the graceful placeholder, mirroring stagesVsTypical.
            if let m = hostedSleepModel {
                SleepDebtLedgerCard(model: m)
            } else {
                hostedSleepDebtPlaceholder
            }
        case .stages:
            // The READ-ONLY latest-night stage card — same shared SleepModel (same night + intervals as the
            // Sleep tab), rendered without the Sleep tab's nav/edit/nap interaction. Until the async build
            // lands — or on a device with no usable latest night — show the placeholder, as above.
            if let m = hostedSleepModel {
                StagesCard(model: m)
            } else {
                hostedSleepPlaceholder
            }
        case .hoursVsNeeded:
            // The single hours-vs-need % metric, rendered from the same shared SleepModel built in load().
            // Until that async build lands — or on a device with no usable latest night — show the graceful
            // placeholder, mirroring stagesVsTypical.
            if let m = hostedSleepModel {
                HoursVsNeededCard(model: m)
            } else {
                hostedHoursVsNeededPlaceholder
            }
        case .consistency:
            // The single sleep-consistency % metric, rendered from the same shared SleepModel built in
            // load(). Until that async build lands — or on a device with no usable latest night — show the
            // graceful placeholder, mirroring stagesVsTypical.
            if let m = hostedSleepModel {
                ConsistencyCard(model: m)
            } else {
                hostedConsistencyPlaceholder
            }
        }
    }

    /// Graceful empty state for a SleepModel-backed hosted card whose model hasn't built yet (first frame)
    /// or is nil (no usable latest night). Keeps the hosted slot present + labelled so add/remove/reorder in
    /// Customise still reads, without rendering a partial card. #today-hosted-cards.
    private var hostedSleepPlaceholder: some View {
        hostedPlaceholder("Stages vs typical", caption: "Last night")
    }

    /// The same empty state, labelled for the hosted "Night detail" grid.
    private var hostedNightDetailPlaceholder: some View {
        hostedPlaceholder("Night detail", caption: "Metrics")
    }

    /// The same empty state, labelled for the hosted "Sleep-debt ledger".
    private var hostedSleepDebtPlaceholder: some View {
        hostedPlaceholder("Sleep-debt ledger", caption: "Last 14 nights")
    }

    /// The same empty state, labelled for the hosted "Hours vs Needed" card.
    private var hostedHoursVsNeededPlaceholder: some View {
        hostedPlaceholder("Hours vs Needed", caption: "Sleep")
    }

    /// The same empty state, labelled for the hosted "Consistency" card.
    private var hostedConsistencyPlaceholder: some View {
        hostedPlaceholder("Consistency", caption: "Sleep")
    }

    private func hostedPlaceholder(_ title: LocalizedStringKey, caption: LocalizedStringKey) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                NoopCardHeader(title, icon: "bed", captionKey: caption)
                Text("Not enough nights yet.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            }
        }
    }

    /// One "Your cards" mini card for a given card type — honours the user's CUSTOMISE selection + order.
    /// stress → Stress screen, sleep → Sleep, everything else → its metric detail.
    @ViewBuilder
    private func liquidCard(for card: DashboardCard) -> some View {
        switch card {
        case .stepsAverage30:
            TodayRollingStepsMiniCard(day: selectedDayKey, surfaceOpacity: cardOpacity)
        case .stress:
            // The Stress screen's own 0–3 formatter, so the card and the screen print the same tenth.
            cardLink(.stress, card: card, value: stress.map { StressTrace.formatLevel($0) },
                     unit: stress == nil ? nil : String(localized: "of 3"),
                     caption: stress == nil ? String(localized: "Calibrating") : card.subtitle)
        case .fitnessAge:
            // Bound symbol as on the Health hero (#2173), so a floored reading does not read exact here
            // and bounded there.
            cardLink(.metric("fitness_age"), card: card,
                     value: fitnessAge.map { "\(fitnessAgeBoundSymbol($0))" + intText($0) },
                     unit: card.unit)
        case .vo2max:
            cardLink(.metric("vo2max_est"), card: card, value: vo2max.map { String(Int($0.rounded())) },
                     unit: card.unit)
        case .vitality:
            cardLink(.metric("vitality"), card: card, value: vitality.map { String(Int($0.rounded())) },
                     unit: vitality == nil ? nil : String(localized: "of 100"))
        case .hrv:
            cardLink(.metric("hrv"), card: card, value: displayDay?.avgHrv.map { String(Int($0.rounded())) },
                     unit: card.unit)
        case .restingHr:
            cardLink(.metric("rhr"), card: card, value: displayDay?.restingHr.map(String.init), unit: card.unit)
        case .respiratory:
            cardLink(.metric("resp_rate"), card: card,
                     value: displayDay?.respRateBpm.map {
                         String(format: "%.1f", locale: AppLanguage.activeLocale, $0)
                     },
                     unit: card.unit)
        case .steps:
            // Route by the EXACT (key, source) the tile chose to display — measured my-whoop, imported
            // apple-health, or the my-whoop estimate — NOT by bare key (bare "steps" resolves to
            // apple-health and would mismatch a WHOOP-measured value). Order-independent.
            cardLink(.metricSourced(key: stepsDetailKey, source: stepsDetailSource), card: card,
                     value: stepCount == nil ? nil : stepsText)
        case .bloodOxygen:
            // #1627: the VALUE resolution is copied from the Key Metrics tile below rather than reinvented —
            // candidate fallback and experimental gating included — so the card and the tile cannot
            // disagree about the same day's number.
            let spo2Real = displayDay?.spo2Pct ?? vitalsDay?.spo2Pct
            let spo2CandidateOn = PuffinExperiment.spo2CandidateDisplayEnabled
            let spo2Candidate = spo2Real == nil && spo2CandidateOn
                ? spo2CandidateByDay[cachedDisplayDay?.day ?? selectedDayKey]
                : nil
            let spo2 = spo2Real ?? spo2Candidate
            // ALWAYS routes to "spo2", never "spo2_candidate": here the string is a NAVIGATION route
            // resolved against MetricCatalog, which has no "spo2_candidate" entry. The candidate MUST
            // carry its label — every other surface that shows it says "strap estimate (unverified)".
            cardLink(.metric("spo2"), card: card,
                     value: spo2.map { String(format: "%.0f", locale: AppLanguage.activeLocale, $0) },
                     unit: spo2 == nil ? nil : "%",
                     caption: spo2Candidate != nil ? String(localized: "strap estimate (unverified)") : card.subtitle)
        case .skinTemp:
            // The classic card's extracted resolver — the same one TodayView calls — so the formatting
            // decision is testable without a live view. #1844: lead with the night's measured ABSOLUTE.
            let skin = TodayView.skinTempCardValue(reading: skinTempLeadReading,
                                                   fahrenheit: temperatureUnit == .fahrenheit)
            cardLink(.metric("skin_temp"), card: card, value: skin == "—" ? nil : skin)
        case .calories:
            // #616: show the resolved imported-first value and route to the matching detail source, like
            // the Steps card.
            cardLink(.metricSourced(key: caloriesDetailKey, source: caloriesDetailSource), card: card,
                     value: caloriesCount.map { String(Int($0.rounded())) }, unit: card.unit)
        case .sleep:
            cardLink(.sleep, card: card, value: displayDay?.totalSleepMin == nil ? nil : sleepText)
        case .hydration:
            // #989: `HydrationGoal.cardValueString` is unit-tested and byte-identical to the Android twin;
            // the same "<total> / <goal> L" string as classic, "—" only when the goal is underivable.
            cardLink(.hydration, card: card,
                     value: hydrationGoalML.map {
                         HydrationGoal.cardValueString(totalML: hydrationTotalML ?? 0, goalML: $0)
                     })
        case .coupled:
            // A tap-through to the full Coupled day screen. No value.
            cardLink(.coupled, card: card, value: nil, showsDash: false)
        case .coach:
            // #1862: a sheet rather than a push — the point of the card is to try Coach WITHOUT
            // leaving Today.
            Button { showCoachLauncher = true } label: {
                TodayMiniCard(title: card.title, icon: card.phIcon, value: nil, caption: card.subtitle,
                              surfaceOpacity: cardOpacity)
            }
            .buttonStyle(LiquidPressStyle())
        }
    }

    /// One mini card pushing its `TabRoute` by value — the first hop off the Today root must ride
    /// the tab's `NavigationPath` so a re-tap of the Today tab can pop it (#198; see TabRoute.swift).
    /// A missing value prints the dash (a card that is ON shows that it has nothing, never a fake 0);
    /// `showsDash: false` is for the navigation-only cards that carry no metric at all.
    private func cardLink(_ route: TabRoute, card: DashboardCard, value: String?, unit: String? = nil,
                          caption: String? = nil, showsDash: Bool = true) -> some View {
        NavigationLink(value: route) {
            TodayMiniCard(title: card.title, icon: card.phIcon,
                          value: value ?? (showsDash ? Self.noValueDash : nil),
                          unit: value == nil ? nil : unit,
                          caption: caption ?? card.subtitle,
                          surfaceOpacity: cardOpacity)
        }
        .buttonStyle(LiquidPressStyle())
    }

    // MARK: - Synthesis (greeting + readiness pills + one-liner)

    /// Liquid parity with classic `effortZeroNote`: the "no cardio load yet" line shown in the synthesis
    /// card when today's Effort is ~0, so a calm day explains itself instead of a bare 0. Reuses classic's
    /// String Catalog entry verbatim — one key serves both Today screens.
    private var effortZeroNote: String? {
        guard EffortDisplay.showsZeroNote(strain: effortStrain(displayDay), isToday: selectedDayOffset == 0) else { return nil }
        return String(localized: "No cardio load yet. Effort builds once your heart rate climbs into your effort zone (around 50% of your heart-rate reserve). A calm day honestly reads near zero.")
    }

    /// The insight line: the readiness one-liner (or the calibration progress while the baseline forms).
    /// Tapping it expands the readiness summary, the old Synthesis card's show/hide.
    private var synthesisSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { synthesisExpanded.toggle() } } label: {
                // While the baseline calibrates, the honest "N of 4 nights" progress replaces the readiness
                // one-liner — the same swap classic makes (`calibrationDetail ?? synthesisCardDetail`).
                NoopInsightRow(text: Text(verbatim: chargeDisplay.calibrationDetail ?? synthLine))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(synthesisExpanded ? "Hides the readiness summary" : "Shows the readiness summary")
            // The reason the count is not moving, when nights are arriving empty. Sits under the progress
            // rather than replacing it: the wearer needs both the number and why.
            if let why = chargeDisplay.calibrationReason(
                dayKeys: repo.days.map(\.day), nightlyHrv: repo.days.map(\.avgHrv),
                today: Repository.logicalDayKey(Date())) {
                NoopInsightRow(verbatim: why, icon: "info")
            }
            // #530 follow-up: the classic hero's "no cardio load yet" note, shown on a calm day so today's
            // ~0 Effort explains itself instead of a bare 0.
            if let note = effortZeroNote {
                NoopInsightRow(verbatim: note, icon: "info")
            }
            if synthesisExpanded {
                Text(LocalizedStringKey(readiness.summary))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 30)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Recovery vitals (heart rate + vitals, Effort)

    private var recoveryVitalsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("Recovery vitals", topPadding: 6) {
                // The Today layout editor: section order and visibility, plus both nested card editors.
                Button { customizationDestination = .today } label: { Text("Edit").todayTapTarget() }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Customize Today")
            }
            vitalsCard
            effortCard
        }
    }

    /// The day's heart-rate trace over the overnight vitals. PER-FIELD, today-first carry: each vital
    /// reads today's own value, else falls back to the prior day that recorded THAT vital (#1842).
    /// Coalesced ONCE so the number and its route agree.
    private var vitalsCard: some View {
        let hrv = displayDay?.avgHrv ?? hrvDay?.avgHrv
        let rhr = (displayDay?.restingHr ?? restingHrDay?.restingHr).map(Double.init)
        let resp = displayDay?.respRateBpm ?? vitalsDay?.respRateBpm
        return VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: TabRoute.fullDayChart) {
                VStack(alignment: .leading, spacing: 12) {
                    NoopCardHeader("Heart rate", icon: "heart", caption: hrRangeCaption)
                    if hrValues.count >= 2 {
                        TodaySegmentedAreaChart(values: hrValues, segments: hrSegments)
                            .frame(height: 64)
                    } else {
                        Text(selectedDayOffset == 0 ? "No heart rate recorded yet today" : "No heart rate recorded this day")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .center)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the full-day heart rate timeline")
            // #706/#684: each vital pushes its own trend — routes taken from `liquidCard`'s own cases so
            // the two surfaces cannot send the same vital to different trends.
            NoopMetricRow {
                vitalMetric(value: hrv.map { String(Int($0.rounded())) }, unit: "ms",
                            label: String(localized: "Heart rate variability"), route: .metric("hrv"))
                vitalMetric(value: rhr.map { String(Int($0.rounded())) }, unit: "bpm",
                            label: String(localized: "Resting heart rate"), route: .metric("rhr"))
                vitalMetric(value: resp.map { String(format: "%.1f", locale: AppLanguage.activeLocale, $0) },
                            unit: "rpm", label: String(localized: "Breaths per minute"), route: .metric("resp_rate"))
            }
            .padding(.top, 14)
            if let line = vitalsProvenanceLine {
                Text(line)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.top, 10)
            }
        }
        .padding(NoopVisualStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .noopPanel(cornerRadius: NoopVisualStyle.cardRadius, surfaceOpacity: cardOpacity)
    }

    /// "Since midnight · 48–71 bpm" over the trace actually drawn. The window names what the loader read:
    /// the calendar day, or the sleep-onset day when that cycle mode is on.
    private var hrRangeCaption: String? {
        guard hrValues.count >= 2, let lo = hrValues.min(), let hi = hrValues.max() else { return nil }
        let range = "\(Int(lo.rounded()))–\(Int(hi.rounded())) bpm"
        let window = dayCycleMode == .sleepOnset ? String(localized: "Since sleep onset")
            : (selectedDayOffset == 0 ? String(localized: "Since midnight") : String(localized: "All day"))
        return "\(window) · \(range)"
    }

    private func vitalMetric(value: String?, unit: String, label: String, route: TabRoute) -> some View {
        NavigationLink(value: route) {
            NoopMetric(value: value ?? Self.noValueDash, unit: value == nil ? nil : unit, labelText: label)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Today's Effort against the window today's Charge suggests, with the day's activity under it.
    private var effortCard: some View {
        let strain = effortStrain(displayDay)
        return VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: TabRoute.metric(HeroRingMetric.effort)) {
                VStack(alignment: .leading, spacing: 12) {
                    NoopCardHeader("Effort", icon: "fire",
                                   caption: effortTargetText.map { String(localized: "Target \($0)") })
                    HStack(alignment: .bottom, spacing: 12) {
                        NoopDotNumber(strain.map { effortNumber($0) } ?? Self.noValueDash, size: 50)
                            .fixedSize()
                        Text("of \(UnitFormatter.effortScaleMax(effortScale))")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(.bottom, 6)
                        Spacer(minLength: 8)
                        if let band = effortBandWord(strain) {
                            NoopTag(verbatim: band, size: 13)
                                .padding(.bottom, 4)
                        }
                    }
                    NoopTrack(fraction: frac(strain) ?? 0, height: 10, target: effortTargetRange)
                        .padding(.top, 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            NoopMetricRow {
                NavigationLink(value: TabRoute.metricSourced(key: caloriesDetailKey, source: caloriesDetailSource)) {
                    NoopMetric(value: caloriesCount.map { Self.groupedInt($0) } ?? Self.noValueDash,
                               unit: caloriesCount == nil ? nil : "kcal",
                               labelText: String(localized: "Active calories"))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                NoopMetric(value: zoneMinutes2to5.map { String(Int($0.rounded())) } ?? Self.noValueDash,
                           unit: zoneMinutes2to5 == nil ? nil : "min",
                           labelText: String(localized: "HR zones 2–5"))
                NavigationLink(value: TabRoute.metricSourced(key: stepsDetailKey, source: stepsDetailSource)) {
                    NoopMetric(value: stepCount == nil ? Self.noValueDash : stepsText,
                               labelText: String(localized: "Steps"))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 16)
        }
        .padding(NoopVisualStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .noopPanel(cornerRadius: NoopVisualStyle.cardRadius, surfaceOpacity: cardOpacity)
    }

    private static func groupedInt(_ v: Double) -> String {
        Int(v.rounded()).formatted(.number.locale(AppLanguage.activeLocale))
    }

    // MARK: - Key metrics grid

    /// The chosen detailed-graph window's oldest day key (1 week / 2 weeks / 1 month ending on the
    /// selected day). The loader banks a 30-day superset; render filters down so a window change in the
    /// editor applies instantly, no reload.
    private var sparkWindowCutoffKey: String {
        let days = (keyMetricsWindowDays == 7 || keyMetricsWindowDays == 30) ? keyMetricsWindowDays : 14
        let cal = Calendar.current
        let anchor = cal.startOfDay(for: selectedLogicalDay)
        return Repository.localDayKey(cal.date(byAdding: .day, value: -(days - 1), to: anchor) ?? anchor)
    }

    /// A metric's spark values inside the chosen window, oldest → newest.
    private func windowedSpark(_ key: String) -> [Double] {
        let cutoff = sparkWindowCutoffKey
        return (kSparks[key] ?? []).filter { $0.0 >= cutoff }.map { $0.1 }
    }

    /// The Key-Metrics header's trailing label for the chosen detailed-graph window (Android twin).
    private var trendWindowLabel: String {
        switch keyMetricsWindowDays {
        case 7: return String(localized: "7-day trend")
        case 30: return String(localized: "30-day trend")
        default: return String(localized: "14-day trend")
        }
    }

    private var keyMetricsSection: some View {
        // HRV / Rest HR (+ Blood Oxygen / Respiratory) tiles share the recovery vitals' per-field
        // today-first carry so they don't blank at the rollover while Recovery/Strain/Rest stay strictly
        // today's own (they are scored surfaces).
        let hrv = displayDay?.avgHrv ?? hrvDay?.avgHrv
        let rhr = (displayDay?.restingHr ?? restingHrDay?.restingHr).map(Double.init)
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("Key metrics", topPadding: 6) {
                HStack(spacing: 10) {
                    // The label names the window the DETAILED tiles graph, so it is only honest while
                    // they are drawn: with the trend graphs off (the default) nothing in this section
                    // renders a trend, and the header was still announcing one (#2376).
                    if keyMetricsDetailed { Text(verbatim: trendWindowLabel) }
                    // #430 parity: the SAME editor the classic grid uses — selection + order + Detailed.
                    Button { customizationDestination = .keyMetrics } label: { Text("Edit").todayTapTarget() }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edit Key Metrics")
                }
            }
            // #430 parity: the grid honours the Key-Metrics editor (selection + order, all ten metrics)
            // instead of a hard-coded six, aligning the liquid grid with the classic grid and Android.
            LazyVGrid(columns: Self.twoColumns, spacing: NoopMetrics.gap) {
                ForEach(enabledKeyMetrics) { metric in
                    ktileFor(metric, hrv: hrv, rhr: rhr)
                }
            }
            NavigationLink(value: TabRoute.metricExplorer) {
                TodayFooterLink(title: "Show all metrics")
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
    }

    /// One editor-selected Key-Metric tile: the metric's value/tint/fill exactly as the old hard-coded
    /// tiles read them (Android's descriptor map is the twin), plus the metric-catalog `key` that names
    /// both its 14-day spark series and its tap-through detail. Weight has no liquid value source yet —
    /// its tile reads "—" but still taps through to the weight trend detail (which has its own series).
    @ViewBuilder
    private func ktileFor(_ metric: KeyMetric, hrv: Double?, rhr: Double?) -> some View {
        switch metric {
        case .charge:
            // Reads the SAME resolved Charge the hero draws, not `displayDay?.recovery` raw — the tile and the
            // hero are the same number, so a carry that reached only one of them would put two answers for
            // Charge on one screen. (#543: one prior row feeds every recovery-derived read-out.) Strain below
            // stays raw, matching the Effort hero, which correctly does not carry.
            ktile(metric.title, icon: keyMetricIcon(metric), intText(chargeDisplay.pct), "%", StrandPalette.chargeColor, frac(chargeDisplay.pct), key: HeroRingMetric.charge)
        case .effort:
            // #492: Effort is a load index (0–100 NOOP / 0–21 WHOOP), NOT a percentage, and the unit was
            // wrong on either axis. Fixed on Android and in `TodayView` at the time; THIS view kept the old
            // form, so the tile also ignored the scale toggle — the hero ring above it read ~8 on the WHOOP
            // axis while this read 38. `effortText` is the same shared formatter the ring and the workout
            // rows use, so all three now agree by construction.
            ktile(metric.title, icon: keyMetricIcon(metric), effortStrain(displayDay).map { effortNumber($0) } ?? Self.noValueDash, "", StrandPalette.effortColor, frac(effortStrain(displayDay)), key: HeroRingMetric.effort)
        case .rest:
            ktile(metric.title, icon: keyMetricIcon(metric), intText(restScore), "%", StrandPalette.restColor, frac(restScore), key: HeroRingMetric.rest)
        case .hrv:
            ktile(metric.title, icon: keyMetricIcon(metric), intText(hrv), "ms", StrandPalette.metricCyan, fracOver(hrv, 120), key: "hrv")
        case .restingHr:
            ktile(metric.title, icon: keyMetricIcon(metric), intText(rhr), "bpm", StrandPalette.metricRose, fracOver(rhr, 100), key: "rhr")
        case .bloodOxygen:
            // Queue 11a: the Liquid tile used to read `spo2Pct` only, with no candidate fallback at all
            // (unlike the classic `TodayView`/`VitalSignsSummary`), so an Oura-only or BLE-only WHOOP
            // 5/MG install with the experimental toggle ON still saw a bare "—" here. Falls back to the
            // device-conditional "spo2_candidate" mean (WHOOP: `spo2_candidate_82`; Oura: ceiling@100
            // `0x6F`, see `AnalyticsEngine.nightlySpo2CeilingMean`) only when `spo2Pct` is nil AND the
            // toggle is ON — same gating as the classic tile, never as the default.
            let spo2Real = displayDay?.spo2Pct ?? vitalsDay?.spo2Pct
            let spo2CandidateOn = PuffinExperiment.spo2CandidateDisplayEnabled
            let spo2CandidateValue = spo2Real == nil && spo2CandidateOn
                ? spo2CandidateByDay[cachedDisplayDay?.day ?? selectedDayKey]
                : nil
            let spo2 = spo2Real ?? spo2CandidateValue
            ktile(metric.title, icon: keyMetricIcon(metric), intText(spo2), "%", StrandPalette.metricCyan, fracOver(spo2, 100), key: spo2CandidateValue != nil ? "spo2_candidate" : "spo2",
                  caption: spo2CandidateValue != nil ? String(localized: "strap estimate (unverified)") : nil)
        case .respiratory:
            let resp = displayDay?.respRateBpm ?? vitalsDay?.respRateBpm ?? respDay?.respRateBpm
            ktile(metric.title, icon: keyMetricIcon(metric), resp.map { String(format: "%.1f", locale: AppLanguage.activeLocale, $0) } ?? "—", "rpm", StrandPalette.accent, fracOver(resp, 24), key: "resp_rate")
        case .steps:
            ktile(metric.title, icon: keyMetricIcon(metric), stepsText, "", StrandPalette.chargeColor,
                  fracOver(stepCount, 10000), key: stepsDetailKey, detailMetric: stepsDetailMetric)
        case .weight:
            let (val, cap) = weightTile(weightKg)
            ktile(metric.title, icon: keyMetricIcon(metric), val, "", StrandPalette.metricAmber, nil, key: "weight", caption: cap)
        case .calories:
            // #616: imported-first value (imported ?: activeKcalEst) + route the tap to the matching
            // detail source, so the number, its sparkline and the chart it opens all agree.
            ktile(metric.title, icon: keyMetricIcon(metric), intText(caloriesCount), "kcal", StrandPalette.metricAmber,
                  fracOver(caloriesCount, 800), key: "energy_kcal", detailMetric: caloriesDetailMetric)
        case .skinTemp:
            // Added 2026-08-24 (queue 11c follow-up): first Key Metrics appearance for Skin Temp — was
            // already a "Your Cards" tile (`DashboardCard.skinTemp`), never a Key Metrics one. Same
            // 2-level carry the Blood Oxygen case just above uses (displayDay → the cached vitals carry),
            // and the SAME `SkinTempDisplay` formatter every other skin-temp surface uses so a deviation
            // reads "+0.1 Δ°C" here exactly as it does on "Your Cards"/the Deep Timeline, never the plain
            // `%+.1f°` that read a fabricated absolute value for a signed deviation (#622).
            // #1844: same lead-with-the-absolute resolution as "Your Cards" above, so the two agree.
            let skinText = TodayView.skinTempCardValue(reading: skinTempLeadReading,
                                                       fahrenheit: temperatureUnit == .fahrenheit)
            // The card's own unit is deliberately empty — the value carries "°C"/"Δ°F" itself, same as
            // the classic TodayView Skin Temp card.
            ktile(metric.title, icon: keyMetricIcon(metric), skinText, "", StrandPalette.metricAmber, nil, key: "skin_temp")
        }
    }

    private func keyMetricIcon(_ metric: KeyMetric) -> String { metric.phIcon }

    private func ktile(_ label: String, icon: String, _ value: String, _ unit: String, _ tint: Color, _ frac: Double?,
                       key: String? = nil, detailMetric: MetricDescriptor? = nil, caption: String? = nil) -> some View {
        // #430 parity: DETAILED tiles grow the trend graph under the value, windowed to the editor's
        // 1-week / 2-week / 1-month choice (the Android twin). A metric with no windowed series keeps a
        // clear slot of the same height so every tile in a detailed row stays equal-height.
        let tile = TodayMiniCard(title: label, icon: icon, value: value, unit: unit,
                                 // Optional sub-value caveat (queue 11a): only ever set for an unvalidated
                                 // candidate fallback (the SpO₂ strap estimate) or the weight provenance.
                                 caption: caption,
                                 spark: keyMetricsDetailed ? key.map { windowedSpark($0) } : nil,
                                 showsSparkSlot: keyMetricsDetailed,
                                 surfaceOpacity: cardOpacity)
        // #430 parity: tap -> the metric's trend detail (the same Explore dossier its MetricRow pushes,
        // closure-based NavigationLink per #38). A metric with no catalog entry stays inert.
        return Group {
            if let metric = detailMetric ?? key.flatMap({ key in
                MetricCatalog.all.first(where: { $0.key == key })
            }) {
                NavigationLink { MetricDetailView(metric: metric) } label: { tile }
                    .buttonStyle(LiquidPressStyle())
            } else {
                tile
            }
        }
    }

    // MARK: - Last workouts

    /// The two most recent workouts up to the selected day, newest first, with the running total.
    private var lastWorkoutsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("Last workouts", caption: String(localized: "\(workouts.count) total"), topPadding: 6)
            NavigationLink(value: TabRoute.workouts) {
                NoopList {
                    if workouts.isEmpty {
                        NoopRow("No workouts yet", icon: "heartbeat")
                    } else {
                        ForEach(workouts.prefix(2), id: \.startTs) { w in
                            workoutRow(w)
                        }
                    }
                }
            }
            .buttonStyle(LiquidPressStyle())
        }
    }

    private func workoutRow(_ w: WorkoutRow) -> some View {
        NoopRow(title: Text(verbatim: SportName.display(w.sport)),
                caption: Text(verbatim: workoutSub(w)),
                icon: TodayV2Icons.sport(w.sport)) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: effortText(w.strain))
                    .font(StrandFont.book(17))
                    .foregroundStyle(StrandPalette.textPrimary)
                // The app's own word for the score ("Belastung"), set in caps, so the row and the hero
                // name it the same way in every language.
                Text("Effort")
                    .textCase(.uppercase)
                    .font(StrandFont.light(10))
                    .tracking(0.8)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    // MARK: - Sync footer

    /// "Synced from WHOOP 4.0 · 2 min ago · View sources" → Data sources, and the layout editor below it.
    private var dataSourcesSection: some View {
        VStack(spacing: 12) {
            NavigationLink(value: TabRoute.dataSources) {
                LiquidSyncFooterLine(source: heroSourceLabel)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { customizationDestination = .today } label: {
                TodayFooterLink(title: "Customize Today")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Customize Today")
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Data

    private func load() async {
        // #989: today's hydration total + goal. One metricSeries row + a UserDefaults read, same as classic
        // TodayView.reloadHydration(). Cleared when the feature is off so the card can't show a stale total.
        if hydrationEnabled {
            hydrationTotalML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
            hydrationGoalML = repo.hydrationGoalML(profileSex: profile.sex)
        } else {
            hydrationTotalML = nil
            hydrationGoalML = nil
        }
        // Resolve the O(days) lookups ONCE here (not on every body re-render): the selected day and the
        // readiness verdict. Both scan repo.days (up to 599 rows); doing it per-render was the stutter.
        let day = resolveDisplayDay()
        cachedDisplayDay = day
        await reloadRRUnitPolicy()
        cachedReadiness = ReadinessEngine.evaluate(days: repo.days, today: day?.day)
        // Prior-day vitals carry, resolved ONCE here (never in body). Bound to today's own key so it can't
        // echo today's still-forming row; only on today (a past day's own row is the whole story).
        let tkey = cachedDisplayDay?.day ?? selectedDayKey
        cachedVitalsDay = (selectedDayOffset == 0) ? Repository.lastVitalsDay(days: repo.days, todayKey: tkey) : nil
        cachedRespDay = (selectedDayOffset == 0) ? Repository.lastRespDay(days: repo.days, todayKey: tkey) : nil
        cachedHrvDay = (selectedDayOffset == 0) ? Repository.lastHrvDay(days: repo.days, todayKey: tkey) : nil
        cachedRestingHrDay = (selectedDayOffset == 0) ? Repository.lastRestingHrDay(days: repo.days, todayKey: tkey) : nil
        cachedSkinTempReadingDay = (selectedDayOffset == 0) ? Repository.lastSkinTempReadingDay(days: repo.days, todayKey: tkey) : nil
        // Charge carry (#543) + the honest label, resolved here for the same reason as the two above: the
        // selector below scans repo.days. Calibration nights come from the SAME `RecoveryScorer` helper the
        // classic Today reads, so the two screens agree on when a wearer is genuinely mid-calibration
        // rather than simply lacking a scored night.
        let calNights = (selectedDayOffset == 0)
            ? RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv),
                                               dayKeys: repo.days.map(\.day),
                                               hasRecovery: day?.recovery != nil)
            : nil
        let priorScored = TodayView.lastScoredRecoveryDay(
            days: repo.days, selectedDayKey: tkey,
            isToday: selectedDayOffset == 0,
            todayScored: day?.recovery != nil,
            isCalibrating: calNights != nil
        )
        cachedChargeDisplay = ChargeDisplay.resolve(
            todayRecovery: day?.recovery,
            priorScored: priorScored,
            calibrationNights: calNights,
            todayKey: tkey)

        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedLogicalDay)
        let calendarFrom = Int(dayStart.timeIntervalSince1970)
        // today → midnight..now; a past day → its full 24h (a missing morning reads as empty space).
        let calendarTo: Int = selectedDayOffset == 0
            ? Int(Date().timeIntervalSince1970)
            : Int((cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart).timeIntervalSince1970)
        let nextDayKey = Repository.localDayKey(cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart)
        let cycleMarkers = dayCycleMode == .sleepOnset
            ? await repo.exploreSeries(key: DayCycleIntelligenceIntegration.onsetKey, source: "my-whoop") : []
        let from = cycleMarkers.last(where: { $0.day == selectedDayKey }).map { Int($0.value) } ?? calendarFrom
        let toExclusive = cycleMarkers.last(where: { $0.day == nextDayKey }).map { Int($0.value) } ?? calendarTo
        let to = max(from, toExclusive - 1)
        // #1001: in-progress Effort for TODAY, over the SAME window resolved just above (the day-cycle
        // onset when that mode is on, else calendar midnight → now) with the identical params the daily
        // pass uses, so the live number matches what the engine will eventually persist. Below
        // `StrainScorer.minReadings` the scorer returns nil and the read-outs fall back to the stored row
        // — never a fabricated value. A navigated past day clears it.
        // An EXPLICIT limit, not the 8000 default: that default is chart-sized, and this read is
        // whole-window. `hrSamples` is `ORDER BY ts ASC LIMIT`, so truncation drops the NEWEST rows —
        // at the ~18k HR rows a real day banks, the default covered roughly the first ten hours and the
        // live score silently stopped climbing after that. It failed safe (`effectiveEffort` takes the
        // max, so the stored row simply won) which is why it went unnoticed. 200_000 is what every
        // other whole-window HR consumer already passes. One read serves today's live Effort and the
        // Effort card's zone minutes.
        let todayHr = await repo.hrSamples(from: from, to: to, limit: 200_000)
        // The Effort card's "HR zones 2–5": time above zone 1 over the same window, against the
        // wearer's own zones (the workout detail's `HRZones.timeInZone`). nil with no samples.
        zoneMinutes2to5 = todayHr.isEmpty ? nil
            : HRZones.timeInZone(todayHr, zoneSet: profile.hrZoneSet).seconds.dropFirst().reduce(0, +) / 60
        let liveStrainLocal: Double?
        if selectedDayOffset == 0 {
            // #2460: the manual HR-max override, then Tanaka, exactly as AnalyticsEngine resolves it
            // for the STORED day. These two numbers meet in `effectiveEffort`, which takes the larger,
            // so a live value on the formula's yardstick outvoted an override set because the real
            // maximum is above it. See `ProfileStore.effortHRmax`.
            let maxHR = profile.effortHRmax
            let restHR = day?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
            liveStrainLocal = StrainScorer.strain(todayHr, maxHR: maxHR, restingHR: restHR,
                                                  method: PuffinExperiment.effortMethod, sex: profile.sex)
        } else {
            liveStrainLocal = nil
        }
        liveTodayStrain = liveStrainLocal

        async let restA = repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        async let stressA = repo.series(key: "stress", source: "my-whoop")
        async let fitA = repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        async let vo2A = repo.exploreSeries(key: "vo2max_est", source: "my-whoop")
        async let vitA = repo.exploreSeries(key: "vitality", source: "my-whoop")
        async let stepsA = repo.exploreSeries(key: "steps_est", source: "my-whoop")
        // Queue 11a: SpO₂ candidate fallback (see `spo2CandidateByDay`'s declaration).
        async let spo2CandA = repo.exploreSeries(key: "spo2_candidate", source: "my-whoop")
        async let weightA = repo.series(key: "weight", source: "apple-health", days: 91)
        async let appleA = repo.appleDailyRows()
        async let hrA = repo.hrBuckets(from: from, to: to, bucketSeconds: 300)
        async let wkA = repo.workoutRows()
        // Ask the same cross-source resolver the Classic Today view uses which source actually won each
        // displayed score. Include the exact carried-Charge day; a fixed relative lookback can miss a
        // legitimately old carried score.
        let sourceDayKey = selectedDayKey
        let sourceFromDay = min(sourceDayKey, priorScored?.day ?? sourceDayKey)
        async let chargeSourceA = repo.resolvedSeries(key: "recovery", source: Repository.whoopSource,
                                                      from: sourceFromDay, to: sourceDayKey)
        async let effortSourceA = repo.resolvedSeries(key: "strain", source: Repository.whoopSource,
                                                      from: sourceDayKey, to: sourceDayKey)
        async let restSourceA = repo.resolvedSeries(key: "sleep_performance", source: Repository.whoopSource,
                                                    from: sourceDayKey, to: sourceDayKey)

        let restSeries = await restA
        let stepsSeries = await stepsA
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        // Selected day's Rest; tail fallback only at offset 0 (a past day with no row shows nothing) AND
        // only when the tail night is still fresh. #977: a live 5.0 whose sleep never scores (no overnight
        // gravity ⇒ no sleep_performance point ever written) used to pin Rest to the weeks-old series tail
        // forever while Charge advanced; freshness-gate the tail-fallback so a stale tail falls through to
        // the Rest hero's No-Data/calibrating state (same empty treatment Effort uses) instead of freezing.
        restScore = TodayView.freshRestScore(
            todayValue: restByDay[selectedDayKey], lastDay: restSeries.last?.day,
            lastValue: restSeries.last?.value, isTodaySelected: selectedDayOffset == 0,
            todayKey: selectedDayKey)
        // StressModel loops the full history to build its baseline — run it OFF the main actor so a big
        // history doesn't stutter the UI. Snapshot the inputs (value types) into the detached task.
        let storedStress = await stressA
        let daysSnapshot = repo.days

        // #430 parity: the day-keyed series the DETAILED Key-Metrics tiles graph — a trailing CALENDAR
        // window ending on the selected day (not the last-N stored rows, which on an old import showed
        // months-old data as a fresh trend, issue #23). The loader banks the 30-day SUPERSET; the chosen
        // 1-week/2-week/1-month window filters at render (windowedSpark), so a picker change applies without
        // a reload. Keys mirror the metric catalog so a tile's graph, its tap-through detail and Android's
        // Window all read the same signal. Rest reuses the already-loaded sleep_performance series.
        let sparkCutoff = Repository.localDayKey(cal.date(byAdding: .day, value: -29, to: dayStart) ?? dayStart)
        let sparkRows = daysSnapshot.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey }
        // #616: imported-first calorie spark (the day's imported Apple active energy ?: NOOP's on-device
        // estimate) over the window, so a Health-Connect / Apple-only calorie user gets a trend too —
        // matching the imported-first VALUE. Union of imported days + strap-row days. Mirrors Android's
        // caloriesSpark (windowed caloriesByDay).
        let appleRowsForSpark = await appleA
        // Queue 11a: SpO₂ candidate fallback — day-keyed for the tile's value lookup, windowed for its
        // detailed-mode sparkline below (same shape as `restByDay`/`kSparks["spo2"]` above).
        let spo2CandSeries = await spo2CandA
        spo2CandidateByDay = Dictionary(spo2CandSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        var winImportedKcal: [String: Double] = [:]
        for r in appleRowsForSpark where r.day >= sparkCutoff && r.day <= selectedDayKey {
            if let k = r.activeKcal { winImportedKcal[r.day] = max(winImportedKcal[r.day] ?? 0, k) }
        }
        var winOnDeviceKcal: [String: Double] = [:]
        for r in sparkRows { if let k = r.activeKcalEst { winOnDeviceKcal[r.day] = k } }
        let energyKcalSpark: [(String, Double)] = Set(winImportedKcal.keys).union(winOnDeviceKcal.keys).sorted()
            .compactMap { day in (winImportedKcal[day] ?? winOnDeviceKcal[day]).map { (day, $0) } }
        kSparks = [
            "recovery": sparkRows.compactMap { r in r.recovery.map { (r.day, $0) } },
            "strain": sparkRows.compactMap { r in r.strain.map { (r.day, $0) } },
            "hrv": sparkRows.compactMap { r in r.avgHrv.map { (r.day, $0) } },
            "rhr": sparkRows.compactMap { r in r.restingHr.map { (r.day, Double($0)) } },
            "spo2": sparkRows.compactMap { r in r.spo2Pct.map { (r.day, $0) } },
            "spo2_candidate": spo2CandSeries.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey },
            // Added 2026-08-24 (queue 11c follow-up) for the new Skin Temp Key Metrics tile — already
            // loaded on `sparkRows` (`daysSnapshot`), same as every other DailyMetric-column tile above.
            "skin_temp": sparkRows.compactMap { r in r.skinTempDevC.map { (r.day, $0) } },
            "resp_rate": sparkRows.compactMap { r in r.respRateBpm.map { (r.day, $0) } },
            "steps": sparkRows.compactMap { r in r.steps.map { (r.day, Double($0)) } },
            // #616: the Calories tile drew no trend line — this dict had no matching entry, so windowedSpark
            // returned []. Bank the imported-first calorie series (built above) so the sparkline matches the
            // tile's imported-first number and a Health-Connect / Apple-only user gets a trend.
            "energy_kcal": energyKcalSpark,
            "steps_est": stepsSeries.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey }
                .map { ($0.day, $0.value) },
            "sleep_performance": restSeries.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey }
                .map { ($0.day, $0.value) },
            "weight": (await weightA).filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey },
        ]
        stress = await Task.detached(priority: .utility) {
            StressModel(days: daysSnapshot, stored: storedStress)?.score
        }.value
        fitnessAge = (await fitA).last?.value   // history-wide latest banked (not day-scoped)
        vo2max = (await vo2A).last?.value        // #1391: latest banked VO₂max estimate
        vitality = (await vitA).last?.value
        // Steps is a DAILY metric, so key it to the SELECTED day (like restScore above), not the history-wide
        // latest. Without this, swiping to a past day with no strap step count showed today's estimate (the
        // `.last` value) instead of that day's. Mirrors the classic Today's stepsEstByDay[selectedDayKey].
        let stepsByDay = Dictionary(stepsSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        stepsEst = stepsByDay[selectedDayKey] ?? (selectedDayOffset == 0 ? stepsSeries.last?.value : nil)
        // Imported Apple Health steps for the SELECTED day (max across rows), the middle tier between the
        // measured strap count and the motion estimate. Health Connect is Android-only, so apple-health is
        // the sole import source on iOS. Mirrors Android `stepsForDay` (#377).
        importedStepsDay = (await appleA).filter { $0.day == selectedDayKey }.compactMap { $0.steps }.max()
        // #616: same-day imported active energy — the calorie fallback when the strap banked no on-device
        // HR estimate for the day, so the tile/card/detail agree (imported-first, mirrors steps).
        importedActiveKcalDay = (await appleA).filter { $0.day == selectedDayKey }.compactMap { $0.activeKcal }.max()

        // Weight for the SELECTED day: prefers a real Apple-Health reading (today's daily, else the
        // "weight" series' newest point so a sparse-but-recent value still renders). Falls back to the
        // user's profile weight in the renderer (weightTile).
        let appleRows = await appleA
        let weightSeries = await weightA
        weightKg = appleRows.filter { $0.day == selectedDayKey }.compactMap { $0.weightKg }.max()
            ?? weightSeries.last(where: { $0.day <= selectedDayKey })?.value

        // Awaited ONCE: the timestamps and the means have to come from the same read, or the segments
        // would describe a different series than the one drawn.
        let hrBuckets = await hrA
        hrValues = hrBuckets.map { $0.bpm }
        hrSegments = hrGapSegments(bucketTs: hrBuckets.map { $0.ts }, bucketSeconds: 300)
        // Every workout up to the end of the selected day (newest first): the section shows the latest
        // two and the running total, so a rest day still shows the last sessions rather than nothing.
        workouts = (await wkA).filter { $0.startTs < to }

        let (chargeSource, effortSource, restSource) = await (chargeSourceA, effortSourceA, restSourceA)
        let sourceResolutions = [
            ("recovery", chargeSource),
            ("strain", effortSource),
            ("sleep_performance", restSource),
        ]
        var providers: [String: ScoreInputProvider] = [:]
        for (metric, resolution) in sourceResolutions {
            let selectedPoint = resolution.points.last(where: { $0.day == sourceDayKey })
            let winner = selectedPoint
                ?? (metric == "recovery"
                    ? priorScored.flatMap { prior in resolution.points.last(where: { $0.day == prior.day }) }
                    : nil)
            if let winner {
                providers[metric] = await repo.scoreInputProvider(
                    resolvedSource: winner.source,
                    day: winner.day,
                    metricKey: metric
                )
            }
        }
        heroProviderByMetric = providers

        // #today-hosted-cards: build the shared SleepModel that backs the hosted sleep cards, but ONLY when
        // at least one sleep-origin card is actually hosted — otherwise Today pays no extra Repository cost.
        // The inputs (allSleepSessions / habitualMidsleepSec / sessionMotions) are loaded exactly as the
        // Sleep tab loads them, then handed to the SAME pure `SleepModel.build`, so a hosted card renders
        // numbers byte-identical to the Sleep tab. Reused by every SleepModel-backed hosted card (built once).
        let sleepOrigin = String(localized: "Sleep")
        if HostedCardPrefs.decodeEnabled(hostedCardsRaw).contains(where: { $0.origin == sleepOrigin }) {
            let hostedSessions = await repo.allSleepSessions()
            let hostedHabitual = await repo.habitualMidsleepSec()
            let hostedMotion = await repo.sessionMotions(sessions: hostedSessions)
            hostedSleepModel = SleepModel.build(SleepModelInputs(
                days: repo.days,
                sleeps: repo.sleeps,
                allSessions: hostedSessions,
                importedSleep: repo.importedSleep,
                habitualMidsleepSec: hostedHabitual,
                motionByStart: hostedMotion))
        } else {
            hostedSleepModel = nil
        }

        // #2040: and today's stress, on the same "only when hosted" rule.
        if HostedCardPrefs.decodeEnabled(hostedCardsRaw).contains(.stressToday) {
            let result = await StressDayCurve.today(
                repo: repo,
                personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled
            )?.result
            hostedStressHours = result?.timeline ?? []
            hostedStressActivityMaskedHours = result?.activityMaskedHours ?? 0
        } else {
            hostedStressHours = []
            hostedStressActivityMaskedHours = 0
        }
    }

    /// Re-read the indexed first-beat bounds on each load, so a new labelled sync clears the note.
    private func reloadRRUnitPolicy() async {
        guard let store = await repo.storeHandle() else {
            whoop5StrictRR = false
            firstRecordedRRDay = nil
            firstScorableRRDay = nil
            return
        }
        let owner = repo.deviceId
        func dayKey(_ ts: Int?) -> String? {
            ts.map { Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0))) }
        }
        whoop5StrictRR = (try? await store.isWhoop5RRSource(deviceId: owner)) ?? false
        firstRecordedRRDay = dayKey((try? await store.firstRecordedRRTimestamp(deviceId: owner)) ?? nil)
        firstScorableRRDay = dayKey((try? await store.firstScorableWhoop5RRTimestamp(deviceId: owner)) ?? nil)
    }

    // MARK: - Derived (sync, off repo.today / repo.days)

    /// Cached in load() — ReadinessEngine.evaluate scans the full history and was invoked ~3× per body
    /// pass (the hero captions + synthLine + readiness.summary). The fallback runs only in the brief window
    /// before the first load() populates the cache.
    private var readiness: ReadinessEngine.Readiness {
        cachedReadiness ?? ReadinessEngine.evaluate(days: repo.days, today: cachedDisplayDay?.day)
    }

    /// One card-level provenance label. Identical winners collapse to one name; mixed scores show at most
    /// two distinct winners in Charge / Effort / Rest order so the compact badge stays readable.
    private var heroSourceLabel: String? {
        Self.heroSourceLabel(
            providers: ["recovery", "strain", "sleep_performance"].compactMap { heroProviderByMetric[$0] })
    }

    /// Pure aggregation seam for the Liquid hero. The provider mapper names the sensors/imports that
    /// supplied the score inputs; identical names collapse and the compact badge is capped at two.
    static func heroSourceLabel(providers: [ScoreInputProvider]) -> String? {
        var seen = Set<String>()
        var labels: [String] = []
        for provider in providers {
            let label = TodayView.todayScoreProviderLabel(
                sourceId: provider.sourceId,
                brand: provider.brand
            )
            if seen.insert(label).inserted { labels.append(label) }
            if labels.count == 2 { break }
        }
        return labels.isEmpty ? nil : labels.joined(separator: " + ")
    }

    private var synthLine: String {
        // #612: when still calibrating BECAUSE the strap stopped delivering nights (connected, but no new
        // night for > staleDays), say so directly instead of "still learning your baseline" — the honest
        // calibrating state with its reason attached. `stale` is always > staleDays (14), so always plural.
        if readiness.level == .insufficient,
           let stale = Baselines.nightsSinceNewestValidNight(dayKeys: repo.days.map(\.day),
                                                             nightlyHrv: repo.days.map(\.avgHrv),
                                                             today: Repository.logicalDayKey(Date())),
           stale > Baselines.staleDays {
            return String(localized: "No new nights from your strap for \(stale) days. Check it's connected and saving data.")
        }
        switch readiness.level {
        case .primed: return String(localized: "You're primed. A hard session should land well today.")
        case .balanced: return String(localized: "You're in a good spot for training.")
        case .strained: return String(localized: "Signals are down a touch. Keep it easy today.")
        case .rundown: return String(localized: "Several recovery signals are down. Prioritise rest today.")
        case .insufficient: return String(localized: "Still learning your baseline. A few more nights and this fills in.")
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? String(localized: "Good morning")
            : h < 17 ? String(localized: "Good afternoon")
            : String(localized: "Good evening")
    }

    // Measured strap count ?: imported Apple Health count ?: motion estimate — the same precedence the
    // detail routing follows below, so the tapped-through source always matches the number shown (#377).
    private var stepCount: Double? {
        displayDay?.steps.map(Double.init) ?? importedStepsDay.map(Double.init) ?? stepsEst
    }

    private var stepsDetailMetric: MetricDescriptor? {
        MetricCatalog.todayStepsMetric(hasMeasuredSteps: displayDay?.steps != nil,
                                       hasImportedSteps: importedStepsDay != nil)
    }

    private var stepsDetailKey: String { stepsDetailMetric?.key ?? "steps_est" }
    private var stepsDetailSource: String { stepsDetailMetric?.source ?? "my-whoop" }

    // #616: calories resolved IMPORTED-FIRST (the day's imported Apple active energy — the figure these
    // surfaces already showed — else NOOP's on-device HR estimate `activeKcalEst`) — one number across the
    // tile, card and the detail it taps to. Mirrors the steps precedence above.
    private var caloriesCount: Double? {
        importedActiveKcalDay ?? displayDay?.activeKcalEst
    }

    private var caloriesDetailMetric: MetricDescriptor? {
        MetricCatalog.todayCaloriesMetric(hasImportedKcal: importedActiveKcalDay != nil,
                                          hasOnDeviceKcal: displayDay?.activeKcalEst != nil)
    }

    private var caloriesDetailKey: String { caloriesDetailMetric?.key ?? "energy_kcal" }
    private var caloriesDetailSource: String { caloriesDetailMetric?.source ?? "my-whoop" }

    // MARK: - Formatting

    private func frac(_ v: Double?) -> Double? { v.map { max(0, min(1, $0 / 100)) } }
    private func fracOver(_ v: Double?, _ over: Double) -> Double? { v.map { max(0, min(1, $0 / over)) } }

    /// What a tile shows when the metric has no value. One constant rather than a dash repeated at each
    /// site, because the unit-suppression below has to recognise it.
    static let noValueDash = "–"

    /// Join a formatted tile value with its unit, dropping the unit when there is no value.
    ///
    /// #492 and the `–%` it left behind: a missing metric rendered its placeholder AND its unit, so an
    /// empty Strain tile read `–%`, which parses as "minus percent" rather than "no data". Android has
    /// had the guard all along (`unit = if (restScore != null) "%" else ""`, and `withUnit`'s NO_DATA
    /// check); this is the iOS twin of it. `%` binds tight, every other unit takes a space.
    static func tileDisplayValue(_ value: String, unit: String) -> String {
        guard !unit.isEmpty, value != noValueDash else { return value }
        return unit == "%" ? value + unit : value + " " + unit
    }

    private func intText(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? Self.noValueDash }

    private func unitText(_ v: Double?, _ unit: String, decimals: Int = 0) -> String {
        guard let v else { return Self.noValueDash }
        let n = decimals > 0 ? String(format: "%.\(decimals)f", locale: AppLanguage.activeLocale, v) : String(Int(v.rounded()))
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    private var stressText: String { stress.map { String(Int($0.rounded())) } ?? String(localized: "Calibrating") }

    private var sleepText: String {
        guard let m = displayDay?.totalSleepMin else { return "–" }
        return "\(Int(m) / 60)h \(Int(m) % 60)m"
    }

    private var stepsText: String {
        guard let s = stepCount else { return "–" }
        return Self.groupingFormatter.string(from: NSNumber(value: Int(s))) ?? "\(Int(s))"
    }

    /// One shared grouping formatter: `stepsText` is read several times per body pass, and a fresh
    /// NumberFormatter each time was measurable on the ~1 Hz re-renders.
    private static let groupingFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    // °C / °F for the Skin Temp card, resolved exactly the way the other six screens that show a
    // temperature resolve it (TodayView, FullDayChartView, MetricExplorerView x2, SettingsView,
    // HealthView): the explicit override when set, else derived from the unit system. Liquid Today was
    // the ONLY one of them missing it — which is why its Skin Temp card could not honour the preference
    // even once it had a value to show (#1627).
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(system: unitSystem, override: distanceSystemRaw)
    }
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @AppStorage(UnitPrefs.skinTempDisplayKey) private var skinTempDisplayRaw = ""   // #1846
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }

    // The user's Effort display scale (#268), 0–100 by default or the WHOOP 0–21 axis if chosen — the SAME
    // preference the Workouts screen + Trends read, so a workout's Effort number is identical everywhere.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// The Effort this view should show: the live in-progress score when it beats the stored row, else the
    /// row (#1001). `StrainScorer.effectiveEffort` holds the never-drop floor and the live/stored
    /// preference and is shared with the Kotlin twin, so the two platforms cannot resolve Effort
    /// differently. `d` for today is always today's row or nil, never a prior day, so the floor cannot
    /// resurrect a stale day — it only stops a read-out dropping below what today has already earned.
    private func effortStrain(_ d: DailyMetric?) -> Double? {
        StrainScorer.effectiveEffort(live: selectedDayOffset == 0 ? liveTodayStrain : nil, stored: d?.strain)
    }

    private func effortText(_ s: Double?) -> String {
        guard let s else { return Self.noValueDash }
        // Route through the shared formatter instead of hardcoding *21: a default (0–100) user was shown the
        // WHOOP-scaled number here while the hero + Workouts table showed 0–100, two numbers for one workout.
        return UnitFormatter.effortDisplay(s, scale: effortScale)
    }

    /// The day's Effort as the hero, the Effort card and its Key-metrics tile print it — one formatter for
    /// the three, so they agree by construction: whole numbers on 0–100, one decimal on the WHOOP 0–21
    /// axis (#45, the hero's long-standing convention).
    private func effortNumber(_ strain: Double) -> String {
        let v = UnitFormatter.effortValue(strain, scale: effortScale)
        return effortScale == .whoop
            ? String(format: "%.1f", locale: AppLanguage.activeLocale, v)
            : String(Int(v.rounded()))
    }

    /// The Effort band word, always read on the 0–21 axis whichever scale is displayed (the bands the
    /// classic strain gauge drew: LIGHT / MODERATE / STRENUOUS / HIGH).
    private func effortBandWord(_ strain: Double?) -> String? {
        guard let strain else { return nil }
        switch UnitFormatter.effortValue(strain, scale: .whoop) {
        case ..<6: return String(localized: "Light")
        case ..<10: return String(localized: "Moderate")
        case ..<14: return String(localized: "Strenuous")
        default: return String(localized: "High")
        }
    }

    /// Today's suggested Effort window as a 0…1 range of the Effort axis, from the Charge the hero shows.
    /// Today only — a past day's window is not advice anyone can act on.
    private var effortTargetRange: ClosedRange<Double>? {
        selectedDayOffset == 0 ? TodayEffortTarget.range(recovery: chargeDisplay.pct) : nil
    }

    /// The same window on the displayed Effort scale.
    private var effortTargetText: String? {
        selectedDayOffset == 0 ? TodayEffortTarget.text(recovery: chargeDisplay.pct, scale: effortScale) : nil
    }

    /// The Weight tile's display string + an honest caption ("from profile" only on the fallback).
    /// Always formatted through the shared `UnitFormatter` so the Imperial/Metric toggle reaches this
    /// tile. Mirrors the classic TodayView's `weightTile`.
    private func weightTile(_ appleWeightKg: Double?) -> (value: String, caption: String) {
        if let kg = appleWeightKg {
            return (UnitFormatter.massFromKilograms(kg, system: unitSystem), String(localized: "latest"))
        }
        return (UnitFormatter.massFromKilograms(profile.weightKg, system: unitSystem), String(localized: "from profile"))
    }

    private func workoutSub(_ w: WorkoutRow) -> String {
        var parts: [String] = [workoutDayLabel(w.startTs)]
        let secs = w.durationS ?? Double(max(w.endTs - w.startTs, 0))
        parts.append("\(Int(secs / 60)) min")
        if let dm = w.distanceM, dm > 0 {
            parts.append(UnitFormatter.distanceFromMeters(dm, system: distanceUnitSystem))
        } else if let k = w.energyKcal {
            parts.append("\(Int(k.rounded())) kcal")
        }
        return parts.joined(separator: " · ")
    }

    /// Today / Yesterday / a short weekday within the week / a short date beyond it.
    private func workoutDayLabel(_ ts: Int) -> String {
        let cal = Calendar.current
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date),
                                      to: cal.startOfDay(for: Date())).day ?? 0
        switch days {
        case ..<1: return String(localized: "Today")
        case 1: return String(localized: "Yesterday")
        case 2...6: return date.formatted(.dateTime.weekday(.abbreviated).locale(AppLanguage.activeLocale))
        default: return date.formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale))
        }
    }

    private var dateLine: String {
        // #1013: localize the sub-header date. The old en_US_POSIX "EEEE, d MMMM" formatter forced English
        // weekday + month names regardless of the UI language. A locale-aware field template localizes both
        // the names AND the field order (e.g. fr "mercredi 4 juillet") in the user's locale.
        return selectedLogicalDay.formatted(
            .dateTime.weekday(.wide).day().month(.wide).locale(AppLanguage.activeLocale))
    }

    /// Provenance caption for the recovery-vitals card, keyed on the row a vital actually came from — NOT a
    /// hardcoded "yesterday". If ANY shown vital fell back to `vitalsDay` (today's own value is nil and the
    /// carried row supplies it), it stamps that row's date via the shared `TodayView.carriedCaption`, so a
    /// genuine post-rollover carry reads "Last night · <date>" and a weeks-old carry relabels to
    /// "Latest sleep · <date>" (#779) instead of a false "Last night". When every shown vital is today's
    /// own (or there's nothing to carry), it returns nil — the card must not claim "Last night" at all.
    private var vitalsProvenanceLine: String? {
        // Each vital can carry from a DIFFERENT row (#1842), so the one card-level footnote stamps the
        // OLDEST row any SHOWN carried vital came from — erring old is the only safe direction for a caption
        // whose job is to stop a stale read passing as today's, and it keeps the "Latest sleep" relabel
        // (#779) firing on the value that actually is weeks old. A row counts only if it SUPPLIED the value.
        let fromHrv: DailyMetric? = (displayDay?.avgHrv == nil && hrvDay?.avgHrv != nil) ? hrvDay : nil
        let fromRhr: DailyMetric? = (displayDay?.restingHr == nil && restingHrDay?.restingHr != nil) ? restingHrDay : nil
        let fromResp: DailyMetric? = (displayDay?.respRateBpm == nil && vitalsDay?.respRateBpm != nil) ? vitalsDay : nil
        let sources: [DailyMetric] = [fromHrv, fromRhr, fromResp].compactMap { $0 }
        guard let carried = sources.min(by: { $0.day < $1.day }) else { return nil }
        return TodayView.carriedCaption(priorDayKey: carried.day,
                                        todayKey: displayDay?.day ?? selectedDayKey)
    }
}

/// Measures the heart-rate card in the same coordinate space as the day-swipe gesture.
private struct LiquidHeartRateCardFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Carries the Today scroll's top overscroll offset up to the view for the custom liquid pull-to-refresh.
private struct PullOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Scene controls (LiveState-isolated leaves)

/// The pull-to-refresh ring + a "Syncing…" label. A pure gesture affordance: it answers "did my pull do
/// anything", and nothing else.
///
/// It used to ALSO hold itself up for the whole of `live.backfilling`, because `ble.syncNow()` kicks off a
/// BLE history offload that far outlives the local `refreshing` flag (which flips false ~350ms after the
/// pull releases). `LiquidBatteryButton` (the header's strap pill) is now that feedback — an ambient,
/// always-on-screen signal that carries a live chunk count — so the long tail belongs there and this hands
/// off to it instead of shadowing it.
private struct LiquidRefreshIndicator: View {
    let pullY: CGFloat
    let pullThreshold: CGFloat
    let refreshing: Bool

    private var progress: CGFloat { min(1, max(0, pullY / pullThreshold)) }

    var body: some View {
        ZStack {
            if refreshing {
                VStack(spacing: 6) {
                    TodayStrapRing(fraction: nil, tint: StrandPalette.textPrimary, spinning: true)
                    Text("Syncing…")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            } else if pullY > 2 {
                TodayStrapRing(fraction: Double(progress), tint: StrandPalette.textPrimary)
                    .opacity(Double(progress))
                    .scaleEffect(0.7 + 0.3 * progress)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: refreshing ? 64 : min(pullY, pullThreshold * 1.15))
        .animation(.easeOut(duration: 0.22), value: refreshing)
    }
}

/// The ONE debounce for the raw "a sync is happening" signal, for any surface that reflects it.
///
/// `live.backfilling` toggles false→true between EVERY offload chunk (`exitBackfilling` at each
/// HISTORY_END → auto-continue re-kick → `beginBackfill`), with a real BLE round-trip gap in between, and
/// a deep backlog is up to ~24 chunks in ONE connection (#594 raised the auto-continue cap 6→24). Bound
/// straight to that signal, an indicator strobes in and out on every chunk boundary. (The MenuBar header
/// pins a constant height for the same reason — see MenuBarContent.)
///
/// Rises INSTANTLY, and falls only after riding out `syncIndicatorSignalDebounceNanoseconds` with no new
/// chunk. Written once on purpose: this existed as two hand-rolled copies with the delay spelled two
/// different ways, and the failure mode of letting them drift — an indicator that flickers only against a
/// strap carrying hours of history — is not reproducible at a desk.
private struct DebouncedSyncSignal: ViewModifier {
    let raw: Bool
    @Binding var debounced: Bool
    @State private var hideTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear { apply(raw) }
            .onChangeCompat(of: raw) { apply($0) }
            .onDisappear { hideTask?.cancel() }
    }

    private func apply(_ raw: Bool) {
        hideTask?.cancel()
        guard !raw else {
            debounced = true                        // a sync is active — show at once
            return
        }
        guard debounced else { return }
        // Might just be the gap between two chunks — wait it out; a new chunk cancels this.
        hideTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: StrandMotion.syncIndicatorSignalDebounceNanoseconds
            )
            guard !Task.isCancelled else { return }
            debounced = false
        }
    }
}

private extension View {
    /// Drive `debounced` from the raw sync signal through the shared debounce above.
    func debouncedSyncSignal(_ raw: Bool, into debounced: Binding<Bool>) -> some View {
        modifier(DebouncedSyncSignal(raw: raw, debounced: debounced))
    }
}

private struct LiquidAddButton: View {
    @EnvironmentObject var router: NavRouter
    var body: some View {
        NoopCircleButton("plus", accessibilityLabel: "Quick actions") { router.requestQuickActions() }
    }
}

/// The live heart-rate readout leaf. Owns LiveState so the ~1 Hz HR notifies re-render ONLY this card,
/// never the whole Today (the isolation the classic Today depends on). Keeps its own rolling buffer of
/// live samples and shows the current bpm live with a beat-by-beat trace. Idle, it falls back to today's
/// banked 5-minute trace only when `showsFallback` — the Recovery vitals card already draws that trace,
/// and two copies of one chart stacked on the default Today would be noise.
private struct LiquidLiveHR: View {
    var fallback: [Double]        // today's banked 5-minute buckets — shown when there's no live stream
    /// Line identity for [fallback] only (#2082). The live series is 1 Hz and contiguous by construction,
    /// so it passes nil and draws exactly as before; the banked buckets skip the hours nothing was
    /// recorded, and without this the line joined across them as though the day were continuous.
    var fallbackSegments: [String] = []
    var showsFallback: Bool

    @EnvironmentObject private var live: LiveState
    @State private var samples: [Double] = []
    @State private var beat = false
    @State private var scrubX: CGFloat?
    #if os(iOS)
    @State private var scrubEngaged = false
    #endif
    private let maxSamples = 90   // ~1.5 min of 1 Hz live HR, enough to read the shape

    private var isLive: Bool { live.connected && samples.count >= 2 }
    private var series: [Double] { isLive ? samples : (showsFallback ? fallback : []) }
    /// The big number is the LIVE heart rate only. It used to fall back to the last banked 5-minute
    /// average, drawn exactly like a live reading, so with the strap off the wrist the card went on showing
    /// one (a tester's 91).
    private var bigBpm: Int? {
        guard let hr = live.heartRate, hr > 0, live.connected else { return nil }
        return hr
    }
    private var subtitle: String {
        if isLive { return String(localized: "Live · beat by beat") }
        if showsFallback && fallback.count >= 2 { return String(localized: "5-minute average · since midnight") }
        return live.connected ? String(localized: "Waiting for the strap") : String(localized: "Strap not connected")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NoopCardHeader("Heart rate", icon: "heartbeat") {
                HStack(spacing: 6) {
                    if isLive {
                        // Reuses the incoming-HR event pulse; no timer or continuous redraw loop.
                        Circle().fill(NoopGlow.heart.tint)
                            .frame(width: 6, height: 6)
                            .scaleEffect(beat ? 1.25 : 0.8)
                            .opacity(beat ? 1 : 0.6)
                            .animation(.easeOut(duration: 0.28), value: beat)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: subtitle)
                }
            }
            if let hr = bigBpm {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    NoopDotNumber("\(hr)", size: 50)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.25), value: hr)
                    Text("bpm").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
                .accessibilityElement(children: .combine)
            }
            if series.count >= 2 {
                TodaySegmentedAreaChart(values: series,
                                        segments: isLive ? [] : (fallbackSegments.count == series.count
                                                                 ? fallbackSegments : []))
                    .frame(height: 64)
                    .contentShape(Rectangle())
                    .overlay { scrubReadout }
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            switch phase {
                            case .active(let location): scrubX = location.x
                            case .ended: scrubX = nil
                            }
                        }
                    }
                    #if os(iOS)
                    .gesture(touchScrubGesture)
                    #endif
                NoopMetricRow {
                    stat(String(localized: "Min"), series.min())
                    stat(String(localized: "Avg"), series.reduce(0, +) / Double(series.count))
                    stat(String(localized: "Max"), series.max())
                }
                .padding(.top, 2)
            } else if bigBpm == nil {
                Text(live.connected
                     ? String(localized: "Waiting for a live heartbeat…")
                     : String(localized: "Connect your strap to see live heart rate"))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { if samples.isEmpty, let hr = live.heartRate, hr > 0 { samples = [Double(hr)] } }
        .onChangeCompat(of: live.heartRate) { hr in
            // No live heart rate (the strap off the wrist, or gone): drop the trace, so the card stops
            // calling an old one "Live".
            guard let hr, hr > 0 else { samples.removeAll(); return }
            samples.append(Double(hr))
            if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
            beat.toggle()
        }
    }

    private func stat(_ label: String, _ v: Double?) -> some View {
        NoopMetric(value: v.map { String(Int($0.rounded())) } ?? LiquidTodayView.noValueDash,
                   unit: v == nil ? nil : "bpm", labelText: label)
    }

    /// Points at the value actually drawn under the finger: the same index→x mapping the chart uses.
    private var scrubReadout: some View {
        GeometryReader { geometry in
            if let scrubX, series.count >= 2 {
                let size = geometry.size
                let index = TodaySegmentedAreaChart.nearestIndex(toX: scrubX, count: series.count, width: size.width)
                let p = TodaySegmentedAreaChart.point(index: index, values: series, size: size)
                Path { path in
                    path.move(to: CGPoint(x: p.x, y: 0))
                    path.addLine(to: CGPoint(x: p.x, y: size.height))
                }
                .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                Circle().fill(Color.white).frame(width: 7, height: 7).position(p)
                (Text("\(Int(series[index].rounded()))").font(StrandFont.captionNumber)
                    + Text(" bpm").font(StrandFont.caption))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(NoopVisualStyle.inset, in: Capsule())
                    .position(x: min(max(p.x, 40), max(40, size.width - 40)), y: -12)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    #if os(iOS)
    private var touchScrubGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.25, maximumDistance: 8)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !scrubEngaged {
                    scrubEngaged = true
                    StrandHaptic.selection.play()
                }
                if let drag {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { scrubX = drag.location.x }
                }
            }
            .onEnded { _ in
                scrubEngaged = false
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { scrubX = nil }
            }
    }
    #endif
}

extension LiquidTodayView {
    /// What the strap-battery ring can honestly say, resolved from the three live signals it has.
    /// Pure + static so the truth table is testable with no strap (`LiquidBatteryDisplayTests`).
    ///
    /// The three signals are INDEPENDENT and land separately, which is the whole reason this exists:
    ///  • `connected` — the CoreBluetooth link.
    ///  • `batteryPct` — standard 0x2A19 (5/MG) or the GET_BATTERY_LEVEL response (4.0).
    ///  • `charging` — a different source entirely: the strap's BATTERY_LEVEL event (~every 8 min),
    ///    which keeps arriving live even mid-offload (`FrameRouter`, "flag only — battery % keeps its
    ///    family-specific source", #77).
    ///
    /// So "charging, but no % yet" is REACHABLE, not hypothetical. The old code nested the bolt inside
    /// `if let pct`, so that state rendered as `bolt.slash` — a crossed-out bolt at a wearer whose strap
    /// was on the charger, which reads as "battery dead". And it drew the ring on `batteryPct` alone with
    /// no `connected` gate: `LiveState.batteryPct` is never cleared (`clearBiometrics` deliberately leaves
    /// it), so a dead strap kept showing its last % as if live — a 21 h old reading rendered identically
    /// to a fresh one. Gating on `connected` here also makes this ring agree with `LiquidStrapBatteryRow`
    /// directly below it, which already required `live.connected`.
    /// The Effort hero's "no cardio load yet" honest note (#530 follow-up — Liquid parity with classic
    /// `TodayView.effortZeroNote`). Pure + static so the gate is testable with no view: the note shows
    /// ONLY for today when a strain value exists and is ~0 — a genuinely calm day reads near zero, while a
    /// no-data day shows its own ring overlay and a past day is never annotated. The caller passes
    /// `effortStrain(displayDay)` — the SAME resolved value the Effort hero draws (#1001) — so the note
    /// and the hero can never disagree about whether today is at zero.
    enum EffortDisplay {
        static func showsZeroNote(strain: Double?, isToday: Bool) -> Bool {
            guard isToday, let s = strain else { return false }
            return s < 1.0
        }
    }

    /// (A3/B2, docs/bugs/2026-07-15-strap-battery-backfill-observability.md)
    enum StrapBatteryDisplay: Equatable {
        /// No link — say nothing about charge. A stale % is worse than no %.
        case offline
        /// Linked, but no charge reading has landed yet. `charging` is still knowable on its own.
        case pending(charging: Bool)
        /// A reading from the current link. `isRing` says whose: the ring's own charge under an active
        /// ring, the strap's under an active strap — the label names the device the number belongs to.
        case charge(pct: Double, charging: Bool, isRing: Bool)
        /// The active device is neither the strap nor a ring that has reported its charge this link, so
        /// this control has nothing to say and is not drawn.
        ///
        /// Distinct from [offline], which asserts a strap that IS active is not connected. Collapsing the
        /// two put a crossed-out bolt and "strap not connected" on the header of a wearer whose ring was
        /// streaming, which is a different false claim from the one #2208 is about rather than a fix for
        /// it, and the only one a ring-only wearer would see every day. (@pipiche38 on #2216)
        case notActiveDevice

        /// #2208: `activeIsWhoop` is required, not defaulted. `connected` alone was never enough: it is
        /// true the moment ANY source streams, `batteryPct` is the strap's and is never cleared, so under
        /// an active ring both halves of the old gate passed and this drew the strap's charge. Charging
        /// is strap-only for the same reason, so a non-WHOOP active device reports neither of the strap's.
        ///
        /// A ring reports its OWN charge into `ringPct` (`LiveState.ouraBatteryPct`), cleared with the
        /// link, so under a non-WHOOP active device a non-nil `ringPct` is a reading from the ring that is
        /// live right now and is drawn as such; nil (no ring, or none has reported yet) keeps the control
        /// off the header. `ringCharging` is the ring's charger state (`OuraWearState.charging`), the only
        /// charging evidence a ring gives. Same resolution `LiveConsoleReadout.batteryPercent` applies.
        ///
        /// No default values on purpose. A defaulted flag is one a future call site can forget, and
        /// forgetting it reinstates exactly this bug in a form that still compiles.
        static func resolve(activeIsWhoop: Bool, connected: Bool,
                            batteryPct: Double?, charging: Bool?,
                            ringPct: Int?, ringCharging: Bool) -> StrapBatteryDisplay {
            guard activeIsWhoop else {
                guard let ringPct else { return .notActiveDevice }
                return .charge(pct: Double(ringPct), charging: ringCharging, isRing: true)
            }
            guard connected else { return .offline }
            guard let pct = batteryPct else { return .pending(charging: charging == true) }
            return .charge(pct: pct, charging: charging == true, isRing: false)
        }
    }

    /// What the Charge hero can honestly say for the selected day. Pure + static so the truth table is
    /// testable with no clock and no view (`LiquidChargeCarryTests`).
    ///
    /// See `LiquidChargeCarryTests` for the regression this closes: Liquid read `displayDay?.recovery`
    /// raw, so after the 04:00 rollover — or on any day with no scored night — Charge blanked while the
    /// Rest hero (`freshRestScore`) and the vitals (`Repository.lastVitalsDay`) carried right beside it,
    /// and the widget/watch/Live Activity (`Repository.widgetAnchor`, #911) all showed a number.
    ///
    /// The SELECTION is not re-implemented here: callers pass the row `TodayView.lastScoredRecoveryDay`
    /// picked (its #547 future-day guard included) and the caption comes from `TodayView.carriedCaption`,
    /// so the two Today screens cannot drift apart.
    enum ChargeDisplay: Equatable {
        /// The selected day scored its own Charge.
        case scored(pct: Double)
        /// No score for the selected day; showing a REAL prior night's, stamped with whose it is.
        case carried(pct: Double, caption: String)
        /// Pre-seed-gate: the baseline is still learning and owns its own "N of 4 nights" copy.
        case calibrating(nights: Int)
        /// Nothing honest to show — no score, no prior night, and not calibrating.
        case noData

        /// The number the hero vessel draws, or nil for the honest empty state. A carry draws the REAL
        /// prior value; the empty states draw nothing rather than a fabricated zero.
        var pct: Double? {
            switch self {
            case .scored(let p): return p
            case .carried(let p, _): return p
            case .calibrating, .noData: return nil
            }
        }

        /// The short Charge-state pill beside the greeting. It shares a row with the greeting under a
        /// `fixedSize`, so it stays SHORT — the carried day's full "Last night · <date>" stamp lives in
        /// `caption`, not here. Only `.calibrating` may say "Calibrating": the pill used to key off
        /// `recovery != nil` and so claimed a calibrating baseline on every unscored day, including a
        /// trusted wearer who simply hadn't worn the strap that night.
        var stateLabel: String {
            switch self {
            case .scored: return String(localized: "Solid")
            case .carried: return String(localized: "Last night")
            case .calibrating: return String(localized: "Calibrating")
            case .noData: return String(localized: "No data")
            }
        }

        /// The synthesis-card detail line while the baseline is still forming — the same "N of
        /// `Baselines.minNightsSeed` nights" progress classic `TodayView.calibrationDetail` surfaces, so a
        /// wearer in their first few nights reads identical calibration copy on both Today screens (before
        /// this, Liquid dropped the count and showed a bare "Calibrating"). Non-nil ONLY for `.calibrating`:
        /// the compact greeting pill stays short ("Calibrating") because it shares a `fixedSize` row with
        /// the greeting, so the count lives here in the card, exactly as classic keeps it out of its
        /// `ScoreStatePill`. Reuses classic's String Catalog key verbatim — one entry serves both screens.
        var calibrationDetail: String? {
            guard case .calibrating(let nights) = self else { return nil }
            return String(localized: "Learning your baseline, \(nights) of \(Baselines.minNightsSeed) nights.")
        }

        /// The reason half, when nights are arriving but most carry no HRV (see `TodayView`'s twin). Nil
        /// when every observed night counted, so a healthy calibration says nothing extra.
        func calibrationReason(dayKeys: [String], nightlyHrv: [Double?], today: String) -> String? {
            guard case .calibrating = self else { return nil }
            let cov = Baselines.recentHrvCoverage(dayKeys: dayKeys, nightlyHrv: nightlyHrv, today: today)
            guard cov.missing > 0, cov.observed > 0 else { return nil }
            return String(localized: "\(cov.missing) of the last \(cov.observed) nights recorded no HRV. Check the strap is worn overnight and syncing.")
        }

        static func resolve(todayRecovery: Double?, priorScored: DailyMetric?,
                            calibrationNights: Int?, todayKey: String) -> ChargeDisplay {
            if let pct = todayRecovery { return .scored(pct: pct) }
            // Calibration owns its own copy and beats the carry — mid-calibration there is no trustworthy
            // prior score to stand in. Mirrors `lastScoredRecoveryDay`, which returns nil when calibrating.
            if let n = calibrationNights { return .calibrating(nights: n) }
            // `lastScoredRecoveryDay` only ever selects a row whose recovery is non-nil, so the second bind
            // is belt-and-suspenders: a nil falls through to noData rather than fabricating a carry.
            guard let prior = priorScored, let pct = prior.recovery else { return .noData }
            return .carried(pct: pct,
                            caption: TodayView.carriedCaption(priorDayKey: prior.day, todayKey: todayKey))
        }
    }
}

/// Active-device battery ring: the strap's charge under an active strap, the ring's own under an active
/// ring. At sync start it briefly expands within the trailing control row, then settles into an in-place
/// spinner; the layered header keeps either state from moving the Today content. Tap → Devices.
private struct LiquidBatteryButton: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var router: NavRouter

    /// Debounced by `debouncedSyncSignal` below, so a per-chunk `backfilling` gap cannot flash the
    /// indicator back to the battery reading in the middle of one logical sync.
    @State private var syncing = false
    #if DEBUG
    /// Driven only by the `--demo-sync` harness; ignored entirely when that flag is absent.
    @State private var demoSyncing = false
    /// Synthetic chunk tally for the harness, so the expanded read-out is exercised without a strap.
    /// Kept local rather than written into LiveState — a demo aid must not touch real collector state.
    @State private var demoChunks = 0
    #endif

    /// The raw, confirmed "strap history is syncing" signal.
    ///
    /// Pull-to-refresh is not evidence of an offload: `syncNow()` can still decline after its
    /// connected/bonded gate when the connection handshake or backing store is not ready. A successful
    /// `beginBackfill()` publishes `live.backfilling` synchronously, so that state is both prompt and the
    /// only honest source for the header and its VoiceOver label.
    private var syncingRaw: Bool {
        #if DEBUG
        if DemoSyncHarness.active { return demoSyncing }
        #endif
        return live.backfilling
    }

    private var batteryDisplay: LiquidTodayView.StrapBatteryDisplay {
        #if DEBUG
        if DemoSyncHarness.active {
            // The harness stands in for a connected WHOOP, so it answers this the way one would.
            return .resolve(
                activeIsWhoop: true,
                connected: true,
                batteryPct: DemoSyncHarness.batteryPercent,
                charging: DemoSyncHarness.charging,
                ringPct: nil,
                ringCharging: false
            )
        }
        #endif
        return .resolve(
            activeIsWhoop: live.activeIsWhoop,
            connected: live.connected,
            batteryPct: live.batteryPct,
            charging: live.charging,
            ringPct: live.ouraBatteryPct,
            ringCharging: live.ouraWearState == .charging
        )
    }

    var body: some View {
        // Not drawn at all when the active device is neither the strap nor a ring with a charge of its
        // own to show. The alternative is a glyph that has to say SOMETHING about a strap nobody is
        // wearing, and every option is a claim: a charge that is not the active device's, or a crossed-out
        // bolt asserting a disconnection that is not the interesting fact. (#2208) A ring that HAS
        // reported its charge is the active device's own reading, and #2208's fix left it undrawn only
        // because the control could not yet tell whose number it held.
        if case .notActiveDevice = batteryDisplay {
            EmptyView()
        } else {
            Button { router.openDevices() } label: { pill }
                .buttonStyle(LiquidPressStyle())
                .accessibilityLabel(batteryAccessibility)
                .debouncedSyncSignal(syncingRaw, into: $syncing)
                // DEBUG-gated at the CALL SITE too, not just in the body: in Release the harness must cost
                // literally nothing, rather than an async task created and immediately returned per appearance.
                #if DEBUG
                .task { await runDemoSyncCycleIfNeeded() }
                #endif
        }
    }

    /// The v2 strap pill: the battery ring and its percentage, the ring spinning with the chunk tally
    /// while history syncs. A state with no reading says so rather than showing a stale number.
    private var pill: some View {
        HStack(spacing: 7) {
            TodayStrapRing(fraction: ringFraction, tint: ringTint, spinning: syncing)
            Group {
                if syncing {
                    Text(syncChunks > 0 ? "\(syncChunks)" : String(localized: "Syncing"))
                        .monospacedDigit()
                } else {
                    switch batteryDisplay {
                    case .charge(let percent, _, _): Text(verbatim: "\(Int(percent.rounded()))%")
                    case .pending: Text(verbatim: "…")
                    case .offline, .notActiveDevice: Text("Offline")
                    }
                }
            }
            .font(StrandFont.book(12, relativeTo: .caption))
            .foregroundStyle(StrandPalette.textSecondary)
            .lineLimit(1)
            // The state word is never cut ("Synchronisi…"): the greeting beside the pill is the part of
            // the header that scales down to make room.
            .fixedSize()
            if isCharging && !syncing {
                PhIcon("lightning", weight: .fill, size: 11)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 13)
        .frame(height: 42)
        .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
        .contentShape(Capsule())
    }

    private var ringFraction: Double? {
        guard case .charge(let percent, _, _) = batteryDisplay else { return nil }
        return percent / 100
    }

    /// The charge arc is the recovery green; a nearly flat strap turns it to the low-band red.
    private var ringTint: Color {
        guard case .charge(let percent, _, _) = batteryDisplay else { return StrandPalette.textTertiary }
        return percent <= 15 ? NoopGlow.low.tint : NoopGlow.recovery.accent
    }

    private var isCharging: Bool {
        switch batteryDisplay {
        case .charge(_, let charging, _): return charging
        case .pending(let charging): return charging
        case .offline, .notActiveDevice: return false
        }
    }

    /// DEBUG `--demo-sync` only: loop the syncing signal so the charge→sync morph plays in both
    /// directions without a strap. Returns immediately in Release and whenever the flag is absent, and
    /// `.task` cancels it on disappear.
    private func runDemoSyncCycleIfNeeded() async {
        #if DEBUG
        guard DemoSyncHarness.active else { return }
        while !Task.isCancelled {
            try? await Task.sleep(
                nanoseconds: UInt64(DemoSyncHarness.idleSeconds * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            demoChunks = 0
            demoSyncing = true
            // Tick the tally the way an offload does, so the expanded label is watched changing rather
            // than appearing once and holding.
            for tick in 1...DemoSyncHarness.chunkTicks {
                try? await Task.sleep(
                    nanoseconds: UInt64(DemoSyncHarness.chunkIntervalSeconds * 1_000_000_000)
                )
                guard !Task.isCancelled else { return }
                demoChunks = tick
            }
            demoSyncing = false
        }
        #endif
    }

    /// Chunks acked this session, shown inside the spinner where the battery percentage sits. The
    /// expanded label stays "Syncing" — this is the numeric read-out, not the caption.
    private var syncChunks: Int {
        #if DEBUG
        if DemoSyncHarness.active { return demoChunks }
        #endif
        return live.syncChunksThisSession
    }

    /// Never "Strap battery" alone for a no-reading state — that was indistinguishable from a real one.
    private var batteryAccessibility: String {
        if syncing {
            // `syncChunks` is a COUNT, not an index, so it reads "3 chunks" — the phrasing the Android
            // twin and `SyncStatusChip` already use. Reusing that exact key also means this read-out
            // inherits its existing translations rather than adding an untranslated variant.
            //
            // The SAME accessor the ring draws from, not `live.syncChunksThisSession` directly: in
            // Release the two are identical, but under `--demo-sync` reading LiveState here would have
            // VoiceOver announcing a real count while the ring showed the synthetic one — i.e. the
            // harness could not be used to check the read-out it exists to exercise.
            let n = syncChunks
            guard n > 0 else { return String(localized: "Syncing strap history") }
            // #689/#815: the connect-time ring backlog, when the strap reported one. Zero is dropped by
            // `SyncChipState.resolve`, and dropped here for the same reason: "0 pages behind" beside a
            // running sync contradicts itself. Both counts inflect — the phrase is built from its own
            // entry and joined through a template, so "1 chunk" and "1 page" read correctly and the
            // joining punctuation stays inside the translated template rather than being concatenated.
            let behind = live.pagesBehindAtConnect
                .flatMap { $0 > 0 ? $0 : nil }
                .map { String(localized: "\($0) pages behind at connect") }
            if let behind {
                return String(localized: "Syncing strap history, \(n) chunks, \(behind)")
            }
            return String(localized: "Syncing strap history, \(n) chunks")
        }

        switch batteryDisplay {
        case .notActiveDevice:
            return ""          // not drawn; the label is unreachable and must not claim anything
        case .offline:
            return String(localized: "Strap battery, strap not connected")
        case .pending(let charging):
            return charging
                ? String(localized: "Strap battery charging, no reading yet")
                : String(localized: "Strap battery, no reading yet")
        case .charge(let percent, let charging, let isRing):
            let n = Int(percent.rounded())
            // Named for the device the number belongs to: "Strap battery" over a ring's charge would be
            // the #2208 misattribution again, in the label instead of the number.
            if isRing {
                return charging
                    ? String(localized: "Ring battery \(n) percent, charging")
                    : String(localized: "Ring battery \(n) percent")
            }
            return charging
                ? String(localized: "Strap battery \(n) percent, charging")
                : String(localized: "Strap battery \(n) percent")
        }
    }
}

/// The sync footer line under Today ("Synced from WHOOP 4.0 · 2 min ago · View sources"), with the
/// strap's runtime estimate beneath it. Owns LiveState; display-only.
///
/// B1 (docs/bugs/2026-07-15-strap-battery-backfill-observability.md): a multi-hour history recovery must
/// stay visible on the default Today, so while a drain runs this says THAT it is running and how many
/// chunks it has pulled, and when one last completed. It does NOT yet say "~15h behind" — that needs the
/// persisted data frontier, a Repository read that LiveState does not carry. The header's strap pill is
/// the ambient at-a-glance signal; this is the detailed line.
private struct LiquidSyncFooterLine: View {
    /// The provider of the shown scores (`heroSourceLabel`), nil before any score resolved.
    let source: String?
    @EnvironmentObject var live: LiveState

    var body: some View {
        VStack(spacing: 4) {
            Text(verbatim: syncLine)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
            // #2208: the strap's charge only when the strap is the active device.
            if live.connected, live.activeIsWhoop, let pct = live.batteryPct, let note = runtimeNote {
                Text(verbatim: "\(String(localized: "Strap battery")) · \(note)")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityLabel(Text(verbatim: "\(String(localized: "Strap battery")) \(batteryText(pct: pct))"))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var syncLine: String {
        var parts: [String] = []
        if live.backfilling {
            // "Syncing…" alone reads as a spinner that might be stuck; the chunk count is the cheapest
            // proof the drain is moving. Suppressed at zero — nothing pulled yet is not progress.
            parts.append(live.syncChunksThisSession > 0
                         ? String(localized: "Syncing… \(live.syncChunksThisSession) chunks")
                         : String(localized: "Syncing…"))
        } else if let ts = live.lastSyncedAt {
            if let source {
                parts.append(String(localized: "Synced from \(source)"))
                parts.append(relativeAgo(ts))
            } else {
                parts.append(String(localized: "Synced \(relativeAgo(ts))"))
            }
        } else if let source {
            parts.append(String(localized: "Data from \(source)"))
        }
        parts.append(String(localized: "View sources"))
        return parts.joined(separator: " · ")
    }

    /// "Charging" (#972) or the "~X days left" runtime (#992); nil when neither is known, so the line only
    /// ever shows an estimate we trust. The percentage itself lives in the header's strap pill.
    private var runtimeNote: String? {
        if live.charging == true { return String(localized: "Charging") }
        return estimateText
    }

    /// "87%" plus a trailing "· Charging" (#972) or "· ~9 days left" runtime (#992), matching the Settings /
    /// Mac / Android pill and the classic Today badge. Spoken in full by VoiceOver.
    private func batteryText(pct: Double) -> String {
        let base = "\(Int(pct.rounded()))%"
        if live.charging == true { return "\(base) · \(String(localized: "Charging"))" }
        if let est = estimateText { return "\(base) · \(est)" }
        return base
    }

    /// #992: reproduced verbatim from `TodayView.estimateText`: under 48 h show hours, at two days or more
    /// round to days; nil (no banked discharge yet, or charging) hides it.
    private var estimateText: String? {
        guard live.charging != true, let est = live.batteryEstimate else { return nil }
        let hours = est.hoursRemaining
        guard hours.isFinite, hours > 0 else { return nil }
        if hours < 48 {
            return String(localized: "~\(Int(hours.rounded()))h left")
        }
        let days = Int((hours / 24).rounded())
        return days == 1
            ? String(localized: "~1 day left")
            : String(localized: "~\(days) days left")
    }
}

// MARK: - Cross-platform chrome helpers
//
// The liquid Today is shared with the macOS target now (the mac split-view shell hosts it too). A few of
// its chrome modifiers are iOS-only, so they are wrapped here: `topBarTrailing` + `navigationBarTitleDisplayMode`
// don't exist on macOS, and `presentationCompactAdaptation` is an iOS phone-width concern. These keep the
// exact iOS behaviour while giving macOS the platform-correct equivalent.
private extension View {
    /// A sheet's trailing ink "Done" button (inline title on iOS; the confirmation-action toolbar slot on macOS).
    @ViewBuilder func liquidSheetDoneChrome(done: @escaping () -> Void) -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: done)
                        .font(StrandFont.medium(15))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
            }
        #else
        self.toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: done)
                    .font(StrandFont.medium(15))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
        }
        #endif
    }

    /// Keep a popover a popover in compact width (iOS 16.4+); a no-op on macOS where popovers never adapt.
    @ViewBuilder func liquidPopoverAdaptation() -> some View {
        #if os(iOS)
        if #available(iOS 16.4, *) { self.presentationCompactAdaptation(.popover) } else { self }
        #else
        self
        #endif
    }

    /// Present the Live Session screen: fullScreenCover on iOS (the guardian owns the display mid-
    /// workout), a plain sheet on macOS where fullScreenCover doesn't exist. The session view calls
    /// `onClose` itself once the summary is dismissed.
    @ViewBuilder func liveSessionCover(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented) {
            LiveSessionView(onClose: { isPresented.wrappedValue = false })
        }
        #else
        self.sheet(isPresented: isPresented) {
            LiveSessionView(onClose: { isPresented.wrappedValue = false })
        }
        #endif
    }
}
