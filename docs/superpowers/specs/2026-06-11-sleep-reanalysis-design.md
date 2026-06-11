# Sleep Re-analysis — Design Spec

**Date:** 2026-06-11
**Why:** Sleep staging is computed once per night and cached behind the `intel_hr_frontier`
incremental gate (`IntelligenceEngine.analyzeRecent`). When the staging algorithm changes
(e.g. the deep/REM fixes), already-cached nights keep their stale results — there is no way
to force a recompute. Dev-process need: re-analyze last night, or everything, on demand.

## Goals

1. Button(s) to force re-analysis of sleep from stored raw streams — last night and full window
2. Stale-row safety: a re-analyzed night must not leave orphaned computed sessions behind
   (sessions upsert keyed by `(deviceId, startTs)`; a changed onset would duplicate)
3. Raw-data safety: never delete a computed night the engine cannot recreate (raw streams
   may be trimmed/absent for old nights)
4. Reuse the existing pipeline — no second analysis path

## Non-goals

- Re-analyzing imported WHOOP nights (no raw streams exist for them; imported rows are
  never touched)
- Any change to the staging algorithm itself
- Android parity

## Architecture

### 1. `ReanalysisScope` + force mode on `IntelligenceEngine.analyzeRecent`

```swift
enum ReanalysisScope {
    case lastNight    // forces day offsets 0 and 1 (covers the midnight edge: the most
                      // recent sleep may have ENDED on yesterday's UTC day)
    case everything   // forces all maxDays offsets

    /// Pure helper — the only logic worth unit-testing in isolation.
    func forcesOffset(_ offset: Int) -> Bool
}
```

`analyzeRecent(maxDays: Int = 21, force: ReanalysisScope? = nil)`:

- The per-day skip gate (`to <= frontier && cachedByDay[day] != nil`,
  IntelligenceEngine.swift:124) additionally requires `force?.forcesOffset(offset) != true`.
  Forced days always re-read the raw streams and re-run `AnalyticsEngine.analyzeDay`.
- Everything else — staging, two-pass baselines, recovery re-score, workout re-derivation,
  daily upsert — is the existing path, unchanged.
- The frontier cursor update at the end of the run is unchanged (forced runs don't move it
  backwards).
- `skinMeanMemo` behavior unchanged; forced days simply overwrite their memo entries.

### 2. Stale-session cleanup (raw-data-safe)

Inside the per-day loop, when `force` covers the day AND the fetched raw HR stream is
non-empty (the same emptiness check the engine already uses to skip dead days): delete
computed sleep sessions attributed to that day BEFORE upserting the fresh result.
Attribution mirrors the engine's own rule (sessions whose END falls on the UTC day):

```swift
// New API in Packages/WhoopStore/Sources/WhoopStore/MetricsCache.swift:
/// Deletes sleep sessions whose endTs ∈ [endFrom, endTo) for the given device id.
public func deleteSleepSessions(deviceId: String, endFrom: Int, endTo: Int) async throws -> Int
```

The engine calls it with the forced day's UTC bounds and the computed namespace id
(`deviceId + "-noop"`). Imported sessions live under a different device id — untouchable
by construction. Raw-empty days skip the delete entirely, so a night whose raw rows were
trimmed keeps its old computed result (goal 3).

### 3. Settings UI — "Re-analysis" section card

New section card in `Strand/Screens/SettingsView.swift`, placed after "Backup & restore",
following the existing section-card helper idiom:

- **"Re-analyze last night"** → `await intelligence.analyzeRecent(force: .lastNight)`
- **"Re-analyze everything"** (caption: "Recomputes the last 21 nights from raw strap
  data. Nights without raw data keep their current values.") →
  `await intelligence.analyzeRecent(force: .everything)`
- Both disabled while `intelligence.computing`; a `ProgressView` shows while running.
- Result line after completion from the engine's published `note` (e.g. "Re-analyzed N
  nights"); engine sets it at the end of a forced run.
- `IntelligenceEngine` reaches SettingsView the same way other dependencies do (it already
  lives in AppModel; inject as `@EnvironmentObject` if not already available — follow the
  pattern the Intelligence screen uses).

No confirmation dialog: the action is recompute-from-source, not destructive (goal 3
guarantees nothing is deleted that can't be recreated).

The shared view means the card appears on iOS and macOS automatically.

### 4. Data flow after a run

The engine's existing end-of-run repository refresh bumps `refreshSeq`; `SleepInputKey`
already keys on it, so SleepView (and the rest) pick up recomputed nights without extra
wiring. Verify this refresh exists on the forced path; add the repo refresh call if the
current code only refreshes on the non-empty-upsert path.

## Localization

New strings (String Catalog + German, du-form): section title "Re-analysis", the two
button labels, the "everything" caption, and the "Re-analyzed %lld nights" note.

## Testing

- `WhoopStoreTests`: `deleteSleepSessions` — insert sessions under two device ids with
  ends inside/outside the range; assert only in-range rows of the target device id die.
- `StrandTests` (or wherever pure helpers are tested in-app): `ReanalysisScope.forcesOffset`
  — lastNight → {0, 1} only; everything → all.
- Manual: Settings button on simulator with seeded store; verify SleepView re-renders and
  the note appears. Build both platforms.

## Out of scope (recorded)

- A per-night re-analyze (long-press a night in a list) — YAGNI for the dev workflow.
- Surfacing re-analysis on the Sleep screen itself (decided: Settings only).
