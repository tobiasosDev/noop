import SwiftUI
import StrandDesign

// MARK: - WatchGlanceView — the watch app's single primary screen
//
// The v2 look scaled to the wrist: the three NOOP rings (Charge / Effort / Rest) with their numbers in the
// dot-matrix face, each honouring confidence (a calibrating score shows a dash plus a small
// "cal" marker, NEVER a fabricated number), a live heart-rate readout from the watch's own sensor, and a
// one-line sleep summary. When nothing has synced yet we show a friendly "open NOOP on your iPhone" state,
// and we always label the scores with the snapshot's age ("as of 2h ago") rather than implying they are live.
struct WatchGlanceView: View {
    @EnvironmentObject private var store: WatchScoreStore
    @EnvironmentObject private var liveHR: WatchLiveHR

    var body: some View {
        // The glance is page 1 of the watch app's swipeable page deck (WatchRootView): just the synced
        // scores, sized to ONE screen with no scrolling. Breathe / Workout / Intervals are their OWN pages
        // a swipe away, so the glance no longer pushes or links anywhere. The phone is the brain for the
        // SCORES here; the active features run on the watch's own sensors + haptics on their pages.
        Group {
            if let snap = store.snapshot {
                glance(snap)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NoopVisualStyle.canvas.ignoresSafeArea())
        .onAppear { liveHR.start() }
        .onDisappear { liveHR.stop() }
    }

    // MARK: Synced state

    @ViewBuilder
    private func glance(_ snap: WatchScoreSnapshot) -> some View {
        // One staleness decision for the whole glance: when the snapshot has aged out (per the shared
        // contract) we force every ring into its empty-track + dash branch so an arbitrarily old
        // snapshot never shows live-looking numbers. The honest recency line below says how old it is.
        let stale = snap.isStale()
        // The sleep line is the first thing to give way: on the smallest faces the page drops it rather
        // than push the recency line off the bottom. A stale snapshot's sleep line is out of date too, so
        // it is dropped rather than implying it is today's.
        ViewThatFits(in: .vertical) {
            glanceStack(snap, stale: stale, showsSleep: !stale)
            glanceStack(snap, stale: stale, showsSleep: false)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The page top to bottom: the wordmark, the three rings, the live heart rate, the sleep line and the
    /// recency line. The gaps open up to the board's spacing where the face is tall enough and close to a
    /// few points where it is not.
    private func glanceStack(_ snap: WatchScoreSnapshot, stale: Bool, showsSleep: Bool) -> some View {
        VStack(spacing: 0) {
            Text(verbatim: "NOOP")
                .font(StrandFont.dot(13))
                .tracking(13 * 0.06)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
                .accessibilityHidden(true)
            Spacer(minLength: 8).frame(maxHeight: 18)
            scoreRings(snap, stale: stale)
            Spacer(minLength: 8).frame(maxHeight: 18)
            heartRate
            if showsSleep, !snap.sleepSummary.isEmpty {
                sleepLine(snap.sleepSummary).padding(.top, 6)
            }
            asOf(snap)
                .padding(.top, 6)
        }
    }

    /// The three score rings. Each renders a number only when the phone earned one AND it is still
    /// current; a calibrating OR stale score is a dash with a small "cal" marker so we never show a value
    /// we did not compute or one that is no longer current. The rings are 54 pt where three fit across
    /// the face and shrink with it on the narrower watches.
    private func scoreRings(_ snap: WatchScoreSnapshot, stale: Bool) -> some View {
        GeometryReader { geo in
            let diameter = min(54, (geo.size.width - 8) / 3)
            HStack(spacing: 0) {
                // The labels ride a plain String property into ScoreRing, so they must be wrapped HERE;
                // a bare literal would bypass the string catalog entirely.
                ScoreRing(label: String(localized: "Charge"), value: snap.charge,
                          calibrating: snap.chargeCalibrating || stale,
                          color: StrandPalette.chargeColor, diameter: diameter)
                ScoreRing(label: String(localized: "Effort"), value: snap.effort,
                          calibrating: snap.effortCalibrating || stale,
                          color: StrandPalette.effortColor, diameter: diameter)
                ScoreRing(label: String(localized: "Rest"), value: snap.rest,
                          calibrating: snap.restCalibrating || stale,
                          color: StrandPalette.restColor, diameter: diameter)
            }
            .frame(width: geo.size.width)
        }
        .frame(height: 72)
    }

    /// Live heart rate from the watch's own sensor. Honest about denial: "HR unavailable" when HealthKit
    /// access was refused, a dash until the first sample lands, then the live BPM.
    private var heartRate: some View {
        HStack(spacing: 8) {
            PhIcon("heart", size: 15)
                .foregroundStyle(StrandPalette.textPrimary)
            if liveHR.denied {
                Text("HR unavailable")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer(minLength: 0)
            } else {
                Text(verbatim: liveHR.bpm.map(String.init) ?? "–")
                    .font(StrandFont.value(17))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                Text("bpm")
                    .font(StrandFont.light(11))
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
                if liveHR.bpm != nil {
                    WatchLiveDot()
                    Text("Live")
                        .font(StrandFont.light(10.5))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(NoopVisualStyle.inset))
    }

    /// One-line sleep summary straight from the phone (e.g. "7h 12m · 81% Rest"). Empty string = skip it.
    @ViewBuilder
    private func sleepLine(_ summary: String) -> some View {
        if !summary.isEmpty {
            HStack(spacing: 6) {
                PhIcon("bed", size: 12)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(summary)
                    .font(StrandFont.light(11))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The honesty line: how recent the synced scores are, straight from the shared contract so the
    /// glance and the complication phrase it identically ("Today" / "Yesterday" / "2h ago"). When the
    /// snapshot is stale the rings above are already dashes, and this line carries the recency.
    private func asOf(_ snap: WatchScoreSnapshot) -> some View {
        let fresh = snap.freshnessText()
        return Text(snap.isStale() ? String(localized: "stale · \(fresh)") : String(localized: "as of \(fresh)"))
            .font(StrandFont.light(10))
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            PhIcon("device-mobile", size: 28)
                .foregroundStyle(StrandPalette.textTertiary)
            Text("Open NOOP on your iPhone to sync")
                .font(StrandFont.light(13.5))
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .padding(.horizontal, 12)
    }

    // Snapshot recency now comes from the shared contract (`freshnessText` / `isStale` on
    // WatchScoreSnapshot) so the glance and the complication never drift apart. The old local
    // ageString helper was retired with that move.
}

// MARK: - ScoreRing — one v2 score ring scaled for the wrist
//
// The dot-matrix number inside a thin coloured arc with a white knob, the label under it. A calibrating
// score draws an EMPTY track with a dash and a small "cal" marker, never a fabricated fill or number.
private struct ScoreRing: View {
    let label: String
    let value: Double?
    let calibrating: Bool
    let color: Color
    var diameter: CGFloat = 54

    var body: some View {
        VStack(spacing: 6) {
            WatchScoreRing(value: calibrating ? nil : value, tint: color,
                           diameter: diameter, numberSize: (diameter * 15 / 54).rounded())
            Text(label)
                .font(StrandFont.light(9.5))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
