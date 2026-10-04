import XCTest
@testable import Strand
import WhoopProtocol

/// `Backfiller.classifyOffloadFrame` skips the full parse for every frame the type peek does not name
/// METADATA. Before, each offload record was fully decoded on the main actor only to be classified
/// `.other` and thrown away (main-thread hitch); the records are decoded off the main actor at chunk end.
///
/// The shortcut must classify exactly as the full parse does, so every case is checked against
/// `classifyHistoricalMeta(parseFrame(_:family:))`, for both families: history start/end/complete,
/// real records, every packet type, every truncation, and single-byte damage at every position (which
/// covers forged METADATA, frames that only become METADATA through the type byte, and broken checksums).
final class BackfillerClassifyOffloadFrameTests: XCTestCase {

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    /// The HISTORY_END body: unix, two pad bytes, a u32, then the trim cursor.
    private var metaBody: [UInt8] { le32(1_780_930_000) + [0, 0] + le32(0) + le32(70_476) }

    /// Real WHOOP 4.0 v24 record (Whoop4HistoricalV24HardwareTests).
    private let whoop4RecordHex =
        "aa6400a12f18054c1c0a023ed0266a5037805418016d022b0234020000000000006b07ff00" +
        "85593c1f65cebed7b3e63eb85a5f3f000080401f65cebed7b3e63eb85a5f3f500264025d03" +
        "640229014009010c020c00000000000f0001c4020000000000008fdeb278"
    /// Real WHOOP 5.0 puffin METADATA (type 56) and REALTIME_DATA frames (FastPathParityTests).
    private let whoop5MetadataHex = "aa010c000001e741380300abcd00000060153281"
    private let whoop5RealtimeHex = "aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc"

    private var whoop4Bases: [[UInt8]] {
        [frameFromPayload(metaBody, type: 49, seq: 0, cmd: 1),
         frameFromPayload(metaBody, type: 49, seq: 7, cmd: 2),
         frameFromPayload(metaBody, type: 49, seq: 0, cmd: 3),
         frameFromPayload(metaBody, type: 49, seq: 0, cmd: 9),
         frameFromPayload(Array("BLE: History burst success".utf8), type: 50, seq: 0, cmd: 0),
         bytes(whoop4RecordHex)]
    }

    /// The puffin METADATA alias (56) is named METADATA by both the peek and the parse, but has no schema
    /// fields, so it classifies `.other` either way; it is kept for exactly that agreement.
    private var whoop5Bases: [[UInt8]] {
        [puffinCommandFrame(cmd: 1, seq: 0, payload: metaBody, type: 49),
         puffinCommandFrame(cmd: 2, seq: 3, payload: metaBody, type: 49),
         puffinCommandFrame(cmd: 3, seq: 0, payload: metaBody, type: 49),
         puffinCommandFrame(cmd: 2, seq: 0, payload: metaBody, type: 56),
         bytes(whoop5MetadataHex),
         bytes(whoop5RealtimeHex)]
    }

    private func assertSameAsFullParse(_ frames: [[UInt8]], _ family: DeviceFamily,
                                       file: StaticString = #filePath, line: UInt = #line) -> Int {
        var mismatches: [String] = []
        for frame in frames {
            let expected = classifyHistoricalMeta(parseFrame(frame, family: family))
            let actual = Backfiller.classifyOffloadFrame(frame, family: family)
            if actual != expected {
                mismatches.append("\(frame.map { String(format: "%02x", $0) }.joined()): "
                                  + "full parse \(expected), shortcut \(actual)")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "\(family): " + mismatches.prefix(10).joined(separator: "\n"),
                      file: file, line: line)
        return frames.count
    }

    /// Precondition: the built frames really are the start / end / complete the test claims to cover.
    func testTheBuiltMetadataFramesClassifyAsHistoryMarkers() {
        for (family, bases) in [(DeviceFamily.whoop4, whoop4Bases), (.whoop5, whoop5Bases)] {
            let kinds = bases.prefix(3).map { frame -> String in
                switch classifyHistoricalMeta(parseFrame(frame, family: family)) {
                case .start: return "start"
                case .end: return "end"
                case .complete: return "complete"
                case .other: return "other"
                }
            }
            XCTAssertEqual(kinds, ["start", "end", "complete"], "\(family)")
        }
    }

    func testEveryPacketTypeClassifiesAsTheFullParseDoes() {
        for type in 0...255 {
            let t = UInt8(type)
            _ = assertSameAsFullParse([frameFromPayload(metaBody, type: t, seq: 0, cmd: 2),
                                       frameFromPayload(metaBody, type: t, seq: 0, cmd: 3)], .whoop4)
            _ = assertSameAsFullParse([puffinCommandFrame(cmd: 2, seq: 0, payload: metaBody, type: t),
                                       puffinCommandFrame(cmd: 1, seq: 0, payload: metaBody, type: t)], .whoop5)
        }
    }

    func testEveryTruncationClassifiesAsTheFullParseDoes() {
        for (family, bases) in [(DeviceFamily.whoop4, whoop4Bases), (.whoop5, whoop5Bases)] {
            for base in bases {
                _ = assertSameAsFullParse((0...base.count).map { Array(base.prefix($0)) }, family)
            }
        }
    }

    /// One damaged byte at every position, both families, every base frame, the frame type among them.
    func testSingleByteDamageClassifiesAsTheFullParseDoes() {
        var checked = 0
        for (family, bases) in [(DeviceFamily.whoop4, whoop4Bases), (.whoop5, whoop5Bases)] {
            for base in bases {
                var variants: [[UInt8]] = []
                for i in base.indices {
                    for mutate in [{ (b: UInt8) in b ^ 0x01 }, { $0 ^ 0x80 }, { $0 ^ 0xFF },
                                   { _ in 47 }, { _ in 49 }, { _ in 56 }, { _ in 0xAA }] {
                        var f = base
                        f[i] = mutate(f[i])
                        variants.append(f)
                    }
                }
                checked += assertSameAsFullParse(variants, family)
            }
        }
        XCTAssertGreaterThan(checked, 2_000)
    }
}
