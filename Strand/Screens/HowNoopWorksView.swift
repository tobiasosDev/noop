import SwiftUI
import StrandDesign

// MARK: - How NOOP works (primer)
//
// COMPONENT 5 of the Sleep & Recovery Guidance / Explainability layer
// (docs/superpowers/specs/2026-06-20-sleep-guidance-explainability.md).
//
// A short, skimmable, plain-English primer that answers the four "how does this
// work?" questions people ask: how sleep is sorted, how scores + calibration work,
// what "recording" means, and where the provenance badges come from. It is the one
// place that ties the four guidance components together so nobody has to guess.
//
// Presented as a sheet (Settings → About and a "?" affordance): a v2 page that opens on the
// strap-to-screen flow and the four sync steps, then the privacy hero, then the primer cards,
// the scoring-methods card, and a "Got it" button.
//
// All copy here is the single APPROVED source of truth (the spec's COMPONENT 5 text,
// verbatim), shared word-for-word across macOS / iOS / Android. No fabricated values,
// no jargon, no em-dashes. Kotlin's primer composable mirrors these four sections.

struct HowNoopWorksView: View {
    let onClose: () -> Void

    /// The four primer sections, in the order the spec lists them. The icon gives each card its
    /// own glance-able identity.
    private enum Section: CaseIterable, Identifiable {
        case sleepSorting
        case scores
        case recording
        case provenance

        var id: Self { self }

        var title: String {
            switch self {
            case .sleepSorting: return String(localized: "How your sleep is sorted")
            case .scores:       return String(localized: "How your scores work")
            case .recording:    return String(localized: "What \"recording\" means")
            case .provenance:   return String(localized: "Where your numbers come from")
            }
        }

        var body: String {
            switch self {
            case .sleepSorting:
                return String(localized: "NOOP picks your main sleep as your longest real block, and (once it has learned your usual hours) the one nearest your normal sleep time. Everything else that day is a nap. You can always edit bed and wake times.")
            case .scores:
                return String(localized: "Charge, Effort and Rest are scored on your own device from your strap data. Charge needs about four nights of sleep to learn your baseline (that's \"Calibrating\", counted as nights of 4 on the ring), and keeps sharpening over your first couple of weeks. On a WHOOP 5 or MG the strap banks little history, so that count can sit at 0 of 4 until you have worn it across a few nights. That's the strap's sync limit, not a fault. Before there's a number, NOOP shows what it can without faking one.")
            case .recording:
                return String(localized: "When your strap is connected NOOP is saving data live. \"Last synced\" tells you how fresh it is. If it says \"Not recording\", reconnect.")
            case .provenance:
                return String(localized: "A badge shows whether a number was scored on-device by NOOP, or imported from Whoop or Apple Health.")
            }
        }

        /// Phosphor glyph for the section's icon tile — sleep / scores / recording / provenance.
        var icon: String {
            switch self {
            case .sleepSorting: return "moon-stars"
            case .scores:       return "gauge"
            case .recording:    return "broadcast"
            case .provenance:   return "seal-check"
            }
        }

        /// Short overline tag above the section title.
        var overline: String {
            switch self {
            case .sleepSorting: return String(localized: "SLEEP")
            case .scores:       return String(localized: "SCORES")
            case .recording:    return String(localized: "RECORDING")
            case .provenance:   return String(localized: "PROVENANCE")
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                NoopDetailHeader("How NOOP works", onBack: onClose)
                    .padding(.bottom, 6)
                VStack(alignment: .leading, spacing: 8) {
                    Text("From your wrist to your screen. Nowhere else.")
                        .font(StrandFont.title1)
                        .tracking(-0.5)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Four steps, all on hardware you own.")
                        .font(StrandFont.light(14, relativeTo: .subheadline))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .padding(.bottom, 10)
                flowCard
                NoopSectionTitle("The four steps", captionKey: "Every sync")
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    stepCard(number: index + 1, title: step.title, body: step.body)
                }
                privacyHero
                    .padding(.top, 16)
                NoopSectionTitle("The basics")
                introCard
                ForEach(Section.allCases) { section in
                    primerCard(section)
                }
                scoringMethodsCard
                footerNote
                NoopButton("Got it", kind: .primary, fullWidth: true, action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
        #if os(iOS)
        // #697/#horizontal-swipe parity, see ScreenScaffold.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        #if os(iOS) && DEBUG
        .modifier(DemoScrollAnchor())
        #endif
        // Same sizing split as ScoringGuideView / WhatsNewView: a fixed window on macOS,
        // fill the presented sheet on iOS so nothing runs off a narrow phone screen (#185).
        #if os(macOS)
        .frame(width: 560, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceBase)
    }

    // MARK: - Flow + steps

    /// The four steps from strap to screen. Plain statements of what the app does; nothing here
    /// claims a signal the strap grid (NOOP limitations) does not.
    private static let steps: [(title: LocalizedStringKey, body: LocalizedStringKey)] = [
        ("Your strap records",
         "Your strap samples heart rate and motion around the clock and holds what it measured until NOOP collects it."),
        ("NOOP reads it over Bluetooth",
         "When your phone or computer is in range, NOOP pulls new data straight off the strap and checks every frame on arrival."),
        ("Scores are computed on this device",
         "Charge, Rest, Effort and HRV are worked out here, with formulas published in the open source."),
        ("Your data stays here",
         "One local database. Back it up to a folder you choose, export it whenever you like."),
    ]

    /// Strap, Bluetooth, this device; and the cloud that is not part of it.
    private var flowCard: some View {
        NoopCard {
            HStack(alignment: .top, spacing: 0) {
                flowNode("watch", label: Text("Your strap"))
                VStack(spacing: 8) {
                    Text("Bluetooth")
                        .font(StrandFont.light(10, relativeTo: .caption2))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(StrandPalette.textTertiary)
                    BluetoothLink()
                        .frame(height: 14)
                }
                .padding(.top, 12)
                .frame(maxWidth: .infinity)
                flowNode(Self.deviceIcon, label: Text("This \(Platform.deviceNoun)"))
                Rectangle().fill(NoopVisualStyle.borderHighlight)
                    .frame(width: 1, height: 58)
                    .padding(.horizontal, 16)
                flowNode("cloud-slash", label: Text("No cloud"), off: true)
            }
            .padding(.top, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Your strap connects to this \(Platform.deviceNoun) over Bluetooth. No cloud."))
    }

    private static var deviceIcon: String {
        #if os(macOS)
        return "laptop"
        #else
        return "device-mobile"
        #endif
    }

    private func flowNode(_ icon: String, label: Text, off: Bool = false) -> some View {
        VStack(spacing: 10) {
            PhIcon(icon, size: 24)
                .foregroundStyle(off ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .frame(width: 58, height: 58)
                .background {
                    if !off {
                        Circle().fill(RadialGradient(colors: [NoopVisualStyle.raised, NoopVisualStyle.inset],
                                                     center: UnitPoint(x: 0.35, y: 0.3),
                                                     startRadius: 0, endRadius: 44))
                    }
                }
                .overlay {
                    if off {
                        Circle().strokeBorder(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    } else {
                        Circle().strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1)
                    }
                }
            label
                .font(StrandFont.light(11, relativeTo: .caption2))
                .foregroundStyle(off ? StrandPalette.textTertiary : StrandPalette.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: 62)
    }

    private func stepCard(number: Int, title: LocalizedStringKey, body: LocalizedStringKey) -> some View {
        NoopCard {
            HStack(alignment: .top, spacing: 12) {
                Text(verbatim: String(format: "%02d", number))
                    .font(StrandFont.dot(44))
                    .tracking(StrandFont.dotTracking(44))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 62, alignment: .leading)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(StrandFont.book(16, relativeTo: .headline))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(body)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The ink hero: the three things NOOP does not have.
    private var privacyHero: some View {
        NoopHeroCard(glow: .ink, padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                NoopIconBadge("Private by design", icon: "lock-simple")
                HStack(alignment: .top, spacing: 0) {
                    zeroFigure("Accounts")
                    zeroFigure("Servers")
                    zeroFigure("Telemetry")
                }
                .padding(.top, 28)
                Text("No account. No server. No telemetry.")
                    .font(StrandFont.light(24, relativeTo: .title2))
                    .tracking(-0.5)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 28)
                Text("Switch off Wi-Fi and mobile data: NOOP keeps syncing and scoring as before.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            .padding(.bottom, 4)
        }
    }

    private func zeroFigure(_ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NoopDotNumber("0", size: 84)
            Text(label)
                .font(StrandFont.light(10.5, relativeTo: .caption2))
                .foregroundStyle(NoopMetric.heroLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Primer cards

    private var introCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                NoopCardHeader("The one rule", icon: "seal-check")
                Text("NOOP never shows you a number it had to make up. If a score isn't ready, it tells you why and what to do next. Everything here runs on your device, from your strap.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One primer section: glyph + overline + title, then the plain-English body. The glyph is
    /// decorative (hidden from VoiceOver); the card reads its title and body together.
    private func primerCard(_ section: Section) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    NoopIconTile(section.icon)
                    VStack(alignment: .leading, spacing: 2) {
                        NoopOverline(verbatim: section.overline)
                        Text(section.title)
                            .font(StrandFont.book(16, relativeTo: .headline))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Text(section.body)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(section.title). \(section.body)")
    }

    // MARK: - A7: "How your scores are computed" (named method families)

    /// The four scores, each named with the PUBLISHED method family it follows. Honest about the
    /// approach without faking precision: it cites the method, not a proprietary-identical claim. Order
    /// mirrors the app's score order (Charge, Effort, Rest, Fitness Age).
    private enum ScoreMethod: CaseIterable, Identifiable {
        case charge, effort, rest, fitnessAge
        var id: Self { self }

        var name: String {
            switch self {
            case .charge:     return String(localized: "Charge")
            case .effort:     return String(localized: "Effort")
            case .rest:       return String(localized: "Rest")
            case .fitnessAge: return String(localized: "Fitness Age")
            }
        }

        /// The plain-English description of the published method behind the score.
        var method: String {
            switch self {
            case .charge:
                return String(localized: "A baseline-normalized recovery score: your resting heart rate, sleep quality and night-to-night consistency, weighted against your own baseline, with heart-rate variability (rMSSD) leading wherever the strap gives us a clean reading.")
            case .effort:
                return String(localized: "A cardiovascular load from time in heart-rate zones (Edwards TRIMP): each zone is weighted so harder ones count for more, summed into one daily figure. Settings offers an exponential alternative (Banister) that credits short, hard efforts more.")
            case .rest:
                return String(localized: "Sleep scored from how long you slept versus how much you needed, how efficient the night was, and the restorative (deep and REM) share of it.")
            case .fitnessAge:
                return String(localized: "An estimated VO2max from the Nes / HUNT Fitness Study model (resting heart rate, age and activity), read against population norms to express it as a fitness age.")
            }
        }

        /// The short method-family tag shown as an overline next to the score name.
        var family: String {
            switch self {
            case .charge:     return String(localized: "RESTING HR + SLEEP + HRV")
            case .effort:     return String(localized: "BANISTER TRIMP / HR ZONES")
            case .rest:       return String(localized: "DURATION + EFFICIENCY + STAGES")
            case .fitnessAge: return String(localized: "NES / HUNT VO2MAX")
            }
        }

    }

    /// A7 , the "How your scores are computed" card: one row per score naming its published method
    /// family, honest about the approach without claiming a proprietary-identical result.
    private var scoringMethodsCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    NoopIconTile("function")
                    VStack(alignment: .leading, spacing: 2) {
                        NoopOverline("METHOD")
                        Text("How your scores are computed")
                            .font(StrandFont.book(16, relativeTo: .headline))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Text("Each score follows a published method, computed on your device. We name the method family so you can read up on it, and we never claim to reproduce another company's number exactly.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ScoreMethod.allCases) { method in
                        Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
                        methodRow(method)
                            .padding(.vertical, 12)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One score-method row: the score name + its method-family overline, then the plain-English method.
    private func methodRow(_ m: ScoreMethod) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(m.name)
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(m.family)
                    .font(StrandFont.overline)
                    .tracking(0.4)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer(minLength: 0)
            }
            Text(m.method)
                .font(StrandFont.light(12.5, relativeTo: .footnote))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(m.name). \(m.method)")
    }

    private var footerNote: some View {
        Text("NOOP never makes up a number. When it can't compute one honestly it tells you what's missing and what to do, rather than showing a fake value.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

/// The dotted Bluetooth link between the strap and the device nodes: a 2-on-4 dotted rule between
/// two small hollow rings.
private struct BluetoothLink: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, mid = geo.size.height / 2, r: CGFloat = 4
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: r * 2 + 1, y: mid))
                    p.addLine(to: CGPoint(x: w - r * 2 - 1, y: mid))
                }
                .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                Circle().stroke(StrandPalette.textPrimary, lineWidth: 1)
                    .frame(width: r * 2, height: r * 2)
                    .position(x: r + 1, y: mid)
                Circle().stroke(StrandPalette.textPrimary, lineWidth: 1)
                    .frame(width: r * 2, height: r * 2)
                    .position(x: w - r - 1, y: mid)
            }
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("How NOOP works") {
    HowNoopWorksView(onClose: {})
        .preferredColorScheme(.dark)
}
#endif
