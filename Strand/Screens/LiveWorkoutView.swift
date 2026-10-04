import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Live workout mode (#238) — the in-exercise screen: a big live heart rate, the current HR zone,
/// elapsed time, and live effort building, all from the SAME live feed and scorers the rest of the
/// app uses (no invented numbers). Presented while a manual workout is active, entered from the
/// Start-workout control on Live. End stops the workout and dismisses.
///
/// Live HR is the smoothed `AppModel.bpm`; the zone is derived from the user's HR-max via the shared
/// `HRZones` model; elapsed time ticks from the workout's start (a TimelineView, no manual Timer);
/// effort is the running `ActiveWorkout.liveStrain` (StrainScorer over the captured window).
struct LiveWorkoutView: View {
    @EnvironmentObject private var model: AppModel
    // PERF (scroll/recompose): this screen deliberately does NOT observe `LiveState` directly. A connected
    // strap publishes `LiveState` ~1 Hz (HR + each R-R packet, plus sensor frames), and an
    // `@EnvironmentObject live` here would invalidate the WHOLE body on every tick — the hero, effort
    // tile, zone card and controls all re-evaluate even though they read from `model` (smoothed bpm +
    // scorers), not `live`. The only region that genuinely needs `live` is the additive sensor readout
    // (speed / cadence / power), so it's extracted into the small `SensorRowIfPresent` leaf below that
    // owns its OWN `@EnvironmentObject live`. A sensor/R-R packet now re-renders just that row, not the
    // hero. (`model.live` is its own ObservableObject, so the leaf's `live` is the one that sees the
    // @Published changes — exactly as the parent's direct observation did before.)
    let onClose: () -> Void

    /// Effort display scale (#268) — routes the live Effort read-out through the shared helper so it
    /// matches every other surface. Display-only; the captured value stays stored 0–100.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// Keep the screen awake while recording (#703). Opt-in, default off; the toggle lives in Settings.
    /// Read here so we can hold the idle timer off only while this in-exercise screen is up and release it
    /// the moment it leaves, which is exactly the bounded usage Apple asks for. iOS-only (no-op on Mac).
    @AppStorage("workoutKeepScreenOn") private var keepScreenOn = false

    /// Guards the destructive End action behind a confirm (#517) — a stray tap must not end the workout
    /// instantly with no way back.
    @State private var showEndConfirm = false
    @State private var showDeleteConfirm = false

    private var zoneSet: HRZoneSet { model.profile.hrZoneSet }
    private var zone: Int { model.bpm.map { zoneSet.zoneNumber(forBPM: Double($0)) } ?? 0 }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    hero(topInset: geo.safeAreaInsets.top)
                    Group {
                        HStack(alignment: .top, spacing: NoopMetrics.gap) {
                            heartRateTile
                            effortTile
                        }
                        .padding(.top, 4)
                        zoneCard
                        // Live-observing leaf: renders the sensor card only when a standard fitness sensor
                        // is feeding metrics, refreshing on its own packets without re-rendering the hero.
                        SensorRowIfPresent()
                        controls.padding(.top, 12)
                    }
                    .padding(.horizontal, NoopMetrics.screenHPadding)
                }
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .ignoresSafeArea(edges: .top)
            #if os(iOS)
            // #697/#horizontal-swipe parity, see ScreenScaffold. This is the full-screen in-exercise
            // tracker, up for the whole workout, so worth the same defensive fix.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            #if os(iOS) && DEBUG
            .modifier(DemoScrollAnchor())
            #endif
        }
        .background(NoopVisualStyle.canvas.ignoresSafeArea())
        .noopHidesTabBar()
        .noopHidesSystemNavBar()
        // If the workout ended elsewhere (process restart cleared it), close the screen.
        .onChangeCompat(of: model.activeWorkout == nil) { gone in if gone { onClose() } }
        // Arm the realtime HR stream while the in-exercise screen is up (#681). On a WHOOP 5/MG live HR
        // only flows while the puffin realtime stream is armed; previously only the Live tab armed it, so
        // starting a manual workout straight from Workouts (Live never opened) left `model.bpm == nil` —
        // captureWorkoutSample bailed on every sample and endWorkout silently discarded the empty
        // session. Ref-counted in AppModel, so when this screen sits over an already-armed Live tab the
        // two balance and neither disarms the other (mirrors Android LiveWorkoutScreen's DisposableEffect
        // requestRealtimeHr/releaseRealtimeHr). Balanced: one start on appear, one stop on disappear.
        .onAppear {
            model.startRealtimeHR()
            // Hold the display awake for the session only if the user opted in (#703).
            if keepScreenOn { ScreenIdle.keepAwake(true) }
        }
        .onDisappear {
            model.stopRealtimeHR()
            // Always release on the way out so the system idle timer resumes. Even if the toggle was
            // flipped off mid-workout, this clears any hold we placed.
            ScreenIdle.keepAwake(false)
        }
        // Confirm before ending (#517): ending still requires an explicit confirm so a stray tap cannot
        // discard the in-progress recording with no way back.
        .alert("End this workout?",
               isPresented: $showEndConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("End", role: .destructive) {
                model.endWorkout()
                onClose()
            }
        } message: {
            Text("This stops recording and saves what's captured so far. It can't be resumed.")
        }
        .confirmationDialog("Delete", isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.discardWorkout()
                onClose()
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Hero

    /// The effort-glow hero, bleeding under the status bar: the close control and the recording state,
    /// the elapsed clock in the dot-matrix face, and the session totals.
    private func hero(topInset: CGFloat) -> some View {
        NoopHeroCard(glow: .strain, padding: 0, bleed: true) {
            VStack(spacing: 0) {
                header
                elapsedClock.padding(.top, 64)
                startedCaption.padding(.top, 14)
                LiveWorkoutHeroTotals(recorder: model.gpsRecorder, peakHr: model.activeWorkout?.peakHr ?? 0,
                                      kcal: liveCalories)
                    .padding(.top, 62)
            }
            .padding(.horizontal, 20)
            .padding(.top, topInset + 6)
            .padding(.bottom, 30)
        }
    }

    private var header: some View {
        HStack {
            // Closing only hides the screen; the workout keeps recording and Live / Workouts re-open it.
            Button(action: onClose) {
                PhIcon("caret-down", size: 18)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.white.opacity(0.07)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(LTPressStyle())
            .accessibilityLabel(Text("Close"))
            .accessibilityHint(Text("The workout keeps recording"))
            Spacer(minLength: 8)
            recordingLabel
            Spacer(minLength: 8)
            // Balances the close control so the recording label stays centred.
            Color.clear.frame(width: 42, height: 42)
        }
    }

    /// "● RECORDING WORKOUT · RUN"; where that does not fit between the header circles (German), the
    /// shorter "RECORDING" rather than a truncated word.
    private var recordingLabel: some View {
        ViewThatFits(in: .horizontal) {
            recordingLabel(short: false)
            recordingLabel(short: true)
        }
    }

    private func recordingLabel(short: Bool) -> some View {
        let paused = model.activeWorkout?.isPaused == true
        let sport = model.activeWorkout?.sport ?? ""
        return HStack(spacing: 8) {
            Circle().fill(paused ? StrandPalette.textTertiary : Color.white)
                .frame(width: 7, height: 7)
                .shadow(color: .white.opacity(paused ? 0 : 0.9), radius: 5)
            Group {
                if paused { Text("Paused") } else if short { Text("Recording") } else { Text("Recording workout") }
            }
            .lineLimit(1)
            if !sport.isEmpty {
                Text(verbatim: "·")
                Text(verbatim: SportName.display(sport)).lineLimit(1)
            }
        }
        .font(StrandFont.overline)
        .tracking(StrandFont.overlineTracking)
        .textCase(.uppercase)
        .foregroundStyle(Color.white.opacity(0.8))
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
    }

    /// The elapsed clock — the shared pause-aware clock, ticking once a second.
    private var elapsedClock: some View {
        Group {
            if let workout = model.activeWorkout {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(verbatim: Self.elapsed(seconds: workout.elapsed()))
                        .font(StrandFont.dot(66))
                        .tracking(66 * 0.02)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                }
                .accessibilityLabel(Text("Elapsed time"))
                .accessibilityValue(Text(verbatim: Self.elapsed(seconds: workout.elapsed())))
            } else {
                Text(verbatim: "—").font(StrandFont.dot(66))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var startedCaption: some View {
        let started = model.activeWorkout?.start.formatted(date: .omitted, time: .shortened) ?? "—"
        return Text("Elapsed · started \(started)")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Tiles

    private var heartRateTile: some View {
        let avg = model.activeWorkout?.avgHr ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            tileOverline("Heart rate", icon: "heartbeat")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: model.bpm.map { "\($0)" } ?? "—")
                    .font(StrandFont.value(38, weight: 300))
                    .tracking(-1.1)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .contentTransition(.numericText())
                Text("bpm").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
            .padding(.top, 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.bpm.map { "Heart rate \($0) beats per minute" } ?? "Heart rate not available")
            HStack(spacing: 6) {
                if zone >= 1 {
                    NoopTag("ZONE \(zone)", size: 10)
                } else {
                    NoopTag("Below Zone 1", size: 10)
                }
                if avg > 0 {
                    Text("Avg \(avg)").lineLimit(1)
                }
            }
            .font(StrandFont.light(10.5))
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.top, 8)
        }
        .ltCard(padding: 16)
    }

    /// Same `liveStrain` / Effort-scale conversion and `StrainGauge` intensity label as before; the bars
    /// are a seven-step level meter of the same fraction, the current step in the effort accent.
    private var effortTile: some View {
        let strain = model.activeWorkout?.liveStrain ?? 0
        let displayEffort = UnitFormatter.effortValue(strain, scale: effortScale)
        let maxValue = effortScale == .whoop ? 21.0 : 100.0
        let fraction = min(max(displayEffort / maxValue, 0), 1)
        // VoiceOver needs the selected scale maximum (0–21 / 0–100) even though the visible denominator
        // is a caption. Reuse the same localized "of %@" caption as Today / Week-in-review.
        let valueText = effortScale == .whoop
            ? String(format: "%.1f", displayEffort)
            : "\(Int(displayEffort.rounded()))"
        let scaleCaption = String(localized: "of \(UnitFormatter.effortScaleMax(effortScale))")
        let stateLabel = StrainGauge.stateLabel(forFraction: fraction)
        return VStack(alignment: .leading, spacing: 0) {
            tileOverline("Effort", icon: "fire")
            HStack(alignment: .bottom) {
                Text(verbatim: valueText)
                    .font(StrandFont.value(38, weight: 300))
                    .tracking(-1.1)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .contentTransition(.numericText())
                Spacer(minLength: 6)
                EffortLevelBars(fraction: fraction)
                    .frame(width: 66, height: 30)
            }
            .padding(.top, 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(String(localized: "Effort")) \(valueText) \(scaleCaption)")
            .accessibilityValue(Text(stateLabel))
            HStack(spacing: 6) {
                NoopTag(verbatim: stateLabel, size: 10)
                Text(verbatim: scaleCaption).lineLimit(1)
            }
            .font(StrandFont.light(10.5))
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.top, 8)
        }
        .ltCard(padding: 16)
    }

    private func tileOverline(_ title: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 6) {
            PhIcon(icon, size: 14)
            Text(title)
        }
        .font(StrandFont.overline)
        .tracking(StrandFont.overlineTracking)
        .textCase(.uppercase)
        .foregroundStyle(StrandPalette.textTertiary)
    }

    // MARK: - Zone card

    /// Time in each zone for this session as a proportional strip (current zone ringed), the current
    /// zone's band and minutes, and the per-zone minutes.
    private var zoneCard: some View {
        let samples = model.activeWorkout?.samples ?? []
        let tiz = HRZones.timeInZone(samples, zoneSet: zoneSet)
        let minutes = (1...5).map { Int((tiz.seconds(inZone: $0) / 60).rounded()) }
        return VStack(alignment: .leading, spacing: 0) {
            NoopCardHeader("HR zone", caption: String(localized: "Max \(Int(zoneSet.maxHR.rounded())) bpm"))
            ZoneStrip(minutes: minutes, current: zone)
                .frame(height: 34)
                .padding(.top, 16)
            HStack(alignment: .firstTextBaseline) {
                Group {
                    if let band = zoneSet.zones.first(where: { $0.number == zone }) {
                        Text("Zone \(zone): \(Int(band.lower))–\(Int(band.upper)) bpm · \(minutes[zone - 1]) min")
                    } else {
                        Text("Warming up. Keep moving to climb into Zone 1.")
                    }
                }
                .font(StrandFont.book(13, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(verbatim: minutes.map(String.init).joined(separator: " · ") + " " + String(localized: "min"))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .accessibilityLabel(Text("Minutes in zones 1 to 5"))
                    .accessibilityValue(Text(verbatim: minutes.map(String.init).joined(separator: ", ")))
            }
            .padding(.top, 12)
        }
        .ltCard()
    }

    // MARK: - Controls

    private var controls: some View {
        let paused = model.activeWorkout?.isPaused == true
        return VStack(spacing: 18) {
            HStack(spacing: 10) {
                LTActionButton(paused ? "Resume" : "Pause", icon: paused ? "play" : "pause") {
                    model.toggleWorkoutPause()
                }
                LTActionButton("End workout", icon: "stop", kind: .primary) {
                    showEndConfirm = true
                }
                .accessibilityHint(Text("Stops recording and saves what's captured so far"))
            }
            Button { showDeleteConfirm = true } label: {
                Text("Delete")
                    .font(StrandFont.light(13))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Helpers

    /// The running calorie estimate over the captured HR window, with the same model and inputs
    /// `endWorkout` saves (Keytel / Harris–Benedict, measured resting HR), so the figure on screen is the
    /// one the saved workout will carry. nil until two samples exist.
    private var liveCalories: Double? {
        guard let samples = model.activeWorkout?.samples, samples.count >= 2 else { return nil }
        let profile = model.profile
        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex)
        let restingHR = model.repo.today?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
        let kcal = Calories.estimateBoutCalories(samples, profile: up, hrmax: Double(profile.hrMax),
                                                 restingHR: restingHR).0
        return kcal > 0 ? kcal : nil
    }

    /// Delegates to the shared clock. This carried its own `%d:%02d` with NO hour roll-over, so a
    /// 90-minute session read "90:00" here while Android's live workout screen read "1:30:00" — and,
    /// after the card fix, while the iOS card that opens THIS screen read "1:30:00" too. The math was
    /// already pause-aware (`workout.elapsed()`); only the formatting was the odd one out.
    private static func elapsed(seconds: TimeInterval) -> String {
        ActiveWorkoutClock.clock(Int(seconds))
    }

    /// The HR-zone name the live screens show beside the zone number (shared with the Live hero).
    static func zoneName(_ zone: Int) -> String {
        switch zone {
        case 1: return String(localized: "Recovery")
        case 2: return String(localized: "Fat burn")
        case 3: return String(localized: "Aerobic")
        case 4: return String(localized: "Threshold")
        case 5: return String(localized: "Maximum")
        default: return ""
        }
    }
}

/// The session's time in each zone as one strip of five segments whose widths follow the minutes (with a
/// floor so every label stays legible); the current zone is ringed in white.
private struct ZoneStrip: View {
    let minutes: [Int]
    let current: Int

    var body: some View {
        GeometryReader { geo in
            let weights = minutes.map { CGFloat(max($0, 2)) }
            let total = weights.reduce(0, +)
            let usable = max(0, geo.size.width - 4 * 4)
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { z in
                    let on = z == current
                    Text(verbatim: "Z\(z)")
                        .font(StrandFont.book(11))
                        .foregroundStyle(on ? Color.white : Color.white.opacity(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: usable * weights[z - 1] / total, height: geo.size.height)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(NoopVisualStyle.zoneFill(z)))
                        .overlay {
                            if on {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.white, lineWidth: 1.5)
                            }
                        }
                        .shadow(color: .white.opacity(on ? 0.18 : 0), radius: 9)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A seven-step level meter for the live effort: steps below the current one in grey, the current step
/// in the effort accent, the rest faint.
private struct EffortLevelBars: View {
    let fraction: Double

    var body: some View {
        let current = min(6, Int(fraction * 7))
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<7, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(i == current ? NoopGlow.strain.accent
                          : i < current ? NoopGlow.ink.deep : NoopGlow.ink.deep.opacity(0.45))
                    .frame(height: 6 + CGFloat(i) * 4)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Presents the in-exercise screen: full screen on iPhone (it is the whole display for the session, closed
/// with its own control), a sheet on the Mac.
extension View {
    @ViewBuilder
    func liveWorkoutCover<Content: View>(isPresented: Binding<Bool>,
                                         @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }
}

// MARK: - Live-observing leaves (scroll-stutter isolation)

/// Additive readout for a connected standard fitness sensor (a footpod / bike speed-cadence sensor /
/// power meter) feeding RSC/CSC/CPS ALONGSIDE heart rate. Only the fields the sensor actually sent
/// render — each metric is dropped when its value is absent, and the WHOLE card is hidden when nothing is
/// present (`live.hasSensorMetrics`), so a plain HR-only workout looks exactly as before. Speed follows the
/// exercise-distance preference; cadence stays per-minute and power in watts. Nothing here touches HR /
/// zone / effort.
///
/// This is a standalone leaf that owns its OWN `@EnvironmentObject live` (the parent `LiveWorkoutView`
/// does not observe `LiveState`), so an incoming sensor / R-R packet re-renders only this card, not the
/// hero / effort tile / zone card above.
private struct SensorRowIfPresent: View {
    @EnvironmentObject private var live: LiveState
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(
            system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
            override: distanceSystemRaw)
    }

    var body: some View {
        if live.hasSensorMetrics {
            let speed = UnitFormatter.speedFromKilometersPerHour(
                live.sensorSpeedKmh, system: distanceUnitSystem)
            let cadence = LiveState.formatCadence(live.sensorCadence)
            let power = LiveState.formatPowerWatts(live.sensorPowerWatts)
            VStack(alignment: .leading, spacing: 14) {
                NoopCardHeader("Sensor", icon: "speedometer")
                NoopMetricRow {
                    if let speed { NoopMetric(value: speed, label: "Speed") }
                    if let cadence { NoopMetric(value: "\(cadence)", unit: "/min", label: "Cadence") }
                    if let power { NoopMetric(value: "\(power)", unit: "W", label: "Power") }
                }
            }
            .ltCard()
        }
    }
}

/// The hero's session totals: live GPS distance and average pace for a distance sport (#1195), the peak
/// heart rate otherwise, and the running calorie estimate.
///
/// A standalone leaf that owns its OWN `@ObservedObject` on the recorder (the parent `LiveWorkoutView`
/// does not observe it), so a GPS fix re-renders only these figures. The GPS pair self-gates until the
/// first accepted fix, so a denied-permission or GPS-less (Mac) session shows the heart-rate pair instead
/// of empty distance. Mirrors Android's gated distance/pace row in `LiveWorkoutScreen`.
private struct LiveWorkoutHeroTotals: View {
    @ObservedObject var recorder: GpsWorkoutRecorder
    let peakHr: Int
    let kcal: Double?
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(
            system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
            override: distanceSystemRaw)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // `isRecording` is essential, not just `pointCount > 0`: the recorder is a single long-lived
            // object and `stop()` leaves `pointCount`/`distanceM` intact (only `start()` resets them, and it
            // runs solely for distance sports). Without the `isRecording` guard a non-GPS workout started
            // after a GPS one would show the previous session's stale distance. Together they mean "a GPS
            // recording is live AND has at least one accepted fix" — the Android `gpsEnabled && track` twin.
            if recorder.isRecording, recorder.pointCount > 0 {
                total(UnitFormatter.distanceFromMeters(recorder.distanceM, system: distanceUnitSystem),
                      label: "Distance")
                total(UnitFormatter.paceFromSecPerKm(recorder.paceSecPerKm, system: distanceUnitSystem),
                      label: "Avg pace")
            } else {
                total(peakHr > 0 ? "\(peakHr) bpm" : "—", label: "Peak heart rate")
            }
            total(kcal.map { "\(Int($0.rounded())) kcal" } ?? "—", label: "Calories")
        }
    }

    /// One centred total. The formatted string ("5.1 km", "6:18 /km") is split at its first space so the
    /// unit can sit small beside the figure, as the kit's metric does.
    private func total(_ formatted: String, label: LocalizedStringKey) -> some View {
        let parts = formatted.split(separator: " ", maxSplits: 1).map(String.init)
        return VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: parts.first ?? formatted)
                    .font(StrandFont.value(21))
                    .tracking(-0.4)
                    .foregroundStyle(StrandPalette.textPrimary)
                if parts.count > 1 {
                    Text(verbatim: parts[1])
                        .font(StrandFont.book(10))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text(label)
                .font(StrandFont.light(10.5))
                .foregroundStyle(Color.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
