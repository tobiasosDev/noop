# Home (TodayView) Redesign — "Layout B: Scores + Live HR Strip"

**Date:** 2026-06-10
**Status:** Approved
**Target:** iPhone-first; macOS/iPad adapt via existing ViewThatFits / size-class patterns.

## Goal

The current Home is a long single column of nine sections with poor space economy on
iPhone. Rebuild it as a compact, WHOOP-style dashboard: top-line scores as a triple-ring
hero, NOOP's live heart-rate identity as a full-width strip, compact monitor cards, and a
today-only activity timeline. Detail content moves to the screens that already own it.

## Layout (top → bottom, compact width)

1. Header
2. System notes (HealthAlertBanner, SyncingHistoryNote, DataPendingNote — unchanged rules)
3. Triple-ring hero (Sleep / Recovery / Strain)
4. Live HR strip
5. Monitor 2-up (Readiness + Strain Coach)
6. Goals chips card
7. My Day — Today's Activities timeline

### 1. Header

- `ScreenScaffold` title becomes **"Today"**, subtitle = localized date line (existing
  `dateLine`).
- Toolbar adds a **strap battery pill** (`⌚ 78%` from `live.batteryPct`; shows charging
  state when `live.charging == true`; hidden entirely when `!live.connected`).
- Existing support-heart toolbar button stays.
- **Journal prompt** leaves the card stack: becomes a toolbar sun icon with
  `attentionWiggle` when yesterday is unlogged (`journal.lastLoggedDay != today`),
  opening the same `model.journalRoute`. Once logged, the icon shows without wiggle as a
  plain entry point (checkmark seal variant).
- The date-stepper ("◂ TODAY ▸") from the mockup is **cut for v1** — no
  historical-day browsing on Home.

### 2. Triple-ring hero — `ScoreRingTrio`

Three equal-width tappable rings in one row:

| Ring | Value | Color | Center | Tap → |
|---|---|---|---|---|
| Sleep | sleep performance % = min(100, asleep ÷ need × 100) via existing `SleepNeed` | `metricPurple` ramp | "84%" / "—" | Sleep screen |
| Recovery | `repo.today?.recovery` | existing recovery color ramp | "72%"; calibrating shows "N/4" | Insights |
| Strain | intraday `dayStrain` (live), falling back to scored `d.strain` | strain gradient | "9.2" of 21 | Workouts |

- New **`MiniRing`** component in StrandDesign (~96 pt diameter, value + small unit label
  center, uppercase label + chevron below). `RecoveryRing` stays untouched (168 pt,
  single-purpose, used elsewhere).
- Calibration state ports from the old hero: recovery ring center shows
  "N of 4" (from `RecoveryScorer.calibrationNights`) while the HRV baseline seeds.
- Empty state: em-dash center, tertiary ring stroke; never fake zeros.

### 3. Live HR strip

Full-width `ChartCard`:

- Series: today's 5-minute HR bucket means (existing `repo.hrBuckets` query →
  `hrPoints`), rose gradient, area fill, fixed strip height of 72 pt (not the full
  `NoopMetrics.chartHeight` hero size).
- Header trailing: `● 62 bpm` live from `live.heartRate` when `live.connected`;
  otherwise the last bucket value with a "last synced" footnote.
- Footer: Min / Avg / Max (kept).
- Visibility: hidden when `hrPoints.count < 2` (unchanged rule).

### 4. Monitor 2-up — Readiness + Strain Coach

Two equal-width compact cards in one HStack (stacking on very narrow widths via
ViewThatFits):

- **Readiness:** status dot + level headline (`ReadinessEngine.evaluate`), one sub-line
  (`load 1.04 · in range`). Tap toggles an **inline disclosure** revealing the existing
  signal rows. Hidden when `level == .insufficient` — Strain Coach card then goes
  full-width.
- **Strain Coach:** target band headline (`StrainTarget.band`), one sub-line state
  (`9.2 now — room to push`). Tap toggles inline disclosure with the existing
  `StrainGauge` + detail. Pre-recovery and "building" states keep their current honest
  copy, compacted to the sub-line.

### 5. Goals chips

One `NoopCard` with horizontal wrapping chips: status dot + goal name + short status
("hit" / "6:48" / "on track"). Same `GoalProgress` evaluation and color rules as today
(including the weeklyStrain weekly-average rule). Hidden when `goalStore.goals.isEmpty`.

### 6. My Day — Today's Activities

Timeline card merging **today's** sleep episode(s) and **today's** workouts as rows:

- Row: tinted badge (☾ duration for sleep, ⚡ strain for workouts) + uppercase name +
  trailing start/end times.
- Sleep rows from `repo.sleeps` filtered to today; workout rows from `repo.workoutRows()`
  filtered to today.
- Tap workout row → Workouts screen; tap sleep row → Sleep screen.
- Empty state: single quiet line ("Nothing logged yet today.").
- Replaces the all-time "Last Workouts" 6-tile grid — history lives in Workouts.

## Removed from Home (content relocation)

| Removed | Lives in |
|---|---|
| 10-tile Key Metrics grid + sparklines | Trends / Metric Explorer (already exist) |
| Data Sources footer (incl. strap-sync row) | Data Sources screen (already exists) |
| Readiness signal rows (as always-visible) | Inline disclosure on Readiness card |
| Strain Coach gauge (as always-visible) | Inline disclosure on Strain Coach card |
| Morning journal card | Toolbar sun icon (wiggle when pending) |
| Last Workouts grid | Workouts screen |

Cold-start honesty notes (`DataPendingNote`, `SyncingHistoryNote`, `HealthAlertBanner`)
stay at the top, unchanged.

## Adaptive layout (macOS / iPad)

iPhone-first single column. On wide canvases ViewThatFits pairs sections:
rings + HR strip share the top row; monitor 2-up and goals share the second; activities
full-width below. Existing `NoopMetrics.gap` / `sectionGap` rhythm and equal margins
keep the gapless-dashboard character.

## Data / loading changes

- `loadAll()` drops the 10 sparkline queries (grid gone) — keeps HR buckets, workouts,
  sleeps (add today-filter), goals, `dayStrain`, and adds sleep-need evaluation for the
  sleep ring.
- No schema or store changes. All inputs already published by `Repository`, `LiveState`,
  `GoalStore`, `JournalStore`.

## Localization

All new user-facing strings as `LocalizedStringKey` literals so the String Catalog picks
them up (du/dein German per project convention; xliff round-trip after).

## Testing / verification

- Build iOS **and** macOS (shared views; memory: mobile-compat rule).
- Simulator screenshot harness (`NOOP_SCREEN`) for: cold start (no recovery, no data),
  calibrating (N/4), full data, strap disconnected (no battery pill, HR strip fallback),
  no goals (section hidden), no activities today.
- Existing previews updated; new `MiniRing` preview added in StrandDesign.

## Out of scope (v1)

- Historical-day browsing (date stepper).
- Tonight's-sleep / alarm footer card (layout A element).
- Any change to other screens receiving relocated content (they already exist).
