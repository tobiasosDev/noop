import SwiftUI
import Foundation
import StrandDesign
import StrandImport
import StrandAnalytics
import WhoopStore

// MARK: - Marker editor (manual entry — MVP)
//
// The "+ add a reading" sheet for the Lab Book (Health Records pillar, spec §"Add / edit
// a marker"). Pick a marker from MarkerCatalog (searchable) OR add a custom marker (free
// name + unit), then: value (numeric, the marker's canonical unit prefilled, a unit
// switcher where sensible e.g. mmol/L↔mg/dL with the conversion shown transparently),
// date/time taken, an optional note, and an OPTIONAL "reference range from my report"
// free-text — NEVER a NOOP-shipped range. Blood pressure is a PAIRED marker (systolic +
// diastolic entered together, stored as two keys) so it reads naturally.
//
// On save it hands the caller `[LabMarkerRow]` drafts (one row, or two for BP) under the
// strap device id with a `lab-book`-projecting write path; the caller persists + refreshes.
// SELF-CONTAINED: no AppModel/Settings edits; the sheet owns all its state.
//
// NON-CLINICAL: this only captures what the user types. The reference field is theirs,
// shown back verbatim — NOOP defines no ranges and asserts no normality.

struct MarkerEditorView: View {
    /// Persist the validated draft row(s). Async so the caller can write + refresh.
    let onSave: (_ drafts: [LabMarkerRow]) async -> Void

    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss

    // Marker selection.
    @State private var selection: MarkerDefinition?
    @State private var customName = ""
    @State private var customUnit = ""
    @State private var addingCustom = false
    @State private var search = ""

    // Reading inputs.
    @State private var valueText = ""
    @State private var diastolicText = ""   // only used for the paired BP marker
    @State private var unit = ""
    @State private var unitChoice = 0       // index into the active unit options (the switcher)
    @State private var takenAt = Date()
    @State private var note = ""
    @State private var referenceText = ""

    @State private var saving = false

    private enum Field: Hashable { case value, diastolic, note, reference, customName, customUnit }
    @FocusState private var focused: Field?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            NoopSheetHeader("Add a reading", doneTitle: saving ? "Saving…" : "Save",
                            doneEnabled: !drafts.isEmpty && !saving,
                            onCancel: { dismiss() }, onDone: { save() })
            Text("Type in a number from your own report. It stays on \(Platform.deviceNounPhrase).")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
                .padding(.top, -10)
                .padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    if selection != nil || addingCustom {
                        readingHero
                        detailsList
                        notesSection
                    } else {
                        markerPicker
                    }
                    disclaimerNote
                        .padding(.top, 6)
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.bottom, 30)
            }
            #if os(iOS)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            #if os(iOS) && DEBUG
            .modifier(DemoScrollAnchor())
            #endif
            .scrollDismissesKeyboard(.interactively)
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #else
        // A FIXED frame (not minWidth/minHeight): a macOS sheet hosting a ScrollView needs a definite
        // height, otherwise the scroll content's height stays ambiguous and every row collapses to the top,
        // rendering the title/fields/catalog on top of each other. Matches the other editor sheets.
        .frame(width: 520, height: 720)
        .background(NoopSheetBackground())
        #endif
        .keyboardDoneToolbar($focused)
    }

    // MARK: - Marker picker

    /// The first step: search the catalog, pick a marker (grouped by category), or start a custom one.
    private var markerPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkoutSearchField(query: $search, isFocused: $searchFocused,
                               prompt: String(localized: "Search markers (e.g. LDL, ferritin)"))
                .accessibilityLabel(Text("Search markers"))
            if isSearching {
                pickerLabel(String(localized: "Results")) { Text(verbatim: "\(filteredCatalog.count)") }
                if filteredCatalog.isEmpty {
                    Text("No match. Add it as a custom marker below.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.horizontal, 4)
                } else {
                    catalogList(filteredCatalog, showsCategory: true)
                }
            } else {
                ForEach(catalogGroups, id: \.category) { group in
                    pickerLabel(group.category.displayName) { Text(verbatim: "\(group.markers.count)") }
                    catalogList(group.markers, showsCategory: false)
                }
            }
            pickerLabel(String(localized: "Not in the list?")) { EmptyView() }
            NoopList {
                Button {
                    addingCustom = true
                    focused = .customName
                } label: {
                    NoopRow("Add a custom marker", caption: "Your own name and unit", icon: "plus", chevron: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    private var filteredCatalog: [MarkerDefinition] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return MarkerCatalog.builtIn }
        return MarkerCatalog.builtIn.filter {
            LabBookView.markerName($0).lowercased().contains(q) || $0.displayName.lowercased().contains(q)
                || $0.key.contains(q)
        }
    }

    /// The catalog bucketed by category, in the category's declared order (the Lab Book's own order).
    private var catalogGroups: [(category: LabMarkerCategory, markers: [MarkerDefinition])] {
        LabMarkerCategory.allCases.compactMap { category in
            let markers = MarkerCatalog.builtIn.filter { $0.category == category }
            return markers.isEmpty ? nil : (category, markers)
        }
    }

    /// The `.slabel` above a picker group: 12 pt uppercase ink3, a count at the right.
    private func pickerLabel<Trailing: View>(_ title: String,
                                             @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: title)
                .font(StrandFont.book(12, relativeTo: .caption))
                .tracking(12 * 0.08)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing().font(StrandFont.book(12, relativeTo: .caption))
        }
        .foregroundStyle(StrandPalette.textTertiary)
        .padding(.horizontal, 2)
        .padding(.top, 24)
        .padding(.bottom, 10)
    }

    private func catalogList(_ markers: [MarkerDefinition], showsCategory: Bool) -> some View {
        NoopList {
            ForEach(markers, id: \.key) { def in
                Button {
                    choose(def)
                } label: {
                    NoopRow(title: Text(verbatim: LabBookView.markerName(def)),
                            caption: showsCategory ? Text(verbatim: def.category.displayName) : nil,
                            icon: def.category.icon) {
                        Text(verbatim: def.canonicalUnit)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(LabBookView.markerName(def)), \(def.canonicalUnit)")
            }
        }
    }

    // MARK: - Reading hero

    /// The marker being logged, with the number typed straight into the dot-matrix figure.
    private var readingHero: some View {
        NoopHeroCard(glow: .heart, padding: 18) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    NoopIconBadge(verbatim: heroTitle, icon: addingCustom ? "flask" : category.icon)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button {
                        if addingCustom { addingCustom = false } else { reset() }
                    } label: {
                        NoopPill(addingCustom ? "Marker list" : "Change", icon: "arrows-left-right", compact: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(addingCustom ? Text("Back to the marker list") : Text("Change marker"))
                }
                Group {
                    if isBloodPressure {
                        bloodPressureFigure
                    } else {
                        valueFigure
                    }
                }
                .padding(.top, 26)
                if let heroNote {
                    Text(verbatim: heroNote)
                        .font(StrandFont.footnote)
                        .foregroundStyle(Color.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 18)
                }
            }
            .padding(.bottom, heroNote == nil ? 10 : 0)
            .frame(maxWidth: .infinity)
        }
    }

    private var heroTitle: String {
        if let selection { return LabBookView.markerName(selection) }
        let name = customName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? String(localized: "Custom marker") : name
    }

    /// The quiet line under the figure: the paired-marker note for BP, or the stored unit and the exact
    /// conversion factor when the value is typed in the other unit.
    private var heroNote: String? {
        if isBloodPressure {
            return String(localized: "Entered together; stored as two markers so each lines up cleanly against your signals.")
        }
        guard unitOptions.count > 1 else { return nil }
        return String(localized: "Stored as \(MarkerUnits.canonicalUnit(for: markerKey, fallback: unit)). \(conversionNote)")
    }

    private var valueFigure: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            dotField(text: $valueText, placeholder: "0", field: .value, size: figureSize(valueText))
                .accessibilityLabel(Text("Value"))
            if !activeUnit.isEmpty {
                Text(verbatim: activeUnit)
                    .font(StrandFont.book(15, relativeTo: .subheadline))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var bloodPressureFigure: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            dotField(text: $valueText, placeholder: "120", field: .value, size: 64)
                .accessibilityLabel(Text("Systolic blood pressure in mmHg"))
            Text(verbatim: "/")
                .font(StrandFont.dot(40))
                .foregroundStyle(Color.white.opacity(0.5))
            dotField(text: $diastolicText, placeholder: "80", field: .diastolic, size: 64)
                .accessibilityLabel(Text("Diastolic blood pressure in mmHg"))
            Text(verbatim: "mmHg")
                .font(StrandFont.book(15, relativeTo: .subheadline))
                .foregroundStyle(Color.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
    }

    /// Long values step the figure down so a five-digit reading still fits the hero.
    private func figureSize(_ text: String) -> CGFloat {
        switch text.count {
        case ...3: return 88
        case 4: return 76
        case 5: return 64
        default: return 52
        }
    }

    /// A numeric field drawn as the hero's dot-matrix figure; it sizes to what was typed (or its
    /// placeholder) so the unit sits right beside the number.
    private func dotField(text: Binding<String>, placeholder: String, field: Field, size: CGFloat) -> some View {
        TextField(text: text, prompt: Text(verbatim: placeholder)) { Text("Value") }
            .textFieldStyle(.plain)
            .font(StrandFont.dot(size))
            .foregroundStyle(StrandPalette.textPrimary)
            .multilineTextAlignment(.center)
            .numericKeyboard()
            .focused($focused, equals: field)
            .fixedSize()
            .frame(minWidth: 44)
    }

    // MARK: - Details

    /// Name and unit for a custom marker, the unit switcher where a marker has two, and when it was taken.
    private var detailsList: some View {
        NoopList {
            if addingCustom {
                fieldRow(icon: "textbox", label: "Name", prompt: "e.g. Magnesium",
                         text: $customName, field: .customName,
                         accessibility: "Custom marker name")
                fieldRow(icon: "ruler", label: "Unit", prompt: "e.g. mmol/L",
                         text: $customUnit, field: .customUnit,
                         accessibility: "Custom marker unit")
            } else if unitOptions.count > 1 {
                NoopRow("Unit", icon: "arrows-left-right") {
                    // The transparent unit switcher (e.g. mmol/L ↔ mg/dL).
                    SegmentedPillControl(Array(unitOptions.indices), selection: $unitChoice) { unitOptions[$0] }
                        .fixedSize()
                        .accessibilityLabel("Unit")
                }
            }
            NoopRow("Taken", icon: "calendar-blank") {
                DatePicker("", selection: $takenAt, in: ...Date(),
                           displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .tint(StrandPalette.textPrimary)
                    .accessibilityLabel("Date and time taken")
            }
        }
    }

    // MARK: - Note + reference

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            NoopList {
                fieldRow(icon: "note-pencil", label: "Note (optional)", prompt: "e.g. fasting, morning draw",
                         text: $note, field: .note, accessibility: "Optional note")
                fieldRow(icon: "clipboard-text", label: "Reference range from my report (optional)",
                         // The label above already says whose range it is; the longer prompt was cut off.
                         prompt: "e.g. 2.0-5.0",
                         text: $referenceText, field: .reference,
                         accessibility: "Reference range from your own report, optional")
            }
            Text("NOOP never fills this in. It only shows back exactly what you type from your own report.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    /// A `.li` row holding a text field: the icon tile, a small label, and the field under it.
    private func fieldRow(icon: String, label: LocalizedStringKey, prompt: LocalizedStringKey,
                          text: Binding<String>, field: Field, accessibility: LocalizedStringKey) -> some View {
        HStack(spacing: 14) {
            NoopIconTile(icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(StrandFont.light(12, relativeTo: .caption))
                    .foregroundStyle(StrandPalette.textTertiary)
                TextField(prompt, text: text)
                    .textFieldStyle(.plain)
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .focused($focused, equals: field)
                    .accessibilityLabel(Text(accessibility))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { focused = field }
    }

    // MARK: - Disclaimer

    private var disclaimerNote: some View {
        NoopInsightRow(text: Text("Lab Book keeps your own numbers. It doesn't test, read, or judge them, and it's not medical advice. Everything stays on \(Platform.deviceNounPhrase)."),
                       icon: "lock-simple")
            .padding(.horizontal, 4)
    }

    // MARK: - Selection + units

    private func choose(_ def: MarkerDefinition) {
        selection = def
        unit = def.canonicalUnit
        unitChoice = 0
        focused = .value
    }

    private func reset() {
        selection = nil
        valueText = ""
        diastolicText = ""
        unitChoice = 0
        search = ""
    }

    /// The active marker key (catalog key, or a slug of the custom name).
    private var markerKey: String {
        if let selection { return selection.key }
        return MarkerUnits.slug(customName)
    }

    private var category: LabMarkerCategory {
        if let selection { return selection.category }
        return .other
    }

    private var isBloodPressure: Bool { markerKey == LabBookProjection.bpSystolicKey }

    /// The unit options for the active marker — a switcher list only for markers that have a
    /// well-known dual unit (lipids/glucose: mmol/L↔mg/dL). Everything else has one canonical unit.
    private var unitOptions: [String] {
        if addingCustom { return [customUnit.isEmpty ? "" : customUnit] }
        return MarkerUnits.options(for: markerKey, canonical: unit)
    }

    private var activeUnit: String {
        guard unitOptions.indices.contains(unitChoice) else { return unit }
        return unitOptions[unitChoice]
    }

    private var conversionNote: String {
        guard unitOptions.count > 1, activeUnit != MarkerUnits.canonicalUnit(for: markerKey, fallback: unit),
              let factor = MarkerUnits.factorToCanonical(markerKey: markerKey, from: activeUnit) else {
            return ""
        }
        return String(localized: "× \(MarkerUnits.factorLabel(factor)) on save.")
    }

    // MARK: - Build the draft rows

    /// The validated draft row(s): two for BP, one otherwise. Empty when inputs aren't usable yet.
    private var drafts: [LabMarkerRow] {
        // Custom marker needs a name + unit.
        if addingCustom {
            guard !customName.trimmingCharacters(in: .whitespaces).isEmpty,
                  !customUnit.trimmingCharacters(in: .whitespaces).isEmpty,
                  let v = parsed(valueText) else { return [] }
            return [row(key: markerKey, category: .other, value: v, unit: customUnit)]
        }
        guard selection != nil else { return [] }
        if isBloodPressure {
            guard let sys = parsed(valueText), let dia = parsed(diastolicText) else { return [] }
            return [
                row(key: LabBookProjection.bpSystolicKey, category: .bloodPressure, value: sys, unit: "mmHg"),
                row(key: LabBookProjection.bpDiastolicKey, category: .bloodPressure, value: dia, unit: "mmHg"),
            ]
        }
        guard let raw = parsed(valueText) else { return [] }
        // Convert the entered value to the canonical stored unit if a switcher is in use.
        let canonical = MarkerUnits.canonicalUnit(for: markerKey, fallback: unit)
        let stored = MarkerUnits.toCanonical(markerKey: markerKey, value: raw, from: activeUnit)
        return [row(key: markerKey, category: category, value: stored, unit: canonical)]
    }

    private func row(key: String, category: LabMarkerCategory, value: Double, unit: String) -> LabMarkerRow {
        let trimmedNote = note.trimmingCharacters(in: .whitespaces)
        let trimmedRef = referenceText.trimmingCharacters(in: .whitespaces)
        let epoch = Int(takenAt.timeIntervalSince1970)
        return LabMarkerRow(
            id: "\(key)-\(epoch)-\(UUID().uuidString.prefix(8))",
            deviceId: repo.deviceId,
            markerKey: key,
            category: category.rawValue,
            day: LabBookFormat.dayKey(takenAt),
            takenAt: epoch,
            value: value,
            valueText: nil,
            unit: unit,
            source: "manual",
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            referenceText: trimmedRef.isEmpty ? nil : trimmedRef
        )
    }

    private func parsed(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces))
    }

    private func save() {
        let rows = drafts
        guard !rows.isEmpty else { return }
        saving = true
        Task {
            await onSave(rows)
            dismiss()
        }
    }
}

#if DEBUG
extension MarkerEditorView {
    /// Screenshot harness: open on a catalog marker with a value already typed.
    init(demoMarkerKey: String, value: String, secondValue: String = "",
         onSave: @escaping (_ drafts: [LabMarkerRow]) async -> Void) {
        self.init(onSave: onSave)
        let def = MarkerCatalog.definition(for: demoMarkerKey)
        _selection = State(initialValue: def)
        _unit = State(initialValue: def?.canonicalUnit ?? "")
        _valueText = State(initialValue: value)
        _diastolicText = State(initialValue: secondValue)
    }

    /// Screenshot harness: open on the custom-marker form with a name and unit filled in.
    init(demoCustomName: String, unit: String, onSave: @escaping (_ drafts: [LabMarkerRow]) async -> Void) {
        self.init(onSave: onSave)
        _addingCustom = State(initialValue: true)
        _customName = State(initialValue: demoCustomName)
        _customUnit = State(initialValue: unit)
    }
}
#endif

// MARK: - Unit handling (transparent mmol/L ↔ mg/dL switcher for lipids/glucose)
//
// Only the markers with a well-known dual unit get a switcher; everything else keeps its
// single canonical unit. Conversions are exact and reversible. The stored value is always
// the canonical unit, so the daily projection + correlation stay consistent regardless of
// what the user typed in.

enum MarkerUnits {
    /// Markers whose mg/dL → mmol/L factor we know (molar-mass derived, standard clinical factors).
    /// Lipids share 38.67; glucose uses 18.0.
    private static let mgdlToMmol: [String: Double] = [
        "total_cholesterol": 1.0 / 38.67,
        "ldl":               1.0 / 38.67,
        "hdl":               1.0 / 38.67,
        "triglycerides":     1.0 / 88.57,   // triglyceride molar conversion
        "fasting_glucose":   1.0 / 18.0,
    ]

    /// The canonical (stored) unit for a marker — the catalog's, or a fallback.
    static func canonicalUnit(for key: String, fallback: String) -> String {
        MarkerCatalog.definition(for: key)?.canonicalUnit ?? fallback
    }

    /// The unit options shown in the switcher. Two entries (canonical + mg/dL) for the dual-unit
    /// markers; otherwise just the single canonical unit.
    static func options(for key: String, canonical: String) -> [String] {
        if mgdlToMmol[key] != nil { return [canonicalUnit(for: key, fallback: canonical), "mg/dL"] }
        return [canonical]
    }

    /// Multiplicative factor turning a value in `from` into the canonical unit, or nil if no conversion.
    static func factorToCanonical(markerKey: String, from unit: String) -> Double? {
        guard unit == "mg/dL", let f = mgdlToMmol[markerKey] else { return nil }
        return f
    }

    /// Convert a typed value (in `from`) to the canonical stored unit. Identity when no conversion applies.
    static func toCanonical(markerKey: String, value: Double, from unit: String) -> Double {
        guard let f = factorToCanonical(markerKey: markerKey, from: unit) else { return value }
        return value * f
    }

    /// A short label for the conversion factor (4 sig figs), e.g. "0.02586".
    static func factorLabel(_ f: Double) -> String { String(format: "%.5g", f) }

    /// A lower-cased, underscored slug for a custom marker name → its stable key. Delegates to the CSV
    /// importer's `customKey` so a hand-added custom marker and an imported one always share one key.
    static func slug(_ name: String) -> String {
        let key = LabMarkerCsvImport.customKey(name)
        return key.isEmpty ? "custom_" : key
    }
}

#if DEBUG
@MainActor
private func markerEditorPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Marker Editor") {
    MarkerEditorView { _ in }
        .environmentObject(markerEditorPreviewRepo())
        .frame(width: 520, height: 720)
        .preferredColorScheme(.dark)
}
#endif
