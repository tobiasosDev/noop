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
    /// Distinct journal questions already imported (e.g. a German WHOOP export), verbatim. When
    /// present, the Log is driven entirely by these — grouped by their resolved category and keyed
    /// by the verbatim string — so native logging unifies with the imported history on the same
    /// (deviceId, day, question) key, and the English catalog defaults don't double up the rows.
    @State private var importedQuestions: [String] = []
    /// Entry count per imported question, used to pick the dominant variant when several questions
    /// resolve to the same behaviour (the longest history wins). See `dedupedImportedQuestions`.
    @State private var questionCounts: [String: Int] = [:]
    @State private var saved = false
    /// Set when the user changes any answer/note since the last seed or save. Used to auto-save the
    /// current day before switching days so in-progress edits aren't silently discarded.
    @State private var dirty = false
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
        .safeAreaInset(edge: .bottom, spacing: 0) { stickySaveBar }
        .task {
            selectedDay = initialDay ?? Self.yesterdayKey()
            await load()
            appeared = true
        }
        .onChange(of: selectedDay) { _ in seedAnswersForSelectedDay() }
        .onDisappear {
            // Persist in-progress edits (including answers cleared to "—") when the screen is
            // dismissed — sheet swipe-down or tab/sidebar switch — since that bypasses selectDay.
            if dirty { Task { await save() } }
        }
    }

    // MARK: - Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("Log", overline: "What did you do")
                Spacer()
                dayStepper
            }

            if hasImports {
                // Imported journal present (e.g. a German WHOOP export): log against those exact
                // questions, grouped by resolved category — no English-catalog duplicates.
                ForEach(groupedImports, id: \.0) { group in
                    importedCategoryCard(group.0, group.1)
                }
            } else if journal.trackedBehaviors.isEmpty {
                NoopCard {
                    Text("No behaviours tracked yet. Choose what to log in Settings → Journal.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(JournalCatalog.categories, id: \.self) { cat in
                    let items = journal.trackedBehaviors.filter { $0.category == cat }
                    if !items.isEmpty { categoryCard(cat, items) }
                }
            }
        }
    }

    /// Whether any WHOOP journal data is imported. When true, the Log shows only those questions
    /// (resolved + grouped); the fresh-install path shows the tracked catalog behaviours instead.
    private var hasImports: Bool { !importedQuestions.isEmpty }

    /// One loggable row per distinct behaviour. Multiple imported question strings can resolve to
    /// the same behaviour — a German WHOOP import ("Alkohol konsumiert?") plus an English answer the
    /// user logged natively before catalog resolution existed ("Did you drink any alcohol?"). Both
    /// mean "Alcohol", so we collapse them to a single row keyed by the variant with the MOST
    /// history, so the longest-running series keeps accumulating. Unresolved questions stay distinct.
    private var dedupedImportedQuestions: [String] {
        var repForID: [String: String] = [:]   // behaviour id → chosen representative question
        var standalone: [String] = []           // unresolved questions (kept verbatim, as-is)
        for q in importedQuestions {
            guard let id = JournalCatalog.byQuestion(q)?.id else { standalone.append(q); continue }
            if let cur = repForID[id] {
                if (questionCounts[q] ?? 0) > (questionCounts[cur] ?? 0) { repForID[id] = q }
            } else {
                repForID[id] = q
            }
        }
        return Array(repForID.values) + standalone
    }

    /// Order imported categories: the curated ones first, then "Body" (symptoms), then anything
    /// that didn't resolve. Within a category, sort by display label. Empty buckets are dropped.
    private var groupedImports: [(String, [String])] {
        let order = JournalCatalog.categories + ["Body", "Other"]
        var buckets: [String: [String]] = [:]
        for q in dedupedImportedQuestions {
            let cat = JournalCatalog.byQuestion(q)?.category ?? "Other"
            buckets[cat, default: []].append(q)
        }
        return order.compactMap { cat in
            guard let qs = buckets[cat], !qs.isEmpty else { return nil }
            let sorted = qs.sorted { importedLabel($0).localizedCaseInsensitiveCompare(importedLabel($1)) == .orderedAscending }
            return (cat, sorted)
        }
    }

    /// Display label for an imported question: the resolved catalog label, else a prettified form.
    private func importedLabel(_ q: String) -> String {
        JournalCatalog.byQuestion(q)?.shortLabel ?? Self.prettify(q)
    }

    /// A category card built from imported question strings (each resolved for its label/icon/tint,
    /// but keyed by the verbatim question so the imported history keeps counting).
    private func importedCategoryCard(_ category: String, _ questions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(category.uppercased())
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary)
            NoopCard {
                VStack(spacing: 0) {
                    ForEach(Array(questions.enumerated()), id: \.element) { idx, q in
                        let b = JournalCatalog.byQuestion(q)
                        entryRow(question: q,
                                 label: b?.shortLabel ?? Self.prettify(q),
                                 icon: b?.icon ?? "questionmark.circle",
                                 goodWhenYes: b?.goodWhenYes)
                        if idx < questions.count - 1 {
                            Divider().overlay(StrandPalette.hairline)
                        }
                    }
                }
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
        entryRow(question: b.question, label: b.shortLabel, icon: b.icon, goodWhenYes: b.goodWhenYes)
    }

    /// A single loggable row, keyed by its verbatim question. Used for both catalog behaviours and
    /// absorbed imported questions (which carry no catalog metadata).
    private func entryRow(question: String, label: String, icon: String, goodWhenYes: Bool?) -> some View {
        let answer = answers[question]
        let tint = tintFor(goodWhenYes: goodWhenYes, answer: answer)
        return VStack(spacing: 10) {
            HStack(spacing: NoopMetrics.gap) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(answer != nil ? tint : StrandPalette.textTertiary)
                    .frame(width: 24)
                Text(label)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: NoopMetrics.gap)
                triState(question, tint: tint)
            }
            if expandedNote == question || !(notes[question] ?? "").isEmpty {
                TextField("Add a note (optional)", text: noteBinding(question))
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
                answers[q] = true; expandedNote = q; saved = false; dirty = true
            }
            choice("No", selected: answers[q] == false, tint: tint) {
                answers[q] = false; expandedNote = q; saved = false; dirty = true
            }
            choice("—", selected: answers[q] == nil, tint: StrandPalette.textTertiary) {
                answers[q] = nil; notes[q] = nil
                if expandedNote == q { expandedNote = nil }
                saved = false; dirty = true
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

    /// Save bar pinned to the bottom of the screen so it's always reachable without scrolling.
    /// A short gradient lets the scroll content dissolve into the opaque bar above the home
    /// indicator. Hidden until there's something loggable / loaded.
    @ViewBuilder
    private var stickySaveBar: some View {
        if loaded && !loggableQuestions.isEmpty {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [StrandPalette.surfaceBase.opacity(0), StrandPalette.surfaceBase],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 18)
                .allowsHitTesting(false)
                saveBar
                    .padding(.horizontal, 28)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                    .background(StrandPalette.surfaceBase)
            }
        }
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
                .foregroundStyle(StrandPalette.surfaceBase)
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
        return Button { selectDay(day) } label: {
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
        let imported = await repo.importedJournalQuestions()
        var byDay: [String: [JournalEntry]] = [:]
        var counts: [String: Int] = [:]
        for e in entries {
            byDay[e.day, default: []].append(e)
            counts[e.question, default: 0] += 1
        }
        await MainActor.run {
            history = byDay
            importedQuestions = imported
            questionCounts = counts
            seedAnswersForSelectedDay()
            loaded = true
        }
    }

    /// The row key a stored question maps onto: when imported, the deduped representative for its
    /// behaviour (so a day stored under a non-representative variant still seeds the visible row);
    /// otherwise the question itself.
    private func representativeQuestion(for q: String) -> String {
        guard hasImports, let id = JournalCatalog.byQuestion(q)?.id else { return q }
        return dedupedImportedQuestions.first { JournalCatalog.byQuestion($0)?.id == id } ?? q
    }

    private func seedAnswersForSelectedDay() {
        answers = [:]; notes = [:]; expandedNote = nil; saved = false; dirty = false
        // Apply non-representative variants first, then the representative variant, so when several
        // stored variants of one behaviour share a day the representative's answer AND note both win
        // (consistent with what `save()` will persist). Stable otherwise.
        let rows = (history[selectedDay] ?? []).sorted {
            (representativeQuestion(for: $0.question) == $0.question ? 1 : 0)
                < (representativeQuestion(for: $1.question) == $1.question ? 1 : 0)
        }
        for e in rows {
            // Seed under the representative key the row is rendered with, so an answer stored under
            // any variant of the behaviour shows up (and isn't mistaken for unanswered).
            let key = representativeQuestion(for: e.question)
            answers[key] = e.answeredYes
            // Never clobber a real note with a nil one: the representative variant wins when it has
            // a note, but a note attached to another variant survives if the representative's is nil.
            if let n = e.notes { notes[key] = n }
        }
    }

    private func save() async {
        // Capture the day once: `selectedDay` can change during the awaits below (a concurrent
        // auto-save from selectDay), and the in-memory mirror must land on the day we saved.
        let day = selectedDay
        var draft = JournalDraft(day: day)
        draft.answers = answers
        draft.notes = notes
        let entries = draft.entries()
        let written = Set(entries.map(\.question))

        // Reconcile the day: delete stored rows that belong to a behaviour shown on screen but are
        // no longer the row we just wrote — i.e. a duplicate variant being collapsed onto the
        // representative, or an answer the user cleared to "—". Rows for behaviours NOT shown
        // (e.g. untracked) are left untouched so their history is preserved.
        let shownIDs = Set(loggableQuestions.compactMap { JournalCatalog.byQuestion($0)?.id })
        let shownVerbatim = Set(loggableQuestions)
        let stored = history[day] ?? []
        let deleteKeys: [String] = stored.map(\.question).filter { q in
            guard !written.contains(q) else { return false }
            if let id = JournalCatalog.byQuestion(q)?.id { return shownIDs.contains(id) }
            return shownVerbatim.contains(q)
        }

        await repo.reconcileJournalDay(day, write: entries, delete: deleteKeys)
        await MainActor.run {
            saved = true
            dirty = false
            // Mirror the reconciled state in memory: written rows + any stored rows we left intact.
            let deleted = Set(deleteKeys)
            let kept = stored.filter { !deleted.contains($0.question) && !written.contains($0.question) }
            history[day] = entries + kept
            // Collapse the Today prompt once the morning's target (yesterday) or today is actually
            // logged — not when an auto-save merely cleared answers (entries empty).
            if !entries.isEmpty,
               day == Self.yesterdayKey() || day == Repository.localDayKey(Date()) {
                journal.lastLoggedDay = Repository.localDayKey(Date())
            }
        }
    }

    // MARK: - Helpers

    private func tintFor(goodWhenYes good: Bool?, answer: Bool?) -> Color {
        guard let answer, let good else { return StrandPalette.accent }
        // "good when yes" answered yes → positive; answered the "bad" way → warning.
        return (answer == good) ? StrandPalette.statusPositive : StrandPalette.statusWarning
    }

    private func noteBinding(_ q: String) -> Binding<String> {
        Binding(get: { notes[q] ?? "" }, set: { notes[q] = $0; saved = false; dirty = true })
    }

    /// Switch the edited day, auto-saving the current day first if it has unsaved edits, so
    /// navigating away (stepper or History tap) never silently discards in-progress answers.
    private func selectDay(_ day: String) {
        guard day != selectedDay else { return }
        if dirty {
            Task { await save(); await MainActor.run { selectedDay = day } }
        } else {
            selectedDay = day
        }
    }

    private func shiftDay(_ delta: Int) {
        guard let date = Self.parse(selectedDay),
              let shifted = Calendar.current.date(byAdding: .day, value: delta, to: date) else { return }
        let key = Repository.localDayKey(shifted)
        if key <= Repository.localDayKey(Date()) { selectDay(key) }
    }

    /// Everything loggable on this screen: the deduped imported questions when a WHOOP journal
    /// exists, otherwise the tracked catalog behaviours (fresh install).
    private var loggableQuestions: [String] {
        hasImports ? dedupedImportedQuestions : journal.trackedBehaviors.map(\.question)
    }
    private var answeredCount: Int {
        loggableQuestions.filter { answers[$0] != nil }.count
    }
    private var progressComplete: Bool {
        let total = loggableQuestions.count
        return total > 0 && answeredCount == total
    }
    private var progressText: String {
        "\(answeredCount) of \(loggableQuestions.count) logged"
    }

    /// Turn a verbatim question ("Koffein konsumiert?", "Did you stretch?") into a compact row label.
    private static func prettify(_ question: String) -> String {
        var s = question
        if let r = s.range(of: "?", options: .backwards) { s.removeSubrange(r) }
        for p in ["Did you ", "Have you ", "Were you ", "Do you "] where s.hasPrefix(p) {
            s.removeFirst(p.count)
            s = s.prefix(1).capitalized + s.dropFirst()
            break
        }
        return s.trimmingCharacters(in: .whitespaces)
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
