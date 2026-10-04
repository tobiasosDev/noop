import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandImport
import WhoopStore
import Foundation
#if canImport(MapKit)
import MapKit
#endif

// MARK: - Workout detail (#410)
//
// A READ-ONLY drill-down for one tapped session (v2): the sport and when, the session Effort on the one
// effort glow, the session figures, the GPS route when one was recorded on-device (#524), the HR curve on
// its zone bands, the zone minutes (imported when the row carries them, else derived from the strap's
// raw HR and labelled approximate), and the heart-rate recovery after the session (#516).
//
// Presented as a `.sheet` wrapped in a NavigationStack by WorkoutsView; the header's back circle closes it.

struct WorkoutDetailView: View {
    let row: WorkoutRow

    #if DEBUG
    /// Screenshot harness only: when the seeded store has no HR for the window, draw a synthetic curve
    /// and recovery so the charts can be checked. Never set in the app.
    var demoSyntheticHR = false
    #endif

    @EnvironmentObject private var repo: Repository
    @StateObject private var profile = ProfileStore()
    @Environment(\.dismiss) private var dismiss

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(
            system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
            override: distanceSystemRaw)
    }

    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// Loaded HR curve over the session window (5-min-ish bucket means). Empty until loaded.
    @State private var hrPoints: [TrendPoint] = []
    /// Per-zone MINUTES for the zones bar: imported zones (duration-weighted) when present, else the
    /// window's raw HR samples binned into age-derived %HRmax zones. nil = no zone split to show.
    @State private var zoneMinutes: [Double]? = nil
    /// True when the zones bar came from imported WHOOP percentages (vs derived from raw strap HR).
    @State private var zonesFromImport = false
    @State private var loaded = false
    /// #516: computed from the recorded workout-end + post-workout HR window. nil when the workout was
    /// not intense enough or the strap did not record enough post-workout coverage.
    @State private var heartRateRecovery: HeartRateRecovery.Result?

    /// The GPS route captured for this session on-device (#524), if any. Decoded from `RouteStore` by the
    /// row's natural key. nil = no route was recorded (honest — the map only shows when points exist).
    @State private var route: [RouteMath.LatLng] = []

    /// Drives the GPX/FIT export chooser for the recorded route.
    @State private var showRouteExport = false

    /// Steps over the session window for an on-foot sport (#398): the count plus whether it came from the
    /// strap's own counter (MG/5.0) or the phone pedometer (fallback for WHOOP 4.0 / not-yet-synced / CSV
    /// import). nil = not an on-foot sport, or no step source had data for the window.
    private struct StepReadout { let count: Int; let fromStrap: Bool }
    @State private var steps: StepReadout?

    var body: some View {
        ScreenScaffold(title: nil,
                       // PERF: chart/map-heavy column (a MapKit route map, the session HR curve, the zone
                       // split and the recovery curve). The LazyVStack path builds the off-screen ones on
                       // demand — byte-identical layout — so a tall detail doesn't materialise the map + the
                       // charts before the header is even on screen.
                       lazy: Self.lazyColumn) {
            NoopScreenHeader(verbatim: "") { headerControls }
            titleBlock
            if let strain = row.strain {
                effortHero(strain: strain)
            }
            statGrid
            routeSection
            hrCurveSection
            zonesSection
            heartRateRecoverySection
        }
        .noopHidesSystemNavBar()
        .task { await load() }
    }

    /// The lazy column (see `body`). The DEBUG screenshot harness turns it off when it anchors the scroll
    /// mid-screen, where a lazy stack has not realised the rows it is asked to show yet.
    private static var lazyColumn: Bool {
        #if DEBUG
        return !CommandLine.arguments.contains("--demo-anchor")
        #else
        return true
        #endif
    }

    // MARK: - Header

    /// The route export (when this session recorded one). The back circle is the header's own.
    @ViewBuilder private var headerControls: some View {
        if route.count >= 2 {
            NoopCircleButton("export", accessibilityLabel: "Export route") { showRouteExport = true }
                .confirmationDialog("Export route", isPresented: $showRouteExport, titleVisibility: .visible) {
                    Button("GPX — Strava, Garmin, most apps") { exportRoute(.gpx) }
                    Button("FIT — Garmin Connect") { exportRoute(.fit) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Save this route as a standard file you can import into Strava, Garmin Connect, and other apps.")
                }
        }
    }

    /// The sport glyph tile, the sport as the title, and "Fri 2 Oct · 07:12 · 52 min".
    private var titleBlock: some View {
        HStack(spacing: 14) {
            WorkoutTypeIcon(workoutType: row.sport, size: 22, weight: .light)
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(NoopVisualStyle.raised))
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: SportName.display(row.sport))
                    .font(StrandFont.title1)
                    .tracking(-0.56)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: subtitle)
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.bottom, 8)
    }

    /// "Fri 2 Oct · 07:12–08:04 · 52 min".
    private var subtitle: String {
        var parts = [Date(timeIntervalSince1970: TimeInterval(row.startTs))
                        .formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
                     timeRangeLabel(row.startTs, row.endTs)]
        if let d = row.durationS, d > 0 { parts.append(durationLabel(d)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Effort hero

    /// The session's Effort contribution on the effort glow: the value in the dot-matrix face with its
    /// intensity word, and where it sits on the full Light → All-out scale.
    private func effortHero(strain: Double) -> some View {
        let displayValue = UnitFormatter.effortValue(strain, scale: effortScale)
        let scaleMax: Double = effortScale == .whoop ? 21 : 100
        let fraction = max(0, min(1, displayValue / scaleMax))
        let ticks: [Double] = [0, 0.25, 0.5, 0.75, 1]
        return NoopHeroCard(glow: .strain, padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge("Effort", icon: "fire")
                    Spacer(minLength: 8)
                    NoopPill(verbatim: heroPillLabel, compact: true)
                }
                HStack(alignment: .bottom, spacing: 14) {
                    Text(verbatim: UnitFormatter.effortDisplay(strain, scale: effortScale))
                        .font(StrandFont.dot(104))
                        .tracking(StrandFont.dotTracking(104))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    VStack(alignment: .leading, spacing: 8) {
                        NoopTag(verbatim: StrainGauge.stateLabel(forFraction: fraction))
                        Text(effortScale == .whoop ? "of 21" : "of 100")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .padding(.bottom, 12)
                }
                .padding(.top, 26)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Effort \(UnitFormatter.effortDisplay(strain, scale: effortScale)) \(effortScale == .whoop ? "of 21" : "of 100")"))
                HStack {
                    Text("Light")
                    Spacer()
                    Text("All-out")
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.top, 22)
                NoopTickScale(marker: fraction)
                    .padding(.top, 10)
                GeometryReader { geo in
                    ForEach(ticks, id: \.self) { t in
                        Text(verbatim: scaleMax == 21 ? String(format: "%.0f", 21 * t) : "\(Int(100 * t))")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize()
                            .position(x: min(max(geo.size.width * t, 6), geo.size.width - 10), y: 7)
                    }
                }
                .frame(height: 14)
                .padding(.top, 6)
                .accessibilityHidden(true)
                Text("This session's contribution to the day's Effort, as captured during the workout.")
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.84))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
            .padding(.bottom, 2)
        }
    }

    /// Where the session came from, and whether it carries a route ("Whoop", "Manual · GPS").
    private var heroPillLabel: String {
        let source = sourceLabel(row.source)
        return route.count >= 2 ? source + " · GPS" : source
    }

    // MARK: - Stat grid

    /// Duration, average and max HR, calories, distance (when recorded) and steps (on-foot sports) as
    /// small three-up cards.
    private var statGrid: some View {
        var stats: [(value: String, unit: String?, label: LocalizedStringKey)] = [
            (row.durationS.map { ActiveWorkoutClock.clock(Int($0.rounded())) } ?? "–", nil, "Duration"),
            (row.avgHr.map { "\($0)" } ?? "–", row.avgHr != nil ? "bpm" : nil, "Avg HR"),
            (row.maxHr.map { "\($0)" } ?? "–", row.maxHr != nil ? "bpm" : nil, "Max HR"),
            (row.energyKcal.map { grouped($0) } ?? "–", row.energyKcal != nil ? "kcal" : nil, "Calories"),
        ]
        if let m = row.distanceM, m > 0 {
            let parts = distanceLabel(m).split(separator: " ", maxSplits: 1).map(String.init)
            stats.append((parts.first ?? "–", parts.count > 1 ? parts[1] : nil, "Distance"))
        }
        // Steps for an on-foot sport (#398). Shown for the on-foot set even before the value lands, so the
        // card doesn't pop in; "–" until a source has data. The label is honest about the source.
        if WorkoutCatalog.isOnFoot(row.sport) {
            let stepsLabel: LocalizedStringKey
            if let steps { stepsLabel = steps.fromStrap ? "Steps · strap" : "Steps · phone" } else { stepsLabel = "Steps" }
            stats.append((steps.map { grouped(Double($0.count)) } ?? "–", nil, stepsLabel))
        }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, s in
                NoopMetric(value: s.value, unit: s.unit, label: s.label)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .noopPanel(cornerRadius: 22)
            }
        }
    }

    // MARK: - GPS route (#524)

    /// The captured-route card: a MapKit map of the polyline with start/end markers, the export chips and
    /// where the route came from. Shown ONLY when ≥2 points were captured — honest "no map" otherwise (a
    /// Mac with no GPS, denied permission, or a non-distance sport never produce a route).
    @ViewBuilder private var routeSection: some View {
        if route.count >= 2 {
            NoopSectionTitle("Route") {
                Text(verbatim: [distanceLabel(row.distanceM), paceLabel].filter { $0 != "–" }.joined(separator: " · "))
            }
            VStack(alignment: .leading, spacing: 0) {
                WorkoutRouteMap(points: route)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                    .accessibilityLabel(routeAccessibilityLabel)
                HStack(spacing: 8) {
                    Text(routeOriginLabel)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer(minLength: 8)
                    Button { exportRoute(.gpx) } label: { NoopChip(verbatim: "GPX", icon: "download-simple") }
                        .buttonStyle(LTPressStyle())
                        .accessibilityLabel(Text("GPX — Strava, Garmin, most apps"))
                    Button { exportRoute(.fit) } label: { NoopChip(verbatim: "FIT", icon: "download-simple") }
                        .buttonStyle(LTPressStyle())
                        .accessibilityLabel(Text("FIT — Garmin Connect"))
                }
                .padding(.horizontal, 4)
                .padding(.top, 14)
                Text(routeDescription)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 10)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .noopPanel()
        }
    }

    // MARK: - HR curve

    @ViewBuilder private var hrCurveSection: some View {
        if hrPoints.count > 1 {
            let values = hrPoints.map(\.value)
            NoopSectionTitle("Heart rate") { Text(verbatim: hrCaption(values)) }
            VStack(alignment: .leading, spacing: 8) {
                WorkoutHRCurve(points: hrPoints, zoneSet: profile.hrZoneSet)
                    .frame(height: 176)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "Heart rate during \(SportName.display(row.sport))"))
                    .accessibilityValue(Text(verbatim: hrCaption(values)
                        + " · " + String(localized: "\(Int((values.min() ?? 0).rounded())) bpm")))
                // #18: the row's Avg HR can be EDITED on the manual sheet while the graph, zones and Effort
                // stay from the recorded session (preservingCaptured keeps the captured strain/zones). When
                // the typed average disagrees materially with this trace's own mean AND the row carries that
                // captured strain/zones, say so plainly. We do NOT re-score from the typed number.
                if avgHrEditedDisclosure(traceMean: values.reduce(0, +) / Double(values.count)) {
                    Text("The average above was edited. The graph, zones and Effort stay from the recorded session.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }
            .ltCard()
        } else if loaded {
            NoopSectionTitle("Heart rate")
            NoopInsightRow("No heart-rate samples were recorded over this session's window.", icon: "heartbeat")
                .ltCard()
        }
    }

    /// "Avg 148 · max 176 bpm" — the row's own figures, falling back to the trace's peak.
    private func hrCaption(_ values: [Double]) -> String {
        let peak = row.maxHr ?? Int((values.max() ?? 0).rounded())
        if let avg = row.avgHr { return String(localized: "Avg \(avg) · max \(peak) bpm") }
        return String(localized: "Max \(peak) bpm")
    }

    /// #18: whether the displayed Avg HR was edited away from what this HR trace implies. True only when the
    /// row carries CAPTURED strain or zones (so the graph/zones/Effort are from a real recording, not the
    /// typed value) AND the row's avgHr differs from the trace mean by more than a small tolerance. The
    /// tolerance absorbs ordinary rounding/bucketing drift so an unedited session never trips the note.
    private func avgHrEditedDisclosure(traceMean: Double) -> Bool {
        guard let avg = row.avgHr, row.strain != nil || row.zonesJSON != nil else { return false }
        return abs(Double(avg) - traceMean) > 3
    }

    // MARK: - HR zones

    @ViewBuilder private var zonesSection: some View {
        if let z = zoneMinutes, z.reduce(0, +) > 0 {
            let total = z.reduce(0, +)
            let maxMin = max(z.max() ?? 1, 0.001)
            NoopSectionTitle("HR zones") { Text(verbatim: durationLabel(total * 60)) }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(0..<5, id: \.self) { i in
                    HStack(spacing: 12) {
                        ZoneLabelColumn(zone: i + 1)
                        NoopTrack(fraction: z[i] / maxMin, height: 12,
                                  fill: [NoopVisualStyle.zoneFill(i + 1), NoopVisualStyle.zoneFill(i + 1)])
                        Text(verbatim: durationLabel(z[i] * 60))
                            .font(StrandFont.book(13, relativeTo: .subheadline))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(width: 54, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(Text(verbatim: "\(Int((z[i] / total * 100).rounded())) %"))
                }
                Text(zonesFromImport
                     ? "WHOOP's imported per-zone split for this session."
                     : "Time in each %HRmax zone, derived from the strap's heart rate over this window (approximate).")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .ltCard()
        }
    }

    // MARK: - Heart-rate recovery (#516)

    @ViewBuilder private var heartRateRecoverySection: some View {
        if let recovery = heartRateRecovery {
            NoopSectionTitle("Heart rate recovery", captionKey: "After you stopped")
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(verbatim: recovery.after1Minute.map { Self.signedDrop($0) } ?? "–")
                        .font(StrandFont.dot(50))
                        .tracking(StrandFont.dotTracking(50))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("bpm in 1 min").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(recoveryAccessibility(String(localized: "1 min"), recovery.after1Minute))
                RecoveryCurve(recovery: recovery)
                    .frame(height: 56)
                    .padding(.top, 16)
                HStack {
                    Text(verbatim: String(localized: "Stop · \(recovery.endHR)"))
                    Spacer()
                    if let a1 = recovery.after1Minute {
                        Text(verbatim: String(localized: "1 min · \(recovery.endHR - a1)"))
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Spacer()
                    if let a5 = recovery.after5Minutes {
                        Text(verbatim: String(localized: "5 min · \(recovery.endHR - a5)"))
                    }
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.top, 6)
                .accessibilityHidden(true)
                NoopMetricRow {
                    NoopMetric(value: recovery.after2Minutes.map { Self.signedDrop($0) } ?? "–", unit: "bpm",
                               label: "After 2 min")
                    NoopMetric(value: recovery.after5Minutes.map { Self.signedDrop($0) } ?? "–", unit: "bpm",
                               label: "After 5 min")
                    NoopMetric(value: repo.today?.restingHr.map { "\($0)" } ?? "–", unit: "bpm",
                               label: "Resting HR today")
                }
                .padding(.top, 14)
                .overlay(alignment: .top) { LTHairline() }
                .padding(.top, 16)
                Text("The change from your heart rate when you stopped. A dash means the strap did not record enough data around that minute.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
            .ltCard()
        }
    }

    /// A recovery figure as the signed change: a fall of 31 bpm reads "−31".
    private static func signedDrop(_ drop: Int) -> String {
        drop > 0 ? "\u{2212}\(drop)" : (drop == 0 ? "0" : "+\(-drop)")
    }

    private func recoveryAccessibility(_ label: String, _ value: Int?) -> String {
        value.map { String(localized: "Heart rate recovery at \(label), \($0) beats per minute") }
            ?? String(localized: "Heart rate recovery at \(label), not available")
    }

    // MARK: - Bits

    private func sourceLabel(_ source: String) -> String {
        switch WorkoutSource.classify(source) {
        case .whoop:        return String(localized: "Whoop")
        case .apple:        return String(localized: "Apple")
        case .detected:     return String(localized: "Detected")
        case .manual:       return String(localized: "Manual")
        case .lifting:      return String(localized: "Lifting")
        case .activityFile: return String(localized: "File")
        }
    }

    // MARK: - Load

    private func load() async {
        // #524: the GPS route, if this session recorded one on-device. A cheap UserDefaults read keyed
        // by the row's natural key (startTs + sport); decoded to points only when ≥2 were captured so the
        // map only ever draws a real route.
        let routePoints: [RouteMath.LatLng] = {
            guard let r = RouteStore.load(startTs: row.startTs, sport: row.sport) else { return [] }
            let pts = RouteMath.decode(r.polyline)
            return pts.count >= 2 ? pts : []
        }()

        // HR curve over the exact session window — a finer bucket than the 24h chart so a short run
        // still reads as a curve, not a handful of points.
        let buckets = await repo.workoutHrBuckets(from: row.startTs, to: row.endTs, source: row.source)
        let bucketPoints = buckets.map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }

        // Zones: prefer the imported per-workout percentages (a WHOOP-computed split), and only fall
        // back to deriving zone-minutes from the strap's own raw HR when the row has none — so we
        // never overwrite a real imported split with an on-device approximation.
        var minutes: [Double]?
        var fromImport = false
        if let pct = WorkoutZones.percents(row.zonesJSON) {
            let durMin = (row.durationS ?? Double(row.endTs - row.startTs)) / 60.0
            if durMin > 0 {
                minutes = pct.map { durMin * $0 / 100.0 }
                fromImport = true
            }
        }
        if minutes == nil {
            minutes = await repo.workoutZoneMinutes(from: row.startTs, to: row.endTs, zoneSet: profile.hrZoneSet,
                                                    source: row.source)
        }

        let loadedHRR = await repo.workoutHeartRateRecovery(
            from: row.startTs, to: row.endTs, maxHR: Double(profile.hrMax), source: row.source)

        // Steps for an on-foot session (#398), computed at display time over the exact window so it
        // "fills in after sync": prefer the strap's own counter (MG/5.0) once it has offloaded the window,
        // else the phone pedometer (any strap, incl. WHOOP 4.0 / CSV-import). Never shown for non-foot
        // sports (cycling/rowing/… have no footfalls). Both sources return nil for "no data", so an empty
        // window stays "–" rather than a fabricated 0.
        var stepReadout: StepReadout? = nil
        if WorkoutCatalog.isOnFoot(row.sport) {
            if let ticks = await repo.strapStepTicks(from: row.startTs, to: row.endTs) {
                // Same per-user ticks-per-step calibration the daily total applies (#139), floor 0.5.
                let scaled = Int((Double(ticks) / max(profile.stepTicksPerStep, 0.5)).rounded())
                if scaled > 0 { stepReadout = StepReadout(count: scaled, fromStrap: true) }
            }
            if stepReadout == nil,
               let ped = await WorkoutPedometer.steps(fromSec: row.startTs, toSec: row.endTs), ped > 0 {
                stepReadout = StepReadout(count: ped, fromStrap: false)
            }
        }

        var points = bucketPoints
        var hrr = loadedHRR
        #if DEBUG
        if demoSyntheticHR, points.isEmpty {
            let n = max(2, (row.endTs - row.startTs) / 60)
            points = (0..<n).map { i in
                let t = Double(i) / Double(n)
                let v = 112 + 40 * (1 - exp(-t * 6)) + 18 * pow(t, 6) + 3 * sin(Double(i) * 0.9)
                return TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(row.startTs + i * 60)), value: v)
            }
            hrr = hrr ?? HeartRateRecovery.Result(endHR: 168, after1Minute: 31, after2Minutes: 48, after5Minutes: 62)
        }
        #endif
        await MainActor.run {
            self.route = routePoints
            self.hrPoints = points
            self.zoneMinutes = minutes
            self.zonesFromImport = fromImport
            self.heartRateRecovery = hrr
            self.steps = stepReadout
            self.loaded = true
        }
    }

    /// Write the route to a GPX/FIT file and hand it to the system share sheet (or a Save panel on macOS).
    /// Points are decoded lat/lon only (the stored polyline), so the exporter interpolates per-point times
    /// across the session window and carries the workout's summary (sport, distance, calories, HR).
    ///
    /// The build + disk write run OFF the main actor (a long route is a non-trivial encode, and blocking
    /// file IO must never stall the UI); only the share-sheet present hops back to the main actor.
    @MainActor private func exportRoute(_ format: RouteExporter.Format) {
        guard route.count >= 2 else { return }
        let points = route.map { RoutePoint(lat: $0.lat, lon: $0.lon) }
        // Name the file by the workout's start (not export time) so it's stable + matches the Android twin.
        let name = "noop-route-\(row.startTs).\(format.ext)"
        let startTs = row.startTs, endTs = row.endTs, sport = row.sport
        let distanceM = row.distanceM, energyKcal = row.energyKcal, avgHr = row.avgHr, maxHr = row.maxHr
        Task.detached(priority: .userInitiated) {
            let data = RouteExporter.render(
                format, route: points, startTs: startTs, endTs: endTs, sport: sport,
                distanceM: distanceM, energyKcal: energyKcal, avgHr: avgHr, maxHr: maxHr)
            let url = NoopScratch.file(name)
            do { try data.write(to: url) } catch { return }
            await MainActor.run { FileExport.exportFile(at: url, suggestedName: name) }
        }
    }


    /// Avg pace from the row's GPS distance + duration, in the user's unit system: "m:ss /km" (metric) or
    /// "m:ss /mi" (imperial). "–" when distance or duration is missing/zero (pace undefined — honest).
    private var paceLabel: String {
        guard let m = row.distanceM, m > 0 else { return "–" }
        let secs = row.durationS ?? Double(row.endTs - row.startTs)
        guard secs > 0 else { return "–" }
        let km = m / 1000.0
        return UnitFormatter.paceFromSecPerKm(secs / km, system: distanceUnitSystem)
    }

    private var routeAccessibilityLabel: String {
        let dist = distanceLabel(row.distanceM)
        return String(localized: "Map of your \(SportName.display(row.sport)) route, \(dist).")
    }

    /// #1205: the route card's overline and description must be honest about where the route came
    /// from. An on-device recorded route says "Recorded on device"; an imported route (Apple Health
    /// or Health Connect) says "Imported from Apple Health" / "Imported" so the user is not told
    /// their phone recorded GPS data that actually came from another app.
    private var routeOriginLabel: LocalizedStringKey {
        switch WorkoutSource.classify(row.source) {
        // "Imported" rather than naming the app: every string here is one the catalog already carries in
        // all nine locales, so the honesty fix ships translated on day one. A source-specific variant
        // ("Imported from Apple Health") would be a NEW key, and nothing catches a missing entry: the i18n
        // audit checks locale coverage OF catalog entries, not that a `String(localized:)` literal has one.
        // It would have read English on every non-English device while the gate stayed green.
        case .apple, .whoop, .lifting, .activityFile: return "Imported"
        case .detected, .manual: return "Recorded on device"
        }
    }

    private var routeDescription: String {
        switch WorkoutSource.classify(row.source) {
        // Same rule as the overline: both of these are existing catalog keys with all nine locales. The
        // imported line carries the privacy claim without the "recorded on your device" the original
        // string opens with, which is the part that was untrue for a route another app collected.
        case .apple, .whoop, .lifting, .activityFile:
            return String(localized: "This stays on your device. It is never uploaded, never synced, never shared.")
        case .detected, .manual:
            return String(localized: "Your GPS route for this session, recorded and stored on your device. Nothing leaves your phone.")
        }
    }

    // MARK: - Formatting (kept local, matching WorkoutsView's rhythm)

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE d MMM yyyy"
        return f
    }()
    /// #1821: routed through AppClock so the Clock format setting reaches this label. Was a `static
    /// let`, which would have frozen the reader's choice at first use until the app relaunched.
    private static var timeFmt: DateFormatter { AppClock.hourMinuteFormatter() }
    /// #1821: routed through AppClock so the Clock format setting reaches this label. Was a `static
    /// let`, which would have frozen the reader's choice at first use until the app relaunched.
    private static var tooltipTime: DateFormatter { AppClock.hourMinuteFormatter() }

    private func dateLabel(_ ts: Int) -> String {
        Self.dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
    private func timeLabel(_ ts: Int) -> String {
        Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
    private func timeRangeLabel(_ start: Int, _ end: Int) -> String {
        end > start ? "\(timeLabel(start))–\(timeLabel(end))" : timeLabel(start)
    }
    private func durationLabel(_ s: Double?) -> String {
        guard let s, s > 0 else { return "–" }
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return String(localized: "\(h)h \(m)m") }
        return String(localized: "\(m)m")
    }
    private func distanceLabel(_ m: Double?) -> String {
        guard let m, m > 0 else { return "–" }
        return UnitFormatter.distanceFromMeters(m, system: distanceUnitSystem)
    }
    private func grouped(_ v: Double) -> String {
        Self.intFmt.string(from: NSNumber(value: Int(v.rounded()))) ?? "\(Int(v.rounded()))"
    }
    private static let intFmt: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return f
    }()
}


// MARK: - Session HR curve

/// The session's heart rate on the zone bands: the five %HRmax zones shaded faintly behind the line (the
/// higher, the brighter), bpm guides on the left and zone names on the right, the chart-blue line over a
/// soft fill, and a dashed cursor with a white dot at the peak.
private struct WorkoutHRCurve: View {
    let points: [TrendPoint]
    let zoneSet: HRZoneSet

    private static let leftAxis: CGFloat = 30
    private static let rightAxis: CGFloat = 24
    private static let bottomAxis: CGFloat = 22

    var body: some View {
        Canvas { ctx, size in
            let plot = CGRect(x: Self.leftAxis, y: 6, width: size.width - Self.leftAxis - Self.rightAxis,
                              height: size.height - Self.bottomAxis - 6)
            guard plot.width > 0, plot.height > 0, points.count > 1,
                  let t0 = points.first?.date, let t1 = points.last?.date else { return }
            let values = points.map(\.value)
            let lo = max(0, (values.min() ?? 60) - 8), hi = (values.max() ?? 180) + 8
            let span = max(hi - lo, 1), duration = max(t1.timeIntervalSince(t0), 1)
            func y(_ v: Double) -> CGFloat { plot.maxY - plot.height * CGFloat((min(max(v, lo), hi) - lo) / span) }
            func x(_ d: Date) -> CGFloat { plot.minX + plot.width * CGFloat(d.timeIntervalSince(t0) / duration) }
            func label(_ s: String, _ color: Color = StrandPalette.textTertiary) -> GraphicsContext.ResolvedText {
                var t = ctx.resolve(Text(verbatim: s).font(StrandFont.light(10)))
                t.shading = .color(color)
                return t
            }

            // Zone bands inside the visible range, brighter for the harder zones, with their names.
            for zone in zoneSet.zones {
                let top = zone.number == 5 ? hi : min(zone.upper, hi), bottom = max(zone.lower, lo)
                guard top > bottom else { continue }
                let band = CGRect(x: plot.minX, y: y(top), width: plot.width, height: y(bottom) - y(top))
                ctx.fill(Path(band), with: .color(.white.opacity(0.012 * Double(zone.number))))
                ctx.fill(Path(CGRect(x: plot.minX, y: y(bottom), width: plot.width, height: 1)),
                         with: .color(.white.opacity(0.08)))
                ctx.draw(label("Z\(zone.number)"), at: CGPoint(x: size.width, y: band.midY), anchor: .trailing)
                if bottom > lo + span * 0.04 {
                    ctx.draw(label("\(Int(bottom.rounded()))"), at: CGPoint(x: 0, y: y(bottom)), anchor: .leading)
                }
            }

            // The line over its fill.
            let pts = points.map { CGPoint(x: x($0.date), y: y($0.value)) }
            var fill = Path()
            fill.move(to: CGPoint(x: pts[0].x, y: plot.maxY))
            pts.forEach { fill.addLine(to: $0) }
            fill.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: plot.maxY))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [StrandPalette.effortColor.opacity(0.45), StrandPalette.effortColor.opacity(0)]),
                startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
            var line = Path()
            line.addLines(pts)
            ctx.stroke(line, with: .color(StrandPalette.metricCyan),
                       style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))

            // The peak: dashed cursor and dot.
            if let i = values.indices.max(by: { values[$0] < values[$1] }) {
                let p = pts[i]
                var cursor = Path()
                cursor.move(to: p)
                cursor.addLine(to: CGPoint(x: p.x, y: plot.maxY))
                ctx.stroke(cursor, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .color(.white))
                let peakLabel = "\(Int(values[i].rounded())) · \(Self.time(points[i].date))"
                ctx.draw(label(peakLabel, StrandPalette.textPrimary),
                         at: CGPoint(x: min(max(p.x, plot.minX + 40), plot.maxX), y: size.height),
                         anchor: p.x > plot.maxX - 40 ? .bottomTrailing : .bottom)
                // Start and a mid-session time where they do not collide with the peak label.
                for (frac, anchor) in [(0.0, UnitPoint.bottomLeading), (0.5, UnitPoint.bottom)] {
                    let tx = plot.minX + plot.width * frac
                    guard abs(tx - p.x) > 70 else { continue }
                    let d = t0.addingTimeInterval(duration * frac)
                    ctx.draw(label(Self.time(d)), at: CGPoint(x: tx, y: size.height), anchor: anchor)
                }
            }
        }
    }

    private static func time(_ d: Date) -> String { AppClock.hourMinuteFormatter().string(from: d) }
}

/// The recovery curve after the session ended: the end heart rate, then the measured 1, 2 and 5 minute
/// points (a missing minute is skipped), with the 1-minute point marked.
private struct RecoveryCurve: View {
    let recovery: HeartRateRecovery.Result

    var body: some View {
        Canvas { ctx, size in
            var samples: [(minute: Double, bpm: Double)] = [(0, Double(recovery.endHR))]
            if let a = recovery.after1Minute { samples.append((1, Double(recovery.endHR - a))) }
            if let a = recovery.after2Minutes { samples.append((2, Double(recovery.endHR - a))) }
            if let a = recovery.after5Minutes { samples.append((5, Double(recovery.endHR - a))) }
            guard samples.count > 1 else { return }
            let lo = samples.map(\.bpm).min() ?? 0, hi = samples.map(\.bpm).max() ?? 1
            let span = max(hi - lo, 1)
            // Minutes on a square-root axis so the first two minutes, where recovery happens, get the room.
            let pts = samples.map {
                CGPoint(x: size.width * CGFloat(($0.minute / 5).squareRoot()),
                        y: 6 + (size.height - 12) * CGFloat(1 - ($0.bpm - lo) / span))
            }
            var fill = Path()
            fill.move(to: CGPoint(x: pts[0].x, y: size.height))
            pts.forEach { fill.addLine(to: $0) }
            fill.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [StrandPalette.effortColor.opacity(0.4), StrandPalette.effortColor.opacity(0)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            var line = Path()
            line.addLines(pts)
            ctx.stroke(line, with: .color(StrandPalette.metricCyan),
                       style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: pts[0].x - 3, y: pts[0].y - 3, width: 6, height: 6)), with: .color(.white))
            if recovery.after1Minute != nil {
                let p = pts[1]
                var cursor = Path()
                cursor.move(to: CGPoint(x: p.x, y: 0))
                cursor.addLine(to: CGPoint(x: p.x, y: size.height))
                ctx.stroke(cursor, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .color(.white))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Route map (#524)
//
// A MapKit map of the captured route polyline, drawn with start (green) + end (red) markers — the Apple
// analogue of Android's `RouteCanvas`, but on real map tiles. Built as a platform-bridged representable
// around `MKMapView` so it runs on BOTH iOS 17 and macOS 13 (SwiftUI's newer `Map { MapPolyline }` needs
// iOS 17 / macOS 14, and the macOS deployment target is 13). The map is offline-capable: MapKit caches
// tiles locally and the route itself is on-device — NOOP never sends the route anywhere.

#if canImport(MapKit) && canImport(UIKit)
import UIKit
typealias RouteMapRepresentable = UIViewRepresentable
#elseif canImport(MapKit) && canImport(AppKit)
import AppKit
typealias RouteMapRepresentable = NSViewRepresentable
#endif

#if canImport(MapKit)
struct WorkoutRouteMap: RouteMapRepresentable {
    let points: [RouteMath.LatLng]

    private var coordinates: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeMap(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsUserLocation = false
        // The v2 surfaces are dark in every appearance, so the tiles are too.
        #if canImport(UIKit)
        map.overrideUserInterfaceStyle = .dark
        #elseif canImport(AppKit)
        map.appearance = NSAppearance(named: .darkAqua)
        #endif
        configure(map)
        return map
    }

    /// Draw the polyline + start/end pins and frame the route. Replaces any existing overlays so a
    /// re-render doesn't stack them.
    private func configure(_ map: MKMapView) {
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
        let coords = coordinates
        guard coords.count >= 2 else { return }
        let line = MKPolyline(coordinates: coords, count: coords.count)
        map.addOverlay(line)

        let start = MKPointAnnotation(); start.coordinate = coords.first!; start.title = String(localized: "Start")
        let end = MKPointAnnotation(); end.coordinate = coords.last!; end.title = String(localized: "Finish")
        map.addAnnotations([start, end])

        // Frame the whole route with a little padding so the line isn't flush to the edges.
        let rect = line.boundingMapRect
        let inset = UIEdgeInsetsLikePadding
        map.setVisibleMapRect(rect, edgePadding: inset, animated: false)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            // The v2 route is a white line on the dark map. A platform colour (the renderer needs a
            // UIColor/NSColor, not a SwiftUI Color).
            r.strokeColor = RoutePlatformColor.line
            r.lineWidth = 3
            r.lineJoin = .round
            r.lineCap = .round
            return r
        }
    }

    #if canImport(UIKit)
    private var UIEdgeInsetsLikePadding: UIEdgeInsets { UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24) }
    func makeUIView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateUIView(_ map: MKMapView, context: Context) { configure(map) }
    #elseif canImport(AppKit)
    private var UIEdgeInsetsLikePadding: NSEdgeInsets { NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24) }
    func makeNSView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateNSView(_ map: MKMapView, context: Context) { configure(map) }
    #endif
}

/// The route stroke colour as a platform colour (MapKit's renderer can't take a SwiftUI `Color`): the v2
/// ink, so the line reads like every other trace on the screen.
private enum RoutePlatformColor {
    #if canImport(UIKit)
    static let line = UIColor(StrandPalette.textPrimary)
    #elseif canImport(AppKit)
    static let line = NSColor(StrandPalette.textPrimary)
    #endif
}
#else
/// Platforms without MapKit (none we ship, but keeps the type resolvable): no route map.
struct WorkoutRouteMap: View {
    let points: [RouteMath.LatLng]
    var body: some View { Color.clear }
}
#endif

#if DEBUG
#Preview("Workout Detail") {
    NavigationStack {
        WorkoutDetailView(row: WorkoutRow(
            startTs: Int(Date().timeIntervalSince1970) - 3600,
            endTs: Int(Date().timeIntervalSince1970),
            sport: "Running", source: "whoop", durationS: 3600, energyKcal: 712,
            avgHr: 152, maxHr: 178, strain: 14.2, distanceM: 10_400,
            zonesJSON: #"{"z1":12.5,"z2":28.0,"z3":33.5,"z4":18.0,"z5":6.0}"#, notes: nil, steps: nil))
            .environmentObject(Repository(deviceId: "preview"))
    }
    .frame(width: 1040, height: 940)
    .preferredColorScheme(.dark)
}
#endif
