import SwiftUI
import StrandDesign

/// "What's New" — a proper in-app changelog, shown automatically after an update and reachable any
/// time from Settings. The newest release leads as a hero and a list of its highlights; what NOOP is and
/// what to expect follow, then every earlier release, so people who never open GitHub still understand
/// the experimental footing and the WHOOP 5/MG status.
struct WhatsNewView: View {
    let onClose: () -> Void
    /// Highlights opened to their full text (keyed by release version + index).
    @State private var expanded: Set<String> = []

    private var latest: AppChangelog.Release? { AppChangelog.releases.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                // PERF: the changelog grows with every release, so this is an ever-lengthening column.
                // LazyVStack builds the off-screen release cards on demand instead of constructing the
                // entire history up-front each time the sheet opens.
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let latest {
                        hero(latest)
                        highlights(latest).padding(.top, 16)
                    }
                    expectations
                    if AppChangelog.releases.count > 1 {
                        NoopSectionTitle("Earlier releases", topPadding: 30)
                            .padding(.bottom, 12)
                        ForEach(AppChangelog.releases.dropFirst()) { release in
                            earlierRelease(release)
                                .padding(.bottom, 22)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            #if os(iOS)
            // #697/#horizontal-swipe parity: every other screen (ScreenScaffold, Liquid Today) already
            // stops a vertical scroll from drifting/bouncing the screen left-right. This sheet runs its
            // own ScrollView and had never gotten the fix.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            #if os(iOS) && DEBUG
            .modifier(DemoScrollAnchor())
            #endif
            footer
        }
        // A fixed 560×640 is right for the macOS sheet window, but on iPhone it's wider than the
        // screen, so the content (and the button) ran off the right edge (#185). iOS fills the presented
        // sheet instead.
        #if os(macOS)
        .frame(width: 560, height: 640)
        .background(NoopSheetBackground())
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A long changelog scroll → open full-height, with a grabber for swipe-to-dismiss.
        .noopSheetPresentation(largeFirst: true)
        #endif
    }

    private var header: some View {
        HStack {
            NoopOverline("Release notes")
            Spacer()
            NoopCircleButton("x", size: 34, accessibilityLabel: "Close", action: onClose)
        }
        .padding(.leading, 24)
        .padding(.trailing, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    // MARK: Newest release

    private func hero(_ release: AppChangelog.Release) -> some View {
        NoopHeroCard(glow: .ink, padding: 22, minHeight: 232) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    NoopDotNumber(release.version, size: 92)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    NoopPill(verbatim: String(localized: "Build \(buildNumber)"), compact: true)
                }
                Spacer(minLength: 24)
                Text("What's new in NOOP")
                    .font(StrandFont.title1)
                    .tracking(-0.56)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(release.title)
                    .font(StrandFont.light(13.5, relativeTo: .subheadline))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                Text("\(release.date) · \(release.items.count) changes")
                    .font(StrandFont.footnote)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .padding(.top, 6)
            }
            .frame(minHeight: 232 - 44, alignment: .topLeading)
        }
    }

    private var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
    }

    private func highlights(_ release: AppChangelog.Release) -> some View {
        NoopList {
            ForEach(Array(release.items.enumerated()), id: \.offset) { index, item in
                highlightRow(item, key: "\(release.version)#\(index)", tile: 44)
            }
        }
    }

    private func highlightRow(_ item: String, key: String, tile: CGFloat) -> some View {
        let h = Highlight(item)
        let open = expanded.contains(key)
        return Button {
            withAnimation(StrandMotion.gentle) {
                if open { expanded.remove(key) } else { expanded.insert(key) }
            }
        } label: {
            HStack(alignment: open ? .top : .center, spacing: 14) {
                PhIcon(h.icon, size: tile * 0.48)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: tile, height: tile)
                    .background(RoundedRectangle(cornerRadius: tile / 3, style: .continuous)
                        .fill(LinearGradient(colors: [NoopVisualStyle.raised, NoopVisualStyle.inset],
                                             startPoint: .top, endPoint: .bottom)))
                    .overlay(RoundedRectangle(cornerRadius: tile / 3, style: .continuous)
                        .strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(verbatim: h.title)
                            .font(StrandFont.book(15.5, relativeTo: .body))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(open ? nil : 2)
                        if h.isBeta { BetaChip() }
                    }
                    if !h.detail.isEmpty {
                        Text(verbatim: h.detail)
                            .font(StrandFont.light(12.5, relativeTo: .caption))
                            .lineSpacing(2)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(open ? nil : 2)
                    }
                    if open, let refs = h.refs {
                        Text(verbatim: refs)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(.top, 2)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(open ? Text("Shows less") : Text("Shows the full note"))
    }

    // MARK: What to expect + earlier releases

    private var expectations: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoopSectionTitle("What to expect", topPadding: 30)
                .padding(.bottom, 12)
            NoopList {
                ForEach(AppChangelog.expectations) { e in
                    HStack(alignment: .top, spacing: 14) {
                        NoopIconTile(Self.phosphor(for: e.icon))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.title)
                                .font(StrandFont.book(15, relativeTo: .body))
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(e.body)
                                .font(StrandFont.light(13, relativeTo: .footnote))
                                .lineSpacing(2)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 15)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func earlierRelease(_ release: AppChangelog.Release) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "v\(release.version) · \(release.date)")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text(release.title)
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
            NoopList {
                ForEach(Array(release.items.enumerated()), id: \.offset) { index, item in
                    highlightRow(item, key: "\(release.version)#\(index)", tile: 34)
                }
            }
        }
    }

    private var footer: some View {
        Button(action: onClose) { Text("Continue") }
            .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            // The kit's `.fade`: the list dissolves into the pinned button instead of being cut.
            .background(alignment: .top) {
                LinearGradient(colors: [NoopVisualStyle.surface.opacity(0), NoopVisualStyle.surface],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                    .offset(y: -28)
                    .allowsHitTesting(false)
            }
    }

    /// `AppChangelog.expectations` names SF Symbols (shared with surfaces that still use them); this
    /// sheet draws the matching Phosphor glyph.
    private static func phosphor(for symbol: String) -> String {
        switch symbol {
        case "flask":          return "flask"
        case "checkmark.seal": return "seal-check"
        case "hourglass":      return "hourglass"
        case "lock.shield":    return "shield-check"
        default:               return PhIcon.exists(symbol) ? symbol : "info"
        }
    }
}

/// One changelog line split for display. Notes are written "**Lead (#123, thanks @x).** Body": the bold
/// lead becomes the title, its trailing issue/credit parenthesis is kept for the opened row, and the rest
/// is the detail. A line without a bold lead is shown whole.
private struct Highlight {
    let title: String
    let detail: String
    let refs: String?
    let icon: String
    let isBeta: Bool

    init(_ item: String) {
        var lead = item
        var detail = ""
        var refs: String?
        if item.hasPrefix("**"),
           let close = item.range(of: "**", range: item.index(item.startIndex, offsetBy: 2)..<item.endIndex) {
            lead = String(item[item.index(item.startIndex, offsetBy: 2)..<close.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            detail = String(item[close.upperBound...]).trimmingCharacters(in: .whitespaces)
            if lead.hasSuffix(".") { lead.removeLast() }
            if lead.hasSuffix(")"), let open = lead.range(of: " (", options: .backwards) {
                refs = String(lead[lead.index(after: open.lowerBound)...])
                lead = String(lead[..<open.lowerBound])
            }
        }
        self.title = lead
        self.detail = detail
        self.refs = refs
        let l = lead.lowercased()
        self.isBeta = l.contains("beta") || l.contains("experimental")
        self.icon = Highlight.icon(for: l)
    }

    /// A glyph for the line's subject, read from words in its lead; a sparkle when nothing matches.
    private static func icon(for lead: String) -> String {
        let table: [(String, String)] = [
            ("lift", "barbell"), ("gym", "barbell"), ("workout", "person-simple-run"),
            ("sleep", "moon-stars"), ("nap", "moon-stars"), ("night", "moon-stars"),
            ("sync", "arrows-clockwise"), ("coach", "sparkle"), ("stress", "pulse"),
            ("rhythm", "waveform"), ("heart", "heart"), ("hrv", "heart"),
            ("oura", "circle"), ("ring", "circle"), ("whoop", "watch"), ("strap", "watch"),
            ("chart", "chart-line-up"), ("step", "footprints"), ("health", "heart"),
            ("locali", "translate"), ("translat", "translate"), ("widget", "squares-four"),
            ("today", "squares-four"), ("backup", "archive"), ("alarm", "alarm"),
            ("battery", "battery-high"), ("diagnos", "bug"), ("export", "export"),
            ("privacy", "shield-check"), ("correction", "wrench"), ("fix", "wrench"),
        ]
        return table.first { lead.contains($0.0) }?.1 ?? "sparkle"
    }
}

/// The small hairline "Beta" capsule beside an experimental highlight.
private struct BetaChip: View {
    var body: some View {
        Text("Beta")
            .font(StrandFont.book(10, relativeTo: .caption2))
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
    }
}
