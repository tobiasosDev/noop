//  MacShellV2.swift
//  NOOP v2 · the macOS shell's building blocks: the sidebar rows, section labels and strap pill, and the
//  menu-bar extra's compact score card (after the "Widgets" board's Medium widget).
//
//  Pure presentation over StrandDesign: every value arrives resolved by the shell that owns the data
//  (`RootView`, `MenuBarContent`), so these views carry no model and render the same in a preview.

import SwiftUI
import StrandDesign

// MARK: - Sidebar

/// A sidebar section label (the kit's `.over`) that folds its group: the overline and a small caret.
struct MacSidebarSectionHeader: View {
    let title: LocalizedStringKey
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).strandOverline()
                Spacer(minLength: 4)
                PhIcon(isExpanded ? "caret-down" : "caret-right", size: 10)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One sidebar destination: its Phosphor glyph and title. The selected row sits in the inset capsule of
/// the segmented control's active segment (`.seg span.on`) in full ink; the others read in secondary ink
/// and lift a faint wash under the pointer.
struct MacSidebarRow: View {
    let title: Text
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                PhIcon(icon, size: 16)
                title
                    .font(StrandFont.book(13))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? StrandPalette.textPrimary : StrandPalette.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(NoopVisualStyle.inset)
                        .overlay(Capsule(style: .continuous)
                            .strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
                } else if hovering {
                    Capsule(style: .continuous).fill(Color.white.opacity(0.04))
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The strap pill at the foot of the sidebar (the Today header's `.strap`): a status dot, the connection
/// word and the battery line.
struct MacSidebarStatusPill: View {
    let status: String
    let detail: String
    let dot: Color
    /// A soft halo on the dot while a link is up.
    let isLive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
                .background(Circle().fill(dot.opacity(isLive ? 0.22 : 0)).frame(width: 16, height: 16))
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: status)
                    .font(StrandFont.book(12))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Text(verbatim: detail)
                    .font(StrandFont.light(11))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 9)
        .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Score ring

/// The compact score ring of the Widgets board: a dark track, the score's arc in its domain colour, a
/// white knob at the arc's end and the dot-matrix number inside. A nil `fraction` draws the track only.
struct V2ScoreRing: View {
    let fraction: Double?
    let value: String?
    let tint: Color
    var diameter: CGFloat = 62

    var body: some View {
        let line = diameter * 0.073
        let radius = (diameter - line) / 2
        let numberSize = diameter * 0.27
        ZStack {
            Circle().stroke(Color.white.opacity(0.10), lineWidth: line)
            if let fraction, fraction > 0 {
                let f = min(fraction, 1)
                let angle = Angle.degrees(-90 + 360 * f).radians
                Circle().trim(from: 0, to: f)
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle().fill(Color.white)
                    .frame(width: line * 1.2, height: line * 1.2)
                    .shadow(color: .white.opacity(0.7), radius: 3)
                    .offset(x: radius * CGFloat(cos(angle)), y: radius * CGFloat(sin(angle)))
            }
            Text(verbatim: value ?? "–")
                .font(StrandFont.dot(numberSize))
                .tracking(StrandFont.dotTracking(numberSize))
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, line + 3)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

// MARK: - Menu-bar score card

/// What the menu-bar card shows, resolved from the live model by `MenuBarContent`.
struct MenuBarScoreSnapshot {
    enum Link { case streaming, connected, offline }

    var dateText: String
    var link: Link
    /// Today's Charge, 0–100.
    var charge: Double?
    /// Effort as a 0…1 fill, and its number on the user's scale.
    var effortFraction: Double?
    var effortText: String?
    /// Rest, 0–100.
    var rest: Double?
    var liveHR: Int?
    var strapBattery: Double?
}

/// The menu-bar extra's lit card, laid out like the Widgets board's Medium widget: the NOOP wordmark, the
/// date and the link pill on top, then the Charge / Effort / Rest rings beside the live heart rate and the
/// strap's charge. Its glow follows the Charge band; with no Charge it stays ink.
struct MenuBarScoreCard: View {
    let snapshot: MenuBarScoreSnapshot

    var body: some View {
        NoopHeroCard(glow: NoopGlow.charge(snapshot.charge), padding: 16,
                     cornerRadius: NoopVisualStyle.listRadius) {
            VStack(alignment: .leading, spacing: 16) {
                header
                HStack(alignment: .center, spacing: 0) {
                    HStack(alignment: .top, spacing: 8) {
                        scoreRing(fraction: snapshot.charge.map { $0 / 100 }, value: whole(snapshot.charge),
                             tint: StrandPalette.recoveryColor(snapshot.charge ?? 0), label: "Charge")
                        scoreRing(fraction: snapshot.effortFraction, value: snapshot.effortText,
                             tint: StrandPalette.effortColor, label: "Effort")
                        scoreRing(fraction: snapshot.rest.map { $0 / 100 }, value: whole(snapshot.rest),
                             tint: StrandPalette.restColor, label: "Rest")
                    }
                    // The rings keep their natural width; the live column takes what is left.
                    .fixedSize(horizontal: true, vertical: false)
                    Rectangle()
                        .fill(NoopVisualStyle.borderHighlight)
                        .frame(width: 1)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 12)
                    sideColumn
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: "NOOP")
                .font(StrandFont.dot(14))
                .tracking(StrandFont.dotTracking(14) * 1.5)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(verbatim: snapshot.dateText)
                .font(StrandFont.light(11))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            linkPill
        }
    }

    /// The `.ld` link pill: a dot with a faint halo and the link's word.
    private var linkPill: some View {
        let (word, dot): (LocalizedStringKey, Color) = {
            switch snapshot.link {
            case .streaming: return ("Streaming", StrandPalette.statusPositive)
            case .connected: return ("Connected", StrandPalette.textPrimary)
            case .offline:   return ("Offline", StrandPalette.textTertiary)
            }
        }()
        return HStack(spacing: 7) {
            Circle().fill(dot)
                .frame(width: 6, height: 6)
                .background(Circle().fill(Color.white.opacity(0.12)).frame(width: 12, height: 12))
            Text(word)
                .font(StrandFont.book(11))
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
    }

    private func scoreRing(fraction: Double?, value: String?, tint: Color, label: LocalizedStringKey) -> some View {
        VStack(spacing: 6) {
            V2ScoreRing(fraction: fraction, value: value, tint: tint, diameter: 56)
            Text(label)
                .font(StrandFont.light(10))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(minWidth: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: value ?? "–"))
    }

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                sideLabel("Live", icon: "heart")
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: snapshot.liveHR.map(String.init) ?? "–")
                        .font(StrandFont.dot(24))
                        .tracking(StrandFont.dotTracking(24))
                        .foregroundStyle(snapshot.liveHR == nil ? StrandPalette.textTertiary
                                                                : StrandPalette.textPrimary)
                        .contentTransition(.numericText())
                    if snapshot.liveHR != nil {
                        Text(verbatim: "bpm")
                            .font(StrandFont.book(10))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                sideLabel("Strap", icon: "battery-high")
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: snapshot.strapBattery.map { "\(Int($0.rounded()))" } ?? "–")
                        .font(StrandFont.book(16))
                        .foregroundStyle(snapshot.strapBattery == nil ? StrandPalette.textTertiary
                                                                      : StrandPalette.textPrimary)
                    if snapshot.strapBattery != nil {
                        Text(verbatim: "%")
                            .font(StrandFont.book(10))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sideLabel(_ title: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 5) {
            PhIcon(icon, size: 12)
            Text(title).font(StrandFont.book(11))
        }
        .foregroundStyle(StrandPalette.textSecondary)
    }

    private func whole(_ v: Double?) -> String? {
        v.map { "\(Int($0.rounded()))" }
    }
}

/// The menu-bar card's compact pill buttons: an ink pill for the one primary action, a quiet inset pill
/// for the rest. Shorter than the 52 pt screen buttons so the popover stays a glance.
struct MenuBarPillButtonStyle: ButtonStyle {
    var primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StrandFont.medium(13))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            // The kit's ink-pill pair (`gold` is the v2 ink fill, `goldDeepText` its label), which flips
            // correctly in the light appearance.
            .foregroundStyle(primary ? StrandPalette.goldDeepText : StrandPalette.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(Capsule(style: .continuous)
                .fill(primary ? StrandPalette.gold : NoopVisualStyle.inset))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(primary ? Color.clear : NoopVisualStyle.borderHighlight, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule(style: .continuous))
    }
}
