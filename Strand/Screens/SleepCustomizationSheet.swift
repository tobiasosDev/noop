import SwiftUI
import StrandDesign

// MARK: - Sleep card customization (#sleep-layout)

/// The Sleep tab's "Arrange" sheet — reorder / show-hide the analytical cards. A single-page twin of
/// `TodayCustomizationSheet` (Sleep has no nested editors), driven by the SAME generic `EditableLayoutList`
/// so the reorder/hide UX is byte-for-byte Today's. Persists via `SleepLayoutPrefs`; the render side
/// (`SleepView`) reads the same `@AppStorage` keys and re-lays-out on save.
struct SleepCustomizationSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let initialDraft: EditableLayoutDraft<SleepSection>

    @Binding private var sectionOrderRaw: String
    @Binding private var hiddenSectionsRaw: String

    @State private var draft: EditableLayoutDraft<SleepSection>

    private var isDirty: Bool { draft != initialDraft }

    init(sectionOrderRaw: Binding<String>, hiddenSectionsRaw: Binding<String>) {
        _sectionOrderRaw = sectionOrderRaw
        _hiddenSectionsRaw = hiddenSectionsRaw

        let fullOrder = SleepLayoutPrefs.decodeOrder(sectionOrderRaw.wrappedValue)
        let hiddenSet = Set(SleepLayoutPrefs.decodeHidden(hiddenSectionsRaw.wrappedValue))
        let d = EditableLayoutDraft(
            visible: fullOrder.filter { !hiddenSet.contains($0) },
            hidden: fullOrder.filter { hiddenSet.contains($0) }
        )
        initialDraft = d
        _draft = State(initialValue: d)
    }

    var body: some View {
        VStack(spacing: 0) {
            NoopSheetHeader("Customize Sleep", doneTitle: "Save", onCancel: { dismiss() }, onDone: save)
            EditableLayoutList(
                draft: $draft,
                shownTitle: String(localized: "Shown"),
                hiddenTitle: String(localized: "Hidden"),
                title: \.title,
                subtitle: \.customizationCaption,
                icon: \.customizationIcon,
                tint: \.customizationTint,
                configurationLabel: { _ in nil },
                onConfigure: { _ in },
                onReset: {
                    draft = EditableLayoutDraft(
                        visible: SleepSection.defaultOrder,
                        allItems: SleepSection.defaultOrder
                    )
                },
                intro: String(localized: "Drag to reorder. Hidden cards stay one tap away and keep their data."),
                countLabel: { $0 == 1 ? String(localized: "1 card") : String(localized: "\($0) cards") }
            ) {
                EmptyView()
            }
        }
        .background(NoopSheetBackground())
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

    private func save() {
        // Store the FULL order (shown ++ hidden, so a hidden card keeps a stable slot) + the hidden set,
        // matching SleepLayoutPrefs and the Android SleepArrangeSheet.
        sectionOrderRaw = SleepLayoutPrefs.encode(draft.visible + draft.hidden)
        hiddenSectionsRaw = SleepLayoutPrefs.encodeHidden(draft.hidden)
        dismiss()
    }
}

// MARK: - Per-card Arrange-sheet metadata (icon + caption + tint), mirroring TodaySection's

extension SleepSection {
    /// The Phosphor glyph shown beside the card's name in the Arrange sheet — the same one the card
    /// carries when it is pinned to Today.
    var customizationIcon: String {
        switch self {
        case .sleepMarks:      return "moon-stars"
        case .stages:          return "chart-bar"
        case .bodyClock:       return "clock"
        case .nightDetail:     return "squares-four"
        case .sleepDebt:       return "scales"
        case .stagesVsTypical: return "chart-bar-horizontal"
        case .asleepDuration:  return "timer"
        }
    }

    /// What the card shows, for the Arrange row's caption.
    var customizationCaption: String? {
        switch self {
        case .sleepMarks:      return String(localized: "Going to sleep · I'm awake")
        case .stages:          return String(localized: "Last night's stages and naps")
        case .bodyClock:       return String(localized: "Your 24 h body-clock dial")
        case .nightDetail:     return String(localized: "Metrics · vs typical")
        case .sleepDebt:       return String(localized: "Sleep debt, night by night")
        case .stagesVsTypical: return String(localized: "Last night against your typical")
        case .asleepDuration:  return String(localized: "Time asleep over recent nights")
        }
    }

    /// Tint for the card's Arrange-sheet icon. Sleep cards live in the Rest world, so they lean on the
    /// rest palette with the accent for the log/marks entry.
    var customizationTint: Color {
        switch self {
        case .sleepMarks:      return StrandPalette.accent
        case .stages:          return StrandPalette.restColor
        case .bodyClock:       return StrandPalette.restColor
        case .nightDetail:     return StrandPalette.restBright
        case .sleepDebt:       return StrandPalette.effortColor
        case .stagesVsTypical: return StrandPalette.restColor
        case .asleepDuration:  return StrandPalette.restBright
        }
    }
}
