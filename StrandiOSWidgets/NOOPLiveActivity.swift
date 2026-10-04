import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Live Activity for an active live-HR session — shown on the Lock Screen and in the Dynamic Island.
struct NOOPLiveActivity: Widget {
    /// The heart rate to draw: none once iOS has marked the banner stale. Each push is fresh for 30 s
    /// (`LiveActivityController.staleAfter`) and NOOP re-pushes a steady number well inside that, so a stale banner
    /// means the readings stopped — the strap off the wrist, or out of reach — even while NOOP itself is asleep and
    /// cannot say so: iOS redraws the banner at the stale date on its own.
    static func shownBpm(_ context: ActivityViewContext<NOOPActivityAttributes>) -> Int? {
        context.isStale ? nil : context.state.bpm
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NOOPActivityAttributes.self) { context in
            // Lock Screen / banner presentation: the session, its scores, and the live heart rate large.
            NOOPLiveActivityBanner(title: context.attributes.title, state: context.state,
                                   bpm: Self.shownBpm(context))
                .activityBackgroundTint(NoopVisualStyle.surface)
                .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(verbatim: Self.shownBpm(context).map(String.init) ?? "–")
                            .font(StrandFont.dot(18))
                    } icon: {
                        PhIcon("heart", size: 15)
                    }
                    .foregroundStyle(StrandPalette.textPrimary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // Charge + Effort (#446) — one more stat alongside the leading live HR.
                    HStack(spacing: 10) {
                        if let r = context.state.recovery {
                            statColumn(label: "Charge", value: "\(r)%")
                        }
                        if let e = context.state.effort {
                            statColumn(label: "Effort", value: "\(e)")
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.attributes.title)
                        .font(StrandFont.light(12))
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                PhIcon("heart", size: 14).foregroundStyle(StrandPalette.textPrimary)
            } compactTrailing: {
                Text(verbatim: Self.shownBpm(context).map(String.init) ?? "–")
                    .font(StrandFont.dot(14))
                    .monospacedDigit()
            } minimal: {
                PhIcon("heart", size: 14).foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }
}

/// The live-HR banner on the Lock Screen: the session glyph in its ring, the title over Charge and Effort,
/// and the heart rate large in the dot face with its live mark. `bpm` arrives already gated on staleness
/// (`NOOPLiveActivity.shownBpm`), so a nil here is "no current reading", never a zero.
struct NOOPLiveActivityBanner: View {
    let title: String
    let state: NOOPActivityAttributes.ContentState
    let bpm: Int?

    var body: some View {
        HStack(spacing: 12) {
            PhIcon("heartbeat", size: 19)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(Circle().strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(StrandFont.book(13))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                // Charge + Effort (#446) on the banner, mirroring the Dynamic Island expanded stats.
                HStack(spacing: 12) {
                    if let r = state.recovery {
                        bannerStat(label: "Charge", value: "\(r)%")
                    }
                    if let e = state.effort {
                        bannerStat(label: "Effort", value: "\(e)")
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text(verbatim: bpm.map(String.init) ?? "–")
                        .font(StrandFont.dot(34))
                        .tracking(StrandFont.dotTracking(34))
                        .foregroundStyle(bpm == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    if bpm != nil {
                        Text("bpm")
                            .font(StrandFont.light(10))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                if bpm != nil {
                    HStack(spacing: 5) {
                        Circle().fill(StrandPalette.textPrimary).frame(width: 5, height: 5)
                            .background(Circle().fill(Color.white.opacity(0.12)).frame(width: 11, height: 11))
                        Text("Live HR")
                            .font(StrandFont.light(10.5))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

/// Lock-Screen banner stat (label then value). File-scope because the `ActivityConfiguration` content
/// closure isn't a method of `NOOPLiveActivity`.
///
/// #759 - the label and value stay together on one baseline and `fixedSize` stops either truncating, so
/// a value is never separated from its label at narrow widths.
@ViewBuilder
private func bannerStat(label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(label).font(StrandFont.light(11)).foregroundStyle(StrandPalette.textSecondary)
        Text(value).font(StrandFont.book(12)).foregroundStyle(StrandPalette.textPrimary)
    }
    .fixedSize()
}

/// Dynamic Island expanded-region stat column (label over value). File-scope for the same reason as
/// `bannerStat`. #759 - centre-aligned + `fixedSize` so each value sits directly under its own label.
@ViewBuilder
private func statColumn(label: String, value: String) -> some View {
    VStack(alignment: .center, spacing: 1) {
        Text(label).font(StrandFont.light(10)).foregroundStyle(.secondary)
        Text(value).font(StrandFont.dot(16))
    }
    .multilineTextAlignment(.center)
    .fixedSize()
}
