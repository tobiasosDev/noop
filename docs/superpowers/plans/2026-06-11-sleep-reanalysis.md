# Sleep Re-analysis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Settings buttons to force re-analysis of sleep staging (last night / last 21 nights) from stored raw streams, bypassing the `intel_hr_frontier` cache gate, with stale-session cleanup that can never delete a night it can't recreate.

**Architecture:** A `ReanalysisScope` force mode threads through `IntelligenceEngine.analyzeRecent`'s existing per-day loop: forced days skip the frontier/cached gate, delete their computed `-noop` sleep sessions (only when raw HR is present), and recompute via the unchanged `AnalyticsEngine` path. One new ranged-delete API in WhoopStore (modeled on the existing `deleteWorkouts` precedent). UI is one new `SettingsSection` card.

**Tech Stack:** Swift/SwiftUI (shared iOS+macOS), GRDB (WhoopStore package), XCTest, XcodeGen, String Catalog.

**Spec:** `docs/superpowers/specs/2026-06-11-sleep-reanalysis-design.md`
**Branch:** `add-sleep-reanalysis` (stacked on `redesign-sleep-screen`, already checked out)

---

## File structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Packages/WhoopStore/Sources/WhoopStore/MetricsCache.swift` | Modify | New `deleteSleepSessions(deviceId:endFrom:endTo:)` |
| `Packages/WhoopStore/Tests/WhoopStoreTests/MetricsCacheTests.swift` | Modify | Test for the delete API |
| `Strand/Data/IntelligenceEngine.swift` | Modify | `ReanalysisScope` enum + force mode in `analyzeRecent` |
| `StrandTests/JournalLogicTests.swift` | Modify | Fix pre-existing main-actor compile error (unblocks the suite) |
| `StrandTests/ReanalysisScopeTests.swift` | Create | Pure scope-helper test |
| `Strand/Screens/SettingsView.swift` | Modify | "Re-analysis" section card |
| `Strand/Resources/Localizable.xcstrings` | Modify | New keys + German |

Key facts for the implementer:
- `IntelligenceEngine` is constructed with `deviceId: "my-whoop"` (AppModel.swift:128) and persists computed rows under `computedId = deviceId + "-noop"`.
- `StrandApp.swift:17` already injects `model.intelligence` via `.environmentObject` — SettingsView just declares it.
- The store-write idiom is `try syncWrite { db in ... }` (see `upsertSleepSessions`, MetricsCache.swift:71). A ranged-delete precedent exists: `deleteWorkouts(deviceId:sport:from:to:)` referenced at IntelligenceEngine.swift:265.
- WhoopStore tests use `WhoopStore.inMemory()` and the reader `store.sleepSessions(deviceId:from:to:limit:)` (MetricsCacheTests.swift:8, :30).
- **`StrandTests` currently does not compile** — `JournalLogicTests.swift:17/:25` call `@MainActor Repository.mergeJournal` from nonisolated methods (pre-existing on main, upstream aa219e2). Task 1 fixes that so later tasks can run the suite.
- Never use `#if DEBUG` anywhere — it silently doesn't compile in this project setup.

---

### Task 1: Unblock StrandTests (pre-existing main-actor compile error)

**Files:**
- Modify: `StrandTests/JournalLogicTests.swift`

- [ ] **Step 1.1: Add `@MainActor` to the test class**

The file's test methods call main-actor-isolated `Repository.mergeJournal` from nonisolated contexts. Annotate the whole class (smallest honest fix, matches how other test files handle main-actor APIs):

```swift
@MainActor
final class JournalLogicTests: XCTestCase {
```

(If the class is already split or the error points at only two methods, annotating just those two methods is equally fine — whichever makes the suite compile with the smallest diff.)

- [ ] **Step 1.2: Run the suite — must be GREEN now**

```bash
cd /Users/tobiasluscher/Development/noop
xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests -quiet 2>&1 | tail -10
```
Expected: all tests pass (86 as of the last verified run), zero compile errors.

- [ ] **Step 1.3: Commit**

```bash
git add StrandTests/JournalLogicTests.swift
git commit -m "test: fix JournalLogicTests main-actor isolation compile error"
```

---

### Task 2: `deleteSleepSessions` store API (TDD)

**Files:**
- Modify: `Packages/WhoopStore/Sources/WhoopStore/MetricsCache.swift`
- Test: `Packages/WhoopStore/Tests/WhoopStoreTests/MetricsCacheTests.swift`

- [ ] **Step 2.1: Write the failing test** (append inside `MetricsCacheTests`):

```swift
func testDeleteSleepSessionsByEndRange() async throws {
    let store = try await WhoopStore.inMemory()
    // Three sessions for the target device: ends at 1_000, 5_000, 9_000.
    let mk = { (start: Int, end: Int) in
        CachedSleepSession(startTs: start, endTs: end, efficiency: 0.9,
                           restingHr: 50, avgHrv: 60, stagesJSON: nil)
    }
    try await store.upsertSleepSessions([mk(500, 1_000), mk(4_000, 5_000), mk(8_000, 9_000)],
                                        deviceId: "devA-noop")
    // Same shape under ANOTHER device id — must survive untouched.
    try await store.upsertSleepSessions([mk(4_000, 5_000)], deviceId: "devB")

    // Delete devA-noop sessions ending in [2_000, 6_000) → only the end=5_000 row dies.
    let n = try await store.deleteSleepSessions(deviceId: "devA-noop", endFrom: 2_000, endTo: 6_000)
    XCTAssertEqual(n, 1)

    let a = try await store.sleepSessions(deviceId: "devA-noop", from: 0, to: 100_000, limit: 100)
    XCTAssertEqual(a.map(\.endTs).sorted(), [1_000, 9_000])
    let b = try await store.sleepSessions(deviceId: "devB", from: 0, to: 100_000, limit: 100)
    XCTAssertEqual(b.count, 1, "other device ids must be untouched")
}
```

- [ ] **Step 2.2: Run — must FAIL to compile** (`deleteSleepSessions` doesn't exist):

```bash
swift test --package-path Packages/WhoopStore --filter MetricsCacheTests 2>&1 | tail -5
```
Expected: compile error "value of type 'WhoopStore' has no member 'deleteSleepSessions'".

- [ ] **Step 2.3: Implement** (in `MetricsCache.swift`, next to `upsertSleepSessions`, same `syncWrite` idiom):

```swift
/// Delete sleep sessions whose endTs falls in [endFrom, endTo) for the given device id.
/// Used by forced re-analysis to clear a day's computed sessions (attribution = the UTC
/// day the session ENDS on) before re-upserting fresh results — without this, a staging
/// change that shifts a session's startTs would orphan the old row under the
/// (deviceId, startTs) natural key. Returns rows deleted.
@discardableResult
public func deleteSleepSessions(deviceId: String, endFrom: Int, endTo: Int) async throws -> Int {
    try syncWrite { db in
        try db.execute(sql: """
            DELETE FROM sleepSession
            WHERE deviceId = ? AND endTs >= ? AND endTs < ?
            """, arguments: [deviceId, endFrom, endTo])
        return db.changesCount
    }
}
```

- [ ] **Step 2.4: Run — must PASS:**

```bash
swift test --package-path Packages/WhoopStore --filter MetricsCacheTests 2>&1 | tail -5
```
Expected: all MetricsCacheTests pass including the new one.

- [ ] **Step 2.5: Run the whole package suite** (regression):

```bash
swift test --package-path Packages/WhoopStore 2>&1 | tail -3
```
Expected: pass.

- [ ] **Step 2.6: Commit**

```bash
git add Packages/WhoopStore
git commit -m "feat(store): ranged deleteSleepSessions for forced re-analysis"
```

---

### Task 3: `ReanalysisScope` (TDD)

**Files:**
- Modify: `Strand/Data/IntelligenceEngine.swift` (enum only in this task)
- Create: `StrandTests/ReanalysisScopeTests.swift`

- [ ] **Step 3.1: Write the failing test:**

```swift
import XCTest
@testable import Strand

final class ReanalysisScopeTests: XCTestCase {

    func testLastNightForcesOnlyTheTwoNewestOffsets() {
        XCTAssertTrue(ReanalysisScope.lastNight.forcesOffset(0))
        XCTAssertTrue(ReanalysisScope.lastNight.forcesOffset(1),
                      "the most recent sleep may have ENDED on yesterday's UTC day")
        XCTAssertFalse(ReanalysisScope.lastNight.forcesOffset(2))
        XCTAssertFalse(ReanalysisScope.lastNight.forcesOffset(20))
    }

    func testEverythingForcesAllOffsets() {
        for offset in 0..<21 {
            XCTAssertTrue(ReanalysisScope.everything.forcesOffset(offset))
        }
    }
}
```

NOTE: if `@testable import Strand` is not how the existing StrandTests import the app module, copy the import line from `JournalLogicTests.swift` instead. New test files in `StrandTests/` are picked up by the XcodeGen glob — run `xcodegen generate` before building.

- [ ] **Step 3.2: Run — must FAIL** (`ReanalysisScope` doesn't exist):

```bash
xcodegen generate
xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests/ReanalysisScopeTests -quiet 2>&1 | tail -5
```
Expected: compile error "cannot find 'ReanalysisScope'".

- [ ] **Step 3.3: Implement** — add at the top level of `Strand/Data/IntelligenceEngine.swift` (above the class):

```swift
/// Scope of a FORCED re-analysis: bypasses the `intel_hr_frontier` incremental gate so
/// already-cached nights are recomputed from raw streams (needed whenever the staging
/// algorithm changes — cached results are otherwise reused forever).
enum ReanalysisScope {
    /// Forces day offsets 0 and 1 — the most recent sleep may have ENDED on
    /// yesterday's UTC day when re-analysis runs before tonight's offload.
    case lastNight
    /// Forces every offset in the analysis window.
    case everything

    func forcesOffset(_ offset: Int) -> Bool {
        switch self {
        case .lastNight:  return offset <= 1
        case .everything: return true
        }
    }
}
```

- [ ] **Step 3.4: Run — must PASS** (same command as 3.2). Expected: 2 tests pass.

- [ ] **Step 3.5: Commit**

```bash
git add Strand/Data/IntelligenceEngine.swift StrandTests/ReanalysisScopeTests.swift
git commit -m "feat(intel): ReanalysisScope — forced re-analysis day selection"
```

---

### Task 4: Force mode in `analyzeRecent`

**Files:**
- Modify: `Strand/Data/IntelligenceEngine.swift`

Line references are to the file at branch point (647ed5a); locate by the quoted code if drifted.

- [ ] **Step 4.1: Signature** — `func analyzeRecent(maxDays: Int = 21)` becomes:

```swift
func analyzeRecent(maxDays: Int = 21, force: ReanalysisScope? = nil) async {
```

Existing callers (AppModel.swift:181, IntelligenceView.swift:45/:48) pass no `force` — unchanged.

- [ ] **Step 4.2: Gate bypass** — the per-day skip gate (~line 124):

```swift
if to <= frontier, let cached = cachedByDay[day] {
```
becomes:
```swift
if force?.forcesOffset(offset) != true, to <= frontier, let cached = cachedByDay[day] {
```

- [ ] **Step 4.3: Stale-session cleanup + forced-night counter** — directly AFTER the raw-stream fetches for the day (the `let hr = ...` block and its siblings) and any existing empty-raw early-`continue`, add:

```swift
// Forced re-analysis: clear this day's computed sessions BEFORE the fresh upsert.
// Attribution mirrors the engine's own rule (a session belongs to the UTC day it ENDS
// on). Gated on non-empty raw HR so a night whose raw rows were trimmed keeps its old
// result — re-analysis must never delete what it cannot recreate.
if force?.forcesOffset(offset) == true, !hr.isEmpty {
    let dayMidnightUtc = dayStart - dayStart % 86_400
    _ = try? await store.deleteSleepSessions(deviceId: computedId,
                                             endFrom: dayMidnightUtc,
                                             endTo: dayMidnightUtc + 86_400)
    forcedNights += 1
}
```

and declare the counter next to the other per-run accumulators (near `var scoredNights ...`):

```swift
var forcedNights = 0   // forced days that actually had raw data to recompute
```

IMPORTANT placement check: if the engine `continue`s on empty raw HR before this point, the `!hr.isEmpty` condition is redundant but harmless — keep it anyway (it documents the safety invariant and survives reordering).

- [ ] **Step 4.4: Forced-run note** — at the end of the run, after the existing `note = out.isEmpty ? ... : nil` assignment, add:

```swift
if force != nil {
    note = String(localized: "Re-analyzed \(forcedNights) nights")
}
```

- [ ] **Step 4.5: Confirm refresh propagation** — read the end-of-run block: `if !dailies.isEmpty { await repo.refresh() }` already exists (line ~282). Forced days with raw data always produce dailies, so the refresh fires and `refreshSeq` invalidates `SleepInputKey`. No change needed — just confirm it's still there.

- [ ] **Step 4.6: Build both platforms:**

```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug build -quiet
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS Simulator' -configuration Debug build -quiet
```
Expected: both BUILD SUCCEEDED.

- [ ] **Step 4.7: Commit**

```bash
git add Strand/Data/IntelligenceEngine.swift
git commit -m "feat(intel): force mode — frontier bypass + stale-session cleanup per forced day"
```

---

### Task 5: Settings "Re-analysis" card

**Files:**
- Modify: `Strand/Screens/SettingsView.swift`

- [ ] **Step 5.1: Inject the engine** — next to the existing `@EnvironmentObject` declarations (lines ~12–15):

```swift
@EnvironmentObject private var intelligence: IntelligenceEngine
```

(`StrandApp.swift:17` already injects it app-wide; no wiring change needed.)

- [ ] **Step 5.2: Add the section card** — after the "Backup & restore" section (MARK at ~line 450), insert a new section using the file's private `SettingsSection` helper (icon + title + blurb + content, see ~line 813):

```swift
// MARK: - Re-analysis

private var reanalysisSection: some View {
    SettingsSection(icon: "arrow.triangle.2.circlepath",
                    title: "Re-analysis",
                    blurb: "Recompute sleep from the strap's raw data after algorithm changes. Nights without raw data keep their current values.") {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Task { await intelligence.analyzeRecent(force: .lastNight) }
            } label: {
                Label("Re-analyze last night", systemImage: "moon.zzz")
            }
            .disabled(intelligence.computing)

            Button {
                Task { await intelligence.analyzeRecent(force: .everything) }
            } label: {
                Label("Re-analyze everything", systemImage: "arrow.clockwise")
            }
            .disabled(intelligence.computing)

            if intelligence.computing {
                ProgressView().controlSize(.small)
            } else if let note = intelligence.note {
                Text(note)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
}
```

Match the surrounding sections' button styling exactly — if neighboring sections style their action buttons (e.g. `.buttonStyle`, tint, fonts), copy that idiom rather than leaving defaults. Add `reanalysisSection` to the section list in the body right after the backup section.

- [ ] **Step 5.3: Build both platforms** (commands as Step 4.6). Expected: both succeed.

- [ ] **Step 5.4: Commit**

```bash
git add Strand/Screens/SettingsView.swift
git commit -m "feat(settings): re-analysis card — force last night / everything"
```

---

### Task 6: Localization

**Files:**
- Modify: `Strand/Resources/Localizable.xcstrings`

- [ ] **Step 6.1: Add catalog entries** — manual entries, en + de stringUnits, `"extractionState": "manual"`, matching the file's existing JSON style exactly (read an existing entry first; do NOT reformat the file):

| key | de |
|-----|----|
| `Re-analysis` | `Neuanalyse` |
| `Re-analyze last night` | `Letzte Nacht neu analysieren` |
| `Re-analyze everything` | `Alles neu analysieren` |
| `Recompute sleep from the strap's raw data after algorithm changes. Nights without raw data keep their current values.` | `Berechnet den Schlaf nach Algorithmus-Änderungen aus den Rohdaten des Straps neu. Nächte ohne Rohdaten behalten ihre aktuellen Werte.` |
| `Re-analyzed %lld nights` | `%lld Nächte neu analysiert` |

Derivation check before adding: `forcedNights` is `Int` → `%lld`. The SettingsSection `title`/`blurb` params are `LocalizedStringKey` → keys extract verbatim; `Label("Re-analyze last night", ...)` is `LocalizedStringKey` too. The note is built with `String(localized:)` in Task 4.

- [ ] **Step 6.2: Validate + build:**

```bash
python3 -c "import json; json.load(open('Strand/Resources/Localizable.xcstrings')); print('JSON OK')"
xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug build -quiet
```
(Don't use `plutil -lint` — it rejects plain JSON on this machine.)

- [ ] **Step 6.3: Commit**

```bash
git add Strand/Resources/Localizable.xcstrings
git commit -m "l10n(settings): German for the re-analysis card"
```

---

### Task 7: Verification

- [ ] **Step 7.1: Full builds + all suites:**

```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug build -quiet
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS Simulator' -configuration Debug build -quiet
xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests -quiet 2>&1 | tail -5
swift test --package-path Packages/WhoopStore 2>&1 | tail -3
```
Expected: 2× BUILD SUCCEEDED, StrandTests fully green (incl. the previously-broken JournalLogicTests), WhoopStore package green.

- [ ] **Step 7.2: On-simulator smoke test.** Constraints: NEVER synthesize host mouse/keyboard events — use Maestro (installed) for any in-sim interaction. Check the NOOP_SCREEN harness has a settings case (`grep -n '"settings"' StrandiOS/App/RootTabView.swift`); add `case "settings": SettingsView()` if missing. Then:

```bash
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination "platform=iOS Simulator,name=iPhone 16 Pro" -configuration Debug build -quiet
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug-iphonesimulator/*.app | head -1)
xcrun simctl boot "iPhone 16 Pro" 2>/dev/null; xcrun simctl install booted "$APP"
SIMCTL_CHILD_NOOP_SCREEN=settings xcrun simctl launch --terminate-running-process booted com.tecminds.noop
```

Maestro flow: scrollUntilVisible "Re-analysis", screenshot, tap "Re-analyze last night", wait, screenshot the result note. Repeat launch with `-AppleLanguages "(de)"` and screenshot "Neuanalyse" card. Verify: buttons disabled while running, note appears ("Re-analyzed N nights" / "N Nächte neu analysiert" — N may be 0 on a dataless sim; that's a PASS for the UI contract).

- [ ] **Step 7.3: Spec walk** — confirm each Goals/Architecture bullet of the spec is implemented; flag any gap.

---

### Task 8: Submit

- [ ] **Step 8.1: Push + stacked PR** (gt is not synced for this repo — use git/gh):

```bash
git push -u origin add-sleep-reanalysis
gh pr create --base redesign-sleep-screen --head add-sleep-reanalysis \
  --title "feat: forced sleep re-analysis — last night / everything (dev tool)" \
  --body "## Summary
- Settings → Re-analysis card: force recompute of sleep staging from raw strap streams (last night = offsets 0+1, everything = full 21-day window), bypassing the intel_hr_frontier cache gate
- Stale-row safe: forced days delete their computed -noop sessions (keyed by end-day) before re-upsert — and ONLY when raw HR exists, so re-analysis can never destroy a night it can't recreate
- New WhoopStore API: deleteSleepSessions(deviceId:endFrom:endTo:) with test
- Drive-by: fixes the pre-existing JournalLogicTests main-actor compile error so StrandTests runs again
- German localization for all new strings

Stacked on #9 (redesign-sleep-screen). Spec: docs/superpowers/specs/2026-06-11-sleep-reanalysis-design.md

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```
