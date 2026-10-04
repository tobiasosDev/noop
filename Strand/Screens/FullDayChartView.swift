import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Deep Timeline (full-day, full-resolution metric viewer) — #575
//
// The headline tap-through from Explore: a whole-day line for one metric that the user can ZOOM and PAN
// down to the raw per-second signal. The hard problem — never drawing ~86k points for a worn 24h — is
// solved in the read layer (`Repository.timelineSeries` picks coarse SQL buckets at day scale and raw
// seconds when zoomed in), so this screen only ever receives ~targetPoints points regardless of zoom.
//
// Reuses the existing `OverviewHRChart` (its `.chartXScale(domain:)` already pins the axis); the chart's
// zoom binding drives the visible window, and re-reads at the new resolution as the window changes. macOS
// adds scroll-to-zoom (no pinch); both platforms drag-to-pan. Serves #574 (owned-source filter / honest
// "Other sources" disclosure) and is the detail surface behind #582.
//
// #979 spin-offs: (1) annotation parity with the classic Today whole-day chart — the main night's sleep
// band + a sport glyph at each workout, fed through the SAME OverviewHRChart layers Today uses (this
// screen previously drew a bare line, despite being sold as "the whole-day trend with bands"); (2) an
// iPhone touch-and-hold scrub (`touchScrub: true`) so the crosshair readout the Mac pointer hover gets
// is reachable on touch too.

struct FullDayChartView: View {
    @EnvironmentObject var repo: Repository

    /// The day this timeline is showing (its real calendar midnight). Defaults to the logical day so an
    /// after-midnight open still lands on the night the user is living, not an empty new calendar day (#144).
    /// Mutable so the user can step back through previous days (#597 — was today-only with no way back).
    @State private var dayStart: Date
    /// True once we've done the one-shot "open on the most recent day with data" jump (or the caller pinned
    /// an explicit day, in which case we never override it). Stops the jump from fighting manual navigation.
    @State private var didLandOnLatest: Bool

    init(dayStart: Date? = nil) {
        _dayStart = State(initialValue: dayStart ?? Repository.logicalDayStart(Date()))
        _didLandOnLatest = State(initialValue: dayStart != nil)
    }

    @State private var metric: Repository.TimelineMetric = .hr
    // Imperial/Metric temperature preference (#101) — mirrors MetricExplorerView so skin temp here
    // respects the same °C/°F override instead of always showing Celsius.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    private var temperatureUnit: TemperatureUnit {
        let system = UnitSystem(rawValue: unitSystemRaw) ?? .metric
        return UnitPrefs.resolveTemperature(system: system, override: temperatureRaw)
    }
    /// "Owned only" hides empty non-strap rows; "All sources" surfaces the disclosure (#574). The active
    /// device is always the owned source, so this currently scopes the empty-state copy rather than swapping reads.
    @State private var ownedOnly = true
    /// What the source row calls the owned source: the active device's registry display name (nickname,
    /// else "Brand Model"), so an active Oura ring reads "Oura …" over the ring's own series instead of
    /// the strap label this row shipped with. `nil` (no registry row) keeps the legacy "My WHOOP".
    @State private var sourceName: String? = nil
    /// #623: true when the current SpO2/respiration metric is genuinely unsupported on the active strap —
    /// a 5.0-family strap that has NEVER produced it (4.0-only wire signals) — vs merely an empty window.
    @State private var metricUnsupported = false

    @State private var series: Repository.TimelineSeries = .empty
    // #979 spin-off — day annotations, mirroring the classic Today's Overview HR markers: the main
    // night's band (labelled with its duration) and each workout's sport glyph. Day-scoped facts, so
    // they're loaded per shown day (NOT per zoom window — the chart clamps them into the visible
    // window itself), keeping the zoom/pan re-read path untouched.
    @State private var sleepSpan: OverviewHRChart.SleepSpan? = nil
    @State private var workoutSpans: [OverviewHRChart.WorkoutSpan] = []
    /// The visible window the chart's gestures mutate. nil → full day (the chart falls back to `dayBounds`).
    @State private var zoomDomain: ClosedRange<Date>? = nil
    @State private var loading = true
    @State private var showDayPicker = false
    /// The shown day's workouts, for the Events list (the chart's own spans carry only a glyph).
    @State private var workoutRowsForDay: [WorkoutRow] = []

    /// The full clamp the zoom window can never escape — the selected calendar day.
    private var dayBounds: ClosedRange<Date> {
        dayStart...dayStart.addingTimeInterval(86_400)
    }

    /// #986: a continuous left-drag can scroll back to the shown day plus the two before it (a rolling
    /// 3-day window), so older HR is reachable by dragging, not only the day-stepper. Deliberately bounded
    /// so one drag can't fling through weeks. The default view is still exactly one day (xRange: dayBounds);
    /// this only widens the pan clamp, and the data reload keys on the visible window so panned-to days load.
    private var panBounds: ClosedRange<Date> {
        dayStart.addingTimeInterval(-2 * 86_400)...dayBounds.upperBound
    }

    /// The currently-visible window (zoomed or the whole day).
    private var visibleWindow: ClosedRange<Date> { zoomDomain ?? dayBounds }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                NoopScreenHeader("Deep timeline") {
                    NoopCircleButton("calendar-blank", accessibilityLabel: "Pick a day") { showDayPicker = true }
                        .popover(isPresented: $showDayPicker) { dayPicker }
                }
                Text("Every second of your day, zoomable.")
                    .font(StrandFont.light(14))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, 2)
                    .padding(.top, 12)
                DeepTimelineLiveHero(latest: displayPoints.last.map { (value: $0.value, date: $0.date) },
                                     metric: metric, format: { format($0) }, unitSuffix: unitSuffix)
                    .padding(.top, 16)
                dayNav
                    .padding(.top, 28)
                metricPills
                    .padding(.top, 14)
                sourceRow
                    .padding(.top, 12)
                chartArea
                    .padding(.top, 26)
                zoomHint
                    .padding(.top, 18)
                if !series.points.isEmpty {
                    windowCard
                        .padding(.top, 22)
                }
                eventsSection
                Text(footnote)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 22)
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
        // The v2 header names the screen; the system title only labels the macOS window bar.
        #if os(macOS)
        .navigationTitle("Deep Timeline")
        #endif
        .noopHidesSystemNavBar()
        .task(id: taskKey) { await reload() }
        .task(id: annotationKey) { await reloadAnnotations() }
        .task { await landOnLatestDayIfNeeded() }
        .task(id: metric) { await resolveMetricUnsupported() }   // #623
        .task(id: repo.deviceId) { sourceName = repo.activeDeviceDisplayName() }
    }

    /// #623: a SpO2/respiration track is "unsupported on this strap" only when it's a 5.0-family strap that
    /// has never produced the metric — not merely an empty window (a 4.0-v24 banks SpO2, and the legacy
    /// bare-"WHOOP" model resolves to the 5.0 family). Re-resolves when the metric changes.
    ///
    /// The family test must be a positive "is it a 5/MG" (#1086), never a coalesced one: the respiration
    /// copy tells the reader their estimate is on the Health screen, which is true for a WHOOP 5 (the R-R
    /// RSA estimate runs) and false for a non-WHOOP device whose banked stream that estimate refuses.
    private func resolveMetricUnsupported() async {
        guard repo.activeStrapIsWhoop5(), metric == .spo2 || metric == .respiration else {
            metricUnsupported = false
            return
        }
        metricUnsupported = !(await repo.strapHasEverProduced(metric))
    }

    /// Annotations re-read only when the shown day changes or fresh strap data lands — deliberately NOT
    /// on zoom (see `sleepSpan` above), so scrubbing/pinching never re-queries sleeps/workouts.
    private var annotationKey: String {
        "\(Int(dayStart.timeIntervalSince1970))|\(repo.refreshSeq)"
    }

    /// Re-read whenever the metric, the day, the source scope, the settled zoom window, or fresh strap
    /// data changes. The window is bucketed to whole seconds so micro-jitter during a drag doesn't thrash
    /// the DB — the chart redraws smoothly from the in-hand domain while the data settles.
    private var taskKey: String {
        let lo = Int(visibleWindow.lowerBound.timeIntervalSince1970)
        let hi = Int(visibleWindow.upperBound.timeIntervalSince1970)
        return "\(metric.rawValue)|\(Int(dayStart.timeIntervalSince1970))|\(ownedOnly)|\(lo)|\(hi)|\(repo.refreshSeq)"
    }

    // MARK: Controls

    /// The metric chips — one per timeline track the store can read.
    private var metricPills: some View {
        // The row scrolls edge to edge: clipped at the 20 pt gutter, a chip cut off there read as broken
        // rather than as "more to the right" (German labels push the last chip past the screen).
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Repository.TimelineMetric.allCases) { m in
                    Button {
                        withAnimation(StrandMotion.interactive) { metric = m }
                    } label: {
                        NoopChip(verbatim: m.title, isOn: metric == m, icon: m == .hr ? "heartbeat" : nil)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
            .padding(.horizontal, NoopMetrics.screenHPadding)
        }
        .padding(.horizontal, -NoopMetrics.screenHPadding)
    }

    /// #574 — owned-source scope. The active device is the owned source; "All" reveals the honest
    /// disclosure that other sources' raw per-second streams aren't offloaded on-device.
    private var sourceRow: some View {
        HStack(spacing: 12) {
            SegmentedPillControl([true, false], selection: $ownedOnly, fillsAvailableWidth: true) {
                $0 ? String(localized: "Owned") : String(localized: "All")
            }
            .frame(width: 150)
            Group {
                if let sourceName {
                    Text("Owned = \(sourceName)'s own samples. Other sources keep no per-second data.")
                } else {
                    Text("Owned = My WHOOP's own samples. Other sources keep no per-second data.")
                }
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The day title with the ‹ › stepper — move the whole timeline back/forward a day so a user can reach
    /// the days that actually hold their data, not just today (#597). Forward is clamped at today.
    private var dayNav: some View {
        HStack(spacing: 6) {
            Text(dayTitle)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button { stepDay(-1) } label: {
                PhIcon("caret-left", size: 18).frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(StrandPalette.textPrimary)
            .opacity(0.8)
            .accessibilityLabel("Previous day")
            Button { stepDay(1) } label: {
                PhIcon("caret-right", size: 18).frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(StrandPalette.textPrimary)
            .opacity(isOnLatestDay ? 0.25 : 0.8)
            .disabled(isOnLatestDay)
            .accessibilityLabel("Next day")
        }
    }

    /// The graphical calendar behind the header's calendar circle; picks the shown day (never a future one).
    private var dayPicker: some View {
        DatePicker("", selection: Binding(
            get: { dayStart },
            set: { picked in
                let day = Repository.logicalDayStart(picked)
                withAnimation(StrandMotion.interactive) {
                    dayStart = min(day, Repository.logicalDayStart(Date()))
                    zoomDomain = nil
                }
                showDayPicker = false
            }), in: ...Date(), displayedComponents: [.date])
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(12)
            .frame(minWidth: 320, minHeight: 360)
            #if os(iOS)
            .presentationCompactAdaptation(.popover)
            #endif
    }

    private var isOnLatestDay: Bool { dayStart >= Repository.logicalDayStart(Date()) }

    /// Step the shown day by `delta` days, clamped so you can never go past today, and drop any zoom so the
    /// new day opens at full-day scale.
    private func stepDay(_ delta: Int) {
        let next = dayStart.addingTimeInterval(Double(delta) * 86_400)
        if delta > 0 && next > Repository.logicalDayStart(Date()) { return }
        withAnimation(StrandMotion.interactive) {
            dayStart = next
            zoomDomain = nil
        }
    }

    /// "Today, Saturday 3 October" style: the relative word when there is one, then the full date.
    private var dayTitle: String {
        let today = Repository.logicalDayStart(Date())
        let full = dayStart.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(AppLanguage.activeLocale))
        if Calendar.current.isDate(dayStart, inSameDayAs: today) { return String(localized: "Today") }
        if Calendar.current.isDate(dayStart, inSameDayAs: today.addingTimeInterval(-86_400)) {
            return String(localized: "Yesterday")
        }
        return full
    }

    // MARK: Chart

    @ViewBuilder private var chartArea: some View {
        Group {
            if loading && series.points.isEmpty {
                loadingState
            } else if series.points.isEmpty {
                emptyState
            } else {
                chart
            }
        }
        .frame(height: 230)
    }

    /// `series.points` in the DISPLAYED unit (#101) — for every metric but skin temp this is just the raw
    /// points; skin temp is stored/read in °C, so when the user has °F selected the chart's line, y-axis
    /// domain AND gridlines (which plot the raw value, not `format`'s output) need the converted number,
    /// not just the readout label. The timeline series is the ABSOLUTE skin temp (`skinTempCelsius`), so
    /// the absolute °C→°F conversion (×9/5 + 32) is the right one here — not a deviation rescale.
    private var displayPoints: [TrendPoint] {
        guard metric == .skinTemp, temperatureUnit == .fahrenheit else { return series.points }
        return series.points.map {
            TrendPoint(date: $0.date, value: UnitFormatter.celsiusToFahrenheit($0.value))
        }
    }

    private var chart: some View {
        OverviewHRChart(
            points: displayPoints,
            // #979 spin-off — the same sleep-band + workout-glyph layers the classic Today feeds. Passed
            // on EVERY metric track (they're time annotations, so "when was I asleep / training" reads
            // against skin temp or HRV just as it does against HR); the glyph anchors at the shown
            // metric's peak inside the workout window, and the chart clamps both into the zoom window.
            sleep: sleepSpan,
            workouts: workoutSpans,
            gradient: gradientFor(metric),
            valueRange: valueRange(displayPoints),
            xRange: dayBounds,
            height: 230,
            // #979 spin-off — iPhone touch scrub: hold to pin the crosshair, drag to read values under
            // the finger (the Mac pointer hover's readout, made reachable on touch). Opt-in here only.
            touchScrub: true,
            zoomDomain: $zoomDomain,
            zoomBounds: panBounds,   // #986: pan/scroll clamp is the rolling 3-day window, not one day
            valueFormat: { format($0) },
            dateFormat: { Self.timeFmt.string(from: $0) }
        )
        #if os(macOS)
        // macOS has no pinch here, so wheel/trackpad scroll zooms about the cursor-agnostic centre.
        // (DeepTimeline owns the scroll handler; the chart's own gesture covers drag-pan.)
        .modifier(ScrollToZoomModifier(
            current: { visibleWindow },
            bounds: panBounds,   // #986: match the widened pan clamp
            apply: { zoomDomain = $0 }
        ))
        #endif
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large)
            Text("Loading the day…")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Honest empty/dash state — a window the strap offloaded nothing for (a not-yet-synced stretch, an
    /// off-wrist gap, or a metric this device doesn't record). Never a fabricated flat line.
    private var emptyState: some View {
        VStack(spacing: 8) {
            PhIcon("wave-sine", size: 26)
                .foregroundStyle(StrandPalette.textTertiary)
            // The track's own name, unchanged: lowercasing it broke German nouns ("Kein herzfrequenz hier"),
            // and an article in front of it cannot agree with every track's gender.
            Text("\(metric.title): no data")
                .font(StrandFont.book(15))
                .foregroundStyle(StrandPalette.textSecondary)
            Text(emptyReason)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    /// #623: on a 5.0/MG the SpO2 + raw respiration tracks are PERMANENTLY empty (4.0-only wire signals),
    /// so say that instead of a generic "nothing offloaded" that reads as broken, and point respiration at
    /// the Health screen where the R-R/RSA estimate surfaces. Strap view only (ownedOnly). Twin of Android
    /// FullDayChartScreen.EmptyTimelineState.
    private var emptyReason: String {
        if ownedOnly, metricUnsupported, metric == .spo2 {
            return String(localized: "This strap doesn’t send SpO₂ over Bluetooth. Import a WHOOP export or Health Connect to see it.")
        }
        if ownedOnly, metricUnsupported, metric == .respiration {
            return String(localized: "This strap sends no raw respiration stream. Your estimated respiratory rate appears on the Health screen.")
        }
        return ownedOnly
            ? String(localized: "Nothing offloaded for this window yet.")
            : String(localized: "Other sources don’t offload raw per-second data on-device.")
    }

    /// The gesture hint in a quiet capsule, with Reset once zoomed.
    private var zoomHint: some View {
        HStack(spacing: 10) {
            PhIcon("arrows-out-line-horizontal", size: 18).opacity(0.7)
            Group {
                #if os(macOS)
                Text(zoomDomain == nil ? "Scroll to zoom · drag to pan" : "Zoomed in. Drag to pan")
                #else
                // #979 spin-off: name the hold-to-scrub affordance — a hidden gesture nobody tries is a
                // feature that doesn't exist. (On the Mac the pointer hover is self-discovering.)
                Text(zoomDomain == nil ? "Pinch to zoom · drag to pan · hold to read" : "Zoomed in. Drag to pan · hold to read")
                #endif
            }
            .font(StrandFont.light(12))
            .foregroundStyle(StrandPalette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            if zoomDomain != nil {
                Button { withAnimation(StrandMotion.interactive) { zoomDomain = nil } } label: {
                    NoopPill("Reset", icon: "arrow-counter-clockwise", compact: true)
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(minHeight: 54)
        .background(Capsule(style: .continuous).fill(NoopVisualStyle.surface))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
    }

    /// The visible window in numbers: its span and resolution, then average · peak (with its time) · low.
    private var windowCard: some View {
        let pts = displayPoints
        let values = pts.map(\.value)
        let peak = pts.max { $0.value < $1.value }
        let window = visibleWindow
        let span = Int(window.upperBound.timeIntervalSince(window.lowerBound) / 60)
        let title: String = zoomDomain == nil
            ? String(localized: "Whole day")
            : String(localized: "Zoomed · \(Self.timeFmt.string(from: window.lowerBound))–\(Self.timeFmt.string(from: window.upperBound))")
        let spanText = span >= 120 ? String(localized: "\(span / 60) h") : String(localized: "\(span) min")
        return NoopCard {
            VStack(alignment: .leading, spacing: 16) {
                NoopCardHeader(verbatim: title, icon: zoomDomain == nil ? "chart-line" : "magnifying-glass-plus") {
                    Text(verbatim: "\(spanText) · \(resolutionSubtitle)")
                }
                NoopMetricRow {
                    NoopMetric(value: values.isEmpty ? "—" : format(values.reduce(0, +) / Double(values.count)),
                               unit: unitWord, labelText: String(localized: "Average"))
                    NoopMetric(value: peak.map { format($0.value) } ?? "—", unit: unitWord,
                               labelText: peak.map { String(localized: "Peak · \(Self.timeFmt.string(from: $0.date))") }
                                   ?? String(localized: "Peak"))
                    NoopMetric(value: values.min().map { format($0) } ?? "—", unit: unitWord,
                               labelText: String(localized: "Low"))
                }
            }
        }
    }

    /// The unit as a separate small word for the metric row (bpm, ms, g, s, °C/°F).
    private var unitWord: String? {
        let u = unitSuffix.trimmingCharacters(in: .whitespaces)
        return u.isEmpty ? nil : u
    }

    // MARK: Events

    /// One row of the day's events: tapping zooms the chart onto it.
    private struct TimelineEvent: Identifiable {
        let id: String
        let time: Date
        let icon: String
        let title: String
        let caption: String
        let window: ClosedRange<Date>
    }

    /// The shown day's sleep edges and workouts, from the same annotation reads the chart draws.
    private var events: [TimelineEvent] {
        var out: [TimelineEvent] = []
        if let sleep = sleepSpan {
            let minutes = Int(sleep.end.timeIntervalSince(sleep.start) / 60)
            let asleep = String(localized: "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m asleep")
            if dayBounds.contains(sleep.end) {
                out.append(TimelineEvent(id: "wake", time: sleep.end, icon: "sun",
                                         title: String(localized: "Woke up"), caption: asleep,
                                         window: padded(sleep.end...sleep.end)))
            }
            if dayBounds.contains(sleep.start) {
                out.append(TimelineEvent(id: "sleep", time: sleep.start, icon: "bed",
                                         title: String(localized: "Asleep"), caption: asleep,
                                         window: padded(sleep.start...sleep.start)))
            }
        }
        for w in workoutRowsForDay {
            let start = Date(timeIntervalSince1970: TimeInterval(w.startTs))
            let end = Date(timeIntervalSince1970: TimeInterval(w.endTs))
            let minutes = Int(max(0, w.durationS ?? Double(w.endTs - w.startTs)) / 60)
            out.append(TimelineEvent(id: "w\(w.startTs)", time: start, icon: TodayV2Icons.sport(w.sport),
                                     title: SportName.display(w.sport),
                                     caption: String(localized: "\(minutes) min"),
                                     window: padded(start...max(end, start.addingTimeInterval(60)))))
        }
        return out.sorted { $0.time < $1.time }
    }

    /// An event window with 10 minutes either side, clamped into the pan bounds.
    private func padded(_ r: ClosedRange<Date>) -> ClosedRange<Date> {
        let lo = max(panBounds.lowerBound, r.lowerBound.addingTimeInterval(-600))
        let hi = min(panBounds.upperBound, r.upperBound.addingTimeInterval(600))
        return lo...max(hi, lo.addingTimeInterval(60))
    }

    @ViewBuilder private var eventsSection: some View {
        let list = events
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                NoopSectionTitle("Events", captionKey: "Tap to jump", topPadding: 30)
                NoopList {
                    ForEach(list) { event in
                        Button {
                            withAnimation(StrandMotion.interactive) { zoomDomain = event.window }
                        } label: {
                            HStack(spacing: 14) {
                                Text(verbatim: Self.timeFmt.string(from: event.time))
                                    .font(StrandFont.value(14))
                                    .foregroundStyle(StrandPalette.textPrimary)
                                    .frame(width: 44, alignment: .leading)
                                NoopIconTile(event.icon)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: event.title)
                                        .font(StrandFont.book(15))
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    Text(verbatim: event.caption)
                                        .font(StrandFont.light(12))
                                        .foregroundStyle(StrandPalette.textTertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                PhIcon("caret-right", size: 15).foregroundStyle(StrandPalette.textPrimary).opacity(0.4)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var footnote: String {
        guard !series.points.isEmpty else { return String(localized: "Stored on this device") }
        return String(localized: "\(series.points.count) points drawn · \(resolutionSubtitle) · stored on this device")
    }

    // MARK: Read

    /// One-shot on first open: if today has no data but an earlier day does (the classic just-synced-history
    /// case, #597), land the timeline on that most-recent day so the user sees their data instead of an empty
    /// today. Skipped when the caller pinned an explicit day, and never fights manual navigation afterwards.
    private func landOnLatestDayIfNeeded() async {
        guard !didLandOnLatest else { return }
        didLandOnLatest = true
        if let latest = await repo.latestDataDayStart(), latest < dayStart {
            withAnimation(StrandMotion.interactive) { dayStart = latest }
        }
    }

    private func reload() async {
        loading = true
        let window = visibleWindow
        let result = await repo.timelineSeries(
            metric: metric,
            from: Int(window.lowerBound.timeIntervalSince1970),
            to: Int(window.upperBound.timeIntervalSince1970),
            targetPoints: 600
        )
        // Guard against a stale task landing after the user moved on.
        guard !Task.isCancelled else { return }
        series = result
        loading = false
    }

    /// #979 spin-off — load the shown day's sleep + workouts and scope them EXACTLY like the classic
    /// Today's Overview HR markers: `allSleepSessions` (imported AND on-device computed sources — a
    /// Bluetooth-only user's sleep lives under the computed source), longest overlapping block = the main
    /// night, never a nap; `workoutRows` (already dedup/dismiss-filtered) kept where they overlap the day.
    /// The band + duration use the EFFECTIVE onset so a hand-corrected bedtime shows the same band here as
    /// on the Sleep tab (#318). Both repo reads are today-relative, so `days:` walks back far enough from
    /// now to cover the shown day; the +2 pad mirrors TodayView's sleep read (the night straddles midnight).
    private func reloadAnnotations() async {
        let daysBack = max(0, Int(Date().timeIntervalSince(dayStart) / 86_400)) + 2

        let sleepCandidates: [OverviewHRChart.SleepSpan] = await repo.allSleepSessions(days: daysBack)
            .map { s in
                .init(start: Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs)),
                      end: Date(timeIntervalSince1970: TimeInterval(s.endTs)),
                      label: Self.hoursMinutes(s.endTs - s.effectiveStartTs))
            }
        let rows = await repo.workoutRows(days: daysBack)
        let workoutCandidates: [OverviewHRChart.WorkoutSpan] = rows
            .map { w in
                .init(start: Date(timeIntervalSince1970: TimeInterval(w.startTs)),
                      end: Date(timeIntervalSince1970: TimeInterval(w.endTs)),
                      symbol: sportSymbol(w.sport))
            }
        guard !Task.isCancelled else { return }
        // The pure, headless-tested selection (StrandDesignTests) — window = the shown DAY, not the zoom.
        sleepSpan = OverviewHRChart.mainSleep(sleepCandidates, overlapping: dayBounds)
        workoutSpans = OverviewHRChart.workouts(workoutCandidates, overlapping: dayBounds)
        let lo = Int(dayBounds.lowerBound.timeIntervalSince1970), hi = Int(dayBounds.upperBound.timeIntervalSince1970)
        workoutRowsForDay = rows.filter { $0.startTs < hi && $0.endTs > lo }
    }

    /// "H:MM" for a duration in seconds (e.g. a 6h06m night → "6:06") — mirrors TodayView.hoursMinutes
    /// so the band label reads identically on both whole-day charts.
    private static func hoursMinutes(_ seconds: Int) -> String {
        let h = max(0, seconds) / 3600, m = (max(0, seconds) % 3600) / 60
        return "\(h):\(String(format: "%02d", m))"
    }

    // MARK: Presentation helpers

    private var resolutionSubtitle: String {
        guard !series.points.isEmpty else { return "—" }
        if series.isRaw { return String(localized: "Raw · per second") }
        let m = series.bucketSeconds / 60
        return m >= 1 ? String(localized: "\(m)-minute average")
                      : String(localized: "\(series.bucketSeconds)-second average")
    }

    private var unitSuffix: String {
        switch metric {
        case .hr: return " bpm"
        case .skinTemp: return UnitFormatter.temperatureUnit(temperatureUnit)   // #101: °C / °F per preference
        case .respiration: return ""
        case .hrv: return " ms"
        // Gravity-vector magnitude (#102): tag it "g" so the readout doesn't read as a bare, unexplained
        // number — spo2/bandSleepState stay unitless (unitless ratio / a named state, not a magnitude).
        case .motion: return " g"
        // Seconds of movement per ~30 s window (the ring's OWN 0x47 activity), so tag it "s".
        case .ouraMovement: return " s"
        case .spo2, .bandSleepState: return ""
        }
    }

    private func format(_ v: Double) -> String {
        switch metric {
        case .hr, .respiration, .hrv, .ouraMovement: return String(Int(v.rounded()))
        // `v` already arrives in the displayed unit — callers read from `displayPoints`, which converts
        // skin temp to °F upfront so the chart's own axis (plotted from the same points) agrees. (#101)
        case .skinTemp: return String(format: "%.1f", v)
        case .spo2, .motion: return String(format: "%.2f", v)
        // #175: name the band's own state at the nearest code so the readout reads "asleep", not "2.0".
        case .bandSleepState: return Self.bandStateLabel(v)
        }
    }

    /// #175: map the band's 0-3 sleep_state code to its word. A bucket-averaged fractional value (when
    /// zoomed out) is rounded to the nearest code — honest for a readout label; the track itself plots the
    /// numeric code. This names the BAND's own reported state, never a stage NOOP derives.
    static func bandStateLabel(_ v: Double) -> String {
        switch Int(v.rounded()) {
        case 0: return String(localized: "wake")
        case 1: return String(localized: "still")
        case 2: return String(localized: "asleep")
        case 3: return String(localized: "up")
        default: return String(Int(v.rounded()))
        }
    }

    /// Padded value range so the line never sits flush against an edge (mirrors MetricExplorer/TodayView).
    private func valueRange(_ pts: [TrendPoint]) -> ClosedRange<Double> {
        let vals = pts.map(\.value)
        guard let lo = vals.min(), let hi = vals.max() else {
            return metric == .hr ? 40...120 : 0...1
        }
        if hi <= lo { return (lo - 1)...(hi + 1) }
        let pad = (hi - lo) * 0.12
        return (lo - pad)...(hi + pad)
    }

    /// The v2 chart line (the periwinkle line over the strain-blue fill) for every track: colour on
    /// this screen belongs to the live hero; the tracks are told apart by their chip, not by hue.
    private func gradientFor(_ m: Repository.TimelineMetric) -> Gradient {
        Gradient(colors: [StrandPalette.metricCyan.opacity(0.75), StrandPalette.metricCyan])
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
}

/// The Deep timeline's glow hero: the live heart rate with a rolling beat-by-beat trace while the strap
/// streams, else the latest stored reading of the shown track. Owns LiveState so the ~1 Hz HR notifies
/// re-render only this card.
private struct DeepTimelineLiveHero: View {
    /// The newest point of the shown track (in its displayed unit), for the not-streaming state.
    let latest: (value: Double, date: Date)?
    let metric: Repository.TimelineMetric
    let format: (Double) -> String
    let unitSuffix: String

    @EnvironmentObject private var live: LiveState
    @State private var samples: [Double] = []
    private let maxSamples = 60

    private var liveBpm: Int? {
        guard live.connected, let hr = live.heartRate, hr > 0 else { return nil }
        return hr
    }

    var body: some View {
        NoopHeroCard(glow: .strain, padding: 20, cornerRadius: NoopVisualStyle.heroRadius) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge(liveBpm != nil ? "Live now" : "Latest", icon: "heartbeat")
                    Spacer(minLength: 8)
                    if let date = liveBpm != nil ? Date() : latest?.date {
                        NoopPill(verbatim: date.formatted(.dateTime.hour().minute().locale(AppLanguage.activeLocale)),
                                 compact: true)
                    }
                }
                HStack(alignment: .bottom, spacing: 10) {
                    if let bpm = liveBpm {
                        NoopDotNumber("\(bpm)", size: 72).fixedSize().padding(.vertical, -7)
                        Text("bpm").font(StrandFont.light(15)).foregroundStyle(Color.white.opacity(0.7))
                            .padding(.bottom, 6)
                    } else if let latest {
                        NoopDotNumber(format(latest.value), size: 72).fixedSize().padding(.vertical, -7)
                        let unit = unitSuffix.trimmingCharacters(in: .whitespaces)
                        if !unit.isEmpty {
                            Text(verbatim: unit).font(StrandFont.light(15)).foregroundStyle(Color.white.opacity(0.7))
                                .padding(.bottom, 6)
                        }
                    } else {
                        Text("No reading yet")
                            .font(StrandFont.light(22))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                    Spacer(minLength: 8)
                    if liveBpm != nil, samples.count >= 2 {
                        liveTrace
                            .frame(width: 120, height: 40)
                            .padding(.bottom, 6)
                    }
                }
                .padding(.top, 18)
                Text(caption)
                    .font(StrandFont.light(13))
                    .foregroundStyle(Color.white.opacity(0.66))
                    .padding(.top, 12)
            }
        }
        .onChangeCompat(of: live.heartRate) { hr in
            guard let hr, hr > 0 else { samples.removeAll(); return }
            samples.append(Double(hr))
            if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        }
        .accessibilityElement(children: .combine)
    }

    private var caption: LocalizedStringKey {
        if liveBpm != nil { return "Strap streaming every second" }
        return live.connected ? "Waiting for a live heartbeat · showing the stored timeline"
                              : "Strap not connected · showing the stored timeline"
    }

    /// The rolling live samples as a thin white line ending in a dot.
    private var liveTrace: some View {
        GeometryReader { geo in
            let pts = samples.indices.map { TodaySegmentedAreaChart.point(index: $0, values: samples, size: geo.size) }
            ZStack {
                Path { p in
                    p.move(to: pts[0])
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                Circle().fill(Color.white).frame(width: 6, height: 6).position(pts[pts.count - 1])
            }
        }
        .accessibilityHidden(true)
    }
}

#if os(macOS)
import AppKit
// MARK: - macOS scroll-to-zoom
//
// Scroll up (or trackpad pinch on macOS, which arrives as a magnify event the chart already handles) zooms
// in about the window centre; scroll down zooms out toward the day. Kept as a modifier so the platform
// split stays out of the screen body.
private struct ScrollToZoomModifier: ViewModifier {
    let current: () -> ClosedRange<Date>
    let bounds: ClosedRange<Date>
    let apply: (ClosedRange<Date>) -> Void

    func body(content: Content) -> some View {
        content.background(ScrollCatcher { deltaY in
            // Each notch scales by ~1.15; up (positive) zooms in, down zooms out.
            let scale = deltaY > 0 ? 1.15 : (1.0 / 1.15)
            let zoomed = OverviewHRChart.zoomed(current(), scale: scale, anchorFraction: 0.5, bounds: bounds)
            apply(zoomed.upperBound > zoomed.lowerBound ? zoomed : current())
        })
    }
}

/// A transparent NSView that reports scroll-wheel deltaY up the closure. AppKit-only.
private struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void
    func makeNSView(context: Context) -> NSView { CatcherView(onScroll: onScroll) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onScroll = onScroll
    }
    final class CatcherView: NSView {
        var onScroll: (CGFloat) -> Void
        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func scrollWheel(with event: NSEvent) {
            if abs(event.scrollingDeltaY) > 0.5 { onScroll(event.scrollingDeltaY) }
        }
    }
}
#endif
