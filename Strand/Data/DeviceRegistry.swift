import Foundation
import Combine
import WhoopStore

// MARK: - DeviceRegistry
//
// Observable @MainActor cache over the synchronous `DeviceRegistryStore` (device-foundation
// Task 5). The UI observes this for the paired-device list + the currently active device; the
// app's `deviceId` is sourced from `activeDeviceId` so it's "the active device's id" rather than
// the hardcoded "my-whoop" literal. Behaviour is unchanged today — migration v15 seeds a single
// 'my-whoop' row as `.active`, so the active id is still "my-whoop".
//
// `DeviceRegistryStore` is synchronous (its own GRDB queue, internally serialized). Reads here are
// plain synchronous calls (WAL snapshots, which never wait for the writer). Writes come in two speeds,
// both through `DeviceRegistryWriteLane` so they land in the order they were issued:
//   • hot-path writes (a connect / drop stamp, a strap adopting its peripheral id, a model correction,
//     the Apple Watch refresh on every foreground) are ENQUEUED and return at once. The published state
//     is edited in memory at call time, so a reader of `devices` sees the new value immediately, and the
//     store's own snapshot replaces it once the write has landed.
//   • rare user-initiated identity mutations (add, make active, archive, rename, forget, serial
//     adoption) stay synchronous, ordered after every hot-path write still on the lane.
// Failures stay non-fatal and fall back to the seeded defaults.
@MainActor
final class DeviceRegistry: ObservableObject {
    /// All paired devices (any status), oldest-added first — the store's `all()` ordering.
    @Published private(set) var devices: [PairedDevice] = []
    /// The active device's id. Defaults to "my-whoop" so callers have a safe value before the
    /// first `reload()` and if the registry can't be read.
    @Published private(set) var activeDeviceId: String = "my-whoop"

    private let store: DeviceRegistryStore

    /// One hot-path write the lane has not reported back yet, with the in-memory edit that mirrors its SQL.
    private struct PendingEdit {
        let ticket: Int
        let apply: ([PairedDevice]) -> [PairedDevice]
    }

    /// Hot-path writes still in flight, oldest first. Every snapshot shown is overlaid with the ones it
    /// cannot contain yet, so a value a caller has already written never goes missing from `devices` while
    /// an older snapshot is published. Each edit only sets fields to values, so re-applying one that has
    /// in fact landed changes nothing.
    private var pendingEdits: [PendingEdit] = []

    /// Lane position of the newest registry write issued from here. Every lane submission below is made on
    /// the main actor in this order and the lane is FIFO, so a snapshot read on the lane right after write N
    /// contains writes 1...N.
    private var lastTicket = 0

    /// Lane position of the newest snapshot published. A snapshot from an older position that arrives late
    /// (its main-actor hop raced a newer one) is dropped instead of clobbering newer state.
    private var shownTicket = 0

    init(store: DeviceRegistryStore) {
        self.store = store
    }

    /// Load the device list and active id from the store. Best-effort: on any error the published
    /// values are left untouched (keeping the safe "my-whoop" fallback), never crashing. A direct read
    /// cannot tell which in-flight hot-path writes it already contains, so all of them are overlaid.
    func reload() {
        guard let rows = try? store.all() else { return }
        show(pendingEdits.reduce(rows) { $1.apply($0) })
    }

    // MARK: - UI mutations (Devices screen)
    //
    // Each op runs the synchronous store write on `DeviceRegistryWriteLane` (after any hot-path write
    // still queued there), then refreshes the published `devices` / `activeDeviceId` from the store so
    // the UI updates. Best-effort: a store failure leaves the published state untouched (we never crash
    // the UI on a write error).

    /// Add or upsert a paired device (the Add wizard's chosen strap). Refreshes the published list.
    func add(_ device: PairedDevice) {
        writeNow { try? $0.add(device) }
    }

    /// Make `id` the single active device. The store demotes whatever was active in the same
    /// transaction (invariant I1); changing `activeDeviceId` drives the `SourceCoordinator` to run the
    /// right live source.
    func setActive(_ id: String) {
        writeNow { try? $0.setActive(id) }
    }

    /// #771: re-point the active Oura device off its transient CoreBluetooth-UUID id onto its stable
    /// `oura-<serial>` id (read from the ring on connect), folding ONLY the active row's data + registry into
    /// the serial id — other past `oura-*` pairings are left untouched. Best-effort; returns true when a
    /// re-point happened so the caller can `setActive(serialId)` to move the spine onto it.
    @discardableResult
    func adoptSerialIdentity(from activeId: String, to serialId: String) -> Bool {
        writeNow(publishIf: { $0 }) { (try? $0.adoptSerialIdentity(from: activeId, to: serialId)) ?? false }
    }

    /// Archive (remove) a device: NOOP stops connecting to it, but its recorded data is kept. If the
    /// archived device was the active one, `activeDeviceId` is left as-is here — the caller decides the
    /// next active device (or leaves none active) and calls `setActive` explicitly.
    func archive(_ id: String) {
        writeNow { try? $0.archive(id) }
    }

    /// Rename a device. `name` nil/empty clears the nickname so it falls back to brand+model.
    func rename(_ id: String, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname = (trimmed?.isEmpty == false) ? trimmed : nil
        writeNow { try? $0.rename(id, nickname: nickname) }
    }

    /// Permanently delete every recorded sample/derived row for a device across all `deviceId`-keyed
    /// tables. Does NOT remove the registry row (that's `archive`); this only empties its recordings.
    ///
    /// Routed through the `WhoopStore` actor's `deleteAllData(deviceId:)`, so the heavy 16+-table delete
    /// runs on the actor's OWN (off-main) executor instead of blocking the main thread (this is a
    /// `@MainActor` cache). Calling the synchronous `DeviceRegistryStore` write directly here would run
    /// the whole transaction on the main actor and freeze the UI on a large device/Apple-Health dataset.
    /// Best-effort: a store failure leaves the recordings and published state untouched. Awaits the delete
    /// BEFORE `reload()` so the refreshed device list reflects the emptied recordings.
    func deleteDeviceData(_ id: String, store: WhoopStore) async {
        guard ImuSessionFileStore.shared.deleteDevice(id) else { return }
        do {
            try await store.deleteAllData(deviceId: id)
        } catch {
            return
        }
        reload()
    }

    /// Permanently FORGET a device: wipe all of its recorded data AND remove its registry entry, so a
    /// duplicate/stale strap disappears from the Devices list entirely. Today an archived ("Removed")
    /// row can only be re-activated or have its data wiped — never purged — so a duplicate strap lingers
    /// forever (issue #1193). Routes the heavy multi-table sample wipe through the `WhoopStore` actor
    /// (off-main, like `deleteDeviceData`), then removes the small `pairedDevice`/`device` registry rows
    /// and refreshes the published list. Best-effort: if the data wipe fails the registry row is left in
    /// place (we never leave orphaned recordings behind a removed row).
    func forget(_ id: String, store: WhoopStore) async {
        guard ImuSessionFileStore.shared.deleteDevice(id) else { return }
        do {
            try await store.deleteAllData(deviceId: id)
        } catch {
            return
        }
        writeNow { try? $0.remove(id) }
    }

    // MARK: - Hot-path mutations (BLE connect / drop, foreground)
    //
    // Deferred: each edits the published list in memory now and lands its store write on the lane, off
    // the main thread. These run on every connect, every drop and every foreground, and a synchronous
    // write here waited on the main thread for SQLite's single writer, which the backfill holds from a
    // second pool under a 5 s busy timeout (main-thread hitch).

    /// Adopt (or clear, when nil) the stable BLE identity for a device — the
    /// CBPeripheral.identifier.uuidString on iOS/Mac. Lets NOOP tell physical straps apart and map a
    /// connected peripheral back to its registry row. Updates the published list at once; the store write
    /// is deferred to the lane. Best-effort.
    func setPeripheralId(_ id: String, peripheralId: String?) {
        writeLater({ Self.editing($0, id: id) { $0.peripheralId = peripheralId } }) {
            try $0.setPeripheralId(id, peripheralId: peripheralId)
        }
    }

    /// Stamp a device as seen right now — a real connect or disconnect, not every inbound packet, which
    /// would be a write per second for no more truth. Updates the published list at once; the store write
    /// is deferred to the lane. Best-effort. (#1527)
    func touchLastSeen(_ id: String, at ts: Int = Int(Date().timeIntervalSince1970)) {
        writeLater({ Self.stamping($0, id: id, at: ts) }) { try $0.touchLastSeen(id, at: ts) }
    }

    /// Stamp the row that adopted `peripheralId` as seen at `ts`, resolved on the lane with the store's own
    /// exact lookup (`device(forPeripheralId:)`). Resolving there rather than here keeps the lookup behind
    /// any adoption still queued: a strap that connects and drops while the writer lock is held still has
    /// its connect-time `setPeripheralId` land first, exactly as when both writes were synchronous. A
    /// peripheral no row has adopted stamps nothing. (#1527)
    func touchLastSeenForPeripheral(_ peripheralId: String, at ts: Int = Int(Date().timeIntervalSince1970)) {
        writeLater({ rows in
            guard let id = rows.first(where: { $0.peripheralId == peripheralId })?.id else { return rows }
            return Self.stamping(rows, id: id, at: ts)
        }) { store in
            guard let device = try store.device(forPeripheralId: peripheralId) else { return }
            try store.touchLastSeen(device.id, at: ts)
        }
    }

    /// Find the paired device that has adopted a given BLE peripheral, if any. A plain read of the
    /// store (no reload) — returns nil on any error or when no row has adopted that peripheral yet.
    func device(forPeripheralId peripheralId: String) -> PairedDevice? {
        (try? store.device(forPeripheralId: peripheralId)) ?? nil
    }

    /// Update the model label for a device. Updates the published list at once; the store write is
    /// deferred to the lane. Best-effort.
    func setModel(_ id: String, model: String) {
        writeLater({ Self.editing($0, id: id) { $0.model = model } }) { try $0.setModel(id, model: model) }
    }

    /// Re-upsert a device whose only change is `lastSeenAt` (the Apple Watch refresh each foreground
    /// makes), deferred to the lane. Same SQL as `add`, so the stored row ends exactly as `add` would leave
    /// it; when the stored row already equals `device` the write is skipped entirely, a WAL read that never
    /// waits for the writer lock.
    func refreshSighting(_ device: PairedDevice) {
        writeLater({ rows in
            rows.map { row in
                guard row.id == device.id else { return row }
                var refreshed = device
                refreshed.addedAt = row.addedAt   // the upsert never rewrites addedAt
                return refreshed
            }
        }) { store in
            // An unreadable row is not "identical": fall through to the write `add` would have made.
            if (try? store.all())?.first(where: { $0.id == device.id }) == device { return }
            try store.add(device)
        }
    }

    // MARK: - Write plumbing

    /// A user-initiated mutation: run `write` synchronously on the lane, after every hot-path write still
    /// queued there (so, for instance, a strap's adopted `peripheralId` is on its row before a serial
    /// adoption copies the row), then publish the store's state when `publishIf` accepts the result.
    @discardableResult
    private func writeNow<T>(publishIf: (T) -> Bool = { _ in true },
                             _ write: (DeviceRegistryStore) -> T) -> T {
        lastTicket += 1
        let ticket = lastTicket
        let store = self.store
        let (result, rows) = DeviceRegistryWriteLane.afterQueuedWrites { () -> (T, [PairedDevice]?) in
            let result = write(store)
            return (result, publishIf(result) ? (try? store.all()) : nil)
        }
        if let rows { publish(rows, through: ticket) }
        return result
    }

    /// A hot-path mutation: apply `edit` (the in-memory twin of `write`'s SQL) to the published list now,
    /// enqueue `write`, and publish the store's snapshot when it has landed.
    private func writeLater(_ edit: @escaping ([PairedDevice]) -> [PairedDevice],
                            _ write: @escaping @Sendable (DeviceRegistryStore) throws -> Void) {
        lastTicket += 1
        let ticket = lastTicket
        pendingEdits.append(PendingEdit(ticket: ticket, apply: edit))
        show(edit(devices))
        DeviceRegistryWriteLane.enqueue(store, write) { [weak self] rows in
            Task { @MainActor in self?.landed(ticket, rows: rows) }
        }
    }

    /// The lane reported write `ticket` back. A failed snapshot read keeps what is shown, as a failed
    /// `reload()` always has, and only retires the edit.
    private func landed(_ ticket: Int, rows: [PairedDevice]?) {
        guard let rows else {
            pendingEdits.removeAll { $0.ticket == ticket }
            return
        }
        publish(rows, through: ticket)
    }

    /// Publish a lane snapshot taken right after write `ticket`, overlaid with the hot-path writes queued
    /// behind it. Dropped when a snapshot from a later position is already shown.
    private func publish(_ rows: [PairedDevice], through ticket: Int) {
        guard ticket > shownTicket else { return }
        shownTicket = ticket
        pendingEdits.removeAll { $0.ticket <= ticket }
        show(pendingEdits.reduce(rows) { $1.apply($0) })
    }

    /// Assign the published values, skipping an assignment that would change nothing so an unchanged
    /// snapshot does not invalidate every observing view.
    private func show(_ rows: [PairedDevice]) {
        if rows != devices { devices = rows }
        if let active = rows.first(where: { $0.status == .active })?.id, active != activeDeviceId {
            activeDeviceId = active
        }
    }

    /// `UPDATE pairedDevice SET lastSeenAt = ? WHERE id = ? AND status != 'archived'`, in memory.
    private static func stamping(_ rows: [PairedDevice], id: String, at ts: Int) -> [PairedDevice] {
        rows.map { row in
            guard row.id == id, row.status != .archived else { return row }
            var stamped = row
            stamped.lastSeenAt = ts
            return stamped
        }
    }

    /// `UPDATE pairedDevice SET … WHERE id = ?`, in memory.
    private static func editing(_ rows: [PairedDevice], id: String,
                                _ change: (inout PairedDevice) -> Void) -> [PairedDevice] {
        rows.map { row in
            guard row.id == id else { return row }
            var edited = row
            change(&edited)
            return edited
        }
    }
}

// MARK: - DeviceRegistryWriteLane

/// The one serial lane that registry writes run on, so a caller on the main thread never waits for
/// SQLite's single writer.
///
/// Main-thread hitch: a registry write is a one-row UPDATE, but it cannot start until the writer lock is
/// free, and the backfill holds that lock from a SECOND `DatabasePool` on the same file (BLEManager's) for
/// whole chunk inserts, including 10k-row retention sweeps, under `busyMode = .timeout(5)`. Issued on the
/// main thread, the stamp each connect, drop and foreground makes froze scrolling for up to 5 s ("freezes
/// about a second, then recovers"). Hot-path callers enqueue here and return at once.
///
/// Process-wide rather than per store: `DeviceRegistry` and `BLEManager` each hold a `DeviceRegistryStore`
/// over their own pool, and their writes must still land in the order they were issued. A strap's adopted
/// `peripheralId` has to be on its provisional row before `adoptSerialIdentity` copies that row onto the
/// serial id.
enum DeviceRegistryWriteLane {
    private static let queue = DispatchQueue(label: "noop.deviceRegistry.writes", qos: .utility)

    /// Run `write` on the lane and return immediately; writes land in the order they were enqueued.
    /// `landed`, when given, runs on the lane right after the write with a fresh `all()` snapshot (nil when
    /// that read failed), so the caller can publish without another read of its own. Best-effort like every
    /// registry write: a thrown error is swallowed, exactly as the `try?` call sites always did.
    static func enqueue(_ store: DeviceRegistryStore,
                        _ write: @escaping @Sendable (DeviceRegistryStore) throws -> Void,
                        landed: (@Sendable ([PairedDevice]?) -> Void)? = nil) {
        queue.async {
            try? write(store)
            if let landed { landed(try? store.all()) }
        }
    }

    /// Run `body` on the lane, blocking the caller until every write enqueued before it has landed. For the
    /// rare identity mutations whose result must include the hot-path writes issued before them. Never call
    /// it from inside a lane block: the lane would wait on itself.
    static func afterQueuedWrites<T>(_ body: () throws -> T) rethrows -> T {
        try queue.sync(execute: body)
    }
}
