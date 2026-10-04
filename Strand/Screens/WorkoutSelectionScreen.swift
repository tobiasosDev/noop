import SwiftUI
import StrandDesign

// MARK: - Workout selection browser
//
// The v2 activity picker for a live start (and the merge-name reuse): a sheet with a search field, the
// recent sports as chips, every sport as a three-column grid of tiles, and a docked primary action. A
// tap SELECTS a sport; the docked button starts (or merges) with it. Catalogue, recents, GPS flags,
// and `onStart` / `RecentSportsPrefs` are unchanged.

/// Public entry used by Live / Workouts. Keeps the prior `onStart` + optional title overrides so the
/// merge-name prompt can reuse the same browser.
struct StartWorkoutSheet: View {
    let onStart: (_ sport: String) -> Void
    private let heading: String
    private let explainer: String?
    private let actionVerb: String
    /// The live-start flow (no overrides): the dock names what recording will do (GPS on).
    private let isStartFlow: Bool

    init(title: String? = nil, subtitle: String? = nil, actionVerb: String? = nil,
         onStart: @escaping (_ sport: String) -> Void) {
        self.onStart = onStart
        self.heading = title ?? String(localized: "Start a workout")
        // The default explainer is what the dock and the tiles already say, so only a caller's own
        // subtitle (the merge prompt's instruction) is shown.
        self.explainer = subtitle
        self.actionVerb = actionVerb ?? String(localized: "Start")
        self.isStartFlow = actionVerb == nil
    }

    var body: some View {
        WorkoutSelectionScreen(heading: heading, explainer: explainer, actionVerb: actionVerb,
                               isStartFlow: isStartFlow, onStart: onStart)
    }
}

// MARK: - Screen

struct WorkoutSelectionScreen: View {
    let heading: String
    let explainer: String?
    let actionVerb: String
    let isStartFlow: Bool
    let onStart: (_ sport: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: String?
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    private var filtered: [WorkoutCatalog.Sport] { WorkoutCatalog.matching(query) }
    private var recentSports: [WorkoutCatalog.Sport] {
        RecentSportsPrefs.recent().compactMap { WorkoutCatalog.sport(named: $0) }
    }
    private var showRecent: Bool { trimmedQuery.isEmpty && !recentSports.isEmpty }
    private var selectedSport: WorkoutCatalog.Sport? { selected.flatMap { WorkoutCatalog.sport(named: $0) } }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            NoopSheetHeader(LocalizedStringKey(heading), doneTitle: nil, onCancel: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    WorkoutSearchField(query: $query, isFocused: $searchFocused,
                                       prompt: String(localized: "Search \(WorkoutCatalog.all.count) sports"))
                    if let explainer {
                        Text(explainer)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 16)
                    }
                    if showRecent {
                        sectionLabel("Recent")
                        recentChips
                    }
                    sectionLabel(trimmedQuery.isEmpty ? "All sports" : "Results") {
                        Text(String(localized: "\(filtered.count) sports"))
                    }
                    if filtered.isEmpty {
                        emptyResults
                    } else {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(filtered) { sport in
                                WorkoutSportTile(sport: sport, isSelected: sport.name == selected) {
                                    select(sport.name)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.bottom, 24)
            }
            #if os(iOS)
            // #697/#horizontal-swipe parity, see ScreenScaffold.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { dock }
        }
        .background(NoopSheetBackground())
        .onAppear {
            // Pre-select the most recent sport so a repeat session is one tap on the dock.
            if selected == nil { selected = recentSports.first?.name }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #endif
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 640)
        #endif
    }

    private func sectionLabel(_ title: LocalizedStringKey) -> some View {
        sectionLabel(title) { EmptyView() }
    }

    private func sectionLabel<Trailing: View>(_ title: LocalizedStringKey,
                                              @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline) {
            NoopOverline(title)
            Spacer(minLength: 8)
            trailing()
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    private var recentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(recentSports) { sport in
                    RecentWorkoutChip(sport: sport, isSelected: sport.name == selected) {
                        select(sport.name)
                    }
                }
            }
        }
    }

    private var emptyResults: some View {
        VStack(spacing: 10) {
            PhIcon("magnifying-glass", size: 28)
                .foregroundStyle(StrandPalette.textTertiary)
            Text("No workouts found")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Try a different activity name.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .accessibilityElement(children: .combine)
    }

    /// The docked summary of the selection and the primary action.
    private var dock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if let sport = selectedSport {
                    (Text(verbatim: SportName.display(sport.name)).foregroundColor(StrandPalette.textPrimary)
                     + Text(verbatim: summaryDetail(sport)).foregroundColor(StrandPalette.textSecondary))
                } else {
                    Text("Pick a sport").foregroundColor(StrandPalette.textTertiary)
                }
            }
            .font(StrandFont.light(13, relativeTo: .subheadline))
            .lineLimit(1)
            Button {
                if let selected { start(selected) }
            } label: {
                HStack(spacing: 8) {
                    PhIcon("play", weight: .fill, size: 18)
                    Text(verbatim: actionVerb)
                }
            }
            .buttonStyle(LTPillStyle(kind: .primary))
            .disabled(selected == nil)
        }
        .padding(.horizontal, NoopMetrics.screenHPadding)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background {
            NoopVisualStyle.surface
                .overlay(alignment: .top) { LTHairline() }
                .ignoresSafeArea(edges: .bottom)
        }
        .background(alignment: .top) {
            // The grid fades out under the dock instead of being cut by its edge.
            LinearGradient(colors: [NoopVisualStyle.surface.opacity(0), NoopVisualStyle.surface],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 56)
                .offset(y: -56)
                .allowsHitTesting(false)
        }
    }

    /// " · Outdoor · GPS on" — catalogue facts only; GPS is named only for a live start, where
    /// `startWorkout` records a route for every distance sport.
    private func summaryDetail(_ sport: WorkoutCatalog.Sport) -> String {
        var parts = WorkoutActivityMeta.items(for: sport).filter { $0.symbol == nil }.map(\.text)
        if isStartFlow && sport.isDistanceSport { parts.append(String(localized: "GPS on")) }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }

    private func select(_ name: String) {
        searchFocused = false
        withAnimation(StrandMotion.interactive) { selected = name }
        StrandHaptic.selection.play()
    }

    private func start(_ name: String) {
        searchFocused = false
        RecentSportsPrefs.recordSelection(name)
        onStart(name)
        dismiss()
    }
}

// MARK: - Search

/// The v2 search field (`.srch`): a 48 pt raised capsule with a magnifier and a plain text field.
struct WorkoutSearchField: View {
    @Binding var query: String
    var isFocused: FocusState<Bool>.Binding
    var prompt: String = String(localized: "Search workouts")

    var body: some View {
        HStack(spacing: 10) {
            PhIcon("magnifying-glass", size: 18)
                .foregroundStyle(StrandPalette.textPrimary)
                .opacity(0.6)
            TextField(prompt, text: $query)
                .textFieldStyle(.plain)
                .font(StrandFont.light(15, relativeTo: .body))
                .foregroundStyle(StrandPalette.textPrimary)
                .focused(isFocused)
                .submitLabel(.search)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
            if !query.isEmpty {
                Button { query = "" } label: {
                    PhIcon("x-circle", weight: .fill, size: 18)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
        .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Recent chip

/// A recent sport as a `.chip`: its glyph and name; the selected one is the ink chip.
struct RecentWorkoutChip: View {
    let sport: WorkoutCatalog.Sport
    var isSelected: Bool = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                WorkoutTypeIcon(workoutType: sport.name, size: 15, weight: .light,
                                color: isSelected ? StrandPalette.goldDeepText : StrandPalette.textSecondary)
                Text(verbatim: SportName.display(sport.name))
                    .font(StrandFont.book(12, relativeTo: .caption))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? StrandPalette.goldDeepText : StrandPalette.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule(style: .continuous).fill(isSelected ? StrandPalette.gold : NoopVisualStyle.inset))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(isSelected ? Color.clear : NoopVisualStyle.border, lineWidth: 1))
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(LTPressStyle())
        .accessibilityLabel(Text("\(SportName.display(sport.name)) workout"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Sport tile

/// One sport in the three-column grid (`.sp`): a 42 pt glyph disc over the name. Selected = a white
/// rim with a soft glow, the disc inverted to ink, and a check in the corner.
struct WorkoutSportTile: View {
    let sport: WorkoutCatalog.Sport
    let isSelected: Bool
    let onSelect: () -> Void

    private var meta: [WorkoutActivityMeta.Item] { WorkoutActivityMeta.items(for: sport) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        Button(action: onSelect) {
            VStack(spacing: 12) {
                WorkoutTypeIcon(workoutType: sport.name, size: 19, weight: .light,
                                color: isSelected ? StrandPalette.goldDeepText : StrandPalette.textPrimary)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(isSelected ? StrandPalette.gold : NoopVisualStyle.raised))
                    .overlay(Circle().strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                tileName
                    .font(StrandFont.book(13, relativeTo: .footnote))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity, minHeight: 104)
            .background(shape.fill(LinearGradient(colors: [NoopVisualStyle.inset, NoopVisualStyle.surface],
                                                  startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(isSelected ? Color.white.opacity(0.75) : NoopVisualStyle.border,
                                        lineWidth: 1))
            .overlay(shape.inset(by: 1).strokeBorder(Color.white.opacity(isSelected ? 0.4 : 0), lineWidth: 1))
            .shadow(color: .white.opacity(isSelected ? 0.06 : 0), radius: 12)
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    PhIcon("check-circle", weight: .fill, size: 18)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(10)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(LTPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabelText))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Up to two lines, but a single word too long for the tile ("Freiwasserschwimmen") shrinks onto one
    /// line instead of being broken mid-word.
    @ViewBuilder private var tileName: some View {
        let name = SportName.display(sport.name)
        let longestWord = name.split(whereSeparator: { $0 == " " || $0 == "-" }).map(\.count).max() ?? 0
        if longestWord >= 15 {
            Text(verbatim: name).lineLimit(1).minimumScaleFactor(0.6)
        } else {
            Text(verbatim: name).lineLimit(2).minimumScaleFactor(0.8)
        }
    }

    private var accessibilityLabelText: String {
        let labels = meta.map(\.text)
        let name = SportName.display(sport.name)
        if labels.isEmpty { return String(localized: "\(name) workout") }
        return String(localized: "\(name) workout") + ", " + labels.joined(separator: ", ")
    }
}

// MARK: - Metadata

enum WorkoutActivityMeta {
    struct Item: Equatable {
        var symbol: String?
        var text: String
    }

    /// Labels derived only from catalogue flags / known types — no invented capabilities.
    static func items(for sport: WorkoutCatalog.Sport) -> [Item] {
        var items: [Item] = []
        if sport.isDistanceSport {
            items.append(Item(symbol: "location.fill", text: "GPS"))
        }
        if let type = KnownWorkoutType.exact(matching: sport.name) {
            switch type {
            case .treadmillRun, .treadmillWalk, .indoorCycle, .poolSwim, .rowMachine, .elliptical:
                items.append(Item(symbol: nil, text: String(localized: "Indoor")))
            case .running, .walking, .hiking, .cycling, .openWaterSwim, .rowing, .skiing, .snowboarding:
                items.append(Item(symbol: nil, text: String(localized: "Outdoor")))
            case .strength, .bodybuilding, .weightlifting:
                items.append(Item(symbol: nil, text: String(localized: "Strength")))
            case .yoga, .pilates, .stretching:
                items.append(Item(symbol: nil, text: String(localized: "Mindfulness")))
            case .hiit:
                items.append(Item(symbol: nil, text: String(localized: "Cardio")))
            default:
                break
            }
        }
        return items
    }
}

// MARK: - Presentation helper

extension View {
    /// The workout browser as a v2 sheet on iOS (it carries its own detents and background) and a plain
    /// sheet on macOS.
    @ViewBuilder
    func workoutSelectionCover(isPresented: Binding<Bool>,
                               @ViewBuilder content: @escaping () -> StartWorkoutSheet) -> some View {
        self.sheet(isPresented: isPresented, content: content)
    }

    @ViewBuilder
    func workoutSelectionCover<Item: Identifiable>(item: Binding<Item?>,
                                                   @ViewBuilder content: @escaping (Item) -> StartWorkoutSheet) -> some View {
        self.sheet(item: item, content: content)
    }
}

#if DEBUG
#Preview("Start a workout") {
    StartWorkoutSheet { _ in }
        .preferredColorScheme(.dark)
}
#endif
