import SwiftUI
import StrandDesign

/// Automations — turn the strap's physical inputs (double-tap, wrist on/off) and live biometrics
/// into actions (Shortcuts, and Mac-only screen lock) and haptic coaching. All on-device.
struct AutomationsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var behavior: BehaviorStore
    // PERF: this screen does NOT observe `LiveState`. Its only live-dependent pixel is the "Strap
    // bonded / not connected" pill inside the double-tap card, which is now the `BondStatePill` leaf
    // that owns its own `@EnvironmentObject live`. Observing `live` at this level would re-render the
    // whole 8-9 card automations column on every ~1 Hz strap tick (bond state changes only rarely);
    // scoping it means a tick re-renders just the one pill.
    /// Deep-link into the experimental Rhythm visualization (it self-gates on its own consent).
    @EnvironmentObject var router: NavRouter

    /// v5 cycle-awareness opt-in (default OFF — the most sensitive health category, manual-first).
    @AppStorage(AppModel.cycleAwarenessKey) private var cycleAwareness = false
    /// #hide-cycle: the user's "not for me" opt-out (never age-based). Master visibility control lives here
    /// so it stays reachable to un-hide even after the offer is gone from Today + Health.
    @AppStorage(AppModel.cycleAwarenessHiddenKey) private var cycleHidden = false

    /// Whether the cycle-awareness opt-in is offered for this profile (#801). Delegates to the shared
    /// ``ProfileStore/cycleAwarenessApplies`` gate (mirrors HealthView's opt-in gate) so a male profile
    /// can't enable the feature here when it can't see the Health card either.
    private var cycleOptInApplies: Bool { model.profile.cycleAwarenessApplies }
    /// v5 Rhythm experimental gate (the screen still shows its own consent clickwrap when opened).
    @AppStorage(RhythmConsent.enabledKey) private var rhythmEnabled = false
    /// Inactivity reminder (#419) — UI-local store, persisted in UserDefaults. The buzz itself fires
    /// from the BLE offload path (BLEManager.maybeBuzzInactivity → the shipped SedentaryDetector); this
    /// screen only edits the prefs the engine reads.
    @StateObject private var inactivity = InactivityPrefs()
    #if os(iOS)
    /// Wrist-alerts master gate (PR #572). On iOS the NotificationSettingsView (and its store) are
    /// excluded by project.yml, so `notif.masterEnabled` — the key SedentaryDetector + the wrist-buzz
    /// posting read — has no UI to flip and is stuck at its default OFF. Bind the SAME raw key here so
    /// iPhone users can actually turn wrist alerts on. Default OFF, matching the store's default.
    @AppStorage("notif.masterEnabled") private var wristAlertsMaster = false
    #endif

    // #haptics (#1115): per-event toggles for NOOP's IN-SESSION strap buzzes. Default ON (opt-out) — these
    // are feedback to a feature you started, so a fresh install buzzes as before and a user turns off any
    // cue. Ambient cues (inactivity / stress / coaching) keep their own opt-in cards; double-tap is gated by
    // its action picker. Same keys the buzz sites read via HapticPrefs (which also defaults an unset key on).
    @AppStorage(HapticPrefs.breathing) private var breathingHaptic = true
    @AppStorage(HapticPrefs.intervals) private var intervalsHaptic = true
    @AppStorage(HapticPrefs.liveSession) private var liveSessionHaptic = true
    @AppStorage(HapticPrefs.workout) private var workoutHaptic = true

    var body: some View {
        // PERF: the cards are direct children of the scaffold column, so the LazyVStack path (byte-identical
        // layout) genuinely builds the off-screen cards on demand instead of constructing all of them + their
        // toggle subtrees up-front.
        ScreenScaffold(title: nil, lazy: true) {
            NoopScreenHeader("Automations")
                .padding(.bottom, 6)
            AutomationsHero(rulesOn: activeRules.filter { $0 }.count, rulesTotal: activeRules.count,
                            cuesOn: [breathingHaptic, intervalsHaptic, liveSessionHaptic, workoutHaptic].filter { $0 }.count,
                            doubleTap: behavior.doubleTapAction == .none ? nil : behavior.doubleTapAction.label,
                            coaching: behavior.zoneCoaching || behavior.stressCheckIn)
            NoopSectionTitle("On your wrist", caption: String(localized: "Buzz, tap and wear"))
            #if os(iOS)
            wristAlertsCard
            #endif
            hapticsCard
            doubleTapCard
            wearCard
            coachingCard
            // #766: the strap's silent wake-alarm card used to sit here, which let users conflate it with
            // the wind-down reminder. It's moved to the dedicated Alarms screen (SmartAlarmView) so every
            // wake/wind-down control lives in one place. Automations is just inputs-to-actions now.
            NoopSectionTitle("Nudges", caption: String(localized: "Reminders and alerts"))
            inactivityCard
            illnessCard
            healthInsightsCard
            batteryCard
            strainTargetCard
            NoopInsightRow(text: Text("Every rule runs on \(Platform.deviceNounPhrase) and the strap. Nothing is sent anywhere."))
                .padding(.horizontal, 4)
                .padding(.top, 10)
        }
        // The screen draws its own v2 header.
        .noopHidesSystemNavBar()
    }

    /// Whether each automation is switched on, for the hero's count.
    private var activeRules: [Bool] {
        var rules: [Bool] = []
        #if os(iOS)
        rules.append(wristAlertsMaster)
        #endif
        rules += [breathingHaptic || intervalsHaptic || liveSessionHaptic || workoutHaptic,
                  behavior.doubleTapAction != .none, wearActive,
                  behavior.zoneCoaching || behavior.stressCheckIn, inactivity.enabled, behavior.illnessWatch,
                  cycleAwareness || rhythmEnabled, behavior.batteryAlerts, behavior.strainTargetNudge]
        return rules
    }

    // MARK: - Wrist alerts master (iOS only — PR #572)

    #if os(iOS)
    /// The master switch for wrist-buzz notifications. On macOS this lives in its own Notifications
    /// screen; that screen is excluded from the iOS target, so without this the gate is unreachable on
    /// iPhone and every wrist alert (inactivity, app notifications) stays silently off. Binds the same
    /// `notif.masterEnabled` key the SedentaryDetector and the notification posting read.
    private var wristAlertsCard: some View {
        Section2(icon: "bell.badge.fill", title: String(localized: "Wrist alerts"),
                 blurb: String(localized: "Let NOOP tap your wrist for the things you turn on below, so you can leave your phone and still feel what matters."),
                 active: wristAlertsMaster, master: $wristAlertsMaster) {
            NoteRow(text: String(localized: "The master switch for every wrist buzz (inactivity, stress, alerts). Off keeps the strap quiet no matter what else is on."))
        }
    }
    #endif

    // MARK: - Haptics (#1115)

    /// Per-event opt-in toggles for NOOP's in-session strap buzzes (all default OFF, existing installs
    /// migrated on). Parity with the Android Automations "Haptics" section. Ambient cues and the
    /// Android-only call/notification buzzes are not shown here (the latter can't exist on Apple).
    private var hapticsCard: some View {
        Section2(icon: "waveform.path", title: String(localized: "Haptics"),
                 blurb: String(localized: "Choose which in-session cues buzz your wrist during a breathing session, timer, or workout."),
                 active: breathingHaptic || intervalsHaptic || liveSessionHaptic || workoutHaptic,
                 trailing: String(localized: "\([breathingHaptic, intervalsHaptic, liveSessionHaptic, workoutHaptic].filter { $0 }.count) of 4")) {
            VStack(spacing: 0) {
                ToggleRow(label: String(localized: "Breathing pacer"),
                          help: String(localized: "Buzz each inhale and exhale during a breathing or resonance session."),
                          isOn: $breathingHaptic)
                rowDivider
                ToggleRow(label: String(localized: "Interval timer"),
                          help: String(localized: "Buzz on each interval change."),
                          isOn: $intervalsHaptic)
                rowDivider
                ToggleRow(label: String(localized: "Live Session cues"),
                          help: String(localized: "Coaching buzzes during a live workout session."),
                          isOn: $liveSessionHaptic)
                rowDivider
                ToggleRow(label: String(localized: "Workout start & end"),
                          help: String(localized: "A buzz confirms a workout starting and saving."),
                          isOn: $workoutHaptic)
            }
        }
    }

    // MARK: - Double tap

    private var doubleTapCard: some View {
        Section2(icon: "hand.tap.fill", title: String(localized: "Double-tap"),
                 blurb: String(localized: "Double-tap the strap to trigger an action on \(Platform.deviceNounPhrase). (The strap exposes a single double-tap gesture.)"),
                 active: behavior.doubleTapAction != .none) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("When I double-tap").font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Picker("", selection: $behavior.doubleTapAction) {
                        ForEach(doubleTapOptions) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .tint(StrandPalette.textSecondary)
                }
                .modifier(SubRowInsets())
                if behavior.doubleTapAction == .runShortcut {
                    shortcutField(String(localized: "Shortcut name"), text: $behavior.doubleTapShortcut)
                        .modifier(SubRowInsets())
                }
                rowDivider
                HStack {
                    Button {
                        model.runMacAction(behavior.doubleTapAction, shortcut: behavior.doubleTapShortcut)
                    } label: { NoopChip("Test action", icon: "play") }
                    .buttonStyle(.plain)
                    .disabled(behavior.doubleTapAction == .none)
                    .opacity(behavior.doubleTapAction == .none ? 0.45 : 1)
                    Spacer()
                    // Live-observing leaf: re-renders on its own when the strap's bond state flips, so a
                    // ~1 Hz strap tick doesn't re-render the whole automations column (scroll-stutter
                    // isolation). Renders byte-for-byte the previous inline pill.
                    BondStatePill()
                }
                .modifier(SubRowInsets())
                if !model.moments.isEmpty {
                    rowDivider
                    momentsView
                        .modifier(SubRowInsets())
                }
            }
        }
    }

    private var momentsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent moments").font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Button("Clear") {
                    model.moments.removeAll()
                    UserDefaults.standard.removeObject(forKey: "moments")
                }
                .buttonStyle(.plain).font(StrandFont.light(14)).foregroundStyle(StrandPalette.textSecondary)
            }
            ForEach(Array(model.moments.suffix(5).reversed().enumerated()), id: \.offset) { _, d in
                Text(Self.momentFormatter.string(from: d))
                    .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
    private static let momentFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        // Keep the "EEE d MMM ·" layout but honor the device's 12-/24-hour clock (#337): the "j"
        // template resolves to a 12-hour pattern (contains "a") only where the user prefers it.
        let uses24h = !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: AppLanguage.activeLocale) ?? "H").contains("a")
        f.dateFormat = "EEE d MMM · " + (uses24h ? "HH:mm" : "h:mm a")
        return f
    }()

    // MARK: - Wear & presence

    private var wearCard: some View {
        Section2(icon: "figure.walk.motion", title: String(localized: "Wear & presence"),
                 blurb: wearBlurb,
                 active: wearActive) {
            VStack(spacing: 0) {
                #if os(macOS)
                ToggleRow(label: String(localized: "Lock the Mac when I take the strap off"),
                          help: String(localized: "Fires the moment the strap leaves your wrist."),
                          isOn: $behavior.autoLockOnWristOff)
                rowDivider
                #endif
                shortcutFieldRow(String(localized: "Run a Shortcut when taken off"),
                                 help: String(localized: "Presence automation: set a Focus, pause media, set away…"),
                                 text: $behavior.wristOffShortcut)
                rowDivider
                shortcutFieldRow(String(localized: "Run a Shortcut when put back on"),
                                 help: String(localized: "Reverse the above when you return."),
                                 text: $behavior.wristOnShortcut)
            }
        }
    }

    // MARK: - Coaching

    private var coachingCard: some View {
        Section2(icon: "bolt.heart.fill", title: String(localized: "Haptic coaching"),
                 blurb: String(localized: "Train by feel. The strap buzzes so you don't have to watch a screen."),
                 active: behavior.zoneCoaching || behavior.stressCheckIn) {
            VStack(spacing: 0) {
                ToggleRow(label: String(localized: "HR-zone coaching"),
                          help: String(localized: "Buzz when you hit your top zone (ease off) and again when you recover. Uses your max HR from Settings."),
                          isOn: $behavior.zoneCoaching)
                rowDivider
                // v5 L3 closed-loop check-in (master + sub toggles). Default OFF, manual-first. The keys
                // mirror BiofeedbackPrefs, which the central detector (AppModel.evaluateStress) reads.
                ToggleRow(label: String(localized: "Stress check-ins (haptic)"),
                          help: String(localized: "When a fresh, non-exercise HRV dip is detected while you're still, NOOP offers a one-minute guided breath: a single confirming buzz and a dismissible card. Never an alarm, never a diagnosis."),
                          isOn: $behavior.stressCheckIn)
                if behavior.stressCheckIn {
                    rowDivider
                    ToggleRow(label: String(localized: "Auto-nudge"),
                              help: String(localized: "Let the check-in fire on its own. Off keeps it manual: you start a breath from Breathe yourself."),
                              isOn: $behavior.stressAutoNudge)
                    rowDivider
                    ToggleRow(label: String(localized: "Respect quiet hours"),
                              help: String(localized: "Suppress auto-nudges overnight (10pm-7am)."),
                              isOn: $behavior.stressQuietHours)
                    rowDivider
                    ToggleRow(label: String(localized: "Use my resonance pace"),
                              help: String(localized: "Breathe at the pace your last \u{201C}find my pace\u{201D} sweep locked in, if you have one. Otherwise a calm 5.5 breaths/min."),
                              isOn: $behavior.stressUseResonancePace)
                }
            }
        }
    }

    // MARK: - Inactivity reminder (#419)

    private var inactivityCard: some View {
        Section2(icon: "timer", title: String(localized: "Inactivity reminder"),
                 blurb: String(localized: "A gentle wrist buzz when you've been sitting too long, a nudge to get up and move. Inferred from the strap's motion on each history sync, so it lags real time by a sync or two."),
                 active: inactivity.enabled, master: $inactivity.enabled) {
            VStack(spacing: 0) {
                NoteRow(text: String(localized: "Buzzes after you've been sitting past your threshold."))
                if inactivity.enabled {
                    if !notifMasterOn {
                        NoteRow(text: String(localized: "Notifications are off, so this can't buzz yet. Turn on the master switch in Notifications to let it through."),
                                warning: true)
                    }
                    rowDivider
                    stepperRow(label: String(localized: "Sitting for"), help: String(localized: "Minutes seated before the first nudge."),
                               value: $inactivity.thresholdMinutes, suffix: String(localized: "min"), range: 15...120, step: 15)
                    rowDivider
                    stepperRow(label: String(localized: "Re-nudge every"), help: String(localized: "If you're still seated, buzz again this often."),
                               value: $inactivity.reNudgeMinutes, suffix: String(localized: "min"), range: 15...120, step: 15)
                    rowDivider
                    stepperRow(label: String(localized: "Buzz strength"), help: String(localized: "How strong the buzz is."),
                               value: $inactivity.buzzLoops, suffix: "×", range: 1...4, step: 1)
                    rowDivider
                    ToggleRow(label: String(localized: "Only during active hours"),
                              help: String(localized: "Only nudge during your active hours."),
                              isOn: $inactivity.activeHoursEnabled)
                    if inactivity.activeHoursEnabled {
                        rowDivider
                        HStack(spacing: 12) {
                            Text("From").font(StrandFont.book(15)).foregroundStyle(StrandPalette.textPrimary)
                            DatePicker("", selection: activeStartBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden().datePickerStyle(.compact)
                                .accessibilityLabel("Active hours start")
                            Text("to").font(StrandFont.light(15)).foregroundStyle(StrandPalette.textSecondary)
                            DatePicker("", selection: activeEndBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden().datePickerStyle(.compact)
                                .accessibilityLabel("Active hours end")
                            Spacer(minLength: 0)
                        }
                        .modifier(SubRowInsets())
                    }
                }
            }
        }
    }

    /// The reused global notification master (notif.masterEnabled, default OFF) — drives the inert-feature
    /// warning so enabling the reminder while master is off isn't silently a no-op.
    private var notifMasterOn: Bool {
        UserDefaults.standard.object(forKey: "notif.masterEnabled") as? Bool ?? false
    }
    private var activeStartBinding: Binding<Date> {
        Binding(get: { Self.date(fromMinutes: inactivity.activeStartMinutes) },
                set: { inactivity.activeStartMinutes = Self.minutes(from: $0) })
    }
    private var activeEndBinding: Binding<Date> {
        Binding(get: { Self.date(fromMinutes: inactivity.activeEndMinutes) },
                set: { inactivity.activeEndMinutes = Self.minutes(from: $0) })
    }

    /// A label/help row with a native −[value]+ stepper, clamped to `range` and moved by `step`.
    private func stepperRow(label: String, help: String, value: Binding<Int>,
                            suffix: String, range: ClosedRange<Int>, step: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(StrandFont.book(15, relativeTo: .body)).foregroundStyle(StrandPalette.textPrimary)
                Text(help).font(StrandFont.light(12.5, relativeTo: .caption)).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text("\(value.wrappedValue) \(suffix)")
                .font(StrandFont.light(15, relativeTo: .body)).foregroundStyle(StrandPalette.textSecondary)
            Stepper("", value: value, in: range, step: step).labelsHidden()
                .accessibilityLabel(label)
        }
        .modifier(SubRowInsets())
    }

    // MARK: - Illness early-warning

    private var illnessCard: some View {
        Section2(icon: "waveform.path.ecg", title: String(localized: "Illness early-warning"),
                 blurb: String(localized: "Watches your resting HR, HRV, skin temperature and respiration against your own 28-day baseline. On-device and approximate: informational only, not a diagnosis."),
                 active: behavior.illnessWatch, master: $behavior.illnessWatch) {
            NoteRow(text: String(localized: "Needs at least 14 days of history. When two or more signals drift together you get a banner on the dashboard and a notification, at most once a day."))
        }
        .onChangeCompat(of: behavior.illnessWatch) { _ in
            model.reevaluateIllness()
            if behavior.illnessWatch { IllnessNotifier.requestAuthorization() }
        }
    }

    // MARK: - Health insights (v5: cycle awareness opt-in · experimental Rhythm)

    private var healthInsightsCard: some View {
        Section2(icon: "thermometer.medium", title: String(localized: "Health insights"),
                 blurb: String(localized: "Optional, on-device reads from your nightly signals. Each is off by default: for awareness only, never a diagnosis."),
                 active: cycleAwareness || rhythmEnabled) {
            VStack(spacing: 0) {
                // #801: cycle awareness reads the MENSTRUAL temperature shift, so the toggle is only
                // offered to profiles it applies to (gated the same way as the Health opt-in card,
                // not shown for male profiles). Keeps the two surfaces consistent: a profile that can't
                // see the Health card can't enable the feature from here either.
                if cycleOptInApplies {
                    // #hide-cycle: the master visibility control — a USER opt-out, never age-based. Turning
                    // it off hides the cycle-awareness offer on Today + Health AND stops active tracking;
                    // turning it back on re-offers it. Reversible, so it is never a one-way door.
                    ToggleRow(label: String(localized: "Show cycle awareness"),
                              help: String(localized: "Shows the cycle-awareness card on Today and in Health. Turn off to hide it entirely — a private choice, never based on your age. You can turn it back on here any time."),
                              isOn: Binding(get: { !cycleHidden },
                                            set: { show in
                                                cycleHidden = !show
                                                if !show {
                                                    cycleAwareness = false
                                                    model.cycleAwarenessEnabled = false
                                                    Task { await model.refreshV5Signals() }
                                                }
                                            }))
                    rowDivider
                    if !cycleHidden {
                        ToggleRow(label: String(localized: "Cycle awareness"),
                                  help: String(localized: "Reads a coarse menstrual-cycle phase from your nightly skin temperature, entirely on \(Platform.deviceNounPhrase). Awareness only: not contraception, not a fertility predictor, not a medical service. The card appears in Health."),
                                  isOn: $cycleAwareness)
                            .onChangeCompat(of: cycleAwareness) { on in
                                model.cycleAwarenessEnabled = on
                                Task { await model.refreshV5Signals() }
                            }
                        rowDivider
                    }
                }
                ToggleRow(label: String(localized: "Rhythm visualization (experimental)"),
                          help: String(localized: "An experimental picture of your beat-to-beat heart timing. Not an ECG and not a diagnosis. You'll read and accept an experimental note before it shows anything."),
                          isOn: $rhythmEnabled)
                if rhythmEnabled {
                    rowDivider
                    HStack {
                        Text("Open Rhythm").font(StrandFont.book(15)).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Button {
                            router.openRhythm()
                        } label: { NoopChip("Open", icon: "pulse") }
                        .buttonStyle(.plain)
                    }
                    .modifier(SubRowInsets())
                }
            }
        }
    }

    // MARK: - Strap battery alerts

    private var batteryCard: some View {
        Section2(icon: "battery.25", title: String(localized: "Battery alerts"),
                 blurb: String(localized: "Get a notification when the strap battery runs low (15%) so you can top it up before tonight, and when it finishes charging."),
                 active: behavior.batteryAlerts, master: $behavior.batteryAlerts) {
            VStack(spacing: 0) {
                NoteRow(text: String(localized: "A reminder to recharge before bed when the strap drops to 15%, and a heads-up when it reaches 100%, each at most once per charge cycle."))
                if behavior.batteryAlerts {
                    rowDivider
                    ToggleRow(label: String(localized: "Predictive runtime warning"),
                              help: String(localized: "An early \"recharge tonight\" heads-up when the strap has about a day of estimated runtime left, at most once per discharge cycle. Turn off to keep only the 15% warning."),
                              isOn: $behavior.batteryPredictiveAlerts)
                }
            }
        }
        .onChangeCompat(of: behavior.batteryAlerts) { on in
            if on { BatteryNotifier.requestAuthorization() }
        }
    }

    // MARK: - Strain target nudge (#593)

    private var strainTargetCard: some View {
        Section2(icon: "flame", title: String(localized: "Strain target"),
                 blurb: String(localized: "A once-a-day nudge when your Effort reaches the low end of today's optimal strain range, worked out from your recovery."),
                 active: behavior.strainTargetNudge, master: $behavior.strainTargetNudge) {
            NoteRow(text: String(localized: "Posts after your strap syncs and NOOP scores the day — not the exact second you cross it. At most once per day."))
        }
        .onChangeCompat(of: behavior.strainTargetNudge) { on in
            if on {
                StrainTargetNotifier.requestAuthorization()
                // The repo.$days sink only fires on data changes, so if today's target is
                // already reached, evaluate now rather than waiting for the next refresh
                // (the reevaluateIllness idiom).
                model.evaluateStrainTarget()
            }
        }
    }

    // MARK: - Helpers

    /// Double-tap actions offered in the picker. The "Lock the Mac" action can't work on iPhone
    /// (a third-party app can't lock iOS), so it's dropped there.
    private var doubleTapOptions: [MacActionKind] {
        #if os(iOS)
        MacActionKind.allCases.filter { $0 != .lockScreen }
        #else
        MacActionKind.allCases
        #endif
    }

    /// Wear & presence blurb. macOS mentions the auto-lock affordance (and the Apple-Watch unlock
    /// caveat); iOS, where that toggle is hidden, describes the Shortcut-driven presence reactions.
    /// Wear & presence is "active" when any of its reactions are configured: a wrist-on/off Shortcut,
    /// or (macOS) the auto-lock toggle. Presentation-only — drives the card's accent state.
    private var wearActive: Bool {
        let shortcuts = !behavior.wristOffShortcut.isEmpty || !behavior.wristOnShortcut.isEmpty
        #if os(macOS)
        return shortcuts || behavior.autoLockOnWristOff
        #else
        return shortcuts
        #endif
    }

    private var wearBlurb: String {
        #if os(macOS)
        String(localized: "React when the strap comes off or goes on. Note: macOS reserves true auto-UNLOCK for Apple Watch, so this can lock, not unlock.")
        #else
        String(localized: "React when the strap comes off or goes on. Run a Shortcut to set a Focus, pause media, mark yourself away.")
        #endif
    }

    // `date(fromMinutes:)` / `minutes(from:)` stay: the inactivity active-hours pickers above use them.
    // (The strap-alarm time binding moved to SmartAlarmView with the rest of the alarm UI, #766.)
    private static func date(fromMinutes m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
    private static func minutes(from d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func shortcutField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(StrandFont.light(14, relativeTo: .subheadline))
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
            .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
            .frame(maxWidth: 320)
    }

    private func shortcutFieldRow(_ label: String, help: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(StrandFont.book(15, relativeTo: .body)).foregroundStyle(StrandPalette.textPrimary)
                Text(help).font(StrandFont.light(12.5, relativeTo: .caption)).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            shortcutField(String(localized: "Shortcut name"), text: text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SubRowInsets())
    }

    private var rowDivider: some View {
        Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
    }
}

// MARK: - Live-observing leaf (scroll-stutter isolation)

/// The strap bond-status pill in the double-tap card ("Strap bonded" / "Strap not connected"). It owns
/// its OWN `@EnvironmentObject live` so a ~1 Hz strap publish re-renders only this pill, not the whole
/// automations column (the parent `AutomationsView` no longer observes `LiveState`). Renders
/// byte-for-byte the previous inline `StatePill(live.bonded ? …)`.
private struct BondStatePill: View {
    @EnvironmentObject private var live: LiveState
    var body: some View {
        StatePill(live.bonded ? "Strap bonded" : "Strap not connected",
                  tone: live.bonded ? .positive : .warning, showsDot: true)
    }
}

// MARK: - Local section + row (mirrors the settings idiom)

private struct Section2<Content: View>: View {
    let icon: String; let title: String; var blurb: String? = nil
    /// Whether the automation is switched on. Kept for the call sites; v2 shows the state on the switch
    /// itself rather than as a tinted card.
    var active: Bool = false
    /// The automation's master switch, drawn on the header row when it has one.
    var master: Binding<Bool>? = nil
    /// A short state on the header's right ("3 of 4").
    var trailing: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
            content()
        }
        .background(RoundedRectangle(cornerRadius: NoopVisualStyle.listRadius, style: .continuous)
            .fill(NoopVisualStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: NoopVisualStyle.listRadius, style: .continuous)
            .strokeBorder(NoopVisualStyle.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: NoopVisualStyle.listRadius, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            G6IconTile(icon: Self.phosphor(icon), size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(StrandFont.book(15, relativeTo: .body)).foregroundStyle(StrandPalette.textPrimary)
                if let blurb {
                    Text(blurb).font(StrandFont.light(12.5, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing {
                Text(trailing).font(StrandFont.light(13, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if let master {
                // The v2 switch draws its own label, so the label is empty here and the title is spoken.
                Toggle(isOn: master) { EmptyView() }
                    .toggleStyle(.noop)
                    .fixedSize()
                    .accessibilityLabel(Text(title))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    /// The v2 Phosphor glyph for each automation (the call sites still name the old SF Symbol).
    static func phosphor(_ sf: String) -> String {
        switch sf {
        case "bell.badge.fill": return "bell-ringing"
        case "waveform.path": return "vibrate"
        case "hand.tap.fill": return "hand-tap"
        case "figure.walk.motion": return "user-focus"
        case "bolt.heart.fill": return "person-simple-run"
        case "timer": return "armchair"
        case "waveform.path.ecg": return "thermometer"
        case "thermometer.medium": return "lightbulb"
        case "battery.25": return "battery-warning"
        case "flame": return "target"
        default: return "sparkle"
        }
    }
}

/// Insets of the rows inside an automation card: aligned with the header title, past its icon tile.
private struct SubRowInsets: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.leading, 66)
            .padding(.trailing, 18)
            .padding(.vertical, 13)
    }
}

/// An explanatory line inside an automation card.
private struct NoteRow: View {
    let text: String
    var warning: Bool = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if warning {
                PhIcon("warning", size: 14).foregroundStyle(StrandPalette.textPrimary)
            }
            Text(text)
                .font(StrandFont.light(12.5, relativeTo: .caption))
                .foregroundStyle(warning ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SubRowInsets())
    }
}

private struct ToggleRow: View {
    let label: String; let help: String; @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(StrandFont.book(15, relativeTo: .body)).foregroundStyle(StrandPalette.textPrimary)
                Text(help).font(StrandFont.light(12.5, relativeTo: .caption)).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.noop)
        .modifier(SubRowInsets())
    }
}

// MARK: - Hero

/// How many automations are on, with the in-session cues, the double-tap action and coaching.
private struct AutomationsHero: View {
    let rulesOn: Int
    let rulesTotal: Int
    let cuesOn: Int
    let doubleTap: String?
    let coaching: Bool

    var body: some View {
        NoopHeroCard(glow: .ink, padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                NoopIconBadge("Strap buzzes", icon: "vibrate")
                HStack(alignment: .bottom, spacing: 12) {
                    NoopDotNumber("\(rulesOn)", size: 80)
                        .fixedSize()
                    Text("automations on\nof \(rulesTotal)")
                        .font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineSpacing(2)
                        .padding(.bottom, 8)
                }
                .padding(.top, 26)
                HStack(alignment: .top, spacing: 0) {
                    G6HeroMetric(value: "\(cuesOn)", unit: String(localized: "of 4"), label: Text("In-session cues"))
                    G6HeroMetric(value: doubleTap ?? String(localized: "Off"), label: Text("Double-tap"))
                    G6HeroMetric(value: coaching ? String(localized: "On") : String(localized: "Off"),
                                 label: Text("Coaching"))
                }
                .padding(.top, 26)
            }
            .padding(.top, 20)
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
    }
}
