import XCTest
@testable import Strand

final class ReanalysisScopeTests: XCTestCase {

    func testLastNightForcesOnlyTheTwoNewestOffsets() {
        XCTAssertTrue(ReanalysisScope.lastNight.forcesOffset(0))
        XCTAssertTrue(ReanalysisScope.lastNight.forcesOffset(1),
                      "the most recent sleep may have ENDED on yesterday's UTC day")
        XCTAssertFalse(ReanalysisScope.lastNight.forcesOffset(2))
        XCTAssertFalse(ReanalysisScope.lastNight.forcesOffset(20))
    }

    func testEverythingForcesAllOffsets() {
        for offset in 0..<21 {
            XCTAssertTrue(ReanalysisScope.everything.forcesOffset(offset))
        }
    }
}
