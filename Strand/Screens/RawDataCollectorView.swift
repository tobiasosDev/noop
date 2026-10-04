import SwiftUI
import StrandDesign
import WhoopStore

/// iOS/macOS parity twin of Android's 5/MG Raw Data Collector screen.
struct RawDataCollectorView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @StateObject private var store = RawDataSessionStore()

    @State private var exportingId: String?
    @State private var deleteCandidate: RawDataSessionStore.Session?
    @State private var confirmDeleteAll = false
    @State private var exportError: String?
    @State private var deleteError: String?
    @State private var imuCoverage: [String: String] = [:]
    @State private var historicalFrom = Date().addingTimeInterval(-3_600)
    @State private var historicalTo = Date()
    @State private var markerDraft: MarkerDraft?

    private struct MarkerDraft: Identifiable {
        let id = UUID()
        let sessionId: String
        let markerId: String?
        var at: Date
        var type: String
        var text: String
    }

    var body: some View {
        ScreenScaffold(title: nil) {
            NoopScreenHeader("5/MG Raw Data Collector")
                .padding(.bottom, 6)
            Text("Record a bounded 100 Hz motion session and export its complete timeline.")
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
            coverageCard
            controls
            historicalRangeCard
            sessionsSection
        }
        // The screen draws its own v2 header.
        .noopHidesSystemNavBar()
        .task {
            // Restore a session after navigation/process lifecycle changes. The BLE layer rejects a
            // duplicate arm, so this is safe when capture never stopped.
            if let active = store.active, live.bonded { _ = model.ble.startGroundTruthRawCapture(sessionId: active.id) }
            await refreshImuCoverage()
            #if DEBUG
            // Screenshot harness: `--demo-marker` opens the marker editor on the newest session.
            if CommandLine.arguments.contains("--demo-marker"), let first = store.sessions.first {
                editMarker(nil, in: first)
            }
            #endif
        }
        .onChangeCompat(of: live.bonded) { bonded in
            if bonded, let active = store.active { _ = model.ble.startGroundTruthRawCapture(sessionId: active.id) }
        }
        .confirmationDialog("Delete this session?", isPresented: Binding(
            get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let session = deleteCandidate else { return }
                deleteCandidate = nil
                Task { await delete(session) }
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            if let session = deleteCandidate {
                Text("The session \(Self.range(session)) and its captured raw data will be deleted permanently.")
            }
        }
        .confirmationDialog("Delete all sessions?", isPresented: $confirmDeleteAll,
                            titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { Task { await deleteAll() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All \(store.sessions.count) recorded sessions and their captured raw data will be deleted permanently.")
        }
        .alert("Couldn't export session", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "Unknown error") }
        .alert("Couldn't delete session", isPresented: Binding(
            get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: { Text(deleteError ?? "Unknown error") }
        .sheet(item: $markerDraft) { draft in markerSheet(draft) }
    }

    /// The link and capture state as list rows: a state dot carries the band's up/down, the values stay in
    /// secondary ink.
    @ViewBuilder private var coverageCard: some View {
        G13GroupHeader("Capture coverage")
        NoopList {
            RawCoverageRow(title: "Strap", icon: "bluetooth",
                           value: live.connected
                               ? (live.bonded ? String(localized: "connected + paired")
                                              : String(localized: "connected; pairing"))
                               : String(localized: "disconnected"),
                           state: live.connected ? StrandPalette.statusPositive : StrandPalette.statusCritical)
            RawCoverageRow(title: "History sync", icon: "arrows-clockwise",
                           value: live.backfilling
                               ? String(localized: "running (\(live.syncChunksThisSession) chunks)")
                               : String(localized: "idle"))
            if let active = store.active {
                RawCoverageRow(title: "Realtime IMU", icon: "pulse",
                               value: String(localized: "session active since \(Self.time(active.startedAtMs))"),
                               state: StrandPalette.statusWarning)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if store.active != nil {
            NoopButton("Stop session", kind: .destructive,
                       fullWidth: true) { Task { await stop() } }
                .padding(.top, 4)
        } else {
            Button { start() } label: {
                HStack(spacing: 8) {
                    PhIcon("record", size: 17)
                    Text("Start raw-data session")
                }
            }
            .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
            .disabled(!live.bonded)
            .padding(.top, 4)
        }
    }

    @ViewBuilder private var historicalRangeCard: some View {
        G13GroupHeader("Historical export window")
        NoopList {
            G6Footnote("Create a session from synchronized history without starting a live capture. 100 Hz coverage is included wherever it still exists in the rolling buffer.")
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            RawDateRow { DatePicker("From", selection: $historicalFrom) }
            RawDateRow { DatePicker("To", selection: $historicalTo, in: historicalFrom...) }
            Button {
                _ = store.createHistorical(deviceId: model.ble.deviceId,
                                           from: historicalFrom, to: historicalTo)
            } label: {
                NoopRow(title: Text("Add historical session"), icon: "clock-counter-clockwise") {
                    PhIcon("plus", size: 15).foregroundStyle(StrandPalette.textPrimary)
                }
            }
            .buttonStyle(.plain)
            .disabled(historicalTo <= historicalFrom || historicalTo.timeIntervalSince(historicalFrom) > 7 * 86_400)
            .opacity(historicalTo <= historicalFrom || historicalTo.timeIntervalSince(historicalFrom) > 7 * 86_400 ? 0.45 : 1)
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            G13GroupHeader("Recorded sessions", trailing: Text("\(store.sessions.count) saved"))
            if store.sessions.isEmpty {
                NoopCard {
                    HStack(spacing: 12) {
                        NoopIconTile("waveform")
                        Text("No sessions recorded yet.")
                            .font(StrandFont.light(14, relativeTo: .subheadline))
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                ForEach(store.sessions) { session in sessionCard(session) }
                NoopButton("Delete all sessions", kind: .destructive,
                           fullWidth: true) { confirmDeleteAll = true }
                    .disabled(store.active != nil)
            }
        }
    }

    private func sessionCard(_ session: RawDataSessionStore.Session) -> some View {
        let coverageText = imuCoverage[session.id, default: "no complete seconds"]
        return NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Self.range(session))
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    if session.active { NoopTag("Recording", size: 11).fixedSize() }
                }
                Text(session.active ? String(localized: "Export status: recording")
                     : String(localized: "IMU: \(coverageText)"))
                    .font(StrandFont.mono(12))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let exportedAt = session.lastExportedAtMs {
                    Text(String(localized: "Last exported \(Self.time(exportedAt)) · export remains available"))
                        .font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                if !session.active, let endMs = session.endedAtMs {
                    sessionRangeEditor(session, endMs: endMs)
                }
                TextField("Session comment", text: Binding(
                    get: { store.sessions.first(where: { $0.id == session.id })?.comment ?? session.comment },
                    set: { store.setComment($0, sessionId: session.id) }
                ), axis: .vertical)
                    .lineLimit(2...4)
                    .modifier(RawFieldStyle())
                markerList(session)
                sessionActions(session)
            }
        }
    }

    /// The editable analysis range of a stopped session, as two date rows in an inset list.
    private func sessionRangeEditor(_ session: RawDataSessionStore.Session, endMs: Int64) -> some View {
        NoopList {
            RawDateRow {
                DatePicker("From", selection: Binding(
                    get: { Date(timeIntervalSince1970: Double(session.startedAtMs) / 1_000) },
                    set: { store.setRange(sessionId: session.id, from: $0,
                                          to: Date(timeIntervalSince1970: Double(endMs) / 1_000)) }
                ))
            }
            RawDateRow {
                DatePicker("To", selection: Binding(
                    get: { Date(timeIntervalSince1970: Double(endMs) / 1_000) },
                    set: { store.setRange(sessionId: session.id,
                                          from: Date(timeIntervalSince1970: Double(session.startedAtMs) / 1_000), to: $0) }
                ))
            }
        }
    }

    /// The session's markers as rows (tap to edit) under an Add-marker row.
    private func markerList(_ session: RawDataSessionStore.Session) -> some View {
        let markers = session.events.filter { $0.kind == "marker" }.sorted { $0.atMs < $1.atMs }
        return NoopList {
            Button { editMarker(nil, in: session) } label: {
                NoopRow(title: Text("Add marker"), icon: "flag") {
                    PhIcon("plus", size: 15).foregroundStyle(StrandPalette.textPrimary)
                }
            }
            .buttonStyle(.plain)
            ForEach(markers) { marker in
                Button { editMarker(marker, in: session) } label: {
                    NoopRow(title: Text(Self.markerLabel(marker.markerType)) + Text(verbatim: " · \(Self.time(marker.atMs))"),
                            caption: marker.text.flatMap { $0.isEmpty ? nil : Text(verbatim: $0) },
                            chevron: true) { EmptyView() }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Export and Delete side by side when both labels fit, stacked otherwise (German "Session
    /// exportieren" does not fit a half-width pill).
    private func sessionActions(_ session: RawDataSessionStore.Session) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { sessionActionButtons(session) }
            VStack(spacing: 10) { sessionActionButtons(session) }
        }
    }

    @ViewBuilder private func sessionActionButtons(_ session: RawDataSessionStore.Session) -> some View {
        Button {
            Task { await export(session) }
        } label: {
            HStack(spacing: 8) {
                PhIcon("export", size: 16)
                Text(exportingId == session.id ? "Building export…" : "Export session")
                    .lineLimit(1)
            }
        }
        .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
        .disabled(session.active || exportingId != nil)
        NoopButton("Delete session", kind: .destructive,
                   fullWidth: true) { deleteCandidate = session }
            .disabled(session.active || exportingId != nil)
    }

    private func markerSheet(_ initial: MarkerDraft) -> some View {
        Group {
            if let binding = Binding($markerDraft) {
                let session = store.sessions.first(where: { $0.id == binding.wrappedValue.sessionId })
                G13SheetScaffold(header: NoopSheetHeader(initial.markerId == nil ? "Add marker" : "Edit marker",
                                                         doneTitle: "Save",
                                                         onCancel: { markerDraft = nil },
                                                         onDone: { saveMarker(binding.wrappedValue) }),
                                 macSize: CGSize(width: 460, height: 520)) {
                    markerTimeCard(binding, session: session)
                    G13GroupHeader("Marker type")
                    SegmentedPillControl(RawDataSessionStore.markerTypes, selection: binding.type,
                                         fillsAvailableWidth: true) { Self.markerLabelString($0) }
                    G13GroupHeader("Marker note")
                    TextField("Marker note", text: binding.text, axis: .vertical)
                        .lineLimit(2...4)
                        .modifier(RawFieldStyle())
                    if let markerId = binding.wrappedValue.markerId {
                        NoopButton("Delete marker", kind: .destructive, fullWidth: true) {
                            store.deleteMarker(sessionId: binding.wrappedValue.sessionId, markerId: markerId)
                            markerDraft = nil
                        }
                        .padding(.top, 12)
                    }
                }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: false)
        #endif
    }

    /// The marker's time in the dot-matrix face, the session clock it is measured against, and the
    /// −10 s / now / +10 s nudges.
    private func markerTimeCard(_ binding: Binding<MarkerDraft>, session: RawDataSessionStore.Session?) -> some View {
        NoopCard {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let current = Self.markerCurrentTime(session: session, now: timeline.date)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Marker: \(binding.wrappedValue.at.formatted(date: .omitted, time: .standard))")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Current time: \(current.formatted(date: .omitted, time: .standard))")
                        .font(StrandFont.light(13, relativeTo: .subheadline))
                        .foregroundStyle(StrandPalette.textTertiary)
                    HStack(spacing: 8) {
                        Button { binding.wrappedValue.at.addTimeInterval(-10) } label: { Text(verbatim: "−10 s") }
                            .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                        Button("0") {
                            binding.wrappedValue.at = Self.markerCurrentTime(session: session, now: Date())
                        }
                        .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                        Button { binding.wrappedValue.at.addTimeInterval(10) } label: { Text(verbatim: "+10 s") }
                            .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private func editMarker(_ marker: RawDataSessionStore.Event?, in session: RawDataSessionStore.Session) {
        let currentMs = session.endedAtMs ?? Int64(Date().timeIntervalSince1970 * 1_000)
        markerDraft = MarkerDraft(sessionId: session.id, markerId: marker?.markerId,
                                  at: Date(timeIntervalSince1970: Double(marker?.atMs ?? currentMs) / 1_000),
                                  type: marker?.markerType ?? "moment", text: marker?.text ?? "")
    }

    private func saveMarker(_ draft: MarkerDraft) {
        if let markerId = draft.markerId {
            store.updateMarker(sessionId: draft.sessionId, markerId: markerId,
                               at: draft.at, type: draft.type, text: draft.text)
        } else {
            store.addMarker(sessionId: draft.sessionId, at: draft.at, type: draft.type, text: draft.text)
        }
        markerDraft = nil
    }

    private func start() {
        guard let session = store.start(deviceId: model.ble.deviceId) else { return }
        guard model.ble.startGroundTruthRawCapture(sessionId: session.id) else {
            store.stop(); store.removeMetadata(session.id); return
        }
    }

    private func stop() async {
        await model.ble.stopGroundTruthRawCapture()
        store.stop()
        await refreshImuCoverage()
    }

    private func export(_ session: RawDataSessionStore.Session) async {
        guard let end = session.endedAtMs else { return }
        exportingId = session.id
        let bounds = Self.fullSecondBounds(fromMs: session.startedAtMs, toMs: end)
        let from = bounds?.from ?? 1, to = bounds?.to ?? 0
        let segments = bounds.map {
            ImuSessionFileStore.shared.exportSegments(session.id, from: $0.from, to: $0.to)
        } ?? []
        let history = bounds == nil ? Data("stream,unix_s,v1,v2,v3,v4\n".utf8)
            : await model.ble.groundTruthHistoryCSV(from: from, to: to)
        let sensorAvailable = !segments.isEmpty || history.split(separator: 0x0A).count > 1
        var entries = store.exportEntries(for: session, sensorAvailable: sensorAvailable)
        entries.append(.init(name: "history-sensors.csv", data: history))
        // A live capture can only produce its first complete one-second frame after startup.
        // Historical windows must still cover the exact requested start.
        let firstImuTs = segments.map(\.startTs).min().flatMap { $0 <= from + 1 ? $0 : nil }
        let coverageFrom = session.capturedStartedAtMs == nil ? from : max(from, firstImuTs ?? from)
        let imuComplete = Self.covers(segments, from: coverageFrom, to: to)
        let coverage: [String: Any] = [
            "requested_start_ts": from, "requested_end_ts": to,
            "required_start_ts": coverageFrom,
            "startup_seconds": max(0, coverageFrom - from),
            "complete": imuComplete,
            "segments": segments.map { ["file": $0.name, "start_ts": $0.startTs, "end_ts": $0.endTs,
                                         "sample_count": $0.sampleCount] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: coverage, options: [.prettyPrinted, .sortedKeys]) {
            entries.append(.init(name: "imu-coverage.json", data: data))
        }
        for segment in segments { entries.append(.init(name: "imu/\(segment.name)", data: segment.data)) }
        let result = await FileExport.exportBundle(entries: entries,
                                                    suggestedName: "noop-5mg-raw-\(session.id).zip")
        if result == nil { exportError = "The export file could not be created or shared." }
        else {
            store.markExported(session.id)
        }
        exportingId = nil
    }

    private func delete(_ session: RawDataSessionStore.Session) async {
        guard session.endedAtMs != nil else { return }
        guard store.removeMetadata(session.id) else {
            deleteError = "The captured data could not be deleted. The session was kept so you can retry."
            return
        }
        imuCoverage[session.id] = nil
    }

    private func deleteAll() async {
        for session in store.sessions where !session.active { await delete(session) }
    }

    private func refreshImuCoverage() async {
        for session in store.sessions {
            guard let end = session.endedAtMs,
                  let bounds = Self.fullSecondBounds(fromMs: session.startedAtMs, toMs: end) else { continue }
            let stats = ImuSessionFileStore.shared.stats(session.id, from: bounds.from, to: bounds.to)
            let first = stats.firstTs.flatMap { $0 <= Int64(bounds.from + 1) ? Int($0) : nil }
            let from = session.capturedStartedAtMs == nil ? bounds.from : max(bounds.from, first ?? bounds.from)
            let expected = max(0, bounds.to - from + 1)
            let bytes = ByteCountFormatter.string(fromByteCount: stats.bytes, countStyle: .file)
            let readiness = expected > 0 && stats.coveredSeconds == expected ? "ready" : "incomplete"
            imuCoverage[session.id] = "\(stats.coveredSeconds)/\(expected) s · \(bytes) · \(readiness)"
        }
    }

    private static func time(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1_000)
            .formatted(Date.FormatStyle(date: .omitted, time: .shortened)
                .locale(AppClock.formattingLocale))   // #1821
    }

    static func fullSecondBounds(fromMs: Int64, toMs: Int64) -> (from: Int, to: Int)? {
        let from = Int((fromMs + 999) / 1_000), to = Int(toMs / 1_000) - 1
        return from <= to ? (from, to) : nil
    }

    static func markerCurrentTime(session: RawDataSessionStore.Session?, now: Date) -> Date {
        session?.endedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1_000) } ?? now
    }

    private static func range(_ session: RawDataSessionStore.Session) -> String {
        let start = Date(timeIntervalSince1970: Double(session.startedAtMs) / 1_000)
        let date = start.formatted(date: .numeric, time: .omitted)
        let end = session.endedAtMs.map(time) ?? "…"
        return "\(date) · \(time(session.startedAtMs))–\(end)"
    }

    private static func markerLabel(_ type: String?) -> LocalizedStringKey {
        switch type {
        case "start": "Start"
        case "end": "End"
        case "issue": "Issue"
        default: "Moment"
        }
    }

    /// The marker-type name as a plain string, for the segmented control's labels.
    private static func markerLabelString(_ type: String) -> String {
        switch type {
        case "start": String(localized: "Start")
        case "end": String(localized: "End")
        case "issue": String(localized: "Issue")
        default: String(localized: "Moment")
        }
    }

    private static func covers(_ chunks: [ImuSessionFileStore.ExportSegment], from: Int, to: Int) -> Bool {
        var cursor = from
        for chunk in chunks.sorted(by: { $0.startTs < $1.startTs }) {
            let start = chunk.startTs, end = chunk.endTs
            if chunk.sampleCount < (end - start + 1) * ImuSessionFileStore.sampleRate { continue }
            if start > cursor { return false }
            if end >= cursor { cursor = end + 1 }
            if cursor > to { return true }
        }
        return cursor > to
    }
}

/// A capture-coverage row: icon tile, label, an optional state dot, and the value in secondary ink.
private struct RawCoverageRow: View {
    let title: LocalizedStringKey
    let icon: String
    let value: String
    var state: Color? = nil

    var body: some View {
        NoopRow(title: Text(title), icon: icon) {
            HStack(spacing: 7) {
                if let state {
                    Circle().fill(state).frame(width: 7, height: 7).accessibilityHidden(true)
                }
                Text(verbatim: value)
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A date-picker row inside a v2 list: the label in Book 15, the system picker tinted to ink.
private struct RawDateRow<Picker: View>: View {
    @ViewBuilder var picker: () -> Picker

    var body: some View {
        picker()
            .font(StrandFont.book(15, relativeTo: .body))
            .foregroundStyle(StrandPalette.textPrimary)
            .tint(StrandPalette.textPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .frame(minHeight: 52)
    }
}

/// The v2 text field: Book 15 ink on the inset surface with a hairline edge.
private struct RawFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(StrandFont.book(15, relativeTo: .body))
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(NoopVisualStyle.inset))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(NoopVisualStyle.border, lineWidth: 1))
    }
}
