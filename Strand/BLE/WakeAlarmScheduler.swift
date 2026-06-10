import Foundation

/// What the live-fire orchestrator should do at a given moment, given the next wake target.
enum WakeAlarmAction: Equatable {
    /// Nothing to do — outside the keep-alive window, or this wake already fired.
    case idle
    /// Inside the lead window before wake: keep the BLE link hot so we're awake to fire on time.
    case openKeepAliveWindow
    /// At (or just past) the wake instant and not yet fired: send RUN_ALARM over the live link.
    case fire
}

/// Pure decision core for the live-fire alarm path (the verdict's recommended fix: NOOP fires
/// RUN_ALARM/cmd-68 over a kept-alive BLE link at wake — the strap's firmware alarm/cmd-66 is
/// wedged on this deep-discharged unit but the live haptic is proven to buzz, see
/// `whoop4-deep-discharge-state`). Mechanism-agnostic and side-effect-free so the timing math is
/// unit-tested on any platform; `BLEManager` owns the link, persistence, and notification backstop.
enum WakeAlarmScheduler {
    /// How long before wake to start keeping the link hot. Mirrors WHOOP's ~2 h high-freq window.
    static let windowLead: TimeInterval = 2 * 60 * 60
    /// Fire only within this grace after the target. Past it we stay silent rather than buzz the
    /// wrist at the wrong time — the on-time phone notification (Layer 1) has already alarmed.
    static let fireGrace: TimeInterval = 5 * 60

    /// - Parameters:
    ///   - wakeTarget: the next absolute wake instant, or nil when no alarm is set.
    ///   - now: current time.
    ///   - lastFiredWake: the wake instant most recently fired (persisted, survives app restart).
    static func decide(wakeTarget: Date?, now: Date,
                       lastFiredWake: Date?,
                       windowLead: TimeInterval = windowLead,
                       fireGrace: TimeInterval = fireGrace) -> WakeAlarmAction {
        guard let wake = wakeTarget else { return .idle }
        // Idempotent across state restoration: the same wake instant fires at most once. Wake
        // instants are computed to whole seconds, so a sub-second tolerance is exact-match here.
        let alreadyFired = lastFiredWake.map { abs($0.timeIntervalSince(wake)) < 1 } ?? false
        if now >= wake {
            if now < wake.addingTimeInterval(fireGrace), !alreadyFired { return .fire }
            return .idle
        }
        if now >= wake.addingTimeInterval(-windowLead) { return .openKeepAliveWindow }
        return .idle
    }
}
