import XCTest
import WhoopStore
@testable import Strand

/// Pins `Repository.dedupBlocks` to the O(n²) scan it replaced (main-thread hitch round).
///
/// The rewrite looks kept blocks up by onset bucket instead of testing every one. `oldDedupBlocks` below is a
/// VERBATIM copy of the replaced implementation and is the oracle: every generated input must produce the
/// identical kept list, in the identical order.
final class DedupBlocksEquivalenceTests: XCTestCase {

    /// The implementation `dedupBlocks` had before the bucket index, copied verbatim.
    private static func oldDedupBlocks(_ blocks: [CachedSleepSession]) -> [CachedSleepSession] {
        var seen = Set<[Int]>()
        var out: [CachedSleepSession] = []
        for b in blocks {
            let key = [b.startTs, b.endTs]
            guard seen.insert(key).inserted else { continue }
            let overlapsOtherSource = out.contains { kept in
                guard let source = b.deviceId, let keptSource = kept.deviceId,
                      source != keptSource else { return false }
                let start = max(b.effectiveStartTs, kept.effectiveStartTs)
                let end = min(b.endTs, kept.endTs)
                let bDuration = b.endTs - b.effectiveStartTs
                let keptDuration = kept.endTs - kept.effectiveStartTs
                let overlap = end - start
                return bDuration > 0 && keptDuration > 0 &&
                    overlap > bDuration / 2 && overlap > keptDuration / 2
            }
            if !overlapsOtherSource { out.append(b) }
        }
        return out
    }

    private static func block(_ source: String?, _ start: Int, _ end: Int,
                              adjusted: Int? = nil) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: end, efficiency: nil, restingHr: nil, avgHrv: nil,
                           stagesJSON: nil, startTsAdjusted: adjusted, deviceId: source)
    }

    private func assertSame(_ input: [CachedSleepSession], _ label: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Repository.dedupBlocks(input), Self.oldDedupBlocks(input), label, file: file, line: line)
    }

    func testHandPickedShapesMatchTheOldScan() {
        let t = 1_700_000_000
        let cases: [(String, [CachedSleepSession])] = [
            ("empty", []),
            ("single", [Self.block("a", t, t + 28_800)]),
            ("twin across sources, active first", [Self.block("a", t, t + 38_400),
                                                     Self.block("b", t + 574, t + 37_976)]),
            ("same source split stays", [Self.block("a", t, t + 20_000), Self.block("a", t + 1_000, t + 19_000)]),
            ("nap inside a night survives", [Self.block("a", t, t + 36_000), Self.block("b", t + 10_000, t + 13_600)]),
            ("equal bounds, different sources: first wins by key", [Self.block("a", t, t + 3_600),
                                                                     Self.block("b", t, t + 3_600)]),
            ("nil source never collapses", [Self.block(nil, t, t + 3_600), Self.block("b", t + 10, t + 3_590),
                                            Self.block(nil, t + 20, t + 3_580)]),
            ("zero and negative spans", [Self.block("a", t, t), Self.block("b", t, t),
                                         Self.block("a", t + 100, t + 50), Self.block("b", t + 60, t + 90)]),
            ("adjusted onset moves the span", [Self.block("a", t, t + 30_000, adjusted: t + 20_000),
                                               Self.block("b", t + 19_000, t + 30_500)]),
            ("adjusted onset after the end", [Self.block("a", t, t + 3_600, adjusted: t + 7_200),
                                              Self.block("b", t, t + 3_600)]),
            ("exact half overlap does not collapse", [Self.block("a", t, t + 100), Self.block("b", t + 50, t + 150)]),
            ("one second past half collapses", [Self.block("a", t, t + 100), Self.block("b", t + 49, t + 149)]),
            ("long kept, short later block", [Self.block("a", t, t + 7_201), Self.block("b", t, t + 3_600)]),
            ("short kept, long later block", [Self.block("a", t, t + 3_600), Self.block("b", t, t + 7_199)]),
            ("negative timestamps", [Self.block("a", -90_000, -60_000), Self.block("b", -89_000, -61_000)]),
            ("straddles a bucket edge", [Self.block("a", 86_390, 86_410), Self.block("b", 86_395, 86_412)]),
            ("huge span forces the wide window", [Self.block("a", 0, 4_000_000_000),
                                                  Self.block("b", 1, 3_999_999_999),
                                                  Self.block("c", t, t + 60)]),
        ]
        for (label, input) in cases { assertSame(input, label) }
    }

    func testGeneratedInputsMatchTheOldScan() {
        var rng = SplitMix64(seed: 0x5EED_B10C)
        let sources: [String?] = ["oura-ring", "my-whoop", "whoop-2", "my-whoop-noop", nil]
        let spans = [0, -60, 1, 2, 3, 60, 1_800, 3_600, 7_200, 20_000, 28_800, 38_400, 43_200, 200_000]
        let jitters = [0, 0, 0, 1, 30, 574, -600, 3_599, 86_399]
        let t0 = 1_700_000_000
        for iteration in 0..<4_000 {
            let n = Int.random(in: 0...48, using: &rng)
            var blocks: [CachedSleepSession] = []
            for _ in 0..<n {
                let roll = Int.random(in: 0..<10, using: &rng)
                if roll == 0, let prev = blocks.randomElement(using: &rng) {
                    // Exact bounds of an earlier block under another (or the same) source.
                    blocks.append(Self.block(sources.randomElement(using: &rng)!, prev.startTs, prev.endTs,
                                             adjusted: prev.startTsAdjusted))
                    continue
                }
                if roll == 1, let prev = blocks.randomElement(using: &rng), prev.endTs > prev.startTs + 2 {
                    // Nested inside an earlier block.
                    let a = Int.random(in: prev.startTs..<(prev.endTs - 1), using: &rng)
                    let b = Int.random(in: (a + 1)...prev.endTs, using: &rng)
                    blocks.append(Self.block(sources.randomElement(using: &rng)!, a, b))
                    continue
                }
                let start = t0 + Int.random(in: 0..<14, using: &rng) * 3_600
                    + jitters.randomElement(using: &rng)!
                let end = start + spans.randomElement(using: &rng)!
                let adjusted: Int?
                switch Int.random(in: 0..<6, using: &rng) {
                case 0: adjusted = start + [-1_800, 600, 50_000, 0].randomElement(using: &rng)!
                default: adjusted = nil
                }
                blocks.append(Self.block(sources.randomElement(using: &rng)!, start, end, adjusted: adjusted))
            }
            if iteration % 3 == 0 { blocks.shuffle(using: &rng) }
            assertSame(blocks, "generated #\(iteration)")
        }
    }

    /// A realistic multi-year union of two raw ids: one night per day under each, small bound jitter,
    /// occasional naps and edited onsets. This is the shape the 4000-day refresh feeds it.
    func testLongTwoSourceHistoryMatchesTheOldScan() {
        var rng = SplitMix64(seed: 0xD0D0_2024)
        let t0 = 1_600_000_000
        var active: [CachedSleepSession] = []
        var canonical: [CachedSleepSession] = []
        for day in 0..<900 {
            let bed = t0 + day * 86_400 + Int.random(in: -7_200...7_200, using: &rng)
            let wake = bed + Int.random(in: 14_400...36_000, using: &rng)
            if Int.random(in: 0..<10, using: &rng) > 0 {
                let adjusted = Int.random(in: 0..<15, using: &rng) == 0 ? bed + 900 : nil
                active.append(Self.block("whoop-new", bed, wake, adjusted: adjusted))
            }
            if Int.random(in: 0..<10, using: &rng) > 1 {
                canonical.append(Self.block("my-whoop", bed + Int.random(in: -900...900, using: &rng),
                                            wake + Int.random(in: -900...900, using: &rng)))
            }
            if Int.random(in: 0..<6, using: &rng) == 0 {
                let napStart = wake + Int.random(in: 14_400...28_800, using: &rng)
                canonical.append(Self.block("my-whoop", napStart, napStart + Int.random(in: 900...5_400, using: &rng)))
            }
        }
        assertSame(active + canonical, "active then canonical")
        assertSame(canonical + active, "canonical then active")
    }
}

/// Small, seedable, deterministic generator so a failing case reproduces exactly.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
