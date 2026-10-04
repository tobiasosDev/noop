import Foundation

/// Compares the values actually exported to Health, retaining no HealthKit objects or persistent cursor.
/// A bridge restart deliberately reconciles the whole window again, including externally deleted data.
enum HeartRateWritebackDelta {
    struct Value: Equatable, Sendable {
        let bpm: Double
        let endTs: Int
    }

    /// Minute starts to replace. Expired cached buckets fall outside the reconciliation window and
    /// must not be mistaken for local deletions. A partial minute's changing end is a real change.
    static func changedRange(previous: [Int: Value]?, current: [Int: Value],
                             window: Range<Int>) -> Range<Int>? {
        guard let previous else { return current.isEmpty ? nil : window }
        let changed = Set(previous.keys).union(current.keys).filter {
            window.contains($0) && previous[$0] != current[$0]
        }
        guard let first = changed.min(), let last = changed.max() else { return nil }
        return first..<min(last + 60, window.upperBound)
    }

    /// Commits export state only after deletion and every save succeed. A failed partial backfill
    /// leaves its cursor unchanged so the next attempt can repair the entire original window.
    @MainActor
    static func replace(sampleCount: Int, chunkSize: Int = 5000,
                        delete: () async throws -> Void,
                        save: (Range<Int>) async throws -> Void,
                        commit: () -> Void) async throws {
        precondition(chunkSize > 0)
        try await delete()
        for start in stride(from: 0, to: sampleCount, by: chunkSize) {
            try await save(start..<min(start + chunkSize, sampleCount))
        }
        commit()
    }

}
