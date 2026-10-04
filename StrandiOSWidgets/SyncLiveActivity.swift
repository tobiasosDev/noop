import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Live Activity for a strap history sync — the Lock Screen banner and the Dynamic Island.
///
/// Shows what the app's own Today sync control shows: that a sync is running, how many chunks it has
/// pulled, how long it has been going, and the strap's connect-time backlog when it reported one. No
/// progress bar, because there is no total to draw one against (see `SyncActivityAttributes`).
struct SyncLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SyncActivityAttributes.self) { context in
            // Lock Screen / banner presentation.
            SyncLiveActivityBanner(title: context.attributes.title, state: context.state)
                .activityBackgroundTint(NoopVisualStyle.surface)
                .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            // ONE line, deliberately. iOS shows the expanded layout for a few seconds whenever an activity
            // starts and offers no way to start compact, so the only lever on that flash is how tall the
            // expanded layout is: no bottom or centre region, so it is a short pill rather than a card.
            // The backlog detail and title live on the Lock Screen banner instead.
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label { Text(context.state.status) } icon: { syncGlyph(context.state.phase) }
                        .font(StrandFont.book(14))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if isActive(context.state.phase) {
                        elapsed(since: context.state.startedAt)
                            .font(StrandFont.value(14, weight: 500))
                            .monospacedDigit()
                    }
                }
            } compactLeading: {
                // Same footprint as the live-HR island's heart: one symbol, no label, so the compact pill
                // stays as narrow as that one does.
                syncGlyph(context.state.phase)
            } compactTrailing: {
                // "…" while connecting and until the first chunk lands; then the chunk count, the only
                // live number a sync has. Never "0", so the island never claims progress the strap has
                // not made.
                Text(context.state.chunks > 0 ? "\(context.state.chunks)" : "…")
                    .monospacedDigit()
            } minimal: {
                syncGlyph(context.state.phase)
            }
        }
    }
}

/// The sync banner on the Lock Screen: the phase glyph, the run's title over its status and backlog, and
/// the elapsed clock while it is still pulling.
struct SyncLiveActivityBanner: View {
    let title: String
    let state: SyncActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            syncGlyph(state.phase, size: 19)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(Circle().strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StrandFont.light(12)).foregroundStyle(StrandPalette.textSecondary)
                Text(state.status)
                    .font(StrandFont.book(17))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let detail = state.detail {
                    Text(detail).font(StrandFont.light(11)).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Spacer()
            if isActive(state.phase) {
                elapsed(since: state.startedAt)
                    .font(StrandFont.value(17, weight: 500))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

private func isActive(_ phase: SyncActivityAttributes.Phase) -> Bool {
    phase == .connecting || phase == .syncing
}

/// Counts up on its own from the run's start; no pushes needed to keep it moving.
private func elapsed(since start: Date) -> some View {
    Text(timerInterval: start...Date.distantFuture, countsDown: false)
}

/// One glyph per phase. The sync arrows in the positive (green) colour for both active phases — the
/// connecting/syncing distinction is carried by the trailing "…" vs count, not by swapping symbols, which
/// kept the compact pill's width steady — then a tick once done, and the critical colour when the strap
/// went quiet.
@ViewBuilder
private func syncGlyph(_ phase: SyncActivityAttributes.Phase, size: CGFloat = 15) -> some View {
    switch phase {
    case .connecting, .syncing:
        PhIcon("arrows-clockwise", size: size).foregroundStyle(StrandPalette.statusPositive)
    case .done:
        PhIcon("check-circle", weight: .fill, size: size).foregroundStyle(StrandPalette.statusPositive)
    case .interrupted:
        PhIcon("warning-circle", weight: .fill, size: size).foregroundStyle(StrandPalette.statusCritical)
    }
}
