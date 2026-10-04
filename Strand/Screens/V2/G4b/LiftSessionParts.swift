import SwiftUI
import StrandDesign

// MARK: - Lift session v2 chrome
//
// Small pieces of the running-session sheet and the minimised bar that the StrandDesign kit does not carry:
// the translucent buttons that sit on a glow (`.gb`), the set tick, and the heart-rate pill of the sheet
// header. Behaviour stays in the screens; these only draw.

/// A button on a glowing hero (`.gb`): 40 pt capsule, 8 % white over the glow, a 12 % white hairline,
/// 13 pt Book label. `primary` turns it into the ink pill for the one action the stage is waiting for.
struct LiftGlassButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(primary ? StrandFont.medium(14, relativeTo: .subheadline) : StrandFont.book(13, relativeTo: .subheadline))
            .foregroundStyle(primary ? StrandPalette.goldDeepText : Color.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(Capsule(style: .continuous).fill(primary ? StrandPalette.gold : Color.white.opacity(0.08)))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(primary ? Color.clear : Color.white.opacity(0.12), lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.38)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(StrandMotion.interactive, value: configuration.isPressed)
    }
}

/// The set tick: an ink disc with a black check once the set is done, an empty ring before.
struct LiftCheckCircle: View {
    let done: Bool
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            if done {
                // The filled glyph's disc spans 208 of its 256-unit grid; scaled so the disc is `size`.
                PhIcon("check-circle", weight: .fill, size: size * 256 / 208)
                    .foregroundStyle(StrandPalette.textPrimary)
            } else {
                Circle().strokeBorder(NoopVisualStyle.quaternaryText, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The live heart rate in a 30 pt pill (`.hrp`): a heartbeat glyph, the number and "bpm".
struct LiftHeartRatePill: View {
    var body: some View {
        HStack(spacing: 6) {
            PhIcon("heartbeat", size: 14)
                .foregroundStyle(StrandPalette.textPrimary)
            LiftHeartRate(style: .pill)
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
        .fixedSize()
    }
}

/// "Strap buzzes at 0:05" beside a running rest: the warning the session sends `restWarningLeadSec` before
/// the rest ends, said only when it can happen — a bonded strap and the Lift rest buzz switched on. Its own
/// view so only this line follows the strap's live state, not the sheet around it.
struct LiftRestBuzzNote: View {
    @EnvironmentObject private var live: LiveState
    @AppStorage(HapticPrefs.liftRest) private var restBuzz = true

    var body: some View {
        if live.bonded && restBuzz {
            Text(String(localized: "Strap buzzes at \(ActiveWorkoutClock.clock(LiftSessionController.restWarningLeadSec))"))
                .lineLimit(1)
                .fixedSize()
        }
    }
}
