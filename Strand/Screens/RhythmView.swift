import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics

// RhythmView.swift — EXPERIMENTAL beat-to-beat regularity VISUALIZATION (v5 "Rhythm").
//
// Spec: docs/superpowers/specs/2026-06-19-v5-rhythm-screening-design.md (§6, §9, §11).
//
// WHAT THIS SHIPS (and deliberately does NOT):
//   This is the §11 "ship at most a clearly-labelled visualization" path. It draws the
//   Poincaré scatter of the night's R-R cloud and the DESCRIPTIVE stats from
//   `RhythmScreener` (SD1/SD2, normalised RMSSD, ectopic fraction) plus a NEUTRAL
//   regularity label ("looked steady" / "some variation" / "varied more than usual").
//   It has NO clinical verdict, NO "see a clinician" call-to-action, NO disease name,
//   NO red/alarm styling, and NO probability-of-condition — the screening heads-up is
//   HELD per §11 and is not part of this UI.
//
// SELF-CONTAINED: the view takes the engine results (`NightRhythmSummary` + the per-window
// `WindowResult`s) via init. It does NOT touch AppModel. The consent record is a local
// `@AppStorage` flag (mirroring the `TermsGateView` clickwrap), so the whole feature is
// OFF by default and only computes/shows after the user reads the experimental,
// non-diagnostic disclaimer and ticks the un-pre-checked box. Central wiring (Wave 3)
// mounts `RhythmView` as an experimental item under Settings / Health behind this gate —
// see the task's `wiringNeeded`.

// MARK: - Consent record (local, version-stamped — mirrors `Terms`)

/// The on-device consent record for the experimental Rhythm visualization. Mirrors the
/// `Terms` clickwrap pattern: a CURRENT version is stored once the user accepts; bumping
/// the version on a MATERIAL change to the disclaimer re-prompts. Nothing computes or shows
/// until `accepted` is true. Default OFF.
public enum RhythmConsent {
    /// Bump on a material change to the experimental/non-diagnostic wording to re-prompt.
    public static let currentVersion = "1.0"
    /// `@AppStorage` key holding the accepted consent version ("" = never accepted).
    public static let acceptedVersionKey = "noopRhythmConsentVersion"
    /// `@AppStorage` key for the feature on/off flag (the `noopRhythmScreening` flag, default OFF).
    public static let enabledKey = "noopRhythmScreening"

    /// True when the stored accepted version matches the current one.
    public static func isAccepted(_ storedVersion: String) -> Bool {
        !storedVersion.isEmpty && storedVersion == currentVersion
    }

    /// The points the user must read before turning the feature on (spec §9). Each is its
    /// own line (head + body), like `Terms.points`. No condition name, no diagnosis, no
    /// "consider a clinician" verdict — this is a visualization, not a screen.
    public static let points: [(String, String)] = [
        (String(localized: "Experimental, and not a medical device"),
         String(localized: "This is an experimental wellness visualization of your beat-to-beat timing. It is NOT an ECG, and it cannot diagnose, detect, or rule out any heart condition.")),
        (String(localized: "It is a picture, not a verdict"),
         String(localized: "It shows the shape of your heartbeat timing and a plain-language description of how steady it looked. It does not tell you whether anything is right or wrong.")),
        (String(localized: "Variation is normal and often benign"),
         String(localized: "Beat-to-beat timing varies for many ordinary reasons: breathing, movement, an imperfect optical reading, or the occasional extra or skipped beat that most healthy people have.")),
        (String(localized: "It is not a substitute for a professional"),
         String(localized: "If you feel unwell or are worried about your heart, contact a qualified professional; in an emergency, your local emergency service. Do not rely on NOOP.")),
        (String(localized: "Everything stays on your device"),
         String(localized: "All of this is computed on your own device from data you already have. No heartbeat data leaves it.")),
    ]
}

// MARK: - The experimental, non-diagnostic disclaimer block (permanent, non-dismissible)

/// The standing experimental + non-diagnostic note shown at the foot of the visualization
/// (spec §6 "permanent, non-dismissible disclaimer block", §7 wording). Calm, neutral ink —
/// never red, never alarm. Reused at the bottom of every result state so the framing is always
/// present, even when the rhythm "looked steady".
private struct RhythmDisclaimerNote: View {
    var body: some View {
        NoopInsightRow("Experimental wellness visualization: not a diagnosis, not an ECG, and not a medical device. It cannot detect any heart condition. Beat-to-beat variation has many ordinary, benign causes. If you feel unwell or are worried, contact a qualified professional; in an emergency, your local emergency service. Everything is computed on your device.",
                       icon: "info")
            .padding(.horizontal, 4)
    }
}

// MARK: - Consent gate (clickwrap — mirrors `TermsGateView`)

/// Feature-specific consent gate, shown the FIRST time the user enables the Rhythm
/// visualization (and again if `RhythmConsent.currentVersion` changes). The user must tick
/// the un-pre-checked box and tap Accept; the accepted version is stored locally. Backing
/// out leaves the feature OFF. Mirrors `TermsGateView` exactly, but feature-scoped.
struct RhythmConsentGate: View {
    /// Called once the user accepts — the caller persists `RhythmConsent.currentVersion`
    /// and flips the feature on.
    let onAccept: () -> Void
    /// Called when the user backs out without accepting — the feature stays OFF.
    var onCancel: (() -> Void)? = nil

    @State private var checked = false
    @Environment(\.isPresented) private var isPresented
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                // Close: backs out without accepting, so the feature stays OFF.
                HStack {
                    Spacer()
                    if onCancel != nil || isPresented {
                        NoopCircleButton("x", accessibilityLabel: "Close Rhythm") {
                            if let onCancel { onCancel() } else { dismiss() }
                        }
                    }
                }
                .frame(minHeight: 42)

                NoopHeroCard(glow: .ink, padding: 22) {
                    VStack(alignment: .leading, spacing: 0) {
                        NoopIconBadge("Rhythm", icon: "heartbeat")
                        Text("Before you turn on Rhythm")
                            .font(StrandFont.title1)
                            .tracking(-0.56)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 44)
                        Text("An experimental picture of your beat-to-beat timing. Please read these first.")
                            .font(StrandFont.light(14, relativeTo: .subheadline))
                            .foregroundStyle(Color.white.opacity(0.62))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 10)
                    }
                }

                NoopList {
                    ForEach(RhythmConsent.points, id: \.0) { point in
                        HStack(alignment: .top, spacing: 14) {
                            PhIcon("check", size: 14)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(NoopVisualStyle.raised))
                                .overlay(Circle().strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(point.0)
                                    .font(StrandFont.book(15, relativeTo: .body))
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(point.1)
                                    .font(StrandFont.light(12, relativeTo: .caption))
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .accessibilityElement(children: .combine)
                    }
                }

                Text("This is a wellness visualization, not a screening test. It does not tell you to see a clinician and it names no condition. This is not legal or medical advice.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)

                // The un-pre-checked acknowledgement.
                Button { checked.toggle() } label: {
                    HStack(alignment: .center, spacing: 12) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(checked ? StrandPalette.textPrimary : Color.clear)
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(checked ? Color.clear : NoopVisualStyle.borderHighlight, lineWidth: 1.5))
                            .overlay { if checked { PhIcon("check", weight: .fill, size: 14).foregroundStyle(NoopVisualStyle.canvas) } }
                            .frame(width: 24, height: 24)
                        Text("I understand this is an experimental wellness feature, not a medical device or a diagnosis.")
                            .font(StrandFont.book(14, relativeTo: .subheadline))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .noopPanel(cornerRadius: NoopVisualStyle.listRadius)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(checked ? [.isButton, .isSelected] : .isButton)

                Button(action: onAccept) {
                    Text("Turn on Rhythm")
                }
                .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                .disabled(!checked)   // the kit style dims a disabled button itself
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)

                if let onCancel {
                    Button("Not now", action: onCancel)
                        .buttonStyle(.noopGhost)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, NoopMetrics.screenHPadding)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        #if os(iOS)
        // #697/#horizontal-swipe parity, see ScreenScaffold.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        #if os(iOS) && DEBUG
        .modifier(DemoScrollAnchor())
        #endif
        .background(NoopVisualStyle.canvas.ignoresSafeArea())
    }
}

// MARK: - Poincaré scatter plot (Canvas, design-tokened)

/// The signature visualization: a Poincaré scatter of successive (NN[i], NN[i+1]) pairs.
/// A steady rhythm draws a tight elongated comet along the diagonal; a more variable one
/// draws a rounder, more diffuse cloud. Purely descriptive — drawn in neutral white on a neutral
/// glow (never red). A scale grid, the identity diagonal for reference, and — when the stats are
/// known — the cloud's long (SD2) and short (SD1) axes. Decorative for accessibility (the numbers
/// + label carry the meaning).
private struct PoincarePlot: View {
    let points: [RhythmScreener.PoincarePoint]
    /// The cloud's descriptive axes (SD1, SD2) in ms, drawn through its centre when both are known.
    var sd1: Double?
    var sd2: Double?

    /// Fixed physiological plot bounds (ms) so the same rhythm always reads at the same
    /// scale night-to-night — 300…1500 ms covers ~40…200 bpm, the readable resting band.
    private let lo: Double = 300
    private let hi: Double = 1500
    private let ticks: [Double] = [300, 600, 900, 1200, 1500]

    var body: some View {
        GeometryReader { geo in
            let axisW: CGFloat = 30, axisH: CGFloat = 16
            let side = min(geo.size.width - axisW, geo.size.height - axisH)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let s = side
                    func map(_ v: Double) -> CGFloat {
                        let clamped = Swift.min(Swift.max(v, lo), hi)
                        return CGFloat((clamped - lo) / (hi - lo)) * s
                    }
                    let ox = axisW
                    // Grid + axes.
                    var grid = Path()
                    for t in ticks.dropFirst().dropLast() {
                        grid.move(to: CGPoint(x: ox + map(t), y: 0)); grid.addLine(to: CGPoint(x: ox + map(t), y: s))
                        grid.move(to: CGPoint(x: ox, y: s - map(t))); grid.addLine(to: CGPoint(x: ox + s, y: s - map(t)))
                    }
                    ctx.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)
                    var axes = Path()
                    axes.move(to: CGPoint(x: ox, y: 0)); axes.addLine(to: CGPoint(x: ox, y: s))
                    axes.addLine(to: CGPoint(x: ox + s, y: s))
                    ctx.stroke(axes, with: .color(.white.opacity(0.3)), lineWidth: 1)

                    // Identity diagonal (NN[i] == NN[i+1]) — the line a perfectly metronomic
                    // beat would sit on. For reference only.
                    var diag = Path()
                    diag.move(to: CGPoint(x: ox, y: s))
                    diag.addLine(to: CGPoint(x: ox + s, y: 0))
                    ctx.stroke(diag, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                    // The point cloud. Small, semi-transparent dots so density reads as a cloud.
                    let r: CGFloat = 1.6
                    for p in points {
                        let x = ox + map(p.x)
                        let y = s - map(p.y)     // Canvas y grows downward; higher NN[i+1] sits higher.
                        ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                                 with: .color(.white.opacity(0.42)))
                    }

                    // The descriptive axes through the cloud's centre: SD2 along the diagonal, SD1 across it.
                    if let sd1, let sd2, !points.isEmpty {
                        let mx = points.map(\.x).reduce(0, +) / Double(points.count)
                        let my = points.map(\.y).reduce(0, +) / Double(points.count)
                        let c = CGPoint(x: ox + map(mx), y: s - map(my))
                        let k = s / CGFloat(hi - lo) / CGFloat(2.0.squareRoot())
                        let l2 = CGFloat(sd2) * 2 * k, l1 = CGFloat(sd1) * 2 * k
                        var axis = Path()
                        axis.move(to: CGPoint(x: c.x - l2, y: c.y + l2)); axis.addLine(to: CGPoint(x: c.x + l2, y: c.y - l2))
                        axis.move(to: CGPoint(x: c.x - l1, y: c.y - l1)); axis.addLine(to: CGPoint(x: c.x + l1, y: c.y + l1))
                        ctx.stroke(axis, with: .color(.white.opacity(0.9)), lineWidth: 1)
                    }
                }
                .frame(width: axisW + side, height: side)

                // Tick labels.
                ForEach(ticks.dropFirst(), id: \.self) { t in
                    Text(verbatim: "\(Int(t))")
                        .font(StrandFont.light(9.5))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .frame(width: axisW - 4, alignment: .trailing)
                        .position(x: (axisW - 4) / 2, y: side - CGFloat((t - lo) / (hi - lo)) * side)
                }
                ForEach(ticks.dropLast(), id: \.self) { t in
                    Text(verbatim: "\(Int(t))")
                        .font(StrandFont.light(9.5))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .fixedSize()
                        .position(x: axisW + CGFloat((t - lo) / (hi - lo)) * side, y: side + 10)
                }
            }
            .frame(width: axisW + side, height: side + axisH)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

// MARK: - The visualization screen

/// The experimental Rhythm visualization. Self-contained: takes the engine outputs via
/// init (the night summary + the per-window results, whose `poincare` clouds + stats it
/// renders). Shows the consent gate first if consent hasn't been recorded for the current
/// version. NEVER edits AppModel.
struct RhythmView: View {

    /// The night's descriptive roll-up from `RhythmScreener.summarizeNight`, or nil when
    /// nothing readable has been computed yet (thin/garbage night, or feature just enabled).
    let night: RhythmScreener.NightRhythmSummary?
    /// The per-window results for the night, in time order. Their `poincare` clouds are
    /// pooled for the plot and their stats drive the descriptive tiles. May be empty.
    let windows: [RhythmScreener.WindowResult]
    /// Why the night is empty (#1360) — picks WHICH honest empty-state copy shows when there is nothing
    /// to plot. `.gatheringData` (the "try again" state) is the default for previews and any caller that
    /// doesn't diagnose the reason.
    let emptyReason: RhythmEmptyState
    /// Optional dismissal hook when presented as a sheet.
    var onClose: (() -> Void)? = nil

    init(night: RhythmScreener.NightRhythmSummary?,
         windows: [RhythmScreener.WindowResult],
         emptyReason: RhythmEmptyState = .gatheringData,
         onClose: (() -> Void)? = nil) {
        self.night = night
        self.windows = windows
        self.emptyReason = emptyReason
        self.onClose = onClose
    }

    // Local consent record — the feature is OFF until the user passes the gate. Mirrors the
    // Terms clickwrap; no AppModel involvement.
    @AppStorage(RhythmConsent.acceptedVersionKey) private var acceptedVersion = ""
    @AppStorage(RhythmConsent.enabledKey) private var enabled = false

    /// The "How this is measured" note, one tap away.
    @State private var showsMethod = false

    private var consentGiven: Bool {
        enabled && RhythmConsent.isAccepted(acceptedVersion)
    }

    var body: some View {
        Group {
            if consentGiven {
                visualization
            } else {
                RhythmConsentGate(
                    onAccept: {
                        acceptedVersion = RhythmConsent.currentVersion
                        enabled = true
                    },
                    onCancel: onClose
                )
            }
        }
        .noopHidesSystemNavBar()
    }

    // MARK: Visualization (post-consent)

    /// The readable window whose stats we headline — prefer the most-varied readable
    /// window so the "what a diffuse cloud looks like" example is the informative one;
    /// fall back to the first readable window, then nil.
    private var headlineWindow: RhythmScreener.WindowResult? {
        let readable = windows.filter { $0.label != .unreadable }
        return readable.first(where: { $0.label == .varied })
            ?? readable.first(where: { $0.label == .occasionalEctopy })
            ?? readable.first
    }

    /// All Poincaré points across the night's readable windows, pooled for one plot.
    private var allPoints: [RhythmScreener.PoincarePoint] {
        windows.flatMap { $0.poincare }
    }

    /// #1298: the temp .csv URL for the share sheet, written ONCE by `.task` (below) — not in `body`,
    /// so rendering never touches disk. nil until the write lands / when nothing is readable.
    @State private var rhythmExportURL: URL?

    /// Write the night's DESCRIPTIVE data to a temp .csv for the OS share sheet — the §11 "share with
    /// my clinician" path. Neutral data ONLY (`RhythmExport` forbids any verdict / condition name); nil
    /// when nothing readable. A tiny, atomic write, run off the render path from `.task`.
    private func buildRhythmExportURL() -> URL? {
        guard let night, !windows.isEmpty else { return nil }
        let csv = RhythmExport.csv(summary: night, windows: windows)
        let url = NoopScratch.file("rhythm.csv")
        return (try? csv.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    private var visualization: some View {
        ScreenScaffold(
            title: nil,
            // PERF: chart-heavy column (the Poincaré beat-to-beat scatter and the stats grid). The
            // LazyVStack path builds the off-screen cards — including the scatter's point set — on demand.
            lazy: true
        ) {
            NoopScreenHeader("Rhythm") {
                NoopPill("Experimental", compact: true)
            }
            .padding(.bottom, 8)
            .task(id: windows.count) { rhythmExportURL = buildRhythmExportURL() }

            if allPoints.isEmpty {
                emptyState
            } else {
                heroCard
                statsSection
            }

            NoopList {
                Button { showsMethod = true } label: {
                    NoopRow(title: Text("How this is measured"),
                            caption: Text("Quiet, still windows only · SD1, SD2 and regularity"),
                            icon: "book-open", chevron: true) { EmptyView() }
                }
                .buttonStyle(.plain)
                if let rhythmExportURL {
                    // #1298: hand the clinician the DATA, never a verdict. A neutral CSV export.
                    ShareLink(item: rhythmExportURL) {
                        NoopRow(title: Text("Share"), caption: Text("The night's descriptive numbers as a CSV"),
                                icon: "export", chevron: true) { EmptyView() }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, allPoints.isEmpty ? 0 : 14)
            RhythmDisclaimerNote()
                .padding(.top, 8)
        }
        .sheet(isPresented: $showsMethod) { methodologySheet }
    }

    // MARK: Hero — the scatter and the neutral, plain-language headline (NO verdict)

    private var heroCard: some View {
        // Neutral ink glow, never the heart red: this screen must not read as an alarm (§11).
        NoopHeroCard(glow: .ink, padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Last night · beat-to-beat scatter")
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.white.opacity(0.8))
                        Text("Each dot pairs one heartbeat interval with the next.")
                            .font(StrandFont.light(12, relativeTo: .caption))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                    Spacer(minLength: 8)
                    ScoreStatePill(confidenceState, text: confidenceText)
                }
                PoincarePlot(points: allPoints, sd1: headlineWindow?.sd1, sd2: headlineWindow?.sd2)
                    .padding(.top, 18)
                Text("RRn across · RRn+1 up · ms")
                    .font(StrandFont.footnote)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                    .padding(.leading, 24)
                HStack(alignment: .center, spacing: 10) {
                    NoopTag(verbatim: chipLabel(regularity), size: 12).fixedSize()
                    Text(headlineDetail)
                        .font(StrandFont.light(14, relativeTo: .subheadline))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 14)
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1) }
                .padding(.top, 16)
            }
        }
    }

    private var regularity: RhythmRegularity { night?.overall ?? headlineWindow?.label ?? .unreadable }

    /// The SHORT neutral status word for the tag (the sentence-length `headlineDetail` reads beside it).
    /// Non-diagnostic wording.
    private func chipLabel(_ label: RhythmRegularity) -> String {
        switch label {
        case .steady:           return String(localized: "Steady")
        case .occasionalEctopy: return String(localized: "Some variation")
        case .varied:           return String(localized: "More varied")
        case .unreadable:       return String(localized: "No clear reading")
        }
    }

    // MARK: The numbers — the descriptive stats (2 × 3 tiles)

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("The numbers", captionKey: "DESCRIPTIVE STATS")
            Grid(horizontalSpacing: NoopMetrics.gap, verticalSpacing: NoopMetrics.gap) {
                GridRow {
                    statTile("SHORT AXIS", value: fmt(headlineWindow?.sd1, digits: 0), unit: "ms",
                             caption: "SD1 · ms")
                    statTile("LONG AXIS", value: fmt(headlineWindow?.sd2, digits: 0), unit: "ms",
                             caption: "SD2 · ms")
                }
                GridRow {
                    statTile("CLOUD SHAPE", value: fmt(headlineWindow?.sd1sd2, digits: 2), unit: nil,
                             caption: "SD1:SD2 ratio")
                    statTile("BEAT-TO-BEAT", value: percent(headlineWindow?.normRmssd), unit: nil,
                             caption: "variation index")
                }
                GridRow {
                    statTile("EXTRA / SKIPPED", value: percent(headlineWindow?.ectopicFraction), unit: nil,
                             caption: "of beats")
                    statTile("BEATS READ", value: headlineWindow.map { $0.nBeats.formatted(.number.locale(AppLanguage.activeLocale)) } ?? "—", unit: nil,
                             caption: "clean intervals")
                }
            }
        }
    }

    private func statTile(_ label: LocalizedStringKey, value: String, unit: String?,
                          caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(StrandFont.overlineScaled(10))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(StrandPalette.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value)
                    .font(StrandFont.value(26, weight: 300))
                    .tracking(-0.52)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let unit {
                    Text(verbatim: unit)
                        .font(StrandFont.book(11))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.top, 10)
            Text(caption)
                .font(StrandFont.light(10.5, relativeTo: .caption2))
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.top, 5)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .noopPanel()
        .accessibilityElement(children: .combine)
    }

    // MARK: Empty / thin-night state

    /// #1360: a TRUTHFUL empty state. When every window was refused for a *capture* reason the device can
    /// never satisfy — its beats arrive banked, or it records no stillness signal at all — say so, instead
    /// of the "try again after a settled night" copy that is a lie when tomorrow is structurally identical.
    /// `.gatheringData`/`.none` keep the original "no clear reading yet" wording (a genuine try-again).
    private var emptyState: some View {
        let title: LocalizedStringKey
        let message: LocalizedStringKey
        switch emptyReason {
        case .deviceBanksBeats:
            title = "This device can't support a rhythm reading"
            message = "Rhythm needs beat-to-beat timing measured one beat at a time. Your device stores its heartbeats in batches, so the exact spacing between them isn't recoverable. Nothing is wrong with your night."
        case .deviceNoMotion:
            title = "This device can't support a rhythm reading"
            message = "Rhythm reads only during still, resting windows, and this device doesn't record the stillness signal it needs to find them. Nothing is wrong with your night."
        case .none, .gatheringData:
            title = "No clear reading yet"
            message = "Rhythm only looks during quiet, still, resting windows, so it needs a calm night's worth of steady beats. Once there's a clean window, the scatter and its description show here."
        }
        return G5EmptyCard(icon: "wave-sine", title: title, message: Text(message))
    }

    // MARK: Methodology

    private var methodologySheet: some View {
        VStack(spacing: 0) {
            NoopSheetHeader("How this is measured", cancelTitle: "Done", doneTitle: nil,
                            onCancel: { showsMethod = false })
            ScrollView {
                Text("During quiet, still, resting windows, NOOP looks at the timing between your heartbeats (R-R intervals) and draws their Poincaré scatter. From the cloud it computes its short and long axes (SD1, SD2) and a few plain regularity numbers. Movement and noisy windows are skipped, not shown. These are transparent, published descriptive statistics: a picture of your timing, never a clinical measurement.")
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NoopMetrics.screenHPadding)
                    .padding(.bottom, 30)
            }
        }
        .background(NoopSheetBackground())
        #if os(iOS)
        .noopSheetPresentation(largeFirst: false)
        #else
        .frame(width: 480, height: 360)
        #endif
    }

    // MARK: - Copy mapping (neutral, non-clinical — NO verdict, NO condition name)

    private var headlineDetail: String {
        switch regularity {
        case .steady:
            return String(localized: "Across the quiet windows we could read, your beat-to-beat timing held a tight, even shape.")
        case .occasionalEctopy:
            return String(localized: "Mostly steady, with a few isolated extra or skipped beats. Very common and usually nothing.")
        case .varied:
            return String(localized: "The scatter looked rounder and more spread out than a tight, steady beat. This has many ordinary causes and is not a diagnosis.")
        case .unreadable:
            return String(localized: "There wasn't a calm, still window clean enough to describe. Try again after a settled night.")
        }
    }

    /// Confidence pill state from the headline window's read certainty.
    private var confidenceState: ScoreState {
        switch headlineWindow?.confidence ?? .calibrating {
        case .solid:       return .solid
        case .building:    return .building
        case .calibrating: return .calibrating
        }
    }

    /// Honest confidence line so a thin night reads truthfully (spec §6).
    private var confidenceText: LocalizedStringKey {
        let readable = night?.readableWindows ?? windows.filter { $0.label != .unreadable }.count
        switch headlineWindow?.confidence ?? .calibrating {
        case .solid:       return "Solid"
        case .building:    return readable <= 1 ? "Building (1 window)" : "Building"
        case .calibrating: return "Calibrating"
        }
    }

    // MARK: - Formatting

    private func fmt(_ value: Double?, digits: Int) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(digits)).locale(AppLanguage.activeLocale))
    }

    /// A 0…1 fraction rendered as a whole-number percent (normalised RMSSD / ectopic fraction).
    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }
}

#if DEBUG
#Preview("Rhythm — steady") {
    RhythmView(
        night: RhythmScreener.NightRhythmSummary(
            readableWindows: 6, steadyWindows: 6, occasionalWindows: 0,
            variedWindows: 0, variationRecurred: false, overall: .steady),
        windows: [
            RhythmScreener.WindowResult(
                label: .steady, sd1: 28, sd2: 74, sd1sd2: 0.38,
                normRmssd: 0.05, turningPointRate: 0.7, ectopicFraction: 0.01,
                nBeats: 240, confidence: .solid, agreedAcrossSources: false,
                poincare: (0..<240).map { i in
                    let base = 900.0 + sin(Double(i) * 0.3) * 30
                    return RhythmScreener.PoincarePoint(x: base, y: base + 18)
                })
        ]
    )
    .preferredColorScheme(.dark)
}

/// Render targets for `--demo-screen rhythm` / `rhythm-consent`: the visualization from a fixture night
/// (marking consent as given on the demo device), or the consent gate itself.
struct RhythmDemoHost: View {
    var showsConsent = false
    @AppStorage(RhythmConsent.acceptedVersionKey) private var acceptedVersion = ""
    @AppStorage(RhythmConsent.enabledKey) private var enabled = false

    var body: some View {
        if showsConsent {
            RhythmConsentGate(onAccept: {}, onCancel: {})
        } else {
            RhythmView(night: Self.night, windows: Self.windows)
                .onAppear {
                    acceptedVersion = RhythmConsent.currentVersion
                    enabled = true
                }
        }
    }

    private static let night = RhythmScreener.NightRhythmSummary(
        readableWindows: 6, steadyWindows: 6, occasionalWindows: 0,
        variedWindows: 0, variationRecurred: false, overall: .steady)

    private static let windows = [
        RhythmScreener.WindowResult(
            label: .steady, sd1: 28, sd2: 74, sd1sd2: 0.38,
            normRmssd: 0.05, turningPointRate: 0.7, ectopicFraction: 0.01,
            nBeats: 240, confidence: .solid, agreedAcrossSources: false,
            poincare: (0..<240).map { i in
                let base = 980.0 + sin(Double(i) * 0.3) * 60 + cos(Double(i) * 0.11) * 50
                return RhythmScreener.PoincarePoint(x: base, y: base + 18 + sin(Double(i) * 1.7) * 22)
            })
    ]
}
#endif
