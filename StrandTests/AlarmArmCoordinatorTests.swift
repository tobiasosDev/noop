import XCTest
import Combine
@testable import Strand

@MainActor
final class AlarmArmCoordinatorTests: XCTestCase {

    /// Mock strap driver: records calls and reports a settable connection state.
    final class MockDriver: AlarmArmDriving {
        var isConnected: Bool
        var connectCalled = 0
        var scanCalled = 0
        var armCalled = 0
        var disableCalled = 0
        init(connected: Bool) { isConnected = connected }
        func connect() { connectCalled += 1 }
        func scanForWhoops() { scanCalled += 1 }
        func armStrapAlarm(at date: Date) { armCalled += 1 }
        func disableStrapAlarm() { disableCalled += 1 }
    }

    func testAlreadyConnected_writesThenConfirms() {
        let live = LiveState()
        let driver = MockDriver(connected: true)
        let c = AlarmArmCoordinator(driver: driver, live: live, connectTimeout: 5, confirmTimeout: 5)

        c.arm(wakeDate: Date(timeIntervalSince1970: 1_781_912_880))
        XCTAssertEqual(driver.armCalled, 1, "armed immediately when connected")
        XCTAssertEqual(c.step, .confirming)

        // Strap read-back confirms our epoch.
        live.alarmArmedForEpoch = 1_781_912_880
        live.alarmArmConfirmed = true
        XCTAssertEqual(c.step, .confirmed(epoch: 1_781_912_880))
    }

    func testDisconnected_connectsFirstThenArmsOnLink() {
        let live = LiveState()
        let driver = MockDriver(connected: false)
        let c = AlarmArmCoordinator(driver: driver, live: live, connectTimeout: 5, confirmTimeout: 5)

        c.arm(wakeDate: Date(timeIntervalSince1970: 1_781_912_880))
        XCTAssertEqual(c.step, .connecting)
        XCTAssertEqual(driver.connectCalled, 1)
        XCTAssertEqual(driver.armCalled, 0, "must not write before the link is up")

        // Link comes up → coordinator arms.
        driver.isConnected = true
        live.connected = true
        XCTAssertEqual(driver.armCalled, 1)
        XCTAssertEqual(c.step, .confirming)
    }

    func testReadbackFalse_failsNotStored() {
        let live = LiveState()
        let driver = MockDriver(connected: true)
        let c = AlarmArmCoordinator(driver: driver, live: live, connectTimeout: 5, confirmTimeout: 5)
        c.arm(wakeDate: Date(timeIntervalSince1970: 1_781_912_880))

        live.alarmArmConfirmed = false
        XCTAssertEqual(c.step, .failed(.notStored))
    }

    func testCancel_setsCancelled() {
        let live = LiveState()
        let driver = MockDriver(connected: false)
        let c = AlarmArmCoordinator(driver: driver, live: live, connectTimeout: 5, confirmTimeout: 5)
        c.arm(wakeDate: Date())
        c.cancel()
        XCTAssertEqual(c.step, .failed(.cancelled))
    }

    func testConnectTimeout_failsNoLink() {
        let live = LiveState()
        let driver = MockDriver(connected: false)
        let c = AlarmArmCoordinator(driver: driver, live: live, connectTimeout: 0.2, confirmTimeout: 5)
        c.arm(wakeDate: Date())
        let exp = expectation(description: "no link")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(c.step, .failed(.noLink))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testConfirmTimeout_failsNotStored() {
        let live = LiveState()
        let driver = MockDriver(connected: true)
        let c = AlarmArmCoordinator(driver: driver, live: live, connectTimeout: 5, confirmTimeout: 0.2)
        c.arm(wakeDate: Date(timeIntervalSince1970: 1_781_912_880))
        // Already connected → immediately in .confirming; do NOT set alarmArmConfirmed.
        XCTAssertEqual(c.step, .confirming)
        let exp = expectation(description: "not stored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(c.step, .failed(.notStored))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }
}
