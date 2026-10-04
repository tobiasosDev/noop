import SwiftUI
import StrandDesign
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The alarm facts every screen states — tonight's wind-down time and the strap alarm's next buzz —
/// resolved in ONE place. The Alarms screen and the Sleep tab's Alarms row both read these, so the two
/// can never print different times for the same alarm ("two readouts of one fact must not disagree").
@MainActor
enum AlarmReadout {
    /// The wind-down reminder's minute of day, or nil while the reminder is off (no time to promise).
    static func windDownMinute(enabled: Bool) -> Int? {
        enabled ? WindDownNudge.nudgeMinuteOfDay() : nil
    }

    /// The wind-down minute for the stored reminder switch.
    static var windDownMinute: Int? { windDownMinute(enabled: WindDownNudge.isEnabled) }

    /// Whether switching the strap alarm on actually arms anything: a WHOOP 5/MG arms its firmware alarm
    /// only with Protocol probes on (#864), so without them nothing will buzz and no countdown is owed.
    static func strapAlarmWillArm(whoop5Detected: Bool) -> Bool {
        !(whoop5Detected && !PuffinExperiment.isEnabled)
    }

    /// The strap alarm's next fire, or nil when nothing will fire. `nextSmartAlarmDate` is the same pure
    /// resolver `applySmartAlarm` arms the strap from, and the per-day overrides go in so a day with its
    /// own time resolves to THAT time.
    static func nextStrapAlarm(enabled: Bool, minutes: Int, weekdays: Set<Int>, overrides: [Int: Int],
                               whoop5Detected: Bool, from now: Date = Date()) -> Date? {
        guard enabled, strapAlarmWillArm(whoop5Detected: whoop5Detected) else { return nil }
        return AppModel.nextSmartAlarmDate(minutes: minutes, weekdays: weekdays, overrides: overrides, from: now)
    }

    /// "22:20" for a minute of day.
    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// "Sun 08:00": the next buzz as a short weekday and time, in the app language and the reader's
    /// 12/24-hour convention.
    static func shortStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.activeLocale
        formatter.setLocalizedDateFormatFromTemplate("EEE jj:mm")
        return formatter.string(from: date)
    }
}

/// Smart alarm (#207) — the iOS/macOS surface.
///
/// HONEST by design: a sideloaded, backgrounded app on iOS can't fire a dependable LOUD wake alarm
/// (that needs the critical-alert entitlement, which a non-App-Store build doesn't have), so this
/// platform deliberately does NOT offer a wake alarm. The dependable phone wake lives on Android,
/// which has the exact-alarm primitive. Here we offer the cross-platform WIND-DOWN nudge — a gentle
/// evening reminder — and we say plainly why there's no wake alarm, rather than promising one we
/// can't keep.
struct SmartAlarmView: View {
    // #766: this is now the ONE alarm surface. The strap's silent firmware wake-alarm used to live in a
    // separate card over in Automations, which let users conflate it with the wind-down reminder; it's
    // moved here so every wake/wind-down control sits together. Needs the model (to arm/disarm the strap
    // alarm over BLE) and the behavior store (the alarm's persisted on/time/weekdays).
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var behavior: BehaviorStore
    /// Pushed from Sleep or More, or presented as a sheet: only then is there somewhere to go back to, so
    /// only then does the header draw its back circle (a macOS sidebar root has none).
    @Environment(\.isPresented) private var isPresented

    @State private var windDownOn = WindDownNudge.isEnabled
    /// Shown when the user flips the nudge on but notifications are denied at the OS level — the reminder
    /// can never fire, so we revert the switch and point them to Settings instead of failing silently.
    @State private var showNotifDeniedAlert = false
    /// Earliest wake time the nudge is derived from (minutes since midnight). Seeded from the store.
    @State private var wakeMinutes = WindDownNudge.wakeMinutes

    // PR#554 (MumiZed) — per-day wake overrides. `perDayOn` reflects whether ANY override is set; the
    // `overrides` map mirrors the store so the pickers stay in sync. Additive: with none set, the nudge
    // behaves exactly as before (one wake time for every evening).
    @State private var perDayOn = WindDownNudge.hasPerDayOverrides
    @State private var overrides: [Int: Int] = WindDownNudge.perDayWakeOverrides

    /// The one time row whose picker is open. Rows state their time as text, like every v2 list, and a tap
    /// opens that row's picker in place; one at a time, so the screen never grows a stack of wheels.
    @State private var editing: TimeField?

    // #34: consecutive times the strap reported back a DIFFERENT alarm time than we sent (set in
    // FrameRouter). ≥2 = the strap is persistently refusing the alarm (a corrupted clock/alarm register),
    // which the strapRejectedCard surfaces with reset guidance. @AppStorage so it updates live.
    @AppStorage("alarm.rejectStreak") private var alarmRejectStreak = 0
    /// Calendar weekday numbers laid out Monday-first (Mon…Sun → 2,3,4,5,6,7,1), matching AutomationsView.
    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    /// The time rows that can open a picker.
    private enum TimeField: Hashable {
        case strapAlarm
        case usualWake
        case day(Int)
    }

    var body: some View {
        // #766: retitled to "Alarms" because it now holds BOTH the strap's silent wake-alarm and the
        // evening wind-down reminder, so naming it "Wind-Down" undersold it. One surface, clearly labelled.
        ScreenScaffold(title: nil) {
            VStack(alignment: .leading, spacing: 0) {
                pageHeader
                windowHero
                    .padding(.top, 20)
                morningSection
                eveningSection
                perDaySection
                honestyCard
            }
        }
        .noopHidesSystemNavBar()
        .alert(String(localized: "Notifications are off"), isPresented: $showNotifDeniedAlert) {
            Button(String(localized: "Open Settings")) { Self.openNotificationSettings() }
            Button(String(localized: "Not now"), role: .cancel) {}
        } message: {
            Text("Turn on notifications for NOOP in Settings to get your wind-down reminder.")
        }
    }

    /// Deep-link to the OS notification settings so a user who denied can flip it back on — the system
    /// permission dialog only appears once, so Settings is the only recovery path.
    private static func openNotificationSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    /// The back circle (pushed or presented only), then the page title and what the screen holds.
    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isPresented {
                NoopScreenHeader(verbatim: "") { EmptyView() }
                    .padding(.bottom, 18)
            }
            Text("Alarms")
                .font(StrandFont.title1)
                .tracking(-0.56)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Your strap wake-alarm and the evening wind-down reminder, in one place.")
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    // MARK: - Hero: tonight at a glance

    // The night in two readouts: when the wind-down nudge lands and when the strap actually buzzes.
    //
    // The wind-down row carries its source underneath, an arithmetic pair: the nudge is DERIVED from the
    // usual wake time, so the arrow joins those two and nothing else. The alarm is not part of that
    // derivation, so it is never chained on the arrow (that would claim the nudge is timed for the alarm);
    // it is the separate "Wake" row, resolved through the same funnel the strap is armed from. The usual
    // wake time stays small and named for what it is. It once sat here labelled "Wake", in the largest
    // type on the screen, and it is the reminder's INPUT: the first figure a reader met was not their alarm.
    //
    // How long until it goes off sits in the hero footer, where the eye lands, rather than beside the
    // picker six rows down. Exactly one countdown on the screen, because two live ones start the next
    // "which of these is the real one" question, which is the question this whole screen exists to stop.
    //
    // Re-rendered once a minute rather than computed at view build, since a countdown frozen at whatever
    // it read when the screen opened is worse than none. The TimelineView wraps only the hero, so the 60s
    // tick cannot re-render the lists below, and every alarm figure in it (the night span, the wake time,
    // the countdown) resolves from the SAME tick, so none of them can straddle the fire moment.
    private var windowHero: some View {
        TimelineView(.periodic(from: .now, by: 60)) { tick in
            heroCard(now: tick.date,
                     next: nextStrapAlarm(from: tick.date),
                     countdown: strapAlarmCountdown(from: tick.date),
                     stamp: nextStrapAlarmStamp(from: tick.date)) {
                if windDownOn {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.right")
                            .font(StrandFont.light(10, relativeTo: .caption2))
                            .accessibilityHidden(true)
                        heroTime(label: "Usual wake", time: timeLabel(wakeMinutes))
                    }
                } else {
                    Text("Reminder off")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func heroCard<WindDownSource: View>(now: Date, next: Date?, countdown: String?, stamp: String?,
                                                @ViewBuilder windDownSource: () -> WindDownSource) -> some View {
        let source = windDownSource()
        return NoopHeroCard(glow: .sleep) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    NoopIconBadge("Tonight", icon: "moon-stars")
                    Spacer(minLength: 8)
                    NoopPill(verbatim: nightSpan(now: now, next: next, stamp: stamp), compact: true)
                }
                VStack(spacing: 0) {
                    heroReadout(icon: "bell-simple", label: "Wind down",
                                time: AlarmReadout.windDownMinute(enabled: windDownOn).map(timeLabel)) {
                        source
                    }
                    heroRule
                    heroReadout(icon: "vibrate", label: "Wake", time: next.map(clockTime)) {
                        Text(verbatim: wakeCaption(for: next))
                    }
                }
                .padding(.top, 22)
                heroFooter(countdown: countdown)
            }
        }
    }

    /// One hero row: an icon and label over a short source line, the time in the dot-matrix face.
    private func heroReadout<Caption: View>(icon: String, label: LocalizedStringKey, time: String?,
                                            @ViewBuilder caption: () -> Caption) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    PhIcon(icon, size: 16).opacity(0.85)
                    Text(label).font(StrandFont.book(15, relativeTo: .body))
                }
                caption()
                    .font(StrandFont.light(11.5, relativeTo: .caption))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Nothing to promise reads as an empty clock rather than as a time. The frame is the kit's
            // 0.9 line height, so the dot face's tall line box does not stretch the row.
            NoopDotNumber(time ?? "--:--", size: 52,
                          color: time == nil ? NoopVisualStyle.quaternaryText : StrandPalette.textPrimary)
                .fixedSize()
                .frame(height: 47)
                .layoutPriority(1)
        }
        .padding(.vertical, 14)
    }

    /// The reminder's input as the source line of the wind-down figure: "Usual wake 06:30", small, never a
    /// figure of its own.
    private func heroTime(label: LocalizedStringKey, time: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
            Text(verbatim: time).font(StrandFont.value(11.5))
        }
    }

    /// The hairline between the hero's rows and above its footer.
    private var heroRule: some View {
        Rectangle().fill(StrandPalette.textPrimary.opacity(0.1)).frame(height: 1)
    }

    /// The countdown, with the strap's own state in front of it when that changes what the countdown is
    /// worth: a strap that keeps refusing the alarm (#34) gets the warning first, so a tick mark never sits
    /// beside an alarm the strap is not keeping. No countdown, no footer: the Wake row already says why.
    @ViewBuilder private func heroFooter(countdown: String?) -> some View {
        if let countdown {
            HStack(alignment: .top, spacing: 8) {
                PhIcon(strapRejectsAlarm ? "warning" : (model.whoop5Detected ? "flask" : "check-circle"), size: 16)
                VStack(alignment: .leading, spacing: 3) {
                    if strapRejectsAlarm {
                        Text("Your strap isn't accepting the alarm")
                            .font(StrandFont.light(13, relativeTo: .footnote))
                    }
                    Text(verbatim: countdown)
                        .font(StrandFont.light(strapRejectsAlarm ? 11.5 : 13, relativeTo: .footnote))
                        .foregroundStyle(strapRejectsAlarm ? StrandPalette.textSecondary
                                                           : StrandPalette.textPrimary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(StrandPalette.textPrimary.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .overlay(alignment: .top) { heroRule }
            .padding(.top, 6)
        }
    }

    /// Where the next buzz's time comes from: that weekday's own time, or the default. Read from the
    /// override map the funnel resolved it with, keyed by the fire's own weekday, so the caption names the
    /// rule that actually produced the figure beside it.
    private func wakeCaption(for next: Date?) -> String {
        guard let next else {
            if !behavior.smartAlarmEnabled { return String(localized: "Strap alarm off") }
            if !strapAlarmWillArm { return String(localized: "Not armed on this strap") }
            return String(localized: "No alarm day selected")
        }
        let weekday = Calendar.current.component(.weekday, from: next)
        if overrides[weekday] != nil { return String(localized: "\(Self.weekdayName(weekday))'s own time") }
        return String(localized: "Your default time")
    }

    /// "Sat 3 → Sun 4 Oct": from tonight to the morning of the next buzz, so the date the wake figure
    /// belongs to is on the card. A buzz later the same day shows that day alone, and with no alarm to
    /// name the pill is just tonight's date.
    private func nightSpan(now: Date, next: Date?, stamp: String?) -> String {
        guard let next, let stamp else { return Self.dayStamp(now, template: "EEE d MMM") }
        let cal = Calendar.current
        if cal.isDate(next, inSameDayAs: now) { return stamp }
        let sameMonth = cal.isDate(next, equalTo: now, toGranularity: .month)
        return "\(Self.dayStamp(now, template: sameMonth ? "EEE d" : "EEE d MMM")) → \(stamp)"
    }

    private static func dayStamp(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.activeLocale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// The next buzz's time of day in the same clock the wind-down figure uses, so the hero's two times
    /// read alike.
    private func clockTime(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return AlarmReadout.clock((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    // MARK: - Morning: the strap's silent wake-alarm (#766, moved here from Automations)

    // The strap's own firmware alarm: a silent wrist buzz at the chosen time, armed over BLE so it fires
    // even if the phone is asleep or NOOP is closed. Lifted (behaviour intact) out of
    // AutomationsView.alarmCard so users stop conflating it with the wind-down reminder below.
    private var morningSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Morning", caption: "Strap wake-alarm")
            NoopList {
                strapToggleRow
                if behavior.smartAlarmEnabled {
                    alarmTimeRow
                    // The time and the days it fires on are edited together, under the row whose caption
                    // already states both.
                    if editing == .strapAlarm {
                        timeWheel(alarmTimeBinding)
                            // Distinct from the wind-down picker's label below. Both were "Wake time",
                            // so VoiceOver announced the alarm and the reminder's timing input by the
                            // same name, on the same screen, with different values.
                            .accessibilityLabel("Strap alarm wake time")
                        alarmWeekdayPicker
                    }
                }
            }
            if behavior.smartAlarmEnabled {
                strapAlarmNotes
                // Only where the strap is not a 5/MG, the same branch the "Armed on the strap itself"
                // note above takes.
                if !model.whoop5Detected {
                    checkStoredControl
                }
            }
            strapRejectedCard   // #34: only shows when the strap keeps refusing the alarm
        }
        .onChangeCompat(of: behavior.smartAlarmEnabled) { _ in model.applySmartAlarm() }
        .onChangeCompat(of: behavior.smartAlarmMinutes) { _ in model.applySmartAlarm() }
        .onChangeCompat(of: behavior.smartAlarmWeekdays) { _ in model.applySmartAlarm() }
    }

    /// The `.st` section title at the v2 rhythm: 30 pt above, 14 pt to the list.
    private func sectionTitle(_ title: LocalizedStringKey, caption: LocalizedStringKey) -> some View {
        NoopSectionTitle(title, captionKey: caption, topPadding: 30)
            .padding(.bottom, 12)
    }

    private var strapToggleRow: some View {
        NoopRow("Wake me with a strap buzz", caption: "Silent, on your wrist only", icon: "vibrate") {
            Toggle(isOn: $behavior.smartAlarmEnabled) { EmptyView() }
                .toggleStyle(.noop)
                .fixedSize()
                .accessibilityLabel("Wake me with a strap buzz")
        }
    }

    private var alarmTimeRow: some View {
        timeRow(.strapAlarm, title: Text("Wake at"), caption: Text(verbatim: alarmTimeCaption),
                icon: "alarm", time: timeLabel(behavior.smartAlarmMinutes))
    }

    /// "Your default for every day", or the days it fires on once the weekday chips narrow it.
    private var alarmTimeCaption: String {
        let days = behavior.smartAlarmWeekdays
        if days.isEmpty || days.count == 7 { return String(localized: "Your default for every day") }
        return String(localized: "Your default on \(Self.alarmWeekdaySummary(days))")
    }

    // #1706: ask the strap what it actually has stored. The readback was otherwise only reachable by
    // ARMING, so anyone whose alarm is off could not produce the frame that explains a wrong reported time.
    //
    // Shown unconditionally, where the Android twin hides it until bonded. That is a deliberate platform
    // difference, not drift: the Android card already observes LiveState, so gating there is free, while
    // this view does not — and pulling `live` in would re-render the whole alarm screen on every 1 Hz HR
    // tick, which this codebase keeps parent views clear of on purpose. `getStrapAlarm` no-ops and logs
    // when nothing is connected, so the worst case is one ignored write.
    private var checkStoredControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            NoopButton("Check what the strap has stored", kind: .secondary, fullWidth: true) {
                model.ble.getStrapAlarm()
            }
            Text("The answer from the strap appears in your strap log and debug export, with the raw bytes it replied with.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
        .padding(.top, 14)
    }

    /// What the Morning list cannot say in a row: when a per-day time overrides "Wake at", and what
    /// arming actually does on this strap.
    private var strapAlarmNotes: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The per-day overrides that re-time THIS alarm (#1864) are edited further down, so read on its
            // own this list can say "10:00" during a week whose Saturday fires at 20:30. Checking your alarm
            // is exactly what someone opens this section to do, so the qualifier belongs against the number
            // it qualifies. Shown only when an override actually exists, because otherwise the picker IS the
            // whole truth.
            if !overrides.isEmpty, let next = nextStrapAlarmLabel {
                Text("Some days have a time of their own, set under Different wake time per day below. Next buzz \(next).")
            }
            // #864: a WHOOP 5/MG only arms its firmware alarm when Protocol probes is on (see
            // BLEManager.armStrapAlarm, which logs "not armed" and returns otherwise). Without this
            // branch the card claimed "Armed on the strap itself" to a 5/MG owner whose strap was
            // NOT armed, an honest-data violation (reporter: 5/MG, Experimental off, never buzzed).
            // Mirrors the Android SmartAlarmScreen StrapAlarmCard wording exactly. The else copy
            // was truth-synced once a real 4.0 wake was confirmed (PR #535: official-app wire
            // capture + on-device buzz by the capture author); 5/MG remains experimental, so this
            // gated branch keeps its backup-alarm wording.
            if !strapAlarmWillArm {
                HStack(alignment: .top, spacing: 8) {
                    PhIcon("warning", size: 14)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.top, 1)
                    Text("WHOOP 5/MG strap alarms require Protocol probes (Test Centre → 5/MG protocol diagnostics). Your wake time is saved, but the strap is not armed yet. Keep a backup alarm.")
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            } else if model.whoop5Detected {
                // 5/MG with Protocol probes ON: the rev-4 command arms the strap. One wake was
                // captured on an MG (#864) and one reported on a 5.0 without a log (#2464);
                // neither repeated, so the copy simplifies both to "reported" and promises none.
                Text("Armed on the strap with an experimental 5/MG command. Strap-driven wakes have been reported on 5.0 and MG, but are not guaranteed. Keep a backup alarm for anything you cannot miss.")
            } else {
                Text("Armed on the strap itself, so it can buzz at your wake time even if your phone is asleep or NOOP is closed. Sends the exact alarm command the official app sends, confirmed buzzing on a real WHOOP 4.0 (community wire capture + on-device test, #535). Keep a backup alarm for anything you truly can't miss.")
            }
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 12)
    }

    /// The #34 gate, named once: the hero footer and the card below both read it.
    private var strapRejectsAlarm: Bool {
        behavior.smartAlarmEnabled && alarmRejectStreak >= 2
    }

    // #34: shown ONLY when the strap has repeatedly reported back a different alarm time than we sent —
    // i.e. its firmware is refusing the write (a reset/corrupted clock/alarm register). Gated on the alarm
    // being on and a rejection STREAK (≥2) so a one-off readback quirk never nags. Actionable: a strap
    // reset via the official app clears it; the phone Clock alarm covers the gap meanwhile.
    @ViewBuilder private var strapRejectedCard: some View {
        if strapRejectsAlarm {
            noteCard(icon: "warning",
                     title: "Your strap isn't accepting the alarm",
                     message: "The strap keeps reporting a different time than NOOP sends, so its firmware alarm won't fire at your wake time — usually a strap whose clock or alarm has reset. Reset the strap in the official WHOOP app (or fully charge it and reconnect), and keep your phone's Clock alarm as your wake until it takes.")
                .padding(.top, 12)
        }
    }

    // The honest note about the difference between the strap's silent buzz (above) and a loud phone wake.
    // The strap alarm is real, but it's a gentle wrist buzz, not a sound, so we say plainly to keep a
    // backup, and that the louder smart wake lives on Android. It closes the screen rather than splitting
    // the Morning and Evening lists; the toggle's own caption and the armed note under it already carry
    // "silent" and "keep a backup alarm" where the alarm is switched on.
    private var honestyCard: some View {
        noteCard(icon: "bell-slash",
                 title: "The strap alarm is a silent buzz, not a sound",
                 message: "The wake-alarm above buzzes your wrist from the strap's own firmware. It can't sound a loud alarm. We also schedule a backup notification at your wake time, but a sideloaded app can't sound a guaranteed wake on this device (that needs a critical-alert permission this build doesn't have), so Focus or silent mode can still mute it. Keep your phone's built-in Clock alarm as your real backup. NOOP's phone-based smart wake (light-sleep detection) is available on the Android app.")
            .padding(.top, 30)
    }

    /// A neutral v2 note card: an icon, a title and the explanation under it.
    private func noteCard(icon: String, title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        NoopCard {
            HStack(alignment: .top, spacing: 12) {
                PhIcon(icon, size: 18)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(StrandFont.light(13, relativeTo: .footnote))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Evening: the wind-down nudge

    private var eveningSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Evening", caption: "Wind-down nudge")
            NoopList {
                windDownToggleRow
                if windDownOn {
                    NoopRow("When", icon: "hourglass-medium") {
                        Text("\(WindDownNudge.leadMinutes) min before bed")
                    }
                    usualWakeRow
                    if editing == .usualWake {
                        timeWheel(wakeBinding)
                            .accessibilityLabel("Your usual wake time")
                    }
                }
            }
            // Answers "so what actually wakes me?" in the one place the question gets asked, beside the
            // time that does not. Only shown when there IS a strap alarm to name.
            if windDownOn, let next = nextStrapAlarmLabel {
                Text("Your strap alarm is what wakes you, next on \(next).")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 12)
            }
        }
    }

    private var windDownToggleRow: some View {
        NoopRow(title: Text("Remind me to wind down"), caption: windDownToggleCaption, icon: "bell-simple") {
            Toggle(isOn: $windDownOn) { EmptyView() }
                .toggleStyle(.noop)
                .fixedSize()
                .accessibilityLabel("Remind me to wind down")
                .onChangeCompat(of: windDownOn) { on in
                    WindDownNudge.setEnabled(on) { outcome in
                        // Denied at the OS level: the reminder can never fire, so reflect reality
                        // (revert the switch) and surface the path to Settings.
                        if outcome == .denied {
                            windDownOn = false
                            showNotifDeniedAlert = true
                        }
                    }
                }
        }
    }

    /// "Bed target 22:50" while the reminder is on; what the reminder is while it is off.
    private var windDownToggleCaption: Text {
        guard let bed = bedTargetMinute else {
            return Text("A calm evening reminder, timed from your wake time and usual sleep need. It's a suggestion, not an alarm.")
        }
        return Text("Bed target \(timeLabel(bed))")
    }

    /// Tonight's bed target: the nudge plus its lead, from the same wind-down minute the hero prints, so
    /// the bed time and the nudge time can never drift apart.
    private var bedTargetMinute: Int? {
        AlarmReadout.windDownMinute(enabled: windDownOn).map { ($0 + WindDownNudge.leadMinutes) % (24 * 60) }
    }

    // Was "Wake time", the same words the strap alarm's own picker uses one section up. Two pickers called
    // the same thing, holding different times, and only one of them wakes anybody: a reporter asked
    // outright which time would wake them. This field is an INPUT to the reminder's arithmetic, so it is
    // named for what it is rather than for what it sounds like, and says so under its own name.
    private var usualWakeRow: some View {
        timeRow(.usualWake, title: Text("Your usual wake time"),
                caption: Text("This time does not wake you. It only decides when the evening reminder fires."),
                icon: "sun-horizon", time: timeLabel(wakeMinutes))
    }

    // MARK: - Time rows

    /// A list row that states a time and opens its picker in place on tap.
    private func timeRow(_ field: TimeField, title: Text, caption: Text?, icon: String, time: String) -> some View {
        Button {
            toggleEditing(field)
        } label: {
            NoopRow(title: title, caption: caption, icon: icon) {
                HStack(spacing: 14) {
                    Text(verbatim: time)
                        .font(StrandFont.value(17))
                        .foregroundStyle(StrandPalette.textPrimary)
                    disclosureCaret(open: editing == field)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func toggleEditing(_ field: TimeField) {
        withAnimation(StrandMotion.interactive) { editing = editing == field ? nil : field }
    }

    private func disclosureCaret(open: Bool, dimmed: Bool = false) -> some View {
        PhIcon("caret-right", size: 18)
            .foregroundStyle(StrandPalette.textPrimary)
            .opacity(dimmed ? 0.35 : 0.5)
            .rotationEffect(.degrees(open ? 90 : 0))
    }

    /// The in-place picker a time row opens: the wheel on iOS (the compact control is a system capsule a
    /// v2 row cannot restyle), the stepper field on macOS.
    private func timeWheel(_ selection: Binding<Date>) -> some View {
        DatePicker("", selection: selection, displayedComponents: .hourAndMinute)
            .labelsHidden()
            #if os(iOS)
            .datePickerStyle(.wheel)
            #else
            .datePickerStyle(.stepperField)
            #endif
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
    }

    // MARK: - Per-day wake overrides (PR#554)

    // PR#554 — per-day wake overrides. A toggle reveals a per-weekday wake-time editor; with it off (or no
    // override set) every day uses its default. Each weekday row shows the effective wake (its own time or
    // the default) and opens a picker to set it, with a clear control once the day has a time of its own.
    //
    // Its own section rather than part of the evening reminder: #1864 made these days drive the strap
    // alarm too, so it shows while either of the two is on.
    @ViewBuilder private var perDaySection: some View {
        if behavior.smartAlarmEnabled || windDownOn {
            VStack(alignment: .leading, spacing: 0) {
                perDayHeader
                if perDayOn {
                    NoopList {
                        ForEach(Self.weekdayOrder, id: \.self) { weekday in
                            weekdayOverrideRow(weekday)
                            if editing == .day(weekday) {
                                weekdayEditor(weekday)
                            }
                        }
                    }
                    .padding(.top, 14)
                    // The rows state their time as text, so how to edit one is said here once.
                    VStack(alignment: .leading, spacing: 4) {
                        Text(untouchedDayExplainer)
                        Text("Tap a day to give it its own time, or clear it to fall back.")
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 12)
                }
            }
        }
    }

    private var perDayHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Text("Different wake time per day")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Toggle(isOn: $perDayOn) { EmptyView() }
                    .toggleStyle(.noop)
                    .fixedSize()
                    .accessibilityLabel("Different wake time per day")
                    .onChangeCompat(of: perDayOn) { on in
                        // Turning the section OFF clears every override (so the nudge reverts to the single
                        // time); turning it ON just reveals the editor — no override is created until the
                        // user sets one.
                        if !on {
                            for weekday in 1...7 { WindDownNudge.setWakeOverride(weekday: weekday, minutes: nil) }
                            overrides = [:]
                            // #1864: re-arm the strap alarm + backup notification so they drop the per-day
                            // times and revert to the single default, matching the wind-down nudge's revert.
                            model.applySmartAlarm()
                        }
                    }
            }
            // #1864 made these overrides drive the STRAP ALARM as well as the reminder, but the copy stayed
            // written as though they only moved the nudge. A day set here re-times the buzz on your wrist.
            // Saying so is the difference between a lie-in and an alarm that goes off on Saturday evening.
            Text("Set a wake time for specific days (a lie-in at the weekend, say). These times move your strap alarm AND the evening reminder on those days.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 30)
    }

    /// When the strap alarm will next actually buzz, as a localised weekday and time, or nil when there
    /// is no alarm to name.
    ///
    /// Deliberately the NEXT FIRE rather than `smartAlarmMinutes`. With a per-day override set there is no
    /// single alarm time to state, and naming the base one would be wrong on exactly the days the reporter
    /// had changed: their Saturday override reads 20:30 while the base reads 10:00. A line that answers
    /// "what wakes me" has to be right on every day, or it is one more thing on this screen to misread.
    /// `nextSmartAlarmDate` is the same pure resolver `applySmartAlarm` arms the strap from, so this cannot
    /// drift from what the strap is actually told.
    ///
    /// The template formatter also follows the reader's 12/24-hour setting, unlike `timeLabel`.
    private var nextStrapAlarmLabel: String? {
        guard let next = nextStrapAlarm() else { return nil }
        let formatter = DateFormatter()
        // `AppLanguage.activeLocale`, not `.current`: the app language is an in-app setting, so a reader
        // running NOOP in German on an English device must get German weekday words here, while keeping
        // their device's 24-hour convention. The same reason every other formatter in the app uses it.
        formatter.locale = AppLanguage.activeLocale
        formatter.setLocalizedDateFormatFromTemplate("EEEE jj:mm")
        return formatter.string(from: next)
    }

    /// Whether switching the alarm on actually arms anything that will go off.
    ///
    /// A WHOOP 5/MG arms its firmware alarm only with Experimental on: `BLEManager.armStrapAlarm` logs
    /// "not armed" and returns otherwise. That is the #864 case, reported by a 5/MG owner whose strap
    /// never buzzed while this card told them it was armed, and the card carries a warning for it.
    ///
    /// A countdown is a promise, so it must not be made for an alarm that will not exist. On macOS there
    /// is not even a fallback to fall back to: `scheduleSmartAlarmBackupNotification` is `#if os(iOS)`
    /// with no `#else`, so in that state nothing whatsoever happens at the chosen time. Saying "Alarm in
    /// 18 hours" directly above the line admitting the strap is NOT armed would reintroduce the exact
    /// honesty bug one row up from its own fix.
    ///
    /// A strap that is merely disconnected is NOT excluded here: `armStrapAlarm` queues and arms on
    /// reconnect, so the alarm is real and the countdown to it is true.
    private var strapAlarmWillArm: Bool {
        AlarmReadout.strapAlarmWillArm(whoop5Detected: model.whoop5Detected)
    }

    /// The one moment every alarm readout on this screen is derived from, or nil when nothing will fire.
    ///
    /// Single funnel on purpose. This resolver was called from three places, each repeating the gate and
    /// the argument list, which is three chances for one of them to drift from what the strap is actually
    /// armed with. `nextSmartAlarmDate` is the same pure function `applySmartAlarm` arms from, and the
    /// overrides go in so a day with its own time resolves to THAT time. The gate is spelled here as well
    /// as inside `AlarmReadout`, so this screen's own funnel visibly carries it and no readout can skip it.
    ///
    /// `from` is a parameter so the ticking countdown re-resolves against the clock it is given rather
    /// than a `Date()` captured somewhere else.
    private func nextStrapAlarm(from now: Date = Date()) -> Date? {
        guard behavior.smartAlarmEnabled, strapAlarmWillArm else { return nil }
        return AlarmReadout.nextStrapAlarm(enabled: behavior.smartAlarmEnabled,
                                           minutes: behavior.smartAlarmMinutes,
                                           weekdays: behavior.smartAlarmWeekdays,
                                           overrides: overrides,
                                           whoop5Detected: model.whoop5Detected,
                                           from: now)
    }

    /// The next alarm's date: "Sun 4 Oct".
    ///
    /// The absolute companion to the countdown, the way a phone's clock app pairs them. "In 17 hours" is
    /// what you want at a glance; the date is what you check when the answer matters, since it is what
    /// actually settles "tonight or tomorrow". The time of day is the hero's own wake figure, so the stamp
    /// carries only the date rather than printing that time a second time beside it.
    ///
    /// Takes the SAME clock the countdown was resolved from. Reading `Date()` here instead would give the
    /// two lines two clocks up to a tick apart, and `nextSmartAlarmDate` returns the next strictly-future
    /// fire: straddle that moment and the countdown says "less than a minute" while the stamp names
    /// tomorrow. Two lines disagreeing about one fact is the exact defect this screen exists to remove.
    private func nextStrapAlarmStamp(from now: Date = Date()) -> String? {
        nextStrapAlarm(from: now).map { date in
            let formatter = DateFormatter()
            formatter.locale = AppLanguage.activeLocale
            formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
            return formatter.string(from: date)
        }
    }

    /// How long until the strap alarm next buzzes, as "18 hours, 6 minutes", or nil when no alarm is set.
    ///
    /// A wall-clock time answers "when", but not "is that tonight or tomorrow", which is the question an
    /// alarm actually raises when you are looking at it in the evening. Resolved through the same
    /// `nextSmartAlarmDate` the strap is armed from, so a per-day override counts down to ITS time.
    ///
    /// `DateComponentsFormatter` rather than hand-built text because the unit words pluralise differently
    /// per language, and an app that ships nine of them should not be writing "1 hours".
    private func strapAlarmCountdown(from now: Date) -> String? {
        guard let next = nextStrapAlarm(from: now) else { return nil }
        let seconds = next.timeIntervalSince(now)
        // Under a minute there is no useful number left, and "in 0 minutes" reads like a bug.
        guard seconds >= 60 else { return String(localized: "Alarm in less than a minute") }
        let formatter = DateComponentsFormatter()
        formatter.calendar = {
            var cal = Calendar.current
            cal.locale = AppLanguage.activeLocale
            return cal
        }()
        formatter.unitsStyle = .full
        // Days included because a weekday-restricted alarm can be up to a week out, and "151 hours" is
        // not an answer. Leading zero units are dropped, so a same-day alarm stays "18 hours, 6 minutes".
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.zeroFormattingBehavior = .dropAll
        formatter.maximumUnitCount = 3
        guard let span = formatter.string(from: seconds), !span.isEmpty else { return nil }
        return String(localized: "Alarm in \(span)")
    }

    /// What a day with no override of its own actually does.
    ///
    /// There is no single fallback to show: the strap alarm falls back to its OWN time while the reminder
    /// falls back to the usual wake time above, and a row can only display one number. Naming both beats
    /// picking one and being wrong half the time. Hoisted out of the view body to keep this screen clear
    /// of the iOS type-check budget.
    ///
    /// Both base times are real settings, so `timeLabel` is right here and matches the rows above.
    /// `nextStrapAlarmLabel` differs on purpose: it renders a weekday too, so it needs a date formatter
    /// regardless, and takes the reader's clock format while it is there.
    private var untouchedDayExplainer: String {
        guard behavior.smartAlarmEnabled else {
            return String(localized: "Days you leave alone use the usual wake time above.")
        }
        let alarm = timeLabel(behavior.smartAlarmMinutes)
        let usual = timeLabel(wakeMinutes)
        return String(localized: "Days you leave alone keep your strap alarm at \(alarm), and time the reminder from \(usual).")
    }

    /// The one time a day without its own falls back to, or nil when the strap alarm and the reminder fall
    /// back to different times. A row has room for one number, so it only prints one when that number is
    /// true for both; otherwise it says "Default" and the explainer under the list names the two.
    private var untouchedDayFallback: Int? {
        switch (behavior.smartAlarmEnabled, windDownOn) {
        case (true, false): return behavior.smartAlarmMinutes
        case (false, _): return wakeMinutes
        case (true, true): return behavior.smartAlarmMinutes == wakeMinutes ? wakeMinutes : nil
        }
    }

    /// The calendar weekday of tomorrow, the row the coming morning belongs to.
    private var tomorrowWeekday: Int {
        let cal = Calendar.current
        return cal.component(.weekday, from: cal.date(byAdding: .day, value: 1, to: Date()) ?? Date())
    }

    /// One weekday's row: the day, the effective wake (its own time, or the default in tertiary ink), and a
    /// caret that opens the picker under it.
    private func weekdayOverrideRow(_ weekday: Int) -> some View {
        let own = overrides[weekday]
        let value: String
        if let own {
            value = timeLabel(own)
        } else if let fallback = untouchedDayFallback {
            value = String(localized: "\(timeLabel(fallback)) (default)")
        } else {
            value = String(localized: "Default")
        }
        return Button {
            toggleEditing(.day(weekday))
        } label: {
            HStack(spacing: 14) {
                Text(Self.alarmWeekdayShort(weekday))
                    .font(StrandFont.book(14.5, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 44, alignment: .leading)
                if weekday == tomorrowWeekday {
                    Text("Tomorrow")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 8)
                Text(verbatim: value)
                    .font(own == nil ? StrandFont.light(14, relativeTo: .subheadline)
                                     : StrandFont.book(14, relativeTo: .subheadline))
                    .foregroundStyle(own == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                disclosureCaret(open: editing == .day(weekday), dimmed: own == nil)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The open picker under one weekday row, and the clear control once that day has a time of its own.
    private func weekdayEditor(_ weekday: Int) -> some View {
        let effective = overrides[weekday] ?? untouchedDayFallback ?? wakeMinutes
        return VStack(spacing: 10) {
            timeWheel(overrideBinding(weekday, effective: effective))
                .accessibilityLabel("\(Self.weekdayName(weekday)) wake time")
            if overrides[weekday] != nil {
                Button {
                    WindDownNudge.setWakeOverride(weekday: weekday, minutes: nil)
                    overrides[weekday] = nil
                    // #1864: re-arm so clearing an override reverts that day's wake to the default time
                    // on the strap alarm + backup notification too, not just the wind-down nudge.
                    model.applySmartAlarm()
                } label: {
                    HStack(spacing: 8) {
                        PhIcon("arrow-counter-clockwise", size: 16)
                        Text("Clear, use the default time")
                    }
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                .accessibilityLabel("Clear \(Self.weekdayName(weekday)) override, use the default wake time")
                .padding(.horizontal, 18)
            }
        }
        .padding(.bottom, 14)
    }

    /// A binding for one weekday's wake override — reads the effective minute, writes a NEW override (a pick
    /// always sets that day's override) into both the store and the local mirror, rescheduling via the store.
    private func overrideBinding(_ weekday: Int, effective: Int) -> Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = effective / 60
                c.minute = effective % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let m = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                WindDownNudge.setWakeOverride(weekday: weekday, minutes: m)
                overrides[weekday] = m
                // #1864: re-arm the strap alarm + backup notification so the new per-day time takes
                // effect immediately, not just the wind-down reminder. Without this the override moved
                // only the evening nudge and left the wake on the default time.
                model.applySmartAlarm()
            }
        )
    }

    /// Full weekday name for a Calendar weekday number (1=Sun…7=Sat).
    private static func weekdayName(_ dow: Int) -> String {
        let names = [String(localized: "Sunday"), String(localized: "Monday"), String(localized: "Tuesday"),
                     String(localized: "Wednesday"), String(localized: "Thursday"), String(localized: "Friday"),
                     String(localized: "Saturday")]
        return (1...7).contains(dow) ? names[dow - 1] : String(localized: "Day \(dow)")
    }

    // Bridges the minutes-since-midnight store to a DatePicker's Date, persisting + rescheduling.
    private var wakeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = wakeMinutes / 60
                c.minute = wakeMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let m = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                wakeMinutes = m
                WindDownNudge.setWakeMinutes(m)
            }
        )
    }

    private func timeLabel(_ minutes: Int) -> String {
        AlarmReadout.clock(minutes)
    }

    // MARK: - Strap alarm weekday picker (#766, moved here from Automations, behaviour intact)

    private var alarmWeekdayPicker: some View {
        HStack(alignment: .center, spacing: 14) {
            NoopIconTile("calendar-dots")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    ForEach(Self.weekdayOrder, id: \.self) { dow in
                        alarmWeekdayChip(dow)
                    }
                }
                Text(Self.alarmWeekdaySummary(behavior.smartAlarmWeekdays))
                    .font(StrandFont.light(12, relativeTo: .caption))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    /// One day chip: the `.chip` treatment on a circle, ink when the alarm fires that day.
    private func alarmWeekdayChip(_ dow: Int) -> some View {
        let selected = Self.alarmWeekdayIsSelected(dow, in: behavior.smartAlarmWeekdays)
        return Text(Self.alarmWeekdayInitial(dow))
            .font(StrandFont.book(12, relativeTo: .caption))
            .foregroundStyle(selected ? StrandPalette.goldDeepText : StrandPalette.textSecondary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(selected ? StrandPalette.gold : NoopVisualStyle.inset))
            .overlay(Circle().strokeBorder(selected ? Color.clear : NoopVisualStyle.border, lineWidth: 1))
            .contentShape(Circle())
            .onTapGesture { behavior.smartAlarmWeekdays = Self.alarmToggledWeekday(dow, in: behavior.smartAlarmWeekdays) }
            .accessibilityLabel(Self.weekdayName(dow))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Bridges the strap alarm's minutes-since-midnight store to a DatePicker's Date.
    private var alarmTimeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = behavior.smartAlarmMinutes / 60
                c.minute = behavior.smartAlarmMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                behavior.smartAlarmMinutes = (c.hour ?? 7) * 60 + (c.minute ?? 0)
            }
        )
    }

    // The strap-alarm weekday rules: pure + nonisolated so they stay unit-testable. Kept byte-identical
    // to the originals in AutomationsView (only renamed with an `alarm` prefix to avoid colliding with
    // this view's full-name `weekdayName`).

    /// A day reads as "on" when the set is empty (= every day) or explicitly contains it.
    nonisolated static func alarmWeekdayIsSelected(_ dow: Int, in days: Set<Int>) -> Bool {
        days.isEmpty || days.contains(dow)
    }

    /// Toggle one weekday, normalising "every day" at both ends so the empty set always means every day.
    nonisolated static func alarmToggledWeekday(_ dow: Int, in days: Set<Int>) -> Set<Int> {
        var next: Set<Int>
        if days.isEmpty {
            next = Set(1...7)
            next.remove(dow)
        } else if days.contains(dow) {
            next = days
            next.remove(dow)
        } else {
            next = days
            next.insert(dow)
        }
        return next.count == 7 ? [] : next
    }

    /// Human-readable summary of the selection.
    nonisolated static func alarmWeekdaySummary(_ days: Set<Int>) -> String {
        if days.isEmpty || days.count == 7 { return String(localized: "Every day") }
        if days == Set(2...6) { return String(localized: "Weekdays") }
        if days == Set([1, 7]) { return String(localized: "Weekends") }
        return weekdayOrder.filter { days.contains($0) }.map { alarmWeekdayShort($0) }.joined(separator: ", ")
    }

    /// One-letter day chip. Derived from the localized short name so the initials follow the
    /// language (and Tue/Thu or Sat/Sun never share a single collision-prone key). English output
    /// is byte-identical to the old hardcoded initials.
    private static func alarmWeekdayInitial(_ dow: Int) -> String {
        let short = alarmWeekdayShort(dow)
        return short == "?" ? "?" : String(short.prefix(1))
    }

    nonisolated private static func alarmWeekdayShort(_ dow: Int) -> String {
        switch dow {
        case 1: return String(localized: "Sun")
        case 2: return String(localized: "Mon")
        case 3: return String(localized: "Tue")
        case 4: return String(localized: "Wed")
        case 5: return String(localized: "Thu")
        case 6: return String(localized: "Fri")
        case 7: return String(localized: "Sat")
        default: return "?"
        }
    }
}
