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
