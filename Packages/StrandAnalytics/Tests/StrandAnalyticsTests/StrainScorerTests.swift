import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class StrainScorerTests: XCTestCase {

    /// Build n consecutive 1 Hz HR samples at a constant bpm.
    private func hr(_ bpm: Int, _ n: Int, start: Int = 0) -> [HRSample] {
        (0..<n).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    func testTanakaAndDefaultMax() {
        XCTAssertEqual(StrainScorer.tanakaHRmax(age: 30), 187.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.defaultMaxHR(age: 30), 190)
    }

    func testTrimpToStrainCeilingMapsTo100() {
        // Edwards 24 h ceiling TRIMP = 7200 → Effort exactly 100.0 with D = 7201
        // (rescaled from the old 21.0; the curve/saturation point is unchanged).
        XCTAssertEqual(StrainScorer.trimpToStrain(7200), 100.0, accuracy: 1e-9)
    }

    func testTrimpToStrainKnownValues() {
        XCTAssertEqual(StrainScorer.trimpToStrain(0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.trimpToStrain(-5), 0.0, accuracy: 1e-9)
        // 10.91 × 100/21 on the rescaled axis.
        XCTAssertEqual(StrainScorer.trimpToStrain(100), 51.96, accuracy: 1e-2)
    }

    func testStrainGoldenEdwardsZone5() {
        // 600 z5 samples at 1 Hz, resting 60, max 190. TRIMP = 600*5*(1/60)=50.
        // Effort = 100*ln(51)/ln(7201) = 44.27 (was 9.3 on the 0–21 axis).
        let s = StrainScorer.strain(hr(185, 600), maxHR: 190, restingHR: 60)
        XCTAssertEqual(s!, 44.27, accuracy: 1e-2)
    }

    func testStrainReturnsNilTooFewReadings() {
        XCTAssertNil(StrainScorer.strain(hr(150, 599), maxHR: 190, restingHR: 60))
    }

    func testStrainReturnsNilInvalidHRR() {
        XCTAssertNil(StrainScorer.strain(hr(150, 600), maxHR: 60, restingHR: 60))
        XCTAssertNil(StrainScorer.strain(hr(150, 600), maxHR: 50, restingHR: 60))
    }

    func testStrainMonotonicInZoneTime() {
        // More time at high intensity → higher strain. Compare 600 vs 1200 z5 samples.
        let short = StrainScorer.strain(hr(185, 600), maxHR: 190, restingHR: 60)!
        let long = StrainScorer.strain(hr(185, 1200), maxHR: 190, restingHR: 60)!
        XCTAssertGreaterThan(long, short)
    }

    func testStrainMonotonicInIntensity() {
        // Same duration, higher zone → higher strain.
        let z3 = StrainScorer.strain(hr(155, 600), maxHR: 190, restingHR: 60)!  // ~73% HRR → w3
        let z5 = StrainScorer.strain(hr(185, 600), maxHR: 190, restingHR: 60)!  // ~96% HRR → w5
        XCTAssertGreaterThan(z5, z3)
    }

    func testStrainBanisterAlsoBounded() {
        let s = StrainScorer.strain(hr(185, 600), maxHR: 190, restingHR: 60, method: .banister)!
        XCTAssertGreaterThan(s, 0)
        XCTAssertLessThanOrEqual(s, 100.0)
    }

    func testEstimateHRmaxObservedVsTanaka() {
        // Thin history but known age → tanaka.
        let (v1, src1) = StrainScorer.estimateHRmax([150, 160, 170], age: 30)
        XCTAssertEqual(v1, 187.0, accuracy: 1e-9)
        XCTAssertEqual(src1, "tanaka")

        // No age, no history → unknown.
        let (v2, src2) = StrainScorer.estimateHRmax([150], age: nil)
        XCTAssertEqual(v2, 0.0)
        XCTAssertEqual(src2, "unknown")

        // Dense history with a sustained high tail above tanaka → observed.
        // The 99.5th percentile must exceed 187, so the top ~0.5% must be high:
        // 700 samples, top 10 (>0.5%) at 195 → p99.5 lands in the high tail.
        var hist = Array(repeating: 120.0, count: 690)
        hist.append(contentsOf: Array(repeating: 195.0, count: 10))
        let (v3, src3) = StrainScorer.estimateHRmax(hist, age: 30)
        XCTAssertEqual(src3, "observed")
        XCTAssertGreaterThan(v3, 187.0)
    }

    func testPercentileLinearInterp() {
        XCTAssertEqual(StrainScorer.percentile([10, 20, 30, 40], 50), 25.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.percentile([10, 20, 30, 40], 0), 10.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.percentile([10, 20, 30, 40], 100), 40.0, accuracy: 1e-9)
    }

    func testFitStrainDenominator() throws {
        // Pairs generated from a known D should recover that D. Pairs use the rescaled
        // 0–100 axis (maxStrain = 100), matching fitStrainDenominator's maxStrain term.
        let knownD = 5000.0
        func strainFor(_ t: Double) -> Double { 100 * log(t + 1) / log(knownD) }
        let pairs = [(100.0, strainFor(100)), (1000.0, strainFor(1000)), (50.0, strainFor(50))]
        let fitted = try StrainScorer.fitStrainDenominator(pairs)
        XCTAssertEqual(fitted, knownD, accuracy: 1.0)
    }

    func testFitStrainDenominatorThrowsTooFew() {
        XCTAssertThrowsError(try StrainScorer.fitStrainDenominator([(100, 10)]))
    }

    // MARK: - Histogram overload parity

    /// The histogram overload must be bit-identical to the array path for both methods —
    /// it exists purely so callers can aggregate a day in SQL instead of loading raw rows.
    func testHistogramStrainMatchesArrayPath() {
        // Mixed-intensity day: rest, zones 1–5, with repeated bpm values (deterministic).
        var samples: [HRSample] = []
        var ts = 0
        for (bpm, n) in [(58, 900), (95, 600), (120, 700), (140, 500), (165, 300), (185, 120)] {
            for _ in 0..<n { samples.append(HRSample(ts: ts, bpm: bpm)); ts += 1 }
        }
        var counts: [Int: Int] = [:]
        for s in samples { counts[s.bpm, default: 0] += 1 }
        let bins = counts.map { (bpm: $0.key, count: $0.value) }
        let dur = StrainScorer.sampleDurationMinutes(samples)

        for method in [StrainScorer.Method.edwards, .banister] {
            for sex in ["male", "female"] {
                let fromArray = StrainScorer.strain(samples, maxHR: 190, restingHR: 60,
                                                    method: method, sex: sex)
                let fromBins = StrainScorer.strain(histogram: bins, sampleDurationMin: dur,
                                                   maxHR: 190, restingHR: 60,
                                                   method: method, sex: sex)
                XCTAssertEqual(fromArray, fromBins, "method=\(method) sex=\(sex)")
            }
        }
    }

    func testHistogramStrainNilGates() {
        // Under minReadings → nil (599 samples).
        XCTAssertNil(StrainScorer.strain(histogram: [(bpm: 150, count: 599)],
                                         sampleDurationMin: 1.0 / 60.0,
                                         maxHR: 190, restingHR: 60))
        // Invalid HRR (max ≤ resting) → nil.
        XCTAssertNil(StrainScorer.strain(histogram: [(bpm: 150, count: 1000)],
                                         sampleDurationMin: 1.0 / 60.0,
                                         maxHR: 60, restingHR: 60))
    }
}
