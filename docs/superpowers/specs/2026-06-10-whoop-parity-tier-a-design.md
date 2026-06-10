# WHOOP-Parity Tier A: Strain Coach, Sleep Planner, Performance Report, Goals

**Date:** 2026-06-10
**Status:** Approved
**Scope:** 4 features, pure compute + UI on existing data. No new permissions, no network, no BLE changes. Shared macOS + iOS (approach: shared-first, repo convention).

Deferred to later tiers: NOOP Age / healthspan, native VO₂max, Strength Trainer (Tier B); GPS activities, weather Daily Outlook, BLE HR broadcast, Hormonal Insights (Tier C).

## 1. Shared infrastructure

### New compute modules (Packages/StrandAnalytics — pure functions, unit-testable)

- **`StrainTarget.swift`** — maps recovery % → recommended strain band.
  `target = 4.0 + 0.145 × recovery`, clamped to [4.0, 18.5]; band = (target − 1.0, target + 1.0).
  Output: `StrainTargetResult { low, high, midpoint, state(currentStrain:) }` where state is `.building / .onTarget / .overreaching` relative to the band.
- **`SleepNeed.swift`** — extracted from `Strand/Screens/SleepView.swift:484–497` (currently UI-side; planner needs it too). Same math, one source of truth:
  `need = max(450 min, mean(asleep durations))`; `debt = max(0, need − asleep)` per night.
  SleepView refactored to call this.
- **`SleepPlanner.swift`** — bedtime recommendation (§3).
- **`PerformanceReport.swift`** — period aggregation (§4).

### Intraday strain

No new algorithm. `StrainScorer.strain()` (Packages/StrandAnalytics/Sources/StrandAnalytics/StrainScorer.swift) is already window-agnostic: feed it `repo.hrSamples(from: startOfToday, to: now)` with `maxHR: profile.hrMax` and resting HR from the latest RHR baseline. Existing ≥600-sample (~10 min) guard applies; below that the gauge shows the pending state.

### Persistence

- **Migration v11** in `Packages/WhoopStore/Sources/WhoopStore/Database.swift`:
  ```sql
  goal(id INTEGER PK AUTOINCREMENT, kind TEXT NOT NULL, target REAL NOT NULL,
       createdAt INTEGER NOT NULL, archivedAt INTEGER NULL)
  ```
  Adherence is computed at read time from `metricSeries` — no tracking table.
- **Planner prefs** → `BehaviorStore` (UserDefaults), same pattern as smart alarm keys:
  `planner.wakeMinutes` (default 420), `planner.goalLevel` (peak/perform/getBy), `planner.bedtimeReminderEnabled`.

### Navigation

- 2 new screens: `ReportView.swift`, `GoalsView.swift` in `Strand/Screens/`.
- macOS: new `NavItem` cases + icon/title/detail switch entries in `Strand/App/RootView.swift`.
- iOS: `link()` rows in More → Insights section in `StrandiOS/App/RootTabView.swift`.
- Strain Coach card + Goals status card → `TodayView`. Sleep Planner section → `SleepView`. Live strain strip → `LiveView`. No new tabs.

## 2. Strain Coach

- **Morning target:** today's recovery → `StrainTarget`. No recovery yet → pending state.
- **TodayView card** (after hero section): `StrainGauge` with target-band marker, current day-strain fill, state line — e.g. "8.3 now → aim 13.8–15.8 · Building". Recomputed in `loadAll()` keyed on `repo.refreshSeq` (fires as BLE data lands) — no extra timer.
- **LiveView strip:** one line under the HR number — "Day strain 8.3 / target ~14.8".
- Strap disconnected → last computed strain + staleness hint (relative time of last sample).

## 3. Sleep Planner

- **Wake time source:** if `BehaviorStore.smartAlarmEnabled`, use `smartAlarmMinutes` (strap alarm) and show an alarm badge; else use `planner.wakeMinutes`, editable inline.
- **Tonight's need:** `need = baseNeed + 0.3 × currentDebt` (gradual debt repayment).
- **Goal levels:** Peak = 100 %, Perform = 85 %, Get By = 70 % of tonight's need.
- **Bedtime:** `inBed = needForGoal / personalEfficiency` where efficiency = personal typical from history, default 0.90, floor 0.75. `bedtime = wakeTime − inBed`. Rendered relative ("23:10 tonight"), correct across the midnight boundary.
- **UI:** card at top of SleepView — 3 goal chips, large recommended bedtime, breakdown rows (base need, + debt repayment, − efficiency adjustment), wake-time row.
- **Bedtime reminder (iOS only):** toggle in the card. New `BedtimeReminderScheduler` in `StrandiOS/System/` (mirrors `JournalReminderScheduler`): non-repeating `UNCalendarNotificationTrigger` 30 min before tonight's recommended bedtime, rescheduled on each data refresh. macOS: card only (no background lane).

## 4. Performance Report

- **`ReportView.swift`** with period picker: **Weekly** (last 7 full days) / **Monthly** (last 28).
- **`PerformanceReport.swift`** computes from `[DayMetrics]`:
  - Header: date range, data coverage (days with data / period length).
  - Recovery: average, Δ vs prior period, best/worst day, HRV + RHR trend direction.
  - Sleep: avg duration vs need, performance, consistency, debt trajectory.
  - Strain: avg + total, distribution, days over/under the strain target (reuses `StrainTarget`).
  - Takeaways: rule-based bullets (debt grew/shrank by X, N overreach days, HRV trending up/down).
- Charts reuse `TrendChart` / `Sparkline` / `StatePill`. Δ vs prior period requires 2× window of data; if missing, the comparison row is hidden (not zeroed).

## 5. Goals

- **Kinds:** `sleepDuration` (min/night), `weeklyStrain` (avg day strain), `dailySteps`. Max one active goal per kind.
- **Adherence:** computed at read from `metricSeries`. `sleepDuration` and `dailySteps`: % of days hit in the current week + current streak (consecutive hit days). `weeklyStrain`: current week's average day strain vs target (progress %, no streak).
- **`GoalsView.swift`:** active goals as progress cards (ring + streak + 7-day dot row), add-goal sheet (kind picker + target slider with per-kind sensible ranges), archive action.
- **TodayView:** compact goal-status chip row (hit / on track / behind per active goal). Hidden when no goals exist.

## 6. Error handling

- Every card/screen has an explicit empty state ("Need a night of data", "No recovery yet today", "Set a goal to start"). No silent blanks.
- Planner with no sleep history → defaults (need 450 min, efficiency 0.90) and a "based on defaults" caption.
- Report with zero data days in period → full-screen empty state, picker still usable.

## 7. Testing

Unit tests in `StrandTests` (macOS host):
- `StrainTarget`: mapping at recovery 0/50/100, clamping, band edges, state classification.
- `SleepPlanner`: no-history defaults, midnight wrap, debt-repayment portion, goal-level scaling, efficiency floor.
- `PerformanceReport`: empty period, partial coverage, Δ hidden when prior window missing.
- Goal adherence: streak math, week boundary, no-data days.

## 8. Verification & ship

1. Build macOS + iOS (xcodegen → xcodebuild), tests green.
2. iOS simulator: `NOOP_SCREEN` harness screenshots of TodayView (coach + goals cards), SleepView (planner), ReportView, GoalsView; mobile layout per ViewThatFits/size-class rules.
3. Bump build number, archive, upload to TestFlight (icon alpha-channel fix already in pipeline).

## Design notes

- Implementation uses the frontend-design skill for the new cards/screens.
- The `StrainTarget` curve is a documented approximation of WHOOP's recovery→exertion guidance, not a reverse-engineered formula; constants live in one place for tuning.
