# Guided WHOOP 4 Alarm Arm Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace NOOP's fire-and-forget WHOOP 4 firmware-alarm arming on iOS with an official-app-style guided flow that connects to the strap, writes the alarm, reads it back to confirm it stored, and schedules a phone-notification backup.

**Architecture:** A `@MainActor` `AlarmArmCoordinator` state machine drives the flow by calling existing `BLEManager` methods and observing `LiveState`; an `ArmAlarmSheet` renders the steps; a `WakeAlarmNotifier` (mirroring the existing `IllnessNotifier`/`BatteryNotifier` pattern) schedules the phone backup. A shared `WakeTime` helper computes the next wake instant. All built on top of a `upstream/main` merge done first.

**Tech Stack:** Swift / SwiftUI, Combine, UserNotifications, CoreBluetooth (via existing `BLEManager`), XcodeGen (`project.yml`), `xcodebuild` (macOS `Strand` scheme for the `StrandTests` suite).

## Global Constraints

- Deployment targets: `Strand`/`StrandTests` macOS **13.0**; `NOOPiOS` iOS **17.0**. Code must compile on both.
- After creating/removing any source file, regenerate the project: `xcodegen generate`.
- Build (macOS): `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
- Test (macOS app suite): `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test`
- Package tests where touched: `swift test` inside the package dir (e.g. `Packages/WhoopStore`).
- Test classes that touch `@MainActor` types (`LiveState`, `BLEManager`, `AlarmArmCoordinator`) MUST be annotated `@MainActor` to avoid actor-isolation compile errors (see prior `AlarmReadbackTests` isolation breakage).
- UI uses `StrandPalette` (colors) and `StrandFont` (type), matching existing cards.
- WHOOP 4 SET_ALARM payload is settled and pinned by `SetAlarmPayloadTests`: `[0x01][unix u32 LE][0x00,0x00,0x00,0x00]` (9 bytes). Do not change it.
- This guided flow targets **WHOOP 4**. WHOOP 5/MG arming stays gated behind the Experimental toggle and is unchanged.
- Branch: `fix-whoop4-alarm-payload`. Commit after every task. Do not push unless asked.

---

### Task 1: Merge `upstream/main` (Phase 0)

Bring in upstream 6.0.3 (6.0.0 multi-device + #535 payload + #547 bad-clock straps) and resolve the 4 known conflicts. No new feature code; the deliverable is a green merged tree.

**Files (resolve conflicts in):**
- `Strand/BLE/Commands.swift`
- `StrandTests/SetAlarmPayloadTests.swift`
- `Strand/Screens/AutomationsView.swift`
- `project.yml`

**Interfaces:**
- Produces (post-merge, relied on by later tasks): `WhoopCommand.setAlarmPayload(epochSec:) -> [UInt8]` (9 bytes); `BLEManager.armStrapAlarm(at: Date)`, `BLEManager.disableStrapAlarm()`, `BLEManager.getStrapAlarm()` (sends `getAlarmTime` payload `[0x00]`), `BLEManager.connect(model:)`, `BLEManager.scanForWhoops()`, `BLEManager.state: LiveState`; `LiveState.connected: Bool`, `LiveState.alarmArmConfirmed: Bool?`, `LiveState.alarmArmedForEpoch: UInt32?`; `BehaviorStore.smartAlarmEnabled: Bool`, `BehaviorStore.smartAlarmMinutes: Int`, `BehaviorStore.smartAlarmWeekdays` (from upstream); `AppModel.applySmartAlarm()`.

- [ ] **Step 1: Confirm clean tree and fetch**

Run:
```bash
cd /Users/tobiasluscher/Development/noop
git status --short        # expect empty
git fetch upstream
```
Expected: no output from `git status --short`; fetch succeeds.

- [ ] **Step 2: Start the merge**

```bash
git merge --no-ff upstream/main
```
Expected: `CONFLICT` in exactly these 4 files: `Strand/BLE/Commands.swift`, `Strand/Screens/AutomationsView.swift`, `StrandTests/SetAlarmPayloadTests.swift`, `project.yml`. Verify with `git diff --name-only --diff-filter=U`. If any OTHER file conflicts, stop and inspect before continuing.

- [ ] **Step 3: Resolve `StrandTests/SetAlarmPayloadTests.swift` — take upstream (superset)**

Upstream's test file is a strict superset of ours (adds the whole-frame wire-capture test). Take it:
```bash
git checkout --theirs StrandTests/SetAlarmPayloadTests.swift
git add StrandTests/SetAlarmPayloadTests.swift
```

- [ ] **Step 4: Resolve `Strand/BLE/Commands.swift` — take upstream payload + fix get-alarm doc**

Take upstream's version (its `setAlarmPayload` is byte-identical to ours, with the #535 comment):
```bash
git checkout --theirs Strand/BLE/Commands.swift
```
Then fix ONE doc inaccuracy: upstream's `getAlarmTime` doc says "Payload [0x01]" but the runtime request is `[0x00]` (`BLEManager.getStrapAlarm`). Edit the `case getAlarmTime = 67` doc comment in `Strand/BLE/Commands.swift` so it reads `Payload [0x00].` instead of `Payload [0x01].`, then:
```bash
git add Strand/BLE/Commands.swift
```

- [ ] **Step 5: Resolve `Strand/Screens/AutomationsView.swift` — take upstream (weekday-aware card)**

Upstream's alarm card is richer (adds `alarmWeekdayPicker` + `smartAlarmWeekdays`). Our branch's read-back status row will be re-added on top of upstream's structure in Task 6, so take upstream now:
```bash
git checkout --theirs Strand/Screens/AutomationsView.swift
git add Strand/Screens/AutomationsView.swift
```

- [ ] **Step 6: Resolve `project.yml` — upstream version, fork identity**

Open `project.yml`. Keep upstream's `MARKETING_VERSION` (6.0.3) and structural changes, but re-apply the tecminds distribution identity if upstream clobbered it: the fork's `DEVELOPMENT_TEAM`, bundle identifiers, and app icon settings for `NOOPiOS` and `NOOPiOSWidgets` (see commit `1ade1afd` for the exact identity values). Keep the iOS app and widget `CURRENT_PROJECT_VERSION` aligned to the same build number (per the TestFlight release flow). Then:
```bash
git add project.yml
```

- [ ] **Step 7: Complete the merge**

```bash
git diff --name-only --diff-filter=U   # expect empty
git commit --no-edit
```
Expected: no unresolved files; merge commit created.

- [ ] **Step 8: Regenerate, build, and test (the gate)**

```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test
(cd Packages/WhoopStore && swift test)
```
Expected: build succeeds; `StrandTests` all pass (incl. `SetAlarmPayloadTests`, `AlarmReadbackTests`); `WhoopStore` tests pass (incl. #547 `TimestampHealTests`). Fix any merge fallout (e.g. references to our removed `AutomationsView` status helpers) before proceeding — those helpers are intentionally re-added in Task 6, so any compile error here should be in non-alarm code; if `AutomationsView` fails to compile because something else referenced the removed helpers, that is expected to be nothing (the helpers were private to the view).

- [ ] **Step 9: Commit is already made in Step 7. Verify HEAD**

```bash
git log --oneline -1   # expect the merge commit
```

---

### Task 2: `WakeTime` helper (next wake instant)

A single source of truth for "the next Date at HH:MM", reused by the firmware arm and the phone notification. Removes the inline computation currently duplicated in `AppModel.applySmartAlarm()`.

**Files:**
- Create: `Strand/System/WakeTime.swift`
- Test: `StrandTests/WakeTimeTests.swift`
- Modify: `Strand/App/AppModel.swift` (the `applySmartAlarm()` date computation)

**Interfaces:**
- Produces: `enum WakeTime { static func next(minutesSinceMidnight: Int, from now: Date = Date(), calendar: Calendar = .current) -> Date }` — returns the next future Date whose local time is `minutesSinceMidnight` (rolls to tomorrow if today's time already passed).

- [ ] **Step 1: Write the failing test**

Create `StrandTests/WakeTimeTests.swift`:
```swift
import XCTest
@testable import Strand

final class WakeTimeTests: XCTestCase {
    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testReturnsTodayWhenTimeStillAhead() {
        let c = cal()
        // now = 2026-06-21 06:00 UTC; wake at 07:00 → today 07:00
        let now = c.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 6))!
        let wake = WakeTime.next(minutesSinceMidnight: 7 * 60, from: now, calendar: c)
        XCTAssertEqual(wake, c.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 7))!)
    }

    func testRollsToTomorrowWhenTimeAlreadyPassed() {
        let c = cal()
        // now = 2026-06-21 08:00 UTC; wake at 07:00 → tomorrow 07:00
        let now = c.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 8))!
        let wake = WakeTime.next(minutesSinceMidnight: 7 * 60, from: now, calendar: c)
        XCTAssertEqual(wake, c.date(from: DateComponents(year: 2026, month: 6, day: 22, hour: 7))!)
    }

    func testExactEqualNowRollsToTomorrow() {
        let c = cal()
        let now = c.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 7))!
        let wake = WakeTime.next(minutesSinceMidnight: 7 * 60, from: now, calendar: c)
        XCTAssertEqual(wake, c.date(from: DateComponents(year: 2026, month: 6, day: 22, hour: 7))!)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/WakeTimeTests`
Expected: FAIL — `cannot find 'WakeTime' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Strand/System/WakeTime.swift`:
```swift
import Foundation

/// Single source of truth for "the next Date at a given local time of day".
/// Used by both the strap firmware alarm (epoch) and the phone-notification backup so they
/// never disagree about which instant the user asked to wake at.
enum WakeTime {
    /// The next future Date whose local wall-clock time is `minutesSinceMidnight`.
    /// Rolls to tomorrow if today's occurrence is already at or before `now`.
    static func next(minutesSinceMidnight: Int, from now: Date = Date(), calendar: Calendar = .current) -> Date {
        let hour = minutesSinceMidnight / 60
        let minute = minutesSinceMidnight % 60
        var next = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        if next <= now { next = calendar.date(byAdding: .day, value: 1, to: next) ?? next }
        return next
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/WakeTimeTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Refactor `AppModel.applySmartAlarm()` to use `WakeTime` (DRY)**

In `Strand/App/AppModel.swift`, replace the inline date computation in `applySmartAlarm()` so the body becomes:
```swift
func applySmartAlarm() {
    guard behavior.smartAlarmEnabled else { ble.disableStrapAlarm(); return }
    let next = WakeTime.next(minutesSinceMidnight: behavior.smartAlarmMinutes)
    ble.armStrapAlarm(at: next)
}
```
Keep any upstream weekday handling that wraps this; if upstream's `applySmartAlarm` already selects a weekday-aware date, compute the base time via `WakeTime.next(...)` and apply the existing weekday adjustment to it rather than deleting that logic.

- [ ] **Step 6: Build to verify the refactor compiles**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
Expected: build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Strand/System/WakeTime.swift StrandTests/WakeTimeTests.swift Strand/App/AppModel.swift Strand.xcodeproj
git commit -m "feat(alarm): WakeTime helper for next wake instant; DRY applySmartAlarm

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01N9rqE1jz53up6JWTNoTdP5"
```

---

### Task 3: `AlarmArmCoordinator` state machine + driver protocol

The orchestrator. Drives connect → write → confirm by calling a small `AlarmArmDriving` protocol (BLEManager conforms) and observing a `LiveState`. Pure logic, fully unit-testable with a mock driver + a real `LiveState`.

**Files:**
- Create: `Strand/BLE/AlarmArmCoordinator.swift`
- Test: `StrandTests/AlarmArmCoordinatorTests.swift`
- Modify: `Strand/BLE/BLEManager.swift` (add `AlarmArmDriving` conformance, end of file)
- Modify: `Strand/App/AppModel.swift` (own an `armCoordinator`)

**Interfaces:**
- Consumes: `BLEManager.connect(model:)`, `scanForWhoops()`, `armStrapAlarm(at:)`, `disableStrapAlarm()`, `state: LiveState`; `LiveState.$connected`, `LiveState.$alarmArmConfirmed`, `LiveState.alarmArmedForEpoch`.
- Produces:
  - `enum ArmStep: Equatable { case idle, connecting, syncingClock, writing, confirming, confirmed(epoch: UInt32), failed(ArmFailure) }`
  - `enum ArmFailure: Equatable { case noLink, notStored, cancelled }`
  - `protocol AlarmArmDriving: AnyObject { var isConnected: Bool { get }; func connect(); func scanForWhoops(); func armStrapAlarm(at date: Date); func disableStrapAlarm() }`
  - `@MainActor final class AlarmArmCoordinator: ObservableObject { @Published private(set) var step: ArmStep; init(driver: AlarmArmDriving, live: LiveState, connectTimeout: TimeInterval = 20, confirmTimeout: TimeInterval = 8); func arm(wakeDate: Date); func cancel() }`

- [ ] **Step 1: Write the failing test**

Create `StrandTests/AlarmArmCoordinatorTests.swift`:
```swift
import XCTest
import Combine
@testable import Strand

@MainActor
final class AlarmArmCoordinatorTests: XCTestCase {

    /// Mock strap driver: records calls and reports a settable connection state.
    final class MockDriver: AlarmArmDriving {
        var isConnected: Bool
        var connectCalled = 0
        var scanCalled = 0
        var armCalled = 0
        var disableCalled = 0
        init(connected: Bool) { isConnected = connected }
        func connect() { connectCalled += 1 }
        func scanForWhoops() { scanCalled += 1 }
        func armStrapAlarm(at date: Date) { armCalled += 1 }
        func disableStrapAlarm() { disableCalled += 1 }
    }

    func testAlreadyConnected_writesThenConfirms() {
        let live = LiveState()
        let driver = MockDriver(connected: true)
        let c = AlarmArmCoordinator(driver: driver, live: live, connectTimeout: 5, confirmTimeout: 5)

        c.arm(wakeDate: Date(timeIntervalSince1970: 1_781_912_880))
        XCTAssertEqual(driver.armCalled, 1, "armed immediately when connected")
        XCTAssertEqual(c.step, .confirming)

        // Strap read-back confirms our epoch.
        live.alarmArmedForEpoch = 1_781_912_880
        live.alarmArmConfirmed = true
        XCTAssertEqual(c.step, .confirmed(epoch: 1_781_912_880))
    }

    func testDisconnected_connectsFirstThenArmsOnLink() {
        let live = LiveState()
        let driver = MockDriver(connected: false)
        let c = AlarmArmCoordinator(driver: driver, live: live, connectTimeout: 5, confirmTimeout: 5)

        c.arm(wakeDate: Date(timeIntervalSince1970: 1_781_912_880))
        XCTAssertEqual(c.step, .connecting)
        XCTAssertEqual(driver.connectCalled, 1)
        XCTAssertEqual(driver.armCalled, 0, "must not write before the link is up")

        // Link comes up → coordinator arms.
        driver.isConnected = true
        live.connected = true
        XCTAssertEqual(driver.armCalled, 1)
        XCTAssertEqual(c.step, .confirming)
    }

    func testReadbackFalse_failsNotStored() {
        let live = LiveState()
        let driver = MockDriver(connected: true)
        let c = AlarmArmCoordinator(driver: driver, live: live, connectTimeout: 5, confirmTimeout: 5)
        c.arm(wakeDate: Date(timeIntervalSince1970: 1_781_912_880))

        live.alarmArmConfirmed = false
        XCTAssertEqual(c.step, .failed(.notStored))
    }

    func testCancel_setsCancelled() {
        let live = LiveState()
        let driver = MockDriver(connected: false)
        let c = AlarmArmCoordinator(driver: driver, live: live, connectTimeout: 5, confirmTimeout: 5)
        c.arm(wakeDate: Date())
        c.cancel()
        XCTAssertEqual(c.step, .failed(.cancelled))
    }

    func testConnectTimeout_failsNoLink() {
        let live = LiveState()
        let driver = MockDriver(connected: false)
        let c = AlarmArmCoordinator(driver: driver, live: live, connectTimeout: 0.2, confirmTimeout: 5)
        c.arm(wakeDate: Date())
        let exp = expectation(description: "no link")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(c.step, .failed(.noLink))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/AlarmArmCoordinatorTests`
Expected: FAIL — `cannot find 'AlarmArmCoordinator'`/`AlarmArmDriving` in scope.

- [ ] **Step 3: Write the coordinator**

Create `Strand/BLE/AlarmArmCoordinator.swift`:
```swift
import Foundation
import Combine

/// The strap operations the guided alarm flow needs. `BLEManager` conforms; tests use a mock.
@MainActor
protocol AlarmArmDriving: AnyObject {
    var isConnected: Bool { get }
    func connect()
    func scanForWhoops()
    func armStrapAlarm(at date: Date)
    func disableStrapAlarm()
}

/// Steps surfaced to the guided arm sheet.
enum ArmStep: Equatable {
    case idle
    case connecting
    case syncingClock
    case writing
    case confirming
    case confirmed(epoch: UInt32)
    case failed(ArmFailure)
}

enum ArmFailure: Equatable { case noLink, notStored, cancelled }

/// Orchestrates the official-app-style arm: ensure a live link, write the alarm, read it back to
/// confirm the strap stored it. Calls existing `BLEManager` methods; observes `LiveState`. No wire
/// protocol lives here — `armStrapAlarm` already does SET_CLOCK → SET_ALARM → read-back confirm.
@MainActor
final class AlarmArmCoordinator: ObservableObject {
    @Published private(set) var step: ArmStep = .idle

    private let driver: AlarmArmDriving
    private let live: LiveState
    private let connectTimeout: TimeInterval
    private let confirmTimeout: TimeInterval

    private var cancellables = Set<AnyCancellable>()
    private var timeoutWork: DispatchWorkItem?

    init(driver: AlarmArmDriving, live: LiveState,
         connectTimeout: TimeInterval = 20, confirmTimeout: TimeInterval = 8) {
        self.driver = driver
        self.live = live
        self.connectTimeout = connectTimeout
        self.confirmTimeout = confirmTimeout
    }

    /// Begin arming for `wakeDate`. Safe to call again to retry.
    func arm(wakeDate: Date) {
        reset()
        if driver.isConnected {
            beginArm(wakeDate: wakeDate)
        } else {
            step = .connecting
            driver.connect()
            driver.scanForWhoops()
            startTimeout(connectTimeout) { [weak self] in self?.fail(.noLink) }
            live.$connected
                .filter { $0 }
                .first()
                .sink { [weak self] _ in self?.beginArm(wakeDate: wakeDate) }
                .store(in: &cancellables)
        }
    }

    /// Abort the in-flight arm.
    func cancel() {
        reset()
        step = .failed(.cancelled)
    }

    // MARK: - Internals

    private func beginArm(wakeDate: Date) {
        clearTimeout()
        step = .syncingClock           // armStrapAlarm sends SET_CLOCK first
        driver.armStrapAlarm(at: wakeDate)   // then SET_ALARM + begins read-back confirm
        step = .writing
        step = .confirming
        startTimeout(confirmTimeout) { [weak self] in self?.fail(.notStored) }
        live.$alarmArmConfirmed
            .compactMap { $0 }          // ignore the initial "arming…" nil
            .first()
            .sink { [weak self] confirmed in
                guard let self else { return }
                self.clearTimeout()
                if confirmed {
                    self.step = .confirmed(epoch: self.live.alarmArmedForEpoch
                        ?? UInt32(clamping: Int64(wakeDate.timeIntervalSince1970)))
                } else {
                    self.step = .failed(.notStored)
                }
            }
            .store(in: &cancellables)
    }

    private func fail(_ reason: ArmFailure) {
        reset()
        step = .failed(reason)
    }

    private func reset() {
        clearTimeout()
        cancellables.removeAll()
    }

    private func startTimeout(_ seconds: TimeInterval, _ action: @escaping () -> Void) {
        clearTimeout()
        let work = DispatchWorkItem(block: action)
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func clearTimeout() {
        timeoutWork?.cancel()
        timeoutWork = nil
    }
}
```

- [ ] **Step 4: Conform `BLEManager` to `AlarmArmDriving`**

At the end of `Strand/BLE/BLEManager.swift`, add an extension:
```swift
extension BLEManager: AlarmArmDriving {
    var isConnected: Bool { state.connected }
    // connect(), scanForWhoops(), armStrapAlarm(at:), disableStrapAlarm() already exist.
}
```
Note: `connect(model:)` has a default argument, so it satisfies the protocol's `func connect()`.

- [ ] **Step 5: Own the coordinator in `AppModel`**

In `Strand/App/AppModel.swift`, add a stored property constructed after `ble`/`live` exist (use the same `LiveState` instance the app observes, i.e. `ble.state`):
```swift
lazy var armCoordinator = AlarmArmCoordinator(driver: ble, live: ble.state)
```
Place it near the other BLE-derived members. `lazy` avoids init-order issues with `ble`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/AlarmArmCoordinatorTests`
Expected: PASS (5 tests).

- [ ] **Step 7: Full build to verify app target compiles**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
Expected: build succeeds.

- [ ] **Step 8: Commit**

```bash
git add Strand/BLE/AlarmArmCoordinator.swift StrandTests/AlarmArmCoordinatorTests.swift Strand/BLE/BLEManager.swift Strand/App/AppModel.swift Strand.xcodeproj
git commit -m "feat(alarm): AlarmArmCoordinator connect→write→confirm state machine

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01N9rqE1jz53up6JWTNoTdP5"
```

---

### Task 4: `WakeAlarmNotifier` (phone backup)

A local-notification backstop scheduled whenever smart alarm is on. Mirrors `IllnessNotifier`/`BatteryNotifier`. The schedulable date math is the testable unit.

**Files:**
- Create: `Strand/System/WakeAlarmNotifier.swift`
- Test: `StrandTests/WakeAlarmNotifierTests.swift`

**Interfaces:**
- Consumes: `WakeTime.next(minutesSinceMidnight:from:calendar:)`.
- Produces: `enum WakeAlarmNotifier { static let identifier = "noop.wakeAlarm"; static func requestAuthorization(); static func fireComponents(minutesSinceMidnight: Int) -> DateComponents; static func schedule(minutesSinceMidnight: Int); static func cancel() }`

- [ ] **Step 1: Write the failing test**

Create `StrandTests/WakeAlarmNotifierTests.swift`:
```swift
import XCTest
@testable import Strand

final class WakeAlarmNotifierTests: XCTestCase {
    func testFireComponents_areHourAndMinuteOnly() {
        let comps = WakeAlarmNotifier.fireComponents(minutesSinceMidnight: 7 * 60 + 30)
        XCTAssertEqual(comps.hour, 7)
        XCTAssertEqual(comps.minute, 30)
        XCTAssertNil(comps.day, "calendar trigger should match time-of-day, not a fixed date")
    }

    func testIdentifierIsStable() {
        XCTAssertEqual(WakeAlarmNotifier.identifier, "noop.wakeAlarm")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/WakeAlarmNotifierTests`
Expected: FAIL — `cannot find 'WakeAlarmNotifier'`.

- [ ] **Step 3: Write the implementation**

Create `Strand/System/WakeAlarmNotifier.swift`:
```swift
import Foundation
import UserNotifications

/// Phone-notification backstop for the smart alarm. Scheduled whenever smart alarm is ON, regardless
/// of whether the strap firmware arm confirmed — the strap buzz is primary, this is the safety net.
/// System-owned, so it fires even if NOOP is force-quit. Mirrors `IllnessNotifier`/`BatteryNotifier`.
enum WakeAlarmNotifier {
    static let identifier = "noop.wakeAlarm"

    /// Ask up front (when smart alarm is first enabled) so the system prompt appears predictably.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Hour/minute-only components for a time-of-day calendar trigger (fires at the next occurrence).
    static func fireComponents(minutesSinceMidnight: Int) -> DateComponents {
        DateComponents(hour: minutesSinceMidnight / 60, minute: minutesSinceMidnight % 60)
    }

    /// Schedule (replacing any prior) a one-shot wake notification at the given time of day.
    static func schedule(minutesSinceMidnight: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = "Wake up"
            content.body = "Backup alarm from NOOP."
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: fireComponents(minutesSinceMidnight: minutesSinceMidnight),
                repeats: false)
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        }
    }

    /// Cancel the pending backup (smart alarm disabled).
    static func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/WakeAlarmNotifierTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Strand/System/WakeAlarmNotifier.swift StrandTests/WakeAlarmNotifierTests.swift Strand.xcodeproj
git commit -m "feat(alarm): WakeAlarmNotifier phone-notification backup

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01N9rqE1jz53up6JWTNoTdP5"
```

---

### Task 5: `ArmAlarmSheet` SwiftUI view

Renders the coordinator's `step` as a live checklist with a terminal success/failure footer. UI-only; verified by build + a SwiftUI preview (no unit test — there is no logic beyond mapping `ArmStep` to rows).

**Files:**
- Create: `Strand/Screens/ArmAlarmSheet.swift`

**Interfaces:**
- Consumes: `AlarmArmCoordinator` (`@ObservedObject`), `ArmStep`, `ArmFailure`, `StrandPalette`, `StrandFont`.
- Produces: `struct ArmAlarmSheet: View { init(coordinator: AlarmArmCoordinator, onDone: @escaping () -> Void, onRetry: @escaping () -> Void) }`

- [ ] **Step 1: Write the view**

Create `Strand/Screens/ArmAlarmSheet.swift`:
```swift
import SwiftUI

/// Official-app-style guided arm dialog. Shows connect → set clock → write → confirm as a live
/// checklist, then a success ("buzzes even with NOOP closed") or failure ("phone backup is still
/// set") footer. Driven entirely by `AlarmArmCoordinator.step`.
struct ArmAlarmSheet: View {
    @ObservedObject var coordinator: AlarmArmCoordinator
    let onDone: () -> Void
    let onRetry: () -> Void

    private struct Phase: Identifiable { let id: Int; let label: String; let order: Int }
    private let phases: [Phase] = [
        .init(id: 0, label: "Connecting to your strap", order: 0),
        .init(id: 1, label: "Setting the strap clock", order: 1),
        .init(id: 2, label: "Writing the alarm", order: 2),
        .init(id: 3, label: "Confirming it stored", order: 3),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Arming your strap alarm")
                .font(StrandFont.title)
                .foregroundStyle(StrandPalette.textPrimary)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(phases) { phase in
                    HStack(spacing: 12) {
                        statusIcon(for: phase.order)
                        Text(phase.label)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                    }
                }
            }

            footer
        }
        .padding(24)
        .frame(minWidth: 320)
        .interactiveDismissDisabled(isBusy)
    }

    private var currentOrder: Int {
        switch coordinator.step {
        case .idle, .connecting: return 0
        case .syncingClock: return 1
        case .writing: return 2
        case .confirming: return 3
        case .confirmed: return 4
        case .failed: return -1
        }
    }

    private var isBusy: Bool {
        switch coordinator.step {
        case .confirmed, .failed: return false
        default: return true
        }
    }

    @ViewBuilder
    private func statusIcon(for order: Int) -> some View {
        if case .failed = coordinator.step, order >= failedAtOrder {
            Image(systemName: "xmark.circle.fill").foregroundStyle(StrandPalette.warning)
        } else if order < currentOrder {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(StrandPalette.accent)
        } else if order == currentOrder {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "circle").foregroundStyle(StrandPalette.textSecondary.opacity(0.4))
        }
    }

    /// Which phase the failure occurred at (so earlier phases keep their checkmarks).
    private var failedAtOrder: Int {
        guard case let .failed(reason) = coordinator.step else { return Int.max }
        switch reason {
        case .noLink, .cancelled: return 0
        case .notStored: return 3
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch coordinator.step {
        case let .confirmed(epoch):
            VStack(alignment: .leading, spacing: 8) {
                Text("Confirmed for \(Self.clock.string(from: Date(timeIntervalSince1970: TimeInterval(epoch))))")
                    .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text("Your strap will buzz your wrist even with NOOP closed.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Button("Done", action: onDone).buttonStyle(.borderedProminent)
            }
        case let .failed(reason):
            VStack(alignment: .leading, spacing: 8) {
                Text(message(for: reason))
                    .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text("Your phone backup alarm is still set, so you'll still be woken.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                HStack {
                    Button("Retry", action: onRetry).buttonStyle(.borderedProminent)
                    Button("Keep my phone alarm", action: onDone)
                }
            }
        default:
            HStack {
                Spacer()
                Button("Cancel") { coordinator.cancel() }
            }
        }
    }

    private func message(for reason: ArmFailure) -> String {
        switch reason {
        case .noLink: return "Couldn't reach your strap."
        case .notStored: return "Your strap didn't store the alarm."
        case .cancelled: return "Arming cancelled."
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f
    }()
}
```
If `StrandPalette` lacks `warning`/`textSecondary`/`accent` or `StrandFont` lacks `title`/`body`/`caption`, substitute the nearest existing tokens used elsewhere in `Strand/Screens` (grep `StrandPalette.` / `StrandFont.` in `AutomationsView.swift` for the exact names) — do not invent new palette entries.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
Expected: build succeeds. Fix any palette/font token name mismatches per the note above.

- [ ] **Step 3: Commit**

```bash
git add Strand/Screens/ArmAlarmSheet.swift Strand.xcodeproj
git commit -m "feat(alarm): ArmAlarmSheet guided connect/write/confirm dialog

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01N9rqE1jz53up6JWTNoTdP5"
```

---

### Task 6: Wire the sheet into `AutomationsView` + copy + on-device verification

Present the sheet on enable and on (debounced) wake-time change; always schedule the phone backup when smart alarm is on; cancel it on disable; re-add a read-back status row; update the card blurb.

**Files:**
- Modify: `Strand/Screens/AutomationsView.swift`

**Interfaces:**
- Consumes: `AppModel.armCoordinator`, `AppModel.applySmartAlarm()`, `WakeAlarmNotifier`, `WakeTime`, `ArmAlarmSheet`, `LiveState.alarmArmConfirmed`, `BehaviorStore.smartAlarmEnabled/smartAlarmMinutes`.

- [ ] **Step 1: Add presentation state + sheet to `alarmCard`**

In `Strand/Screens/AutomationsView.swift`, add view state near the top of the struct:
```swift
@State private var showArmSheet = false
```
Attach the sheet to the alarm card's container (the `Section2 { ... }` in `alarmCard`), passing the coordinator from `model`:
```swift
.sheet(isPresented: $showArmSheet) {
    ArmAlarmSheet(
        coordinator: model.armCoordinator,
        onDone: { showArmSheet = false },
        onRetry: { model.armCoordinator.arm(wakeDate: WakeTime.next(minutesSinceMidnight: behavior.smartAlarmMinutes)) }
    )
}
```

- [ ] **Step 2: Trigger on enable, schedule backup, cancel on disable**

Replace the existing `.onChangeCompat(of: behavior.smartAlarmEnabled) { _ in model.applySmartAlarm() }` on the alarm card with:
```swift
.onChangeCompat(of: behavior.smartAlarmEnabled) { _ in
    if behavior.smartAlarmEnabled {
        WakeAlarmNotifier.requestAuthorization()
        WakeAlarmNotifier.schedule(minutesSinceMidnight: behavior.smartAlarmMinutes)
        model.armCoordinator.arm(wakeDate: WakeTime.next(minutesSinceMidnight: behavior.smartAlarmMinutes))
        showArmSheet = true
    } else {
        model.ble.disableStrapAlarm()
        WakeAlarmNotifier.cancel()
    }
}
```

- [ ] **Step 3: Trigger on debounced wake-time change**

Add a debounced subscription so scrubbing the time picker doesn't present the sheet on every tick. Add `.onReceive` on the alarm card:
```swift
.onReceive(
    behavior.$smartAlarmMinutes
        .dropFirst()
        .debounce(for: .milliseconds(800), scheduler: RunLoop.main)
) { _ in
    guard behavior.smartAlarmEnabled else { return }
    WakeAlarmNotifier.schedule(minutesSinceMidnight: behavior.smartAlarmMinutes)
    model.armCoordinator.arm(wakeDate: WakeTime.next(minutesSinceMidnight: behavior.smartAlarmMinutes))
    showArmSheet = true
}
```
If `behavior.smartAlarmMinutes` is not exposed as a Combine `@Published` publisher (`$smartAlarmMinutes`), confirm `BehaviorStore` is an `ObservableObject` with `@Published var smartAlarmMinutes` (it is, since `AutomationsView` binds to it) — the projected `$` publisher is therefore available. Remove the now-redundant `.onChangeCompat(of: behavior.smartAlarmMinutes) { _ in model.applySmartAlarm() }` for the alarm card to avoid double-arming. Keep upstream's `smartAlarmWeekdays` onChange (weekday selection) but route it through the same schedule+arm block if it should re-arm; otherwise leave it calling `model.applySmartAlarm()`.

- [ ] **Step 4: Re-add a read-back status row**

Inside the `if behavior.smartAlarmEnabled` block of `alarmCard`, add a compact status row reflecting the confirm state (re-introducing the helper that the merge dropped). Add this row after the "Wake at" picker:
```swift
HStack(spacing: 8) {
    Image(systemName: alarmStatusIcon).foregroundStyle(alarmStatusTint)
    Text(alarmStatusText).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
}
```
And add these private helpers to the view (driven by `live.alarmArmConfirmed`):
```swift
private var alarmStatusIcon: String {
    switch live.alarmArmConfirmed {
    case .some(true): return "checkmark.seal.fill"
    case .some(false): return "exclamationmark.triangle.fill"
    case .none: return "clock.arrow.circlepath"
    }
}
private var alarmStatusTint: Color {
    switch live.alarmArmConfirmed {
    case .some(true): return StrandPalette.accent
    case .some(false): return StrandPalette.warning
    case .none: return StrandPalette.textSecondary
    }
}
private var alarmStatusText: String {
    switch live.alarmArmConfirmed {
    case .some(true): return "Confirmed on your strap — buzzes even with NOOP closed."
    case .some(false): return "Strap didn't store it — phone backup is set."
    case .none: return "Tap Enable to sync the alarm to your strap."
    }
}
```
(Match `StrandPalette`/`StrandFont` token names to those already used in this file.)

- [ ] **Step 5: Update the card blurb**

Update the `Section2(..., blurb:)` text for the alarm card to describe the new flow:
```
"When you turn this on, NOOP connects to your strap and writes the alarm, then reads it back to confirm it stored — so a wake actually fires. A phone backup alarm is always set as a safety net. Strap-driven wake is still being verified on WHOOP 4.0, so keep the phone backup until you've seen it wake you."
```

- [ ] **Step 6: Build to verify it compiles**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
Expected: build succeeds.

- [ ] **Step 7: Run the full test suite (regression gate)**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test`
Expected: all `StrandTests` pass (`WakeTimeTests`, `AlarmArmCoordinatorTests`, `WakeAlarmNotifierTests`, `SetAlarmPayloadTests`, `AlarmReadbackTests`).

- [ ] **Step 8: Build the iOS app target (the real platform)**

Run: `xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
Expected: build succeeds (catches iOS-only API issues; UserNotifications + SwiftUI sheet are iOS-supported).

- [ ] **Step 9: Commit**

```bash
git add Strand/Screens/AutomationsView.swift Strand.xcodeproj
git commit -m "feat(alarm): guided arm sheet + phone backup wired into Smart alarm card

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01N9rqE1jz53up6JWTNoTdP5"
```

- [ ] **Step 10: On-device verification (user, WHOOP 4)**

This cannot be automated (no strap motor in the simulator). Install on the user's iPhone with the WHOOP 4 worn, then verify:
1. Strap already connected → enable smart alarm → sheet shows Connecting ✓ → Confirming → **Confirmed for HH:MM**.
2. Strap disconnected → enable smart alarm → sheet actively connects, then confirms.
3. Set a wake ~2 min out, force-quit NOOP → strap buzzes at the time; phone notification also fires (backup).
4. Disable smart alarm → confirm no buzz/notification next cycle.
Record the result (did the strap buzz?) in the branch notes — this is the one fact none of the reverse-engineering sources can confirm for this specific strap.

---

## Self-Review

**Spec coverage:**
- Phase 0 merge → Task 1. ✓
- AlarmArmCoordinator (connect→arm→confirm, timeouts) → Task 3. ✓
- ArmAlarmSheet → Task 5. ✓
- WakeAlarmNotifier (always-on backup) → Task 4 + wiring in Task 6. ✓
- AutomationsView wiring (trigger on enable + debounced time change; disable path; status row; blurb) → Task 6. ✓
- Tests (coordinator, notifier date math, keep existing green) → Tasks 3, 4, 6. ✓
- On-device plan → Task 6 Step 10. ✓
- WakeTime DRY helper (implied by spec's shared next-wake instant) → Task 2. ✓
- Out-of-scope (auto-re-arm, 5/MG guided arming, .timeSensitive) → not implemented. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; test code is concrete.

**Type consistency:** `ArmStep`/`ArmFailure`/`AlarmArmDriving`/`AlarmArmCoordinator.arm(wakeDate:)`/`cancel()`/`step` used identically across Tasks 3, 5, 6. `WakeTime.next(minutesSinceMidnight:from:calendar:)` consistent across Tasks 2, 4, 6. `WakeAlarmNotifier.schedule(minutesSinceMidnight:)`/`cancel()`/`requestAuthorization()` consistent across Tasks 4, 6. `model.armCoordinator` (Task 3 Step 5) matches usage in Task 6.
