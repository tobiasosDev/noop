import SwiftUI
import Combine
import Charts
import StrandDesign
import StrandAnalytics
import StrandImport
import WhoopStore

/// NOOP — Health Monitor.
/// The live heart-rate hero (the screen's one glow), then the weekly scores (Fitness Age, Vitality), the
/// recovery contributors against baseline, the body's vital signs as a two-column grid, the nightly
/// skin-temperature suite, and the records/sources links. Every section is its own leaf view owning only
/// what it reads, so the ~1 Hz live HR stream re-renders the hero and nothing else.
struct HealthView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    // NOTE: HealthView itself deliberately does NOT observe `LiveState`/`AppModel` for live HR. A
    // connected strap publishes at ~1 Hz; observing here would re-evaluate this body (and re-diff the
    // heavy vitals/skin-temp/age sections) on every tick. The ONLY live-dependent decision the parent
    // used to make — "empty state vs the live stack while there's no history yet" — now lives in the
    // `HealthFirstRunContent` leaf, which owns `live`/`model` itself. The common path (history present)
    // branches purely on `repo.days`, so a live tick re-renders only the `HeartRateSection` hero leaf.

    // MARK: - Body

    /// The lazy column (see `body`). The DEBUG screenshot harness turns it off when it anchors the scroll
    /// mid-screen, where a lazy stack has not realised the rows it is asked to show yet.
    private static var lazyColumn: Bool {
        #if DEBUG
        return !CommandLine.arguments.contains("--demo-anchor")
        #else
        return true
        #endif
    }

    var body: some View {
        ScreenScaffold(title: nil,
                       onRefresh: { await repo.refresh() },
                       // PERF (scroll): lazy column — builds the trailing vitals/skin-temp/records sections
                       // on demand instead of all up-front.
                       lazy: Self.lazyColumn) {
            // The screen's own v2 header: back/menu circles, the page title and the sync status (#364).
            HealthHeader()
            if repo.days.isEmpty {
                // First run / no history: whether to show the empty state or the full live stack depends
                // on whether a strap is streaming live HR — a `live`-dependent choice. It's isolated to
                // this leaf (which owns `live`/`model`) so a ~1 Hz HR tick re-renders only this branch,
                // never the parent, and only while there's no history (a transient first-run state).
                HealthFirstRunContent()
            } else {
                // History present: `live` is irrelevant to the layout choice, so the parent renders the
                // full section stack directly without observing the HR stream.
                HealthSectionsStack()
            }
        }
        .noopHidesSystemNavBar()
    }
}

// MARK: - Content stacks

/// The full Health section stack (live HR hero + the static weekly/contributor/vitals/skin-temp sections).
/// Each section is its own leaf owning exactly what it needs, so only the `HeartRateSection` hero
/// re-renders on a ~1 Hz HR tick. Shared by the history-present path and the first-run live path so the
/// stack is defined once.
private struct HealthSectionsStack: View {
    var body: some View {
        // The live HR hero owns `live`/`profile`, so the ~1 Hz HR stream re-renders only this subtree.
        HeartRateSection()
            .padding(.top, 8)
        // Fitness Age + Vitality (weekly, computed by IntelligenceEngine and read back from the
        // metricSeries). Their own views depending only on `repo`/`profile`.
        FitnessAgeSection()
        VitalitySection()
        // The CONTRIBUTORS to today's recovery, each scored against the on-device baseline.
        RecoveryContributorsSection()
        // The vitals grid depends only on `repo`, so it is unaffected by live HR ticks.
        VitalsSection()
        // v5 skin-temperature suite: the nightly chart, the illness "heads-up", body clock and (opt-in)
        // cycle awareness, each driven by a pure StrandAnalytics engine result AppModel publishes.
        SkinTempSection()
        // v5 deep-links: the records logbook + the multi-device fused record, reachable from their
        // honest Health home as drill-in rows (not their own destinations).
        HealthHubLinksSection()
    }
}

/// First-run content (no history yet). Owns `live`/`model` so the live-HR-gated choice between the empty
/// state and the full live stack ticks here, in isolation, instead of re-rendering HealthView.
private struct HealthFirstRunContent: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var model: AppModel

    /// HR to display: the spike-filtered median (model.bpm, #39) when available, else the reported
    /// value, else R-R-derived (the strap streams R-R even when its HR field reads 0).
    private var displayHR: Int? {
        if let hr = model.bpm, hr > 0 { return hr }
        if let hr = live.heartRate, hr > 0 { return hr }
        if let last = live.rr.last, last > 0 { return Int((60_000.0 / Double(last)).rounded()) }
        return nil
    }
    private var hasLiveHR: Bool { displayHR != nil }

    var body: some View {
        if !hasLiveHR {
            // The sync control in the header stays reachable (#364), so a freshly-connected strap can be
            // told to sync before the screen has any data to show.
            G5EmptyCard(icon: "heartbeat",
                        message: Text("No biometrics yet. Import your WHOOP export (and Apple Health if you have it) in Data Sources to fill this in."))
                .padding(.top, 8)
        } else {
            HealthSectionsStack()
        }
    }
}

// MARK: - Header + sync status (#364)

/// The v2 header: the back circle (when pushed/presented) and a "more" menu, the page title, and the
/// manual "Sync now" status pill mirroring the Android Sync-now button. Its own view depending only on
/// `live` (connection + backfill state) and `model` (the BLE pass-through). Honesty rules: the pill only
/// acts when a strap can actually sync; while a sync runs it shows the live chunk count (never a
/// fabricated percent — total pending is unknowable from the protocol); otherwise it shows when history
/// last synced.
private struct HealthHeader: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var model: AppModel

    /// The strap link is usable for a manual offload kick (matches BLEManager.syncNow's own gate).
    ///
    /// `historyReady`, not `bonded` alone: the live-HR path sets `bonded` for a 5/MG that has never
    /// completed a handshake, so this enabled itself and beginBackfill then declined it silently.
    private var canSync: Bool { live.connected && live.bonded && live.historyReady && !live.backfilling }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoopScreenHeader(verbatim: "") {
                G5MoreMenu {
                    // Reaches the BLE engine's gated entry point directly (same idiom as SettingsView's
                    // `model.ble.enableWhoop5DeepData()`); BLEManager.syncNow() is the honest gate — a
                    // no-op when no strap is connected or a sync is already running.
                    Button {
                        model.ble.syncNow()
                    } label: {
                        Label(live.backfilling ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!canSync)
                }
            }
            .padding(.bottom, 18)

            Text("Health")
                .font(StrandFont.title1)
                .tracking(-0.56)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Live vitals, streamed from the strap.")
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.top, 6)
            syncPill
                .padding(.top, 16)
        }
    }

    /// The status pill under the title. Tapping it syncs when a sync is possible; otherwise it is a plain
    /// read-out whose spoken hint says why the button is unavailable.
    @ViewBuilder private var syncPill: some View {
        let pill = HStack(spacing: 8) {
            PhIcon(live.connected ? "arrows-clockwise" : "bluetooth-slash", size: 14)
                .opacity(0.8)
            statusText.lineLimit(1)
        }
        .font(StrandFont.book(12, relativeTo: .caption))
        .foregroundStyle(StrandPalette.textSecondary)
        .padding(.leading, 11)
        .padding(.trailing, 14)
        .frame(height: 32)
        .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))

        if canSync {
            Button { model.ble.syncNow() } label: { pill }
                .buttonStyle(.plain)
                .accessibilityLabel("Sync now")
                .accessibilityValue(statusText)
                .accessibilityHint("Pulls your strap's stored history immediately, without waiting for the next automatic sync.")
        } else {
            pill
                .accessibilityElement(children: .combine)
                .accessibilityHint(helperText)
        }
    }

    /// The status line: in-progress (with the live chunk count) while syncing, else a last-synced read-out,
    /// else an honest "not connected" / pairing state.
    private var statusText: Text {
        if live.backfilling {
            let chunks = live.syncChunksThisSession
            return chunks > 0
                ? Text("Syncing strap history…") + Text(verbatim: " · ") + Text("\(chunks) chunks pulled")
                : Text("Syncing strap history…")
        }
        if !live.connected { return Text("No strap connected") }
        if let last = live.lastSyncedAt {
            return Text("History synced") + Text(verbatim: " · \(relativeAgo(last))")
        }
        // Same condition as the sync gate. Keyed on `bonded` this said "Ready to sync" above an action that
        // could not run, on exactly the strap that cannot sync.
        return live.historyReady ? Text("Ready to sync") : Text("Pairing…")
    }

    private var helperText: String {
        if live.backfilling {
            return String(localized: "Pulling your strap's stored history. This drains oldest-first; a deep backlog now continues automatically across passes instead of waiting between syncs.")
        }
        if !live.connected {
            return String(localized: "Connect your strap to sync its stored history. Until then, only imported data shows here.")
        }
        // historyReady, not `bonded`: `bonded` is set by the live-HR path, so a 5/MG that never completed a
        // handshake would read "syncs right away" next to an action that cannot run.
        if !live.historyReady {
            return String(localized: "Finishing the pairing handshake. Sync now becomes available once the strap is paired.")
        }
        return String(localized: "Syncs your strap's stored history right away, instead of waiting for the next automatic sync.")
    }
}

// MARK: - Heart rate hero (live)

/// Live HR hero, split into its own view so the ~1Hz HR stream only re-renders this
/// subtree — the static sections do not. Depends on `live`, `profile` and today's HR buckets.
private struct HeartRateSection: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var repo: Repository

    /// Rolling buffer of recently-streamed live HR (newest last), so the hero graph builds a real
    /// continuous time-series instead of collapsing to a 2-point flat line when the strap streams HR
    /// but little/no R-R (the #105 case — Live HR works, but the Health graph showed only 2 samples).
    /// Each sample carries the wall-clock time it arrived so the hero can say how far back the trace
    /// reaches (#198 — an iPhone user with no hover needs time context on the chart).
    /// Sampled on a fixed 1 Hz clock (#941), so the 180-sample cap is a strict rolling 3 minutes;
    /// resets when the view is recreated, which is fine for a live trace.
    @State private var hrHistory: [LiveHRSample] = []

    /// Today's low / average / high from the stored HR buckets (min/max read from the SAMPLES inside each
    /// bucket, not from the bucket means — the #2032 rule Today's footer follows). nil until loaded.
    @State private var today: TodayHRStats?

    /// The 1 Hz sampling clock for the hero trace (#941, reimplemented from ryanbr's PR). The buffer
    /// used to append only when `displayHR` CHANGED, but AppModel deliberately republishes `bpm` only
    /// when the smoothed median actually moves, so a steady heart rate banked ZERO points and the
    /// time-axis chart drew one long phantom ramp from the last change to the next. Banking the current
    /// median once a second draws steady HR flat.
    private let sampleTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    /// HR to display: the spike-filtered median (model.bpm, #39) when available — raw live.heartRate
    /// carries PPG harmonic spikes (real ~92 read as 170+); AppModel.bpm's doc mandates "every screen
    /// should show THIS". Falls back to the reported value, then R-R-derived, only until the median has a sample.
    private var displayHR: Int? {
        if let hr = model.bpm, hr > 0 { return hr }
        if let hr = live.heartRate, hr > 0 { return hr }
        if let last = live.rr.last, last > 0 { return Int((60_000.0 / Double(last)).rounded()) }
        return nil
    }
    private var hrIsDerived: Bool { (live.heartRate ?? 0) <= 0 && !live.rr.isEmpty }

    /// HR as a fraction of HR-max (0…1).
    private func hrFraction(_ hr: Int?) -> Double {
        guard let hr = hr, profile.hrMax > 0 else { return 0 }
        return min(max(Double(hr) / Double(profile.hrMax), 0), 1)
    }

    /// Current zone 1…5 from %HR-max (WHOOP/Karvonen-style bands: 50/60/70/80/90).
    private func hrZone(_ fraction: Double) -> Int {
        switch fraction {
        case ..<0.60: return 1
        case ..<0.70: return 2
        case ..<0.80: return 3
        case ..<0.90: return 4
        default:      return 5
        }
    }

    /// A short, time-stamped HR series for the hero chart (newest last).
    /// Prefers the accumulated live-HR time-series — that's what a "live" graph should show, and it
    /// keeps growing even when the strap streams HR but sparse R-R (#105). Falls back to R-R-derived
    /// beats, then a flat line at the current HR. The R-R / flat fallbacks have no real per-sample
    /// timestamps, so we synthesise a 1 Hz trailing window ending "now" (#198).
    private func hrSeries(_ hr: Int?) -> [LiveHRSample] {
        if hrHistory.count > 1 { return hrHistory }
        let beats = live.rr.suffix(60).compactMap { rr -> Double? in
            rr > 0 ? 60_000.0 / Double(rr) : nil
        }
        if beats.count > 1 { return Self.synthesiseSeries(beats) }
        if let hr = hr { return Self.synthesiseSeries([Double(hr), Double(hr)]) }
        return []
    }

    /// Wrap a bare value series in trailing 1 Hz timestamps ending at `Date()`, so the
    /// fallbacks (R-R-derived beats, flat line) chart on the same time x-axis as the live buffer.
    private static func synthesiseSeries(_ values: [Double]) -> [LiveHRSample] {
        let now = Date()
        let n = values.count
        return values.enumerated().map { i, v in
            LiveHRSample(date: now.addingTimeInterval(Double(i - (n - 1))), bpm: v)
        }
    }

    var body: some View {
        // Compute the derived live values ONCE per body pass and thread them into the
        // subviews, instead of re-evaluating heavy computed properties multiple times.
        let displayHR = self.displayHR
        let hasLiveHR = displayHR != nil
        let fraction = hrFraction(displayHR)
        let zone = hrZone(fraction)
        let series = hrSeries(displayHR)

        NoopHeroCard(glow: .heart, padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge("Heart rate", icon: "heartbeat")
                    Spacer(minLength: 8)
                    G5LivePill(text: livePillText(hasLiveHR: hasLiveHR), live: hasLiveHR)
                }
                readout(displayHR: displayHR, hasLiveHR: hasLiveHR, zone: zone)
                    .padding(.top, 30)
                trace(series: series, hasLiveHR: hasLiveHR, displayHR: displayHR, zone: zone)
                    .frame(height: 56)
                    .padding(.top, 22)
                traceCaptions(series: series, hasLiveHR: hasLiveHR, fraction: fraction)
                    .padding(.top, 8)
                todayRow
                    .padding(.top, 20)
            }
            .padding(.top, -2)
        }
        .onReceive(sampleTimer) { now in
            // Bank the CURRENT spike-filtered HR once a second, stamped with the tick's real wall-clock
            // time: this feeds the trace (#198) and the #105 series without the phantom ramp that
            // on-change sampling drew through steady stretches (#941). The 30...220 physiological guard
            // mirrors the Android chart's existing range check; nil banks nothing (disconnect clears the
            // median on both platforms), so a stale value never flat-lines a dead trace.
            guard let v = displayHR, (30...220).contains(v) else { return }
            hrHistory.append(LiveHRSample(date: now, bpm: Double(v)))
            if hrHistory.count > 180 { hrHistory.removeFirst(hrHistory.count - 180) }
        }
        .task(id: repo.refreshSeq) { await loadToday() }
    }

    private func livePillText(hasLiveHR: Bool) -> Text {
        guard hasLiveHR else { return Text("Awaiting strap") }
        return hrIsDerived ? Text("from R-R") : Text("Live")
    }

    /// The dot-matrix number, its unit and the zone tag.
    private func readout(displayHR: Int?, hasLiveHR: Bool, zone: Int) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            NoopDotNumber(displayHR.map(String.init) ?? "—", size: 100,
                          color: hasLiveHR ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                .layoutPriority(1)
            Text("bpm")
                .font(StrandFont.book(15, relativeTo: .subheadline))
                .foregroundStyle(Color.white.opacity(0.7))
                .padding(.bottom, 8)
            Spacer(minLength: 8)
            NoopTag(hasLiveHR ? "Zone \(zone)" : "Idle")
                .fixedSize()
                .padding(.bottom, 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasLiveHR
            ? Text("Heart rate \(displayHR ?? 0) beats per minute, zone \(zone)")
            : Text("Heart rate: awaiting strap"))
    }

    @ViewBuilder
    private func trace(series: [LiveHRSample], hasLiveHR: Bool, displayHR: Int?, zone: Int) -> some View {
        if series.count > 1 {
            LiveTimeChart(samples: series)
                .accessibilityLabel("Live heart rate over time")
                .accessibilityValue(hasLiveHR ? "\(displayHR ?? 0) beats per minute, zone \(zone)" : "no data")
        } else {
            // No trace yet: an empty dashed baseline, so the hero keeps its shape without implying data.
            Canvas { ctx, size in
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(p, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
            .accessibilityHidden(true)
        }
    }

    /// "3 min ago … now · 34 % of max 187": how far back the live trace reaches, and where the current
    /// beat sits against the profile's HR-max.
    private func traceCaptions(series: [LiveHRSample], hasLiveHR: Bool, fraction: Double) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if series.count > 1, let first = series.first {
                Text(verbatim: relativeAgo(first.date.timeIntervalSince1970))
                    .foregroundStyle(Color.white.opacity(0.55))
            } else {
                Text("Waiting for live heart rate")
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            Spacer(minLength: 8)
            if hasLiveHR {
                (Text("now") + Text(verbatim: " · ")
                    + Text("\(Int((fraction * 100).rounded())) % of max \(profile.hrMax)"))
                    .foregroundStyle(StrandPalette.textPrimary)
            } else {
                Text("Max HR \(profile.hrMax)")
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        }
        .font(StrandFont.footnote)
        .lineLimit(1)
    }

    /// Today's low / average / high, each with the clock time of its 5-minute bucket.
    private var todayRow: some View {
        let low: LocalizedStringKey = today.map { t -> LocalizedStringKey in
            "Today's low · \(AppClock.hourMinute(unix: t.lowAt))" } ?? "Today's low"
        let high: LocalizedStringKey = today.map { t -> LocalizedStringKey in
            "Today's high · \(AppClock.hourMinute(unix: t.highAt))" } ?? "Today's high"
        return NoopMetricRow {
            NoopMetric(value: today.map { "\(Int($0.low.rounded()))" } ?? "—", unit: "bpm",
                       label: low, labelColor: NoopMetric.heroLabel)
            NoopMetric(value: today.map { "\(Int($0.average.rounded()))" } ?? "—", unit: "bpm",
                       label: "Average today", labelColor: NoopMetric.heroLabel)
            NoopMetric(value: today.map { "\(Int($0.high.rounded()))" } ?? "—", unit: "bpm",
                       label: high, labelColor: NoopMetric.heroLabel)
        }
    }

    /// Read today's 5-minute HR buckets (local midnight → now) and keep the extremes + the mean of the
    /// bucket means — the same Min/Avg/Max arithmetic Today's HR card footer shows.
    private func loadToday() async {
        let start = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let end = Int(Date().timeIntervalSince1970)
        let buckets = await repo.hrBuckets(from: start, to: end, bucketSeconds: 300)
        today = TodayHRStats(buckets)
    }
}

/// Today's heart-rate extremes and mean from the stored 5-minute buckets. `lowAt`/`highAt` are the start
/// of the bucket holding the extreme sample.
private struct TodayHRStats: Equatable {
    let low: Double, lowAt: Int
    let high: Double, highAt: Int
    let average: Double

    init?(_ buckets: [HRBucket]) {
        guard let lo = buckets.min(by: { $0.minBpm < $1.minBpm }),
              let hi = buckets.max(by: { $0.maxBpm < $1.maxBpm }) else { return nil }
        low = lo.minBpm
        lowAt = lo.ts
        high = hi.maxBpm
        highAt = hi.ts
        average = buckets.map(\.bpm).reduce(0, +) / Double(buckets.count)
    }
}

// MARK: - Live HR sample + time chart

/// One streamed live-HR reading with the wall-clock time it arrived. Carrying the time
/// (rather than a bare bpm) is what lets the hero render a real time x-axis (#198).
struct LiveHRSample: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let bpm: Double
}

/// The live HR hero trace: a thin white line brightening toward "now" over a soft white wash, a dashed
/// rule at the current beat and a haloed end dot, on a real time x-axis so the trace scrolls as samples
/// arrive. The strict rolling 3-minute window comes from the caller's 1 Hz-sampled, 180-capped buffer
/// (HeartRateSection.hrHistory, #941).
///
/// Hover/tooltip: reuses the same `CrosshairRule`/`HighlightDot`/`PositionedTooltip`/`ChartTooltip`
/// components `TrendChart`'s `chartOverlay` uses — no new mechanism. No downsampling here: the buffer is
/// already capped at 180 samples (#941) and this IS the live, in-progress trace.
private struct LiveTimeChart: View {
    var samples: [LiveHRSample]

    /// The x-position the cursor is hovering, in chart-local coordinates.
    @State private var hoverX: CGFloat? = nil

    /// Auto-fitted y bounds with a little headroom so the trace never kisses the edges.
    private var yDomain: ClosedRange<Double> {
        let values = samples.map(\.bpm)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        if lo == hi { return (lo - 5)...(hi + 5) }
        let pad = (hi - lo) * 0.12
        return (lo - pad)...(hi + pad)
    }

    /// The sample nearest a given chart-local x, matching `TrendChart.nearestPoint`.
    private func nearestSample(toX x: CGFloat, proxy: ChartProxy, plot: CGRect) -> LiveHRSample? {
        guard !samples.isEmpty else { return nil }
        let relX = x - plot.minX
        guard let date: Date = proxy.value(atX: relX) else { return nil }
        return samples.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
    }

    var body: some View {
        Chart {
            if let last = samples.last {
                RuleMark(y: .value("Now", last.bpm))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    .foregroundStyle(Color.white.opacity(0.18))
            }
            ForEach(samples) { s in
                AreaMark(x: .value("Time", s.date), y: .value("BPM", s.bpm))
                    .foregroundStyle(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", s.date), y: .value("BPM", s.bpm))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(LinearGradient(
                        stops: [.init(color: .white.opacity(0.25), location: 0),
                                .init(color: .white.opacity(0.8), location: 0.6),
                                .init(color: .white, location: 1)],
                        startPoint: .leading, endPoint: .trailing))
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plotArea in plotArea.clipped() }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                ZStack(alignment: .topLeading) {
                    // The haloed "now" dot, drawn here (outside the clipped plot) so it never gets cut.
                    if let last = samples.last,
                       let px = proxy.position(forX: last.date),
                       let py = proxy.position(forY: last.bpm) {
                        Circle().fill(Color.white.opacity(0.18)).frame(width: 14, height: 14)
                            .position(x: px + plot.minX, y: py + plot.minY)
                        Circle().fill(Color.white).frame(width: 7, height: 7)
                            .position(x: px + plot.minX, y: py + plot.minY)
                    }
                    if let hx = hoverX,
                       let s = nearestSample(toX: hx, proxy: proxy, plot: plot),
                       let px = proxy.position(forX: s.date),
                       let py = proxy.position(forY: s.bpm) {
                        let cx = px + plot.minX
                        let cy = py + plot.minY
                        CrosshairRule(x: cx, height: geo.size.height)
                        HighlightDot(color: StrandPalette.textPrimary).position(x: cx, y: cy)
                        PositionedTooltip(
                            anchor: CGPoint(x: cx, y: cy),
                            container: geo.size,
                            tooltip: ChartTooltip(
                                value: String(localized: "\(Int(s.bpm.rounded())) bpm"),
                                label: s.date.formatted(.dateTime.hour().minute().second()),
                                accent: NoopGlow.heart.tint
                            )
                        )
                    }
                }
                .animation(StrandMotion.fade, value: hoverX)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    // Non-animating transaction: otherwise crossing the plot edge re-runs the line's
                    // draw-on animation and flickers the curve (mirrors TrendChart #104).
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) {
                        switch phase {
                        case .active(let location): hoverX = location.x
                        case .ended: hoverX = nil
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Recovery contributors (distance from baseline)

/// The recovery CONTRIBUTORS: the inputs to today's recovery (HRV, Resting HR, Sleep, Respiratory), each
/// shown as its reading, its baseline and a bar for the distance between them. Depends only on `repo`, so
/// the ~1Hz live HR stream never re-renders it. Presentation-only — every value reads off the latest
/// `DailyMetric` and the baseline mean of prior nights; nothing here changes data or scoring.
private struct RecoveryContributorsSection: View {
    @EnvironmentObject var repo: Repository

    /// One contributor row's resolved read-out.
    private struct Contributor {
        let label: LocalizedStringKey
        let strength: Double?      // 0…100 (baseline ≈ 70), nil while calibrating / no value
        let word: String
        let value: String          // "68"
        let unit: String?          // "ms"
        let baseline: String?      // "62 ms"
        let direction: Int?        // +1 / 0 / −1 raw reading vs baseline; nil without both
    }

    var body: some View {
        let latest = repo.days.last
        // A contributor needs at least the recovery seed depth of prior nights to score against
        // a baseline; below that the bars stay empty and the caption says calibrating.
        let priorCount = repo.days.dropLast().compactMap(\.avgHrv).filter { $0 > 0 }.count
        let ready = priorCount >= Baselines.minNightsSeed
        let contributors = buildContributors(latest)

        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("Contributors") {
                if ready {
                    if let charge = latest?.recovery {
                        Text("Recovery · Charge \(Int(charge.rounded())) %")
                    } else {
                        Text("Recovery")
                    }
                } else {
                    ScoreStatePill(.calibrating, text: "Calibrating (\(priorCount) of \(Baselines.minNightsSeed))")
                }
            }
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(contributors.enumerated()), id: \.offset) { idx, c in
                        if idx > 0 { Rectangle().fill(NoopVisualStyle.border).frame(height: 1) }
                        row(c, ready: ready)
                            .padding(.top, idx == 0 ? 2 : 13)
                            .padding(.bottom, 13)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 6)
            }
            Group {
                if ready {
                    Text("Bar = distance from your baseline. Lower resting HR counts as a gain.")
                } else {
                    Text("Baselines are learned on-device over your first 14 days. Until then, typical ranges apply.")
                }
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.top, -2)
        }
    }

    private func row(_ c: Contributor, ready: Bool) -> some View {
        let word = ready ? c.word : String(localized: "Calibrating")
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.label)
                    .font(StrandFont.book(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textPrimary)
                Group {
                    if ready, let base = c.baseline {
                        Text("Baseline \(base)")
                    } else {
                        Text("Calibrating")
                    }
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            G5DivergingBar(offset: ready ? c.strength.map { ($0 - 70) / 30 } : nil)
                .frame(width: 84)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: c.value)
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let unit = c.unit {
                    Text(verbatim: unit)
                        .font(StrandFont.book(10))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                if ready, let d = c.direction {
                    PhIcon(d > 0 ? "arrow-up" : (d < 0 ? "arrow-down" : "minus"), size: 11)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.leading, 4)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 74, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(c.label) + Text(verbatim: ", \(c.value)\(c.unit.map { " \($0)" } ?? ""), \(word)"))
    }

    /// Resolve each contributor from the latest day against the baseline mean of prior nights.
    /// HRV and Sleep score higher when above baseline; Resting HR and Respiratory score higher
    /// when at/below baseline (lower is better). Strength is a centred 0–100 (baseline ≈ 70).
    private func buildContributors(_ latest: DailyMetric?) -> [Contributor] {
        let hrvBase  = baseline { $0.avgHrv }
        let rhrBase  = baseline { $0.restingHr.map(Double.init) }
        let sleepBase = baseline { $0.totalSleepMin }
        let respBase = baseline { $0.respRateBpm }
        let rhr = latest?.restingHr.map(Double.init)

        return [
            Contributor(
                label: "HRV",
                strength: higherIsBetter(latest?.avgHrv, base: hrvBase),
                word: word(higherIsBetter(latest?.avgHrv, base: hrvBase)),
                value: latest?.avgHrv.map { "\(Int($0.rounded()))" } ?? "—", unit: "ms",
                baseline: hrvBase.map { "\(Int($0.rounded())) ms" },
                direction: direction(latest?.avgHrv, base: hrvBase)),
            Contributor(
                label: "Resting HR",
                strength: lowerIsBetter(rhr, base: rhrBase),
                word: word(lowerIsBetter(rhr, base: rhrBase)),
                value: latest?.restingHr.map { "\($0)" } ?? "—", unit: "bpm",
                baseline: rhrBase.map { "\(Int($0.rounded())) bpm" },
                direction: direction(rhr, base: rhrBase)),
            Contributor(
                label: "Sleep",
                strength: higherIsBetter(latest?.totalSleepMin, base: sleepBase),
                word: word(higherIsBetter(latest?.totalSleepMin, base: sleepBase)),
                value: latest?.totalSleepMin.map { sleepText($0) } ?? "—", unit: nil,
                baseline: sleepBase.map { sleepText($0) },
                direction: direction(latest?.totalSleepMin, base: sleepBase)),
            Contributor(
                label: "Respiratory",
                strength: lowerIsBetter(latest?.respRateBpm, base: respBase),
                word: word(lowerIsBetter(latest?.respRateBpm, base: respBase)),
                value: latest?.respRateBpm.map { String(format: "%.1f", $0) } ?? "—", unit: "rpm",
                baseline: respBase.map { String(format: "%.1f rpm", $0) },
                direction: direction(latest?.respRateBpm, base: respBase)),
        ]
    }

    /// Mean of a per-day column across prior nights (excludes the latest day so "vs baseline"
    /// compares the latest reading against history). nil until enough nights exist.
    private func baseline(_ key: (DailyMetric) -> Double?) -> Double? {
        let prior = repo.days.dropLast().compactMap(key).filter { $0 > 0 }
        guard prior.count >= Baselines.minNightsSeed else { return nil }
        return prior.reduce(0, +) / Double(prior.count)
    }

    /// Which way the raw reading sits from its baseline: within ±2 % reads as level.
    private func direction(_ value: Double?, base: Double?) -> Int? {
        guard let value, let base, base > 0 else { return nil }
        let ratio = value / base
        if ratio > 1.02 { return 1 }
        if ratio < 0.98 { return -1 }
        return 0
    }

    /// Centre a "higher is better" reading on a 0…100 strength: at baseline → 70, scaling up to
    /// 100 by ~+30% above and down to 0 by ~-40% below. nil inputs return nil (no bar fill).
    private func higherIsBetter(_ value: Double?, base: Double?) -> Double? {
        guard let value, let base, base > 0 else { return nil }
        let ratio = value / base
        return clampStrength(70 + (ratio - 1) * 100)
    }
    /// Centre a "lower is better" reading (RHR, respiratory) — at baseline → 70, better as it falls.
    private func lowerIsBetter(_ value: Double?, base: Double?) -> Double? {
        guard let value, let base, base > 0 else { return nil }
        let ratio = value / base
        return clampStrength(70 - (ratio - 1) * 200)
    }
    private func clampStrength(_ v: Double) -> Double { min(100, max(0, v)) }

    /// The qualitative word for the spoken label — banded like the contributor strengths.
    private func word(_ strength: Double?) -> String {
        guard let s = strength else { return "—" }
        switch s {
        case ..<40:  return String(localized: "Low")
        case ..<60:  return String(localized: "Fair")
        case ..<78:  return String(localized: "Good")
        default:     return String(localized: "Strong")
        }
    }

    private func sleepText(_ minutes: Double) -> String {
        let m = max(0, Int(minutes.rounded()))
        return "\(m / 60)h \(m % 60)m"
    }
}

// MARK: - Fitness Age

/// The "Fitness Age" card under "Weekly scores": a weekly, on-device fitness comparison (NOT a biological
/// age) computed by IntelligenceEngine from the Nes/HUNT model and read back from the "fitness_age"
/// metricSeries under the strap source. Depends only on `repo` (the weekly value + the recent dailies that
/// drive the readiness checklist) and `profile` (age/sex/waist), so the ~1Hz live HR stream never
/// re-renders it.
///
/// Two states, both honest about coverage:
///   • a value exists → the dot-matrix age, the distance from the calendar age, a tick scale marking both,
///     VO₂max and the 8-week change; tappable through to the metric's full trend, with an "How accurate
///     is this?" disclosure that reveals the readiness checklist.
///   • no value yet → the checklist card directly, with required-missing inputs deep-linking to Settings.
///
/// The checklist groups inputs by ROLE exactly as the engine reports them: "Drives your Fitness Age"
/// (age/sex/resting-HR/activity) vs "Sharpens your VO₂max" (height+weight/waist) — never implying the body
/// measurements sharpen the age (the body term cancels in the model).
private struct FitnessAgeSection: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    /// Drives the not-ready card's "refresh Fitness Age" button (force an immediate recompute).
    @EnvironmentObject var intelligence: IntelligenceEngine

    /// Latest weekly Fitness Age (years) read from the "fitness_age" metricSeries, nil until loaded/computed.
    @State private var fitnessAge: Double?
    /// The day key of that latest weekly value (the "Week of …" caption).
    @State private var fitnessAgeDay: String?
    /// The weekly value about eight weeks before the latest one, for the change metric. nil without history.
    @State private var fitnessAgeEightWeeksAgo: Double?
    /// Latest estimated VO₂max (ml/kg/min) from "vo2max_est" — present even without a waist (the Uth
    /// HR-ratio fallback, #1391); a waist upgrades it to the more accurate Nes waist-based estimate.
    @State private var vo2max: Double?
    /// Estimator captured beside the latest value. nil is an honest legacy-unknown state, never inferred
    /// from today's waist because the profile may have changed since the point was scored.
    @State private var vo2maxEstimator: Vo2MaxEstimator?
    @State private var loaded = false
    /// True while a manual "refresh Fitness Age" recompute is running (spinner in the readiness card).
    @State private var refreshing = false

    /// Reveal the readiness checklist (the "How accurate is this?" disclosure under a shown value).
    @State private var showReadiness = false

    /// The two drill-downs this section can present, as ONE enum-driven sheet — two stacked
    /// `.sheet` modifiers race on macOS (only one wins) and neither carried a fixed frame, so a
    /// single item-driven sheet (mirrors WorkoutsView / FusedRecordView) is the reliable idiom.
    /// - `.trend`: the full metric trend (existing MetricDetailView for "fitness_age").
    /// - `.settings`: Settings (the profile card) so a required-missing input can be filled in place.
    private enum FitnessSheet: String, Identifiable {
        case trend, settings
        var id: String { rawValue }
    }
    @State private var fitnessSheet: FitnessSheet?

    /// The catalog descriptor backing the trend sheet + accent.
    private var fitnessAgeMetric: MetricDescriptor? { MetricCatalog.all.first { $0.key == "fitness_age" } }

    /// Build the readiness verdict from the same signals IntelligenceEngine feeds the engine: the last 7
    /// computed/imported days give the resting-HR + activity coverage counts; the profile gives the rest.
    private var readiness: FitnessAgeReadiness {
        let last7 = repo.days.suffix(7)
        let rhrDays = last7.compactMap { $0.restingHr }.count
        let activityDays = last7.compactMap { $0.strain }.count
        return FitnessAgeEngine.assessReadiness(
            hasAge: profile.age > 0,
            hasSex: !profile.sex.isEmpty,
            rhrDays: rhrDays,
            activityDays: activityDays,
            hasHeightWeight: profile.heightCm > 0 && profile.weightKg > 0,
            hasWaist: profile.waistCm > 0)
    }

    /// The not-ready card's lead — delegates to the file-scope `fitnessReadyLeadCopy(rhrDays:hasAge:hasSex:)`,
    /// shared with the Today card's `MetricDetailView` tap-through so both surfaces show the SAME countdown.
    private func fitnessReadyLead() -> String {
        fitnessReadyLeadCopy(
            rhrDays: repo.days.suffix(7).compactMap { $0.restingHr }.count,
            hasAge: profile.age > 0, hasSex: !profile.sex.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("Weekly scores") {
                if let day = fitnessAgeDay, let label = weekOfLabel(day) {
                    Text("Week of \(label)")
                }
            }
            content
        }
        .sheet(item: $fitnessSheet) { which in
            NavigationStack {
                switch which {
                case .trend:
                    if let m = fitnessAgeMetric { MetricDetailView(metric: m) }
                case .settings:
                    SettingsView()
                }
            }
            #if os(macOS)
            .frame(width: 900, height: 820)
            #endif
        }
        .task(id: repo.refreshSeq) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let age = fitnessAge {
            valueCard(age: age)
        } else if loaded {
            // No value yet: lead with a concrete countdown ("N more nights of wear…") so the user knows
            // how far off it is, then the checklist shows exactly what's still needed.
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    NoopCardHeader("Fitness age", icon: "hourglass", captionKey: "Weekly")
                    ReadinessChecklist(
                        readiness: readiness,
                        lead: fitnessReadyLead(),
                        onFix: { fitnessSheet = .settings },
                        onRefresh: {
                            guard !refreshing else { return }
                            refreshing = true
                            Task {
                                _ = await intelligence.recomputeFitnessAgeOnly()
                                await load()
                                refreshing = false
                            }
                        },
                        refreshing: refreshing)
                }
            }
        } else {
            // Brief read of the weekly value; honest placeholder rather than an empty gap.
            G5EmptyCard(icon: "hourglass", message: Text("Reading your Fitness Age…"))
        }
    }

    /// The younger/older-than-your-age subtitle as whole-phrase variants per count and direction, so
    /// translators see complete sentences (never a stitched plural or direction fragment).
    private func ageDeltaLine(years: Int, younger: Bool, bound: String = "") -> String {
        // A bounded reading can only be stated as a direction, never as a distance: the true age is at
        // or beyond the bound, so a plain "N years younger" would present a floor as a measurement.
        // "At least N" is the same number said truthfully, and where there is no safe distance to give
        // (a chronological age at or inside the bound) the line states the bound on its own.
        if bound == "≤" {
            if younger && years == 1 { return String(localized: "At least 1 year younger than your age") }
            if younger && years > 1 { return String(localized: "At least \(years) years younger than your age") }
            return String(localized: "\(Int(FitnessAgeEngine.minAge)) or younger")
        }
        if bound == "≥" {
            if !younger && years == 1 { return String(localized: "At least 1 year older than your age") }
            if !younger && years > 1 { return String(localized: "At least \(years) years older than your age") }
            return String(localized: "\(Int(FitnessAgeEngine.maxAge)) or older")
        }
        if years == 0 { return String(localized: "About the same as your age") }
        switch (younger, years == 1) {
        case (true, true):   return String(localized: "1 year younger than your age")
        case (true, false):  return String(localized: "\(years) years younger than your age")
        case (false, true):  return String(localized: "1 year older than your age")
        case (false, false): return String(localized: "\(years) years older than your age")
        }
    }

    /// The short distance read-out beside the number ("4 years below"), whole phrases per count and
    /// direction. A bounded reading falls back to the full bound sentence for the same reason as above.
    private func shortDeltaLine(years: Int, younger: Bool, bound: String) -> String {
        if !bound.isEmpty { return ageDeltaLine(years: years, younger: younger, bound: bound) }
        if years == 0 { return String(localized: "About your age") }
        switch (younger, years == 1) {
        case (true, true):   return String(localized: "1 year below")
        case (true, false):  return String(localized: "\(years) years below")
        case (false, true):  return String(localized: "1 year above")
        case (false, false): return String(localized: "\(years) years above")
        }
    }

    /// The shown-value card: the tappable score block (header, number, distance, tick scale) opens the
    /// full "fitness_age" trend; below it VO₂max and the 8-week change, the waist nudge, and the
    /// "How accurate is this?" disclosure.
    private func valueCard(age: Double) -> some View {
        let shown = Int(age.rounded())
        let bound = fitnessAgeBoundSymbol(age)
        let delta = Double(profile.age) - age        // +ve = fitness age younger than chronological
        let years = Int(abs(delta).rounded())
        let younger = delta >= 0
        return NoopCard {
            VStack(alignment: .leading, spacing: 0) {
                Button { fitnessSheet = .trend } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        NoopCardHeader("Fitness age", icon: "hourglass", captionKey: "Weekly")
                            .padding(.bottom, 14)
                        HStack(alignment: .lastTextBaseline, spacing: 10) {
                            NoopDotNumber("\(bound)\(shown)", size: 58)
                            Text("yrs ± \(Int(FitnessAgeEngine.displayBandYears))")
                                .font(StrandFont.light(13, relativeTo: .footnote))
                                .foregroundStyle(StrandPalette.textSecondary)
                                .padding(.bottom, 5)
                            Spacer(minLength: 8)
                            if profile.age > 0 {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(shortDeltaLine(years: years, younger: younger, bound: bound))
                                        .font(StrandFont.book(15, relativeTo: .body))
                                        .foregroundStyle(StrandPalette.textPrimary)
                                        .multilineTextAlignment(.trailing)
                                    Text("your age of \(profile.age)")
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                }
                                .padding(.bottom, 4)
                            }
                        }
                        if profile.age > 0 {
                            FitnessAgeScale(fitnessAge: age, actualAge: Double(profile.age))
                                .padding(.top, 22)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                // The spoken label carries the bound too, so a screen reader is not told a floored reading is exact.
                .accessibilityLabel("Fitness Age \(bound)\(shown), \(ageDeltaLine(years: years, younger: younger, bound: bound)). Tap to see the trend.")

                metricsRow
                    .padding(.top, 14)
                    .overlay(alignment: .top) { Rectangle().fill(NoopVisualStyle.border).frame(height: 1) }
                    .padding(.top, 18)

                // At a bound the age has stopped carrying information: every model output past the end of
                // the scale banks as the same number, so someone still improving sees nothing move (#2184).
                // The VO₂max beside it is NOT clamped and is the same estimate this age derives from, so it
                // keeps resolving where the age cannot.
                if !bound.isEmpty, vo2max != nil {
                    Text("Fitness Age stops here. VO₂max keeps moving.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.top, 10)
                }

                // Nudge on WAIST being unset (the sole gate). VO₂max is already shown (the Uth fallback), so
                // the prompt offers to sharpen it to the Nes waist-based estimate, not to reveal a missing number.
                if profile.waistCm <= 0 { vo2maxSharpenPrompt.padding(.top, 14) }

                disclosure
                    .padding(.top, 14)
            }
        }
    }

    /// VO₂max (with its estimator) and the change against the weekly value about eight weeks earlier.
    @ViewBuilder private var metricsRow: some View {
        NoopMetricRow {
            if let vo2 = vo2max {
                NoopMetric(value: String(format: "%.0f", vo2), unit: "ml/kg/min",
                           labelText: "VO₂max · \(vo2MaxEstimatorDisplayName(vo2maxEstimator))")
            } else {
                NoopMetric(value: "—", unit: nil, label: "VO₂max estimate")
            }
            if let now = fitnessAge, let then = fitnessAgeEightWeeksAgo {
                let change = now - then
                NoopMetric(value: (change < 0 ? "−" : (change > 0 ? "+" : "±")) + String(format: "%.1f", abs(change)),
                           unit: String(localized: "yrs"), label: "vs 8 weeks ago")
            }
        }
    }

    /// VO₂max is already shown from heart rate alone (the Uth fallback), so this nudges the user to add a
    /// waist to upgrade it to the more accurate Nes waist-based estimate. Tapping opens Settings — a
    /// one-step sharpen, shown only while no waist is set.
    private var vo2maxSharpenPrompt: some View {
        Button { fitnessSheet = .settings } label: {
            HStack(spacing: 10) {
                PhIcon("ruler", size: 15)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("Add your waist for a more accurate VO₂max")
                    .font(StrandFont.light(12.5, relativeTo: .footnote))
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
                PhIcon("caret-right", size: 13)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Settings to add your waist measurement")
    }

    /// The honest disclosure: what we have / what we still need, grouped by what it unlocks.
    @ViewBuilder private var disclosure: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(StrandMotion.interactive) { showReadiness.toggle() }
            } label: {
                HStack(spacing: 10) {
                    PhIcon("info", size: 15)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text("How accurate is this?")
                        .font(StrandFont.light(12.5, relativeTo: .footnote))
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    PhIcon(showReadiness ? "caret-up" : "caret-down", size: 13)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Whole-string key per variant (never a stitched Hide/Show fragment).
            .accessibilityLabel(showReadiness
                ? "How accurate is this? Hide the data behind your Fitness Age"
                : "How accurate is this? Show the data behind your Fitness Age")

            if showReadiness {
                VStack(alignment: .leading, spacing: 14) {
                    Text("± \(Int(FitnessAgeEngine.displayBandYears)) yr · a fitness comparison, not a biological age")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    ReadinessChecklist(readiness: readiness, lead: nil, onFix: { fitnessSheet = .settings })
                }
                .transition(.opacity)
            }
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(NoopVisualStyle.border).frame(height: 1) }
    }

    /// "28 Sep" — the first day of the week holding the latest weekly value.
    private func weekOfLabel(_ day: String) -> String? {
        guard let date = Self.dayParser.date(from: day),
              let start = Calendar.current.dateInterval(of: .weekOfYear, for: date)?.start else { return nil }
        return start.formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale))
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Load the latest weekly Fitness Age (+ optional VO₂max) from the strap's metricSeries. Uses the
    /// same `exploreSeries(key:source:)` path every other metric on this screen reads, with source
    /// "my-whoop" (the Repository merges the computed "-noop" rows under any real import). Takes the
    /// freshest point — the weekly value is keyed to the week's Saturday and refines through the week.
    private func load() async {
        let faPts = await repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        let vo2Resolution = await repo.resolvedSeries(key: "vo2max_est", source: "my-whoop")
        fitnessAge = faPts.last?.value
        fitnessAgeDay = faPts.last?.day
        // The weekly value nearest to (at or before) eight weeks before the latest one.
        if let last = faPts.last, let lastDate = Self.dayParser.date(from: last.day),
           let target = Calendar.current.date(byAdding: .day, value: -56, to: lastDate) {
            let targetKey = Self.dayParser.string(from: target)
            fitnessAgeEightWeeksAgo = faPts.last(where: { $0.day <= targetKey })?.value
        } else {
            fitnessAgeEightWeeksAgo = nil
        }
        if let latest = vo2Resolution.points.last {
            vo2max = latest.value
            let tag = await repo.scoreProvenanceTag(
                resolvedSource: latest.source, day: latest.day, metricKey: "vo2max_est")
            vo2maxEstimator = tag.flatMap { Vo2MaxEstimator(rawValue: $0) }
        } else {
            vo2max = nil
            vo2maxEstimator = nil
        }
        loaded = true
    }
}

/// The Fitness Age tick scale: 1 pt ticks across a span around both ages, a glowing marker at the
/// fitness age and a dashed marker at the calendar age, with both labelled underneath.
private struct FitnessAgeScale: View {
    let fitnessAge: Double
    let actualAge: Double

    /// The span shown: at least ±6 years beyond both ages, snapped out to multiples of five.
    private var span: ClosedRange<Double> {
        var lo = ((min(fitnessAge, actualAge) - 6) / 5).rounded(.down) * 5
        var hi = ((max(fitnessAge, actualAge) + 6) / 5).rounded(.up) * 5
        if hi - lo < 20 { lo -= 5; hi += 5 }
        return lo...hi
    }

    private func position(_ v: Double) -> Double {
        let s = span
        return min(max((v - s.lowerBound) / (s.upperBound - s.lowerBound), 0), 1)
    }

    var body: some View {
        let pf = position(fitnessAge), pa = position(actualAge)
        VStack(spacing: 8) {
            NoopTickScale(marker: pf, height: 20)
                .overlay {
                    GeometryReader { geo in
                        Path { p in
                            let x = geo.size.width * pa
                            p.move(to: CGPoint(x: x, y: -6))
                            p.addLine(to: CGPoint(x: x, y: geo.size.height + 6))
                        }
                        .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                }
            GeometryReader { geo in
                let w = geo.size.width
                // Two marker labels closer than this would overlap, so they merge into one.
                let close = abs(pf - pa) * w < 70
                let half: CGFloat = close ? 62 : 30
                let centres = close ? [clampX((pf + pa) / 2 * w, w: w, half: half)]
                                    : [clampX(pf * w, w: w, half: half), clampX(pa * w, w: w, half: half)]
                let leftEdge = (centres.min() ?? 0) - half
                let rightEdge = (centres.max() ?? w) + half
                ZStack(alignment: .topLeading) {
                    // End labels, dropped where a marker label would collide with them.
                    if leftEdge > 24 {
                        Text(verbatim: "\(Int(span.lowerBound))").fixedSize()
                    }
                    if w - rightEdge > 24 {
                        Text(verbatim: "\(Int(span.upperBound))").fixedSize()
                            .frame(width: w, alignment: .trailing)
                    }
                    if close {
                        (Text("\(Int(fitnessAge.rounded())) fitness") + Text(verbatim: " · ")
                            + Text("\(Int(actualAge)) actual"))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize()
                            .position(x: centres[0], y: 7)
                    } else {
                        Text("\(Int(fitnessAge.rounded())) fitness")
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize()
                            .position(x: centres[0], y: 7)
                        Text("\(Int(actualAge)) actual")
                            .fixedSize()
                            .position(x: centres[1], y: 7)
                    }
                }
            }
            .frame(height: 14)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityHidden(true)
    }

    private func clampX(_ x: CGFloat, w: CGFloat, half: CGFloat) -> CGFloat {
        min(max(x, half), w - half)
    }
}

/// The Fitness Age not-ready lead: a concrete countdown of nights-of-wear still needed (from the shared
/// `nightsUntilReady`), noting the profile basics only when they're actually missing. File-scope (not a
/// view method) so BOTH the Health hub's Fitness Age card and the Today card's `MetricDetailView`
/// tap-through render the SAME copy from one source. Kept WORD-FOR-WORD identical to the Android
/// `fitnessReadyLead` so the two platforms match.
func fitnessReadyLeadCopy(rhrDays: Int, hasAge: Bool, hasSex: Bool) -> String {
    let remaining = FitnessAgeEngine.nightsUntilReady(rhrDays: rhrDays)
    let needsBasics = !hasAge || !hasSex
    switch (remaining, needsBasics) {
    case (0, false): return String(localized: "A few more days and we can show your Fitness Age.")
    case (0, true):  return String(localized: "Add your age and sex below and we can show your Fitness Age.")
    case (1, false): return String(localized: "1 more night of wear and we can show your Fitness Age.")
    case (1, true):  return String(localized: "1 more night of wear, plus your age and sex below, and we can show your Fitness Age.")
    case (let n, false): return String(localized: "\(n) more nights of wear and we can show your Fitness Age.")
    case (let n, true):  return String(localized: "\(n) more nights of wear, plus your age and sex below, and we can show your Fitness Age.")
    }
}

/// The readiness checklist: an optional lead line, then the engine's `items` as status rows with their
/// `detail` text, GROUPED by `.role` into "Drives your Fitness Age" and "Sharpens your VO₂max".
/// A required-but-missing input shows a "Fix in Settings" affordance (the engine's required+missing
/// rows are age/sex; resting-HR can only be earned by wearing the strap, so it gets no fix button).
/// Card-less, so it reads inside the Fitness Age card both as the disclosure and as the not-ready state.
private struct ReadinessChecklist: View {
    let readiness: FitnessAgeReadiness
    /// Optional intro line shown above the groups (e.g. the "a few more days" no-value message).
    /// Already-localized text (from `fitnessReadyLead()`, which returns `String(localized:)`), so it's a
    /// plain `String` rendered verbatim — not a `LocalizedStringKey` (which would re-key a resolved string).
    let lead: String?
    /// Invoked when the user taps a required-missing row's "Fix in Settings".
    let onFix: () -> Void
    /// Optional force-recompute action (the "refresh Fitness Age" button, not-ready state only);
    /// `refreshing` swaps it for a spinner while the recompute runs. nil = no button.
    var onRefresh: (() -> Void)? = nil
    var refreshing: Bool = false

    private var drivesAge: [FitnessReadinessItem] { readiness.items.filter { $0.role == .drivesAge } }
    private var unlocksVO2: [FitnessReadinessItem] { readiness.items.filter { $0.role == .unlocksVO2max } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                confidencePill
                Spacer(minLength: 0)
                // Force-recompute affordance: NOOP scores Fitness Age weekly, so this applies it NOW
                // from stored data. Spinner while it runs.
                if let onRefresh {
                    if refreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        NoopCircleButton("arrows-clockwise", size: 34,
                                         accessibilityLabel: "Refresh Fitness Age now", action: onRefresh)
                    }
                }
            }
            if let lead {
                Text(lead)
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            group(title: "Drives your Fitness Age", items: drivesAge)
            group(title: "Sharpens your VO₂max", items: unlocksVO2)
            Text("Built from published methods (Nes/HUNT) on \(Platform.deviceNounPhrase). It's a fitness comparison against an average peer your age, not a biological or medical age.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The overall confidence chip, mapped onto the existing score-lifecycle pill vocabulary.
    @ViewBuilder private var confidencePill: some View {
        switch readiness.confidence {
        case .ready:    ScoreStatePill(.solid, text: "Ready")
        case .estimate: ScoreStatePill(.building, text: "Estimate (partial data)")
        case .notReady: ScoreStatePill(.calibrating, text: "Not enough data yet")
        }
    }

    @ViewBuilder
    private func group(title: LocalizedStringKey, items: [FitnessReadinessItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                NoopOverline(title)
                ForEach(items, id: \.key) { item in
                    readinessRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private func readinessRow(_ item: FitnessReadinessItem) -> some View {
        // A required/optional input that's still unsatisfied earns a "Fix in Settings" affordance, but
        // only when it's actually fixable there (age/sex/body metrics/waist) — resting-HR and activity
        // coverage come from wearing the strap, so those get no fix button.
        let fixable = item.status != .satisfied
            && (item.key == "age" || item.key == "sex" || item.key == "bodyMetrics" || item.key == "waist")
        let row = HStack(alignment: .top, spacing: 12) {
            PhIcon(statusIcon(item.status), weight: item.status == .missing ? .light : .fill, size: 16)
                .foregroundStyle(item.status == .missing ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .frame(width: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(StrandFont.book(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(item.detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
            if fixable {
                Button(action: onFix) {
                    Text("Fix in Settings")
                        .font(StrandFont.book(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
                        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.label): \(item.detail). Fix in Settings.")
            }
        }
        // When a Fix button is present keep it as its own VoiceOver stop (.contain); otherwise fold the
        // whole row into one labelled stop. Two branches so we never pass a nil accessibility label.
        if fixable {
            row.accessibilityElement(children: .contain)
        } else {
            row
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.label), \(statusWord(item.status)). \(item.detail)")
        }
    }

    private func statusIcon(_ s: FitnessReadinessStatus) -> String {
        switch s {
        case .satisfied: return "check-circle"
        case .partial:   return "warning-circle"
        case .missing:   return "circle"
        }
    }
    private func statusWord(_ s: FitnessReadinessStatus) -> String {
        switch s {
        case .satisfied: return String(localized: "ready")
        case .partial:   return String(localized: "partial")
        case .missing:   return String(localized: "missing")
        }
    }
}

// MARK: - Vitality / Body Age

/// The "Vitality" card: a weekly wellness score (0–100) + a Body Age in years, computed by
/// IntelligenceEngine from the published mortality-hazard model and read back from the metricSeries.
/// A wellness trend from your habits — NOT a clinical biological age. Recomputes the live best/worst
/// factor the same way the engine does, for the plain-English "why".
private struct VitalitySection: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @State private var vitality: Double?
    @State private var bodyAge: Double?
    @State private var loaded = false

    private var contributions: [VitalityEngine.Contribution] {
        let last7 = repo.days.suffix(7)
        let nights = last7.compactMap { $0.totalSleepMin }.map { Double($0) / 60.0 }.filter { $0 > 0 }
        let hrvs = last7.compactMap { $0.avgHrv }
        let rhrs = last7.compactMap { $0.restingHr }.map(Double.init)
        let steps = last7.compactMap { $0.steps }.map(Double.init)
        func mean(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
        // Aggregate EXACTLY as the stored headline does (IntelligenceEngine), so this "what's driving it"
        // breakdown reconciles with the Vitality / Body Age number it explains rather than being recomputed
        // on different statistics: resting HR + HRV are MEDIANED (robust to one outlier night), sleep +
        // steps are MEANED.
        return VitalityEngine.contributions(.init(
            chronoAge: Double(profile.age),
            restingHR: rhrs.isEmpty ? nil : IntelligenceEngine.medianOf(rhrs),
            sleepHours: mean(nights),
            sleepConsistency: VitalityEngine.sleepConsistency(nightlyHours: nights),
            rmssd: hrvs.isEmpty ? nil : IntelligenceEngine.medianOf(hrvs),
            rmssdNorm: VitalityEngine.rmssdNorm(forAge: Double(profile.age)),
            steps: mean(steps)))
    }

    var body: some View {
        Group {
            if let v = vitality, let ba = bodyAge {
                card(vitality: v, bodyAge: ba)
            } else if loaded {
                G5EmptyCard(icon: "heart-half", message: Text("A few more days and we can show your Vitality."))
            } else {
                G5EmptyCard(icon: "heart-half", message: Text("Reading your Vitality…"))
            }
        }
        .task(id: repo.refreshSeq) { await load() }
    }

    private func card(vitality v: Double, bodyAge ba: Double) -> some View {
        let delta = Double(profile.age) - ba
        let younger = delta >= 0
        let yrs = Int(abs(delta).rounded())
        let sorted = contributions.sorted { $0.lnHazard < $1.lnHazard }
        let best = sorted.first.flatMap { $0.lnHazard < 0 ? $0 : nil }
        let worst = sorted.last.flatMap { $0.lnHazard > 0 ? $0 : nil }
        return NoopCard {
            VStack(alignment: .leading, spacing: 0) {
                NoopCardHeader("Vitality", icon: "heart-half", captionKey: "Weekly")
                    .padding(.bottom, 14)
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    NoopDotNumber("\(Int(v.rounded()))", size: 58)
                        .accessibilityLabel("Vitality \(Int(v.rounded())) out of 100")
                    Text("of 100")
                        .font(StrandFont.light(13, relativeTo: .footnote))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .padding(.bottom, 5)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(verbatim: "\(Int(ba.rounded()))")
                                .font(StrandFont.value(21))
                                .tracking(-0.42)
                            Text("yrs")
                                .font(StrandFont.book(10))
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Text("Body Age")
                            .font(StrandFont.light(10.5))
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text(bodyAgeDeltaLine(yrs: yrs, younger: younger))
                            .font(StrandFont.light(10.5))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.bottom, 4)
                    .accessibilityElement(children: .combine)
                }
                NoopTrack(fraction: v / 100, height: 10)
                    .padding(.top, 18)
                if best != nil || worst != nil {
                    // Two equal columns even when only one factor applies, so a lone tile keeps its size.
                    HStack(alignment: .top, spacing: 10) {
                        if let best { factorTile(best, helping: true) }
                        if let worst { factorTile(worst, helping: false) }
                        if best == nil || worst == nil { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                    }
                    .padding(.top, 16)
                }
                Text("A wellness estimate from your habits, not a clinical biological age.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.top, 14)
            }
        }
    }

    /// One "Helping most" / "Holding you back" tile.
    private func factorTile(_ c: VitalityEngine.Contribution, helping: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PhIcon(helping ? "arrow-up-right" : "arrow-down-right", size: 13)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .padding(.bottom, 10)
            Group { helping ? Text("Helping most") : Text("Holding you back") }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            // The engine's label is a fixed English name; routed through the catalogue so it reads in the
            // app's language.
            Text(LocalizedStringKey(c.label))
                .font(StrandFont.book(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(NoopVisualStyle.inset))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    /// The Body Age delta as whole-phrase variants per count and direction, so translators see
    /// complete phrases (never a stitched plural or direction fragment).
    private func bodyAgeDeltaLine(yrs: Int, younger: Bool) -> String {
        if yrs == 0 { return String(localized: "about your age") }
        switch (younger, yrs == 1) {
        case (true, true):   return String(localized: "1 yr younger")
        case (true, false):  return String(localized: "\(yrs) yrs younger")
        case (false, true):  return String(localized: "1 yr older")
        case (false, false): return String(localized: "\(yrs) yrs older")
        }
    }

    private func load() async {
        vitality = (await repo.exploreSeries(key: "vitality", source: "my-whoop")).last?.value
        bodyAge = (await repo.exploreSeries(key: "body_age", source: "my-whoop")).last?.value
        loaded = true
    }
}

// MARK: - Vital signs grid

/// The vital-signs grid, split into its own view so it depends only on `repo` and is
/// not re-rendered by the ~1Hz live HR stream. Each tile opens the metric's detail.
private struct VitalsSection: View {
    @EnvironmentObject var repo: Repository

    // Temperature display preference (D#103). Skin temp is stored in °C (absolute or a ±deviation); the
    // toggle re-labels it to °F. Display-only — banding still runs on the stored °C value.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.skinTempDisplayKey) private var skinTempDisplayRaw = ""   // #1846
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    private var temperatureUnit: TemperatureUnit {
        let system = UnitSystem(rawValue: unitSystemRaw) ?? .metric
        return UnitPrefs.resolveTemperature(system: system, override: temperatureRaw)
    }

    // #103/queue-11a: SpO₂ candidate nightly means from metricSeries — WHOOP `spo2_candidate_82`, or an
    // Oura owner's ceiling@100 `0x6F` mean (device-conditional, see IntelligenceEngine) — loaded when
    // the experimental toggle is ON. Empty when the toggle is OFF or no candidate data exists.
    @State private var spo2CandidateByDay: [String: Double] = [:]
    @State private var hrvOverCountByDay: [String: Double] = [:]   // #1118

    /// The vital whose detail sheet is open.
    @State private var detail: VitalDetailTarget?

    var body: some View {
        let readings = BodyVitalSigns.readings(
            sourceRows: repo.vitalMetricRows,
            temperatureUnit: temperatureUnit,
            spo2CandidateByDay: spo2CandidateByDay,
            hrvOverCountByDay: hrvOverCountByDay,
            skinTempPreferred: SkinTempDisplay.Kind(rawValue: skinTempDisplayRaw) ?? .absolute   // #1846
        )
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("Vital signs") {
                if let day = BodyVitalSigns.latestDayLabel(readings) {
                    Text("Latest") + Text(verbatim: " · \(day)")
                }
            }
            Grid(horizontalSpacing: NoopMetrics.gap, verticalSpacing: NoopMetrics.gap) {
                ForEach(Array(stride(from: 0, to: readings.count, by: 2)), id: \.self) { i in
                    GridRow {
                        tile(readings[i])
                        if i + 1 < readings.count {
                            tile(readings[i + 1])
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
            Text("Once NOOP has 14 nights of history, in-range compares each vital to your own baseline (approximate, not medical advice); until then, typical adult ranges apply.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, -2)
        }
        .sheet(item: $detail) { target in
            NavigationStack { MetricDetailView(metric: target.metric) }
            #if os(macOS)
            .frame(width: 900, height: 820)
            #endif
        }
        .task(id: PuffinExperiment.spo2CandidateDisplayEnabled) {
            // #1118: load the per-night HRV over-count flags (always — no toggle) so the HRV tile can
            // caption an over-counted 4.0 night's reading "unverified". The engine writes "hrv_rr_overcount"
            // (1/0) under the "-noop" computed device ID; `exploreSeries` with source "my-whoop" reads it
            // from the computed metricSeries. Absent/0 on a clean or imported night → no caveat.
            let ocPts = await repo.exploreSeries(key: "hrv_rr_overcount", source: "my-whoop", days: 14)
            hrvOverCountByDay = Dictionary(ocPts.map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
            // #103/queue-11a: load the SpO₂ candidate nightly means from metricSeries when the toggle is
            // ON. The engine writes "spo2_candidate" under the "-noop" computed device ID; `exploreSeries`
            // with source "my-whoop" reads it from Layer 2 (computed metricSeries) — "my-whoop" is the
            // generic active-strap sentinel, resolved through `computedReadIds`, so this already covers
            // an Oura ring's own computed id. Empty when the toggle is OFF (the engine writes nothing) or
            // the owner has no in-band reading for its device.
            guard PuffinExperiment.spo2CandidateDisplayEnabled else {
                spo2CandidateByDay = [:]
                return
            }
            let pts = await repo.exploreSeries(key: "spo2_candidate", source: "my-whoop", days: 14)
            spo2CandidateByDay = Dictionary(pts.map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// A tile, tappable through to the metric detail when the catalog carries that vital.
    @ViewBuilder private func tile(_ reading: BodyVitalReading) -> some View {
        if let metric = VitalDetailTarget.metric(forVital: reading.key) {
            Button { detail = VitalDetailTarget(metric: metric) } label: { VitalTile(reading: reading) }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the trend")
        } else {
            VitalTile(reading: reading)
        }
    }
}

/// The metric a vital tile opens.
private struct VitalDetailTarget: Identifiable {
    let metric: MetricDescriptor
    var id: String { metric.id }

    /// The catalog metric for a `BodyVitalReading.key` (strap source). Raw SpO₂ has no catalog entry.
    static func metric(forVital key: String) -> MetricDescriptor? {
        let catalogKey: String
        switch key {
        case "resp": catalogKey = "resp_rate"
        case "spo2": catalogKey = "spo2"
        case "rhr":  catalogKey = "rhr"
        case "hrv":  catalogKey = "hrv"
        case "skin": catalogKey = "skin_temp"
        default:     return nil
        }
        return MetricCatalog.all.first { $0.key == catalogKey }
    }
}

// MARK: - Vital tile

/// One vital sign: an icon + label header, the value, a dot-matrix state tag and the reading's caption
/// (day · source · state, plus any caveat). Presentation-only: value, banding and source are unchanged.
private struct VitalTile: View {
    let reading: BodyVitalReading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                PhIcon(icon, size: 15).opacity(0.9)
                Text(verbatim: reading.label)
                    .font(StrandFont.book(13, relativeTo: .footnote))
                    .lineLimit(1)
            }
            .foregroundStyle(StrandPalette.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: reading.value.map { reading.format($0) } ?? "—")
                    .font(StrandFont.value(27, weight: 300))
                    .tracking(-0.54)
                    .foregroundStyle(StrandPalette.textPrimary)
                if reading.value != nil {
                    Text(verbatim: reading.unit)
                        .font(StrandFont.book(11))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.top, 12)
            NoopTag(verbatim: tagWord, size: 10.5)
                .fixedSize()
                .padding(.top, 12)
            Text(verbatim: reading.stateCaption)
                .font(StrandFont.light(10.5, relativeTo: .caption2))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .noopPanel()
        .contentShape(RoundedRectangle(cornerRadius: NoopVisualStyle.cardRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.accessibilityText)
    }

    private var icon: String {
        switch reading.key {
        case "resp":    return "wind"
        case "spo2":    return "drop"
        case "spo2raw": return "drop-half"
        case "rhr":     return "heart"
        case "hrv":     return "wave-sine"
        case "skin":    return "thermometer-simple"
        default:        return "pulse"
        }
    }

    /// The short state word for the tag — the same verdict the caption states, from the same banding.
    private var tagWord: String {
        // Raw SpO₂ is a device-dependent ADC, never judged in or out of range (#93).
        if reading.key == "spo2raw" {
            return reading.banding.band == .noData ? String(localized: "No data") : String(localized: "Uncalibrated")
        }
        switch (reading.banding.band, reading.banding.basis) {
        case (.noData, _):               return String(localized: "No data")
        case (.inRange, .personal):      return String(localized: "In range")
        case (.outOfRange, .personal):   return String(localized: "Off baseline")
        case (.inRange, .population):    return String(localized: "Typical")
        case (.outOfRange, .population): return String(localized: "Outside range")
        }
    }
}

// MARK: - Skin-temperature suite (v5: nightly chart · illness heads-up · body clock · cycle awareness)

/// The v5 skin-temperature section: the last nights' deviation chart, the confounder-suppressed illness
/// "heads-up", the body-clock estimate, and the OPT-IN cycle awareness — each rendered from a pure
/// StrandAnalytics engine result the analytics pass computed and `AppModel` publishes. Honest throughout:
/// the heads-up only shows when the engine returns a non-quiet level; cycle awareness shows the opt-in
/// until the user turns it on (default OFF); the body clock shows nil-state copy until it can read a rhythm.
private struct SkinTempSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var repo: Repository

    /// The cycle-awareness opt-in (default OFF). The same key AppModel reads, so a flip is consistent.
    @AppStorage(AppModel.cycleAwarenessKey) private var cycleEnabled = false
    /// #hide-cycle: the user's "not for me" opt-out. When set, the cycle opt-in invitation is suppressed
    /// here (the section falls back to the generic skin-temp state); reversible from Automations.
    @AppStorage(AppModel.cycleAwarenessHiddenKey) private var cycleHidden = false
    @State private var cycleTrackerPresented = false

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    private var fahrenheit: Bool {
        let system = UnitSystem(rawValue: unitSystemRaw) ?? .metric
        return UnitPrefs.resolveTemperature(system: system, override: temperatureRaw) == .fahrenheit
    }

    /// Whether the cycle-awareness opt-in is offered for this profile (#801). Delegates to the shared
    /// ``ProfileStore/cycleAwarenessApplies`` gate so Health + Automations stay in lockstep: cycle phase
    /// is read from the menstrual skin-temperature shift, so the opt-in is NOT shown for male profiles.
    private var cycleOptInApplies: Bool { model.profile.cycleAwarenessApplies && !cycleHidden }

    /// The last 30 days' nightly skin-temperature DEVIATIONS (the on-device ±°C vs baseline). Imported
    /// absolute temperatures are left out: they have no baseline to sit against.
    private var nights: [(day: String, dev: Double)] {
        repo.days.suffix(30).compactMap { d in
            guard let v = d.skinTempDevC, !VitalBands.isAbsoluteSkinTemp(v) else { return nil }
            return (day: d.day, dev: v)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            chartCard

            // 1. Illness heads-up — only when the engine returned something worth surfacing.
            if let illness = model.illnessSignal, illness.level != .quiet {
                HeadsUpCard(result: illness, distance: model.illnessDistance)
            }

            // 2. Body clock — shows nil-state copy via the engine's own confidence handling.
            if let phase = model.circadianPhase {
                BodyClockCard(estimate: phase)
            }

            // 3. Cycle awareness: opt-in, and gated on profile sex (#801). If a profile that previously
            // enabled it later switches to male, we still honour the existing awareness card rather than
            // silently hiding their data; only the OPT-IN invitation (in the chart card) is gated.
            if cycleEnabled, let cycle = model.cyclePhase {
                CycleAwarenessCard(result: cycle, curve: model.cycleCurve,
                                   onLogPeriod: {
                                       Task {
                                           await repo.logPeriodStart(day: Repository.localDayKey(Date()))
                                           await model.refreshV5Signals()
                                       }
                                   },
                                   onOpenDetail: { cycleTrackerPresented = true },
                                   // Symmetric off (#801): turn it off in-place, here in Health, where
                                   // it was turned on, not only from Automations.
                                   onTurnOff: {
                                       cycleEnabled = false
                                       model.cycleAwarenessEnabled = false
                                       Task { await model.refreshV5Signals() }
                                   })
            }
        }
        .sheet(isPresented: $cycleTrackerPresented) {
            if let cycle = model.cyclePhase {
                CycleTrackerView(result: cycle, curve: model.cycleCurve)
                    .environmentObject(repo)
                    .environmentObject(model)
            }
        }
    }

    /// The nightly chart card, with the cycle-awareness opt-in (or the honest empty note) at its foot.
    private var chartCard: some View {
        let nights = self.nights
        let unit = SkinTempDisplay.unitSymbol(kind: .deviation, fahrenheit: fahrenheit)
        return NoopCard {
            VStack(alignment: .leading, spacing: 0) {
                NoopCardHeader("Skin temperature", icon: "thermometer-simple") {
                    if nights.count > 1 {
                        Text("\(nights.count) nights") + Text(verbatim: " · \(unit) ") + Text("vs baseline")
                    }
                }
                if nights.count > 1 {
                    SkinTempNightsChart(values: nights.map(\.dev), fahrenheit: fahrenheit)
                        .frame(height: 104)
                        .padding(.top, 6)
                    axisLabels(nights)
                        .padding(.leading, 24)
                        .padding(.top, 8)
                }

                // The cycle-awareness opt-in lives at the foot of the chart it would annotate. Shown only
                // while OFF and offered to this profile (#801).
                if !cycleEnabled && cycleOptInApplies {
                    CycleAwarenessOptInCard(onEnable: {
                        cycleEnabled = true
                        model.cycleAwarenessEnabled = true
                        Task { await model.refreshV5Signals() }
                    })
                    .padding(.top, nights.count > 1 ? 16 : 0)
                } else if nights.count < 2 && model.illnessSignal == nil && model.circadianPhase == nil
                            && model.cyclePhase == nil {
                    // Honest empty state when the suite has nothing to show yet.
                    NoopInsightRow("Wear the strap overnight and these read from your nightly skin temperature.",
                                   icon: "info")
                        .padding(.top, 4)
                }
            }
        }
    }

    /// Date captions under the chart: three evenly spaced nights, then the last.
    private func axisLabels(_ nights: [(day: String, dev: Double)]) -> some View {
        let n = nights.count
        let picks = [0, n / 3, (2 * n) / 3].filter { $0 < n - 1 }
        return HStack {
            ForEach(Array(picks.enumerated()), id: \.offset) { i, idx in
                if i > 0 { Spacer(minLength: 4) }
                Text(verbatim: Self.shortDay(nights[idx].day))
            }
            Spacer(minLength: 4)
            Group {
                if nights[n - 1].day == BodyVitalSigns.logicalDayKey(Date()) {
                    Text("Last night")
                } else {
                    Text(verbatim: Self.shortDay(nights[n - 1].day))
                }
            }
            .foregroundStyle(StrandPalette.textPrimary)
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .lineLimit(1)
    }

    private static func shortDay(_ key: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: key) else { return key }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale))
    }
}

/// The nightly skin-temperature deviation chart: a ±1 °C scale with the typical band shaded (the same
/// ±0.6 °C population range the vital tile bands a deviation against), a dashed zero line, the nights as
/// a line + fill, and a cursor on the latest night.
private struct SkinTempNightsChart: View {
    let values: [Double]
    let fahrenheit: Bool

    /// The ±0.6 °C range the skin-temp vital tile uses as its population band for a deviation.
    private static let typicalBand = 0.6

    var body: some View {
        let scale = fahrenheit ? 1.8 : 1.0
        let band = Self.typicalBand * scale
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading) {
                Text(verbatim: SkinTempDisplay.numberString(1, kind: .deviation, fahrenheit: fahrenheit, decimals: fahrenheit ? 1 : 0))
                Spacer()
                Text(verbatim: "0")
                Spacer()
                Text(verbatim: SkinTempDisplay.numberString(-1, kind: .deviation, fahrenheit: fahrenheit, decimals: fahrenheit ? 1 : 0))
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(width: 24, alignment: .leading)
            .padding(.bottom, 2)
            GeometryReader { geo in
                let h = geo.size.height
                let bandTop = h * (0.5 - CGFloat(Self.typicalBand / 2))
                let bandHeight = h * CGFloat(Self.typicalBand)
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.white.opacity(0.045))
                        .frame(height: bandHeight)
                        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1) }
                        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1) }
                        .offset(y: bandTop)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h / 2))
                        p.addLine(to: CGPoint(x: geo.size.width, y: h / 2))
                    }
                    .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    Text("Typical range ±\(SkinTempDisplay.numberString(band, kind: .absolute, fahrenheit: false, decimals: 1))")
                        .font(StrandFont.light(9.5))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .offset(x: 4, y: bandTop - 14)
                    NoopAreaChart(values: values.map { min(max($0, -1), 1) }, range: -1...1,
                                  line: StrandPalette.metricCyan, fill: StrandPalette.effortColor, cursor: 1)
                }
            }
            .padding(.top, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Skin temperature deviation over \(values.count) nights"))
    }
}

// MARK: - Health hub deep-links (Lab Book · Your Data, Fused)

/// The records/sources list: the records logbook (Lab Book) and the multi-device fused record get their
/// honest Health home without making either its own top-level destination — they route via `NavRouter`
/// (the macOS sidebar selects the item; iOS presents the pillar sheet).
private struct HealthHubLinksSection: View {
    @EnvironmentObject var router: NavRouter
    @EnvironmentObject var repo: Repository

    /// Lab Book coverage for the row caption: distinct markers and the latest reading. nil until read.
    @State private var lab: (markers: Int, latest: Int?)?

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("Records & sources", caption: String(localized: "On \(Platform.deviceNounPhrase)"))
            NoopList {
                Button { router.openLabBook() } label: {
                    NoopRow(title: Text("Lab Book"), caption: labCaption, icon: "flask", chevron: true) { EmptyView() }
                }
                .buttonStyle(.plain)
                Button { router.openFusedRecord() } label: {
                    // No trailing "Fused": the title already says it, and in German the repeat squeezed the
                    // title onto two lines.
                    NoopRow(title: Text("Your Data, Fused"),
                            caption: Text("The best-sourced number per metric across every band you use."),
                            icon: "git-merge", chevron: true) { EmptyView() }
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: repo.refreshSeq) { await loadLab() }
    }

    private var labCaption: Text {
        guard let lab, lab.markers > 0 else {
            return Text("Keep your bloods, BP and body numbers private, on \(Platform.deviceNounPhrase).")
        }
        let count = lab.markers == 1 ? Text("1 marker") : Text("\(lab.markers) markers")
        guard let latest = lab.latest else { return count }
        return count + Text(verbatim: " · ") + Text("last reading \(LabBookFormat.day(latest))")
    }

    /// Count the logbook's markers through the same store reads Lab Book itself uses.
    private func loadLab() async {
        guard let store = await repo.storeHandle() else { return }
        var keys = Set<String>()
        var latest: Int?
        for category in LabMarkerCategory.allCases {
            let rows = (try? await store.labMarkers(deviceId: repo.deviceId, category: category.rawValue)) ?? []
            for r in rows {
                keys.insert(r.markerKey)
                latest = max(latest ?? r.takenAt, r.takenAt)
            }
        }
        lab = (keys.count, latest)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Health Monitor") {
    let repo = Repository(deviceId: "preview")
    repo.days = [
        DailyMetric(
            day: "2026-06-06",
            totalSleepMin: 462, efficiency: 92,
            deepMin: 96, remMin: 108, lightMin: 240, disturbances: 7,
            restingHr: 52, avgHrv: 74, recovery: 81, strain: 11.4,
            exerciseCount: 1,
            spo2Pct: 97, skinTempDevC: 34.2, respRateBpm: 14.6
        )
    ]
    repo.loaded = true

    let live = LiveState()
    live.connected = true
    live.bonded = true
    live.heartRate = 132
    live.rr = [455, 460, 448, 470, 452, 461, 449, 458, 463, 451]

    return HealthView()
        .environmentObject(repo)
        .environmentObject(live)
        .environmentObject(ProfileStore())
        .environmentObject(AppModel())
        .environmentObject(NavRouter())
        .environmentObject(IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: "preview"))
        .frame(width: 900, height: 760)
        .preferredColorScheme(.dark)
}

/// Deterministic render target for `--demo-screen fitnessage` (pair with `--demo-seed` to populate the
/// weekly value). Shows the REAL `FitnessAgeSection` on the production scaffold, so a screenshot matches
/// what ships. Reads the same injected `repo`/`profile` environment objects as the live app.
struct FitnessAgeDemoScreen: View {
    var body: some View {
        ScreenScaffold(title: "Health Monitor", subtitle: "Fitness Age", onRefresh: {}) {
            FitnessAgeSection()
        }
    }
}

/// Deterministic render target for `--demo-screen vitality` (pair with `--demo-seed`).
struct VitalityDemoScreen: View {
    var body: some View {
        ScreenScaffold(title: "Health Monitor", subtitle: "Vitality", onRefresh: {}) {
            VitalitySection()
        }
    }
}
#endif

/// The symbol a stored Fitness Age needs when it is sitting on a reporting bound (#2173).
///
/// `FitnessAgeEngine` clamps to [minAge, maxAge], so every model output below 20 is stored as
/// exactly 20.0 and every output above 80 as exactly 80.0. A reader cannot tell either from a
/// genuine 20 or 80, and the number looks as exact as every other number on the screen, which is
/// what makes a floored reading read like a sync or scoring fault rather than the end of the scale.
///
/// Decided from the value rather than carried out of the engine, matching the Kotlin twin. The
/// clamp returns the bound constant itself, so equality is exact and needs no tolerance, and
/// deciding here covers the weekly rows already banked, which no flag added today could reach.
/// A reading that is genuinely 20.0 is therefore also called "20 or younger", which is true of it.
/// Saying "<20" would need the unclamped value, and that is gone before anything is stored.
func fitnessAgeBoundSymbol(_ value: Double) -> String {
    if value <= FitnessAgeEngine.minAge { return "≤" }
    if value >= FitnessAgeEngine.maxAge { return "≥" }
    return ""
}
