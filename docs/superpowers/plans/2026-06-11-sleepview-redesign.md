# SleepView Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-layout SleepView to WHOOP-style Layout A — RecoveryRing performance hero, hypnogram, stages-vs-typical, 6-tile grid, 30-day trend, planner at bottom — with zero information loss.

**Architecture:** Pure re-layout of existing memoized data. Model layer (`SleepModel`, `SleepInputKey`, `Stages`, `Night`, all series builders) extracts from the 1023-line `SleepView.swift` into `Strand/Data/SleepModel.swift`. `RecoveryRing` gains two optional center-label overrides so it can render "87% / PERFORMANCE" instead of recovery vocabulary. No new queries, no new model fields, no staging/planner math changes.

**Tech Stack:** SwiftUI (shared iPhone+macOS view), XcodeGen, StrandDesign package components (`RecoveryRing`, `Hypnogram`, `ChartCard`, `StatTile`, `NoopCard`, `SectionHeader`, `WrapLayout`).

**Spec:** `docs/superpowers/specs/2026-06-11-sleepview-redesign-design.md`

**Reference line numbers** refer to `Strand/Screens/SleepView.swift` at commit `43ef62f` (1023 lines).

---

## File structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Strand/Data/SleepModel.swift` | Create | Model types + builders: `SleepInputKey`, `SleepModel`, `Stages`, `Night`, `SleepPlannerInputs`, stage decoding |
| `Strand/Screens/SleepView.swift` | Modify | Layout only: hero ring, timeline, stages-vs-typical, grid, trend, planner; formatting helpers |
| `Packages/StrandDesign/Sources/StrandDesign/RecoveryRing.swift` | Modify | Optional `centerText` / `stateText` label overrides |
| `Strand/Resources/Localizable.xcstrings` | Modify | German for new strings |

There are no unit tests for view layout in this codebase; the verification contract is: **both platforms build, `StrandTests` stays green, screenshots reviewed**. Build commands appear in every task.

---

### Task 0: Branch

- [ ] **Step 0.1: Create stacked branch (Graphite)**

```bash
cd /Users/tobiasluscher/Development/noop
gt create redesign-sleep-screen
```

---

### Task 1: Extract model layer to `Strand/Data/SleepModel.swift`

Pure move-refactor — no behavior change. Computed properties that read `repo`/`behavior` become static functions taking them as parameters.

**Files:**
- Create: `Strand/Data/SleepModel.swift`
- Modify: `Strand/Screens/SleepView.swift`

- [ ] **Step 1.1: Create `Strand/Data/SleepModel.swift` with this skeleton, then move code into it**

```swift
import Foundation
import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Input fingerprint

/// Cheap, Equatable fingerprint of the repo inputs SleepView derives from. Two snapshots are
/// equal iff the data the screen reads is unchanged, so the heavy `SleepModel` rebuild is
/// skipped on the many `body` re-evaluations that don't touch sleep data.
struct SleepInputKey: Equatable {
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

    @MainActor
    init(repo: Repository) {
        loaded = repo.loaded
        daysCount = repo.days.count
        sleepsCount = repo.sleeps.count
        firstDay = repo.days.first?.day
        lastDay = repo.days.last?.day
        lastDayUpdated = repo.days.last
        lastSleep = repo.sleeps.last
        refreshSeq = repo.refreshSeq
    }
}

// MARK: - Value types (moved verbatim from SleepView.swift L897–954, private → internal)

struct Stages { /* move body verbatim from L897–906 */ }
struct Night  { /* move body verbatim from L908–954 */ }

// MARK: - Memoized model

struct SleepModel {
    typealias Metric = (latest: Double?, typical: Double?, series: [Double])

    // move stored properties verbatim from L869–895 (night, intervals,
    // isPersistedHypnogram, the seven Metrics, the four typicals, trendPoints)

    /// Build every expensive derivation exactly once (was SleepView.buildModel, L479–500).
    @MainActor
    static func build(repo: Repository) -> SleepModel? {
        guard let night = latestNight(repo) else { return nil }
        return SleepModel(
            night: night,
            intervals: night.intervals,
            isPersistedHypnogram: (night.realSegments?.count ?? 0) >= 2,
            performance: performanceSeries(repo),
            efficiency: efficiencySeries(repo),
            consistency: consistencySeries(repo),
            hoursVsNeeded: hoursVsNeededSeries(repo),
            restorative: restorativeSeries(repo),
            respiratory: respiratorySeries(repo),
            sleepDebt: sleepDebtSeries(repo),
            typicalTotalMin: typicalTotalMin(repo),
            typicalDeepMin: typicalStageMin(repo, \.deepMin),
            typicalRemMin: typicalStageMin(repo, \.remMin),
            typicalLightMin: typicalStageMin(repo, \.lightMin),
            trendPoints: durationTrendPoints(repo))
    }

    // MARK: Builders — moved from SleepView, `repo` passed explicitly.
    // Mechanical transform for each: `private var xSeries: Metric { ... }` becomes
    // `@MainActor static func xSeries(_ repo: Repository) -> Metric { ... }`;
    // body unchanged except `repo` is now the parameter. Full example:

    @MainActor
    static func sleepNeedMin(_ repo: Repository) -> Double {          // was L634–636; internal: hero + planner use it
        SleepNeed.needMin(totalSleepMinsByNight: repo.days.compactMap { $0.totalSleepMin })
    }

    // Apply the same transform to (source lines in parentheses; keep doc comments):
    //   private  latestNight(_:) -> Night?                  (L510–519)
    //   private  typicalTotalMin(_:) -> Double?              (L522–524)
    //   private  typicalStageMin(_:_:) -> Double?            (L527–529; extra KeyPath param)
    //   private  metric(_:_:) -> Metric                      (L536–539)
    //   internal performanceSeries(_:) -> Metric             (L544–552)
    //   private  efficiencySeries(_:) -> Metric              (L554–559)
    //   private  consistencySeries(_:) -> Metric             (L565–592)
    //   private  hoursVsNeededSeries(_:) -> Metric           (L596–605)
    //   private  restorativeSeries(_:) -> Metric             (L608–614)
    //   private  respiratorySeries(_:) -> Metric             (L616–618)
    //   internal sleepDebtSeries(_:) -> Metric               (L622–631; planner uses it)
    //   internal typicalEfficiency(_:) -> Double?            (L650–654; planner uses it)
    //   private  durationTrendPoints(_:) -> [TrendPoint]     (L674–686; `SleepView.dayParser` → `dayParser`)
    //   private  mean(_:) -> Double?                         (L781–784; pure, no repo param)
    //   private  decodeStages(_:) -> Stages?                 (L789–802; pure)
    //   private  decodeSegments(_:sessionStart:) -> (...)    (L807–834; pure)
    //   private  static let dayParser                        (L837–843)
}

// MARK: - Planner inputs (moved from SleepView L638–663)

enum SleepPlannerInputs {
    @MainActor
    static func goal(_ behavior: BehaviorStore) -> SleepPlanner.Goal {
        SleepPlanner.Goal(rawValue: behavior.plannerGoalRaw) ?? .perform
    }

    /// Strap alarm wins when enabled; manual planner time otherwise.
    @MainActor
    static func wakeMinutes(_ behavior: BehaviorStore) -> Int {
        behavior.smartAlarmEnabled ? behavior.smartAlarmMinutes : behavior.plannerWakeMinutes
    }

    @MainActor
    static func recommendation(repo: Repository, behavior: BehaviorStore) -> SleepPlanner.Recommendation {
        let lastDebt = SleepModel.sleepDebtSeries(repo).latest ?? 0
        return SleepPlanner.recommend(wakeMinutes: wakeMinutes(behavior),
                                      baseNeedMin: SleepModel.sleepNeedMin(repo),
                                      debtMin: lastDebt,
                                      efficiency: SleepModel.typicalEfficiency(repo),
                                      goal: goal(behavior))
    }
}
```

- [ ] **Step 1.2: Update `SleepView.swift` to consume the extracted layer**

Delete the moved code (L461–500 memoization plumbing, L502–663 derived model + series + planner inputs except `clock` L666–668, L674–686 trend points, L781–784 `mean`, L786–843 stage decoding + `dayParser`, L846–954 value types). Keep: `trendRange` (L688–693), all formatting helpers (L716–779), `clock`, every view section, the preview. Replace call sites:

```swift
private var dataKey: SleepInputKey { SleepInputKey(repo: repo) }

// body: `buildModel()` (two call sites, L52 and L72) becomes:
SleepModel.build(repo: repo)

// plannerSection accessors become:
private var plannerGoal: SleepPlanner.Goal { SleepPlannerInputs.goal(behavior) }
private var plannerRecommendation: SleepPlanner.Recommendation {
    SleepPlannerInputs.recommendation(repo: repo, behavior: behavior)
}
```

- [ ] **Step 1.3: Regenerate project and build both platforms**

```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug build -quiet
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS Simulator' -configuration Debug build -quiet
```
Expected: both `BUILD SUCCEEDED`.

- [ ] **Step 1.4: Run app test suite**

```bash
xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests -quiet
```
Expected: all pass (this task changes no behavior).

- [ ] **Step 1.5: Commit**

```bash
git add Strand/Data/SleepModel.swift Strand/Screens/SleepView.swift Strand.xcodeproj
git commit -m "refactor(sleep): extract SleepModel layer out of SleepView"
```

---

### Task 2: `RecoveryRing` center-label overrides

**Files:**
- Modify: `Packages/StrandDesign/Sources/StrandDesign/RecoveryRing.swift`

- [ ] **Step 2.1: Add two optional properties + init params**

After `public var showsHover: Bool` add:

```swift
/// Overrides the big center number (e.g. "87%", "—"). nil → the rounded score.
public var centerText: String?
/// Overrides the state word under the number (e.g. "PERFORMANCE"). nil → recovery vocabulary.
public var stateText: String?
```

In `public init(...)`, insert matching parameters with `= nil` defaults **between `showsHover` and `valueFormat`**, and assign them in the body:

```swift
public init(
    score: Double,
    supporting: String? = nil,
    diameter: CGFloat = 240,
    lineWidth: CGFloat = 16,
    showsLabel: Bool = true,
    showsHover: Bool = true,
    centerText: String? = nil,
    stateText: String? = nil,
    valueFormat: @escaping (Double) -> String = { "Recovery \(Int($0.rounded()))" }
) {
    ...existing assignments...
    self.centerText = centerText
    self.stateText = stateText
}
```

- [ ] **Step 2.2: Use overrides in `centerLabel`**

```swift
// L182: Text(numberString)          →  Text(centerText ?? numberString)
// L186: Text(stateWord)             →  Text(stateText ?? stateWord)
```

Existing callers (`MenuBarContent.swift:155`, `OnboardingWizard.swift:613`) pass no new args — unaffected.

- [ ] **Step 2.3: Build package, commit**

```bash
swift build --package-path Packages/StrandDesign
git add Packages/StrandDesign/Sources/StrandDesign/RecoveryRing.swift
git commit -m "feat(design): RecoveryRing centerText/stateText label overrides"
```

---

### Task 3: Hero ring section + body reorder (planner to bottom)

**Files:**
- Modify: `Strand/Screens/SleepView.swift`

- [ ] **Step 3.1: Add the hero section**

Insert above the current `hero(_:)` (which Task 4 renames to `nightTimeline`):

```swift
// MARK: - 1. HERO — sleep performance ring

@ViewBuilder
private func sleepHero(_ model: SleepModel) -> some View {
    let night = model.night
    let needMin = SleepModel.sleepNeedMin(repo)
    let supporting = needMin > 0
        ? String(localized: "\(durationText(night.stages.asleep)) asleep · \(durationText(needMin)) needed")
        : String(localized: "\(durationText(night.stages.asleep)) asleep")
    VStack(alignment: .leading, spacing: NoopMetrics.gap) {
        SectionHeader("Last night", overline: "Sleep",
                      trailing: "\(night.dateLabel) · \(night.onsetText)–\(night.wakeText)")
        NoopCard {
            // Wide (mac): ring left, details right. Narrow (iPhone): stacked, centered.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 28) {
                    heroRing(model, supporting: supporting)
                    Text(heroSubline(model))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                VStack(spacing: 10) {
                    heroRing(model, supporting: supporting)
                    Text(heroSubline(model))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Ring with score, or a zero-fill track with "—" when no performance value exists (spec §1).
@ViewBuilder
private func heroRing(_ model: SleepModel, supporting: String) -> some View {
    if let perf = model.performance.latest {
        RecoveryRing(score: perf, supporting: supporting,
                     diameter: 180, lineWidth: 14,
                     centerText: "\(Int(perf.rounded()))%",
                     stateText: String(localized: "PERFORMANCE"),
                     valueFormat: { "\(String(localized: "Performance")) \(Int($0.rounded()))%" })
    } else {
        RecoveryRing(score: 0, supporting: supporting,
                     diameter: 180, lineWidth: 14, showsHover: false,
                     centerText: "—", stateText: String(localized: "PERFORMANCE"))
    }
}

/// "8h 01m in bed · 90% efficiency[ · stages approximate (on-device)]"
private func heroSubline(_ model: SleepModel) -> String {
    var parts = [String(localized: "\(durationText(model.night.timeInBed)) in bed"),
                 String(localized: "\(efficiencyText(model.night)) efficiency")]
    if model.isPersistedHypnogram { parts.append(String(localized: "stages approximate (on-device)")) }
    return parts.joined(separator: " · ")
}
```

- [ ] **Step 3.2: Reorder `body` (L56–66) — spec section order, planner last in BOTH branches**

```swift
VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
    if let resolved {
        sleepHero(resolved)
        nightTimeline(resolved)      // renamed in Task 4; until then keep `hero(resolved)`
        stagesVsTypical(resolved)
        metricGrid(resolved)
        durationTrend(resolved)
    } else {
        emptyState
    }
    // The planner closes BOTH branches — even with no nights it answers
    // "when should I go to bed tonight?" from defaults (and says so).
    plannerSection
}
```

- [ ] **Step 3.3: Update the file-header comment (L7–26)** to describe the new order: 1. hero ring, 2. night timeline, 3. stages vs typical, 4. metric grid (six tiles), 5. 30-day trend, 6. planner.

- [ ] **Step 3.4: Build both platforms (commands as Step 1.3), commit**

```bash
git add Strand/Screens/SleepView.swift
git commit -m "feat(sleep): performance-ring hero, story order, planner to bottom"
```

---

### Task 4: Night-timeline card — slim subtitle, chip footer

**Files:**
- Modify: `Strand/Screens/SleepView.swift`

- [ ] **Step 4.1: Rename `hero(_:)` → `nightTimeline(_:)` (L191) and update its one call site in `body`.** Delete its `SectionHeader` line (L198–199 — the hero owns that header now).

- [ ] **Step 4.2: Slim the `ChartCard`** — time-in-bed/efficiency/badge moved to the hero subline:

```swift
ChartCard(
    title: "Stage breakdown",
    subtitle: nil,
    trailing: durationText(s.asleep),
    height: NoopMetrics.chartHeight,
    chart: { ...unchanged Hypnogram/stageBar... },
    footer: { stageChips(s) }
)
```

- [ ] **Step 4.3: Replace the `ChartFooter` rows with stage chips** (same data, same order; `WrapLayout` from StrandDesign wraps on narrow widths):

```swift
/// REM/Deep/Light/Awake duration+percent chips — replaces the ChartFooter rows.
@ViewBuilder
private func stageChips(_ s: Stages) -> some View {
    WrapLayout(spacing: 8) {
        stageChip(.rem,   "REM",   s.rem,   s.total)
        stageChip(.deep,  "Deep",  s.deep,  s.total)
        stageChip(.light, "Light", s.light, s.total)
        stageChip(.awake, "Awake", s.awake, s.total)
    }
}

private func stageChip(_ stage: SleepStage, _ label: LocalizedStringKey,
                       _ minutes: Double, _ total: Double) -> some View {
    HStack(spacing: 5) {
        Circle().fill(StrandPalette.sleepStageColor(stage)).frame(width: 7, height: 7)
        Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        Text(verbatim: "\(durationText(minutes)) · \(pct(minutes, total))%")
            .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
    }
    .padding(.horizontal, 9).padding(.vertical, 5)
    .background(StrandPalette.surfaceInset, in: Capsule(style: .continuous))
}
```

If `WrapLayout`'s API differs (check `Packages/StrandDesign/Sources/StrandDesign/WrapLayout.swift` — 2.0K, read it first), fall back to a plain `HStack(spacing: 8)` — four chips fit a 390pt iPhone at footnote size.

- [ ] **Step 4.4: Build both platforms, commit**

```bash
git add Strand/Screens/SleepView.swift
git commit -m "feat(sleep): stage chips footer on the night timeline card"
```

---

### Task 5: Metric grid — six tiles

**Files:**
- Modify: `Strand/Screens/SleepView.swift`

- [ ] **Step 5.1: Delete the "Sleep Performance" `StatTile`** (L293–299) and the now-unused `let perf = model.performance` binding (L281). The other six tiles stay byte-identical. (`SleepModel.performance` itself stays — the hero reads it.)

- [ ] **Step 5.2: Build macOS (fast signal), commit**

```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug build -quiet
git add Strand/Screens/SleepView.swift
git commit -m "feat(sleep): drop performance tile — value lives in the hero ring"
```

---

### Task 6: Localization

**Files:**
- Modify: `Strand/Resources/Localizable.xcstrings`

- [ ] **Step 6.1: Build the iOS target once** (extraction populates new keys into the String Catalog):

```bash
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS Simulator' -configuration Debug build -quiet
```

- [ ] **Step 6.2: Add German translations** in `Localizable.xcstrings` for the new keys (du-form per project convention; interpolated keys keep their `%@`/`%lld` placeholders):

| en | de |
|----|----|
| `PERFORMANCE` | `LEISTUNG` |
| `Performance` | `Leistung` |
| `%@ asleep · %@ needed` | `%@ geschlafen · %@ benötigt` |
| `%@ asleep` | `%@ geschlafen` |
| `%@ in bed` | `%@ im Bett` |
| `%@ efficiency` | `%@ Effizienz` |
| `stages approximate (on-device)` | `Phasen approximiert (auf dem Gerät)` |

Keys already localized (stage names "REM/Deep/Light/Awake", "Stage breakdown", "Last night", "Sleep") need no new entries.

- [ ] **Step 6.3: Verify catalog parses, commit**

```bash
plutil -lint Strand/Resources/Localizable.xcstrings || python3 -c "import json;json.load(open('Strand/Resources/Localizable.xcstrings'))"
git add Strand/Resources/Localizable.xcstrings
git commit -m "l10n(sleep): German strings for redesigned hero"
```

(Note: `plutil -lint` rejects plain JSON on this machine — the python fallback is the real check.)

---

### Task 7: Verification

- [ ] **Step 7.1: Full builds + tests**

```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug build -quiet
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS Simulator' -configuration Debug build -quiet
xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests -quiet
```
Expected: 2× BUILD SUCCEEDED, tests pass.

- [ ] **Step 7.2: iPhone screenshot via the NOOP_SCREEN harness**

First confirm the harness knows the screen: `grep -n '"sleep"' StrandiOS/App/RootTabView.swift` — if the switch (L135+) lacks a `case "sleep": SleepView()`, add it. Then:

```bash
xcrun simctl list devices available | grep -m1 iPhone        # pick a booted/available device
xcrun simctl boot "<device>" 2>/dev/null || true
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination "platform=iOS Simulator,name=<device>" -configuration Debug build -quiet
APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*Debug-iphonesimulator/NOOP*.app" -newer project.yml | head -1)
xcrun simctl install booted "$APP"
SIMCTL_CHILD_NOOP_SCREEN=sleep xcrun simctl launch --terminate-running-process booted com.tecminds.noop
sleep 3 && xcrun simctl io booted screenshot /tmp/sleep-redesign-iphone.png
```

Review the screenshot: ring hero centered, hypnogram below, chips wrap cleanly, 2-column grid, planner last, nothing clipped.

- [ ] **Step 7.3: macOS spot check** — run the Strand app (or the Xcode preview) wide; the hero must switch to ring-left/text-right (`ViewThatFits` wide branch).

- [ ] **Step 7.4: Spec checklist** — walk `docs/superpowers/specs/2026-06-11-sleepview-redesign-design.md` "Approved structure" table; confirm all six sections render in order and every datum in the "Info mapping" survives.

---

### Task 8: Submit

- [ ] **Step 8.1: Submit the stack**

```bash
gt submit
```

PR title: `feat(sleep): SleepView redesign — performance-ring hero + story layout (Layout A)`. Body references the spec and mockup paths.
