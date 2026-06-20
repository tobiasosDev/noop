import XCTest
@testable import Strand

/// Pins the WHOOP 4.0 / Gen4 SET_ALARM_TIME (cmd 66) payload layout (#428 alarm fix).
///
/// Root cause of the never-firing wrist alarm: NOOP used to send a 7-byte body
/// `[0x01][epoch u32 LE][0x00,0x00]`. The strap ACKed it but never buzzed (no
/// STRAP_DRIVEN_ALARM_EXECUTED) because the 2-byte-short body under-runs the firmware's 9-byte
/// alarm struct, so the schedule was dropped after the ack.
///
/// The correct Gen4 body is 9 bytes — `[0x01][epoch u32 LE][0x00,0x00,0x00,0x00]` — i.e. FOUR
/// trailing zero pad bytes, not two. Source: openwhoop (bWanShiTong/openwhoop,
/// `packet_implementations.rs::alarm_time` → `Gen4: [rev=0x01][unix:4][padding:4]`), which arms a
/// real WHOOP 4.0 from the CLI. The 20-byte waveform form is WHOOP 5/MG (Gen5), NOT 4.0.
final class SetAlarmPayloadTests: XCTestCase {

    // Length MUST be exactly 9. A 7-byte body is the bug that left the alarm un-scheduled.
    func testGen4PayloadLengthIsNine() {
        let p = WhoopCommand.setAlarmPayload(epochSec: 0x11223344)
        XCTAssertEqual(p.count, 9, "Gen4 alarm body must be 9 bytes (rev + u32 epoch + 4 pad)")
    }

    // Byte layout: [rev=0x01][epoch u32 LE][0,0,0,0].
    func testGen4PayloadLayout() {
        let p = WhoopCommand.setAlarmPayload(epochSec: 0x11223344)
        XCTAssertEqual(p[0], 0x01, "leading revision/form byte")
        XCTAssertEqual(Array(p[1..<5]), [0x44, 0x33, 0x22, 0x11], "epoch u32 LE")
        XCTAssertEqual(Array(p[5..<9]), [0x00, 0x00, 0x00, 0x00], "four fixed zero pad bytes (NOT two)")
    }

    // A realistic wake epoch round-trips through the little-endian encoder unchanged.
    func testGen4PayloadEpochRoundTrips() {
        let epoch: UInt32 = 1_700_000_000
        let p = WhoopCommand.setAlarmPayload(epochSec: epoch)
        let decoded = UInt32(p[1]) | (UInt32(p[2]) << 8) | (UInt32(p[3]) << 16) | (UInt32(p[4]) << 24)
        XCTAssertEqual(decoded, epoch)
    }
}
