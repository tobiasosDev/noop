import XCTest
@testable import Strand
import WhoopProtocol
import WhoopStore

/// Everything an offload session says and stores, pinned as one transcript.
///
/// `finishChunk` reads the parsed records for its diagnostics: the per-chunk clock line, the layout
/// lines, the SpO2 RE dump, the #891 dump and the R-R census. Those reads, and the freeing of the parsed
/// records, moved off the main actor with the decode (main-thread hitch), and the per-frame classify
/// stopped parsing data records (`classifyOffloadFrame`). None of it may change a byte, so the expected
/// transcript below is the output of the Backfiller as it was BEFORE that change, captured by running
/// this test against it: log and Connection-mode lines, layouts, chunk outcomes, inserted rows, acks and
/// the session tallies, over two sessions and chunks that carry decodable, unmapped-layout, unmapped-type
/// and console records.
@MainActor
final class BackfillerChunkTranscriptTests: XCTestCase {

    private final class RecordingStore: BackfillStoreWriting {
        var transcript: (String) -> Void = { _ in }
        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            transcript("insert \(deviceId) hr=\(streams.hr.map { "\($0.ts):\($0.bpm)" })"
                       + " rr=\(streams.rr.map { "\($0.ts):\($0.rrMs)" }) gravity=\(streams.gravity.count)"
                       + " spo2=\(streams.spo2.count) skinTemp=\(streams.skinTemp.count) resp=\(streams.resp.count)"
                       + " events=\(streams.events.count) battery=\(streams.battery.count)")
            // An ON CONFLICT key that absorbed one R-R row, so `inserted` and `offered` differ.
            return (streams.hr.count, max(0, streams.rr.count - 1), streams.events.count, streams.battery.count,
                    streams.spo2.count, streams.skinTemp.count, streams.resp.count, streams.gravity.count)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
        func setCursor(_ name: String, _ value: Int) async throws { transcript("cursor \(name)=\(value)") }
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// The real WHOOP 4.0 v24 record of `Whoop4HistoricalV24HardwareTests`, as [type, seq, cmd] + body.
    private let realRecord: [UInt8] = {
        let hex = "aa6400a12f18054c1c0a023ed0266a5037805418016d022b0234020000000000006b07ff00" +
            "85593c1f65cebed7b3e63eb85a5f3f000080401f65cebed7b3e63eb85a5f3f500264025d03" +
            "640229014009010c020c00000000000f0001c4020000000000008fdeb278"
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }()

    /// The real record re-stamped and re-framed: its own unix, heart rate and two R-R intervals, and
    /// optionally another layout version. The CRC is rebuilt, so the frame stays intact.
    private func record(unix: UInt32, hr: UInt8, rr: (UInt16, UInt16), version: UInt8 = 24) -> [UInt8] {
        var body = Array(realRecord[7..<(realRecord.count - 4)])
        body.replaceSubrange(4..<8, with: le32(unix))
        body[14] = hr
        body[16] = UInt8(rr.0 & 0xFF); body[17] = UInt8(rr.0 >> 8)
        body[18] = UInt8(rr.1 & 0xFF); body[19] = UInt8(rr.1 >> 8)
        return frameFromPayload(body, type: 47, seq: version, cmd: realRecord[6])
    }

    private func meta(_ cmd: UInt8, unix: UInt32 = 1_780_930_000, trim: UInt32 = 0) -> [UInt8] {
        frameFromPayload(le32(unix) + [0, 0] + le32(0) + le32(trim), type: 49, seq: 0, cmd: cmd)
    }

    private func console(_ text: String) -> [UInt8] {
        frameFromPayload([0, 0, 0, 0, 0] + Array(text.utf8), type: 50, seq: 0, cmd: 0)
    }

    func testAnOffloadSessionSaysAndStoresExactlyWhatItDidBefore() async {
        var lines: [String] = []
        let store = RecordingStore()
        store.transcript = { lines.append($0) }
        let backfiller = Backfiller(
            store: store, deviceId: "my-whoop",
            ackTrim: { trim, endData in lines.append("ack \(trim) \(endData)") },
            onBankedOffload: { lines.append("banked \($0)") },
            log: { lines.append("log \($0)") },
            onChunk: { decoded, console in lines.append("chunk decoded=\(decoded) console=\(console)") },
            connectionActive: { true },
            connectionLog: { lines.append("conn \($0)") },
            firmwareLayout: { lines.append("layout \($0)") })
        backfiller.clockRef = ClockRef(device: 1_780_900_000, wall: 1_780_900_120)

        let t0: UInt32 = 1_780_928_574
        let sessions: [[[UInt8]]] = [
            [meta(1),
             record(unix: t0, hr: 109, rr: (555, 564)),
             record(unix: t0 + 1, hr: 110, rr: (548, 0)),
             record(unix: t0 + 1, hr: 110, rr: (551, 553)),
             console("BLE: History burst success. Trim: 0x00000011:000047d8"),
             record(unix: t0 + 4, hr: 0, rr: (0, 0), version: 99),
             record(unix: t0 + 5, hr: 112, rr: (530, 541)),
             meta(2, unix: t0 + 5, trim: 70_476),
             record(unix: t0 + 86_400, hr: 64, rr: (930, 0)),
             frameFromPayload([1, 2, 3, 4, 5, 6, 7, 8], type: 52, seq: 0, cmd: 0),
             record(unix: t0 + 86_402, hr: 65, rr: (925, 921)),
             frameFromPayload([9, 8, 7, 6], type: 52, seq: 1, cmd: 0),
             meta(2, unix: t0 + 86_402, trim: 70_477),
             console("BLE: PullStats: Data: 660, Events: 118"),
             meta(2, unix: t0 + 86_402, trim: 70_478),
             meta(2, unix: t0 + 86_402, trim: 0xFFFF_FFFF),
             meta(3)],
            [meta(1),
             record(unix: t0 + 200_000, hr: 70, rr: (850, 860)),
             record(unix: t0 + 200_003, hr: 0, rr: (0, 0), version: 99),
             meta(2, unix: t0 + 200_003, trim: 70_480),
             meta(3)],
        ]
        for (n, frames) in sessions.enumerated() {
            lines.append("== session \(n + 1)")
            backfiller.begin(family: .whoop4, continuedAfterRows: n > 0)
            for frame in frames { await backfiller.ingest(frame) }
            lines.append("tally rows=\(backfiller.sessionRowsPersisted) motion=\(backfiller.sessionMotionRows)"
                         + " skinTemp=\(backfiller.sessionSkinTempRows) nights=\(backfiller.sessionNightKeys.sorted())"
                         + " dropped=\(backfiller.sessionDroppedImplausible)"
                         + " unhandled=\(backfiller.sessionUnhandledPacketTypes.sorted { $0.key < $1.key })"
                         + " lastAcked=\(String(describing: backfiller.lastAckedTrim))"
                         + " backfilling=\(backfiller.isBackfilling) stalled=\(backfiller.persistStalled)"
                         + " hexBudget=\(backfiller.rejectHexBudget) noCursor=\(backfiller.sawNoFlashCursor)")
            lines.append("rr offered=\(backfiller.sessionRrOffered) inserted=\(backfiller.sessionRrInserted)"
                         + " sumMs=\(backfiller.sessionRrSumMs) span=\(String(describing: backfiller.sessionRrMinTs))"
                         + "…\(String(describing: backfiller.sessionRrMaxTs)) hist=\(backfiller.sessionRrHist)"
                         + " gaps=\(backfiller.sessionRrGapHist) fill=\(backfiller.sessionRrFill)")
            lines.append("rr line \(backfiller.sessionRrEmissionLine() ?? "nil")")
            lines.append("clock line " + (Backfiller.sessionClockDiagLine(
                nightKeys: backfiller.sessionNightKeys, device: backfiller.sessionClockDevice,
                wall: backfiller.sessionClockWall, usedIdentityRef: backfiller.sessionUsedIdentityRef,
                family: backfiller.family) ?? "nil"))
        }

        let actual = lines.joined(separator: "\n")
        XCTAssertEqual(actual, Self.expected, "transcript changed:\n\(actual)")
    }

    private static let expected = """
        == session 1
        log Backfill: hist clock chunk=1 offset=+120s staleGate=closed rr=7 secs=3 pack=2.33 max=3 span=6s dens=1.17
        log Backfill: historical records use layout v24
        layout 24
        conn firmware layout=v24 decodable
        conn spo2re v=24 unix=1780928574 red=592 ir=612 skinRaw=861 len=104 raw=aa6400a12f18054c1c0a023ed0266a5037805418016d022b0234020000000000006b07ff0085593c1f65cebed7b3e63eb85a5f3f000080401f65cebed7b3e63eb85a5f3f500264025d03640229014009010c020c00000000000f0001c4020000000000008fdeb278
        conn spo2re v=24 unix=1780928575 red=592 ir=612 skinRaw=861 len=104 raw=aa6400a12f18054c1c0a023fd0266a5037805418016e02240200000000000000006b07ff0085593c1f65cebed7b3e63eb85a5f3f000080401f65cebed7b3e63eb85a5f3f500264025d03640229014009010c020c00000000000f0001c4020000000000000f5c6c97
        conn spo2re v=24 unix=1780928575 red=592 ir=612 skinRaw=861 len=104 raw=aa6400a12f18054c1c0a023fd0266a5037805418016e02270229020000000000006b07ff0085593c1f65cebed7b3e63eb85a5f3f000080401f65cebed7b3e63eb85a5f3f500264025d03640229014009010c020c00000000000f0001c4020000000000009500f539
        log Historical records use firmware layout v99, which NOOP doesn't decode yet: those records carry no heart rate or motion, so any night made only of them can't be staged from the strap. A strap emitting a mix of layouts still stages the nights it can. Please report this (issue #1992).
        chunk decoded=true console=false
        log Backfill: 1 undecodable sensor record(s) of 6 frame(s) (trim=70476) — archiving raw bytes before ack (CRC/unmapped layout).
        log Backfill: rejected frame[0] 104B: aa6400a12f63054c1c0a0242d0266a5037805418010002000000000000000000006b07ff0085593c1f65cebed7b3e63eb85a5f3f000080401f65cebed7b3e63eb85a5f3f500264025d03640229014009010c020c00000000000f0001c4020000000000006beddad4
        insert my-whoop hr=["1780928574:109", "1780928575:110", "1780928575:110", "1780928579:112"] rr=["1780928574:555", "1780928574:564", "1780928575:548", "1780928575:551", "1780928575:553", "1780928579:530", "1780928579:541"] gravity=4 spo2=4 skinTemp=4 resp=4 events=0 battery=0
        banked (hr: 4, rr: 6, events: 0, battery: 0, spo2: 4, skinTemp: 4, resp: 4, gravity: 4)
        conn offload progress trim=70476 chunkRows=26 sessionRows=26 sessionMotion=4 nights=1
        cursor strap_trim=70476
        ack 70476 [76, 19, 1, 0, 237, 155, 203, 216]
        log Backfill: hist clock chunk=2 offset=+120s staleGate=closed rr=3 secs=2 pack=1.50 max=2 span=3s dens=1.00
        log Backfill: the strap sent 2 record(s) of packet type HISTORICAL_IMU_DATA_STREAM, which this decoder has no rows for — they are being dropped. If HISTORICAL_IMU_DATA_STREAM is not a name you recognise, this is a firmware record type NOOP has never mapped: please report it on #891 with the strap model and firmware build.
        log Backfill: unmapped type HISTORICAL_IMU_DATA_STREAM first frame 19B: aa0f00c33400000102030405060708dededca9
        chunk decoded=true console=false
        insert my-whoop hr=["1781014974:64", "1781014976:65"] rr=["1781014974:930", "1781014976:925", "1781014976:921"] gravity=2 spo2=2 skinTemp=2 resp=2 events=0 battery=0
        banked (hr: 2, rr: 2, events: 0, battery: 0, spo2: 2, skinTemp: 2, resp: 2, gravity: 2)
        conn offload progress trim=70477 chunkRows=12 sessionRows=38 sessionMotion=6 nights=2
        cursor strap_trim=70477
        ack 70477 [77, 19, 1, 0, 185, 101, 92, 177]
        chunk decoded=false console=true
        log Backfill: 1 frame(s) this chunk carried no sensor records (strap console/diagnostic output) — normal, nothing to persist (trim=70478).
        insert my-whoop hr=[] rr=[] gravity=0 spo2=0 skinTemp=0 resp=0 events=0 battery=0
        banked (hr: 0, rr: 0, events: 0, battery: 0, spo2: 0, skinTemp: 0, resp: 0, gravity: 0)
        conn offload progress trim=70478 chunkRows=0 sessionRows=38 sessionMotion=6 nights=2
        cursor strap_trim=70478
        ack 70478 [78, 19, 1, 0, 87, 202, 233, 163]
        log Backfill: reached the end of available history (trim=0xFFFFFFFF) - caught up after persisting 38 row(s) this run. Nothing more to offload.
        conn offload trim=0xFFFFFFFF noCursor (strap has no banked history to offload)
        cursor strap_trim=4294967295
        ack 4294967295 [255, 255, 255, 255, 210, 233, 226, 1]
        tally rows=38 motion=6 skinTemp=6 nights=[20612, 20613] dropped=0 unhandled=[(key: "HISTORICAL_IMU_DATA_STREAM", value: 2)] lastAcked=Optional(4294967295) backfilling=false stalled=false hexBudget=23 noCursor=true
        rr offered=10 inserted=8 sumMs=6618 span=Optional(1780928574)…Optional(1781014976) hist=[1, 3, 1, 0] gaps=[1, 1, 0, 1, 0, 0, 0, 0] fill=[2, 1, 0, 0]
        rr line rr emit path=historical offered=10 inserted=8 secs=5 sumRr=6s span=86403s ratio=0.00 ratioRep=1.32 perSec[1/2/3/4+]=1/3/1/0 modalGap=1s fill[<=1/<=1.5/<=2/>2]=2/1/0/0
        clock line Backfill: rows landed on 2026-06-08…2026-06-09 · clock ref in sync
        == session 2
        log Backfill: hist clock chunk=1 offset=+120s staleGate=closed rr=2 secs=1 pack=2.00 max=2 span=1s dens=2.00
        log Backfill: historical records use layout v24
        layout 24
        conn firmware layout=v24 decodable
        conn spo2re v=24 unix=1781128574 red=592 ir=612 skinRaw=861 len=104 raw=aa6400a12f18054c1c0a027edd296a503780541801460252035c030000000000006b07ff0085593c1f65cebed7b3e63eb85a5f3f000080401f65cebed7b3e63eb85a5f3f500264025d03640229014009010c020c00000000000f0001c40200000000000013508025
        chunk decoded=true console=false
        log Backfill: 1 undecodable sensor record(s) of 2 frame(s) (trim=70480) — archiving raw bytes before ack (CRC/unmapped layout).
        log Backfill: rejected frame[0] 104B: aa6400a12f63054c1c0a0281dd296a5037805418010002000000000000000000006b07ff0085593c1f65cebed7b3e63eb85a5f3f000080401f65cebed7b3e63eb85a5f3f500264025d03640229014009010c020c00000000000f0001c402000000000000d7025e45
        insert my-whoop hr=["1781128574:70"] rr=["1781128574:850", "1781128574:860"] gravity=1 spo2=1 skinTemp=1 resp=1 events=0 battery=0
        banked (hr: 1, rr: 1, events: 0, battery: 0, spo2: 1, skinTemp: 1, resp: 1, gravity: 1)
        conn offload progress trim=70480 chunkRows=6 sessionRows=6 sessionMotion=1 nights=1
        cursor strap_trim=70480
        ack 70480 [80, 19, 1, 0, 123, 80, 24, 212]
        tally rows=6 motion=1 skinTemp=1 nights=[20614] dropped=0 unhandled=[] lastAcked=Optional(70480) backfilling=false stalled=false hexBudget=22 noCursor=false
        rr offered=2 inserted=1 sumMs=1710 span=Optional(1781128574)…Optional(1781128574) hist=[0, 1, 0, 0] gaps=[0, 0, 0, 0, 0, 0, 0, 0] fill=[0, 0, 0, 0]
        rr line rr emit path=historical offered=2 inserted=1 secs=1 sumRr=1s span=1s ratio=1.71 ratioRep=1.71 perSec[1/2/3/4+]=0/1/0/0 modalGap=0s fill[<=1/<=1.5/<=2/>2]=0/0/0/0
        clock line Backfill: rows landed on 2026-06-10 · clock ref in sync
        """
}
