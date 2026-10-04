import SwiftUI
import StrandDesign
import StrandAnalytics
import Foundation

/// Strain/illness early-warning banner. Observes AppModel in isolation so the ~1 Hz HR stream
/// re-renders only this small view, not the whole screen. Renders nothing when there's no alert.
struct HealthAlertBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let alert = model.healthAlert {
            let copy = localizedHealthAlertCopy(alert)
            // A neutral v2 card whose only colour is the alert glyph (the alert accent is the one active
            // state on the card): prominent, but never a coloured border or a tinted wash.
            NoopCard {
                HStack(alignment: .top, spacing: 14) {
                    PhIcon("warning", size: 17)
                        .foregroundStyle(NoopGlow.low.tint)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: NoopVisualStyle.tileRadius, style: .continuous)
                            .fill(NoopVisualStyle.raised))
                        .accessibilityHidden(true)
                    Text(copy)
                        .font(StrandFont.light(14, relativeTo: .subheadline))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(copy)
        }
    }
}

/// Home-facing rendering of the semantic illness result. Both Today variants share this banner,
/// so neither can accidentally expose the analytics engine's English notification copy.
func localizedHealthAlertCopy(_ alert: AppModel.HealthAlert) -> String {
    if alert.message == .raised {
        let formatter = ListFormatter()
        formatter.locale = AppLanguage.activeLocale
        let signals = formatter.string(from: alert.firedSignals) ?? alert.firedSignals.joined(separator: ", ")
        return String(localized: "Your body looks strained. Signals up: \(signals). No alcohol or travel was logged, so consider taking it easy. On-device estimate, not a diagnosis.")
    }
    if alert.message == .alreadyUnwellAgree {
        return String(localized: "You logged feeling unwell, and your signals agree. Take it easy today. On-device estimate, not a diagnosis.")
    }
    if alert.message == .alreadyUnwell {
        return String(localized: "You logged feeling unwell. Take it easy today. On-device estimate, not a diagnosis.")
    }
    // The publisher gates the banner to raised/already-unwell. Keep the impossible fallback localized
    // and semantic rather than leaking `Result.copy` if a future caller bypasses that gate.
    return String(localized: "Nothing notable. Your signals look like their normal range.")
}
