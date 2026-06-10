import Foundation
import GRDB

/// A read-only, structured snapshot of the on-device store — row counts, timestamp ranges,
/// sync cursors, distinct event kinds, and the latest strap-clock correlation. Built for remote
/// troubleshooting: a user exports it from the Live screen and shares it, so a "no strain / no
/// recovery / no stress" report can be diagnosed without physical access to the device.
///
/// Everything here is an aggregate (COUNT/MIN/MAX/GROUP BY) — no raw biometric samples leave the
/// device, so the snapshot is safe to share. `Codable` so it round-trips to JSON verbatim.
public struct StoreDiagnostics: Codable, Sendable {
    /// One ts-keyed stream table: how many rows, and the unix-second span they cover. A frozen
    /// strap RTC shows up here as a `minTs == maxTs` (or a span stuck months in the past).
    public struct TableStat: Codable, Sendable {
        public let name: String
        public let count: Int
        public let minTs: Int?
        public let maxTs: Int?
    }
    /// One day-keyed cache table (dailyMetric / appleDaily / metricSeries): row count + day span.
    public struct DayStat: Codable, Sendable {
        public let name: String
        public let count: Int
        public let minDay: String?
        public let maxDay: String?
    }
    /// Per-deviceId breakdown for a stream — surfaces rows landing under an unexpected id
    /// (strap id vs the `<id>-noop` computed id vs `apple-health`).
    public struct PerDeviceStat: Codable, Sendable {
        public let deviceId: String
        public let count: Int
        public let minTs: Int?
        public let maxTs: Int?
    }
    public struct KindCount: Codable, Sendable {
        public let kind: String
        public let count: Int
    }
    public struct NameValue: Codable, Sendable {
        public let name: String
        public let value: Int
    }
    public struct DeviceRow: Codable, Sendable {
        public let id: String
        public let name: String?
        public let firstSeen: Int?
        public let lastSeen: Int?
    }
    /// Latest strap↔phone clock correlation (from the newest rawBatch). `offsetSec = wall - device`:
    /// a large positive value means the strap RTC is running far behind real time (deep-discharge /
    /// frozen RTC). nil when raw retention is off / the outbox has been drained.
    public struct ClockRefStat: Codable, Sendable {
        public let capturedAt: Int
        public let deviceClockRef: Int
        public let wallClockRef: Int
        public let offsetSec: Int
    }
    /// A recent dailyMetric row — shows whether the score columns the dashboard reads are nil.
    public struct DailyRow: Codable, Sendable {
        public let deviceId: String
        public let day: String
        public let recovery: Double?
        public let strain: Double?
        public let avgHrv: Double?
        public let restingHr: Int?
    }

    public let schemaVersion: Int
    public let tsTables: [TableStat]
    public let dayTables: [DayStat]
    public let hrByDevice: [PerDeviceStat]
    public let rrByDevice: [PerDeviceStat]
    public let eventKinds: [KindCount]
    public let cursors: [NameValue]
    public let devices: [DeviceRow]
    public let rawBatchCount: Int
    public let rawBytes: Int
    public let latestClockRef: ClockRefStat?
    public let recentDailyMetrics: [DailyRow]
}

extension WhoopStore {
    /// Gather a `StoreDiagnostics` snapshot. One serial read on the actor's executor (off main).
    public func diagnosticsSnapshot() async throws -> StoreDiagnostics {
        try syncRead { db in
            func tsStat(_ table: String, tsCol: String = "ts") throws -> StoreDiagnostics.TableStat {
                let c = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
                let mn = try Int.fetchOne(db, sql: "SELECT MIN(\(tsCol)) FROM \(table)")
                let mx = try Int.fetchOne(db, sql: "SELECT MAX(\(tsCol)) FROM \(table)")
                return .init(name: table, count: c, minTs: mn, maxTs: mx)
            }
            let tsTables = try [
                tsStat("hrSample"), tsStat("rrInterval"), tsStat("event"), tsStat("battery"),
                tsStat("spo2Sample"), tsStat("skinTempSample"), tsStat("respSample"),
                tsStat("gravitySample"), tsStat("stepSample"),
                tsStat("sleepSession", tsCol: "startTs"),
            ]

            func dayStat(_ table: String) throws -> StoreDiagnostics.DayStat {
                let c = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
                let mn = try String.fetchOne(db, sql: "SELECT MIN(day) FROM \(table)")
                let mx = try String.fetchOne(db, sql: "SELECT MAX(day) FROM \(table)")
                return .init(name: table, count: c, minDay: mn, maxDay: mx)
            }
            let dayTables = try [dayStat("dailyMetric"), dayStat("appleDaily"), dayStat("metricSeries")]

            func perDevice(_ table: String) throws -> [StoreDiagnostics.PerDeviceStat] {
                try Row.fetchAll(db, sql: """
                    SELECT deviceId, COUNT(*) AS c, MIN(ts) AS mn, MAX(ts) AS mx
                    FROM \(table) GROUP BY deviceId ORDER BY c DESC
                    """).map { .init(deviceId: $0["deviceId"], count: $0["c"], minTs: $0["mn"], maxTs: $0["mx"]) }
            }
            let hrByDevice = try perDevice("hrSample")
            let rrByDevice = try perDevice("rrInterval")

            let eventKinds = try Row.fetchAll(db, sql: """
                SELECT kind, COUNT(*) AS c FROM event GROUP BY kind ORDER BY c DESC LIMIT 40
                """).map { StoreDiagnostics.KindCount(kind: $0["kind"], count: $0["c"]) }

            let cursors = try Row.fetchAll(db, sql: "SELECT name, value FROM cursors ORDER BY name")
                .map { StoreDiagnostics.NameValue(name: $0["name"], value: $0["value"] ?? 0) }

            let devices = try Row.fetchAll(db, sql: """
                SELECT id, name, firstSeen, lastSeen FROM device ORDER BY lastSeen DESC
                """).map { StoreDiagnostics.DeviceRow(id: $0["id"], name: $0["name"],
                                                      firstSeen: $0["firstSeen"], lastSeen: $0["lastSeen"]) }

            let rawBatchCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawBatch") ?? 0
            let rawBytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(byteSize), 0) FROM rawBatch") ?? 0

            let clock: StoreDiagnostics.ClockRefStat? = try Row.fetchOne(db, sql: """
                SELECT capturedAt, deviceClockRef, wallClockRef FROM rawBatch
                ORDER BY capturedAt DESC LIMIT 1
                """).map { row in
                    let dev: Int = row["deviceClockRef"]
                    let wall: Int = row["wallClockRef"]
                    return .init(capturedAt: row["capturedAt"], deviceClockRef: dev,
                                 wallClockRef: wall, offsetSec: wall - dev)
                }

            let recentDaily = try Row.fetchAll(db, sql: """
                SELECT deviceId, day, recovery, strain, avgHrv, restingHr
                FROM dailyMetric ORDER BY day DESC LIMIT 14
                """).map { StoreDiagnostics.DailyRow(deviceId: $0["deviceId"], day: $0["day"],
                                                     recovery: $0["recovery"], strain: $0["strain"],
                                                     avgHrv: $0["avgHrv"], restingHr: $0["restingHr"]) }

            return StoreDiagnostics(
                schemaVersion: WhoopStoreInfo.schemaVersion,
                tsTables: tsTables, dayTables: dayTables,
                hrByDevice: hrByDevice, rrByDevice: rrByDevice,
                eventKinds: eventKinds, cursors: cursors, devices: devices,
                rawBatchCount: rawBatchCount, rawBytes: rawBytes,
                latestClockRef: clock, recentDailyMetrics: recentDaily)
        }
    }
}
