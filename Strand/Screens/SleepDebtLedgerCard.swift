import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Sleep-debt ledger (#today-hosted-cards)
//
// The Sleep tab's "Sleep-debt ledger" card, extracted into a standalone view so it can ALSO be hosted in
// the Today tab. Both the Sleep tab and the Today host render THIS view from the SAME `SleepModel`, so the
// recency-weighted estimate can never diverge between the two surfaces (the parity contract). The
// debt-only formatting helpers (`debtHeadline` / `debtRead` / `debtSigned`) are lifted from the former
// `SleepView.sleepDebtLedger`; the nap-credited ledger is computed once in `SleepModel.build` (the shared
// builder) and read here — it is NOT recomputed.

/// The "Sleep-debt ledger" card. The recency-weighted debt carried into tonight as a dot-matrix headline,
/// the raw per-night delta against need for the most recent week (surplus above the need line, deficit
/// below, last night in the sleep accent), and a plain-English read under the card — rendered from the
/// shared [SleepModel]'s `sleepDebtLedger`. (#242)
struct SleepDebtLedgerCard: View {
    let model: SleepModel

    /// The nights the bar strip shows. The estimate itself still runs over the ledger's full window; a
    /// week keeps one weekday label per bar legible.
    private static let shownNights = 7

    var body: some View {
        let ledger = model.sleepDebtLedger
        let shown = Array(ledger.nights.suffix(Self.shownNights))
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("Sleep-debt ledger", caption: windowCaption(shown.count))
            NoopCard {
                if ledger.nightCount == 0 {
                    Text("No nights with sleep data yet. Your ledger fills in as you wear the strap to bed.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        headline(ledger)
                        DebtDeltaBars(nights: shown, accessibilityValue: barsAccessibilityValue(shown))
                            .padding(.top, 16)
                        Text("Each night against your \(clockText(ledger.needMin)) need")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(.top, 12)
                    }
                }
            }
            if ledger.nightCount > 0 {
                // The plain-English read of the current actionable estimate.
                NoopInsightRow(verbatim: debtRead(ledger))
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            }
        }
    }

    /// The headline: the debt carried into tonight in the dot-matrix face (counting up on appear), with
    /// its caption beside it.
    private func headline(_ ledger: SleepDebtLedger) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            CountUpText(
                value: ledger.magnitudeMin,
                format: { debtHeadline(forMagnitudeMin: $0) },
                font: StrandFont.dot(44),
                color: StrandPalette.textPrimary
            )
            .tracking(StrandFont.dotTracking(44))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Text(debtCaption(ledger))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.bottom, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(headlineAccessibilityText(ledger)))
    }

    // MARK: - Sleep-debt ledger formatting (lifted from the ledger-only SleepView helpers)

    /// The headline for an arbitrary (interpolated) magnitude so `CountUpText` renders a coherent string
    /// on every frame as the number ticks up. Below the on-target deadband nothing is carried — the
    /// estimate clears sub-band debt to zero — so the headline reads 0:00 there.
    private func debtHeadline(forMagnitudeMin m: Double) -> String {
        if m < SleepDebt.onTargetBandMin { return clockText(0) }
        return clockText(m)
    }

    /// The caption beside the headline: what the number is, or that the ledger is balanced.
    private func debtCaption(_ ledger: SleepDebtLedger) -> String {
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin || !ledger.isDebt {
            return String(localized: "On target")
        }
        return String(localized: "carried into tonight")
    }

    private func headlineAccessibilityText(_ ledger: SleepDebtLedger) -> String {
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin || !ledger.isDebt {
            return String(localized: "Sleep debt: on target")
        }
        return String(localized: "Sleep debt carried into tonight: \(durationText(ledger.magnitudeMin))")
    }

    /// The section caption names the nights the bars show.
    private func windowCaption(_ shown: Int) -> String? {
        switch shown {
        case 0: return nil
        case 1: return String(localized: "Last night")
        default: return String(localized: "Last \(shown) nights")
        }
    }

    /// Each shown night's delta, in order, as VoiceOver reads the strip ("Fri −18m, Sat +12m").
    private func barsAccessibilityValue(_ shown: [SleepDebtNight]) -> String {
        shown.map { "\(DebtDeltaBars.weekday($0.day)) \(debtSigned($0.deltaMin))" }.joined(separator: ", ")
    }

    /// Plain-English read of the current actionable estimate.
    private func debtRead(_ ledger: SleepDebtLedger) -> String {
        let nights = ledger.nightCount
        let span = nights == 1
            ? String(localized: "the last night")
            : String(localized: "the last \(nights) nights")
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin {
            return String(localized: "You've effectively met your current sleep need across \(span).")
        }
        let mag = durationText(ledger.magnitudeMin)
        if ledger.isDebt {
            return String(localized: "Add about \(mag) to your base sleep target tonight. Meeting that complete sleep need clears the displayed debt; recent shortfalls carry forward at a reduced weight.")
        }
        return String(localized: "You've effectively met your current sleep need across \(span).")
    }

    /// Signed "+1h 20m" / "−2h 10m" / "0m" balance string.
    private func debtSigned(_ minutes: Double) -> String {
        if abs(minutes) < 1 { return String(localized: "0m") }
        let sign = minutes >= 0 ? "+" : "−"
        return "\(sign)\(durationText(abs(minutes)))"
    }

    /// Minutes → "H:MM", the v2 duration form ("0:38", "7:50").
    private func clockText(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    /// Minutes → "Xm" / "Yh Zm" (verbatim of `SleepView.durationText`). Kept local to the card so it
    /// renders identically whether hosted in Today or shown in the Sleep tab.
    private func durationText(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return String(localized: "\(m)m") }
        return String(localized: "\(m / 60)h \(m % 60)m")
    }
}

/// The per-night delta strip: each night a rounded bar from the need line — up for a surplus, down for a
/// deficit — scaled to the week's spread, with its weekday underneath. The need line sits where the
/// week's largest surplus and deficit put it, so a week of short nights uses the whole height instead of
/// leaving the surplus half empty. Last night carries the sleep accent; the rest stay neutral.
private struct DebtDeltaBars: View {
    let nights: [SleepDebtNight]
    let accessibilityValue: String

    private let height: CGFloat = 70

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                bars(width: geo.size.width)
            }
            .frame(height: height)
            weekdayRow
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Per-night sleep against need"))
        .accessibilityValue(Text(verbatim: accessibilityValue))
    }

    private func bars(width: CGFloat) -> some View {
        let deltas = nights.map(\.deltaMin)
        let up = Swift.max(0, deltas.max() ?? 0)
        let down = Swift.max(0, -(deltas.min() ?? 0))
        let span = Swift.max(up + down, 1)
        let zeroY = height * CGFloat(up / span)
        let slot = width / CGFloat(Swift.max(nights.count, 1))
        let barW = Swift.min(30, slot * 0.68)
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: zeroY))
                p.addLine(to: CGPoint(x: width, y: zeroY))
            }
            .stroke(StrandPalette.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            ForEach(Array(deltas.enumerated()), id: \.offset) { i, d in
                let h = Swift.max(4, height * CGFloat(Swift.abs(d) / span))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(i == deltas.count - 1 ? NoopGlow.sleep.accent : NoopGlow.ink.deep)
                    .frame(width: barW, height: h)
                    // Surplus grows upward from the need line, deficit downward.
                    .position(x: slot * (CGFloat(i) + 0.5), y: d >= 0 ? zeroY - h / 2 : zeroY + h / 2)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(nights.enumerated()), id: \.offset) { i, night in
                Text(verbatim: Self.weekday(night.day))
                    .font(StrandFont.footnote)
                    .foregroundStyle(i == nights.count - 1 ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// "Fri" for a "yyyy-MM-dd" key, in the app language.
    static func weekday(_ key: String) -> String {
        guard let date = dayParser.date(from: key) else { return key }
        return weekdayFormatter.string(from: date)
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()
}
