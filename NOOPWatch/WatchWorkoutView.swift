import SwiftUI
import StrandDesign
#if canImport(HealthKit)
import HealthKit
#endif

// MARK: - WatchWorkoutView — record a workout ON the wrist (M3)
//
// This is the one ACTIVE feature where the watch is the brain, not the phone. The phone owns SCORES; this
// screen owns a real HKWorkoutSession + HKLiveWorkoutBuilder running on the watch's own sensors, so the
// heart rate here is the higher-fidelity in-workout stream (not the foregrounded anchored-query readout the
// glance uses), and the energy is the watch's own activeEnergyBurned. On End we save the finished workout
// to HealthKit so it shows up in Activity / Fitness like any other.
//
// We deliberately reimplement the phone's LiveWorkoutView rather than link it: that screen reads the strap
// feed and the shared scorers off AppModel, which don't exist on the watch. The framing is kept though —
// a generic "functional" workout (functionalStrengthTraining), the elapsed clock in the dot face, the live
// HR, and the building Effort idea expressed honestly here as the live calorie burn from the wrist.
//
// Everything is GUARDED. If HealthKit is unavailable or workout authorization is denied, we show a calm
// "Grant Health access" state instead of a dead Start button. StrandHaptic (real WatchKit path now) marks
// the start / pause / resume / end landings so the wrist confirms each state change without looking.
struct WatchWorkoutView: View {
    @StateObject private var workout = WatchWorkoutSession()

    init() {}

    #if DEBUG
    /// DEBUG screenshot aid: drive the page from a given session (see `WatchWorkoutSession.demoRecording`).
    init(session: WatchWorkoutSession) {
        _workout = StateObject(wrappedValue: session)
    }
    #endif

    var body: some View {
        // One screen, no scrolling. A GeometryReader hands each state the real space it has to live in so
        // the controls never fall below the fold on any watch size.
        GeometryReader { geo in
            Group {
                switch workout.phase {
                case .unavailable, .denied:
                    grantAccess
                case .idle:
                    idle
                case .requesting:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .active, .paused, .ending:
                    recording
                case .saved:
                    saved
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, 4)
        // The page's one glow: the Effort world, lit while a session is recording.
        .background(WatchGlowBackground(glow: .strain, strength: isRecording ? 0.55 : 0.3))
    }

    private var isRecording: Bool {
        workout.phase == .active || workout.phase == .paused || workout.phase == .ending
    }

    // MARK: Pre-flight states

    /// HealthKit unavailable or workout write denied. Honest about it, with a retry that re-asks (or sends
    /// the user to Settings if the system has already remembered a hard "no").
    private var grantAccess: some View {
        VStack(spacing: 8) {
            PhIcon("heartbeat", size: 24)
                .foregroundStyle(StrandPalette.textTertiary)
            Text("Grant Health access")
                .font(StrandFont.book(14))
                .foregroundStyle(StrandPalette.textPrimary)
            // Condensed so the whole panel clears the fold on a 41mm.
            Text("Live heart rate and energy, recorded on your wrist. Stays on device.")
                .font(StrandFont.light(11))
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
            Button("Allow access") { workout.requestAuthorization() }
                .buttonStyle(WatchPillButtonStyle())
                .frame(height: 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
    }

    /// Ready to record: what it records, and one ink Start.
    private var idle: some View {
        VStack(spacing: 0) {
            PhIcon("barbell", size: 28)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Workout")
                .font(StrandFont.light(22))
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.top, 10)
            Text("Functional strength")
                .font(StrandFont.light(11))
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.top, 2)
            Spacer(minLength: 10)
            Button {
                workout.start()
            } label: {
                HStack(spacing: 6) {
                    PhIcon("play", weight: .fill, size: 12)
                    Text("Start")
                }
            }
            .buttonStyle(WatchPillButtonStyle())
            .frame(height: 38)
        }
        .padding(.top, 18)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Recording

    /// The recording page, top to bottom: the state line, the elapsed clock in the dot face, the live heart
    /// rate, the energy and average under it, and Pause/Resume + End pinned to the bottom so they are always
    /// on screen without scrolling.
    private var recording: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 6).frame(maxHeight: 14)
            Text("Functional strength")
                .font(StrandFont.light(11))
                .foregroundStyle(StrandPalette.textSecondary)
            elapsed
                .padding(.top, 6)
            Spacer(minLength: 6).frame(maxHeight: 12)
            heroHeartRate
            statsRow
                .padding(.top, 8)
            Spacer(minLength: 6)
            controls
                .frame(height: 36)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            WatchLiveDot(color: workout.phase == .paused ? StrandPalette.statusWarning : .white)
            Text(workout.phase == .paused ? String(localized: "PAUSED") : String(localized: "RECORDING"))
                .font(StrandFont.book(12))
                .foregroundStyle(StrandPalette.metricCyan)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var elapsed: some View {
        if workout.phase == .paused {
            // Frozen while paused: builder.elapsedTime freezes on pause, so liveElapsed() reads the same
            // pause-accurate value the active clock last showed — no reliance on the pause event's timing.
            clockText(workout.liveElapsed())
        } else {
            // Elapsed time ticks itself off the session via a TimelineView, so we never run a manual Timer.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                clockText(workout.liveElapsed())
            }
        }
    }

    private func clockText(_ seconds: TimeInterval) -> some View {
        Text(verbatim: Self.clock(seconds))
            .font(StrandFont.dot(30))
            .tracking(30 * 0.02)
            .monospacedDigit()
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    /// The live wrist heart rate. A dash until the first in-session sample lands.
    private var heroHeartRate: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            PhIcon("heart", size: 14)
                .foregroundStyle(StrandPalette.textPrimary)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
            Text(verbatim: workout.bpm.map(String.init) ?? "–")
                .font(StrandFont.light(26))
                .tracking(-0.5)
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("bpm")
                .font(StrandFont.light(11))
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Active energy and the session-average heart rate from the watch's own builder, the watch-native
    /// stand-in for the phone's building Effort. A dash until the builder reports any.
    private var statsRow: some View {
        HStack {
            Text(workout.activeKcal.map { String(localized: "\($0) kcal") } ?? String(localized: "– kcal"))
            Spacer(minLength: 4)
            Text(workout.avgBpm.map { String(localized: "Avg \($0) bpm") } ?? String(localized: "Avg – bpm"))
        }
        .font(StrandFont.light(10))
        .foregroundStyle(StrandPalette.textTertiary)
        .monospacedDigit()
    }

    /// Pause/Resume and End sit SIDE BY SIDE on one row so both are always on screen without scrolling.
    private var controls: some View {
        HStack(spacing: 8) {
            if workout.phase == .paused {
                Button {
                    workout.resume()
                } label: {
                    PhIcon("play", weight: .fill, size: 14)
                }
                .buttonStyle(WatchPillButtonStyle())
                .accessibilityLabel("Resume")
            } else {
                Button {
                    workout.pause()
                } label: {
                    PhIcon("pause", weight: .fill, size: 14)
                }
                .buttonStyle(WatchPillButtonStyle(primary: false))
                .accessibilityLabel("Pause")
            }

            Button(role: .destructive) {
                workout.end()
            } label: {
                PhIcon("stop", weight: .fill, size: 14)
            }
            .buttonStyle(WatchPillButtonStyle(primary: false, tint: StrandPalette.statusCritical))
            .accessibilityLabel("End workout")
            .disabled(workout.phase == .ending)
        }
    }

    // MARK: Saved

    private var saved: some View {
        VStack(spacing: 10) {
            PhIcon("check-circle", weight: .fill, size: 34)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Workout saved")
                .font(StrandFont.light(20))
                .foregroundStyle(StrandPalette.textPrimary)
            // A small honest recap of what we banked. Whole-phrase per shape (no appended tail)
            // so the kcal variant localizes as one string.
            Text(workout.activeKcal.map { String(localized: "\(Self.clock(workout.elapsed)) · \($0) kcal") }
                 ?? Self.clock(workout.elapsed))
                .font(StrandFont.light(11))
                .foregroundStyle(StrandPalette.textSecondary)
            Button("Done") { workout.reset() }
                .buttonStyle(WatchPillButtonStyle())
                .frame(height: 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Helpers

    /// m:ss for short sessions, h:mm:ss once we cross the hour. Whole seconds, monospaced at the call site.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}

// MARK: - WatchWorkoutSession — the HKWorkoutSession + HKLiveWorkoutBuilder engine
//
// Owns the live workout lifecycle on the watch. The view is pure; this object is the only thing that talks
// to HealthKit. Every published value comes from the builder's own statistics (HR / active energy) or the
// session's accumulated duration, so the numbers the wrist shows are the ones HealthKit will save. Nothing
// is invented: a metric stays nil until its first real sample lands and the UI renders a dash for nil.
final class WatchWorkoutSession: NSObject, ObservableObject {

    /// Where we are in the lifecycle. The view switches its whole layout on this.
    enum Phase: Equatable {
        case unavailable   // HealthKit not on this device at all
        case denied        // workout write authorization refused
        case idle          // authorized, ready to start
        case requesting    // auth prompt in flight
        case active        // recording
        case paused        // recording, paused
        case ending        // end() in flight, saving to HealthKit
        case saved         // saved, showing the recap
    }

    @Published private(set) var phase: Phase = .idle
    /// Live wrist heart rate (whole BPM) from the builder, or nil before the first sample.
    @Published private(set) var bpm: Int?
    /// Session-average heart rate so far, or nil before the first sample.
    @Published private(set) var avgBpm: Int?
    /// Active energy burned this session in whole kcal, or nil before the first sample.
    @Published private(set) var activeKcal: Int?
    /// Accumulated session duration. Read live by the view's TimelineView while active.
    @Published private(set) var elapsed: TimeInterval = 0

    #if canImport(HealthKit) && os(watchOS)
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private let hrUnit = HKUnit.count().unitDivided(by: .minute())
    private let kcalUnit = HKUnit.kilocalorie()

    /// What we ask to write: the workout itself plus the two series we surface live. Read-only HR is for the
    /// live readout. Mirrors the phone's "we never invent, we record" stance.
    private var shareTypes: Set<HKSampleType> {
        var set: Set<HKSampleType> = [HKQuantityType.workoutType()]
        if let e = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) { set.insert(e) }
        if let hr = HKQuantityType.quantityType(forIdentifier: .heartRate) { set.insert(hr) }
        return set
    }
    private var readTypes: Set<HKObjectType> {
        var set: Set<HKObjectType> = []
        if let hr = HKQuantityType.quantityType(forIdentifier: .heartRate) { set.insert(hr) }
        if let e = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) { set.insert(e) }
        return set
    }
    #endif

    override init() {
        super.init()
        refreshAvailability()
    }

    /// Decide the initial phase from HealthKit availability and the write status we already hold. We do not
    /// ask for permission here, only on Start or the explicit "Allow access" button, so opening the tab is
    /// quiet (Apple's guidance: prompt at the point of use).
    private func refreshAvailability() {
        #if canImport(HealthKit) && os(watchOS)
        guard HKHealthStore.isHealthDataAvailable() else { phase = .unavailable; return }
        let status = store.authorizationStatus(for: HKQuantityType.workoutType())
        phase = (status == .sharingDenied) ? .denied : .idle
        #else
        phase = .unavailable
        #endif
    }

    /// Explicit auth request (the "Allow access" button). Idempotent; HealthKit no-ops if already decided.
    func requestAuthorization(then start: Bool = false) {
        #if canImport(HealthKit) && os(watchOS)
        guard HKHealthStore.isHealthDataAvailable() else { phase = .unavailable; return }
        phase = .requesting
        store.requestAuthorization(toShare: shareTypes, read: readTypes) { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                // requestAuthorization's `granted` only reports whether the sheet was shown, not the user's
                // choice, so we read the real share status back. Denied write = no workout to save.
                let status = self.store.authorizationStatus(for: HKQuantityType.workoutType())
                if status == .sharingDenied {
                    self.phase = .denied
                } else {
                    self.phase = .idle
                    if start { self.start() }
                }
            }
        }
        #else
        phase = .unavailable
        #endif
    }

    /// Begin recording a generic functional-strength workout indoors. If we have not been authorized yet,
    /// route through the auth prompt first and auto-start on grant.
    func start() {
        #if canImport(HealthKit) && os(watchOS)
        guard HKHealthStore.isHealthDataAvailable() else { phase = .unavailable; return }
        let status = store.authorizationStatus(for: HKQuantityType.workoutType())
        guard status == .sharingAuthorized else {
            requestAuthorization(then: true)
            return
        }

        let config = HKWorkoutConfiguration()
        config.activityType = .functionalStrengthTraining
        config.locationType = .indoor

        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self

            self.session = session
            self.builder = builder

            let begin = Date()
            session.startActivity(with: begin)
            builder.beginCollection(withStart: begin) { [weak self] _, _ in
                // Collection started (or failed silently); the delegate callbacks drive the UI from here.
                DispatchQueue.main.async { self?.phase = .active }
            }
            StrandHaptic.commit.play()  // a firm tap confirms the session is live without looking
        } catch {
            // Could not create the session (rare). Fall back to idle so Start can be tried again.
            phase = .idle
        }
        #else
        phase = .unavailable
        #endif
    }

    func pause() {
        #if canImport(HealthKit) && os(watchOS)
        session?.pause()
        // The session's didChangeTo callback flips us to .paused; haptic there so it matches the real state.
        #endif
    }

    func resume() {
        #if canImport(HealthKit) && os(watchOS)
        session?.resume()
        #endif
    }

    /// Live elapsed time for the ticking clock. `HKLiveWorkoutBuilder.elapsedTime` is pause-aware and
    /// advances continuously while recording — independent of whether samples arrive — so read it live on
    /// each TimelineView tick rather than only in the sample/event callbacks, which left the clock frozen
    /// at 0:00 when no samples landed (loose watch, denied HR-read). Falls back to the last stored value
    /// once the builder is gone (the saved recap, where `elapsed` holds the finalized duration). (@bhelm)
    func liveElapsed() -> TimeInterval {
        #if canImport(HealthKit) && os(watchOS)
        return builder?.elapsedTime ?? elapsed
        #else
        return elapsed
        #endif
    }

    /// Stop the session, finalize collection, and save the workout to HealthKit. The recap appears on save.
    func end() {
        #if canImport(HealthKit) && os(watchOS)
        guard let session, let builder, phase == .active || phase == .paused else { return }
        phase = .ending
        let stop = Date()
        session.stopActivity(with: stop)
        // Freeze the final duration for the recap NOW: the builder is niled below, and the stored `elapsed`
        // was otherwise only ever advanced by sample callbacks — so a sparse-sample session showed a
        // too-short recap. finishWorkout's authoritative HKWorkout.duration overrides it just below. (@bhelm)
        elapsed = builder.elapsedTime
        builder.endCollection(withEnd: stop) { [weak self] _, _ in
            builder.finishWorkout { [weak self] hkWorkout, _ in
                DispatchQueue.main.async {
                    if let duration = hkWorkout?.duration { self?.elapsed = duration }
                    StrandHaptic.success.play()  // milestone: the workout is banked to HealthKit
                    self?.phase = .saved
                    self?.session = nil
                    self?.builder = nil
                }
            }
        }
        #else
        phase = .saved
        #endif
    }

    #if DEBUG
    /// DEBUG-ONLY screenshot aid: a session that reads as mid-recording with nothing behind it (no
    /// HealthKit session, no builder), so the recording page can be screenshotted on a simulator that cannot
    /// start a real workout. Compiled out of release builds.
    static func demoRecording() -> WatchWorkoutSession {
        let demo = WatchWorkoutSession()
        demo.phase = .active
        demo.bpm = 146
        demo.avgBpm = 139
        demo.activeKcal = 312
        demo.elapsed = 1934
        return demo
    }
    #endif

    /// Clear the recap and return to idle so another workout can be started.
    func reset() {
        bpm = nil
        avgBpm = nil
        activeKcal = nil
        elapsed = 0
        refreshAvailability()
    }
}

// MARK: - HealthKit delegates

#if canImport(HealthKit) && os(watchOS)
extension WatchWorkoutSession: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch toState {
            case .running:
                if self.phase != .active { StrandHaptic.selection.play() }
                self.phase = .active
            case .paused:
                self.phase = .paused
                StrandHaptic.light.play()  // soft tap marks the pause landing
            default:
                break
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        // The session died on us. Surface idle so the user can retry rather than sitting on a frozen screen.
        DispatchQueue.main.async { [weak self] in
            self?.phase = .idle
            self?.session = nil
            self?.builder = nil
        }
    }
}

extension WatchWorkoutSession: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // Pause / resume events update the accumulated duration the elapsed readout shows.
        DispatchQueue.main.async { [weak self] in
            self?.elapsed = workoutBuilder.elapsedTime
        }
    }

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                        didCollectDataOf collectedTypes: Set<HKSampleType>) {
        // A new batch of samples landed. Pull the latest HR, the running average HR, and total active
        // energy straight from the builder's own statistics so the wrist shows exactly what HealthKit holds.
        var newBpm: Int?
        var newAvg: Int?
        var newKcal: Int?

        if let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate),
           collectedTypes.contains(hrType),
           let stats = workoutBuilder.statistics(for: hrType) {
            if let recent = stats.mostRecentQuantity()?.doubleValue(for: hrUnit) {
                newBpm = Int(recent.rounded())
            }
            if let avg = stats.averageQuantity()?.doubleValue(for: hrUnit) {
                newAvg = Int(avg.rounded())
            }
        }

        if let eType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
           collectedTypes.contains(eType),
           let stats = workoutBuilder.statistics(for: eType),
           let total = stats.sumQuantity()?.doubleValue(for: kcalUnit) {
            newKcal = Int(total.rounded())
        }

        let elapsedNow = workoutBuilder.elapsedTime
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let newBpm { self.bpm = newBpm }
            if let newAvg { self.avgBpm = newAvg }
            if let newKcal { self.activeKcal = newKcal }
            self.elapsed = elapsedNow
        }
    }
}
#endif
