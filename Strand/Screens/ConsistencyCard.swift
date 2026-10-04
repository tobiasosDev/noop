import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Consistency (#today-hosted-cards)
//
// The Sleep tab surfaces "Consistency" only as a tile inside the Night-detail metric grid — there is
// no standalone renderer for it. This card gives that single metric its own hostable view so it can be
// surfaced in the Today tab on its own. Both the Sleep tab tile and this hosted card read the SAME
// `SleepModel.consistency` metric (latest / typical / series) — the bedtime-onset-spread score that also
// honours the imported-consistency preference and is byte-identical to Android's `consistencySeries` — so
// the number, the vs-typical caption and the scale can never diverge between the two surfaces (the
// parity contract). The tile is the shared `SleepMetricTile` the Night-detail grid uses, with the same value
// and caption helpers, so the hosted card reads the same figures as the Sleep-tab tile.

/// The "Consistency" card. Renders the wearer's latest sleep-consistency percentage against their personal
/// typical from the shared [SleepModel], as a full-width v2 tile: the value, the vs-typical caption, and the
/// latest placed on a 0–100 % scale beside the typical.
struct ConsistencyCard: View {
    let model: SleepModel

    var body: some View {
        // The metric (latest %, typical mean, history series) is computed ONCE in the model build and
        // read here — the same memoized result the Night-detail grid reads for its tile.
        let m = model.consistency

        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("Consistency", captionKey: "Sleep")
            // The Night-detail tile at full width: the same value and vs-typical caption the Sleep-tab
            // grid prints, with the latest placed on a 0–100 % scale beside its typical.
            SleepMetricTile(title: m.latestDay == nil ? "Last night" : "Latest", icon: "calendar-check",
                            value: m.latest.map { "\(Int($0.rounded()))" } ?? "—",
                            unit: m.latest.map { _ in "%" },
                            caption: SleepTileCaption.make(latestDay: m.latestDay, latest: m.latest,
                                                           typical: m.typical) { "\(Int($0.rounded()))" }) {
                if let scale = SleepRangeBar.percentScale(m) {
                    scale.frame(width: 150)
                }
            }
        }
    }
}
