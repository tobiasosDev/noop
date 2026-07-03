import Foundation

// UniversalTrace.swift - the lines that ride EVERY Test Centre export, not only in Connection mode.
//
// The dayOwner line (built in the app's IntelligenceEngine) already rides every export tagged `.universal`.
// This adds the strap CLOCK-DRIFT + firmware-layout picture to that universal block so the RTC cluster
// (#531 / #767 / #804 / #812) self-diagnoses on every export. Previously the clock-drift summary was only
// emitted while the Connection test mode was on (BLEManager, gated on TestCentre.active(.connection)), so a
// Sleep or Battery report from a clock-broken strap never carried the one line that explains the failure.
// Hoisting it to the universal block means ANY active mode surfaces it.
//
// Pure + side-effect-free: no clock read of its own, no I/O. The caller (the export assembler) passes the
// last strap-reported banked-record window and its own wall-now; this formats one line. No PII (ISO dates,
// counts and a firmware version int only). No em-dashes. The Kotlin twin is UniversalTrace.kt.

public enum UniversalTrace {

    /// The universal strap-clock line: the strap's newest banked-record timestamp vs wall clock, with a
    /// FUTURE-DATE flag (the tell of a wandering / un-clocked RTC), the optional banked span in days, and the
    /// firmware record-layout version the strap hands over. One line, tagged `.universal` by the caller, so
    /// every export self-diagnoses the clock/firmware state behind the #531/#767/#804/#812 cluster.
    ///
    /// All timestamps are unix seconds in the same wall domain (the BLE layer decodes oldest/newest from the
    /// strap's GET_DATA_RANGE reply and the caller passes its own wall-now), so the future test is a plain
    /// comparison. `oldestUnix` is optional (a short range reply gives only the upper bound). `firmwareLayout`
    /// is the historical record-layout version (18/24/25/26) the strap emits, or nil when not yet observed
    /// this session; it is reported as "v<n>" or "unknown" so the line is always firmware-aware.
    ///
    /// - Parameter futureToleranceSeconds: slack before flagging FUTURE; a strap RTC vs phone skew of a
    ///   minute or two is normal, so the default mirrors a couple of minutes.
    public static func clockDriftLine(newestUnix: Int,
                                      wallNowUnix: Int,
                                      oldestUnix: Int? = nil,
                                      firmwareLayout: Int? = nil,
                                      futureToleranceSeconds: Int = 120) -> String {
        let aheadSeconds = newestUnix - wallNowUnix
        let future = aheadSeconds > futureToleranceSeconds
        var line = "strapClock newest=\(ConnectionTrace.isoDate(newestUnix)) "
            + "wall=\(ConnectionTrace.isoDate(wallNowUnix)) "
            + "newestVsWall=\(ConnectionTrace.signed(aheadSeconds))s"
        if let oldestUnix, oldestUnix < newestUnix {
            // Round to the nearest whole day so a near-3-day window reads spanDays=3, not 2 (60s shy
            // of exactly three days should still report three days of banked history).
            let spanDays = max(0, Int((Double(newestUnix - oldestUnix) / 86_400).rounded()))
            line += " oldest=\(ConnectionTrace.isoDate(oldestUnix)) spanDays=\(spanDays)"
        }
        line += firmwareLayout.map { " firmware=v\($0)" } ?? " firmware=unknown"
        line += future ? " FUTURE-DATED (strap clock ahead of wall)" : " clockOk"
        return line
    }
}
