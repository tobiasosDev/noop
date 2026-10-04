import Foundation

/// Walks an observer cursor with bounded replies, retaining only the affected date range.
/// A failed page throws away the candidate cursor so callers cannot commit a partial traversal.
enum HealthObserverPager {
    static let pageSize = 500

    static func bootstrapCutoff(now: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -31, to: calendar.startOfDay(for: now))!
    }

    struct Page<Anchor> {
        let oldest: Date?
        let sampleCount: Int
        let deletedCount: Int
        let anchor: Anchor
    }

    struct Window<Anchor> {
        let oldest: Date?
        let hasDeletions: Bool
        let anchor: Anchor
    }

    static func scan<Anchor>(
        from prior: Anchor?,
        fetch: (Anchor?, Int) async throws -> Page<Anchor>
    ) async throws -> Window<Anchor> {
        var cursor = prior
        var oldest: Date?
        var hasDeletions = false
        while true {
            try Task.checkCancellation()
            let page = try await fetch(cursor, pageSize)
            if let date = page.oldest { oldest = min(oldest ?? date, date) }
            hasDeletions = hasDeletions || page.deletedCount > 0
            cursor = page.anchor
            // An empty page is definitive even when HealthKit returns a short nonterminal reply.
            if page.sampleCount == 0 && page.deletedCount == 0 {
                return Window(oldest: oldest, hasDeletions: hasDeletions, anchor: page.anchor)
            }
        }
    }
}

/// Actor-confined delivery queue. A batch takes only the completions it owns; a new wake during an
/// awaited query stays in the next batch and cannot be acknowledged by the earlier read.
struct HealthObserverDeliveryQueue<Payload> {
    struct Delivery {
        let payload: Payload
        var completions: [() -> Void]
    }

    private var pending: [String: Delivery] = [:]
    private var draining = false

    mutating func enqueue(id: String, payload: Payload, completion: @escaping () -> Void) -> Bool {
        if pending[id] != nil {
            pending[id]?.completions.append(completion)
        } else {
            pending[id] = Delivery(payload: payload, completions: [completion])
        }
        guard !draining else { return false }
        draining = true
        return true
    }

    mutating func nextBatch() -> [Delivery]? {
        guard !pending.isEmpty else {
            draining = false
            return nil
        }
        let batch = Array(pending.values)
        pending.removeAll()
        return batch
    }
}
