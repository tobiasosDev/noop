import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Stages (read-only Today host card) (#today-hosted-cards)
//
// The Sleep tab's "Stages" section is deeply STATEFUL/INTERACTIVE (night ◀/▶ navigation, a wake-time edit
// button, and nap add/edit/delete), so the Today glance surface hosts a READ-ONLY copy: the CURRENT
// `model.night` (the SAME night + intervals the Sleep tab shows) rendered by the shared `StageDetailView`
// with none of the interactive chrome.
//
// PARITY IS ON THE DATA: both surfaces render the night through `StageDetailView` below, so the chart, the
// stage tiles and the honesty notes cannot drift between Today and the Sleep tab. The clock-window row and
// the Main/Nap split stay Sleep-tab only, for cross-platform feature parity: the Kotlin `SleepModel` carries
// no session timestamps/nap blocks, so the Android host card shows the same chart + breakdown and no more.

/// The read-only "Stages" card hosted in Today: latest night's stage chart + breakdown, rendered from the
/// shared [SleepModel] — no navigation, no edit, no nap mutation.
struct StagesCard: View {
    let model: SleepModel

    var body: some View {
        StageDetailView(night: model.night, intervals: model.intervals,
                        typical: StageTypicals(model: model))
    }
}

// MARK: - Stage shares

/// The personal per-stage typical minutes the stage tiles compare against (the SleepModel means).
struct StageTypicals {
    var deep: Double?
    var rem: Double?
    var light: Double?

    static let none = StageTypicals(deep: nil, rem: nil, light: nil)

    init(deep: Double?, rem: Double?, light: Double?) {
        self.deep = deep
        self.rem = rem
        self.light = light
    }

    init(model: SleepModel) {
        self.init(deep: model.typicalDeepMin, rem: model.typicalRemMin, light: model.typicalLightMin)
    }
}

/// How the v2 Sleep screen prints a night's stage shares: Deep, REM and Light as whole percentages of the
/// time ASLEEP (largest remainder, so the three always add up to 100), and Awake as a share of the time in
/// bed. One apportionment for every stage percentage on the screen — the stage tiles and the Stages vs
/// typical card both read it — so the same stage can never print two different numbers.
enum SleepStageShares {
    /// (deep, rem, light) percent of asleep time, or nil for a night with no asleep minutes.
    static func asleepPercents(deep: Double, rem: Double, light: Double) -> (deep: Int, rem: Int, light: Int)? {
        guard let p = StagePercentages.wholePercentages([deep, rem, light]) else { return nil }
        return (p[0], p[1], p[2])
    }

    static func asleepPercents(_ s: Stages) -> (deep: Int, rem: Int, light: Int)? {
        asleepPercents(deep: s.deep, rem: s.rem, light: s.light)
    }

    /// Awake as a whole percent of the time in bed.
    static func awakePercent(_ s: Stages) -> Int {
        s.total > 0 ? Int((s.awake / s.total * 100).rounded()) : 0
    }

    /// The typical shares, from the personal per-stage means; nil until all three have history.
    static func typicalPercents(_ t: StageTypicals) -> (deep: Int, rem: Int, light: Int)? {
        guard let d = t.deep, let r = t.rem, let l = t.light else { return nil }
        return asleepPercents(deep: d, rem: r, light: l)
    }
}

// MARK: - Shared stage section

/// The night's stage section, shared by the Sleep tab and the read-only Today card: the overnight heart-rate
/// chart, the per-stage timeline card, the four stage tiles, and the honesty notes. It owns its OWN
/// transient UI state — `selectedStage` (tap a row or tile to light that stage up on both charts) and
/// `nightHR` (the sleeping-HR trace) — so tapping a stage in Today never reaches into the Sleep tab.
struct StageDetailView: View {
    let night: Night
    let intervals: [SleepInterval]
    var typical: StageTypicals = .none
    /// Optional block above the heart-rate chart (the Sleep tab's bed-by line and night read).
    var lead: AnyView? = nil
    /// Optional row at the top of the stage card (the Sleep tab's clock window, edit and provenance).
    var cardHeader: AnyView? = nil

    @EnvironmentObject var repo: Repository
    /// Transient tap-highlight, LOCAL to this instance.
    @State private var selectedStage: SleepStage? = nil
    /// Per-night sleeping-HR buckets, loaded by the `.task(id:)` below.
    @State private var nightHR: [HRBucket] = []
    /// The Sleep-chart shape (Settings → Appearance → Sleep chart). Display-only. (#sleep-chart-style)
    @AppStorage(SleepChartStyle.storageKey) private var sleepChartStyleRaw = SleepChartStyle.classic.rawValue

    /// Clock labels for the timeline axis; follows the app's Clock format setting (#1821).
    private static var axisFormatter: DateFormatter { AppClock.hourMinuteFormatter() }

    /// The display-smoothed timeline (90 s keeps the fine tick texture while dropping epoch noise) and its
    /// origin/span, shared by the HR chart and the stage rows so both sit on one time axis.
    private var timeline: (intervals: [SleepInterval], origin: TimeInterval, span: TimeInterval) {
        let smoothed = Hypnogram.displaySmoothed(intervals.sorted { $0.start < $1.start }, minDuration: 90)
        let origin = smoothed.first?.start ?? 0
        let span = max(1, (smoothed.map(\.end).max() ?? 1) - origin)
        return (smoothed, origin, span)
    }

    var body: some View {
        let t = timeline
        VStack(alignment: .leading, spacing: 0) {
            if let lead { lead.padding(.bottom, 22) }
            if intervals.count >= 2 {
                SleepNightHRChart(buckets: nightHR, intervals: t.intervals, origin: t.origin, span: t.span,
                                  nightStart: night.onsetDate, selectedStage: selectedStage)
            }
            NoopSectionTitle("Stages", captionKey: "vs your typical night", topPadding: intervals.count >= 2 ? 28 : 0)
                .padding(.bottom, 12)
            stageCard(t)
            stageTiles
                .padding(.top, 12)
            notes
        }
        // WHOOP top-chart data (ryanAtriumAi #988): 1-min sleeping-HR buckets for THIS night, reloaded
        // only when the displayed night changes.
        .task(id: night.session.startTs) {
            nightHR = await repo.hrBuckets(from: night.session.startTs, to: night.session.endTs, bucketSeconds: 60)
        }
        // Browsing to another night clears the stage highlight.
        .onChangeCompat(of: night.session.startTs) { _ in selectedStage = nil }
    }

    // MARK: Stage card

    private func stageCard(_ t: (intervals: [SleepInterval], origin: TimeInterval, span: TimeInterval)) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 0) {
                if let cardHeader { cardHeader.padding(.bottom, 14) }
                if intervals.count >= 2 {
                    let style = SleepChartStyle.resolve(sleepChartStyleRaw)
                    if style == .classic {
                        stageRows(t)
                    } else {
                        // #sleep-chart-style: Fill / Garmin Fill / Ribbon draw the stepped hypnogram instead
                        // of the per-stage rows; the tiles below are its key.
                        Hypnogram(intervals: intervals, height: 150, showsStageAxis: true, showsHover: true,
                                  nightStart: night.onsetDate, showsTimeAxis: true,
                                  highlightedStage: selectedStage, filled: style.isFilled,
                                  stagePalette: style.stagePalette)
                    }
                    stageInsight
                        .padding(.top, 12)
                    // #407 — the movement trace on the SAME timeline, for the same main-night group.
                    motionStrip
                        .padding(.top, 14)
                } else {
                    stageBar
                }
            }
        }
    }

    /// Awake · REM · Light · Deep rows over the shared onset → wake axis. Each row is independently legible
    /// however fragmented the staging is; tap a row to light that stage up (tap again to clear).
    private func stageRows(_ t: (intervals: [SleepInterval], origin: TimeInterval, span: TimeInterval)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([SleepStage.awake, .rem, .light, .deep], id: \.self) { stage in
                stageRow(stage, t)
            }
            HStack {
                Text(Self.axisFormatter.string(from: night.onsetDate))
                Spacer()
                Text(Self.axisFormatter.string(from: night.onsetDate.addingTimeInterval(t.span / 2)))
                Spacer()
                Text(Self.axisFormatter.string(from: night.onsetDate.addingTimeInterval(t.span)))
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.leading, 52)
            .padding(.top, 8)
            .accessibilityHidden(true)
        }
    }

    private func stageRow(_ stage: SleepStage,
                          _ t: (intervals: [SleepInterval], origin: TimeInterval, span: TimeInterval)) -> some View {
        let isSelected = selectedStage == stage
        let dimmed = selectedStage != nil && !isSelected
        let minutes = stageMinutes(stage)
        return HStack(spacing: 0) {
            Text(stage.v2Label)
                .font(StrandFont.footnote)
                .foregroundStyle(isSelected ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                .frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(t.intervals.filter { $0.stage == stage }) { iv in
                        let x0 = CGFloat((iv.start - t.origin) / t.span) * geo.size.width
                        let w = max(3, CGFloat((iv.end - iv.start) / t.span) * geo.size.width)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(dimmed ? StrandPalette.textTertiary.opacity(0.35) : StrandPalette.sleepStageColor(stage))
                            .frame(width: w, height: 12)
                            .offset(x: x0, y: 9)
                    }
                }
            }
            .frame(height: 30)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(stage) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stage.label): \(durationText(minutes))")
        .accessibilityHint("Highlights this stage on the sleep chart")
        .accessibilityAddTraits(.isButton)
    }

    private func toggle(_ stage: SleepStage) {
        withAnimation(StrandMotion.fade) { selectedStage = selectedStage == stage ? nil : stage }
    }

    /// Selected: tonight's minutes against the 30-day typical range. Otherwise the tap hint.
    @ViewBuilder
    private var stageInsight: some View {
        if let sel = selectedStage {
            let minutes = stageMinutes(sel)
            if let t = stageTypicalRange(sel) {
                let phrase = minutes > t.hi ? String(localized: "above your usual")
                    : (minutes < t.lo ? String(localized: "below your usual") : String(localized: "about your usual"))
                Text("\(sel.label) \(durationText(minutes)) · typically \(durationText(t.lo)) to \(durationText(t.hi)), \(phrase).")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(sel.label): \(durationText(minutes)). Not enough history yet for a typical range.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Tap a stage to compare with your 30-day typical.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// #407 — the per-epoch movement strip under the timeline. Reads the already-resolved main-night
    /// GROUP's persisted motion off `night.motionEpochs`; a night with no persisted motion (older rows
    /// whose `motionJSON` is NULL) shows an HONEST empty note rather than a fabricated flat trace.
    private var motionStrip: some View {
        HStack(alignment: .center, spacing: 0) {
            Text("Motion")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 52, alignment: .leading)
            if night.motionEpochs.count >= 2 {
                MotionTrace(epochs: night.motionEpochs, height: 28, tint: StrandPalette.metricCyan)
            } else {
                Text("No movement detail for this night")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    // A gap after the lane label, which can fill the lane in longer languages.
                    .padding(.leading, 6)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .accessibilityLabel(Text("No movement detail recorded for this night"))
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Proportional stacked stage bar, for a night whose stages carry no timeline (totals only).
    private var stageBar: some View {
        let s = night.stages
        let total = max(1, s.total)
        return VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach([SleepStage.deep, .light, .rem, .awake], id: \.self) { stage in
                        Rectangle()
                            .fill(StrandPalette.sleepStageColor(stage))
                            .frame(width: max(0, CGFloat(stageMinutes(stage) / total) * geo.size.width))
                    }
                }
            }
            .frame(height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Sleep stage breakdown"))
            HStack(spacing: 14) {
                ForEach([SleepStage.deep, .light, .rem, .awake], id: \.self) { stage in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(StrandPalette.sleepStageColor(stage))
                            .frame(width: 9, height: 9)
                        Text(stage.v2Label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    // MARK: Stage tiles

    private var stageTiles: some View {
        let s = night.stages
        let shares = SleepStageShares.asleepPercents(s)
        let typicalShares = SleepStageShares.typicalPercents(typical)
        return VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                tile(.deep) { deepTile(s, share: shares?.deep, typical: typicalShares?.deep) }
                tile(.awake) { awakeTile(s) }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                tile(.rem) {
                    stageValue(s.rem, share: shares?.rem, typical: typicalShares?.rem, title: SleepStage.rem.v2Label)
                }
                tile(.light) {
                    stageValue(s.light, share: shares?.light, typical: typicalShares?.light, title: SleepStage.light.v2Label)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A tappable stage tile: tapping it lights the stage up on the charts, like the rows.
    private func tile<Content: View>(_ stage: SleepStage, @ViewBuilder content: () -> Content) -> some View {
        let isSelected = selectedStage == stage
        return Button { toggle(stage) } label: {
            content()
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .noopPanel()
                .overlay(RoundedRectangle(cornerRadius: NoopVisualStyle.cardRadius, style: .continuous)
                    .strokeBorder(isSelected ? NoopVisualStyle.borderHighlight : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Highlights this stage on the sleep chart")
    }

    private func tileTitle(_ title: String, trailing: String? = nil, icon: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: title).font(StrandFont.book(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 4)
            if let trailing {
                Text(verbatim: trailing).font(StrandFont.light(12)).foregroundStyle(StrandPalette.textSecondary)
            }
            if let icon { PhIcon(icon, size: 16).foregroundStyle(StrandPalette.textPrimary).opacity(0.9) }
        }
        .lineLimit(1)
    }

    private func shareCaption(_ share: Int?, typical: Int?) -> String {
        guard let share else { return "—" }
        if let typical { return String(localized: "\(share)% · typical \(typical)%") }
        return String(localized: "\(share)% of time asleep")
    }

    private func deepTile(_ s: Stages, share: Int?, typical: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            tileTitle(SleepStage.deep.v2Label, icon: "moon")
            HStack(spacing: 10) {
                StageShareRing(fraction: Double(share ?? 0) / 100)
                    .frame(width: 52, height: 52)
                // Beside the ring the caption has room for one short line, so it breaks after the share
                // rather than wherever the translation happens to run out.
                NoopMetric(value: hoursMinutes(s.deep), unit: "h",
                           labelText: shareCaption(share, typical: typical).replacingOccurrences(of: " · ", with: " ·\n"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func awakeTile(_ s: Stages) -> some View {
        let pct = SleepStageShares.awakePercent(s)
        let wakeUps = wakeUpCount
        return VStack(alignment: .leading, spacing: 0) {
            tileTitle(SleepStage.awake.v2Label, trailing: hoursMinutes(s.awake))
            NoopTrack(fraction: Double(pct) / 100, height: 14)
                .padding(.top, 18)
            // The share and its unit read as one phrase ("7% of time in bed"); the wake-up count follows.
            VStack(alignment: .leading, spacing: 4) {
                (Text(verbatim: "\(pct)% ") + Text("of time in bed"))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let wakeUps {
                    Text(wakeUps == 1 ? String(localized: "1 wake-up") : String(localized: "\(wakeUps) wake-ups"))
                }
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.top, 10)
        }
        .accessibilityElement(children: .combine)
    }

    private func stageValue(_ minutes: Double, share: Int?, typical: Int?, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            tileTitle(title)
            NoopMetric(value: hoursMinutes(minutes), unit: "h", labelText: shareCaption(share, typical: typical))
        }
        .accessibilityElement(children: .combine)
    }

    /// Awake stretches INSIDE the night (not the lie-in before onset or after waking), counted from the same
    /// smoothed timeline the rows draw, so the count matches what the Awake row shows.
    private var wakeUpCount: Int? {
        let t = timeline.intervals
        guard t.count >= 2 else { return nil }
        let inner = t.dropFirst().dropLast()
        return inner.filter { $0.stage == .awake }.count
    }

    // MARK: Notes

    @ViewBuilder
    private var notes: some View {
        let lowConfidence = stageStagingIsLowConfidence
        let incomplete = stageShowsIncompleteNote
        let coverage = stageCoverage.flatMap { $0 < HypnogramCoverage.minCoverage ? $0 : nil }
        let oura = repo.activeDeviceIsOura
        if lowConfidence || incomplete || coverage != nil || oura {
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    // H9 — a high-efficiency night whose deep+REM share is implausibly low: a likely staging
                    // miss. Read from `ScoreConfidence.rest(...)` so the note can never disagree with the score.
                    if lowConfidence {
                        note("Low confidence", "This night scored high efficiency but very little deep or REM, more likely a staging estimate miss than a real restorative shortfall. The totals are kept as-is; read the split with care.")
                    }
                    // #345 — staged on SPARSE motion coverage AND reading short: it may be under-detected.
                    if incomplete {
                        note("May be incomplete", "Your strap recorded little movement overnight (common on WHOOP 4.0), so this night may be under-detected and the sleep total can read short. Make sure the strap fully synced; the numbers are kept as-is.")
                    }
                    // #1716 — part of the night's window has no stage data; the percentage is floored so
                    // 94.8 % never prints as 95 % and appears to contradict the gate that flagged it.
                    if let coverage {
                        note("Partly recorded", "Only \(Int((coverage * 100).rounded(.down)))% of this night's window has stage data. The stage totals cover only that part of the night.")
                    }
                    // An Oura night's split is the ring's RAW on-device classification, not the app's.
                    if oura {
                        note("Raw on-device stages", "This split is the ring's raw on-device classification read over Bluetooth, not the adjusted stages the Oura app shows. Expect more Awake and less Deep/REM here than in the Oura app for the same night.", icon: "info")
                    }
                }
            }
            .padding(.top, 12)
        }
    }

    private func note(_ title: LocalizedStringKey, _ body: LocalizedStringKey, icon: String = "warning") -> some View {
        HStack(alignment: .top, spacing: 12) {
            PhIcon(icon, size: 18).foregroundStyle(StrandPalette.textPrimary).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(StrandFont.book(14)).foregroundStyle(StrandPalette.textPrimary)
                Text(body).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// H9 — true when this night's staging is LOW-CONFIDENCE, via the engine's own `ScoreConfidence.rest`
    /// H9 overload so the UI and the persisted Rest confidence agree by construction. (#H9)
    private var stageStagingIsLowConfidence: Bool {
        let s = night.stages
        guard let effPct = efficiencyPct else { return false }
        return SleepView.isStagingLowConfidence(asleepMin: s.asleep, deepMin: s.deep, remMin: s.rem,
                                                efficiency: effPct / 100.0)
    }

    /// The "May be incomplete" caveat: `SleepView.stageSparseNoteApplies` is the single place the #345 rule
    /// lives. Reads the day's REAL stored blocks, never the synthetic merged `session`.
    private var stageShowsIncompleteNote: Bool {
        SleepView.stageSparseNoteApplies(stagingSparse: night.sourceBlocks.contains { $0.stagingSparse == true },
                                         asleepMin: night.stages.asleep)
    }

    /// How much of this night's window its stage timeline accounts for (#1716), asked of the bridged
    /// main-night GROUP via the same shared accumulation `analyzeDay` uses.
    private var stageCoverage: Double? {
        let group = SleepView.mainNightGroup(night.sourceBlocks, habitualMidsleepSec: night.habitualMidsleepSec)
        return HypnogramCoverage.groupFraction(group.isEmpty ? night.sourceBlocks : group)
    }

    // MARK: Typical ranges + formatting

    private func stageMinutes(_ stage: SleepStage) -> Double {
        switch stage {
        case .awake: return night.stages.awake
        case .light: return night.stages.light
        case .deep:  return night.stages.deep
        case .rem:   return night.stages.rem
        }
    }

    /// Per-stage typical minutes over the trailing 30 scored days: the 25th–75th percentile band. Returns
    /// nil below 5 scored nights (honest cold-start: no range fabricated from a few days).
    private func stageTypicalRange(_ stage: SleepStage) -> (lo: Double, hi: Double)? {
        let values: [Double] = repo.days.suffix(30).compactMap { d in
            switch stage {
            case .light: return d.lightMin
            case .deep:  return d.deepMin
            case .rem:   return d.remMin
            case .awake:
                // Awake isn't a stored daily column; derive from in-bed minus asleep via efficiency.
                guard let asleep = d.totalSleepMin, asleep > 0, var e = d.efficiency, e > 0 else { return nil }
                if e > 1.5 { e /= 100 }   // efficiency arrives as % on some import paths
                guard e > 0.3, e <= 1 else { return nil }
                return asleep * (1 - e) / e
            }
        }.filter { $0 > 0 }.sorted()
        guard values.count >= 5 else { return nil }
        func pct(_ p: Double) -> Double {
            let idx = p * Double(values.count - 1)
            let l = Int(idx.rounded(.down)), u = Int(idx.rounded(.up))
            let frac = idx - Double(l)
            return values[l] * (1 - frac) + values[u] * frac
        }
        return (pct(0.25), pct(0.75))
    }

    /// Efficiency in percent. Prefer the stored session value, else asleep / time-in-bed.
    private var efficiencyPct: Double? {
        if let stored = night.session.efficiency ?? repo.today?.efficiency {
            return stored <= 1.0 ? stored * 100 : stored
        }
        let bed = night.timeInBed
        guard bed > 0 else { return nil }
        return Swift.min(100, night.stages.asleep / bed * 100)
    }

    private func durationText(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return String(localized: "\(m)m") }
        return String(localized: "\(m / 60)h \(m % 60)m")
    }

    /// "1:42" — hours and minutes for the tile values.
    private func hoursMinutes(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        return String(format: "%d:%02d", m / 60, m % 60)
    }
}

/// The Deep tile's ring: a dark track, the share in the sleep accent from the top, and a small white knob.
private struct StageShareRing: View {
    let fraction: Double
    private let lineWidth: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            let r = (d - lineWidth) / 2
            let f = min(max(fraction, 0), 1)
            let a = Angle.degrees(-90 + 360 * f).radians
            ZStack {
                // Inset both strokes so their centreline shares the knob's radius.
                Circle().stroke(Color.white.opacity(0.08), lineWidth: lineWidth)
                    .padding(lineWidth / 2)
                Circle().trim(from: 0, to: f)
                    .stroke(NoopGlow.sleep.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(lineWidth / 2)
                if f > 0 {
                    Circle().fill(Color.white).frame(width: 9, height: 9)
                        .offset(x: r * CGFloat(cos(a)), y: r * CGFloat(sin(a)))
                }
            }
            .frame(width: d, height: d)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

extension SleepStage {
    /// The stage's display name in sentence case ("Deep", "REM").
    var v2Label: String {
        switch self {
        case .awake: return String(localized: "Awake")
        case .light: return String(localized: "Light")
        case .deep:  return String(localized: "Deep")
        case .rem:   return String(localized: "REM")
        }
    }
}

// MARK: - Overnight heart rate

/// The sleeping heart-rate chart: a 1.2 pt trace over a soft blue area, y captions, onset → wake clock
/// captions, and a highlighted band — the selected stage's stretches, or by default the night's longest deep
/// sleep stretch. Gaps in the data break the line honestly rather than interpolating across them, and weak
/// optical stretches (PPG conf < 0.3) draw dashed so an estimate is never presented as a clean beat.
struct SleepNightHRChart: View {
    let buckets: [HRBucket]
    let intervals: [SleepInterval]
    let origin: TimeInterval
    let span: TimeInterval
    let nightStart: Date
    let selectedStage: SleepStage?

    private static var axisFormatter: DateFormatter { AppClock.hourMinuteFormatter() }
    private let plotHeight: CGFloat = 164

    private var inWindow: [HRBucket] {
        let start = nightStart.timeIntervalSince1970
        return buckets.filter {
            let rel = TimeInterval($0.ts) - start
            return rel >= origin - 60 && rel <= origin + span + 60
        }
    }

    /// Bands to highlight as 0…1 x ranges, with the label for the first.
    private var bands: (ranges: [ClosedRange<Double>], label: String?) {
        let stage = selectedStage ?? .deep
        let ivs = intervals.filter { $0.stage == stage }
        let picked = selectedStage == nil ? Array(ivs.max { $0.duration < $1.duration }.map { [$0] } ?? []) : ivs
        let ranges = picked.map { iv in
            max(0, (iv.start - origin) / span)...min(1, (iv.end - origin) / span)
        }
        let label = selectedStage == nil
            ? (ranges.isEmpty ? nil : String(localized: "Deep sleep"))
            : stage.v2Label
        return (ranges, label)
    }

    var body: some View {
        let pts = inWindow
        if pts.count >= 2 {
            let bpms = pts.map(\.bpm)
            let lo = (((bpms.min() ?? 40) - 3) / 10).rounded(.down) * 10
            let hi = max(lo + 10, (((bpms.max() ?? 90) + 3) / 10).rounded(.up) * 10)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    yAxis(lo: lo, hi: hi).frame(width: 22, height: plotHeight)
                    plot(pts, lo: lo, hi: hi).frame(height: plotHeight)
                }
                .padding(.top, 14)
                HStack {
                    Text(Self.axisFormatter.string(from: nightStart.addingTimeInterval(origin)))
                    Spacer()
                    Text(Self.axisFormatter.string(from: nightStart.addingTimeInterval(origin + span / 3)))
                    Spacer()
                    Text(Self.axisFormatter.string(from: nightStart.addingTimeInterval(origin + span * 2 / 3)))
                    Spacer()
                    Text(Self.axisFormatter.string(from: nightStart.addingTimeInterval(origin + span)))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.leading, 28)
                .padding(.top, 8)
                .accessibilityHidden(true)
                Text("Heart rate overnight · bpm")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.leading, 28)
                    .padding(.top, 6)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Sleeping heart rate through the night"))
        } else {
            Text("No heart-rate detail for this night")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        }
    }

    private func yAxis(lo: Double, hi: Double) -> some View {
        GeometryReader { geo in
            let mid = ((lo + hi) / 2).rounded()
            ForEach([hi, mid, lo], id: \.self) { v in
                Text(verbatim: "\(Int(v))")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize()
                    .position(x: 9, y: geo.size.height * (1 - CGFloat((v - lo) / max(1, hi - lo))))
            }
        }
    }

    private func plot(_ pts: [HRBucket], lo: Double, hi: Double) -> some View {
        let b = bands
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(b.ranges.indices, id: \.self) { i in
                    let r = b.ranges[i]
                    let x0 = geo.size.width * CGFloat(r.lowerBound)
                    let w = max(1, geo.size.width * CGFloat(r.upperBound - r.lowerBound))
                    Rectangle().fill(Color.white.opacity(0.045))
                        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.55)).frame(height: 1) }
                        .frame(width: w, height: geo.size.height)
                        .offset(x: x0)
                }
                if let label = b.label, let first = b.ranges.first {
                    let x0 = geo.size.width * CGFloat(first.lowerBound)
                    let w = max(1, geo.size.width * CGFloat(first.upperBound - first.lowerBound))
                    Text(verbatim: label)
                        .font(StrandFont.light(10))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize()
                        .frame(width: max(w, 60))
                        .offset(x: min(max(0, x0 + w / 2 - max(w, 60) / 2), geo.size.width - max(w, 60)), y: -14)
                }
                trace(pts, lo: lo, hi: hi)
            }
        }
    }

    private func trace(_ pts: [HRBucket], lo: Double, hi: Double) -> some View {
        let start = nightStart.timeIntervalSince1970
        let fill = StrandPalette.effortColor
        let line = StrandPalette.metricCyan
        return Canvas { ctx, size in
            func point(_ b: HRBucket) -> CGPoint {
                let rel = TimeInterval(b.ts) - start
                return CGPoint(x: CGFloat((rel - origin) / span) * size.width,
                               y: size.height * (1 - CGFloat((b.bpm - lo) / max(1, hi - lo))))
            }
            // Contiguous runs (a > 5-min gap breaks the line), each filled to the baseline.
            var runs: [[HRBucket]] = []
            for b in pts {
                if let last = runs.last?.last, b.ts - last.ts <= 300 { runs[runs.count - 1].append(b) }
                else { runs.append([b]) }
            }
            for run in runs where run.count >= 2 {
                var area = Path()
                let first = point(run[0])
                area.move(to: CGPoint(x: first.x, y: size.height))
                run.forEach { area.addLine(to: point($0)) }
                area.addLine(to: CGPoint(x: point(run[run.count - 1]).x, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(Gradient(colors: [fill.opacity(0.45), fill.opacity(0)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            // Strong (measured) and weak (low-confidence optical) strokes; the weak segment owns the bridge.
            var strong = Path(), weak = Path()
            var prev: (ts: Int, pt: CGPoint, strong: Bool)? = nil
            for b in pts {
                let p = point(b)
                let isStrong = b.conf >= 0.3
                if let pr = prev, b.ts - pr.ts <= 300 {
                    if isStrong {
                        if pr.strong { strong.addLine(to: p) } else { strong.move(to: pr.pt); strong.addLine(to: p) }
                    } else {
                        if !pr.strong { weak.addLine(to: p) } else { weak.move(to: pr.pt); weak.addLine(to: p) }
                    }
                } else {
                    if isStrong { strong.move(to: p) } else { weak.move(to: p) }
                }
                prev = (b.ts, p, isStrong)
            }
            ctx.stroke(strong, with: .color(line), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            ctx.stroke(weak, with: .color(line.opacity(0.55)), style: StrokeStyle(lineWidth: 1, lineJoin: .round, dash: [2, 3]))
        }
    }
}
