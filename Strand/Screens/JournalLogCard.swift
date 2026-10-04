import SwiftUI
import StrandDesign
import WhoopStore

/// Native journal logging, yes/no chips and numeric fields for the merged behaviour catalog plus a
/// custom-question field, hosted at the top of Insights. Answers write under
/// `Repository.journalDeviceId` ("noop-journal"), NEVER the imported source, so a CSV re-import can't
/// clobber them and clearing is safe (imported rows are never touched). Tri-state: tapping the selected
/// chip again clears the answer. Day attribution follows the importer's wake-day convention, answers
/// describe the night and day leading into the selected morning, so logged days line up with imported
/// history.
///
/// v2 (#322): items sit under collapsible groups (Nutrition / Supplements / …); an item can be a
/// numeric value (with a unit) instead of a toggle; and custom items can be renamed / regrouped /
/// converted / reordered in edit mode. The stored KEY (`canonical`) never changes on a rename, so all
/// history, logged and imported, stays joined under the original question.
struct JournalLogCard: View {
    @EnvironmentObject var repo: Repository
    /// The journal catalog is single-user state owned here (UserDefaults-backed), so hosting the card
    /// needs no app-level injection.
    @StateObject private var catalog = JournalCatalogStore()

    /// Distinct imported question strings (from InsightsView's load), adopted into the catalog so
    /// logged answers and imported history group under the same behaviour.
    let importedQuestions: [String]
    /// question → answeredYes for the selected day, native rows only (drives the chip state).
    let answers: [String: Bool]
    /// question → numeric value for the selected day, native rows only (drives the numeric fields).
    let numericAnswers: [String: Double]
    @Binding var dayOffset: Int            // -1 = tomorrow, 0 = today, 1 = yesterday
    let onChanged: () -> Void              // parent re-runs load() after a write

    init(importedQuestions: [String], answers: [String: Bool],
         numericAnswers: [String: Double] = [:], dayOffset: Binding<Int>,
         onChanged: @escaping () -> Void) {
        self.importedQuestions = importedQuestions
        self.answers = answers
        self.numericAnswers = numericAnswers
        self._dayOffset = dayOffset
        self.onChanged = onChanged
    }

    @State private var customDraft = ""
    @State private var customIsNumeric = false
    @State private var customGroup: JournalGroup = .other
    /// Edit mode: swaps the answer controls for rename/group/convert/remove and reveals hidden items.
    @State private var editing = false
    /// Collapsed groups (persisted per group).
    @AppStorage("journal.collapsedGroups") private var collapsedGroupsRaw = ""
    /// The item being renamed (drives the rename sheet).
    @State private var renaming: JournalCatalogItem?
    @State private var renameDraft = ""

    private var dayKey: String {
        Repository.localDayKey(
            Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date())
    }

    /// The resolved, grouped catalog for the current imported set. Hidden items included only while
    /// editing (so they can be restored in place).
    private var resolved: [JournalCatalogItem] {
        catalog.resolvedItems(imported: importedQuestions, includeHidden: editing)
    }

    /// Items grouped by their group, each group ordered by sortIndex then display.
    private func items(in group: JournalGroup) -> [JournalCatalogItem] {
        resolved.filter { $0.group == group }
            .sorted { ($0.sortIndex, $0.display) < ($1.sortIndex, $1.display) }
    }

    private var collapsedGroups: Set<String> {
        Set(collapsedGroupsRaw.split(separator: ",").map(String.init))
    }

    private func toggleCollapsed(_ group: JournalGroup) {
        var set = collapsedGroups
        if set.contains(group.rawValue) { set.remove(group.rawValue) } else { set.insert(group.rawValue) }
        collapsedGroupsRaw = set.sorted().joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("Journal") {
                Button(editing ? "Done" : "Edit") { editing.toggle() }
                    .buttonStyle(.plain)
                    .font(StrandFont.book(12, relativeTo: .caption))
                    .foregroundStyle(editing ? StrandPalette.textPrimary : StrandPalette.textTertiary)
            }
            // Day picker (#656): a bounded, scrollable range — Tomorrow back through the last 7 days — so
            // any recent day can be backfilled (was Yesterday/Today/Tomorrow only). Chronological
            // left→right; snaps to the selected day, so a deep-link from the Today journal widget lands on
            // that day's pill. Only when not editing.
            if !editing {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Self.journalDayOffsets, id: \.self) { off in
                                dayPill(journalDayLabel(off), offset: off).id(off)
                            }
                        }
                        .padding(.horizontal, 1)   // don't clip the selected pill's ring
                    }
                    // Defer the initial scroll a tick: scrollTo in onAppear can no-op before the pills lay
                    // out, which would leave the picker on the oldest day instead of the selected one.
                    .onAppear { DispatchQueue.main.async { proxy.scrollTo(dayOffset, anchor: .center) } }
                    // onChangeCompat, not onChange: the zero/two-arg onChange is macOS 14+, and this card
                    // is shared with the macOS 13 target.
                    .onChangeCompat(of: dayOffset) { _ in proxy.scrollTo(dayOffset, anchor: .center) }
                }
            }
            NoopCard(padding: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    NoopCardHeader(journalDayLabel(dayOffset), icon: "notebook") {
                        if dayOffset == -1 {
                            Text("Counts toward tomorrow")
                        } else {
                            Text("Leads into this morning")
                        }
                    }
                    .padding(.bottom, 4)

                    ForEach(JournalGroup.displayOrder, id: \.self) { group in
                        groupBlock(group)
                    }

                    Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
                        .padding(.top, 4)
                    addRow
                        .padding(.top, 14)

                    Text(editing
                         ? "Rename, regroup, or remove an item to tidy your list. Renaming keeps the original question behind the scenes, so a WHOOP import still lines up. Custom items are deleted; built-in ones are hidden and can be restored below."
                         : dayOffset == -1
                         ? "Logging ahead for tomorrow: today's activities inform tomorrow's recovery, just as yesterday's are reflected in today's. Tomorrow's answers line up with tomorrow's morning."
                         : "Answers are about the night and day leading into this morning, the same attribution a WHOOP export uses, so logged and imported days line up.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
            }
        }
        .sheet(item: $renaming) { item in renameSheet(item) }
    }

    // MARK: - Group block

    @ViewBuilder private func groupBlock(_ group: JournalGroup) -> some View {
        let groupItems = items(in: group)
        // Empty groups hidden outside edit mode; in edit mode all six show so items can be moved in.
        if !groupItems.isEmpty || editing {
            let collapsed = collapsedGroups.contains(group.rawValue)
            VStack(alignment: .leading, spacing: 0) {
                Button { toggleCollapsed(group) } label: {
                    HStack(spacing: 6) {
                        NoopOverline(verbatim: group.title)
                        Text(verbatim: "\(groupItems.count)")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Spacer()
                        PhIcon(collapsed ? "caret-right" : "caret-down", size: 12)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.title), \(groupItems.count) items, \(collapsed ? "collapsed" : "expanded")")

                if !collapsed {
                    ForEach(groupItems) { item in
                        Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
                        itemRow(item)
                            .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    // MARK: - Item row

    @ViewBuilder private func itemRow(_ item: JournalCatalogItem) -> some View {
        HStack(spacing: 12) {
            PhIcon(Self.icon(for: item), size: 18)
                .foregroundStyle(StrandPalette.textPrimary)
                .opacity(item.hidden ? 0.35 : 0.7)
            Text(verbatim: item.display)   // display = rename ?? canonical; data, not a UI literal
                .font(StrandFont.book(14.5, relativeTo: .subheadline))
                .foregroundStyle(item.hidden ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if editing {
                editControls(item)
            } else if item.kind.isNumeric {
                numericField(item)
            } else {
                yesNoControl(q: item.canonical)
            }
        }
    }

    /// A Phosphor glyph for a journal item, matched on keywords in its (canonical) question; the
    /// group's glyph when nothing matches. Display only — the question text is never changed.
    static func icon(for item: JournalCatalogItem) -> String {
        let q = (JournalQuestionIdentity.canonical(item.canonical) + " " + item.display).lowercased()
        let table: [(keys: [String], icon: String)] = [
            (["alcohol", "drink", "wine", "beer"], "wine"),
            (["caffeine", "coffee", "tea"], "coffee"),
            (["meal", "eat", "food", "snack", "dinner", "sugar"], "fork-knife"),
            (["read"], "book-open"),
            (["screen", "phone", "device"], "device-mobile"),
            (["meditat", "mindful", "breath"], "flower-lotus"),
            (["magnes", "vitamin", "supplement", "melatonin", "zinc", "omega", "creatine"], "pill"),
            (["sauna", "hot"], "thermometer-hot"),
            (["cold", "ice"], "snowflake"),
            (["sex", "intimacy"], "heart"),
            (["nap"], "bed"),
            (["travel", "flight", "fly"], "airplane"),
            (["sick", "ill", "fever"], "first-aid-kit"),
            (["stress", "anxious", "anxiety"], "lightning"),
            (["water", "hydrat"], "drop"),
            (["sun", "daylight", "outside"], "sun"),
            (["stretch", "yoga"], "person-simple-tai-chi"),
            (["workout", "exercise", "train"], "barbell"),
        ]
        for row in table where row.keys.contains(where: { q.contains($0) }) { return row.icon }
        switch item.group {
        case .supplements: return "pill"
        case .nutrition:   return "fork-knife"
        case .lifestyle:   return "sun-horizon"
        case .health:      return "first-aid-kit"
        case .behaviour:   return "person-simple"
        case .other:       return "notebook"
        }
    }

    /// The Yes / No capsule (`.yn`). Tri-state: tapping the selected side again clears the answer.
    private func yesNoControl(q: String) -> some View {
        HStack(spacing: 0) {
            answerPill("Yes", q: q, value: true)
            answerPill("No", q: q, value: false)
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(NoopVisualStyle.surface))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
    }

    // MARK: - Numeric field

    private func numericField(_ item: JournalCatalogItem) -> some View {
        let current = numericAnswers[JournalQuestionIdentity.canonical(item.canonical)]
        return HStack(spacing: 4) {
            stepperButton("minus", q: item.canonical, current: current)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                NumericLogField(
                    value: current,
                    placeholder: "—",
                    onCommit: { v in commitNumeric(item.canonical, value: v) })
                .frame(width: 44)
                if let unit = item.kind.unitLabel, !unit.isEmpty {
                    Text(verbatim: unit)
                        .font(StrandFont.book(10, relativeTo: .caption2))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .frame(minWidth: 56)
            stepperButton("plus", q: item.canonical, current: current)
            if current != nil {
                Button {
                    Task { await repo.clearJournalAnswer(day: dayKey, question: item.canonical); onChanged() }
                } label: {
                    PhIcon("x-circle", size: 16)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(width: 22, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(item.display)")
            }
        }
    }

    private func stepperButton(_ symbol: String, q: String, current: Double?) -> some View {
        Button {
            let base = current ?? 0
            let next = max(0, symbol == "plus" ? base + 1 : base - 1)
            commitNumeric(q, value: next)
        } label: {
            PhIcon(symbol, size: 14)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(NoopVisualStyle.raised))
                .overlay(Circle().strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "plus" ? "Increase" : "Decrease")
    }

    private func commitNumeric(_ q: String, value: Double) {
        Task {
            await repo.saveJournalNumeric(day: dayKey, question: q, value: value)
            onChanged()
        }
    }

    // MARK: - Edit-mode controls

    private func editControls(_ item: JournalCatalogItem) -> some View {
        HStack(spacing: 10) {
            if item.hidden {
                pillButton("Restore", selected: false) { catalog.restore(item.canonical) }
            } else {
                Menu {
                    Button("Rename…") { startRename(item) }
                    Menu("Group") {
                        ForEach(JournalGroup.displayOrder, id: \.self) { g in
                            Button(g.title) { catalog.setGroup(item.canonical, to: g) }
                        }
                    }
                    if item.kind.isNumeric {
                        Button("Change to Yes/No") { catalog.setKind(item.canonical, to: .bool) }
                    } else {
                        Button("Change to Number") { catalog.setKind(item.canonical, to: .numeric(unitLabel: nil)) }
                    }
                } label: {
                    PhIcon("sliders-horizontal", size: 18)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Edit \(item.display)")

                removeButton(item)
            }
        }
    }

    /// Edit-mode control: delete a custom question / hide a built-in one. Tinted red to read as removal.
    private func removeButton(_ item: JournalCatalogItem) -> some View {
        Button { catalog.remove(item.canonical) } label: {
            PhIcon("minus-circle", weight: .fill, size: 20)
                .foregroundStyle(NoopGlow.low.tint)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.custom ? "Delete this custom item" : "Hide this item")
        .accessibilityLabel(item.custom ? "Delete \(item.display)" : "Hide \(item.display)")
    }

    // MARK: - Rename sheet

    private func startRename(_ item: JournalCatalogItem) {
        renameDraft = item.displayName ?? item.canonical
        renaming = item
    }

    private func renameSheet(_ item: JournalCatalogItem) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSheetHeader("Rename item", doneTitle: "Save",
                            doneEnabled: !renameDraft.trimmingCharacters(in: .whitespaces).isEmpty,
                            onCancel: { renaming = nil },
                            onDone: {
                                catalog.rename(item.canonical, to: renameDraft)
                                renaming = nil
                            })
            VStack(alignment: .leading, spacing: 10) {
                TextField("Display name", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .g3FieldChrome()
                Text("History stays under the original question so WHOOP imports still line up.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            Spacer(minLength: 0)
        }
        .frame(minWidth: 320)
        .background(NoopSheetBackground())
        #if os(iOS)
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.visible)
        #endif
    }

    // MARK: - Add row

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Add a custom item…", text: $customDraft)
                    .textFieldStyle(.plain)
                    .font(StrandFont.book(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .g3FieldChrome(minHeight: 44, radius: 14)
                Button {
                    let t = customDraft.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    catalog.addCustom(t,
                                      kind: customIsNumeric ? .numeric(unitLabel: nil) : .bool,
                                      group: customGroup)
                    customDraft = ""
                } label: {
                    PhIcon("plus", size: 16)
                        .foregroundStyle(NoopVisualStyle.canvas)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(StrandPalette.textPrimary))
                        .opacity(customDraft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .disabled(customDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Add")
            }
            HStack(spacing: 8) {
                Button { customIsNumeric = false } label: { NoopChip("Yes/No", isOn: !customIsNumeric) }
                    .buttonStyle(.plain)
                Button { customIsNumeric = true } label: { NoopChip("Number", isOn: customIsNumeric) }
                    .buttonStyle(.plain)
                Spacer(minLength: 0)
                Menu {
                    Picker("Group", selection: $customGroup) {
                        ForEach(JournalGroup.displayOrder, id: \.self) { g in
                            Text(g.title).tag(g)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: customGroup.title)
                        PhIcon("caret-up-down", size: 12)
                    }
                    .font(StrandFont.book(12, relativeTo: .caption))
                    .foregroundStyle(StrandPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("New item group")
            }
        }
    }

    // MARK: - Controls

    private func dayPill(_ label: LocalizedStringKey, offset: Int) -> some View {
        Button {
            dayOffset = offset
            onChanged()   // reload the selected day's answers
        } label: {
            NoopChip(label, isOn: dayOffset == offset)
        }
        .buttonStyle(.plain)
    }

    /// The bounded day-picker range (#656): Tomorrow (-1) plus today and the 6 prior days, chronological
    /// oldest → newest left-to-right. Bounded on purpose — journal answers feed the correlation engine, so
    /// unbounded backfill of stale days would distort it (matches WHOOP's limited retroactive window).
    private static let journalDayOffsets: [Int] = Array((-1...6).reversed())

    /// Short pill label for a day-picker offset (daysBack; -1 = Tomorrow). "%lld days ago" is a String
    /// Catalog key, so 2–6 stay localized just like the twin "%lld nights ago" (#527/#656).
    private func journalDayLabel(_ offset: Int) -> LocalizedStringKey {
        switch offset {
        case -1: return "Tomorrow"
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return "\(offset) days ago"
        }
    }

    private func answerPill(_ label: LocalizedStringKey, q: String, value: Bool) -> some View {
        let selected = answers[JournalQuestionIdentity.canonical(q)] == value
        return Button {
            Task {
                // Tri-state: re-tapping the filled side clears the answer (natural-key delete,
                // scoped to "noop-journal", imported rows can never be removed this way).
                if selected {
                    await repo.clearJournalAnswer(day: dayKey, question: q)
                } else {
                    await repo.saveJournalAnswer(day: dayKey, question: q, answeredYes: value)
                }
                onChanged()
            }
        } label: {
            Text(label)
                .font(StrandFont.book(12, relativeTo: .caption))
                .foregroundStyle(selected ? NoopVisualStyle.canvas : StrandPalette.textTertiary)
                .frame(width: 46)
                .padding(.vertical, 6)
                .background(Capsule(style: .continuous).fill(selected ? StrandPalette.textPrimary : Color.clear))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func pillButton(_ label: LocalizedStringKey, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NoopChip(label, isOn: selected)
        }
        .buttonStyle(.plain)
    }
}

/// A compact numeric log field: shows the current value or a ghost placeholder, commits a Double on
/// return / focus-out. Kept small so the numeric row reads like the yes/no capsule.
private struct NumericLogField: View {
    let value: Double?
    let placeholder: String
    let onCommit: (Double) -> Void

    @State private var text = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(StrandFont.value(16))
            .foregroundStyle(StrandPalette.textPrimary)
            .onAppear { text = value.map(Self.format) ?? "" }
            .onChangeCompat(of: value) { v in text = v.map(Self.format) ?? "" }
            .onSubmit { commit() }
        #if os(iOS)
            .keyboardType(.decimalPad)
        #endif
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: ".")
        if let v = Double(cleaned) { onCommit(v) }
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
