import SwiftUI

// MiniRing.swift — the Home triple-ring hero element. A small score ring: gradient
// arc + center value + uppercase label with a chevron underneath (the whole thing is
// wrapped in a Button by the caller). Distinct from RecoveryRing (the 168pt signature
// instrument) — this is deliberately plain so three of them read as one calm row.

public struct MiniRing: View {
    let label: LocalizedStringKey
    let value: String          // center text — "84%", "9.2", "2/4", "—"
    let progress: Double?      // 0...1 arc; nil renders the empty track only
    let gradient: Gradient
    var caption: LocalizedStringKey? = nil   // small line under the value, e.g. "of 21"
    var diameter: CGFloat = 96

    public init(label: LocalizedStringKey, value: String, progress: Double?,
                gradient: Gradient, caption: LocalizedStringKey? = nil,
                diameter: CGFloat = 96) {
        self.label = label; self.value = value; self.progress = progress
        self.gradient = gradient; self.caption = caption; self.diameter = diameter
    }

    public var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(StrandPalette.surfaceOverlay, lineWidth: 7)
                if let p = progress {
                    Circle()
                        .trim(from: 0, to: CGFloat(Swift.max(0.02, Swift.min(1, p))))
                        .stroke(
                            AngularGradient(gradient: gradient,
                                            center: .center,
                                            startAngle: .degrees(0),
                                            endAngle: .degrees(360 * Swift.max(0.02, Swift.min(1, p)))),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 0) {
                    Text(value)
                        .font(StrandFont.number(diameter * 0.23))
                        .foregroundStyle(progress == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if let caption {
                        Text(caption)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(width: diameter, height: diameter)

            HStack(spacing: 3) {
                Text(label)
                    .strandOverline()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("MiniRing row") {
    HStack(spacing: 12) {
        MiniRing(label: "Sleep", value: "84%", progress: 0.84,
                 gradient: Gradient(colors: [StrandPalette.metricPurple.opacity(0.6), StrandPalette.metricPurple]))
        MiniRing(label: "Recovery", value: "72%", progress: 0.72,
                 gradient: Gradient(colors: [StrandPalette.recovery078, StrandPalette.recovery078]))
        MiniRing(label: "Strain", value: "9.2", progress: 9.2 / 21,
                 gradient: StrandPalette.strainGradient, caption: "of 21")
        MiniRing(label: "Recovery", value: "2/4", progress: nil,
                 gradient: Gradient(colors: [StrandPalette.accent]))
    }
    .padding(24)
    .background(StrandPalette.surfaceBase)
}
#endif
