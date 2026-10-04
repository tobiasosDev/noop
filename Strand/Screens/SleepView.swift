import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - SleepView
//
// The night, read in two seconds, in the v2 kit: a Rest hero in the sleep glow (score, state word,
// provenance, asleep / need / consistency, the night pager), the alarms row, then the arrangeable cards —
// the stage section (night read, overnight heart rate, stage timeline + tiles; `StageDetailView`), body
// clock, sleep marks, night detail, debt ledger, stages vs typical, asleep duration — and the naps.
// Data wiring is unchanged: everything derives from the memoized `SleepModel`.

struct SleepView: View {
    @EnvironmentObject var repo: Repository
    // NOTE: SleepView itself deliberately does NOT observe `LiveState` OR `AppModel`. A connected strap
    // publishes at ~1 Hz, and `AppModel` itself publishes `bpm` at that same ~1 Hz (AppModel.swift:202) —
    // `@EnvironmentObject` subscribes to the WHOLE object's `objectWillChange` regardless of which
    // properties are read, so holding either here would re-evaluate this heavy ~3000-line body on every
    // tick. The live dependencies — the "going to sleep / awake" mark card (appends to the strap log),
    // the "Syncing strap history…" note, and the body-clock dial's `circadianPhase` (#1680) — each own
    // their OWN `@EnvironmentObject var live`/`appModel` in a small leaf below (mirrors the Today
    // leaf-scoping pattern and HealthView.swift:17-22), so a tick refreshes only that leaf.
    @EnvironmentObject var intelligence: IntelligenceEngine

    /// Memoized snapshot of every expensive derivation (latest Night with its intervals
    /// resolved once, the seven metric series, the trend points, the typical means). Rebuilt
    /// only when the underlying repo data actually changes — NOT on hover/animation/1Hz HR
    /// ticks that merely re-evaluate `body`. `nil` until first build or when there's no night.
    @State private var model: SleepModel?
    /// The Sleep tab's stage-chart shape (Settings → Appearance → Sleep chart). Display-only; Filled/Ribbon
    /// draw the WHOOP-style stepped hypnogram, Classic keeps the per-stage rows. Mirrors Android. (#sleep-chart-style)
    @AppStorage(SleepChartStyle.storageKey) private var sleepChartStyleRaw = SleepChartStyle.classic.rawValue
    /// The repo signature the cached `model` was built from. Cheap to compute every render;
    /// when it differs from the current inputs we rebuild the model.
    @State private var modelKey: SleepInputKey?
    @State private var loadedSleepRefresh: Int?
    @State private var resultTracker = SleepResultChangeTracker()
    @State private var resultNoticeVisible = false
    @State private var resultNoticeRevision = 0
    @State private var resultNoticeScope: String?

    /// Which night the hero hypnogram shows: 0 = last night, N = N sleep-sessions back.
    /// Snaps back to 0 whenever the data key changes — a stale offset would silently point
    /// at a different session after a sync. The memoized trend `model` stays cached since
    /// the trends are night-independent. (#160)
    @State private var nightOffset = 0
    /// Memoized decode of the NAVIGATED night (nil when `nightOffset == 0` — the hero reads
    /// `model.night` then). Rebuilt only in the `nightOffset` / data-key onChange handlers;
    /// `decodedNight` JSON-decodes, which must never run per body pass (1Hz HR ticks). (#160)
    @State private var navNight: Night?

    /// Every sleep BLOCK across both sources, UN-deduplicated (`repo.allSleepSessions`) — `repo.sleeps`
    /// keeps one winner per night for the dashboard, collapsing split-sleep days (a nap + a main
    /// sleep on the same day) into a single block. The hero groups these by day (`navDays`) and
    /// merges each day into one Night, so a split day reads as one correctly-totalled night with the
    /// gaps preserved. Oldest→newest. Falls back to `repo.sleeps` until loaded. (#170)
    @State private var allSessions: [CachedSleepSession] = []
    /// `navDays` memoized, rebuilt where `model` is.
    ///
    /// Grouping calls `Calendar.startOfDay` once per session, and the browsable history is every block
    /// ever recorded, so recomputing it per render is a per-frame pass over years of nights. Body reaches
    /// it more than once (the wake-timestamp list, and `dayBlocks(at:)` for the source blocks), so a
    /// scroll paid it repeatedly. Invalidated by the same two paths that rebuild `model`: `dataKey`
    /// covers a `repo.sleeps` change, and the refresh task covers `allSessions` reloading. Nil falls back
    /// to computing it, so a first render before either has run is correct rather than empty.
    @State private var navDaysCache: [[CachedSleepSession]]?

    /// The user's LEARNED habitual midsleep (local time-of-day seconds), or nil under the cold-start
    /// threshold. Loaded from `repo.habitualMidsleepSec()` — the SAME value `AnalyticsEngine.analyzeDay`
    /// threads into the daily total — and fed into the main-night selector so the hero, the naps split,
    /// and the edit target pick the SAME block the analytics rollup did, for a shift/late sleeper too. nil
    /// keeps the existing cold-start overnight-band fallback. (#547) Refreshed with `allSessions`.
    @State private var habitualMidsleepSec: Int? = nil

    /// Persisted per-epoch MOTION series keyed by each session's detected `startTs` (#407). Loaded in the
    /// same `.task` as `allSessions` from `repo.sessionMotions(sessions:)`, then laid along the hypnogram for
    /// the SAME main-night GROUP blocks the hero resolved (mergeDay's group) — we do NOT re-resolve the
    /// night, only read the already-chosen group's stored motion. A block with no stored series stays absent
    /// (honest empty state for older rows whose `motionJSON` is NULL). Refreshed with `allSessions`.
    @State private var motionByStart: [Int: [Double]] = [:]

    /// Non-nil while the wake-time editor sheet is open. Carries the night's stable key (`startTs`) and
    /// current wake time so the editor seeds its picker; saving routes through `repo.editSleepWakeTime`,
    /// which marks the session `userEdited` so a later strap sync can't revert the correction. (#318)
    @State private var wakeEdit: WakeEdit?

    /// Non-nil while the "Add nap" picker sheet is open (#508). Carries a seed bed/wake for the picker;
    /// saving routes through `repo.addManualNap`, which stages the chosen window from raw and writes it as
    /// its OWN separate session row (`userEdited = 1`) — never folded into the night's main sleep.
    @State private var addNap: AddNapSeed?

    /// True while the hero's "why this is your main sleep" popover is open. The reason text comes
    /// straight from the foundation `MainNightReason` for the displayed night's blocks — never
    /// re-derived here — so the explainer says exactly what the selector decided. (spec 2026-06-20 C1)
    @State private var showMainSleepWhy = false
    /// The stable detected key of the nap whose "why this is a nap" popover is open, or nil. Keyed by
    /// the nap's own `startTs` so one popover shows at a time even with several nap rows. (C1)
    @State private var napWhyStartTs: Int?


    /// The transient UNDO banner shown after a suppressing delete (#65). Non-nil for ~7 seconds: carries
    /// the snapshot needed to restore the deleted night into its ORIGINAL namespace and the window text
    /// for the message. A user-created/edited delete writes no tombstone but still offers undo (restore).
    @State private var sleepUndo: SleepUndoBanner?
    /// The pending auto-dismiss task for `sleepUndo`, cancelled when a new delete replaces the banner or
    /// the user hits Undo, so a stale timer can't clear a fresh banner.
    @State private var sleepUndoTask: Task<Void, Never>?

    // #sleep-layout: the arrangeable analytical-card order + explicit hidden set, byte-identical to the
    // Android SleepLayoutPrefs keys. Reordered via the Arrange sheet; display-only, no metric changes.
    @AppStorage(SleepLayoutPrefs.orderKey) private var sleepSectionOrderRaw = ""
    @AppStorage(SleepLayoutPrefs.hiddenKey) private var sleepHiddenSectionsRaw = ""
    @State private var showSleepCustomize = false

    /// The analytical cards to render, in saved order minus the hidden set.
    private var sleepVisibleSections: [SleepSection] {
        SleepLayoutPrefs.visibleOrder(orderRaw: sleepSectionOrderRaw, hiddenRaw: sleepHiddenSectionsRaw)
    }

    var body: some View {
        // Resolve the memoized model for THIS render. `dataKey` is O(1)-ish (counts + last-row
        // identity), so comparing it every render is cheap. When it matches the cached key we
        // reuse the cached model untouched — the many body re-evaluations from hover/animation/
        // 1Hz HR ticks pay nothing. When it differs (or on first render) we build once, here,
        // synchronously, so the very first frame already shows content (no empty-state flash).
        let key = dataKey
        let resolved: SleepModel? = (key == modelKey) ? model : buildModel()
        // The title lives inside the Rest hero, which bleeds under the status bar; the empty state keeps a
        // plain scaffold title for orientation.
        ScreenScaffold(title: resolved == nil ? "Sleep" : nil,
                       subtitle: resolved == nil ? "Last night, read in two seconds." : nil,
                       // PERF: the live-observing pieces (the hero's waiting state, the mark card, the alarms
                       // row) own their observation in leaves, so a 1 Hz HR tick never re-evaluates this body.
                       onRefresh: { await repo.refresh() },
                       lazy: true) {
            // ONE child, so the sheets / tasks / change handlers below attach once (on a multi-child
            // Group every child would get its own copy of each).
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                if let resolved {
                    restHero(resolved)
                    if let sleepUndo { sleepUndoBanner(sleepUndo) }
                    if resultNoticeVisible {
                        DataPendingNote(title: "Sleep result updated",
                                        message: "This night's sleep times or total asleep changed by at least five minutes.",
                                        symbol: "checkmark.circle")
                    }
                    SleepAlarmsRow()
                    // While last night is still syncing or being scored: what happens next, and which
                    // night the cards below describe meanwhile. Renders nothing once the night is in.
                    SleepWaitingSection(latestWakeTs: resolved.night.session.endTs,
                                        isLatest: nightOffset == 0,
                                        previousNight: previousNightSummary(resolved))
                    // #sleep-layout: the analytical cards render in the user's saved order minus the
                    // hidden set, below the pinned Rest hero. Reordered via the Arrange sheet.
                    ForEach(sleepVisibleSections) { section in
                        sleepSectionView(section, resolved)
                    }
                    // Naps ride with Stages (hidden with it), drawn at the foot of the screen.
                    if sleepVisibleSections.contains(.stages) {
                        napSection(nightOffset == 0 && !resolved.isStubNight ? resolved.night
                                   : (navNight ?? stubNight(at: nightOffset) ?? resolved.night))
                    }
                    sleepArrangeRow
                } else {
                    emptyState
                    SleepAlarmsRow()
                }
            }
            // Persist the freshly-built model so subsequent renders with the same inputs hit
            // the cache. Writing State during body is not allowed, so commit it after layout;
            // `resolved` already drives THIS frame, so there is no flash and no extra rebuild.
            .onChangeCompat(of: key) { newKey in
                modelKey = newKey
                navDaysCache = SleepModel.navDays(navSessions: navSessions)
                model = buildModel()
                // New data invalidates a navigated offset — the same offset would silently
                // point at a different session. Snap back to last night. (#160)
                nightOffset = 0
                navNight = nil
            }
            // The navigated night is decoded once per ◀/▶ press, never per body pass —
            // `decodedNight` JSON-decodes and body re-evaluates at 1Hz while HR streams. (#160)
            .onChangeCompat(of: nightOffset) { newOffset in
                navNight = newOffset == 0 ? nil : decodedNight(at: newOffset)
                resetResultNotice()
                observeResultChange()
            }
            .onAppear {
                if modelKey != key {
                    modelKey = key
                    model = resolved
                    nightOffset = 0
                    navNight = nil
                }
            }
            .onChangeCompat(of: intelligence.computing) { _ in observeResultChange() }
            .onDisappear { resetResultNotice() }
            .task(id: resultNoticeRevision) {
                guard resultNoticeVisible else { return }
                do { try await Task.sleep(nanoseconds: 8_000_000_000) }
                catch { return }
                resultNoticeVisible = false
            }
            // Load EVERY sleep block across BOTH sources (un-deduplicated) so the hero's ◀/▶ can
            // browse split-sleep days the dashboard collapses — including Bluetooth-only nights,
            // whose blocks live under the computed source. Re-runs whenever a sync/import bumps
            // refreshSeq; snaps back to the newest day and rebuilds the model so offset 0 reflects
            // the freshly-loaded blocks. (#170)
            .task(id: repo.refreshSeq) {
                let refresh = repo.refreshSeq
                let sessions = await repo.allSleepSessions()
                // Load the learned habitual midsleep the engine used, so the main-night pick aligns to it
                // (a shift/late sleeper) instead of only the cold-start band. nil under threshold. (#547)
                let habitual = await repo.habitualMidsleepSec()
                // Per-epoch motion for every block (#407), keyed by detected start. mergeDay reads only the
                // already-resolved group's entries — this just pre-fetches them all so the model build is sync.
                let motions = await repo.sessionMotions(sessions: sessions)
                guard !Task.isCancelled, refresh == repo.refreshSeq else { return }
                allSessions = sessions
                habitualMidsleepSec = habitual
                motionByStart = motions
                nightOffset = 0
                navNight = nil
                modelKey = dataKey
                navDaysCache = SleepModel.navDays(navSessions: navSessions)
                model = buildModel()
                loadedSleepRefresh = refresh
                observeResultChange()
            }
            .sheet(item: $wakeEdit) { edit in
                // The night's RECORDED coverage for the #940 guards: from the immutable detected
                // onset (where the strap actually saw the night; an earlier hand-set onset widens
                // it) through the current wake. A corrected window that abandons this range has no
                // data to stage from, so the editor confirms the move instead of silently creating
                // a phantom night.
                let coverageLo = min(edit.detectedStartTs, edit.bedTs)
                SleepTimeEditor(bedTs: edit.bedTs, wakeTs: edit.wakeTs,
                                detectedStartTs: edit.detectedStartTs,
                                coverage: coverageLo...max(edit.wakeTs, coverageLo + 1),
                                suppressesReDetection: !edit.userEdited,
                                onSave: { newBedTs, newWakeTs in
                    await repo.editSleepTimes(detectedStartTs: edit.detectedStartTs, oldEndTs: edit.wakeTs,
                                              storedStagesJSON: edit.stagesJSON,
                                              newStartTs: newBedTs, newEndTs: newWakeTs)
                    // Re-score the day so the dashboard aggregates (Rest / recovery) honor the corrected
                    // sleep window, not just the Sleep tab's session view; then refresh the read cache.
                    await intelligence.analyzeRecent()
                    await repo.refresh()
                }, onDelete: {
                    // Delete = the edit path minus the re-insert: drop this session so every metric
                    // recomputes immediately as if the night were never recorded, durably tombstoned so a
                    // re-detect doesn't bring it back, then re-score + refresh exactly like an edit. (#68)
                    // #65: the returned snapshot lets the user UNDO within a few seconds. It restores the
                    // deleted row into its ORIGINAL namespace and lifts the tombstone.
                    let snapshot = await repo.deleteSleepSession(detectedStartTs: edit.detectedStartTs,
                                                                 endTs: edit.wakeTs)
                    await intelligence.analyzeRecent()
                    await repo.refresh()
                    // `edit.bedTs` is the effective (displayed) onset, so the banner shows the same clock
                    // time the user saw for this night.
                    if let snapshot { presentSleepUndo(snapshot, displayStart: edit.bedTs, windowEnd: edit.wakeTs) }
                })
            }
            .sheet(isPresented: $showSleepCustomize) {
                SleepCustomizationSheet(
                    sectionOrderRaw: $sleepSectionOrderRaw,
                    hiddenSectionsRaw: $sleepHiddenSectionsRaw
                )
            }
            // Manually add a missed nap (#508): same picker, but the chosen window is staged from raw and
            // stored as its OWN separate session — never folded into main sleep (which would mislabel the
            // awake daytime gap as light sleep).
            .sheet(item: $addNap) { seed in
                SleepTimeEditor(bedTs: seed.bedTs, wakeTs: seed.wakeTs,
                                title: "Add a nap",
                                blurb: "Pick when the nap started and ended. NOOP stages it from your data as its own session, separate from the night's sleep.",
                                bedLabel: "Nap started", wakeLabel: "Nap ended",
                                mode: .nap) { startTs, endTs in
                    await repo.addManualNap(startTs: startTs, endTs: endTs)
                    // Re-score so the day's aggregates pick up the new session, exactly like an edit.
                    await intelligence.analyzeRecent()
                    await repo.refresh()
                }
            }
        }
        // The Rest hero carries the screen's title; no system bar above it.
        .noopHidesSystemNavBar()
        #if DEBUG
        // Screenshot harness: `--demo-sleep-sheet edit|nap` opens the editor over the seeded night.
        .task { await openDemoSheet() }
        #endif
    }

    #if DEBUG
    private func openDemoSheet() async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo-sleep-sheet"), i + 1 < args.count else { return }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard let night = model?.night else { return }
        if args[i + 1] == "nap" {
            addNap = AddNapSeed(forNight: night)
        } else if let target = night.editTarget {
            wakeEdit = WakeEdit(detectedStartTs: target.startTs, bedTs: target.effectiveStartTs,
                                wakeTs: target.endTs, stagesJSON: target.stagesJSON, userEdited: target.userEdited)
        }
    }
    #endif

    /// "Rest 85 · 7h 01m asleep · 23:04 – 06:31": the night the cards below describe while last night is
    /// still on its way.
    private func previousNightSummary(_ model: SleepModel) -> String {
        let night = model.night
        let asleep = String(localized: "\(durationText(night.stages.asleep)) asleep")
        let window = "\(night.onsetText) – \(night.wakeText)"
        if let score = performanceScore(for: night) {
            return "\(String(localized: "Rest \(Int(score.rounded()))")) · \(asleep) · \(window)"
        }
        return "\(asleep) · \(window)"
    }
    // MARK: - 0. REST HERO — scenic backdrop + sleep-performance gauge (Bevel)

    // MARK: - Delete undo (#65)

    /// Show the transient UNDO banner after a suppressing delete, and arm the 7-second auto-dismiss. A
    /// second delete replaces the banner (its old auto-dismiss task is cancelled first) so only the most
    /// recent delete is undoable. Single-level and transient, matching the WorkoutsView postLogNote idiom.
    private func presentSleepUndo(_ snapshot: SleepDeletionSnapshot, displayStart: Int, windowEnd: Int) {
        sleepUndoTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            sleepUndo = SleepUndoBanner(snapshot: snapshot, identityStart: snapshot.session.startTs,
                                        displayStart: displayStart, windowEnd: windowEnd)
        }
        let armed = snapshot.session.startTs
        sleepUndoTask = Task {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Only clear if this is still the banner we armed (a newer delete would have replaced it).
                if sleepUndo?.identityStart == armed {
                    withAnimation(.easeOut(duration: 0.2)) { sleepUndo = nil }
                }
            }
        }
    }

    /// Undo the most recent suppressing delete: restore the row into its ORIGINAL namespace, lift the
    /// tombstone, re-score, then dismiss the banner.
    private func undoSleepDelete(_ banner: SleepUndoBanner) async {
        sleepUndoTask?.cancel()
        await repo.undoDeleteSleepSession(banner.snapshot)
        await intelligence.analyzeRecent()
        await repo.refresh()
        await MainActor.run { withAnimation(.easeOut(duration: 0.2)) { sleepUndo = nil } }
    }

    /// Locale-formatted clock time (no date) for the banner's window range.
    private func clockTime(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts))
            .formatted(Date.FormatStyle(date: .omitted, time: .shortened)
                .locale(AppClock.formattingLocale))   // #1821
    }

    /// The transient undo strip: the suppressed window and a real Undo button. The Undo button carries its
    /// own explicit label for VoiceOver.
    @ViewBuilder
    private func sleepUndoBanner(_ banner: SleepUndoBanner) -> some View {
        // Branch the copy on userEdited: a hand-edited/added night writes NO tombstone (it is never
        // re-detected), so the suppression promise would be false for it. Only a DETECTED delete writes a
        // tombstone, so only it gets the "won't detect ... again" wording. (#65 banner honesty.)
        let message = banner.snapshot.session.userEdited
            ? String(localized: "Sleep deleted.")
            : String(localized: "Sleep deleted. NOOP won't detect sleep between \(clockTime(banner.displayStart)) and \(clockTime(banner.windowEnd)) again.")
        HStack(alignment: .center, spacing: 14) {
            PhIcon("trash", size: 18)
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityHidden(true)
            Text(message)
                .font(StrandFont.light(14))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                Task { await undoSleepDelete(banner) }
            } label: {
                Text("Undo")
                    .font(StrandFont.medium(15))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .background(Capsule(style: .continuous).fill(StrandPalette.textSecondary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Undo sleep deletion")
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .background(RoundedRectangle(cornerRadius: NoopVisualStyle.cardRadius, style: .continuous)
            .fill(NoopVisualStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: NoopVisualStyle.cardRadius, style: .continuous)
            .strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
    }

    /// A short night-relative label ("Last night" / "1 night ago" / "N nights ago") for the
    /// ◀/▶-navigated night. Shared by the Rest hero overline and the hypnogram nav header so both
    /// name the SAME night the hero's score is now resolved for.
    private var nightRelativeLabel: LocalizedStringKey {
        let n = nightsAgo(nightOffset)
        return n == 0 ? "Last night" : (n == 1 ? "1 night ago" : "\(n) nights ago")
    }

    /// #1311: how many nights back the carousel night at `offset` is, counted in CALENDAR nights rather
    /// than carousel index. The ◀/▶ carousel steps by RECORDED night (`navDays`, newest-first), so a
    /// night with no data (strap off-body) is a gap the flat index can't see — labelling by index makes
    /// two nights either side of a skipped night read as consecutive and desyncs the "N nights ago"
    /// labels (and the Rest value they name).
    ///
    /// Counted FROM TODAY, not from the newest recorded night.
    ///
    /// Delegates to `SleepNightLabel.nightsAgo`, which is where this logic is tested. It lived inline
    /// and private here, which is why the newest-anchored defect went uncaught on this platform.
    /// Kotlin twin: `calendarNightsAgo`.
    private func nightsAgo(_ offset: Int, now: Date = Date()) -> Int {
        SleepNightLabel.nightsAgo(
            // Optional per entry, NOT `?? 0`: a day group with no session must fall back to the offset
            // the way the Kotlin twin does. Zero would be 1970 and would read as ~20,000 nights ago.
            wakeTimestamps: navDays.map { $0.first.map { s in Int(s.endTs) } },
            offset: offset,
            today: Repository.logicalDay(now)
        )
    }

    /// The night the Rest hero reflects: the ◀/▶-navigated night while browsing (falling back to
    /// last night only if that navigated night hasn't decoded yet), else last night. Keeps the
    /// hero's score, vessel fill, state word, provenance badge and overline on the SAME night the
    /// hypnogram shows — the fix for the score freezing on last night's value during navigation.
    private func heroNight(_ model: SleepModel) -> Night {
        (nightOffset == 0 ? model.night : navNight) ?? model.night
    }

    /// The sleep-performance score (0–100) for a SPECIFIC night: the imported WHOOP figure for that
    /// night's LOCAL wake-day when the export carried one, else the resolved Rest composite for that
    /// day. Mirrors `performanceSeries`'s per-day transform exactly (the same single source of truth
    /// the Today Rest score reads), keyed by the wake-day (sleep is filed under the day you woke) so
    /// a navigated past night reads ITS OWN score, never last night's. nil when that day has no score.
    private func performanceScore(for night: Night) -> Double? {
        let wakeDay = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(night.session.endTs)))
        if let p = repo.importedSleep[wakeDay]?.performancePct { return p }
        guard let daily = repo.days.last(where: { $0.day == wakeDay }) else { return nil }
        return AnalyticsEngine.Rest.composite(daily: daily)
    }

    /// Dispatch a reorderable Sleep section to its card. Naps ride with `.stages` (drawn at the foot of the
    /// screen); the Rest hero is pinned outside this list. Mirrors the Android SleepScreen `when(section)`.
    @ViewBuilder
    private func sleepSectionView(_ section: SleepSection, _ model: SleepModel) -> some View {
        switch section {
        case .sleepMarks:      SleepMarkCard()
        case .stages:          stageSection(model)
        case .bodyClock:       bodyClockDial(model)
        case .nightDetail:     NightDetailCard(model: model)
        case .sleepDebt:       SleepDebtLedgerCard(model: model)
        case .stagesVsTypical: StagesVsTypicalCard(model: model)
        case .asleepDuration:  durationTrend(model)
        }
    }
    /// The 24 h dial (#1680), or nothing at all.
    ///
    /// Drawn only for a fit that is at least `.wide`: an `.unreadable` rhythm has no phase to compare a
    /// night against, and an empty ring would read as a broken chart rather than as "not enough data". The
    /// card is a reorderable Sleep section, so anyone who does not want it hides it in Arrange — the same
    /// affordance every other card on this screen already has, rather than a new setting of its own.
    @ViewBuilder
    private func bodyClockDial(_ model: SleepModel) -> some View {
        // PERF: `circadianPhase` lives on `AppModel`, isolated into its own leaf (`BodyClockDialSection`)
        // rather than read via an `appModel: AppModel` property on this screen — see the NOTE above.
        BodyClockDialSection(actualBedHour: Self.localClockHour(model.night.session.effectiveStartTs),
                              actualWakeHour: Self.localClockHour(model.night.session.endTs))
    }

    /// A unix second as a fractional local clock hour — the dial's only input beyond the phase estimate.
    static func localClockHour(_ ts: Int) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute],
                                                from: Date(timeIntervalSince1970: TimeInterval(ts)))
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60.0
    }

    /// The Arrange entry for the reorderable cards — opens the Arrange sheet. Mirrors the Today tab's arrange
    /// entry and the Android Sleep affordance.
    private var sleepArrangeRow: some View {
        NoopList {
            Button { showSleepCustomize = true } label: {
                NoopRow("Arrange Sleep cards", caption: "Order and hide the sections above",
                        icon: "sliders-horizontal", chevron: true)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 18)
    }

    /// The Rest hero: the night pager, the Rest score with its state word and provenance, a one-line read
    /// of the night and the asleep / need / consistency trio. It runs under the status bar in the sleep
    /// glow. The waiting state (last night still syncing or being scored) is decided inside the
    /// `SleepHeroView` leaf, which owns the live observation.
    private func restHero(_ model: SleepModel) -> some View {
        let night = heroNight(model)
        let score = performanceScore(for: night)
        let lastIndex = max(navDays.count - 1, 0)
        let n = nightsAgo(nightOffset)
        let asleep = durationText(night.stages.asleep)
        let sentence: String = n == 0 ? String(localized: "\(asleep) asleep last night.")
            : (n == 1 ? String(localized: "\(asleep) asleep, 1 night ago.") : String(localized: "\(asleep) asleep, \(n) nights ago."))
        let third: SleepHeroView.Stat = nightOffset == 0
            ? .init(value: model.consistency.latest.map { "\(Int($0.rounded()))" } ?? "—",
                    unit: model.consistency.latest == nil ? nil : "%", label: String(localized: "Consistency"))
            : .init(value: hoursMinutes(night.timeInBed), unit: "h", label: String(localized: "In bed"))
        return SleepHeroView(
            pagerLabel: nightRelativeLabel,
            canGoOlder: nightOffset < lastIndex,
            canGoNewer: nightOffset > 0,
            onOlder: { if nightOffset < lastIndex { nightOffset += 1 } },
            onNewer: { if nightOffset > 0 { nightOffset -= 1 } },
            score: score,
            scoreWord: score.map(sleepScoreWord),
            source: score != nil ? heroSource(for: night) : (repo.activeDeviceIsOura ? String(localized: "Oura") : String(localized: "On-device")),
            asleepClock: hoursMinutes(night.stages.asleep),
            sentence: sentence,
            stats: [
                .init(value: hoursMinutes(night.stages.asleep), unit: "h", label: String(localized: "Asleep")),
                // The normative need every debt surface measures against (one need on this screen).
                .init(value: hoursMinutes(model.sleepDebtLedger.needMin), unit: "h", label: String(localized: "Sleep needed")),
                third,
            ],
            // When the older-night arrow is disabled because no earlier night is banked yet, a greyed
            // chevron reads as broken; say why instead. (#614 follow-up)
            showsEarliestHint: nightOffset >= lastIndex,
            latestWakeTs: model.night.session.endTs,
            isLatest: nightOffset == 0)
    }

    /// "7:12" — hours and minutes, for the hero's figures.
    private func hoursMinutes(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        return String(format: "%d:%02d", m / 60, m % 60)
    }
    /// A short Rest state word for the hero gauge — same banding the synthesis hero uses.
    private func sleepScoreWord(_ score: Double) -> String {
        switch score {
        case ..<50:  return String(localized: "Poor")
        case ..<70:  return String(localized: "Fair")
        case ..<85:  return String(localized: "Good")
        default:     return String(localized: "Optimal")
        }
    }

    /// Whether a SPECIFIC night's sleep-performance score is WHOOP's own imported figure, an Oura
    /// ring-provided figure, or NOOP's on-device approximation — so the hero is honest about provenance,
    /// like Today's badges. Keyed by the night's wake-day (matching `performanceScore(for:)`) so a
    /// navigated night's badge tracks ITS OWN score's provenance, not last night's.
    private func heroSource(for night: Night) -> String {
        let wakeDay = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(night.session.endTs)))
        if repo.importedSleep[wakeDay]?.performancePct != nil { return String(localized: "Whoop") }
        return repo.activeDeviceIsOura ? String(localized: "Oura") : String(localized: "On-device")
    }

    // MARK: - Provenance for the displayed night (COMPONENT 4, spec 2026-06-20)

    /// The REAL per-day merge winner for the DISPLAYED night's sleep numbers, as the same brand wording the
    /// By-Day badge / Today / Intelligence use ("On-device" / "Whoop"). A WHOOP export covering the night's
    /// wake-day wins the dashboard merge (imports win field-by-field, Repository.mergeDaily), so the badge
    /// says "Whoop"; otherwise the night was scored on-device by NOOP. Keyed by the night's LOCAL wake-day
    /// (the `mergeSleep` / importer convention, sleep is filed under the day you woke), so a navigated past
    /// night reads its OWN provenance, not last night's. Honest: never a blanket "on-device". Apple Health
    /// carries no sleep into `importedSleep`, so the sleep merge winner is only ever Whoop vs on-device. (C4)
    private func nightSource(_ night: Night) -> String {
        let wakeDay = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(night.session.endTs)))
        if repo.importedSleep[wakeDay] != nil { return String(localized: "Whoop") }
        // An Oura ring PROVIDES the night's stages (its own SleepNet hypnogram, banked as the imported
        // session that wins the merge), so name it "Oura" — not the generic "On-device" that implies a
        // NOOP computation. WHOOP import still wins above; only a night surfaced under a live Oura strap
        // reaches here as "Oura".
        if repo.activeDeviceIsOura { return String(localized: "Oura") }
        return String(localized: "On-device")
    }

    // MARK: - 0b. SLEEP MARKS — tap to log "going to sleep" / "I'm awake" (#461, Phase 1)
    //
    // Extracted to the `SleepMarkCard` leaf at the foot of this file. It owns its OWN `@EnvironmentObject
    // var live` (it appends to the shareable strap log) + `repo`, plus the `lastMark` confirmation state,
    // so SleepView itself no longer observes LiveState and a 1 Hz HR tick can't re-render this body.

    // MARK: - 1. Stages

    /// The stage section for the displayed night: the night read, the overnight heart rate, the stage
    /// timeline with the clock window and edit affordance, and the stage tiles (`StageDetailView`, shared
    /// with Today's read-only card). Offset 0 reads the memoized latest night; navigated offsets read the
    /// cached `navNight` — never a fresh decode here. A night with no usable stages keeps its REAL window
    /// and edit pencil over an honest placeholder — never the latest night under a navigated label. (#160)
    @ViewBuilder
    private func stageSection(_ model: SleepModel) -> some View {
        let typical = StageTypicals(model: model)
        // #940: when the NEWEST day failed to merge (model.isStubNight), offset 0 falls through to the same
        // honest stage-less stub path the navigated browse uses, instead of drawing a zeroed stage card.
        if nightOffset == 0, !model.isStubNight {
            StageDetailView(night: model.night, intervals: model.intervals, typical: typical,
                            lead: AnyView(nightRead(model.night, model: model)),
                            cardHeader: AnyView(windowHeader(model.night)))
                .padding(.top, 14)
        } else if let night = navNight {
            StageDetailView(night: night, intervals: night.intervals, typical: typical,
                            lead: AnyView(nightRead(night, model: model)),
                            cardHeader: AnyView(windowHeader(night)))
                .padding(.top, 14)
        } else if let stub = stubNight(at: nightOffset) {
            NoopSectionTitle("Stages", captionKey: "vs your typical night")
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    windowHeader(stub)
                    noStagePlaceholder.frame(height: 120)
                }
            }
        }
    }

    /// A stage-less stub Night for the day `offset` stops back, purely to reuse Night's date/time
    /// formatting and keep the edit affordance on a real stored row. nil for an empty day.
    private func stubNight(at offset: Int) -> Night? {
        guard let session = sessionRow(at: offset) else { return nil }
        return Night(session: session, stages: Stages(awake: 0, light: 0, deep: 0, rem: 0),
                     sourceBlocks: dayBlocks(at: offset), habitualMidsleepSec: habitualMidsleepSec)
    }

    /// The night's read above the heart-rate chart: the restorative (deep + REM) time against the wearer's
    /// usual. Sleep debt is deliberately left to the ledger card and the Night detail tile rather than
    /// stated a third time here.
    private func nightRead(_ night: Night, model: SleepModel) -> some View {
        let restorative = night.stages.deep + night.stages.rem
        var parts: [String] = []
        if let d = model.typicalDeepMin, let r = model.typicalRemMin {
            parts.append(String(localized: "Your usual is \(durationText(d + r))."))
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(durationText(restorative)) of deep and REM sleep")
                .font(StrandFont.book(16, relativeTo: .headline))
                .foregroundStyle(StrandPalette.textPrimary)
            if !parts.isEmpty {
                Text(verbatim: parts.joined(separator: " "))
                    .font(StrandFont.light(14))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The stage card's header: the night's clock window, its time in bed / efficiency / provenance, the
    /// "why this is your main sleep" explainer (C1) and the edit pencil (#318). The provenance names the
    /// REAL per-day merge winner (C4).
    private func windowHeader(_ night: Night) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "\(night.onsetText) – \(night.wakeText)")
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: windowCaption(night))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if let reason = mainSleepReasonText(night) {
                Button { showMainSleepWhy.toggle() } label: { circleIcon("info") }
                    .buttonStyle(.plain)
                    .help("Why this is your main sleep")
                    .accessibilityLabel("Why this is your main sleep")
                    .popover(isPresented: $showMainSleepWhy, arrowEdge: .bottom) {
                        whyPopover(text: reason, napSuffix: false)
                    }
            }
            wakeEditButton(night)
        }
    }

    /// "7h 44m in bed · 93% efficiency · On-device · stages approximate".
    private func windowCaption(_ night: Night) -> String {
        var parts = [String(localized: "\(durationText(night.timeInBed)) in bed")]
        if night.stages.total > 0 { parts.append(String(localized: "\(efficiencyText(night)) efficiency")) }
        parts.append(nightSource(night))
        if (night.realSegments?.count ?? 0) >= 2 {
            // An Oura night's stages are the ring's RAW on-device classification, not a NOOP approximation.
            parts.append(repo.activeDeviceIsOura ? String(localized: "raw on-device stages")
                                                 : String(localized: "stages approximate (on-device)"))
        }
        return parts.joined(separator: " · ")
    }

    /// A 34 pt circle holding a Phosphor icon, for the stage card's header controls.
    private func circleIcon(_ name: String, weight: PhosphorWeight = .light) -> some View {
        PhIcon(name, weight: weight, size: 16)
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(width: 34, height: 34)
            .background(Circle().fill(NoopVisualStyle.inset))
            .overlay(Circle().strokeBorder(NoopVisualStyle.border, lineWidth: 1))
            .contentShape(Circle())
    }

    /// Pencil affordance that opens the sleep-time editor for `night`. Auto-detection misreads the wake
    /// time most often, so a one-tap correction sits beside the window. A filled pencil marks a night
    /// already hand-corrected. (#318)
    ///
    /// The hero shows a MERGED/synthetic Night — its `session` carries no `stagesJSON` and a reset
    /// `userEdited` (mergeDay). So resolve the actual stored block being edited by identity (the night's
    /// main block), never by re-scanning `allSessions` for a wake-time match.
    @ViewBuilder
    private func wakeEditButton(_ night: Night) -> some View {
        if let target = night.editTarget {
            let isEdited = target.userEdited
            Button {
                wakeEdit = WakeEdit(detectedStartTs: target.startTs,
                                    bedTs: target.effectiveStartTs,
                                    wakeTs: target.endTs,
                                    stagesJSON: target.stagesJSON,
                                    userEdited: isEdited)
            } label: {
                circleIcon("pencil-simple", weight: isEdited ? .fill : .light)
            }
            .buttonStyle(.plain)
            .help("Edit sleep times")
            .accessibilityLabel(isEdited ? "Edit sleep times (edited)" : "Edit sleep times")
        }
    }

    /// A compact explainer popover: the verbatim foundation reason text, with the nap suffix appended for a
    /// nap row. Plain English, no jargon (the words come straight from `mainSleepReasonText` and the spec's
    /// nap-row suffix). Sized for both macOS and iOS. (spec 2026-06-20 C1)
    @ViewBuilder
    private func whyPopover(text: String, napSuffix: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PhIcon("moon-stars", size: 16)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityHidden(true)
                Text(napSuffix ? "About this nap" : "About your main sleep")
                    .font(StrandFont.book(14))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            if !text.isEmpty {
                Text(text)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if napSuffix {
                Text("Logged as a nap. Wrong? Tap Edit to adjust your sleep and wake times.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(NoopMetrics.cardInnerPadding)
        .frame(width: 260)
        .background(NoopPanelSurface(cornerRadius: NoopVisualStyle.compactRadius, elevated: true))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Naps (#508)

    /// Naps: each of the day's sleep blocks OTHER than the night's main group, individually editable +
    /// deletable with the SAME durable mechanism main sleep uses, plus "Add nap". A nap is always its own
    /// session row (never folded into main sleep), so editing or adding one never touches the night's main
    /// hypnogram. The day's main sleep is the bridged main-night GROUP (#561): a briefly-interrupted night's
    /// sibling fragments are part of the night, NOT naps. (#508, #518, #555)
    @ViewBuilder
    private func napSection(_ night: Night) -> some View {
        let groupStarts = night.mainGroupStarts
        let naps = night.sourceBlocks
            .filter { !groupStarts.contains($0.startTs) }
            .sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        let mainMin = night.stages.total
        let napMin = naps.reduce(0.0) { $0 + Double($1.endTs - $1.effectiveStartTs) / 60.0 }
        NoopSectionTitle("Naps", captionKey: "Daytime sleep")
        if !naps.isEmpty {
            NoopList {
                ForEach(naps, id: \.startTs) { nap in napRow(nap) }
            }
        }
        Button { addNap = AddNapSeed(forNight: night) } label: {
            HStack(spacing: 8) {
                PhIcon("plus", size: 18)
                Text("Add nap")
            }
        }
        .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
        .accessibilityLabel("Add a nap")
        // Daily split (#518): only meaningful once the day has a nap. Total = main + naps, the time that
        // drives the day's Rest.
        Text(naps.isEmpty
             ? String(localized: "No naps recorded for this day. Each nap is stored as its own session, separate from the night.")
             : String(localized: "Main sleep \(durationText(mainMin)) · naps \(durationText(napMin)) · total \(durationText(mainMin + napMin))"))
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    /// One nap row: its weekday, clock window, length and origin; tapping opens the SAME `SleepTimeEditor`
    /// main sleep uses (re-staged from raw over the corrected window, sticky via `userEdited`, never a
    /// duplicate since the detected `startTs` PK is immutable). The info button explains why it is a nap.
    private func napRow(_ nap: CachedSleepSession) -> some View {
        let start = Date(timeIntervalSince1970: TimeInterval(nap.effectiveStartTs))
        let weekday = start.formatted(Date.FormatStyle().weekday(.wide).locale(AppLanguage.activeLocale))
        let origin = nap.userEdited ? String(localized: "added by hand") : String(localized: "detected")
        let caption = "\(napWindowText(nap)) · \(durationText(Double(nap.endTs - nap.effectiveStartTs) / 60.0)) · \(origin)"
        let edit = {
            wakeEdit = WakeEdit(detectedStartTs: nap.startTs,
                                bedTs: nap.effectiveStartTs,
                                wakeTs: nap.endTs,
                                stagesJSON: nap.stagesJSON,
                                userEdited: true)   // a nap row writes no tombstone on delete
        }
        return NoopRow(title: Text("\(weekday) nap"), caption: Text(verbatim: caption), icon: "cloud-moon",
                       chevron: true) {
            // C1 — "why this is a nap": everything other than the chosen main block is logged as a nap.
            Button { napWhyStartTs = (napWhyStartTs == nap.startTs) ? nil : nap.startTs } label: {
                PhIcon("info", size: 18)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Why this is logged as a nap")
            .accessibilityLabel("Why this is logged as a nap")
            .popover(isPresented: Binding(
                get: { napWhyStartTs == nap.startTs },
                set: { if !$0 { napWhyStartTs = nil } }), arrowEdge: .bottom) {
                whyPopover(text: "", napSuffix: true)
            }
        }
        .onTapGesture(perform: edit)
        .accessibilityAction(named: Text("Edit nap times"), edit)
    }

    /// "HH:mm–HH:mm" clock window for a nap row (device 12-/24-h setting via the shared Night formatter).
    private func napWindowText(_ nap: CachedSleepSession) -> String {
        let start = Night.clockString(nap.effectiveStartTs)
        let end = Night.clockString(nap.endTs)
        return "\(start) – \(end)"
    }
    /// Pure #345 gate (unit-testable without a live view) — whether the "May be incomplete" caveat applies.
    /// Mirror EXACTLY in Kotlin.
    ///
    /// `stagingSparse` alone is NOT the question the note asks. It is a STAGING-MECHANISM verdict:
    /// `SleepStager.isGravitySparse` returns true when the gravity span is short against the HR span OR when
    /// the LARGEST inter-sample gap exceeds `maxGapMin`, and its own doc calls that second branch "the
    /// typical WHOOP 4.0 backfill (#28)" whose only consequence is to ENABLE `buildRuns`' HR-vouched bridge.
    /// So a single long motion dropout sets it on a night of ANY length, including a complete twelve-hour
    /// one, and the flag is raised precisely where the engine has already applied its own mitigation.
    ///
    /// The note's copy, though, claims something narrower and checkable: that the night "may be
    /// under-detected and the sleep total can read short". So require the total to actually read short. A
    /// night at or above the wearer's need cannot honestly be captioned as possibly reading short, whatever
    /// the motion trace looked like.
    ///
    /// A night that staged to NOTHING keeps the caveat: zero asleep is the strongest form of the collapse
    /// this note exists to explain, not an exemption from it.
    ///
    /// `needHours` is a parameter rather than a constant so a personalised need
    /// (`AnalyticsEngine.Rest.personalizedNeedHours`) can be threaded in later without moving the rule. It
    /// is computed per pass today and not persisted on the row a screen can reach, so the shared default
    /// stands in.
    static func stageSparseNoteApplies(stagingSparse: Bool,
                                       asleepMin: Double,
                                       needHours: Double = AnalyticsEngine.Rest.defaultNeedHours) -> Bool {
        guard stagingSparse else { return false }
        return asleepMin < needHours * 60.0
    }

    /// Pure H9 gate (unit-testable without a live view) — true when a night's staging is low-confidence:
    /// a high-efficiency night whose deep+REM share is below the restorative floor. Built on the engine's
    /// own `ScoreConfidence.rest(...)` so the UI flag and the persisted Rest confidence agree. `asleepMin`,
    /// `deepMin`, `remMin` are minutes; `efficiency` is asleep/in-bed in [0,1]. Returns false for an unstaged
    /// or zero-asleep night (no staging to doubt). Mirror EXACTLY in Kotlin. (#H9)
    static func isStagingLowConfidence(asleepMin: Double, deepMin: Double, remMin: Double,
                                       efficiency: Double) -> Bool {
        guard asleepMin > 0 else { return false }
        let restorativeMin = max(0, deepMin) + max(0, remMin)
        // An UNSTAGED night (no deep+REM at all) has no staging split to doubt — its base Rest
        // confidence already reads honestly as `.building` (NOT a downgrade), so it must never be
        // flagged. Only a night that DID stage some sleep can be a suspicious "high efficiency yet
        // implausibly little restorative" staging miss.
        guard restorativeMin > 0 else { return false }
        let tier = ScoreConfidence.rest(
            hasSession: true,
            hasStagedSleep: true,
            asleepSeconds: asleepMin * 60.0,
            restorativeSeconds: restorativeMin * 60.0,
            efficiency: efficiency)
        // The H9 overload only DOWNGRADES solid → building on the suspicious case; a genuinely
        // low-restorative-AND-low-efficiency night keeps its honest base tier and isn't flagged here.
        return tier == .building
            && (restorativeMin / asleepMin) < ScoreConfidence.restorativeLowConfidenceShare
            && efficiency >= ScoreConfidence.highEfficiencyThreshold
    }

    // MARK: - 2. Metric grid (UNIFORM fixed-height StatTiles, each with sparkline)
    //
    // The "Night detail" grid now lives in `NightDetailCard` (a standalone view) so it can ALSO be hosted
    // in the Today tab from the SAME `SleepModel`. `sleepSectionView(.nightDetail)` renders `NightDetailCard`
    // directly; the grid body and its tile-formatting helpers (`pctValue` / `rrValue` / `vsTypical` /
    // `debtCaption` / `debtColor` / `spark` / `tileColumns`) moved there with it.

    // The "Sleep-debt ledger" card now lives in `SleepDebtLedgerCard` (a standalone view) so it can ALSO
    // be hosted in the Today tab from the SAME `SleepModel`. `sleepSectionView(.sleepDebt)` renders
    // `SleepDebtLedgerCard` directly; the card body, its `debtDeltaBars` strip and the debt-only
    // formatters (`debtHeadline` / `debtTag` / `debtRead` / `debtBalanceColor` / `debtSigned`) moved there
    // with it — they had no other caller in SleepView.

    // MARK: - 4. 30-day asleep-hours trend

    @ViewBuilder
    private func durationTrend(_ model: SleepModel) -> some View {
        // #today-hosted-cards: the card view was extracted to AsleepDurationCard so Today can host it.
        // The memoized model values keep the Sleep-tab perf (no per-render recompute); the Today host
        // builds AsleepDurationData itself from the same source, so the two render identical numbers.
        AsleepDurationCard(data: AsleepDurationData(points: model.trendPoints,
                                                    typicalTotalMin: model.typicalTotalMin,
                                                    needMin: model.sleepDebtLedger.needMin))
    }

    /// Compare only after the screen has loaded the refreshed blocks and scoring has settled.
    /// The observer lives on the screen, so a hidden notice cannot stop change observation.
    private func observeResultChange() {
        guard loadedSleepRefresh == repo.refreshSeq, !intelligence.computing else { return }
        guard let model else { resetResultNotice(); return }
        let snapshot = resultSnapshot(heroNight(model))
        if resultNoticeScope != snapshot.scope { resultNoticeVisible = false }
        resultNoticeScope = snapshot.scope
        if resultTracker.observe(snapshot, ready: true) {
            resultNoticeVisible = true
            resultNoticeRevision += 1
        }
    }

    private func resetResultNotice() {
        resultTracker = SleepResultChangeTracker()
        resultNoticeVisible = false
        resultNoticeScope = nil
    }

    private func resultSnapshot(_ night: Night) -> SleepResultSnapshot {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: Double(night.session.endTs)))
        let sources = Set(night.sourceBlocks.compactMap(\.deviceId)).sorted().joined(separator: ",")
        return SleepResultSnapshot(
            scope: "\(repo.deviceId):\(sources):\(day.timeIntervalSince1970)",
            onset: night.session.effectiveStartTs, wake: night.session.endTs,
            asleepMinutes: night.stages.asleep,
            edited: night.session.userEdited || night.sourceBlocks.contains { $0.userEdited })
    }

    // MARK: - Memoization plumbing

    /// A cheap fingerprint of the repo inputs this screen derives from. Recomputed every
    /// render but only contains counts + the identity of the newest/oldest rows, so equality
    /// is fast. When it changes we know `repo.days`/`repo.sleeps` actually changed and the
    /// memoized `model` must be rebuilt; otherwise hover/animation/1Hz HR re-renders are free.
    private var dataKey: SleepInputKey {
        SleepInputKey(
            loaded: repo.loaded,
            daysCount: repo.days.count,
            sleepsCount: repo.sleeps.count,
            firstDay: repo.days.first?.day,
            lastDay: repo.days.last?.day,
            lastDayUpdated: repo.days.last,
            lastSleep: repo.sleeps.last,
            refreshSeq: repo.refreshSeq)
    }

    /// Build every expensive derivation exactly once. Called only when `dataKey` changes, so each
    /// full pass over repo.days / repo.sleeps runs once per data change rather than once per render.
    /// A thin wrapper: it snapshots the view's current state into `SleepModelInputs` and hands off to
    /// the pure `SleepModel.build(_:)` (SleepModel.swift), which the Today host also calls. Returns
    /// nil when there is no usable latest night (renders empty state).
    private func buildModel() -> SleepModel? {
        SleepModel.build(SleepModelInputs(
            days: repo.days,
            sleeps: repo.sleeps,
            allSessions: allSessions,
            importedSleep: repo.importedSleep,
            habitualMidsleepSec: habitualMidsleepSec,
            motionByStart: motionByStart))
    }

    // MARK: - Derived model

    /// The browsable block list: every sleep session un-deduplicated (incl. same-day naps / split
    /// sleep). Falls back to `repo.sleeps` (one-per-night) until the fuller list loads, so the hero
    /// is never empty during the first frame. (#170)
    private var navSessions: [CachedSleepSession] {
        allSessions.isEmpty ? repo.sleeps : allSessions
    }

    /// The browsable DAY list — a thin wrapper over the shared `SleepModel.navDays`, which is the
    /// source of truth the builder and the ◀/▶ nav both read (no duplicated grouping). (#170)
    private var navDays: [[CachedSleepSession]] {
        navDaysCache ?? SleepModel.navDays(navSessions: navSessions)
    }

    /// The device's current UTC offset (seconds east), evaluated once per pick. Feeds the selector's
    /// `offsetSec` so the timing test reads the user's clock via the SAME `offsetSec` math the engine
    /// uses (`SleepStageTotals.localSecOfDay`), instead of `Calendar.current.component(.hour:)` which was
    /// the duplicated, DST-fragile gate the audit flagged. (#547)
    static var tzOffsetSec: Int { TimeZone.current.secondsFromGMT() }

    /// The day's single WINNING main block — the durable-edit anchor (`editTarget`) and the one block whose
    /// learned-timing score won. Scores by learned timing on each block's EFFECTIVE onset (what the user
    /// sees) and returns the owning session. This is the BARE single-block pick (no gap-bridge), because the
    /// edit affordance writes against ONE real row so it must resolve to one block. The HERO display and the
    /// nap split do NOT use this alone: they use `mainNightGroup`, which bridges the winner's adjacent
    /// fragments (a wake gap shorter than `gapBridgeMaxMin`) into ONE night the way `AnalyticsEngine`
    /// does (#561), so a biphasic / briefly-interrupted night is shown as one continuous sleep instead of
    /// phantom naps (#555). `habitualMidsleepSec` is the SAME learned value the engine threads into the
    /// persisted totals (loaded via `repo.habitualMidsleepSec()`), so a shift/late sleeper's pick matches
    /// the analytics rollup; nil keeps the cold-start overnight-band bonus. (#525 / #547 / #561)
    static func mainNightSession(_ sessions: [CachedSleepSession],
                                 habitualMidsleepSec: Int? = nil) -> CachedSleepSession? {
        SleepStageTotals.mainNightIndex(
            sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec).map { sessions[$0] }
    }

    /// The day's MAIN-night GROUP — the winning block PLUS any adjacent fragments bridged into it (a wake
    /// gap shorter than `gapBridgeMaxMin`), so a briefly-interrupted / biphasic night reads as ONE
    /// continuous sleep exactly the way `AnalyticsEngine.analyzeDay` rolls it up for the daily total (#561).
    /// The hero aggregates this whole group and ONLY blocks outside it are naps. Without it the tab used the
    /// un-bridged single-block pick and rendered the bridged siblings as phantom naps (#555). A night with
    /// no bridgeable gap collapses to the single block `mainNightSession` picks, so the common case is byte-
    /// identical. Returns ascending by effective onset. (#561 / #555)
    static func mainNightGroup(_ sessions: [CachedSleepSession],
                               habitualMidsleepSec: Int? = nil) -> [CachedSleepSession] {
        guard let idx = SleepStageTotals.mainNightGroupIndices(
            sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec) else { return [] }
        return idx.map { sessions[$0] }.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
    }

    /// Actual asleep minutes in blocks outside a day's canonical main-night group. The Repository's
    /// all-session union has already removed cross-namespace duplicates; this helper only applies the
    /// same main-vs-nap classification the hero uses and decodes persisted stages. A stage-less nap
    /// contributes nothing rather than substituting its in-bed window. Mirrors Android
    /// `napSleepMinutesByDay`.
    static func napSleepMinutes(_ sessions: [CachedSleepSession],
                                habitualMidsleepSec: Int? = nil) -> Double {
        let mainStarts = Set(mainNightGroup(sessions, habitualMidsleepSec: habitualMidsleepSec)
            .map { $0.startTs })
        return sessions
            .filter { !mainStarts.contains($0.startTs) }
            .reduce(0) { total, nap in
                total + decodedAsleepMinutes(nap.stagesJSON, effectiveStartTs: nap.effectiveStartTs)
            }
    }

    /// The day's main-night bridged SPAN (onset → wake), the same window `mainNightGroup` bridges into
    /// one continuous night. The ONE canonical bed/wake read every glance screen (Coupled, Today's HR
    /// band) should show — never a screen-local "freshest" or "longest single block" heuristic, which
    /// can silently disagree with each other and with the Sleep tab hero on a night stored as more than
    /// one block (#294). nil only when `sessions` has nothing bridgeable.
    static func mainNightSpan(_ sessions: [CachedSleepSession],
                              habitualMidsleepSec: Int? = nil) -> (start: Int, end: Int)? {
        let group = mainNightGroup(sessions, habitualMidsleepSec: habitualMidsleepSec)
        guard let first = group.first, let last = group.last else { return nil }
        return (first.effectiveStartTs, last.endTs)
    }

    /// Classify a block as a nap: it's a nap exactly when it is NOT the day's chosen main block. Derived
    /// from the pick (never an independent onset/duration gate), so the label can't contradict the
    /// selection — the contradiction the audit flagged. The main block is never a nap. (#518/#547)
    static func isNap(_ s: CachedSleepSession, main: CachedSleepSession?) -> Bool {
        guard let main else { return false }
        return s.startTs != main.startTs
    }

    // MARK: - Why-this-is-your-main-sleep explainer (COMPONENT 1, spec 2026-06-20)

    /// The verbatim reason copy for the displayed night, with {DUR} filled as "Xh Ym" from the chosen
    /// block's asleep duration — driven entirely by the foundation `MainNightReason`, so the explainer
    /// states exactly what the selector decided (never a re-derived guess). Resolved over the day's blocks
    /// via the same `mainNightSelection` API the analytics pick uses, with the SAME learned habitual the
    /// hero used, so the words match the block the hero shows. nil only when the day has no blocks. (C1)
    private func mainSleepReasonText(_ night: Night) -> String? {
        guard let sel = SleepStageTotals.mainNightSelection(
            night.sourceBlocks.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: SleepView.tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec) else { return nil }
        let dur = durationText(sel.asleepMinutes)
        switch sel.reason {
        case .onlyBlock:
            return String(localized: "This is your only sleep block today.")
        case .longest:
            return String(localized: "Picked as your main sleep because it was your longest block (\(dur)).")
        case .longestNearUsual:
            return String(localized: "Picked as your main sleep because it was your longest block (\(dur)), near your usual bedtime.")
        case .alignedToUsual:
            return String(localized: "Picked as your main sleep because it started near your usual sleep time.")
        }
    }

    // `mergeDay` / `nightOnsetTs` / the fragment-level `isPreOnsetAwakeStub(_:)` moved to
    // SleepModel.swift (pure statics reused by the builder and the ◀/▶ nav). The pure rule statics and
    // tuning constants below stay here — they are the shared source of truth reused by tests and by
    // those moved helpers.

    /// Longest a leading block can be and still be treated as a spurious pre-sleep awake stub (lying in bed
    /// before sleep). Generous (a few hours) because the reporter's stub ran 21:41 → 00:27 — ~2h45m of
    /// pre-sleep awake — so a tight cap missed it (#736). The real guard against swallowing a genuine first
    /// sleep fragment is `preOnsetStubAsleepMaxMin`: a stub must be essentially SLEEPLESS, which a real sleep
    /// block never is. The cap only stops a pathological all-day awake block from being silently dropped.
    static let preOnsetStubMaxMin: Double = 240
    /// Most asleep minutes a fragment can carry and still count as a (sleepless) pre-onset awake stub. A real
    /// first sleep fragment of a biphasic night carries far more, so it's never mistaken for a stub. (#736)
    static let preOnsetStubAsleepMaxMin: Double = 3
    /// A leading pre-onset fragment carrying SOME sleep is still spurious when it is minor RELATIVE to the
    /// night's main block: its asleep minutes are below this fraction of the largest fragment's. A genuine
    /// biphasic first sleep is comparable to the main block (well above this) and is kept; only a small stray
    /// lead is dropped. Extends the essentially-sleepless `preOnsetStubAsleepMaxMin` rule (#736), which missed
    /// a lead carrying a few minutes more than 3. Mirrors Android PRE_ONSET_STUB_MINOR_FRAC. (#259)
    static let preOnsetStubMinorFrac: Double = 0.15

    /// Absolute floor (ASLEEP minutes) under the #259 relative "minor lead" test: a leading fragment that
    /// carries at least this much real sleep is a genuine first sleep — a real sleep episode — and is NEVER
    /// a spurious pre-onset lead, however large the main block is. Without it a long main sleep inflates the
    /// 15% relative bar (a 6h night → ~54 min) so a genuine ~34-min first sleep was swallowed and the shown
    /// bedtime jumped hours late, hiding the real onset the bridged night (and the Health write-back, #364)
    /// already spans. 20 min ≈ the shortest standalone sleep episode; below it a handful of asleep minutes
    /// beside a long night is a stray lead. Mirrors Android PRE_ONSET_STUB_MINOR_ASLEEP_FLOOR_MIN.
    /// (bridged-night headline: a real 2026-07-14 12:16 first sleep hidden behind the 1:29 main block)
    static let preOnsetStubMinorAsleepFloorMin: Double = 20

    /// Pure stub test on a fragment's span + asleep minutes, so the rule is unit-testable without decoding
    /// JSON or building a view. Spurious when BRIEF and EITHER essentially sleepless OR minor relative to the
    /// main block (`refAsleepMin`, the group's largest asleep span): asleep below `preOnsetStubMinorFrac` of
    /// it AND below the absolute `preOnsetStubMinorAsleepFloorMin` real-sleep-episode floor. `refAsleepMin`
    /// defaults to 0 (relative test off) so existing callers/tests are byte-identical. (#736 / #259)
    static func isPreOnsetAwakeStub(spanMin: Double, asleepMin: Double, refAsleepMin: Double = 0) -> Bool {
        guard spanMin <= preOnsetStubMaxMin else { return false }
        if asleepMin <= preOnsetStubAsleepMaxMin { return true }
        // #259 relative "minor lead" test, floored: a real sleep episode (>= the floor) is never a stray
        // lead, so a long main block can't inflate the 15% bar past a genuine short first sleep.
        return refAsleepMin > 0
            && asleepMin < preOnsetStubMinorFrac * refAsleepMin
            && asleepMin < preOnsetStubMinorAsleepFloorMin
    }

    /// The index into an ascending-by-onset group whose fragment supplies the DISPLAYED bedtime: the first
    /// fragment that is NOT a spurious leading pre-onset awake stub, falling back to 0 when every fragment is
    /// stub-like. Pure mirror of `nightOnsetTs`'s walk, driven by per-fragment (spanMin, asleepMin) so a
    /// golden test can pin the #736 behaviour without view internals. (#736)
    static func nightOnsetIndex(spansMin: [Double], asleepsMin: [Double]) -> Int {
        let refAsleepMin = asleepsMin.max() ?? 0
        for i in spansMin.indices {
            let asleep = i < asleepsMin.count ? asleepsMin[i] : 0
            if !isPreOnsetAwakeStub(spanMin: spansMin[i], asleepMin: asleep, refAsleepMin: refAsleepMin) { return i }
        }
        return 0
    }

    /// The real stored blocks composing the day at `offset` (for the stage-less stub Night, so its edit
    /// affordance still targets a real row). Empty when out of range.
    private func dayBlocks(at offset: Int) -> [CachedSleepSession] {
        let days = navDays
        return offset >= 0 && offset < days.count ? days[offset] : []
    }

    /// The merged Night for the DAY `offset` stops back from the most recent (0 = last night). Backs the
    /// hero's ◀/▶ navigation via the `navNight` cache — a thin wrapper over the shared
    /// `SleepModel.decodedNight`, which JSON-decodes, so it only runs from the builder and the onChange
    /// handlers, never per render. (#160, #170)
    private func decodedNight(at offset: Int) -> Night? {
        SleepModel.decodedNight(at: offset, navDays: navDays,
                                habitualMidsleepSec: habitualMidsleepSec, motionByStart: motionByStart)
    }

    /// A synthetic session for the DAY `offset` stops back, spanning the MAIN block's window (not the
    /// whole day), for the honest no-stage-data header when the day's blocks don't decode to usable
    /// stages. Using the main block (#518) keeps the stub header on the real night rather than a
    /// 1 AM→5 PM overnight+nap span. (#160, #170)
    private func sessionRow(at offset: Int) -> CachedSleepSession? {
        SleepView.stubDaySession(dayBlocks(at: offset), habitualMidsleepSec: habitualMidsleepSec)
    }

    /// The stage-less stub SESSION for a day whose blocks decode to no usable sleep: the MAIN
    /// block's effective window (the same pick `sessionRow` always made), falling back to the day's
    /// first block so a day with ANY stored block renders a header. Static and pure so the #940
    /// no-blank rule is unit-testable without view internals (SleepPhantomNightFallbackTests): as
    /// long as a day has a block, the tab has something honest to show and `buildModel` never
    /// collapses the whole screen to the first-run empty state. nil only for an empty day.
    static func stubDaySession(_ blocks: [CachedSleepSession],
                               habitualMidsleepSec: Int? = nil) -> CachedSleepSession? {
        guard let main = mainNightSession(blocks, habitualMidsleepSec: habitualMidsleepSec) ?? blocks.first
        else { return nil }
        return CachedSleepSession(startTs: main.effectiveStartTs, endTs: main.endTs,
                                  efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
    }

    // The typical/need values, the per-tile `Metric` series (performance / efficiency / consistency /
    // hoursVsNeeded / restorative / respiratory / sleepDebt), the `napSleepMinutesByDay` credit map,
    // `durationTrendPoints`, and the `mean` helper moved to SleepModel.swift as pure statics over
    // explicit inputs. `buildModel()` calls them via `SleepModel.build(_:)`; the renderers read the
    // resulting `SleepModel` fields.


    // MARK: - Empty / sparse states

    @ViewBuilder
    private var emptyState: some View {
        SleepFreshnessNote(latestWakeTs: nil)
        if repo.loaded {
            ComingSoon(what: "No nights here yet. Import your WHOOP export in Data Sources to see every night, your sleep stages and trends straight away. Or open Intelligence to see last night computed from the strap after you wear it to bed.")
        } else {
            ComingSoon(what: "Loading your sleep history…")
        }
    }


    /// Hero chart slot for a NAVIGATED session with no decodable stages — honest about the
    /// gap instead of rendering the latest night under a navigated label. (#160)
    private var noStagePlaceholder: some View {
        Text("No stage data recorded for this night.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(NoopPanelSurface(tint: StrandPalette.restColor, cornerRadius: 12))
    }

    // MARK: - Formatting helpers

    // The metric-grid tile formatters (`pctValue` / `rrValue` / `vsTypical` / `debtCaption` / `debtColor`)
    // moved to `NightDetailCard` with the grid; they had no other caller in SleepView.

    // The Sleep-debt ledger formatters (`debtHeadline` / `debtTag` / `debtRead` / `debtBalanceColor` /
    // `debtSigned`) moved to `SleepDebtLedgerCard` with the card; they had no other caller in SleepView.

    private func efficiencyText(_ night: Night) -> String {
        let e = efficiencyPct(night)
        return e.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    /// Efficiency in percent. Prefer the stored session value, else asleep / time-in-bed.
    private func efficiencyPct(_ night: Night) -> Double? {
        if let stored = night.session.efficiency ?? repo.today?.efficiency {
            return stored <= 1.0 ? stored * 100 : stored
        }
        let bed = night.timeInBed
        guard bed > 0 else { return nil }
        return Swift.min(100, night.stages.asleep / bed * 100)
    }

    private func durationText(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return String(localized: "\(m)m") }
        return String(localized: "\(m / 60)h \(m % 60)m")
    }

    // The metric-grid `spark(_:)` sparkline helper moved to `NightDetailCard` with the grid.

    // MARK: - Stage decoding

    /// Asleep minutes decoded from a stored `stagesJSON` in EITHER of the two formats that exist in the
    /// DB: on-device COMPUTED nights store a SEGMENT ARRAY `[{"start":epoch,"end":epoch,"stage":…}]`
    /// (`AnalyticsEngine.encodeStages`); imported nights store a dict of MINUTES
    /// `{"light","deep","rem","awake"}`. The displayed-onset stub test (`nightOnsetTs` /
    /// `isPreOnsetAwakeStub`) MUST read asleep minutes format-agnostically: it previously used the
    /// dict-only `decodeStages`, which returns nil for a computed night's segment array, so every
    /// fragment of an on-device night read as 0 asleep minutes — a real ~54-min first sleep tripped the
    /// "essentially sleepless stub" branch and the shown bedtime jumped from the true 12:16 onset to the
    /// 1:29 main block, bypassing the #259 real-sleep-episode floor entirely (the 2026-07-14 night).
    /// `effectiveStartTs` threads the fragment's effective onset into the segment decode's #259
    /// pre-onset trim. Internal (not private) so the golden test pins the DECODE PATH itself, not a
    /// pre-computed minute count. Android twin: SleepScreen's onset stub-test caller needs the same
    /// both-format decode.
    static func decodedAsleepMinutes(_ json: String?, effectiveStartTs: Int) -> Double {
        decodeStages(json)?.asleep
            ?? decodeSegments(json, sessionStart: effectiveStartTs)?.stages.asleep
            ?? 0
    }

    /// Decode the imported stagesJSON dict of MINUTES {"light","deep","rem","awake"}.
    /// Internal (not private) so `SleepModel.mergeDay` (SleepModel.swift) can call it.
    static func decodeStages(_ json: String?) -> Stages? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        func val(_ key: String) -> Double {
            if let n = dict[key] as? NSNumber { return n.doubleValue }
            if let d = dict[key] as? Double { return d }
            if let i = dict[key] as? Int { return Double(i) }
            return 0
        }
        let s = Stages(awake: val("awake"), light: val("light"),
                       deep: val("deep"), rem: val("rem"))
        return s.total > 0 ? s : nil
    }

    /// Decode the COMPUTED stagesJSON segment array [{"start":epoch,"end":epoch,"stage":"wake"|
    /// "light"|"deep"|"rem"}] into stage totals plus the real timeline (seconds relative to the
    /// session start, the Hypnogram's domain). The on-device SleepStager calls awake "wake". (#77)
    /// Internal (not private) so `SleepModel.mergeDay` (SleepModel.swift) can call it.
    static func decodeSegments(
        _ json: String?, sessionStart: Int
    ) -> (stages: Stages, intervals: [SleepInterval])? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !arr.isEmpty else { return nil }
        var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        var intervals: [SleepInterval] = []
        for seg in arr {
            guard let rawStart = (seg["start"] as? NSNumber)?.intValue,
                  let end = (seg["end"] as? NSNumber)?.intValue,
                  let name = seg["stage"] as? String else { continue }
            // #259: trim each segment to the effective onset (`sessionStart`) so a hand-edited bedtime the
            // raw was too sparse to re-stage (WHOOP 4.0) can't sum pre-onset stages past time-in-bed — nor
            // draw bars before the onset. No-op when segments already start at/after it (the common case).
            let start = max(rawStart, sessionStart)
            guard end > start else { continue }
            let minutes = Double(end - start) / 60.0
            let stage: SleepStage
            switch name {
            case "wake", "awake": stage = .awake; stages.awake += minutes
            case "light": stage = .light; stages.light += minutes
            case "deep": stage = .deep; stages.deep += minutes
            case "rem": stage = .rem; stages.rem += minutes
            default: continue
            }
            intervals.append(SleepInterval(
                stage: stage,
                start: TimeInterval(start - sessionStart),
                end: TimeInterval(end - sessionStart)))
        }
        return stages.total > 0 ? (stages, intervals) : nil
    }

}

// MARK: - Live-observing leaf subviews (scroll-stutter isolation)
//
// SleepView itself does NOT observe `LiveState` (a connected strap publishes at ~1 Hz, which would
// re-evaluate the heavy Sleep body on every tick). The small leaves below each hold their OWN
// `@EnvironmentObject var live` (or `AppModel`), so a live tick re-renders only that leaf — never the
// stage chart, the metric grid or the trends (mirrors the Today leaf-scoping pattern).

/// The "going to sleep / I'm awake" sleep-mark card (#461, Phase 1). Tapping logs a timestamped mark —
/// persisted to the `sleep_mark` metric series AND appended to the shareable strap log — then confirms
/// with a haptic and a transient line. LOGGING ONLY: a mark never touches the sleep detector or the
/// night boundaries. Owns `live` (it appends to the strap log) + `repo` (the metric-series write) and
/// the `lastMark` confirmation state, so its strap-log write keeps working without SleepView observing.
/// Lives in the Sleep tab but is also hostable in Today (#today-hosted-cards), so it is `internal` and
/// self-contained — it reads only the shared `repo`/`live` environment objects, both present on Today too.
struct SleepMarkCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState

    /// The most recent sleep-mark the user tapped, shown as a transient confirmation line under the
    /// two buttons. Drives the SwiftUI haptic landing too. LOGGING-ONLY. (#461)
    @State private var lastMark: SleepMark?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoopSectionTitle("Sleep marks", captionKey: "Tap to log")
                .padding(.bottom, 12)
            HStack(spacing: 10) {
                markButton("Going to sleep", caption: "Marks lights-out", icon: "moon") { logMark(.bedtime) }
                    .accessibilityLabel("Log going to sleep")
                markButton("I'm awake", caption: "Marks wake-up", icon: "sun-horizon") { logMark(.wake) }
                    .accessibilityLabel("Log waking up")
            }
            Group {
                if let lastMark {
                    Text(lastMark.confirmation)
                        .transition(.opacity)
                        .accessibilityLabel(lastMark.confirmation)
                } else {
                    Text("Tap when you're heading to bed or when you wake. Each tap is logged with the time. It doesn't change tonight's detected sleep.")
                }
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.top, 10)
        }
        // A success haptic lands when a new mark is captured (value-driven, not per-tap), matching the
        // app's sparse tactile vocabulary. No-op on macOS.
        .strandHaptic(.success, trigger: lastMark?.tsMs ?? 0)
    }

    /// A `.mk` ghost button: icon, label and a small caption, 58 pt tall.
    private func markButton(_ title: LocalizedStringKey, caption: LocalizedStringKey, icon: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                PhIcon(icon, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(StrandFont.book(15, relativeTo: .body)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(caption).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(NoopVisualStyle.inset))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Persist + log a tapped mark. Optimistically shows the confirmation immediately, fires the
    /// haptic via `lastMark`, appends the human-readable strap-log line, then writes the metric-series
    /// row through the repo's live store handle (no new Repository API, no schema change). The write is
    /// idempotent by (deviceId, day, key). (#461)
    private func logMark(_ type: SleepMarkType) {
        let mark = SleepMark(type: type)
        withAnimation(.easeOut(duration: 0.2)) { lastMark = mark }
        // The shareable strap log is the human-readable surface that lands in a debug export.
        live.append(log: mark.logLine)
        Task {
            guard let store = await repo.storeHandle() else { return }
            try? await store.upsertMetricSeries([mark.metricPoint], deviceId: repo.deviceId)
        }
    }
}
/// The "Syncing strap history…" note, shown only while a historical offload is running (#77). Owns the
/// `LiveState` observation so the chunk count ticks without re-rendering the rest of the Sleep screen.
enum SleepFreshnessStatus: Equatable {
    case syncing, calculating, syncFailed, awaitingSync, notDetected
}

/// Pure priority ladder behind the Sleep status banner. "Missing" is deliberately held until morning so
/// opening Sleep during the night does not claim a still-in-progress night was missed.
func resolveSleepFreshness(hasCurrentNight: Bool, morningReady: Bool, syncing: Bool,
                           calculating: Bool, syncedSinceDayStart: Bool,
                           syncFailed: Bool) -> SleepFreshnessStatus? {
    if syncing { return .syncing }
    // #2108: a night already in hand outranks .calculating. It used to sit below, so `hasCurrentNight`
    // could only silence the missing-night states and a finished night was structurally unable to
    // silence this one: the banner said "detecting and staging the night now" directly above that same
    // night scored, timed and staged on screen. A note that contradicts the content beside it is worse
    // than no note, and one that is always on is read by nobody the day it matters. .syncing stays
    // above, because data still arriving can genuinely change what is shown.
    if hasCurrentNight { return nil }
    if calculating { return .calculating }
    if !morningReady { return nil }
    if syncFailed { return .syncFailed }
    return syncedSinceDayStart ? .notDetected : .awaitingSync
}

/// The freshness of the expected current night, resolved from the live sync state. One resolver for the
/// hero's waiting state and the "What happens next" list, so the two can never describe different states.
@MainActor
enum SleepFreshness {
    static func status(live: LiveState, intelligence: IntelligenceEngine, latestWakeTs: Int?) -> SleepFreshnessStatus? {
        #if DEBUG
        // Screenshot harness: `--demo-sleep-waiting syncing|calculating|failed|awaiting|missing`.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--demo-sleep-waiting"), i + 1 < args.count {
            switch args[i + 1] {
            case "syncing": return .syncing
            case "calculating": return .calculating
            case "failed": return .syncFailed
            case "missing": return .notDetected
            default: return .awaitingSync
            }
        }
        #endif
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.startOfDay(for: now)
        let current = latestWakeTs.map {
            calendar.isDate(Date(timeIntervalSince1970: TimeInterval($0)), inSameDayAs: now)
        } ?? false
        // AppModel intentionally waits two quiet seconds after HISTORY_COMPLETE before starting the
        // scoring pass. Treat that debounce as calculation too; otherwise the state can flash the final
        // "wasn't detected" verdict between sync completion and `intelligence.computing` becoming true.
        let calculationQueued = live.lastSyncedAt.map {
            (0..<5).contains(now.timeIntervalSince1970 - $0)
        } ?? false
        return resolveSleepFreshness(
            hasCurrentNight: current,
            morningReady: calendar.component(.hour, from: now) >= 6,
            syncing: live.backfilling,
            calculating: intelligence.computing || calculationQueued,
            syncedSinceDayStart: (live.lastSyncedAt ?? 0) >= start.timeIntervalSince1970,
            syncFailed: live.lastSyncError != nil)
    }

    /// The headline and explanation for a waiting state.
    static func copy(_ status: SleepFreshnessStatus) -> (title: LocalizedStringKey, message: LocalizedStringKey, tag: LocalizedStringKey) {
        switch status {
        case .syncing:
            return ("Waiting for last night's sleep",
                    "Your strap is sending last night's history now. Keep NOOP open near the strap.", "Syncing")
        case .calculating:
            return ("Calculating last night's sleep…",
                    "Your strap history is in. NOOP is detecting and staging the night now.", "Calculating")
        case .syncFailed:
            return ("Last night's sleep hasn't synced",
                    "The history sync stopped before it finished. Keep the strap nearby and try Sync again.", "Sync stopped")
        case .awaitingSync:
            return ("Waiting for last night's sleep",
                    "Connect the strap and sync its history. NOOP will calculate the night when the overnight data arrives.", "Waiting")
        case .notDetected:
            return ("Last night's sleep wasn't detected",
                    "Sync finished, but NOOP couldn't confidently identify a sleep window. Keep the strap connected and try Sync again; the older night below is still your latest detected sleep.", "Not found")
        }
    }
}

/// The Rest hero as a live-observing leaf: it decides between the night's score and the waiting state
/// (last night still syncing or being scored, `SleepFreshness`), so only this leaf re-renders on a live
/// tick. Runs under the status bar in the screen's one glow.
private struct SleepHeroView: View {
    struct Stat {
        var value: String
        var unit: String?
        var label: String
    }

    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var intelligence: IntelligenceEngine

    let pagerLabel: LocalizedStringKey
    let canGoOlder: Bool
    let canGoNewer: Bool
    let onOlder: () -> Void
    let onNewer: () -> Void
    let score: Double?
    let scoreWord: String?
    let source: String
    let asleepClock: String
    let sentence: String
    let stats: [Stat]
    let showsEarliestHint: Bool
    let latestWakeTs: Int?
    let isLatest: Bool

    var body: some View {
        let status = isLatest ? SleepFreshness.status(live: live, intelligence: intelligence,
                                                      latestWakeTs: latestWakeTs) : nil
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack {
                NoopIconBadge("Rest", icon: "moon-stars")
                Spacer(minLength: 8)
                NoopPill(verbatim: source, compact: true)
            }
            .padding(.top, 34)
            if let status {
                waiting(status)
            } else {
                scoreBlock
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The glow runs on up under the status bar (the scroll view's top inset).
        .background(alignment: .bottom) {
            NoopHeroSurface(glow: .sleep, bleed: true)
                .padding(.top, -90)
        }
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, -NoopMetrics.screenHPadding)
        .padding(.top, -8)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Sleep")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            NoopPager(label: Text(pagerLabel), canGoBack: canGoOlder, canGoForward: canGoNewer,
                      onBack: onOlder, onForward: onNewer)
                .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var scoreBlock: some View {
        // The tag stands on the digits' baseline, as in the frame, rather than on the line box's bottom.
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            if let score {
                NoopDotNumber("\(Int(score.rounded()))", size: 92)
                if let scoreWord {
                    NoopTag(verbatim: scoreWord).fixedSize().alignmentGuide(.lastTextBaseline) { $0[.bottom] }
                }
            } else {
                NoopDotNumber(asleepClock, unit: "h", size: 72, unitSize: 30)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(score.map { String(localized: "Sleep performance \(Int($0.rounded())) of 100, \(scoreWord ?? "")") }
                            ?? sentence)
        Text(verbatim: sentence)
            .font(StrandFont.light(19, relativeTo: .title3))
            .foregroundStyle(StrandPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 16)
        HStack(alignment: .top, spacing: 0) {
            ForEach(stats.indices, id: \.self) { i in
                TrendsHeroStat(value: stats[i].value, unit: stats[i].unit, caption: stats[i].label)
            }
        }
        .padding(.top, 20)
        if showsEarliestHint {
            Text("No earlier night stored yet. Earlier nights sync in the morning.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.top, 14)
        }
    }

    private var waitingDots: some View {
        Text(verbatim: "••:••")
            .font(StrandFont.dot(44))
            .tracking(StrandFont.dotTracking(44))
            .foregroundStyle(StrandPalette.textPrimary.opacity(0.7))
            .fixedSize()
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func waiting(_ status: SleepFreshnessStatus) -> some View {
        let copy = SleepFreshness.copy(status)
        // A long state tag ("Synchronisierung gestoppt") drops under the placeholder instead of truncating.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 14) {
                waitingDots
                NoopTag(copy.tag, size: 13).fixedSize().padding(.bottom, 6)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 12) {
                waitingDots
                NoopTag(copy.tag, size: 13).fixedSize()
            }
        }
        .padding(.top, 26)
        Text(copy.title)
            .font(StrandFont.light(19, relativeTo: .title3))
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.top, 18)
        Text(copy.message)
            .font(StrandFont.light(14))
            .foregroundStyle(StrandPalette.textPrimary.opacity(0.72))
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
        // Honest progress: the chunks pulled so far, never a percent — the total pending is unknowable
        // from the protocol, so a determinate bar would lie (#77).
        if status == .syncing {
            Text("\(live.syncChunksThisSession) chunks pulled")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.top, 14)
        }
    }
}

/// "What happens next" while last night is still on its way: the three states a night passes through,
/// the current one tagged NOW, and which night the cards below describe meanwhile. Nothing at all once
/// the night is in. A live-observing leaf for the same reason as the hero.
private struct SleepWaitingSection: View {
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var intelligence: IntelligenceEngine
    let latestWakeTs: Int?
    let isLatest: Bool
    let previousNight: String

    var body: some View {
        if isLatest, let status = SleepFreshness.status(live: live, intelligence: intelligence,
                                                       latestWakeTs: latestWakeTs) {
            NoopSectionTitle("What happens next", captionKey: "3 states")
            NoopList {
                stateRow(icon: "arrows-clockwise", title: "Waiting for last night's sleep",
                         caption: "The strap still holds the night. Shown until it syncs.",
                         isNow: status == .syncing || status == .awaitingSync || status == .syncFailed)
                stateRow(icon: "cpu", title: "Calculating last night's sleep…",
                         caption: "The night is on this device. NOOP is detecting and staging it.",
                         isNow: status == .calculating)
                stateRow(icon: "question", title: "Last night's sleep wasn't detected",
                         caption: "Shown when the sync finished but no sleep window could be identified.",
                         isNow: status == .notDetected)
            }
            NoopSectionTitle("Meanwhile", captionKey: "Previous night")
            NoopList {
                NoopRow(title: Text("Your latest detected night"), caption: Text(verbatim: previousNight),
                        icon: "moon") { EmptyView() }
            }
        }
    }

    private func stateRow(icon: String, title: LocalizedStringKey, caption: LocalizedStringKey,
                          isNow: Bool) -> some View {
        NoopRow(title, caption: caption, icon: icon) {
            if isNow { NoopTag("Now", size: 11) }
        }
        .opacity(isNow ? 1 : 0.75)
    }
}

/// A line break between two styled runs of one `Text`.
private let sleepLineBreak = "\n"

/// The waiting state as a plain note, for the first-run empty screen (no older night to show beneath it).
private struct SleepFreshnessNote: View {
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var intelligence: IntelligenceEngine
    let latestWakeTs: Int?

    var body: some View {
        if let status = SleepFreshness.status(live: live, intelligence: intelligence, latestWakeTs: latestWakeTs) {
            if status == .syncing {
                SyncingHistoryNote(chunks: live.syncChunksThisSession)
            } else {
                let copy = SleepFreshness.copy(status)
                NoopCard {
                    NoopInsightRow(text: Text(copy.title).foregroundColor(StrandPalette.textPrimary)
                                   + Text(verbatim: sleepLineBreak) + Text(copy.message), icon: "moon-stars")
                }
            }
        }
    }
}

/// The direct route to the one alarm screen, available even before a night is recorded. Its caption
/// states tonight's wind-down time and the strap alarm's next buzz through `AlarmReadout` — the SAME
/// resolver the Alarms screen prints — so the two can never disagree. A leaf, because the strap-alarm
/// gate reads `AppModel`, which publishes at 1 Hz.
private struct SleepAlarmsRow: View {
    @EnvironmentObject private var router: NavRouter
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var behavior: BehaviorStore

    private var caption: String {
        var parts: [String] = []
        if let windDown = AlarmReadout.windDownMinute {
            parts.append(String(localized: "Wind down \(AlarmReadout.clock(windDown))"))
        }
        if let next = AlarmReadout.nextStrapAlarm(enabled: behavior.smartAlarmEnabled,
                                                  minutes: behavior.smartAlarmMinutes,
                                                  weekdays: behavior.smartAlarmWeekdays,
                                                  overrides: WindDownNudge.perDayWakeOverrides,
                                                  whoop5Detected: model.whoop5Detected) {
            parts.append(String(localized: "strap buzz \(AlarmReadout.shortStamp(next))"))
        }
        return parts.isEmpty ? String(localized: "Wind-down reminder and strap wake-alarm")
                             : parts.joined(separator: " · ")
    }

    var body: some View {
        NoopList {
            Button { router.openAlarms() } label: {
                NoopRow(title: Text("Alarms"), caption: Text(verbatim: caption), icon: "alarm", chevron: true) {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
        }
    }
}
// MARK: - Local value types

/// Cheap, Equatable fingerprint of the repo inputs SleepView derives from. Two snapshots are
/// equal iff the data the screen reads is unchanged, so the heavy `SleepModel` rebuild is
/// skipped on the many `body` re-evaluations that don't touch sleep data.
private struct SleepInputKey: Equatable {
    let loaded: Bool
    let daysCount: Int
    let sleepsCount: Int
    let firstDay: String?
    let lastDay: String?
    /// Newest day row (Equatable) — catches in-place edits to the latest day's values.
    let lastDayUpdated: DailyMetric?
    /// Newest sleep session (Equatable) — catches a re-import of the latest night.
    let lastSleep: CachedSleepSession?
    /// Bumped on every Repository.refresh — catches a re-import that changes only the
    /// imported metricSeries figures (importedSleep) without touching days/sleeps.
    let refreshSeq: Int
}

// SleepModel / Night / Stages and the pure `SleepModel.build(_:)` derivation pipeline now live in
// SleepModel.swift, so the Today host can build the same model without a SleepView instance.

// MARK: - Wake-time editor

/// Identifies the night being edited for `.sheet(item:)`. A night's `startTs` is its stable natural
/// key (wake-time edits never move it), so it doubles as the sheet identity.
/// The transient UNDO banner state after a suppressing delete (#65). `identityStart` is the immutable
/// detected key so a stale auto-dismiss task can tell whether it still owns the current banner;
/// `displayStart` is the effective (shown) onset for the message clock.
private struct SleepUndoBanner {
    let snapshot: SleepDeletionSnapshot
    let identityStart: Int
    let displayStart: Int
    let windowEnd: Int
}

private struct WakeEdit: Identifiable {
    let detectedStartTs: Int   // immutable detected key the edit writes against
    let bedTs: Int             // current effective onset (seeds the bed picker)
    let wakeTs: Int            // current wake (seeds the wake picker)
    let stagesJSON: String?
    /// True for a hand-edited / manually-added (nap) night. Such a delete writes NO tombstone (it is
    /// never re-detected), so the editor's delete-confirm copy must NOT promise re-detection suppression
    /// for it. Mirrors the undo-banner branch (#65 banner/confirm honesty).
    let userEdited: Bool
    var id: Int { detectedStartTs }
}

/// Seeds the "Add nap" picker (#508). A nap is short, so seed a 30-minute window anchored to the night's
/// wake (a natural place to look for a missed afternoon nap), clamped to never start before the night's
/// onset. The identity is the seed start so `.sheet(item:)` presents once per request.
private struct AddNapSeed: Identifiable {
    let bedTs: Int
    let wakeTs: Int
    var id: Int { bedTs }
    init(forNight night: Night) {
        // Anchor an hour after the night's wake; a 30-min default window the user adjusts.
        let anchor = night.session.endTs + 3_600
        self.bedTs = anchor
        self.wakeTs = anchor + 30 * 60
    }
}

/// A sheet to hand-correct a night's bed (onset) and wake (end) instants, or to add a nap. Seeds both
/// pickers with the current values, including each calendar date. Hands the chosen unix-second (bed,
/// wake) back via `onSave`. Pure presentation + a single async save — persistence lives in the repo.
private struct SleepTimeEditor: View {
    /// Editing an existing sleep, or adding a nap: the hero reads "In bed" over two clocks for an edit, and
    /// the nap's length over the day for a nap.
    enum Mode { case edit, nap }

    let onSave: (Int, Int) async -> Void
    /// Optional destructive delete (#68). Non-nil for an existing main-sleep / nap edit (the editor then
    /// shows a "Delete this sleep" button gated behind a confirmation); nil for the "Add a nap" sheet,
    /// which has nothing to delete yet.
    let onDelete: (() async -> Void)?
    private let title: LocalizedStringKey
    private let blurb: LocalizedStringKey
    private let bedLabel: LocalizedStringKey
    private let wakeLabel: LocalizedStringKey
    private let deleteLabel: LocalizedStringKey
    private let mode: Mode
    /// The detected onset, so the hero can say how far the edit moves the night from what was detected.
    private let detectedStartTs: Int?
    /// The wake the sheet opened with, for the same comparison.
    private let originalWakeTs: Int
    /// The night's RECORDED coverage (detected onset ... current wake, unix seconds) for the #940
    /// guards: a time-only bed roll past the wake auto-decrements the date, and a corrected window
    /// fully outside this range gets an explicit confirm instead of silent acceptance. nil for the
    /// "Add a nap" sheet, whose window deliberately sits outside the night (only the future-bed
    /// guard applies there).
    private let coverage: ClosedRange<Int>?
    /// True when deleting THIS session writes a re-detection tombstone (a DETECTED night). false for a
    /// userEdited/nap row, which is never re-detected, so the delete-confirm copy drops the suppression
    /// promise for it, matching the undo banner. (#65 confirm honesty.)
    private let suppressesReDetection: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var bed: Date
    @State private var wake: Date
    @State private var saving = false
    @State private var confirmingDelete = false
    /// The bed value BEFORE the in-flight picker change, so the #940 auto-correct can tell a
    /// time-only roll (same calendar day: rescue it) from a deliberate date change (respect it).
    @State private var previousBed: Date
    /// True while the #940 "no recorded data there" confirm is up; Save proceeds only on consent.
    @State private var confirmingDisjoint = false

    /// `title`/`blurb`/`bedLabel`/`wakeLabel` default to the edit-an-existing-night wording; the
    /// "Add a nap" caller (#508) overrides them. The save logic is identical either way — adding a nap
    /// is just an edit whose "existing" window is a seed. `onDelete` (#68) is the optional destructive
    /// action; `deleteLabel` lets the nap editor say "Delete this nap".
    init(bedTs: Int, wakeTs: Int,
         title: LocalizedStringKey = "Edit sleep times",
         blurb: LocalizedStringKey = "Correct when you went to bed and woke. Stages are re-derived from your data; the edit is kept through the next strap sync.",
         bedLabel: LocalizedStringKey = "Asleep",
         wakeLabel: LocalizedStringKey = "Woke",
         deleteLabel: LocalizedStringKey = "Delete this sleep",
         mode: Mode = .edit,
         detectedStartTs: Int? = nil,
         coverage: ClosedRange<Int>? = nil,
         suppressesReDetection: Bool = true,
         onSave: @escaping (Int, Int) async -> Void,
         onDelete: (() async -> Void)? = nil) {
        self.onSave = onSave
        self.onDelete = onDelete
        self.title = title; self.blurb = blurb
        self.bedLabel = bedLabel; self.wakeLabel = wakeLabel
        self.deleteLabel = deleteLabel
        self.mode = mode
        self.detectedStartTs = detectedStartTs
        self.originalWakeTs = wakeTs
        self.coverage = coverage
        self.suppressesReDetection = suppressesReDetection
        // A bed can never be seeded in the future (#940): the "Add a nap" anchor is wake+1h, which is
        // ahead of the clock right after a morning sync; clamp so the picker opens inside its bound.
        let seedBed = min(bedTs, Int(Date().timeIntervalSince1970))
        _bed = State(initialValue: Date(timeIntervalSince1970: TimeInterval(seedBed)))
        _previousBed = State(initialValue: Date(timeIntervalSince1970: TimeInterval(seedBed)))
        _wake = State(initialValue: Date(timeIntervalSince1970: TimeInterval(wakeTs)))
    }

    /// The current edit window after the same future/inverted/duration guards used by persistence.
    private var validatedWindow: (start: Int, end: Int)? {
        SleepEditGuard.clampedEditWindow(
            start: Int(bed.timeIntervalSince1970),
            end: Int(wake.timeIntervalSince1970),
            now: Int(Date().timeIntervalSince1970))
    }

    /// The single save funnel: both the direct Save and the #940 disjoint confirm land here.
    private func commit(start: Int, end: Int) {
        saving = true
        Task {
            await onSave(start, end)
            dismiss()
        }
    }

    /// Save, after #940 guard 2: a corrected window that no longer touches the night's recorded coverage
    /// has no data to stage from. Silently accepting it fabricated an all-awake phantom night; ask first.
    private func save() {
        guard let window = validatedWindow else { return }
        if let coverage, SleepEditGuard.isDisjoint(
            newStart: window.start, newEnd: window.end,
            coverageStart: coverage.lowerBound, coverageEnd: coverage.upperBound) {
            confirmingDisjoint = true
        } else {
            commit(start: window.start, end: window.end)
        }
    }

    var body: some View {
        let canSave = validatedWindow != nil
        VStack(spacing: 0) {
            NoopSheetHeader(title, doneTitle: saving ? "Saving…" : "Save", doneEnabled: canSave && !saving,
                            onCancel: { dismiss() }, onDone: { save() })
            if mode == .edit {
                Text(verbatim: nightLine)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.top, -10)
                    .padding(.bottom, 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if mode == .edit {
                        editHero
                    } else {
                        napHero
                    }
                    pickers
                    NoopInsightRow(blurb)
                        .padding(.horizontal, 4)
                        .padding(.top, 6)
                    // Destructive delete for an existing night/nap (#68), confirmation-gated so a tap can't
                    // clear a night by accident; nil for the "Add a nap" sheet (nothing to delete).
                    if onDelete != nil {
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            HStack(spacing: 8) {
                                PhIcon("trash", size: 18)
                                Text(deleteLabel).font(StrandFont.book(15))
                            }
                            .foregroundStyle(StrandPalette.statusCritical)
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(saving)
                        .accessibilityLabel(deleteLabel)
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 620)
        .background(NoopSheetBackground())
        #else
        .noopSheetPresentation(largeFirst: true)
        #endif
        // #940 guard 1: a time-only roll that lands the bed in the future, or at/after the night's
        // wake, almost always means the PREVIOUS evening (23:00 "yesterday", not tonight). Snap the
        // date back a day so the picker visibly shows the night the user meant. Pure rule + tests:
        // SleepEditGuard.autoCorrectedBed (Android twin in com.noop.analytics).
        .onChangeCompat(of: bed) { newBed in
            let corrected = SleepEditGuard.autoCorrectedBed(
                previousBed: previousBed, candidateBed: newBed,
                originalWake: coverage.map { Date(timeIntervalSince1970: TimeInterval($0.upperBound)) },
                now: Date())
            previousBed = corrected
            if corrected != newBed { bed = corrected }
        }
        // #940 guard 2's consent step. On-brand role-tagged .alert, same shape as the delete confirm.
        .alert("Move this sleep?", isPresented: $confirmingDisjoint) {
            Button("Cancel", role: .cancel) { }
            Button("Move anyway") {
                guard let window = SleepEditGuard.clampedEditWindow(
                    start: Int(bed.timeIntervalSince1970),
                    end: Int(wake.timeIntervalSince1970),
                    now: Int(Date().timeIntervalSince1970)) else { return }
                commit(start: window.start, end: window.end)
            }
        } message: {
            Text("This moves the night to a time with no recorded data. Stages can't be derived there, so it may show as empty until data covers it.")
        }
        // On-brand destructive confirm — the same role-tagged .alert DevicesView uses for "Remove this
        // device?", not a bare default. (#68 — Android parity: "Delete this sleep session?")
        .alert("Delete this sleep session?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                saving = true
                Task {
                    await onDelete?()
                    dismiss()
                }
            }
        } message: {
            // A detected night is tombstoned so it won't re-detect; a userEdited/nap row writes no
            // tombstone, so its copy drops that (false) promise. Mirrors the undo banner. (#65)
            Text(suppressesReDetection
                 ? "Removes this recorded sleep and recomputes the day without it. NOOP won't re-detect sleep in this window. You can undo for a few seconds after."
                 : "Removes this sleep and recomputes the day without it. You can undo for a few seconds after.")
        }
    }

    // MARK: Hero

    private var minutesInBed: Int { max(0, Int(wake.timeIntervalSince(bed) / 60)) }

    private func duration(_ m: Int) -> String {
        m < 60 ? String(localized: "\(m)m") : String(localized: "\(m / 60)h \(m % 60)m")
    }

    /// The hero re-renders on every picker tick, so its formatters are built once per template and locale.
    private static var formatterCache: [String: DateFormatter] = [:]

    private static func formatter(_ template: String) -> DateFormatter {
        let locale = AppLanguage.activeLocale
        let key = "\(locale.identifier)|\(template)"
        if let f = formatterCache[key] { return f }
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        formatterCache[key] = f
        return f
    }

    /// "Friday into Saturday · 2–3 Oct".
    private var nightLine: String {
        let day = Self.formatter("EEEE")
        let date = Self.formatter("dMMM")
        return String(localized: "\(day.string(from: bed)) into \(day.string(from: wake)) · \(date.string(from: bed)) – \(date.string(from: wake))")
    }

    /// How far the edit moves the night from what the strap detected: "16m earlier than detected · wake
    /// unchanged". Empty when there is nothing to compare against.
    private var shiftLine: String? {
        guard let detected = detectedStartTs else { return nil }
        let bedShift = (Int(bed.timeIntervalSince1970) - detected) / 60
        let wakeShift = (Int(wake.timeIntervalSince1970) - originalWakeTs) / 60
        let bedPart = bedShift == 0 ? String(localized: "Bedtime as detected")
            : (bedShift < 0 ? String(localized: "\(duration(-bedShift)) earlier than detected")
                            : String(localized: "\(duration(bedShift)) later than detected"))
        let wakePart = wakeShift == 0 ? String(localized: "wake unchanged")
            : (wakeShift < 0 ? String(localized: "wake \(duration(-wakeShift)) earlier")
                             : String(localized: "wake \(duration(wakeShift)) later"))
        return "\(bedPart) · \(wakePart)"
    }

    private var editHero: some View {
        NoopHeroCard(glow: .sleep, padding: 18) {
            VStack(spacing: 0) {
                HStack {
                    NoopIconBadge("In bed", icon: "moon-stars")
                    Spacer(minLength: 8)
                    Text(verbatim: duration(minutesInBed)).font(StrandFont.book(17))
                }
                HStack(spacing: 12) {
                    clockColumn(bedLabel, date: bed)
                    clockColumn(wakeLabel, date: wake)
                }
                .padding(.top, 16)
                if let shiftLine {
                    Text(verbatim: shiftLine)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .padding(.top, 14)
                }
            }
        }
    }

    /// One clock: its label and weekday over the dot-matrix time.
    private func clockColumn(_ label: LocalizedStringKey, date: Date) -> some View {
        let weekday = Self.formatter("EEE").string(from: date)
        let clock = Self.formatter("HHmm").string(from: date)
        return VStack(spacing: 14) {
            HStack {
                Text(label)
                Spacer()
                Text(verbatim: weekday)
            }
            .font(StrandFont.light(13))
            .foregroundStyle(StrandPalette.textSecondary)
            Text(verbatim: clock)
                .font(StrandFont.dot(30))
                .tracking(StrandFont.dotTracking(30))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    /// The nap hero: its length in dot-matrix and where it sits in the day (06:00 → 24:00).
    private var napHero: some View {
        let dayFmt = Self.formatter("EEEdMMM")
        let isYesterday = Calendar.current.isDateInYesterday(bed)
        let isToday = Calendar.current.isDateInToday(bed)
        let dayLabel = isToday ? String(localized: "Today · \(dayFmt.string(from: bed))")
            : (isYesterday ? String(localized: "Yesterday · \(dayFmt.string(from: bed))") : dayFmt.string(from: bed))
        return NoopHeroCard(glow: .sleep, padding: 18) {
            VStack(spacing: 0) {
                HStack {
                    NoopIconBadge("Nap", icon: "cloud-moon")
                    Spacer(minLength: 8)
                    NoopPill(verbatim: dayLabel, compact: true)
                }
                NoopDotNumber("\(minutesInBed)", unit: "m", size: 72, unitSize: 28)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                napDayStrip.padding(.top, 24)
            }
        }
    }

    /// The nap's window on a 06:00 → 24:00 track.
    private var napDayStrip: some View {
        let cal = Calendar.current
        let dayStart = cal.date(bySettingHour: 6, minute: 0, second: 0, of: bed) ?? bed
        let span: TimeInterval = 18 * 3600
        let f0 = min(max(bed.timeIntervalSince(dayStart) / span, 0), 1)
        let f1 = min(max(wake.timeIntervalSince(dayStart) / span, 0), 1)
        return VStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12)).frame(height: 10)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white)
                        .frame(width: max(8, w * CGFloat(f1 - f0)), height: 18)
                        .shadow(color: .white.opacity(0.6), radius: 6)
                        .offset(x: w * CGFloat(f0))
                }
                .frame(height: 18)
            }
            .frame(height: 18)
            HStack {
                ForEach(["06:00", "12:00", "18:00", "24:00"], id: \.self) { t in
                    Text(verbatim: t)
                    if t != "24:00" { Spacer() }
                }
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityHidden(true)
    }

    // MARK: Pickers

    private var pickers: some View {
        NoopList {
            pickerRow(bedLabel, icon: "moon", selection: $bed)
            pickerRow(wakeLabel, icon: "sun-horizon", selection: $wake)
        }
    }

    /// Both endpoints are bounded to the PAST (#940): a sleep can't start or end in the future, and an
    /// unbounded picker let a cross-midnight time roll land on the coming evening. Date and time are both
    /// editable so corrections preserve the exact endpoint the user picked (#970).
    private func pickerRow(_ label: LocalizedStringKey, icon: String, selection: Binding<Date>) -> some View {
        HStack(spacing: 10) {
            PhIcon(icon, size: 18).foregroundStyle(StrandPalette.textSecondary)
            // The date + time pills keep their size; a long label ("Nickerchen begonnen") wraps beside
            // them instead of pushing the sheet wider than the screen.
            Text(label).font(StrandFont.book(15)).foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            DatePicker(label, selection: selection, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(StrandPalette.textPrimary)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Sleep") {
    let repo = Repository.previewSleep()
    return SleepView()
        .environmentObject(repo)
        .environmentObject(LiveState())
        .environmentObject(AppModel())
        .environmentObject(IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: "preview"))
        .frame(width: 980, height: 1180)
        .preferredColorScheme(.dark)
}

@MainActor
private extension Repository {
    /// Sample repository populated with imported-style nights for previews.
    static func previewSleep() -> Repository {
        let repo = Repository(deviceId: "preview")
        let cal = Calendar.current
        let now = Date()

        var days: [DailyMetric] = []
        var sleeps: [CachedSleepSession] = []
        let fmt: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()

        for i in (0..<30).reversed() {
            let date = cal.date(byAdding: .day, value: -i, to: now)!
            let jitter = Double((i * 23) % 11) - 5
            let light = 210.0 + jitter
            let deep = 80.0 + jitter * 0.5
            let rem = 95.0 + jitter * 0.7
            let awake = 25.0 + Double((i * 7) % 9)
            let asleep = light + deep + rem
            let stagesJSON = "{\"light\":\(light),\"deep\":\(deep),\"rem\":\(rem),\"awake\":\(awake)}"

            days.append(DailyMetric(
                day: fmt.string(from: date),
                totalSleepMin: asleep,
                efficiency: 88 + jitter * 0.3,
                deepMin: deep, remMin: rem, lightMin: light,
                disturbances: Int(awake / 6), restingHr: 50 + (i % 4),
                avgHrv: 65 - Double(i % 5), recovery: 60 + jitter,
                strain: 10 + Double(i % 6), exerciseCount: i % 2,
                spo2Pct: 96, skinTempDevC: 33.4, respRateBpm: 14.6 + jitter * 0.1))

            var onset = cal.date(bySettingHour: 22, minute: 50 + Int(jitter), second: 0, of: date) ?? date
            onset = cal.date(byAdding: .day, value: -1, to: onset) ?? onset
            let end = onset.addingTimeInterval((asleep + awake) * 60)
            sleeps.append(CachedSleepSession(
                startTs: Int(onset.timeIntervalSince1970),
                endTs: Int(end.timeIntervalSince1970),
                efficiency: 88 + jitter * 0.3,
                restingHr: 50 + (i % 4),
                avgHrv: 65 - Double(i % 5),
                stagesJSON: stagesJSON))
        }

        repo.days = days
        repo.sleeps = sleeps
        repo.loaded = true
        return repo
    }
}
#endif
