import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

private struct WorkoutRecoveryTrendPoint: Identifiable, Equatable {
    let startTs: Int
    let result: HeartRateRecovery.Result
    var id: Int { startTs }
}

// MARK: - Workouts
//
// The activity log (v2): the add row, sport chips and the range control, one effort-glow hero for the
// window's typical session Effort, the totals, the active-calorie heatmap, the per-sport breakdown and
// zone split, the HR-recovery trend, and the session log. Neutral cards stay grey-black; the only colour
// is the hero and the effort accent on the leading bar.

struct WorkoutsView: View {
    @EnvironmentObject var repo: Repository
    /// PERF (chart-invalidation): `AppModel` publishes `bpm` at ~1 Hz (AppModel.swift:202) via
    /// `@Published`, and `@EnvironmentObject` subscribes to the WHOLE object's `objectWillChange` —
    /// regardless of which properties `body` actually reads. Holding `model: AppModel` here re-ran this
    /// screen's entire ~1900-line body (chart + grids + sorting) every tick. `hrMax` and `analyzeRecent()`
    /// are the only two things this screen needs, and both live on sub-objects (`ProfileStore`,
    /// `IntelligenceEngine`) injected separately at the app root (StrandApp.swift) — neither publishes at
    /// live-tick frequency. The one genuinely `AppModel`-dependent piece ("Start Workout" / active-session
    /// state, #459) is isolated into `WorkoutStartControl`, mirroring `HealthView`'s live-observing-leaf
    /// pattern (HealthView.swift:17-22, 44-46), so a tick re-renders only that small leaf.
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var intelligence: IntelligenceEngine

    // Exercise-distance preference (#1913). Unset follows the original combined preference.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(
            system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
            override: distanceSystemRaw)
    }

    // Effort display scale (#268) — drives the effort hero's read-out. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// All loaded sessions, newest first. Seedable for previews. #797: this holds only the rows inside the
    /// currently-LOADED window (`loadedWindowDays`), not the entire history. A 1700+-workout import made
    /// the eager all-rows read + sort fire on every `refreshSeq` bump (first paint AND every backfill
    /// slice). First paint loads a bounded window; selecting a wider range than is loaded lazily pages in
    /// the rest (`expandWindow`).
    @State private var allRows: [WorkoutRow]
    @State private var loaded: Bool
    @State private var seededInitialRange = false
    /// Current (the most recent sessions) or Archived (everything older). A view split only: archived rows
    /// stay in the database and are one tap away.
    @State private var scope: Scope = .current

    @State private var range: Range = .all
    /// #797: how many trailing days of workouts are currently LOADED into `allRows`. First paint loads
    /// `Self.firstPaintWindowDays`; picking "All" (or a range wider than this) pages the full history in on
    /// demand. nil means the full history is loaded (the user expanded to "All"). Preview rows are treated
    /// as fully loaded (nil) so the preview path is unchanged.
    @State private var loadedWindowDays: Int?
    private let usesPreviewRows: Bool

    /// Daily active-calorie totals (day "yyyy-MM-dd" → kcal) for the 13-week heatmap, loaded alongside the
    /// rows. Empty until loaded / when there's no daily-calorie data (the heatmap then hides itself).
    @State private var dailyKcal: [String: Double] = [:]

    /// Local `yyyy-MM-dd` formatter for the heatmap's day keys + "today" anchor (matches the stored keys).
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private func todayDayString() -> String { Self.dayFormatter.string(from: Date()) }

    /// #797: trailing-day window the FIRST workouts read is bounded to, so first paint never sorts a
    /// multi-thousand-workout history. Comfortably covers the default range (the tightest range with ≥2
    /// sessions, almost always ≤90 days); a wider pick pages the rest in via `expandWindow`. 400 days
    /// covers the 1Y range plus headroom.
    static let firstPaintWindowDays = 400

    // iPhone (.compact) can't fit the labelled "Add workout" button beside the 5-segment range pill —
    // the button got crushed into a tall sliver (#234/#339). Stack them there; iPad/Mac keep one row.
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    /// The add/edit sheet target: `.some(nil)` = add a new workout, `.some(row)` = edit `row`,
    /// `nil` = sheet closed. Wrapped in Identifiable so `.sheet(item:)` can drive presentation.
    @State private var sheet: WorkoutSheetTarget?

    /// The read-only detail screen target — a tapped session. Drives a `.sheet(item:)` separate from
    /// the add/edit sheet so a primary tap (detail) and the ••• menu (edit) never collide. (#410)
    @State private var detail: WorkoutDetailTarget?

    /// A transient one-line note shown after a manual save / relabel for a sport that already has a
    /// solid/building ActivityCost entry — "Sessions like this usually …" (#439). Auto-clears.
    @State private var postLogNote: String?

    /// #516: eligible workouts in the visible 7/30/90-day window, calculated from recorded HR. Wider
    /// workout ranges intentionally keep this trend capped at 90 days so opening a deep history never
    /// launches hundreds of raw-HR reads.
    @State private var recoveryTrend: [WorkoutRecoveryTrendPoint] = []

    // MARK: - Filters + selection (#64)

    /// Filter beyond the time range: a displayed-sport key (nil = all), an origin class (nil = all), and
    /// a free-text search over the displayed sport. Pure `WorkoutFilter` applies them after the window cut.
    @State private var sportFilter: String?
    @State private var sourceFilter: WorkoutSource?
    @State private var searchText = ""

    /// Multi-select + merge mode. `selectionMode` toggles the leading checkmarks + the toolbar strip;
    /// `selected` holds the natural keys ("startTs|sport") of the chosen rows. Only MANUAL / DETECTED rows
    /// are selectable (imported history is read-only and can never be merged or bulk-deleted).
    @State private var selectionMode = false
    @State private var selected: Set<String> = []
    /// When every selected row is a bare detected bout, the merge has no sport to keep — this drives a
    /// small confirm sheet asking the user to name the merged session.
    @State private var mergeSportPrompt: MergeSportTarget?
    /// The sport search field under the header, opened from the header's search circle.
    @State private var showsSearch = false
    @FocusState private var searchFocused: Bool
    /// The log shows its first `sessionPreviewCount` rows until "Show all" is tapped.
    @State private var showsAllSessions = false

    /// The selection key for a row (its natural key). Stable across a reload so the checkmarks persist.
    private func selectionKey(_ row: WorkoutRow) -> String { "\(row.startTs)|\(row.sport)" }

    /// Wraps the pending merge inputs so a `.sheet(item:)` can present the "name the merged session" prompt
    /// (used only when every selected row is detected, so there's no sport to inherit).
    private struct MergeSportTarget: Identifiable {
        let rows: [WorkoutRow]
        let id = UUID()
    }

    /// Wraps the optional edited row so `.sheet(item:)` can present add (editing == nil) or edit.
    private struct WorkoutSheetTarget: Identifiable {
        let editing: WorkoutRow?
        /// True for "Duplicate as manual": the form pre-fills FROM a read-only row, but the save is a pure
        /// ADD. The pre-fill row is not a stored manual row, so it must never travel on as `replacing:` —
        /// it carries the ORIGINAL's natural key while claiming source "manual", and the repository would
        /// take that as an edit and retire the row it was copied from. `Repository.saveManualWorkout`
        /// documents that an imported row is never passed as `replacing`; this is what makes that true.
        var isCopy = false
        let id = UUID()
    }

    /// Wraps a tapped row so `.sheet(item:)` can present its detail screen.
    private struct WorkoutDetailTarget: Identifiable {
        let row: WorkoutRow
        let id = UUID()
    }

    init(previewRows: [WorkoutRow]? = nil) {
        _allRows = State(initialValue: previewRows ?? [])
        _loaded = State(initialValue: previewRows != nil)
        // Preview-seeded rows are treated as the full history (nil window) so the preview path never pages.
        _loadedWindowDays = State(initialValue: previewRows != nil ? nil : Self.firstPaintWindowDays)
        usesPreviewRows = previewRows != nil
    }

    var body: some View {
        // Compute the windowed (unscoped) rows ONCE per body evaluation and thread them into both the
        // session list below AND the HR-recovery trend `.task(id:)` further down this modifier chain.
        // SwiftUI re-runs `body` on hover/animation/1Hz HR ticks; `sessions(for:)` was independently
        // re-derived by `windowRows` here AND by `recoveryTrendRows` (via `recoveryTrendInputKey`, read on
        // every body pass as the `.task(id:)` argument) — the same unscoped filter run twice per pass.
        let resolved = effectiveRange
        let unscopedRows = sessions(for: resolved)
        let trendRows = recoveryTrendRows(from: unscopedRows)
        return ScreenScaffold(title: nil,
                       onRefresh: { await repo.refresh() },
                       // PERF: the column ends in the full "All sessions" log. On a large imported history the
                       // eager VStack built every section + the whole list up-front; the LazyVStack path (which
                       // is byte-identical layout) builds the off-screen sections/rows on demand instead.
                       lazy: Self.lazyColumn) {
            NoopScreenHeader("Workouts") { headerControls }
                .padding(.bottom, 6)
            titleBlock
            if allRows.isEmpty {
                addWorkoutRow
                emptyState
            } else {
                // Compute the per-sport groups ONCE per body evaluation, then thread them into every
                // section — same idea as `unscopedRows` above, applied to the rest of the fan-out
                // (rows → sportGroups → …) that used to rebuild several times per render.
                // Current / Archived applies to what the LIST and its summaries show. `unscopedRows`
                // itself stays unscoped so the HR-recovery trend and the auto-widen probe keep seeing the
                // whole window.
                let windowRows = Self.scopedRows(unscopedRows, scope: scope)
                let groups = sportGroups(from: windowRows)
                let zonesSummary = WorkoutZones.summary(from: windowRows)

                addWorkoutRow
                filterBar
                rangeBar(rows: windowRows, effectiveRange: resolved)
                if let postLogNote { postLogBanner(postLogNote) }
                effortHero(rows: windowRows, effectiveRange: resolved)
                summarySection(rows: windowRows, effectiveRange: resolved, groups: groups)
                heatmapSection()
                breakdownSection(groups: groups)
                if let z = zonesSummary {
                    zonesSection(z, totalSessions: windowRows.count)
                }
                recoveryTrendSection
                sessionsSection(rows: windowRows)
            }
        }
        .noopHidesSystemNavBar()
        .task(id: repo.refreshSeq) {
            guard !usesPreviewRows else { return }
            // #797: read only the currently-loaded window (bounded on first paint), not the whole history.
            let r = await repo.workoutRows(days: loadedWindowDays ?? 4000)
            allRows = r
            let wasLoaded = loaded
            loaded = true
            if !wasLoaded {
                range = defaultRange(for: r)
                seededInitialRange = true
            }
            // 13-week active-calorie heatmap: pull ~100 days of daily metrics and map day → active kcal.
            // Loaded AFTER `loaded`/range are set so the secondary heatmap never delays the list's first
            // paint — the card is hidden until this populates, then appears in place.
            let toDay = todayDayString()
            let fromDate = Calendar.current.date(byAdding: .day, value: -100, to: Date()) ?? Date()
            let metrics = await repo.dailyMetrics(fromDay: Self.dayFormatter.string(from: fromDate), toDay: toDay)
            dailyKcal = Dictionary(metrics.compactMap { m in m.activeKcalEst.map { (m.day, $0) } },
                                   uniquingKeysWith: max)
        }
        .onAppear {
            // Preview-seeded rows skip `.task`; still choose a range that has data.
            if loaded && !seededInitialRange {
                range = defaultRange(for: allRows)
                seededInitialRange = true
            }
        }
        // #797: when the user picks a range wider than the bounded first-paint window (typically "All"),
        // page the full history in. A pick that fits the loaded window is a no-op. Also covers the
        // auto-widen: if the selected window is sparse and `effectiveRange` falls back to `.all`, the
        // full read is needed to show the older sessions.
        .onChange(of: range) { newRange in
            Task { await expandWindowIfNeeded(for: newRange == .all ? .all : effectiveRange) }
        }
        .task(id: recoveryTrendInputKey(rows: trendRows)) {
            await loadRecoveryTrend(rows: trendRows)
        }
        .sheet(item: $sheet) { target in
            ManualWorkoutSheet(editing: target.editing) { row, replacing in
                Task {
                    // A copy pre-fills the form but replaces nothing — see `WorkoutSheetTarget.isCopy`.
                    await repo.saveManualWorkout(row, replacing: target.isCopy ? nil : replacing)
                    // #598: rescore the just-added workout from the strap's HR for its window NOW, so its
                    // average / peak HR, strain and calories appear immediately (from your own strap data)
                    // instead of waiting up to 15 minutes for the next analyze tick. No-ops when the strap
                    // had no HR for that window, and never overrides a value you typed yourself.
                    await intelligence.analyzeRecent()
                    await reload()
                    // Post-log note (#439): if this sport now has a solid/building recovery-cost
                    // entry, surface its personal-pattern sentence as a transient caption.
                    await showPostLogNote(forSport: WorkoutSource.displaySport(row.sport))
                }
            }
        }
        .sheet(item: $detail) { target in
            // These shared screens aren't hosted in a per-screen NavigationStack, so the read-only
            // detail rides its own NavigationStack inside the sheet (the iOS grabber and the detail's
            // own back circle give the dismiss affordances). Mirrors HealthView presenting MetricDetailView.
            NavigationStack {
                WorkoutDetailView(row: target.row)
                    .environmentObject(repo)
            }
            #if os(iOS)
            .noopSheetPresentation(largeFirst: true)
            #else
            .frame(width: 620, height: 720)
            #endif
        }
        // #459 / PERF: the "Add workout" row, its active-session cover and the sport picker all live in
        // `WorkoutStartControl`, which owns `AppModel` itself — see the comment on this screen's
        // `profile`/`intelligence` properties above for why `model` can't live here.
        // #64: name the merged session when every selected row is a bare detected bout (there's no sport
        // to inherit). Reuses the "Start a workout" named-sport picker.
        .workoutSelectionCover(item: $mergeSportPrompt) { target in
            StartWorkoutSheet(title: String(localized: "Name the merged session"),
                              subtitle: String(localized: "These sessions have no sport label yet. Pick one for the merged session."),
                              actionVerb: String(localized: "Merge")) { name in
                performMerge(target.rows, sport: name)
            }
        }
    }

    /// The lazy column (see `body`). The DEBUG screenshot harness turns it off when it anchors the scroll
    /// mid-screen, where a lazy stack has not realised the rows it is asked to show yet.
    private static var lazyColumn: Bool {
        #if DEBUG
        return !CommandLine.arguments.contains("--demo-anchor")
        #else
        return true
        #endif
    }

    // MARK: - Header, title, empty state

    /// Search toggle and the overflow menu (source filter, Current / Archived, select mode).
    private var headerControls: some View {
        HStack(spacing: 10) {
            NoopCircleButton(showsSearch ? "x" : "magnifying-glass",
                             accessibilityLabel: showsSearch ? "Close search" : "Search sport") {
                withAnimation(StrandMotion.interactive) {
                    showsSearch.toggle()
                    if !showsSearch { searchText = "" }
                }
            }
            Menu {
                Picker(selection: $sourceFilter) {
                    Text("All sources").tag(WorkoutSource?.none)
                    ForEach(Self.sourceFilterOptions, id: \.self) { opt in
                        Text(Self.sourceFilterLabel(opt)).tag(WorkoutSource?.some(opt))
                    }
                } label: {
                    Label("Filter by source", systemImage: "line.3.horizontal.decrease")
                }
                .pickerStyle(.menu)
                Picker(selection: $scope) {
                    ForEach(Scope.allCases) { s in Text(s.label).tag(s) }
                } label: {
                    Label("Scope", systemImage: "archivebox")
                }
                .pickerStyle(.menu)
                if allRows.contains(where: WorkoutMerge.isMergeable) {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selectionMode.toggle()
                            if !selectionMode { selected.removeAll() }
                        }
                    } label: {
                        Label(selectionMode ? "Finish selecting" : "Select sessions to merge or delete",
                              systemImage: "checkmark.circle")
                    }
                }
                if filter.isActive {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            sportFilter = nil; sourceFilter = nil; searchText = ""
                        }
                    } label: { Label("Clear filters", systemImage: "xmark.circle") }
                }
            } label: {
                NoopCircleIcon("dots-three")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("More"))
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Workouts")
                .font(StrandFont.title1)
                .tracking(-0.56)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Every session, threaded together.")
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(.bottom, 6)
    }

    /// No sessions yet (or still loading): what will fill this screen, and the add row above it.
    private var emptyState: some View {
        Group {
            if loaded {
                NoopInsightRow("No workouts yet. They come from your WHOOP and Apple Health history. Import in Data Sources to bring them in, or add one you tracked elsewhere.", icon: "barbell")
            } else {
                NoopInsightRow("Loading your sessions…", icon: "barbell")
            }
        }
        .ltCard()
    }

    /// Present the read-only detail for a tapped row. The primary affordance; the ••• menu stays the
    /// secondary path for edit/relabel/delete.
    private func openDetail(_ row: WorkoutRow) { detail = WorkoutDetailTarget(row: row) }

    /// Re-read every source after a mutation so the screen reflects the new state immediately.
    /// Keeps the user's current range — only the initial load picks a default — and the auto-widen
    /// (`effectiveRange`) still covers a now-empty window.
    private func reload() async {
        allRows = await repo.workoutRows(days: loadedWindowDays ?? 4000)
    }

    // MARK: - Heart-rate recovery trend (#516)

    /// Apply the screen's 90-day cap to the already-`sessions(for:)`-filtered `unscopedRows` `body`
    /// computes once. PERF: this used to re-derive `sessions(for: effectiveRange)` from scratch (the SAME
    /// unscoped filter `body`'s `windowRows` already ran), so a body pass — routinely once per second on
    /// a ~1 Hz HR tick before the `WorkoutStartControl` isolation above — filtered `allRows` twice.
    /// Reusing the caller's rows removes the second pass; taking them as a parameter (rather than a
    /// computed property reading `effectiveRange` again) is what makes the reuse possible.
    private func recoveryTrendRows(from unscopedRows: [WorkoutRow]) -> [WorkoutRow] {
        guard let last = latestTs else { return [] }
        let cutoff = last - 90 * 86_400
        return unscopedRows.filter { $0.startTs >= cutoff }.sorted { $0.startTs < $1.startTs }
    }

    /// Stable task identity: changing the range/filter/rows or HRmax cancels and rebuilds the trend.
    private func recoveryTrendInputKey(rows: [WorkoutRow]) -> String {
        "\(repo.refreshSeq)|\(profile.hrMax)|" + rows.map { "\($0.startTs):\($0.endTs)" }.joined(separator: ",")
    }

    private var recoveryTrendCaption: String {
        if let days = effectiveRange.days, days <= 90 { return effectiveRange.caption }
        return String(localized: "last 90 days")
    }

    private func loadRecoveryTrend(rows: [WorkoutRow]) async {
        guard !usesPreviewRows else { recoveryTrend = []; return }
        var built: [WorkoutRecoveryTrendPoint] = []
        for row in rows {
            if Task.isCancelled { return }
            if let result = await repo.workoutHeartRateRecovery(
                from: row.startTs, to: row.endTs, maxHR: Double(profile.hrMax),
                source: row.source) {
                built.append(WorkoutRecoveryTrendPoint(startTs: row.startTs, result: result))
            }
        }
        guard !Task.isCancelled else { return }
        recoveryTrend = built
    }

    /// #797: page the FULL workout history in when the user selects a range wider than the bounded
    /// first-paint window. Idempotent: once expanded (`loadedWindowDays == nil`) it never re-reads here.
    /// Only a pick of `.all` (or a future range exceeding the loaded window) triggers the one-time full
    /// read, so the common 7D/30D/90D/1Y interactions stay on the already-loaded bounded set.
    private func expandWindowIfNeeded(for picked: Range) async {
        guard !usesPreviewRows, loadedWindowDays != nil else { return }
        // A bounded range that fits inside what's already loaded needs no wider read.
        if let pickedDays = picked.days, pickedDays <= (loadedWindowDays ?? 0) { return }
        loadedWindowDays = nil
        allRows = await repo.workoutRows(days: 4000)
    }

    // MARK: - Post-log activity-cost note (#439)

    /// After a manual save / relabel, look up whether `sport` has a solid/building ActivityCost entry
    /// (n ≥ minSessions) and, if so, show its plain-English sentence as a transient caption that
    /// auto-clears. Copy is "usually"/"personal pattern" framed (the engine's own wording) — never a
    /// law. Computes off the freshly reloaded sessions + the merged daily Charge.
    private func showPostLogNote(forSport sport: String) async {
        let costs = InsightsView.computeActivityCosts(workouts: allRows, days: repo.days)
        guard let match = costs.first(where: { $0.sport == sport }) else {
            await MainActor.run { postLogNote = nil }
            return
        }
        let sentence = match.sentence()
        await MainActor.run { withAnimation(.easeOut(duration: 0.2)) { postLogNote = sentence } }
        // Auto-dismiss after a few seconds (transient caption, not a permanent card).
        try? await Task.sleep(nanoseconds: 7_000_000_000)
        await MainActor.run {
            if postLogNote == sentence { withAnimation(.easeOut(duration: 0.2)) { postLogNote = nil } }
        }
    }

    /// The transient "personal pattern" caption — an insight line on a neutral card.
    private func postLogBanner(_ text: String) -> some View {
        NoopInsightRow(text: Text(text), icon: "chart-line-up")
            .ltCard()
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(text)
    }

    // MARK: - Row actions (edit · relabel · dismiss · delete)

    private func editWorkout(_ row: WorkoutRow, isCopy: Bool = false) {
        sheet = WorkoutSheetTarget(editing: row, isCopy: isCopy)
    }

    private func relabel(_ row: WorkoutRow, to sport: String) {
        Task {
            await repo.relabelDetected(row, sport: sport)
            await reload()
            await showPostLogNote(forSport: WorkoutSource.displaySport(sport))
        }
    }

    private func dismiss(_ row: WorkoutRow) {
        Task { await repo.dismissDetected(row); await reload() }
    }

    private func delete(_ row: WorkoutRow) {
        // #524: also drop any on-device GPS route stored under this session's natural key, so deleting a
        // workout doesn't leave its route orphaned in the RouteStore side-store.
        RouteStore.remove(startTs: row.startTs, sport: row.sport)
        Task { await repo.deleteWorkout(row); await reload() }
    }

    /// Common sports offered when re-labelling a detected bout (keeps the menu short and honest —
    /// the user can fine-tune via Edit afterwards).
    private static let relabelSports = ["Running", "Walking", "Cycling", "Strength Training",
                                        "Swimming", "Rowing", "Yoga", "HIIT",
                                        "CrossFit", "Hiking", "Tennis"]

    // MARK: - Range control

    /// The time range (`.seg`) and, under it, how many sessions it holds — with the Current / Archived
    /// split beside the caption. The split is always shown, including when everything still fits in
    /// Current: a control that appeared only once a wearer crossed ten sessions would shift the screen
    /// the first time it did, and an empty Archived answers "where did my older workouts go" plainly.
    private func rangeBar(rows: [WorkoutRow], effectiveRange: Range) -> some View {
        let fellBack = effectiveRange != range
        let caption = rangeCaption(rows: rows, effectiveRange: effectiveRange, fellBack: fellBack)
        return VStack(alignment: .leading, spacing: 10) {
            SegmentedPillControl(
                Range.allCases,
                selection: $range,
                fillsAvailableWidth: true
            ) { $0.label }
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .center, spacing: 8) {
                Text(caption)
                    .font(StrandFont.footnote)
                    .foregroundStyle(fellBack ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                    .lineLimit(2)
                    .accessibilityLabel(caption)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    ForEach(Scope.allCases) { s in
                        Button {
                            withAnimation(StrandMotion.interactive) { scope = s }
                        } label: {
                            NoopChip(s.label, isOn: scope == s)
                        }
                        .buttonStyle(LTPressStyle())
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Scope"))
            }
        }
    }

    /// #64: the sport filter as chips (All + the most-used sports, the rest behind a "More" chip), the
    /// active source filter as a removable chip, and the sport search when the header's search is open.
    /// The predicate is the pure `WorkoutFilter`; these controls only drive its state.
    private var filterBar: some View {
        let sports = availableSports
        let pinned = Array(sports.prefix(3))
        return VStack(alignment: .leading, spacing: 10) {
            if showsSearch {
                WorkoutSearchField(query: $searchText, isFocused: $searchFocused,
                                   prompt: String(localized: "Search sport"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button { sportFilter = nil } label: { NoopChip("All", isOn: sportFilter == nil) }
                        .buttonStyle(LTPressStyle())
                    ForEach(pinned, id: \.self) { s in
                        Button { sportFilter = (sportFilter == s ? nil : s) } label: {
                            NoopChip(verbatim: SportName.display(s), isOn: sportFilter == s)
                        }
                        .buttonStyle(LTPressStyle())
                    }
                    if sports.count > pinned.count {
                        let other = sportFilter.flatMap { pinned.contains($0) ? nil : $0 }
                        Menu {
                            ForEach(sports.dropFirst(pinned.count), id: \.self) { s in
                                Button(SportName.display(s)) { sportFilter = s }
                            }
                        } label: {
                            NoopChip(verbatim: other.map(SportName.display) ?? String(localized: "More"), isOn: other != nil,
                                     icon: "caret-down")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel(String(localized: "Filter by sport"))
                    }
                    if let source = sourceFilter {
                        Button { sourceFilter = nil } label: {
                            NoopChip(verbatim: Self.sourceFilterLabel(source), isOn: true, icon: "x")
                        }
                        .buttonStyle(LTPressStyle())
                        .accessibilityLabel(String(localized: "Clear filters"))
                    }
                }
            }
        }
    }

    /// The origin classes offered in the Source filter (imported + on-device), in a stable menu order.
    private static let sourceFilterOptions: [WorkoutSource] =
        [.whoop, .apple, .detected, .manual, .lifting, .activityFile]

    /// The Source-filter menu label for an origin class (matches the row source labels).
    private static func sourceFilterLabel(_ c: WorkoutSource) -> String {
        switch c {
        case .whoop:        return String(localized: "Whoop")
        case .apple:        return String(localized: "Apple")
        case .detected:     return String(localized: "Detected")
        case .manual:       return String(localized: "Manual")
        case .lifting:      return String(localized: "Lifting")
        case .activityFile: return String(localized: "File")
        }
    }

    /// The "Add workout" row: a live start or a manual log of a past session. Present on the populated
    /// screen and the empty state so a user with no imports can still log a session.
    /// #459 / PERF: the row is `WorkoutStartControl`, a leaf that owns `AppModel` itself so this screen
    /// doesn't have to — see the comment on `profile`/`intelligence` above.
    private var addWorkoutRow: some View {
        WorkoutStartControl(onLogManually: { sheet = WorkoutSheetTarget(editing: nil) })
    }

    /// The latest session start (anchors every window — windows are relative to the
    /// most recent session, not "now", so an old log still resolves).
    private var latestTs: Int? { allRows.map(\.startTs).max() }

    /// The active filter (#64), composed once. Sport / source / search all apply AFTER the window cut,
    /// so the effort hero, tiles, breakdown, zones and list all read one filtered set.
    private var filter: WorkoutFilter {
        WorkoutFilter(sport: sportFilter, sourceClass: sourceFilter, search: searchText)
    }

    /// Sessions inside a given range, RELATIVE TO THE LATEST session, then passed through the active
    /// filter. `.all` = all. The window anchor (`latestTs`) is the newest of ALL loaded rows so the
    /// window doesn't shift when a filter narrows the set.
    /// Which slice of the history the list is showing.
    ///
    /// A VIEW split, never a delete. Archived rows stay in the database untouched and are one tap away,
    /// which is the whole reason the request for "keep the last 10 and auto-delete the rest" is answered
    /// this way instead: NOOP has no server and no cloud copy, so pruning real training history would be
    /// irreversible, and hiding it costs nothing.
    enum Scope: String, CaseIterable, Identifiable {
        case current, archived
        var id: String { rawValue }
        /// `LocalizedStringKey` rather than `String`, because this is only ever handed to `Text`, so the
        /// resolution belongs to the view environment.
        ///
        /// The sibling enums on other screens return `String(localized:)` instead, which is equally correct
        /// for a value that has to be a String. What is NOT correct, and is what this property shipped as
        /// first, is a BARE literal returned as a String: it renders in English forever, and the i18n gate
        /// does not catch it, because a literal in that position is not somewhere the scanner looks. The
        /// gate flagged the Picker's "Scope" key and said nothing about these two, which are the words
        /// actually printed on the tabs.
        var label: LocalizedStringKey { self == .current ? "Current" : "Archived" }
    }

    /// How many of the most recent sessions "Current" holds.
    static let currentScopeCount = 10

    /// Split rows into the most recent `currentCount` and everything older.
    ///
    /// Pure and order-preserving: membership is decided by ranking on `startTs`, but the rows come back in
    /// the order they arrived, so the caller's sort still decides what the screen shows. Ranking rather
    /// than comparing against a cutoff timestamp is what makes ties safe: two sessions that start in the
    /// same second cannot both sneak past a threshold and hand "Current" an eleventh row.
    ///
    /// Applied AFTER the range and sport filters, so each tab means "the 10 most recent of what you are
    /// currently looking at" rather than silently showing an empty Current when a filter excludes the
    /// newest sessions.
    nonisolated static func scopedRows(_ rows: [WorkoutRow], scope: Scope,
                                       currentCount: Int = currentScopeCount) -> [WorkoutRow] {
        guard rows.count > currentCount else { return scope == .current ? rows : [] }
        let key: (WorkoutRow) -> String = { "\($0.startTs)|\($0.sport)" }
        let newest = Set(rows.sorted { $0.startTs > $1.startTs }.prefix(currentCount).map(key))
        return rows.filter { scope == .current ? newest.contains(key($0)) : !newest.contains(key($0)) }
    }

    private func sessions(for r: Range) -> [WorkoutRow] {
        let windowed: [WorkoutRow]
        if let days = r.days {
            guard let last = latestTs else { return [] }
            let cutoff = last - days * 86_400
            windowed = allRows.filter { $0.startTs >= cutoff }
        } else {
            windowed = allRows
        }
        // Deliberately NOT scoped. This feeds the HR-recovery trend (a 90-day analysis) and the
        // auto-widen probe as well as the list, and cutting those to the ten most recent sessions would
        // quietly change what they measure. The Current/Archived split is applied to the LIST rows only.
        return filter.apply(windowed)
    }

    /// The set of displayed-sport names present across ALL loaded rows, for the sport-filter menu.
    /// Ordered by frequency (desc) so the common sports sit at the top.
    private var availableSports: [String] {
        var counts: [String: Int] = [:]
        for r in allRows { counts[WorkoutSource.displaySport(r.sport), default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    /// The range actually shown: the SELECTED range when it holds ≥1 session, else
    /// the smallest LARGER range that does — so switching ranges stays visibly
    /// distinct and only an empty window widens.
    private var effectiveRange: Range {
        guard !allRows.isEmpty else { return range }
        for r in range.widening where !sessions(for: r).isEmpty { return r }
        return .all
    }

    /// "N sessions · <range>" near the control, flagging an auto-widen. Appends "· filtered" (#64) when a
    /// sport/source/search filter is narrowing the list. Takes the already-resolved range / windowed rows
    /// so `body` computes them once.
    private func rangeCaption(rows: [WorkoutRow], effectiveRange: Range, fellBack: Bool) -> String {
        guard loaded, !allRows.isEmpty else { return "—" }
        let n = rows.count
        let suffix = filter.isActive ? String(localized: " · filtered") : ""
        if fellBack {
            return (n == 1
                ? String(localized: "1 session · sparse, widened to \(effectiveRange.caption)")
                : String(localized: "\(n) sessions · sparse, widened to \(effectiveRange.caption)")) + suffix
        }
        return (n == 1
            ? String(localized: "1 session · \(effectiveRange.caption)")
            : String(localized: "\(n) sessions · \(effectiveRange.caption)")) + suffix
    }

    /// Pick the tightest range that still holds ≥2 sessions; otherwise show All.
    private func defaultRange(for source: [WorkoutRow]) -> Range {
        guard let last = source.map(\.startTs).max() else { return .all }
        for r in Range.allCases where r.days != nil {
            let cutoff = last - (r.days ?? 0) * 86_400
            if source.filter({ $0.startTs >= cutoff }).count >= 2 { return r }
        }
        return .all
    }

    // MARK: - Effort hero

    /// The effort-glow hero for the windowed range: the typical session Effort in the dot-matrix face
    /// with its intensity word, the per-session Effort across the window against that average, and the
    /// peak session, the change against the previous window and the session count.
    @ViewBuilder
    private func effortHero(rows: [WorkoutRow], effectiveRange: Range) -> some View {
        let scored = rows.filter { $0.strain != nil }.sorted { $0.startTs < $1.startTs }
        let strains = scored.compactMap(\.strain)
        let avgStrain = strains.isEmpty ? nil : strains.reduce(0, +) / Double(strains.count)
        let scaleMax: Double = effortScale == .whoop ? 21 : 100
        NoopHeroCard(glow: .strain, padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    // The badge keeps one line; the overline gives way (German runs both long).
                    NoopIconBadge(verbatim: String(localized: "Effort this \(effectiveRange.heroWord)"), icon: "fire")
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Text("Typical effort")
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .textCase(.uppercase)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    Text(verbatim: avgStrain.map { UnitFormatter.effortDisplay($0, scale: effortScale) } ?? "—")
                        .font(StrandFont.dot(96))
                        .tracking(StrandFont.dotTracking(96))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    VStack(alignment: .leading, spacing: 8) {
                        if let avgStrain {
                            NoopTag(verbatim: StrainGauge.stateLabel(
                                forFraction: UnitFormatter.effortValue(avgStrain, scale: effortScale) / scaleMax))
                        }
                        Text(avgStrain == nil ? String(localized: "No data")
                                              : String(localized: "per session · \(String(localized: "of \(UnitFormatter.effortScaleMax(effortScale))"))"))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .padding(.bottom, 10)
                }
                .padding(.top, 26)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(avgStrain.map { String(localized: "Typical effort \(UnitFormatter.effortDisplay($0, scale: effortScale))") }
                                    ?? String(localized: "Typical effort, no data"))
                if strains.count >= 2, let avgStrain {
                    let lo = 0.0, hi = max(strains.max() ?? 1, avgStrain) * 1.25
                    let span = max(hi - lo, 1)
                    LTHeroTrace(points: strains.enumerated().map { i, v in
                                    CGPoint(x: Double(i) / Double(strains.count - 1), y: (v - lo) / span)
                                },
                                showsCursor: false, showsEndDot: true, showsFloor: false,
                                reference: CGFloat((avgStrain - lo) / span))
                        .frame(height: 78)
                        .padding(.top, 20)
                    HStack {
                        Text(verbatim: shortDate(scored.first?.startTs))
                        Spacer()
                        Text(verbatim: shortDate(scored.last?.startTs)).foregroundStyle(StrandPalette.textPrimary)
                    }
                    .overlay { Text(verbatim: shortDate(scored[scored.count / 2].startTs)) }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
                }
                effortHeroStats(scored: scored, effectiveRange: effectiveRange, avgStrain: avgStrain)
                    .padding(.top, 20)
            }
            .padding(.bottom, 2)
        }
    }

    /// Peak session · change against the previous window · sessions in the window.
    private func effortHeroStats(scored: [WorkoutRow], effectiveRange: Range, avgStrain: Double?) -> some View {
        let peak = scored.max { ($0.strain ?? 0) < ($1.strain ?? 0) }
        let previous = previousWindowAverage(effectiveRange)
        return HStack(alignment: .top, spacing: 0) {
            heroStat(peak?.strain.map { UnitFormatter.effortDisplay($0, scale: effortScale) } ?? "—",
                     label: peak.map { String(localized: "Peak · \(shortDate($0.startTs))") } ?? String(localized: "Peak"))
            if let previous, let avgStrain {
                let delta = UnitFormatter.effortValue(avgStrain, scale: effortScale)
                    - UnitFormatter.effortValue(previous, scale: effortScale)
                heroStat(String(format: effortScale == .whoop ? "%+.1f" : "%+.0f", delta),
                         label: String(localized: "vs previous \(effectiveRange.heroWord)"))
            }
            heroStat("\(scored.count)", label: String(localized: "Scored sessions"))
        }
    }

    private func heroStat(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: value)
                .font(StrandFont.value(21))
                .tracking(-0.4)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(verbatim: label)
                .font(StrandFont.light(10.5))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The typical session Effort in the equal-length window just before the current one (same filter),
    /// or nil for "All" / when that window holds no scored session or is not loaded.
    private func previousWindowAverage(_ r: Range) -> Double? {
        guard let days = r.days, let last = latestTs else { return nil }
        let end = last - days * 86_400, start = end - days * 86_400
        if let loadedDays = loadedWindowDays, days * 2 > loadedDays { return nil }
        let prev = filter.apply(allRows.filter { $0.startTs >= start && $0.startTs < end }).compactMap(\.strain)
        guard !prev.isEmpty else { return nil }
        return prev.reduce(0, +) / Double(prev.count)
    }

    /// "10 Sep" for a session start.
    private func shortDate(_ ts: Int?) -> String {
        guard let ts else { return "" }
        return Date(timeIntervalSince1970: TimeInterval(ts)).formatted(.dateTime.day().month(.abbreviated))
    }

    // MARK: - Totals

    private func summarySection(rows: [WorkoutRow], effectiveRange: Range, groups: [SportGroup]) -> some View {
        let totalCount = rows.count
        let totalTimeS = rows.compactMap(\.durationS).reduce(0, +)
        let totalKcal = rows.compactMap(\.energyKcal).reduce(0, +)
        // Only POSITIVE distances count as "has distance" (a strap-detected sport with no GPS/manual
        // distance is nil, and an explicit 0 is not a real distance) — matches `distanceLabel`'s `m > 0`
        // guard on the per-workout rows. When nothing in the window has distance, the tile shows "–"
        // instead of a misleading "0.0 km covered" (#reddit: rugby read as data loss).
        let withDistance = rows.filter { ($0.distanceM ?? 0) > 0 }
        let totalKmRaw = withDistance.compactMap(\.distanceM).reduce(0, +) / 1000.0
        let distanceSports = Array(Set(withDistance.map { SportName.display($0.sport) })).sorted()
        let perSession = totalCount > 0 ? Double(totalCount) : 1
        return Group {
            NoopSectionTitle("Totals") { Text(verbatim: sentenceCase(effectiveRange.caption)) }
            Grid(horizontalSpacing: NoopMetrics.gap, verticalSpacing: NoopMetrics.gap) {
                GridRow {
                    totalTile("Total workouts", icon: "list-checks", value: Text(verbatim: "\(totalCount)"),
                              caption: sentenceCase(effectiveRange.caption))
                    totalTile("Total time", icon: "clock", value: durationText(totalTimeS),
                              caption: totalCount > 0
                                ? String(localized: "\(Int((totalTimeS / perSession / 60).rounded())) min per session") : "—")
                }
                GridRow {
                    totalTile("Total calories", icon: "fire",
                              value: unitText(grouped(totalKcal), unit: "kcal"),
                              caption: totalCount > 0 ? String(localized: "\(grouped(totalKcal / perSession)) per session") : "—")
                    totalTile("Total distance", icon: "path",
                              value: withDistance.isEmpty ? Text(verbatim: "–")
                                : distanceText(UnitFormatter.distanceFromKilometers(totalKmRaw, system: distanceUnitSystem)),
                              caption: distanceSports.isEmpty ? String(localized: "No distance recorded")
                                : distanceSports.prefix(4).joined(separator: ", "))
                }
            }
            if let top = groups.first {
                mostActiveCard(top, rows: rows)
            }
        }
    }

    private func totalTile(_ title: LocalizedStringKey, icon: String, value: Text, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The kit's card header keeps a spacer for a trailing caption; a half-width tile has none, so
            // the title gets the whole row.
            HStack(spacing: 8) {
                PhIcon(icon, size: 16).opacity(0.9)
                Text(title)
                    .font(StrandFont.book(14, relativeTo: .subheadline))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(StrandPalette.textPrimary)
            value
                .font(StrandFont.light(26, relativeTo: .title2))
                .tracking(-0.5)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 12)
            Text(verbatim: caption)
                .font(StrandFont.light(10.5))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 3)
        }
        .ltCard()
        .accessibilityElement(children: .combine)
    }

    /// A figure with its unit set small beside it ("14,820 kcal").
    private func unitText(_ value: String, unit: String) -> Text {
        Text(verbatim: value) + Text(verbatim: " " + unit).font(StrandFont.light(11)).foregroundColor(StrandPalette.textSecondary)
    }

    /// "24 h 10 m" with small units.
    private func durationText(_ seconds: Double) -> Text {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        let small: (String) -> Text = {
            Text(verbatim: $0).font(StrandFont.light(11)).foregroundColor(StrandPalette.textSecondary)
        }
        if h > 0 { return Text(verbatim: "\(h)") + small("h") + Text(verbatim: " \(m)") + small("m") }
        return Text(verbatim: "\(m)") + small("m")
    }

    /// "186 km" split so the unit sits small.
    private func distanceText(_ formatted: String) -> Text {
        let parts = formatted.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return Text(verbatim: formatted) }
        return unitText(parts[0], unit: parts[1])
    }

    /// The most-used sport: its glyph, name, sessions and time (and distance when it has any).
    private func mostActiveCard(_ g: SportGroup, rows: [WorkoutRow]) -> some View {
        let km = rows.filter { $0.sport == g.sport }.compactMap(\.distanceM).filter { $0 > 0 }.reduce(0, +) / 1000
        var detail = durationLabel(g.totalTimeS)
        if km > 0 { detail += " · " + UnitFormatter.distanceFromKilometers(km, system: distanceUnitSystem) }
        return HStack(spacing: 14) {
            WorkoutTypeIcon(workoutType: g.sport, size: 20)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NoopVisualStyle.raised))
            VStack(alignment: .leading, spacing: 2) {
                Text("Most active").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                Text(verbatim: SportName.display(g.sport))
                    .font(StrandFont.book(17, relativeTo: .headline))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(g.count == 1 ? String(localized: "1 session") : String(localized: "\(g.count) sessions"))
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: detail).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .noopPanel()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Active-calorie heatmap (last 13 weeks)
    //
    // A contribution-style grid of daily active calories: columns = weeks (Monday-first), rows = weekdays,
    // cell shade = that day's burn vs the window max. The bucketing is the pure cross-platform
    // `ActivityHeatmap` (parity with the Kotlin twin); this is just the SwiftUI renderer. Hidden entirely
    // when there's no daily-calorie data yet.
    @ViewBuilder
    private func heatmapSection() -> some View {
        let grid = ActivityHeatmap.build(values: dailyKcal, today: todayDayString())
        if !grid.isEmpty {
            NoopSectionTitle("Active calories", captionKey: "Last 13 weeks")
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    HStack(alignment: .bottom, spacing: 10) {
                        Text(verbatim: "\(grid.streak)")
                            .font(StrandFont.dot(44))
                            .tracking(StrandFont.dotTracking(44))
                            .foregroundStyle(StrandPalette.textPrimary)
                        VStack(alignment: .leading, spacing: 2) {
                            // Reuses the Settings streak copy ("day(s) in a row").
                            Text(grid.streak == 1 ? "day in a row" : "days in a row")
                                .font(StrandFont.book(15, relativeTo: .body))
                                .foregroundStyle(StrandPalette.textPrimary)
                            if grid.streak > 0, let since = streakStart(grid.streak) {
                                Text("Active every day since \(since)")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        .padding(.bottom, 3)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(verbatim: "\(grouped(grid.total)) kcal")
                        Text("in 13 weeks")
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                }
                .accessibilityElement(children: .combine)
                Canvas { ctx, size in drawHeatmap(ctx, size: size, grid: grid, today: todayDayString()) }
                    .aspectRatio(13.0 / 7.9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Text("Active-calorie heatmap, last 13 weeks"))
                HStack(spacing: 4) {
                    Spacer()
                    Text("Less").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    ForEach(0..<5, id: \.self) { lvl in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(heatColor(lvl))
                            .frame(width: 11, height: 11)
                    }
                    Text("More").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
                .accessibilityHidden(true)
            }
            .ltCard()
        }
    }

    /// "25 Sep" — the first day of a streak that runs through today.
    private func streakStart(_ streak: Int) -> String? {
        guard let d = Calendar.current.date(byAdding: .day, value: -(streak - 1), to: Date()) else { return nil }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    /// Renders the heatmap into the Canvas: a left gutter of weekday labels (Mon/Wed/Fri/Sun), the cells,
    /// and a bottom row of month labels (drawn where the month changes). Labels use the LOCALIZED calendar
    /// symbols so they translate for free and carry no hardcoded literals.
    private func drawHeatmap(_ ctx: GraphicsContext, size: CGSize, grid: ActivityHeatmap.Grid, today: String) {
        let cols = grid.columns.count
        guard cols > 0 else { return }
        let gap: CGFloat = 3.4
        let leftInset: CGFloat = 20   // weekday gutter
        let bottomInset: CGFloat = 18 // month row
        let cell = min((size.width - leftInset - gap * CGFloat(cols - 1)) / CGFloat(cols),
                       (size.height - bottomInset - gap * 6) / 7)
        guard cell > 0 else { return }
        let labelFont = StrandFont.light(9.5)
        let labelColor = StrandPalette.textTertiary

        // Resolve + colour via the Canvas shading (macOS 13 compatible — `Text.foregroundStyle`
        // returning Text is macOS 14+, but a resolved text's `shading` is available here).
        func label(_ s: String) -> GraphicsContext.ResolvedText {
            var t = ctx.resolve(Text(s).font(labelFont))
            t.shading = .color(labelColor)
            return t
        }
        // Weekday gutter: Mon/Wed/Fri/Sun. `veryShortWeekdaySymbols` is Sunday-first, so row r (Mon-first)
        // maps to symbol (r + 1) % 7.
        let wd = Calendar.current.veryShortWeekdaySymbols
        if wd.count == 7 {
            for r in stride(from: 0, to: 7, by: 2) {
                let y = CGFloat(r) * (cell + gap) + cell / 2
                ctx.draw(label(wd[(r + 1) % 7]), at: CGPoint(x: 0, y: y), anchor: .leading)
            }
        }

        // Month row under the grid: label a column when its month differs from the previous one.
        let months = Calendar.current.shortMonthSymbols
        let gridBottom = 7 * cell + 6 * gap
        var lastMonth = -1
        for c in 0..<cols {
            guard let day = grid.columns[c].first(where: { $0.day != nil })?.day,
                  let m = Int(day.dropFirst(5).prefix(2)), m >= 1, m <= 12 else { continue }
            if m != lastMonth {
                lastMonth = m
                let x = leftInset + CGFloat(c) * (cell + gap)
                ctx.draw(label(months[m - 1]), at: CGPoint(x: x, y: gridBottom + 6), anchor: .topLeading)
            }
        }

        // Cells; today's cell gets an outline so "where am I" reads at a glance (mirrors #222).
        for c in 0..<cols {
            let col = grid.columns[c]
            for r in 0..<7 {
                let rect = CGRect(x: leftInset + CGFloat(c) * (cell + gap),
                                  y: CGFloat(r) * (cell + gap),
                                  width: cell, height: cell)
                let path = Path(roundedRect: rect, cornerRadius: cell * 0.26)
                ctx.fill(path, with: .color(heatColor(col[r].level)))
                if col[r].day == today {
                    ctx.stroke(path, with: .color(StrandPalette.textPrimary), lineWidth: 1.2)
                }
            }
        }
    }

    /// Level (0 = no data, 1...4 by intensity) → the effort-blue ramp.
    private func heatColor(_ level: Int) -> Color {
        switch level {
        case 0: return NoopVisualStyle.raised
        case 1: return StrandPalette.effortColor.opacity(0.32)
        case 2: return StrandPalette.effortColor.opacity(0.62)
        case 3: return StrandPalette.effortColor.opacity(0.9)
        default: return StrandPalette.metricCyan
        }
    }

    // MARK: - Activity breakdown

    /// One bar per sport, scaled to the busiest one's time; the top sport carries the effort gradient.
    @ViewBuilder
    private func breakdownSection(groups: [SportGroup]) -> some View {
        NoopSectionTitle("Activity breakdown", captionKey: "By sport")
        let maxTime = max(groups.map(\.totalTimeS).max() ?? 1, 1)
        VStack(spacing: 14) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                HStack(spacing: 12) {
                    Text(verbatim: SportName.display(g.sport))
                        .font(StrandFont.light(13, relativeTo: .subheadline))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .frame(width: 78, alignment: .leading)
                    // The leading sport keeps the kit's effort gradient; the rest are neutral.
                    if i == 0 {
                        NoopTrack(fraction: g.totalTimeS / maxTime, height: 12)
                    } else {
                        NoopTrack(fraction: g.totalTimeS / maxTime, height: 12,
                                  fill: [NoopVisualStyle.quaternaryText, NoopVisualStyle.quaternaryText])
                    }
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(verbatim: durationLabel(g.totalTimeS))
                            .font(StrandFont.book(13, relativeTo: .subheadline))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(verbatim: breakdownCaption(g))
                            .font(StrandFont.light(10.5))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 64, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .ltCard()
    }

    /// "12 sessions · 3,400 kcal" — the count, and the calories when the sport has any.
    private func breakdownCaption(_ g: SportGroup) -> String {
        let count = g.count == 1 ? String(localized: "1 session") : String(localized: "\(g.count) sessions")
        return g.totalKcal > 0 ? count + " · " + String(localized: "\(grouped(g.totalKcal)) kcal") : count
    }

    // MARK: - HR zones (imported per-workout zone split)

    @ViewBuilder
    private func zonesSection(_ z: WorkoutZones.Summary, totalSessions: Int) -> some View {
        NoopSectionTitle("HR zones", captionKey: "Share of workout time")
        let maxMin = max(z.minutes.max() ?? 1, 0.001)
        let total = max(z.totalMinutes, 0.001)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<5, id: \.self) { i in
                HStack(spacing: 12) {
                    ZoneLabelColumn(zone: i + 1)
                    NoopTrack(fraction: z.minutes[i] / maxMin, height: 12,
                              fill: [NoopVisualStyle.zoneFill(i + 1), NoopVisualStyle.zoneFill(i + 1)])
                    Text(verbatim: "\(Int((z.minutes[i] / total * 100).rounded())) %")
                        .font(StrandFont.book(13, relativeTo: .subheadline))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: 44, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text(verbatim: durationLabel(z.minutes[i] * 60)))
            }
            NoopInsightRow(text: Text(zoneInsight(z, totalSessions: totalSessions)))
                .padding(.top, 4)
        }
        .ltCard()
    }

    /// What the bars add up to, and where they come from.
    private func zoneInsight(_ z: WorkoutZones.Summary, totalSessions: Int) -> String {
        let total = max(z.totalMinutes, 0.001)
        let easy = Int(((z.minutes[0] + z.minutes[1]) / total * 100).rounded())
        let sessions = totalSessions == 1
            ? String(localized: "\(z.sessionsWithZones) of 1 session")
            : String(localized: "\(z.sessionsWithZones) of \(totalSessions) sessions")
        return String(localized: "\(easy)% of your zone time sits in zones 1–2.") + " "
            + String(localized: "Share of imported zone time, duration-weighted across sessions (approximate).")
            + " " + sessions + "."
    }

    // MARK: - Heart-rate recovery trend (#516)

    @ViewBuilder private var recoveryTrendSection: some View {
        if !recoveryTrend.isEmpty {
            NoopSectionTitle("Recovery trend") {
                Text(verbatim: recoveryTrend.count == 1
                    ? String(localized: "1 workout")
                    : String(localized: "\(recoveryTrend.count) workouts"))
            }
            VStack(alignment: .leading, spacing: 12) {
                NoopCardHeader("Heart-rate recovery", icon: "heartbeat") { Text(verbatim: recoveryTrendCaption) }
                WorkoutRecoveryTrendChart(points: recoveryTrend)
                    .frame(height: NoopMetrics.chartHeight)
                HStack(spacing: 16) {
                    recoveryLegend("1 min", color: StrandPalette.metricRose)
                    recoveryLegend("2 min", color: StrandPalette.metricCyan)
                    recoveryLegend("5 min", color: StrandPalette.metricPurple)
                }
                Text("Each line shows how many beats per minute your heart rate changed after exercise. Only high-intensity workouts with recorded post-workout heart rate are included.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .ltCard()
        }
    }

    private func recoveryLegend(_ label: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    // MARK: - All sessions

    /// How many rows the log shows before "Show all".
    private static let sessionPreviewCount = 10

    @ViewBuilder
    private func sessionsSection(rows: [WorkoutRow]) -> some View {
        NoopSectionTitle("All sessions") {
            if rows.contains(where: WorkoutMerge.isMergeable) {
                selectPill
            } else {
                Text(verbatim: String(localized: "\(rows.count) total"))
            }
        }
        if selectionMode { selectionToolbar(rows: rows) }
        let shown = showsAllSessions ? rows : Array(rows.prefix(Self.sessionPreviewCount))
        NoopList {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, row in
                sessionRow(row)
            }
        }
        if rows.count > shown.count {
            Button {
                withAnimation(StrandMotion.interactive) { showsAllSessions = true }
            } label: {
                Text("Show all \(rows.count) sessions")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// #64: the Select / Done toggle in the log's title row. Only shown when at least one row is
    /// selectable (manual / detected); a pure-imported list has nothing to merge or bulk-delete.
    private var selectPill: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                selectionMode.toggle()
                if !selectionMode { selected.removeAll() }
            }
        } label: {
            NoopChip(selectionMode ? "Done" : "Select", isOn: selectionMode)
        }
        .buttonStyle(LTPressStyle())
        .accessibilityLabel(selectionMode
            ? String(localized: "Finish selecting")
            : String(localized: "Select sessions to merge or delete"))
    }

    /// #64: the Merge / Delete / Cancel strip shown above the log in selection mode. Merge needs 2+
    /// eligible rows; Delete needs 1+.
    private func selectionToolbar(rows: [WorkoutRow]) -> some View {
        let chosen = rows.filter { selected.contains(selectionKey($0)) }
        let canMerge = WorkoutMerge.canMerge(chosen)
        return HStack(spacing: 10) {
            LTActionButton("Merge (\(chosen.count))", icon: "git-merge", kind: .primary, height: 40, fontSize: 13,
                           fullWidth: false) {
                beginMerge(chosen)
            }
            .disabled(!canMerge)
            LTActionButton("Delete (\(chosen.count))", icon: "trash", height: 40, fontSize: 13, fullWidth: false) {
                let toDelete = chosen
                selectionMode = false; selected.removeAll()
                Task { await repo.bulkDeleteWorkouts(toDelete); await reload() }
            }
            .disabled(chosen.isEmpty)
            Spacer(minLength: 0)
            Button(String(localized: "Cancel")) {
                withAnimation(.easeOut(duration: 0.15)) { selectionMode = false; selected.removeAll() }
            }
            .buttonStyle(.plain)
            .font(StrandFont.light(14))
            .foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .contain)
    }

    /// Start a merge: if the chosen rows carry a real sport, merge straight away; if every one is a bare
    /// detected bout, prompt the user to name the merged session first.
    private func beginMerge(_ chosen: [WorkoutRow]) {
        guard WorkoutMerge.canMerge(chosen) else { return }
        if WorkoutMerge.resolvedSport(chosen) == nil {
            mergeSportPrompt = MergeSportTarget(rows: chosen)
        } else {
            performMerge(chosen, sport: nil)
        }
    }

    /// Commit a merge through the repository (manual-row path), then rescore + reload. Leaves selection
    /// mode. Imported rows can never reach here (canMerge gates on manual/detected).
    private func performMerge(_ chosen: [WorkoutRow], sport: String?) {
        guard let merged = WorkoutMerge.merge(chosen, sport: sport) else { return }
        selectionMode = false; selected.removeAll(); mergeSportPrompt = nil
        Task {
            await repo.mergeWorkouts(chosen, into: merged)
            await intelligence.analyzeRecent()
            await reload()
        }
    }

    /// One log row (`.li`): the sport glyph tile, the sport with "Fri 2 Oct · 52 min · 8.4 km · Whoop"
    /// under it, the session Effort, and the ••• actions. A tap opens the detail; in selection mode it
    /// toggles the row instead (imported rows show a lock and cannot be selected).
    private func sessionRow(_ row: WorkoutRow) -> some View {
        let selectable = WorkoutMerge.isMergeable(row)
        let isSelected = selected.contains(selectionKey(row))
        return Button {
            if selectionMode {
                guard selectable else { return }
                withAnimation(.easeOut(duration: 0.12)) { toggleSelection(row) }
            } else {
                openDetail(row)
            }
        } label: {
            HStack(spacing: 14) {
                if selectionMode {
                    selectionGlyph(selectable: selectable, isSelected: isSelected)
                }
                WorkoutTypeIcon(workoutType: row.sport, size: 17)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: NoopVisualStyle.tileRadius, style: .continuous)
                        .fill(NoopVisualStyle.raised))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: SportName.display(row.sport))
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    // Date · duration · distance · source: wraps rather than cutting the source off.
                    Text(verbatim: rowSubtitle(row))
                        .font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: Self.effortCellLabel(strain: row.strain, scale: effortScale))
                        .font(StrandFont.value(17))
                        .foregroundStyle(row.strain != nil ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    Text("Effort")
                        .font(StrandFont.book(10))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                // Reserve the ••• width inside the label; the interactive Menu is overlaid on top (below)
                // so it captures its own taps instead of being swallowed by the row button (#318).
                if !selectionMode { Color.clear.frame(width: 28) }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(LTPressStyle())
        // Visible per-row ••• actions (#1/#318), layered at the trailing edge over its reserved column.
        .overlay(alignment: .trailing) {
            if !selectionMode {
                rowActionsMenu(row).padding(.trailing, 12)
            }
        }
        .contextMenu { if !selectionMode { rowMenu(row) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel(row, selectable: selectable, isSelected: isSelected))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(selectionMode
            ? (selectable ? String(localized: "Double-tap to select") : String(localized: "Imported history can't be merged"))
            : String(localized: "Opens workout detail"))
    }

    /// The leading selection glyph: a filled/hollow check for a mergeable row, or a lock for imported
    /// history (which can never be merged or bulk-deleted).
    @ViewBuilder
    private func selectionGlyph(selectable: Bool, isSelected: Bool) -> some View {
        if selectable {
            PhIcon(isSelected ? "check-circle" : "circle", weight: isSelected ? .fill : .light, size: 22)
                .foregroundStyle(isSelected ? StrandPalette.textPrimary : StrandPalette.textTertiary)
        } else {
            PhIcon("lock-simple", size: 16)
                .foregroundStyle(StrandPalette.textTertiary.opacity(0.6))
                .frame(width: 22)
        }
    }

    /// Toggle one row's selection (mergeable rows only).
    private func toggleSelection(_ row: WorkoutRow) {
        let key = selectionKey(row)
        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
    }

    /// The row's second line: "Fri 2 Oct · 52 min · 8.4 km · Whoop", nil fields omitted. Calories and
    /// average HR live in the detail.
    private func rowSubtitle(_ row: WorkoutRow) -> String {
        var parts: [String] = [rowDateLabel(row.startTs)]
        if let d = durationLabelOrNil(row.durationS) { parts.append(d) }
        if let d = row.distanceM, d > 0 { parts.append(distanceLabel(row.distanceM)) }
        parts.append(Self.sourceFilterLabel(WorkoutSource.classify(row.source)))
        // Breaks only after a "·": each part stays whole ("6.4 km" never splits) and a wrapped line ends
        // on the dot instead of starting with one.
        return parts.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: "\u{00A0}· ")
    }

    /// A full-sentence a11y label for a row (date, time, duration, calories, distance, HR, Effort).
    private func rowAccessibilityLabel(_ row: WorkoutRow, selectable: Bool, isSelected: Bool) -> String {
        var parts: [String] = [dateLabel(row.startTs), timeRangeLabel(row.startTs, row.endTs)]
        if let d = durationLabelOrNil(row.durationS) { parts.append(d) }
        if let k = row.energyKcal, k > 0 { parts.append(String(localized: "\(grouped(k)) kcal")) }
        if let d = row.distanceM, d > 0 { parts.append(distanceLabel(row.distanceM)) }
        if let hr = row.avgHr { parts.append(String(localized: "\(hr) bpm")) }
        let effort = row.strain != nil
            ? String(localized: "Effort \(Self.effortCellLabel(strain: row.strain, scale: effortScale))")
            : String(localized: "no Effort recorded")
        let base = String(localized: "\(SportName.display(row.sport)), \(parts.joined(separator: " · ")), \(effort)")
        guard selectionMode else { return base }
        if !selectable { return String(localized: "\(base). Imported, can't be merged.") }
        return isSelected ? String(localized: "\(base). Selected.") : String(localized: "\(base). Not selected.")
    }

    /// The same actions as `rowMenu`, surfaced as a tappable "•••" so they're discoverable on both macOS
    /// (no right-click needed) and iOS (no long-press needed).
    private func rowActionsMenu(_ row: WorkoutRow) -> some View {
        Menu {
            rowMenu(row)
        } label: {
            PhIcon("dots-three", size: 18)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 28, height: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Actions"))
    }

    /// Right-click actions per row. A grandfathered DETECTED bout can be re-labelled as a real manual
    /// session or dismissed with its legacy marker retained. A MANUAL session can be edited or deleted.
    /// Imported WHOOP / Apple rows are read-only (we never rewrite imported history).
    @ViewBuilder
    private func rowMenu(_ row: WorkoutRow) -> some View {
        switch WorkoutSource.classify(row.source) {
        case .detected:
            Menu("Re-label as") {
                ForEach(Self.relabelSports, id: \.self) { sport in
                    Button(SportName.display(sport)) { relabel(row, to: sport) }
                }
            }
            Button("Edit details…") { editWorkout(row) }
            Divider()
            Button("Dismiss (not a workout)", role: .destructive) { dismiss(row) }
        case .manual:
            Button("Edit…") { editWorkout(row) }
            Divider()
            Button("Delete", role: .destructive) { delete(row) }
        case .whoop, .apple, .lifting, .activityFile:
            // Imported history is read-only; offer a copy-to-manual edit path that doesn't touch it.
            Button("Duplicate as manual…") { editWorkout(asManualCopy(row), isCopy: true) }
        }
    }

    /// A manual-source copy of an imported row, so "Duplicate as manual" opens the add sheet pre-filled
    /// without ever mutating the imported original (the sheet saves under the strap source).
    private func asManualCopy(_ row: WorkoutRow) -> WorkoutRow {
        WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: WorkoutSource.displaySport(row.sport),
                   source: "manual", durationS: row.durationS, energyKcal: row.energyKcal,
                   avgHr: row.avgHr, maxHr: row.maxHr, strain: row.strain, distanceM: row.distanceM,
                   zonesJSON: row.zonesJSON, notes: row.notes, steps: row.steps)
    }

    /// #796 - the per-session Effort cell label: the stored 0-100 strain mapped to the user's Effort scale
    /// (the SAME `UnitFormatter.effortDisplay` every other Effort read-out routes through, so the toggle and
    /// rounding stay consistent), or "–" when the session has no captured strain. Pure + unit-testable.
    static func effortCellLabel(strain: Double?, scale: EffortScale) -> String {
        guard let strain else { return "–" }
        return UnitFormatter.effortDisplay(strain, scale: scale)
    }

    // MARK: - Aggregation

    private struct SportGroup: Identifiable {
        let sport: String
        let count: Int
        let totalTimeS: Double
        let totalKcal: Double
        var id: String { sport }
        var totalTimeH: Double { totalTimeS / 3600.0 }
        var avgTimePerSessionMin: Double { count > 0 ? (totalTimeS / Double(count)) / 60.0 : 0 }
    }

    /// Sessions grouped by sport, ordered by count (desc), then total time.
    /// Takes the already-windowed rows so `body` builds the groups exactly once.
    private func sportGroups(from rows: [WorkoutRow]) -> [SportGroup] {
        var bySport: [String: (count: Int, time: Double, kcal: Double)] = [:]
        for r in rows {
            var acc = bySport[r.sport] ?? (0, 0, 0)
            acc.count += 1
            acc.time += r.durationS ?? 0
            acc.kcal += r.energyKcal ?? 0
            bySport[r.sport] = acc
        }
        return bySport
            .map { SportGroup(sport: $0.key, count: $0.value.count,
                              totalTimeS: $0.value.time, totalKcal: $0.value.kcal) }
            .sorted { ($0.count, $0.totalTimeS) > ($1.count, $1.totalTimeS) }
    }

    /// The most-frequent sport (modal), derived from the already-built groups.
    private func modalSport(from groups: [SportGroup]) -> (sport: String, count: Int) {
        guard let top = groups.first else { return ("–", 0) }
        return (top.sport, top.count)
    }

    // MARK: - Range model

    private enum Range: CaseIterable, Hashable {
        case week, month, quarter, year, all
        var label: String {
            switch self {
            case .week:    return String(localized: "7D")
            case .month:   return String(localized: "30D")
            case .quarter: return String(localized: "90D")
            case .year:    return String(localized: "1Y")
            case .all:     return String(localized: "All")
            }
        }
        var caption: String {
            switch self {
            case .week:    return String(localized: "last 7 days")
            case .month:   return String(localized: "last 30 days")
            case .quarter: return String(localized: "last 90 days")
            case .year:    return String(localized: "last year")
            case .all:     return String(localized: "all time")
            }
        }
        /// A short noun for the effort hero's "Effort this …" headline.
        var heroWord: String {
            switch self {
            case .week:    return String(localized: "week")
            case .month:   return String(localized: "month")
            case .quarter: return String(localized: "quarter")
            case .year:    return String(localized: "year")
            case .all:     return String(localized: "log")
            }
        }
        /// Trailing-window length in days, or nil for "all".
        var days: Int? {
            switch self {
            case .week:    return 7
            case .month:   return 30
            case .quarter: return 90
            case .year:    return 365
            case .all:     return nil
            }
        }
        /// This range plus every LARGER range, ascending — the auto-expand search
        /// order when the selected window holds zero sessions.
        var widening: [Range] {
            let order: [Range] = [.week, .month, .quarter, .year, .all]
            guard let i = order.firstIndex(of: self) else { return [.all] }
            return Array(order[i...])
        }
    }

    // MARK: - Formatting

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    // The "jmm" skeleton respects the device's 12-/24-hour setting (#337): "4:34 PM" where 12-hour is
    // preferred, "16:34" where 24-hour is — instead of forcing 24-hour on everyone (matches TodayView).
    /// #1821: routed through AppClock so the Clock format setting reaches this label. Was a `static
    /// let`, which would have frozen the reader's choice at first use until the app relaunched.
    private static var timeFmt: DateFormatter { AppClock.hourMinuteFormatter() }

    /// "Fri 2 Oct" for the log rows.
    private func rowDateLabel(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts))
            .formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func dateLabel(_ ts: Int) -> String {
        Self.dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
    private func timeLabel(_ ts: Int) -> String {
        Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// "HH:mm–HH:mm" when the row carries a real end, start-only otherwise (#157).
    private func timeRangeLabel(_ start: Int, _ end: Int) -> String {
        end > start ? "\(timeLabel(start))-\(timeLabel(end))" : timeLabel(start)
    }

    private func durationLabel(_ s: Double?) -> String {
        guard let s, s > 0 else { return "–" }
        let total = Int(s.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return String(localized: "\(h)h \(m)m") }
        return String(localized: "\(m)m")
    }

    /// #64: the duration label, or nil when there's no duration to show — so the compact row's summary
    /// line can omit the field entirely rather than printing a bare "–".
    private func durationLabelOrNil(_ s: Double?) -> String? {
        guard let s, s > 0 else { return nil }
        return durationLabel(s)
    }

    private func distanceLabel(_ m: Double?) -> String {
        guard let m, m > 0 else { return "–" }
        return UnitFormatter.distanceFromMeters(m, system: distanceUnitSystem)
    }

    /// "last 30 days" → "Last 30 days", for a caption that opens a line.
    private func sentenceCase(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    private func grouped(_ v: Double) -> String {
        Self.intFmt.string(from: NSNumber(value: Int(v.rounded()))) ?? "\(Int(v.rounded()))"
    }
    private static let intFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()
}

/// Three raw-bpm HRR lines on one shared axis (#516). Unlike Compare's normalized overlay, these values
/// share a unit and scale, so their vertical distance remains meaningful. Point marks keep a single eligible
/// workout visible even when there is not yet enough history to draw a line.
///
/// PERF: an active period (multiple workouts/day over the 90-day window `recoveryTrendRows` caps to) can
/// put several hundred points on this chart — up to 3 (1/2/5-min) per workout. `displayPlots` downsamples
/// EACH interval's line independently with StrandDesign's `ChartDownsample.minMaxBucketed` (the same
/// helper TrendChart/OverviewHRChart use, generalized to a date/value key-path form so it can be called
/// from here); hover still reads the full-resolution `points`, never the downsampled draw set.
///
/// Hover/tooltip (previously missing): reuses the same `CrosshairRule`/`HighlightDot`/`PositionedTooltip`/
/// `ChartTooltip` components `TrendChart`'s `chartOverlay` uses — no new mechanism.
private struct WorkoutRecoveryTrendChart: View {
    let points: [WorkoutRecoveryTrendPoint]

    /// The x-position the cursor is hovering, in chart-local coordinates.
    @State private var hoverX: CGFloat? = nil

    private struct Plot: Identifiable {
        let startTs: Int
        let interval: String
        let value: Int
        var id: String { "\(interval)@\(startTs)" }
        var date: Date { Date(timeIntervalSince1970: TimeInterval(startTs)) }
    }

    private static let oneLabel = String(localized: "1 min")
    private static let twoLabel = String(localized: "2 min")
    private static let fiveLabel = String(localized: "5 min")

    private var plots: [Plot] {
        points.flatMap { point in
            var out: [Plot] = []
            if let value = point.result.after1Minute {
                out.append(Plot(startTs: point.startTs, interval: Self.oneLabel, value: value))
            }
            if let value = point.result.after2Minutes {
                out.append(Plot(startTs: point.startTs, interval: Self.twoLabel, value: value))
            }
            if let value = point.result.after5Minutes {
                out.append(Plot(startTs: point.startTs, interval: Self.fiveLabel, value: value))
            }
            return out
        }
    }

    /// `plots`, min/max-bucketed per interval so a dense line downsamples on its OWN shape rather than
    /// having one series' bucket choice clip another's peaks.
    private var displayPlots: [Plot] {
        let byInterval = Dictionary(grouping: plots, by: \.interval)
        return [Self.oneLabel, Self.twoLabel, Self.fiveLabel].flatMap { key -> [Plot] in
            let series = (byInterval[key] ?? []).sorted { $0.startTs < $1.startTs }
            return ChartDownsample.minMaxBucketed(series, threshold: ChartDownsample.markThreshold,
                                                   targetCount: ChartDownsample.targetVertices,
                                                   date: { $0.date }, value: { Double($0.value) })
        }
    }

    /// The full-resolution workout nearest a given chart-local x (not per-interval — one workout can carry
    /// up to 3 values at the SAME x, so the tooltip names whichever are available together).
    private func nearestPoint(toX x: CGFloat, proxy: ChartProxy, plot: CGRect) -> WorkoutRecoveryTrendPoint? {
        guard !points.isEmpty else { return nil }
        let relX = x - plot.minX
        guard let date: Date = proxy.value(atX: relX) else { return nil }
        return points.min(by: {
            abs(TimeInterval($0.startTs) - date.timeIntervalSince1970)
                < abs(TimeInterval($1.startTs) - date.timeIntervalSince1970)
        })
    }

    private static let tooltipDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    private func tooltipValue(for point: WorkoutRecoveryTrendPoint) -> String {
        var parts: [String] = []
        if let v = point.result.after1Minute { parts.append(String(localized: "1m \(v)")) }
        if let v = point.result.after2Minutes { parts.append(String(localized: "2m \(v)")) }
        if let v = point.result.after5Minutes { parts.append(String(localized: "5m \(v)")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        // Bound once: `displayPlots` groups and downsamples on every read, and this chart is the one the
        // note above calls out for putting several hundred marks on screen. The axis is derived from the
        // SAME drawn collection, so the marks cannot span days the chart is not plotting.
        let drawn = displayPlots
        let axisDays = ChartAxisDays.spanning(drawn.map(\.date), targetLabels: 4)
        Chart(drawn) { point in
            LineMark(
                x: .value("Workout", point.date),
                y: .value("Recovery", point.value)
            )
            .foregroundStyle(by: .value("Recovery interval", point.interval))
            .interpolationMethod(.catmullRom)
            PointMark(
                x: .value("Workout", point.date),
                y: .value("Recovery", point.value)
            )
            .foregroundStyle(by: .value("Recovery interval", point.interval))
            .symbolSize(28)
        }
        .chartForegroundStyleScale(
            domain: [Self.oneLabel, Self.twoLabel, Self.fiveLabel],
            range: [StrandPalette.metricRose, StrandPalette.metricCyan, StrandPalette.metricPurple]
        )
        .chartLegend(.hidden)
        // Day-aligned marks, not a requested count. This axis already formats day-only, so a sub-day
        // stride from `.automatic(desiredCount:)` put two marks in one day carrying the SAME string, one
        // over the other. Four labels kept, matching what the count asked for.
        .chartXAxis {
            AxisMarks(values: axisDays) { value in
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
                AxisValueLabel(format: ChartAxisDays.labelFormat(for: axisDays))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
                AxisValueLabel {
                    if let bpm = value.as(Int.self) { Text("\(bpm)") }
                }
                .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                ZStack(alignment: .topLeading) {
                    if let hx = hoverX,
                       let p = nearestPoint(toX: hx, proxy: proxy, plot: plot),
                       let px = proxy.position(forX: Date(timeIntervalSince1970: TimeInterval(p.startTs))) {
                        let cx = px + plot.minX
                        CrosshairRule(x: cx, height: geo.size.height)
                        PositionedTooltip(
                            anchor: CGPoint(x: cx, y: plot.minY + 8),
                            container: geo.size,
                            tooltip: ChartTooltip(
                                value: tooltipValue(for: p),
                                label: Self.tooltipDateFormatter.string(
                                    from: Date(timeIntervalSince1970: TimeInterval(p.startTs)))
                            )
                        )
                    }
                }
                .animation(StrandMotion.fade, value: hoverX)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    // Non-animating transaction: otherwise crossing the plot edge re-runs the line's
                    // draw-on animation and flickers the curve (mirrors TrendChart #104).
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) {
                        switch phase {
                        case .active(let location): hoverX = location.x
                        case .ended: hoverX = nil
                        }
                    }
                }
            }
        }
        .accessibilityLabel("Heart-rate recovery trend in beats per minute")
    }
}

#if DEBUG
@MainActor
private func previewWorkoutRows() -> [WorkoutRow] {
    let now = Int(Date().timeIntervalSince1970)
    let day = 86_400
    return [
        WorkoutRow(startTs: now - day * 0 - 3600, endTs: now - day * 0,
                   sport: "Running", source: "whoop", durationS: 3600, energyKcal: 712,
                   avgHr: 152, maxHr: 178, strain: 14.2, distanceM: 10_400,
                   zonesJSON: #"{"z1":12.5,"z2":28.0,"z3":33.5,"z4":18.0,"z5":6.0}"#, notes: nil, steps: nil),
        WorkoutRow(startTs: now - day * 1 - 2700, endTs: now - day * 1,
                   sport: "Strength Training", source: "whoop", durationS: 2700, energyKcal: 388,
                   avgHr: 118, maxHr: 156, strain: 9.4, distanceM: nil,
                   zonesJSON: nil, notes: nil, steps: nil),
        WorkoutRow(startTs: now - day * 2 - 1800, endTs: now - day * 2,
                   sport: "Cycling", source: "apple_health", durationS: 1800, energyKcal: 240,
                   avgHr: nil, maxHr: nil, strain: nil, distanceM: 12_800,
                   zonesJSON: nil, notes: nil, steps: nil),
        WorkoutRow(startTs: now - day * 3 - 1500, endTs: now - day * 3,
                   sport: "Running", source: "apple_health", durationS: 1500, energyKcal: 310,
                   avgHr: nil, maxHr: nil, strain: nil, distanceM: 5_100,
                   zonesJSON: nil, notes: nil, steps: nil),
        WorkoutRow(startTs: now - day * 4 - 3300, endTs: now - day * 4,
                   sport: "Cycling", source: "whoop", durationS: 3300, energyKcal: 540,
                   avgHr: 134, maxHr: 162, strain: 11.8, distanceM: 24_600,
                   // Android key shape on purpose — exercises the cross-platform parser.
                   zonesJSON: #"{"zone1":20.0,"zone2":35.0,"zone3":30.0,"zone4":10.0}"#, notes: nil, steps: nil),
        WorkoutRow(startTs: now - day * 6 - 2400, endTs: now - day * 6,
                   sport: "Yoga", source: "whoop", durationS: 2400, energyKcal: 165,
                   avgHr: 92, maxHr: 118, strain: 5.1, distanceM: nil,
                   zonesJSON: nil, notes: nil, steps: nil),
    ]
}

#Preview("Workouts") {
    let repo = Repository(deviceId: "preview")
    return WorkoutsView(previewRows: previewWorkoutRows())
        .environmentObject(repo)
        .environmentObject(ProfileStore())
        .environmentObject(AppModel())
        .environmentObject(IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: "preview"))
        .frame(width: 1040, height: 940)
        .preferredColorScheme(.dark)
}

#Preview("Workouts — empty") {
    let repo = Repository(deviceId: "preview")
    return WorkoutsView(previewRows: [])
        .environmentObject(repo)
        .environmentObject(ProfileStore())
        .environmentObject(AppModel())
        .environmentObject(IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: "preview"))
        .frame(width: 1040, height: 600)
        .preferredColorScheme(.dark)
}
#endif

/// "Z2 · Fat burn" in a column as wide as the widest of the five labels, so the bars beside it start on
/// one line in every language without a fixed width that cuts the German names off.
struct ZoneLabelColumn: View {
    let zone: Int

    private static func label(_ zone: Int) -> String { "Z\(zone) · \(LiveWorkoutView.zoneName(zone))" }

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(1...5, id: \.self) { z in Text(verbatim: Self.label(z)).hidden() }
            Text(verbatim: Self.label(zone)).foregroundStyle(StrandPalette.textSecondary)
        }
        .font(StrandFont.light(13, relativeTo: .subheadline))
        .lineLimit(1)
        .fixedSize()
    }
}
