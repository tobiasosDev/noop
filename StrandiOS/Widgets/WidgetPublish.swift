#if os(iOS)
import Foundation
import WidgetKit

extension WidgetSnapshot {
    /// Build a glance snapshot from the live app state and publish it to the shared App Group, then
    /// ask WidgetKit to refresh. Called when the app becomes active and after a Health sync.
    ///
    /// `async` because the Rest score (#446) lives in a computed metric series, not a `DailyMetric`
    /// column, so it needs an `exploreSeries` read. The sole caller already runs inside a `Task`, so it
    /// just gains an `await`. Charge / Effort / HRV / Resting HR all read synchronously off the SAME
    /// most-recent scored day the existing Charge field already anchored on, so the richer fields and the
    /// headline never disagree about which day they describe.
    @MainActor
    static func publish(from model: AppModel) async {
        // Most recent day that actually has a recovery score — the anchor row for every derived field.
        let day = model.repo.days.last(where: { $0.recovery != nil })
        // Rest (sleep_performance) for that same day. exploreSeries merges imported + on-device,
        // exactly like the Today Rest tile. Keyed to the anchor day; falls back to the series tail when
        // the anchor row has no Rest entry yet (early in a fresh day), matching TodayView's behaviour.
        var restScore: Double?
        if let day {
            let restSeries = await model.repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
            let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
            restScore = restByDay[day.day] ?? restSeries.last?.value
        }
        let snap = WidgetSnapshot(
            recovery: day?.recovery.map { Int($0.rounded()) },
            bpm: model.bpm ?? model.live.heartRate,
            batteryPct: model.live.batteryPct.map { Int($0.rounded()) },
            bonded: model.live.bonded,
            updated: Date(),
            // Effort is stored on NOOP's 0–100 axis (the same value the Today Effort tile reads), so it
            // publishes as a whole number without the WHOOP-0–21 toggle the main app applies — the widget
            // extension can't reach UnitFormatter/UnitPrefs, and 0–100 is the default scale.
            effort: day?.strain.map { Int($0.rounded()) },
            rest: restScore.map { Int($0.rounded()) },
            hrv: day?.avgHrv.map { Int($0.rounded()) },
            restingHr: day?.restingHr
        )
        snap.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
#endif
