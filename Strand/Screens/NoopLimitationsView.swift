import SwiftUI
import StrandDesign

// MARK: - NoopLimitationsView — "what NOOP can (and can't) read off each strap"
//
// The iOS/macOS twin of Android's NoopLimitationsScreen: a plain tri-state capability grid listing every
// metric NOOP surfaces and whether it comes live off a WHOOP 4.0 vs a 5.0/MG. Marks mirror the
// decoder/analytics truth (Interpreter / AnalyticsEngine / HistoricalStreams): full = read live; partial =
// an on-device estimate or an experimental / firmware-gated read; none = not off the strap (SpO₂ % is
// import-only on both; blood pressure has no path). A legend carries the meaning in place of per-row prose.
// Reached from the iOS More tab (Data group) and the macOS sidebar (Data & App). The hero's counts are
// derived from the same rows, so the summary can never disagree with the grid.

struct NoopLimitationsView: View {

    /// Tri-state support for a metric on a given strap — honest, never overstated.
    private enum LimitState {
        case full, partial, none

        /// Phosphor glyph shown in the strap column.
        var glyph: String {
            switch self {
            case .full:    return "check"
            case .partial: return "minus"
            case .none:    return "x"
            }
        }

        /// Spoken label for the row's accessibility description.
        var spoken: String {
            switch self {
            case .full:    return String(localized: "yes")
            case .partial: return String(localized: "partly")
            case .none:    return String(localized: "no")
            }
        }
    }

    /// One row: a metric, and how it reads on a 4.0 vs a 5.0/MG. No note — the legend carries the meaning.
    private struct LimitRow: Identifiable {
        let feature: LocalizedStringKey
        let spokenFeature: String
        let whoop4: LimitState
        let whoop5: LimitState
        var id: String { spokenFeature }
    }

    private let rows: [LimitRow] = [
        LimitRow(feature: "Live heart rate", spokenFeature: "Live heart rate", whoop4: .full, whoop5: .full),
        LimitRow(feature: "HRV (rMSSD)", spokenFeature: "HRV", whoop4: .full, whoop5: .full),
        LimitRow(feature: "Sleep staging", spokenFeature: "Sleep staging", whoop4: .full, whoop5: .full),
        LimitRow(feature: "Recovery & strain", spokenFeature: "Recovery and strain", whoop4: .full, whoop5: .full),
        // `.partial` on BOTH generations: the displayed respiratory rate is always
        // `SleepStager.respRateFromRR` — an on-device RSA estimate off the R-R stream, which is what
        // `.partial` means — computed with NO family branch (`AnalyticsEngine`'s `respRateDaily`). The
        // 5.0/MG v18 wire carries no respiratory channel at all (`Whoop5HistoricalTests…` pins
        // `resp_rate_raw` nil); the 4.0 v24 layout DOES carry `resp_rate_raw`, but it is a raw ADC stored
        // unconverted (schema: "resp rate computed server-side", `HistoricalStreams` keeps it as a raw
        // `RespSample`) and never becomes the shown value. Neither is "read live off the strap" (`.full`)
        // — which is also why an over-counted-R-R 4.0 night (#1331) blanks it.
        LimitRow(feature: "Respiratory rate", spokenFeature: "Respiratory rate", whoop4: .partial, whoop5: .partial),
        LimitRow(feature: "Stress (on-device)", spokenFeature: "Stress", whoop4: .full, whoop5: .full),
        LimitRow(feature: "Workout detection", spokenFeature: "Workout detection", whoop4: .full, whoop5: .full),
        LimitRow(feature: "Skin temperature", spokenFeature: "Skin temperature", whoop4: .partial, whoop5: .full),
        LimitRow(feature: "Steps", spokenFeature: "Steps", whoop4: .partial, whoop5: .full),
        LimitRow(feature: "Blood oxygen (SpO₂ %)", spokenFeature: "Blood oxygen", whoop4: .none, whoop5: .none),
        LimitRow(feature: "ECG", spokenFeature: "ECG", whoop4: .none, whoop5: .partial),
        LimitRow(feature: "Blood pressure", spokenFeature: "Blood pressure", whoop4: .none, whoop5: .none),
    ]

    var body: some View {
        ScreenScaffold(title: nil) {
            NoopScreenHeader("NOOP limitations")
                .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 6) {
                Text("What NOOP reads")
                    .font(StrandFont.title1)
                    .tracking(-0.5)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Straight from the strap, over Bluetooth. Where a signal is only estimated or still experimental, NOOP says so.")
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 10)
            hero
            NoopSectionTitle("By feature", caption: buildCaption)
            tableCard
            legend
            cleanRoomCard
            #if os(iOS)
            // A gap in the grid is best reported with a strap log; Test Centre is where one is captured.
            NoopList {
                NavigationLink { TestCentreView() } label: {
                    NoopRow("Missing something?", caption: "Share a strap log from Test Centre",
                            icon: "notebook", chevron: true)
                }
                .buttonStyle(.plain)
            }
            #endif
        }
        .noopHidesSystemNavBar()
    }

    // MARK: - Hero

    /// The ink hero: per strap generation, how many of the grid's signals are read live, how many only
    /// partly, how many not at all — counted from `rows`, never typed in.
    private var hero: some View {
        NoopHeroCard(glow: .ink, padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge(verbatim: String(localized: "Read on \(Platform.deviceNounPhrase)"), icon: "bluetooth")
                    Spacer(minLength: 8)
                    NoopPill(verbatim: String(localized: "\(rows.count) signals"), compact: true)
                }
                HStack(alignment: .top, spacing: 20) {
                    heroColumn(title: "WHOOP 4.0", states: rows.map(\.whoop4))
                    Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1)
                    heroColumn(title: "WHOOP 5.0 / MG", states: rows.map(\.whoop5))
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 26)
            }
            .padding(.bottom, 2)
        }
    }

    private func heroColumn(title: String, states: [LimitState]) -> some View {
        let full = states.filter { $0 == .full }.count
        let partial = states.filter { $0 == .partial }.count
        let none = states.filter { $0 == .none }.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 6) {
                NoopDotNumber("\(full)", size: 72)
                Text("of \(states.count)")
                    .font(StrandFont.light(13, relativeTo: .footnote))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.bottom, 6)
            }
            Text(verbatim: title)
                .font(StrandFont.book(15, relativeTo: .body))
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.top, 14)
            Text("\(partial) partly · \(none) not read")
                .font(StrandFont.light(10.5, relativeTo: .caption2))
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// "Build 550" — which build this grid describes, since the marks move as decoding lands.
    private var buildCaption: String? {
        guard let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else { return nil }
        return String(localized: "Build \(build)")
    }

    // MARK: - Grid

    private var tableCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Feature")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: "WHOOP\n4.0")
                    .frame(width: 76)
                Text(verbatim: "WHOOP\n5.0 / MG")
                    .frame(width: 76)
            }
            .font(StrandFont.book(11, relativeTo: .caption2))
            .tracking(0.66)
            .textCase(.uppercase)
            .multilineTextAlignment(.center)
            .lineSpacing(1)
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .accessibilityHidden(true)
            ForEach(rows) { row in
                Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
                HStack(spacing: 0) {
                    Text(row.feature)
                        .font(StrandFont.book(14.5, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    supportCell(row.whoop4).frame(width: 76)
                    supportCell(row.whoop5).frame(width: 76)
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 50)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(a11yLabel(row))
            }
        }
        .padding(.vertical, 4)
        .noopPanel()
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 10) {
            legendRow(.full, "Read live off the strap")
            legendRow(.partial, "On-device estimate, or experimental / firmware-gated")
            legendRow(.none, "Not from the strap. SpO₂ can be filled by importing a WHOOP or Health export.")
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private func legendRow(_ state: LimitState, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            supportCell(state)
            Text(label)
                .font(StrandFont.light(13, relativeTo: .footnote))
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The 28 pt state glyph: a filled ring with a check, a dashed ring with a dash, a faint ring with
    /// a cross. Shape and fill carry the state, so it reads without colour.
    private func supportCell(_ state: LimitState) -> some View {
        ZStack {
            switch state {
            case .full:
                Circle().fill(StrandPalette.textPrimary.opacity(0.14))
                Circle().strokeBorder(StrandPalette.textPrimary.opacity(0.22), lineWidth: 1)
            case .partial:
                Circle().strokeBorder(StrandPalette.textPrimary.opacity(0.3),
                                      style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            case .none:
                Circle().strokeBorder(StrandPalette.textPrimary.opacity(0.08), lineWidth: 1)
            }
            PhIcon(state.glyph, size: 14)
                .foregroundStyle(state == .full ? StrandPalette.textPrimary
                                 : state == .partial ? StrandPalette.textSecondary
                                 : NoopVisualStyle.quaternaryText)
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    // MARK: - Clean room

    private var cleanRoomCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                NoopCardHeader("Clean-room, on purpose", icon: "shield-check")
                Text("NOOP is clean-room interoperability with hardware you own. It reads what the strap sends over Bluetooth and computes everything here: no WHOOP firmware, no WHOOP app code, no account. Commands that could alter the strap for good are never sent.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 14)
    }

    /// VoiceOver line for one row, assembled at runtime from already-localized parts. A plain String (not a
    /// LocalizedStringKey), so it carries no catalog key of its own.
    private func a11yLabel(_ row: LimitRow) -> String {
        "\(row.spokenFeature): WHOOP 4.0 \(row.whoop4.spoken), 5.0/MG \(row.whoop5.spoken)"
    }
}
