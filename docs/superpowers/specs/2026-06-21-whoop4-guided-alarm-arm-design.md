# Guided WHOOP 4 Alarm Arm (official-app-style connect → write → confirm)

Date: 2026-06-21
Branch: `fix-whoop4-alarm-payload`
Platform: iOS (Strand target). Android already has the equivalent toggle (#536).

## Problem

NOOP's WHOOP 4 firmware smart alarm arms fire-and-forget. `AutomationsView` toggles
`smartAlarmEnabled` → `AppModel.applySmartAlarm()` → `ble.armStrapAlarm(at:)`. If the strap is
not connected at that moment the BLE write is a silent no-op; the only feedback is a status row
that tells the user to "connect it (Live tab) and toggle again." This is the exact failure mode
the official WHOOP app avoids: it keeps the strap connected while setting the alarm and only
reports success once the strap acknowledges and stores it.

We want the iOS app to behave like the official app: tapping/enabling the alarm opens a dialog
that (1) ensures a live connection (connecting if needed), (2) writes the alarm bytes, and
(3) reads the alarm back to confirm the strap actually persisted it — surfacing each step and the
final result, with a phone-notification backup so the user is woken regardless.

## Settled facts (no longer in question)

- **SET_ALARM_TIME (cmd 66) payload for WHOOP 4 / Gen4 = `[0x01][unix u32 LE][0x00,0x00,0x00,0x00]`
  (9 bytes).** Triangulated across three independent reverse-engineering sources:
  - openwhoop (`packet_implementations.rs`, Gen4, golden-tested),
  - the official-app wire capture upstream shipped as #535 (byte-identical),
  - the captured frame `aa1000 57 23 70 42 01 {unix} 00000000 <crc32>` in the
    reverse-engineering-whoop write-up.
  The 20-byte form with embedded haptic/alarm_id is **WHOOP 5/MG (Gen5/Maverick) only**.
- **GET_ALARM_TIME (cmd 67)** request payload `[0x00]`; reply `[<3-byte cmd-resp prefix>,
  enabled u8, unix u32 LE]`.
- **DISABLE_ALARM = cmd 69**, **RUN_ALARM (test buzz) = cmd 68** — both already implemented on the
  branch (`disableStrapAlarm`, `testAlarmBuzz`).
- The branch already has the **read-back confirm loop** (`BLEManager.beginArmConfirm`,
  `FrameRouter.alarmReadback`/`frameContainsEpoch`, `LiveState.alarmArmConfirmed`). This work
  *wraps* that loop in a connection-aware UI; it does not re-derive any wire protocol.

## Design decisions (locked with user)

1. **Merge `upstream/main` first**, then build on the merged base.
2. **Actively connect, then arm** when the strap is not connected (official-app behavior).
3. **Confirm once + phone-notification backup.**
4. **Trigger**: present the sheet on enabling smart alarm and on wake-time change (debounced so
   scrubbing the time picker does not repeatedly present the sheet — present on settle/commit).
5. **Fallback**: schedule the phone-notification backup whenever smart alarm is ON, regardless of
   whether the firmware arm confirmed. The strap buzz is primary; the phone is the safety net.

## Phase 0 — Upstream merge

Merge `upstream/main` (currently 6.0.3) into the branch. Merge-base is `a96c2bfb` (v5.3.0);
branch is 3 ahead / 5 behind. Brings:
- **6.0.0** (`4b69da6f`): multi-device support + offline imports + experimental drivers.
- **#535** (in 6.0.0): WHOOP4 SET_ALARM payload fix — **byte-identical** to the branch's 7→9 fix.
- **#547** (`d094ff10`, 6.0.3): data-hygiene for bad-clock straps (cross-platform; iOS touches
  `HistoricalStreams`, `TimestampHeal`, `AppModel`, `Backfiller`, `IntelligenceEngine`,
  `TodayView`). Relevant given this user's strap's deep-discharge clock history; applies cleanly.

Dry-run merge produced exactly **4 conflicts**, all small:

| File | Conflict | Resolution |
|------|----------|------------|
| `Strand/BLE/Commands.swift` | `setAlarmPayload` comment + `getAlarmTime` payload | Bytes already identical. Keep one merged doc comment; keep branch's `getAlarmTime` `[0x00]` payload and the read-back doc. |
| `StrandTests/SetAlarmPayloadTests.swift` | add/add (both added a golden test) | Fold into one test asserting the 9 bytes `01 <unix4> 00 00 00 00`. |
| `Strand/Screens/AutomationsView.swift` | both edited the alarm card | Combine: keep upstream card structure + branch's read-back status row (later superseded by the sheet wiring in Component 4). |
| `project.yml` | version/build numbers | Adopt 6.0.3 base with tecminds distribution identity; reconcile iOS + widget build numbers (per `noop-testflight-release-flow`). |

**Gate:** `bun`/xcodebuild build + `StrandTests` green before any feature code. `BLEManager.swift`
merges without conflict.

## Component 1 — `AlarmArmCoordinator` (new state machine)

`@MainActor final class AlarmArmCoordinator: ObservableObject` — orchestrates the guided flow by
calling existing `BLEManager` methods and observing `LiveState`. No new wire/BLE protocol code.

```
enum ArmStep: Equatable {
    case idle
    case connecting          // ensuring a live link
    case syncingClock        // SET_CLOCK sent
    case writing             // SET_ALARM_TIME sent
    case confirming          // GET_ALARM_TIME read-back in flight
    case confirmed(epoch: UInt32)
    case failed(ArmFailure)
}
enum ArmFailure: Equatable { case noLink, notStored, cancelled }
```

- `@Published private(set) var step: ArmStep = .idle`
- `func arm(wakeDate: Date)`:
  1. If `!live.connected` → `step = .connecting`; call `ble.connect()` and `ble.scanForWhoops()`;
     await `live.connected == true` with a ~20s timeout → on timeout `step = .failed(.noLink)`.
  2. `step = .syncingClock` then `.writing` (driven from `ble.armStrapAlarm(at:)`, which already
     does SET_CLOCK → SET_ALARM → `beginArmConfirm`).
  3. `step = .confirming`; observe `live.alarmArmConfirmed`: `true → .confirmed(epoch)`,
     `false → .failed(.notStored)`, with a ~8s timeout → `.failed(.notStored)`.
- `func cancel()` → `step = .failed(.cancelled)` and stop observing.
- Per-step timeouts so the UI never hangs. The step labels for `syncingClock`/`writing` are short
  and may be coalesced visually; the meaningful gates are `connecting` and `confirming`.

Boundaries: depends only on `BLEManager` (methods) and `LiveState` (`connected`,
`alarmArmConfirmed`, `alarmArmedForEpoch`). Testable with a mock conforming to a small
`AlarmArmDriving` protocol (connect, scan, arm, observable connected/confirmed signals).

## Component 2 — `ArmAlarmSheet` (new SwiftUI view)

Modal sheet bound to an `AlarmArmCoordinator`. Renders steps as a vertical checklist:
- Connecting to your strap
- Setting the strap clock
- Writing the alarm
- Confirming it stored

Each row shows ✓ (done), a spinner (active), or a dim pending dot. Themed with `StrandPalette`
and `StrandFont`, matching existing cards. Terminal states:
- **Confirmed for HH:MM** — "Your strap will buzz your wrist even with NOOP closed." → Done.
- **Couldn't reach / store** — explains the phone backup is still set; actions **Retry** and
  **Keep my phone alarm** (dismiss). Honest copy: on-device firing not yet verified on this strap.

The sheet is non-dismissible by swipe while `connecting`/`confirming` are active (avoid a
half-armed state); a Cancel button maps to `coordinator.cancel()`.

## Component 3 — `WakeAlarmNotifier` (new, phone backup)

Mirrors the established `IllnessNotifier` / `BatteryNotifier` / `WindDownNudge` pattern.
- `requestAuthorization([.alert, .sound])` the first time smart alarm is armed.
- `schedule(at wakeDate:)` — one `UNCalendarNotificationTrigger` (hour/minute) local notification
  with a fixed identifier (`"noop.wakeAlarm"`); scheduling replaces any prior one.
- `cancel()` removes the pending request.
- Called by the smart-alarm flow: schedule whenever smart alarm is ON (decision 5); cancel on
  disable. System-owned, so it fires even if NOOP is force-quit.
- `.timeSensitive` interruption level is a possible later enhancement (needs the Time Sensitive
  Notifications entitlement); v1 mirrors the existing notifiers (`.alert`/`.sound`) for
  consistency and to avoid an entitlement/provisioning change.

## Component 4 — `AutomationsView` wiring

- Enabling `smartAlarmEnabled` or changing the wake time (debounced on settle) presents
  `ArmAlarmSheet` and calls `coordinator.arm(wakeDate:)`. Replaces the current fire-and-forget
  `model.applySmartAlarm()` call path for the *arming* action.
- `WakeAlarmNotifier.schedule(at:)` is invoked whenever smart alarm is ON (independent of the
  firmware result).
- Disabling smart alarm → `ble.disableStrapAlarm()` + `WakeAlarmNotifier.cancel()`.
- The status row keeps reflecting `live.alarmArmConfirmed` for at-a-glance state between sheet
  presentations.
- Update the card blurb to describe the new connect-and-confirm flow + the always-on phone backup.

## Component 5 — Tests + on-device verification

Automated:
- `AlarmArmCoordinatorTests`: connect-timeout → `.failed(.noLink)`; already-connected →
  `.confirming` → `.confirmed`; read-back false → `.failed(.notStored)`; `cancel()` → `.cancelled`.
  Uses a mock `AlarmArmDriving`.
- `WakeAlarmNotifierTests`: next-occurrence date math (today vs tomorrow rollover), identifier
  reuse/replacement.
- Keep `SetAlarmPayloadTests` (merged) and `AlarmReadbackTests` green.

On-device (user, WHOOP 4):
1. Arm while already connected → expect Confirmed.
2. Arm while disconnected → dialog connects, then Confirmed.
3. Set a near-term wake, force-quit NOOP → verify strap buzz at time; verify phone notification
   fires as backup.
Haptic firing itself can only be verified on hardware (no motor in the simulator).

## Out of scope (YAGNI)

- Auto-re-arm on every reconnect / daily tick (Android #536 behavior). The existing daily
  re-arm in `AppModel` is retained as-is; no new re-arm scheduling in this work.
- WHOOP 5/MG guided arming (its firmware firing is still unconfirmed and gated behind
  Experimental). The sheet may be reused later but 5/MG arming logic is unchanged here.
- `.timeSensitive` entitlement (noted as a later enhancement).

## Risks / notes

- This user's strap had a 16-month deep-discharge ("acked-never-stored") history; a correct
  payload + confirm loop still cannot un-wedge firmware whose alarm store is corrupt. The
  read-back confirm + phone backup make that case *visible and survivable* rather than silent.
- 6.0.0 multi-device merge is the largest unknown; mitigated by the clean `BLEManager` merge and
  the build/test gate before feature work.
