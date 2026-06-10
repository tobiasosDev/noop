import XCTest
@testable import Strand
import WhoopStore

/// Covers the three-tier daily-metric merge that feeds `repo.days` (and therefore Trends/Sleep).
/// Regression guard for the iOS bug where Apple Health days were written to the store under the
/// `apple-health` source but never surfaced in the dashboard because `refresh()`/`mergeDaily` only
/// read the strap (`my-whoop`) and computed (`my-whoop-noop`) sources.
final class RepositoryMergeTests: XCTestCase {

    private func dm(_ day: String, recovery: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil,
                    remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                    avgHrv: nil, recovery: recovery, strain: nil, exerciseCount: nil)
    }

    @MainActor
    func testAppleHealthFillsDaysNeitherStrapSourceHas() {
        // Recent days exist ONLY under Apple Health; old day exists under the strap import.
        let apple    = [dm("2026-06-01", recovery: 1), dm("2026-06-02", recovery: 2)]
        let computed = [dm("2026-06-01", recovery: 5)]                                  // overwrites apple on 06-01
        let imported = [dm("2026-06-01", recovery: 9), dm("2024-01-01", recovery: 7)]   // strap wins 06-01

        let merged = Repository.mergeDaily(imported: imported, computed: computed, apple: apple)

        // All three dates surface, oldest→newest.
        XCTAssertEqual(merged.map(\.day), ["2024-01-01", "2026-06-01", "2026-06-02"])
        // Priority: strap import > computed > apple on a shared day.
        XCTAssertEqual(merged.first { $0.day == "2026-06-01" }?.recovery, 9)
        // An Apple-only recent day still appears (the bug: it used to vanish).
        XCTAssertEqual(merged.first { $0.day == "2026-06-02" }?.recovery, 2)
    }
}
