import SwiftUI
import Charts
import Foundation
import UniformTypeIdentifiers
import StrandDesign
import StrandImport
import StrandAnalytics
import WhoopStore

// MARK: - Lab Book (Health Records pillar — v5)
//
// "Your own logbook." NOOP gives you a private place to KEEP the numbers you already
// get from your doctor or pharmacy — bloods, blood pressure, body measurements — and
// SEE them next to your wearable signals, entirely on this device. NOOP never tests
// you, never reads a result for you, and never tells you what a number means medically.
// (Spec: docs/superpowers/specs/2026-06-19-v5-health-records-design.md.)
//
// This screen is SELF-CONTAINED: it takes the repo via the environment (the same one
// every other screen binds to) and reads/writes markers through `repo.storeHandle()` —
// the on-device WhoopStore, where the LabMarkerStore extension lives (v17 `labMarker`
// table). Raw readings are stored under the strap device id (`repo.deviceId`); every
// write also projects a daily series under the `lab-book` source so Compare/Explore/
// Coach see markers unchanged. The "Compare with a signal" surface reuses the same
// Pearson idiom + restrained copy as CompareView's pairCard.
//
// NON-CLINICAL (load-bearing, spec §"Non-clinical / legal framing"): no word here
// asserts a clinical judgement — never "abnormal/high/low/normal" as NOOP's own
// statement; any reference range shown is EXACTLY what the user typed from their own
// report; correlation copy says "association, not a medical finding". The full
// disclaimer shows on the screen and (Wave 3) links to the consolidated About & Legal.

struct LabBookView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState

    /// All readings, grouped + ordered for display. Loaded off the store on appear/refresh.
    @State private var markers: [LabMarkerRow] = []
    @State private var loaded = false

    /// The marker whose detail sheet is open (nil = none).
    @State private var detailKey: String?
    /// Whether the add/edit editor sheet is open.
    @State private var showingEditor = false
    /// Whether the first-use disclaimer sheet is open.
    @State private var showingDisclaimer = false

    // Markers CSV import (LabMarkerCsvImport, Phase 2).
    @State private var showingCsvImporter = false   // macOS .fileImporter presentation
    @State private var csvImporting = false
    @State private var csvSummary: String?
    @State private var csvFailed = false

    var body: some View {
        ScreenScaffold(
            title: nil,
            onRefresh: { await load() },
            // PERF: the column ends in the marker list (a sparkline per marker). The LazyVStack path builds
            // the off-screen rows on demand, so a logbook with many markers doesn't render every row up-front.
            lazy: true
        ) {
            header
            if !loaded {
                G5EmptyCard(icon: "flask", message: Text("Reading your logbook…"))
                    .padding(.top, 10)
            } else if markers.isEmpty {
                emptyState
                    .padding(.top, 10)
            } else {
                if let key = latestChangeKey {
                    latestChangeHero(key)
                        .padding(.top, 10)
                }
                markersSection
            }
            actions
                .padding(.top, loaded && !markers.isEmpty ? 14 : 2)
            aboutRow
                .padding(.top, 14)
            disclaimerNote
                .padding(.top, 8)
        }
        .noopHidesSystemNavBar()
        .task(id: repo.refreshSeq) { await load() }
        .sheet(isPresented: $showingEditor) {
            MarkerEditorView { drafts in
                await save(drafts)
            }
        }
        .sheet(item: detailBinding) { key in
            MarkerDetailView(markerKey: key.id,
                             readings: readings(for: key.id),
                             onDelete: { id in await delete(id) })
        }
        .sheet(isPresented: $showingDisclaimer) {
            LabBookDisclaimerView()
        }
        // macOS picker for the markers CSV; iOS goes through DocumentPicker (see
        // presentCsvImporter) for the iCloud download-on-pick behaviour (#179).
        .fileImporter(isPresented: $showingCsvImporter,
                      allowedContentTypes: [.commaSeparatedText, .plainText],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { importMarkersCsv(url: url) }
            case .failure(let error):
                NSLog("Import: markers CSV picker failed - \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Header (back/add circles, title, scope)

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoopScreenHeader(verbatim: "") {
                NoopCircleButton("plus", accessibilityLabel: "Add a marker reading") { showingEditor = true }
            }
            .padding(.bottom, 18)
            Text("Lab Book")
                .font(StrandFont.title1)
                .tracking(-0.56)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Your bloods, BP and body numbers. Kept private, on \(Platform.deviceNounPhrase).")
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    /// Whole-phrase variants per count so translators see complete phrases (never stitched plurals).
    private var countLine: String {
        let keys = Set(markers.map(\.markerKey)).count
        switch (keys == 1, markers.count == 1) {
        case (true, true):   return String(localized: "1 marker tracked · 1 reading")
        case (true, false):  return String(localized: "1 marker tracked · \(markers.count) readings")
        case (false, true):  return String(localized: "\(keys) markers tracked · 1 reading")
        case (false, false): return String(localized: "\(keys) markers tracked · \(markers.count) readings")
        }
    }

    // MARK: - Latest change (the hero)

    /// The marker whose newest numeric reading is the most recent one in the logbook.
    private var latestChangeKey: String? {
        markers.filter { $0.value != nil }.max(by: { $0.takenAt < $1.takenAt })?.markerKey
    }

    /// The most recent change: the marker's newest reading, where it came from, and its readings over
    /// time. Descriptive arithmetic only — NOOP never judges the value (no in/out-of-range verdict); a
    /// reference range appears only as the user typed it from their own report.
    private func latestChangeHero(_ key: String) -> some View {
        let series = readings(for: key).filter { $0.value != nil }
        let latest = series.last
        let previous = series.dropLast().last
        let category = latest.flatMap { LabMarkerCategory(rawValue: $0.category) }
        return Button { detailKey = key } label: {
            NoopHeroCard(glow: .heart, padding: 22) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        NoopIconBadge("Latest change", icon: "flask")
                        Spacer(minLength: 8)
                        if let latest {
                            NoopPill(verbatim: [category?.displayName, LabBookFormat.shortDay(latest.takenAt)]
                                        .compactMap { $0 }.joined(separator: " · "), compact: true)
                        }
                    }
                    Text(verbatim: displayName(for: key))
                        .font(StrandFont.light(19, relativeTo: .title3))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.top, 26)
                    if let latest, let v = latest.value {
                        HStack(alignment: .lastTextBaseline, spacing: 10) {
                            NoopDotNumber(LabBookFormat.value(v, key: key), size: 96)
                            Text(verbatim: latest.unit)
                                .font(StrandFont.book(15, relativeTo: .subheadline))
                                .foregroundStyle(Color.white.opacity(0.7))
                                .padding(.bottom, 8)
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 10)
                    }
                    if let latest, let v = latest.value, let previous, let p = previous.value {
                        changeRow(key: key, latest: v, previous: p, unit: latest.unit, since: previous.takenAt)
                            .padding(.top, 16)
                    }
                    if series.count > 1 {
                        G5ReadingsLine(values: series.compactMap(\.value),
                                       label: latestReference(key).map { Text("Reference \($0)") })
                            .frame(height: 70)
                            .padding(.top, 20)
                        readingDates(series)
                            .padding(.top, 8)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this marker's history")
    }

    /// "↑ from 24 ng/mL · +58 % since 14 Mar 2026" — the change against the previous reading.
    private func changeRow(key: String, latest: Double, previous: Double, unit: String, since: Int) -> some View {
        let dir = latest > previous ? 1 : (latest < previous ? -1 : 0)
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                PhIcon(dir > 0 ? "arrow-up" : (dir < 0 ? "arrow-down" : "minus"), size: 14)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                Text("from \(LabBookFormat.value(previous, key: key)) \(unit)")
                    .font(StrandFont.light(15, relativeTo: .subheadline))
            }
            .foregroundStyle(Color.white.opacity(0.88))
            Spacer(minLength: 8)
            if previous != 0 {
                let pct = Int(((latest - previous) / abs(previous) * 100).rounded())
                Text("\(pct > 0 ? "+" : "")\(pct) % since \(LabBookFormat.day(since))")
                    .font(StrandFont.footnote)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    /// Up to four reading dates under the hero line, the newest in full ink.
    private func readingDates(_ series: [LabMarkerRow]) -> some View {
        let n = series.count
        let idx = n <= 4 ? Array(0..<n) : [0, n / 3, (2 * n) / 3, n - 1]
        return HStack {
            ForEach(Array(idx.enumerated()), id: \.offset) { i, j in
                if i > 0 { Spacer(minLength: 4) }
                Text(verbatim: LabBookFormat.monthYear(series[j].takenAt))
                    .foregroundStyle(j == n - 1 ? StrandPalette.textPrimary : Color.white.opacity(0.55))
            }
        }
        .font(StrandFont.footnote)
        .lineLimit(1)
    }

    /// The reference range the user typed from their own report, if any reading carries one.
    private func latestReference(_ key: String) -> String? {
        readings(for: key).last(where: { $0.referenceText?.isEmpty == false })?.referenceText
    }

    // MARK: - Markers list

    private var markersSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("Markers", caption: countLine)
            NoopList {
                ForEach(orderedKeys, id: \.self) { key in
                    markerRow(key)
                }
            }
            Text("Sparklines show your last four readings of each marker.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.horizontal, 4)
                .padding(.top, -2)
        }
    }

    /// Every marker key, grouped in the spec's category order, alphabetised by display name within.
    private var orderedKeys: [String] {
        orderedCategories.flatMap { markerKeys(in: $0) }
    }

    // MARK: - Empty state (honest)

    private var emptyState: some View {
        G5EmptyCard(icon: "note-pencil", title: "Keep your own numbers here",
                    message: Text("Type in a blood-pressure reading or a cholesterol value from your last appointment. It stays on \(Platform.deviceNounPhrase), and over time you'll see how it lines up with your sleep, heart rate and recovery."))
    }

    // MARK: - Actions (add a reading · import a markers CSV)
    //
    // The cross-platform floor is manual entry. The bulk markers CSV import is the Phase-2 engine
    // (LabMarkerCsvImport, spec §"Phasing"): (date, marker, value, unit) rows with tolerant headers,
    // catalog + custom marker mapping, and skip-and-count on anything unreadable. The picker follows the
    // Data Sources idiom (DocumentPicker on iOS, .fileImporter on macOS).

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showingEditor = true
            } label: {
                HStack(spacing: 8) {
                    PhIcon("plus", size: 17)
                    Text("Add a reading")
                }
            }
            .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
            .accessibilityLabel("Add a marker reading")

            Button {
                presentCsvImporter()
            } label: {
                HStack(spacing: 8) {
                    if csvImporting {
                        ProgressView().controlSize(.small)
                    } else {
                        PhIcon("file-arrow-down", size: 17)
                    }
                    Text(csvImporting ? "Importing…" : "Import readings (CSV)")
                }
            }
            .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
            .disabled(csvImporting)
            .accessibilityLabel("Choose a markers CSV file to import")
            .accessibilityHint("Bring in a markers CSV (date, marker, value, unit). Names that match the catalog fold onto your existing markers; anything else comes in as a custom marker. Rows that can't be read are skipped and counted, never guessed. Everything you import stays on \(Platform.deviceNounPhrase).")

            if let s = csvSummary {
                NoopInsightRow(verbatim: s, icon: csvFailed ? "warning" : "check-circle")
                    .padding(.top, 4)
            }
        }
    }

    private var aboutRow: some View {
        NoopList {
            Button { showingDisclaimer = true } label: {
                NoopRow("About Lab Book", caption: "What it stores, and what it never claims",
                        icon: "info", chevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Read the full Lab Book note")
        }
    }

    private func presentCsvImporter() {
        #if os(iOS)
        // iOS: UIDocumentPickerViewController with asCopy:true (DocumentPicker) so an
        // undownloaded iCloud file is fetched and handed over readable (#179).
        Task {
            guard let url = await DocumentPicker.importFile([.commaSeparatedText, .plainText]) else { return } // cancelled
            importMarkersCsv(url: url)
        }
        #else
        showingCsvImporter = true
        #endif
    }

    /// Parse a markers CSV (LabMarkerCsvImport) and upsert the readings into the Lab Book
    /// under this device id with the `lab-csv` provenance tag; the daily `lab-book`
    /// projection rides the store's upsert, then a refresh lets Compare/Explore/Coach see
    /// the new markers.
    private func importMarkersCsv(url: URL) {
        csvImporting = true
        csvSummary = nil
        csvFailed = false
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                // A WHOOP biomarker export (its own header signature) routes to the vendor parser —
                // packed units, US 2-digit dates, a Status column carried into note; any other file
                // takes the generic (date,marker,value,unit) path.
                let isWhoop = WhoopBiomarkerExportParser.matches(data: data)
                let result = isWhoop ? WhoopBiomarkerExportParser.parse(data: data)
                                     : LabMarkerCsvImport.parse(data: data)
                let sourceId = isWhoop ? WhoopBiomarkerExportParser.sourceId : LabMarkerCsvImport.sourceId
                guard !result.fileTooLarge else {
                    csvSummary = String(localized: "That file is too large for a markers CSV import.")
                    csvFailed = true
                    csvImporting = false
                    return
                }
                guard result.importedReadings > 0 else {
                    csvSummary = String(localized: "No usable rows found. Check the file has date, marker and value columns.")
                    csvFailed = true
                    logImport("Lab Book CSV: no usable rows (\(result.skippedRows) skipped)")
                    csvImporting = false
                    return
                }
                guard let store = await repo.storeHandle() else {
                    csvSummary = String(localized: "Couldn't open the local store.")
                    csvFailed = true
                    csvImporting = false
                    return
                }
                let rows = result.rows.map { r -> LabMarkerRow in
                    // Local noon of the row's literal day: deterministic, so re-importing
                    // the same file updates in place (natural key
                    // deviceId+markerKey+takenAt+source) instead of duplicating.
                    let epoch = LabBookFormat.noonEpoch(r.day)
                    return LabMarkerRow(
                        id: "\(r.markerKey)-\(epoch)-\(UUID().uuidString.prefix(8))",
                        deviceId: repo.deviceId,
                        markerKey: r.markerKey,
                        category: r.category.rawValue,
                        day: r.day,
                        takenAt: epoch,
                        value: r.value,
                        valueText: nil,
                        unit: r.unit,
                        source: sourceId,
                        note: r.note,
                        referenceText: nil
                    )
                }
                try await store.upsertLabMarkers(rows)
                await repo.refresh()   // re-resolves the lab-book projection into Compare/Explore/Coach
                await load()
                var msg = String(localized: "Imported \(result.importedReadings) readings (\(result.distinctMarkers) markers)")
                if let a = result.earliestDay, let b = result.latestDay, a != b { msg += " · \(a)-\(b)" }
                if result.skippedRows > 0 {
                    // Whole-phrase variants per count; the separator stays outside the localized key.
                    msg += " · " + (result.skippedRows == 1
                                    ? String(localized: "1 row skipped")
                                    : String(localized: "\(result.skippedRows) rows skipped"))
                }
                // A vendor export's not-measured markers ("--" / "No Data Available") are absent by
                // design, not malformed — reported apart so a clean import doesn't look broken.
                if result.notMeasured > 0 {
                    msg += " · " + (result.notMeasured == 1
                                    ? String(localized: "1 not measured")
                                    : String(localized: "\(result.notMeasured) not measured"))
                }
                csvSummary = msg
                csvFailed = false
                logImport("Lab Book CSV: \(result.importedReadings) readings, \(result.distinctMarkers) markers, \(result.skippedRows) rejected")
            } catch {
                csvSummary = String(localized: "Import failed: \(error.localizedDescription)")
                csvFailed = true
                logImport("Lab Book CSV failed: \(error.localizedDescription)")
            }
            csvImporting = false
        }
    }

    /// One privacy-safe line into the SAME exported strap log the other importers use
    /// (issue #421 parity): COUNTS only, never a file name, a path, or any health value.
    /// Same shape as DataSourcesView.logImport.
    private func logImport(_ line: String) {
        live.append(log: "[\(AppModel.logTimeFormatter.string(from: Date()))] Import \(line)")
    }

    // MARK: - Category ordering

    /// Categories present in the data, in the spec's display order.
    private var orderedCategories: [LabMarkerCategory] {
        let present = Set(markers.compactMap { LabMarkerCategory(rawValue: $0.category) })
        return LabBookView.categoryOrder.filter { present.contains($0) }
    }

    private static let categoryOrder: [LabMarkerCategory] = [
        .bloodPanel, .bloodPressure, .bodyMeasurement, .imaging, .appointmentNote, .other,
    ]

    /// Distinct marker keys in a category, alphabetised by display name.
    private func markerKeys(in category: LabMarkerCategory) -> [String] {
        let keys = Set(markers.filter { $0.category == category.rawValue }.map(\.markerKey))
        return keys.sorted { displayName(for: $0) < displayName(for: $1) }
    }

    /// One marker as a tappable list row: icon, name, last-taken caption, a sparkline of its last four
    /// readings, and the latest reading with its unit.
    private func markerRow(_ key: String) -> some View {
        let series = readings(for: key)
        let numeric = series.compactMap { $0.value }
        let latest = series.last
        let category = latest.flatMap { LabMarkerCategory(rawValue: $0.category) }
        return Button {
            detailKey = key
        } label: {
            HStack(spacing: 12) {
                NoopIconTile(category?.icon ?? "flask")
                VStack(alignment: .leading, spacing: 2) {
                    // Two lines for the long names ("Blutdruck (systolisch)") rather than an ellipsis.
                    Text(verbatim: displayName(for: key))
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(lastTakenCaption(latest, category: category))
                        .font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if numeric.count > 1 {
                    G5Sparkline(values: Array(numeric.suffix(4)))
                        .frame(width: 50, height: 22)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: latestValue(latest, key: key))
                        .font(StrandFont.book(17, relativeTo: .body))
                        .tracking(-0.17)
                        .foregroundStyle(StrandPalette.textPrimary)
                    if let unit = latest?.unit, latest?.value != nil, !unit.isEmpty {
                        Text(verbatim: unit)
                            .font(StrandFont.light(11, relativeTo: .caption2))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 66, alignment: .trailing)
            }
            .padding(.leading, 18)
            .padding(.trailing, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayName(for: key)), latest \(latestLabel(latest, key: key)), \(series.count) readings")
    }

    // MARK: - Disclaimer (always visible footnote + link)

    private var disclaimerNote: some View {
        NoopInsightRow(text: Text("Lab Book is a private notebook, not a medical service. NOOP stores and lines up the numbers you enter. It doesn't test, read, diagnose, or advise. Your records never leave \(Platform.deviceNounPhrase); there's no account or cloud, so it isn't \"HIPAA-covered.\" Always rely on your doctor or pharmacist to interpret results."),
                       icon: "lock-simple")
            .padding(.horizontal, 4)
    }

    // MARK: - Data helpers

    /// Marker definition lookup → display name (catalog, else the key humanised).
    private func displayName(for key: String) -> String {
        if let def = MarkerCatalog.definition(for: key) { return LabBookView.markerName(def) }
        return LabBookView.humanise(key)
    }

    /// A built-in marker's name in the app's language. The catalogue's `displayName` is a fixed English
    /// name (it also matches CSV headers, so it stays English there); screens route it through the
    /// string catalogue, falling back to the English name until a translation exists.
    static func markerName(_ def: MarkerDefinition) -> String {
        String(localized: String.LocalizationValue(def.displayName))
    }

    static func humanise(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Readings for one marker, oldest-first (the store already returns them sorted by takenAt).
    private func readings(for key: String) -> [LabMarkerRow] {
        markers.filter { $0.markerKey == key }
    }

    private func latestLabel(_ row: LabMarkerRow?, key: String) -> String {
        guard let row else { return "—" }
        if let v = row.value { return "\(LabBookFormat.value(v, key: key)) \(row.unit)" }
        return row.valueText ?? "—"
    }

    /// The latest reading's number alone (its unit renders below it in the row).
    private func latestValue(_ row: LabMarkerRow?, key: String) -> String {
        guard let row else { return "—" }
        if let v = row.value { return LabBookFormat.value(v, key: key) }
        return row.valueText ?? "—"
    }

    private func lastTakenCaption(_ row: LabMarkerRow?, category: LabMarkerCategory?) -> String {
        guard let row else { return String(localized: "no readings yet") }
        return [LabBookFormat.shortDay(row.takenAt), category?.displayName].compactMap { $0 }.joined(separator: " · ")
    }

    private var detailBinding: Binding<MarkerKeyID?> {
        Binding(
            get: { detailKey.map(MarkerKeyID.init) },
            set: { detailKey = $0?.id }
        )
    }

    // MARK: - Load / save / delete (through the shared on-device store)

    private func load() async {
        guard let store = await repo.storeHandle() else { return }
        // Read by category so we cover them all; markers are stored under the strap device id.
        var all: [LabMarkerRow] = []
        for category in LabMarkerCategory.allCases {
            let rows = (try? await store.labMarkers(deviceId: repo.deviceId, category: category.rawValue)) ?? []
            all.append(contentsOf: rows)
        }
        markers = all.sorted { $0.takenAt < $1.takenAt }
        loaded = true
    }

    private func save(_ drafts: [LabMarkerRow]) async {
        guard !drafts.isEmpty, let store = await repo.storeHandle() else { return }
        try? await store.upsertLabMarkers(drafts)
        await repo.refresh()   // re-resolves the lab-book projection into Compare/Explore/Coach
        await load()
    }

    private func delete(_ id: String) async {
        guard let store = await repo.storeHandle() else { return }
        _ = try? await store.deleteLabMarker(id: id)
        await repo.refresh()
        await load()
    }
}

// MARK: - Small Lab Book charts

/// A marker sparkline: a 1.2 pt line through the readings with a white dot on the newest.
private struct G5Sparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1, let lo = values.min(), let hi = values.max() else { return }
            let span = max(hi - lo, 0.000_1)
            let inset: CGFloat = 3
            let pts = values.enumerated().map { i, v in
                CGPoint(x: inset + (size.width - inset * 2) * CGFloat(i) / CGFloat(values.count - 1),
                        y: inset + (size.height - inset * 2) * (1 - CGFloat((v - lo) / span)))
            }
            var p = Path()
            p.addLines(pts)
            ctx.stroke(p, with: .color(StrandPalette.metricCyan), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            if let last = pts.last {
                ctx.fill(Path(ellipseIn: CGRect(x: last.x - 2.4, y: last.y - 2.4, width: 4.8, height: 4.8)),
                         with: .color(.white))
            }
        }
    }
}

/// The hero's readings line: a thin white line through every reading, hollow points, and a haloed white
/// dot on the newest; an optional caption (the user's own reference text) sits top-left.
private struct G5ReadingsLine: View {
    let values: [Double]
    var label: Text? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                guard values.count > 1, let lo = values.min(), let hi = values.max() else { return }
                let span = max(hi - lo, 0.000_1)
                let top: CGFloat = label == nil ? 8 : 22
                let inset: CGFloat = 7   // room for the end dots' halo inside the canvas
                let pts = values.enumerated().map { i, v in
                    CGPoint(x: inset + (size.width - inset * 2) * CGFloat(i) / CGFloat(values.count - 1),
                            y: top + (size.height - top - 8) * (1 - CGFloat((v - lo) / span)))
                }
                var p = Path()
                p.addLines(pts)
                ctx.stroke(p, with: .color(.white.opacity(0.8)), lineWidth: 1.2)
                for pt in pts.dropLast() {
                    let r = CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)
                    ctx.fill(Path(ellipseIn: r), with: .color(.black))
                    ctx.stroke(Path(ellipseIn: r), with: .color(.white.opacity(0.8)), lineWidth: 1)
                }
                if let last = pts.last {
                    ctx.fill(Path(ellipseIn: CGRect(x: last.x - 7, y: last.y - 7, width: 14, height: 14)),
                             with: .color(.white.opacity(0.18)))
                    ctx.fill(Path(ellipseIn: CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7)),
                             with: .color(.white))
                }
            }
            if let label {
                label.font(StrandFont.light(9.5))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .padding(.leading, 6)
                    .padding(.top, 4)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Identifiable wrapper so a String marker key can drive `.sheet(item:)`

private struct MarkerKeyID: Identifiable { let id: String }

// MARK: - Category display names + ordering

extension LabMarkerCategory {
    /// Human label for the Lab Book grouping header. Organisational only — never a clinical panel name.
    var displayName: String {
        switch self {
        case .bloodPanel:      return String(localized: "Blood panel")
        case .bloodPressure:   return String(localized: "Blood pressure")
        case .bodyMeasurement: return String(localized: "Body")
        case .imaging:         return String(localized: "Imaging")
        case .appointmentNote: return String(localized: "Notes")
        case .other:           return String(localized: "Custom")
        }
    }

    /// The Phosphor icon for a category's list rows.
    var icon: String {
        switch self {
        case .bloodPanel:      return "drop"
        case .bloodPressure:   return "heartbeat"
        case .bodyMeasurement: return "scales"
        case .imaging:         return "scan"
        case .appointmentNote: return "note-pencil"
        case .other:           return "flask"
        }
    }
}

// MARK: - Shared formatting (decimals from the catalog; UTC day labels)

enum LabBookFormat {
    /// Format a numeric value with the marker's catalog decimals. A custom (non-catalog) marker has no
    /// declared precision, so it is shown at its own precision via `plain` rather than a fixed 1 decimal,
    /// which rounded plateletcrit 0.27 to "0.3" and urine specific gravity 1.020 to "1.0".
    static func value(_ v: Double, key: String) -> String {
        guard v.isFinite else { return "—" }
        guard let decimals = MarkerCatalog.definition(for: key)?.decimals else { return plain(v) }
        return decimals == 0 ? String(Int(v.rounded())) : String(format: "%.\(decimals)f", v)
    }

    /// Up to 3 decimals with trailing zeros dropped ("0.27", "1.02", "140"), always with a "." separator
    /// whatever the device locale (`String(format:)` without a locale is POSIX). A value that rounds to
    /// zero prints "0", never "-0"; a non-finite value prints "—". Twin: `LabValueFormat.plain` (Android);
    /// both are pinned by the same expected strings in `LabBookFormatTests` / `LabValueFormatTest`.
    static func plain(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    /// "12 Jun 2026" for a takenAt epoch-seconds value, in the app language (it sits inside sentences such
    /// as "+58 % since …", which a fixed English month broke in German).
    static func day(_ epoch: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(epoch))
            .formatted(.dateTime.day().month(.abbreviated).year().locale(AppLanguage.activeLocale))
    }

    /// "12 Sep" for a takenAt epoch-seconds value, in the app language (row captions, pills).
    static func shortDay(_ epoch: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(epoch))
            .formatted(.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale))
    }

    /// "Sep 2026" for a takenAt epoch-seconds value (chart date captions).
    static func monthYear(_ epoch: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(epoch))
            .formatted(.dateTime.month(.abbreviated).year().locale(AppLanguage.activeLocale))
    }

    /// "12 Sep" from a stored `yyyy-MM-dd` day, parsed and rendered in UTC like `dayFromKey`.
    static func dayMonthFromKey(_ day: String) -> String {
        guard let date = utcKeyFormatter.date(from: day) else { return day }
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale)
        style.timeZone = TimeZone(identifier: "UTC") ?? .current
        return date.formatted(style)
    }

    /// "2026" from a stored `yyyy-MM-dd` day.
    static func yearFromKey(_ day: String) -> String {
        String(day.prefix(4))
    }

    /// "12 Jun 2026" rendered from a stored `yyyy-MM-dd` day string, LOCATION-INDEPENDENTLY: the day key
    /// is parsed in UTC and reformatted in UTC, so the history date never shifts with the device zone the
    /// way `day(takenAt)` (a local render of a stored instant) can near midnight. Falls back to the raw
    /// string if it doesn't parse.
    static func dayFromKey(_ day: String) -> String {
        guard let date = utcKeyFormatter.date(from: day) else { return day }
        return utcDayFormatter.string(from: date)
    }

    /// "d MMM yyyy" pinned to UTC, paired with `utcKeyFormatter` so `dayFromKey` round-trips a UTC day.
    private static let utcDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    /// The `yyyy-MM-dd` day key the projection uses (LOCAL day of the reading).
    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func dayKey(_ date: Date) -> String { keyFormatter.string(from: date) }

    /// A `yyyy-MM-dd` parser PINNED to UTC, so a day string always maps to the same instant regardless
    /// of the device zone. The local-zone `keyFormatter` above returns nil for a day whose LOCAL midnight
    /// is skipped by a DST transition (e.g. Chile/Cuba, 06 Sep) - which used to collapse `noonEpoch` to
    /// epoch 0 and collide different days on the natural key. UTC never skips midnight.
    private static let utcKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Epoch seconds of UTC noon on a `yyyy-MM-dd` day — the deterministic, LOCATION-INDEPENDENT `takenAt`
    /// for CSV-imported readings, so re-importing the same file (even after travel to another zone) upserts
    /// in place instead of minting a duplicate (natural key deviceId+markerKey+takenAt+source). Pinned to
    /// UTC so a DST-skipped local midnight can never collapse the key to epoch 0. 0 only for a genuinely
    /// unparseable day string. History dates render from the stored `day` string, not this takenAt.
    static func noonEpoch(_ day: String) -> Int {
        guard let midnight = utcKeyFormatter.date(from: day) else { return 0 }
        return Int(midnight.timeIntervalSince1970) + 12 * 3600
    }
}

// MARK: - Marker detail (history + trend + "compare with a signal")

private struct MarkerDetailView: View {
    let markerKey: String
    let readings: [LabMarkerRow]
    let onDelete: (_ id: String) async -> Void

    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss

    /// The wearable metric chosen to correlate against (nil until the user picks one).
    @State private var signal: MetricDescriptor?
    /// The trailing-window width for the windowed-aggregate pairing.
    @State private var window: LabWindow = .fortnight
    /// The computed correlation result, recomputed when signal/window change.
    @State private var pairs: [WindowedPair] = []
    @State private var correlation: Correlation?
    @State private var computing = false
    /// The reading whose trash was tapped, held for the confirmation: a delete cannot be undone.
    @State private var pendingDelete: LabMarkerRow?

    private var displayName: String {
        MarkerCatalog.definition(for: markerKey).map(LabBookView.markerName) ?? LabBookView.humanise(markerKey)
    }
    private var unit: String { readings.last?.unit ?? MarkerCatalog.definition(for: markerKey)?.canonicalUnit ?? "" }
    private var numericReadings: [LabMarkerRow] { readings.filter { $0.value != nil } }
    private var category: LabMarkerCategory? {
        readings.last.flatMap { LabMarkerCategory(rawValue: $0.category) }
            ?? MarkerCatalog.definition(for: markerKey)?.category
    }

    var body: some View {
        ScreenScaffold(title: nil,
                       // PERF: hero + trend chart + the compare card + the row-per-reading history list.
                       // The LazyVStack path builds the off-screen history rows on demand, so a marker
                       // with many readings doesn't materialise its whole list before the hero is on screen.
                       lazy: true) {
            NoopScreenHeader(verbatim: displayName) { EmptyView() }
                .padding(.bottom, 8)
            hero
            if numericReadings.count > 1 { trendSection }
            if !numericReadings.isEmpty { compareSection }
            historySection
            Text("These are your own numbers shown back to you. NOOP doesn't decide whether any value is normal, high or low.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, 2)
        }
        .noopHidesSystemNavBar()
        .confirmationDialog("Delete this reading?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { row in
            Button("Delete", role: .destructive) { Task { await onDelete(row.id) } }
            Button("Cancel", role: .cancel) {}
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        // Fixed frame — a macOS sheet around a ScrollView needs a definite height or its rows
        // collapse to the top and overlap (the "Add a reading" layout bug).
        .frame(width: 520, height: 720)
        #endif
        .background(NoopVisualStyle.canvas)
    }

    // MARK: - Hero (descriptive arithmetic, never interpretation)

    private var hero: some View {
        let latest = readings.last
        let previous = numericReadings.dropLast().last
        return NoopHeroCard(glow: .heart, padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge(verbatim: displayName, icon: category?.icon ?? "flask")
                    Spacer(minLength: 8)
                    if let latest {
                        NoopPill(verbatim: String(localized: "Latest · \(LabBookFormat.shortDay(latest.takenAt))"),
                                 compact: true)
                    }
                }
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    NoopDotNumber(latestNumber, size: 96)
                    if latest?.value != nil {
                        Text(verbatim: unit)
                            .font(StrandFont.book(15, relativeTo: .subheadline))
                            .foregroundStyle(Color.white.opacity(0.7))
                            .padding(.bottom, 8)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 30)
                Text(trendSentence)
                    .font(StrandFont.light(17, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
                NoopMetricRow {
                    if let ref = latestReferenceText {
                        NoopMetric(value: ref, label: "From your report", labelColor: NoopMetric.heroLabel)
                    }
                    if let previous, let p = previous.value {
                        NoopMetric(value: LabBookFormat.value(p, key: markerKey), unit: unit,
                                   label: "Previous · \(LabBookFormat.shortDay(previous.takenAt))",
                                   labelColor: NoopMetric.heroLabel)
                    }
                    NoopMetric(value: "\(readings.count)", label: countLabel, labelColor: NoopMetric.heroLabel)
                }
                .padding(.top, 20)
            }
        }
    }

    /// Whole-phrase variants per count (never a stitched plural).
    private var countLabel: LocalizedStringKey {
        readings.count == 1 ? "1 reading · your own entries" : "\(readings.count) readings · your own entries"
    }

    private var latestNumber: String {
        guard let row = readings.last else { return "—" }
        if let v = row.value { return LabBookFormat.value(v, key: markerKey) }
        return row.valueText ?? "—"
    }

    /// "Your last 3 LDL readings: 3.4 → 3.1 → 2.9 mmol/L, trending down." — descriptive only.
    /// Whole-phrase variants per direction so translators never see a stitched trend fragment.
    private var trendSentence: String {
        let nums = numericReadings
        guard let last = nums.last?.value else {
            return readings.last?.valueText.map { String(localized: "Latest entry: \($0).") } ?? String(localized: "No numeric readings yet.")
        }
        guard nums.count >= 2 else {
            return String(localized: "One reading so far: \(LabBookFormat.value(last, key: markerKey)) \(unit). Log a few more to see a trend.")
        }
        let shown = nums.suffix(3).compactMap { $0.value }
        let arrowed = shown.map { LabBookFormat.value($0, key: markerKey) }.joined(separator: " → ")
        let first = shown.first ?? last
        if last > first {
            return String(localized: "Your last \(shown.count) readings: \(arrowed) \(unit), trending up.")
        }
        if last < first {
            return String(localized: "Your last \(shown.count) readings: \(arrowed) \(unit), trending down.")
        }
        return String(localized: "Your last \(shown.count) readings: \(arrowed) \(unit), holding steady.")
    }

    private var latestReferenceText: String? {
        readings.last(where: { ($0.referenceText?.isEmpty == false) })?.referenceText
    }

    // MARK: - Trend

    private var trendSection: some View {
        let nums = numericReadings
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("Trend") {
                if let a = nums.first, let b = nums.last {
                    Text(verbatim: "\(LabBookFormat.monthYear(a.takenAt)) – \(LabBookFormat.monthYear(b.takenAt)) · \(unit)")
                }
            }
            MarkerTrendChart(readings: nums, markerKey: markerKey, unit: unit)
                .frame(height: 170)
        }
    }

    // MARK: - Compare with a signal (reuses the Pearson idiom + restrained copy)

    private var compareSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("Compare with a signal")
            NoopCard {
                VStack(alignment: .leading, spacing: 16) {
                    signalChips
                    SegmentedPillControl(LabWindow.allCases, selection: $window, fillsAvailableWidth: true) { $0.label }
                        .accessibilityLabel("Trailing window")

                    if signal == nil {
                        Text("Pick a wearable signal (resting HR, HRV, sleep, Charge, weight…) to line it up against this marker. NOOP averages the signal over the \(window.phrase) before each reading.")
                            .font(StrandFont.light(14, relativeTo: .subheadline))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        resultBlock
                    }
                }
            }
        }
        .task(id: "\(signal?.id ?? "")|\(window.rawValue)|\(repo.refreshSeq)") {
            await recompute()
        }
    }

    /// The pickable wearable signals as chips; tapping the selected chip clears it.
    private var signalChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LabBookSignals.options) { metric in
                    Button {
                        signal = signal?.id == metric.id ? nil : metric
                    } label: {
                        NoopChip(verbatim: metric.title, isOn: signal?.id == metric.id)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .accessibilityLabel("Choose a wearable signal to compare")
    }

    @ViewBuilder
    private var resultBlock: some View {
        let n = pairs.count
        if computing {
            Text("Lining them up…").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
        } else if n < LabBookSignals.floor {
            // Below the floor: show the points exist, withhold the conclusion sentence.
            // Whole-phrase variants per count (never a stitched plural).
            if n > 0 { scatter(nil) }
            HStack(alignment: .top, spacing: 12) {
                NoopTag("Too few", size: 10.5).fixedSize()
                Text(n == 0
                     ? "No overlap yet between this marker and \(signal?.title.lowercased() ?? String(localized: "that signal")). Log a few more readings (and keep wearing your strap)."
                     : (n == 1
                        ? "1 reading lines up so far, not enough to read a trend yet (NOOP waits for \(LabBookSignals.floor))."
                        : "\(n) readings line up so far, not enough to read a trend yet (NOOP waits for \(LabBookSignals.floor))."))
                    .font(StrandFont.light(13.5, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 14)
            .overlay(alignment: .top) { Rectangle().fill(NoopVisualStyle.border).frame(height: 1) }
        } else if let c = correlation {
            pairResult(c, n: n)
        } else {
            scatter(nil)
            Text("\(n) readings line up, but there isn't enough variation to compute a relationship.")
                .font(StrandFont.light(13.5, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One correlation read-out, in the shipped restrained idiom + the mandatory markers clause.
    private func pairResult(_ c: Correlation, n: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "r = \(LabBookSignals.signedR(c.r))")
                    .font(StrandFont.light(28, relativeTo: .title))
                    .tracking(-0.56)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(n) paired readings")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            scatter(c)
            NoopInsightRow(verbatim: LabBookSignals.insightSentence(markerName: displayName,
                                                                     signalName: signal?.title ?? "the signal",
                                                                     r: c.r))
            // The mandatory clause for markers (spec §"On-device algorithm").
            Text("\(n) readings used · \(LabBookSignals.strengthWord(c.r)) \(LabBookSignals.directionWord(c.r)) association. This is your own data sitting side by side. It's not a medical finding, and it shows association, not cause.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// The paired readings as a scatter (marker on x, the signal's window mean on y), with the fitted
    /// line when a correlation exists. Purely descriptive.
    private func scatter(_ c: Correlation?) -> some View {
        MarkerPairScatter(pairs: pairs, fit: c.map { ($0.slope, $0.intercept) },
                          xLabel: displayName, yLabel: signal?.title ?? "")
            .frame(height: 130)
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("History", caption: readings.count == 1 ? String(localized: "1 reading")
                                                                       : String(localized: "\(readings.count) readings"))
            NoopList {
                ForEach(readings.reversed(), id: \.id) { row in
                    historyRow(row)
                }
            }
        }
    }

    private func historyRow(_ row: LabMarkerRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: LabBookFormat.dayMonthFromKey(row.day))
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: LabBookFormat.yearFromKey(row.day))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(width: 92, alignment: .leading)
            Text(verbatim: row.note ?? "")
                .font(StrandFont.light(13, relativeTo: .footnote))
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: row.value.map { LabBookFormat.value($0, key: markerKey) } ?? row.valueText ?? "—")
                    .font(StrandFont.book(17, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                if row.value != nil {
                    Text(verbatim: row.unit)
                        .font(StrandFont.light(11, relativeTo: .caption2))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .lineLimit(1)
            Button(role: .destructive) {
                pendingDelete = row
            } label: {
                // A 44 pt target around the 28 pt glyph, without widening the row's value column.
                PhIcon("trash", size: 15)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(width: 28, height: 28)
                    .padding(8)
                    .contentShape(Rectangle())
                    .padding(-8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete this reading")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Correlation compute (windowed-aggregate pairing → Pearson)

    private func recompute() async {
        guard let signal else { pairs = []; correlation = nil; return }
        computing = true
        defer { computing = false }
        // The marker series, read from the projected `lab-book` daily series (numeric only).
        let markerSeries = await repo.series(key: markerKey, source: WhoopStore.labBookSourceId)
        // The wearable series, freshest-wins through the Explore read path.
        let wearable = await repo.exploreSeries(key: signal.key, source: signal.source)
        let built = LabBookProjection.pairMarkerToWearable(marker: markerSeries,
                                                           wearable: wearable,
                                                           windowDays: window.days)
        pairs = built
        correlation = built.count >= LabBookSignals.floor
            ? CorrelationEngine.pearson(LabBookProjection.correlationInput(built))
            : nil
    }
}

/// The marker's readings over time: a y scale on the left, the readings placed by date as a line + fill,
/// each point labelled with its value, the newest one white with a dashed drop to the axis, and up to four
/// reading dates underneath.
private struct MarkerTrendChart: View {
    let readings: [LabMarkerRow]
    let markerKey: String
    let unit: String

    private var values: [Double] { readings.compactMap(\.value) }

    /// Four evenly spaced, rounded y ticks spanning the readings with some headroom.
    private var ticks: [Double] {
        guard let lo = values.min(), let hi = values.max() else { return [0, 1] }
        let rawSpan = max(hi - lo, abs(hi) * 0.1, 1)
        let step = Self.niceStep(rawSpan / 2.5)
        let start = (lo / step).rounded(.down) * step - (lo - (lo / step).rounded(.down) * step < step * 0.3 ? step : 0)
        return (0..<5).map { start + Double($0) * step }.filter { $0 <= hi + step * 1.2 }
    }

    private static func niceStep(_ raw: Double) -> Double {
        let mag = pow(10, floor(log10(max(raw, 0.000_1))))
        let n = raw / mag
        let nice: Double = n <= 1 ? 1 : (n <= 2 ? 2 : (n <= 5 ? 5 : 10))
        return nice * mag
    }

    /// Plot positions for the readings inside a plot of `size`, placed by date, scaled into `lo...hi`.
    private func points(in size: CGSize, lo: Double, hi: Double) -> [CGPoint] {
        let times = readings.map { Double($0.takenAt) }
        let t0 = times.first ?? 0, t1 = times.last ?? 1
        let inset: CGFloat = 8
        let span = max(hi - lo, 0.000_1)
        var out: [CGPoint] = []
        for (t, v) in zip(times, values) {
            let fx: Double = t1 > t0 ? (t - t0) / (t1 - t0) : 0.5
            let x = inset + (size.width - inset * 2) * CGFloat(fx)
            let y = size.height * (1 - CGFloat((v - lo) / span))
            out.append(CGPoint(x: x, y: y))
        }
        return out
    }

    var body: some View {
        let ticks = self.ticks
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading) {
                    ForEach(Array(ticks.reversed().enumerated()), id: \.offset) { i, t in
                        if i > 0 { Spacer(minLength: 0) }
                        Text(verbatim: LabBookFormat.plain(t))
                    }
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 30, alignment: .leading)
                GeometryReader { geo in
                    plot(size: geo.size, ticks: ticks)
                }
                .padding(.top, 6)
            }
            dateLabels
                .padding(.leading, 36)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Trend of \(readings.count) readings"))
    }

    @ViewBuilder
    private func plot(size: CGSize, ticks: [Double]) -> some View {
        let lo = ticks.first ?? 0, hi = ticks.last ?? 1
        let h = size.height
        let pts = points(in: size, lo: lo, hi: hi)
        ZStack(alignment: .topLeading) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { _, t in
                Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
                    .offset(y: h * (1 - CGFloat((t - lo) / max(hi - lo, 0.000_1))))
            }
            if pts.count > 1 {
                areaPath(pts, height: h)
                    .fill(LinearGradient(colors: [StrandPalette.effortColor.opacity(0.42),
                                                  StrandPalette.effortColor.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                Path { p in p.addLines(pts) }
                    .stroke(StrandPalette.metricCyan, lineWidth: 1.2)
            }
            if let last = pts.last {
                Path { p in
                    p.move(to: last)
                    p.addLine(to: CGPoint(x: last.x, y: h))
                }
                .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            ForEach(Array(pts.enumerated()), id: \.offset) { i, pt in
                pointMark(at: pt, value: values[i], isLast: i == pts.count - 1, width: size.width)
            }
        }
    }

    private func areaPath(_ pts: [CGPoint], height h: CGFloat) -> Path {
        Path { p in
            p.move(to: CGPoint(x: pts[0].x, y: h))
            pts.forEach { p.addLine(to: $0) }
            p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: h))
            p.closeSubpath()
        }
    }

    @ViewBuilder
    private func pointMark(at pt: CGPoint, value: Double, isLast: Bool, width: CGFloat) -> some View {
        Circle()
            .fill(isLast ? Color.white : Color.black)
            .overlay(Circle().strokeBorder(StrandPalette.metricCyan, lineWidth: isLast ? 0 : 1))
            .frame(width: isLast ? 8 : 7, height: isLast ? 8 : 7)
            .position(pt)
        Text(verbatim: LabBookFormat.value(value, key: markerKey))
            .font(StrandFont.light(10.5))
            .foregroundStyle(isLast ? StrandPalette.textPrimary : StrandPalette.textSecondary)
            .fixedSize()
            .position(x: min(max(pt.x, 10), width - 10), y: pt.y - 12)
    }

    /// Up to four reading dates, the newest in full ink.
    private var dateLabels: some View {
        let n = readings.count
        let idx = n <= 4 ? Array(0..<n) : [0, n / 3, (2 * n) / 3, n - 1]
        return HStack {
            ForEach(Array(idx.enumerated()), id: \.offset) { i, j in
                if i > 0 { Spacer(minLength: 4) }
                Text(verbatim: LabBookFormat.monthYear(readings[j].takenAt))
                    .foregroundStyle(j == n - 1 ? StrandPalette.textPrimary : StrandPalette.textTertiary)
            }
        }
        .font(StrandFont.footnote)
        .lineLimit(1)
    }
}

/// Paired readings as dots (marker on x, the signal's window mean on y), the newest white, with the
/// least-squares line dashed when a correlation exists.
private struct MarkerPairScatter: View {
    let pairs: [WindowedPair]
    let fit: (slope: Double, intercept: Double)?
    let xLabel: String
    let yLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: yLabel)
                .font(StrandFont.light(10.5))
                .foregroundStyle(StrandPalette.textTertiary)
            Canvas { ctx, size in
                guard let xLo = pairs.map(\.markerValue).min(), let xHi = pairs.map(\.markerValue).max(),
                      let yLo = pairs.map(\.wearableMean).min(), let yHi = pairs.map(\.wearableMean).max() else { return }
                let xs = max(xHi - xLo, 0.000_1), ys = max(yHi - yLo, 0.000_1)
                let pad: CGFloat = 10
                func pt(_ x: Double, _ y: Double) -> CGPoint {
                    CGPoint(x: pad + (size.width - pad * 2) * CGFloat((x - xLo) / xs),
                            y: pad + (size.height - pad * 2) * (1 - CGFloat((y - yLo) / ys)))
                }
                var axis = Path()
                axis.move(to: CGPoint(x: 0, y: size.height - 0.5))
                axis.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                axis.move(to: CGPoint(x: 0, y: 0.5))
                axis.addLine(to: CGPoint(x: size.width, y: 0.5))
                ctx.stroke(axis, with: .color(.white.opacity(0.07)), lineWidth: 1)
                if let fit {
                    var line = Path()
                    line.move(to: pt(xLo, fit.intercept + fit.slope * xLo))
                    line.addLine(to: pt(xHi, fit.intercept + fit.slope * xHi))
                    ctx.stroke(line, with: .color(.white.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                let newest = pairs.max(by: { $0.day < $1.day })?.day
                for p in pairs {
                    let c = pt(p.markerValue, p.wearableMean)
                    let isNewest = p.day == newest
                    let r: CGFloat = isNewest ? 4.5 : 3.5
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                             with: .color(isNewest ? .white : StrandPalette.metricCyan))
                }
            }
            HStack {
                Spacer()
                Text(verbatim: xLabel)
                    .font(StrandFont.light(10.5))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Trailing window control (7 / 14 / 30 days)

enum LabWindow: String, CaseIterable, Identifiable {
    case week, fortnight, month
    var id: String { rawValue }
    var label: String {
        switch self {
        case .week:      return String(localized: "7d")
        case .fortnight: return String(localized: "14d")
        case .month:     return String(localized: "30d")
        }
    }
    var days: Int {
        switch self {
        case .week:      return 7
        case .fortnight: return 14
        case .month:     return 30
        }
    }
    var phrase: String {
        switch self {
        case .week:      return String(localized: "7 days")
        case .fortnight: return String(localized: "14 days")
        case .month:     return String(localized: "30 days")
        }
    }
}

// MARK: - Wearable signals offered for correlation + the shared insight language
//
// The pickable wearable metrics + the restrained correlation copy, kept here so the
// Lab Book detail's "Compare with a signal" reads in the exact CompareView idiom
// (strength words, tends-to, association-not-cause) plus the mandatory markers clause.

enum LabBookSignals {
    /// The reading-count floor below which NO conclusion sentence renders (spec default 4).
    static let floor = 4

    /// The wearable metrics offered to pair a marker against. Strap-source keys read through the
    /// Explore freshest-wins path; weight resolves from Apple/Health-Connect/strap as available.
    static let options: [MetricDescriptor] = [
        descriptor("rhr"),
        descriptor("hrv"),
        descriptor("recovery"),
        descriptor("sleep_performance"),
        descriptor("sleep_total_min"),
        descriptor("strain"),
        descriptor("skin_temp"),
        descriptor("steps"),
        descriptor("weight"),
    ].compactMap { $0 }

    private static func descriptor(_ key: String) -> MetricDescriptor? {
        MetricCatalog.all.first { $0.key == key }
    }

    static func signedR(_ r: Double) -> String {
        (r >= 0 ? "+" : "−") + String(format: "%.2f", abs(r))
    }

    static func strengthWord(_ r: Double) -> String {
        switch abs(r) {
        case ..<0.1:  return String(localized: "negligible")
        case ..<0.3:  return String(localized: "weak")
        case ..<0.5:  return String(localized: "moderate")
        case ..<0.7:  return String(localized: "strong")
        default:      return String(localized: "very strong")
        }
    }

    static func directionWord(_ r: Double) -> String {
        if abs(r) < 0.1 { return "" }
        return r >= 0 ? String(localized: "positive") : String(localized: "negative")
    }

    /// "When LDL is higher, HRV tends to be lower." — descriptive, no causal language.
    /// Whole-phrase variants per direction so translators never see a stitched verb fragment.
    static func insightSentence(markerName: String, signalName: String, r: Double) -> String {
        guard abs(r) >= 0.3 else {
            return String(localized: "Over your readings, \(markerName) and \(signalName.lowercased()) move largely independently. No clear relationship.")
        }
        return r < 0
            ? String(localized: "When \(markerName) is higher, \(signalName.lowercased()) tends to be lower.")
            : String(localized: "When \(markerName) is higher, \(signalName.lowercased()) tends to be higher.")
    }

    static func correlationColor(_ r: Double) -> Color {
        let base = r >= 0 ? StrandPalette.statusPositive : StrandPalette.statusCritical
        return base.opacity(0.55 + 0.45 * min(abs(r), 1.0))
    }
}

// MARK: - First-use / linked disclaimer

private struct LabBookDisclaimerView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScreenScaffold(title: "About Lab Book", subtitle: "A private notebook, not a medical service.") {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                bullet(String(localized: "NOOP stores and lines up the numbers you enter yourself. It does not test you, read your results, give medical advice, or diagnose anything."))
                bullet(String(localized: "Anything you see here (including any side-by-side trend) is your own information shown back to you. It's an association, never a cause, and never a medical finding."))
                bullet(String(localized: "NOOP never decides whether a value is \"normal,\" \"high,\" or \"low.\" Any reference range shown is exactly what you typed from your own report."))
                bullet(String(localized: "Your records never leave \(Platform.deviceNounPhrase). There's no account, no cloud, no NOOP server. Because NOOP is an independent app you run yourself (not a healthcare provider), it isn't \"HIPAA-covered,\" and that protection doesn't apply here; the safety comes from the data being local-only and yours."))
                bullet(String(localized: "Always rely on your doctor, pharmacist, or a qualified professional to interpret results and make decisions. If a number worries you, talk to them, not to an app."))
                Button("Got it") { dismiss() }
                    .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                    .padding(.top, 12)
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #else
        .frame(width: 480, height: 560)
        #endif
        .background(NoopVisualStyle.canvas)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(StrandPalette.textTertiary)
                .frame(width: 5, height: 5)
                .padding(.top, 8)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .lineSpacing(2)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
@MainActor
private func labBookPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Lab Book") {
    LabBookView()
        .environmentObject(labBookPreviewRepo())
        .environmentObject(LiveState())
        .frame(width: 920, height: 860)
        .preferredColorScheme(.dark)
}

/// Render targets for `--demo-screen labbook` / `labbook-marker`: seeds a handful of sample readings into
/// the demo store (only when it holds none), then shows the Lab Book or one marker's detail.
struct LabBookDemoHost: View {
    var showsMarker = false
    @EnvironmentObject var repo: Repository
    @State private var rows: [LabMarkerRow] = []
    @State private var ready = false

    var body: some View {
        Group {
            if !ready {
                NoopVisualStyle.canvas
            } else if showsMarker {
                MarkerDetailView(markerKey: "vitamin_d",
                                 readings: rows.filter { $0.markerKey == "vitamin_d" }.sorted { $0.takenAt < $1.takenAt },
                                 onDelete: { _ in })
            } else {
                LabBookView()
            }
        }
        .task {
            await seedIfEmpty()
            ready = true
        }
    }

    private func seedIfEmpty() async {
        guard let store = await repo.storeHandle() else { return }
        var existing: [LabMarkerRow] = []
        for c in LabMarkerCategory.allCases {
            existing += (try? await store.labMarkers(deviceId: repo.deviceId, category: c.rawValue)) ?? []
        }
        if existing.isEmpty {
            let samples: [(String, LabMarkerCategory, String, Double, String, String?, String?)] = [
                ("vitamin_d", .bloodPanel, "2025-03-08", 55, "nmol/L", "GP practice · first test", "75–250"),
                ("vitamin_d", .bloodPanel, "2025-09-20", 85, "nmol/L", "GP practice · 2,000 IU daily since May", "75–250"),
                ("vitamin_d", .bloodPanel, "2026-03-14", 60, "nmol/L", "Winter, no supplement", "75–250"),
                ("vitamin_d", .bloodPanel, "2026-09-12", 95, "nmol/L", "After a summer outdoors", "75–250"),
                ("ferritin", .bloodPanel, "2025-09-20", 64, "µg/L", nil, nil),
                ("ferritin", .bloodPanel, "2026-09-12", 86, "µg/L", nil, nil),
                ("ldl", .bloodPanel, "2025-09-20", 3.1, "mmol/L", nil, nil),
                ("ldl", .bloodPanel, "2026-09-12", 2.7, "mmol/L", nil, nil),
                ("bp_systolic", .bloodPressure, "2026-09-01", 124, "mmHg", nil, nil),
                ("bp_systolic", .bloodPressure, "2026-10-01", 118, "mmHg", nil, nil),
                ("body_fat", .bodyMeasurement, "2026-08-28", 17.9, "%", nil, nil),
                ("body_fat", .bodyMeasurement, "2026-09-28", 16.8, "%", nil, nil),
            ]
            let seeded = samples.map { s in
                LabMarkerRow(id: "demo-\(s.0)-\(s.2)", deviceId: repo.deviceId, markerKey: s.0,
                             category: s.1.rawValue, day: s.2, takenAt: LabBookFormat.noonEpoch(s.2),
                             value: s.3, valueText: nil, unit: s.4, source: "manual", note: s.5,
                             referenceText: s.6)
            }
            try? await store.upsertLabMarkers(seeded)
            existing = seeded
        }
        rows = existing
    }
}
#endif
