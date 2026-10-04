import SwiftUI
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers
import PhotosUI
import StrandDesign
import StrandAnalytics
import WhoopStore
// #174: the R22 card reads the flag COUNT off `Whoop5Config.enableR22Sequence` rather than restating it —
// the hardcoded "15" outlived the sequence growing to 16 and declared success a flag early.
import WhoopProtocol

/// Settings — profile (powers zones / calories / recovery), strap connection, and about.
/// Grouped cards on surface.raised with a two-column form feel.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore

    /// Profile-photo picker selection (PhotosUI). Cleared back to nil once the bytes are loaded.
    @State private var avatarPickerItem: PhotosPickerItem?

    /// Custom background image (#custom-background). The store owns the decoded image + toggles; the
    /// picker selection + the file-importer flag are local UI state.
    @ObservedObject private var backgroundStore = BackgroundImageStore.shared
    @State private var backgroundPickerItem: PhotosPickerItem?
    @State private var showBackgroundFileImporter = false

    /// Backup & restore UI state.
    @State private var backupBusy = false
    @State private var backupAlertTitle = ""
    @State private var backupAlertMessage = ""
    @State private var showBackupAlert = false
    /// #1807: a restore refused ONLY for size is recoverable, so it gets its own two-button alert rather
    /// than the shared single-OK one every other backup outcome uses.
    @State private var showOversizeRestoreConfirm = false
    @State private var oversizeRestoreMessage = ""

    /// Opt-in WHOOP 5/MG "R22" deep-data unlock (off by default) — the one probe that writes a
    /// persistent feature flag to the strap. See [PuffinExperiment.deepDataKey]. (#174)
    @AppStorage(PuffinExperiment.deepDataKey) private var deepDataEnabled = false

    /// #174: set when the deep-data switch is turned OFF, so the app can OFFER to clear the flags on the
    /// strap instead of silently leaving them set. The switch alone has never written anything in either
    /// direction — it gates sends — so turning it off used to change nothing on the hardware while reading
    /// like an undo. Asking is the right shape rather than writing automatically: the strap may not be
    /// connected, and a write to bonded hardware is not something a toggle should do unannounced.
    @State private var confirmingDeepDataDisable = false

    /// #103 opt-in: surfaces the WHOOP 5/MG `spo2_candidate_82` nightly mean in the Blood Oxygen tile
    /// as a "strap estimate (unverified)" fallback when no calibrated `spo2Pct` exists. Display-only —
    /// writes nothing to the strap. See [PuffinExperiment.spo2CandidateDisplayKey].
    @AppStorage(PuffinExperiment.spo2CandidateDisplayKey) private var spo2CandidateDisplayEnabled = false
    @AppStorage(AppModel.ouraAllDayLiveHRKey) private var ouraAllDayLiveHREnabled = false   // item 27

    /// #1545 opt-in: score Effort with Banister's exponential TRIMP instead of Edwards' heart-rate zones.
    /// Default OFF — it re-scores the whole window against a different recipe. See
    /// [PuffinExperiment.banisterEffortKey].
    @AppStorage(PuffinExperiment.banisterEffortKey) private var banisterEffortEnabled = false

    /// Opt-in "Continuous HRV capture" (off by default) — holds the dense realtime stream armed 24/7 so
    /// the strap banks beat-to-beat R-R for better overnight HRV/recovery/sleep, at a battery cost.
    /// See [PuffinExperiment.keepRealtimeForDataKey].
    @AppStorage(PuffinExperiment.keepRealtimeForDataKey) private var continuousHrvEnabled = false

    /// #927 "Overnight only" refinement of Continuous HRV capture (off by default): arm the stream only
    /// inside the nightly quiet-hours window instead of 24/7. Composed with the base toggle (base on +
    /// this off = ALWAYS, the pre-#927 behaviour); existing installs are pinned to OFF by
    /// `PuffinExperiment.migrateContinuousHrvOvernightDefault()` at launch, so they still see no change.
    ///
    /// The `@AppStorage` default MUST match `PuffinExperiment.continuousHrvOvernightOnlyEnabled` (#1008).
    /// They read the same key by different routes, so a mismatch shows the toggle OFF on a fresh install
    /// while capture is actually overnight-only — and a user "correcting" that would write an explicit
    /// false and get the 24/7 behaviour they were trying to avoid.
    @AppStorage(PuffinExperiment.continuousHrvOvernightOnlyKey) private var continuousHrvOvernightOnly = true

    // #477 Power saving moved OUT of this screen into `PowerSavingView` — a first-class More row on
    // iPhone (between Test Centre and Settings) and its own sidebar item on macOS. Its `@AppStorage`
    // keys live there now; nothing here reads them.

    /// "Experimental sleep staging (V2)" (ON by default, promoted after the 44-subject cross-subject
    /// benchmark). When on, detected nights are re-staged with `SleepStagerV2` (the transparent
    /// cardiorespiratory recipe) instead of the older V1 stager. Read at the staging call site in
    /// `Repository`. See [PuffinExperiment.experimentalSleepV2Key].
    @AppStorage(PuffinExperiment.experimentalSleepV2Key) private var experimentalSleepV2Enabled = true

    /// "Motion-aware wake refinement" (#364 follow-up, OFF by default). A post-pass over the already-staged
    /// hypnogram: reclassifies a scored WAKE segment to `light` when its per-minute step-tick cadence shows
    /// no locomotion and its per-minute gravity posture is stable outside a minority of isolated burst
    /// minutes. Self-gates on OBSERVED gravity + step density (#345) — a no-op on a sparse night (e.g.
    /// WHOOP 4.0) regardless of this switch. See [PuffinExperiment.motionAwareWakeKey].
    @AppStorage(PuffinExperiment.motionAwareWakeKey) private var motionAwareWakeEnabled = false

    // Display preferences. `units.system` remains the body-measurement choice for compatibility;
    // exercise distance/pace can override it independently. Stored data is always SI.
    /// #1821: Clock format. Defaults to `.system`, so upgrading changes nobody's displayed times.
    /// #1841: shared with Android by name and meaning; each platform keeps its own store. Default FALSE
    /// on Apple (Android defaults true) because the system behaviour may not fire on our
    /// `NavigationStack(path:)` tabs — see RootTabView.
    /// The Coach master switch, under the same `noop.` key Android writes. Default ON, so nothing changes
    /// for an install that never opens this row. Read by `RootTabView` (the tab), Today (the launcher card)
    /// and `CoachBriefScheduler` (the daily background brief).
    @AppStorage("noop.coachEnabled") private var coachEnabled = true
    @AppStorage("noop.bottomBarAutoHide") private var bottomBarAutoHide = false
    @AppStorage(ClockFormatPreference.defaultsKey)
    private var clockFormatRaw = ClockFormatPreference.system.rawValue
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @AppStorage(UnitPrefs.skinTempDisplayKey) private var skinTempDisplayRaw = ""   // #1846
    // Effort display scale (#268). Display-only — Effort stays stored 0–100, this only chooses whether
    // it's shown on NOOP's 0–100 axis or WHOOP's 0–21 Day Strain axis.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @AppStorage(UnitPrefs.trendChartStyleKey) private var trendChartStyleRaw = TrendChartStyle.line.rawValue
    @AppStorage(UnitPrefs.hrvWindowKey) private var hrvWindowRaw = HrvWindow.whole.rawValue
    // Live-HR Live Activity (Lock Screen + Dynamic Island), iOS only (#336). Default on.
    @AppStorage(UnitPrefs.liveActivityKey) private var liveActivityEnabled = true
    // Strap-sync Live Activity, iOS only. Separate from the live-HR one on purpose. Default on.
    @AppStorage(UnitPrefs.syncLiveActivityKey) private var syncLiveActivityEnabled = true
    @AppStorage(UnitPrefs.liftLiveActivityKey) private var liftLiveActivityEnabled = true
    @AppStorage(DayCycleMode.storageKey) private var dayCycleModeRaw = DayCycleMode.sleepOnset.rawValue
    // Alternate app icon (iOS only) — false = Titanium (primary AppIcon), true = Blue Titanium
    // ("AppIcon-Navy"). Display-only preference; the live switch goes through setAlternateIconName.
    @AppStorage("appIcon.alt") private var useNavyIcon = false
    // Light/Dark/System theme. Read by both app roots' .preferredColorScheme; default follows the OS.
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.defaultMode.rawValue
    // App-owned copy language. Apple binds a bundle localization at process launch, so this writes the
    // standard AppleLanguages override and takes effect after the user reopens NOOP.
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.system.rawValue
    // Chart colour style: Titanium (brand) or Classic (throwback red→green). Re-colours gauges + charts.
    @AppStorage(ChartStyle.storageKey) private var chartStyleRaw = ChartStyle.titanium.rawValue
    // Sleep tab stage-CHART shape: Classic per-stage rows, or the WHOOP-style stepped hypnogram Filled/Ribbon.
    @AppStorage(SleepChartStyle.storageKey) private var sleepChartStyleRaw = SleepChartStyle.classic.rawValue
    // Chrome accent colour (mint / WHOOP blue / custom). Chrome only — never the data colour worlds.
    @AppStorage(AccentColor.storageKey) private var accentRaw = AccentColor.mint.rawValue
    @AppStorage(AccentColor.customHexKey) private var accentCustomHex = AccentColor.defaultCustomHex
    // Day-cycle scene backdrop behind Today (#698). Default ON. Off swaps the scene for a plain dark
    // canvas. TodayView reads the same key to gate its SceneScreenBackground.
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var showDayCycleBackground = true
    // "Sky behind cards" (default ON): extend the day-cycle sky behind the whole Today scroll so
    // Card transparency reveals it under every card. User-toggleable below. Mirrors Kotlin NoopPrefs.skyBehindCards.
    @AppStorage(SkyBehindCardsPrefs.enabledKey) private var skyBehindCards = true
    // Card-surface opacity percent (100 = solid). Reactive — moving the slider live-updates every card.
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    // "Reduce motion in NOOP" (default OFF): pose every looping animation still and stop the decorative
    // tilt sensor, without needing system Low Power Mode or system Reduce Motion. Apple-only so far —
    // Android has no such toggle yet and its gate reads two signals, not three (#941).
    @AppStorage(QuietMotionPrefs.enabledKey) private var quietMotion = false
    // Hydration tracker (opt-in, MVP). Default OFF — when off the hydration dashboard card + detail are
    // hidden. Mirrors the Android pref so the toggle reads the same on both platforms.
    @AppStorage(HydrationStore.enabledKey) private var hydrationEnabled = false

    /// Opt-in "Auto-detect workouts" (default OFF). When ON, Today scans the last day or two of HR for a
    /// sustained-elevated window and offers — via a single dismissible card — to save it as a workout.
    /// Nothing is ever created automatically. Mirrors the Android `NoopPrefs.KEY_AUTO_DETECT_WORKOUTS`.
    @AppStorage(PuffinExperiment.autoDetectWorkoutsKey) private var autoDetectWorkoutsEnabled = false

    /// "Journal reminder" (#627, default ON). When ON, Today shows the persistent journal widget
    /// (last-7-days strip + tap-through). Mirrors the Android `NoopPrefs.KEY_JOURNAL_REMINDER_ENABLED`.
    @AppStorage(PuffinExperiment.journalReminderKey) private var journalReminderEnabled = true

    /// Opt-in "Keep screen on during a workout" (default OFF, #703). When ON, the live-workout view
    /// holds the screen awake while a manual recording is running so you can glance at your live HR
    /// without the device dimming. The live-workout view reads this same key. The string is shared
    /// verbatim with the Android twin (SharedPreferences "workoutKeepScreenOn").
    @AppStorage("workoutKeepScreenOn") private var workoutKeepScreenOn = false

    /// Opt-in "Keep screen on while syncing" (default OFF, iOS only). `SyncKeepAwake` holds the screen awake
    /// for as long as a strap history sync runs while this is on.
    @AppStorage(ScreenIdle.strapSyncKeepAwakeKey) private var syncKeepScreenOn = false

    /// The strap model the user last picked (same key the scan pickers write). Gates the WHOOP 4.0-only
    /// rename control in the strap card — renaming uses the Harvard command set, which a 5/MG doesn't share.
    @AppStorage("selectedWhoopModel") private var selectedWhoopModelRaw = WhoopModel.whoop4.rawValue
    /// Draft text for the strap-rename field (strap card). Empty placeholder; never pre-seeded so the
    /// current name stays visible separately above it.
    @State private var strapNameDraft = ""

    /// Whether to surface the WHOOP 5/MG-only probes (puffin/R22/broadcast-HR/frame-capture). Gated so a
    /// confident 4.0 owner never sees 5/MG controls that can't touch their strap (#22). The model
    /// preference DEFAULTS to whoop4, so we deliberately do NOT hide on the raw default alone — the same
    /// `"selectedWhoopModel"` key is rewritten to the family that actually advertised when a strap
    /// connects (BLEManager, PR#195), so a real 5/MG owner who never opened the model picker still flips
    /// this true the moment their strap is discovered. We hide the 5/MG block only when the user is
    /// confidently on a 4.0 (pref says whoop4 AND nothing 5/MG is connected). The always-on raw-CSV
    /// diagnostic stays visible on every model regardless.
    private var showFiveMGControls: Bool {
        selectedWhoopModelRaw == WhoopModel.whoop5mg.rawValue
    }

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(system: unitSystem, override: distanceSystemRaw)
    }
    private var distanceSystemBinding: Binding<String> {
        Binding(get: { distanceUnitSystem.rawValue }, set: { distanceSystemRaw = $0 })
    }

    /// Raw-sensor CSV export (experimental diagnostic, #308/#276/#322). Holds the last-written file so
    /// macOS can "Reveal in Finder" after a share, mirroring the puffin-capture export.
    @State private var rawCsvBusy = false
    @State private var lastRawCsvURL: URL?

    /// Passive WHOOP 5/MG optical experiment: the picker writes local timestamp markers into the
    /// durable deep-buffer JSONL. It never calls a BLE write path.
    @State private var showOpticalPhasePicker = false
    @State private var opticalPhaseStatus = ""

    /// Confirm gate for the "Recalibrate Charge baseline" action (it re-learns the HRV anchor from tonight).
    @State private var showRecalibrateConfirm = false

    /// "What's New" changelog sheet, reachable any time from About.
    @State private var showWhatsNew = false

    /// "How your scores work" explainer sheet, reachable any time from About.
    @State private var showScoringGuide = false

    /// "How NOOP works" primer sheet (the four-section explainability primer), reachable any
    /// time from About — covers how sleep is sorted, how scores + calibration work, what
    /// recording means, and where the provenance badges come from.
    @State private var showHowNoopWorks = false

    /// "Set up Apple Watch" sheet: the honest watch onboarding flow (what it's great at, where
    /// it's lighter, then the Health permission request). Presented from the About page's primary
    /// action. iOS does the real HealthKit request; macOS reads as an iPhone-only step.
    @State private var showAppleWatchSetup = false

    /// Steps-estimate calibration sheet (WHOOP 4.0). Reached from the Profile card's "Steps estimate"
    /// tap-through; explains the estimate, shows the current fit + a recent estimated-vs-phone table,
    /// and offers a manual coefficient override. See [StepsCalibrationSheet].
    @State private var showStepsCalibration = false

    /// iOS environment-diagnostics sheet (device, iOS+build, Data Protection, background refresh,
    /// low-power, sideload + cert expiry). iOS-only; the macOS strap log already carries OS + version.
    @State private var showDiagnostics = false

    /// User-initiated GitHub release check behind the About "Check for updates" button.
    @StateObject private var updateChecker = UpdateChecker()
    /// #1659. Default comes from `UpdateAvailability.defaultEnabled` so the toggle and the launch check
    /// cannot disagree about what "unset" means.
    @AppStorage(UpdateWatch.Keys.enabled) private var autoCheckUpdates = UpdateAvailability.defaultEnabled
    @Environment(\.openURL) private var openURL

    /// Whether the "Advanced" disclosure (Recovery, Test Centre, experimental probes, Backup &
    /// restore) is expanded. Default FALSE so a first-run user lands on the handful of everyday
    /// sections (profile, units, appearance, strap, features) instead of the full wall of 11 cards
    /// (S3). Nothing is removed; every section below stays one tap away by expanding this group.
    /// Persisted so it remembers the user's choice; mirrors the Android `noop.settingsAdvancedOpen` key.
    @AppStorage(SettingsDisclosureDefaults.advancedOpenKey) private var advancedOpen = SettingsDisclosureDefaults.advancedOpenDefault

    /// Which screen this instance draws: nil is the Settings hub, otherwise one of its pages. Every page is
    /// a SettingsView of its own, so the cards keep their bindings and each page carries the shared alerts
    /// and sheets below.
    private let page: SettingsPage?

    init(page: SettingsPage? = nil) {
        self.page = page
    }

    /// The hub's search: a field under the title that filters every row by name and caption.
    @State private var searching = false
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool
    /// The Profile page's open inline editor (one at a time), by row id.
    @State private var openEditor: String?
    /// Confirms the Appearance page's reset to the Mint preset.
    @State private var showAppearanceReset = false

    var body: some View {
        ScreenScaffold(title: nil, topBackground: liquidScaffoldSky()) {
            if let page {
                pageContent(page)
            } else {
                hubContent
            }
        }
        // Every Settings screen draws its own v2 header (back circle + title), so the system bar goes.
        .noopHidesSystemNavBar()
        // The hub registers the page destinations once; a page never re-registers them (a second
        // registration of the same type in one stack double-pushes, #38).
        .modifier(SettingsPageDestinations(enabled: page == nil))
        .confirmationDialog("Reset the look?", isPresented: $showAppearanceReset, titleVisibility: .visible) {
            Button("Reset to Mint") { resetAppearance() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Returns the theme, accent, chart colours, sleep chart, motion and card settings to the Mint preset. Language, clock and AI Coach stay as they are.")
        }
        .alert(backupAlertTitle, isPresented: $showBackupAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(backupAlertMessage)
        }
        // Title and buttons reuse catalogue strings that already carry all nine locales, rather than
        // minting new copy that would ship English everywhere until someone translated it. The message
        // below is where the specifics live. (#1807)
        .alert("Backup problem", isPresented: $showOversizeRestoreConfirm) {
            Button("Restore") { runImport(allowOversize: true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(oversizeRestoreMessage)
        }
        .confirmationDialog("Recalibrate your Charge baseline?",
                            isPresented: $showRecalibrateConfirm, titleVisibility: .visible) {
            Button("Recalibrate") { recalibrateHrvBaseline() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This restarts the roughly 4-night build-up for Charge and your HRV baseline. Your history stays. Use it if a bad first week, like wearing it while sick, set your baseline off.")
        }
        // #174: the switch going OFF is the moment to offer the undo. Declining leaves the flags set and
        // says so — which is still an improvement on the old behaviour, where the same tap silently left
        // them set with no indication either way.
        .confirmationDialog("Clear the R22 flags on your strap?",
                            isPresented: $confirmingDeepDataDisable, titleVisibility: .visible) {
            Button("Clear flags on strap") { model.ble.disableWhoop5DeepData() }
            Button("Just stop sending", role: .cancel) { }
        } message: {
            Text("Turning this switch off only stops NOOP sending the unlock. The flags it already wrote stay on the strap until something clears them. NOOP can write the off value to all 16 now and read each one back so you can see what the strap actually stores. Needs the strap connected and bonded.")
        }
        .confirmationDialog("Mark optical experiment phase",
                            isPresented: $showOpticalPhasePicker, titleVisibility: .visible) {
            ForEach(PuffinOpticalExperimentPhase.allCases, id: \.self) { phase in
                Button(phase.displayName) { markOpticalPhase(phase) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("A marker starts the selected phase and ends the previous one. This only timestamps the local capture file; it sends nothing to the strap.")
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(onClose: { showWhatsNew = false })
        }
        .sheet(isPresented: $showScoringGuide) {
            ScoringGuideView(onClose: { showScoringGuide = false })
        }
        .sheet(isPresented: $showHowNoopWorks) {
            HowNoopWorksView(onClose: { showHowNoopWorks = false })
        }
        .sheet(isPresented: $showAppleWatchSetup) {
            AppleWatchSetupView(onClose: { showAppleWatchSetup = false })
        }
        .sheet(isPresented: $showStepsCalibration) {
            StepsCalibrationSheet(repo: model.repo, onClose: { showStepsCalibration = false })
                .environmentObject(profile)
        }
        #if os(iOS)
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsSheet(onClose: { showDiagnostics = false })
        }
        #endif
    }

    // MARK: - Hub (v2)

    /// The Settings hub: the profile hero, then Personal / Strap & app / Advanced / About as rows that open
    /// one page each. Every section of the old long screen is one of those pages, so nothing is dropped.
    @ViewBuilder private var hubContent: some View {
        NoopScreenHeader(verbatim: "") {
            NoopCircleButton(searching ? "x" : "magnifying-glass",
                             accessibilityLabel: searching ? "Close search" : "Search settings") {
                withAnimation(StrandMotion.interactive) {
                    searching.toggle()
                    if !searching { searchQuery = "" }
                }
                searchFocused = searching
            }
        }
        .padding(.bottom, 6)
        NoopPageTitle("Settings", subtitle: "Tune NOOP to you. Every setting stays on \(Platform.deviceNounPhrase).")
            .padding(.bottom, 10)
        if searching {
            G6SearchField(placeholder: String(localized: "Search settings"), text: $searchQuery,
                          focused: $searchFocused)
        }
        if searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            SettingsProfileHero(
                avatar: profile.avatarImageData,
                bodyLine: profileBodyLine,
                daysOfHistory: daysOfHistory,
                baselinesSettled: model.repo.days.contains { $0.recovery != nil },
                hrvAverage: thirtyDayAverage(\.avgHrv),
                restingAverage: thirtyDayAverage { $0.restingHr.map(Double.init) },
                hrMax: profile.hrMax)
            NoopSectionTitle("Personal", caption: String(localized: "Feeds every score"))
            NoopList { ForEach(personalItems) { hubRow($0) } }
            NoopSectionTitle("Strap & app", caption: strapSectionCaption)
            NoopList { ForEach(strapItems) { hubRow($0) } }
            advancedCard
            NoopSectionTitle("About", caption: String(localized: "Open source · PolyForm NC"))
            NoopList { ForEach(aboutItems) { hubRow($0) } }
            Text(verbatim: hubFooter)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
        } else {
            hubSearchResults
        }
    }

    @ViewBuilder private var hubSearchResults: some View {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        let matches = (personalItems + strapItems + advancedItems + aboutItems).filter {
            $0.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || ($0.caption?.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
        if matches.isEmpty {
            Text("No matches")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 30)
        } else {
            NoopList { ForEach(matches) { hubRow($0) } }
        }
    }

    /// One hub row: a page push, a sheet, a pushed screen, or the external project link.
    @ViewBuilder private func hubRow(_ item: SettingsHubItem) -> some View {
        let label = G6NavRowLabel(title: Text(verbatim: item.title), caption: item.caption.map { Text(verbatim: $0) },
                                  icon: item.icon, trailing: item.trailing.map { Text(verbatim: $0) },
                                  chevron: item.target == .github ? "arrow-up-right" : "caret-right")
        switch item.target {
        case .page(let page):
            NavigationLink(value: page) { label }.buttonStyle(.plain)
        case .testCentre:
            NavigationLink(destination: TestCentreView()) { label }.buttonStyle(.plain)
        case .howNoopWorks:
            Button { showHowNoopWorks = true } label: { label }.buttonStyle(.plain)
        case .scoringGuide:
            Button { showScoringGuide = true } label: { label }.buttonStyle(.plain)
        case .appleWatch:
            NavigationLink {
                AppleWatchAboutView(onStartSetup: { showAppleWatchSetup = true })
            } label: { label }.buttonStyle(.plain)
        case .storage:
            // Storage (#590): the on-device space breakdown and the one-tap clean-up.
            NavigationLink { StorageView() } label: { label }.buttonStyle(.plain)
        case .github:
            // Project home — NOOP's code, releases, issues and wiki live on GitHub.
            Link(destination: URL(string: "https://github.com/ryanbr/noop")!) { label }
                .buttonStyle(.plain)
                .accessibilityLabel("Project home and source code on GitHub")
        }
    }

    private var personalItems: [SettingsHubItem] {
        [
            SettingsHubItem(title: String(localized: "Profile"),
                            caption: String(localized: "Birthday, body, heart-rate zones"),
                            icon: "user-circle", target: .page(.profile)),
            SettingsHubItem(title: String(localized: "Units"), caption: unitsSummary,
                            icon: "ruler", target: .page(.units)),
            SettingsHubItem(title: String(localized: "Appearance"), caption: appearanceSummary,
                            icon: "palette", target: .page(.appearance)),
        ]
    }

    private var strapItems: [SettingsHubItem] {
        var items = [
            SettingsHubItem(title: String(localized: "Strap"),
                            caption: [activeDeviceName, String(localized: "strap log")]
                                .compactMap { $0 }.joined(separator: " · "),
                            icon: "watch", target: .page(.strap)),
        ]
        #if os(iOS)
        items.append(SettingsHubItem(title: String(localized: "Live notifications"),
                                     caption: String(localized: "Heart rate, Lift Log and sync on the Lock Screen"),
                                     icon: "bell-ringing", target: .page(.liveNotifications)))
        #endif
        items.append(SettingsHubItem(title: String(localized: "Streak"), caption: streakSummary,
                                     icon: "calendar-check", target: .page(.streak)))
        items.append(SettingsHubItem(title: String(localized: "Features"),
                                     caption: String(localized: "Hydration, auto-detect workouts, journal reminder"),
                                     icon: "toggle-right", target: .page(.features)))
        #if os(iOS)
        items.append(SettingsHubItem(title: String(localized: "Sync"),
                                     caption: syncKeepScreenOn
                                        ? String(localized: "Screen stays on while syncing")
                                        : String(localized: "Screen sleeps normally while syncing"),
                                     icon: "arrows-clockwise", target: .page(.sync)))
        #endif
        return items
    }

    /// Advanced: the lower-frequency sections, each its own page (S3: a fresh install lands with them
    /// tucked away, `advancedOpen` keeps the user's choice).
    private var advancedItems: [SettingsHubItem] {
        [
            SettingsHubItem(title: String(localized: "Recovery"),
                            caption: String(localized: "Recalibrate your Charge baseline"),
                            icon: "heart", target: .page(.recovery)),
            SettingsHubItem(title: String(localized: "HRV"),
                            caption: String(localized: "Continuous capture and the HRV window"),
                            icon: "pulse", target: .page(.hrv)),
            SettingsHubItem(title: String(localized: "Test Centre"),
                            caption: String(localized: "Diagnostics, strap log and bug reports"),
                            icon: "stethoscope", target: .testCentre),
            SettingsHubItem(title: String(localized: "Experimental"),
                            caption: String(localized: "Live Sessions, sleep staging and other trials"),
                            icon: "flask", target: .page(.experimental)),
            SettingsHubItem(title: String(localized: "Diagnostics"),
                            caption: String(localized: "Raw sensor export for bug reports"),
                            icon: "file-magnifying-glass", target: .page(.diagnostics)),
            SettingsHubItem(title: String(localized: "Backup & restore"),
                            caption: String(localized: "Move everything to another device"),
                            icon: "hard-drives", target: .page(.backup)),
        ]
    }

    private var aboutItems: [SettingsHubItem] {
        [
            SettingsHubItem(title: String(localized: "How NOOP works"), caption: nil,
                            icon: "info", target: .howNoopWorks),
            SettingsHubItem(title: String(localized: "How your scores work"), caption: nil,
                            icon: "gauge", target: .scoringGuide),
            SettingsHubItem(title: String(localized: "About Apple Watch data"), caption: nil,
                            icon: "question", target: .appleWatch),
            SettingsHubItem(title: String(localized: "Storage"), caption: nil,
                            icon: "hard-drives", target: .storage),
            SettingsHubItem(title: String(localized: "Check for updates"), caption: nil,
                            icon: "download-simple", target: .page(.updates), trailing: updatesSummary),
            SettingsHubItem(title: String(localized: "Project on GitHub"),
                            caption: String(localized: "Source, issues and release notes"),
                            icon: "code", target: .github),
            SettingsHubItem(title: String(localized: "About NOOP"),
                            caption: String(localized: "What NOOP is, the medical disclaimer and credits"),
                            icon: "seal-check", target: .page(.about)),
        ]
    }

    /// The Advanced card: a header row that opens and closes the group, then either the page chips
    /// (closed) or one row per page (open).
    private var advancedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { advancedOpen.toggle() }
            } label: {
                HStack(spacing: 14) {
                    G6IconTile(icon: "sliders-horizontal")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Advanced")
                            .font(StrandFont.book(15, relativeTo: .body))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("For tinkerers and bug reports")
                            .font(StrandFont.light(12.5, relativeTo: .caption))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    PhIcon(advancedOpen ? "caret-up" : "caret-down", size: 15)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .opacity(0.5)
                }
                .padding(.leading, 14)
                .padding(.trailing, 16)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Advanced"))
            .accessibilityValue(advancedOpen ? Text("Expanded") : Text("Collapsed"))
            .accessibilityHint(Text("Shows the advanced settings sections"))

            if advancedOpen {
                ForEach(advancedItems) { item in
                    Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
                    hubRow(item)
                }
            } else {
                G6FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(advancedItems) { item in
                        advancedChip(item)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 16)
                .padding(.top, 2)
                .padding(.bottom, 16)
            }
        }
        .background(RoundedRectangle(cornerRadius: NoopVisualStyle.listRadius, style: .continuous)
            .fill(NoopVisualStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: NoopVisualStyle.listRadius, style: .continuous)
            .strokeBorder(NoopVisualStyle.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: NoopVisualStyle.listRadius, style: .continuous))
    }

    @ViewBuilder private func advancedChip(_ item: SettingsHubItem) -> some View {
        let chip = G6OutlineChip(title: Text(verbatim: item.title))
        switch item.target {
        case .page(let page): NavigationLink(value: page) { chip }.buttonStyle(.plain)
        case .testCentre: NavigationLink(destination: TestCentreView()) { chip }.buttonStyle(.plain)
        default: EmptyView()
        }
    }

    // MARK: Hub summaries

    /// "35 · 74.2 kg · 182 cm", in the body units the user chose.
    private var profileBodyLine: String {
        let weight = unitSystem == .imperial
            ? "\(Int(UnitFormatter.kgToPounds(profile.weightKg).rounded())) lb"
            : String(format: "%.1f kg", profile.weightKg)
        let height: String
        if unitSystem == .imperial {
            let parts = UnitFormatter.cmToFeetInches(profile.heightCm)
            height = "\(parts.feet)′ \(parts.inches)″"
        } else {
            height = String(format: "%.0f cm", profile.heightCm)
        }
        return "\(profile.age) · \(weight) · \(height)"
    }

    /// Days since the earliest stored day, and that day — the "626 days of history since Jan 2025" line.
    private var daysOfHistory: (count: Int, since: Date)? {
        guard let first = model.repo.freshness.earliestDay,
              let date = Self.dayKeyFormatter.date(from: first) else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date),
                                                   to: Calendar.current.startOfDay(for: Date())).day ?? 0
        return (max(days + 1, 1), date)
    }

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Plain mean of a nightly value over the last 30 loaded days, for the hero's reference figures.
    private func thirtyDayAverage(_ value: (DailyMetric) -> Double?) -> Double? {
        let values = model.repo.days.suffix(30).compactMap(value)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var activeDeviceName: String? {
        model.deviceRegistry?.devices.first { $0.status == .active }?.displayName
    }

    /// "WHOOP 4.0 · 82 %" over the Strap & app list.
    private var strapSectionCaption: String? {
        guard let name = activeDeviceName else { return nil }
        if live.connected, let pct = live.batteryPct { return "\(name) · \(Int(pct.rounded())) %" }
        return name
    }

    private var unitsSummary: String {
        let body = unitSystem == .imperial ? String(localized: "Imperial") : String(localized: "Metric")
        let temp: String
        switch TemperatureUnit(rawValue: temperatureRaw) {
        case .celsius?: temp = "°C"
        case .fahrenheit?: temp = "°F"
        case nil: temp = unitSystem == .imperial ? "°F" : "°C"
        }
        let effort = effortScaleRaw == EffortScale.whoop.rawValue ? "0–21" : "0–100"
        return "\(body) · \(temp) · \(String(localized: "Effort \(effort)"))"
    }

    /// The Units card's temperature value: "Follow body" or the pinned unit.
    private var temperatureMenuLabel: String {
        switch TemperatureUnit(rawValue: temperatureRaw) {
        case .celsius?: return "°C"
        case .fahrenheit?: return "°F"
        case nil: return String(localized: "Follow body")
        }
    }

    private var appearanceSummary: String {
        let mode = AppearanceMode(rawValue: appearanceRaw)?.label ?? AppearanceMode.defaultMode.label
        let accent = AccentColor.resolve(accentRaw).label
        let liquid = liquidTodayEnabled ? String(localized: "Liquid Today on") : String(localized: "Liquid Today off")
        return "\(mode) · \(String(localized: "\(accent) accent")) · \(liquid)"
    }

    private var streakSummary: String {
        let days = model.repo.days
        let today = AnalyticsEngine.dayString(Int(Date().timeIntervalSince1970),
                                              offsetSec: TimeZone.current.secondsFromGMT())
        let s = StreakCalculator.streaks(dayKeys: days.map { $0.day },
                                         qualified: days.map { $0.recovery != nil },
                                         today: today)
        return s.current == 1
            ? String(localized: "Charge streak · 1 day in a row")
            : String(localized: "Charge streak · \(s.current) days in a row")
    }

    private var updatesSummary: String {
        switch updateChecker.state {
        case .upToDate:
            return "\(bundleVersionString) · \(String(localized: "up to date"))"
        case .available(let v, _, _):
            return String(localized: "\(v) available")
        default:
            return bundleVersionString
        }
    }

    private var hubFooter: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let version = build.map { "\(bundleVersionString) (\($0))" } ?? bundleVersionString
        return "NOOP \(version) · \(String(localized: "offline by design"))"
    }

    // MARK: - Pages (v2)

    /// One Settings page: the v2 header, then that page's sections.
    @ViewBuilder private func pageContent(_ page: SettingsPage) -> some View {
        NoopScreenHeader(page.title) { pageHeaderTrailing(page) }
            .padding(.bottom, 6)
        switch page {
        case .profile:
            profilePage
        case .units:
            unitsCard.environment(\.settingsSectionShowsTitle, false)
        case .appearance:
            appearancePage
        case .strap:
            strapCard.environment(\.settingsSectionShowsTitle, false)
        case .liveNotifications:
            #if os(iOS)
            liveNotificationsCard.environment(\.settingsSectionShowsTitle, false)
            #else
            EmptyView()
            #endif
        case .streak:
            streakCard
        case .features:
            featuresCard.environment(\.settingsSectionShowsTitle, false)
        case .sync:
            #if os(iOS)
            syncCard.environment(\.settingsSectionShowsTitle, false)
            #else
            EmptyView()
            #endif
        case .recovery:
            recoveryCard.environment(\.settingsSectionShowsTitle, false)
        case .hrv:
            hrvCard.environment(\.settingsSectionShowsTitle, false)
        case .experimental:
            experimentalCard
        case .diagnostics:
            rawSensorDiagnosticsCard.environment(\.settingsSectionShowsTitle, false)
            #if os(iOS)
            // iOS reality & diagnostics: the one-tap environment dump for bug reports.
            NoopList { iosDiagnosticsRow }
            #endif
        case .backup:
            backupCard.environment(\.settingsSectionShowsTitle, false)
        case .updates:
            updatesPage
        case .about:
            aboutCard.environment(\.settingsSectionShowsTitle, false)
        }
    }

    @ViewBuilder private func pageHeaderTrailing(_ page: SettingsPage) -> some View {
        if page == .appearance {
            NoopCircleButton("arrow-counter-clockwise", accessibilityLabel: "Reset the look") {
                showAppearanceReset = true
            }
        }
    }

    /// The Appearance page's reset: the Mint preset recipe plus the default theme, sleep chart, trend
    /// chart and motion. Language, clock, AI Coach and the tab-bar behaviour are left alone.
    private func resetAppearance() {
        appearanceRaw = AppearanceMode.defaultMode.rawValue
        themePresetBinding.wrappedValue = .mint
        sleepChartStyleRaw = SleepChartStyle.classic.rawValue
        trendChartStyleRaw = TrendChartStyle.line.rawValue
        quietMotion = false
        skyBehindCards = true
    }

    // MARK: Profile page

    /// The Profile page: the heart-rate zone hero, then Body / Heart / Day lists and the photo. Every field
    /// of the old Profile card is here; numbers edit in place (the row opens a stepper or a wheel).
    @ViewBuilder private var profilePage: some View {
        SettingsZonesHero(zones: profile.hrZoneSet, hrMax: profile.hrMax,
                          isCustom: profile.hasCustomHRZones, isManual: profile.hrMaxOverride > 0)
        NoopSectionTitle("Body", caption: String(localized: "Feeds calories and fitness age"))
        NoopList {
            dateOfBirthRow
            G6MenuRow(title: Text("Sex"), selection: $profile.sex, valueText: sexLabel) {
                Text("Male").tag("male")
                Text("Female").tag("female")
                Text("Non-binary").tag("nonbinary")
            }
            G6DisclosureRow(title: Text("Weight"), value: weightValue, unit: unitSystem == .imperial ? "lb" : "kg",
                            isOpen: editorBinding("weight")) {
                if unitSystem == .imperial {
                    poundsField(weightKg: $profile.weightKg, showsValue: false)
                } else {
                    measureField(value: $profile.weightKg, unit: "kg", range: 30...250, step: 0.5, format: "%.1f",
                                 accessibility: String(localized: "Weight in kilograms"), showsValue: false)
                }
            }
            G6DisclosureRow(title: Text("Height"), value: heightValue,
                            unit: unitSystem == .imperial ? nil : "cm", isOpen: editorBinding("height")) {
                if unitSystem == .imperial {
                    feetInchesField(heightCm: $profile.heightCm, showsValue: false)
                } else {
                    measureField(value: $profile.heightCm, unit: "cm", range: 120...230, step: 1, format: "%.0f",
                                 accessibility: String(localized: "Height in centimetres"), showsValue: false)
                }
            }
            // Waist (optional): an empty waist is valid (0 = unset). It upgrades VO₂max to the Nes
            // waist-based estimate (#1391); the Fitness Age itself does not need it.
            G6DisclosureRow(title: Text("Waist (optional)"), value: waistValue,
                            unit: profile.waistCm > 0 ? (unitSystem == .imperial ? "in" : "cm") : nil,
                            isOpen: editorBinding("waist")) {
                if unitSystem == .imperial {
                    waistInchesField(waistCm: $profile.waistCm, showsValue: false)
                } else {
                    waistCentimetresField(waistCm: $profile.waistCm, showsValue: false)
                }
            }
        }
        G6Footnote("Optional: VO₂max builds from about 4 nights of heart rate; a waist makes it more accurate. The Fitness Age itself doesn't need it. Measure around your middle, at the navel.")
            .padding(.horizontal, 4)

        NoopSectionTitle("Heart", caption: String(localized: "Shapes Effort"))
        NoopList {
            G6DisclosureRow(title: Text("Max heart rate"),
                            caption: profile.hrMaxOverride > 0 ? Text("Manual override") : Text("Auto · \(profile.hrMax) bpm (Tanaka)"),
                            value: "\(profile.hrMax)", unit: "bpm", isOpen: editorBinding("hrmax")) {
                hrMaxField
            }
            // Custom HR zones (#531, @kavemang): replace the conventional %HRmax bands with five
            // personalized inclusive BPM lower bounds. Off = the effective set stays conventional.
            G6ToggleRow("Custom HR zones",
                        caption: profile.hasCustomHRZones
                            ? Text("On · your own five zone starts")
                            : Text("Off · zones follow your max heart rate"),
                        isOn: Binding(get: { profile.hasCustomHRZones },
                                      set: { profile.setCustomHRZonesEnabled($0) }))
            if profile.hasCustomHRZones {
                ForEach(profile.hrZoneThresholds.indices, id: \.self) { index in
                    G6Row(title: Text("Zone \(index + 1) starts")) { hrZoneThresholdField(index: index) }
                }
            }
        }
        if profile.hasCustomHRZones {
            G6Footnote("Set the BPM where each zone begins. Turn off to restore the default percentage-of-max zones.")
                .padding(.horizontal, 4)
        }

        NoopSectionTitle("Day", caption: String(localized: "How a day is counted"))
        NoopList {
            G6MenuRow(title: Text("Day cycle"), caption: Text("When a new day starts"),
                      selection: dayCycleBinding,
                      valueText: dayCycleModeRaw == DayCycleMode.midnight.rawValue
                        ? "00:00" : String(localized: "Main sleep")) {
                Text("Main sleep").tag(DayCycleMode.sleepOnset)
                Text("00:00").tag(DayCycleMode.midnight)
            }
            // Step calibration (#139/#132): daily steps = @57 counter ticks ÷ this divisor. 1.0 = raw
            // pass-through; up to 30 because a 5/MG motion counter can overcount by ~24×; the stepper uses a
            // variable increment (fine near 1.0, coarse up top) so high values stay reachable.
            G6DisclosureRow(title: Text("Step calibration"), caption: Text("Counter ticks per step"),
                            value: String(format: "%.1f", profile.stepTicksPerStep),
                            isOpen: editorBinding("steps")) {
                Stepper("Step calibration") {
                    profile.stepTicksPerStep = ProfileStore.steppedStepScale(profile.stepTicksPerStep, up: true)
                } onDecrement: {
                    profile.stepTicksPerStep = ProfileStore.steppedStepScale(profile.stepTicksPerStep, up: false)
                }
                .labelsHidden()
                .accessibilityLabel("Step calibration, \(String(format: "%.1f", profile.stepTicksPerStep)) counter ticks per step")
            }
            // The WHOOP 4.0 steps ESTIMATE calibration (separate from the 5/MG @57 divisor above): a 4.0
            // sends no step count, so NOOP estimates steps from motion and calibrates that to the phone.
            Button {
                showStepsCalibration = true
            } label: {
                G6Row(title: Text("Steps estimate"), caption: Text("WHOOP 4.0 · calibrated to your phone")) {
                    G6Value(value: stepsCalibrationSummary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Steps estimate calibration. \(stepsCalibrationSummary). Opens the calibration screen.")
        }
        G6Footnote(text: Text(dayCycleModeRaw == DayCycleMode.midnight.rawValue
             ? "Uses a conventional local calendar day from 00:00 to 00:00."
             : "Default. Steps and in-progress Effort restart at the beginning of detected main sleep. Naps do not start a new day; missing sleep falls back to local midnight."))
            .padding(.horizontal, 4)
        G6Footnote("Counter ticks per step. Leave at 1.0 unless your steps run high. On a WHOOP 5/MG they can run very high (10× or more), so this goes up to 30. Walk a known 1,000 steps and divide NOOP's count by the real count to get your value.")
            .padding(.horizontal, 4)

        NoopSectionTitle("Photo", caption: String(localized: "Optional"))
        NoopList { profilePhotoRow }

        NoopInsightRow(text: Text("Your profile lives on \(Platform.deviceNounPhrase) only. NOOP never sends it anywhere."),
                       icon: "lock-simple")
            .padding(.horizontal, 4)
            .padding(.top, 10)
    }

    /// One inline editor open at a time on the Profile page.
    private func editorBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { openEditor == id }, set: { openEditor = $0 ? id : nil })
    }

    /// #146: age is derived from the date of birth, so it advances on its own.
    private var dateOfBirthRow: some View {
        G6DisclosureRow(title: Text("Date of birth"), caption: Text("Age \(profile.age)"),
                        value: profile.dateOfBirth.formatted(date: .abbreviated, time: .omitted),
                        isOpen: editorBinding("dob")) {
            DatePicker("Date of birth",
                       selection: $profile.dateOfBirth,
                       in: ProfileStore.dateOfBirthRange,
                       displayedComponents: .date)
                .labelsHidden()
                #if os(iOS)
                .datePickerStyle(.wheel)
                #endif
                .accessibilityLabel("Date of birth, age \(profile.age) years")
        }
    }

    private var sexLabel: String {
        switch profile.sex {
        case "female": return String(localized: "Female")
        case "nonbinary": return String(localized: "Non-binary")
        default: return String(localized: "Male")
        }
    }

    private var weightValue: String {
        unitSystem == .imperial
            ? String(format: "%.0f", UnitFormatter.kgToPounds(profile.weightKg))
            : String(format: "%.1f", profile.weightKg)
    }

    private var heightValue: String {
        if unitSystem == .imperial {
            let parts = UnitFormatter.cmToFeetInches(profile.heightCm)
            return "\(parts.feet)′ \(parts.inches)″"
        }
        return String(format: "%.0f", profile.heightCm)
    }

    private var waistValue: String {
        guard profile.waistCm > 0 else { return String(localized: "Not set") }
        return unitSystem == .imperial
            ? "\(Int(UnitFormatter.cmToInches(profile.waistCm).rounded()))"
            : String(format: "%.0f", profile.waistCm)
    }

    /// The day-cycle choice; a change re-scores so Steps and in-progress Effort move to the new day edge.
    private var dayCycleBinding: Binding<DayCycleMode> {
        Binding(
            get: { DayCycleMode.persisted(dayCycleModeRaw) },
            set: { mode in
                dayCycleModeRaw = mode.rawValue
                Task { await model.intelligence.analyzeRecent(); await model.repo.refresh() }
            }
        )
    }

    // MARK: Appearance page

    /// The Appearance page: a live preview of the look, then General, Theme, Sleep chart style, Motion &
    /// surfaces and the experimental Liquid Today, each bound to its existing preference key.
    @ViewBuilder private var appearancePage: some View {
        AppearancePreviewHero(
            themeLabel: AppearanceMode(rawValue: appearanceRaw)?.label ?? AppearanceMode.defaultMode.label,
            presetLabel: themePresetBinding.wrappedValue.label,
            accentLabel: AccentColor.resolve(accentRaw).label,
            accent: StrandPalette.accent,
            liquidToday: liquidTodayEnabled,
            transparency: 100 - cardOpacityPercent,
            charge: model.repo.days.last(where: { $0.recovery != nil })?.recovery,
            sleepMinutes: model.repo.days.last(where: { $0.totalSleepMin != nil })?.totalSleepMin,
            effort: model.repo.days.last(where: { $0.strain != nil })?.strain)

        NoopSectionTitle("General", caption: String(localized: "Language and layout"))
        NoopList {
            // App-owned copy language. Apple binds a bundle localization at process launch, so this takes
            // effect after the user reopens NOOP (the caption says so).
            G6MenuRow(title: Text("Language"), caption: Text("Takes effect after you reopen NOOP"),
                      selection: $appLanguageRaw, valueText: languageLabel) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language == .system ? String(localized: "System default") : language.autonym)
                        .tag(language.rawValue)
                }
            }
            .onChangeCompat(of: appLanguageRaw) { AppLanguage.apply($0) }
            // #1821: a display CONVENTION rather than a unit; "System default" follows the device's own
            // 24-Hour Time switch. No relaunch: the formatter caches per resolved template.
            G6MenuRow(title: Text("Clock"), selection: $clockFormatRaw, valueText: clockLabel) {
                Text("System default").tag(ClockFormatPreference.system.rawValue)
                Text("12-hour").tag(ClockFormatPreference.twelveHour.rawValue)
                Text("24-hour").tag(ClockFormatPreference.twentyFourHour.rawValue)
            }
            // #1829: the resolved clock is memoised, so the write has to drop the memo.
            .onChangeCompat(of: clockFormatRaw) { _ in AppClock.invalidate() }
            // The Coach master switch: not chrome — with it off the AI is off (tab, launcher card and the
            // daily brief). The saved provider key is kept, so this is a flip rather than a re-setup.
            G6ToggleRow("AI Coach", caption: Text("Shows the Coach tab and the daily brief"), isOn: $coachEnabled)
                .onChangeCompat(of: coachEnabled) { on in
                    // Take down what the brief already published, not just stop the next one.
                    CoachBriefScheduler.applyMasterSwitch(on)
                }
            #if os(iOS)
            // #1841: the system owns the behaviour (iOS 26 minimises the tab bar to a pill on scroll);
            // inert below iOS 26, which is why it is not offered there.
            if #available(iOS 26.0, *) {
                G6ToggleRow("Hide bar when scrolling", caption: Text("Minimises the tab bar while you scroll"),
                            isOn: $bottomBarAutoHide)
            }
            #endif
        }

        NoopSectionTitle("Theme", caption: themePresetBinding.wrappedValue == .custom
                         ? String(localized: "Custom")
                         : String(localized: "\(themePresetBinding.wrappedValue.label) preset"))
        NoopList {
            G6Block(nil) {
                SegmentedPillControl(AppearanceMode.allCases, selection: appearanceModeBinding,
                                     fillsAvailableWidth: true) { $0.label }
            }
            // Theme presets — one-tap bundles coordinating accent + chart world + backdrop + card opacity.
            // Derived (no stored value): tweaking any control below flips this to Custom.
            G6Block("Preset", caption: Text("\(ThemePreset.allCases.count - 1) looks")) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ThemePreset.allCases.filter { $0 != .custom }) { preset in
                            Button { themePresetBinding.wrappedValue = preset } label: {
                                NoopChip(verbatim: preset.label, isOn: themePresetBinding.wrappedValue == preset)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            // Chrome accent colour — the active-state tint only. The DATA colours follow Chart colours.
            G6Block("Accent", caption: Text("Used for the active state only")) {
                HStack(spacing: 14) {
                    ForEach(AccentColor.allCases) { choice in
                        accentSwatch(choice)
                    }
                    Spacer(minLength: 0)
                    if AccentColor.resolve(accentRaw) == .custom {
                        ColorPicker("Custom colour", selection: customAccentBinding, supportsOpacity: false)
                            .labelsHidden()
                            .accessibilityLabel("Custom accent colour")
                    }
                }
            }
            // Default = NOOP's clean metric ramps; Classic = the throwback red→amber→green readiness scale.
            G6MenuRow(title: Text("Chart colours"), caption: Text("Default ramps or the classic red to green"),
                      selection: $chartStyleRaw, valueText: ChartStyle.resolve(chartStyleRaw).label) {
                ForEach(ChartStyle.allCases) { style in Text(style.label).tag(style.rawValue) }
            }
            // Trend chart style (line vs bar). Display-only: the plotted data is identical either way.
            G6MenuRow(title: Text("Trend charts"), selection: $trendChartStyleRaw,
                      valueText: (TrendChartStyle(rawValue: trendChartStyleRaw) ?? .line).label) {
                ForEach(TrendChartStyle.allCases) { style in Text(style.label).tag(style.rawValue) }
            }
            #if os(iOS)
            G6MenuRow(title: Text("App icon"), selection: $useNavyIcon,
                      valueText: useNavyIcon ? String(localized: "Navy") : String(localized: "Default")) {
                Text("Default").tag(false)
                Text("Navy").tag(true)
            }
            .onChangeCompat(of: useNavyIcon) { applyAppIcon($0) }
            #endif
        }

        // Sleep tab stage-CHART shape. Display-only — same stages either way; a night with no timestamped
        // segments falls back to Classic.
        NoopSectionTitle("Sleep chart style", caption: String(localized: "Sleep tab"))
        HStack(spacing: 8) {
            ForEach(SleepChartStyle.allCases) { style in
                Button { sleepChartStyleRaw = style.rawValue } label: {
                    SleepChartStyleTile(style: style, isOn: SleepChartStyle.resolve(sleepChartStyleRaw) == style)
                }
                .buttonStyle(.plain)
            }
        }

        NoopSectionTitle("Motion & surfaces", caption: String(localized: "Easier on the eyes"))
        NoopList {
            // Reduce motion in NOOP: the third, in-app signal beside Low Power Mode and system Reduce Motion.
            G6ToggleRow("Reduce motion in NOOP",
                        caption: Text("Holds gauges and pours still and stops the tilt sensor. Saves battery."),
                        isOn: $quietMotion)
            // Day-cycle background (#698): on by default.
            G6ToggleRow("Day-cycle background", caption: Text("Ground warms slightly after sunset"),
                        isOn: $showDayCycleBackground)
            // Sky behind cards: extends the backdrop behind the whole Today scroll. Needs the day-cycle on.
            G6ToggleRow("Sky behind cards",
                        caption: Text("Lets lowering card transparency show it under every card. Needs the day-cycle background."),
                        isOn: $skyBehindCards)
                .disabled(!showDayCycleBackground)
                .opacity(showDayCycleBackground ? 1 : 0.5)
            // Transparent cards: a quick on/off over the SAME cardOpacityPercent, in lock-step with the slider.
            G6ToggleRow("Transparent cards", caption: Text("Let the background show through every card"),
                        isOn: Binding(
                            get: { cardOpacityPercent < 100 },
                            set: { on in cardOpacityPercent = on ? (cardOpacityPercent >= 100 ? 70 : cardOpacityPercent) : 100 }
                        ))
            // Card transparency: the slider shows TRANSPARENCY (0 = solid); the stored value is OPACITY.
            G6Block("Card transparency", caption: Text(verbatim: "\(100 - cardOpacityPercent) %")) {
                VStack(spacing: 6) {
                    Slider(
                        value: Binding(
                            get: { Double(100 - cardOpacityPercent) },
                            set: { cardOpacityPercent = 100 - Int($0.rounded()) }
                        ),
                        in: 0...100, step: 1
                    )
                    .tint(StrandPalette.textPrimary)
                    .accessibilityLabel("Card transparency")
                    HStack {
                        Text("Solid")
                        Spacer()
                        Text("Glass")
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            G6Block("Custom background", caption: nil) {
                backgroundImageControls
            }
        }

        NoopSectionTitle("Experimental", caption: String(localized: "May change"))
        NoopList {
            // Opt-in liquid Today (default ON in this build). Off falls back to the classic dashboard.
            Toggle(isOn: $liquidTodayEnabled) {
                HStack(spacing: 14) {
                    G6IconTile(icon: "drop-half", size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Liquid Today")
                            .font(StrandFont.book(15, relativeTo: .body))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Glass Charge card that fills with your score. Off returns the classic dashboard.")
                            .font(StrandFont.light(12.5, relativeTo: .caption))
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

    private var appearanceModeBinding: Binding<AppearanceMode> {
        Binding(get: { AppearanceMode(rawValue: appearanceRaw) ?? AppearanceMode.defaultMode },
                set: { appearanceRaw = $0.rawValue })
    }

    private var languageLabel: String {
        let language = AppLanguage.resolve(appLanguageRaw)
        return language == .system ? String(localized: "System default") : language.autonym
    }

    private var clockLabel: String {
        switch ClockFormatPreference.from(stored: clockFormatRaw) {
        case .system: return String(localized: "System default")
        case .twelveHour: return String(localized: "12-hour")
        case .twentyFourHour: return String(localized: "24-hour")
        }
    }

    /// One accent swatch: the colour disc, ringed in ink when it is the active choice.
    private func accentSwatch(_ choice: AccentColor) -> some View {
        let isOn = AccentColor.resolve(accentRaw) == choice
        return Button { accentRaw = choice.rawValue } label: {
            Circle()
                .fill(choice.accent)
                .frame(width: 30, height: 30)
                .padding(3.5)
                .overlay(Circle().strokeBorder(isOn ? StrandPalette.textPrimary : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: choice.label))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: Updates page

    /// Check for updates (a single, user-initiated read of GitHub's public releases API — no background
    /// polling beyond the opt-out daily check, no auto-update) and What's new.
    @ViewBuilder private var updatesPage: some View {
        NoopList {
            G6Row(title: Text("NOOP"), caption: Text("Installed version")) {
                G6Value(value: bundleVersionString, chevron: false)
            }
            Button { showWhatsNew = true } label: {
                G6Row(title: Text("What's new"), caption: Text("The changelog for this version")) {
                    G6Value(value: "", chevron: true)
                }
            }
            .buttonStyle(.plain)
        }
        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Button {
                        // Compare the ACTUAL installed bundle version against GitHub's latest, not the
                        // hand-maintained AppChangelog.currentVersion (#697-adjacent).
                        updateChecker.check(currentVersion: bundleVersionString)
                    } label: {
                        if updateChecker.state == .checking {
                            HStack(spacing: NoopMetrics.space1 + 2) {
                                ProgressView().controlSize(.small)
                                Text("Checking…")
                            }
                        } else {
                            Text("Check for updates")
                        }
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))
                    .disabled(updateChecker.state == .checking)

                    if case .upToDate(let v) = updateChecker.state {
                        Text("You're on the latest (\(v)).")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    } else if case .failed = updateChecker.state {
                        Text("Couldn't check. Try again.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                // Update available: what's new, with a download straight to the release.
                if case .available(let v, let url, let notes) = updateChecker.state {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Version \(v) is available")
                                .font(StrandFont.book(15))
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            NoopButton("Download", kind: .primary) { openURL(url) }
                        }
                        if !notes.isEmpty {
                            ScrollView {
                                Text(notes)
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            #if os(iOS)
                            // #697/#horizontal-swipe parity, see ScreenScaffold.
                            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                            #endif
                            .frame(maxHeight: 150)
                        }
                    }
                }
                G6Footnote("Checks the project's home (GitHub) for the latest version when you tap. Nothing else is sent.")
            }
        }
        // #1659: the automatic half. iOS cannot auto-update a sideloaded build, so noticing and saying so
        // is all that is possible. ON by default (see UpdateAvailability.defaultEnabled); off stops the
        // request entirely.
        NoopList {
            G6ToggleRow("Check automatically",
                        caption: Text("Once a day, NOOP asks GitHub for the latest version number and puts a note in Updates if there's a newer one. Nothing about you is sent, and it never installs anything."),
                        isOn: $autoCheckUpdates)
        }
    }

    // MARK: - Profile

    /// The optional profile photo: the avatar, then choose/change and remove. PhotosUI works on both
    /// supported platforms; the photo stays on the device and is never uploaded.
    private var profilePhotoRow: some View {
        let hasAvatar = profile.hasAvatar
        return HStack(spacing: 14) {
            ProfileAvatarView(imageData: profile.avatarImageData, size: 42, placeholder: .disc)
                .accessibilityLabel(hasAvatar ? "Your profile photo" : "No profile photo set")
            VStack(alignment: .leading, spacing: 3) {
                Text("Photo")
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Stays on \(Platform.deviceNounPhrase), never uploaded")
                    .font(StrandFont.light(12.5, relativeTo: .caption))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                NoopChip(hasAvatar ? "Change" : "Choose")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hasAvatar ? "Change photo" : "Choose photo")
            if hasAvatar {
                Button {
                    profile.clearAvatar()
                } label: {
                    PhIcon("trash", size: 16)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove photo")
                .accessibilityHint("Reverts to the default profile icon")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        // Load the picked photo's bytes, then hand them to the store (which downscales + persists).
        // Clearing the selection afterwards lets the user re-pick the same photo if they want.
        .onChange(of: avatarPickerItem) { newItem in
            guard let newItem else { return }
            Task {
                let data = try? await newItem.loadTransferable(type: Data.self)
                await MainActor.run {
                    if let data { profile.setAvatar(data) }
                    avatarPickerItem = nil
                }
            }
        }
    }

    /// One recent-background preset: a small cropped thumbnail (accent-ringed when active) over its
    /// fill-mode label. Tapping re-applies that image + scaling.
    @ViewBuilder
    private func backgroundRecentThumb(thumb: Image?, mode: BackgroundFillMode, active: Bool,
                                       action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            VStack(spacing: 3) {
                Group {
                    if let thumb { thumb.resizable().scaledToFill() } else { StrandPalette.surfaceInset }
                }
                .frame(width: 64, height: 64)
                .clipShape(shape)
                .overlay(shape.strokeBorder(active ? StrandPalette.textPrimary : NoopVisualStyle.border,
                                            lineWidth: active ? 2 : 1))
                Text(mode.label)
                    .font(StrandFont.caption)
                    .foregroundStyle(active ? StrandPalette.textPrimary : StrandPalette.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }

    /// Custom background image controls (#custom-background): pick from Photos or Browse the files,
    /// choose the fill mode, and (once set) enable / remove. The store downscales + persists a
    /// device-local file — nothing here is uploaded (NOOP is offline), and it is left out of `.noopbak`.
    /// Wrapped in a layout-transparent `Group` so the picker `onChange` + the file importer can hang off
    /// the whole cluster while it still flows inside the appearance VStack.
    @ViewBuilder
    private var backgroundImageControls: some View {
        let hasImage = backgroundStore.hasImage
        Group {
            HStack(spacing: NoopMetrics.space2) {
                PhotosPicker(selection: $backgroundPickerItem, matching: .images) {
                    Text(hasImage ? "Replace from Photos" : "Choose from Photos")
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))

                Button {
                    showBackgroundFileImporter = true
                } label: {
                    Text("Browse files")
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
            }

            if hasImage {
                // Recent presets: tap a thumbnail to re-apply that image + the scaling it was last shown
                // with. The first (accent-ringed) one is the active background.
                if !backgroundStore.recents.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recent")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                        HStack(spacing: 10) {
                            ForEach(backgroundStore.recents.indices, id: \.self) { index in
                                backgroundRecentThumb(
                                    thumb: backgroundStore.thumbnails.indices.contains(index)
                                        ? backgroundStore.thumbnails[index] : nil,
                                    mode: backgroundStore.recents[index].fillMode,
                                    active: index == 0,
                                    action: { backgroundStore.applyRecent(index) })
                            }
                        }
                    }
                }

                Toggle(isOn: $backgroundStore.enabled) {
                    Text("Show custom background")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.noop)

                FormRow(label: "Scaling") {
                    G6MenuValue(title: Text("Background scaling"), selection: Binding(
                        get: { backgroundStore.fillMode },
                        set: { backgroundStore.setFillMode($0) }),
                                valueText: backgroundStore.fillMode.label) {
                        ForEach(BackgroundFillMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                }

                Button {
                    backgroundStore.clearImage()
                } label: {
                    Text("Remove image")
                }
                .buttonStyle(NoopButtonStyle(.tertiary))
                .accessibilityHint("Removes the custom background and restores the day-cycle sky")
            }

            Text("Optional. Use your own photo behind every tab, in place of the day-cycle sky. It stays on \(Platform.deviceNounPhrase) and is never uploaded. Pair it with Transparent cards above to let it show through.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Load the picked photo's bytes, hand them to the store (which downscales + persists), then clear
        // the selection so the same photo can be re-picked. Mirrors the avatar row.
        .onChange(of: backgroundPickerItem) { newItem in
            guard let newItem else { return }
            Task {
                let data = try? await newItem.loadTransferable(type: Data.self)
                await MainActor.run {
                    if let data { backgroundStore.setImage(from: data) }
                    backgroundPickerItem = nil
                }
            }
        }
        // "Browse files" — the system file browser. The picked URL is security-scoped (outside the
        // sandbox), so bracket the one-time read; we copy the bytes into our own file immediately.
        .fileImporter(isPresented: $showBackgroundFileImporter, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { backgroundStore.setImage(from: data) }
        }
    }

    /// One-line state for the "Steps estimate" tap-through row: manual, the auto-fit confidence, or a
    /// not-yet-calibrated prompt — so the row reflects the current calibration without opening the sheet.
    private var stepsCalibrationSummary: String {
        if profile.stepsManualCoefficient > 0 { return String(localized: "Manual") }
        if profile.stepsCalibrationCoefficient > 0 {
            return String(localized: "Auto · \(StepsCalibrationFormat.confidenceLabel(profile.stepsCalibrationConfidence)) confidence")
        }
        return String(localized: "Not calibrated")
    }

    /// Numeric weight/height field: tabular value + small +/- stepper.
    private func measureField(value: Binding<Double>, unit: String,
                              range: ClosedRange<Double>, step: Double,
                              format: String, accessibility: String, showsValue: Bool = true) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            if showsValue {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                    Text(String(format: format, value.wrappedValue))
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: NoopMetrics.formValueColumnWidth, alignment: .center)
                    Text(unit)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize()
                }
                .fixedSize()
            }
            Stepper(accessibility, value: value, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel(accessibility)
        }
        .fixedSize()
    }

    /// Imperial weight entry: shows pounds, steps in 1-lb increments, and writes the kg equivalent back
    /// to the SI-stored profile. Range mirrors the metric 30…250 kg (≈66…551 lb).
    private func poundsField(weightKg: Binding<Double>, showsValue: Bool = true) -> some View {
        let lb = Binding<Double>(
            get: { UnitFormatter.kgToPounds(weightKg.wrappedValue) },
            set: { weightKg.wrappedValue = $0 / UnitFormatter.poundsPerKilogram }
        )
        return HStack(spacing: NoopMetrics.space2) {
            if showsValue {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                    Text(String(format: "%.0f", lb.wrappedValue))
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: NoopMetrics.formValueColumnWidth, alignment: .center)
                    Text("lb")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize()
                }
                .fixedSize()
            }
            Stepper("Weight in pounds", value: lb, in: 66...551, step: 1)
                .labelsHidden()
                .accessibilityLabel("Weight, \(Int(lb.wrappedValue.rounded())) pounds")
        }
        .fixedSize()
    }

    /// Imperial height entry: shows feet′ inches″, steps in whole inches, and writes the cm equivalent
    /// back to the SI-stored profile. Range mirrors the metric 120…230 cm (≈47…91 in).
    private func feetInchesField(heightCm: Binding<Double>, showsValue: Bool = true) -> some View {
        let inches = Binding<Double>(
            get: { UnitFormatter.cmToInches(heightCm.wrappedValue).rounded() },
            set: { heightCm.wrappedValue = $0 * UnitFormatter.centimetersPerInch }
        )
        let parts = UnitFormatter.cmToFeetInches(heightCm.wrappedValue)
        return HStack(spacing: NoopMetrics.space2) {
            if showsValue {
                Text("\(parts.feet)′ \(parts.inches)″")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: NoopMetrics.formWideValueColumnWidth, alignment: .center)
            }
            Stepper("Height in inches", value: inches, in: 47...91, step: 1)
                .labelsHidden()
                .accessibilityLabel("Height, \(parts.feet) feet \(parts.inches) inches")
        }
        .fixedSize()
    }

    /// Metric waist entry: 0 = unset (shows a muted "Not set" rather than a misleading 0 cm). Steps in
    /// 1-cm increments; the first increment from unset lands at a sensible 80 cm so the stepper doesn't
    /// crawl up from the range floor. Mirrors `measureField` but tolerant of the optional empty state.
    private func waistCentimetresField(waistCm: Binding<Double>, showsValue: Bool = true) -> some View {
        let set = waistCm.wrappedValue > 0
        return HStack(spacing: NoopMetrics.space2) {
            if showsValue {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                Text(set ? String(format: "%.0f", waistCm.wrappedValue) : String(localized: "Not set"))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(set ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .frame(minWidth: NoopMetrics.formValueColumnWidth, alignment: .center)
                if set {
                    Text("cm")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize()
                }
            }
            .fixedSize()
            }
            Stepper("Waist in centimetres") {
                waistCm.wrappedValue = min(160, (set ? waistCm.wrappedValue : 79) + 1)
            } onDecrement: {
                // Stepping below the 60-cm floor clears it back to unset (optional).
                let next = waistCm.wrappedValue - 1
                waistCm.wrappedValue = next < 60 ? 0 : next
            }
                .labelsHidden()
                .accessibilityLabel(set ? "Waist, \(Int(waistCm.wrappedValue.rounded())) centimetres" : "Waist not set")
        }
        .fixedSize()
    }

    /// Imperial waist entry: 0 = unset (muted "Not set"); otherwise shows whole inches and stores the cm
    /// equivalent — the same metric/imperial treatment as Height. First increment from unset lands near a
    /// sensible 31″. Range mirrors the metric 60…160 cm (≈24…63 in).
    private func waistInchesField(waistCm: Binding<Double>, showsValue: Bool = true) -> some View {
        let set = waistCm.wrappedValue > 0
        let inches = set ? UnitFormatter.cmToInches(waistCm.wrappedValue).rounded() : 0
        return HStack(spacing: NoopMetrics.space2) {
            if showsValue {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                Text(set ? "\(Int(inches))" : "Not set")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(set ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .frame(minWidth: NoopMetrics.formValueColumnWidth, alignment: .center)
                if set {
                    Text("in")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize()
                }
            }
            .fixedSize()
            }
            Stepper("Waist in inches") {
                let nextIn = (set ? inches : 30) + 1
                waistCm.wrappedValue = min(160, nextIn * UnitFormatter.centimetersPerInch)
            } onDecrement: {
                let nextIn = inches - 1
                // Stepping below the ~24″ floor clears it back to unset (optional).
                waistCm.wrappedValue = nextIn < 24 ? 0 : nextIn * UnitFormatter.centimetersPerInch
            }
                .labelsHidden()
                .accessibilityLabel(set ? "Waist, \(Int(inches)) inches" : "Waist not set")
        }
        .fixedSize()
    }

    /// HR-max override: 0 = auto. Shown as a compact tabular value with a stepper.
    private var hrMaxField: some View {
        HStack(spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                Text(profile.hrMaxOverride > 0 ? "\(profile.hrMaxOverride)" : "Auto")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(profile.hrMaxOverride > 0
                                     ? StrandPalette.textPrimary
                                     : StrandPalette.textTertiary)
                    .frame(width: NoopMetrics.formValueColumnWidth, alignment: .center)
                Text("bpm")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize()
            }
            .fixedSize()
            Stepper("Max heart rate override",
                    value: $profile.hrMaxOverride, in: 0...230, step: 1)
                .labelsHidden()
                .accessibilityLabel("Max heart rate override, \(profile.hrMaxOverride == 0 ? "automatic" : "\(profile.hrMaxOverride) bpm")")
        }
        .fixedSize()
    }

    /// One personalized zone lower bound (bpm), stepped neighbour-aware (see `Profile.stepHRZoneThreshold`)
    /// so the five bounds stay strictly increasing. Mirrors `hrMaxField`'s compact value + stepper layout.
    private func hrZoneThresholdField(index: Int) -> some View {
        let value = profile.hrZoneThresholds.indices.contains(index) ? profile.hrZoneThresholds[index] : 0
        return HStack(spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                Text("\(value)")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: NoopMetrics.formValueColumnWidth, alignment: .center)
                Text("bpm")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize()
            }
            .fixedSize()
            Stepper("",
                    onIncrement: { profile.stepHRZoneThreshold(at: index, up: true) },
                    onDecrement: { profile.stepHRZoneThreshold(at: index, up: false) })
                .labelsHidden()
                .accessibilityLabel("Zone \(index + 1) starts at \(value) beats per minute")
        }
        .fixedSize()
    }

    // MARK: - Units

    /// Independent body and exercise-distance unit choices plus temperature and Effort overrides.
    /// Display-only — nothing stored changes; NOOP keeps everything in SI.
    private var unitsCard: some View {
        SettingsSection(
            icon: "ruler",
            title: "Units",
            blurb: "Choose body measurements and exercise distance separately. Your data is always stored the same way; these settings only change its display."
        ) {
            VStack(spacing: 0) {
                FormRow(label: "Body measurements") {
                    G6MenuValue(title: Text("Body measurement units"), selection: $unitSystemRaw,
                                valueText: unitSystem == .imperial ? String(localized: "Imperial")
                                                                   : String(localized: "Metric")) {
                        Text("Metric").tag(UnitSystem.metric.rawValue)
                        Text("Imperial").tag(UnitSystem.imperial.rawValue)
                    }
                }
                rowDivider
                FormRow(label: "Exercise distance & pace") {
                    G6MenuValue(title: Text("Exercise distance and pace units"), selection: distanceSystemBinding,
                                valueText: distanceUnitSystem == .imperial ? String(localized: "Miles")
                                                                           : String(localized: "Kilometres")) {
                        Text("Kilometres").tag(UnitSystem.metric.rawValue)
                        Text("Miles").tag(UnitSystem.imperial.rawValue)
                    }
                }
                rowDivider
                FormRow(label: "Temperature") {
                    // Three-way: "Follow body" follows body measurements; °C / °F pin it explicitly.
                    G6MenuValue(title: Text("Temperature unit"), selection: $temperatureRaw,
                                valueText: temperatureMenuLabel) {
                        Text("Follow body").tag("")
                        Text(verbatim: "°C").tag(TemperatureUnit.celsius.rawValue)
                        Text(verbatim: "°F").tag(TemperatureUnit.fahrenheit.rawValue)
                    }
                }
                rowDivider
                FormRow(label: "Skin temperature") {
                    // #1846: lead with a temperature ("33.5 °C") or with the move from your own baseline
                    // ("-0.1 Δ°C"). Only a PREFERENCE — a night that measured just one of the two still
                    // shows that one, so the choice can never blank a card.
                    G6MenuValue(title: Text("Skin temperature display"), selection: $skinTempDisplayRaw,
                                valueText: skinTempDisplayRaw == SkinTempDisplay.Kind.deviation.rawValue
                                    ? String(localized: "vs baseline") : String(localized: "Temperature")) {
                        Text("Temperature").tag("")
                        Text("vs baseline").tag(SkinTempDisplay.Kind.deviation.rawValue)
                    }
                }
                rowDivider
                // Effort scale (#268) — show NOOP's native 0–100 Effort or WHOOP's 0–21 Day Strain axis.
                // Display-only; the stored value never changes, so a flip just re-labels every Effort read-out.
                FormRow(label: "Effort scale") {
                    G6MenuValue(title: Text("Effort scale"), selection: $effortScaleRaw,
                                valueText: effortScaleRaw == EffortScale.whoop.rawValue ? "0–21" : "0–100") {
                        Text(verbatim: "0–100").tag(EffortScale.hundred.rawValue)
                        Text(verbatim: "0–21").tag(EffortScale.whoop.rawValue)
                    }
                }

                // #1545: directly under the Effort SCALE row on purpose. It shipped in the experimental
                // block beside the SpO2 and stress-baseline toggles, where the person who asked for it
                // could not find it. The two are different concepts — that row is the display AXIS,
                // this the computation RECIPE — but a user asking "how is my Effort worked out" reaches
                // for the same place for both, and each row's caption separates them.
                // MARK: #1545 Effort scale — Banister exponential TRIMP instead of Edwards zones.
                Divider().overlay(StrandPalette.hairline)

                Toggle(isOn: $banisterEffortEnabled) {
                    Text("Effort: exponential intensity scale")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.noop)
                // Clear of the divider above, like the menu rows (which carry a 44 pt minimum height).
                .padding(.top, 12)
                .padding(.bottom, 4)
                .onChangeCompat(of: banisterEffortEnabled) { _ in
                    // Re-score immediately on the flip. The recipe changes stored Effort for EVERY day in
                    // the window, so without this the user waits up to 30 min for the next analyze loop
                    // while the screen still shows scores from the recipe they just turned off — and the
                    // toggle's own copy promises the history is re-scored. Same pattern as the SpO2
                    // candidate and HRV-window toggles (analyzeRecent → refresh).
                    Task { await model.intelligence.analyzeRecent(); await model.repo.refresh() }
                }
                Text("Scores Effort on an exponential intensity curve (Banister TRIMP) instead of the default heart-rate zones (Edwards). The default earns nothing below half of your heart-rate reserve, so an hour of lifting — where hard sets average out against the rests — can score close to zero. The exponential curve has no floor and weights short, hard efforts far more heavily. Re-scores your history, and both scales reach the same maximum. Off by default.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Appearance (Theme everywhere; alternate app icon iOS-only)

    /// Theme (System / Light / Dark) on every platform, plus the iOS app-icon choice. The Theme picker
    /// writes `AppearanceMode.storageKey`, which both app roots read via `.preferredColorScheme`; because
    /// every palette token is a dynamic `Color(light:dark:)`, the whole UI re-resolves on change.
    /// Day streak (#569): consecutive days with a Charge score, computed on-device from the merged
    /// daily metrics. A day qualifies when its `DailyMetric` has a `recovery` value. The math is the
    /// pure `StreakCalculator` (Swift/Kotlin twin).
    private var streakCard: some View {
        let days = model.repo.days
        let today = AnalyticsEngine.dayString(Int(Date().timeIntervalSince1970),
                                              offsetSec: TimeZone.current.secondsFromGMT())
        let s = StreakCalculator.streaks(dayKeys: days.map { $0.day },
                                         qualified: days.map { $0.recovery != nil },
                                         today: today)
        return NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                NoopCardHeader("Charge streak", icon: "calendar-check")
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    NoopDotNumber("\(s.current)", size: 64)
                        .fixedSize()
                    Text(s.current == 1 ? "day in a row" : "days in a row")
                        .font(StrandFont.light(13, relativeTo: .subheadline))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Text(s.longest == 1 ? "Longest: 1 day" : "Longest: \(s.longest) days")
                    .font(StrandFont.light(13, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textTertiary)
                G6Footnote("A day counts when it has a Charge score. Wear the strap overnight to keep it going.")
            }
        }
    }

    /// Bridges the SwiftUI `ColorPicker` (a `Color`) to the persisted custom-accent hex string.
    private var customAccentBinding: Binding<Color> {
        Binding(
            get: { Color(hex: accentCustomHex) },
            set: { accentCustomHex = $0.noopAccentHex ?? AccentColor.defaultCustomHex }
        )
    }

    /// The Theme PRESET is derived from the four coordinated prefs (no stored value): reads which preset
    /// the live combination matches (or `.custom`), and on pick writes accent + chart + backdrop + opacity.
    private var themePresetBinding: Binding<ThemePreset> {
        Binding(
            get: {
                ThemePreset.matching(
                    accent: AccentColor.resolve(accentRaw),
                    chart: ChartStyle.resolve(chartStyleRaw),
                    backdrop: showDayCycleBackground,
                    cardOpacity: cardOpacityPercent)
            },
            set: { preset in
                guard let r = preset.recipe else { return }   // .custom → no-op
                accentRaw = r.accent.rawValue
                chartStyleRaw = r.chart.rawValue
                showDayCycleBackground = r.backdrop
                cardOpacityPercent = r.cardOpacity
            }
        )
    }

    #if os(iOS)
    /// Apply the alternate-icon choice. Runs on the main actor (UIKit requirement) and tolerates the
    /// no-op cases (already-set, unsupported); on failure it surfaces the error and reverts the toggle
    /// so the control never disagrees with what's actually on the Home Screen.
    private func applyAppIcon(_ useNavy: Bool) {
        Task { @MainActor in
            let target = useNavy ? "AppIcon-Navy" : nil
            // No-op if iOS already shows the requested icon (avoids a needless system prompt).
            guard UIApplication.shared.supportsAlternateIcons,
                  UIApplication.shared.alternateIconName != target else { return }
            do {
                try await UIApplication.shared.setAlternateIconName(target)
            } catch {
                useNavyIcon = !useNavy
                backupAlertTitle = String(localized: "Couldn't change the app icon")
                backupAlertMessage = error.localizedDescription
                showBackupAlert = true
            }
        }
    }
    #endif

    // MARK: - Strap

    private var strapCard: some View {
        SettingsSection(
            icon: "antenna.radiowaves.left.and.right",
            title: "Strap",
            blurb: "NOOP pairs directly with your WHOOP over Bluetooth: no WHOOP app, no cloud."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    // The label is LiveState's fixed English literal (shared with the sidebar footer); look it
                    // up in the catalogue here so the pill follows the app language.
                    G13StatusPill(LocalizedStringKey(strapStatusTitle), tone: strapTone, pulsing: live.connected)
                    if let pct = live.batteryPct {
                        G13StatusPill(live.charging == true
                                      ? "Battery \(Int(pct.rounded()))% · Charging"
                                      : "Battery \(Int(pct.rounded()))%",
                                      tone: batteryTone(pct))
                    }
                    Spacer(minLength: 0)
                }
                Text(strapStatusDetail)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                HStack(spacing: NoopMetrics.space3) {
                    NoopButton("Re-scan", kind: .primary) {
                        model.scan()
                    }

                    NoopButton("Disconnect", kind: .secondary) {
                        model.disconnect()
                    }
                    .disabled(!live.connected && !live.bonded)
                }

                rowDivider
                // MARK: Strap log — a Settings shortcut so people don't have to hunt for it on the Live
                // screen (#507: couldn't find it on Mac; #509: same on iPhone). Same text as the Live card.
                HStack(spacing: 12) {
                    Text("STRAP LOG").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Button("Copy") { PlatformPasteboard.copy(live.exportableLogText()) }
                        .buttonStyle(.plain).font(StrandFont.book(14)).foregroundStyle(StrandPalette.textPrimary)
                    Button("Save…") {
                        Task {
                            let extra = await DebugDataDiagnostics.dynamicLines(repo: model.repo)
                            FileExport.exportText(live.exportableLogText(extraHeaderLines: extra),
                                                  suggestedName: FileExport.timestampedName("noop-strap-log", ext: "txt"))
                        }
                    }
                    .buttonStyle(.plain).font(StrandFont.book(14)).foregroundStyle(StrandPalette.textPrimary)
                }
                Text("Grab this when you report a bug. It tells me what the app saw. (The full live log is also on the Live screen.)")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                // #518: Continuous HRV capture, "Overnight only" and the HRV window picker moved to the
                // "HRV" card under Advanced (see `hrvCard`) — same @AppStorage bindings, same BLE + re-score
                // wiring, just relocated as power-user tuning rather than shown here at all times.

                // MARK: Strap name — rename the WHOOP 4.0's BLE advertising name (Harvard command set).
                if live.connected && selectedWhoopModelRaw == WhoopModel.whoop4.rawValue {
                    rowDivider
                    strapNameControl
                }

            }
        }
    }


    /// Rename the WHOOP 4.0's BLE advertising name. Shows the current name (read back from firmware in
    /// the connect handshake → `LiveState.advertisingName`) and writes a new one via `renameStrap`. The
    /// strap reboots to apply, so the new name lands on the next connect. WHOOP 4.0 only (Harvard).
    @ViewBuilder private var strapNameControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Strap name").strandOverline()
            Text("Current: \(live.advertisingName ?? "—")")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: NoopMetrics.space3) {
                TextField("New strap name", text: $strapNameDraft)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, NoopMetrics.space3)
                    .padding(.vertical, 9)
                    .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    .disableAutocorrection(true)
                    .accessibilityLabel("New strap name")
                NoopButton("Rename", kind: .primary) {
                    model.ble.renameStrap(strapNameDraft)
                }
                .disabled(strapNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let status = live.renameStatus {
                Text(status)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Text("Changes the Bluetooth name your WHOOP 4.0 advertises (what you see when pairing). The strap reboots to apply, so the new name appears the next time it connects. WHOOP 4.0 only.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Shares LiveState.connectionStatus* with the sidebar footer (RootView) so the two never drift (#266).
    private var strapStatusTitle: String { live.connectionStatusLabel }

    private var strapTone: StrandTone {
        if live.connectionStatusIsActive { return .positive }
        if live.connectionStatusIsIdle { return .warning }
        return .critical
    }

    private var strapStatusDetail: String {
        // encryptedBond, not bonded — see LiveState.connectionStatusLabel. Saying "is paired" for a
        // live-HR-only link contradicts both LiveView's pill and the buzz/alarm rows on this same screen,
        // which correctly refuse and explain that they need the full encrypted bond.
        //
        // A live-HR link falls through to the pairing hint when one is set, and otherwise to "Finishing
        // the secure pairing handshake…", which is accurate HERE because this platform still retries the
        // CLIENT_HELLO on every connect. The #1635 suppression is now ported here too, so once it latches
        // nothing is finishing any more and the old fall-through would describe a handshake that is no
        // longer being attempted. The `bonded && connected` arm below is that fix, matching the Android
        // twin (`SettingsLogic.strapStatusLine`).
        if live.encryptedBond && live.connected {
            return String(localized: "Your strap is paired and sending data. Open Live for a real-time heart rate.")
        }
        // An actionable hint outranks the generic arm: the suppression hint names the one action that
        // restores the handshake, which "not fully paired" alone does not.
        if live.connected, let hint = live.pairingHint { return hint }
        // Live HR over the UNBONDED standard profile (#69). True whenever the handshake is suppressed or
        // simply has not landed, and the honest description either way.
        if live.bonded && live.connected {
            return String(localized: "Live heart rate is streaming, but your strap is not fully paired. The encrypted pairing is what carries motion, skin temperature, SpO₂ and respiratory rate — without it, sleep is staged from heart rate alone. Buzz, alarms and history sync need it too.")
        }
        if live.connected { return String(localized: "Connected. Finishing the secure pairing handshake…") }
        if live.bonded { return String(localized: "Previously paired but not currently connected. Re-scan to reconnect.") }
        return String(localized: "No strap connected. Put your WHOOP nearby and tap Re-scan to pair.")
    }

    private func batteryTone(_ pct: Double) -> StrandTone {
        if pct <= 15 { return .critical }
        if pct <= 30 { return .warning }
        return .positive
    }

    // MARK: - Recovery (Charge baseline)

    /// Advanced recovery controls. The Recalibrate button re-anchors the whole Charge (recovery)
    /// baseline from tonight onward — the cure for a baseline poisoned by a bad first week (worn sick,
    /// or an early reading that anchored too high). It writes now (epoch SECONDS) to BOTH the
    /// `noop.hrvBaselineEpoch` and `noop.recoveryBaselineEpoch` settings the recovery engine reads, then
    /// kicks a recompute the same way the sleep-edit path does (analyzeRecent → refresh). History stays.
    #if os(iOS)
    /// NOOP's live notifications — its Live Activities, on the Lock Screen and in the Dynamic Island — one switch
    /// each: the live heart rate, a Lift Log session, a strap sync. These three are every Live Activity the app has.
    /// A switch only decides whether its notification is SHOWN: the heart rate is still measured, recorded and
    /// scored, a session still runs and buzzes, a sync still runs, with any of them off.
    private var liveNotificationsCard: some View {
        SettingsSection(
            icon: "bell.badge",
            title: "Live notifications",
            blurb: "Shown on the Lock Screen and in the Dynamic Island. A switch only hides one: NOOP still measures and records everything."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                liveNotificationSwitch("Live heart rate", isOn: $liveActivityEnabled,
                                       detail: "While the strap is connected.")
                rowDivider
                liveNotificationSwitch("Lift Log session", isOn: $liftLiveActivityEnabled,
                                       detail: "Your set, rest and heart rate, and the Lock Screen light-up on a double-tap.")
                rowDivider
                liveNotificationSwitch("Strap sync", isOn: $syncLiveActivityEnabled,
                                       detail: "Progress while NOOP pulls history from the strap.")
            }
        }
    }

    private func liveNotificationSwitch(_ title: LocalizedStringKey, isOn: Binding<Bool>,
                                        detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Toggle(isOn: isOn) {
                Text(title)
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .toggleStyle(.noop)
            Text(detail)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    #endif

    private var recoveryCard: some View {
        SettingsSection(
            icon: "heart.text.square",
            title: "Recovery",
            blurb: "Your Charge score learns a personal baseline from your heart-rate variability, resting heart rate and more over time. If a bad first week set it off, you can re-learn it from tonight. Your history stays."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                NoopButton("Recalibrate Charge baseline", kind: .secondary) {
                    showRecalibrateConfirm = true
                }

                Text("Restarts the roughly 4-night build-up for Charge and your HRV baseline from tonight. Use it if a bad first week set your baseline off. Your history stays.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Write the recalibration anchor and trigger a recompute. Re-anchors EVERY baseline that feeds
    /// Charge — HRV plus resting HR / respiration / skin temp — by writing now (epoch SECONDS) to both
    /// `noop.hrvBaselineEpoch` and `noop.recoveryBaselineEpoch` via the single cross-platform source of
    /// truth (`Baselines.recalibrateRecoveryBaselines`). No stored day is deleted; only the day the
    /// baselines re-learn from moves. Then re-score + refresh so the change is reflected without a
    /// relaunch (same path as a sleep edit), and Today honestly shows the building/calibrating state.
    private func recalibrateHrvBaseline() {
        Baselines.recalibrateRecoveryBaselines()
        Task {
            await model.intelligence.analyzeRecent()
            await model.repo.refresh()
        }
        backupAlertTitle = String(localized: "Charge baseline recalibrating")
        backupAlertMessage = String(localized: "NOOP will re-learn your baseline from tonight's data onward. Your history is kept, and it takes a few nights to settle.")
        showBackupAlert = true
    }

    // MARK: - Features (opt-in trackers)

    /// Opt-in, manual-first feature toggles (default OFF). Hydration tracking gates the water-log card on
    /// the Today dashboard and its detail screen — nothing is shown or stored until it's enabled.
    private var featuresCard: some View {
        SettingsSection(
            icon: "drop.fill",
            title: "Features",
            blurb: "Optional trackers, off by default. Turn them on to add their cards. Everything stays on \(Platform.deviceNounPhrase)."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2 + 2) {
                Toggle(isOn: $hydrationEnabled) {
                    Text("Hydration tracking")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.noop)
                .accessibilityHint("Adds a water-log card to your dashboard")

                Text("Adds a simple fluid log with a daily goal that adjusts to your effort. Tap to add a sip, cup or bottle and watch a progress ring fill. On \(Platform.deviceNounPhrase) only. Nothing is synced.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                rowDivider

                Toggle(isOn: $autoDetectWorkoutsEnabled) {
                    Text("Auto-detect workouts")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.noop)
                .accessibilityHint("Offers to save a workout when it spots sustained elevated heart rate")

                Text("After a sync, NOOP looks over your recent heart rate for a sustained, raised stretch that looks like exercise and offers to save it. It only ever suggests. Nothing is saved until you tap Save, and you can dismiss any suggestion. Turning this off stops future suggestions but keeps your existing workout history. Deliberately conservative, so the odd workout may be missed. On \(Platform.deviceNounPhrase) only.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                rowDivider

                Toggle(isOn: $journalReminderEnabled) {
                    Text("Journal reminder")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.noop)
                .accessibilityHint("Show a Today card reminding you to log your journal")

                Text("Show a Today card reminding you to log your journal")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                rowDivider

                Toggle(isOn: $workoutKeepScreenOn) {
                    Text("Keep screen on during a workout")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.noop)
                .accessibilityHint("Stops the screen dimming while a workout is recording")

                Text("Holds the screen awake while you're recording a workout, so your live heart rate stays visible without the device dimming. Only applies during a recording. The screen sleeps normally the rest of the time. Leaving it on does use a bit more battery, and means your unlocked screen stays visible for the whole workout, so flip it off if that's a concern.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    #if os(iOS)
    // MARK: - Sync (iOS)

    /// Behaviour while a strap history sync runs. Its own section rather than a row under Features, which holds
    /// optional trackers. `SyncKeepAwake` reads the same key.
    private var syncCard: some View {
        SettingsSection(
            icon: "arrow.triangle.2.circlepath",
            title: "Sync",
            blurb: "How NOOP behaves while it pulls stored history from your strap."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2 + 2) {
                Toggle(isOn: $syncKeepScreenOn) {
                    Text("Keep screen on while syncing")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.noop)
                .accessibilityHint("Stops the screen locking while your strap's history syncs")

                Text("Holds the screen awake while NOOP pulls stored history from your strap, so you can watch a long sync finish without the phone locking. Only applies while a sync is running and NOOP is open. The screen sleeps normally the rest of the time. It uses a bit more battery while the screen stays on.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    #endif

    // MARK: - Backup & restore

    // MARK: - Experimental (WHOOP 5 / MG)

    // #518 (declutter): HRV tuning relocated out of the always-visible Strap card into Advanced. Same
    // @AppStorage bindings and the same BLE + re-score wiring — just tucked away as power-user tuning.
    private var hrvCard: some View {
        SettingsSection(
            icon: "waveform.path.ecg",
            title: "HRV",
            blurb: "Tune how NOOP captures and windows your heart-rate-variability reading."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                // MARK: Continuous HRV capture — keep the dense beat-to-beat (R-R) stream armed 24/7.
                Toggle(isOn: $continuousHrvEnabled) {
                    Text("Continuous HRV capture")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.noop)
                .onChangeCompat(of: continuousHrvEnabled) { on in model.ble.setKeepRealtimeForData(on) }
                Text("Keeps the detailed beat-to-beat heart-rate stream running all day and night, not just while a live screen is open, so NOOP captures much more for overnight HRV, recovery and sleep. Uses more battery: your strap streams heart rate continuously while connected.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                // #927 Overnight only: window-gate the continuous stream to the nightly quiet-hours window.
                if continuousHrvEnabled {
                    Toggle(isOn: $continuousHrvOvernightOnly) {
                        Text("Overnight only")
                            .font(StrandFont.book(15, relativeTo: .body))
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .toggleStyle(.noop)
                    .onChangeCompat(of: continuousHrvOvernightOnly) { _ in
                        model.ble.setKeepRealtimeForData(PuffinExperiment.keepRealtimeForDataEnabled)
                    }
                    Text("Runs the continuous HRV stream only during your quiet hours window (22:00–07:00 by default), roughly halving the battery cost. Daytime Stress readings will be sparser. Note: continuous background HRV capture (including daytime naps) is paused outside this window. For on-demand daytime HRV readings (including naps), use the \"Take an HRV reading\" button on the Live screen.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // HRV window (#141) — Whole night (NOOP's long-standing value) or DEEP sleep only
                // (WHOOP-style, reads lower). Unlike the Effort scale this CHANGES the number, so a switch
                // re-scores + re-baselines (like a sleep edit).
                FormRow(label: "HRV window") {
                    G6MenuValue(title: Text("HRV window"), selection: $hrvWindowRaw,
                                valueText: hrvWindowRaw == HrvWindow.deep.rawValue ? String(localized: "Deep sleep")
                                                                                   : String(localized: "Night")) {
                        // #153: "Night" (not "Whole night") — a single short word so the two-segment control
                        // doesn't truncate once it sizes to the row.
                        Text("Night").tag(HrvWindow.whole.rawValue)
                        Text("Deep sleep").tag(HrvWindow.deep.rawValue)
                    }
                    .onChangeCompat(of: hrvWindowRaw) { _ in
                        // #201/#195: analyzeRecent re-scores the recent ~21 nights' avgHrv under the new
                        // window AND re-folds the HRV baseline in the same pass, so DON'T re-anchor the
                        // baseline epoch (that reset read as "the setting is broken").
                        Task { await model.intelligence.analyzeRecent(); await model.repo.refresh() }
                    }
                }
                Text("Whole night is NOOP's default measure; Deep sleep pools HRV over slow-wave sleep only, reading lower and matching WHOOP. Switching re-scores your recent nights over the new window and takes effect right away once you have a few nights of data.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Entry point used by `body`. The 5/MG probe card only renders for a 5/MG (see `showFiveMGControls`,
    /// #22); the raw-sensor CSV diagnostic is split into its own card so it stays available on every
    /// model — a 4.0 owner still needs the export to share decoded streams. The SpO2 candidate card is
    /// split out the same way (see `spo2CandidateCard`'s comment) — it is NOT WHOOP-5/MG-specific.
    @ViewBuilder private var experimentalCard: some View {
        // Liquid Today moved to the Appearance page's Experimental section, beside the look it changes.
        liveSessionsCard
        // WHOOP 5/MG protocol research now lives in Test Centre. Everyday Settings no longer carries
        // a second copy; the persisted keys and reversible disable actions remain unchanged there.
        if showFiveMGControls || model.repo.activeDeviceIsOura { spo2CandidateCard }
        if model.repo.activeDeviceIsOura { ouraAllDayLiveHRCard }   // item 27
        sleepStagingCard
        rawSensorDiagnosticsCard
    }

    /// Opt-in liquid Today redesign (default ON in this build). Off falls back to the
    /// classic dashboard immediately, no rebuild. Same data either way.
    @AppStorage("noop.liquidTodayEnabled") private var liquidTodayEnabled = true

    /// Live Sessions (beta) — the silent-guardian in-workout coach. Default ON (the entry itself is
    /// BETA-labelled on the Liquid Today); off removes the Start-session control entirely. Same key the
    /// Today entry reads (`LiveSessionPrefs.betaKey`).
    @AppStorage(LiveSessionPrefs.betaKey) private var liveSessionsBeta = true
    private var liveSessionsCard: some View {
        SettingsSection(
            icon: "shield.lefthalf.filled",
            title: "Experimental · Live Sessions",
            blurb: "A one-tap guarded workout: the strap watches your heart rate against a band gated on today's Charge, and only ever buzzes to correct course. Silence means you're on track."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Toggle(isOn: $liveSessionsBeta) {
                    Text("Live Sessions (beta)")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.noop)
                Text("Silence-first strap coaching during workouts.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Sleep staging engine. V2 (the transparent cardiorespiratory recipe) is the DEFAULT after a 44-subject
    /// cross-subject benchmark; model-agnostic — it works on WHOOP 4 and 5 — so it renders on every strap.
    /// Turning the toggle OFF falls back to the older V1 percentile-band stager; either way only future
    /// (and re-derived) nights are affected.
    private var sleepStagingCard: some View {
        SettingsSection(
            icon: "bed.double.fill",
            title: "Sleep staging",
            blurb: "How NOOP splits a night into light / deep / REM. The V2 recipe is the default; turn it off to fall back to the older V1 staging."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Toggle(isOn: $experimentalSleepV2Enabled) {
                    Text("Sleep staging (V2)")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.noop)
                Text("A transparent cardiorespiratory recipe that recovers deep and REM better than the older V1 staging, and is now the default. It only changes how already-detected nights are split into stages (detection and scores are unchanged); turn it off to fall back to V1. Takes effect on the next nights staged.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                rowDivider

                // MARK: Motion-aware wake refinement (#364 follow-up) — default OFF.
                Toggle(isOn: $motionAwareWakeEnabled) {
                    Text("Motion-aware wake refinement")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.noop)
                Text("Reviews each scored wake block for real evidence of getting up (walking cadence, a change in body position) instead of just a heart-rate rise. A wake block with no locomotion and a stable posture — a hot night, a brief turn-over — is folded back into light sleep; a real get-up is left alone. Self-checks how much motion detail your strap actually recorded and stays off on a night that's too sparse to trust (older WHOOP 4.0 firmware, mainly). Off by default; takes effect on the next nights staged.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// SpO2 candidate display (#103/queue-11a) — split out of the WHOOP 5/MG research card
    /// `fiveMGCard` (2026-08-23; #1709 removed that card's call site and #2417 its body): the toggle's
    /// own copy has covered Oura since `89c8533b` ("Blood Oxygen: strap estimate (WHOOP 5/MG, Oura)"),
    /// but it stayed nested inside the WHOOP-5/MG-only card, gated by `showFiveMGControls` — so an
    /// Oura-only install (no WHOOP 5/MG ever connected) could never reach it. `metricSeries` confirmed
    /// zero `spo2_candidate` rows ever written on such an install despite pass-2 scoring running daily,
    /// and a full screenshot sweep of Settings confirmed the section never renders. Same split as
    /// `rawSensorDiagnosticsCard` just below (#22) — this card shows for a 5/MG OR an active Oura
    /// device, not just a 5/MG.
    private var spo2CandidateCard: some View {
        SettingsSection(
            icon: "lungs.fill",
            title: "Experimental · Blood Oxygen",
            blurb: "Surfaces a device-conditional, unverified SpO₂ estimate in the Blood Oxygen tile when no calibrated reading exists."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Toggle(isOn: $spo2CandidateDisplayEnabled) {
                    Text("Blood Oxygen: strap estimate (WHOOP 5/MG, Oura)")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.noop)
                .onChangeCompat(of: spo2CandidateDisplayEnabled) { _ in
                    // Re-score immediately so the candidate is computed and persisted on this
                    // toggle flip — without this the user waits up to 15 min for the next analyze
                    // loop, and the Blood Oxygen tile stays blank in the meantime. Same pattern as
                    // the HRV window toggle above (analyzeRecent → refresh).
                    Task { await model.intelligence.analyzeRecent(); await model.repo.refresh() }
                }
                Text("Your WHOOP 5.0/MG sends a strap-computed SpO₂ percentage (the @82 candidate byte) every second — an 8-night independent validation tracked it at corr +0.99 against the WHOOP app, but two nights on the original test device moved the OPPOSITE direction, so device/firmware variance is unresolved. An Oura ring's own SpO₂ reading runs high on the wire (over 100% on a fifth to a half of samples on a clean night); this instead surfaces the ring's mean with each sample capped at 100% first, which has matched the Oura app's own displayed value on every full night checked against it so far, though only a few nights. Turning this on surfaces whichever applies to your device as \"strap estimate (unverified)\" in the Blood Oxygen tile when no calibrated import exists. It never feeds recovery or illness scoring. WHOOP 4.0 has no @82 stream, so this does nothing there.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Item 27: keep the Oura ring in daytime-HR mode while the screen is off during the DAY. The ring
    /// produces daytime heart rate (and the beats behind windowed rMSSD) only while a client holds that
    /// mode, so the screen-keyed suspend that protects the night suite also empties a pocketed-phone day.
    /// ON stands the hold down only for the learned night band; OFF is today's behaviour. Oura-only.
    private var ouraAllDayLiveHRCard: some View {
        SettingsSection(
            icon: "waveform.path.ecg",
            title: "Experimental · Oura ring all-day heart rate",
            blurb: "Oura ring only. Keeps your ring measuring heart rate through the day, standing it down only for your night. A WHOOP strap is not affected."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Toggle(isOn: $ouraAllDayLiveHREnabled) {
                    Text("Oura ring: all-day heart rate & HRV")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.noop)
                Text("Your Oura ring only measures daytime heart rate while NOOP keeps it in that mode, and NOOP stops asking whenever the screen has been off for five minutes — which protects the ring's own sleep tracking at night, but also leaves a pocketed phone's day blank on the Heart Rate and HRV charts. On, NOOP keeps asking through the day and stops only for your usual night, learned from your sleep history (an hour before your typical bedtime to an hour after your usual wake), so the night is unchanged. Costs ring battery: the ring runs its own optical sensor all day. Until enough nights are learned it behaves as if off. Off by default.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Diagnostics (every model)

    /// Raw-sensor CSV export — a read-only diagnostic over the decoded streams NOOP already stores
    /// (HR, R-R, motion, steps, PPG-HR, SpO₂, skin temp, resp, events). Split out of the 5/MG card so it
    /// stays visible on EVERY model (#22): a WHOOP 4.0 owner still needs this to share decoded data.
    private var rawSensorDiagnosticsCard: some View {
        SettingsSection(
            icon: "doc.text.magnifyingglass",
            title: "Diagnostics",
            blurb: "A read-only export of the decoded sensor streams NOOP already stores. Works on any strap. Nothing is written to your device, and nothing is uploaded."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                // MARK: Export raw sensor data (CSV) — a read-only diagnostic over the decoded streams
                // NOOP already stores (HR, R-R, motion, steps, PPG-HR, SpO₂, skin temp, resp, events).
                Button {
                    exportRawSensorCSV()
                } label: {
                    if rawCsvBusy {
                        HStack(spacing: NoopMetrics.space1 + 2) {
                            ProgressView().controlSize(.small)
                            Text("Exporting…")
                        }
                    } else {
                        Text("Export raw sensor data (CSV)")
                    }
                }
                .buttonStyle(NoopButtonStyle(.secondary))
                .disabled(rawCsvBusy)

                #if os(macOS)
                if let url = lastRawCsvURL {
                    NoopButton("Reveal in Finder", kind: .secondary) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                #endif

                Text("Dumps the last 24 hours of decoded per-sample sensor streams (heart rate, R-R, motion, steps, SpO₂, skin temperature, respiration, events) to a single CSV. All on \(Platform.deviceNounPhrase), nothing uploaded. Share it to help prototype and test sleep, activity and strength algorithms.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Export the last 24h of decoded sensor streams for the connected strap to a CSV, then save (macOS
    /// NSSavePanel) or share (iOS share sheet). This is the only exporter left on this screen: the Puffin
    /// capture export that shared the shape went with the research card in #2417.
    ///
    /// The strap id comes from `repo.deviceId`, NOT `model.deviceId`. The latter is a hardcoded
    /// `let "my-whoop"`; the former is seeded with it and then re-pointed to the registry's active strap
    /// once the store opens (`adoptActiveDeviceId`). This read used the hardcoded one, so after a
    /// remove+re-add — which mints a fresh "whoop-<uuid>" that the Collector writes today's raw under —
    /// the CSV exported the legacy id's streams rather than the strap being worn, silently, in the file
    /// people attach to bug reports. That is #814 on the diagnostic path, and the Android twin of it.
    ///
    /// Read on the MainActor before the Task hop, as `LiveSessionRunner` does, rather than reaching into
    /// the actor-isolated repo from inside the task.
    private func exportRawSensorCSV() {
        rawCsvBusy = true
        let strapId = model.repo.deviceId
        Task {
            let since = Date().timeIntervalSince1970 - 24 * 60 * 60
            guard let store = await model.repo.storeHandle() else {
                await MainActor.run {
                    rawCsvBusy = false
                    backupAlertTitle = String(localized: "Export failed")
                    backupAlertMessage = String(localized: "Couldn't open the local store.")
                    showBackupAlert = true
                }
                return
            }
            do {
                let url = try await store.exportRawCSV(deviceId: strapId, since: since)
                await MainActor.run {
                    rawCsvBusy = false
                    lastRawCsvURL = url
                    #if os(macOS)
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.commaSeparatedText]
                    panel.nameFieldStringValue = url.lastPathComponent
                    panel.canCreateDirectories = true
                    guard panel.runModal() == .OK, let dest = panel.url else { return }
                    let fm = FileManager.default
                    do {
                        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                        try fm.copyItem(at: url, to: dest)
                    } catch {
                        backupAlertTitle = String(localized: "Export failed")
                        backupAlertMessage = error.localizedDescription
                        showBackupAlert = true
                    }
                    #else
                    FileExport.exportFile(at: url)
                    #endif
                }
            } catch {
                await MainActor.run {
                    rawCsvBusy = false
                    backupAlertTitle = String(localized: "Export failed")
                    backupAlertMessage = error.localizedDescription
                    showBackupAlert = true
                }
            }
        }
    }

    private func markOpticalPhase(_ phase: PuffinOpticalExperimentPhase) {
        if model.ble.markWhoop5OpticalPhase(phase) {
            opticalPhaseStatus = String(localized: "Marked: \(phase.displayName)")
        } else {
            opticalPhaseStatus = String(localized: "Marker wasn't saved. Keep frame recording on and try again.")
        }
    }

    #if os(macOS)
    #endif

    private var backupCard: some View {
        SettingsSection(
            icon: "externaldrive.fill",
            title: "Backup & restore",
            blurb: "Move all your NOOP data to another machine. Export saves everything (history, sleeps, workouts, settings) to a single file you can copy across; import replaces \(Platform.deviceNounPhrase)'s data with a backup."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                // Export leads as the one primary action; Import and CSV share the row under it. Two-up
                // leaves room for the Phosphor glyphs on an iPhone, and the label still shrinks to fit
                // rather than wrapping mid-word (the three-up row broke to one character per line, #188).
                VStack(spacing: 10) {
                    Button {
                        runExport()
                    } label: {
                        backupButtonLabel(String(localized: "Export…"), icon: "export")
                    }
                    .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                    .disabled(backupBusy)

                    HStack(spacing: 10) {
                        Button {
                            runImport()
                        } label: {
                            backupButtonLabel(String(localized: "Import…"), icon: "download-simple")
                        }
                        .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                        .disabled(backupBusy)

                        Button {
                            runCsvExport()
                        } label: {
                            backupButtonLabel(String(localized: "Export CSV…"), icon: "table")
                        }
                        .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                        .disabled(backupBusy)
                    }
                }

                if backupBusy {
                    HStack(spacing: NoopMetrics.space2) {
                        ProgressView().controlSize(.small).tint(StrandPalette.textSecondary)
                        Text("Working…")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    PhIcon("info", size: 15)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text("Importing overwrites everything currently on \(Platform.deviceNounPhrase). Your old data is kept in a side file just in case. NOOP needs a relaunch for an import to take effect. Export CSV writes a WHOOP-format zip of your days, sleeps, workouts and journal that re-imports into NOOP on Mac, iPhone, or Android. On-device computed rows are marked APPROXIMATE in its Source column; the full backup stays the lossless restore path.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // #644: .noopbak is a plain ZIP, not an encrypted container — anyone who gets the file
                // can open it in any archive tool. Say so plainly next to the Export button, rather than
                // let people assume the file itself is protected once it leaves the device (e.g. dropped
                // into a cloud-synced folder).
                G13WarnNote("This is a plain, unencrypted archive — anyone who gets the file can open it with any zip tool. Store it somewhere you trust.")

                // Reach the scheduled / folder-based Backup & Sync screen (back up to a chosen folder on
                // demand or about once a day, restore from a snapshot in that folder).
                NavigationLink {
                    BackupSyncView()
                } label: {
                    HStack(spacing: 10) {
                        PhIcon("folder-simple", size: 17)
                        Text("Backup & Sync to a folder…")
                        Spacer(minLength: 0)
                        PhIcon("caret-right", size: 14)
                            .opacity(0.35)
                    }
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Backup and Sync to a folder")
            }
        }
    }

    /// A single-line Backup button label: the Phosphor glyph and the word as one centred unit, shrinking
    /// to fit instead of wrapping (#188).
    private func backupButtonLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            PhIcon(icon, size: 17)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func runExport() {
        backupBusy = true
        Task {
            let result = await DataBackup.runExport(checkpoint: { await model.repo.checkpointForBackup() })
            handleBackup(result)
        }
    }

    private func runImport(allowOversize: Bool = false) {
        backupBusy = true
        Task {
            let result = await DataBackup.runImport(allowOversize: allowOversize)
            handleBackup(result)
        }
    }

    private func runCsvExport() {
        backupBusy = true
        Task {
            let result = await CsvExport.run(repo: model.repo)
            backupBusy = false
            switch result {
            case .cancelled:
                return
            case .exported(let url):
                backupAlertTitle = String(localized: "CSV exported")
                backupAlertMessage = String(localized: "Saved to \(url.lastPathComponent). The zip re-imports into NOOP (Data Sources → WHOOP Export) on any Mac, iPhone, or Android device.")
                showBackupAlert = true
            case .failure(let message):
                backupAlertTitle = String(localized: "Export problem")
                backupAlertMessage = message
                showBackupAlert = true
            }
        }
    }

    @MainActor
    private func handleBackup(_ result: DataBackup.BackupResult) {
        backupBusy = false
        switch result {
        case .cancelled:
            return
        case .exported(let url):
            backupAlertTitle = String(localized: "Backup exported")
            backupAlertMessage = String(localized: "Saved to \(url.lastPathComponent). Copy this file to your other \(Platform.deviceNoun) and use Import there to restore everything.")
            showBackupAlert = true
        case .exportedOversize(let url, let bytes, let limit):
            // #1807: the file is written and worth keeping — say so first, then say what restoring it
            // will ask for. The old behaviour said nothing here and refused at restore, which is the
            // one moment the original is already gone.
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            let cap = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            backupAlertTitle = String(localized: "Backup exported")
            backupAlertMessage = String(localized: "Saved to \(url.lastPathComponent). Your database is \(size), over the \(cap) NOOP restores without asking — the backup is complete and valid, and restoring it will ask you to confirm once.")
            showBackupAlert = true
        case .restoreTooLarge(let name, let limit):
            let cap = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            oversizeRestoreMessage = String(localized: "\(name) is larger than the \(cap) NOOP restores without asking. That limit guards against a malicious archive expanding to fill this \(Platform.deviceNoun) — a backup you exported yourself is not that. Restoring it needs the space the database will take. You'll be asked to choose the file again.")
            showOversizeRestoreConfirm = true
        case .imported:
            backupAlertTitle = String(localized: "Backup imported")
            backupAlertMessage = String(localized: "Your data has been restored. Quit and reopen NOOP for it to take effect.")
            showBackupAlert = true
        case .failure(let message):
            backupAlertTitle = String(localized: "Backup problem")
            backupAlertMessage = message
            showBackupAlert = true
        }
    }

    // MARK: - About

    /// The real marketing version straight from the bundle (CFBundleShortVersionString, set from
    /// project.yml MARKETING_VERSION), so the About pill can never go stale the way a hand-edited
    /// Swift constant can. Mirrors how Android's pill reads BuildConfig.VERSION_NAME. Falls back to
    /// the hand-maintained changelog version only if the Info.plist key is somehow missing.
    private var bundleVersionString: String { UpdateWatch.installedVersion }

    /// The About NOOP page: what NOOP is, the medical disclaimer, the iPhone notes (iOS) and the credits.
    /// The help sheets, Storage, updates and the project link are rows on the hub.
    private var aboutCard: some View {
        SettingsSection(
            icon: "info.circle.fill",
            title: "About",
            blurb: "NOOP: all your data, none of the cloud."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("NOOP")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    NoopTag(verbatim: "v\(bundleVersionString)", size: 12)
                    Spacer()
                }

                Text("A standalone companion for your WHOOP. Everything stays on this device: your history, your live stream, your numbers. Nothing is uploaded. NOOP is an independent, experimental project, not the WHOOP app.")
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                // Medical disclaimer
                NoopInsightRow(text: Text("NOOP is not a medical device. It is for informational and personal-insight purposes only and is not intended to diagnose, treat, cure or prevent any condition. Talk to a clinician for medical advice."),
                               icon: "warning")

                #if os(iOS)
                // iOS reality: honest expectations for a sideloaded iPhone build.
                iphoneExpectations
                #endif

                rowDivider

                VStack(alignment: .leading, spacing: 6) {
                    Text("Built on").strandOverline()
                    attribution(repo: "johnmiddleton12/my-whoop", note: String(localized: "WHOOP 4.0 protocol"))
                    attribution(repo: "b-nnett/goose", note: String(localized: "WHOOP 5.0 protocol"))
                }

                Text("Open-source BLE reverse-engineering work. Thank you.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func attribution(repo: String, note: String) -> some View {
        HStack(spacing: 8) {
            PhIcon("caret-right", size: 10)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(repo)
                .font(StrandFont.mono(12))
                .foregroundStyle(StrandPalette.textPrimary)
            Text("· \(note)")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - iOS reality & diagnostics (iOS-only)

    #if os(iOS)
    /// A tappable row (mirroring "How your scores work") that opens the environment-diagnostics sheet.
    private var iosDiagnosticsRow: some View {
        Button {
            showDiagnostics = true
        } label: {
            G6NavRowLabel(title: Text("Device diagnostics"),
                          caption: Text("Device, iOS build, Data Protection and sideload status, for bug reports."),
                          icon: "device-mobile")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Diagnostics")
    }

    /// Calm, honest "what to expect running NOOP on iPhone" callout — sideloading reality, re-sign
    /// cadence, the unlock-after-reboot (#222) note, background-BLE limits, and beta-iOS caveat. Surfaces
    /// the live sideload-cert expiry when we can read it, with a gentle warning under ~3 days.
    private var iphoneExpectations: some View {
        let diag = IOSDiagnostics.capture()
        let expiry = diag.expiryDaysRemaining()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PhIcon("device-mobile", size: 16)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Using NOOP on iPhone")
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
            }

            iphoneExpectationLine(String(localized: "This is a sideloaded build, installed outside the App Store. It needs re-signing periodically: roughly every 7 days on a free Apple ID, about a year on a paid developer account."))
            iphoneExpectationLine(String(localized: "After your iPhone reboots, unlock it once. Until you do, iOS keeps NOOP's files locked (Data Protection), so new history can't be written or synced."))
            iphoneExpectationLine(String(localized: "Background Bluetooth has OS limits: iOS may pause NOOP when it's not in the foreground, so keep it open while syncing a fresh strap."))
            iphoneExpectationLine(String(localized: "On a beta version of iOS, things can break that work on the release build."))

            if let days = expiry {
                let warning = days <= 3
                HStack(alignment: .top, spacing: 8) {
                    PhIcon(warning ? "warning" : "clock", size: 14)
                        .foregroundStyle(warning ? StrandPalette.statusWarning : StrandPalette.textTertiary)
                    Text(expiryMessage(days))
                        .font(StrandFont.footnote)
                        .foregroundStyle(warning ? StrandPalette.statusWarning : StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(NoopVisualStyle.inset))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(NoopVisualStyle.border, lineWidth: 1))
    }

    private func expiryMessage(_ days: Int) -> String {
        if days < 0 {
            let expired = -days
            return expired == 1
                ? String(localized: "This sideloaded build expired 1 day ago. Re-sign it to keep it running.")
                : String(localized: "This sideloaded build expired \(expired) days ago. Re-sign it to keep it running.")
        }
        return days == 1
            ? String(localized: "This sideloaded build expires in 1 day. Re-sign to keep it running.")
            : String(localized: "This sideloaded build expires in \(days) days. Re-sign to keep it running.")
    }

    private func iphoneExpectationLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(StrandPalette.textTertiary)
                .frame(width: 4, height: 4)
                .padding(.top, 6)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    #endif

    // MARK: - Shared bits

    private var rowDivider: some View {
        Rectangle()
            .fill(NoopVisualStyle.border)
            .frame(height: 1)
            .padding(.vertical, 8)
    }
}

// MARK: - Pages

/// The Settings pages the hub opens. Each is drawn by `SettingsView(page:)`.
enum SettingsPage: String, Hashable, CaseIterable {
    case profile, units, appearance, strap, liveNotifications, streak, features, sync
    case recovery, hrv, experimental, diagnostics, backup
    case updates, about

    var title: LocalizedStringKey {
        switch self {
        case .profile:           return "Profile"
        case .units:             return "Units"
        case .appearance:        return "Appearance"
        case .strap:             return "Strap"
        case .liveNotifications: return "Live notifications"
        case .streak:            return "Streak"
        case .features:          return "Features"
        case .sync:              return "Sync"
        case .recovery:          return "Recovery"
        case .hrv:               return "HRV"
        case .experimental:      return "Experimental"
        case .diagnostics:       return "Diagnostics"
        case .backup:            return "Backup & restore"
        case .updates:           return "Check for updates"
        case .about:             return "About NOOP"
        }
    }
}

/// Registers the page destinations on the hub's stack (the pages push `SettingsPage` values).
private struct SettingsPageDestinations: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.navigationDestination(for: SettingsPage.self) { page in
                SettingsView(page: page)
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
            }
        } else {
            content
        }
    }
}

/// Where a hub row leads.
private enum SettingsHubTarget: Hashable {
    case page(SettingsPage)
    case testCentre, howNoopWorks, scoringGuide, appleWatch, storage, github
}

/// One hub row, as data so the lists and the search share it.
private struct SettingsHubItem: Identifiable {
    let title: String
    let caption: String?
    let icon: String
    let target: SettingsHubTarget
    var trailing: String? = nil
    var id: String { title }
}

/// Whether a `SettingsSection` draws its own title. A page that holds a single section already shows
/// the same title in its header, so it turns this off.
private struct SettingsSectionShowsTitleKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var settingsSectionShowsTitle: Bool {
        get { self[SettingsSectionShowsTitleKey.self] }
        set { self[SettingsSectionShowsTitleKey.self] = newValue }
    }
}

// MARK: - Hub hero

/// The hub's profile hero: avatar and body line with an edit shortcut, the days of history with the
/// baseline state, and three reference figures.
private struct SettingsProfileHero: View {
    let avatar: Data?
    let bodyLine: String
    let daysOfHistory: (count: Int, since: Date)?
    let baselinesSettled: Bool
    let hrvAverage: Double?
    let restingAverage: Double?
    let hrMax: Int

    var body: some View {
        NoopHeroCard(glow: .ink) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    ProfileAvatarView(imageData: avatar, size: 62, placeholder: .disc)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Your profile")
                            .font(StrandFont.light(26, relativeTo: .title))
                            .tracking(-0.52)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(verbatim: bodyLine)
                            .font(StrandFont.light(12.5, relativeTo: .caption))
                            .foregroundStyle(Color.white.opacity(0.62))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    NavigationLink(value: SettingsPage.profile) {
                        PhIcon("pencil-simple", size: 18)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(width: 42, height: 42)
                            .background(Circle().fill(Color.white.opacity(0.07)))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Edit profile"))
                }
                HStack(alignment: .bottom, spacing: 12) {
                    NoopDotNumber(daysOfHistory.map { "\($0.count)" } ?? "0", size: 64)
                        .fixedSize()
                    VStack(alignment: .leading, spacing: 1) {
                        Text("days of history")
                        if let since = daysOfHistory?.since {
                            Text("since \(since.formatted(.dateTime.month(.abbreviated).year()))")
                        }
                    }
                    .font(StrandFont.light(12, relativeTo: .caption))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.bottom, 6)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("Baselines")
                            .font(StrandFont.footnote)
                            .foregroundStyle(Color.white.opacity(0.55))
                        NoopTag(baselinesSettled ? "Solid" : "Building", size: 12)
                    }
                    .padding(.bottom, 4)
                }
                .padding(.top, 30)
                HStack(alignment: .top, spacing: 0) {
                    G6HeroMetric(value: hrvAverage.map { "\(Int($0.rounded()))" } ?? "—", unit: "ms",
                                 label: Text("HRV · 30-day avg"))
                    G6HeroMetric(value: restingAverage.map { "\(Int($0.rounded()))" } ?? "—", unit: "bpm",
                                 label: Text("Resting · 30-day avg"))
                    G6HeroMetric(value: "\(hrMax)", unit: "bpm", label: Text("Max heart rate"))
                }
                .padding(.top, 22)
            }
        }
    }
}

// MARK: - Profile hero

/// The Profile page hero: max heart rate in the dot face and the five zones it shapes, brightening
/// toward Zone 5.
private struct SettingsZonesHero: View {
    let zones: HRZoneSet
    let hrMax: Int
    let isCustom: Bool
    let isManual: Bool

    var body: some View {
        NoopHeroCard(glow: .ink, padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge("Heart-rate zones", icon: "heartbeat")
                    Spacer(minLength: 8)
                    NoopPill(isCustom ? "Custom" : (isManual ? "Manual" : "Auto"), compact: true)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    NoopDotNumber("\(hrMax)", size: 80)
                        .fixedSize()
                    Text("bpm max\nheart rate")
                        .font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineSpacing(2)
                        .padding(.bottom, 8)
                }
                .padding(.top, 28)
                Group {
                    if isCustom {
                        Text("Your own five zone starts shape every zone.")
                    } else {
                        Text("Zones run from 50 % to 100 % of your max heart rate.")
                    }
                }
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(Color.white.opacity(0.84))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                HStack(alignment: .top, spacing: 4) {
                    ForEach(zones.zones, id: \.number) { zone in
                        zoneTile(zone)
                    }
                }
                .padding(.top, 22)
            }
            .padding(.top, 20)
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
    }

    /// Z1…Z5 tiles fill brighter toward the top zone; the top zone is solid ink with black text.
    private func zoneTile(_ zone: HRZone) -> some View {
        let fills: [Double] = [0.08, 0.16, 0.28, 0.46, 1]
        let top = zone.number == 5
        let low = Int(zone.lower.rounded(.up))
        let high = top ? Int(zone.upper.rounded(.down)) : Int(zone.upper.rounded(.up)) - 1
        return VStack(spacing: 8) {
            Text(verbatim: "Z\(zone.number)")
                .font(StrandFont.book(12, relativeTo: .caption))
                .foregroundStyle(top ? NoopVisualStyle.canvas : StrandPalette.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(top ? StrandPalette.textPrimary : Color.white.opacity(fills[max(0, min(zone.number - 1, 4))])))
            Text(verbatim: "\(low)–\(high)")
                .font(StrandFont.light(11, relativeTo: .caption2))
                .foregroundStyle(Color.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Zone \(zone.number), \(low) to \(high) beats per minute"))
    }
}

// MARK: - Appearance hero

/// The Appearance page hero: a small phone showing the Today look in the current accent and card
/// transparency, beside the current theme, preset, Liquid Today and transparency.
private struct AppearancePreviewHero: View {
    let themeLabel: String
    let presetLabel: String
    let accentLabel: String
    let accent: Color
    let liquidToday: Bool
    let transparency: Int
    let charge: Double?
    let sleepMinutes: Double?
    let effort: Double?

    var body: some View {
        NoopHeroCard(glow: .ink, padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge("Live preview", icon: "eye")
                    Spacer(minLength: 8)
                    Text("Updates as you change")
                        .font(StrandFont.footnote)
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                HStack(alignment: .center, spacing: 18) {
                    phone
                    VStack(alignment: .leading, spacing: 14) {
                        current(Text(verbatim: themeLabel), label: Text("Theme"))
                        current(HStack(spacing: 7) {
                            Circle().fill(accent).frame(width: 10, height: 10)
                            Text(verbatim: accentLabel)
                        }, label: Text("\(presetLabel) preset · accent"))
                        current(liquidToday ? Text("On") : Text("Off"), label: Text("Liquid Today"))
                        current(Text(verbatim: "\(transparency) %"), label: Text("Card transparency"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 18)
            }
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .padding(.bottom, 22)
        }
    }

    private func current<V: View>(_ value: V, label: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            value
                .font(StrandFont.book(16, relativeTo: .body))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            label
                .font(StrandFont.light(10.5))
                .foregroundStyle(Color.white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// The miniature Today: the Charge card with the accent marker on its tick scale, then two small
    /// cards, all at the chosen card transparency.
    private var phone: some View {
        let cardOpacity = Double(100 - transparency) / 100
        return VStack(alignment: .leading, spacing: 6) {
            Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(StrandFont.light(7))
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.horizontal, 12)
                .padding(.top, 14)
            VStack(spacing: 10) {
                HStack(spacing: 4) {
                    PhIcon("lightning", size: 7)
                        .frame(width: 12, height: 12)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                    Text("Charge")
                    Spacer(minLength: 0)
                }
                .font(StrandFont.light(7))
                .foregroundStyle(StrandPalette.textSecondary)
                NoopDotNumber(charge.map { "\(Int($0.rounded()))" } ?? "--", unit: charge == nil ? nil : "%",
                              size: 40, unitSize: 16)
                ZStack(alignment: .leading) {
                    NoopTickScale(height: 12, tickSpacing: 3)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(accent)
                            .frame(width: 1.5, height: 18)
                            .shadow(color: accent, radius: 3)
                            .offset(x: geo.size.width * min(max((charge ?? 0) / 100, 0), 1), y: -3)
                    }
                    .frame(height: 12)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06 * cardOpacity + 0.02)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .padding(.horizontal, 10)
            HStack(spacing: 6) {
                miniCard(Text("Sleep"), value: sleepMinutes.map { "\(Int($0) / 60)h \(Int($0) % 60)m" } ?? "—",
                         opacity: cardOpacity)
                miniCard(Text("Effort"), value: effort.map { "\(Int($0.rounded()))" } ?? "—", opacity: cardOpacity)
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 0)
        }
        .frame(width: 164, height: 262, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .accessibilityHidden(true)
    }

    private func miniCard(_ title: Text, value: String, opacity: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            title.font(StrandFont.light(6.5)).foregroundStyle(StrandPalette.textTertiary)
            Text(verbatim: value).font(StrandFont.light(13)).foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: 12, surfaceOpacity: max(opacity, 0.15)))
    }
}

/// One Sleep chart style choice: a small drawing of the chart shape over its name.
private struct SleepChartStyleTile: View {
    let style: SleepChartStyle
    let isOn: Bool

    /// Stage levels across the night (0 = awake at the top, 3 = deep at the bottom) for the drawings.
    private static let levels: [CGFloat] = [0, 1.2, 2, 1.2, 0.6, 1.2, 0]

    var body: some View {
        VStack(spacing: 8) {
            Canvas { ctx, size in draw(in: &ctx, size: size) }
                .frame(height: 34)
            Text(verbatim: style.label)
                .font(StrandFont.book(11.5, relativeTo: .caption))
                .foregroundStyle(isOn ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(isOn ? NoopVisualStyle.raised : NoopVisualStyle.inset))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(isOn ? StrandPalette.textPrimary.opacity(0.7) : NoopVisualStyle.border, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: style.label))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let levels = Self.levels
        let step = size.width / CGFloat(levels.count)
        let y: (CGFloat) -> CGFloat = { 4 + $0 / 2 * (size.height - 10) }
        let ink = StrandPalette.textPrimary
        switch style {
        case .classic, .filled:
            var line = Path()
            for (i, l) in levels.enumerated() {
                let x0 = CGFloat(i) * step, x1 = x0 + step
                if i == 0 { line.move(to: CGPoint(x: x0, y: y(l))) } else { line.addLine(to: CGPoint(x: x0, y: y(l))) }
                line.addLine(to: CGPoint(x: x1, y: y(l)))
            }
            if style == .filled {
                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                ctx.fill(fill, with: .color(ink.opacity(isOn ? 0.18 : 0.12)))
            }
            ctx.stroke(line, with: .color(ink.opacity(isOn ? 1 : 0.7)), lineWidth: 1.2)
        case .garminFilled:
            for (i, l) in levels.enumerated() {
                let rect = CGRect(x: CGFloat(i) * step + 0.5, y: y(l), width: step - 1, height: size.height - y(l))
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(ink.opacity(isOn ? 0.8 : 0.55)))
            }
        case .ribbon:
            for (i, l) in levels.enumerated() {
                let rect = CGRect(x: CGFloat(i) * step + 1, y: y(l) - 2.5, width: step - 2, height: 5)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(ink.opacity(isOn ? 0.8 : 0.55)))
            }
        }
    }
}

// MARK: - Advanced disclosure (S3)

/// The persisted defaults for the Settings "Advanced" disclosure. Pulled out so the one fact that must
/// never regress, that a fresh install lands COLLAPSED, is a single testable constant. The key matches
/// the Android `SettingsDisclosurePrefs.KEY` suffix so a backup/restore round-trip carries the choice.
enum SettingsDisclosureDefaults {
    static let advancedOpenKey = "settingsAdvancedOpen"
    static let advancedOpenDefault = false
}

// MARK: - Section card

/// A settings section on a v2 page: its title (unless the page header already says it), an explanatory
/// line, then the controls in a neutral card. `icon` is kept for the call sites; the v2 page header and
/// hub row carry the icon now.
private struct SettingsSection<Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let blurb: LocalizedStringKey
    @ViewBuilder var content: () -> Content
    @Environment(\.settingsSectionShowsTitle) private var showsTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsTitle {
                NoopSectionTitle(title, topPadding: 18)
            }
            Text(blurb)
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
            NoopCard {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - iOS diagnostics sheet

#if os(iOS)
/// A read-only environment dump for bug reports: device, iOS+build, Data Protection (#222),
/// background refresh, low-power, sideload + cert expiry — with a one-tap Copy.
private struct DiagnosticsSheet: View {
    let onClose: () -> Void

    /// Captured once at presentation; a snapshot, not a live monitor.
    private let lines: [String] = IOSDiagnostics.capture().summaryLines()
    @State private var copied = false

    var body: some View {
        G13SheetScaffold(header: NoopSheetHeader("Diagnostics", cancelTitle: "Close",
                                                 doneTitle: lines.isEmpty ? nil : (copied ? "Copied!" : "Copy"),
                                                 onCancel: onClose, onDone: copy)) {
            G13SheetTitle(title: Text("Attach this to a bug report."))
            if lines.isEmpty {
                NoopCard {
                    Text("No iOS diagnostics available.")
                        .font(StrandFont.light(14, relativeTo: .subheadline))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                NoopList {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        DiagnosticsLineRow(line: line)
                    }
                }
            }
        }
        .noopSheetPresentation(largeFirst: false)
    }

    private func copy() {
        // UIPasteboard via the shared cross-platform wrapper.
        PlatformPasteboard.copy(lines.joined(separator: "\n"))
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copied = false
        }
    }
}

/// One environment line as a list row: the label before the first ": " on the left, the raw value in the
/// mono face on the right. A line without a label shows whole, in mono.
private struct DiagnosticsLineRow: View {
    let line: String

    var body: some View {
        let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            if parts.count == 2, !parts[0].isEmpty {
                // The labels are short; the values are what may need a second line.
                Text(verbatim: parts[0])
                    .font(StrandFont.book(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize()
                Spacer(minLength: 8)
                Text(verbatim: parts[1])
                    .font(StrandFont.mono(12.5))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: line)
                    .font(StrandFont.mono(12.5))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
/// DEBUG-only: the diagnostics sheet presented over an empty screen, so `--demo-screen diagnostics-sheet`
/// can screenshot it. Same file as the private sheet so it can reach it. Stripped from Release.
struct DiagnosticsSheetDemoScreen: View {
    @State private var shown = true
    var body: some View {
        Color.clear.sheet(isPresented: $shown) { DiagnosticsSheet(onClose: {}) }
    }
}
#endif
#endif

// MARK: - Steps estimate calibration

/// Small shared formatters for the steps-estimate calibration UI — kept apart from the sheet so the
/// Profile-card summary row and the sheet agree on the confidence wording. Mirrors the Android
/// `StepsCalibrationFormat` object.
enum StepsCalibrationFormat {
    /// A 0–1 confidence as Low / Medium / High — the honest read-out the sheet and the summary row share.
    /// Thirds: < 0.34 Low, < 0.67 Medium, else High. A manual coefficient is confidence 1.0 → "High".
    static func confidenceLabel(_ confidence: Double) -> String {
        switch confidence {
        case ..<0.34: return String(localized: "Low")
        case ..<0.67: return String(localized: "Medium")
        default:      return String(localized: "High")
        }
    }
}

/// One recent day's estimated-vs-phone steps comparison row, for the sheet's accuracy table.
private struct StepsComparisonRow: Identifiable {
    let day: String          // yyyy-MM-dd
    let estimated: Int
    let actual: Int
    var id: String { day }
    /// Signed error of the estimate against the phone count, as a percentage (estimate − actual) / actual.
    var errorPct: Double { actual > 0 ? Double(estimated - actual) / Double(actual) * 100 : 0 }
}

/// WHOOP 4.0 steps-ESTIMATE calibration — honest explainer + current fit + a recent estimated-vs-phone
/// table + a manual coefficient override with a live preview. Presented as a sheet from Settings →
/// Profile → "Steps estimate". Reads the SAME data the engine fits against (the computed `steps_est`
/// series and the phone's `steps`), never recomputing the headline. Mirrors Android `StepsCalibrationScreen`.
// Internal (not file-private) so the Today Steps tile can present the SAME calibration sheet directly
// when it's showing an ESTIMATE for a WHOOP 4.0 user — one shared entry point, no duplicated screen (H6).
struct StepsCalibrationSheet: View {
    let repo: Repository
    let onClose: () -> Void
    @EnvironmentObject var profile: ProfileStore

    /// Recent days that have BOTH an estimate and a real phone step count, newest first — the accuracy table.
    @State private var comparison: [StepsComparisonRow] = []
    /// A representative recent motion volume (median of recent days' motion), used so the manual-coefficient
    /// preview reflects a TYPICAL day. nil until loaded / no recent estimated day with a known motion.
    @State private var sampleMotion: Double?

    /// The draft manual coefficient the slider edits, committed to ProfileStore on release. 0 = auto-fit.
    @State private var draftManual: Double = 0
    @State private var didLoad = false

    /// The strap has banked no motion, and we have looked.
    ///
    /// Named once because two places depend on it and they must stay exactly complementary: the
    /// no-motion banner appears, and the calibration countdown does NOT. Written as two separate
    /// expressions they drifted immediately — the guard's first draft tested `sampleMotion == nil`
    /// alone, which is also true during the load, so the countdown vanished in a window where the
    /// banner had not appeared yet and the card explained nothing at all.
    private var strapHasNoMotion: Bool { didLoad && sampleMotion == nil }

    /// #107: the sheet's guidance depends on the strap family. A WHOOP 4.0 streams motion automatically, so
    /// "let it sync" is right; a 5/MG only streams motion once the experimental deep-data unlock is on, so
    /// the 4.0 advice is futile there and the empty state must say so instead.
    @AppStorage("selectedWhoopModel") private var selectedWhoopModelRaw = WhoopModel.whoop4.rawValue
    @AppStorage(PuffinExperiment.deepDataKey) private var deepDataEnabled = false
    private var is5MG: Bool { selectedWhoopModelRaw == WhoopModel.whoop5mg.rawValue }

    /// The coefficient the slider's max anchors to — generous headroom over whatever the auto-fit found so
    /// a manual nudge in either direction is reachable. Floor keeps the slider usable before any fit.
    private var sliderMax: Double {
        max(profile.stepsCalibrationCoefficient, profile.stepsManualCoefficient, 50) * 2
    }

    var body: some View {
        G13SheetScaffold(header: NoopSheetHeader("Steps estimate", cancelTitle: "Close", doneTitle: nil,
                                                 onCancel: onClose),
                         macSize: CGSize(width: 560, height: 680)) {
            G13SheetTitle("Calibrate your steps",
                          subtitle: Text(is5MG ? "WHOOP 5.0 / MG · motion → steps" : "WHOOP 4.0 · motion → steps"))
            currentFitHero
            if strapHasNoMotion { noMotionNote }
            explainerCard
            comparisonSection
            manualAdjustSection
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #endif
        .task { await loadIfNeeded() }
    }

    // MARK: Cards

    /// The honest "it's an estimate, not a step counter" framing — reused verbatim from the engine doc.
    private var explainerCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                NoopCardHeader("How this works", icon: "footprints") { EmptyView() }
                    .padding(.bottom, -2)
                Text(is5MG
                     ? String(localized: "NOOP estimates your steps from your WHOOP's stored motion, calibrated to your phone's step count. It's an estimate, not a hardware step counter; normal WHOOP 5/MG history sync supplies the motion data.")
                     : String(localized: "NOOP estimates your steps from your WHOOP's motion, calibrated to your phone's step count. It's an estimate, not a step counter. A WHOOP 4.0 doesn't transmit steps."))
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("On the days your phone also counted steps, NOOP learns how much your motion maps to steps, then applies that to the strap-only days. The more matching days it has, the more it trusts the estimate.")
                    .font(StrandFont.light(12.5, relativeTo: .caption))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Shown when the strap has banked NO motion yet (sampleMotion is nil) — the real reason a fresh
    /// WHOOP 4.0 shows zero steps (#37 bringiton321). Steps are built from the strap's synced motion
    /// history, so without a backfill there is nothing to estimate from — calibration can't help yet.
    ///
    /// #107: family-aware. A 4.0 streams motion automatically → "let it sync" is right. A 5/MG only streams
    /// motion once the experimental deep-data unlock is ON — so on a 5/MG the honest advice is "turn that on
    /// and reconnect", not "wait for a sync" (which never comes). Imports don't supply strap motion either.
    private var noMotionNote: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    PhIcon("bluetooth-slash", size: 16)
                        .foregroundStyle(StrandPalette.statusWarning)
                    Text("No motion synced yet")
                        .font(StrandFont.book(14, relativeTo: .subheadline))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text(noMotionLead)
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(noMotionAction)
                    .font(StrandFont.light(12.5, relativeTo: .caption))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The "why it's empty" line — a 5/MG needs the deep-data unlock before it streams motion at all.
    private var noMotionLead: String {
        if is5MG {
            return String(localized: "We're not seeing motion from your WHOOP 5.0 / MG yet. Keep NOOP connected and let strap history finish syncing; the experimental R22 flags are not required. Account or Apple Health imports do not contain the raw strap motion this estimate needs.")
        }
        return String(localized: "We're not seeing any motion from your strap yet. Steps are estimated from your WHOOP's banked motion history, so your strap needs to sync that history before NOOP has anything to count.")
    }

    /// The "what to do" line — 5/MG points at the deep-data toggle (unless it's already on, then just sync).
    private var noMotionAction: String {
        if is5MG && !deepDataEnabled {
            return String(localized: "Open NOOP near the strap and let WHOOP 5/MG history finish syncing. The step estimate and calibration fill in once enough stored motion has arrived; the legacy R22 experiment is not required.")
        }
        if is5MG {
            return String(localized: "Deep data is on — open NOOP near your strap and let it sync its motion history (a full first-run sync can take a while). Once a day or two of motion lands, your step estimate and the calibration below fill in.")
        }
        return String(localized: "Open NOOP near your strap and let it catch up (a full history sync can take a while on first run). Once a day or two of motion lands, your step estimate and the calibration below will start to fill in.")
    }

    /// The current calibration read-out as the sheet's ink hero: coefficient, sample days, and a
    /// Low/Medium/High confidence — or, if nothing's fit yet and no manual value is set, an honest "what we
    /// still need" prompt.
    private var currentFitHero: some View {
        let calibrated = profile.stepsCalibrationCoefficient > 0 || profile.stepsManualCoefficient > 0
        return NoopHeroCard(glow: .ink, padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge("Current calibration", icon: "footprints")
                    Spacer(minLength: 8)
                    if calibrated {
                        NoopPill(profile.stepsManualCoefficient > 0 ? "Manual" : "Auto", compact: true)
                    }
                }
                if calibrated { calibratedReadout } else { uncalibratedReadout }
            }
        }
    }

    @ViewBuilder private var calibratedReadout: some View {
        let coeff = profile.stepsManualCoefficient > 0
            ? profile.stepsManualCoefficient : profile.stepsCalibrationCoefficient
        HStack(alignment: .bottom, spacing: 12) {
            NoopDotNumber(String(format: "%.1f", coeff), size: 64)
                .fixedSize()
            Text("steps per motion unit")
                .font(StrandFont.light(12, relativeTo: .caption))
                .foregroundStyle(Color.white.opacity(0.62))
                .padding(.bottom, 6)
        }
        .padding(.top, 26)
        VStack(spacing: 8) {
            if profile.stepsManualCoefficient > 0 {
                statLine(String(localized: "Source"), String(localized: "Manual (you set this by hand)"))
            } else {
                statLine(String(localized: "Fitted from"),
                         profile.stepsCalibrationSampleDays == 1
                             ? String(localized: "1 day your phone also counted")
                             : String(localized: "\(profile.stepsCalibrationSampleDays) days your phone also counted"))
                statLine(String(localized: "Confidence"), "\(StepsCalibrationFormat.confidenceLabel(profile.stepsCalibrationConfidence)) · \(Int((profile.stepsCalibrationConfidence * 100).rounded()))%")
            }
        }
        .padding(.top, 18)
    }

    @ViewBuilder private var uncalibratedReadout: some View {
        Text("Not calibrated yet")
            .font(StrandFont.light(24, relativeTo: .title2))
            .tracking(-0.48)
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.top, 24)
        // Only ask for phone-step days when phone-step days are what is actually missing.
        //
        // A step estimate is `motion * coefficient` (`StepsEstimateEngine.estimate`) and a
        // calibration point is the ratio `steps / motion`, so BOTH halves are required. With no
        // banked strap motion neither the estimate nor the fit can move however many days the
        // phone counts. The countdown below then names the half the user already has and hides
        // the half they do not — a field report asked whether entering Apple Health steps by
        // hand would start the calibration, which is exactly the conclusion it invites.
        //
        // The no-motion card under this hero already explains the real blocker, so the honest move
        // is to stop competing with it rather than to add more copy.
        if !strapHasNoMotion {
            // #589: a concrete countdown instead of a vague "a few days". Headline comes straight
            // from the engine's needsMoreDays state so the wording matches the Today steps tile.
            // #693: drive `have` off `profile.stepsCalibrationSampleDays` — the value the engine
            // persists for the not-yet-calibrated case (IntelligenceEngine.swift sets it to the
            // usable-day `have`, the SAME source the Today tile reads). `usableMatchedDays` can't be
            // used here: `loadIfNeeded` early-returns before computing it when coeff == 0 (no fit
            // yet), so it would always read 0 and the card was stuck on "Need 3 more days".
            Text(StepsEstimateEngine.CalibrationStatus
                .needsMoreDays(have: profile.stepsCalibrationSampleDays,
                               need: StepsEstimateEngine.minCalibrationDays)
                .headline)
                .font(StrandFont.book(15, relativeTo: .body))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Text("These are the days where your phone also counted steps, so NOOP can learn how your motion maps to steps. Or set the coefficient manually below.")
                .font(StrandFont.light(13, relativeTo: .subheadline))
                .foregroundStyle(Color.white.opacity(0.62))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    /// The accuracy table: recent days that have BOTH an estimate and a phone count, side by side, so the
    /// user can SEE how close the estimate runs. Empty until enough both-have days exist.
    @ViewBuilder private var comparisonSection: some View {
        NoopSectionTitle("Estimated vs your phone")
        if comparison.isEmpty {
            NoopCard {
                Text("No days yet where both NOOP and your phone counted steps. Once your phone logs a few days alongside the strap, they'll appear here so you can see how close the estimate is.")
                    .font(StrandFont.light(13, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            NoopList {
                comparisonHeaderRow
                ForEach(comparison) { row in comparisonRow(row) }
            }
            G6Footnote("These days are excluded from the estimate (your phone's real count is shown instead). They're here only so you can judge the estimate's accuracy.")
                .padding(.horizontal, 4)
        }
    }

    private var comparisonHeaderRow: some View {
        HStack {
            Text("Day").frame(maxWidth: .infinity, alignment: .leading)
            Text("Est.").frame(width: 64, alignment: .trailing)
            Text("Phone").frame(width: 64, alignment: .trailing)
            Text(verbatim: "Δ").frame(width: 52, alignment: .trailing)
        }
        .font(StrandFont.light(12, relativeTo: .caption))
        .foregroundStyle(StrandPalette.textTertiary)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private func comparisonRow(_ row: StepsComparisonRow) -> some View {
        HStack {
            Text(Self.shortDay(row.day))
                .font(StrandFont.book(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.grouped(row.estimated))
                .font(StrandFont.value(14))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 64, alignment: .trailing)
            Text(Self.grouped(row.actual))
                .font(StrandFont.value(14))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 64, alignment: .trailing)
            // Within 15 % reads as plain ink; a wider miss keeps the caution amber so it still stands out.
            Text(String(format: "%+.0f%%", row.errorPct))
                .font(StrandFont.value(14))
                .foregroundStyle(abs(row.errorPct) <= 15
                                 ? StrandPalette.textSecondary : StrandPalette.statusWarning)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Self.shortDay(row.day)): estimated \(row.estimated) steps, phone \(row.actual) steps, \(Int(row.errorPct.rounded())) percent difference")
    }

    /// Manual override: a slider bound to a draft, committed on release, with a live preview of what a
    /// typical recent day would estimate at the chosen coefficient. 0 returns to auto-fit.
    @ViewBuilder private var manualAdjustSection: some View {
        NoopSectionTitle("Adjust manually")
        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Override the automatic fit with your own steps-per-motion value. Useful if your phone has no step history to learn from, or the estimate runs consistently high or low. Set it back to auto by dragging to the far left.")
                    .font(StrandFont.light(13, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(draftManual > 0 ? String(format: "%.1f", draftManual) : String(localized: "Auto"))
                        .font(StrandFont.value(28, weight: 300))
                        .tracking(-0.56)
                        .foregroundStyle(draftManual > 0 ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                    Text(draftManual > 0 ? "steps / motion unit" : "fit from your phone")
                        .font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                }

                Slider(value: $draftManual, in: 0...sliderMax, step: 0.5) {
                    Text("Manual steps coefficient")
                } minimumValueLabel: {
                    Text("Auto").font(StrandFont.light(12, relativeTo: .caption)).foregroundStyle(StrandPalette.textTertiary)
                } maximumValueLabel: {
                    Text("High").font(StrandFont.light(12, relativeTo: .caption)).foregroundStyle(StrandPalette.textTertiary)
                } onEditingChanged: { editing in
                    // Commit on release — snap a tiny drag back to 0 (auto) so "auto" is reachable.
                    if !editing { profile.stepsManualCoefficient = draftManual < 0.5 ? 0 : draftManual }
                }
                .tint(StrandPalette.textPrimary)
                .accessibilityValue(draftManual > 0
                                    ? "\(String(format: "%.1f", draftManual)) steps per motion unit"
                                    : "Automatic")

                // Live preview: a typical recent day re-estimated at the draft coefficient.
                if let motion = sampleMotion {
                    let effective = draftManual > 0 ? draftManual : profile.stepsCalibrationCoefficient
                    if effective > 0 {
                        let preview = Int((motion * effective).rounded())
                        statLine(String(localized: "A typical recent day"),
                                 draftManual > 0
                                     ? String(localized: "≈ \(Self.grouped(preview)) steps at this setting")
                                     : String(localized: "≈ \(Self.grouped(preview)) steps (auto)"))
                    }
                }
                if draftManual > 0 {
                    Text("Takes effect on the next analytics pass (after the next sync).")
                        .font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    /// A small "label … value" line shared by the fit hero and the preview.
    private func statLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(StrandFont.light(13, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: 12)
            Text(value)
                .font(StrandFont.book(13, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Data

    /// Build the comparison table + a typical-day motion, once. The engine stores `steps_est` ONLY for
    /// strap-only days (a phone-covered day uses the phone's real count), so an estimate and a phone count
    /// never co-exist in storage. To still SHOW "how close the estimate is", we reconstruct what the
    /// estimate WOULD have been on recent phone-covered days: read each day's motion volume the same way
    /// the engine does (gravity over [localMidnight, +24h)) and run the public `StepsEstimateEngine` with
    /// the live calibration. This reuses the engine, never invents a number, and needs no extra storage.
    private func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        draftManual = profile.stepsManualCoefficient

        // Effective calibration in force right now: a manual override wins, else the persisted auto-fit.
        let coeff = profile.stepsManualCoefficient > 0
            ? profile.stepsManualCoefficient : profile.stepsCalibrationCoefficient

        // Phone reference steps from Apple Health daily rows (steps > 0 only), newest first.
        let appleRows = await repo.appleDailyRows()
        let phoneDays = appleRows
            .compactMap { row -> (day: String, steps: Int)? in
                guard let s = row.steps, s > 0 else { return nil }
                return (row.day, s)
            }
            .sorted { $0.day > $1.day }

        // Reconstruct the estimate for the most recent phone-covered days, motion-by-motion.
        guard coeff > 0 else { return }
        let cal = StepsEstimateEngine.Calibration(coefficient: coeff,
                                                  sampleDays: profile.stepsCalibrationSampleDays,
                                                  confidence: profile.stepsCalibrationConfidence,
                                                  manual: profile.stepsManualCoefficient > 0)
        let dayParser = DateFormatter(); dayParser.locale = Locale(identifier: "en_US_POSIX"); dayParser.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        var rows: [StepsComparisonRow] = []
        var motions: [Double] = []
        for entry in phoneDays.prefix(10) {           // scan a few extra to fill 7 after motion gaps
            guard let dayDate = dayParser.date(from: entry.day) else { continue }
            let mid = Int(calendar.startOfDay(for: dayDate).timeIntervalSince1970)
            // #1643: the UNION, not `repo.deviceId` alone — a re-added strap leaves motion under both the
            // active id and the canonical one, and reading either by itself makes this screen disagree
            // with the estimator it is supposed to be reconstructing.
            let grav = await repo.gravitySamplesUnion(from: mid, to: mid + 86_400 - 1)
            let motion = StepsEstimateEngine.dayMotionIntensity(grav)
            guard motion > 0, let est = StepsEstimateEngine.estimate(motion: motion, calibration: cal) else { continue }
            motions.append(motion)
            rows.append(StepsComparisonRow(day: entry.day, estimated: est, actual: entry.steps))
            if rows.count >= 7 { break }
        }
        comparison = rows
        // #693: the "Need N more days…" countdown is now driven by `profile.stepsCalibrationSampleDays`
        // (the engine-persisted usable-day count, read directly in the card) — NOT a local match count
        // computed here. This scan reaches here ONLY when coeff > 0 (already calibrated), so a local count
        // would never reflect the not-yet-calibrated state the countdown describes. The rows still feed the
        // accuracy table (`comparison`) above.

        // Typical recent day's motion for the live preview = median of the motions we just measured.
        if !motions.isEmpty {
            let s = motions.sorted()
            sampleMotion = s[s.count / 2]
        }
    }

    // MARK: Formatting

    // Built once: these run per table row on every render.
    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; return f
    }()
    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()

    private static func grouped(_ n: Int) -> String {
        groupedFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    /// "yyyy-MM-dd" → "EEE d MMM" for the table's day column.
    private static func shortDay(_ key: String) -> String {
        guard let d = dayKeyParser.date(from: key) else { return key }
        return shortDayFormatter.string(from: d)
    }
}

// MARK: - Two-column form row

/// Label on the left, control on the right — the two-column form feel.
private struct FormRow<Control: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space4) {
            Text(label)
                .font(StrandFont.book(15, relativeTo: .body))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            control()
                .layoutPriority(1)
        }
        .frame(minHeight: 44)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Settings") {
    let model = AppModel()
    model.live.bonded = true
    model.live.connected = true
    model.live.batteryPct = 64
    return SettingsView()
        .environmentObject(model)
        .environmentObject(model.live)
        .environmentObject(model.profile)
        // iPhone-width (402pt) so the narrow Backup row stays in the preview's blast radius —
        // at 720 the three-up button row had slack and the truncation regression slipped through. (#188)
        .frame(width: 402, height: 900)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}
#endif

// MARK: - Custom accent colour bridge

private extension Color {
    /// sRGB hex (`#RRGGBB`) for persisting a `ColorPicker` selection into `AccentColor.customHexKey`.
    /// Falls back to nil if the colour can't resolve to sRGB (the caller then keeps the default).
    var noopAccentHex: String? {
        #if os(iOS)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        #elseif os(macOS)
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = ns.redComponent, g = ns.greenComponent, b = ns.blueComponent
        #endif
        return String(format: "#%02X%02X%02X",
                      Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}
