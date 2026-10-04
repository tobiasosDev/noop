import SwiftUI
import StrandDesign

// MARK: - Unified Today customization

/// Every Today editing entry point presents the same sheet and optionally deep-links to one child editor.
enum TodayCustomizationDestination: String, Identifiable, Hashable {
    case today
    case keyMetrics
    case yourCards
    case addedCards

    var id: String { rawValue }
}

struct TodayCustomizationSheet: View {
    @Environment(\.dismiss) private var dismiss

    private enum Route: Hashable {
        case keyMetrics
        case yourCards
        case addedCards
    }

    private let initialSectionDraft: EditableLayoutDraft<TodaySection>
    private let initialKeyMetricDraft: EditableLayoutDraft<KeyMetric>
    private let initialDashboardDraft: EditableLayoutDraft<DashboardCard>
    private let initialHostedDraft: EditableLayoutDraft<HostedCard>
    private let initialDetailed: Bool
    private let initialWindowDays: Int

    @Binding private var sectionOrderRaw: String
    @Binding private var hiddenSectionsRaw: String
    @Binding private var keyMetricsRaw: String
    @Binding private var keyMetricsDetailed: Bool
    @Binding private var keyMetricsWindowDays: Int
    @Binding private var dashboardCardsRaw: String
    @Binding private var hostedCardsRaw: String

    @State private var path: [Route]
    @State private var sectionDraft: EditableLayoutDraft<TodaySection>
    @State private var keyMetricDraft: EditableLayoutDraft<KeyMetric>
    @State private var dashboardDraft: EditableLayoutDraft<DashboardCard>
    @State private var hostedDraft: EditableLayoutDraft<HostedCard>
    @State private var detailed: Bool
    @State private var windowDays: Int

    private var currentDestination: TodayCustomizationDestination {
        switch path.last {
        case .keyMetrics: return .keyMetrics
        case .yourCards: return .yourCards
        case .addedCards: return .addedCards
        case nil: return .today
        }
    }

    private var isDirty: Bool {
        sectionDraft != initialSectionDraft
            || keyMetricDraft != initialKeyMetricDraft
            || dashboardDraft != initialDashboardDraft
            || hostedDraft != initialHostedDraft
            || detailed != initialDetailed
            || windowDays != initialWindowDays
    }

    init(
        initialDestination: TodayCustomizationDestination = .today,
        sectionOrderRaw: Binding<String>,
        hiddenSectionsRaw: Binding<String>,
        keyMetricsRaw: Binding<String>,
        keyMetricsDetailed: Binding<Bool>,
        keyMetricsWindowDays: Binding<Int>,
        dashboardCardsRaw: Binding<String>,
        hostedCardsRaw: Binding<String>
    ) {
        _sectionOrderRaw = sectionOrderRaw
        _hiddenSectionsRaw = hiddenSectionsRaw
        _keyMetricsRaw = keyMetricsRaw
        _keyMetricsDetailed = keyMetricsDetailed
        _keyMetricsWindowDays = keyMetricsWindowDays
        _dashboardCardsRaw = dashboardCardsRaw
        _hostedCardsRaw = hostedCardsRaw

        let fullSectionOrder = TodayLayoutPrefs.decodeOrder(sectionOrderRaw.wrappedValue)
        let hiddenSectionSet = Set(TodayLayoutPrefs.decodeHidden(hiddenSectionsRaw.wrappedValue))
        let sections = EditableLayoutDraft(
            visible: fullSectionOrder.filter { !hiddenSectionSet.contains($0) },
            hidden: fullSectionOrder.filter { hiddenSectionSet.contains($0) }
        )
        let metrics = EditableLayoutDraft(
            visible: KeyMetricPrefs.decodeEnabled(keyMetricsRaw.wrappedValue),
            allItems: KeyMetric.defaultOrder
        )
        let cards = EditableLayoutDraft(
            visible: DashboardCardPrefs.decodeEnabled(dashboardCardsRaw.wrappedValue),
            allItems: DashboardCard.canonicalOrder
        )
        let hosted = EditableLayoutDraft(
            visible: HostedCardPrefs.decodeEnabled(hostedCardsRaw.wrappedValue),
            allItems: HostedCard.canonicalOrder
        )

        initialSectionDraft = sections
        initialKeyMetricDraft = metrics
        initialDashboardDraft = cards
        initialHostedDraft = hosted
        initialDetailed = keyMetricsDetailed.wrappedValue
        initialWindowDays = keyMetricsWindowDays.wrappedValue

        _sectionDraft = State(initialValue: sections)
        _keyMetricDraft = State(initialValue: metrics)
        _dashboardDraft = State(initialValue: cards)
        _hostedDraft = State(initialValue: hosted)
        _detailed = State(initialValue: keyMetricsDetailed.wrappedValue)
        _windowDays = State(initialValue: keyMetricsWindowDays.wrappedValue)

        switch initialDestination {
        case .today:
            _path = State(initialValue: [])
        case .keyMetrics:
            _path = State(initialValue: [.keyMetrics])
        case .yourCards:
            _path = State(initialValue: [.yourCards])
        case .addedCards:
            _path = State(initialValue: [.addedCards])
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                NoopSheetHeader("Customize Today", doneTitle: "Save", onCancel: cancel, onDone: save)
                TodaySectionsCustomizationPage(
                    draft: $sectionDraft,
                    keyMetrics: keyMetricDraft.visible,
                    dashboardCards: dashboardDraft.visible,
                    hostedCardCount: hostedDraft.visible.count,
                    detailed: $detailed,
                    windowDays: $windowDays,
                    onConfigure: openConfiguration,
                    onReset: resetCurrentLayout
                )
            }
            .background(NoopSheetBackground())
            .noopHidesSystemNavBar()
            .navigationDestination(for: Route.self) { route in
                VStack(spacing: 0) {
                    subpageHeader(route)
                    switch route {
                    case .keyMetrics:
                        KeyMetricsCustomizationPage(
                            draft: $keyMetricDraft,
                            detailed: $detailed,
                            windowDays: $windowDays,
                            onReset: resetCurrentLayout
                        )
                    case .yourCards:
                        DashboardCardsCustomizationPage(
                            draft: $dashboardDraft,
                            onReset: resetCurrentLayout
                        )
                    case .addedCards:
                        HostedCardsCustomizationPage(
                            draft: $hostedDraft,
                            onReset: resetCurrentLayout
                        )
                    }
                }
                .background(NoopSheetBackground())
                .noopHidesSystemNavBar()
            }
        }
        .interactiveDismissDisabled(isDirty)
        .tint(StrandPalette.textPrimary)
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #endif
        #if os(macOS)
        .frame(
            minWidth: NoopMetrics.editorSheetMinWidth,
            minHeight: NoopMetrics.editorSheetMinHeight
        )
        #endif
    }

    /// A nested editor's header: back to Customize Today, the editor's title, and Save (which commits
    /// every page's draft at once, as the root's Save does).
    private func subpageHeader(_ route: Route) -> some View {
        let title: LocalizedStringKey
        switch route {
        case .keyMetrics: title = "Key metrics"
        case .yourCards: title = "Your cards"
        case .addedCards: title = "Added cards"
        }
        return ZStack {
            Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary).lineLimit(1)
            HStack {
                NoopCircleButton("caret-left", size: 34, accessibilityLabel: "Back") {
                    if !path.isEmpty { path.removeLast() }
                }
                Spacer()
                Button(action: save) { Text("Save") }
                    .buttonStyle(.plain)
                    .font(StrandFont.medium(15))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    private func openConfiguration(_ section: TodaySection) {
        switch section {
        case .keyMetrics:
            path.append(.keyMetrics)
        case .yourCards:
            path.append(.yourCards)
        case .addedCards:
            path.append(.addedCards)
        default:
            break
        }
    }

    private func resetCurrentLayout() {
        switch currentDestination {
        case .today:
            sectionDraft = EditableLayoutDraft(
                visible: TodaySection.defaultOrder,
                allItems: TodaySection.defaultOrder
            )
        case .keyMetrics:
            keyMetricDraft = EditableLayoutDraft(
                visible: KeyMetric.defaultOrder,
                allItems: KeyMetric.defaultOrder
            )
            detailed = false
            windowDays = 14
        case .yourCards:
            dashboardDraft = EditableLayoutDraft(
                visible: DashboardCard.defaultSelection,
                allItems: DashboardCard.canonicalOrder
            )
        case .addedCards:
            hostedDraft = EditableLayoutDraft(
                visible: HostedCard.defaultSelection,
                allItems: HostedCard.canonicalOrder
            )
        }
    }

    private func cancel() {
        dismiss()
    }

    private func save() {
        sectionOrderRaw = TodayLayoutPrefs.encode(sectionDraft.visible + sectionDraft.hidden)
        hiddenSectionsRaw = TodayLayoutPrefs.encodeHidden(sectionDraft.hidden)
        keyMetricsRaw = KeyMetricPrefs.encode(keyMetricDraft.visible)
        keyMetricsDetailed = detailed
        keyMetricsWindowDays = windowDays
        dashboardCardsRaw = DashboardCardPrefs.encode(dashboardDraft.visible)
        hostedCardsRaw = HostedCardPrefs.encode(hostedDraft.visible)
        dismiss()
    }

}

// MARK: - Editor pages

private struct TodaySectionsCustomizationPage: View {
    @Binding var draft: EditableLayoutDraft<TodaySection>
    let keyMetrics: [KeyMetric]
    let dashboardCards: [DashboardCard]
    let hostedCardCount: Int
    @Binding var detailed: Bool
    @Binding var windowDays: Int
    let onConfigure: (TodaySection) -> Void
    let onReset: () -> Void
    /// The Key metrics row opens in place to its trend window and tile chips.
    @State private var keyMetricsExpanded = false

    var body: some View {
        EditableLayoutList(
            draft: $draft,
            shownTitle: String(localized: "Shown on Today"),
            hiddenTitle: String(localized: "Hidden"),
            title: \.customizationTitle,
            subtitle: subtitle,
            icon: \.customizationIcon,
            tint: \.customizationTint,
            configurationLabel: configurationLabel,
            onConfigure: configure,
            onReset: onReset,
            intro: String(localized: "Drag to reorder. Hidden blocks stay one tap away and keep their data."),
            countLabel: { String(localized: "\($0) blocks") },
            configurationIcon: { $0 == .keyMetrics ? (keyMetricsExpanded ? "caret-up" : "caret-down") : nil },
            nested: { section in
                guard section == .keyMetrics, keyMetricsExpanded else { return nil }
                return AnyView(KeyMetricsInlinePanel(metrics: keyMetrics, detailed: $detailed,
                                                     windowDays: $windowDays,
                                                     onEdit: { onConfigure(.keyMetrics) }))
            }
        ) {
            EmptyView()
        }
    }

    private func configure(_ section: TodaySection) {
        if section == .keyMetrics {
            withAnimation(StrandMotion.interactive) { keyMetricsExpanded.toggle() }
        } else {
            onConfigure(section)
        }
    }

    private func subtitle(for section: TodaySection) -> String? {
        switch section {
        case .keyMetrics:
            return String(localized: "\(keyMetrics.count) metrics shown")
        case .yourCards:
            // "4 cards · Stress, Fitness age, +2": the first two by name, the rest as a count.
            let names = dashboardCards.prefix(2).map(\.title)
            let rest = dashboardCards.count - names.count
            let list = names.joined(separator: ", ") + (rest > 0 ? ", +\(rest)" : "")
            return String(localized: "\(dashboardCards.count) cards · \(list)")
        case .addedCards:
            return hostedCardCount == 0
                ? String(localized: "None added yet")
                : String(localized: "\(hostedCardCount) added")
        default:
            return section.customizationCaption
        }
    }

    private func configurationLabel(for section: TodaySection) -> String? {
        switch section {
        case .yourCards, .addedCards:
            return String(localized: "Edit")
        default:
            return nil
        }
    }
}

/// The Key metrics row's in-place panel: sparklines on or off, their trend window, and the shown
/// tiles as chips with a dashed "Edit" chip into the full tile editor.
private struct KeyMetricsInlinePanel: View {
    let metrics: [KeyMetric]
    @Binding var detailed: Bool
    @Binding var windowDays: Int
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyMetricsTrendControls(detailed: $detailed, windowDays: $windowDays, compact: true)
            TodayChipFlowLayout(spacing: 6) {
                ForEach(metrics) { metric in
                    Text(verbatim: metric.title)
                        .font(StrandFont.book(11.5, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
                        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                }
                Button(action: onEdit) {
                    HStack(spacing: 5) {
                        PhIcon("plus", size: 11)
                        Text("Edit")
                    }
                    .font(StrandFont.book(11.5, relativeTo: .caption))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(NoopVisualStyle.borderHighlight, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit Key Metrics")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(NoopVisualStyle.inset))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
    }
}

/// "Sparklines on each tile" and the 1 week / 2 weeks / 1 month window they graph — the same two
/// settings the Key metrics editor has always carried (`today.keyMetricsDetailed` / `…WindowDays`).
private struct KeyMetricsTrendControls: View {
    @Binding var detailed: Bool
    @Binding var windowDays: Int
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $detailed) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trend window")
                        .font(StrandFont.book(compact ? 13 : 15, relativeTo: .subheadline))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Sparklines on each tile")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .toggleStyle(.noop)
            if detailed {
                SegmentedPillControl([7, 14, 30], selection: $windowDays, fillsAvailableWidth: true) { days in
                    switch days {
                    case 7: return String(localized: "1 week")
                    case 30: return String(localized: "1 month")
                    default: return String(localized: "2 weeks")
                    }
                }
            }
        }
    }
}

private struct KeyMetricsCustomizationPage: View {
    @Binding var draft: EditableLayoutDraft<KeyMetric>
    @Binding var detailed: Bool
    @Binding var windowDays: Int
    let onReset: () -> Void

    var body: some View {
        EditableLayoutList(
            draft: $draft,
            shownTitle: String(localized: "Shown"),
            hiddenTitle: String(localized: "Hidden"),
            title: \.title,
            subtitle: { _ in nil },
            icon: \.customizationIcon,
            tint: \.customizationTint,
            configurationLabel: { _ in nil },
            onConfigure: { _ in },
            onReset: onReset,
            intro: String(localized: "Drag to reorder. Hidden tiles stay one tap away and keep their data."),
            countLabel: { String(localized: "\($0) tiles") }
        ) {
            KeyMetricsTrendControls(detailed: $detailed, windowDays: $windowDays)
                .padding(18)
                .background(LayoutRowSurface(position: .only))
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.bottom, 28)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }
}

private struct DashboardCardsCustomizationPage: View {
    @Binding var draft: EditableLayoutDraft<DashboardCard>
    let onReset: () -> Void

    var body: some View {
        EditableLayoutList(
            draft: $draft,
            shownTitle: String(localized: "Shown"),
            hiddenTitle: String(localized: "Hidden"),
            title: \.title,
            subtitle: \.subtitle,
            icon: \.phIcon,
            tint: \.customizationTint,
            configurationLabel: { _ in nil },
            onConfigure: { _ in },
            onReset: onReset,
            intro: String(localized: "Drag to reorder. Hidden cards stay one tap away and keep their data."),
            countLabel: { String(localized: "\($0) cards") }
        ) {
            EmptyView()
        }
    }
}

/// The Customise page for the Trends/Sleep cards hosted in Today (#today-hosted-cards). Reuses the shared
/// Shown/Hidden editor exactly like "Your cards"; the Shown list is the `HostedCardPrefs` selection in
/// order, the Hidden list is every not-yet-hosted card. Subtitle names the originating tab.
private struct HostedCardsCustomizationPage: View {
    @Binding var draft: EditableLayoutDraft<HostedCard>
    let onReset: () -> Void

    var body: some View {
        EditableLayoutList(
            draft: $draft,
            shownTitle: String(localized: "Added to Today"),
            hiddenTitle: String(localized: "Available"),
            title: \.title,
            subtitle: { String(localized: "from \($0.origin)") },
            icon: \.customizationIcon,
            tint: \.customizationTint,
            configurationLabel: { _ in nil },
            onConfigure: { _ in },
            onReset: onReset,
            allowEmpty: true,   // hosting is opt-in: the last card can be un-hosted (Shown may be empty)
            group: { $0.origin }   // group the Available list by origin tab ("Sleep", "Trends")
        ) {
            EmptyView()
        }
    }
}

#if DEBUG
#Preview("Customize Today") {
    TodayCustomizationSheet(
        sectionOrderRaw: .constant(""),
        hiddenSectionsRaw: .constant(""),
        keyMetricsRaw: .constant(""),
        keyMetricsDetailed: .constant(false),
        keyMetricsWindowDays: .constant(14),
        dashboardCardsRaw: .constant(""),
        hostedCardsRaw: .constant("")
    )
    .preferredColorScheme(.dark)
}
#endif
