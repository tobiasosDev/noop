# Home (TodayView) Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Home screen as a compact WHOOP-style dashboard (spec: `docs/superpowers/specs/2026-06-10-home-redesign-design.md`, layout B): triple-ring hero, live HR strip, monitor 2-up, goals chips, today-only activities timeline.

**Architecture:** New pure logic (sleep performance %, today-activity merge) goes in `StrandAnalytics` with unit tests. New `MiniRing` + `WrapLayout` view components go in `StrandDesign`. Cross-platform ring navigation uses a new `openScreen` SwiftUI environment closure (shared `HomeDestination` enum; each shell — macOS sidebar, iOS tabs — supplies its own handler). `TodayView.swift` is rebuilt around the existing engines (`ReadinessEngine`, `StrainTarget`, `DayStrain`, `GoalProgress`) — no store/schema changes.

**Tech Stack:** SwiftUI (macOS 13 / iOS 17), SPM local packages, XcodeGen, xcodebuild, simulator screenshot harness (`NOOP_SCREEN`).

**Platform notes (critical):**
- The iOS target `NOOPiOS` excludes `Strand/App/RootView.swift` (where `NavItem` lives) and `Strand/App/StrandApp.swift`. Anything referenced from `TodayView.swift` must live in files INCLUDED in both targets. All other `Strand/App/*.swift` files ARE shared.
- `#if DEBUG` does NOT compile in this XcodeGen setup — use `#if os(...)` / `#if targetEnvironment(simulator)` (existing previews use `#if DEBUG` only inside packages; app-target files must avoid relying on it for behavior).
- If `git` output looks garbled, prefix with `rtk proxy`.
- All new user-facing strings: `LocalizedStringKey` literals (String Catalog auto-extraction). Data-model strings via `String(localized:)`.

**Build / test commands:**
- Package tests: `swift test --package-path Packages/StrandAnalytics`
- Generate project: `xcodegen generate`
- macOS build: `xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug build -quiet`
- iOS sim build: `xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build -quiet` (if that device name is missing, pick one from `xcrun simctl list devices available`)

---

### Task 1: `SleepNeed.performancePct` (StrandAnalytics)

**Files:**
- Modify: `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepNeed.swift`
- Test: `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/SleepNeedTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to the existing `SleepNeedTests` test class:

```swift
    // MARK: performancePct

    func testPerformancePctNilWhenNoSleep() {
        XCTAssertNil(SleepNeed.performancePct(needMin: 450, asleepMin: nil))
        XCTAssertNil(SleepNeed.performancePct(needMin: 450, asleepMin: 0))
    }

    func testPerformancePctComputesRatio() {
        XCTAssertEqual(SleepNeed.performancePct(needMin: 450, asleepMin: 360)!, 80, accuracy: 0.01)
    }

    func testPerformancePctCapsAt100() {
        XCTAssertEqual(SleepNeed.performancePct(needMin: 450, asleepMin: 600)!, 100, accuracy: 0.01)
    }

    func testPerformancePctNilWhenNeedZero() {
        XCTAssertNil(SleepNeed.performancePct(needMin: 0, asleepMin: 400))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/StrandAnalytics --filter SleepNeedTests`
Expected: FAIL — `performancePct` has no member.

- [ ] **Step 3: Implement**

Append inside `public enum SleepNeed` in `SleepNeed.swift`:

```swift
    /// Sleep performance % for the Home sleep ring = asleep ÷ need, capped at 100.
    /// nil when there is no positive sleep tonight or no positive need — the ring
    /// shows an honest empty state instead of a fake 0.
    public static func performancePct(needMin: Double, asleepMin: Double?) -> Double? {
        guard let asleep = asleepMin, asleep > 0, needMin > 0 else { return nil }
        return Swift.min(100, asleep / needMin * 100)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/StrandAnalytics --filter SleepNeedTests`
Expected: PASS (all, including pre-existing).

- [ ] **Step 5: Commit**

```bash
git add Packages/StrandAnalytics
git commit -m "feat(analytics): SleepNeed.performancePct for the Home sleep ring"
```

---

### Task 2: `MyDay.activities` today-merge helper (StrandAnalytics)

**Files:**
- Create: `Packages/StrandAnalytics/Sources/StrandAnalytics/MyDay.swift`
- Create: `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/MyDayTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MyDayTests.swift`:

```swift
import XCTest
import WhoopStore
@testable import StrandAnalytics

final class MyDayTests: XCTestCase {
    // Fixed clock: 2026-06-10 12:00 UTC, UTC calendar — day = 2026-06-10.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let noon = Date(timeIntervalSince1970: 1_781_092_800) // 2026-06-10 12:00:00 UTC
    private let dayStart = 1_781_049_600                          // 2026-06-10 00:00:00 UTC

    private func sleep(start: Int, end: Int) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: end, efficiency: nil, restingHr: nil,
                           avgHrv: nil, stagesJSON: nil)
    }
    private func workout(start: Int) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + 1800, sport: "cycling", source: "my-whoop",
                   durationS: 1800, energyKcal: nil, avgHr: nil, maxHr: nil, strain: 6.5,
                   distanceM: nil, zonesJSON: nil, notes: nil)
    }

    func testSleepCountsWhenItEndsToday() {
        // Started yesterday 23:40, ended today 07:05 — counts.
        let s = sleep(start: dayStart - 1200, end: dayStart + 7 * 3600)
        let acts = MyDay.activities(sleeps: [s], workouts: [], now: noon, calendar: cal)
        XCTAssertEqual(acts.count, 1)
    }

    func testYesterdaysSleepExcluded() {
        let s = sleep(start: dayStart - 30 * 3600, end: dayStart - 1) // ended before midnight
        XCTAssertTrue(MyDay.activities(sleeps: [s], workouts: [], now: noon, calendar: cal).isEmpty)
    }

    func testWorkoutCountsWhenItStartsToday() {
        let w = workout(start: dayStart + 10 * 3600)
        XCTAssertEqual(MyDay.activities(sleeps: [], workouts: [w], now: noon, calendar: cal).count, 1)
    }

    func testYesterdaysWorkoutExcluded() {
        let w = workout(start: dayStart - 3600)
        XCTAssertTrue(MyDay.activities(sleeps: [], workouts: [w], now: noon, calendar: cal).isEmpty)
    }

    func testMergedSortedByStart() {
        let s = sleep(start: dayStart - 1200, end: dayStart + 7 * 3600)   // starts 23:40 yesterday
        let w = workout(start: dayStart + 10 * 3600)                       // 10:00 today
        let acts = MyDay.activities(sleeps: [s], workouts: [w], now: noon, calendar: cal)
        XCTAssertEqual(acts.count, 2)
        guard case .sleep = acts[0], case .workout = acts[1] else {
            return XCTFail("expected sleep then workout, got \(acts)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/StrandAnalytics --filter MyDayTests`
Expected: FAIL — `MyDay` not found.

- [ ] **Step 3: Implement**

Create `MyDay.swift`:

```swift
import Foundation
import WhoopStore

// MyDay.swift — the Home "Today's Activities" timeline. Pure merge/filter so the
// view stays declarative and the day-boundary rules are unit-tested.

public enum MyDay {

    public enum Activity: Equatable {
        case sleep(CachedSleepSession)
        case workout(WorkoutRow)

        public var startTs: Int {
            switch self {
            case .sleep(let s):   return s.startTs
            case .workout(let w): return w.startTs
            }
        }
    }

    /// Today's timeline: sleep sessions count when they END today (the night you woke
    /// from this morning, even though it started yesterday evening); workouts count when
    /// they START today. Merged chronologically by start time.
    public static func activities(sleeps: [CachedSleepSession], workouts: [WorkoutRow],
                                  now: Date = Date(),
                                  calendar: Calendar = .current) -> [Activity] {
        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let lo = Int(dayStart.timeIntervalSince1970)
        let hi = Int(dayEnd.timeIntervalSince1970)
        let s = sleeps.filter { $0.endTs >= lo && $0.endTs < hi }.map(Activity.sleep)
        let w = workouts.filter { $0.startTs >= lo && $0.startTs < hi }.map(Activity.workout)
        return (s + w).sorted { $0.startTs < $1.startTs }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/StrandAnalytics`
Expected: PASS — full package green (no regressions).

- [ ] **Step 5: Commit**

```bash
git add Packages/StrandAnalytics
git commit -m "feat(analytics): MyDay.activities — today-only sleep+workout timeline merge"
```

---

### Task 3: `MiniRing` + `WrapLayout` components (StrandDesign)

**Files:**
- Create: `Packages/StrandDesign/Sources/StrandDesign/MiniRing.swift`
- Create: `Packages/StrandDesign/Sources/StrandDesign/WrapLayout.swift`

No unit-test infra for views in this repo — verification is the package build + preview + the Task 6 screenshots.

- [ ] **Step 1: Create `MiniRing.swift`**

```swift
import SwiftUI

// MiniRing.swift — the Home triple-ring hero element. A small score ring: gradient
// arc + center value + uppercase label with a chevron underneath (the whole thing is
// wrapped in a Button by the caller). Distinct from RecoveryRing (the 168pt signature
// instrument) — this is deliberately plain so three of them read as one calm row.

public struct MiniRing: View {
    let label: LocalizedStringKey
    let value: String          // center text — "84%", "9.2", "2/4", "—"
    let progress: Double?      // 0...1 arc; nil renders the empty track only
    let gradient: Gradient
    var caption: LocalizedStringKey? = nil   // small line under the value, e.g. "of 21"
    var diameter: CGFloat = 96

    public init(label: LocalizedStringKey, value: String, progress: Double?,
                gradient: Gradient, caption: LocalizedStringKey? = nil,
                diameter: CGFloat = 96) {
        self.label = label; self.value = value; self.progress = progress
        self.gradient = gradient; self.caption = caption; self.diameter = diameter
    }

    public var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(StrandPalette.surfaceOverlay, lineWidth: 7)
                if let p = progress {
                    Circle()
                        .trim(from: 0, to: CGFloat(Swift.max(0.02, Swift.min(1, p))))
                        .stroke(
                            AngularGradient(gradient: gradient,
                                            center: .center,
                                            startAngle: .degrees(0),
                                            endAngle: .degrees(360 * Swift.max(0.02, Swift.min(1, p)))),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 0) {
                    Text(value)
                        .font(StrandFont.number(diameter * 0.23))
                        .foregroundStyle(progress == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if let caption {
                        Text(caption)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(width: diameter, height: diameter)

            HStack(spacing: 3) {
                Text(label)
                    .strandOverline()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("MiniRing row") {
    HStack(spacing: 12) {
        MiniRing(label: "Sleep", value: "84%", progress: 0.84,
                 gradient: Gradient(colors: [StrandPalette.metricPurple.opacity(0.6), StrandPalette.metricPurple]))
        MiniRing(label: "Recovery", value: "72%", progress: 0.72,
                 gradient: Gradient(colors: [StrandPalette.recovery078, StrandPalette.recovery078]))
        MiniRing(label: "Strain", value: "9.2", progress: 9.2 / 21, caption: "of 21",
                 gradient: StrandPalette.strainGradient)
        MiniRing(label: "Recovery", value: "2/4", progress: nil,
                 gradient: Gradient(colors: [StrandPalette.accent]))
    }
    .padding(24)
    .background(StrandPalette.surfaceBase)
}
#endif
```

- [ ] **Step 2: Create `WrapLayout.swift`**

(Same algorithm as JournalView's private `FlowLayout`, promoted as a public component for the goals chips. JournalView migration is out of scope.)

```swift
import SwiftUI

// WrapLayout.swift — minimal leading-aligned wrapping row (chips). Public twin of the
// private FlowLayout in JournalView; new chip rows should use this one.

public struct WrapLayout: Layout {
    var spacing: CGFloat

    public init(spacing: CGFloat = 8) { self.spacing = spacing }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = Swift.max(rowH, s.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowH)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = Swift.max(rowH, s.height)
        }
    }
}
```

- [ ] **Step 3: Verify the package builds**

Run: `swift build --package-path Packages/StrandDesign`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Packages/StrandDesign
git commit -m "feat(design): MiniRing score ring + WrapLayout chip row for the Home rebuild"
```

---

### Task 4: `openScreen` environment + shell wiring

**Files:**
- Create: `Strand/App/OpenScreen.swift` (shared — both targets)
- Modify: `Strand/App/RootView.swift` (macOS shell)
- Modify: `StrandiOS/App/RootTabView.swift` (iOS shell)

- [ ] **Step 1: Create the shared destination enum + environment key**

`Strand/App/OpenScreen.swift` (NOTE: must NOT reference `NavItem` — that type is macOS-only):

```swift
import SwiftUI

// OpenScreen.swift — cross-platform "take me to screen X" hook for Home elements
// (ring taps, activity rows). TodayView is shared by the macOS sidebar shell and the
// iOS tab shell, which navigate differently — so Home publishes intent through this
// environment closure and each shell supplies its own handler. Default is a no-op
// (previews, screenshot harness).

enum HomeDestination: String, Identifiable {
    case sleep, insights, workouts, trends
    var id: String { rawValue }
}

private struct OpenScreenKey: EnvironmentKey {
    static let defaultValue: @MainActor (HomeDestination) -> Void = { _ in }
}

extension EnvironmentValues {
    var openScreen: @MainActor (HomeDestination) -> Void {
        get { self[OpenScreenKey.self] }
        set { self[OpenScreenKey.self] = newValue }
    }
}
```

- [ ] **Step 2: Wire the macOS shell**

In `Strand/App/RootView.swift`, on the `detail` view inside `NavigationSplitView` (the `detail:` closure currently reads `detail.frame(...).background(...)`), add the environment handler:

```swift
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .environment(\.openScreen) { dest in
                    switch dest {
                    case .sleep:    selection = .sleep
                    case .insights: selection = .insights
                    case .workouts: selection = .workouts
                    case .trends:   selection = .trends
                    }
                }
        }
```

- [ ] **Step 3: Wire the iOS shell**

In `StrandiOS/App/RootTabView.swift`: give the `TabView` a selection and present non-tab destinations as sheets. Replace the `RootTabView` struct body portion (keep `moreTab`, `tab`, `link` helpers as-is, but `tab(...)` calls gain `.tag(...)`):

```swift
struct RootTabView: View {
    @EnvironmentObject private var repo: Repository

    private enum Tab: Hashable { case today, trends, live, sleep, more }
    @State private var tabSelection: Tab = .today
    @State private var sheetDestination: HomeDestination?

    var body: some View {
        TabView(selection: $tabSelection) {
            tab(TodayView(), "Today", "circle.hexagongrid.fill").tag(Tab.today)
            tab(TrendsView(), "Trends", "chart.xyaxis.line").tag(Tab.trends)
            tab(LiveView(), "Live", "waveform.path.ecg").tag(Tab.live)
            tab(SleepView(), "Sleep", "bed.double.fill").tag(Tab.sleep)
            moreTab.tag(Tab.more)
        }
        .tint(StrandPalette.accent)
        .preferredColorScheme(.dark)
        .task { await repo.refresh() }
        .environment(\.openScreen) { dest in
            switch dest {
            case .sleep:  tabSelection = .sleep
            case .trends: tabSelection = .trends
            case .insights, .workouts: sheetDestination = dest
            }
        }
        .sheet(item: $sheetDestination) { dest in
            NavigationStack {
                Group {
                    switch dest {
                    case .insights: InsightsView()
                    case .workouts: WorkoutsView()
                    case .sleep:    SleepView()
                    case .trends:   TrendsView()
                    }
                }
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(StrandPalette.surfaceBase, for: .navigationBar)
            }
            .preferredColorScheme(.dark)
        }
    }
    // ... existing tab/moreTab/link helpers unchanged ...
}
```

- [ ] **Step 4: Build both platforms**

```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug build -quiet
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build -quiet
```
Expected: both succeed (TodayView doesn't use `openScreen` yet — this task is wiring only).

- [ ] **Step 5: Commit**

```bash
git add Strand/App/OpenScreen.swift Strand/App/RootView.swift StrandiOS/App/RootTabView.swift
git commit -m "feat(nav): openScreen environment — Home can route to Sleep/Insights/Workouts/Trends on both shells"
```

---

### Task 5: Rebuild `TodayView`

**Files:**
- Modify: `Strand/Screens/TodayView.swift` (full rebuild of `body` + sections; engines/helpers reused)

This is one file but several coherent edits. Do them in order; build after each step group with the macOS command (fastest), both platforms at the end.

- [ ] **Step 1: Replace the header comment + `body` + toolbar**

Replace the file-top comment block (lines 7–23) with:

```swift
// MARK: - Home — "Today" (HomeCompact rewrite, spec 2026-06-10)
//
// WHOOP-style compact dashboard, iPhone-first (layout B of the design spec):
//   (1) triple-ring hero       — Sleep performance / Recovery / Day Strain, tappable
//   (2) live HR strip          — today's 5-min HR buckets + live bpm when connected
//   (3) monitor 2-up           — Readiness + Strain Coach, tap to expand detail inline
//   (4) goals chips            — one wrapping chip row, hidden with no goals
//   (5) My Day                 — today-only sleep + workout timeline (MyDay.activities)
//
// Relocated off Home: Key-Metrics tile grid (→ Trends/Explore), Data Sources footer
// (→ Data Sources screen), morning-journal card (→ toolbar sun icon), all-time workout
// grid (→ Workouts). Cold-start honesty notes stay. Only locked StrandDesign components.
```

Replace `body` and the toolbar with:

```swift
    @Environment(\.openScreen) private var openScreen
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var journal: JournalStore

    // Monitor-card inline disclosures.
    @State private var readinessExpanded = false
    @State private var strainExpanded = false

    var body: some View {
        ScreenScaffold(title: "Today", subtitle: "\(dateLine)") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                HealthAlertBanner()
                if repo.today?.recovery == nil {
                    if live.backfilling { SyncingHistoryNote(chunks: live.syncChunksThisSession) }
                    DataPendingNote(
                        title: "Live now. Your scores are building.",
                        message: "Your live heart rate is working from the strap, and recovery, strain and sleep build from it over your next few nights of wear, sharpening as it learns your baseline. Want your full history instantly? Import your WHOOP export in Data Sources and it backfills in about a minute."
                    )
                }
                ringsSection
                heartRateStrip
                monitorSection
                goalsSection
                myDaySection
            }
        }
        .task(id: repo.refreshSeq) { await loadAll() }
        .toolbar {
            ToolbarItem { batteryPill }
            ToolbarItem { journalButton }
            ToolbarItem {
                Button { showingSupport = true } label: {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(StrandPalette.metricRose)
                }
                .help("Support NOOP — donate or get in touch")
                .accessibilityLabel("Support NOOP — donate or get in touch")
            }
        }
        .overlay {
            if showingSupport {
                SupportModalOverlay(isPresented: $showingSupport)
            }
        }
        .animation(.easeOut(duration: 0.18), value: showingSupport)
    }

    /// Strap battery, only while connected — mirrors the WHOOP top-bar pill.
    @ViewBuilder
    private var batteryPill: some View {
        if live.connected, let pct = live.batteryPct {
            HStack(spacing: 4) {
                Image(systemName: live.charging == true ? "bolt.fill" : "applewatch")
                    .font(.system(size: 11))
                Text(verbatim: "\(Int(pct))%")
                    .font(StrandFont.captionNumber)
            }
            .foregroundStyle(pct <= 15 ? StrandPalette.statusWarning : StrandPalette.textSecondary)
            .accessibilityLabel("Strap battery \(Int(pct)) percent")
        }
    }

    /// Morning journal moved off the card stack: a sun icon that wiggles until
    /// yesterday is logged, then turns into a quiet checkmark entry point.
    private var journalButton: some View {
        let done = journal.lastLoggedDay == Repository.localDayKey(Date())
        return Button {
            model.journalRoute = JournalRoute(day: JournalView.yesterdayKey())
        } label: {
            if done {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(StrandPalette.accent)
            } else {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(StrandPalette.statusWarning)
                    .attentionWiggle(period: 4)
            }
        }
        .help("Log yesterday's journal")
        .accessibilityLabel("Log yesterday's journal")
    }
```

Note: the support heart loses `.attentionWiggle` — one wiggling toolbar icon max; the journal nudge owns it now.

- [ ] **Step 2: Add the triple-ring hero (replaces `heroSection`, `heroRingCard`, `heroInsightCard`)**

Delete `heroSection`, `heroRingCard`, `heroInsightCard`, `synthesisWord`, `synthesisDetail`, `ringSupporting`, `calibrationStatus`, `calibrationDetail`, `greetingWord`. Keep `recoveryCalibration`. Add:

```swift
    // MARK: (1) Triple-ring hero — Sleep / Recovery / Strain.

    /// Sleep performance for the sleep ring: personal need from the last 30 nights vs
    /// tonight's sleep. nil (empty ring) when tonight has no sleep yet.
    private var sleepPerformance: Double? {
        let need = SleepNeed.needMin(
            totalSleepMinsByNight: repo.days.suffix(30).compactMap(\.totalSleepMin))
        return SleepNeed.performancePct(needMin: need, asleepMin: repo.today?.totalSleepMin)
    }

    private var ringsSection: some View {
        let d = repo.today
        let recovery = d?.recovery
        let strain = dayStrain ?? d?.strain
        return NoopCard {
            HStack(alignment: .top, spacing: NoopMetrics.gap) {
                ringButton(.sleep) {
                    MiniRing(
                        label: "Sleep",
                        value: sleepPerformance.map { "\(Int($0.rounded()))%" } ?? "—",
                        progress: sleepPerformance.map { $0 / 100 },
                        gradient: Gradient(colors: [StrandPalette.metricPurple.opacity(0.55),
                                                    StrandPalette.metricPurple])
                    )
                }
                ringButton(.insights) {
                    MiniRing(
                        label: "Recovery",
                        value: recovery.map { "\(Int($0.rounded()))%" }
                            ?? recoveryCalibration.map { "\($0)/\(Baselines.minNightsSeed)" } ?? "—",
                        progress: recovery.map { $0 / 100 },
                        gradient: Gradient(colors: [
                            (recovery.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.accent).opacity(0.55),
                            recovery.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.accent,
                        ]),
                        caption: recovery == nil && recoveryCalibration != nil ? "calibrating" : nil
                    )
                }
                ringButton(.workouts) {
                    MiniRing(
                        label: "Strain",
                        value: strain.map { String(format: "%.1f", $0) } ?? "—",
                        progress: strain.map { $0 / 21 },
                        gradient: StrandPalette.strainGradient,
                        caption: "of 21"
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func ringButton<R: View>(_ dest: HomeDestination, @ViewBuilder ring: () -> R) -> some View {
        Button { openScreen(dest) } label: { ring() }
            .buttonStyle(.plain)
    }
```

- [ ] **Step 3: Convert the HR chart into the strip (replaces `heartRateTrendSection`)**

Replace `heartRateTrendSection` with (keep `hrRange` and `hrTimeFmt`):

```swift
    // MARK: (2) Live HR strip — today's continuous HR + live bpm.

    @ViewBuilder
    private var heartRateStrip: some View {
        if hrPoints.count > 1 {
            let v = hrPoints.map(\.value)
            ChartCard(
                title: "Heart Rate",
                subtitle: liveSubtitle,
                trailing: hrTrailing(v),
                height: 72
            ) {
                TrendChart(
                    points: hrPoints,
                    gradient: Gradient(colors: [StrandPalette.metricRose.opacity(0.55), StrandPalette.metricRose]),
                    valueRange: hrRange(v),
                    showsArea: true,
                    height: 72,
                    valueFormat: { "\(Int($0.rounded())) bpm" },
                    dateFormat: { Self.hrTimeFmt.string(from: $0) }
                )
            } footer: {
                ChartFooter([
                    ("Min", "\(Int((v.min() ?? 0).rounded()))"),
                    ("Avg", "\(Int((v.reduce(0, +) / Double(v.count)).rounded()))"),
                    ("Max", "\(Int((v.max() ?? 0).rounded()))"),
                ])
            }
        }
    }

    /// "● live" while the strap streams; otherwise an honest provenance note.
    private var liveSubtitle: String {
        live.connected ? String(localized: "Today · live")
                       : String(localized: "Today · last synced")
    }

    private func hrTrailing(_ v: [Double]) -> String? {
        if live.connected, let bpm = live.heartRate { return "● \(bpm) bpm" }
        return v.last.map { "\(Int($0.rounded())) bpm" }
    }
```

- [ ] **Step 4: Compact the monitor 2-up (replaces `readinessSection` + `strainCoachSection`)**

Replace both sections with one. KEEP unchanged: `readinessColor`, `flagColor`, `strainCoachGauge`, `strainCoachDetail`, `strainCoachStateLine`, `strainCoachStateColor`.

```swift
    // MARK: (3) Monitor 2-up — Readiness + Strain Coach, expandable in place.

    private var monitorSection: some View {
        let r = ReadinessEngine.evaluate(days: repo.days, today: Repository.localDayKey(Date()))
        let hasReadiness = r.level != .insufficient
        // Wide canvas: side by side. Compact: stacked full-width.
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: NoopMetrics.gap) {
                if hasReadiness { readinessCard(r) }
                strainCoachCard
            }
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                if hasReadiness { readinessCard(r) }
                strainCoachCard
            }
        }
    }

    private func readinessCard(_ r: ReadinessEngine.Result) -> some View {
        Button { withAnimation(.easeOut(duration: 0.18)) { readinessExpanded.toggle() } } label: {
            NoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Readiness").strandOverline()
                        Spacer()
                        Image(systemName: readinessExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    HStack(spacing: 8) {
                        Circle().fill(readinessColor(r.level)).frame(width: 9, height: 9)
                        Text(r.headline).font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(readinessExpanded ? nil : 1)
                    }
                    if let acwr = r.acwr {
                        Text("load \(String(format: "%.2f", acwr))")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    if readinessExpanded {
                        Text(r.summary).font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !r.signals.isEmpty {
                            Divider().overlay(StrandPalette.hairline)
                            ForEach(r.signals, id: \.key) { s in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle().fill(flagColor(s.flag)).frame(width: 7, height: 7)
                                        .padding(.top, 5)
                                    Text(s.label).font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                        .frame(width: 104, alignment: .leading)
                                    Text(s.detail).font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private var strainCoachCard: some View {
        Button { withAnimation(.easeOut(duration: 0.18)) { strainExpanded.toggle() } } label: {
            NoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Strain Coach").strandOverline()
                        Spacer()
                        Image(systemName: strainExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    if let recovery = repo.today?.recovery {
                        let band = StrainTarget.band(recovery: recovery)
                        let current = dayStrain ?? 0
                        Text("Aim \(band.low, specifier: "%.1f")–\(band.high, specifier: "%.1f")")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        if dayStrain == nil {
                            Text("Building — needs about 10 minutes of heart-rate data.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            let state = band.state(currentStrain: current)
                            Text(strainCoachStateLine(state, current: current))
                                .font(StrandFont.caption)
                                .foregroundStyle(strainCoachStateColor(state))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if strainExpanded {
                            Divider().overlay(StrandPalette.hairline)
                            HStack {
                                Spacer()
                                strainCoachGauge(current: current)
                                Spacer()
                            }
                            if !live.connected, dayStrain != nil {
                                Text("Strap not connected — showing the last synced value.")
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else {
                        Text("No recovery yet today — your strain target appears once last night is scored.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
```

Note: `strainCoachDetail` becomes unused once this lands — delete it (its copy moved inline above).

- [ ] **Step 5: Goals chips (replaces the goal row list inside `goalsSection`)**

Replace `goalsSection` and `goalChipRow` with (KEEP `goalAchieved`, `goalChipColor`, `goalChipStatus`, `goalWeekDays`):

```swift
    // MARK: (4) Goals — one wrapping chip row. Hidden with no goals.

    @ViewBuilder
    private var goalsSection: some View {
        if !goalStore.goals.isEmpty {
            let weekDays = goalWeekDays()
            NoopCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Goals — Today").strandOverline()
                    WrapLayout(spacing: 8) {
                        ForEach(goalStore.goals, id: \.id) { goal in
                            if let kind = GoalProgress.Kind(rawValue: goal.kind) {
                                goalChip(goal: goal, kind: kind, weekDays: weekDays)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func goalChip(goal: GoalRow, kind: GoalProgress.Kind, weekDays: [String]) -> some View {
        let p = GoalProgress.evaluate(
            kind: kind, target: goal.target,
            values: kind.weekValues(days: repo.days, stepsByDay: goalStepsByDay, weekDays: weekDays),
            weekDays: weekDays)
        return HStack(spacing: 6) {
            Circle().fill(goalChipColor(p, kind: kind)).frame(width: 6, height: 6)
            Text(kind.displayTitle).font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(goalChipStatus(p, kind: kind)).font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(StrandPalette.surfaceInset, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
```

- [ ] **Step 6: My Day activities (replaces `workoutsSection`)**

Replace `workoutsSection` with (KEEP `workoutDuration`; `workoutCaption` becomes unused — delete):

```swift
    // MARK: (5) My Day — today-only sleep + workout timeline.

    private var myDaySection: some View {
        let acts = MyDay.activities(sleeps: repo.sleeps, workouts: workouts)
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("My Day", overline: "Today's activities")
            NoopCard {
                if acts.isEmpty {
                    Text("Nothing logged yet today.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(acts.enumerated()), id: \.offset) { i, act in
                            activityRow(act)
                            if i < acts.count - 1 { Divider().overlay(StrandPalette.hairline) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func activityRow(_ act: MyDay.Activity) -> some View {
        switch act {
        case .sleep(let s):
            Button { openScreen(.sleep) } label: {
                activityRowBody(
                    badge: sleepDurationLabel(s),
                    badgeTint: StrandPalette.metricPurple,
                    icon: "moon.fill",
                    name: "Sleep",
                    start: s.startTs, end: s.endTs
                )
            }
            .buttonStyle(.plain)
        case .workout(let w):
            Button { openScreen(.workouts) } label: {
                activityRowBody(
                    badge: w.strain.map { String(format: "%.1f", $0) } ?? workoutDuration(w),
                    badgeTint: StrandPalette.strainColor(w.strain ?? 0),
                    icon: "bolt.fill",
                    name: LocalizedStringKey(w.sport.capitalized),
                    start: w.startTs, end: w.endTs
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func activityRowBody(badge: String, badgeTint: Color, icon: String,
                                 name: LocalizedStringKey, start: Int, end: Int) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(badge).font(StrandFont.captionNumber)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(badgeTint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(badgeTint)
            Text(name)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(Self.clockFmt.string(from: Date(timeIntervalSince1970: TimeInterval(start))))
                Text(Self.clockFmt.string(from: Date(timeIntervalSince1970: TimeInterval(end))))
            }
            .font(StrandFont.captionNumber)
            .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "7:12" — hours:minutes asleep for the sleep badge.
    private func sleepDurationLabel(_ s: CachedSleepSession) -> String {
        let mins = max(0, s.endTs - s.startTs) / 60
        return "\(mins / 60):" + String(format: "%02d", mins % 60)
    }

    /// Local wall-clock "HH:mm" for activity start/end labels.
    static let clockFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "HH:mm"
        return f
    }()
```

- [ ] **Step 7: Delete relocated sections + slim `loadAll`**

Delete entirely:
- `metricsSection` (the 10 StatTiles), `sourcesSection`, `sourceRow`, `strapSyncRow`
- `MorningJournalCard` struct (bottom of file)
- the `grid` property, `sparks` state, `appleDays` state
- `sparkValues`, `trailingWindow`, `latestString`, `sleepValue`, `caloriesValue`, `intString`, `workoutCaption`, `strainCoachDetail`

Replace `loadAll()` with:

```swift
    private func loadAll() async {
        workouts = await repo.workoutRows()

        // Today's HR trend — 5-minute bucket means from local midnight → now.
        let startOfToday = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let nowTs = Int(Date().timeIntervalSince1970)
        hrPoints = await repo.hrBuckets(from: startOfToday, to: nowTs, bucketSeconds: 300)
            .map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }

        // Strain Coach + strain ring — intraday strain from today's raw HR.
        dayStrain = await DayStrain.compute(repo: repo, hrMax: profile.hrMax,
                                            sex: profile.sex,
                                            restingHr: repo.today?.restingHr)

        // Goals chips — current week only (+2 days timezone slack).
        await goalStore.load()
        goalStepsByDay = Dictionary(
            await repo.series(key: "steps", source: "apple-health", days: 9).map { ($0.day, $0.value) },
            uniquingKeysWith: { _, new in new })
    }
```

- [ ] **Step 8: Build macOS, fix compile fallout**

```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug build -quiet
```
Expected: succeeds. Likely fallout to check: `ReadinessEngine.Result` type name (use whatever `evaluate` returns — check `ReadinessEngine.swift` if the compiler complains), unused-helper warnings, the `#Preview` at the bottom of TodayView still compiling (it only sets `repo.days`; fine).

- [ ] **Step 9: Run macOS test suite (StrandTests guards Repository/journal logic)**

```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug test -quiet
```
Expected: PASS.

- [ ] **Step 10: Build iOS**

```bash
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build -quiet
```
Expected: succeeds.

- [ ] **Step 11: Commit**

```bash
git add Strand/Screens/TodayView.swift
git commit -m "feat(home): compact WHOOP-style Today — ring trio, live HR strip, monitor 2-up, goal chips, My Day"
```

---

### Task 6: Visual verification + localization round-trip

**Files:**
- Modify: `Strand/Resources/Localizable.xcstrings` (auto-extracted on build; German values via existing translate tooling)

- [ ] **Step 1: Screenshot the redesigned Home on the simulator**

```bash
xcrun simctl boot "iPhone 16 Pro" 2>/dev/null || true
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build -quiet
APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*NOOPiOS*" -name "*.app" -newer project.yml | head -1)
xcrun simctl install booted "$APP"
xcrun simctl launch --terminate-running-process \
  --setenv NOOP_SCREEN=today booted $(defaults read "$APP/Info" CFBundleIdentifier)
sleep 3
xcrun simctl io booted screenshot /tmp/home-redesign.png
```
(If the existing screenshot tooling differs, reuse whatever `NOOP_SCREEN` harness invocation past sessions used — see memory note `noop-mobile-compat`.)

Inspect `/tmp/home-redesign.png` with the Read tool. Check: rings row fits compact width without clipping; HR strip is strip-height; monitor cards 2-up or stacked sanely; no orphaned empty sections.

- [ ] **Step 2: Verify the cold-start / empty states compile-time paths**

In the screenshot run the simulator has no strap + likely no data, which IS the cold-start state: confirm `DataPendingNote` shows, rings show "—" (and "N/4" only if calibration data exists), HR strip hidden, My Day shows "Nothing logged yet today.", goals section hidden.

- [ ] **Step 3: German localization pass**

New keys land in `Localizable.xcstrings` on build. Add German values (du/dein) for the new strings — "Heute" etc. — via the existing `Tools/translate-de.py` flow or direct xcstrings edit, matching project convention.

```bash
rtk proxy git diff --stat Strand/Resources/Localizable.xcstrings
```

- [ ] **Step 4: macOS sanity screenshot (wide canvas)**

Run the macOS app build and visually confirm the wide layout (monitor 2-up side-by-side, rings centered, nothing stretched absurd). The TodayView `#Preview` at 920×940 is the quick check if a full app run is impractical.

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "feat(home): localization + visual polish for the compact Today rebuild"
```

---

## Self-review notes (done at plan time)

- **Spec coverage:** header/toolbar (T5.1), rings (T5.2 + T1 + T3), HR strip (T5.3), monitor 2-up disclosures (T5.4), goals chips (T5.5 + T3 WrapLayout), My Day (T5.6 + T2), removals + loadAll slimming (T5.7), navigation taps (T4), adaptive wide layout (monitor ViewThatFits in T5.4; rings/strip are naturally full-width — the spec's "rings + strip share top row on wide" is relaxed to full-width rows since the rings card centers comfortably at any width; revisit only if the macOS screenshot looks empty), localization + screenshots (T6).
- **Type risk flagged:** `ReadinessEngine.evaluate` return type is used as `ReadinessEngine.Result` in T5.4's signature — verify the actual name in `ReadinessEngine.swift` at execution; adjust the helper signature accordingly.
- **Battery pill placement:** macOS toolbar exists on the window; iOS tab shell has no nav bar on the Today tab (no NavigationStack) — if the ToolbarItem doesn't render on iOS, move `batteryPill`+`journalButton` into ScreenScaffold's title row as a trailing HStack instead. Check on the simulator screenshot in T6.
