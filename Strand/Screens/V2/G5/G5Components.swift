import SwiftUI
import StrandDesign

// MARK: - Shared v2 pieces for the Health & Calm screens
//
// Small view-only building blocks the Health, Lab Book, Stress, Breathe and Rhythm screens share and the
// StrandDesign kit does not carry: the hero `.live` pill, the contributor diverging bar, the empty-state
// card and a menu-capable circle button.

/// The hero `.live` capsule: translucent white, a 12 pt label and, while a signal streams, a glowing dot.
struct G5LivePill: View {
    let text: Text
    var live: Bool

    var body: some View {
        HStack(spacing: 7) {
            if live {
                Circle()
                    .fill(Color.white)
                    .frame(width: 7, height: 7)
                    .background(Circle().fill(Color.white.opacity(0.18)).frame(width: 13, height: 13))
                    .shadow(color: .white.opacity(0.9), radius: 5)
                    .accessibilityHidden(true)
            }
            text.font(StrandFont.book(12, relativeTo: .caption)).lineLimit(1)
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }
}

/// The contributor bar: a 6 pt track with a centre tick, filled from the centre toward the side the reading
/// moved (`offset` −1…1, right = a gain). A reading at its baseline shows a short centred nub; nil leaves the
/// track empty (calibrating), so no fill is ever implied.
struct G5DivergingBar: View {
    let offset: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                Capsule(style: .continuous).fill(NoopVisualStyle.raised)
                if let offset {
                    let o = min(max(offset, -1), 1)
                    let half = w / 2
                    let nub = w * 0.06
                    let (x, width): (CGFloat, CGFloat) = abs(o) < 0.06
                        ? (half - nub / 2, nub)
                        : (o > 0 ? half : half - half * CGFloat(-o), half * CGFloat(abs(o)))
                    Capsule(style: .continuous)
                        .fill(StrandPalette.textPrimary.opacity(0.8))
                        .frame(width: max(width, h), height: h)
                        .offset(x: x)
                }
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 1, height: h + 8)
                    .offset(x: w / 2, y: -4)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// The v2 empty / pending card: an icon tile, a 15 pt title and one honest sentence on what fills it.
struct G5EmptyCard: View {
    let icon: String
    let title: Text
    let message: Text

    init(icon: String, title: LocalizedStringKey = "Coming together", message: Text) {
        self.icon = icon
        self.title = Text(title)
        self.message = message
    }

    var body: some View {
        NoopCard {
            HStack(alignment: .top, spacing: 14) {
                NoopIconTile(icon)
                VStack(alignment: .leading, spacing: 4) {
                    title.font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                    message.font(StrandFont.light(13.5, relativeTo: .subheadline))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The v2 circle "more" button that opens a menu (the `.cb` with `dots-three`). A `Menu` cannot take a
/// `NoopCircleButton`, so this wraps the chrome-only `NoopCircleIcon` in a plain-styled menu.
struct G5MoreMenu<Items: View>: View {
    @ViewBuilder var items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            NoopCircleIcon("dots-three")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        #if os(macOS)
        .menuIndicator(.hidden)
        .fixedSize()
        #endif
        .accessibilityLabel(Text("More"))
    }
}

/// A centred hero sentence with one dot-matrix tag inside it ("Your stress ran [HIGH] today."). The
/// sentence is localized WHOLE, with `slot` interpolated where the tag goes, so translators see the full
/// phrase; the slot is then split out and replaced by a `NoopTag`.
struct G5TaggedSentence: View {
    /// The placeholder interpolated into the localized sentence where the tag sits.
    static let slot = "\u{2063}#\u{2063}"

    private let before: [String]
    private let after: [String]
    private let afterPunctuation: String
    private let tag: String

    init(_ sentence: String, tag: String) {
        let parts = sentence.components(separatedBy: Self.slot)
        let head = parts.first ?? sentence
        var tail = parts.count > 1 ? parts[1] : ""
        // Punctuation glued to the tag ("[HIGH]." / "[HIGH],") stays glued to it.
        var glued = ""
        while let c = tail.first, !c.isWhitespace, !c.isLetter, !c.isNumber {
            glued.append(c)
            tail.removeFirst()
        }
        self.before = head.split(separator: " ").map(String.init)
        self.after = tail.split(separator: " ").map(String.init)
        self.afterPunctuation = glued
        self.tag = parts.count > 1 ? tag : ""
    }

    var body: some View {
        G5CenteredFlow(spacing: 5, lineSpacing: 6) {
            ForEach(Array(before.enumerated()), id: \.offset) { _, w in word(w) }
            if !tag.isEmpty {
                HStack(spacing: 1) {
                    NoopTag(verbatim: tag, size: 15)
                        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.3)))
                    if !afterPunctuation.isEmpty { word(afterPunctuation) }
                }
                .fixedSize()
            }
            ForEach(Array(after.enumerated()), id: \.offset) { _, w in word(w) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: (before + (tag.isEmpty ? [] : [tag + afterPunctuation]) + after)
            .joined(separator: " ")))
    }

    private func word(_ w: String) -> some View {
        Text(verbatim: w)
            .font(StrandFont.light(19, relativeTo: .title3))
            .foregroundStyle(Color.white.opacity(0.92))
            .fixedSize()
    }
}

/// A wrapping row layout that centres each line (for sentences built from word + tag tokens).
struct G5CenteredFlow: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 6

    private func lines(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var out: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > width {
                out.append([])
                x = 0
            }
            x += (x > 0 ? spacing : 0) + size.width
            out[out.count - 1].append((i, size))
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let ls = lines(subviews, width: width)
        let height = ls.reduce(CGFloat(0)) { acc, line in
            acc + (line.map(\.1.height).max() ?? 0)
        } + lineSpacing * CGFloat(max(ls.count - 1, 0))
        let widest = ls.map { line in
            line.reduce(CGFloat(0)) { $0 + $1.1.width } + spacing * CGFloat(max(line.count - 1, 0))
        }.max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            let lineWidth = line.reduce(CGFloat(0)) { $0 + $1.1.width } + spacing * CGFloat(max(line.count - 1, 0))
            let lineHeight = line.map(\.1.height).max() ?? 0
            var x = bounds.minX + (bounds.width - lineWidth) / 2
            for (i, size) in line {
                subviews[i].place(at: CGPoint(x: x, y: y + (lineHeight - size.height) / 2),
                                  proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += lineHeight + lineSpacing
        }
    }
}
