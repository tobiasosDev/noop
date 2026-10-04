import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - FusedRecordView — "Your Data, Fused" (v5 — Local Multi-Device Fusion)
//
// The read-only headline screen for the fusion pillar
// (docs/superpowers/specs/2026-06-19-v5-local-multi-device-fusion-design.md §UX). For each core
// metric it shows the BEST-sourced value, a provenance pill naming the source, the plain published
// reason from MetricArbitrationPolicy ("counts directly" / "best stager"), and the inline agreement
// state from FusionResolver (agree / minor delta / conflict). When two sources disagree it offers a
// conflict-compare sheet that lists EVERY source's value side by side and which one NOOP is using and
// why — it NEVER silently merges or averages.
//
// SELF-CONTAINED: the view takes a fully-resolved `FusedRecord` via init (the Repository adapter that
// pulls today's per-source metrics and runs `FusionResolver.resolve` lives in Wave 3 — see
// `wiringNeeded`). It does no I/O and never touches AppModel/Repository directly, so it compiles and
// previews from a fixture. This file owns only PRESENTATION: a metric label, a value formatter, and
// the row/detail chrome — all built from the v2 kit (NoopHeroCard / NoopList / NoopCard / NoopTag …)
// and tokens (StrandPalette / StrandFont / NoopVisualStyle).
//
// Wellness framing only: a source is "higher-trust for this metric" with a plain reason; we never say
// a number is accurate / correct / clinical, never flag a value as concerning. "Everything stays on
// this device."

// MARK: - Presentation model (the read-model this screen consumes)

/// One resolved metric row for the fused record — the engine's `FusedMetricPoint` plus the display
/// label + unit this screen needs to render it. The Wave 3 Repository adapter builds these from the
/// rows it already loads (it owns the metric→label/unit mapping there, or reuses this one).
public struct FusedRow: Identifiable, Equatable {
    public let point: FusedMetricPoint
    /// Human label for the metric ("Resting HR", "Steps", "Sleep").
    public let label: String
    /// Optional accent colour world for the row's value (per-metric tint), defaulted to primary text.
    public let accentHex: String?

    public var id: String { point.metric }

    public init(point: FusedMetricPoint, label: String, accentHex: String? = nil) {
        self.point = point
        self.label = label
        self.accentHex = accentHex
    }
}

/// The whole fused day-record this screen renders. Built by the Wave 3 Repository adapter; passed in
/// via init so the view stays pure and previewable.
public struct FusedRecord: Equatable {
    /// The resolved rows, in display order (importance-first, per the hub rule).
    public let rows: [FusedRow]
    /// The device that OWNS the day's scores (from `DayOwnerResolver`) — shown as the day badge so the
    /// scores' single-owner invariant stays honest. Nil when no scored owner exists yet.
    public let dayOwner: FusionSource?
    /// How many distinct sources contributed across the whole record. Drives the single-source
    /// degradation: when ≤ 1 the screen shows a plain record with no provenance noise.
    public let contributingSourceCount: Int

    public init(rows: [FusedRow], dayOwner: FusionSource?, contributingSourceCount: Int) {
        self.rows = rows
        self.dayOwner = dayOwner
        self.contributingSourceCount = contributingSourceCount
    }
}

// MARK: - Screen

struct FusedRecordView: View {
    let record: FusedRecord
    /// The day label shown beside the metric in the per-metric comparison ("Today", or a formatted
    /// date). Defaulted so the preview/caller can omit it.
    var dayLabel: String = String(localized: "Today")
    /// When the host last merged this record: the hero's "Last merged" figure. nil hides it.
    var mergedAt: Date? = nil
    /// True while the host is still building the record: the header and a quiet note, no figures.
    var isLoading: Bool = false

    /// The metric currently open in the per-metric source comparison (nil = closed).
    @State private var comparing: FusedCompareTarget?

    /// True only when more than one source contributed anywhere — gates all provenance chrome so a
    /// single-WHOOP user sees a plain record, not a manufactured multi-source experience.
    private var isMultiSource: Bool { record.contributingSourceCount > 1 }

    var body: some View {
        ScreenScaffold(title: nil) {
            NoopScreenHeader("Your data, fused")
                .padding(.bottom, 6)
            if isLoading {
                loadingCard
            } else {
                FusedDayHero(record: record, mergedAt: mergedAt)
                if record.rows.isEmpty {
                    emptyCard
                } else {
                    metricsSection
                    if isMultiSource { sourceOrderSection }
                    explainer
                }
                footer
            }
        }
        // The screen draws its own v2 header (back circle + title), so the system bar stays hidden.
        .noopHidesSystemNavBar()
        #if os(iOS)
        // Every source for one metric, pushed like any detail. Opening it never changes the resolved
        // value — it only explains it.
        .navigationDestination(item: $comparing) { target in
            if let row = record.rows.first(where: { $0.id == target.id }) {
                FusedMetricDetailView(row: row, dayLabel: dayLabel)
            }
        }
        #else
        // macOS shows this screen in the split view's detail pane, which has no navigation stack to
        // push onto, so the comparison stays a sheet there.
        .sheet(item: $comparing) { target in
            if let row = record.rows.first(where: { $0.id == target.id }) {
                FusedMetricDetailView(row: row, dayLabel: dayLabel)
                    .frame(width: 480, height: 680)
            }
        }
        #endif
    }

    @ViewBuilder private var metricsSection: some View {
        NoopSectionTitle("Today's metrics", captionKey: "Tap to compare")
        NoopList {
            ForEach(record.rows) { row in
                Button {
                    comparing = FusedCompareTarget(id: row.id)
                } label: {
                    FusedMetricRowView(row: row, showProvenance: isMultiSource)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The tie-break order the resolver applies when two sources sit on the same trust tier for a
    /// metric, with what each source supplies today. Read-only: the order is the published policy.
    @ViewBuilder private var sourceOrderSection: some View {
        NoopSectionTitle("Source order", captionKey: "Breaks ties")
        NoopList {
            ForEach(Array(record.sourcesInPriorityOrder.enumerated()), id: \.element) { index, source in
                HStack(spacing: 14) {
                    Text(verbatim: String(format: "%02d", index + 1))
                        .font(StrandFont.dot(17, weight: 700))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: 24, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: source.displayName)
                            .font(StrandFont.book(15, relativeTo: .body))
                            .foregroundStyle(StrandPalette.textPrimary)
                        sourceCaption(source)
                            .font(StrandFont.light(12, relativeTo: .caption))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// What a source is picked for today ("Picked for Resting HR, HRV"), or that it was only counted.
    private func sourceCaption(_ source: FusionSource) -> Text {
        let won = record.rows
            .filter { $0.point.winningSource == source }
            .map { String(localized: String.LocalizationValue($0.label)) }
        if won.isEmpty { return Text("Counted; another source leads each metric") }
        return Text("Picked for \(won.joined(separator: ", "))")
    }

    @ViewBuilder private var explainer: some View {
        NoopInsightRow(
            isMultiSource
                ? "NOOP picks one source per metric and never averages them. Each metric goes to the source that measures it most directly; when two are equally direct, the higher one in this order wins. Tap a row to see every source."
                : "NOOP picks one source per metric and never averages them. Tap a row to see where a number came from.",
            icon: "info"
        )
        .padding(.horizontal, 4)
        .padding(.top, 8)
        // The pillar's standing non-clinical line (umbrella §4.1). Kept inline + plain — wellness only.
        Text("NOOP picks the best-sourced number and shows you where each came from. It's for wellness and curiosity. It doesn't diagnose or replace medical advice.")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 34)
            .padding(.trailing, 4)
    }

    private var footer: some View {
        Text("Merged on \(Platform.deviceNounPhrase) · nothing leaves the device")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
    }

    private var emptyCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                NoopCardHeader("Nothing to fuse yet", icon: "intersect-three")
                Text("Import a WHOOP export, Apple Health or a second band and your best-sourced record builds here, on this device.")
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var loadingCard: some View {
        NoopCard {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .tint(StrandPalette.textSecondary)
                Text("Reading your sources…")
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
            }
        }
    }
}

/// The value the comparison destination is keyed on (a metric id). Hashable for the iOS push,
/// Identifiable for the macOS sheet.
private struct FusedCompareTarget: Hashable, Identifiable {
    let id: String
}

extension FusedRecord {
    /// Every source that contributed to any metric, in the resolver's tie-break order.
    var sourcesInPriorityOrder: [FusionSource] {
        var seen = Set<FusionSource>()
        for row in rows { for c in row.point.contributors { seen.insert(c.source) } }
        return seen.sorted {
            MetricArbitrationPolicy.sourcePriority($0) < MetricArbitrationPolicy.sourcePriority($1)
        }
    }
}

// MARK: - Hero

/// The ink hero: how many sources fed the day, which device owns the scores, and the record's shape
/// (metrics fused, how many disagree, when it was merged).
private struct FusedDayHero: View {
    let record: FusedRecord
    let mergedAt: Date?

    private var sources: [FusionSource] { record.sourcesInPriorityOrder }
    private var differing: Int {
        record.rows.filter { $0.point.agreement == .minorDelta || $0.point.agreement == .conflict }.count
    }

    var body: some View {
        NoopHeroCard(glow: .ink, padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge("Fused day", icon: "intersect-three")
                    Spacer(minLength: 8)
                    NoopPill(verbatim: Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
                             compact: true)
                }
                HStack(alignment: .center, spacing: 8) {
                    HStack(alignment: .bottom, spacing: 10) {
                        NoopDotNumber("\(record.contributingSourceCount)", size: 96)
                        Text(record.contributingSourceCount == 1 ? "source\ntoday" : "sources\ntoday")
                            .font(StrandFont.light(12, relativeTo: .caption))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineSpacing(2)
                            .padding(.bottom, 8)
                    }
                    Spacer(minLength: 8)
                    FusedSourceStack(sources: sources)
                }
                .padding(.top, 28)

                ownerLine
                    .font(StrandFont.light(21, relativeTo: .title2))
                    .tracking(-0.3)
                    .lineSpacing(2)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 22)
                if !sources.isEmpty {
                    feedLine
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                NoopMetricRow {
                    NoopMetric(value: "\(record.rows.count)", label: "Metrics fused", labelColor: NoopMetric.heroLabel)
                    NoopMetric(value: "\(differing)", label: "Sources differ", labelColor: NoopMetric.heroLabel)
                    if let mergedAt {
                        NoopMetric(value: mergedAt.formatted(date: .omitted, time: .shortened),
                                   label: "Last merged", labelColor: NoopMetric.heroLabel)
                    }
                }
                .padding(.top, 22)
            }
            .padding(.bottom, 2)
        }
    }

    /// "Today's scores owned by WHOOP" — the scores' single owner, made honest.
    private var ownerLine: Text {
        if let owner = record.dayOwner {
            return Text("Today's scores owned by \(owner.displayName)")
        }
        return Text("Scores still calibrating, no single day-owner yet")
    }

    private var feedLine: Text {
        let names = sources.map(\.displayName).joined(separator: " · ")
        if sources.count == 1 { return Text("One source feeds this day:\n\(names)") }
        return Text("\(sources.count) sources feed this day:\n\(names)")
    }
}

/// The overlapping source glyphs at the hero's right edge (WHOOP, Apple Health, Mi Band …).
private struct FusedSourceStack: View {
    let sources: [FusionSource]

    var body: some View {
        HStack(spacing: -10) {
            ForEach(sources.prefix(4), id: \.self) { source in
                PhIcon(source.fusedSourceIcon, size: 17)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(NoopVisualStyle.inset.opacity(0.9)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    // A dark ring around each disc so the overlap reads as a stack, not a blur.
                    .background(Circle().fill(Color.black.opacity(0.55)).padding(-3))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - One fused metric row

private struct FusedMetricRowView: View {
    let row: FusedRow
    /// When false (single-source record) the source chip and agreement chip are hidden — a plain
    /// "label … value" row, no manufactured multi-source noise.
    let showProvenance: Bool

    // Each screen resolves °C/°F for itself (TodayView, FullDayChartView, MetricExplorerView do the
    // same); the fused row used to print a hardcoded "°C" and was the last reader here ignoring it.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
                                     override: temperatureRaw)
    }

    private var point: FusedMetricPoint { row.point }

    var body: some View {
        HStack(spacing: 12) {
            NoopIconTile(fusedMetricIcon(point.metric))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(row.label))
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    if showProvenance { agreementChip }
                }
                if showProvenance {
                    FusedSourceChip(source: point.winningSource)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            FusedValueText(parts: FusionFormat.parts(point.value, metricKey: point.metric,
                                                     temperature: temperatureUnit),
                           size: 17)
            PhIcon("caret-right", size: 14)
                .foregroundStyle(StrandPalette.textPrimary)
                .opacity(0.4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // The whole row is the compare affordance, so VoiceOver and a tap both reach it.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Compare sources")
    }

    /// Quiet for agree / single; a dashed chip when the sources disagree. Never an alarm colour.
    @ViewBuilder private var agreementChip: some View {
        switch point.agreement {
        case .single, .agree:
            EmptyView()
        case .minorDelta:
            FusedDifferenceChip(text: "Differs slightly")
        case .conflict:
            FusedDifferenceChip(text: "Sources differ")
        }
    }
}

/// The small source capsule under a metric ("WHOOP", "Apple Health") with the source's glyph.
private struct FusedSourceChip: View {
    let source: FusionSource
    var body: some View {
        HStack(spacing: 5) {
            PhIcon(source.fusedSourceIcon, size: 12)
            Text(verbatim: source.displayName)
                .font(StrandFont.book(11, relativeTo: .caption2))
                .lineLimit(1)
        }
        .foregroundStyle(StrandPalette.textSecondary)
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .frame(height: 22)
        .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
    }
}

/// The dashed "Sources differ" / "Differs slightly" capsule beside a metric's name.
private struct FusedDifferenceChip: View {
    let text: LocalizedStringKey
    var body: some View {
        HStack(spacing: 4) {
            PhIcon("arrows-split", size: 11)
            Text(text)
                .font(StrandFont.book(10.5, relativeTo: .caption2))
                .lineLimit(1)
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 20)
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        )
    }
}

/// A fused value with its unit set small beside it (`52` `bpm`).
private struct FusedValueText: View {
    let parts: (number: String, unit: String?)
    let size: CGFloat
    var color: Color = StrandPalette.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(verbatim: parts.number)
                .font(StrandFont.value(size))
                .tracking(-size * 0.015)
                .foregroundStyle(color)
            if let unit = parts.unit {
                Text(verbatim: unit)
                    .font(StrandFont.book(10))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

extension FusionSource {
    /// The Phosphor glyph for a source on the fused screens.
    var fusedSourceIcon: String {
        switch self {
        case .whoopImport:   return "bluetooth"
        case .noopComputed:  return "cpu"
        case .appleHealth:   return "heart"
        case .healthConnect: return "heart"
        case .xiaomiBand:    return "watch"
        case .nutritionCsv:  return "fork-knife"
        case .localCache:    return "database"
        }
    }
}

/// The Phosphor glyph for a fused metric key.
private func fusedMetricIcon(_ key: String) -> String {
    switch MetricArbitrationPolicy.kind(forKey: key) {
    case .restingHR: return "heartbeat"
    case .heartRate: return "heart"
    case .hrv:       return "wave-sine"
    case .spo2:      return "drop"
    case .skinTemp:  return "thermometer-simple"
    case .steps:     return "footprints"
    case .sleep:     return "moon-stars"
    case .calories:  return "fire"
    case .other:     return "chart-line"
    }
}

// MARK: - Per-metric comparison

/// Every source's value for one metric, side by side, with the one NOOP is using marked and its trust
/// reason named. NOOP never adjudicates which is "correct" — it shows the spread and explains its
/// best-signal pick. Transparency, not diagnosis.
struct FusedMetricDetailView: View {
    let row: FusedRow
    var dayLabel: String = String(localized: "Today")

    // Each screen resolves °C/°F for itself (TodayView, FullDayChartView, MetricExplorerView do the
    // same); the fused row used to print a hardcoded "°C" and was the last reader here ignoring it.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
                                     override: temperatureRaw)
    }

    private var point: FusedMetricPoint { row.point }
    private var winner: ContributingSource? { point.contributors.first }
    private var metricName: String { String(localized: String.LocalizationValue(row.label)) }

    var body: some View {
        ScreenScaffold(title: nil) {
            NoopScreenHeader("Fused data")
                .padding(.bottom, 6)
            hero
            NoopSectionTitle("Every source", caption: "\(metricName) · \(dayLabel)")
            NoopList {
                ForEach(Array(point.contributors.enumerated()), id: \.offset) { index, contrib in
                    FusedContributorRow(contrib: contrib, metricKey: point.metric,
                                        isWinner: index == 0, temperature: temperatureUnit)
                }
            }
            if point.contributors.count > 1 {
                comparedCard
            } else if let winner {
                NoopInsightRow(text: explanation(winner), icon: "info")
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            }
        }
        .noopHidesSystemNavBar()
    }

    private var hero: some View {
        let parts = FusionFormat.parts(point.value, metricKey: point.metric, temperature: temperatureUnit)
        return NoopHeroCard(glow: .ink, padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge(verbatim: "\(metricName) · \(dayLabel)", icon: fusedMetricIcon(point.metric))
                    Spacer(minLength: 8)
                    NoopPill(agreementTitle, compact: true)
                }
                NoopDotNumber(parts.number, unit: parts.unit, size: 88)
                    .padding(.top, 30)
                if let winner {
                    Text("Using \(winner.source.displayName), \(fusedReason(winner.reason)).")
                        .font(StrandFont.light(19, relativeTo: .title3))
                        .tracking(-0.2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 18)
                }
                NoopMetricRow {
                    NoopMetric(value: "\(point.contributors.count)", label: "Sources counted", labelColor: NoopMetric.heroLabel)
                    if let winner {
                        ForEach(Array(point.contributors.dropFirst().prefix(2).enumerated()), id: \.offset) { _, other in
                            if let delta = delta(other, against: winner) {
                                NoopMetric(value: delta.number, unit: delta.unit,
                                           labelText: String(localized: "\(other.source.displayName) vs \(winner.source.displayName)"), labelColor: NoopMetric.heroLabel)
                            }
                        }
                    }
                }
                .padding(.top, 20)
            }
            .padding(.bottom, 2)
        }
    }

    private var agreementTitle: LocalizedStringKey {
        switch point.agreement {
        case .single:     return "One source"
        case .agree:      return "Sources agree"
        case .minorDelta: return "Differs slightly"
        case .conflict:   return "Sources differ"
        }
    }

    /// How far another source sits from the one in use: a percentage for counts, the unit's own
    /// difference for vitals and durations. nil where a difference would mislead (skin temperature
    /// mixes absolute readings with deviations from baseline, #622).
    private func delta(_ other: ContributingSource, against winner: ContributingSource) -> (number: String, unit: String?)? {
        let d = other.value - winner.value
        func signed(_ s: String, negative: Bool, zero: Bool) -> String {
            zero ? s : (negative ? "\u{2212}" : "+") + s
        }
        switch MetricArbitrationPolicy.kind(forKey: point.metric) {
        case .skinTemp:
            return nil
        case .steps, .calories, .other:
            guard winner.value != 0 else { return nil }
            let pct = Int((d / abs(winner.value) * 100).rounded())
            return (signed("\(abs(pct))", negative: pct < 0, zero: pct == 0), "%")
        default:
            let p = FusionFormat.parts(abs(d), metricKey: point.metric, temperature: temperatureUnit)
            let isZero = p.number == "0" || p.number == "0m"
            return (signed(p.number, negative: d < 0, zero: isZero), p.unit)
        }
    }

    private var comparedCard: some View {
        let maxValue = point.contributors.map { abs($0.value) }.max() ?? 0
        return NoopCard {
            VStack(alignment: .leading, spacing: 0) {
                NoopCardHeader("Compared", icon: "chart-bar", caption: "\(metricName) · \(dayLabel)")
                VStack(spacing: 14) {
                    ForEach(Array(point.contributors.enumerated()), id: \.offset) { index, contrib in
                        FusedCompareBar(
                            name: contrib.source.displayName,
                            value: FusionFormat.value(contrib.value, metricKey: point.metric, temperature: temperatureUnit),
                            fraction: maxValue > 0 ? abs(contrib.value) / maxValue : 0,
                            isWinner: index == 0
                        )
                    }
                }
                .padding(.top, 18)
                if let winner {
                    Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
                        .padding(.top, 18)
                        .padding(.bottom, 14)
                    explanation(winner)
                        .font(StrandFont.light(13, relativeTo: .subheadline))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Why this one — the honest explanation of the pick, never a "correct" claim.
    private func explanation(_ winner: ContributingSource) -> Text {
        // The reason is a short label ("counts directly"), so it sits in parentheses rather than inside the
        // clause: interpolated into "because it …" it cannot be translated grammatically.
        Text("NOOP shows the \(winner.source.displayName) reading for this metric (\(fusedReason(winner.reason))): a higher-trust source here, not a verdict that the others are wrong.")
    }
}

/// One source inside the comparison list: its glyph, name (+ "Using" on the winner), the trust
/// reason, its value, and a check on the one in use.
private struct FusedContributorRow: View {
    let contrib: ContributingSource
    let metricKey: String
    let isWinner: Bool
    let temperature: TemperatureUnit

    var body: some View {
        let formatted = FusionFormat.value(contrib.value, metricKey: metricKey, temperature: temperature)
        HStack(spacing: 12) {
            NoopIconTile(contrib.source.fusedSourceIcon)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(verbatim: contrib.source.displayName)
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    // The tag keeps its full width ("IN BENUTZUNG"); the source name yields first.
                    if isWinner { NoopTag("Using", size: 10).fixedSize().layoutPriority(1) }
                }
                Text(verbatim: fusedReason(contrib.reason))
                    .font(StrandFont.light(12, relativeTo: .caption))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            FusedValueText(parts: FusionFormat.parts(contrib.value, metricKey: metricKey, temperature: temperature),
                           size: 17,
                           color: isWinner ? StrandPalette.textPrimary : StrandPalette.textSecondary)
            ZStack {
                if isWinner {
                    Circle().fill(StrandPalette.textPrimary)
                    PhIcon("check", size: 13).foregroundStyle(NoopVisualStyle.canvas)
                }
            }
            .frame(width: 22, height: 22)
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        // Whole-string key per variant (never a concatenated localized tail on an a11y label).
        .accessibilityLabel(isWinner
            ? "\(contrib.source.displayName), \(formatted), in use"
            : "\(contrib.source.displayName), \(formatted)")
    }
}

/// One horizontal bar in the "Compared" card: source name, a bar scaled to the largest reading, the
/// value. The source in use is the bright one.
private struct FusedCompareBar: View {
    let name: String
    let value: String
    let fraction: Double
    let isWinner: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: name)
                .font(StrandFont.book(12, relativeTo: .caption))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 86, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(NoopVisualStyle.inset)
                    Capsule(style: .continuous)
                        .fill(isWinner
                              ? AnyShapeStyle(LinearGradient(colors: [StrandPalette.textPrimary.opacity(0.6),
                                                                      StrandPalette.textPrimary],
                                                             startPoint: .leading, endPoint: .trailing))
                              : AnyShapeStyle(Color.white.opacity(0.2)))
                        .frame(width: max(12, geo.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 12)
            Text(verbatim: value)
                .font(StrandFont.value(13))
                .foregroundStyle(isWinner ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                .lineLimit(1)
                .frame(minWidth: 46, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Display formatting (presentation only — the engine returns raw Doubles + raw keys)

/// Formats a fused metric's `Double` value for display by its resolver key. Pure + local to this
/// screen: the engine deals in numbers, the UI owns units. Sleep/duration keys read as "7h 12m";
/// temp as "34.1 °C" / "93.4 °F" per the reader's preference; HR/HRV/steps as plain
/// integers with the right unit.
enum FusionFormat {
    static func value(_ v: Double, metricKey: String, temperature: TemperatureUnit) -> String {
        switch MetricArbitrationPolicy.kind(forKey: metricKey) {
        case .restingHR, .heartRate:
            return "\(Int(v.rounded())) bpm"
        case .hrv:
            return "\(Int(v.rounded())) ms"
        case .spo2:
            return "\(Int(v.rounded()))%"
        case .skinTemp:
            // #111/#622: this column is BIMODAL — CSV/Health imports carry an ABSOLUTE wrist °C (~30-35),
            // the live BLE pipeline a signed DEVIATION from baseline. Fusion is the one screen that can
            // show both at once, side by side, so the conversion cannot be assumed: +32 belongs only to
            // the absolute reading, and applying it to a −4.2 deviation is what once printed "24.4 °F".
            // SkinTempDisplay picks the conversion AND the chip ("°F" vs "Δ°F") from the value itself.
            return SkinTempDisplay.format(v, fahrenheit: temperature == .fahrenheit)
        case .steps:
            return integerGrouped(v)
        case .sleep:
            return duration(minutes: v)
        case .calories:
            return "\(integerGrouped(v)) kcal"
        case .other:
            // Unknown unit: a trimmed number, no fake unit.
            return v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
        }
    }

    /// The value split into its number and its unit, for layouts that set the unit smaller beside the
    /// number (`52` + `bpm`). Same rules as `value(_:metricKey:temperature:)`; units-less kinds (steps,
    /// sleep) return a nil unit.
    static func parts(_ v: Double, metricKey: String, temperature: TemperatureUnit) -> (number: String, unit: String?) {
        switch MetricArbitrationPolicy.kind(forKey: metricKey) {
        case .restingHR, .heartRate:
            return ("\(Int(v.rounded()))", "bpm")
        case .hrv:
            return ("\(Int(v.rounded()))", "ms")
        case .spo2:
            return ("\(Int(v.rounded()))", "%")
        case .skinTemp:
            // Same bimodal rule as `value`: the kind (absolute vs deviation) is read from the value.
            let kind = SkinTempDisplay.kind(of: v)
            let fahrenheit = temperature == .fahrenheit
            return (SkinTempDisplay.numberString(v, kind: kind, fahrenheit: fahrenheit),
                    SkinTempDisplay.unitSymbol(kind: kind, fahrenheit: fahrenheit))
        case .steps:
            return (integerGrouped(v), nil)
        case .sleep:
            return (duration(minutes: v), nil)
        case .calories:
            return (integerGrouped(v), "kcal")
        case .other:
            return (v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v), nil)
        }
    }

    /// "8,420" — grouped integer.
    private static func integerGrouped(_ v: Double) -> String {
        integerFormatter.string(from: NSNumber(value: v.rounded())) ?? "\(Int(v.rounded()))"
    }
    /// Built once: the value column formats every row on every render.
    private static let integerFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// "7h 12m" from a minutes value; "52m" under an hour; "0m" for nothing.
    private static func duration(minutes: Double) -> String {
        let total = max(0, Int(minutes.rounded()))
        let h = total / 60
        let m = total % 60
        if h == 0 { return "\(m)m" }
        return "\(h)h \(m)m"
    }
}

// MARK: - Preview

#if DEBUG
private extension FusedMetricPoint {
    /// Build a fixture point straight through the real resolver so the preview exercises the engine.
    static func fixture(_ key: String, _ inputs: [(FusionSource, Double)]) -> FusedMetricPoint {
        FusionResolver.resolve(metricKey: key,
                               inputs: inputs.map { FusionInput(source: $0.0, value: $0.1) })!
    }
}

#Preview("Your Data, Fused — multi-source") {
    let record = FusedRecord(
        rows: [
            FusedRow(point: .fixture("rhr", [(.whoopImport, 52), (.appleHealth, 53)]),
                     label: "Resting HR", accentHex: nil),
            FusedRow(point: .fixture("steps", [(.xiaomiBand, 8420), (.whoopImport, 6100)]),
                     label: "Steps"),
            FusedRow(point: .fixture("sleep_total_min", [(.whoopImport, 432), (.appleHealth, 400)]),
                     label: "Sleep"),
            FusedRow(point: .fixture("skin_temp", [(.whoopImport, 34.1)]),
                     label: "Skin temp"),
            FusedRow(point: .fixture("hrv", [(.whoopImport, 68)]),
                     label: "HRV"),
        ],
        dayOwner: .whoopImport,
        contributingSourceCount: 3
    )
    return FusedRecordView(record: record)
        .frame(width: 480, height: 820)
        .preferredColorScheme(.dark)
}

#Preview("Single WHOOP — plain record") {
    let record = FusedRecord(
        rows: [
            FusedRow(point: .fixture("rhr", [(.whoopImport, 52)]), label: "Resting HR"),
            FusedRow(point: .fixture("sleep_total_min", [(.whoopImport, 432)]), label: "Sleep"),
            FusedRow(point: .fixture("hrv", [(.whoopImport, 68)]), label: "HRV"),
        ],
        dayOwner: .whoopImport,
        contributingSourceCount: 1
    )
    return FusedRecordView(record: record)
        .frame(width: 480, height: 600)
        .preferredColorScheme(.dark)
}
#endif

/// The arbitration reason (`MetricArbitrationPolicy.reason`, a fixed English label shared with Android)
/// looked up in the app catalogue, so a translated label shows where one exists.
func fusedReason(_ reason: String) -> String {
    Bundle.main.localizedString(forKey: reason, value: reason, table: nil)
}
