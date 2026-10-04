import XCTest
import SQLite3
@testable import Strand
import WhoopStore

/// The registry's hot-path writes (connect / drop stamps, peripheral adoption, model corrections, the Apple
/// Watch refresh) run on `DeviceRegistryWriteLane` instead of the main thread. A synchronous write there
/// waited for the backfill pool's write lock under a 5 s busy timeout, which is the "freezes about a second,
/// then recovers" scroll hitch. These pin the three things the move must not change: writes land in the
/// order they were issued, a caller never waits for a held lock, and a user mutation still sees every hot
/// write issued before it.
@MainActor
final class DeviceRegistryDeferredWriteTests: XCTestCase {
    private var paths: [String] = []

    override func tearDown() {
        for path in paths {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        paths = []
        super.tearDown()
    }

    /// A file-backed store (a real `DatabasePool`, as in production) plus a second, raw connection on the
    /// same file. The raw one stands in for BLEManager's backfill pool: another writer on the file that can
    /// hold SQLite's write lock while the registry writes.
    private func fileStore() async throws -> (registry: DeviceRegistry, store: DeviceRegistryStore,
                                              other: RawConnection) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-lane-\(UUID().uuidString).sqlite").path
        paths.append(path)
        let whoopStore = try await WhoopStore(path: path)
        let store = DeviceRegistryStore(dbQueue: whoopStore.registryWriter)
        let registry = DeviceRegistry(store: store)
        registry.reload()
        return (registry, store, try RawConnection(path: path))
    }

    /// Lane writes are FIFO, so after this every write enqueued before it has landed; then wait for the
    /// main-actor hops that publish their snapshots.
    private func settle(_ registry: DeviceRegistry, store: DeviceRegistryStore) async throws {
        DeviceRegistryWriteLane.afterQueuedWrites {}
        let expected = try store.all()
        for _ in 0..<400 where registry.devices != expected {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(registry.devices, expected, "the published list must end equal to the store")
    }

    private func row(_ id: String, in store: DeviceRegistryStore) throws -> PairedDevice? {
        try store.all().first { $0.id == id }
    }

    // MARK: - Order

    /// A burst of interleaved hot-path writes lands in exactly the order it was issued. A trigger logs
    /// every UPDATE the store sees, so a reordering anywhere in the lane shows up as a different sequence,
    /// not merely a different final value.
    func testHotPathBurstLandsInIssueOrder() async throws {
        let (registry, store, other) = try await fileStore()
        try other.exec("""
            CREATE TABLE writeLog (seq INTEGER PRIMARY KEY AUTOINCREMENT, model TEXT, lastSeenAt INTEGER,
                                   peripheralId TEXT);
            CREATE TRIGGER logPairedDeviceUpdate AFTER UPDATE ON pairedDevice BEGIN
                INSERT INTO writeLog (model, lastSeenAt, peripheralId)
                VALUES (NEW.model, NEW.lastSeenAt, NEW.peripheralId);
            END;
        """)
        let seeded = try XCTUnwrap(registry.devices.first { $0.id == "my-whoop" })

        struct Logged: Equatable, Sendable { var model: String; var lastSeenAt: Int; var peripheralId: String? }
        var expected: [Logged] = []
        var current = Logged(model: seeded.model, lastSeenAt: seeded.lastSeenAt, peripheralId: seeded.peripheralId)
        for i in 1...40 {
            registry.setModel("my-whoop", model: "M\(i)")
            current.model = "M\(i)"; expected.append(current)
            registry.touchLastSeen("my-whoop", at: 10_000 + i)
            current.lastSeenAt = 10_000 + i; expected.append(current)
            registry.setPeripheralId("my-whoop", peripheralId: "P\(i)")
            current.peripheralId = "P\(i)"; expected.append(current)
        }

        // The published list carries the newest values at once, before any write has necessarily landed.
        let shown = try XCTUnwrap(registry.devices.first { $0.id == "my-whoop" })
        XCTAssertEqual(shown.model, "M40")
        XCTAssertEqual(shown.lastSeenAt, 10_040)
        XCTAssertEqual(shown.peripheralId, "P40")

        try await settle(registry, store: store)
        let logged = try other.rows("SELECT model, lastSeenAt, peripheralId FROM writeLog ORDER BY seq").map {
            Logged(model: $0[0] ?? "", lastSeenAt: Int($0[1] ?? "") ?? -1, peripheralId: $0[2])
        }
        XCTAssertEqual(logged, expected, "hot-path writes must land in the order they were issued")
    }

    // MARK: - Never waits for the lock

    /// `touchLastSeen` returns at once while another connection holds SQLite's write lock (the backfill's
    /// shape), and the stamp lands once the lock is released.
    func testTouchLastSeenReturnsWhileAnotherWriterHoldsTheLock() async throws {
        let (registry, store, other) = try await fileStore()

        try other.exec("BEGIN IMMEDIATE")   // hold the write lock, as a backfill chunk does
        let started = Date()
        registry.touchLastSeen("my-whoop", at: 4_242)
        registry.setPeripheralId("my-whoop", peripheralId: "PERIPHERAL-A")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.2, "a hot-path write must not wait for the writer lock (took \(elapsed) s)")

        // Shown at once; not yet in the store, which proves the write really was blocked behind the lock.
        XCTAssertEqual(registry.devices.first { $0.id == "my-whoop" }?.lastSeenAt, 4_242)
        XCTAssertNotEqual(try row("my-whoop", in: store)?.lastSeenAt, 4_242)

        try other.exec("COMMIT")
        try await settle(registry, store: store)
        XCTAssertEqual(try row("my-whoop", in: store)?.lastSeenAt, 4_242)
        XCTAssertEqual(try row("my-whoop", in: store)?.peripheralId, "PERIPHERAL-A")
    }

    /// The drop-time stamp resolves its row on the lane, behind the connect-time adoption still queued
    /// there, so a strap that connects and drops while the lock is held is still stamped.
    func testDropStampResolvesBehindAQueuedAdoption() async throws {
        let (registry, store, other) = try await fileStore()

        try other.exec("BEGIN IMMEDIATE")   // hold the write lock, as a backfill chunk does
        registry.setPeripheralId("my-whoop", peripheralId: "PERIPHERAL-B")
        registry.touchLastSeenForPeripheral("PERIPHERAL-B", at: 5_555)
        registry.touchLastSeenForPeripheral("NOBODY", at: 6_666)   // no row adopted it: stamps nothing
        XCTAssertEqual(registry.devices.first { $0.id == "my-whoop" }?.lastSeenAt, 5_555)

        try other.exec("COMMIT")
        try await settle(registry, store: store)
        XCTAssertEqual(try row("my-whoop", in: store)?.lastSeenAt, 5_555)
    }

    /// `reload()` reads the store directly and cannot tell which queued writes it contains, so it keeps
    /// them overlaid instead of briefly showing the pre-write value.
    func testReloadKeepsWritesThatHaveNotLandedYet() async throws {
        let (registry, store, other) = try await fileStore()

        try other.exec("BEGIN IMMEDIATE")   // hold the write lock, as a backfill chunk does
        registry.setModel("my-whoop", model: "WHOOP 4.0")
        registry.reload()
        XCTAssertEqual(registry.devices.first { $0.id == "my-whoop" }?.model, "WHOOP 4.0")
        XCTAssertEqual(try row("my-whoop", in: store)?.model, "WHOOP")

        try other.exec("COMMIT")
        try await settle(registry, store: store)
        XCTAssertEqual(try row("my-whoop", in: store)?.model, "WHOOP 4.0")
    }

    // MARK: - User mutations stay ordered

    /// A synchronous identity mutation runs after every hot-path write issued before it. Serial adoption
    /// copies the provisional row's `peripheralId`; were the queued adoption still pending, the serial row
    /// would lose the strap's identity.
    func testSerialAdoptionSeesTheQueuedPeripheralAdoption() async throws {
        let (registry, store, other) = try await fileStore()
        registry.add(PairedDevice(id: "whoop-PROV", brand: "WHOOP", model: "WHOOP 5.0 / MG",
                                  sourceKind: .liveBLE, capabilities: [.hr], status: .paired,
                                  addedAt: 100, lastSeenAt: 100))
        registry.setActive("whoop-PROV")

        try other.exec("BEGIN IMMEDIATE")   // hold the write lock, as a backfill chunk does
        registry.setPeripheralId("whoop-PROV", peripheralId: "PERIPHERAL-C")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { try? other.exec("COMMIT") }
        let moved = registry.adoptSerialIdentity(from: "whoop-PROV", to: "whoop-MGB0000001")

        XCTAssertTrue(moved)
        XCTAssertEqual(try row("whoop-MGB0000001", in: store)?.peripheralId, "PERIPHERAL-C")
        XCTAssertNil(try row("whoop-PROV", in: store))
        XCTAssertEqual(registry.activeDeviceId, "whoop-MGB0000001")
        try await settle(registry, store: store)
    }

    // MARK: - Apple Watch refresh

    /// The foreground refresh skips the write when the stored row is already identical, which never needs
    /// the writer lock; a real sighting is written exactly as `add` writes it, keeping `addedAt`.
    func testRefreshSightingSkipsAnIdenticalRowAndWritesARealSighting() async throws {
        let (registry, store, other) = try await fileStore()
        registry.add(PairedDevice(id: "apple-health", brand: "Apple", model: "Apple Watch",
                                  sourceKind: .liveAppleWatch, capabilities: [.hr, .hrv], status: .paired,
                                  addedAt: 100, lastSeenAt: 200))
        let stored = try XCTUnwrap(registry.devices.first { $0.id == "apple-health" })

        try other.exec("BEGIN IMMEDIATE")   // hold the write lock, as a backfill chunk does
        registry.refreshSighting(stored)
        let started = Date()
        DeviceRegistryWriteLane.afterQueuedWrites {}
        let drained = Date().timeIntervalSince(started)
        XCTAssertLessThan(drained, 0.5, "an identical refresh must not wait for the writer lock (took \(drained) s)")

        var sighted = stored
        sighted.lastSeenAt = 300
        registry.refreshSighting(sighted)
        XCTAssertEqual(registry.devices.first { $0.id == "apple-health" }?.lastSeenAt, 300)
        XCTAssertEqual(try row("apple-health", in: store)?.lastSeenAt, 200)

        try other.exec("COMMIT")
        try await settle(registry, store: store)
        XCTAssertEqual(try row("apple-health", in: store), sighted)
        XCTAssertEqual(try row("apple-health", in: store)?.addedAt, 100)
    }

    func testIsSightingOnlyIgnoresOnlyLastSeen() {
        let base = PairedDevice(id: "apple-health", brand: "Apple", model: "Apple Watch",
                                sourceKind: .liveAppleWatch, capabilities: [.hr, .hrv], status: .paired,
                                addedAt: 100, lastSeenAt: 200)
        var later = base; later.lastSeenAt = 900
        var fewer = later; fewer.capabilities = [.hr]
        var active = later; active.status = .active
        var named = later; named.nickname = "Wrist"
        XCTAssertTrue(AppleWatchDevice.isSightingOnly(base, existing: base))
        XCTAssertTrue(AppleWatchDevice.isSightingOnly(later, existing: base))
        XCTAssertFalse(AppleWatchDevice.isSightingOnly(fewer, existing: base))
        XCTAssertFalse(AppleWatchDevice.isSightingOnly(active, existing: base))
        XCTAssertFalse(AppleWatchDevice.isSightingOnly(named, existing: base))
    }
}

/// A raw SQLite connection on the store's file, outside GRDB (the test bundle does not link GRDB). It plays
/// the second writer: `BEGIN IMMEDIATE` takes the write lock and holds it until `COMMIT`, exactly what a
/// backfill chunk insert on BLEManager's own pool does to the registry's pool.
private final class RawConnection: @unchecked Sendable {
    private var db: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw Self.error("open", db)
        }
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Self.error(sql, db) }
    }

    /// Every row of `sql`, each column as text (nil for NULL).
    func rows(_ sql: String) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.error(sql, db) }
        defer { sqlite3_finalize(statement) }
        var out: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            })
        }
        return out
    }

    private static func error(_ what: String, _ db: OpaquePointer?) -> NSError {
        NSError(domain: "RawConnection", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: sqlite3_errmsg(db)))"])
    }
}
