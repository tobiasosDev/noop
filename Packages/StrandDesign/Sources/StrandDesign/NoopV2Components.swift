import SwiftUI

// MARK: - v2 building blocks
//
// The pieces every v2 screen is assembled from, named after the classes of the v2 kit on the design
// canvas (`.tag`, `.m`, `.ct`, `.st`, `.insight`, `.ticks`, `.track`, `.list/.li`, `.sw`, `.chip`, `.cb`,
// `.pill`, `.badge`, `.av`, `.pager`). Screens compose these instead of inventing ad-hoc chrome, so the
// whole app keeps one type scale, one set of radii and one ink ramp.

// MARK: Dot-matrix numbers and tags

/// A hero number in the dot-matrix face, with an optional smaller unit (`78` + `%`).
public struct NoopDotNumber: View {
    public var value: String
    public var unit: String?
    public var size: CGFloat
    public var unitSize: CGFloat?
    public var color: Color

    public init(_ value: String, unit: String? = nil, size: CGFloat = 104, unitSize: CGFloat? = nil,
                color: Color = StrandPalette.textPrimary) {
        self.value = value
        self.unit = unit
        self.size = size
        self.unitSize = unitSize
        self.color = color
    }

    public var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: size * 0.04) {
            Text(verbatim: value)
                .font(StrandFont.dot(size))
                .tracking(StrandFont.dotTracking(size))
            if let unit {
                let u = unitSize ?? size * 0.42
                Text(verbatim: unit)
                    .font(StrandFont.dot(u))
                    .tracking(StrandFont.dotTracking(u))
            }
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .accessibilityElement(children: .combine)
    }
}

/// The inline dot-matrix status pill (`ABOVE`, `STRENUOUS`, `OPTIMAL`): Doto 700, uppercase, wide
/// tracking, a hairline capsule on 5 % white.
public struct NoopTag: View {
    private let text: Text
    public var size: CGFloat
    public init(_ key: LocalizedStringKey, size: CGFloat = 15) {
        self.text = Text(key)
        self.size = size
    }
    public init(verbatim string: String, size: CGFloat = 15) {
        self.text = Text(verbatim: string)
        self.size = size
    }

    public var body: some View {
        text
            .font(StrandFont.dot(size, weight: 700))
            .tracking(size * 0.08)
            .textCase(.uppercase)
            .lineLimit(1)
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.top, 2).padding(.bottom, 3)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
    }
}

// MARK: Metrics

/// One metric in a `.mrow`: a 21 pt value with an inline 10 pt unit, a 10.5 pt caption below.
public struct NoopMetric: View {
    public var value: String
    public var unit: String?
    private let label: Text?
    public var valueSize: CGFloat
    /// Caption ink. Neutral cards use the tertiary ink; heroes lift it to ~55 % white (`heroLabel`).
    public var labelColor: Color

    /// The caption ink metrics carry inside a glowing hero.
    public static let heroLabel = Color.white.opacity(0.55)
    /// A one-word label ("Herzfrequenzvariabilität") must shrink rather than break mid-word in a narrow
    /// column. Only known for an already-resolved `labelText`; resolve a key with `String(localized:)`
    /// and pass it as `labelText` where a translation may be one long word.
    private let singleWordLabel: Bool

    public init(value: String, unit: String? = nil, label: LocalizedStringKey?, valueSize: CGFloat = 21,
                labelColor: Color = StrandPalette.textTertiary) {
        self.value = value
        self.unit = unit
        self.label = label.map { Text($0) }
        self.valueSize = valueSize
        self.labelColor = labelColor
        self.singleWordLabel = false
    }
    public init(value: String, unit: String? = nil, labelText: String?, valueSize: CGFloat = 21,
                labelColor: Color = StrandPalette.textTertiary) {
        self.value = value
        self.unit = unit
        self.label = labelText.map { Text(verbatim: $0) }
        self.valueSize = valueSize
        self.labelColor = labelColor
        self.singleWordLabel = labelText.map { !$0.contains(" ") } ?? false
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value)
                    .font(StrandFont.value(valueSize))
                    .tracking(-valueSize * 0.02)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let unit {
                    Text(verbatim: unit)
                        .font(StrandFont.book(10))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            if let label {
                label
                    .font(StrandFont.light(10.5))
                    .foregroundStyle(labelColor)
                    .lineLimit(singleWordLabel ? 1 : nil)
                    .minimumScaleFactor(singleWordLabel ? 0.7 : 1)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A `.mrow`: metrics side by side in equal columns.
public struct NoopMetricRow<Content: View>: View {
    @ViewBuilder public var content: () -> Content
    public init(@ViewBuilder content: @escaping () -> Content) { self.content = content }
    public var body: some View {
        HStack(alignment: .top, spacing: 0) { content() }
    }
}

// MARK: Titles

/// The `.ct` card title row: a 16 pt icon, a 14 pt Book title, an optional 12 pt caption at the right.
public struct NoopCardHeader<Trailing: View>: View {
    private let icon: String?
    private let title: Text
    @ViewBuilder private var trailing: () -> Trailing

    public init(_ title: LocalizedStringKey, icon: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = Text(title)
        self.icon = icon
        self.trailing = trailing
    }
    public init(verbatim title: String, icon: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = Text(verbatim: title)
        self.icon = icon
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let icon {
                PhIcon(icon, size: 16).opacity(0.9)
            }
            // The title wins the width: a long caption wraps (up to two lines) before the title truncates,
            // which matters for long German titles beside a caption.
            title.font(StrandFont.book(14, relativeTo: .subheadline))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            trailing()
                .font(StrandFont.light(12, relativeTo: .caption))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .foregroundStyle(StrandPalette.textPrimary)
    }
}

public extension NoopCardHeader where Trailing == Text? {
    init(_ title: LocalizedStringKey, icon: String? = nil, caption: String? = nil) {
        self.init(title, icon: icon) { caption.map { Text(verbatim: $0) } }
    }
    init(_ title: LocalizedStringKey, icon: String? = nil, captionKey: LocalizedStringKey) {
        self.init(title, icon: icon) { Text(captionKey) }
    }
}

/// The `.st` section title: 21 pt Book on the left, an 11 pt caption or action on the right. Carries the
/// v2 rhythm itself assuming the column's 12 pt card gap: 18 pt above and 2 pt below, which makes the
/// visible gaps the kit's 30 pt before a section title and 14 pt after it.
public struct NoopSectionTitle<Trailing: View>: View {
    private let title: Text
    @ViewBuilder private var trailing: () -> Trailing
    public var topPadding: CGFloat

    public init(_ title: LocalizedStringKey, topPadding: CGFloat = 18, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = Text(title)
        self.topPadding = topPadding
        self.trailing = trailing
    }
    public init(verbatim title: String, topPadding: CGFloat = 18, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = Text(verbatim: title)
        self.topPadding = topPadding
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            // The title wins the width; a long caption wraps (up to two lines) before the title does.
            title.font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .layoutPriority(1)
            Spacer(minLength: 8)
            trailing()
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.top, topPadding)
        .padding(.bottom, 2)
    }
}

public extension NoopSectionTitle where Trailing == Text? {
    init(_ title: LocalizedStringKey, caption: String? = nil, topPadding: CGFloat = 18) {
        self.init(title, topPadding: topPadding) { caption.map { Text(verbatim: $0) } }
    }
    init(_ title: LocalizedStringKey, captionKey: LocalizedStringKey, topPadding: CGFloat = 18) {
        self.init(title, topPadding: topPadding) { Text(captionKey) }
    }
}

/// The large tab-root title ("Trends", "More"): 34 pt Light, an optional 14 pt subtitle, trailing
/// circle buttons.
public struct NoopPageTitle<Trailing: View>: View {
    private let title: Text
    private let subtitle: Text?
    @ViewBuilder private var trailing: () -> Trailing

    public init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil,
                @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                title.font(StrandFont.largeTitle).tracking(-0.7)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    subtitle.font(StrandFont.light(14, relativeTo: .subheadline))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

public extension NoopPageTitle where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// The `.over` overline, as a view.
public struct NoopOverline: View {
    private let text: Text
    public init(_ key: LocalizedStringKey) { text = Text(key) }
    public init(verbatim s: String) { text = Text(verbatim: s) }
    public var body: some View {
        text.font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .textCase(.uppercase)
            .foregroundStyle(StrandPalette.textTertiary)
    }
}

// MARK: Insight

/// The `.insight` line: a sparkle and one sentence in secondary ink.
public struct NoopInsightRow: View {
    private let text: Text
    public var icon: String
    public init(_ key: LocalizedStringKey, icon: String = "sparkle") {
        self.text = Text(key)
        self.icon = icon
    }
    public init(verbatim s: String, icon: String = "sparkle") {
        self.text = Text(verbatim: s)
        self.icon = icon
    }
    public init(text: Text, icon: String = "sparkle") {
        self.text = text
        self.icon = icon
    }
    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PhIcon(icon, size: 18)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.top, 1)
            text.font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: Scales, tracks, gauges

/// The `.ticks` scale: 1 pt ticks every 5 pt, faded at both ends, with an optional glowing white
/// marker at `marker` (0…1).
public struct NoopTickScale: View {
    public var marker: Double?
    public var height: CGFloat
    public var tickSpacing: CGFloat
    public init(marker: Double? = nil, height: CGFloat = 26, tickSpacing: CGFloat = 5) {
        self.marker = marker
        self.height = height
        self.tickSpacing = tickSpacing
    }

    public var body: some View {
        // The ticks own the layout box (exactly `height` tall); the taller marker is an overlay, so it
        // overflows ±6 pt without ever changing the size the ticks are drawn into.
        Canvas { ctx, size in
            var x: CGFloat = 0
            while x <= size.width {
                ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                         with: .color(.white.opacity(0.45)))
                x += tickSpacing
            }
        }
        .mask(
            LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                startPoint: .leading, endPoint: .trailing
            )
        )
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) {
            if let marker {
                GeometryReader { geo in
                    let w = geo.size.width
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white)
                        .frame(width: 2, height: height + 12)
                        .shadow(color: .white.opacity(0.8), radius: 5)
                        .offset(x: max(0, min(w - 2, w * min(max(marker, 0), 1) - 1)), y: -6)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The `.track` progress bar: a near-black capsule with a blue gradient fill, and an optional dashed
/// target window (`target` as a 0…1 range).
public struct NoopTrack: View {
    public var fraction: Double
    public var height: CGFloat
    public var target: ClosedRange<Double>?
    public var fill: [Color]

    public init(fraction: Double, height: CGFloat = 14, target: ClosedRange<Double>? = nil,
                fill: [Color] = [Color(hex: "#3C56D8"), Color(hex: "#6F87FF")]) {
        self.fraction = fraction
        self.height = height
        self.target = target
        self.fill = fill
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let f = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color(light: "#E2E1DD", dark: "#1B1B1F"))
                    .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                if f > 0 {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: fill, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, w * f))
                }
                if let target {
                    let lo = min(max(target.lowerBound, 0), 1), hi = min(max(target.upperBound, 0), 1)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .frame(width: max(8, w * (hi - lo)), height: height + 8)
                        .offset(x: w * lo)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The v2 ring gauge (strap battery, deep-sleep share): a faint full ring, a bright ink arc from the top
/// clockwise, and a white knob with a soft glow at the arc's end.
public struct NoopRingGauge: View {
    public var fraction: Double
    public var lineWidth: CGFloat
    public var tint: Color
    public var showsKnob: Bool
    public init(fraction: Double, lineWidth: CGFloat = 3, tint: Color = StrandPalette.textPrimary,
                showsKnob: Bool = true) {
        self.fraction = fraction
        self.lineWidth = lineWidth
        self.tint = tint
        self.showsKnob = showsKnob
    }

    public var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            let r = (d - lineWidth) / 2
            let f = min(max(fraction, 0), 1)
            ZStack {
                Circle().stroke(Color.white.opacity(0.10), lineWidth: lineWidth)
                Circle().trim(from: 0, to: f)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if showsKnob && f > 0 {
                    let a = Angle.degrees(-90 + 360 * f).radians
                    Circle().fill(Color.white)
                        .frame(width: lineWidth * 3, height: lineWidth * 3)
                        .shadow(color: .white.opacity(0.8), radius: 4)
                        .offset(x: r * CGFloat(cos(a)), y: r * CGFloat(sin(a)))
                }
            }
            .frame(width: d, height: d)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

/// The v2 arc gauge: 60 thin ticks around a 270° sweep, the filled part bright, a white knob at the
/// value.
public struct NoopArcGauge: View {
    public var fraction: Double
    public var tint: Color
    public var tickCount: Int
    public init(fraction: Double, tint: Color = StrandPalette.textPrimary, tickCount: Int = 60) {
        self.fraction = fraction
        self.tint = tint
        self.tickCount = tickCount
    }

    public var body: some View {
        Canvas { ctx, size in
            let d = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let rOuter = d / 2 - 6, rInner = rOuter - 10
            let start = 135.0, sweep = 270.0
            let f = min(max(fraction, 0), 1)
            for i in 0...tickCount {
                let t = Double(i) / Double(tickCount)
                let a = Angle.degrees(start + sweep * t).radians
                var p = Path()
                p.move(to: CGPoint(x: c.x + rInner * CGFloat(cos(a)), y: c.y + rInner * CGFloat(sin(a))))
                p.addLine(to: CGPoint(x: c.x + rOuter * CGFloat(cos(a)), y: c.y + rOuter * CGFloat(sin(a))))
                ctx.stroke(p, with: .color(t <= f ? tint : Color.white.opacity(0.16)), lineWidth: 1.2)
            }
            let a = Angle.degrees(start + sweep * f).radians
            let rk = (rOuter + rInner) / 2
            let k = CGPoint(x: c.x + rk * CGFloat(cos(a)), y: c.y + rk * CGFloat(sin(a)))
            ctx.drawLayer { l in
                l.addFilter(.shadow(color: .white.opacity(0.8), radius: 5))
                l.fill(Path(ellipseIn: CGRect(x: k.x - 6, y: k.y - 6, width: 12, height: 12)), with: .color(.white))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Lists

/// The `.list` container: rows stacked with hairline dividers between them, on the near-black surface
/// with a 24 pt radius. Dividers are inserted automatically between the direct children.
public struct NoopList<Content: View>: View {
    @ViewBuilder public var content: () -> Content
    public init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    public var body: some View {
        _VariadicView.Tree(NoopListLayout()) { content() }
            .background(
                RoundedRectangle(cornerRadius: NoopVisualStyle.listRadius, style: .continuous)
                    .fill(NoopVisualStyle.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: NoopVisualStyle.listRadius, style: .continuous)
                    .strokeBorder(NoopVisualStyle.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: NoopVisualStyle.listRadius, style: .continuous))
    }
}

private struct NoopListLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(children) { child in
                if child.id != children.first?.id {
                    Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
                }
                child
            }
        }
    }
}

/// A `.li` row: optional 34 pt icon tile, a 15 pt Book title with an optional 12 pt caption, a trailing
/// value or control, and an optional chevron.
public struct NoopRow<Trailing: View>: View {
    private let icon: String?
    private let title: Text
    private let caption: Text?
    public var chevron: Bool
    @ViewBuilder private var trailing: () -> Trailing

    public init(_ title: LocalizedStringKey, caption: LocalizedStringKey? = nil, icon: String? = nil,
                chevron: Bool = false, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = Text(title)
        self.caption = caption.map { Text($0) }
        self.icon = icon
        self.chevron = chevron
        self.trailing = trailing
    }
    public init(verbatim title: String, caption: String? = nil, icon: String? = nil,
                chevron: Bool = false, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = Text(verbatim: title)
        self.caption = caption.map { Text(verbatim: $0) }
        self.icon = icon
        self.chevron = chevron
        self.trailing = trailing
    }
    public init(title: Text, caption: Text? = nil, icon: String? = nil,
                chevron: Bool = false, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.caption = caption
        self.icon = icon
        self.chevron = chevron
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 14) {
            if let icon { NoopIconTile(icon) }
            VStack(alignment: .leading, spacing: 2) {
                title.font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let caption {
                    caption.font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
            if chevron {
                PhIcon("caret-right", size: 14).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

public extension NoopRow where Trailing == Text? {
    init(_ title: LocalizedStringKey, caption: LocalizedStringKey? = nil, icon: String? = nil,
         value: String? = nil, chevron: Bool = false) {
        self.init(title, caption: caption, icon: icon, chevron: chevron) { value.map { Text(verbatim: $0) } }
    }
}

/// The 34 pt rounded icon tile used at the leading edge of list rows.
public struct NoopIconTile: View {
    public var icon: String
    public var size: CGFloat
    public init(_ icon: String, size: CGFloat = 34) {
        self.icon = icon
        self.size = size
    }
    public var body: some View {
        PhIcon(icon, size: size * 0.5)
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: NoopVisualStyle.tileRadius, style: .continuous)
                .fill(NoopVisualStyle.raised))
    }
}

// MARK: Controls

/// The v2 switch (`.sw`): 46 × 28; ink track with a black knob when on, dark grey with a grey knob off.
public struct NoopSwitchToggleStyle: ToggleStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        NoopSwitchRow(configuration: configuration)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(configuration.isOn ? Text("On", bundle: .module) : Text("Off", bundle: .module))
            .accessibilityAction { configuration.isOn.toggle() }
    }
}

/// The switch with its label. With `.labelsHidden()` (a switch in a row's trailing slot) it is only the
/// 46 pt switch: a spacer there would claim half the row and wrap the row's title early.
private struct NoopSwitchRow: View {
    let configuration: ToggleStyleConfiguration

    var body: some View {
        if #available(iOS 18.0, macOS 15.0, watchOS 11.0, *) {
            LabelAwareSwitchRow(configuration: configuration)
        } else {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 0)
                NoopSwitchKnob(configuration: configuration)
            }
        }
    }
}

@available(iOS 18.0, macOS 15.0, watchOS 11.0, *)
private struct LabelAwareSwitchRow: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.labelsVisibility) private var labelsVisibility

    var body: some View {
        if labelsVisibility == .hidden {
            NoopSwitchKnob(configuration: configuration)
        } else {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 0)
                NoopSwitchKnob(configuration: configuration)
            }
        }
    }
}

/// The 46 × 28 pt track and knob: ink track with a black knob when on, dark grey with a grey knob off.
private struct NoopSwitchKnob: View {
    let configuration: ToggleStyleConfiguration

    var body: some View {
        Button {
            withAnimation(StrandMotion.interactive) { configuration.isOn.toggle() }
            StrandHaptic.selection.play()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(configuration.isOn ? StrandPalette.textPrimary : Color(light: "#D4D3CF", dark: "#2A2A2E"))
                Circle()
                    .fill(configuration.isOn ? Color(light: "#FFFFFF", dark: "#000000")
                                             : Color(light: "#FFFFFF", dark: "#8A8A90"))
                    .frame(width: 22, height: 22)
                    .padding(3)
            }
            .frame(width: 46, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }
}

public extension ToggleStyle where Self == NoopSwitchToggleStyle {
    /// The v2 switch.
    static var noop: NoopSwitchToggleStyle { .init() }
}

/// A filter chip (`.chip` / `.chip.on`): 30 pt capsule, 12 pt label; selected = ink fill, black text.
public struct NoopChip: View {
    private let text: Text
    public var isOn: Bool
    public var icon: String?
    public init(_ key: LocalizedStringKey, isOn: Bool = false, icon: String? = nil) {
        self.text = Text(key)
        self.isOn = isOn
        self.icon = icon
    }
    public init(verbatim s: String, isOn: Bool = false, icon: String? = nil) {
        self.text = Text(verbatim: s)
        self.isOn = isOn
        self.icon = icon
    }
    public var body: some View {
        HStack(spacing: 6) {
            if let icon { PhIcon(icon, size: 14) }
            text.font(StrandFont.book(12, relativeTo: .caption)).lineLimit(1)
        }
        .foregroundStyle(isOn ? StrandPalette.goldDeepText : StrandPalette.textSecondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule(style: .continuous).fill(isOn ? StrandPalette.gold : NoopVisualStyle.inset))
        .overlay(Capsule(style: .continuous).strokeBorder(isOn ? Color.clear : NoopVisualStyle.border, lineWidth: 1))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The 42 pt circle button (`.cb`) — back, close, gear, plus, search.
public struct NoopCircleButton: View {
    public var icon: String
    public var size: CGFloat
    public var accessibilityLabel: Text
    public var action: () -> Void
    public init(_ icon: String, size: CGFloat = 42, accessibilityLabel: LocalizedStringKey, action: @escaping () -> Void) {
        self.icon = icon
        self.size = size
        self.accessibilityLabel = Text(accessibilityLabel)
        self.action = action
    }
    public var body: some View {
        Button(action: action) {
            NoopCircleIcon(icon, size: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The circle-button chrome without the button (for use inside `Menu` / `NavigationLink` labels).
public struct NoopCircleIcon: View {
    public var icon: String
    public var size: CGFloat
    public init(_ icon: String, size: CGFloat = 42) {
        self.icon = icon
        self.size = size
    }
    public var body: some View {
        PhIcon(icon, size: 18)
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(width: size, height: size)
            .background(Circle().fill(NoopVisualStyle.inset))
            .overlay(Circle().strokeBorder(NoopVisualStyle.border, lineWidth: 1))
            .contentShape(Circle())
    }
}

/// The `.pill`: a 38 pt raised capsule with a 14 pt Book label (pager label, "Last night", "Share").
public struct NoopPill: View {
    private let text: Text
    public var icon: String?
    public var compact: Bool
    public init(_ key: LocalizedStringKey, icon: String? = nil, compact: Bool = false) {
        self.text = Text(key)
        self.icon = icon
        self.compact = compact
    }
    public init(verbatim s: String, icon: String? = nil, compact: Bool = false) {
        self.text = Text(verbatim: s)
        self.icon = icon
        self.compact = compact
    }
    public var body: some View {
        HStack(spacing: 6) {
            if let icon { PhIcon(icon, size: compact ? 13 : 15) }
            text.font(StrandFont.book(compact ? 12 : 14, relativeTo: .subheadline)).lineLimit(1)
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .padding(.horizontal, compact ? 12 : 18)
        .frame(height: compact ? 30 : 38)
        .background(Capsule(style: .continuous).fill(compact ? Color.white.opacity(0.07) : NoopVisualStyle.inset))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
    }
}

/// The hero `.badge`: a 34 pt translucent circle holding an icon, then a 14 pt Book label.
public struct NoopIconBadge: View {
    public var icon: String
    private let title: Text
    public init(_ title: LocalizedStringKey, icon: String) {
        self.title = Text(title)
        self.icon = icon
    }
    public init(verbatim title: String, icon: String) {
        self.title = Text(verbatim: title)
        self.icon = icon
    }
    public var body: some View {
        HStack(spacing: 8) {
            PhIcon(icon, size: 16)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.10)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            title.font(StrandFont.book(14, relativeTo: .subheadline))
        }
        .foregroundStyle(StrandPalette.textPrimary)
    }
}

/// The `.av` avatar: initials on a soft radial grey disc.
public struct NoopAvatar: View {
    public var initials: String
    public var size: CGFloat
    public init(_ initials: String, size: CGFloat = 42) {
        self.initials = initials
        self.size = size
    }
    public var body: some View {
        Text(verbatim: initials)
            .font(StrandFont.medium(size * 0.36))
            .foregroundStyle(StrandPalette.textSecondary)
            .frame(width: size, height: size)
            .background(
                Circle().fill(RadialGradient(colors: [Color(hex: "#3A3A40"), Color(hex: "#121214")],
                                             center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.75))
            )
            .overlay(Circle().strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
    }
}

// MARK: Headers

/// The `.pager` (‹ Today ›): chevrons either side of a pill label.
public struct NoopPager: View {
    private let label: Text
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var onBack: () -> Void
    public var onForward: () -> Void
    public init(label: Text, canGoBack: Bool = true, canGoForward: Bool = true,
                onBack: @escaping () -> Void, onForward: @escaping () -> Void) {
        self.label = label
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.onBack = onBack
        self.onForward = onForward
    }
    public var body: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                PhIcon("caret-left", size: 16).frame(width: 22, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoBack)
            .opacity(canGoBack ? 0.8 : 0.25)
            .accessibilityLabel(Text("Previous", bundle: .module))
            label
                .font(StrandFont.book(14, relativeTo: .subheadline))
                .lineLimit(1)
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
                .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
            Button(action: onForward) {
                PhIcon("caret-right", size: 16).frame(width: 22, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoForward)
            .opacity(canGoForward ? 0.8 : 0.25)
            .accessibilityLabel(Text("Next", bundle: .module))
        }
        .foregroundStyle(StrandPalette.textPrimary)
    }
}

/// A detail-screen header: back circle, 17 pt Book title, trailing content (a pager or circle buttons).
public struct NoopDetailHeader<Trailing: View>: View {
    private let title: Text
    public var onBack: (() -> Void)?
    @ViewBuilder private var trailing: () -> Trailing

    public init(_ title: LocalizedStringKey, onBack: (() -> Void)?, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = Text(title)
        self.onBack = onBack
        self.trailing = trailing
    }
    public init(verbatim title: String, onBack: (() -> Void)?, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = Text(verbatim: title)
        self.onBack = onBack
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 12) {
            if let onBack {
                NoopCircleButton("caret-left", accessibilityLabel: "Back", action: onBack)
            }
            title.font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

public extension NoopDetailHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, onBack: (() -> Void)?) {
        self.init(title, onBack: onBack) { EmptyView() }
    }
}

/// A v2 sheet header (`.shd`): Cancel · title · primary action.
public struct NoopSheetHeader: View {
    private let title: Text
    private let cancelTitle: Text
    private let doneTitle: Text?
    public var onCancel: () -> Void
    public var onDone: (() -> Void)?
    public var doneEnabled: Bool

    public init(_ title: LocalizedStringKey, cancelTitle: LocalizedStringKey = "Cancel",
                doneTitle: LocalizedStringKey? = "Done", doneEnabled: Bool = true,
                onCancel: @escaping () -> Void, onDone: (() -> Void)? = nil) {
        self.title = Text(title)
        self.cancelTitle = Text(cancelTitle)
        self.doneTitle = doneTitle.map { Text($0) }
        self.doneEnabled = doneEnabled
        self.onCancel = onCancel
        self.onDone = onDone
    }

    public var body: some View {
        ZStack {
            title.font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary).lineLimit(1)
            HStack {
                Button(action: onCancel) { cancelTitle }
                    .buttonStyle(.plain)
                    .font(StrandFont.light(15))
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                if let doneTitle, let onDone {
                    Button(action: onDone) { doneTitle }
                        .buttonStyle(.plain)
                        .font(StrandFont.medium(15))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .disabled(!doneEnabled)
                        .opacity(doneEnabled ? 1 : 0.4)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }
}

/// The v2 sheet background: a near-black gradient with a hairline top edge.
public struct NoopSheetBackground: View {
    public init() {}
    public var body: some View {
        LinearGradient(
            stops: [.init(color: Color(light: "#FFFFFF", dark: "#121214"), location: 0),
                    .init(color: Color(light: "#F7F6F3", dark: "#09090A"), location: 0.3)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

// MARK: Charts

/// The v2 line chart: a 1.2 pt line over a soft gradient fill fading to clear, an optional highlighted
/// window (translucent band, 1 pt top rule, a label above) and an optional cursor (dashed rule with a
/// white end dot). Values are drawn left to right and scaled into `range` (or their own extent).
public struct NoopAreaChart: View {
    public var values: [Double]
    public var range: ClosedRange<Double>?
    public var line: Color
    public var fill: Color
    public var highlight: ClosedRange<Double>?
    private let highlightLabel: Text?
    public var cursor: Double?
    public var lineWidth: CGFloat

    public init(values: [Double], range: ClosedRange<Double>? = nil,
                line: Color = Color(hex: "#8E9CF2"), fill: Color = Color(hex: "#5872F2"),
                highlight: ClosedRange<Double>? = nil, highlightLabel: Text? = nil,
                cursor: Double? = nil, lineWidth: CGFloat = 1.2) {
        self.values = values
        self.range = range
        self.line = line
        self.fill = fill
        self.highlight = highlight
        self.highlightLabel = highlightLabel
        self.cursor = cursor
        self.lineWidth = lineWidth
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let lo = range?.lowerBound ?? (values.min() ?? 0)
        let hi = range?.upperBound ?? (values.max() ?? 1)
        let span = max(hi - lo, 0.000_1)
        return values.enumerated().map { i, v in
            let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
            let y = size.height * (1 - CGFloat((min(max(v, lo), hi) - lo) / span))
            return CGPoint(x: x, y: y)
        }
    }

    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let pts = points(in: size)
            ZStack(alignment: .topLeading) {
                if let highlight {
                    let x0 = size.width * CGFloat(min(max(highlight.lowerBound, 0), 1))
                    let x1 = size.width * CGFloat(min(max(highlight.upperBound, 0), 1))
                    Rectangle().fill(Color.white.opacity(0.07))
                        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.35)).frame(height: 1) }
                        .frame(width: max(1, x1 - x0), height: size.height)
                        .offset(x: x0)
                    if let highlightLabel {
                        highlightLabel.font(StrandFont.light(10.5)).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize()
                            .frame(width: max(1, x1 - x0))
                            .offset(x: x0, y: -16)
                    }
                }
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [fill.opacity(0.5), fill.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: pts[0])
                        pts.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(line, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    if let cursor {
                        let i = Int((Double(pts.count - 1) * min(max(cursor, 0), 1)).rounded())
                        let p = pts[i]
                        Path { path in
                            path.move(to: CGPoint(x: p.x, y: 0))
                            path.addLine(to: CGPoint(x: p.x, y: size.height))
                        }
                        .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        Circle().fill(Color.white).frame(width: 7, height: 7)
                            .position(p)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("v2 components") {
    ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            NoopHeroCard(glow: .recovery, minHeight: 300) {
                VStack(spacing: 18) {
                    HStack { NoopIconBadge("Charge", icon: "lightning"); Spacer(); ScoreStatePill(.solid) }
                    NoopDotNumber("78", unit: "%")
                    NoopTickScale(marker: 0.78)
                    HStack(spacing: 4) { Text("HRV is"); NoopTag(verbatim: "Above"); Text("baseline") }
                        .font(StrandFont.light(14))
                }
            }
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    NoopCardHeader("Heart rate", icon: "heart", caption: "Overnight · 48–71 bpm")
                    NoopAreaChart(values: [60, 58, 55, 53, 52, 51, 52, 55, 57, 60, 64, 66], cursor: 1).frame(height: 64)
                    NoopMetricRow {
                        NoopMetric(value: "68", unit: "ms", label: "Heart rate variability")
                        NoopMetric(value: "52", unit: "bpm", label: "Resting heart rate")
                        NoopMetric(value: "15.2", unit: "rpm", label: "Breaths per minute")
                    }
                    NoopTrack(fraction: 0.54, height: 10, target: 0.60...0.75)
                }
            }
            NoopSectionTitle("Last workouts", caption: "31 total")
            NoopList {
                NoopRow("Run", caption: "Yesterday · 52 min", icon: "person-simple-run", value: "62", chevron: true)
                NoopRow("Strength", caption: "Thu · 46 min", icon: "barbell", value: "41", chevron: true)
                Toggle(isOn: .constant(true)) { Text("Bedtime reminder") }.toggleStyle(.noop).padding(18)
            }
            HStack { NoopChip("All", isOn: true); NoopChip("Runs"); NoopPill("Today"); NoopAvatar("TL") }
            NoopButton("Start workout", kind: .primary, fullWidth: true) {}
            NoopButton("Log manually", kind: .secondary, fullWidth: true) {}
        }
        .padding(20)
    }
    .frame(width: 390, height: 1300)
    .background(Color.black)
    .preferredColorScheme(.dark)
}
#endif

// MARK: - Screen chrome convention

/// The v2 header for any screen that can be pushed or presented: a back circle (only when the screen
/// was pushed or presented — never on a tab root or a macOS sidebar root), the 17 pt title, and trailing
/// circle buttons. The back circle calls `dismiss`, which pops a pushed screen and closes a sheet alike.
/// Pair with `noopHidesSystemNavBar()` so the system bar does not draw a second header above it.
public struct NoopScreenHeader<Trailing: View>: View {
    private let title: Text
    @ViewBuilder private var trailing: () -> Trailing
    @Environment(\.isPresented) private var isPresented
    @Environment(\.dismiss) private var dismiss

    public init(_ title: LocalizedStringKey, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = Text(title)
        self.trailing = trailing
    }
    public init(verbatim title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = Text(verbatim: title)
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 12) {
            if isPresented {
                NoopCircleButton("caret-left", accessibilityLabel: "Back") { dismiss() }
            }
            title.font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

public extension NoopScreenHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey) { self.init(title) { EmptyView() } }
    init(verbatim title: String) { self.init(verbatim: title) { EmptyView() } }
}

public extension View {
    /// Hide the system navigation bar because the screen draws its own v2 header (`NoopScreenHeader` /
    /// `NoopDetailHeader`). iOS keeps the edge swipe-back gesture (the shell re-enables it for hidden
    /// bars); on macOS this is a no-op.
    @ViewBuilder
    func noopHidesSystemNavBar() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}
