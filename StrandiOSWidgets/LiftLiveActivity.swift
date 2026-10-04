import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Live Activity for a running Lift Log session — the minimised session bar, on the Lock Screen and
/// in the Dynamic Island.
///
/// It carries the same four things the in-app bar does, in the same order, because it is answering
/// the same question from further away: what am I doing, on what, with what numbers, and how long.
/// The colour language matches too — green while a set is being worked, amber through the rest.
///
/// THE CLOCK TICKS WITHOUT THE APP. Both timers are `Text(timerInterval:)`, driven by dates in the
/// content state, so the Lock Screen counts on its own between pushes. The app only sends a new
/// state when something actually changes (stage, set, heart rate), never once a second to animate a
/// number.
struct LiftLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiftActivityAttributes.self) { context in
            LiftLiveActivityBanner(state: context.state)
                .activityBackgroundTint(NoopVisualStyle.surface)
                .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            let tint = Self.tint(context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.state.exercise)
                    } icon: {
                        PhIcon("barbell", weight: .fill, size: 13)
                    }
                    .font(StrandFont.book(12)).lineLimit(1)
                    .foregroundStyle(tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Label {
                        Text(context.state.bpm.map(String.init) ?? "—").monospacedDigit()
                    } icon: {
                        PhIcon("heart", weight: .fill, size: 12)
                    }
                    .font(StrandFont.book(12))
                    .foregroundStyle(context.state.bpm == nil
                                     ? StrandPalette.textTertiary
                                     : StrandPalette.metricRose)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.detail ?? context.state.status)
                            .font(StrandFont.light(12)).lineLimit(1)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer(minLength: 8)
                        Self.clock(context.state, tint: tint)
                            .font(StrandFont.value(15, weight: 500))
                    }
                }
            } compactLeading: {
                // The heart rate, where the island has the room for it, with the dumbbell standing in until
                // the strap reports one — so this side is never the blank it was (Utku, 22 Sep 2026).
                Label {
                    Text(context.state.bpm.map(String.init) ?? "").monospacedDigit()
                } icon: {
                    PhIcon(context.state.bpm == nil ? "barbell" : "heart", weight: .fill, size: 13)
                }
                .font(Self.islandFont)
                .foregroundStyle(context.state.bpm == nil ? tint : StrandPalette.metricRose)
            } compactTrailing: {
                // Sized like the Lock Screen's clock: a running `Text(timerInterval:)` takes every point it
                // is offered, which stretched the island and left the digits adrift in its middle with blank
                // to their right (Utku, 22 Sep 2026). A hidden "00:00" in the same font gives the region the
                // width of the clock itself, and the live one is right-aligned over it.
                Text(verbatim: "00:00")
                    .font(Self.islandFont)
                    .monospacedDigit()
                    .hidden()
                    .overlay(alignment: .trailing) {
                        Self.clock(context.state, tint: tint)
                            .font(Self.islandFont)
                            .multilineTextAlignment(.trailing)
                    }
            } minimal: {
                PhIcon("barbell", weight: .fill, size: 13).foregroundStyle(tint)
            }
        }
    }

    /// The Lock Screen clock's face, shared by the clock and the hidden template that sizes it.
    static let clockFont = StrandFont.value(22, weight: 500)
    /// The Dynamic Island's compact face, shared by its heart rate, its clock and that clock's template.
    private static let islandFont = StrandFont.value(13, weight: 500)

    /// Green while working, amber through the rest — the sheet's and the bar's colour language.
    static func tint(_ state: LiftActivityAttributes.ContentState) -> Color {
        state.isResting ? StrandPalette.metricAmber : StrandPalette.statusPositive
    }

    /// Counts DOWN through a rest (the number you act on) and UP through a set, both self-ticking.
    ///
    /// Both branches use `Text(timerInterval:)`, which is the API widgets are given for a clock that
    /// advances without the app pushing. `Text(date, style: .timer)` looks equivalent and is not: on
    /// the Lock Screen it rendered "25 minutes" — a rounded, prose duration — where a gym timer has
    /// to read 25:02. Verified in the simulator, which is the only reason it was caught.
    ///
    /// A rest that is over reads 0:00 and stays there, as the in-app bar does
    /// (`LiftSessionEngine.restRemaining` floors at zero). It used to count UP past the end, and a
    /// clock climbing from zero on the Lock Screen read as a new timer rather than a finished rest
    /// (gym session, 16 Sep 2026). The countdown's range therefore starts at the REST'S start, not at
    /// `.now`: a widget re-rendered after the end — for a heart-rate push, say — still gets a range
    /// that is entirely past, which `Text(timerInterval:)` shows as its end value instead of switching
    /// to a count-up. A rest with no length (the sheet is complete) has no range to count and shows
    /// the same 0:00. A working set counts up from its start; a zero-length range would render
    /// nothing, so that end is pushed a day out — well beyond any session.
    static func clock(_ state: LiftActivityAttributes.ContentState, tint: Color) -> some View {
        Group {
            if let ends = state.restEndsAt {
                if ends > state.stageStartedAt {
                    Text(timerInterval: state.stageStartedAt...ends, countsDown: true)
                } else {
                    Text(verbatim: "0:00")
                }
            } else {
                Text(timerInterval: state.stageStartedAt...state.stageStartedAt.addingTimeInterval(86_400),
                     countsDown: false)
            }
        }
        .monospacedDigit()
        .foregroundStyle(tint)
    }
}

/// The session bar on the Lock Screen: what is being worked, on what, with what numbers, and how long.
struct LiftLiveActivityBanner: View {
    let state: LiftActivityAttributes.ContentState

    var body: some View {
        // Width goes to the words. The icon and the numbers sit nearer the banner's edges, and the heart
        // rate stacks over the clock instead of beside it, so the exercise and the next set lose less to
        // truncation — at the same sizes (Utku, 21 Sep 2026: "the writings are usually cut too quick").
        HStack(spacing: 10) {
            PhIcon("barbell", weight: .fill, size: 19)
                .foregroundStyle(LiftLiveActivity.tint(state))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(Circle().strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(state.exercise)
                    .font(StrandFont.book(15))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Text(state.detail.map { "\(state.status) — \($0)" } ?? state.status)
                    .font(StrandFont.light(12))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                // The set coming up, alone on the line, arriving pre-localized from the app (the
                // extension has no catalog). It puts the set number before the exercise, so the tail
                // truncation a long name needs cuts the name and keeps the number.
                Text(state.next)
                    .font(StrandFont.light(11))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 6)

            // Heart rate over the clock, both flush right. A running `Text(timerInterval:)` takes all the
            // width it is offered, so the clock's width comes from a hidden "00:00" in the same font —
            // the widest a set or a rest shows under an hour — and the live clock is right-aligned over
            // it. Sized from the timer itself, a working set's count-up spread across the whole banner.
            //
            // The heart rate is ALWAYS present, dash and all. A readout that vanishes when the strap
            // stops reading is indistinguishable from a missing feature — which is exactly how it
            // was first reported.
            VStack(alignment: .trailing, spacing: 2) {
                Label {
                    Text(state.bpm.map(String.init) ?? "—").monospacedDigit()
                } icon: {
                    PhIcon("heart", weight: .fill, size: 14)
                }
                .font(StrandFont.book(15))
                .foregroundStyle(state.bpm == nil
                                 ? StrandPalette.textTertiary
                                 : StrandPalette.metricRose)

                Text(verbatim: "00:00")
                    .font(LiftLiveActivity.clockFont)
                    .monospacedDigit()
                    .hidden()
                    .overlay(alignment: .trailing) {
                        LiftLiveActivity.clock(state, tint: LiftLiveActivity.tint(state))
                            .font(LiftLiveActivity.clockFont)
                            .multilineTextAlignment(.trailing)
                    }
            }
        }
        .padding(.vertical, 14)
        .padding(.leading, 10)
        .padding(.trailing, 12)
    }
}
