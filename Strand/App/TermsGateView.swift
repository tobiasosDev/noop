import SwiftUI
import StrandDesign

/// First-run acknowledgment gate (clickwrap). Shown over EVERYTHING — before onboarding, pairing, or
/// any Bluetooth access — until the current `Terms.currentVersion` is accepted, and again if the
/// terms materially change. The user must tick the (un-pre-checked) box and tap Accept; the accepted
/// version is then stored locally, the on-device equivalent of a consent record. See `Terms` / `TERMS.md`.
struct TermsGateView: View {
    let onAccept: () -> Void
    /// One flag per `Terms.attestations` entry; every one must be ticked before Accept enables.
    @State private var checks: [Bool] = Array(repeating: false, count: Terms.attestations.count)
    /// The plain-English points (`Terms.points`) open in a sheet from the "Full terms" chip.
    @State private var showPoints = false

    init(onAccept: @escaping () -> Void) {
        self.onAccept = onAccept
    }

    #if DEBUG
    /// Screenshot harness only: open with the first `checked` attestations already ticked, and
    /// optionally with the "Full terms" sheet up.
    init(onAccept: @escaping () -> Void, debugChecked checked: Int, debugShowPoints: Bool = false) {
        self.onAccept = onAccept
        _checks = State(initialValue: (0..<Terms.attestations.count).map { $0 < checked })
        _showPoints = State(initialValue: debugShowPoints)
    }
    #endif

    private var allChecked: Bool { checks.allSatisfy { $0 } }
    private var checkedCount: Int { checks.filter { $0 }.count }

    var body: some View {
        ZStack {
            NoopVisualStyle.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    TermsProgressHero(checked: checkedCount, total: checks.count)
                        .padding(.top, 8)
                    intro
                        .padding(.top, 26)
                    checklist
                        .padding(.top, 20)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
            #if os(iOS)
            // #697/#horizontal-swipe parity, see ScreenScaffold. Shown before onboarding/pairing,
            // on top of everything, so this is the very first screen a new install sees.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            #if os(iOS) && DEBUG
            .modifier(DemoScrollAnchor())
            #endif
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            #if os(macOS)
            .frame(maxWidth: 560, maxHeight: 720)
            #else
            .frame(maxWidth: 560)
            #endif
        }
        .sheet(isPresented: $showPoints) {
            TermsPointsSheet(onClose: { showPoints = false })
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Text(verbatim: "NOOP")
                .font(StrandFont.dot(22))
                .tracking(StrandFont.dotTracking(22))
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button { showPoints = true } label: {
                NoopChip("Full terms", icon: "file-text")
            }
            .buttonStyle(.plain)
        }
        .frame(height: 50)
        .padding(.top, 4)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Before you use NOOP")
                .font(StrandFont.title1)
                .tracking(-0.56)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(introCopy)
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .lineSpacing(3)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var introCopy: String {
        String(localized: "Independent software that you installed yourself. It reads your strap, keeps every number on \(Platform.deviceNounPhrase), and asks for nothing back.")
    }

    private var checklist: some View {
        NoopList {
            ForEach(Array(Terms.attestations.enumerated()), id: \.offset) { idx, line in
                TermsCheckRow(text: line, isOn: Binding(get: { checks[idx] }, set: { checks[idx] = $0 }))
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Group {
                if allChecked {
                    Button(action: onAccept) { Text("Accept & Continue") }
                        .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                } else {
                    Button(action: onAccept) { Text("Accept & Continue") }
                        .buttonStyle(TermsLockedButtonStyle())
                }
            }
            .disabled(!allChecked)
            .keyboardShortcut(.defaultAction)

            Text(footerCaption)
                .font(StrandFont.footnote)
                .tracking(0.11)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(NoopVisualStyle.canvas.ignoresSafeArea())
        // The kit's `.fade`: the list dissolves into the pinned footer instead of being cut by an edge.
        .background(alignment: .top) {
            LinearGradient(colors: [NoopVisualStyle.canvas.opacity(0), NoopVisualStyle.canvas],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 28)
                .offset(y: -28)
                .allowsHitTesting(false)
        }
    }

    /// The licence and the installed build, so a support report can quote exactly which build was
    /// accepted.
    private var footerCaption: String {
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        return String(localized: "PolyForm Noncommercial 1.0.0 · version \(UpdateWatch.installedVersion) (\(build))")
    }
}

/// The ink hero: one ring segment per attestation (lit as each is ticked), the ticked count in the
/// dot-matrix face, and the one-line instruction.
private struct TermsProgressHero: View {
    let checked: Int
    let total: Int

    var body: some View {
        NoopHeroCard(glow: .ink, padding: 0) {
            HStack(spacing: 22) {
                ring
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        PhIcon("seal-check", size: 14)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.white.opacity(0.10)))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                        Text("The fine print")
                            .font(StrandFont.book(13, relativeTo: .subheadline))
                    }
                    .foregroundStyle(StrandPalette.textPrimary)
                    VStack(alignment: .leading, spacing: 3) {
                        // Wraps rather than truncating: German ("Tippe auf jede Zeile, um sie zu
                        // bestätigen.") does not fit one line beside the ring.
                        Text("Tap each line to confirm it.")
                        Text("All \(total) unlock the app.")
                    }
                    .font(StrandFont.subhead)
                    .foregroundStyle(Color.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
        }
    }

    private var ring: some View {
        ZStack {
            TermsSegmentRing(segments: total, lit: checked)
                .frame(width: 112, height: 112)
            VStack(spacing: 4) {
                Text(verbatim: "\(checked)")
                    .font(StrandFont.dot(52))
                    .tracking(StrandFont.dotTracking(52))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.leading, 4)
                Text("of \(total)")
                    .font(StrandFont.footnote)
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(checked) of \(total) confirmed"))
    }
}

/// A ring cut into `segments` arcs with a gap centred at the top; the first `lit` arcs are drawn in ink.
private struct TermsSegmentRing: View {
    let segments: Int
    let lit: Int

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            // The 104-unit design ring: radius 42, stroke 4.5, a 12-unit gap between arcs.
            let scale = d / 104
            let lineWidth = 4.5 * scale
            let radius = 42 * scale
            let circumference = 2 * Double.pi * Double(radius)
            let gap = 12 * Double(scale) / circumference
            let n = max(segments, 1)
            ZStack {
                ForEach(0..<n, id: \.self) { i in
                    let from = Double(i) / Double(n) + gap / 2
                    let to = Double(i + 1) / Double(n) - gap / 2
                    Circle()
                        .trim(from: from, to: max(from, to))
                        .stroke(i < lit ? StrandPalette.textPrimary : Color.white.opacity(0.12),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: radius * 2, height: radius * 2)
                }
            }
            .frame(width: d, height: d)
            .animation(StrandMotion.interactive, value: lit)
        }
        .accessibilityHidden(true)
    }
}

/// One attestation row: a round check at the leading edge; the whole row toggles.
private struct TermsCheckRow: View {
    let text: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(StrandMotion.interactive) { isOn.toggle() }
            StrandHaptic.selection.play()
        } label: {
            HStack(alignment: .top, spacing: 14) {
                check.padding(.top, -2)
                Text(text)
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(isOn ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
        .accessibilityValue(isOn ? Text("Confirmed") : Text("Not confirmed"))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var check: some View {
        if isOn {
            // The filled check-circle reads as an ink disc with the check cut out of it.
            PhIcon("check-circle", weight: .fill, size: 29.5)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 24, height: 24)
        } else {
            Circle()
                .strokeBorder(StrandPalette.textPrimary.opacity(0.26), lineWidth: 1.5)
                .frame(width: 24, height: 24)
        }
    }
}

/// The locked Accept pill: a dark raised capsule with tertiary ink, so it reads as "not yet" rather
/// than as a dimmed primary button.
private struct TermsLockedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StrandFont.medium(15, relativeTo: .body))
            .lineLimit(1)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: NoopButtonMetrics.height)
            .background(Capsule(style: .continuous).fill(NoopVisualStyle.raised))
            .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
    }
}

/// The plain-English summary of `TERMS.md` (`Terms.points`), opened from the gate's "Full terms" chip.
private struct TermsPointsSheet: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            NoopSheetHeader("Full terms", cancelTitle: "Close", doneTitle: nil, onCancel: onClose)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    NoopList {
                        ForEach(Terms.points, id: \.0) { point in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(point.0)
                                    .font(StrandFont.book(15, relativeTo: .body))
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(point.1)
                                    .font(StrandFont.subhead)
                                    .lineSpacing(2)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 15)
                        }
                    }
                    Text("The full terms are in TERMS.md, shipped with NOOP. This is not legal advice.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(NoopSheetBackground())
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #else
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }
}
