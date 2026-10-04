import SwiftUI
import StrandDesign

// MARK: - Per-source page cards (Apple Health, Mi Band)
//
// The v2 pieces the per-source pages share: the 3-up summary tile, the two-up metric card (optionally
// with a sparkline over the selected window), and the two-up grid that lays them out with equal row
// heights. The pages own the data; these only draw it.

/// A `.tl` summary tile: a 20 pt value with a small unit, the metric's label, and an optional
/// caption (an "as of" date for a stale reading).
struct SourceStatTile: View {
    let number: String
    let unit: String?
    let label: Text
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: number)
                    .font(StrandFont.value(20))
                    .tracking(-0.4)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let unit {
                    Text(verbatim: unit)
                        .font(StrandFont.book(10))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            label
                .font(StrandFont.light(10.5, relativeTo: .caption2))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let caption {
                Text(caption)
                    .font(StrandFont.light(10, relativeTo: .caption2))
                    .foregroundStyle(NoopVisualStyle.quaternaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .noopPanel(cornerRadius: 20)
        .accessibilityElement(children: .combine)
    }
}

/// A two-up metric card: icon + title, the value with a small unit, an optional sparkline (with the
/// newest point marked) and a caption. `values == nil` draws the plain metric card (no chart row).
struct SourceMetricCard: View {
    let title: LocalizedStringKey
    let icon: String
    let number: String
    let unit: String?
    var values: [Double]? = nil
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: number)
                    .font(StrandFont.value(24, weight: 300))
                    .tracking(-0.5)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let unit {
                    Text(verbatim: unit)
                        .font(StrandFont.book(11))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.top, values == nil ? 10 : 6)
            if let values {
                SourceSparkline(values: values)
                    .frame(height: 38)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                Text(caption)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(caption)
                    .font(StrandFont.light(10.5, relativeTo: .caption2))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, values == nil ? 15 : 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .noopPanel()
        .accessibilityElement(children: .combine)
    }

    /// The trend card's header is the kit's 14 pt title; the plain metric card's is the quieter 13 pt
    /// secondary one, as the frames draw them.
    @ViewBuilder private var header: some View {
        if values == nil {
            HStack(spacing: 8) {
                PhIcon(icon, size: 15).opacity(0.75)
                Text(title)
                    .font(StrandFont.book(13, relativeTo: .subheadline))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(StrandPalette.textSecondary)
        } else {
            HStack(spacing: 8) {
                PhIcon(icon, size: 16).opacity(0.9)
                Text(title)
                    .font(StrandFont.book(14, relativeTo: .subheadline))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(StrandPalette.textPrimary)
        }
    }
}

/// The card sparkline: the kit's area chart scaled so the line keeps clear of both edges (16 % above
/// the peak, 25 % below the trough), with a white dot on the newest reading. Fewer than two values
/// draw nothing (the card's caption says why).
struct SourceSparkline: View {
    let values: [Double]

    var body: some View {
        if values.count >= 2, let lo = values.min(), let hi = values.max(), let last = values.last {
            let span = max(hi - lo, 0.000_1)
            let full = span / 0.59
            let range = (lo - full * 0.25)...(hi + full * 0.16)
            NoopAreaChart(values: values, range: range, line: StrandPalette.metricCyan, lineWidth: 1.1)
                .overlay {
                    GeometryReader { geo in
                        let y = geo.size.height
                            * (1 - CGFloat((last - range.lowerBound) / (range.upperBound - range.lowerBound)))
                        Circle().fill(Color.white)
                            .frame(width: 5.2, height: 5.2)
                            .position(x: geo.size.width, y: y)
                    }
                }
                .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }

    /// Evenly spaced samples (always keeping the first and newest) so a multi-year window stays a
    /// light sparkline. Render-only: captions and stats come from the full series.
    static func downsample(_ values: [Double], to limit: Int = 90) -> [Double] {
        guard values.count > limit, limit > 1 else { return values }
        let step = Double(values.count - 1) / Double(limit - 1)
        return (0..<limit).map { values[Int((Double($0) * step).rounded())] }
    }
}

/// Lays cards out two-up with equal heights per row; an odd card out runs the full width.
struct SourceCardGrid<Item: Identifiable, Card: View>: View {
    let items: [Item]
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { i in
                GridRow {
                    if i + 1 < items.count {
                        card(items[i])
                        card(items[i + 1])
                    } else {
                        card(items[i]).gridCellColumns(2)
                    }
                }
            }
        }
    }
}
