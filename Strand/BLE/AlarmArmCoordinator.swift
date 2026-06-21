import Foundation
import Combine

/// The strap operations the guided alarm flow needs. `BLEManager` conforms; tests use a mock.
@MainActor
protocol AlarmArmDriving: AnyObject {
    var isConnected: Bool { get }
    func connect()
    func scanForWhoops()
    func armStrapAlarm(at date: Date)
    func disableStrapAlarm()
}

/// Steps surfaced to the guided arm sheet.
enum ArmStep: Equatable {
    case idle
    case connecting
    case syncingClock
    case writing
    case confirming
    case confirmed(epoch: UInt32)
    case failed(ArmFailure)
}

enum ArmFailure: Equatable { case noLink, notStored, cancelled }

/// Orchestrates the official-app-style arm: ensure a live link, write the alarm, read it back to
/// confirm the strap stored it. Calls existing `BLEManager` methods; observes `LiveState`. No wire
/// protocol lives here — `armStrapAlarm` already does SET_CLOCK → SET_ALARM → read-back confirm.
@MainActor
final class AlarmArmCoordinator: ObservableObject {
    @Published private(set) var step: ArmStep = .idle

    private let driver: AlarmArmDriving
    private let live: LiveState
    private let connectTimeout: TimeInterval
    private let confirmTimeout: TimeInterval

    private var cancellables = Set<AnyCancellable>()
    private var timeoutWork: DispatchWorkItem?

    init(driver: AlarmArmDriving, live: LiveState,
         connectTimeout: TimeInterval = 20, confirmTimeout: TimeInterval = 8) {
        self.driver = driver
        self.live = live
        self.connectTimeout = connectTimeout
        self.confirmTimeout = confirmTimeout
    }

    /// Begin arming for `wakeDate`. Safe to call again to retry.
    func arm(wakeDate: Date) {
        reset()
        if driver.isConnected {
            beginArm(wakeDate: wakeDate)
        } else {
            step = .connecting
            driver.connect()
            driver.scanForWhoops()
            startTimeout(connectTimeout) { [weak self] in self?.fail(.noLink) }
            live.$connected
                .filter { $0 }
                .first()
                .sink { [weak self] _ in self?.beginArm(wakeDate: wakeDate) }
                .store(in: &cancellables)
        }
    }

    /// Abort the in-flight arm.
    func cancel() {
        reset()
        step = .failed(.cancelled)
    }

    // MARK: - Internals

    private func beginArm(wakeDate: Date) {
        clearTimeout()
        step = .syncingClock           // armStrapAlarm sends SET_CLOCK first
        driver.armStrapAlarm(at: wakeDate)   // then SET_ALARM + begins read-back confirm
        step = .writing
        step = .confirming
        startTimeout(confirmTimeout) { [weak self] in self?.fail(.notStored) }
        live.$alarmArmConfirmed
            .compactMap { $0 }          // ignore the initial "arming…" nil
            .first()
            .sink { [weak self] confirmed in
                guard let self else { return }
                self.clearTimeout()
                if confirmed {
                    self.step = .confirmed(epoch: self.live.alarmArmedForEpoch
                        ?? UInt32(clamping: Int64(wakeDate.timeIntervalSince1970)))
                } else {
                    self.step = .failed(.notStored)
                }
            }
            .store(in: &cancellables)
    }

    private func fail(_ reason: ArmFailure) {
        reset()
        step = .failed(reason)
    }

    private func reset() {
        clearTimeout()
        cancellables.removeAll()
    }

    private func startTimeout(_ seconds: TimeInterval, _ action: @escaping () -> Void) {
        clearTimeout()
        let work = DispatchWorkItem(block: action)
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func clearTimeout() {
        timeoutWork?.cancel()
        timeoutWork = nil
    }
}
