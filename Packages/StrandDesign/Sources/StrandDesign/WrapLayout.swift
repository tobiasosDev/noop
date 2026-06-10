import SwiftUI

// WrapLayout.swift — minimal leading-aligned wrapping row (chips). Public twin of the
// private FlowLayout in JournalView; new chip rows should use this one.

public struct WrapLayout: Layout {
    var spacing: CGFloat

    public init(spacing: CGFloat = 8) { self.spacing = spacing }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { maxX = Swift.max(maxX, x - spacing); x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = Swift.max(rowH, s.height)
        }
        maxX = Swift.max(maxX, x - spacing)
        return CGSize(width: width == .infinity ? maxX : width, height: y + rowH)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = Swift.max(rowH, s.height)
        }
    }
}

#if DEBUG
#Preview("WrapLayout — wrapping chips") {
    WrapLayout(spacing: 8) {
        ForEach(["Sleep", "Recovery", "Strain", "Steps", "HRV", "Resting HR", "Calories"], id: \.self) { label in
            Text(label)
                .font(StrandFont.caption)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(StrandPalette.surfaceInset, in: Capsule())
        }
    }
    .padding(24)
    .frame(width: 320)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
