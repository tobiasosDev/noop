import XCTest
import WhoopProtocol
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Pins the main-thread contract of `IntelligenceEngine.analyzeRecent` after its CPU-heavy phases moved off
/// the main actor (main-thread hitch round: the launch history repair spent ~2 s of CPU per pass and every
/// post-offload pass up to ~350 ms, much of the post-loop half of it on the main thread).
///
/// Three things must hold however the work is scheduled:
/// - every diagnostic line still reaches `diagnosticSink` ON THE MAIN THREAD (the sink is `LiveState`);
/// - the day-cycle trace still lands where it always did, after the day loop and before the per-night lines;
/// - a second pass served from the engine's in-memory caches persists exactly what the first pass did.
///
/// Set `NOOP_OFFMAIN_DUMP` (as `TEST_RUNNER_NOOP_OFFMAIN_DUMP` through xcodebuild) to a directory to write a
/// normalized transcript of every pass: lines plus stored rows, with pass timings and `now` masked. Two
/// builds run on the same calendar day can then be diffed byte for byte.
@MainActor
final class IntelligenceOffMainTests: XCTestCase {
    private let source = "my-whoop"
    private let traceMasterKey = "testcentre.active.master"

    private func withPreferences(traces: Bool, _ body: () async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let keys = [
            "profile.dateOfBirth", "profile.age", "profile.sex", "profile.weightKg",
            "profile.heightCm", "profile.waistCm", "profile.hrMaxOverride", "profile.stepTicksPerStep",
            "profile.stepsCalibrationCoefficient", "profile.stepsCalibrationSampleDays",
            "profile.stepsCalibrationConfidence", "profile.stepsCalibrationManual",
            "profile.stepsManualCoefficient", "profile.stepsHasBankedMotion",
            IntelligenceEngine.effortRescoreFlagKey, IntelligenceEngine.sleepWearRescoreFlagKey,
            "noop.analyzeWatermark", "analyzeRecent.stepsMotionCache.v1",
            "noop.hrvBaselineEpoch", "noop.recoveryBaselineEpoch", UnitPrefs.hrvWindowKey,
            RescoreBackgroundScheduler.owedKey, RescoreBackgroundScheduler.owedTokenKey,
            RescoreBackgroundScheduler.lastPassSecondsKey, DayCycleMode.storageKey,
            PuffinExperiment.experimentalSleepV2Key, PuffinExperiment.motionAwareWakeKey,
            traceMasterKey,
        ]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.set(DayCycleMode.sleepOnset.rawValue, forKey: DayCycleMode.storageKey)
        defaults.set(true, forKey: PuffinExperiment.experimentalSleepV2Key)
        defaults.set(false, forKey: PuffinExperiment.motionAwareWakeKey)
        if traces { defaults.set(true, forKey: traceMasterKey) }
        try await body()
    }

    /// Three completed nights with daytime steps and an afternoon workout, all before today's local
    /// midnight so the result does not depend on the hour the test runs. Plus the side inputs the
    /// post-loop phases read: an edited night, a manual workout overlapping a detected bout, Apple
    /// Health dailies for the watch fold and an imported baseline history.
    private func seed(_ store: WhoopStore) async throws {
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(id: source, brand: "WHOOP", model: "4.0",
            sourceKind: .liveBLE, capabilities: [.hr, .hrv], status: .active, addedAt: 1, lastSeenAt: 1))
        let tz = TimeZone.current.secondsFromGMT()
        let today = IntelligenceEngine.midnightLocal(Int(Date().timeIntervalSince1970), offsetSec: tz)
        let start = today - 4 * 86_400 + 16 * 3_600
        let end = today - 2 * 3_600
        var hr: [HRSample] = [], rr: [RRInterval] = [], grav: [GravitySample] = [], steps: [StepSample] = []
        var counter = 1_000
        for ts in start..<end {
            let local = ((ts + tz) % 86_400 + 86_400) % 86_400
            let asleep = local >= 23 * 3_600 || local < 7 * 3_600
            let workout = local >= 16 * 3_600 && local < 16 * 3_600 + 40 * 60
            let phase = Double(ts - start)
            let bpm = asleep ? 56 + Int(sin(phase / 900) * 4)
                : workout ? 145 + Int(sin(phase / 120) * 10)
                : 72 + Int(sin(phase / 500) * 9)
            hr.append(HRSample(ts: ts, bpm: bpm))
            if asleep { rr.append(RRInterval(ts: ts, rrMs: 1_000 + (ts.isMultiple(of: 2) ? 22 : -22))) }
            if ts.isMultiple(of: 5) {
                let wobble = asleep ? 0.0 : sin(phase / 7) * 0.4
                grav.append(GravitySample(ts: ts, x: wobble, y: 0, z: 1, unit: "g"))
            }
            if !asleep, ts.isMultiple(of: 60) {
                counter += workout ? 140 : 18
                steps.append(StepSample(ts: ts, counter: counter))
            }
        }
        _ = try await store.insert(Streams(hr: hr, rr: rr, gravity: grav, steps: steps), deviceId: source)

        // A hand-corrected bedtime on the middle night.
        let editedNightEnd = today - 2 * 86_400 + 7 * 3_600
        let edited = CachedSleepSession(startTs: editedNightEnd - 8 * 3_600, endTs: editedNightEnd - 600,
            efficiency: 0.9, restingHr: 54, avgHrv: nil, stagesJSON: "[]", userEdited: true,
            startTsAdjusted: editedNightEnd - 8 * 3_600 + 900)
        // A stale copy of the last night banked under a shifted timebase, for the #899 heal to drop.
        let lastNightEnd = today - 86_400 + 7 * 3_600
        let stale = CachedSleepSession(startTs: lastNightEnd - 8 * 3_600 - 1_200, endTs: lastNightEnd - 1_200,
            efficiency: 0.95, restingHr: 55, avgHrv: 40, stagesJSON: "[]")
        _ = try await store.upsertSleepSessions([edited, stale], deviceId: source + "-noop")

        // A sparse manual workout the detector's bout overlaps (backfill + manual re-score paths).
        let workoutStart = today - 86_400 + 16 * 3_600
        let manual = WorkoutRow(startTs: workoutStart + 60, endTs: workoutStart + 35 * 60,
            sport: "Running", source: "manual", durationS: 34 * 60, energyKcal: nil, avgHr: nil,
            maxHr: nil, strain: nil, distanceM: 5_000, zonesJSON: nil, notes: nil, steps: nil)
        _ = try await store.upsertWorkouts([manual], deviceId: source)

        // Apple Health dailies (watch fold) and an older imported history (baseline seed).
        let apple = (5..<17).map { i in
            DailyMetric(day: AnalyticsEngine.dayString(today - i * 86_400, offsetSec: tz),
                totalSleepMin: 420 + Double(i), efficiency: 0.9, deepMin: nil, remMin: nil, lightMin: nil,
                disturbances: nil, restingHr: 54 + i % 3, avgHrv: 40 + Double(i % 5), recovery: nil,
                strain: nil, exerciseCount: nil)
        }
        _ = try await store.upsertDailyMetrics(apple, deviceId: Repository.appleHealthSource)
        let imported = (20..<30).map { i in
            DailyMetric(day: AnalyticsEngine.dayString(today - i * 86_400, offsetSec: tz),
                totalSleepMin: 430, efficiency: 0.88, deepMin: 80, remMin: 90, lightMin: 260,
                disturbances: 2, restingHr: 53 + i % 4, avgHrv: 60 + Double(i % 7), recovery: 60,
                strain: 9, exerciseCount: 0)
        }
        _ = try await store.upsertDailyMetrics(imported, deviceId: source)
    }

    private struct Pass {
        var lines: [(line: String, domain: TestDomain?, onMain: Bool)] = []
        var t0 = 0, t1 = 0
        var stalls = ""
    }

    /// Measures how long the main thread stays busy while a pass runs: a helper thread posts a block to
    /// the main queue every millisecond and records how late it ran. Dump mode only; it never asserts,
    /// because a shared CI runner's timing says nothing about a phone's.
    private final class MainStallProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private var worstMs = 0.0, over4 = 0, over16 = 0, samples = 0

        init() {
            Thread.detachNewThread { [self] in
                while self.isRunning {
                    let sent = DispatchTime.now().uptimeNanoseconds
                    let done = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async {
                        self.record(Double(DispatchTime.now().uptimeNanoseconds &- sent) / 1_000_000)
                        done.signal()
                    }
                    done.wait()
                    usleep(1_000)
                }
            }
        }

        private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

        private func record(_ ms: Double) {
            lock.lock(); defer { lock.unlock() }
            samples += 1
            worstMs = max(worstMs, ms)
            if ms > 4 { over4 += 1 }
            if ms > 16 { over16 += 1 }
        }

        func stop() -> String {
            lock.lock(); defer { lock.unlock() }
            running = false
            return String(format: "worst=%.1fms over4ms=%d over16ms=%d samples=%d", worstMs, over4, over16, samples)
        }
    }

    private var dumpDir: String? {
        guard let dir = ProcessInfo.processInfo.environment["NOOP_OFFMAIN_DUMP"], !dir.isEmpty else { return nil }
        return dir
    }

    private func scorePass(_ engine: IntelligenceEngine, maxDays: Int, repair: Bool = false) async -> Pass {
        var pass = Pass()
        engine.diagnosticSink = { line, domain in
            pass.lines.append((line: line, domain: domain, onMain: Thread.isMainThread))
        }
        let probe = dumpDir == nil ? nil : MainStallProbe()
        pass.t0 = Int(Date().timeIntervalSince1970)
        if repair {
            await engine.analyzeRecent(maxDays: maxDays, triggerLabel: "sleep-wear-history-repair",
                                       preserveUnscoredHistory: true)
        } else {
            await engine.analyzeRecent(maxDays: maxDays, force: true)
        }
        pass.t1 = Int(Date().timeIntervalSince1970)
        pass.stalls = probe?.stop() ?? ""
        engine.diagnosticSink = nil
        return pass
    }

    /// The #899 heal re-arms exactly one forced pass from the first pass's `defer`; it starts as soon as the
    /// main actor is free. Capture it on its own so the next explicit pass never races it.
    private func drainRearm(_ engine: IntelligenceEngine) async -> Pass {
        var pass = Pass()
        engine.diagnosticSink = { line, domain in
            pass.lines.append((line: line, domain: domain, onMain: Thread.isMainThread))
        }
        pass.t0 = Int(Date().timeIntervalSince1970)
        try? await Task.sleep(nanoseconds: 100_000_000)
        for _ in 0..<3_000 where engine.computing {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        pass.t1 = Int(Date().timeIntervalSince1970)
        engine.diagnosticSink = nil
        return pass
    }

    /// Everything the pass persisted that a reader of the computed source can see.
    private func storedRows(_ store: WhoopStore) async throws -> [String] {
        var rows: [String] = []
        for d in try await store.dailyMetrics(deviceId: source + "-noop", from: "0000-01-01", to: "9999-12-31") {
            rows.append("daily \(d)")
        }
        for d in try await store.dailyMetrics(deviceId: Repository.appleHealthSource,
                                              from: "0000-01-01", to: "9999-12-31") {
            rows.append("apple \(d)")
        }
        for s in try await store.sleepSessions(deviceId: source + "-noop", from: 0, to: Int.max / 2, limit: 1_000) {
            rows.append("sleep \(s)")
        }
        for w in try await store.workouts(deviceId: source, from: 0, to: Int.max / 2, limit: 1_000) {
            rows.append("workout \(w)")
        }
        let keys = ["sleep_performance", DayCycleIntelligenceIntegration.onsetKey, "steps_est",
                    "spo2_candidate", "hrv_rr_overcount", "rhr_primary_session",
                    "rhr_primary_session_valid_samples", "rhr_primary_session_duration_s",
                    "fitness_age", "vo2max_est", "vitality", "body_age"]
        for key in keys {
            for p in try await store.metricSeries(deviceId: source + "-noop", key: key,
                                                  from: "0000-01-01", to: "9999-12-31") {
                rows.append("metric \(p)")
            }
        }
        return rows
    }

    /// Pass-timing lines carry wall-clock costs; `now` appears in the open cycle's bounds. Both are masked
    /// so a transcript compares across builds; every other byte is kept.
    private func normalized(_ pass: Pass) -> [String] {
        let timing = ["analyzeRecent cost ", "analyzeRecent postLoop ", "analyzeRecent storeProbes ",
                      "re-score: done", "re-score: cost"]
        let number = try! NSRegularExpression(pattern: "\\b\\d{10}\\b")
        return pass.lines.compactMap { entry in
            if timing.contains(where: { entry.line.hasPrefix($0) }) { return nil }
            var line = entry.line
            for match in number.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                guard let range = Range(match.range, in: line), let value = Int(line[range]),
                      value >= pass.t0 - 1, value <= pass.t1 + 1 else { continue }
                line.replaceSubrange(range, with: "NOW")
            }
            return "[\(entry.domain.map { "\($0)" } ?? "-")] \(line)"
        }
    }

    private func dump(_ name: String, _ text: [String]) throws {
        guard let dir = dumpDir else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try (text.joined(separator: "\n") + "\n").write(toFile: dir + "/" + name + ".txt",
                                                       atomically: true, encoding: .utf8)
    }

    private func exercise(traces: Bool) async throws {
        try await withPreferences(traces: traces) {
            let store = try await WhoopStore.inMemory()
            try await seed(store)
            let repo = Repository(deviceId: source)
            repo.setStoreForTesting(store)
            let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: source)

            let healing = await scorePass(engine, maxDays: 6)
            let rearmed = await drainRearm(engine)
            let first = await scorePass(engine, maxDays: 6)
            let firstRows = try await storedRows(store)
            let second = await scorePass(engine, maxDays: 6)
            let secondRows = try await storedRows(store)
            let tag = traces ? "traces" : "plain"
            try dump("\(tag)-pass0", normalized(healing))
            try dump("\(tag)-pass0-rearm", normalized(rearmed))
            try dump("\(tag)-pass1", normalized(first) + ["--- stored"] + firstRows)
            try dump("\(tag)-pass2", normalized(second) + ["--- stored"] + secondRows)
            // Timing, kept apart from the transcripts so those stay byte-comparable across builds.
            try dump("stalls-\(tag)", ["pass0 " + healing.stalls, "pass1 " + first.stalls, "pass2 " + second.stalls]
                     + [first, second].map { pass in
                         pass.lines.map(\.line).filter {
                             $0.hasPrefix("analyzeRecent postLoop") || $0.hasPrefix("re-score: done")
                                 || $0.hasPrefix("analyzeRecent cost ")
                         }.joined(separator: " || ")
                     })

            if dumpDir != nil, !traces {
                // The launch history repair's shape: thousands of mostly empty days. Dump mode only, since
                // it adds seconds and asserts nothing the 6-day passes do not.
                let repair = await scorePass(engine, maxDays: 4_000, repair: true)
                try dump("plain-repair4000", normalized(repair) + ["--- stored"] + (try await storedRows(store)))
                try dump("stalls-repair4000", [repair.stalls] + [repair.lines.map(\.line).filter {
                    $0.hasPrefix("analyzeRecent postLoop") || $0.hasPrefix("re-score: done")
                        || $0.hasPrefix("analyzeRecent cost ") || $0.hasPrefix("re-score: cost")
                }.joined(separator: " || ")])
            }

            XCTAssertTrue(healing.lines.contains { $0.line.hasPrefix("Dedup(#1284): dropped ") },
                          "the fixture's stale copy must reach the heal")
            XCTAssertTrue(rearmed.lines.first?.line.hasPrefix("re-score: trigger=") == true,
                          "the heal must re-arm one pass")
            for pass in [healing, rearmed, first, second] {
                let offMain = pass.lines.filter { !$0.onMain }.map(\.line)
                XCTAssertEqual(offMain, [], "diagnostic lines must reach the sink on the main thread")
                XCTAssertTrue(pass.lines.first?.line.hasPrefix("re-score: trigger=") == true)
                XCTAssertTrue(pass.lines.contains { $0.line.hasPrefix("re-score: done") })
            }
            XCTAssertTrue(firstRows.contains { $0.hasPrefix("daily ") }, "the fixture must score nights")
            XCTAssertTrue(firstRows.contains { $0.contains(DayCycleIntelligenceIntegration.onsetKey) },
                          "the fixture must reach the day-cycle phase")
            XCTAssertEqual(secondRows, firstRows,
                           "a pass served from the in-memory caches must persist exactly what a cold one did")

            guard traces else { return }
            // The day-cycle trace is emitted while the cycles are computed: after the day loop's lines and
            // before the first per-night summary, in both the cold and the cached pass.
            for pass in [first, second] {
                let lines = pass.lines.map(\.line)
                let cycle = lines.indices.filter { lines[$0].hasPrefix("stepsCycle ") }
                let dayCache = lines.firstIndex { $0.hasPrefix("analyzeRecent dayCache ") }
                let firstNight = lines.firstIndex { $0.hasPrefix("sleep day=") }
                XCTAssertFalse(cycle.isEmpty, "the steps trace must report the cycles")
                if let dayCache, let firstNight, let lo = cycle.first, let hi = cycle.last {
                    XCTAssertLessThan(dayCache, lo)
                    XCTAssertLessThan(hi, firstNight)
                } else {
                    XCTFail("missing anchor lines: \(lines)")
                }
                XCTAssertTrue(pass.lines.filter { $0.line.hasPrefix("stepsCycle ") }.allSatisfy { $0.domain == .steps })
            }
        }
    }

    func testPassWithoutTracesKeepsSinkOnMainAndCachedPassMatchesColdPass() async throws {
        try await exercise(traces: false)
    }

    func testPassWithEveryTraceKeepsLineOrderAndSinkOnMain() async throws {
        try await exercise(traces: true)
    }
}
