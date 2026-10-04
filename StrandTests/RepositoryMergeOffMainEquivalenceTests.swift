import XCTest
import WhoopProtocol
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Pins the main-thread hitch round's restructure of `Repository`'s union reads: each merge that used to
/// run inline on the main actor after its store reads now runs in a detached task through a pure static
/// helper. Every `old…` function below is a VERBATIM copy of the replaced inline loop, with only the
/// per-id `await store.…` read swapped for a pre-read list, and is the oracle the helper must match on
/// inputs with duplicates across ids, duplicates inside one id, identical timestamps and unsorted lists.
final class RepositoryMergeOffMainEquivalenceTests: XCTestCase {

    // MARK: - Verbatim copies of the replaced inline loops

    private static func oldUnionDaily(_ lists: [[DailyMetric]]) -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for list in lists {
            for m in list {
                byDay[m.day] = byDay[m.day].map { Repository.coalesceDay($0, m) } ?? m
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    private static func oldUnionMetricSeries(_ lists: [[MetricPoint]]) -> [MetricPoint] {
        var byDay: [String: MetricPoint] = [:]
        for list in lists {
            for p in list where byDay[p.day] == nil {
                byDay[p.day] = p
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    private static func oldHRSamples(_ lists: [[HRSample]]) -> [HRSample] {
        var byTs: [Int: HRSample] = [:]
        for list in lists {
            for s in list where byTs[s.ts] == nil {
                byTs[s.ts] = s
            }
        }
        return byTs.values.sorted { $0.ts < $1.ts }
    }

    private static func oldHRBuckets(_ lists: [[HRBucket]]) -> [HRBucket] {
        var byStart: [Int: HRBucket] = [:]
        for list in lists {
            for b in list where byStart[b.ts] == nil {
                byStart[b.ts] = b
            }
        }
        return byStart.values.sorted { $0.ts < $1.ts }
    }

    private static func oldResolvedRows(metricRows: [MetricPoint], dailyRows: [DailyMetric]?,
                                        key: String) -> [(day: String, value: Double)] {
        var byDay = Dictionary(metricRows.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        if let dailyRows {
            for row in dailyRows where byDay[row.day] == nil {
                if let value = Repository.dailyColumn(key: key, day: row) { byDay[row.day] = value }
            }
        }
        return byDay.keys.sorted().compactMap { day in byDay[day].map { (day, $0) } }
    }

    private static func oldResolvedSeries(
        _ perCandidate: [(candidate: MetricSourceCandidate, rows: [(day: String, value: Double)])]
    ) -> [ResolvedMetricPoint] {
        var byDay: [String: ResolvedMetricPoint] = [:]
        for (candidate, rows) in perCandidate {
            for row in rows where byDay[row.day] == nil {
                byDay[row.day] = ResolvedMetricPoint(day: row.day, value: row.value,
                                                     source: candidate.source, sourceKey: candidate.key)
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    private static func oldOneSkinTempScale(
        key: String,
        _ series: [(day: String, value: Double)]
    ) -> [(day: String, value: Double)] {
        guard key == "skin_temp",
              let keep = SkinTempDisplay.dominantKind(valuesAscendingByDay: series.map(\.value))
        else { return series }
        return series.filter { SkinTempDisplay.kind(of: $0.value) == keep }
    }

    private static func oldExploreSeries(key: String, days: [DailyMetric], computedReversed: [[MetricPoint]],
                                         importedReversed: [[MetricPoint]]) -> [(day: String, value: Double)] {
        var byDay: [String: Double] = [:]
        for d in days where byDay[d.day] == nil {
            if let v = Repository.dailyColumn(key: key, day: d) { byDay[d.day] = v }
        }
        for layer in computedReversed {
            for p in layer { byDay[p.day] = p.value }
        }
        for layer in importedReversed {
            for p in layer { byDay[p.day] = p.value }
        }
        return oldOneSkinTempScale(key: key, byDay.sorted { $0.key < $1.key }.map { (day: $0.key, value: $0.value) })
    }

    private static func oldDedupWorkoutsByNaturalKey(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        var seen = Set<String>()
        var out: [WorkoutRow] = []
        for r in rows {
            let key = "\(r.startTs)-\(r.endTs)-\(r.sport)-\(r.source)"
            if seen.insert(key).inserted { out.append(r) }
        }
        return out
    }

    private static func oldWorkoutCollapse(_ input: [WorkoutRow], dismissed: [String],
                                           trace: Bool) -> (visible: [WorkoutRow], trace: [String]) {
        var rows = input
        var emitted: [String] = []
        rows = oldDedupWorkoutsByNaturalKey(rows)
        let spans = WorkoutSource.parseDismissedSpans(dismissed)
        let filtered = rows.filter { !WorkoutSource.isDismissed($0, spans: spans) }
        let deduped: [WorkoutRow]
        if trace {
            let (kept, trace) = WorkoutSource.dedupCrossSourceTrace(filtered)
            for line in trace { emitted.append(line) }
            deduped = kept
        } else {
            deduped = WorkoutSource.dedupCrossSource(filtered)
        }
        let visible = deduped.sorted { $0.startTs > $1.startTs }
        return (visible, emitted)
    }

    /// The old `dedupBlocks`, verbatim, so the sleep oracles below do not lean on the rewritten one.
    private static func oldDedupBlocks(_ blocks: [CachedSleepSession]) -> [CachedSleepSession] {
        var seen = Set<[Int]>()
        var out: [CachedSleepSession] = []
        for b in blocks {
            let key = [b.startTs, b.endTs]
            guard seen.insert(key).inserted else { continue }
            let overlapsOtherSource = out.contains { kept in
                guard let source = b.deviceId, let keptSource = kept.deviceId,
                      source != keptSource else { return false }
                let start = max(b.effectiveStartTs, kept.effectiveStartTs)
                let end = min(b.endTs, kept.endTs)
                let bDuration = b.endTs - b.effectiveStartTs
                let keptDuration = kept.endTs - kept.effectiveStartTs
                let overlap = end - start
                return bDuration > 0 && keptDuration > 0 &&
                    overlap > bDuration / 2 && overlap > keptDuration / 2
            }
            if !overlapsOtherSource { out.append(b) }
        }
        return out
    }

    private static func oldAllSleepSessions(importedRaw: [CachedSleepSession], computedRaw: [CachedSleepSession],
                                            cal: Calendar) -> [CachedSleepSession] {
        let imported = oldDedupBlocks(importedRaw)
        let computed = oldDedupBlocks(computedRaw)
        func endDay(_ s: CachedSleepSession) -> Date {
            cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
        }
        var importedDays = Set<Date>()
        for s in imported { importedDays.insert(endDay(s)) }
        let computedKept = computed.filter { !importedDays.contains(endDay($0)) }
        return (imported + computedKept).sorted { $0.effectiveStartTs < $1.effectiveStartTs }
    }

    private static func oldHabitualMidsleep(importedRaw: [CachedSleepSession], computedRaw: [CachedSleepSession],
                                            offsetSec: Int) -> Int? {
        let imported = oldDedupBlocks(importedRaw)
        let computed = oldDedupBlocks(computedRaw)
        let blocks = (imported + computed).compactMap { s -> SleepStageTotals.HistoryBlock? in
            let start = s.effectiveStartTs, end = s.endTs
            guard end > start else { return nil }
            let mid = start + (end - start) / 2
            let dayKey = AnalyticsEngine.dayString(mid, offsetSec: offsetSec)
            return SleepStageTotals.HistoryBlock(start: start, end: end, dayKey: dayKey)
        }
        return SleepStageTotals.habitualMidsleepSec(blocks, offsetSec: offsetSec)
    }

    // MARK: - Generators

    private static let dayKeys = (1...12).map { String(format: "2026-03-%02d", $0) }

    private static func maybe<T>(_ rng: inout SplitMix64, _ make: (inout SplitMix64) -> T) -> T? {
        Bool.random(using: &rng) ? make(&rng) : nil
    }

    private static func randomDaily(_ rng: inout SplitMix64) -> DailyMetric {
        DailyMetric(
            day: dayKeys.randomElement(using: &rng)!,
            totalSleepMin: maybe(&rng) { Double(Int.random(in: 0...600, using: &$0)) },
            efficiency: maybe(&rng) { Double.random(in: 0...1, using: &$0) },
            deepMin: maybe(&rng) { Double(Int.random(in: 0...200, using: &$0)) },
            remMin: maybe(&rng) { Double(Int.random(in: 0...200, using: &$0)) },
            lightMin: maybe(&rng) { Double(Int.random(in: 0...300, using: &$0)) },
            disturbances: maybe(&rng) { Int.random(in: 0...30, using: &$0) },
            restingHr: maybe(&rng) { Int.random(in: 40...80, using: &$0) },
            avgHrv: maybe(&rng) { Double.random(in: 10...120, using: &$0) },
            recovery: maybe(&rng) { Double(Int.random(in: 0...100, using: &$0)) },
            strain: maybe(&rng) { Double.random(in: 0...21, using: &$0) },
            exerciseCount: maybe(&rng) { Int.random(in: 0...3, using: &$0) },
            spo2Pct: maybe(&rng) { Double.random(in: 90...100, using: &$0) },
            skinTempDevC: maybe(&rng) { [Double.random(in: -1...1, using: &$0), 34.2].randomElement(using: &$0)! },
            respRateBpm: maybe(&rng) { Double.random(in: 10...20, using: &$0) },
            steps: maybe(&rng) { Int.random(in: 0...20_000, using: &$0) },
            activeKcalEst: maybe(&rng) { Double.random(in: 0...900, using: &$0) },
            spo2Red: maybe(&rng) { Int.random(in: 0...9_000, using: &$0) },
            spo2Ir: maybe(&rng) { Int.random(in: 0...9_000, using: &$0) },
            avgSdnn: maybe(&rng) { Double.random(in: 10...150, using: &$0) },
            skinTempC: maybe(&rng) { Double.random(in: 30...36, using: &$0) },
            sleepHrOnly: maybe(&rng) { Bool.random(using: &$0) })
    }

    private static func randomPoints(_ rng: inout SplitMix64, key: String = "k") -> [MetricPoint] {
        (0..<Int.random(in: 0...14, using: &rng)).map { _ in
            MetricPoint(day: dayKeys.randomElement(using: &rng)!, key: key,
                        value: [Double.random(in: -2...120, using: &rng), 34.5, 0.3].randomElement(using: &rng)!)
        }
    }

    private static func flat(_ rows: [(day: String, value: Double)]) -> [String] {
        rows.map { "\($0.day)|\($0.value.bitPattern)" }
    }

    // MARK: - Pure helper equivalence

    func testCoalesceDailyByDayMatchesTheInlineUnion() {
        var rng = SplitMix64(seed: 1)
        for i in 0..<1_500 {
            let lists = (0..<Int.random(in: 1...3, using: &rng)).map { _ in
                (0..<Int.random(in: 0...10, using: &rng)).map { _ in Self.randomDaily(&rng) }
            }
            XCTAssertEqual(Repository.coalesceDailyByDay(lists), Self.oldUnionDaily(lists), "case \(i)")
        }
    }

    func testFirstPointPerDayMatchesTheInlineUnion() {
        var rng = SplitMix64(seed: 2)
        for i in 0..<1_500 {
            let lists = (0..<Int.random(in: 1...3, using: &rng)).map { _ in Self.randomPoints(&rng) }
            XCTAssertEqual(Repository.firstPointPerDay(lists), Self.oldUnionMetricSeries(lists), "case \(i)")
        }
    }

    func testMergeHRByTsMatchesTheInlineUnion() {
        var rng = SplitMix64(seed: 3)
        for i in 0..<1_500 {
            let lists = (0..<Int.random(in: 1...4, using: &rng)).map { _ in
                (0..<Int.random(in: 0...40, using: &rng)).map { _ in
                    HRSample(ts: 1_000 + Int.random(in: 0...30, using: &rng), bpm: Int.random(in: 40...190, using: &rng))
                }
            }
            XCTAssertEqual(Repository.mergeHRByTs(lists), Self.oldHRSamples(lists), "case \(i)")
        }
        // A day-sized pair with a shared stretch, the shape a two-id phone reads.
        let a = (0..<20_000).map { HRSample(ts: 1_700_000_000 + $0, bpm: 60 + $0 % 50) }
        let b = (10_000..<40_000).map { HRSample(ts: 1_700_000_000 + $0, bpm: 70 + $0 % 40) }
        XCTAssertEqual(Repository.mergeHRByTs([a, b]), Self.oldHRSamples([a, b]))
        XCTAssertEqual(Repository.mergeHRByTs([b, a]), Self.oldHRSamples([b, a]))
    }

    func testMergeHRBucketsByStartMatchesTheInlineUnion() {
        var rng = SplitMix64(seed: 4)
        for i in 0..<1_500 {
            let lists = (0..<Int.random(in: 1...4, using: &rng)).map { _ in
                (0..<Int.random(in: 0...30, using: &rng)).map { _ -> HRBucket in
                    let bpm = Double(Int.random(in: 40...190, using: &rng))
                    return HRBucket(ts: 300 * Int.random(in: 0...20, using: &rng), bpm: bpm,
                                    minBpm: bpm - 5, maxBpm: bpm + 5,
                                    conf: [1.0, 0.4].randomElement(using: &rng)!)
                }
            }
            XCTAssertEqual(Repository.mergeHRBucketsByStart(lists), Self.oldHRBuckets(lists), "case \(i)")
        }
    }

    func testResolvedRowsAndCandidateMergeMatchTheInlineVersions() {
        var rng = SplitMix64(seed: 5)
        let keys = ["recovery", "hrv", "rhr", "sleep_performance", "steps", "skin_temp", "sleep_total_min",
                    "avg_hr", "unknown"]
        for i in 0..<1_000 {
            let key = keys.randomElement(using: &rng)!
            let metricRows = Self.randomPoints(&rng, key: key)
            let dailyRows = (0..<Int.random(in: 0...8, using: &rng)).map { _ in Self.randomDaily(&rng) }
            XCTAssertEqual(Self.flat(Repository.resolvedRows(metricRows: metricRows, dailyRows: dailyRows, key: key)),
                           Self.flat(Self.oldResolvedRows(metricRows: metricRows, dailyRows: dailyRows, key: key)),
                           "rows case \(i)")
            // A failed daily read used to skip the fill; the new read passes an empty list instead.
            XCTAssertEqual(Self.flat(Repository.resolvedRows(metricRows: metricRows, dailyRows: [], key: key)),
                           Self.flat(Self.oldResolvedRows(metricRows: metricRows, dailyRows: nil, key: key)),
                           "failed daily read case \(i)")

            let perCandidate = (0..<Int.random(in: 0...4, using: &rng)).map { n in
                (candidate: MetricSourceCandidate(source: "src\(n % 3)", key: key),
                 rows: Self.oldResolvedRows(metricRows: Self.randomPoints(&rng, key: key),
                                            dailyRows: [Self.randomDaily(&rng)], key: key))
            }
            XCTAssertEqual(Repository.mergeResolvedCandidates(perCandidate), Self.oldResolvedSeries(perCandidate),
                           "candidates case \(i)")
        }
    }

    func testExploreLayeredMatchesTheInlineFold() {
        var rng = SplitMix64(seed: 6)
        let keys = ["skin_temp", "recovery", "sleep_performance", "steps", "avg_hr", "hrv"]
        for i in 0..<1_500 {
            let key = keys.randomElement(using: &rng)!
            let days = (0..<Int.random(in: 0...10, using: &rng)).map { _ in Self.randomDaily(&rng) }
            let computed = (0..<Int.random(in: 1...2, using: &rng)).map { _ in Self.randomPoints(&rng, key: key) }
            let imported = (0..<Int.random(in: 1...2, using: &rng)).map { _ in Self.randomPoints(&rng, key: key) }
            XCTAssertEqual(
                Self.flat(Repository.exploreLayered(key: key, mergedDays: days, overwriteLayers: computed + imported)),
                Self.flat(Self.oldExploreSeries(key: key, days: days, computedReversed: computed,
                                                importedReversed: imported)),
                "case \(i)")
        }
    }

    func testCollapseWorkoutRowsMatchesTheInlinePipeline() {
        var rng = SplitMix64(seed: 7)
        let sources = ["my-whoop", "whoop-x", "my-whoop-noop", "whoop-x-noop", "apple-health", "apple_health",
                       "manual", "lifting", "activity-file"]
        let sports = ["Running", "running", "detected", "TraditionalStrengthTraining",
                      "Traditional Strength Training", "Cycling"]
        let dismissedPool = ["1000:4600", "8200:9000", "garbage", "5:1", "20000:30000"]
        for i in 0..<1_000 {
            var rows: [WorkoutRow] = []
            for _ in 0..<Int.random(in: 0...24, using: &rng) {
                if Int.random(in: 0..<6, using: &rng) == 0, let prev = rows.randomElement(using: &rng) {
                    rows.append(prev)   // the same session read under a second namespace
                    continue
                }
                let start = 1_000 + 600 * Int.random(in: 0...30, using: &rng)
                rows.append(WorkoutRow(
                    startTs: start, endTs: start + [0, 600, 1_800, 3_600].randomElement(using: &rng)!,
                    sport: sports.randomElement(using: &rng)!, source: sources.randomElement(using: &rng)!,
                    durationS: Self.maybe(&rng) { Double(Int.random(in: 0...3_600, using: &$0)) },
                    energyKcal: Self.maybe(&rng) { Double(Int.random(in: 0...800, using: &$0)) },
                    avgHr: Self.maybe(&rng) { Int.random(in: 80...170, using: &$0) },
                    maxHr: Self.maybe(&rng) { Int.random(in: 120...200, using: &$0) },
                    strain: Self.maybe(&rng) { Double.random(in: 0...21, using: &$0) },
                    distanceM: Self.maybe(&rng) { Double(Int.random(in: 0...20_000, using: &$0)) },
                    zonesJSON: Self.maybe(&rng) { _ in "[1,2,3,4,5]" }, notes: Self.maybe(&rng) { _ in "n" },
                    steps: Self.maybe(&rng) { Int.random(in: 0...9_000, using: &$0) }))
            }
            let dismissed = dismissedPool.filter { _ in Bool.random(using: &rng) }
            for trace in [false, true] {
                let new = Repository.collapseWorkoutRows(rows, dismissedSpans: dismissed, trace: trace)
                let old = Self.oldWorkoutCollapse(rows, dismissed: dismissed, trace: trace)
                XCTAssertEqual(new.visible, old.visible, "case \(i) trace=\(trace)")
                XCTAssertEqual(new.trace, old.trace, "case \(i) trace=\(trace)")
            }
        }
    }

    func testSleepFoldsMatchTheInlineVersions() {
        var rng = SplitMix64(seed: 8)
        let sources: [String?] = ["whoop-new", "my-whoop", "whoop-new-noop", "my-whoop-noop", nil]
        let t0 = 1_760_000_000
        func blocks(_ rng: inout SplitMix64) -> [CachedSleepSession] {
            (0..<Int.random(in: 0...30, using: &rng)).map { _ in
                let start = t0 + 3_600 * Int.random(in: 0...200, using: &rng) + Int.random(in: -900...900, using: &rng)
                let end = start + [0, 1_800, 5_400, 25_200, 32_400].randomElement(using: &rng)!
                return CachedSleepSession(startTs: start, endTs: end, efficiency: nil, restingHr: nil, avgHrv: nil,
                                          stagesJSON: nil,
                                          startTsAdjusted: Int.random(in: 0..<5, using: &rng) == 0 ? start + 600 : nil,
                                          deviceId: sources.randomElement(using: &rng)!)
            }
        }
        let cal = Calendar.current
        for i in 0..<800 {
            let imported = blocks(&rng)
            let computed = blocks(&rng)
            XCTAssertEqual(Repository.mergeAllSleepBlocks(imported: imported, computed: computed, calendar: cal),
                           Self.oldAllSleepSessions(importedRaw: imported, computedRaw: computed, cal: cal),
                           "all sleep case \(i)")
            for offset in [0, 3_600, -18_000, 19_800] {
                XCTAssertEqual(Repository.habitualMidsleep(imported: imported, computed: computed, offsetSec: offset),
                               Self.oldHabitualMidsleep(importedRaw: imported, computedRaw: computed, offsetSec: offset),
                               "midsleep case \(i) offset \(offset)")
            }
        }
    }

    // MARK: - Facade wiring over a real two-id store

    /// The facades must hand the helpers the per-id lists in the same order the inline loops read them:
    /// active strap first, canonical after. A two-id store with overlapping timestamps and days catches a
    /// reversed or dropped list.
    @MainActor
    func testTwoIdFacadesMatchTheInlineMergeOverTheSameReads() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        repo.adoptActiveDeviceId("whoop-new")
        let ids = ["whoop-new", "my-whoop"]
        let base = Int(Date().timeIntervalSince1970) - 6 * 3_600

        let activeHR = (0..<900).map { HRSample(ts: base + $0, bpm: 60 + $0 % 40) }
        let canonicalHR = (450..<1_500).map { HRSample(ts: base + $0, bpm: 100 + $0 % 30) }
        _ = try await store.insert(Streams(hr: activeHR), deviceId: "whoop-new")
        _ = try await store.insert(Streams(hr: canonicalHR), deviceId: "my-whoop")

        var hrLists: [[HRSample]] = []
        for id in ids { hrLists.append(try await store.hrSamples(deviceId: id, from: base, to: base + 2_000, limit: 8_000)) }
        let hr = await repo.hrSamples(from: base, to: base + 2_000)
        XCTAssertEqual(hr, Self.oldHRSamples(hrLists))
        XCTAssertEqual(hr.first(where: { $0.ts == base + 500 })?.bpm, 60 + 500 % 40, "active strap wins a shared ts")

        var bucketLists: [[HRBucket]] = []
        for id in ids {
            bucketLists.append(try await store.hrBuckets(deviceId: id, from: base, to: base + 2_000, bucketSeconds: 300))
        }
        let buckets = await repo.hrBuckets(from: base, to: base + 2_000)
        XCTAssertEqual(buckets, Self.oldHRBuckets(bucketLists))

        let activeDays = [DailyMetric(day: "2026-03-01", totalSleepMin: nil, efficiency: nil, deepMin: nil,
                                      remMin: nil, lightMin: nil, disturbances: nil, restingHr: 52, avgHrv: nil,
                                      recovery: 70, strain: nil, exerciseCount: nil, steps: 4_000)]
        let canonicalDays = [DailyMetric(day: "2026-03-01", totalSleepMin: 420, efficiency: 0.9, deepMin: 80,
                                         remMin: 90, lightMin: 250, disturbances: 3, restingHr: 58, avgHrv: 61,
                                         recovery: 40, strain: 12, exerciseCount: 1),
                             DailyMetric(day: "2026-03-02", totalSleepMin: 400, efficiency: nil, deepMin: nil,
                                         remMin: nil, lightMin: nil, disturbances: nil, restingHr: 55, avgHrv: 50,
                                         recovery: 66, strain: nil, exerciseCount: nil)]
        _ = try await store.upsertDailyMetrics(activeDays, deviceId: "whoop-new")
        _ = try await store.upsertDailyMetrics(canonicalDays, deviceId: "my-whoop")
        var dailyLists: [[DailyMetric]] = []
        for id in ids {
            dailyLists.append(try await store.dailyMetrics(deviceId: id, from: "2026-01-01", to: "2026-12-31"))
        }
        let daily = await repo.dailyMetrics(fromDay: "2026-01-01", toDay: "2026-12-31")
        XCTAssertEqual(daily, Self.oldUnionDaily(dailyLists))
        XCTAssertEqual(daily.first?.recovery, 70, "active strap claims the column")
        XCTAssertEqual(daily.first?.avgHrv, 61, "canonical fills the gap")

        func workout(_ start: Int, _ sport: String, _ source: String) -> WorkoutRow {
            WorkoutRow(startTs: start, endTs: start + 1_800, sport: sport, source: source, durationS: 1_800,
                       energyKcal: 200, avgHr: 130, maxHr: 160, strain: 9, distanceM: nil, zonesJSON: nil,
                       notes: nil, steps: nil)
        }
        // Hours before any HR above, so the display reconcile has no trace to apply.
        let wBase = base - 40_000
        let shared = workout(wBase, "Running", "manual")
        _ = try await store.upsertWorkouts([shared, workout(wBase + 4_000, "Cycling", "manual")], deviceId: "whoop-new")
        _ = try await store.upsertWorkouts([shared], deviceId: "my-whoop")
        _ = try await store.upsertWorkouts([workout(wBase + 60, "running", "apple-health")],
                                           deviceId: WorkoutSource.appleHealthSource)
        let now = Int(Date().timeIntervalSince1970)
        var union: [WorkoutRow] = []
        for id in Repository.workoutNamespaces(rawIds: ids) {
            union += try await store.workouts(deviceId: id, from: now - 4_000 * 86_400, to: now + 86_400, limit: 5_000)
        }
        let dismissed = UserDefaults.standard.stringArray(forKey: WorkoutSource.dismissedDefaultsKey) ?? []
        let expected = Self.oldWorkoutCollapse(union, dismissed: dismissed, trace: false).visible
        let rows = await repo.workoutRows()
        // No dense HR under the workout windows, so the display reconcile passes every row through.
        XCTAssertEqual(rows, expected)
        XCTAssertEqual(rows.count, 2, "the shared session collapses to one row and the Apple twin folds into it")
    }
}
