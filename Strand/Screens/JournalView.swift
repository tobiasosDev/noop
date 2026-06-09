import SwiftUI
import Foundation
import StrandDesign
import WhoopStore

/// Native daily behaviour log + history. Writes to the same journal source the WHOOP
/// importer uses (deviceId "my-whoop"), so entries feed InsightsView unchanged. The morning
/// prompt opens this defaulted to yesterday (the just-completed cycle).
///
/// Design: refined within StrandDesign's dark/mint language. The log is a calm, scannable
/// stack of category cards with a sign-aware tri-state (a "bad" habit answered Yes tints
/// red, a "good" one tints mint). History is the payoff — each logged day sits beside that
/// day's recovery in its own gradient colour, so "did this hurt me?" reads at a glance.
struct JournalView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var journal: JournalStore

    let initialDay: String?
    init(initialDay: String? = nil) { self.initialDay = initialDay }

    @State private var selectedDay: String = JournalView.yesterdayKey()
    @State private var answers: [String: Bool] = [:]
    @State private var notes: [String: String] = [:]
    @State private var expandedNote: String?            // which row has its note field open
    @State private var history: [String: [JournalEntry]] = [:]
    @State private var saved = false
    @State private var loaded = false
    @State private var appeared = false

    var body: some View {
        ScreenScaffold(title: "Journal", subtitle: "Log what you did. See what it does.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                logSection
                historySection
                insightsLink
            }
            .opacity(appeared ? 1 : 0)
            .animation(StrandMotion.fade, value: appeared)
        }
        .task {
            selectedDay = initialDay ?? Self.yesterdayKey()
            await load()
            appeared = true
        }
        .onChange(of: selectedDay) { _ in seedAnswersForSelectedDay() }
    }

    // MARK: - Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("Log", overline: "What did you do")
                Spacer()
                dayStepper
            }

            let tracked = journal.trackedBehaviors
            if tracked.isEmpty {
                NoopCard {
                    Text("No behaviours tracked yet. Choose what to log in Settings → Journal.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(JournalCatalog.categories, id: \.self) { cat in
                    let items = tracked.filter { $0.category == cat }
                    if !items.isEmpty { categoryCard(cat, items) }
                }
                saveBar
            }
        }
    }

    private func categoryCard(_ category: String, _ items: [JournalBehavior]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(category.uppercased())
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary)
            NoopCard {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, b in
                        behaviorRow(b)
                        if idx < items.count - 1 {
                            Divider().overlay(StrandPalette.hairline)
                        }
                    }
                }
            }
        }
    }

    private func behaviorRow(_ b: JournalBehavior) -> some View {
        let answer = answers[b.question]
        let tint = rowTint(behavior: b, answer: answer)
        return VStack(spacing: 10) {
            HStack(spacing: NoopMetrics.gap) {
                Image(systemName: b.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(answer != nil ? tint : StrandPalette.textTertiary)
                    .frame(width: 24)
                Text(b.shortLabel)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: NoopMetrics.gap)
                triState(b.question, tint: tint)
            }
            if expandedNote == b.question || !(notes[b.question] ?? "").isEmpty {
                TextField("Add a note (optional)", text: noteBinding(b.question))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .textFieldStyle(.plain)
                    .padding(.leading, 24 + NoopMetrics.gap)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .animation(StrandMotion.fade, value: answer)
    }

    /// Yes / No / — choice. Selecting an answer opens the note field for that row.
    private func triState(_ q: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            choice("Yes", selected: answers[q] == true, tint: tint) {
                answers[q] = true; expandedNote = q; saved = false
            }
            choice("No", selected: answers[q] == false, tint: tint) {
                answers[q] = false; expandedNote = q; saved = false
            }
            choice("—", selected: answers[q] == nil, tint: StrandPalette.textTertiary) {
                answers[q] = nil; notes[q] = nil
                if expandedNote == q { expandedNote = nil }
                saved = false
            }
        }
    }

    private func choice(_ label: String, selected: Bool, tint: Color, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(label)
                .font(StrandFont.captionNumber)
                .frame(minWidth: 34)
                .padding(.vertical, 7)
                .background(selected ? tint.opacity(0.16) : StrandPalette.surfaceInset)
                .foregroundStyle(selected ? tint : StrandPalette.textTertiary)
                .overlay(Capsule().stroke(selected ? tint.opacity(0.5) : .clear, lineWidth: 1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var saveBar: some View {
        HStack {
            StatePill(LocalizedStringKey(progressText), tone: progressComplete ? .positive : .neutral, showsDot: false)
            Spacer()
            Button(action: { Task { await save() } }) {
                HStack(spacing: 7) {
                    Image(systemName: saved ? "checkmark.circle.fill" : "tray.and.arrow.down.fill")
                    Text(saved ? "Saved" : "Save")
                }
                .font(StrandFont.headline)
                .foregroundStyle(saved ? StrandPalette.surfaceBase : StrandPalette.surfaceBase)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(saved ? StrandPalette.statusPositive : StrandPalette.accent)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(answeredCount == 0 && !saved)
            .opacity(answeredCount == 0 && !saved ? 0.4 : 1)
        }
        .animation(StrandMotion.fade, value: saved)
    }

    private var dayStepper: some View {
        HStack(spacing: 12) {
            Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
            Text(dayLabel(selectedDay))
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(minWidth: 86)
                .multilineTextAlignment(.center)
            Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .disabled(selectedDay >= Repository.localDayKey(Date()))
                .opacity(selectedDay >= Repository.localDayKey(Date()) ? 0.3 : 1)
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(StrandPalette.textSecondary)
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("History", overline: "Habits vs. recovery")
            let days = history.keys.sorted(by: >)
            if days.isEmpty {
                NoopCard {
                    Text("Your logged days appear here — each next to that morning's recovery, so you can see what a habit does to your body.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(days, id: \.self) { historyRow($0) }
            }
        }
    }

    private func historyRow(_ day: String) -> some View {
        let entries = history[day] ?? []
        let yes = entries.filter(\.answeredYes)
            .map { JournalCatalog.byQuestion($0.question)?.shortLabel ?? $0.question }
        let recovery = repo.days.first { $0.day == day }?.recovery
        let isSelected = day == selectedDay
        return Button { selectedDay = day } label: {
            NoopCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(dayLabel(day))
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        if isSelected {
                            StatePill("EDITING", tone: .accent, showsDot: false)
                        }
                        Spacer()
                        recoveryReadout(recovery)
                    }
                    if yes.isEmpty {
                        Text("Nothing logged this day")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    } else {
                        ChipFlow(yes)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func recoveryReadout(_ recovery: Double?) -> some View {
        if let r = recovery {
            let c = StrandPalette.recoveryColor(r)
            HStack(spacing: 7) {
                Circle().fill(c).frame(width: 8, height: 8)
                Text("\(Int(r.rounded()))%")
                    .font(StrandFont.number(17))
                    .foregroundStyle(c)
            }
        } else {
            Text("—")
                .font(StrandFont.number(17))
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var insightsLink: some View {
        NoopCard {
            HStack(spacing: NoopMetrics.gap) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(StrandPalette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("See what moves your recovery")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Insights ranks each habit by its measured effect.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                Image(systemName: "arrow.right").foregroundStyle(StrandPalette.accent)
            }
        }
    }

    // MARK: - Load / save

    private func load() async {
        let entries = await repo.journalEntries()
        var byDay: [String: [JournalEntry]] = [:]
        for e in entries { byDay[e.day, default: []].append(e) }
        await MainActor.run {
            history = byDay
            seedAnswersForSelectedDay()
            loaded = true
        }
    }

    private func seedAnswersForSelectedDay() {
        answers = [:]; notes = [:]; expandedNote = nil; saved = false
        for e in history[selectedDay] ?? [] {
            answers[e.question] = e.answeredYes
            if let n = e.notes { notes[e.question] = n }
        }
    }

    private func save() async {
        var draft = JournalDraft(day: selectedDay)
        draft.answers = answers
        draft.notes = notes
        let entries = draft.entries()
        await repo.saveJournal(entries)
        await MainActor.run {
            saved = true
            history[selectedDay] = entries
            // Collapse the Today prompt once the morning's target (yesterday) or today is logged.
            if selectedDay == Self.yesterdayKey() || selectedDay == Repository.localDayKey(Date()) {
                journal.lastLoggedDay = Repository.localDayKey(Date())
            }
        }
    }

    // MARK: - Helpers

    private func rowTint(behavior b: JournalBehavior, answer: Bool?) -> Color {
        guard let answer else { return StrandPalette.accent }
        guard let good = b.goodWhenYes else { return StrandPalette.accent }
        // "good when yes" answered yes → positive; answered no → neutral-ish, and vice versa.
        let isGoodOutcome = (answer == good)
        return isGoodOutcome ? StrandPalette.statusPositive : StrandPalette.statusWarning
    }

    private func noteBinding(_ q: String) -> Binding<String> {
        Binding(get: { notes[q] ?? "" }, set: { notes[q] = $0; saved = false })
    }

    private func shiftDay(_ delta: Int) {
        guard let date = Self.parse(selectedDay),
              let shifted = Calendar.current.date(byAdding: .day, value: delta, to: date) else { return }
        let key = Repository.localDayKey(shifted)
        if key <= Repository.localDayKey(Date()) { selectedDay = key }
    }

    private var answeredCount: Int {
        journal.trackedBehaviors.filter { answers[$0.question] != nil }.count
    }
    private var progressComplete: Bool {
        let total = journal.trackedBehaviors.count
        return total > 0 && answeredCount == total
    }
    private var progressText: String {
        "\(answeredCount) of \(journal.trackedBehaviors.count) logged"
    }

    private func dayLabel(_ key: String) -> String {
        if key == Repository.localDayKey(Date()) { return "Today" }
        if key == Self.yesterdayKey() { return "Yesterday" }
        return Self.pretty(key)
    }

    static func yesterdayKey() -> String {
        Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
    }
    private static func parse(_ key: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }
    private static func pretty(_ key: String) -> String {
        guard let d = parse(key) else { return key }
        let f = DateFormatter(); f.locale = .current; f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return f.string(from: d)
    }
}

// MARK: - Chip flow layout

/// A wrapping row of habit chips. StrandDesign has no chip/flow component, so this is a
/// small native `Layout` (macOS 13 / iOS 16+) — chips wrap to the next line when they run
/// out of width, with consistent spacing.
private struct ChipFlow: View {
    let labels: [String]
    init(_ labels: [String]) { self.labels = labels }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(labels, id: \.self) { l in
                Text(l)
                    .font(StrandFont.caption)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(StrandPalette.surfaceInset)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .overlay(Capsule().stroke(StrandPalette.hairline, lineWidth: 1))
                    .clipShape(Capsule())
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0, totalWidth: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth - spacing)
                rowWidth = 0; rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth - spacing)
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
