import XCTest
@testable import Strand

/// Pins the GET_ALARM_TIME (cmd 67) read-back parser that verifies the strap actually STORED the wake
/// epoch NOOP armed — the confirm that ends the silent "armed but never fired" failure.
final class AlarmReadbackTests: XCTestCase {
    /// Build a synthetic WHOOP4 GET_ALARM_TIME COMMAND_RESPONSE:
    /// [0xAA][len u16 LE][crc8][type=35][seq][cmd=67][origin_seq][result=01][enabled][epoch u32 LE][subsec u16][04 00 20][crc32]
    private func frame(epoch: UInt32, enabled: UInt8 = 1) -> [UInt8] {
        var f: [UInt8] = [0xAA, 0x00, 0x00, 0x00, 35, 0x01, 67, 0x01, 0x01, enabled]
        f += [UInt8(epoch & 0xFF), UInt8((epoch >> 8) & 0xFF),
              UInt8((epoch >> 16) & 0xFF), UInt8((epoch >> 24) & 0xFF)]
        f += [0x00, 0x00, 0x04, 0x00, 0x20, 0xDE, 0xAD, 0xBE, 0xEF]
        return f
    }

    func testReadbackDecodesStoredEpoch() {
        let r = FrameRouter.alarmReadback(in: frame(epoch: 1_781_792_400))
        XCTAssertEqual(r?.epoch, 1_781_792_400)
        XCTAssertEqual(r?.enabled, true)
    }

    func testReadbackZeroEpochMeansNotStored() {
        let r = FrameRouter.alarmReadback(in: frame(epoch: 0, enabled: 0))
        XCTAssertEqual(r?.epoch, 0)
        XCTAssertEqual(r?.enabled, false)
    }

    func testReadbackTooShortIsNil() {
        XCTAssertNil(FrameRouter.alarmReadback(in: [0xAA, 0x00, 0x00, 0x00, 35]))
    }

    func testFrameContainsArmedEpochConfirms() {
        let epoch: UInt32 = 1_781_792_400
        XCTAssertTrue(FrameRouter.frameContainsEpoch(frame(epoch: epoch), epoch),
                      "the armed epoch's LE bytes appear in the strap reply → confirmed stored")
    }

    func testFrameDoesNotContainWrongEpoch() {
        XCTAssertFalse(FrameRouter.frameContainsEpoch(frame(epoch: 1_781_792_400), 1_700_000_000))
    }

    func testZeroEpochNeverConfirms() {
        // An unstored/disabled alarm reads back all-zero; epoch 0 must never count as confirmation.
        XCTAssertFalse(FrameRouter.frameContainsEpoch(frame(epoch: 0, enabled: 0), 0))
    }
}
