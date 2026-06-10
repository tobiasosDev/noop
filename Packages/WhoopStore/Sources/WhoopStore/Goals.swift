import Foundation
import GRDB

/// A user goal row (v11). NULL archivedAt = active. Max one active goal per kind
/// is enforced by saveGoal (archives the previous one), not by a constraint.
public struct GoalRow: Equatable, Codable, Sendable {
    public let id: Int64
    public let kind: String
    public let target: Double
    public let createdAt: Int
    public let archivedAt: Int?

    public init(id: Int64, kind: String, target: Double, createdAt: Int, archivedAt: Int?) {
        self.id = id; self.kind = kind; self.target = target
        self.createdAt = createdAt; self.archivedAt = archivedAt
    }
}

extension WhoopStore {

    /// Active goals (archivedAt IS NULL), newest first.
    public func activeGoals() async throws -> [GoalRow] {
        try syncRead { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, kind, target, createdAt, archivedAt
                FROM goal WHERE archivedAt IS NULL ORDER BY createdAt DESC, id DESC
                """)
            return rows.map {
                GoalRow(id: $0["id"], kind: $0["kind"], target: $0["target"],
                        createdAt: $0["createdAt"], archivedAt: $0["archivedAt"])
            }
        }
    }

    /// Insert a goal, archiving any existing active goal of the same kind first.
    @discardableResult
    public func saveGoal(kind: String, target: Double, now: Int) async throws -> Int64 {
        try syncWrite { db in
            try db.execute(sql: "UPDATE goal SET archivedAt = ? WHERE kind = ? AND archivedAt IS NULL",
                           arguments: [now, kind])
            try db.execute(sql: "INSERT INTO goal (kind, target, createdAt) VALUES (?, ?, ?)",
                           arguments: [kind, target, now])
            return db.lastInsertedRowID
        }
    }

    /// Soft-delete: stamp archivedAt so history is preserved.
    public func archiveGoal(id: Int64, now: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: "UPDATE goal SET archivedAt = ? WHERE id = ?",
                           arguments: [now, id])
        }
    }
}
