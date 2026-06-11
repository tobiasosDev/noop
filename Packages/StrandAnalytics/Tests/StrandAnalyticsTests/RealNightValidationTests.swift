import XCTest
@testable import StrandAnalytics
import WhoopProtocol

// Offline validation against the user's REAL recorded nights, pulled from the
// device DB (whoop.sqlite) and dumped to CSV. This is a diagnostic harness, not
// a CI test: it only runs when NOOP_REAL_NIGHT points at a directory holding
// hrSample.csv / rrInterval.csv / respSample.csv / gravitySample.csv.
//
// Ground truth for this user (204 official-WHOOP-app nights in the same DB):
//   deep  mean 23%  (12–35%),  REM mean 24%  (11–42%),  light 52%.
// The native stager was producing deep 0% / REM 0–13% — the bug under repair.
//
// Run:  NOOP_REAL_NIGHT=/tmp/noop-db swift test --package-path Packages/StrandAnalytics \
//          --filter RealNightValidationTests
final class RealNightValidationTests: XCTestCase {

    // The three native-staged nights present in the dump (unix start, end).
    static let nights: [(name: String, start: Int, end: Int)] = [
        ("nap-1.6h", 1781100467, 1781106108),
        ("nap-2.8h", 1781110123, 1781120307),
        ("main-6.9h", 1781123678, 1781148413),
    ]

    func testRealNightStageProportions() throws {
        guard let dir = ProcessInfo.processInfo.environment["NOOP_REAL_NIGHT"] else {
            throw XCTSkip("Set NOOP_REAL_NIGHT to the CSV dump directory to run.")
        }
        let hr = try Self.loadHR("\(dir)/hrSample.csv")
        let rr = try Self.loadRR("\(dir)/rrInterval.csv")
        let resp = try Self.loadResp("\(dir)/respSample.csv")
        let grav = try Self.loadGrav("\(dir)/gravitySample.csv")
        XCTAssertFalse(hr.isEmpty, "no HR rows — check CSV path")

        for night in Self.nights {
            let stages = SleepStager.stageSession(
                start: night.start, end: night.end,
                grav: grav, hr: hr, rr: rr, resp: resp)
            let p = Self.proportions(stages)
            print(String(format: "[%@] %.1fh  deep %.0f%%  rem %.0f%%  light %.0f%%  wake %.0f%%  (deepMin %.0f remMin %.0f)",
                         night.name, Double(night.end - night.start) / 3600,
                         p.deepPct, p.remPct, p.lightPct, p.wakePct, p.deepMin, p.remMin))

            // The main consolidated night is the one with a real sleep architecture
            // to validate against the personal baseline. Naps are noisier; we only
            // require they no longer collapse to all-light.
            if night.name == "main-6.9h" {
                XCTAssertGreaterThan(p.deepPct, 10.0, "\(night.name): deep collapsed (baseline ~23%)")
                XCTAssertLessThan(p.deepPct, 35.0, "\(night.name): deep implausibly high")
                XCTAssertGreaterThan(p.remPct, 12.0, "\(night.name): REM too low (baseline ~24%)")
                XCTAssertLessThan(p.remPct, 40.0, "\(night.name): REM implausibly high")
            }
            // No night may collapse back to all-light (the original 0%-deep failure mode).
            XCTAssertLessThan(p.lightPct, 99.0, "\(night.name): collapsed to all-light")
            if night.name == "nap-2.8h" {
                XCTAssertGreaterThan(p.remPct, 5.0, "\(night.name): REM collapsed")
            }
        }
    }

    // MARK: - proportions

    struct Props { var deepPct, remPct, lightPct, wakePct, deepMin, remMin: Double }

    static func proportions(_ stages: [StageSegment]) -> Props {
        func mins(_ s: String) -> Double {
            stages.filter { $0.stage == s }.reduce(0.0) { $0 + Double($1.end - $1.start) } / 60.0
        }
        let deep = mins("deep"), rem = mins("rem"), light = mins("light"), wake = mins("wake")
        let tst = max(1, deep + rem + light)
        return Props(deepPct: 100 * deep / tst, remPct: 100 * rem / tst,
                     lightPct: 100 * light / tst,
                     wakePct: 100 * wake / (tst + wake),
                     deepMin: deep, remMin: rem)
    }

    // MARK: - CSV loaders (header row skipped)

    static func rows(_ path: String) throws -> [[String]] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return text.split(separator: "\n").dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }
    static func loadHR(_ p: String) throws -> [HRSample] {
        try rows(p).compactMap { r in r.count >= 2 ? HRSample(ts: Int(r[0]) ?? 0, bpm: Int(r[1]) ?? 0) : nil }
    }
    static func loadRR(_ p: String) throws -> [RRInterval] {
        try rows(p).compactMap { r in r.count >= 2 ? RRInterval(ts: Int(r[0]) ?? 0, rrMs: Int(r[1]) ?? 0) : nil }
    }
    static func loadResp(_ p: String) throws -> [RespSample] {
        try rows(p).compactMap { r in r.count >= 2 ? RespSample(ts: Int(r[0]) ?? 0, raw: Int(r[1]) ?? 0) : nil }
    }
    static func loadGrav(_ p: String) throws -> [GravitySample] {
        try rows(p).compactMap { r in r.count >= 4 ? GravitySample(ts: Int(r[0]) ?? 0, x: Double(r[1]) ?? 0, y: Double(r[2]) ?? 0, z: Double(r[3]) ?? 0) : nil }
    }
}
