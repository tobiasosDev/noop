import XCTest
@testable import Strand

@MainActor
final class JournalStoreTests: XCTestCase {

    private func isolatedDefaults() -> UserDefaults {
        let suite = "journal.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testDefaultsOnFreshInstall() {
        let store = JournalStore(defaults: isolatedDefaults())
        XCTAssertEqual(store.trackedIDs, JournalCatalog.defaultTrackedIDs)
        XCTAssertFalse(store.reminderEnabled)
        XCTAssertEqual(store.reminderMinutes, 8 * 60)   // 08:00
        XCTAssertNil(store.lastLoggedDay)
    }

    func testTrackedSetPersistsAcrossReinit() {
        let d = isolatedDefaults()
        let s1 = JournalStore(defaults: d)
        s1.setTracked("alcohol", false)
        s1.setTracked("nap", true)
        s1.reminderEnabled = true
        s1.reminderMinutes = 7 * 60 + 30
        s1.lastLoggedDay = "2026-06-08"

        let s2 = JournalStore(defaults: d)
        XCTAssertFalse(s2.trackedIDs.contains("alcohol"))
        XCTAssertTrue(s2.trackedIDs.contains("nap"))
        XCTAssertTrue(s2.reminderEnabled)
        XCTAssertEqual(s2.reminderMinutes, 7 * 60 + 30)
        XCTAssertEqual(s2.lastLoggedDay, "2026-06-08")
    }

    func testTrackedBehaviorsFollowCatalogOrder() {
        let store = JournalStore(defaults: isolatedDefaults())
        store.setTracked("nap", true)        // catalog id; should appear in catalog order
        let ordered = store.trackedBehaviors.map(\.id)
        let catalogOrder = JournalCatalog.all.map(\.id)
        XCTAssertEqual(ordered, catalogOrder.filter { store.trackedIDs.contains($0) })
    }
}
