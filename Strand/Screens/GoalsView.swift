import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Goal kind metadata (shared with the Today chips)

/// Display metadata for a goal kind. `String(localized:)` (not raw literals) so these
/// computed labels land in the String Catalog.
extension GoalProgress.Kind {
    var displayTitle: String {
        switch self {
        case .sleepDuration: return String(localized: "Sleep duration")
        case .weeklyStrain:  return String(localized: "Weekly strain")
        case .dailySteps:    return String(localized: "Daily steps")
        }
    }

    var symbolName: String {
        switch self {
        case .sleepDuration: return "moon.zzz.fill"
        case .weeklyStrain:  return "flame.fill"
        case .dailySteps:    return "figure.walk"
        }
    }
}

// MARK: - Non-linguistic number fragments (interpolated into localized sentences)

/// "7h 30m" — time fragment, never a sentence.
private func goalHoursText(_ minutes: Double) -> String {
    let h = Int(minutes) / 60, m = Int(minutes) % 60
    return String(format: "%dh %02dm", h, m)
}

/// Thousands-grouped integer fragment (steps).
private func goalStepsText(_ v: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = 0
    return f.string(from: NSNumber(value: v)) ?? "\(Int(v.rounded()))"
}

// MARK: - GoalsView

/// Goals — set a target (sleep / weekly strain / steps), see weekly adherence,
/// streaks and a 7-day dot row. Math in GoalProgress; rows in the goal table.
struct GoalsView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var goalStore: GoalStore

    @State private var showingAdd = false
    @State private var stepsByDay: [String: Double] = [:]

    /// Trailing 7 day-keys ending today, oldest→newest.
    private var weekDays: [String] {
        (0..<7).reversed().map {
            Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -$0, to: Date()) ?? Date())
        }
    }

    var body: some View {
        ScreenScaffold(title: "Goals",
                       subtitle: "Pick a target, then let the week keep score.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if goalStore.goals.isEmpty {
                    ComingSoon(what: "No goals yet. Set one — sleep duration, weekly strain or daily steps — and adherence shows up here and on Today.")
                } else {
                    VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                        ForEach(goalStore.goals, id: \.id) { goal in
                            goalCard(goal)
                        }
                    }
                }
                Button {
                    showingAdd = true
                } label: {
                    Label("Add goal", systemImage: "plus.circle.fill")
                        .font(StrandFont.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
            }
        }
        .task(id: repo.refreshSeq) {
            await goalStore.load()
            stepsByDay = Dictionary(
                await repo.series(key: "steps", source: "apple-health").map { ($0.day, $0.value) },
                uniquingKeysWith: { _, new in new })
        }
        .sheet(isPresented: $showingAdd) {
            AddGoalSheet { kind, target in
                Task { await goalStore.save(kind: kind, target: target) }
            }
        }
    }

    // MARK: Per-goal card

    private func values(for kind: GoalProgress.Kind) -> [String: Double] {
        switch kind {
        case .sleepDuration:
            return Dictionary(uniqueKeysWithValues:
                repo.days.compactMap { d in d.totalSleepMin.map { (d.day, $0) } })
        case .weeklyStrain:
            return Dictionary(uniqueKeysWithValues:
                repo.days.compactMap { d in d.strain.map { (d.day, $0) } })
        case .dailySteps:
            return stepsByDay
        }
    }

    @ViewBuilder
    private func goalCard(_ goal: GoalRow) -> some View {
        if let kind = GoalProgress.Kind(rawValue: goal.kind) {
            let p = GoalProgress.evaluate(kind: kind, target: goal.target,
                                          values: values(for: kind), weekDays: weekDays)
            NoopCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: kind.symbolName)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.accent)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        Text(kind.displayTitle)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Button {
                            Task { await goalStore.archive(id: goal.id) }
                        } label: {
                            Image(systemName: "archivebox")
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Archive this goal")
                        .accessibilityLabel("Archive this goal")
                    }
                    Text(targetLine(kind, target: goal.target))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: percentText(p.percent))
                            .font(StrandFont.number(34))
                            .foregroundStyle(p.percent >= 100 ? StrandPalette.accent : StrandPalette.textPrimary)
                        Text(percentCaption(kind))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Spacer()
                        if p.streak >= 2 {
                            StatePill(streakLabel(p.streak), tone: .positive)
                        }
                    }
                    dotRow(p, kind: kind)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 7-day dot row

    /// Adherence dots, oldest→newest. Daily kinds read hit / missed / no-data.
    /// For .weeklyStrain DayStatus.hit is advisory only (the goal scores the WEEK
    /// AVERAGE — see GoalProgress.swift), so strain dots render neutrally as
    /// data vs no-data and a footnote says how the goal is scored, instead of
    /// painting a single hard day as a per-day pass/fail verdict.
    @ViewBuilder
    private func dotRow(_ p: GoalProgress.Progress, kind: GoalProgress.Kind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(p.week, id: \.day) { d in
                    Circle()
                        .fill(dotColor(d, kind: kind))
                        .overlay(
                            Circle().strokeBorder(
                                d.value == nil ? StrandPalette.hairlineStrong : .clear,
                                lineWidth: 1)
                        )
                        .frame(width: 14, height: 14)
                }
                Spacer()
            }
            if kind == .weeklyStrain {
                Text("Dots show days with strain data — this goal scores the weekly average.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dotRowLabel(p, kind: kind))
    }

    private func dotColor(_ d: GoalProgress.DayStatus, kind: GoalProgress.Kind) -> Color {
        guard d.value != nil else { return StrandPalette.surfaceInset }
        if kind == .weeklyStrain { return StrandPalette.textTertiary }   // neutral: data present
        return d.hit ? StrandPalette.accent : StrandPalette.metricRose.opacity(0.55)
    }

    private func dotRowLabel(_ p: GoalProgress.Progress, kind: GoalProgress.Kind) -> String {
        let dataDays = p.week.filter { $0.value != nil }.count
        if kind == .weeklyStrain {
            return String(localized: "\(dataDays) of 7 days with strain data this week")
        }
        let hits = p.week.filter { $0.hit }.count
        return String(localized: "\(hits) of 7 days hit this week")
    }

    // MARK: Derived text

    /// Pure number — rendered with Text(verbatim:).
    private func percentText(_ percent: Double) -> String {
        String(format: "%.0f%%", min(999, percent))
    }

    private func percentCaption(_ kind: GoalProgress.Kind) -> LocalizedStringKey {
        if kind.isDaily { return "of days hit this week" }
        return "of your weekly target"
    }

    /// Separate singular/plural keys — the pill only shows from 2 up today, but the
    /// guard is UI policy, not a math invariant, so the 1-case stays translatable.
    private func streakLabel(_ n: Int) -> LocalizedStringKey {
        if n == 1 { return "1-day streak" }
        return "\(n)-day streak"
    }

    /// Sentence composed via String(localized:) with the non-linguistic numeric
    /// fragment interpolated — never String(format:) over the whole sentence.
    private func targetLine(_ k: GoalProgress.Kind, target: Double) -> String {
        switch k {
        case .sleepDuration:
            return String(localized: "Target: \(goalHoursText(target)) per night")
        case .weeklyStrain:
            return String(localized: "Target: \(String(format: "%.1f", target)) average day strain")
        case .dailySteps:
            return String(localized: "Target: \(goalStepsText(target)) steps per day")
        }
    }
}

// MARK: - AddGoalSheet

/// Add-goal sheet: kind pill picker + a per-kind target slider with sensible ranges.
/// macOS presents it as a fitted floating sheet; iOS as a medium-detent sheet.
private struct AddGoalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (GoalProgress.Kind, Double) -> Void

    @State private var kind: GoalProgress.Kind = .sleepDuration
    @State private var sleepTarget: Double = 450      // 6h..10h, step 15
    @State private var strainTarget: Double = 14      // 8..18, step 0.5
    @State private var stepsTarget: Double = 10_000   // 4k..20k, step 500

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New goal")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("One active goal per kind — saving replaces the old one.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            SegmentedPillControl(GoalProgress.Kind.allCases, selection: $kind) { $0.displayTitle }
            targetControl
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save goal") {
                    onSave(kind, currentTarget)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 380)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        #endif
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var currentTarget: Double {
        switch kind {
        case .sleepDuration: return sleepTarget
        case .weeklyStrain:  return strainTarget
        case .dailySteps:    return stepsTarget
        }
    }

    private var targetControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            targetReadout
                .font(StrandFont.headline.monospacedDigit())
                .foregroundStyle(StrandPalette.accent)
            slider
                .tint(StrandPalette.accent)
                .accessibilityLabel("Goal target")
            HStack {
                Text(verbatim: rangeEnds.0)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Text(verbatim: rangeEnds.1)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    /// LocalizedStringKey interpolation (specifier / pre-formatted fragment) so each
    /// readout sentence lands in the catalog — never String(format:) on the sentence.
    private var targetReadout: Text {
        switch kind {
        case .sleepDuration:
            return Text("\(goalHoursText(sleepTarget)) per night")
        case .weeklyStrain:
            return Text("\(strainTarget, specifier: "%.1f") average day strain")
        case .dailySteps:
            return Text("\(goalStepsText(stepsTarget)) steps per day")
        }
    }

    @ViewBuilder
    private var slider: some View {
        switch kind {
        case .sleepDuration:
            Slider(value: $sleepTarget, in: 360...600, step: 15)
        case .weeklyStrain:
            Slider(value: $strainTarget, in: 8...18, step: 0.5)
        case .dailySteps:
            Slider(value: $stepsTarget, in: 4000...20000, step: 500)
        }
    }

    /// Pure range-end numbers — rendered with Text(verbatim:).
    private var rangeEnds: (String, String) {
        switch kind {
        case .sleepDuration: return ("6h", "10h")
        case .weeklyStrain:  return ("8.0", "18.0")
        case .dailySteps:    return (goalStepsText(4000), goalStepsText(20000))
        }
    }
}
