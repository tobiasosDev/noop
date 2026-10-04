import SwiftUI
import StrandDesign

/// Shared Shown / Hidden list used by Today sections, Key Metrics, Your Cards and the Sleep sheet.
///
/// v2: the rows sit on the `.list` surface (24 pt radius, hairline dividers) with a drag handle at the
/// leading edge, the item's icon tile, and a minus / plus circle that moves it between Shown and Hidden.
/// Reordering is the List's own long-press drag (`onMove`), with VoiceOver "Move up / Move down" actions
/// and a context menu as the non-drag path.
struct EditableLayoutList<Item, Options>: View
where Item: Identifiable & Equatable, Options: View {
    @Binding var draft: EditableLayoutDraft<Item>

    let shownTitle: String
    let hiddenTitle: String
    let title: (Item) -> String
    let subtitle: (Item) -> String?
    /// A Phosphor icon name.
    let icon: (Item) -> String
    /// Kept for source compatibility; v2 rows are neutral (one accent per screen).
    let tint: (Item) -> Color
    let configurationLabel: (Item) -> String?
    let onConfigure: (Item) -> Void
    let onReset: () -> Void
    /// Whether the Shown list may go EMPTY. Default false — every visible item can be hidden EXCEPT the
    /// last, so surfaces that need ≥1 item (Today sections, Key Metrics, Your Cards) can't be emptied. The
    /// hosted-cards page (#today-hosted-cards) is opt-in, so it passes `true` to allow un-hosting the last.
    var allowEmpty: Bool = false
    /// Optional grouping key for the Hidden ("Available") list. When set (the hosted-cards page passes the
    /// card's origin, e.g. "Sleep" / "Trends"), the Available items are split into one titled group per
    /// origin. nil keeps the single flat Available list. The Shown list stays flat — it is the user's own
    /// cross-origin order.
    var group: ((Item) -> String)? = nil
    /// The sentence above the lists.
    var intro: String? = nil
    /// The right-hand caption of a list label ("9 blocks"); nil shows the bare count.
    var countLabel: ((Int) -> String)? = nil
    /// An icon instead of the text configuration label (the Key metrics row's expand caret).
    var configurationIcon: ((Item) -> String?)? = nil
    /// Content shown inside a Shown row, under its title (the Key metrics trend panel).
    var nested: ((Item) -> AnyView?)? = nil
    @ViewBuilder let options: () -> Options

    var body: some View {
        List {
            if let intro {
                Text(intro)
                    .font(StrandFont.light(13))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 20)
                    .plainLayoutRow()
            }

            options()

            listLabel(shownTitle, count: draft.visible.count)
                .plainLayoutRow()
            ForEach(draft.visible) { item in
                visibleRow(item)
                    .plainLayoutRow(horizontal: NoopMetrics.screenHPadding)
            }
            .onMove(perform: moveVisible)

            if draft.hidden.isEmpty {
                listLabel(hiddenTitle, count: 0)
                    .padding(.top, 28)
                    .plainLayoutRow()
                Text("Nothing hidden")
                    .font(StrandFont.light(14))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LayoutRowSurface(position: .only))
                    .plainLayoutRow(horizontal: NoopMetrics.screenHPadding)
            } else if group != nil {
                // Grouped Available list: one titled group per origin (e.g. "Sleep", "Trends"), so the
                // hidden cards read by category.
                let groups = groupedHidden
                ForEach(groups.indices, id: \.self) { i in
                    listLabel(groups[i].name, count: groups[i].items.count)
                        .padding(.top, 28)
                        .plainLayoutRow()
                    ForEach(groups[i].items) { item in
                        hiddenRow(item, position: position(of: item, in: groups[i].items))
                            .plainLayoutRow(horizontal: NoopMetrics.screenHPadding)
                    }
                }
            } else {
                listLabel(hiddenTitle, count: draft.hidden.count)
                    .padding(.top, 28)
                    .plainLayoutRow()
                ForEach(draft.hidden) { item in
                    hiddenRow(item, position: position(of: item, in: draft.hidden))
                        .plainLayoutRow(horizontal: NoopMetrics.screenHPadding)
                }
            }

            resetRow
                .padding(.top, 28)
                .padding(.bottom, 24)
                .plainLayoutRow(horizontal: NoopMetrics.screenHPadding)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        #if os(iOS) && DEBUG
        .modifier(DemoScrollAnchor())
        #endif
    }

    // MARK: Pieces

    /// The `.slabel` above a list: 12 pt uppercase ink3, a count at the right.
    private func listLabel(_ text: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: text)
                .font(StrandFont.book(12, relativeTo: .caption))
                .tracking(12 * 0.08)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Text(verbatim: countLabel?(count) ?? "\(count)")
                .font(StrandFont.book(12, relativeTo: .caption))
        }
        .foregroundStyle(StrandPalette.textTertiary)
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }

    private func visibleRow(_ item: Item) -> some View {
        let canHide = draft.visible.count > (allowEmpty ? 0 : 1)
        let index = draft.visible.firstIndex(of: item) ?? 0
        return EditableLayoutRow(
            title: title(item),
            subtitle: subtitle(item),
            icon: icon(item),
            configurationLabel: configurationLabel(item),
            configurationIcon: configurationIcon?(item),
            isVisible: true,
            canHide: canHide,
            position: position(of: item, in: draft.visible),
            nested: nested?(item),
            onConfigure: { onConfigure(item) },
            onVisibilityChange: { hide(item) }
        )
        .contextMenu {
            if index > 0 {
                Button("Move up") { move(item, by: -1) }
            }
            if index < draft.visible.count - 1 {
                Button("Move down") { move(item, by: 1) }
            }
            if canHide {
                Button("Hide") { hide(item) }
            }
        }
        .accessibilityAction(named: Text("Move up")) { move(item, by: -1) }
        .accessibilityAction(named: Text("Move down")) { move(item, by: 1) }
    }

    /// One Available (hidden) row — the show affordance. Shared by the flat and grouped Available lists.
    private func hiddenRow(_ item: Item, position: LayoutRowPosition) -> some View {
        EditableLayoutRow(
            title: title(item),
            subtitle: subtitle(item),
            icon: icon(item),
            configurationLabel: nil,
            configurationIcon: nil,
            isVisible: false,
            canHide: true,
            position: position,
            nested: nil,
            onConfigure: { onConfigure(item) },
            onVisibilityChange: { show(item) }
        )
        .moveDisabled(true)
    }

    private var resetRow: some View {
        VStack(spacing: 10) {
            Button(action: onReset) {
                HStack(spacing: 8) {
                    PhIcon("arrow-counter-clockwise", size: 16).opacity(0.7)
                    Text("Reset This Layout")
                }
                .font(StrandFont.book(15, relativeTo: .body))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(LayoutRowSurface(position: .only))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reset This Layout")
            Text("Puts everything back in NOOP's default order. Your data and card settings stay as they are.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
        }
    }

    private func position(of item: Item, in items: [Item]) -> LayoutRowPosition {
        guard let i = items.firstIndex(of: item) else { return .only }
        if items.count == 1 { return .only }
        if i == 0 { return .first }
        if i == items.count - 1 { return .last }
        return .middle
    }

    /// The hidden items bucketed by `group`, groups in first-appearance order (which follows the draft's
    /// canonical order). Only read when `group != nil`.
    private var groupedHidden: [(name: String, items: [Item])] {
        guard let group else { return [] }
        var order: [String] = []
        var buckets: [String: [Item]] = [:]
        for item in draft.hidden {
            let key = group(item)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.map { (name: $0, items: buckets[$0] ?? []) }
    }

    private func moveVisible(from offsets: IndexSet, to destination: Int) {
        draft.moveVisible(from: offsets, to: destination)
    }

    /// The non-drag reorder path (VoiceOver action, context menu): one step up or down.
    private func move(_ item: Item, by step: Int) {
        guard let i = draft.visible.firstIndex(of: item) else { return }
        let target = i + step
        guard target >= 0, target < draft.visible.count else { return }
        withAnimation(StrandMotion.interactive) {
            draft.moveVisible(from: IndexSet(integer: i), to: step > 0 ? target + 1 : target)
        }
    }

    private func hide(_ item: Item) {
        withAnimation(StrandMotion.interactive) {
            draft.hide(item)
        }
    }

    private func show(_ item: Item) {
        withAnimation(StrandMotion.interactive) {
            draft.show(item)
        }
    }
}

/// Where a row sits in its list, so the row can draw its slice of the 24 pt list surface.
enum LayoutRowPosition {
    case first, middle, last, only
}

/// One row's slice of the `.list` surface: the near-black fill, the outer hairline, rounded only at the
/// list's own top and bottom, and the hairline divider above every row but the first.
struct LayoutRowSurface: View {
    let position: LayoutRowPosition
    var fill: Color = NoopVisualStyle.surface

    var body: some View {
        let r = NoopVisualStyle.listRadius
        let top: CGFloat = (position == .first || position == .only) ? r : 0
        let bottom: CGFloat = (position == .last || position == .only) ? r : 0
        let shape = UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                           bottomTrailingRadius: bottom, topTrailingRadius: top,
                                           style: .continuous)
        ZStack(alignment: .top) {
            shape.fill(fill)
            // The outer hairline, extended past the internal edges and clipped, so only the list's outer
            // edges draw a line.
            shape.strokeBorder(NoopVisualStyle.border, lineWidth: 1)
                .padding(.top, top == 0 ? -2 : 0)
                .padding(.bottom, bottom == 0 ? -2 : 0)
            if position == .middle || position == .last {
                Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
            }
        }
        .clipped()
    }
}

private struct EditableLayoutRow: View {
    let title: String
    let subtitle: String?
    let icon: String
    let configurationLabel: String?
    let configurationIcon: String?
    let isVisible: Bool
    let canHide: Bool
    let position: LayoutRowPosition
    let nested: AnyView?
    let onConfigure: () -> Void
    let onVisibilityChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                PhIcon("dots-six-vertical", size: 20)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .opacity(isVisible ? 0.38 : 0.14)
                    .accessibilityHidden(true)

                iconGlyph
                    .foregroundStyle(isVisible ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NoopVisualStyle.raised))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(isVisible ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                    if let subtitle {
                        // Two lines: German captions ("Streamt, solange der Strap in Reichweite ist") do
                        // not fit one line beside the configure and visibility buttons.
                        Text(verbatim: subtitle)
                            .font(StrandFont.light(12, relativeTo: .caption))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let configurationIcon {
                    Button(action: onConfigure) {
                        PhIcon(configurationIcon, size: 20)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .opacity(0.6)
                            .frame(width: 30, height: 30)
                            .padding(7)
                            .contentShape(Rectangle())
                            .padding(-7)   // 44 pt tap target, 30 pt in the layout
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Edit \(title)"))
                } else if let configurationLabel {
                    Button(configurationLabel, action: onConfigure)
                        .buttonStyle(.plain)
                        .font(StrandFont.book(13, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .accessibilityLabel(String(localized: "Edit \(title)"))
                }

                Button(action: onVisibilityChange) {
                    PhIcon(isVisible ? "minus-circle" : "plus-circle", size: 20)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .opacity(isVisible ? 0.45 : 0.8)
                        .frame(width: 30, height: 30)
                        .padding(7)
                        .contentShape(Rectangle())
                        .padding(-7)   // 44 pt tap target, 30 pt in the layout
                }
                .buttonStyle(.plain)
                .disabled(isVisible && !canHide)
                .opacity(isVisible && !canHide ? 0.4 : 1)
                .accessibilityLabel(visibilityLabel)
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .padding(.vertical, 12)

            if let nested {
                nested
                    .padding(.leading, 52)
                    .padding(.trailing, 14)
                    .padding(.bottom, 14)
            }
        }
        .contentShape(Rectangle())
        .background(LayoutRowSurface(position: position))
    }

    /// The row's Phosphor glyph; a neutral square stands in for a name the bundle does not carry, so a
    /// typo shows an empty tile rather than nothing at all.
    private var iconGlyph: some View {
        PhIcon(PhIcon.exists(icon) ? icon : "square", size: 17)
    }

    private var visibilityLabel: String {
        isVisible
            ? String(localized: "Hide \(title)")
            : String(localized: "Show \(title)")
    }
}

private extension View {
    /// A List row with no system chrome: no separator, no background, explicit insets.
    func plainLayoutRow(horizontal: CGFloat = 0) -> some View {
        self
            .listRowInsets(EdgeInsets(top: 0, leading: horizontal, bottom: 0, trailing: horizontal))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
