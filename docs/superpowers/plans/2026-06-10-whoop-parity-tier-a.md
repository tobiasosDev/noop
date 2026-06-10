# WHOOP-Parity Tier A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Strain Coach (target + live gauge), Sleep Planner (bedtime + iOS reminder), Performance Report (7/28-day), Goals (sleep/strain/steps) — shared macOS+iOS, verified in simulator, shipped to TestFlight.

**Architecture:** Pure compute in `Packages/StrandAnalytics` (TDD via `swift test`); goal persistence as migration v11 + CRUD in `Packages/WhoopStore`; UI as shared SwiftUI in `Strand/Screens/` reusing StrandDesign components; iOS-only notification scheduler in `StrandiOS/System/`. Spec: `docs/superpowers/specs/2026-06-10-whoop-parity-tier-a-design.md`.

**Tech Stack:** Swift 5.9, SwiftUI, GRDB (WhoopStore actor), XCTest, xcodegen, xcodebuild, UserNotifications (iOS).

**Conventions the executor MUST know:**
- Branch: `whoop-parity-tier-a` (already created, spec committed).
- After creating/deleting app-target Swift files run `xcodegen generate` before xcodebuild (package files don't need it).
- `#if DEBUG` does NOT compile in this project's xcodegen setup — use `#if os(iOS)` / `#if targetEnvironment(simulator)` only.
- New SwiftUI must work compact (iPhone): use `ViewThatFits(in: .horizontal)` like `TodayView.heroSection` / `LiveView.statusGrid`.
- User-facing strings: plain string literals in SwiftUI views auto-extract to the String Catalog (`LocalizedStringKey` params). German translation done at the end (Task 13).
- Package tests: `cd Packages/StrandAnalytics && swift test`, `cd Packages/WhoopStore && swift test`.
- UI tasks 9–12: invoke the `frontend-design:frontend-design` skill before writing view code.

---

### Task 1: StrainTarget (StrandAnalytics)

**Files:**
- Create: `Packages/StrandAnalytics/Sources/StrandAnalytics/StrainTarget.swift`
- Create: `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/StrainTargetTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import StrandAnalytics

final class StrainTargetTests: XCTestCase {

    func testLinearMapEndpoints() {
        // recovery 0 → mid 4.0; recovery 100 → mid 18.5 (4.0 + 0.145·100 = 18.5).
        XCTAssertEqual(StrainTarget.band(recovery: 0).midpoint, 4.0, accuracy: 1e-9)
        XCTAssertEqual(StrainTarget.band(recovery: 100).midpoint, 18.5, accuracy: 1e-9)
    }

    func testMidScale() {
        // 4.0 + 0.145·50 = 11.25, band ±1.0.
        let b = StrainTarget.band(recovery: 50)
        XCTAssertEqual(b.low, 10.25, accuracy: 1e-9)
        XCTAssertEqual(b.high, 12.25, accuracy: 1e-9)
    }

    func testRecoveryClamped() {
        XCTAssertEqual(StrainTarget.band(recovery: -20), StrainTarget.band(recovery: 0))
        XCTAssertEqual(StrainTarget.band(recovery: 150), StrainTarget.band(recovery: 100))
    }

    func testStateClassification() {
        let b = StrainTarget.band(recovery: 50)   // 10.25...12.25
        XCTAssertEqual(b.state(currentStrain: 5.0), .building)
        XCTAssertEqual(b.state(currentStrain: 11.0), .onTarget)
        XCTAssertEqual(b.state(currentStrain: 10.25), .onTarget)   // edges inclusive
        XCTAssertEqual(b.state(currentStrain: 12.25), .onTarget)
        XCTAssertEqual(b.state(currentStrain: 14.0), .overreaching)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/tobiasluscher/Development/noop/Packages/StrandAnalytics && swift test --filter StrainTargetTests`
Expected: compile FAIL — `cannot find 'StrainTarget' in scope`

- [ ] **Step 3: Write implementation**

```swift
import Foundation

// StrainTarget.swift — recovery-driven exertion guidance.
//
// Maps today's recovery % onto a recommended strain band on the 0–21 scale.
// APPROXIMATION of published recovery→load coaching heuristics (not WHOOP's
// proprietary mapping). Constants live here so the curve is tunable in one place.

public enum StrainTarget {

    /// Band half-width around the midpoint.
    public static let halfWidth: Double = 1.0
    /// Linear map: recovery 0 → 4.0, recovery 100 → 18.5.
    static let base: Double = 4.0
    static let slope: Double = 0.145

    public enum State: String, Equatable, Sendable {
        case building       // below the band — room to push
        case onTarget       // inside the band
        case overreaching   // above the band — exceeding today's recommendation
    }

    public struct Band: Equatable, Sendable {
        public let low: Double
        public let high: Double
        public var midpoint: Double { (low + high) / 2 }

        /// Band edges are inclusive.
        public func state(currentStrain: Double) -> State {
            if currentStrain < low { return .building }
            if currentStrain > high { return .overreaching }
            return .onTarget
        }
    }

    /// Recommended strain band for a recovery score (0–100; out-of-range input clamps).
    public static func band(recovery: Double) -> Band {
        let r = min(100, max(0, recovery))
        let mid = base + slope * r
        return Band(low: max(0, mid - halfWidth), high: min(21, mid + halfWidth))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/tobiasluscher/Development/noop/Packages/StrandAnalytics && swift test --filter StrainTargetTests`
Expected: 4 tests PASS

- [ ] **Step 5: Commit**

```bash
git add Packages/StrandAnalytics
git commit -m "feat(analytics): StrainTarget — recovery → recommended strain band"
```

---

### Task 2: SleepNeed extraction (StrandAnalytics + SleepView refactor)

**Files:**
- Create: `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepNeed.swift`
- Create: `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/SleepNeedTests.swift`
- Modify: `Strand/Screens/SleepView.swift` (`sleepNeedMin` at ~line 495, `sleepDebtSeries` at ~line 484)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import StrandAnalytics

final class SleepNeedTests: XCTestCase {

    func testFloorAppliesWhenMeanBelow() {
        // mean(400, 420) = 410 < 450 floor.
        XCTAssertEqual(SleepNeed.needMin(totalSleepMinsByNight: [400, 420]), 450, accuracy: 1e-9)
    }

    func testMeanWinsAboveFloor() {
        XCTAssertEqual(SleepNeed.needMin(totalSleepMinsByNight: [480, 500]), 490, accuracy: 1e-9)
    }

    func testZerosAndEmptyIgnored() {
        XCTAssertEqual(SleepNeed.needMin(totalSleepMinsByNight: []), 450, accuracy: 1e-9)
        XCTAssertEqual(SleepNeed.needMin(totalSleepMinsByNight: [0, 0, 480]), 480, accuracy: 1e-9)
    }

    func testDebtFlooredAtZero() {
        XCTAssertEqual(SleepNeed.debtMin(needMin: 450, asleepMin: 400), 50, accuracy: 1e-9)
        XCTAssertEqual(SleepNeed.debtMin(needMin: 450, asleepMin: 500), 0, accuracy: 1e-9)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/tobiasluscher/Development/noop/Packages/StrandAnalytics && swift test --filter SleepNeedTests`
Expected: compile FAIL — `cannot find 'SleepNeed' in scope`

- [ ] **Step 3: Write implementation**

```swift
import Foundation

// SleepNeed.swift — personal sleep need & debt. Single source of truth, extracted
// from SleepView's UI-side math (unchanged semantics) so the Sleep Planner and the
// Sleep screen can never disagree.

public enum SleepNeed {

    /// 7.5 h floor so debt/performance read sensibly even for a chronically short sleeper.
    public static let floorMin: Double = 450

    /// Personal need (minutes) = mean asleep across nights with data, never below the floor.
    /// Nights with 0/negative minutes are ignored; no data at all → the floor.
    public static func needMin(totalSleepMinsByNight: [Double]) -> Double {
        let vals = totalSleepMinsByNight.filter { $0 > 0 }
        guard !vals.isEmpty else { return floorMin }
        return Swift.max(floorMin, vals.reduce(0, +) / Double(vals.count))
    }

    /// Debt for one night = need − asleep, floored at 0 (no "credit" for oversleeping).
    public static func debtMin(needMin: Double, asleepMin: Double) -> Double {
        Swift.max(0, needMin - asleepMin)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/tobiasluscher/Development/noop/Packages/StrandAnalytics && swift test --filter SleepNeedTests`
Expected: 4 tests PASS

- [ ] **Step 5: Refactor SleepView to use SleepNeed**

In `Strand/Screens/SleepView.swift` replace the body of `sleepNeedMin` (~line 495):

```swift
    /// The personal sleep need (minutes) — shared math with the Sleep Planner (SleepNeed).
    private var sleepNeedMin: Double {
        SleepNeed.needMin(totalSleepMinsByNight: repo.days.compactMap { $0.totalSleepMin })
    }
```

And in `sleepDebtSeries` (~line 484) replace `Swift.max(0, need - asleep)` with `SleepNeed.debtMin(needMin: need, asleepMin: asleep)`. Confirm `import StrandAnalytics` exists at the top of SleepView.swift (add if missing).

- [ ] **Step 6: Build macOS to verify the refactor compiles**

Run: `cd /Users/tobiasluscher/Development/noop && xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug build -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 7: Commit**

```bash
git add Packages/StrandAnalytics Strand/Screens/SleepView.swift
git commit -m "refactor(sleep): extract SleepNeed into StrandAnalytics (shared with planner)"
```

---

### Task 3: SleepPlanner (StrandAnalytics)

**Files:**
- Create: `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepPlanner.swift`
- Create: `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/SleepPlannerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import StrandAnalytics

final class SleepPlannerTests: XCTestCase {

    func testPeakWithDefaultsWrapsAcrossMidnight() {
        // wake 07:00 (420), need 450, no debt, default efficiency 0.90:
        // inBed = 450/0.9 = 500 → bed = 420 − 500 = −80 → wraps to 1360 (22:40).
        let r = SleepPlanner.recommend(wakeMinutes: 420, baseNeedMin: 450, debtMin: 0,
                                       efficiency: nil, goal: .peak)
        XCTAssertEqual(r.bedMinutes, 1360)
        XCTAssertEqual(r.inBedMin, 500, accuracy: 0.5)
        XCTAssertTrue(r.usedDefaults)
    }

    func testGetByLandsAfterMidnight() {
        // getBy = 70%: goalSleep = 315, inBed = 350 → bed = 420 − 350 = 70 (01:10).
        let r = SleepPlanner.recommend(wakeMinutes: 420, baseNeedMin: 450, debtMin: 0,
                                       efficiency: nil, goal: .getBy)
        XCTAssertEqual(r.bedMinutes, 70)
        XCTAssertFalse(r.bedMinutes < 0)
    }

    func testDebtRepaymentAddsToNeed() {
        // need = 480 + 0.3·60 = 498.
        let r = SleepPlanner.recommend(wakeMinutes: 420, baseNeedMin: 480, debtMin: 60,
                                       efficiency: 0.9, goal: .peak)
        XCTAssertEqual(r.needMin, 498, accuracy: 1e-9)
        XCTAssertFalse(r.usedDefaults)
    }

    func testEfficiencyFloorClamps() {
        // efficiency 0.5 clamps to 0.75: inBed = 450/0.75 = 600.
        let r = SleepPlanner.recommend(wakeMinutes: 420, baseNeedMin: 450, debtMin: 0,
                                       efficiency: 0.5, goal: .peak)
        XCTAssertEqual(r.inBedMin, 600, accuracy: 0.5)
    }

    func testGoalFractions() {
        XCTAssertEqual(SleepPlanner.Goal.peak.fraction, 1.0)
        XCTAssertEqual(SleepPlanner.Goal.perform.fraction, 0.85)
        XCTAssertEqual(SleepPlanner.Goal.getBy.fraction, 0.70)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/tobiasluscher/Development/noop/Packages/StrandAnalytics && swift test --filter SleepPlannerTests`
Expected: compile FAIL — `cannot find 'SleepPlanner' in scope`

- [ ] **Step 3: Write implementation**

```swift
import Foundation

// SleepPlanner.swift — "go to bed at X": when to be in bed to hit tonight's sleep
// need for a chosen performance goal, given the planned wake time. Pure math; the
// wake time comes from the strap alarm or a manual planner setting (app layer).

public enum SleepPlanner {

    public enum Goal: String, CaseIterable, Equatable, Sendable {
        case peak, perform, getBy
        /// Fraction of tonight's need the goal aims to bank.
        public var fraction: Double {
            switch self {
            case .peak:    return 1.0
            case .perform: return 0.85
            case .getBy:   return 0.70
            }
        }
    }

    /// Share of accumulated debt repaid in a single night (gradual, WHOOP-style).
    public static let debtRepayFraction: Double = 0.3
    /// Used when no personal efficiency history exists yet.
    public static let defaultEfficiency: Double = 0.90
    /// Personal efficiency below this is treated as this (guards absurd inBed times).
    public static let efficiencyFloor: Double = 0.75

    public struct Recommendation: Equatable, Sendable {
        /// Recommended bedtime, minutes since local midnight (0..<1440), wrapped.
        public let bedMinutes: Int
        /// Tonight's total need (base + debt repayment), minutes asleep.
        public let needMin: Double
        /// Need scaled by the goal fraction.
        public let goalSleepMin: Double
        /// Time in bed after the efficiency adjustment.
        public let inBedMin: Double
        /// True when no personal efficiency was available (defaults used).
        public let usedDefaults: Bool
    }

    /// - Parameters:
    ///   - wakeMinutes: planned wake, minutes since local midnight.
    ///   - baseNeedMin: personal need (SleepNeed.needMin).
    ///   - debtMin: latest accumulated debt (SleepNeed.debtMin of the last night).
    ///   - efficiency: personal typical sleep efficiency 0–1; nil → default.
    public static func recommend(wakeMinutes: Int,
                                 baseNeedMin: Double,
                                 debtMin: Double,
                                 efficiency: Double?,
                                 goal: Goal) -> Recommendation {
        let usedDefaults = efficiency == nil
        let eff = Swift.max(efficiencyFloor, Swift.min(1.0, efficiency ?? defaultEfficiency))
        let need = baseNeedMin + debtRepayFraction * debtMin
        let goalSleep = need * goal.fraction
        let inBed = goalSleep / eff
        var bed = Double(wakeMinutes) - inBed
        while bed < 0 { bed += 1440 }            // wrap across midnight
        return Recommendation(bedMinutes: Int(bed.rounded()) % 1440,
                              needMin: need,
                              goalSleepMin: goalSleep,
                              inBedMin: inBed,
                              usedDefaults: usedDefaults)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/tobiasluscher/Development/noop/Packages/StrandAnalytics && swift test --filter SleepPlannerTests`
Expected: 5 tests PASS

- [ ] **Step 5: Commit**

```bash
git add Packages/StrandAnalytics
git commit -m "feat(analytics): SleepPlanner — bedtime recommendation with goal levels + debt repayment"
```

---

### Task 4: PerformanceReport (StrandAnalytics)

**Files:**
- Create: `Packages/StrandAnalytics/Sources/StrandAnalytics/PerformanceReport.swift`
- Create: `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/PerformanceReportTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import StrandAnalytics
import WhoopStore

final class PerformanceReportTests: XCTestCase {

    /// DailyMetric with only the fields the report reads.
    private func day(_ day: String, recovery: Double? = nil, strain: Double? = nil,
                     sleep: Double? = nil, hrv: Double? = nil, rhr: Int? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleep, efficiency: nil, deepMin: nil,
                    remMin: nil, lightMin: nil, disturbances: nil, restingHr: rhr,
                    avgHrv: hrv, recovery: recovery, strain: strain, exerciseCount: nil)
    }

    func testEmptyInputYieldsZeroCoverage() {
        let s = PerformanceReport.build(days: [], period: .weekly, today: "2026-06-10")
        XCTAssertEqual(s.coverage, 0)
        XCTAssertNil(s.recovery)
        XCTAssertNil(s.strain)
        XCTAssertNil(s.sleepMin)
    }

    func testWeeklyWindowSelectsTrailing7Days() {
        // 2026-06-04..2026-06-10 inclusive = the weekly window for today 2026-06-10.
        let days = [
            day("2026-06-03", recovery: 10),   // outside
            day("2026-06-04", recovery: 50),
            day("2026-06-10", recovery: 70),
        ]
        let s = PerformanceReport.build(days: days, period: .weekly, today: "2026-06-10")
        XCTAssertEqual(s.coverage, 2)
        XCTAssertEqual(s.fromDay, "2026-06-04")
        XCTAssertEqual(s.toDay, "2026-06-10")
        XCTAssertEqual(s.recovery?.value ?? -1, 60, accuracy: 1e-9)   // mean(50, 70)
    }

    func testDeltaAgainstPriorWindow() {
        // Prior week mean recovery 40, current week mean 60 → delta +20.
        let days = [
            day("2026-05-29", recovery: 40),   // prior window (05-28..06-03)
            day("2026-06-05", recovery: 60),
        ]
        let s = PerformanceReport.build(days: days, period: .weekly, today: "2026-06-10")
        XCTAssertEqual(s.recovery?.delta ?? -1, 20, accuracy: 1e-9)
    }

    func testDeltaNilWhenPriorWindowEmpty() {
        let s = PerformanceReport.build(days: [day("2026-06-05", recovery: 60)],
                                        period: .weekly, today: "2026-06-10")
        XCTAssertNil(s.recovery?.delta)
    }

    func testOverreachUnderreachCounting() {
        // recovery 50 → band 10.25...12.25. strain 14 = over, 5 = under, 11 = on target.
        let days = [
            day("2026-06-05", recovery: 50, strain: 14),
            day("2026-06-06", recovery: 50, strain: 5),
            day("2026-06-07", recovery: 50, strain: 11),
            day("2026-06-08", strain: 12),               // no recovery → not counted
        ]
        let s = PerformanceReport.build(days: days, period: .weekly, today: "2026-06-10")
        XCTAssertEqual(s.overreachDays, 1)
        XCTAssertEqual(s.underreachDays, 1)
    }

    func testBestWorstRecoveryDays() {
        let days = [
            day("2026-06-05", recovery: 30),
            day("2026-06-06", recovery: 90),
        ]
        let s = PerformanceReport.build(days: days, period: .weekly, today: "2026-06-10")
        XCTAssertEqual(s.bestRecoveryDay?.day, "2026-06-06")
        XCTAssertEqual(s.worstRecoveryDay?.day, "2026-06-05")
    }

    func testTakeawayForOverreach() {
        let days = (4...9).map { day("2026-06-0\($0)", recovery: 30, strain: 15) }
        let s = PerformanceReport.build(days: days, period: .weekly, today: "2026-06-10")
        XCTAssertTrue(s.takeaways.contains(where: { $0.contains("above your strain target") }))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/tobiasluscher/Development/noop/Packages/StrandAnalytics && swift test --filter PerformanceReportTests`
Expected: compile FAIL — `cannot find 'PerformanceReport' in scope`

- [ ] **Step 3: Write implementation**

```swift
import Foundation
import WhoopStore

// PerformanceReport.swift — periodized performance assessment over a trailing
// window (weekly = 7 days, monthly = 28), with Δ vs the immediately-prior window
// when that window has data. Pure aggregation over [DailyMetric]; ReportView renders.

public enum PerformanceReport {

    public enum Period: String, CaseIterable, Equatable, Sendable {
        case weekly, monthly
        public var days: Int { self == .weekly ? 7 : 28 }
    }

    public struct Average: Equatable, Sendable {
        public let value: Double
        /// Δ vs the prior window; nil when the prior window has no data for this metric.
        public let delta: Double?
    }

    public struct DayValue: Equatable, Sendable {
        public let day: String
        public let value: Double
    }

    public struct Summary: Equatable, Sendable {
        public let period: Period
        public let fromDay: String
        public let toDay: String
        /// Days in the window with at least one of recovery/strain/sleep present.
        public let coverage: Int

        public let recovery: Average?
        public let bestRecoveryDay: DayValue?
        public let worstRecoveryDay: DayValue?
        public let hrv: Average?
        public let rhr: Average?

        public let sleepMin: Average?
        public let sleepNeedMin: Double
        /// Mean asleep / need × 100 over the window (nil without sleep data).
        public let sleepPerformancePct: Double?

        public let strain: Average?
        public let totalStrain: Double?
        public let overreachDays: Int
        public let underreachDays: Int

        public let takeaways: [String]
    }

    /// ISO day-key calendar math (yyyy-MM-dd, en_US_POSIX — matches Repository).
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date) -> String { fmt.string(from: date) }
    static func shift(_ day: String, by days: Int) -> String {
        guard let d = fmt.date(from: day) else { return day }
        return dayKey(d.addingTimeInterval(Double(days) * 86_400))
    }

    public static func build(days: [DailyMetric], period: Period, today: String) -> Summary {
        let from = shift(today, by: -(period.days - 1))
        let priorFrom = shift(from, by: -period.days)
        let priorTo = shift(from, by: -1)

        let window = days.filter { $0.day >= from && $0.day <= today }
        let prior = days.filter { $0.day >= priorFrom && $0.day <= priorTo }

        func mean(_ vals: [Double]) -> Double? {
            vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
        }
        /// Window mean + Δ vs the prior window's mean for the same field.
        func avg(_ key: (DailyMetric) -> Double?) -> Average? {
            guard let v = mean(window.compactMap(key)) else { return nil }
            return Average(value: v, delta: mean(prior.compactMap(key)).map { v - $0 })
        }

        let coverage = window.filter {
            $0.recovery != nil || $0.strain != nil || $0.totalSleepMin != nil
        }.count

        // Recovery extremes.
        let recDays = window.compactMap { d in d.recovery.map { DayValue(day: d.day, value: $0) } }
        let best = recDays.max(by: { $0.value < $1.value })
        let worst = recDays.min(by: { $0.value < $1.value })

        // Sleep (need over the FULL history passed in, matching SleepView).
        let need = SleepNeed.needMin(totalSleepMinsByNight: days.compactMap { $0.totalSleepMin })
        let sleepAvg = avg { $0.totalSleepMin }
        let perfPct = sleepAvg.map { min(125, $0.value / need * 100) }

        // Strain vs the per-day recovery-derived target band.
        var over = 0, under = 0
        for d in window {
            guard let r = d.recovery, let s = d.strain else { continue }
            switch StrainTarget.band(recovery: r).state(currentStrain: s) {
            case .overreaching: over += 1
            case .building:     under += 1
            case .onTarget:     break
            }
        }
        let strainVals = window.compactMap { $0.strain }
        let strainAvg = avg { $0.strain }

        // Rule-based takeaways.
        var notes: [String] = []
        if over >= 2 { notes.append("\(over) days above your strain target — watch recovery.") }
        if let hrvD = avg({ $0.avgHrv })?.delta {
            if hrvD >= 3 { notes.append("HRV trending up — adaptation is going well.") }
            if hrvD <= -3 { notes.append("HRV trending down — consider easing off.") }
        }
        if let recD = avg({ $0.recovery })?.delta {
            if recD >= 8 { notes.append(String(format: "Recovery up %.0f%% vs the prior period.", recD)) }
            if recD <= -8 { notes.append(String(format: "Recovery down %.0f%% vs the prior period.", abs(recD))) }
        }
        if let p = perfPct, p < 70 {
            notes.append(String(format: "Averaging only %.0f%% of your sleep need.", p))
        }

        return Summary(period: period, fromDay: from, toDay: today, coverage: coverage,
                       recovery: avg { $0.recovery }, bestRecoveryDay: best, worstRecoveryDay: worst,
                       hrv: avg { $0.avgHrv }, rhr: avg { $0.restingHr.map(Double.init) },
                       sleepMin: sleepAvg, sleepNeedMin: need, sleepPerformancePct: perfPct,
                       strain: strainAvg,
                       totalStrain: strainVals.isEmpty ? nil : strainVals.reduce(0, +),
                       overreachDays: over, underreachDays: under,
                       takeaways: notes)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/tobiasluscher/Development/noop/Packages/StrandAnalytics && swift test --filter PerformanceReportTests`
Expected: 7 tests PASS

- [ ] **Step 5: Commit**

```bash
git add Packages/StrandAnalytics
git commit -m "feat(analytics): PerformanceReport — 7/28-day periodized assessment with prior-window deltas"
```

---

### Task 5: GoalProgress (StrandAnalytics)

**Files:**
- Create: `Packages/StrandAnalytics/Sources/StrandAnalytics/GoalProgress.swift`
- Create: `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/GoalProgressTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import StrandAnalytics

final class GoalProgressTests: XCTestCase {

    private let week = ["2026-06-04", "2026-06-05", "2026-06-06", "2026-06-07",
                        "2026-06-08", "2026-06-09", "2026-06-10"]

    func testSleepDurationDailyHitsAndStreak() {
        // Hit on 06-07, 06-09, 06-10 → 3 hits / 5 days with data = 60%; streak 2 (09+10).
        let values = ["2026-06-05": 400.0, "2026-06-06": 430.0, "2026-06-07": 460.0,
                      "2026-06-09": 480.0, "2026-06-10": 470.0]
        let p = GoalProgress.evaluate(kind: .sleepDuration, target: 450,
                                      values: values, weekDays: week)
        XCTAssertEqual(p.week.count, 7)
        XCTAssertEqual(p.percent, 60, accuracy: 1e-9)
        XCTAssertEqual(p.streak, 2)
        XCTAssertEqual(p.todayValue ?? -1, 470, accuracy: 1e-9)
        XCTAssertTrue(p.todayHit)
    }

    func testStreakSkipsTodayWithoutData() {
        // No value for today (06-10); hits on 08+09 → streak 2 must survive.
        let values = ["2026-06-08": 12000.0, "2026-06-09": 11000.0]
        let p = GoalProgress.evaluate(kind: .dailySteps, target: 10000,
                                      values: values, weekDays: week)
        XCTAssertEqual(p.streak, 2)
        XCTAssertNil(p.todayValue)
        XCTAssertFalse(p.todayHit)
    }

    func testMissedDayBreaksStreak() {
        // 06-08 miss (below target) between hits → streak counts only 09+10.
        let values = ["2026-06-07": 12000.0, "2026-06-08": 4000.0,
                      "2026-06-09": 11000.0, "2026-06-10": 10500.0]
        let p = GoalProgress.evaluate(kind: .dailySteps, target: 10000,
                                      values: values, weekDays: week)
        XCTAssertEqual(p.streak, 2)
    }

    func testWeeklyStrainUsesWeekAverage() {
        // avg(10, 14) = 12 vs target 14 → 85.7%; no streak for weeklyStrain.
        let values = ["2026-06-09": 10.0, "2026-06-10": 14.0]
        let p = GoalProgress.evaluate(kind: .weeklyStrain, target: 14,
                                      values: values, weekDays: week)
        XCTAssertEqual(p.percent, 12.0 / 14.0 * 100, accuracy: 1e-6)
        XCTAssertEqual(p.streak, 0)
    }

    func testNoDataAtAll() {
        let p = GoalProgress.evaluate(kind: .sleepDuration, target: 450,
                                      values: [:], weekDays: week)
        XCTAssertEqual(p.percent, 0)
        XCTAssertEqual(p.streak, 0)
        XCTAssertNil(p.todayValue)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/tobiasluscher/Development/noop/Packages/StrandAnalytics && swift test --filter GoalProgressTests`
Expected: compile FAIL — `cannot find 'GoalProgress' in scope`

- [ ] **Step 3: Write implementation**

```swift
import Foundation

// GoalProgress.swift — goal adherence math. Pure: per-day metric values in,
// weekly progress out. Persistence (the goal table) lives in WhoopStore; the
// screens fetch values from Repository and call evaluate().

public enum GoalProgress {

    public enum Kind: String, CaseIterable, Equatable, Sendable {
        case sleepDuration   // minutes asleep per night, daily hit/miss
        case weeklyStrain    // average day strain over the week vs target
        case dailySteps      // steps per day, daily hit/miss

        public var isDaily: Bool { self != .weeklyStrain }
    }

    public struct DayStatus: Equatable, Sendable {
        public let day: String
        public let value: Double?
        public let hit: Bool
    }

    public struct Progress: Equatable, Sendable {
        public let kind: Kind
        public let target: Double
        /// One entry per weekDay, oldest→newest (always weekDays.count entries).
        public let week: [DayStatus]
        /// Daily kinds: hits / days-with-data × 100. weeklyStrain: week-avg / target × 100.
        public let percent: Double
        /// Consecutive hit days ending at the latest day WITH data (daily kinds; 0 otherwise).
        public let streak: Int
        public let todayValue: Double?
        public let todayHit: Bool
    }

    /// - Parameters:
    ///   - values: day-key → metric value (sleep minutes / day strain / steps).
    ///   - weekDays: trailing 7 day-keys ending today, oldest→newest (the caller
    ///     derives these from Repository.localDayKey so calendar logic stays in one place).
    public static func evaluate(kind: Kind, target: Double,
                                values: [String: Double],
                                weekDays: [String]) -> Progress {
        let week = weekDays.map { day -> DayStatus in
            let v = values[day]
            return DayStatus(day: day, value: v, hit: v.map { $0 >= target } ?? false)
        }
        let withData = week.filter { $0.value != nil }

        let percent: Double
        switch kind {
        case .weeklyStrain:
            let vals = withData.compactMap { $0.value }
            let avg = vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
            percent = target > 0 ? avg / target * 100 : 0
        case .sleepDuration, .dailySteps:
            let hits = withData.filter { $0.hit }.count
            percent = withData.isEmpty ? 0 : Double(hits) / Double(withData.count) * 100
        }

        // Streak: walk newest→oldest; a data-less TODAY doesn't break it (the day
        // isn't over), but any other data-less or missed day does.
        var streak = 0
        if kind.isDaily {
            var entries = Array(week.reversed())
            if entries.first?.value == nil { entries.removeFirst() }
            for e in entries {
                if e.hit { streak += 1 } else { break }
            }
        }

        let today = week.last
        return Progress(kind: kind, target: target, week: week, percent: percent,
                        streak: streak, todayValue: today?.value ?? nil,
                        todayHit: today?.hit ?? false)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/tobiasluscher/Development/noop/Packages/StrandAnalytics && swift test --filter GoalProgressTests`
Expected: 5 tests PASS

- [ ] **Step 5: Run the full StrandAnalytics suite (regression)**

Run: `cd /Users/tobiasluscher/Development/noop/Packages/StrandAnalytics && swift test`
Expected: ALL tests PASS (existing + new)

- [ ] **Step 6: Commit**

```bash
git add Packages/StrandAnalytics
git commit -m "feat(analytics): GoalProgress — weekly adherence, streaks, strain-average goals"
```

---

### Task 6: Goal persistence — migration v11 + CRUD (WhoopStore)

**Files:**
- Modify: `Packages/WhoopStore/Sources/WhoopStore/Database.swift` (after the `v10` migration, ~line 230)
- Modify: `Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift:9` (`schemaVersion` 10 → 11)
- Create: `Packages/WhoopStore/Sources/WhoopStore/Goals.swift`
- Create: `Packages/WhoopStore/Tests/WhoopStoreTests/GoalsTests.swift`
- Modify: `Packages/WhoopStore/Tests/WhoopStoreTests/MetricsCacheTests.swift` — `testSchemaVersionBumped` asserts the old number; update to 11. (If it currently asserts 9 while schemaVersion is 10, that's a pre-existing latent mismatch — fix to 11 and note it in the commit message.)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import WhoopStore

final class GoalsTests: XCTestCase {

    func testV11CreatesGoalTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("goal"))
    }

    func testSaveAndReadActiveGoal() async throws {
        let store = try await WhoopStore.inMemory()
        let id = try await store.saveGoal(kind: "sleepDuration", target: 450, now: 1000)
        let goals = try await store.activeGoals()
        XCTAssertEqual(goals.count, 1)
        XCTAssertEqual(goals[0].id, id)
        XCTAssertEqual(goals[0].kind, "sleepDuration")
        XCTAssertEqual(goals[0].target, 450, accuracy: 1e-9)
        XCTAssertNil(goals[0].archivedAt)
    }

    func testSaveSameKindArchivesPrevious() async throws {
        // Max one active goal per kind: saving a new sleepDuration target archives the old one.
        let store = try await WhoopStore.inMemory()
        _ = try await store.saveGoal(kind: "sleepDuration", target: 450, now: 1000)
        _ = try await store.saveGoal(kind: "sleepDuration", target: 480, now: 2000)
        let goals = try await store.activeGoals()
        XCTAssertEqual(goals.count, 1)
        XCTAssertEqual(goals[0].target, 480, accuracy: 1e-9)
    }

    func testDifferentKindsCoexist() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.saveGoal(kind: "sleepDuration", target: 450, now: 1000)
        _ = try await store.saveGoal(kind: "dailySteps", target: 10000, now: 1000)
        let goals = try await store.activeGoals()
        XCTAssertEqual(goals.count, 2)
    }

    func testArchiveRemovesFromActive() async throws {
        let store = try await WhoopStore.inMemory()
        let id = try await store.saveGoal(kind: "weeklyStrain", target: 14, now: 1000)
        try await store.archiveGoal(id: id, now: 2000)
        let goals = try await store.activeGoals()
        XCTAssertTrue(goals.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/tobiasluscher/Development/noop/Packages/WhoopStore && swift test --filter GoalsTests`
Expected: compile FAIL — `value of type 'WhoopStore' has no member 'saveGoal'`

- [ ] **Step 3: Add migration v11 in Database.swift (directly after the v10 block)**

```swift
        // v11 (Tier A goals): user goal definitions. Adherence is computed at read
        // time from metricSeries — no tracking table. Additive only (same rationale
        // as v10: never rebuild destructively).
        migrator.registerMigration("v11") { db in
            try db.create(table: "goal") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()       // GoalProgress.Kind rawValue
                t.column("target", .double).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("archivedAt", .integer)        // NULL = active
            }
        }
```

And bump `WhoopStore.swift:9`: `public static let schemaVersion = 11`. Update `testSchemaVersionBumped` in MetricsCacheTests to assert 11.

- [ ] **Step 4: Write Goals.swift**

```swift
import Foundation
import GRDB

/// A user goal row (v11). NULL archivedAt = active. Max one active goal per kind
/// is enforced by saveGoal (archives the previous one), not by a constraint.
public struct GoalRow: Equatable, Codable, Sendable {
    public let id: Int64
    public let kind: String
    public let target: Double
    public let createdAt: Int
    public let archivedAt: Int?

    public init(id: Int64, kind: String, target: Double, createdAt: Int, archivedAt: Int?) {
        self.id = id; self.kind = kind; self.target = target
        self.createdAt = createdAt; self.archivedAt = archivedAt
    }
}

extension WhoopStore {

    /// Active goals (archivedAt IS NULL), newest first.
    public func activeGoals() async throws -> [GoalRow] {
        try syncRead { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, kind, target, createdAt, archivedAt
                FROM goal WHERE archivedAt IS NULL ORDER BY createdAt DESC, id DESC
                """)
            return rows.map {
                GoalRow(id: $0["id"], kind: $0["kind"], target: $0["target"],
                        createdAt: $0["createdAt"], archivedAt: $0["archivedAt"])
            }
        }
    }

    /// Insert a goal, archiving any existing active goal of the same kind first.
    @discardableResult
    public func saveGoal(kind: String, target: Double, now: Int) async throws -> Int64 {
        try syncWrite { db in
            try db.execute(sql: "UPDATE goal SET archivedAt = ? WHERE kind = ? AND archivedAt IS NULL",
                           arguments: [now, kind])
            try db.execute(sql: "INSERT INTO goal (kind, target, createdAt) VALUES (?, ?, ?)",
                           arguments: [kind, target, now])
            return db.lastInsertedRowID
        }
    }

    /// Soft-delete: stamp archivedAt so history is preserved.
    public func archiveGoal(id: Int64, now: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: "UPDATE goal SET archivedAt = ? WHERE id = ?",
                           arguments: [now, id])
        }
    }
}
```

(If `syncRead`/`syncWrite` signatures differ from this call shape, mirror exactly how `MetricsCache.swift` extensions call them.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/tobiasluscher/Development/noop/Packages/WhoopStore && swift test`
Expected: ALL pass, including 5 GoalsTests + updated `testSchemaVersionBumped`

- [ ] **Step 6: Commit**

```bash
git add Packages/WhoopStore
git commit -m "feat(store): goal table (v11) + CRUD — one active goal per kind, soft archive"
```

---

### Task 7: BehaviorStore planner keys

**Files:**
- Modify: `Strand/Data/BehaviorStore.swift`

- [ ] **Step 1: Add published properties (after the Smart alarm block, ~line 31)**

```swift
    // MARK: Sleep planner
    /// Manual wake time (minutes since local midnight) when the strap alarm is off.
    @Published var plannerWakeMinutes: Int { didSet { d.set(plannerWakeMinutes, forKey: K.plannerWake) } }
    /// SleepPlanner.Goal rawValue ("peak" / "perform" / "getBy").
    @Published var plannerGoalRaw: String { didSet { d.set(plannerGoalRaw, forKey: K.plannerGoal) } }
    /// iOS: schedule a wind-down notification 30 min before the recommended bedtime.
    @Published var bedtimeReminderEnabled: Bool { didSet { d.set(bedtimeReminderEnabled, forKey: K.bedtimeReminder) } }
```

Add to `enum K`:

```swift
        static let plannerWake = "planner.wakeMinutes"
        static let plannerGoal = "planner.goal"
        static let bedtimeReminder = "planner.bedtimeReminderEnabled"
```

Add to `init()` (after the existing assignments):

```swift
        plannerWakeMinutes = d.object(forKey: K.plannerWake) as? Int ?? 7 * 60     // 07:00
        plannerGoalRaw = d.string(forKey: K.plannerGoal) ?? "perform"
        bedtimeReminderEnabled = d.object(forKey: K.bedtimeReminder) as? Bool ?? false
```

- [ ] **Step 2: Build macOS to verify**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug build -quiet 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add Strand/Data/BehaviorStore.swift
git commit -m "feat(planner): BehaviorStore keys — wake time, goal level, bedtime reminder"
```

---

### Task 8: GoalStore + AppModel/app wiring

**Files:**
- Create: `Strand/Data/GoalStore.swift`
- Modify: `Strand/App/AppModel.swift` (~line 40, next to `let profile = ProfileStore()`)
- Modify: `Strand/App/StrandApp.swift` (environmentObject chain, ~line 10)
- Modify: `StrandiOS/App/StrandiOSApp.swift` (environmentObject chain, ~line 34)

- [ ] **Step 1: Write GoalStore**

```swift
import Foundation
import Combine
import WhoopStore
import StrandAnalytics

/// Active goals + CRUD over the WhoopStore `goal` table. App-side wrapper so
/// screens can bind; adherence math lives in StrandAnalytics.GoalProgress.
@MainActor
final class GoalStore: ObservableObject {
    @Published private(set) var goals: [GoalRow] = []
    @Published private(set) var loaded = false

    private let repo: Repository
    init(repo: Repository) { self.repo = repo }

    func load() async {
        guard let store = await repo.storeHandle() else { return }
        goals = (try? await store.activeGoals()) ?? []
        loaded = true
    }

    func save(kind: GoalProgress.Kind, target: Double) async {
        guard let store = await repo.storeHandle() else { return }
        _ = try? await store.saveGoal(kind: kind.rawValue, target: target,
                                      now: Int(Date().timeIntervalSince1970))
        await load()
    }

    func archive(id: Int64) async {
        guard let store = await repo.storeHandle() else { return }
        try? await store.archiveGoal(id: id, now: Int(Date().timeIntervalSince1970))
        await load()
    }
}
```

- [ ] **Step 2: Wire into AppModel**

In `Strand/App/AppModel.swift`, near `let profile = ProfileStore()` (~line 40), add a stored property. The `repo` property already exists on AppModel — match its actual name (it is referenced as `model.repo` from both Apps). If `repo` is initialized inline, use a `lazy var`:

```swift
    lazy var goalStore = GoalStore(repo: repo)
```

(If AppModel has an explicit `init`, instead initialize `goalStore = GoalStore(repo: repo)` after `repo` is set.)

- [ ] **Step 3: Inject into both apps**

`Strand/App/StrandApp.swift` — in EVERY `.environmentObject(model.repo)` chain (there are three: main window ~line 10, plus two more at ~lines 27 and 32), add:

```swift
                .environmentObject(model.goalStore)
```

`StrandiOS/App/StrandiOSApp.swift` — in the `.environmentObject` chain (~line 34), add the same line.

- [ ] **Step 4: Run xcodegen + build both platforms**

```bash
cd /Users/tobiasluscher/Development/noop && xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug build -quiet 2>&1 | tail -3
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug -destination 'generic/platform=iOS Simulator' build -quiet 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED` twice

- [ ] **Step 5: Commit**

```bash
git add Strand/Data/GoalStore.swift Strand/App/AppModel.swift Strand/App/StrandApp.swift StrandiOS/App/StrandiOSApp.swift Strand.xcodeproj
git commit -m "feat(goals): GoalStore wired into AppModel + both app shells"
```

---

### Task 9: Strain Coach UI — DayStrain helper, TodayView card, LiveView strip

**Invoke the `frontend-design:frontend-design` skill before writing the views.**

**Files:**
- Create: `Strand/Data/DayStrain.swift`
- Modify: `Strand/Screens/TodayView.swift` (state ~line 35, body VStack ~line 56, `loadAll()` ~line 404)
- Modify: `Strand/Screens/LiveView.swift` (below `heartRateCard`, ~line 95)

- [ ] **Step 1: Write DayStrain helper**

```swift
import Foundation
import StrandAnalytics

/// Intraday ("so far today") strain from the raw 1 Hz HR stream. Shared by the
/// Today strain-coach card and the Live strip so the number can never disagree.
enum DayStrain {
    /// nil when under StrainScorer.minReadings (~10 min of samples) — callers show pending.
    static func compute(repo: Repository, hrMax: Int, sex: String, restingHr: Int?) async -> Double? {
        let startOfToday = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let nowTs = Int(Date().timeIntervalSince1970)
        // 1 Hz ⇒ up to 86 400 rows/day; the default 8 000 limit would silently truncate.
        let samples = await repo.hrSamples(from: startOfToday, to: nowTs, limit: 100_000)
        let resting = restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
        return StrainScorer.strain(samples, maxHR: Double(hrMax), restingHR: resting, sex: sex)
    }
}
```

- [ ] **Step 2: TodayView — state + load**

Add environment + state near the existing `@State` vars (~line 30):

```swift
    @EnvironmentObject var profile: ProfileStore
    // Strain Coach — intraday strain so far today (nil until ~10 min of HR exists).
    @State private var dayStrain: Double? = nil
```

At the END of `loadAll()` (~line 421, after the hrPoints assignment):

```swift
        // Strain Coach — intraday strain from today's raw HR.
        dayStrain = await DayStrain.compute(repo: repo, hrMax: profile.hrMax,
                                            sex: profile.sex,
                                            restingHr: repo.today?.restingHr)
```

- [ ] **Step 3: TodayView — strainCoachSection**

Insert `strainCoachSection` in the body VStack directly after `heroSection` (~line 56). Add this section builder near `readinessSection`:

```swift
    // MARK: Strain Coach — today's exertion target from recovery, filled live.

    @ViewBuilder
    private var strainCoachSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Strain Coach", overline: "Today's exertion target")
            NoopCard {
                if let recovery = repo.today?.recovery {
                    let band = StrainTarget.band(recovery: recovery)
                    let current = dayStrain ?? 0
                    // Wide: gauge + text side by side. Compact iPhone: stacked.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: NoopMetrics.gap * 2) {
                            strainCoachGauge(current: current)
                            strainCoachDetail(band: band, current: current)
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                            strainCoachGauge(current: current).frame(maxWidth: .infinity)
                            strainCoachDetail(band: band, current: current)
                        }
                    }
                } else {
                    Text("No recovery yet today — your strain target appears once last night is scored.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func strainCoachGauge(current: Double) -> some View {
        StrainGauge(strain: current, diameter: 132, lineWidth: 11)
            .frame(minWidth: 132)
    }

    @ViewBuilder
    private func strainCoachDetail(band: StrainTarget.Band, current: Double) -> some View {
        let state = band.state(currentStrain: current)
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: "Aim %.1f–%.1f", band.low, band.high))
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(strainCoachStateLine(state, band: band, current: current))
                .font(StrandFont.subhead)
                .foregroundStyle(strainCoachStateColor(state))
            if dayStrain == nil {
                Text("Building — needs about 10 minutes of heart-rate data.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else if !live.connected {
                Text("Strap not connected — showing the last synced value.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func strainCoachStateLine(_ s: StrainTarget.State, band: StrainTarget.Band, current: Double) -> String {
        switch s {
        case .building:     return String(format: "%.1f now — room to push today.", current)
        case .onTarget:     return String(format: "%.1f now — right in your target band.", current)
        case .overreaching: return String(format: "%.1f now — beyond today's recommendation.", current)
        }
    }

    private func strainCoachStateColor(_ s: StrainTarget.State) -> Color {
        switch s {
        case .building:     return StrandPalette.textSecondary
        case .onTarget:     return StrandPalette.accent
        case .overreaching: return StrandPalette.statusWarning
        }
    }
```

- [ ] **Step 4: LiveView — day-strain strip**

LiveView needs the same data. Add to LiveView:

```swift
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @State private var dayStrain: Double? = nil
```

In `heartRateCard`'s inner VStack, after the R-R line:

```swift
                if let s = dayStrain, let recovery = repo.today?.recovery {
                    let band = StrainTarget.band(recovery: recovery)
                    Text(String(format: "Day strain %.1f / target %.1f–%.1f", s, band.low, band.high))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .padding(.top, 2)
                }
```

On the ScreenScaffold add (next to the existing `.onAppear`):

```swift
        .task(id: repo.refreshSeq) {
            dayStrain = await DayStrain.compute(repo: repo, hrMax: profile.hrMax,
                                                sex: profile.sex,
                                                restingHr: repo.today?.restingHr)
        }
```

Add `import StrandAnalytics` to LiveView.swift if missing.

- [ ] **Step 5: xcodegen + build both platforms**

```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug build -quiet 2>&1 | tail -3
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug -destination 'generic/platform=iOS Simulator' build -quiet 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED` twice

- [ ] **Step 6: Commit**

```bash
git add Strand/Data/DayStrain.swift Strand/Screens/TodayView.swift Strand/Screens/LiveView.swift Strand.xcodeproj
git commit -m "feat(strain-coach): recovery-driven target band + live intraday strain on Today and Live"
```

---

### Task 10: Sleep Planner UI + iOS bedtime reminder

**Invoke the `frontend-design:frontend-design` skill before writing the views.**

**Files:**
- Modify: `Strand/Screens/SleepView.swift` (planner card at the top of the main VStack; helpers near the derived-model section)
- Create: `StrandiOS/System/BedtimeReminderScheduler.swift`

- [ ] **Step 1: Write BedtimeReminderScheduler**

```swift
#if os(iOS)
import Foundation
import UserNotifications

/// Schedules tonight's wind-down nudge 30 min before the recommended bedtime.
/// Non-repeating — re-scheduled whenever the recommendation or toggle changes
/// (SleepView drives it), so it always reflects tonight's need.
final class BedtimeReminderScheduler {
    static let shared = BedtimeReminderScheduler()
    static let notificationID = "noop.bedtime.reminder"
    private let center = UNUserNotificationCenter.current()

    /// minutes-since-midnight of the recommended bedtime.
    func apply(enabled: Bool, bedMinutes: Int) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        guard enabled else { return }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard granted, let self else { return }
            var remind = bedMinutes - 30
            if remind < 0 { remind += 1440 }
            let content = UNMutableNotificationContent()
            content.title = "Wind down"
            content.body = "Bedtime in 30 minutes to hit tonight's sleep goal."
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: DateComponents(hour: remind / 60, minute: remind % 60),
                repeats: false)
            self.center.add(UNNotificationRequest(identifier: Self.notificationID,
                                                  content: content, trigger: trigger))
        }
    }
}
#endif
```

- [ ] **Step 2: SleepView — planner inputs**

Add to SleepView (next to its existing `@EnvironmentObject` vars):

```swift
    @EnvironmentObject private var behavior: BehaviorStore
```

Add helpers near the derived-model section (~line 387):

```swift
    // MARK: - Sleep Planner

    private var plannerGoal: SleepPlanner.Goal {
        SleepPlanner.Goal(rawValue: behavior.plannerGoalRaw) ?? .perform
    }

    /// Strap alarm wins when enabled; manual planner time otherwise.
    private var plannerWakeMinutes: Int {
        behavior.smartAlarmEnabled ? behavior.smartAlarmMinutes : behavior.plannerWakeMinutes
    }

    /// Personal typical efficiency as 0–1, nil without history.
    private var typicalEfficiency: Double? {
        let vals = repo.days.compactMap { $0.efficiency }.map { $0 <= 1.0 ? $0 : $0 / 100 }
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    private var plannerRecommendation: SleepPlanner.Recommendation {
        let lastDebt = sleepDebtSeries.latest ?? 0
        return SleepPlanner.recommend(wakeMinutes: plannerWakeMinutes,
                                      baseNeedMin: sleepNeedMin,
                                      debtMin: lastDebt,
                                      efficiency: typicalEfficiency,
                                      goal: plannerGoal)
    }

    private static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }
```

- [ ] **Step 3: SleepView — planner card**

Insert `plannerSection` as the FIRST section of the screen's main VStack (above the hero/hypnogram). Builder:

```swift
    @ViewBuilder
    private var plannerSection: some View {
        let rec = plannerRecommendation
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep Planner", overline: "Tonight's plan")
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    // Goal chips.
                    SegmentedPillControl(SleepPlanner.Goal.allCases,
                                         selection: Binding(
                                            get: { plannerGoal },
                                            set: { behavior.plannerGoalRaw = $0.rawValue }),
                                         label: { goalLabel($0) })
                    // Big recommendation.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("In bed by")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Text(Self.clock(rec.bedMinutes))
                            .font(.system(size: 44, weight: .semibold).monospacedDigit())
                            .foregroundStyle(StrandPalette.accent)
                    }
                    // Breakdown.
                    VStack(alignment: .leading, spacing: 4) {
                        plannerRow("Sleep need", minutesText(rec.needMin))
                        plannerRow("Goal (\(goalLabel(plannerGoal)))", minutesText(rec.goalSleepMin))
                        plannerRow("Time in bed", minutesText(rec.inBedMin))
                        if rec.usedDefaults {
                            Text("Based on defaults — sharpens after a few nights.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    Divider().overlay(StrandPalette.hairline)
                    // Wake time row.
                    if behavior.smartAlarmEnabled {
                        HStack(spacing: 8) {
                            Image(systemName: "alarm.fill")
                                .foregroundStyle(StrandPalette.accent)
                            Text("Wake \(Self.clock(behavior.smartAlarmMinutes)) — from your strap alarm")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text("Wake time")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                            Stepper(value: Binding(
                                        get: { behavior.plannerWakeMinutes },
                                        set: { behavior.plannerWakeMinutes = (($0 % 1440) + 1440) % 1440 }),
                                    in: 0...1439, step: 15) {
                                Text(Self.clock(behavior.plannerWakeMinutes))
                                    .font(StrandFont.headline.monospacedDigit())
                                    .foregroundStyle(StrandPalette.textPrimary)
                            }
                        }
                    }
                    #if os(iOS)
                    Toggle("Remind me 30 min before bedtime", isOn: $behavior.bedtimeReminderEnabled)
                        .font(StrandFont.subhead)
                        .tint(StrandPalette.accent)
                    #endif
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        #if os(iOS)
        .onChange(of: behavior.bedtimeReminderEnabled) { _ in syncBedtimeReminder() }
        .onChange(of: plannerRecommendation) { _ in syncBedtimeReminder() }
        .onAppear { syncBedtimeReminder() }
        #endif
    }

    private func goalLabel(_ g: SleepPlanner.Goal) -> String {
        switch g {
        case .peak: return "Peak"
        case .perform: return "Perform"
        case .getBy: return "Get By"
        }
    }

    private func minutesText(_ m: Double) -> String {
        let h = Int(m) / 60, r = Int(m) % 60
        return "\(h)h \(String(format: "%02d", r))m"
    }

    private func plannerRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            Text(value).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    #if os(iOS)
    private func syncBedtimeReminder() {
        BedtimeReminderScheduler.shared.apply(enabled: behavior.bedtimeReminderEnabled,
                                              bedMinutes: plannerRecommendation.bedMinutes)
    }
    #endif
```

Adaptation notes for the executor (verify against the actual file):
- `sleepDebtSeries` is the tuple `(latest, typical, series)` — `.latest` is its first member; if tuple labels differ, use `.0`.
- `SegmentedPillControl` signature: `init(_ items: [T], selection: Binding<T>, label: @escaping (T) -> String)` — confirm at `Packages/StrandDesign/Sources/StrandDesign/Components.swift:201`, adjust call if it differs.
- `onChange(of:)` single-parameter form matches existing usage in LiveView (`.onChange(of: live.bonded) { _ in ... }`) — keep that form for the deployment target.
- `Recommendation` must be `Equatable` for `.onChange` — it already is.
- The planner card must render acceptably at iPhone width: all rows are vertical/full-width already; no ViewThatFits needed, but verify in the simulator (Task 13).

- [ ] **Step 4: xcodegen + build both platforms**

```bash
cd /Users/tobiasluscher/Development/noop && xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug build -quiet 2>&1 | tail -3
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug -destination 'generic/platform=iOS Simulator' build -quiet 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED` twice

- [ ] **Step 5: Commit**

```bash
git add Strand/Screens/SleepView.swift StrandiOS/System/BedtimeReminderScheduler.swift Strand.xcodeproj
git commit -m "feat(sleep-planner): bedtime recommendation card + iOS wind-down reminder"
```

---

### Task 11: ReportView + navigation

**Invoke the `frontend-design:frontend-design` skill before writing the view.**

**Files:**
- Create: `Strand/Screens/ReportView.swift`
- Modify: `Strand/App/RootView.swift` (NavItem enum + titleKey + icon + detail switch)
- Modify: `StrandiOS/App/RootTabView.swift` (More → Insights section + DebugScreenHost)

- [ ] **Step 1: Write ReportView**

```swift
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Performance Report — periodized 7/28-day assessment (recovery / sleep / strain
/// + takeaways), computed on-device by PerformanceReport from the dashboard cache.
struct ReportView: View {
    @EnvironmentObject private var repo: Repository
    @State private var period: PerformanceReport.Period = .weekly

    private var summary: PerformanceReport.Summary {
        PerformanceReport.build(days: repo.days, period: period,
                                today: Repository.localDayKey(Date()))
    }

    var body: some View {
        ScreenScaffold(title: "Performance Report",
                       subtitle: "Your recovery, sleep and strain over the period — and what to do next.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                SegmentedPillControl(PerformanceReport.Period.allCases,
                                     selection: $period,
                                     label: { $0 == .weekly ? "Weekly" : "Monthly" })
                let s = summary
                if s.coverage == 0 {
                    ComingSoon(what: "No data in this period yet. Wear the strap or import your WHOOP export in Data Sources, then check back.")
                } else {
                    headerCard(s)
                    if !s.takeaways.isEmpty { takeawaysSection(s) }
                    recoverySection(s)
                    sleepSection(s)
                    strainSection(s)
                }
            }
        }
    }

    // MARK: Header

    private func headerCard(_ s: PerformanceReport.Summary) -> some View {
        NoopCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(s.fromDay) → \(s.toDay)")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("\(s.coverage) of \(s.period.days) days with data")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
            }
        }
    }

    private func takeawaysSection(_ s: PerformanceReport.Summary) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Takeaways", overline: "What the period says")
            NoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(s.takeaways, id: \.self) { t in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(StrandPalette.accent).frame(width: 7, height: 7)
                                .padding(.top, 5)
                            Text(t).font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Sections — shared tile builders

    /// Δ caption like "+4.2 vs prior" — hidden (nil) when no prior-window data.
    private func deltaCaption(_ a: PerformanceReport.Average?, unit: String, decimals: Int) -> String? {
        guard let d = a?.delta else { return nil }
        return String(format: "%+.\(decimals)f%@ vs prior", d, unit)
    }

    private func tile(_ label: LocalizedStringKey, _ a: PerformanceReport.Average?,
                      unit: String, decimals: Int) -> some View {
        StatTile(label: label,
                 value: a.map { String(format: "%.\(decimals)f%@", $0.value, unit) } ?? "—",
                 caption: deltaCaption(a, unit: unit, decimals: decimals))
    }

    private var grid: [GridItem] { [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)] }

    private func recoverySection(_ s: PerformanceReport.Summary) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Recovery", overline: "Capacity over the period")
            LazyVGrid(columns: grid, spacing: NoopMetrics.gap) {
                tile("Avg recovery", s.recovery, unit: "%", decimals: 0)
                tile("Avg HRV", s.hrv, unit: " ms", decimals: 0)
                tile("Avg RHR", s.rhr, unit: " bpm", decimals: 0)
                if let b = s.bestRecoveryDay {
                    StatTile(label: "Best day", value: String(format: "%.0f%%", b.value), caption: b.day)
                }
                if let w = s.worstRecoveryDay {
                    StatTile(label: "Toughest day", value: String(format: "%.0f%%", w.value), caption: w.day)
                }
            }
        }
    }

    private func sleepSection(_ s: PerformanceReport.Summary) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep", overline: "Need vs banked")
            LazyVGrid(columns: grid, spacing: NoopMetrics.gap) {
                StatTile(label: "Avg sleep",
                         value: s.sleepMin.map { hoursText($0.value) } ?? "—",
                         caption: s.sleepMin?.delta.map { String(format: "%+.0f min vs prior", $0) })
                StatTile(label: "Sleep need", value: hoursText(s.sleepNeedMin), caption: nil)
                StatTile(label: "Performance",
                         value: s.sleepPerformancePct.map { String(format: "%.0f%%", $0) } ?? "—",
                         caption: "of need banked")
            }
        }
    }

    private func strainSection(_ s: PerformanceReport.Summary) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Strain", overline: "Load vs your targets")
            LazyVGrid(columns: grid, spacing: NoopMetrics.gap) {
                tile("Avg strain", s.strain, unit: "", decimals: 1)
                StatTile(label: "Total strain",
                         value: s.totalStrain.map { String(format: "%.1f", $0) } ?? "—",
                         caption: nil)
                StatTile(label: "Over target", value: "\(s.overreachDays) days",
                         caption: "above the recovery-set band")
                StatTile(label: "Under target", value: "\(s.underreachDays) days",
                         caption: "room left on the table")
            }
        }
    }

    private func hoursText(_ minutes: Double) -> String {
        let h = Int(minutes) / 60, m = Int(minutes) % 60
        return "\(h)h \(String(format: "%02d", m))m"
    }
}
```

Adaptation notes: `StatTile`'s real init is `init(label:value:caption:...)` (Components.swift:73) — if `caption` is non-optional or extra params are required, match it. `ComingSoon(what:)` is the existing empty-state component used by SleepView — reuse as-is.

- [ ] **Step 2: macOS navigation (RootView.swift)**

Add to `enum NavItem` after `case trends`:

```swift
    case report = "Report"
```

Add to `titleKey`: `case .report: return "Report"`.
Add to `icon`: `case .report: return "doc.text.below.ecg"`.
Add to the `detail` switch: `case .report: ReportView()`.

- [ ] **Step 3: iOS navigation (RootTabView.swift)**

In `moreTab` → `Section("Insights")` after the Compare link:

```swift
                    link("Report", "doc.text.below.ecg") { ReportView() }
```

In `DebugScreenHost.screen` add: `case "report": ReportView()`.

- [ ] **Step 4: xcodegen + build both platforms**

```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug build -quiet 2>&1 | tail -3
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug -destination 'generic/platform=iOS Simulator' build -quiet 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED` twice

- [ ] **Step 5: Commit**

```bash
git add Strand/Screens/ReportView.swift Strand/App/RootView.swift StrandiOS/App/RootTabView.swift Strand.xcodeproj
git commit -m "feat(report): periodized performance report screen + nav on both platforms"
```

---

### Task 12: GoalsView + Today goal chips + navigation

**Invoke the `frontend-design:frontend-design` skill before writing the views.**

**Files:**
- Create: `Strand/Screens/GoalsView.swift`
- Modify: `Strand/Screens/TodayView.swift` (goals chip section)
- Modify: `Strand/App/RootView.swift` (NavItem)
- Modify: `StrandiOS/App/RootTabView.swift` (More link + DebugScreenHost)

- [ ] **Step 1: Write GoalsView**

```swift
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Goals — set a target (sleep / weekly strain / steps), see weekly adherence,
/// streaks and a 7-day dot row. Math in GoalProgress; rows in the goal table.
struct GoalsView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var goalStore: GoalStore

    @State private var showingAdd = false
    @State private var stepsByDay: [String: Double] = [:]

    /// Trailing 7 day-keys ending today, oldest→newest.
    private var weekDays: [String] {
        (0..<7).reversed().map {
            Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -$0, to: Date()) ?? Date())
        }
    }

    var body: some View {
        ScreenScaffold(title: "Goals",
                       subtitle: "Pick a target, then let the week keep score.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if goalStore.goals.isEmpty {
                    ComingSoon(what: "No goals yet. Set one — sleep duration, weekly strain or daily steps — and adherence shows up here and on Today.")
                } else {
                    ForEach(goalStore.goals, id: \.id) { goal in
                        goalCard(goal)
                    }
                }
                Button {
                    showingAdd = true
                } label: {
                    Label("Add goal", systemImage: "plus.circle.fill")
                        .font(StrandFont.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
            }
        }
        .task(id: repo.refreshSeq) {
            await goalStore.load()
            stepsByDay = Dictionary(uniqueKeysWithValues:
                await repo.series(key: "steps", source: "apple-health").map { ($0.day, $0.value) })
        }
        .sheet(isPresented: $showingAdd) {
            AddGoalSheet { kind, target in
                Task { await goalStore.save(kind: kind, target: target) }
            }
        }
    }

    // MARK: Per-goal card

    private func values(for kind: GoalProgress.Kind) -> [String: Double] {
        switch kind {
        case .sleepDuration:
            return Dictionary(uniqueKeysWithValues:
                repo.days.compactMap { d in d.totalSleepMin.map { (d.day, $0) } })
        case .weeklyStrain:
            return Dictionary(uniqueKeysWithValues:
                repo.days.compactMap { d in d.strain.map { (d.day, $0) } })
        case .dailySteps:
            return stepsByDay
        }
    }

    @ViewBuilder
    private func goalCard(_ goal: GoalRow) -> some View {
        if let kind = GoalProgress.Kind(rawValue: goal.kind) {
            let p = GoalProgress.evaluate(kind: kind, target: goal.target,
                                          values: values(for: kind), weekDays: weekDays)
            NoopCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(kindTitle(kind))
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Button {
                            Task { await goalStore.archive(id: goal.id) }
                        } label: {
                            Image(systemName: "archivebox")
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Archive this goal")
                        .accessibilityLabel("Archive this goal")
                    }
                    Text(targetLine(kind, target: goal.target))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(String(format: "%.0f%%", min(999, p.percent)))
                            .font(.system(size: 34, weight: .semibold).monospacedDigit())
                            .foregroundStyle(p.percent >= 100 ? StrandPalette.accent : StrandPalette.textPrimary)
                        Text(kind.isDaily ? "of days hit this week" : "of your weekly target")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Spacer()
                        if p.streak >= 2 {
                            StatePill("\(p.streak)-day streak", tone: .positive)
                        }
                    }
                    // 7-day dot row, oldest→newest.
                    HStack(spacing: 8) {
                        ForEach(p.week, id: \.day) { d in
                            Circle()
                                .fill(d.hit ? StrandPalette.accent
                                      : d.value != nil ? StrandPalette.metricRose.opacity(0.55)
                                      : StrandPalette.surfaceRaised)
                                .frame(width: 14, height: 14)
                        }
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func kindTitle(_ k: GoalProgress.Kind) -> String {
        switch k {
        case .sleepDuration: return "Sleep duration"
        case .weeklyStrain:  return "Weekly strain"
        case .dailySteps:    return "Daily steps"
        }
    }

    private func targetLine(_ k: GoalProgress.Kind, target: Double) -> String {
        switch k {
        case .sleepDuration:
            let h = Int(target) / 60, m = Int(target) % 60
            return "Target: \(h)h \(String(format: "%02d", m))m per night"
        case .weeklyStrain:
            return String(format: "Target: %.1f average day strain", target)
        case .dailySteps:
            return "Target: \(Int(target)) steps per day"
        }
    }
}

/// Add-goal sheet: kind picker + a per-kind target slider with sensible ranges.
private struct AddGoalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (GoalProgress.Kind, Double) -> Void

    @State private var kind: GoalProgress.Kind = .sleepDuration
    @State private var sleepTarget: Double = 450      // 6h..10h, step 15
    @State private var strainTarget: Double = 14      // 8..18, step 0.5
    @State private var stepsTarget: Double = 10_000   // 4k..20k, step 500

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New goal")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Picker("Goal type", selection: $kind) {
                Text("Sleep duration").tag(GoalProgress.Kind.sleepDuration)
                Text("Weekly strain").tag(GoalProgress.Kind.weeklyStrain)
                Text("Daily steps").tag(GoalProgress.Kind.dailySteps)
            }
            .pickerStyle(.segmented)
            targetControl
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save goal") {
                    onSave(kind, currentTarget)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
            }
        }
        .padding(24)
        .frame(minWidth: 320)
        .background(StrandPalette.surfaceBase)
    }

    private var currentTarget: Double {
        switch kind {
        case .sleepDuration: return sleepTarget
        case .weeklyStrain:  return strainTarget
        case .dailySteps:    return stepsTarget
        }
    }

    @ViewBuilder
    private var targetControl: some View {
        switch kind {
        case .sleepDuration:
            VStack(alignment: .leading, spacing: 6) {
                Text("\(Int(sleepTarget) / 60)h \(String(format: "%02d", Int(sleepTarget) % 60))m per night")
                    .font(StrandFont.headline.monospacedDigit())
                    .foregroundStyle(StrandPalette.accent)
                Slider(value: $sleepTarget, in: 360...600, step: 15)
            }
        case .weeklyStrain:
            VStack(alignment: .leading, spacing: 6) {
                Text(String(format: "%.1f average day strain", strainTarget))
                    .font(StrandFont.headline.monospacedDigit())
                    .foregroundStyle(StrandPalette.accent)
                Slider(value: $strainTarget, in: 8...18, step: 0.5)
            }
        case .dailySteps:
            VStack(alignment: .leading, spacing: 6) {
                Text("\(Int(stepsTarget)) steps per day")
                    .font(StrandFont.headline.monospacedDigit())
                    .foregroundStyle(StrandPalette.accent)
                Slider(value: $stepsTarget, in: 4000...20000, step: 500)
            }
        }
    }
}
```

- [ ] **Step 2: TodayView — goal status chips**

Add to TodayView:

```swift
    @EnvironmentObject var goalStore: GoalStore
    @State private var goalStepsByDay: [String: Double] = [:]
```

In `loadAll()` (end):

```swift
        // Goals chips.
        await goalStore.load()
        goalStepsByDay = Dictionary(uniqueKeysWithValues:
            await repo.series(key: "steps", source: "apple-health").map { ($0.day, $0.value) })
```

Insert `goalsSection` in the body VStack after `strainCoachSection`. Builder (near the other sections):

```swift
    // MARK: Goals — today's status per active goal. Hidden with no goals.

    @ViewBuilder
    private var goalsSection: some View {
        if !goalStore.goals.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Goals", overline: "Today's score")
                NoopCard {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(goalStore.goals, id: \.id) { goal in
                            if let kind = GoalProgress.Kind(rawValue: goal.kind) {
                                goalChipRow(goal: goal, kind: kind)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func goalChipRow(goal: GoalRow, kind: GoalProgress.Kind) -> some View {
        let week = (0..<7).reversed().map {
            Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -$0, to: Date()) ?? Date())
        }
        let values: [String: Double] = {
            switch kind {
            case .sleepDuration:
                return Dictionary(uniqueKeysWithValues:
                    repo.days.compactMap { d in d.totalSleepMin.map { (d.day, $0) } })
            case .weeklyStrain:
                return Dictionary(uniqueKeysWithValues:
                    repo.days.compactMap { d in d.strain.map { (d.day, $0) } })
            case .dailySteps:
                return goalStepsByDay
            }
        }()
        let p = GoalProgress.evaluate(kind: kind, target: goal.target, values: values, weekDays: week)
        HStack(spacing: 10) {
            Circle()
                .fill(p.todayHit ? StrandPalette.accent
                      : p.todayValue != nil ? StrandPalette.statusWarning
                      : StrandPalette.textTertiary)
                .frame(width: 9, height: 9)
            Text(goalChipTitle(kind))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            Text(p.todayHit ? "Hit" : p.todayValue != nil ? "In progress" : "No data yet")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func goalChipTitle(_ k: GoalProgress.Kind) -> String {
        switch k {
        case .sleepDuration: return "Sleep duration"
        case .weeklyStrain:  return "Weekly strain"
        case .dailySteps:    return "Daily steps"
        }
    }
```

- [ ] **Step 3: Navigation**

`RootView.swift`: add `case goals = "Goals"` to NavItem; `titleKey`: `case .goals: return "Goals"`; `icon`: `case .goals: return "target"`; detail: `case .goals: GoalsView()`.

`RootTabView.swift`: in `Section("Insights")` after the Report link add:

```swift
                    link("Goals", "target") { GoalsView() }
```

`DebugScreenHost.screen`: add `case "goals": GoalsView()`.

- [ ] **Step 4: xcodegen + build both platforms**

```bash
cd /Users/tobiasluscher/Development/noop && xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Debug build -quiet 2>&1 | tail -3
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug -destination 'generic/platform=iOS Simulator' build -quiet 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED` twice

- [ ] **Step 5: Commit**

```bash
git add Strand/Screens/GoalsView.swift Strand/Screens/TodayView.swift Strand/App/RootView.swift StrandiOS/App/RootTabView.swift Strand.xcodeproj
git commit -m "feat(goals): GoalsView with weekly adherence + Today status chips + nav"
```

---

### Task 13: Localization, full verification, simulator screenshots

**Files:**
- Modify: `Strand/Resources/Localizable.xcstrings` (German for all new strings)
- No other code changes expected — fix-forward anything the verification surfaces.

- [ ] **Step 1: Run every test suite**

```bash
cd /Users/tobiasluscher/Development/noop/Packages/StrandAnalytics && swift test 2>&1 | tail -3
cd /Users/tobiasluscher/Development/noop/Packages/WhoopStore && swift test 2>&1 | tail -3
cd /Users/tobiasluscher/Development/noop && xcodebuild test -project Strand.xcodeproj -scheme Strand -quiet 2>&1 | tail -5
```
Expected: all PASS

- [ ] **Step 2: German localization**

Build once (`xcodebuild -scheme Strand build`) so `SWIFT_EMIT_LOC_STRINGS` extracts the new keys into `Strand/Resources/Localizable.xcstrings`, then add German (`de`) translations for every new key (Strain Coach, Sleep Planner, Report, Goals strings). Follow the informal du/dein register per the existing German strings (e.g. "Dein Strain-Ziel", "Im Bett bis", "Schlafbedarf"). Commit:

```bash
git add Strand/Resources/Localizable.xcstrings
git commit -m "i18n: German strings for strain coach, sleep planner, report, goals"
```

- [ ] **Step 3: Simulator screenshot pass (NOOP_SCREEN harness)**

Boot a simulator and capture each new/changed screen with the existing harness (it reads the `NOOP_SCREEN` env var; simulator-only):

```bash
xcrun simctl boot "iPhone 16" 2>/dev/null || true
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16' build -quiet
APP=$(find ~/Library/Developer/Xcode/DerivedData -path '*Debug-iphonesimulator/NOOP.app' | head -1)
xcrun simctl install "iPhone 16" "$APP"
for screen in today sleep report goals live; do
  xcrun simctl launch --terminate-running-process \
    --setenv NOOP_SCREEN=$screen "iPhone 16" com.tecminds.noop
  sleep 3
  xcrun simctl io "iPhone 16" screenshot /tmp/noop-$screen.png
done
```

(If the simctl `--setenv` form differs from what the repo's tooling used before, check `git log --all --oneline -- '*screenshot*'` and docs/IOS.md for the canonical harness invocation.)

- [ ] **Step 4: Review each screenshot**

Read each `/tmp/noop-*.png`. Check: no clipped text, no overlapping tiles, planner card readable at iPhone width, gauge band text visible, goals dots row aligned, report grids wrap to 2-up. Fix layout issues (ViewThatFits/size-class), rebuild, re-capture until clean. Send the final set to the user.

- [ ] **Step 5: macOS visual sanity**

`xcodebuild -scheme Strand -configuration Debug build` then launch the built NOOP.app once; click Report, Goals, Sleep, Today in the sidebar; confirm rendering. Close the app afterwards.

- [ ] **Step 6: Commit any fixes**

```bash
git add -A && git commit -m "fix(ui): layout polish from simulator verification pass"
```

---

### Task 14: TestFlight upload

**Pre-step: mem-search "TestFlight upload build 25" (claude-mem) for this morning's exact working commands/gotchas — they supersede the generic commands below. Known gotchas: app icon must have NO alpha channel (already fixed in pipeline); build 25 was uploaded 2026-06-10 morning, so this build is 26+.**

- [ ] **Step 1: Merge/submit the branch per Graphite flow**

```bash
gt submit --no-edit   # PR for whoop-parity-tier-a
```
Get user approval on the PR before shipping if they want to review; else continue.

- [ ] **Step 2: Bump version/build**

In `project.yml`: bump `MARKETING_VERSION` 1.61 → 1.62 and set the build number (`CURRENT_PROJECT_VERSION`) to 26 — verify against App Store Connect's latest build number first; must be strictly greater. Then `xcodegen generate`.

- [ ] **Step 3: Archive + export + upload**

```bash
cd /Users/tobiasluscher/Development/noop
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath /tmp/NOOP.xcarchive archive
# ExportOptions: method app-store-connect, team 48XAPJ6DGL, automatic signing —
# reuse the exact ExportOptions.plist from this morning's upload (mem-search).
xcodebuild -exportArchive -archivePath /tmp/NOOP.xcarchive \
  -exportPath /tmp/NOOP-export -exportOptionsPlist /tmp/ExportOptions.plist
xcrun altool --upload-app -f /tmp/NOOP-export/*.ipa -t ios \
  --apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \
  || echo "altool failed — try: xcrun notarytool / Transporter.app, or the exact upload command from this morning (mem-search)"
```

- [ ] **Step 4: Verify processing + commit + tag**

- Confirm the build appears in App Store Connect → TestFlight (processing 5–60 min; email on completion).
- Remind the user: the build reaches the phone's TestFlight app only after processing AND the Apple ID is an internal tester.

```bash
git add project.yml Strand.xcodeproj
git commit -m "chore(release): v1.62 (26) — tier A WHOOP parity to TestFlight"
gt submit --no-edit
```

---

## Self-Review (done at planning time)

- **Spec coverage:** §1 infra → Tasks 1–8; §2 Strain Coach → Task 9; §3 Sleep Planner → Tasks 3, 7, 10; §4 Report → Tasks 4, 11; §5 Goals → Tasks 5, 6, 8, 12; §6 error states → empty states in Tasks 9–12; §7 testing → Tasks 1–6 TDD + Task 13; §8 verify/ship → Tasks 13–14. No gaps.
- **Type consistency:** `StrainTarget.Band.state(currentStrain:)`, `SleepPlanner.Recommendation`, `GoalProgress.Kind/Progress`, `GoalRow`, `PerformanceReport.Summary` used consistently across tasks.
- **Known adaptation points (executor verifies against real code, flagged inline):** StatTile/SegmentedPillControl init shapes, sleepDebtSeries tuple labels, AppModel repo property init style, simctl harness invocation, this morning's exact upload commands.
