import SwiftUI
import StrandDesign

// MARK: - Group 13 v2 building blocks (diagnostic sheets, calibration sheets, settings leftovers)
//
// The pieces of the Test centre frame that the unframed diagnostic screens share: the amber-iconed
// `.warn` note, the raw-text card, the `.oh` group header and a sheet scaffold (v2 sheet header, a
// scrolling body on the 20 pt gutter, an optional pinned footer). Kept out of the screens so every probe,
// report and calibration sheet lines up on the same insets.

/// The Test centre `.warn` note: the warning glyph in the caution amber beside 12.5 pt secondary ink, on
/// a faint amber wash with a hairline edge. It carries a caution that has to be read without turning the
/// copy itself into a coloured text block.
struct G13WarnNote: View {
    let text: Text
    var icon: String = "warning"

    init(_ key: LocalizedStringKey, icon: String = "warning") {
        self.text = Text(key)
        self.icon = icon
    }
    init(text: Text, icon: String = "warning") {
        self.text = text
        self.icon = icon
    }
    init(verbatim string: String, icon: String = "warning") {
        self.text = Text(verbatim: string)
        self.icon = icon
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PhIcon(icon, size: 16)
                .foregroundStyle(StrandPalette.statusWarning)
                .padding(.top, 1)
            text
                .font(StrandFont.light(12.5, relativeTo: .caption))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(StrandPalette.statusWarning.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(NoopVisualStyle.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Raw strap text (a hex reply, a probe transcript, an environment dump) in the mono face inside a
/// neutral card. Selectable, so a capture can be lifted straight into an issue.
struct G13MonoCard: View {
    let text: String
    var size: CGFloat = 12

    var body: some View {
        NoopCard {
            Text(verbatim: text)
                .font(StrandFont.mono(size))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The Test centre `.oh` group header: an overline in secondary ink with an optional caption at the right.
/// The 16 pt top padding plus the 12 pt column gap gives the frame's 28 pt between groups.
struct G13GroupHeader: View {
    let title: Text
    var trailing: Text? = nil

    init(_ key: LocalizedStringKey, trailing: Text? = nil) {
        self.title = Text(key)
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            title
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .textCase(.uppercase)
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing?
                .font(StrandFont.light(11.5, relativeTo: .caption))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .padding(.top, 16)
    }
}

/// The heading block at the top of a sheet body: a 24 pt light title (the hero headline size of the Test
/// centre frame) and an optional 14 pt secondary line under it.
struct G13SheetTitle: View {
    let title: Text
    var subtitle: Text? = nil

    init(_ key: LocalizedStringKey, subtitle: Text? = nil) {
        self.title = Text(key)
        self.subtitle = subtitle
    }
    init(title: Text, subtitle: Text? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title
                .font(StrandFont.light(24, relativeTo: .title2))
                .tracking(-0.48)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                subtitle
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }
}

/// A v2 sheet: the `.shd` header, a scrolling body on the 20 pt gutter, and an optional pinned footer for
/// the primary action. A macOS sheet sizes itself to its content's ideal height and a scroll view reports
/// almost none, so the macOS frame is explicit.
struct G13SheetScaffold<Content: View, Footer: View>: View {
    let header: NoopSheetHeader
    var macSize = CGSize(width: 520, height: 560)
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
            }
            #if os(iOS) && DEBUG
            .modifier(DemoScrollAnchor())
            #endif
            #if os(iOS)
            // #697/#horizontal-swipe parity, see ScreenScaffold.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            footer()
        }
        .background(NoopSheetBackground())
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: macSize.width, minHeight: 320, idealHeight: macSize.height)
        #endif
    }
}

extension G13SheetScaffold where Footer == EmptyView {
    init(header: NoopSheetHeader, macSize: CGSize = CGSize(width: 520, height: 560),
         @ViewBuilder content: @escaping () -> Content) {
        self.init(header: header, macSize: macSize, content: content, footer: { EmptyView() })
    }
}

/// The pinned footer of a `G13SheetScaffold`: its actions on the 20 pt gutter over a hairline.
struct G13SheetFooter<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .overlay(alignment: .top) {
                Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
            }
    }
}

/// The "waiting for the strap" state of a diagnostic sheet: a small spinner beside the waiting line, in a
/// neutral card where the reply will appear.
struct G13WaitingCard: View {
    let text: Text

    var body: some View {
        NoopCard {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .tint(StrandPalette.textSecondary)
                text
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The result sheet every strap probe shares (#592 battery info, #690 body location, #761 feature flags,
/// #103 device config, the MG ECG capture): the strap's reply as selectable mono text, or a waiting state
/// while the probe is in flight. Copy is the sheet's primary action, offered once there is a reply, so a
/// capture pastes into an issue without a full strap-log export. An optional caution sits above the reply
/// so it is read first.
struct G13ProbeResultSheet: View {
    let headerTitle: LocalizedStringKey
    let title: LocalizedStringKey
    let text: String
    let waiting: Bool
    var waitingText: LocalizedStringKey = "Waiting for the strap's reply…"
    var warning: LocalizedStringKey? = nil
    let onClose: () -> Void

    @State private var copied = false

    var body: some View {
        G13SheetScaffold(header: NoopSheetHeader(headerTitle, cancelTitle: "Close",
                                                 doneTitle: waiting ? nil : (copied ? "Copied!" : "Copy"),
                                                 onCancel: onClose, onDone: copy)) {
            G13SheetTitle(title)
            if let warning { G13WarnNote(warning) }
            if waiting {
                G13WaitingCard(text: Text(waitingText))
            } else {
                G13MonoCard(text: text, size: 13)
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #endif
    }

    private func copy() {
        PlatformPasteboard.copy(text)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copied = false
        }
    }
}

/// A status capsule in ink: a small state dot (green / amber / red by meaning, optionally breathing for a
/// live link) beside a 12 pt Book label. The v2 replacement for a tone-tinted pill, so the state colour
/// lives in the dot and the words stay ink.
struct G13StatusPill: View {
    let text: Text
    var tone: StrandTone? = nil
    var pulsing: Bool = false

    init(verbatim string: String, tone: StrandTone? = nil, pulsing: Bool = false) {
        self.text = Text(verbatim: string)
        self.tone = tone
        self.pulsing = pulsing
    }
    init(_ key: LocalizedStringKey, tone: StrandTone? = nil, pulsing: Bool = false) {
        self.text = Text(key)
        self.tone = tone
        self.pulsing = pulsing
    }

    var body: some View {
        HStack(spacing: 7) {
            if let tone { ConnectionDot(tone: tone, pulsing: pulsing, size: 7) }
            text
                .font(StrandFont.book(12, relativeTo: .caption))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
