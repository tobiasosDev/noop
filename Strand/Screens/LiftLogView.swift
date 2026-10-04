import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// The Lift Log: build a program once, then run it in the gym by tapping through it.
//
// This screen is the front door — the week on the effort glow, the saved programs, the sets each
// muscle got and the sessions run from them. It lives in the Effort colour world, like Workouts,
// because a finished session lands in the `workout` table beside every other workout.
//
// EFFORT IS NEVER MODIFIED HERE (load-bearing). NOOP's Effort is computed from heart rate alone
// (Karvonen %HRR → Edwards TRIMP, `StrainScorer`), and there is no validated public path from typed
// sets/reps/weight to a cardiovascular-strain equivalent — WHOOP's own muscular load runs
// velocity-based algorithms over strap accelerometer/gyroscope data under an unpublished model.
// So the lifting figures are shown BESIDE Effort and never folded into it, matching the choice the
// imported-lifting path already made (`strain: nil, // never a fabricated cardiovascular strain`).

struct LiftLogView: View {
    @EnvironmentObject var repo: Repository

    /// Saved programs, most-recently-touched first. Loaded off the store on appear/refresh.
    @State private var programs: [LiftProgramRow] = []
    @State private var loaded = false

    /// The program being created or edited (nil = the editor is closed).
    @State private var editing: ProgramEditTarget?
    @State private var importing = false
    /// The live session, owned at the app root so it survives this screen going away.
    @EnvironmentObject private var session: LiftSessionController
    /// Recent finished sessions, newest first.
    @State private var history: [LiftSessionRow] = []
    /// This week's fractional sets per muscle.
    @State private var weekCounts: [LiftMuscle: Double] = [:]
    /// The session whose detail sheet is open.
    @State private var viewing: SessionDetailTarget?
    /// Each program's exercise lines (for the cards' count and preview), by program id.
    @State private var programItems: [String: [LiftProgramItemRow]] = [:]
    /// The logged sets of the sessions this screen summarises (this week's and the listed ones), by
    /// session id.
    @State private var sessionSets: [String: [LiftSetRow]] = [:]

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    /// How many finished sessions the list shows.
    private static let listedSessions = 8

    var body: some View {
        ScreenScaffold(title: nil, onRefresh: { await load() }) {
            NoopScreenHeader("Lift log") { addMenu }
                .padding(.bottom, 6)
            titleBlock
            weekHero.padding(.top, 6)
            programsSection
            weekSection
            historySection
        }
        .noopHidesSystemNavBar()
        // Also on a saved session: the session sheet lives above this screen and cannot tell it
        // directly, and a save does not always bump `refreshSeq`.
        .task(id: "\(repo.refreshSeq)-\(session.savedSessions)") { await load() }
        .sheet(item: $editing) { target in
            LiftProgramEditorSheet(program: target.program) {
                await load()
            }
        }
        .sheet(isPresented: $importing) {
            LiftProgramImportSheet { await load() }
        }
        .sheet(item: $viewing) { target in
            LiftSessionDetailSheet(session: target.session) { await load() }
        }
    }

    // MARK: - Header

    /// New program / import from a spreadsheet.
    private var addMenu: some View {
        Menu {
            Button {
                editing = ProgramEditTarget(id: "new", program: nil)
            } label: {
                Label("New program", systemImage: "plus")
            }
            // Filling a dozen exercise lines by hand on a phone is the most tedious thing in the
            // feature; a spreadsheet on a computer does it in a couple of minutes.
            Button {
                importing = true
            } label: {
                Label("Import", systemImage: "tablecells")
            }
        } label: {
            NoopCircleIcon("plus")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("New program"))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Lift log")
                .font(StrandFont.title1)
                .tracking(-0.56)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Your log book")
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - This week (hero)

    /// The week on the effort glow: working sets across the last 7 days, where the muscles sit against
    /// the research floor, the volume, the time spent in sessions and the heaviest set, and the start
    /// (or return-to) control.
    private var weekHero: some View {
        let now = Int(Date().timeIntervalSince1970)
        let week = history.filter { $0.startTs >= now - 7 * 86_400 }
        let sets = week.flatMap { sessionSets[$0.id] ?? [] }.filter { !$0.isWarmup && LiftMetrics.isPerformed(reps: $0.reps) }
        let volumeKg = week.compactMap { LiftMetrics.volumeLoadKg(sessionSets[$0.id] ?? []) }.reduce(0, +)
        let seconds = week.reduce(0) { $0 + max(0, ($1.endTs ?? $1.startTs) - $1.startTs) }
        let heaviest = sets.compactMap(\.weightKg).max()
        let trend = weekTrend(workingSets: sets.count, now: now)
        return NoopHeroCard(glow: .strain, padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge("This week", icon: "barbell")
                    Spacer(minLength: 8)
                    NoopPill("Last 7 days", compact: true)
                }
                HStack(alignment: .bottom, spacing: 14) {
                    Text(verbatim: "\(sets.count)")
                        .font(StrandFont.dot(96))
                        .tracking(StrandFont.dotTracking(96))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .layoutPriority(1)
                    VStack(alignment: .leading, spacing: 8) {
                        if let trend {
                            NoopTag(trend.tag)
                                .accessibilityLabel(Text(trend.spoken))
                        }
                        Text(week.count == 1 ? String(localized: "working sets · 1 session")
                                             : String(localized: "working sets · \(week.count) sessions"))
                            .font(StrandFont.caption)
                            .foregroundStyle(NoopMetric.heroLabel)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.bottom, 10)
                }
                .padding(.top, 10)
                .accessibilityElement(children: .combine)
                if let sentence = floorSentence {
                    Text(verbatim: sentence)
                        .font(StrandFont.light(14, relativeTo: .subheadline))
                        .foregroundStyle(StrandPalette.textPrimary.opacity(0.84))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 18)
                }
                HStack(alignment: .top, spacing: 0) {
                    heroStat(volumeKg > 0 ? volumeLabel(volumeKg) : "—", label: "Volume lifted")
                    heroStat(seconds > 0 ? durationLabel(seconds) : "—", label: "Time in sessions")
                    heroStat(heaviest.map { LiftFormat.weight($0, system: unitSystem) } ?? "—", label: "Heaviest set")
                }
                .padding(.top, 18)
                startControl.padding(.top, 22)
            }
        }
    }

    /// The hero tag: this week's working sets against the 7 days before. Nil without a previous week to
    /// compare with, so the tag never claims a direction it cannot show.
    private func weekTrend(workingSets: Int, now: Int) -> (tag: LocalizedStringKey, spoken: LocalizedStringKey)? {
        let previous = history.filter { $0.startTs >= now - 14 * 86_400 && $0.startTs < now - 7 * 86_400 }
        let before = previous.flatMap { sessionSets[$0.id] ?? [] }
            .filter { !$0.isWarmup && LiftMetrics.isPerformed(reps: $0.reps) }.count
        guard before > 0 else { return nil }
        let ratio = Double(workingSets) / Double(before)
        if ratio > 1.1 { return ("Building", "More working sets than the 7 days before") }
        if ratio < 0.9 { return ("Lighter", "Fewer working sets than the 7 days before") }
        return ("Steady", "About as many working sets as the 7 days before")
    }

    /// "Chest and back at or above the weekly research floor. Quads below it." — named and sourced
    /// against the floor, never as a target (see `weekSection`). Past a handful of muscles the names would
    /// fill the hero, so it counts instead and leaves the names to the per-muscle card.
    private var floorSentence: String? {
        let floor = LiftMetrics.ReferenceDose.hypertrophyMinimumSetsPerWeek
        let ordered = LiftMuscle.ordered.filter { (weekCounts[$0] ?? 0) > 0 }
        guard !ordered.isEmpty else { return nil }
        let at = ordered.filter { (weekCounts[$0] ?? 0) >= floor }.map(\.displayName)
        let below = ordered.filter { (weekCounts[$0] ?? 0) < floor }.map(\.displayName)
        if below.isEmpty {
            return String(localized: "Every muscle you trained is at or above the weekly research floor.")
        }
        if at.count > 3 || below.count > 3 {
            return String(localized: "\(at.count) of \(ordered.count) muscles at or above the weekly research floor, \(below.count) below it.")
        }
        var parts: [String] = []
        if !at.isEmpty {
            parts.append(String(localized: "\(ListFormatter.localizedString(byJoining: at)) at or above the weekly research floor."))
        }
        parts.append(String(localized: "\(ListFormatter.localizedString(byJoining: below)) below it."))
        return parts.joined(separator: " ")
    }

    /// "2:22 h" for an hour or more, "46 min" below it — split by `heroStat` into value and unit.
    private func durationLabel(_ seconds: Int) -> String {
        let minutes = seconds / 60
        guard minutes >= 60 else { return String(localized: "\(minutes) min") }
        return String(localized: "\(minutes / 60):\(String(format: "%02d", minutes % 60)) h")
    }

    /// "21.6 t" from kilograms (or pounds in thousands for imperial users).
    private func volumeLabel(_ kg: Double) -> String {
        let display = LiftFormat.display(fromKilograms: kg, system: unitSystem)
        if display >= 1000 {
            return unitSystem == .imperial ? "\(LiftFormat.trim((display / 1000 * 10).rounded() / 10))k lb"
                                           : "\(LiftFormat.trim((display / 1000 * 10).rounded() / 10)) t"
        }
        return LiftFormat.weight(kg, system: unitSystem)
    }

    private func heroStat(_ value: String, label: LocalizedStringKey) -> some View {
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        return NoopMetric(value: parts.first ?? value, unit: parts.count > 1 ? parts[1] : nil, label: label,
                          labelColor: NoopMetric.heroLabel)
    }

    /// Start a session: straight into the only program, a choice when there are several, the program
    /// editor when there is none yet, and back into the running session when one is live.
    @ViewBuilder private var startControl: some View {
        if session.isActive {
            LTActionButton("Return to session", icon: "play", kind: .primary) { session.isPresented = true }
        } else if programs.isEmpty {
            LTActionButton("New program", icon: "plus", kind: .primary) {
                editing = ProgramEditTarget(id: "new", program: nil)
            }
            .disabled(!loaded)
        } else if programs.count == 1, let only = programs.first {
            LTActionButton("Start session", icon: "play", kind: .primary) { Task { await start(only) } }
                .accessibilityLabel("Start this program")
        } else {
            Menu {
                ForEach(programs, id: \.id) { program in
                    Button(program.name) { Task { await start(program) } }
                }
            } label: {
                HStack(spacing: 8) {
                    PhIcon("play", weight: .fill, size: 18)
                    Text("Start session")
                }
            }
            .menuStyle(.button)
            .buttonStyle(LTPillStyle(kind: .primary))
            .menuIndicator(.hidden)
        }
    }

    // MARK: - Programs

    @ViewBuilder private var programsSection: some View {
        NoopSectionTitle("Programs") {
            Text(verbatim: String(localized: "Saved · \(programs.count)"))
        }
        if !loaded {
            NoopInsightRow("Reading your programs…", icon: "barbell").ltCard()
        } else if programs.isEmpty {
            emptyState
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(programs, id: \.id) { program in
                        programCard(program)
                    }
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
            }
            .padding(.horizontal, -NoopMetrics.screenHPadding)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No programs yet")
                .font(StrandFont.book(15, relativeTo: .body))
                .foregroundStyle(StrandPalette.textPrimary)
            Text("A program is a name and an ordered list of exercises with your targets — working sets, reps, weight, rest and your own technique note.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                LTActionButton("New program", icon: "plus", height: 40, fontSize: 13, fullWidth: false) {
                    editing = ProgramEditTarget(id: "new", program: nil)
                }
                LTActionButton("Import", icon: "table", height: 40, fontSize: 13, fullWidth: false) {
                    importing = true
                }
            }
            .padding(.top, 6)
        }
        .ltCard()
    }

    /// One program as a carousel card: its exercises and when it was last run. Tapping edits it; the
    /// hero's Start runs it.
    private func programCard(_ program: LiftProgramRow) -> some View {
        let items = programItems[program.id] ?? []
        let last = history.first { $0.programId == program.id }
        return Button {
            editing = ProgramEditTarget(id: program.id, program: program)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                NoopIconTile("barbell")
                Text(verbatim: program.name)
                    .font(StrandFont.book(17, relativeTo: .headline))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .padding(.top, 20)
                Text(items.count == 1 ? String(localized: "1 exercise") : String(localized: "\(items.count) exercises"))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.top, 4)
                Text(verbatim: items.prefix(3).map(\.exercise).joined(separator: ", "))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 14)
                LTHairline()
                HStack {
                    Text(verbatim: last.map { Self.shortDate($0.startTs) } ?? String(localized: "Not run yet"))
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 4)
                    if let last {
                        Text(verbatim: relativeAgo(TimeInterval(last.startTs)))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .font(StrandFont.footnote)
                .lineLimit(1)
                .padding(.top, 12)
            }
            .padding(16)
            .frame(width: 157, height: 182, alignment: .topLeading)
            .noopPanel()
            .contentShape(RoundedRectangle(cornerRadius: NoopVisualStyle.cardRadius, style: .continuous))
        }
        .buttonStyle(LTPressStyle())
        .accessibilityHint(Text("Tap to edit"))
    }

    // MARK: - Start a session

    /// Flatten a program into the plan the session runs. The plan is SNAPSHOT at start: editing or
    /// deleting the program mid-session cannot change what is being tapped through.
    private func start(_ program: LiftProgramRow) async {
        guard let store = await repo.storeHandle() else { return }
        let items = (try? await store.liftProgramItems(programId: program.id)) ?? []
        guard !items.isEmpty else { return }
        let vocabulary = (try? await store.liftExercises(deviceId: repo.deviceId)) ?? []

        let plan = items.map { item -> LiftPlanItem in
            // The classification comes from the exercise vocabulary, which is the one place that owns
            // it — the program line deliberately stores no muscle of its own to drift from.
            let known = vocabulary.first { $0.name == item.exercise }
            return LiftPlanItem(exercise: item.exercise,
                                primaryMuscle: known?.primaryMuscle,
                                secondaryMuscles: known?.secondaryMuscles ?? [],
                                targetSets: item.targetSets,
                                restSec: item.restSec,
                                targetRepsLow: item.targetRepsLow,
                                targetRepsHigh: item.targetRepsHigh,
                                targetRpe: item.targetRpe,
                                targetWeightKg: item.targetWeightKg,
                                note: item.note,
                                // Carried so a set added or dropped mid-session can be written back
                                // onto the line it came from, and be there next time.
                                programItemId: item.id)
        }
        // Refuse to start a second session over a running one: two live sessions would both claim
        // the strap gesture and both write the in-flight snapshot.
        guard !session.isActive else {
            session.isPresented = true
            return
        }
        session.start(plan: plan, programId: program.id, programName: program.name)
    }

    // MARK: - This week, per muscle

    @ViewBuilder private var weekSection: some View {
        let ordered = LiftMuscle.ordered.filter { (weekCounts[$0] ?? 0) > 0 }
        NoopSectionTitle("Sets per muscle", captionKey: "Last 7 days · estimated")
        if ordered.isEmpty {
            NoopInsightRow("Once you've logged a session, this shows how many sets each muscle got this week, against what the research associates with growth.", icon: "barbell")
                .ltCard()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                muscleAxis
                ForEach(ordered, id: \.self) { muscle in
                    muscleBar(muscle, sets: weekCounts[muscle] ?? 0)
                }
                muscleLegend.padding(.top, 4)
                // The band is named and sourced, never phrased as a target NOOP sets for
                // anyone: this is not a medical device and does not prescribe.
                Text("Counted from the muscles you assigned each exercise: direct sets count once, indirect ones half. The tick is about 4 sets a week — below that, studies across GROUPS of people stop reliably detecting growth. It is a research reference, not a target for you, and above it gains continue with strongly diminishing returns and no clear ceiling, so the bar has no \"full\".")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .ltCard()
        }
    }

    /// The span the weekly bar is drawn across.
    ///
    /// A DRAWING choice, not a dose. The evidence puts a floor at about 4 sets a week and identifies
    /// NO ceiling for hypertrophy — gains continue above it with strongly diminishing returns — so
    /// any bar maximum is arbitrary and must never be read as a target. 20 is chosen only because it
    /// comfortably contains the range people actually train in, which puts the floor tick early on
    /// the bar and makes a normal week read as progress rather than as "finished".
    ///
    /// The NUMBER beside the bar is the truth. The bar is context for it, and a count past 20 fills
    /// the bar while the number keeps counting.
    private static let weeklySetsBarSpan = 20.0

    /// Width of the muscle-name column and of the count column, shared by the axis row and the bars.
    private static let muscleNameWidth: CGFloat = 92
    private static let muscleCountWidth: CGFloat = 30

    /// 0 · 10 · 20 above the bars, aligned to the bar column.
    private var muscleAxis: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: Self.muscleNameWidth, height: 1)
            GeometryReader { geo in
                ForEach([0.0, 10.0, 20.0], id: \.self) { v in
                    Text(verbatim: LiftFormat.trim(v))
                        .font(StrandFont.light(10))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize()
                        .position(x: min(max(geo.size.width * v / Self.weeklySetsBarSpan, 4), geo.size.width - 6), y: 6)
                }
            }
            .frame(height: 12)
            Color.clear.frame(width: Self.muscleCountWidth, height: 1)
        }
        .accessibilityHidden(true)
    }

    /// The floor marker, and what the two bar shades mean.
    private var muscleLegend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(StrandPalette.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: 18, height: 10)
                Text("Research floor · \(LiftFormat.trim(LiftMetrics.ReferenceDose.hypertrophyMinimumSetsPerWeek)) sets")
            }
            HStack(spacing: 6) {
                Circle().fill(StrandPalette.effortColor).frame(width: 8, height: 8)
                Text("At or above")
            }
            HStack(spacing: 6) {
                Circle().fill(NoopVisualStyle.quaternaryText).frame(width: 8, height: 8)
                Text("Below")
            }
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
    }

    /// One muscle's week: the count, and where it sits relative to the evidence.
    ///
    /// This used to scale the bar 0...4 and turn it FULL and GREEN at four sets — so the screen said
    /// "done" at the exact point the research says growth merely becomes *detectable*. It was telling
    /// the user to stop at the starting line, and it contradicted the caption printed directly below
    /// it. Now four sets is a dashed TICK a fifth of the way along, and nothing on the bar ever reads
    /// as complete, because nothing about the dose is.
    private func muscleBar(_ muscle: LiftMuscle, sets: Double) -> some View {
        let floor = LiftMetrics.ReferenceDose.hypertrophyMinimumSetsPerWeek
        let atOrAboveFloor = sets >= floor
        let fill = min(1.0, sets / Self.weeklySetsBarSpan)
        let tick = min(1.0, floor / Self.weeklySetsBarSpan)

        return HStack(spacing: 12) {
            Text(muscle.displayName)
                .font(StrandFont.light(13, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: Self.muscleNameWidth, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Muted below the floor — below it growth is not reliably detectable, which is worth
                    // showing — and the ordinary track accent above it. Never a "done" colour.
                    if atOrAboveFloor {
                        NoopTrack(fraction: fill, height: 12)
                    } else {
                        NoopTrack(fraction: fill, height: 12,
                                  fill: [NoopVisualStyle.quaternaryText, NoopVisualStyle.quaternaryText])
                    }
                    // The floor, marked where it actually falls.
                    Path { p in
                        p.move(to: CGPoint(x: geo.size.width * tick, y: -4))
                        p.addLine(to: CGPoint(x: geo.size.width * tick, y: geo.size.height + 4))
                    }
                    .stroke(StrandPalette.textPrimary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityHidden(true)
                }
            }
            .frame(height: 12)
            // Deliberately NOT a success colour. There is no success point to signal, and a
            // coloured number is exactly what made four sets read as an achievement.
            Text(LiftFormat.trim(sets))
                .font(StrandFont.book(13, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: Self.muscleCountWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(atOrAboveFloor
                            ? String(localized: "\(muscle.displayName): \(LiftFormat.trim(sets)) sets, at or above the weekly floor of \(LiftFormat.trim(floor))")
                            : String(localized: "\(muscle.displayName): \(LiftFormat.trim(sets)) sets, below the weekly floor of \(LiftFormat.trim(floor))"))
    }

    // MARK: - History

    @ViewBuilder private var historySection: some View {
        NoopSectionTitle("Sessions", captionKey: "Recent")
        if history.isEmpty {
            NoopInsightRow("Finished sessions land here, with every set you logged.", icon: "barbell")
                .ltCard()
        } else {
            NoopList {
                ForEach(history.prefix(Self.listedSessions), id: \.id) { session in
                    Button {
                        viewing = SessionDetailTarget(id: session.id, session: session)
                    } label: {
                        historyRow(session)
                    }
                    .buttonStyle(LTPressStyle())
                }
            }
        }
        VStack(spacing: 6) {
            if let oldest = history.last {
                Text(history.count == 1
                     ? String(localized: "Logged on \(Platform.deviceNounPhrase) · 1 session since \(Self.monthName(oldest.startTs))")
                     : String(localized: "Logged on \(Platform.deviceNounPhrase) · \(history.count) sessions since \(Self.monthName(oldest.startTs))"))
            }
            // Lifting sits beside Effort and never inside it (see the note at the top of this file).
            Text("Lifting adds volume and set counts. It never changes your Effort, which stays measured from heart rate.")
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 6)
    }

    /// "June" — the month the oldest listed session ran in.
    private static func monthName(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(.dateTime.month(.wide))
    }

    /// One finished session: the program, "Thu 1 Oct · 46 min · 14 sets · 7.4 t", and its heaviest set.
    private func historyRow(_ session: LiftSessionRow) -> some View {
        let sets = (sessionSets[session.id] ?? []).filter { !$0.isWarmup && LiftMetrics.isPerformed(reps: $0.reps) }
        let top = sets.max { ($0.weightKg ?? 0) < ($1.weightKg ?? 0) }
        var parts = [Self.shortDate(session.startTs)]
        if let end = session.endTs, end > session.startTs {
            parts.append(String(localized: "\((end - session.startTs) / 60) min"))
        }
        if !sets.isEmpty { parts.append(String(localized: "\(sets.count) sets")) }
        if let volume = LiftMetrics.volumeLoadKg(sessionSets[session.id] ?? []), volume > 0 {
            parts.append(volumeLabel(volume))
        }
        return NoopRow(title: Text(verbatim: session.programName ?? String(localized: "Session")),
                       caption: Text(verbatim: parts.joined(separator: " · ")), icon: "barbell") {
            if let top, let kg = top.weightKg {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: LiftFormat.weight(kg, system: unitSystem))
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                    // Narrow on purpose: the exercise name gives way before the session line beside it
                    // wraps; the reps stay whole.
                    HStack(spacing: 0) {
                        Text(verbatim: top.exercise).lineLimit(1).truncationMode(.tail)
                        if let reps = top.reps { Text(verbatim: " × \(reps)").fixedSize() }
                    }
                    .font(StrandFont.light(10))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: 56, alignment: .trailing)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    /// "Thu 1 Oct".
    private static func shortDate(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    // MARK: - Load

    private func load() async {
        guard let store = await repo.storeHandle() else { return }
        programs = (try? await store.liftPrograms(deviceId: repo.deviceId)) ?? []
        var items: [String: [LiftProgramItemRow]] = [:]
        for program in programs {
            items[program.id] = (try? await store.liftProgramItems(programId: program.id)) ?? []
        }
        programItems = items

        let now = Int(Date().timeIntervalSince1970)
        history = ((try? await store.liftSessions(deviceId: repo.deviceId,
                                                  fromTs: now - 180 * 86_400,
                                                  toTs: now)) ?? [])
            .filter { $0.endTs != nil }                 // an abandoned session is not history
            .sorted { $0.startTs > $1.startTs }
        weekCounts = (try? await store.liftSetCounts(deviceId: repo.deviceId,
                                                      fromTs: now - 7 * 86_400,
                                                      toTs: now).fractional) ?? [:]
        // Sets only for what the screen summarises: the last two weeks (this week, and the one before it
        // that the hero's tag compares with) and the listed sessions.
        var sets: [String: [LiftSetRow]] = [:]
        for s in history where s.startTs >= now - 14 * 86_400 || sets.count < Self.listedSessions {
            sets[s.id] = (try? await store.liftSets(sessionId: s.id)) ?? []
        }
        sessionSets = sets
        loaded = true
    }
}

/// The session whose detail is being read back. A wrapper rather than a retroactive `Identifiable`
/// on `LiftSessionRow`, keeping the store's row types free of app-layer conformances.
private struct SessionDetailTarget: Identifiable {
    let id: String
    let session: LiftSessionRow
}


/// Identifies what the editor sheet is editing. A wrapper rather than a retroactive `Identifiable`
/// on `LiftProgramRow`, so the store's row types stay free of app-layer conformances — and so
/// "new program" has an identity of its own to present on.
private struct ProgramEditTarget: Identifiable {
    let id: String
    let program: LiftProgramRow?
}
