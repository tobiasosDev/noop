import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Pins the main-thread hitch round's Trends / Sleep restructuring against the code it replaced.
///
/// Trends now memoizes its history-wide derivations, which split two helpers so the memo could hold the
/// language-independent half. The old single functions are reproduced verbatim below as oracles and
/// compared over a spread of generated histories. Sleep now reuses its last model build when the inputs
/// are identical and builds the post-refresh model off the main actor; the memo must miss on a change to
/// ANY input, and the detached build must equal the build on the main actor.
final class TrendsSleepMemoTests: XCTestCase {

    // MARK: Fixtures

    private func day(_ key: String, recovery: Double? = nil, sleep: Double? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: sleep, efficiency: sleep == nil ? nil : 0.9,
                    deepMin: sleep == nil ? nil : 80, remMin: sleep == nil ? nil : 95,
                    lightMin: sleep == nil ? nil : 220, disturbances: nil,
                    restingHr: nil, avgHrv: nil, recovery: recovery, strain: nil,
                    exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)
    }

    /// A deterministic pseudo-random history of `count` consecutive days ending on `last`.
    private func history(count: Int, last: String, seed: UInt64, gapEvery: Int) -> [DailyMetric] {
        var state = seed
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        return (0..<count).map { i in
            let key = WeeklyDigestEngine.addDays(last, -(count - 1 - i))
            let gap = gapEvery > 0 && i % gapEvery == 0
            return day(key, recovery: gap ? nil : 5 + 90 * next())
        }
    }

    // MARK: Trends: strongest month (oracle = the pre-memo `strongestMonthLine(_ days:)`, verbatim)

    private func oracleStrongestMonthLine(_ days: ArraySlice<DailyMetric>) -> String? {
        var byMonth: [String: [Double]] = [:]
        for d in days { if let r = d.recovery { byMonth[String(d.day.prefix(7)), default: []].append(r) } }
        let months = byMonth.filter { $0.value.count >= 10 }
            .map { (key: $0.key, mean: $0.value.reduce(0, +) / Double($0.value.count),
                    n: $0.value.count, primed: $0.value.filter { $0 >= 70 }.count) }
        guard months.count >= 2,
              let best = months.max(by: { $0.mean < $1.mean }),
              let worst = months.min(by: { $0.mean < $1.mean }),
              best.key != worst.key,
              let bestDate = TrendsDayFormat.date(best.key + "-01"),
              let worstDate = TrendsDayFormat.date(worst.key + "-01") else { return nil }
        let bestName = TrendsDayFormat.monthName(bestDate), worstName = TrendsDayFormat.monthName(worstDate)
        return String(localized: "\(bestName) was your strongest month: \(best.primed) of \(best.n) days primed or better, against \(worst.primed) of \(worst.n) in \(worstName).")
    }

    func testStrongestMonthSplitMatchesTheSingleFunction() {
        var compared = 0, nonNil = 0
        for (seed, count, gap) in [(1, 20, 0), (2, 45, 3), (3, 365, 0), (4, 365, 2), (5, 400, 5),
                                   (6, 1200, 7), (7, 4000, 0), (8, 60, 1), (9, 31, 0), (10, 0, 0)] as [(UInt64, Int, Int)] {
            let days = history(count: count, last: "2026-10-03", seed: seed, gapEvery: gap)
            for strip in [365, max(count, 365), 30] {
                let slice = days.suffix(strip)
                let old = oracleStrongestMonthLine(slice)
                let new = TrendsView.strongestMonthLine(TrendsView.strongestAndWeakestMonths(slice))
                XCTAssertEqual(new, old, "seed \(seed) count \(count) strip \(strip)")
                compared += 1
                if old != nil { nonNil += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(nonNil, 8, "the spread must exercise the sentence, not only the nil paths")
        XCTAssertEqual(compared, 30)
    }

    // MARK: Trends: earliest browsable week (oracle = the pre-memo `minWeekOffset` body, verbatim)

    private func oracleMinWeekOffset(earliestDay: String?, today: String) -> Int {
        guard
            let earliest = earliestDay,
            let earliestMon = WeeklyDigestEngine.mondayOfWeek(containing: earliest),
            let thisMon = WeeklyDigestEngine.mondayOfWeek(containing: today)
        else { return 0 }
        var off = 0
        var mon = thisMon
        while mon > earliestMon && off > -520 {
            mon = WeeklyDigestEngine.addDays(mon, -7)
            off -= 1
        }
        return off
    }

    func testMinWeekOffsetMatchesThePreMemoWalk() {
        let todays = ["2026-10-03", "2026-10-05", "2026-01-01", "2024-02-29", "2026-12-31"]
        var earliests: [String?] = [nil, "garbage", "2026-10-03", "2026-09-28", "2026-09-27", "2016-01-01", "2000-06-15"]
        for back in stride(from: 0, through: 4000, by: 97) {
            earliests.append(WeeklyDigestEngine.addDays("2026-10-03", -back))
        }
        for today in todays {
            for earliest in earliests {
                XCTAssertEqual(TrendsView.computeMinWeekOffset(earliest: earliest, today: today),
                               oracleMinWeekOffset(earliestDay: earliest, today: today),
                               "earliest \(earliest ?? "nil") today \(today)")
            }
        }
    }

    // MARK: Sleep: the model memo

    private func session(_ start: Int, minutes: Int, stages: String?) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: start + minutes * 60, efficiency: 0.9,
                           restingHr: nil, avgHrv: nil, stagesJSON: stages)
    }

    private func inputs(days: [DailyMetric], sessions: [CachedSleepSession],
                        all: [CachedSleepSession] = [], imported: [String: ImportedSleepFigures] = [:],
                        habitual: Int? = nil, motion: [Int: [Double]] = [:]) -> SleepModelInputs {
        SleepModelInputs(days: days, sleeps: sessions, allSessions: all, importedSleep: imported,
                         habitualMidsleepSec: habitual, motionByStart: motion)
    }

    func testSleepMemoReusesOnlyIdenticalInputs() {
        let night = session(1_759_446_000, minutes: 450,
                            stages: #"{"light":220,"deep":80,"rem":95,"awake":55}"#)
        let base = inputs(days: [day("2026-10-02", sleep: 395), day("2026-10-03", sleep: 400)],
                          sessions: [night])
        let memo = SleepModelMemo()
        var builds = 0
        func get(_ i: SleepModelInputs) { _ = memo.model(for: i) { builds += 1; return SleepModel.build(i) } }

        get(base); XCTAssertEqual(builds, 1)
        get(base); XCTAssertEqual(builds, 1, "identical inputs must reuse the last build")

        let variants: [(String, SleepModelInputs)] = [
            ("days", inputs(days: [day("2026-10-02", sleep: 395), day("2026-10-03", sleep: 401)], sessions: [night])),
            ("sleeps", inputs(days: base.days, sessions: [session(night.startTs, minutes: 451, stages: night.stagesJSON)])),
            ("allSessions", inputs(days: base.days, sessions: [night], all: [night])),
            ("importedSleep", inputs(days: base.days, sessions: [night],
                                     imported: ["2026-10-03": ImportedSleepFigures(performancePct: 80, consistencyPct: nil,
                                                                                  needMin: nil, debtMin: nil)])),
            ("habitualMidsleepSec", inputs(days: base.days, sessions: [night], habitual: 12_600)),
            ("motionByStart", inputs(days: base.days, sessions: [night], motion: [night.startTs: [0.1, 0.2]])),
        ]
        for (field, variant) in variants {
            let before = builds
            get(variant)
            XCTAssertEqual(builds, before + 1, "a change to \(field) must rebuild")
            get(base)
            XCTAssertEqual(builds, before + 2, "switching back to the base inputs after \(field) must rebuild")
        }
    }

    func testSleepMemoMissesOnAnotherClockContext() {
        let night = session(1_759_446_000, minutes: 450,
                            stages: #"{"light":220,"deep":80,"rem":95,"awake":55}"#)
        let i = inputs(days: [day("2026-10-03", sleep: 400)], sessions: [night])
        let memo = SleepModelMemo()
        var builds = 0
        // A stored entry from another logical day must not be handed out today.
        memo.store(nil, inputs: i, context: SleepBuildContext(logicalDay: "1999-01-01",
                                                              timeZone: TimeZone.current,
                                                              utcOffsetSec: TimeZone.current.secondsFromGMT()))
        let model = memo.model(for: i) { builds += 1; return SleepModel.build(i) }
        XCTAssertEqual(builds, 1)
        XCTAssertNotNil(model)
    }

    // MARK: Sleep: the detached build

    /// The comparable projection of a model: every scalar the screen reads plus the series lengths.
    private func projection(_ m: SleepModel?) -> String {
        guard let m else { return "nil" }
        func metric(_ x: SleepModel.Metric) -> String {
            "\(String(describing: x.latest))|\(x.latestDay ?? "-")|\(String(describing: x.typical))|\(x.series)"
        }
        let n = m.night
        return [
            "\(n.session.startTs)-\(n.session.endTs)-\(String(describing: n.session.efficiency))",
            "\(n.stages.awake)/\(n.stages.light)/\(n.stages.deep)/\(n.stages.rem)",
            "\(m.intervals.map { "\($0.stage)@\($0.start)-\($0.end)" })",
            "\(m.isPersistedHypnogram)|\(m.isStubNight)",
            metric(m.performance), metric(m.efficiency), metric(m.consistency), metric(m.hoursVsNeeded),
            metric(m.restorative), metric(m.respiratory), metric(m.sleepDebt),
            "\(String(describing: m.typicalTotalMin))|\(String(describing: m.typicalDeepMin))|\(String(describing: m.typicalRemMin))|\(String(describing: m.typicalLightMin))",
            "\(m.trendPoints.map { "\($0.date.timeIntervalSince1970):\($0.value)" })",
            "\(m.sleepDebtLedger.magnitudeMin)",
        ].joined(separator: "\n")
    }

    func testDetachedBuildEqualsTheMainActorBuild() async {
        let nightStart = 1_759_446_000
        let segments = #"[{"start":\#(nightStart),"end":\#(nightStart + 3600),"stage":"light"},"#
            + #"{"start":\#(nightStart + 3600),"end":\#(nightStart + 7200),"stage":"deep"},"#
            + #"{"start":\#(nightStart + 7200),"end":\#(nightStart + 9000),"stage":"rem"},"#
            + #"{"start":\#(nightStart + 9000),"end":\#(nightStart + 9600),"stage":"wake"}]"#
        let main = session(nightStart, minutes: 160, stages: segments)
        let nap = session(nightStart + 40_000, minutes: 40, stages: #"{"light":30,"deep":0,"rem":0,"awake":10}"#)
        let older = session(nightStart - 86_400, minutes: 420, stages: #"{"light":210,"deep":85,"rem":90,"awake":35}"#)
        var days: [DailyMetric] = []
        for back in stride(from: 40, through: 0, by: -1) {
            days.append(day(WeeklyDigestEngine.addDays("2026-10-03", -back), recovery: Double(40 + back),
                            sleep: Double(360 + (back * 7) % 90)))
        }
        let cases = [
            inputs(days: days, sessions: [older, main]),
            inputs(days: days, sessions: [older, main], all: [older, main, nap], habitual: 12_600,
                   motion: [main.startTs: [0.1, 0.4, 0.2]]),
            inputs(days: days, sessions: [older, main],
                   imported: [days[days.count - 1].day: ImportedSleepFigures(performancePct: 77, consistencyPct: 64,
                                                                              needMin: 470, debtMin: 35)]),
            inputs(days: [], sessions: []),
        ]
        for (index, input) in cases.enumerated() {
            let onMain = await MainActor.run { projection(SleepModel.build(input)) }
            let built = await SleepView.buildOffMain(input)
            XCTAssertEqual(projection(built.model), onMain, "case \(index)")
            let navSessions = input.allSessions.isEmpty ? input.sleeps : input.allSessions
            XCTAssertEqual(built.navDays.map { $0.map(\.startTs) },
                           SleepModel.navDays(navSessions: navSessions).map { $0.map(\.startTs) }, "case \(index)")
        }
    }
}
