# SleepView Redesign — Design Spec

**Date:** 2026-06-11
**Screen:** `Strand/Screens/SleepView.swift` (shared iPhone + macOS SwiftUI view)
**Mockups:** `.superpowers/brainstorm/76343-1781158313/content/sleep-layout-a-v2.html` (Layout A v2, approved)

## Goals

1. WHOOP-like visual style — match the 1.71 Home redesign idiom (ring hero, dark, bold numbers)
2. Better hierarchy — score answers "how did I sleep?" first; details follow in story order
3. iPhone-first layout — mac adapts via the same codepath
4. **Zero information loss** — every datum on the current screen survives the redesign

No new metrics, queries, or model fields. This is a re-layout of existing data.

## Approved structure (top to bottom)

| # | Section | Source |
|---|---------|--------|
| 1 | **Hero: performance ring** | Promoted from metric-grid tile #1 |
| 2 | **Night timeline (hypnogram)** | Current hero, kept |
| 3 | **Stages vs typical** | Current section 3, moved up |
| 4 | **Metric grid (6 tiles)** | Current section 2, minus Performance |
| 5 | **30-day asleep-hours trend** | Current section 4, kept |
| 6 | **Tonight's plan (planner)** | Current section 0, moved to bottom |

Planner placement decision: **bottom** (option A). Morning use case first — user opens the
screen to see how they slept; the plan matters in the evening, end of scroll.

## Section detail

### 1. Hero — sleep performance ring

- Reuse `RecoveryRing` (`Packages/StrandDesign/Sources/StrandDesign/RecoveryRing.swift`),
  the Home signature component: 240° gauge, recovery gradient, draw-in animation.
- `score` = sleep performance % (`model.performance.latest`), diameter ≈ 180pt on iPhone.
- Supporting line: "7:12 asleep · 7:50 needed" (asleep duration vs need).
- Subline below ring (footnote): time in bed · efficiency % · onset–wake times · date label,
  plus the existing "stages approximate (on-device)" badge when `model.isPersistedHypnogram`.
- No score (`model.performance.latest == nil`) → render the ring track at zero fill with
  "—" as the center label; the PERFORMANCE state word stays (implementation choice — the
  label identifies the gauge even without a score). Supporting line still shows
  asleep/needed durations.
- Onset–wake times and date label live in the hero `SectionHeader` trailing (not the
  subline) — positional deviation, no information lost.

### 2. Night timeline

- Existing `Hypnogram` component unchanged (intervals, stage axis, night start), inside
  the existing `ChartCard`.
- Fallback when `intervals.count < 2`: existing proportional `stageBar` — kept as-is.
- Stage durations footer (REM/Deep/Light/Awake, duration + %) restyled from `ChartFooter`
  rows to colored stage chips. Same data, same order.

### 3. Stages vs typical

- Existing `stageRow` capsule bars (last-night fill + typical-mean marker + delta text),
  unchanged. Moved directly under the timeline so stage story reads as one unit.

### 4. Metric grid

- Existing `StatTile` + `tileColumns` adaptive grid (min 164pt → 2 columns on ≥396pt
  iPhones; 168 missed Pro-width two-column fit by 2pt).
- Six tiles, all with sparkline + vs-typical caption, all sourced from the memoized series:
  Restorative, Sleep Debt, Consistency, Hours vs Needed, Efficiency, Respiratory.
- Sleep Performance tile removed — value lives in the hero now. Its vs-typical caption
  moves into the hero subline ("performance +3% vs typical"); its 30-day sparkline is
  intentionally omitted — the approved Layout A v2 mockup shows the hero without one,
  and the performance series remains computed in the model if a future surface wants it.

### 5. Trend

- Existing `TrendChart` card, footer (Avg / Min / Max / Nights) — unchanged.

### 6. Planner

- Existing planner section moved from top to bottom. Internals unchanged.

## Layout strategy (iPhone-first, mac adapts)

- One shared codepath; no `#if os` layout branches.
- Hero uses `ViewThatFits`: iPhone = ring above text (stacked, centered);
  mac/wide = ring left, text right.
- Grid stays adaptive — wider windows naturally get more columns.
- Honor `ScreenScaffold` conventions (iOS toolbar gap: controls go in scaffold rows,
  not `.toolbar`).

## Targeted cleanup

- `SleepView.swift` is 1023 lines. Extract the model layer — `SleepModel`, the
  memoization plumbing (`SleepInputKey`, signature computation), series builders,
  trend-point builder, planner-input builders — into `Strand/Data/SleepModel.swift`
  (~300 lines). View file keeps layout + formatting helpers only.
- No behavior change in the extraction; types stay internal.

## Data flow

- `SleepModel` memoized snapshot pattern untouched: rebuilt only when the repo
  signature changes, never on hover/animation/1Hz ticks.
- All seven metric series, trend points, typical means already computed in the model
  build. The redesign only changes which view consumes which precomputed value.

## Empty / sparse states

- No night at all → existing empty state view, unchanged.
- Sparse trend (< 2 points) → existing `sparsePlaceholder`.
- Missing metric values → existing "—" tile rendering; hero ring shows "—".

## Localization

- New or reworded strings go through the String Catalog; German uses du-form.
- Stage names, metric labels already localized — reuse existing keys wherever the
  string is unchanged.

## Verification

- No new logic → no new unit tests; `SleepStagerTests` and existing suites must stay green.
- Build **both** platforms (iOS sim + macOS) — shared-view regressions are the known risk.
- Screenshot review via `simctl` NOOP_SCREEN harness on iPhone; manual check on mac
  for the wide hero variant.

## Out of scope

- Android Compose sleep screen (explicitly deferred).
- Any change to sleep staging, planner logic, or metric math.
- Other screens (Insights is the likely next candidate, after upstream churn settles).
