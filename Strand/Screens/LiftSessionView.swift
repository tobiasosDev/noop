import SwiftUI
import StrandDesign
import WhoopStore

// The workout sheet: the running stage on the effort glow, the exercise being worked with every set, and
// the rest of the session one tap away.
//
// WHY A SHEET AND NOT A WIZARD. The first version showed one set at a time and walked the plan in
// order. In a real gym that fails twice over: you cannot see what is coming, and you cannot move on
// when a machine is occupied. So every exercise stays listed, any of them opens to its sets, any pending
// set can be started, and finished sets stay with what you lifted.
//
// ONE PLACE FOR THE STAGE. The hero at the top carries what is running — the warm-up, the set being
// worked, or the rest and how much of it is left — with the one action that moves it on. The set rows
// below carry their own state: the set being worked is the raised row, a done set has an ink tick, and
// numbers nobody typed stay grey.
//
// The session itself lives in `LiftSessionController`, ABOVE this view. Swiping this sheet away (or
// Hide) minimises it to the bottom bar; the clock, the strap gesture and the buzzes all keep running,
// because a workout outlives the screen you happen to be looking at.

struct LiftSessionView: View {
    // Only what the sheet draws from. The live heart rate and the running clocks are their own small views
    // (`LiftLiveReadouts.swift`): watched from here, every beat, log line and tick redrew the whole sheet.
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var session: LiftSessionController
    @Environment(\.dismiss) private var dismiss

    #if DEBUG
    /// Screenshot harness only: open with the finish sheet up.
    var demoFinishing = false
    #endif

    /// Called once the session has been written, so the hub can reload.
    let onFinished: () async -> Void

    @State private var showingFinish = false
    @State private var confirmingDiscard = false
    @State private var sessionRpeText = ""
    @State private var saving = false
    /// The two questions finishing can ask. Nil until answered: saving waits for an answer rather than
    /// deciding for the user.
    @State private var unfinishedChoice: UnfinishedChoice?
    @State private var programChoice: ProgramChoice?
    /// Program lines whose set count this session changed, read when the finish sheet opens.
    @State private var setCountChanges: [LiftSessionController.SetCountChange] = []
    @State private var addingExercise = false
    /// The card to bring into view once an exercise has been added — the new one, at the end.
    @State private var scrollTarget: Int?
    /// Exercises opened from the list below the running one, by plan index.
    @State private var expanded: Set<Int> = []
    /// The exercises not started yet are folded into one row until it is opened.
    @State private var showsUpcoming = false
    /// What was lifted last time for each exercise, by set number — the same values handed to the
    /// controller's grey-number chain, kept here for the "Last time" line and the top-set comparison.
    @State private var lastTime: [String: [Int: LiftSetCarry]] = [:]

    private enum UnfinishedChoice: Hashable { case complete, discard }
    private enum ProgramChoice: Hashable { case update, keep }

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    @FocusState private var focused: FocusTarget?
    private enum FocusTarget: Hashable {
        case weight(LiftSlot), reps(LiftSlot), rpe(LiftSlot), sessionRpe
    }

    /// What the user has TYPED into a field, held until they leave it.
    ///
    /// Without this a numeric field cannot accept a decimal at all. Each binding read its text back
    /// out of the engine, so every keystroke round-tripped through `LiftFormat` and was replaced by
    /// the canonical rendering of the parsed value. Typing "45." parsed to 45, re-rendered as "45",
    /// and the point vanished as it was typed — then the next keystroke made "455". A user entering
    /// 45.5 kg silently got 455 kg, which is the shape of bug this feature has to stop having.
    ///
    /// So while a field is focused it shows exactly what was typed; the parsed value still goes to
    /// the engine and to disk on every keystroke, so nothing about durability changes. The draft is
    /// dropped when focus leaves and the row goes back to the canonical formatting.
    @State private var draft: [FocusTarget: String] = [:]

    private var engine: LiftSessionEngine? { session.engine }

    /// Scroll anchor of the stage hero.
    private static let heroID = "lift-session-hero"

    var body: some View {
        Group {
            if let engine {
                VStack(spacing: 0) {
                    sessionHeader(engine)
                    sheet(engine)
                    // The dock never scrolls away: the session's progress and Finish stay where the thumb is.
                    dock(engine)
                }
            } else {
                VStack {
                    NoopInsightRow("No session running", icon: "barbell").ltCard()
                    Spacer()
                }
                .padding(20)
                .padding(.top, 24)
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #else
        .frame(width: 560, height: 800)
        .background(NoopSheetBackground())
        #endif
        .keyboardDoneToolbar($focused)
        .dismissesKeyboardOnTap($focused)
        // Re-read whenever the session's exercises change, so an exercise added mid-session that was
        // done before shows last time's numbers in grey, like every other line.
        .task(id: engine?.plan.map(\.exercise)) { await loadLastTime() }
        // Release a field's draft once the user leaves it, so the row returns to the canonical
        // formatting ("45.50" typed becomes "45.5"). The single-argument form on purpose: the
        // two-argument `onChange` is macOS 14+ and this file also builds for macOS 13.
        .onChange(of: focused) { now in
            draft = draft.filter { $0.key == now }
        }
        .sheet(isPresented: $showingFinish) { finishSheet }
        #if DEBUG
        .task {
            guard demoFinishing else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            showingFinish = true
        }
        #endif
    }

    // MARK: - Header

    /// Hide · "Push A · 38:12" · heart rate. Hide minimises to the bar, exactly like swiping the sheet down.
    private func sessionHeader(_ engine: LiftSessionEngine) -> some View {
        ZStack {
            HStack(spacing: 0) {
                Text(verbatim: session.programName ?? String(localized: "Session"))
                    .lineLimit(1)
                Text(verbatim: " · ")
                LiftRunningClock { $0 - engine.startTs }
                    .fixedSize()
            }
            .font(StrandFont.book(17, relativeTo: .headline))
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, 92)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            HStack {
                Button { dismiss() } label: {
                    HStack(spacing: 6) {
                        PhIcon("caret-down", size: 18).opacity(0.7)
                        Text("Hide")
                    }
                    .font(StrandFont.light(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Minimise the session"))
                Spacer(minLength: 8)
                // Display only, beside the clock that never scrolls away: a glance mid-set is the whole use
                // (`LiftHeartRate`). Always shown, dash included.
                LiftHeartRatePill()
            }
        }
        .padding(.horizontal, NoopMetrics.screenHPadding)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }

    // MARK: - The scrollable sheet

    private func sheet(_ engine: LiftSessionEngine) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    stageHero(engine).id(Self.heroID)
                    ForEach(cardIndices(engine), id: \.self) { index in
                        exerciseCard(engine, index: index, item: engine.plan[index],
                                     collapsible: !focusIndices(engine).contains(index))
                    }
                    otherExercises(engine)
                    addExerciseRow(engine)
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.bottom, 24)
            }
            #if os(iOS) && DEBUG
            .modifier(DemoScrollAnchor())
            #endif
            .onChange(of: engine.currentSlot) { slot in
                // A new stage is read off the hero: bring it back into view when the session moves on.
                guard slot != nil else { return }
                withAnimation { proxy.scrollTo(Self.heroID, anchor: .top) }
            }
            .onChange(of: scrollTarget) { target in
                guard let target else { return }
                expanded.insert(target)
                withAnimation { proxy.scrollTo(target, anchor: .top) }
                scrollTarget = nil
            }
            .sheet(isPresented: $addingExercise) {
                LiftSessionExerciseSheet { name, primary, secondaries in
                    guard session.addExercise(name, primaryMuscle: primary,
                                              secondaryMuscles: secondaries) else { return }
                    scrollTarget = (session.engine?.plan.count ?? 1) - 1
                }
            }
        }
    }

    /// The exercises open as full cards: the one being worked (and, during a rest, the one the next set
    /// belongs to), then any the lifter opened, in plan order.
    private func focusIndices(_ engine: LiftSessionEngine) -> [Int] {
        var out: [Int] = []
        if let current = engine.currentSlot?.exerciseIndex { out.append(current) }
        if case .working = engine.stage {} else if let next = engine.upcomingSlot?.exerciseIndex, !out.contains(next) {
            out.append(next)
        }
        if out.isEmpty, !engine.plan.isEmpty { out.append(0) }
        return out
    }

    private func cardIndices(_ engine: LiftSessionEngine) -> [Int] {
        let focus = focusIndices(engine)
        return focus + engine.plan.indices.filter { expanded.contains($0) && !focus.contains($0) }
    }

    /// Add an exercise the program does not have — at the END of the sheet, after everything planned,
    /// because that is where it goes: the program's lines keep their order, and the new one is tapped to
    /// start whenever the lifter gets to it (Utku, 21 Sep 2026). Finishing asks whether the program keeps
    /// it; until then it changes this session only, like adding or removing a set.
    private func addExerciseRow(_ engine: LiftSessionEngine) -> some View {
        LTActionButton("Add exercise", icon: "plus", height: 44, fontSize: 14) {
            addingExercise = true
        }
        .disabled(engine.plan.count >= LiftSessionEngine.maxExercises)
    }

    // MARK: - The stage hero

    /// What is running now, on the effort glow: the warm-up clock, the set being worked, or the rest
    /// counting down — with what comes next and the action that moves the session on.
    private func stageHero(_ engine: LiftSessionEngine) -> some View {
        let now = LiftSessionController.unixNow
        return NoopHeroCard(glow: .strain, padding: 20) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    stageBadge(engine)
                    Spacer(minLength: 8)
                    if let pill = stagePill(engine) {
                        NoopPill(verbatim: pill, compact: true)
                    }
                }
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    stageClock(engine)
                        .font(StrandFont.dot(84))
                        .tracking(StrandFont.dotTracking(84))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let caption = clockCaption(engine) {
                        Text(verbatim: caption)
                            .font(StrandFont.light(14, relativeTo: .subheadline))
                            .foregroundStyle(NoopMetric.heroLabel)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.bottom, 8)
                    }
                }
                .padding(.top, 22)
                .accessibilityElement(children: .combine)
                if case .resting(_, let endsAt) = engine.stage {
                    LiftRestTrack(endsAt: endsAt, total: max(1, endsAt - engine.stageStartedAt))
                        .padding(.top, 20)
                }
                // The set coming up, through the same resolution the minimised bar and the Lock Screen read
                // (`LiftSessionController.nextLine`), so the three never word it differently.
                HStack(spacing: 8) {
                    Text(verbatim: nextLine(engine))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if case .resting = engine.stage {
                        Spacer(minLength: 0)
                        LiftRestBuzzNote().foregroundStyle(NoopMetric.heroLabel)
                    }
                }
                .font(StrandFont.light(12, relativeTo: .caption))
                .padding(.top, 10)
                HStack(spacing: 8) {
                    Button { session.undo() } label: {
                        HStack(spacing: 6) {
                            PhIcon("arrow-counter-clockwise", size: 14)
                            Text("Undo")
                        }
                    }
                    .buttonStyle(LiftGlassButtonStyle())
                    .disabled(!engine.canUndo)
                    Button { session.advance() } label: {
                        Text(actionLabel(engine))
                    }
                    .buttonStyle(LiftGlassButtonStyle(primary: actionIsPrimary(engine, now: now)))
                    .disabled(engine.isFinished)
                }
                .padding(.top, 18)
            }
        }
    }

    @ViewBuilder
    private func stageBadge(_ engine: LiftSessionEngine) -> some View {
        switch engine.stage {
        // "Rest period", never "Rest": the catalog's "Rest" key is NOOP's SLEEP metric, so the bare word
        // renders as "Erholung" (recovery) in German.
        case .resting: NoopIconBadge("Rest period", icon: "timer")
        case .working: NoopIconBadge("This set", icon: "barbell")
        case .warmup, .finished: NoopIconBadge("Warm-up", icon: "fire")
        }
    }

    /// "After set 2" while resting, "Set 3 of 4" while working.
    private func stagePill(_ engine: LiftSessionEngine) -> String? {
        switch engine.stage {
        case .resting(let slot, _):
            return String(localized: "After set \(slot.setIndex)")
        case .working(let slot):
            let of = engine.planItem(for: slot)?.targetSets ?? slot.setIndex
            return String(localized: "Set \(slot.setIndex) of \(of)")
        case .warmup, .finished:
            return nil
        }
    }

    /// Rest counts DOWN (that is the number you act on); the set and the warm-up count up.
    private func stageClock(_ engine: LiftSessionEngine) -> LiftRunningClock {
        switch engine.stage {
        case .resting: return LiftRunningClock { engine.restRemaining(now: $0) ?? 0 }
        default: return LiftRunningClock { $0 - engine.stageStartedAt }
        }
    }

    /// "of 2:00" beside a rest; the set's numbers beside a set being worked.
    private func clockCaption(_ engine: LiftSessionEngine) -> String? {
        switch engine.stage {
        case .resting(_, let endsAt):
            return String(localized: "of \(ActiveWorkoutClock.clock(max(0, endsAt - engine.stageStartedAt)))")
        case .working(let slot):
            return session.setNumbers(for: slot, system: unitSystem)
        case .warmup, .finished:
            return nil
        }
    }

    /// The next set, and its numbers when it has any.
    private func nextLine(_ engine: LiftSessionEngine) -> String {
        let line = LiftSessionController.nextLine(engine)
        guard let upcoming = engine.upcomingSlot,
              let numbers = session.setNumbers(for: upcoming, system: unitSystem) else { return line }
        return "\(line) · \(numbers)"
    }

    /// The ink pill for the action the stage is waiting for; a rest still running offers it quietly, as
    /// skipping the rest is the exception.
    private func actionIsPrimary(_ engine: LiftSessionEngine, now: Int) -> Bool {
        if case .resting(_, let endsAt) = engine.stage { return endsAt <= now }
        return !engine.isFinished
    }

    // MARK: - One exercise, with all its sets

    private func exerciseCard(_ engine: LiftSessionEngine, index: Int, item: LiftPlanItem,
                              collapsible: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                NoopIconTile("barbell", size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.exercise)
                        .font(StrandFont.book(16, relativeTo: .headline))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(2)
                    Text(verbatim: lastTimeLine(item) ?? LiftMuscleSummary.line(primary: item.primaryMuscle,
                                                                                secondaries: item.secondaryMuscles))
                        .font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                exerciseMenu(engine, index: index, item: item, collapsible: collapsible)
            }
            if let note = item.note, !note.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    PhIcon("note", size: 16).foregroundStyle(StrandPalette.textSecondary)
                    Text(note)
                        .font(StrandFont.light(13, relativeTo: .footnote))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        // Belt and braces with the entry cap: the sets are what this screen is for,
                        // and a note must never be able to push them off it.
                        .lineLimit(4)
                }
                .padding(.top, 14)
            }

            VStack(spacing: 0) {
                columnHeadings
                ForEach(engine.slots(forExercise: index), id: \.self) { slot in
                    setRow(engine, slot: slot)
                }
            }
            .padding(.top, 16)

            setCountRow(engine, index: index, item: item)
                .padding(.top, 14)
        }
        .ltCard()
        .id(index)
    }

    /// The card's ⋯: set count changes, and folding an opened card back into the list.
    private func exerciseMenu(_ engine: LiftSessionEngine, index: Int, item: LiftPlanItem,
                              collapsible: Bool) -> some View {
        Menu {
            Button {
                session.addSet(toExercise: index)
            } label: {
                Label("Add set", systemImage: "plus")
            }
            .disabled(item.targetSets >= LiftSessionEngine.maxSetsPerExercise)
            Button {
                session.removeSet(fromExercise: index)
            } label: {
                Label("Remove the last set", systemImage: "minus")
            }
            .disabled(!engine.canRemoveSet(fromExercise: index))
            if collapsible {
                Button {
                    expanded.remove(index)
                } label: {
                    Label("Fold away", systemImage: "chevron.up")
                }
            }
        } label: {
            PhIcon("dots-three", size: 18)
                .foregroundStyle(StrandPalette.textPrimary)
                .opacity(0.5)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(String(localized: "More for \(item.exercise)"))
    }

    /// "Last time 80 kg · 5, 5, 5, 4": the heaviest weight of the last session's working sets and the
    /// reps of each, from the same values the grey numbers read.
    private func lastTimeLine(_ item: LiftPlanItem) -> String? {
        guard let sets = lastTime[item.exercise], !sets.isEmpty else { return nil }
        let ordered = sets.keys.sorted().compactMap { sets[$0] }
        let reps = ordered.compactMap(\.reps).map(String.init).joined(separator: ", ")
        let top = ordered.compactMap(\.weightKg).max()
        let parts = [top.map { LiftFormat.weight($0, system: unitSystem) }, reps.isEmpty ? nil : reps]
            .compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return String(localized: "Last time \(parts.joined(separator: " · "))")
    }

    /// Add one more set — at the END of the exercise, because that is where the question comes up: you
    /// have done what was written down and have one more in you. Until this existed the sheet drew exactly
    /// `1...targetSets` and the extra set was performed and then lost. Dropping the last planned set is in
    /// the card's ⋯.
    ///
    /// **This changes this session only.** Whether the program keeps the new count is asked when the
    /// session is finished: a program is a plan for next time, and one extra set on a good day is not
    /// always a new plan.
    private func setCountRow(_ engine: LiftSessionEngine, index: Int, item: LiftPlanItem) -> some View {
        HStack(spacing: 10) {
            Button {
                session.addSet(toExercise: index)
            } label: {
                NoopChip("Add set", icon: "plus")
            }
            .buttonStyle(LTPressStyle())
            .disabled(item.targetSets >= LiftSessionEngine.maxSetsPerExercise)
            .opacity(item.targetSets >= LiftSessionEngine.maxSetsPerExercise ? 0.38 : 1)
            .accessibilityLabel(String(localized: "Add a set to \(item.exercise)"))
            Spacer(minLength: 8)
            if let compare = topSetComparison(engine, index: index, item: item) {
                Text(verbatim: compare)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }

    /// "Top set +2.5 kg vs last time" — the heaviest working set done today against last session's.
    private func topSetComparison(_ engine: LiftSessionEngine, index: Int, item: LiftPlanItem) -> String? {
        let today = engine.sets
            .filter { $0.exerciseIndex == index && !$0.isWarmup }
            .compactMap(\.weightKg).max()
        guard let today, let before = lastTime[item.exercise]?.values.compactMap(\.weightKg).max() else {
            return nil
        }
        let delta = LiftFormat.display(fromKilograms: today, system: unitSystem)
            - LiftFormat.display(fromKilograms: before, system: unitSystem)
        if abs(delta) < 0.05 { return String(localized: "Top set matches last time") }
        let signed = (delta > 0 ? "+" : "−") + LiftFormat.trim(abs(delta)) + " " + LiftFormat.weightUnit(unitSystem)
        return String(localized: "Top set \(signed) vs last time")
    }

    /// Width of the set-number column, shared by the heading and every row so the number sits
    /// directly under its label.
    ///
    /// 40, and the headings are `lineLimit(1)` with a scale floor: a real session once photographed a
    /// narrower column wrapping its heading mid-word ("SE / T"). This row is four short labels across a
    /// phone width in ten languages, and a wrapped heading breaks the column alignment for every row
    /// beneath it.
    static let setColumnWidth: CGFloat = 40

    /// Width of the trailing tick column. Mirrored by a clear spacer in the heading row so the four
    /// labels sit over the four things they name.
    private static let tickColumnWidth: CGFloat = 40

    private var columnHeadings: some View {
        HStack(spacing: 0) {
            Text("Set").frame(width: Self.setColumnWidth)
            Text(weightHeading).frame(maxWidth: .infinity)
            Text("Reps").frame(maxWidth: .infinity)
            Text("RPE").frame(maxWidth: .infinity)
            Color.clear.frame(width: Self.tickColumnWidth, height: 1)
        }
        .font(StrandFont.book(10.5, relativeTo: .caption2))
        .tracking(0.84)
        .textCase(.uppercase)
        .foregroundStyle(StrandPalette.textTertiary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 6)
        .frame(height: 26)
    }

    private var weightHeading: LocalizedStringKey {
        unitSystem == .imperial ? "Lb" : "Kg"
    }

    // MARK: - One set row

    private func setRow(_ engine: LiftSessionEngine, slot: LiftSlot) -> some View {
        let recorded = engine.recordedSet(for: slot)
        // The set being worked — or, before it starts, the one coming up — is the raised row.
        let isWorking: Bool = {
            switch engine.stage {
            case .working(let s): return s == slot
            case .resting, .warmup: return engine.upcomingSlot == slot
            case .finished: return false
            }
        }()
        let ink = isWorking ? StrandPalette.textPrimary
            : (recorded != nil ? StrandPalette.textSecondary : StrandPalette.textTertiary)

        return HStack(spacing: 0) {
            // The set number IS the warm-up toggle. Warm-ups are excluded from volume and from the
            // per-muscle counts, so being unable to mark one silently inflates the single figure the
            // whole feature rests on — it has to be reachable in one tap, without leaving the row.
            Button {
                toggleWarmup(slot)
            } label: {
                Text(isWarmup(slot) ? String(localized: "W") : "\(slot.setIndex)")
                    .font(isWarmup(slot) ? StrandFont.medium(13, relativeTo: .footnote)
                                         : StrandFont.value(13, relativeTo: .footnote))
                    .foregroundStyle(isWorking || isWarmup(slot) ? StrandPalette.textPrimary
                                                                 : StrandPalette.textTertiary)
                    .frame(width: Self.setColumnWidth, height: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isWarmup(slot)
                                ? String(localized: "Warm-up set — tap to make it a working set")
                                : String(localized: "Set \(slot.setIndex) — tap to mark it a warm-up"))

            numberField(field: .weight(slot), text: weightBinding(slot), ghost: ghostWeight(slot),
                        ink: ink, raised: isWorking)
            numberField(field: .reps(slot), text: repsBinding(slot), ghost: ghostReps(slot),
                        ink: ink, raised: isWorking)
            numberField(field: .rpe(slot), text: rpeBinding(slot), ghost: ghostRpe(engine, slot: slot),
                        ink: ink, raised: isWorking)

            // The tick both REPORTS and ACTS: an ink disc when the set is done, and tappable to start
            // this set when it is not — which is how you jump to a different exercise. On a done set
            // it re-opens the set for a redo.
            Button {
                session.start(slot)
            } label: {
                LiftCheckCircle(done: recorded != nil)
                    .opacity(recorded == nil && !isWorking ? 0.6 : 1)
                    .frame(width: Self.tickColumnWidth, height: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorded == nil
                                ? String(localized: "Start this set")
                                : String(localized: "Redo this set"))
        }
        .padding(.horizontal, 6)
        .frame(height: 46)
        .background {
            if isWorking {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(NoopVisualStyle.inset)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
            }
        }
    }

    /// Warm-up state lives in the controller, so a mark survives the sheet being minimised and
    /// applies however the set was closed out — button, strap, or the minimised bar.
    private func isWarmup(_ slot: LiftSlot) -> Bool { session.isWarmup(slot) }

    private func toggleWarmup(_ slot: LiftSlot) {
        session.setWarmup(slot, !session.isWarmup(slot))
    }

    /// One number of a set: typed numbers in the row's ink, grey numbers as the prompt. The set being
    /// worked raises its fields onto a tile, so the row you are on reads from arm's length.
    private func numberField(field: FocusTarget, text: Binding<String>, ghost: String,
                             ink: Color, raised: Bool) -> some View {
        TextField("", text: text, prompt: Text(verbatim: ghost).foregroundColor(StrandPalette.textTertiary))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(StrandFont.value(15, relativeTo: .body))
            .foregroundStyle(ink)
            .numericKeyboard()
            .focused($focused, equals: field)
            .padding(.vertical, 5)
            .frame(width: raised ? 50 : nil)
            .background {
                if raised {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(NoopVisualStyle.raised)
                }
            }
            .frame(maxWidth: .infinity)
    }

    // MARK: - The rest of the session

    /// Every exercise that is not open as a card, as one list row each: done ones with their tick, ones
    /// part-way through with their count, and the ones not started folded into a single row until it is
    /// opened. Tapping a row opens the exercise's card.
    @ViewBuilder
    private func otherExercises(_ engine: LiftSessionEngine) -> some View {
        let open = Set(cardIndices(engine))
        let rest = engine.plan.indices.filter { !open.contains($0) }
        let started = rest.filter { i in engine.slots(forExercise: i).contains { engine.isCompleted($0) } }
        let untouched = rest.filter { !started.contains($0) }
        let folds = untouched.count >= 3 && !showsUpcoming
        if !rest.isEmpty {
            NoopList {
                ForEach(started, id: \.self) { index in exerciseRow(engine, index: index) }
                if folds {
                    Button {
                        withAnimation(StrandMotion.interactive) { showsUpcoming = true }
                    } label: {
                        NoopRow(title: Text(String(localized: "\(untouched.count) more exercises")),
                                caption: Text(verbatim: untouched.map { engine.plan[$0].exercise }
                                    .joined(separator: ", ")),
                                icon: "list-checks") {
                            PhIcon("caret-down", size: 18).opacity(0.5)
                        }
                    }
                    .buttonStyle(LTPressStyle())
                } else {
                    ForEach(untouched, id: \.self) { index in exerciseRow(engine, index: index) }
                }
            }
        }
    }

    private func exerciseRow(_ engine: LiftSessionEngine, index: Int) -> some View {
        let item = engine.plan[index]
        let slots = engine.slots(forExercise: index)
        let done = slots.filter { engine.isCompleted($0) }
        return Button {
            withAnimation(StrandMotion.interactive) { _ = expanded.insert(index) }
        } label: {
            NoopRow(title: Text(item.exercise), caption: Text(verbatim: rowCaption(slots: slots, done: done)),
                    icon: "barbell") {
                HStack(spacing: 10) {
                    if !slots.isEmpty, done.count == slots.count { LiftCheckCircle(done: true, size: 22) }
                    PhIcon("caret-down", size: 18).opacity(0.5)
                }
            }
        }
        .buttonStyle(LTPressStyle())
    }

    /// "Done · 3 × 8 · 42.5 kg", "2 of 4 sets done", or the plan "4 × 5 · 80 kg".
    private func rowCaption(slots: [LiftSlot], done: [LiftSlot]) -> String {
        if !done.isEmpty, done.count < slots.count {
            return String(localized: "\(done.count) of \(slots.count) sets done")
        }
        let values = slots.map { session.values(of: $0) }
        let reps = Set(values.compactMap(\.reps))
        let shape = reps.count == 1 ? "\(slots.count) × \(reps.first!)"
                                    : String(localized: "\(slots.count) sets")
        let top = values.compactMap(\.weightKg).max().map { LiftFormat.weight($0, system: unitSystem) }
        let line = [shape, top].compactMap { $0 }.joined(separator: " · ")
        return done.isEmpty ? line : String(localized: "Done · \(line)")
    }

    // MARK: - The dock

    /// Sets done of planned, the volume so far, and Finish.
    private func dock(_ engine: LiftSessionEngine) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                Text(String(localized: "\(engine.completedWorkingSets) of \(engine.plannedWorkingSets) sets"))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let volume = volumeSoFar(engine) {
                    Text(verbatim: " · \(volume)")
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .font(StrandFont.light(13, relativeTo: .footnote))
            .lineLimit(1)
            LTActionButton("Finish", icon: "flag-checkered", kind: .primary) {
                unfinishedChoice = nil
                programChoice = nil
                setCountChanges = []
                showingFinish = true
            }
        }
        .padding(.horizontal, NoopMetrics.screenHPadding)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background {
            NoopVisualStyle.surface
                .overlay(alignment: .top) { LTHairline() }
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            // The list fades into the dock rather than being cut by it.
            LinearGradient(colors: [NoopVisualStyle.surface.opacity(0), NoopVisualStyle.surface],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 40)
                .offset(y: -40)
                .allowsHitTesting(false)
        }
    }

    /// "1,820 kg": weight × reps over the working sets done so far with both numbers typed — the same
    /// arithmetic as the saved session's volume, never a physiological claim.
    private func volumeSoFar(_ engine: LiftSessionEngine) -> String? {
        let kg = engine.sets.reduce(0.0) { sum, set in
            guard !set.isWarmup, let w = set.weightKg, let r = set.reps else { return sum }
            return sum + w * Double(r)
        }
        guard kg > 0 else { return nil }
        let shown = LiftFormat.display(fromKilograms: kg, system: unitSystem)
        return "\(shown.formatted(.number.precision(.fractionLength(0)))) \(LiftFormat.weightUnit(unitSystem))"
    }

    // MARK: - Ghost values
    //
    // The grey numbers come from ONE chain, `LiftSessionController.carry(for:)`: this exercise earlier
    // in the session (set 2 almost always mirrors set 1), then the same set last session, then the
    // program's target. The minimised bar and the Lock Screen read the same chain.
    //
    // A set keeps its grey numbers after it is done, until something is typed over them — grey means
    // "not entered". What they are worth is decided when the session is finished: every set without
    // typed numbers is completed with them, or discarded, in one choice.

    private func ghostWeight(_ slot: LiftSlot) -> String {
        session.carry(for: slot).weightKg.map { display($0) } ?? "—"
    }

    private func ghostReps(_ slot: LiftSlot) -> String {
        session.carry(for: slot).reps.map(String.init) ?? "—"
    }

    /// Grey RPE is the line's max RPE when the program sets one — and, like every other grey number, it is
    /// what the set saves if nothing is typed over it (RULES 34). A previous set's own rating is shown as a
    /// reminder when the plan sets no maximum, and that one is never saved: it belongs to another set.
    private func ghostRpe(_ engine: LiftSessionEngine, slot: LiftSlot) -> String {
        if let planned = engine.planItem(for: slot)?.targetRpe { return LiftFormat.trim(planned) }
        return engine.previousSetInSession(for: slot)?.rpe.map { LiftFormat.trim($0) } ?? "—"
    }

    private func display(_ kg: Double) -> String {
        LiftFormat.trim(LiftFormat.display(fromKilograms: kg, system: unitSystem))
    }

    // MARK: - Field bindings
    //
    // Each field reads and writes THROUGH the controller, so a keystroke lands in the engine and on
    // disk immediately.
    //
    // TYPING INTO ANY SET, AT ANY TIME. A set that has already been performed is edited in place; one
    // that has not is held in `LiftSessionController.pendingValues` and applied the moment it is
    // recorded. The two are indistinguishable from the row, which is the requirement: being mid-set
    // on one machine is no reason to refuse a correction to another row you are looking at.
    //
    // This used to be a claim rather than a behaviour — the comment here said the value was "held
    // until the set is recorded" while `write` silently dropped it — and a real session found it:
    // "when I type something during an active set to other sets it refreshes to the empty".

    /// A text binding that does not fight the user while they type: reads the draft if there is one,
    /// otherwise the canonical rendering of what is stored.
    ///
    /// A typed comma becomes a point on the way in. iOS's `.decimalPad` labels its separator key
    /// from the DEVICE's region — a German or French phone offers "," and the app cannot relabel it
    /// — so the two would otherwise disagree with the "." this screen displays everywhere else.
    /// Normalising here means the field always reads back in the notation it shows, whichever key
    /// the keyboard happened to offer.
    private func fieldBinding(_ field: FocusTarget,
                              formatted: @escaping () -> String,
                              store: @escaping (String) -> Void) -> Binding<String> {
        Binding(
            get: { draft[field] ?? formatted() },
            set: { typed in
                let text = typed.replacingOccurrences(of: ",", with: ".")
                draft[field] = text
                store(text)
            })
    }

    private func weightBinding(_ slot: LiftSlot) -> Binding<String> {
        fieldBinding(.weight(slot),
                     formatted: { session.enteredValues(for: slot).weightKg.map { display($0) } ?? "" },
                     store: { text in
                         let kg = LiftFormat.number(text).map {
                             LiftFormat.kilograms(fromDisplay: $0, system: unitSystem)
                         }
                         write(slot) { $0.weightKg = kg }
                     })
    }

    private func repsBinding(_ slot: LiftSlot) -> Binding<String> {
        fieldBinding(.reps(slot),
                     formatted: { session.enteredValues(for: slot).reps.map(String.init) ?? "" },
                     store: { text in
                         write(slot) { $0.reps = Int(text.trimmingCharacters(in: .whitespaces)) }
                     })
    }

    private func rpeBinding(_ slot: LiftSlot) -> Binding<String> {
        fieldBinding(.rpe(slot),
                     formatted: { session.enteredValues(for: slot).rpe.map { LiftFormat.trim($0) } ?? "" },
                     store: { text in write(slot) { $0.rpe = LiftFormat.number(text) } })
    }

    /// Apply one field change to a set, leaving its other fields as they were.
    ///
    /// Works whether or not the set has been performed — the controller decides where the value
    /// lands. It reads the CURRENT entered values first, so editing the reps cannot blank a weight
    /// that was typed a moment ago into the same pending row.
    private func write(_ slot: LiftSlot, _ mutate: (inout LiftRecordedSet) -> Void) {
        let entered = session.enteredValues(for: slot)
        var row = LiftRecordedSet(exerciseIndex: slot.exerciseIndex, setIndex: slot.setIndex,
                                  weightKg: entered.weightKg, reps: entered.reps, rpe: entered.rpe,
                                  isWarmup: session.isWarmup(slot), startTs: 0, endTs: 0, restSec: nil)
        mutate(&row)
        session.updateSet(slot, weightKg: row.weightKg, reps: row.reps,
                          rpe: row.rpe, isWarmup: row.isWarmup)
    }


    private func actionLabel(_ engine: LiftSessionEngine) -> LocalizedStringKey {
        switch engine.stage {
        case .warmup:   return "Start first set"
        case .working:  return "Set done"
        case .resting(_, let endsAt):
            if engine.allCompleted { return "All sets done" }
            return endsAt > LiftSessionController.unixNow ? "Skip rest" : "Start next set"
        case .finished: return "Saving…"
        }
    }

    // MARK: - Finish

    private var finishSheet: some View {
        let unfinished = session.unfinishedSlots.count
        let asksAboutProgram = !setCountChanges.isEmpty || !addedExercises.isEmpty
        let answered = (unfinished == 0 || unfinishedChoice != nil)
            && (!asksAboutProgram || programChoice != nil)
        return LiftSheetScaffold("Finish session",
                                 subtitle: "One number for the whole session, so a leg day can be compared with a run.",
                                 onCancel: { showingFinish = false }) {
            sessionRpeCard
            if unfinished > 0 { unfinishedCard(count: unfinished) }
            if asksAboutProgram { programCard }

            // One way to save. Session RPE above is optional, so an empty field is simply no rating;
            // a separate "Skip" saved exactly the same way and read as a second choice.
            LTActionButton("Save session", kind: .primary) { Task { await save() } }
                .disabled(saving || !answered)
                .padding(.top, 10)
            if !answered {
                Text("Choose an option above to save.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity)
            }

            // A way OUT that records nothing. Until this existed, the only route off this screen
            // saved. A session started by a mis-tap, or to try something out, had to be saved and
            // then lived in the history and in that day's Effort for good.
            Button(role: .destructive) {
                confirmingDiscard = true
            } label: {
                LiftDestructiveLabel("Discard session")
            }
            .buttonStyle(.plain)
            .disabled(saving)
            .confirmationDialog("Discard this session?",
                                isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) {
                    session.discard()
                    showingFinish = false
                }
                Button("Keep going", role: .cancel) { }
            } message: {
                Text("\(engine?.completedWorkingSets ?? 0) recorded sets will be thrown away. Nothing is saved and no workout is created.")
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 520)
        #endif
        .keyboardDoneToolbar($focused)
        .task { await loadSetCountChanges() }
    }

    /// Session RPE, typed as one number.
    private var sessionRpeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            NoopCardHeader("How hard was the whole session? (1–10)", icon: "barbell", caption: nil)
            TextField("7", text: $sessionRpeText)
                .textFieldStyle(.plain)
                .font(StrandFont.value(28, relativeTo: .title))
                .foregroundStyle(StrandPalette.textPrimary)
                .numericKeyboard()
                .focused($focused, equals: .sessionRpe)
                .padding(.horizontal, 14)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NoopVisualStyle.inset))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(NoopVisualStyle.border, lineWidth: 1))
            Text("This is session RPE. Multiplied by the session's length it gives session load — the one figure that compares across completely different training.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .ltCard()
    }

    /// Sets never started. One choice covers all of them, because what matters at the end of a session
    /// is simply whether they happened: complete them with the numbers the sheet showed, or discard them
    /// to zeros that every figure leaves out and Edit sets can still fill in. A set that was done is never
    /// asked about — it is complete (`LiftSessionController.setsToSave`).
    private func unfinishedCard(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NoopCardHeader("Unfinished sets", icon: "list-checks", caption: nil)
            Text("Sets not started: \(count)")
                .font(StrandFont.light(15, relativeTo: .body))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            SegmentedPillControl([UnfinishedChoice?.some(.complete), .some(.discard)],
                                 selection: $unfinishedChoice, fillsAvailableWidth: true) { choice in
                choice == .complete ? String(localized: "Complete them") : String(localized: "Discard them")
            }
            .accessibilityLabel(Text("Unfinished sets"))
            Text("Completing saves them with the grey numbers shown. Discarding keeps them out of every figure; they stay under Edit sets as zeros you can fill in later.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            // Said before Save rather than after: `save` files nothing when no set counts.
            if unfinishedChoice == .discard,
               !LiftSessionController.anyPerformed(session.setsToSave(completingUnfinished: false)) {
                NoopInsightRow("Every set would be a zero, so discarding saves no session and no workout.",
                               icon: "warning")
            }
        }
        .ltCard()
    }

    /// Exercises added during the session, which the program does not have yet.
    private var addedExercises: [LiftPlanItem] {
        session.engine?.plan.filter(\.addedInSession) ?? []
    }

    /// Set counts changed during the session, and exercises added. The program keeps them only if asked
    /// to — one answer for all of them, listed so the lifter sees what "update" would write.
    private var programCard: some View {
        let added = addedExercises
        return VStack(alignment: .leading, spacing: 12) {
            NoopCardHeader("Program", icon: "list-checks", caption: nil)
            Text(programQuestion(countsChanged: !setCountChanges.isEmpty, exercisesAdded: !added.isEmpty))
                .font(StrandFont.light(15, relativeTo: .body))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(setCountChanges, id: \.itemId) { change in
                Text("\(change.exercise): \(change.from) → \(change.to) sets")
                    .font(StrandFont.light(13, relativeTo: .footnote))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            ForEach(Array(added.enumerated()), id: \.offset) { _, line in
                Text("New: \(line.exercise) · sets: \(line.targetSets)")
                    .font(StrandFont.light(13, relativeTo: .footnote))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            SegmentedPillControl([ProgramChoice?.some(.update), .some(.keep)],
                                 selection: $programChoice, fillsAvailableWidth: true) { choice in
                choice == .update ? String(localized: "Update program") : String(localized: "Keep as it was")
            }
            .accessibilityLabel(Text("Program"))
        }
        .ltCard()
    }

    /// The program question, worded for what actually changed.
    private func programQuestion(countsChanged: Bool, exercisesAdded: Bool) -> LocalizedStringKey {
        switch (countsChanged, exercisesAdded) {
        case (true, true):  return "You added exercises and changed the number of sets. Keep these changes in the program for next time?"
        case (false, true): return "You added exercises. Add them to the program for next time?"
        default:            return "You changed the number of sets. Keep the new counts in the program for next time?"
        }
    }

    // MARK: - Loading and saving

    /// What was lifted for each of this session's exercises LAST time, by set number — the middle
    /// layer of the grey numbers, handed to the controller that owns the chain.
    private func loadLastTime() async {
        guard let engine, let store = await repo.storeHandle() else { return }
        var out: [String: [Int: LiftSetCarry]] = [:]
        // One query per DISTINCT exercise, not per plan line. A program that programs the same
        // movement twice — or an imported one with many lines — would otherwise re-ask the store the
        // same question, and this runs when the sheet opens.
        for exercise in NSOrderedSet(array: engine.plan.map(\.exercise)).compactMap({ $0 as? String }) {
            let rows = (try? await store.lastLiftSets(deviceId: repo.deviceId,
                                                      exercise: exercise,
                                                      before: engine.startTs)) ?? []
            var bySet: [Int: LiftSetCarry] = [:]
            for r in rows where !r.isWarmup {
                bySet[r.setIndex] = LiftSetCarry(weightKg: r.weightKg, reps: r.reps)
            }
            out[exercise] = bySet
        }
        lastTime = out
        session.setLastSession(out)
    }

    private func save() async {
        guard !saving, let store = await repo.storeHandle() else { return }
        saving = true
        defer { saving = false }

        session.finish()
        guard let engine = session.engine else { return }
        let endTs = Int(Date().timeIntervalSince1970)
        let sessionId = UUID().uuidString
        // After `finish`, which closes out the running rest: that set's measured rest belongs to it.
        let finished = session.setsToSave(completingUnfinished: unfinishedChoice == .complete)

        // Nothing to file, so file nothing. With no set done, "Discard them" turns every set into a zero.
        // Filing that anyway wrote a session with nothing in it AND a manual workout, and the engine fills
        // that workout's strain from the heart rate the strap measured — so an hour that recorded nothing
        // still read back as a workout. The finish sheet says so before Save. The program's set counts
        // are a separate thing the user chose explicitly, so those still apply.
        guard LiftSessionController.anyPerformed(finished) else {
            await writeProgram(store: store, plan: engine.plan, sets: finished)
            await finishAndDismiss()
            return
        }

        let row = LiftSessionRow(
            id: sessionId, deviceId: repo.deviceId,
            startTs: engine.startTs, endTs: endTs, sport: LiftSessionView.sport,
            programId: session.programId,
            // Snapshot the name: renaming or deleting the program never rewrites this session.
            programName: session.programName,
            sessionRpe: LiftFormat.number(sessionRpeText),
            note: session.programName)
        _ = try? await store.upsertLiftSessions([row])

        // `ord` is COMPLETION order, which with out-of-order work is not the plan's order — and it
        // is the order that actually happened, which is what a session should read back as. Sets
        // completed at finish without being started come last.
        let rows = finished.enumerated().map { ord, s -> LiftSetRow in
            let item = engine.planItem(for: s.slot)
            return LiftSetRow(
                id: UUID().uuidString, deviceId: repo.deviceId, sessionId: sessionId,
                ord: ord, exercise: item?.exercise ?? "",
                // Snapshot the classification AS IT WAS, so reclassifying later never rewrites what
                // past weeks were counted as.
                primaryMuscle: item?.primaryMuscle,
                secondaryMuscles: item?.secondaryMuscles ?? [],
                setIndex: s.slot.setIndex, weightKg: s.weightKg, reps: s.reps, rpe: s.rpe,
                isWarmup: s.isWarmup, startTs: s.startTs, endTs: s.endTs,
                restSec: s.restSec, note: nil)
        }
        _ = try? await store.upsertLiftSets(rows)
        await writeProgram(store: store, plan: engine.plan, sets: finished)

        // Through the SAME path a manual workout takes, so it inherits overlap dedup, the engine's
        // HR-derived strain fill and delete/merge. `strain` stays nil deliberately: the engine fills
        // it from the heart rate the strap MEASURED, never from typed sets and reps.
        let workout = WorkoutRow(
            startTs: engine.startTs, endTs: endTs, sport: LiftSessionView.sport,
            source: "manual", durationS: Double(max(0, endTs - engine.startTs)),
            energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
            distanceM: nil, zonesJSON: nil, notes: session.programName, steps: nil)
        await repo.saveManualWorkout(workout)

        await finishAndDismiss()
    }

    /// Close the session down and leave the sheet. Shared by the normal save and the nothing-to-file
    /// path above, so the two cannot drift about what ending a session means.
    private func finishAndDismiss() async {
        session.finishedSaving()
        await repo.refresh()
        await onFinished()
        showingFinish = false
        dismiss()
    }

    /// The program lines whose set count this session changed, for the finish sheet to ask about.
    private func loadSetCountChanges() async {
        guard let programId = session.programId, let plan = session.engine?.plan,
              let store = await repo.storeHandle(),
              let rows = try? await store.liftProgramItems(programId: programId) else { return }
        setCountChanges = LiftSessionController.setCountChanges(plan: plan, program: rows)
    }

    /// Carry this session onto its program (`LiftSessionController.programAfterSession`): each line's
    /// heaviest done set becomes its weight and reps (always, Utku 21 Sep 2026); changed set counts and
    /// exercises added during the session reach it only when the user chose to keep them.
    ///
    /// Re-reads the lines, so a program edited elsewhere while the session ran keeps every other change
    /// and a line deleted since is not resurrected. The store call replaces the lines wholesale, so
    /// nothing is written when no line differs.
    private func writeProgram(store: WhoopStore, plan: [LiftPlanItem],
                              sets: [LiftSessionController.FinishedSet]) async {
        guard let programId = session.programId,
              let rows = try? await store.liftProgramItems(programId: programId) else { return }
        let edited = LiftSessionController.programAfterSession(
            sets, plan: plan, program: rows, keepingChanges: programChoice == .update,
            programId: programId, deviceId: repo.deviceId)
        guard edited != rows else { return }
        _ = try? await store.replaceLiftProgramItems(programId: programId, items: edited)
    }

    /// The sport every logged session is filed under — the same token the Hevy/Liftosaur importer
    /// uses, so a typed session and an imported one land in one bucket with one icon.
    static let sport = "Strength Training"
}
