# NOOP Journal — Design Spec

**Date:** 2026-06-09
**Status:** Approved (design), pending implementation plan
**Topic:** Native daily habit/behaviour journaling, WHOOP-Journal style, fully integrated.

## Goal

Let the user log daily behaviours (alcohol, caffeine, meditation, late meal, …) and
see which habits move their recovery / HRV / sleep. Asked every morning; can review
yesterday's and any past day's entry. The journal must feed NOOP's **already-built**
correlation analysis so logged behaviours light up Insights with no engine changes.

## Core principle: build only the capture half

The *analysis* half already exists and ships:

- `JournalEntry(day, question, answeredYes, notes)` — `WhoopStore/JournalWorkoutAppleCache.swift`.
  Natural key `(deviceId, day, question)`. The `journal` SQLite table exists.
- Store API: `upsertJournal(_:deviceId:)` (write, idempotent ON CONFLICT) and
  `journalEntries(deviceId:from:to:)` (read).
- `Repository.journalEntries()` read passthrough.
- `WhoopImporter` writes journal rows from WHOOP's `journal_entries.csv`.
- `InsightsView` — the "what affects what" screen: behaviour effects via
  `StrandAnalytics.BehaviorInsights.rank` (Cohen's d, with/without means, significance,
  sign-aware tint, plain-English sentence) + curated Pearson `Relationship`s.

So we build the **capture** half (logging UI, catalog, morning prompt, history) and
**surface** it. Reuse, don't reinvent.

## Decisions (confirmed with the user)

1. **Answer model:** yes/no + optional free-text note. Feeds the binary Insights engine
   directly; unifies 1:1 with imported WHOOP journal. (No numeric amounts in v1.)
2. **Placement:** a morning-prompt card on the Today home screen + a full Journal screen
   under More → Insights (next to Insights). No new bottom tab.
3. **Morning prompt:** iOS local notification at a user-chosen time (default ~08:00) that
   deep-links into logging yesterday, **plus** a persistent Today card until logged.
4. **Question set:** curated WHOOP-aligned catalog, toggleable, grouped by category;
   custom questions deferred (YAGNI).

## Correctness: the day-key join convention (resolved from code, not guessed)

The `day` field is the join key in two ways: it unifies a logged entry with an imported
one `(deviceId, day, question)`, **and** `InsightsView` joins a behaviour to an outcome
on `behaviour.day == outcome.day`. Getting it wrong silently correlates habits against the
wrong day and stops native/imported entries from merging.

Evidence from `Strand/Data/WhoopImporter.swift`:

- Recovery / strain / HRV / sleep are filed under `dayString(c.cycleStart, tzOffsetMin:)`
  (lines 18, 64–65).
- Journal entries are filed under `dayString(j.cycleStart, tzOffsetMin:)` (line 127).

**They use the identical key.** Therefore recovery[day] and journal[day] already join, and
a native entry written under the same key both unifies with imports and joins to the right
outcome row.

**Rule (write into code + tests):**
- Native logging writes `JournalEntry.day = Repository.localDayKey(targetDate)` under
  `repo.deviceId` — the same convention as the importer.
- The morning prompt's default `targetDate` = **yesterday** (the just-completed cycle):
  `Calendar.current.date(byAdding: .day, value: -1, to: Date())`. Editable in the sheet.
- We deliberately do **not** introduce a different lag for native data: matching the
  shipped convention keeps native and imported entries identical in Insights.

## Unification: catalog strings must match WHOOP verbatim

`InsightsView` groups behaviours by the raw `question` string. A hand-authored "Alcohol"
will **not** merge with WHOOP's exported "Did you drink any alcohol?" — they become two
separate behaviours. The real-export fixture
(`Packages/StrandImport/Tests/StrandImportTests/Resources/journal_entries.csv`) confirms
WHOOP phrases questions as full sentences:

```
Did you drink any alcohol?
Did you have any caffeine?
```

(The shorthand strings in unit tests — "Alcohol?", "Caffeine?" — are NOT real export text.)

**Two-pronged guarantee:**
1. `JournalCatalog` stores WHOOP-style verbatim question text as the canonical key.
2. On load, the Journal absorbs any **distinct `question` strings already present in the
   user's imported journal** as tracked behaviours, so logged + imported always merge
   regardless of minor phrasing drift in the curated list. The catalog is the single
   source of truth and is trivial to correct.

During implementation, reconcile the curated strings against (a) the user's imported
distinct questions and (b) WHOOP's current journal phrasing.

## Components

### Data
- **`Strand/Data/JournalCatalog.swift`** (new) — mirrors `MetricCatalog`. A
  `JournalBehavior { id, question (verbatim), shortLabel, category, icon, goodWhenYes: Bool? }`
  and a static curated list grouped by category
  (Substances · Nutrition · Activity · Mind & Sleep · Environment). `goodWhenYes` is a
  display hint only (tint), not analysis input.
- **`Strand/Data/JournalStore.swift`** (new) — `@MainActor ObservableObject`, UserDefaults-
  backed (single-user on-device, like `BehaviorStore`): tracked behaviour ids (default =
  a sensible core subset), reminder enabled + minutes-since-midnight, last-logged day key.
- **`Strand/Data/Repository.swift`** (edit) — add
  `func saveJournal(_ rows: [JournalEntry]) async` → `store.upsertJournal(rows, deviceId: deviceId)`
  then `await refresh()` (so Insights/history reload). Also expose distinct imported
  questions for the absorb step (reuse `journalEntries()`).

### Screens (shared SwiftUI on `StrandDesign`; identical code on macOS and iOS)
- **`Strand/Screens/JournalView.swift`** (new) — built on `ScreenScaffold`, `NoopCard`,
  `SectionHeader`, `StatTile`, `SegmentedPillControl`, `StatePill`, `StrandPalette`,
  `StrandFont`, `NoopMetrics`.
  - **Log section:** date selector (default yesterday). Tracked behaviours grouped by
    category, each a Yes / No / — control with an optional note field. Progress
    ("6 of 9 logged"). Save writes via `Repository.saveJournal`.
  - **History section:** past days (descending). Each row shows the day's logged
    behaviours as chips alongside **that day's recovery** (from `repo.days`) so the
    habit↔outcome relationship reads at a glance. Tap a day → edit (re-opens log for it).
  - **Footer:** link to `InsightsView` ("See what moves your recovery →").
- **`Strand/Screens/TodayView.swift`** (edit) — inject a `MorningJournalCard`: visible when
  today's prompt is unmet ("Log yesterday's journal" + 1-tap entry); collapses to a compact
  "Journaled ✓" once `JournalStore.lastLoggedDay == today`.
- **Journal settings:** a section (in `SettingsView` or a small `JournalSettingsView`):
  toggle which behaviours are tracked, reminder on/off + time.

### Morning prompt (iOS)
- **`StrandiOS/System/JournalReminderScheduler.swift`** (new) — `UNUserNotificationCenter`
  daily repeating local notification at the chosen time ("Good morning — how did yesterday
  go? Log your journal."). Authorization requested on first enable; reschedules when the
  time changes; cancels when disabled.
- **Deep-link route:** a published `pendingJournalDay: String?` on the app/route model.
  Notification tap sets it to yesterday's key; the iOS shell (`RootTabView`) reacts on
  launch/foreground by routing to More → Journal and presenting the log sheet for that day.
- Today card is the always-visible fallback for a missed/denied notification.

### Nav wiring
- `StrandiOS/App/RootTabView.swift` (edit): add a "Journal" link in the More → Insights
  section.
- `Strand/App/RootView.swift` (edit): add the same to the macOS sidebar so the screen is
  reachable on both platforms (capture stays cross-platform; only the notification
  scheduler is iOS-only).

### Insights (no engine change — verify only)
- Logged entries under `deviceId` flow into `InsightsView` automatically. Ensure its load
  re-runs after a save (it keys on `repo.loaded`; `saveJournal` calls `refresh()` which
  bumps `refreshSeq`/`loaded`). Update the empty-state copy: "Import your WHOOP export …
  **or start logging in Journal** to unlock them."

## Data flow

```
Morning notification (iOS)  ─┐
Today MorningJournalCard    ─┼─→ JournalView (log, target=yesterday)
More → Journal              ─┘            │
                                          ▼
                          Repository.saveJournal([JournalEntry])
                                          │ upsertJournal(deviceId)
                                          ▼
                                   journal table (SQLite)
                                          │
                 ┌────────────────────────┼────────────────────────┐
                 ▼                         ▼                         ▼
        JournalView history        InsightsView (unchanged)   imported WHOOP journal
        (chips + recovery)         BehaviorInsights.rank      (same key → merges)
```

## Error / edge handling
- No tracked behaviours / nothing logged yet → friendly empty states (match existing
  `ComingSoon`/`NoopCard` copy patterns).
- Notification permission denied → keep the Today card; surface a one-line note in Journal
  settings ("Enable notifications in Settings to get the morning reminder").
- Editing a past day re-upserts (idempotent by natural key) — no duplicates.
- Day rollover: card/prompt recompute against the live local day; reminder repeats daily.
- macOS has no local-notification scheduler in v1 (card + manual entry only); the screen
  itself works there.

## Testing & verification
- **Unit:** `JournalCatalog` exposes verbatim WHOOP strings; `JournalStore` persists tracked
  set + reminder prefs across reinit; `Repository.saveJournal` round-trips into
  `journalEntries()`; logged `day` equals the importer's `dayString(cycleStart)` convention
  for the same calendar day; absorb step picks up distinct imported questions.
- **iOS simulator (explicit acceptance criterion from the request):** boot the iOS sim →
  open Journal from the Today card → log yesterday → Today card flips to "Journaled ✓" →
  shift the clock/day → fresh morning prompt appears → history shows the prior day with its
  recovery → with enough overlap, Insights surfaces a behaviour effect. Capture screenshots.

## Out of scope (v1)
- Numeric amounts / 1–5 scales (engine is binary).
- Fully custom user-authored questions (catalog is curated + auto-absorbed imports).
- macOS local-notification morning reminder.
- Android (capture UI is SwiftUI; Android is a separate codebase).

## File summary (~7)
| File | Change |
|---|---|
| `Strand/Data/JournalCatalog.swift` | new — behaviour catalog, verbatim strings |
| `Strand/Data/JournalStore.swift` | new — tracked set + reminder prefs (UserDefaults) |
| `Strand/Screens/JournalView.swift` | new — log + history screen |
| `StrandiOS/System/JournalReminderScheduler.swift` | new — iOS local notifications + route |
| `Strand/Data/Repository.swift` | edit — `saveJournal(_:)` |
| `Strand/Screens/TodayView.swift` | edit — `MorningJournalCard` |
| `StrandiOS/App/RootTabView.swift`, `Strand/App/RootView.swift` | edit — nav link |
| `Strand/Screens/InsightsView.swift` | edit — empty-state copy |
