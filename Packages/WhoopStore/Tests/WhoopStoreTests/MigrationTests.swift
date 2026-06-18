import XCTest
import GRDB
@testable import WhoopStore

final class MigrationTests: XCTestCase {
    func testInMemoryRunsMigrations() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "hrSample", "rrInterval", "event", "battery", "rawBatch"] {
            XCTAssertTrue(tables.contains(t), "missing table \(t)")
        }
    }

    func testFileInitRunsMigrations() async throws {
        let path = NSTemporaryDirectory() + "whoopstore-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try await WhoopStore(path: path)
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("hrSample"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testHrSamplePrimaryKeyIsDeviceIdTs() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("hrSample")
        XCTAssertEqual(cols, ["deviceId", "ts"])
    }

    func testRrIntervalPrimaryKeyIncludesRrMs() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("rrInterval")
        XCTAssertEqual(cols, ["deviceId", "ts", "rrMs"])
    }

    /// v5 adds a `synced` column to all 8 decoded tables.
    func testV5AddsSyncedColumnToDecodedTables() async throws {
        let store = try await WhoopStore.inMemory()
        for table in ["hrSample", "rrInterval", "event", "battery",
                      "spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
            let cols = try await store.columnNamesForTest(table: table)
            XCTAssertTrue(cols.contains("synced"), "\(table) missing synced column")
        }
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 17)
    }

    /// v13 adds the `userEdited` flag to sleepSession (user-corrected wake times survive re-sync).
    func testV13AddsUserEditedColumnToSleepSession() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("userEdited"), "sleepSession missing v13 userEdited column")
    }

    /// v14 adds `startTsAdjusted` (the user-corrected sleep onset; detected startTs stays the key).
    func testV14AddsStartTsAdjustedColumnToSleepSession() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("startTsAdjusted"), "sleepSession missing v14 startTsAdjusted column")
    }

    /// v16 adds `peripheralId` to pairedDevice (stable per-strap BLE identity for multi-WHOOP support).
    func testV16AddsPeripheralIdColumnToPairedDevice() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "pairedDevice")
        XCTAssertTrue(cols.contains("peripheralId"), "pairedDevice missing v16 peripheralId column")
    }

    /// v17 HEAL: regression for the tecminds fork↔upstream migration-identifier collision. On a DB first
    /// provisioned by the fork, "v13" was recorded under a DIFFERENT body (ppgHrSample), so GRDB skipped
    /// upstream's v13 and sleepSession never got `userEdited`. Every sleepSession read + the session upsert
    /// reference that column, so they threw "no such column: userEdited" — the Sleep screen went blank and
    /// the analyze pass aborted. v17 must re-add the column on such a DB. Reproduces the exact device state:
    /// sleepSession WITHOUT userEdited + v1..v16 marked applied so only the new v17 runs.
    func testV17HealsMissingUserEditedOnForkDivergentDB() async throws {
        let path = NSTemporaryDirectory() + "fork-divergent-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let queue = try DatabaseQueue(path: path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE sleepSession (
                    deviceId TEXT NOT NULL, startTs INTEGER NOT NULL, endTs INTEGER NOT NULL,
                    efficiency DOUBLE, restingHr INTEGER, avgHrv DOUBLE, stagesJSON TEXT,
                    startTsAdjusted INTEGER, PRIMARY KEY (deviceId, startTs));
                CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
                """)
            for id in ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12",
                       "v13", "v14", "v15-device-registry", "v16-paired-device-peripheral"] {
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [id])
            }
        }
        let before = try await queue.read { try $0.columns(in: "sleepSession").map(\.name) }
        XCTAssertFalse(before.contains("userEdited"), "precondition: fork-divergent DB lacks userEdited")

        try WhoopStore.makeMigrator().migrate(queue)

        let after = try await queue.read { try $0.columns(in: "sleepSession").map(\.name) }
        XCTAssertTrue(after.contains("userEdited"), "v17 must re-add userEdited on a fork-divergent DB")
    }

    /// v17 is idempotent: on a clean upstream DB (userEdited already present from v13) it must be a no-op,
    /// not a "duplicate column" throw.
    func testV17IsNoOpOnCleanUpstreamDB() async throws {
        let store = try await WhoopStore.inMemory()   // runs the full migrator including v17
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertEqual(cols.filter { $0 == "userEdited" }.count, 1, "userEdited must exist exactly once")
    }
}
