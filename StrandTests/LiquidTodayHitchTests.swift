import XCTest
import CoreGraphics
import WhoopStore
import WhoopProtocol
import StrandAnalytics
@testable import Strand

/// Main-thread hitch round, Liquid Today. The view stopped re-running its body per scroll frame, moved its
/// history and heart-rate maths into detached tasks, and memoised the history scans its body used to redo
/// on every pass. None of that may change a number on screen, so each restructured piece is pinned here
/// against the inline code it replaced, over a spread of inputs. Pure: no strap, no store, no view.
final class LiquidTodayHitchTests: XCTestCase {

    // MARK: - Fixtures

    /// SplitMix64, so the synthetic inputs are the same on every run.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func dayKey(_ offset: Int, from start: String = "2026-05-01") -> String {
        let base = dayParser.date(from: start)!
        return dayParser.string(from: base.addingTimeInterval(TimeInterval(offset * 86_400)))
    }

    /// A history whose vitals land on DIFFERENT days, so each per-field carry resolves its own row and a
    /// miswired field in `scanDays` cannot pass by coincidence.
    private func history(count: Int, seed: UInt64) -> [DailyMetric] {
        var rng = SeededGenerator(state: seed)
        return (0..<count).map { i in
            DailyMetric(
                day: Self.dayKey(i),
                totalSleepMin: i % 7 == 6 ? nil : Double.random(in: 300...520, using: &rng),
                efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                restingHr: i % 4 == 1 ? nil : Int.random(in: 48...64, using: &rng),
                avgHrv: i % 3 == 0 ? nil : Double.random(in: 35...95, using: &rng),
                recovery: i % 2 == 0 ? Double.random(in: 10...99, using: &rng) : nil,
                strain: Double.random(in: 0...90, using: &rng),
                exerciseCount: nil,
                respRateBpm: i % 5 == 2 ? Double.random(in: 13...17, using: &rng) : nil,
                skinTempC: i % 6 == 3 ? Double.random(in: 33...35, using: &rng) : nil)
        }
    }

    // MARK: - TodaySegmentedAreaChart: the extent is hoisted out of the per-point call

    /// The body `point` had before the extent was hoisted, verbatim.
    private func legacyPoint(index: Int, values: [Double], size: CGSize) -> CGPoint {
        let lo = (values.min() ?? 0) - 2
        let hi = (values.max() ?? 1) + 2
        let span = max(hi - lo, 1)
        let n = max(values.count - 1, 1)
        return CGPoint(x: size.width * CGFloat(index) / CGFloat(n),
                       y: size.height * (1 - CGFloat((values[index] - lo) / span)))
    }

    func testHoistedExtentPlacesEveryPointExactlyWhereThePerPointExtentDid() {
        var rng = SeededGenerator(state: 2082)
        let series: [[Double]] = [
            [72],
            [60, 60],
            [60, 60.5, 60.25],                                           // span below the 1-unit floor
            [48, 71, 55, 90.5, 63],
            (0..<288).map { _ in Double.random(in: 42...178, using: &rng) },   // a full day of 5-min buckets
            (0..<90).map { _ in Double(Int.random(in: 55...140, using: &rng)) },
        ]
        let sizes = [CGSize(width: 335, height: 64), CGSize(width: 1, height: 1), CGSize(width: 0, height: 64),
                     CGSize(width: 1024.5, height: 70)]
        for values in series {
            for size in sizes {
                let extent = TodaySegmentedAreaChart.Extent(values)
                for i in values.indices {
                    let expected = legacyPoint(index: i, values: values, size: size)
                    XCTAssertEqual(TodaySegmentedAreaChart.point(index: i, values: values, size: size,
                                                                 extent: extent), expected)
                    XCTAssertEqual(TodaySegmentedAreaChart.point(index: i, values: values, size: size), expected)
                }
            }
        }
    }

    // MARK: - LiquidTodayLoad.scanDays: the history scans load() ran inline

    func testScanDaysMatchesTheInlineResolutionsItReplaced() {
        for (count, seed) in [(0, 1), (1, 2), (5, 3), (45, 4), (600, 5)] as [(Int, UInt64)] {
            let days = history(count: count, seed: seed)
            let lastKey = days.last?.day ?? Self.dayKey(0)
            let cases: [(isToday: Bool, todayKey: String, displayKey: String?, todayScored: Bool)] = [
                (true, lastKey, lastKey, days.last?.recovery != nil),
                (true, lastKey, nil, false),
                (true, Self.dayKey(count + 3), nil, false),           // no row for today yet
                (false, Self.dayKey(max(0, count - 9)), Self.dayKey(max(0, count - 9)), true),
            ]
            for c in cases {
                let scan = LiquidTodayLoad.scanDays(days, displayDayKey: c.displayKey, todayKey: c.todayKey,
                                                    isToday: c.isToday, todayScored: c.todayScored)
                let label = "count \(count), isToday \(c.isToday), todayKey \(c.todayKey)"
                XCTAssertEqual(scan.readiness, ReadinessEngine.evaluate(days: days, today: c.displayKey), label)
                XCTAssertEqual(scan.vitalsDay,
                               c.isToday ? Repository.lastVitalsDay(days: days, todayKey: c.todayKey) : nil, label)
                XCTAssertEqual(scan.respDay,
                               c.isToday ? Repository.lastRespDay(days: days, todayKey: c.todayKey) : nil, label)
                XCTAssertEqual(scan.hrvDay,
                               c.isToday ? Repository.lastHrvDay(days: days, todayKey: c.todayKey) : nil, label)
                XCTAssertEqual(scan.restingHrDay,
                               c.isToday ? Repository.lastRestingHrDay(days: days, todayKey: c.todayKey) : nil, label)
                XCTAssertEqual(scan.skinTempReadingDay,
                               c.isToday ? Repository.lastSkinTempReadingDay(days: days, todayKey: c.todayKey) : nil,
                               label)
                let calibration = c.isToday
                    ? RecoveryScorer.calibrationNights(nightlyHrv: days.map(\.avgHrv), dayKeys: days.map(\.day),
                                                       hasRecovery: c.todayScored)
                    : nil
                XCTAssertEqual(scan.calibrationNights, calibration, label)
            }
        }
    }

    /// Guards the fixture rather than the code: if the carries all landed on one row, the test above could
    /// not tell a swapped field from a correct one.
    func testFixtureResolvesTheCarriesToDifferentRows() {
        let days = history(count: 45, seed: 4)
        let scan = LiquidTodayLoad.scanDays(days, displayDayKey: nil, todayKey: Self.dayKey(46),
                                            isToday: true, todayScored: false)
        let carried = [scan.vitalsDay, scan.respDay, scan.hrvDay, scan.restingHrDay, scan.skinTempReadingDay]
            .compactMap { $0?.day }
        XCTAssertEqual(carried.count, 5, "every carry should resolve on this history")
        XCTAssertGreaterThanOrEqual(Set(carried).count, 3, "the carries should land on different rows")
    }

    // MARK: - LiquidTodayLoad.heartRateDerived: the zone + live-Effort maths load() ran inline

    private func heartRate(count: Int, seed: UInt64, start: Int = 1_780_000_000) -> [HRSample] {
        var rng = SeededGenerator(state: seed)
        var ts = start
        return (0..<count).map { i in
            ts += [1, 1, 1, 5, 60, 600][Int.random(in: 0...5, using: &rng)]   // dense, sparse and gapped
            let effort = i % 400 < 120 ? 70 : 0                                // repeated hard intervals
            return HRSample(ts: ts, bpm: Int.random(in: 55...95, using: &rng) + effort)
        }
    }

    func testHeartRateDerivedMatchesTheInlineMathsItReplaced() {
        let zoneSets = [HRZones.zones(maxHR: 190), HRZones.zones(maxHR: 176, customLowerBounds: [95, 115, 135, 150, 165])]
        let inputs: [LiquidTodayLoad.LiveStrainInputs?] = [
            nil,                                                             // a navigated past day
            .init(maxHR: 190, restingHR: 52, method: .edwards, sex: "male"),
            .init(maxHR: nil, restingHR: StrainScorer.defaultRestingHR, method: .banister, sex: "female"),
        ]
        var sawLiveStrain = false
        for (count, seed) in [(0, 11), (40, 12), (StrainScorer.minReadings + 50, 13), (20_000, 14)] as [(Int, UInt64)] {
            let hr = heartRate(count: count, seed: seed)
            for zoneSet in zoneSets {
                for input in inputs {
                    let derived = LiquidTodayLoad.heartRateDerived(hr, zoneSet: zoneSet, liveStrain: input)
                    let zone: Double? = hr.isEmpty ? nil
                        : HRZones.timeInZone(hr, zoneSet: zoneSet).seconds.dropFirst().reduce(0, +) / 60
                    let live: Double? = input.flatMap {
                        StrainScorer.strain(hr, maxHR: $0.maxHR, restingHR: $0.restingHR, method: $0.method,
                                            sex: $0.sex)
                    }
                    XCTAssertEqual(derived, LiquidTodayLoad.HeartRateDerived(zoneMinutes2to5: zone, liveStrain: live),
                                   "count \(count), live inputs \(input == nil ? "none" : "set")")
                    if live != nil { sawLiveStrain = true }
                }
            }
        }
        XCTAssertTrue(sawLiveStrain, "the fixture must reach StrainScorer.minReadings, or the live branch is untested")
    }

    // MARK: - Body-time memos

    func testMemoRecomputesOnlyWhenTheKeyChanges() {
        var memo = LiquidTodayMemo<String, Int>()
        var computed = 0
        func read(_ key: String) -> Int { memo.value(for: key) { computed += 1; return key.count } }
        XCTAssertEqual(read("charge,effort"), 13)
        XCTAssertEqual(read("charge,effort"), 13)
        XCTAssertEqual(computed, 1)
        XCTAssertEqual(read("rest"), 4)
        XCTAssertEqual(computed, 2)
        XCTAssertEqual(read("charge,effort"), 13, "one entry: going back to an old key recomputes")
        XCTAssertEqual(computed, 3)
    }

    func testDaysKeyedMemoFollowsTheHistoryContents() {
        var memo = LiquidTodayMemo<LiquidTodayDaysKey<String?>, ReadinessEngine.Readiness>()
        var computed = 0
        func read(_ days: [DailyMetric], _ today: String?) -> ReadinessEngine.Readiness {
            memo.value(for: LiquidTodayDaysKey(days: days, extra: today)) {
                computed += 1
                return ReadinessEngine.evaluate(days: days, today: today)
            }
        }
        let days = history(count: 60, seed: 7)
        let today = days.last?.day
        XCTAssertEqual(read(days, today), ReadinessEngine.evaluate(days: days, today: today))
        XCTAssertEqual(read(days, today), ReadinessEngine.evaluate(days: days, today: today))
        XCTAssertEqual(computed, 1, "the same history must not be re-evaluated")

        // An equal history in a different buffer is still the same input.
        let copy = days.map { $0 }
        XCTAssertEqual(read(copy, today), ReadinessEngine.evaluate(days: days, today: today))
        XCTAssertEqual(computed, 1)

        // A changed newest row (the usual shape of a sync) and a changed day both recompute.
        var changed = days
        changed[changed.count - 1] = history(count: 60, seed: 8)[59]
        XCTAssertEqual(read(changed, today), ReadinessEngine.evaluate(days: changed, today: today))
        XCTAssertEqual(computed, 2)
        XCTAssertEqual(read(changed, nil), ReadinessEngine.evaluate(days: changed, today: nil))
        XCTAssertEqual(computed, 3)
    }

    func testLoadGenerationMarksEveryEarlierPassStale() {
        let scratch = LiquidTodayScratch()
        let first = scratch.beginLoad()
        XCTAssertEqual(scratch.loadGeneration, first)
        let second = scratch.beginLoad()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(scratch.loadGeneration, second, "only the newest pass may write")
    }

    // MARK: - Key-metric tile routes: the catalog index

    func testCatalogIndexFindsTheSameDescriptorAsTheLinearSearch() {
        let keys = Set(MetricCatalog.all.map(\.key))
            .union([HeroRingMetric.charge, HeroRingMetric.effort, HeroRingMetric.rest, "hrv", "rhr", "spo2",
                    "spo2_candidate", "resp_rate", "weight", "energy_kcal", "skin_temp", "steps", "steps_est",
                    "not_a_metric", ""])
        for key in keys {
            XCTAssertEqual(LiquidTodayView.catalogMetricByKey[key], MetricCatalog.all.first(where: { $0.key == key }),
                           key)
        }
    }
}
