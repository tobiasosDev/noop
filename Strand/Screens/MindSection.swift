import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Mind
//
// Phase 1b of the mental-health track (design:
// 2026-06-12-noop-mind-mental-health-design.md). Two pieces:
//
//  1. CHECK-IN — a one-tap "How's your mood today?" card with five values (1–5).
//     The chosen value stays marked; tapping another changes today's answer.
//     Storage via MoodStore (dedicated `noop-mood`
//     source id, one row per local day, edits overwrite).
//
//  2. INSIGHTS — once ≥ 7 mood days exist, up to three plain-English lines
//     correlating mood against the body's signals (HRV, recovery, sleep
//     duration) via CorrelationEngine. Gated at |r| ≥ 0.3 and n ≥ 7 so the
//     section never over-claims from noise.
//
// Guardrails (non-negotiable, from the design doc): non-clinical framing with a
// standing footnote, NEUTRAL palette — no red for low mood, no streaks, no guilt
// mechanics. Self-contained on purpose: the section owns its own load/state so a
// slip here stays local and can't take the rest of Insights down.

struct MindSection: View {
    @EnvironmentObject var repo: Repository

    /// Today's stored mood (1–5); nil until the user checks in.
    @State private var todayMood: Int?
    /// Up to three plain-English correlation lines (strongest |r| first).
    @State private var lines: [MoodLine] = []
    /// Distinct days with a mood entry (insights need ≥ `minDays`).
    @State private var moodDayCount = 0

    /// Minimum mood days AND minimum paired observations before any line shows.
    private static let minDays = 7
    /// Minimum correlation magnitude worth a sentence (matches Explore's gate).
    private static let minAbsR = 0.3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NoopCard(padding: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    NoopCardHeader("Mind", icon: "smiley", captionKey: "How's your mood today?")
                        .padding(.bottom, 6)
                    checkInRow
                    if !lines.isEmpty {
                        insightsBlock
                    }
                }
            }
            // Standing footnote — always visible, never conditional.
            Text("Self-tracking, not a clinical assessment. If low mood persists, talk to a professional. You deserve support.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .task(id: repo.refreshSeq) { await load() }
    }

    // MARK: - Check-in

    /// Five numbered circles, 1 (rough) to 5 (great). The chosen one fills with ink — the same neutral,
    /// non-valenced treatment for every value (no red for low mood; the fill marks the choice, nothing
    /// more). Tapping another value changes today's answer.
    private var checkInRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(Array(MoodStore.scale), id: \.self) { value in
                    faceButton(value)
                    if value < MoodStore.scale.upperBound { Spacer(minLength: 4) }
                }
            }
            HStack {
                Text(verbatim: MoodStore.label(for: MoodStore.scale.lowerBound))
                Spacer()
                if let mood = todayMood {
                    Text(verbatim: MoodStore.label(for: mood))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .accessibilityLabel("Today's mood: \(MoodStore.label(for: mood)), \(mood) of 5")
                }
                Spacer()
                Text(verbatim: MoodStore.label(for: MoodStore.scale.upperBound))
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func faceButton(_ value: Int) -> some View {
        let selected = todayMood == value
        return Button {
            select(value)
        } label: {
            Text(verbatim: "\(value)")
                .font(StrandFont.book(18, relativeTo: .title3))
                .foregroundStyle(selected ? NoopVisualStyle.canvas : StrandPalette.textSecondary)
                .frame(width: 52, height: 52)
                .background(Circle().fill(selected ? StrandPalette.textPrimary : NoopVisualStyle.inset))
                .overlay(Circle().strokeBorder(selected ? Color.clear : NoopVisualStyle.border, lineWidth: 1))
                .contentShape(Circle())
        }
        // Liquid tap response: the same physical settle-inward every tappable control gets.
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel("\(MoodStore.label(for: value)), mood \(value) of 5")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Persist the tap and refresh the insight lines (today's point may shift a correlation).
    private func select(_ value: Int) {
        todayMood = value
        Task {
            await repo.saveMood(day: Repository.localDayKey(Date()), value: value)
            await load()
        }
    }

    // MARK: - Insights

    private var insightsBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
                .padding(.top, 16)
            Text("What tracks your mood (\(moodDayCount) check-ins)")
                .strandOverline()
            // A link is just a link, never framed as good or bad: plain insight lines, no colour.
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 4) {
                    NoopInsightRow(verbatim: line.text)
                    Text(line.caption)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.leading, 30)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// One rendered correlation sentence.
    private struct MoodLine: Identifiable {
        let id: String
        let text: String
        let caption: String
        /// Correlation magnitude 0...1 (|r|).
        let strength: Double
    }

    // MARK: - Load

    private func load() async {
        let mood = await repo.moodSeries()
        let todayKey = Repository.localDayKey(Date())
        let todayValue = mood.last(where: { $0.day == todayKey })
            .map { Int($0.value.rounded()) }

        // Candidate body signals from the merged daily cache (the same source the
        // rest of Insights reads), shaped into the (day, value) form mood uses.
        let days = repo.days
        func bodySeries(_ pick: (DailyMetric) -> Double?) -> [(day: String, value: Double)] {
            days.compactMap { d in pick(d).map { (day: d.day, value: $0) } }
        }
        let candidates: [(id: String, name: String, series: [(day: String, value: Double)])] = [
            ("mind-hrv", "HRV", bodySeries { $0.avgHrv }),
            ("mind-recovery", String(localized: "recovery"), bodySeries { $0.recovery }),
            ("mind-sleep", String(localized: "sleep duration"), bodySeries { $0.totalSleepMin }),
        ]

        // Correlate each candidate against mood; keep the gated survivors, take
        // the strongest |r| first, cap at three lines.
        var built: [MoodLine] = []
        if mood.count >= Self.minDays {
            var scored: [(id: String, name: String, corr: Correlation)] = []
            for c in candidates {
                guard let corr = CorrelationEngine.pearson(
                        CorrelationEngine.alignByDay(c.series, mood)),
                      corr.n >= Self.minDays,
                      abs(corr.r) >= Self.minAbsR else { continue }
                scored.append((c.id, c.name, corr))
            }
            built = scored
                .sorted { abs($0.corr.r) > abs($1.corr.r) }
                .prefix(3)
                .map { Self.moodLine(id: $0.id, metric: $0.name, corr: $0.corr) }
        }

        await MainActor.run {
            self.todayMood = todayValue
            self.moodDayCount = mood.count
            self.lines = built
        }
    }

    /// Plain-English sentence + factual caption for one mood↔metric correlation.
    /// Descriptive, never predictive or prescriptive ("tend to be", not "will be").
    private static func moodLine(id: String, metric: String, corr: Correlation) -> MoodLine {
        let strength: String = {
            switch abs(corr.r) {
            case ..<0.5: return String(localized: "Moderate")
            case ..<0.7: return String(localized: "Strong")
            default:     return String(localized: "Very strong")
            }
        }()
        let text = corr.r > 0
            ? String(localized: "Days with higher \(metric) tend to be your better-mood days.")
            : String(localized: "Days with higher \(metric) tend to be your lower-mood days.")
        let caption = String(localized: "\(strength) link · r = \(String(format: "%+.2f", corr.r)) · n = \(corr.n) days")
        // |r| capped at 1 for the leading strength vessel's fill.
        return MoodLine(id: id, text: text, caption: caption, strength: min(1, abs(corr.r)))
    }
}
