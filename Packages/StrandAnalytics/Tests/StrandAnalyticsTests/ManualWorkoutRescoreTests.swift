import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// #137 — the pure re-score logic: recompute an under-sampled manual workout's metrics from the denser
/// HR now available for its window, conservatively and idempotently.
final class ManualWorkoutRescoreTests: XCTestCase {

    private let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")

    /// A dense, moderately-hard window scores real calories + strain (the 5/MG case after offload).
    func testScoresDenseWindow() {
        // 20 minutes at ~140 bpm, 1 Hz.
        let samples = (0..<1200).map { HRSample(ts: 1_000 + $0, bpm: 140) }
        let s = ManualWorkoutRescore.scored(windowSamples: samples, profile: profile, hrMax: 190)
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.avgHr, 140)
        XCTAssertEqual(s?.maxHr, 140)
        XCTAssertNotNil(s?.kcal)
        XCTAssertGreaterThan(s?.kcal ?? 0, 50)   // a 20-min Z3 bout burns well over 50 kcal
        XCTAssertNotNil(s?.strain)
    }

    /// Too few samples → nil (nothing better than what we had; never fabricate from one reading).
    func testTooFewSamplesReturnsNil() {
        XCTAssertNil(ManualWorkoutRescore.scored(windowSamples: [HRSample(ts: 1, bpm: 130)],
                                                 profile: profile, hrMax: 190))
        XCTAssertNil(ManualWorkoutRescore.scored(windowSamples: [], profile: profile, hrMax: 190))
    }

    /// The under-scored gate: only missing/negligible calories qualify; a normal workout never does.
    func testLooksUnderScoredGate() {
        XCTAssertTrue(ManualWorkoutRescore.looksUnderScored(currentKcal: nil))
        XCTAssertTrue(ManualWorkoutRescore.looksUnderScored(currentKcal: 1.0))   // the "1 kcal" symptom
        XCTAssertTrue(ManualWorkoutRescore.looksUnderScored(currentKcal: 5.0))
        XCTAssertFalse(ManualWorkoutRescore.looksUnderScored(currentKcal: 5.01))
        XCTAssertFalse(ManualWorkoutRescore.looksUnderScored(currentKcal: 250))  // a real session
    }

    /// Only persists a strict improvement — so a sparse-window recompute (≈ current) is a no-op, the
    /// pass is idempotent, and it can never *lower* a workout's numbers.
    func testImprovesIsStrictAndMonotonic() {
        let big = ManualWorkoutRescore.Scored(avgHr: 140, maxHr: 150, strain: 12, kcal: 220)
        XCTAssertTrue(ManualWorkoutRescore.improves(big, over: nil))
        XCTAssertTrue(ManualWorkoutRescore.improves(big, over: 1))
        XCTAssertFalse(ManualWorkoutRescore.improves(big, over: 220))   // already this good → no churn
        XCTAssertFalse(ManualWorkoutRescore.improves(big, over: 219.5)) // within the margin → no churn

        let none = ManualWorkoutRescore.Scored(avgHr: 0, maxHr: 0, strain: nil, kcal: nil)
        XCTAssertFalse(ManualWorkoutRescore.improves(none, over: 1))    // no recompute ⇒ never replace
    }

    /// End-to-end shape of the fix: a workout saved with ~1 kcal (sparse live HR) gets rescored from a
    /// dense offloaded window, and the result both clears the under-scored gate and improves.
    func testUnderScoredWorkoutGetsRescoredFromDenseWindow() {
        let stored: Double? = 1.0
        XCTAssertTrue(ManualWorkoutRescore.looksUnderScored(currentKcal: stored))
        let dense = (0..<900).map { HRSample(ts: 2_000 + $0, bpm: 150) }   // 15 min @150
        let s = ManualWorkoutRescore.scored(windowSamples: dense, profile: profile, hrMax: 190)!
        XCTAssertTrue(ManualWorkoutRescore.improves(s, over: stored))
        // And it's idempotent: re-running over the now-good value is a no-op.
        XCTAssertFalse(ManualWorkoutRescore.improves(s, over: s.kcal))
    }
}
