#if DEBUG
import SwiftUI
import StrandDesign
import WhoopStore

extension DemoScreensV2 {
    /// Group 10 demo screens for `--demo-screen <name>` (lowercase names).
    static func group10(_ name: String) -> AnyView? {
        switch name {
        // The Lift log with a few weeks of seeded programs and sessions, pushed so the back circle shows.
        case "g10-liftlog": return AnyView(LiftDemoPushHost { LiftLogView() })
        // The middle of the Lift log (the program cards), drawn on a tall canvas shifted up, since the
        // anchors only reach top, centre and bottom.
        case "g10-liftlog-mid":
            return AnyView(LiftDemoPushHost {
                GeometryReader { _ in
                    LiftLogView().frame(height: 1900, alignment: .top).offset(y: -560)
                }
                .clipped()
            })
        // The empty Lift log (no programs, no sessions).
        case "g10-liftlog-empty": return AnyView(LiftDemoPushHost(seed: false) { EmptyLiftLogHost() })
        // The running session sheet over the Lift log: overhead press done, bench set 2 done, resting.
        case "g10-liftsession": return AnyView(LiftSessionDemoHost(stage: .resting))
        // The same session while a set is being worked.
        case "g10-liftsession-working": return AnyView(LiftSessionDemoHost(stage: .working))
        // A fresh session before the first set.
        case "g10-liftsession-warmup": return AnyView(LiftSessionDemoHost(stage: .warmup))
        // The minimised session bar on its own, as the shell draws it above the tab bar.
        case "g10-liftbar": return AnyView(LiftSessionDemoHost(stage: .resting, minimised: true))
        case "g10-interval": return AnyView(LiftDemoPushHost(seed: false) { IntervalTimerView() })
        // The interval timer mid-session: round 3 of 8, running.
        case "g10-interval-running":
            return AnyView(LiftDemoPushHost(seed: false) { IntervalTimerView(demoRunning: true) })
        // The Lift sheets, each presented as a sheet over a black screen.
        case "g10-sheet-program": return AnyView(LiftSheetDemoHost(sheet: .program))
        case "g10-sheet-item": return AnyView(LiftSheetDemoHost(sheet: .item))
        case "g10-sheet-addexercise": return AnyView(LiftSheetDemoHost(sheet: .addExercise))
        case "g10-sheet-detail": return AnyView(LiftSheetDemoHost(sheet: .detail))
        case "g10-sheet-edit": return AnyView(LiftSheetDemoHost(sheet: .edit))
        case "g10-sheet-import": return AnyView(LiftSheetDemoHost(sheet: .importer))
        // The finish sheet over the running session.
        case "g10-sheet-finish": return AnyView(LiftSessionDemoHost(stage: .resting, finishing: true))
        default: return nil
        }
    }
}

/// DEBUG-only: one of the Lift sheets, presented over a black screen after the lift demo data is seeded,
/// filled from the seeded "Push A" program and its newest session. Presented by item, so the sheet is built
/// once, with everything it shows already loaded.
private struct LiftSheetDemoHost: View {
    enum Sheet { case program, item, addExercise, detail, edit, importer }
    let sheet: Sheet

    private struct Payload: Identifiable {
        let id = "demo"
        var program: LiftProgramRow?
        var item: LiftProgramItemRow?
        var session: LiftSessionRow?
        var sets: [LiftSetRow]
    }

    @EnvironmentObject private var repo: Repository
    @State private var payload: Payload?

    var body: some View {
        Color.black.ignoresSafeArea()
            .sheet(item: $payload) { content($0) }
            .task {
                await LiftDemoSeed.seed(repo)
                guard let store = await repo.storeHandle() else { return }
                let program = (try? await store.liftPrograms(deviceId: repo.deviceId))?
                    .first { $0.id == LiftDemoSeed.pushId }
                let item = (try? await store.liftProgramItems(programId: LiftDemoSeed.pushId))?.first
                let now = Int(Date().timeIntervalSince1970)
                let session = (try? await store.liftSessions(deviceId: repo.deviceId, fromTs: now - 30 * 86_400,
                                                             toTs: now))?
                    .filter { $0.endTs != nil }.max { $0.startTs < $1.startTs }
                var sets: [LiftSetRow] = []
                if let session { sets = (try? await store.liftSets(sessionId: session.id)) ?? [] }
                payload = Payload(program: program, item: item, session: session, sets: sets)
            }
    }

    @ViewBuilder private func content(_ p: Payload) -> some View {
        switch sheet {
        case .program: LiftProgramEditorSheet(program: p.program) { }
        case .item: LiftProgramItemSheet(item: p.item) { _ in }
        case .addExercise: LiftSessionExerciseSheet { _, _, _ in }
        case .detail:
            if let session = p.session { LiftSessionDetailSheet(session: session) }
        case .edit:
            if let session = p.session { LiftSessionEditSheet(session: session, sets: p.sets) { } }
        case .importer: LiftProgramImportSheet { }
        }
    }
}

/// DEBUG-only: the Lift log read under a device id that has no lift rows, so the empty state shows even
/// on a simulator where an earlier capture seeded the demo programs.
private struct EmptyLiftLogHost: View {
    @State private var repo = Repository(deviceId: "demo-lift-empty")

    var body: some View {
        LiftLogView().environmentObject(repo)
    }
}

/// DEBUG-only: pushes `content` onto the harness's navigation stack (so a `NoopScreenHeader` draws its back
/// circle, as it does in the app), after optionally seeding the lift demo data.
private struct LiftDemoPushHost<Content: View>: View {
    @EnvironmentObject private var repo: Repository
    var seed = true
    @ViewBuilder var content: () -> Content
    @State private var shown = false

    var body: some View {
        Color.clear
            .navigationDestination(isPresented: $shown) { content() }
            .task {
                if seed { await LiftDemoSeed.seed(repo) }
                shown = true
            }
    }
}

/// DEBUG-only: the running gym session, started from the seeded "Push A" program and driven into a
/// known stage, presented the way the shell presents it (a sheet over the Lift log), or minimised to
/// the bottom bar. A session left over from a previous launch is discarded first, so every capture
/// starts from the same state.
private struct LiftSessionDemoHost: View {
    enum Stage { case warmup, working, resting }
    let stage: Stage
    var minimised = false
    /// Open the finish sheet over the session.
    var finishing = false

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var session: LiftSessionController
    @State private var ready = false

    var body: some View {
        Group {
            if minimised {
                ZStack(alignment: .bottom) {
                    Color.black.ignoresSafeArea()
                    if ready {
                        LiftSessionBar()
                            .padding(.horizontal, 14)
                            .padding(.bottom, NoopMetrics.tabBarClearance)
                    }
                }
            } else {
                LiftLogView()
                    .sheet(isPresented: $session.isPresented) { LiftSessionView(demoFinishing: finishing) { } }
            }
        }
        .task {
            await LiftDemoSeed.seed(repo)
            if session.isActive { session.discard() }
            guard let store = await repo.storeHandle(),
                  let program = (try? await store.liftPrograms(deviceId: repo.deviceId))?
                    .first(where: { $0.id == LiftDemoSeed.pushId }) else { return }
            let items = (try? await store.liftProgramItems(programId: program.id)) ?? []
            let vocab = (try? await store.liftExercises(deviceId: repo.deviceId)) ?? []
            let plan = items.map { item in
                let known = vocab.first { $0.name == item.exercise }
                return LiftPlanItem(exercise: item.exercise, primaryMuscle: known?.primaryMuscle,
                                    secondaryMuscles: known?.secondaryMuscles ?? [],
                                    targetSets: item.targetSets, restSec: item.restSec,
                                    targetRepsLow: item.targetRepsLow, targetRepsHigh: item.targetRepsHigh,
                                    targetRpe: item.targetRpe, targetWeightKg: item.targetWeightKg,
                                    note: item.note, programItemId: item.id)
            }
            session.start(plan: plan, programId: program.id, programName: program.name)
            if stage != .warmup {
                // Overhead press first (the bench was taken), then two bench sets.
                for set in 1...3 {
                    session.start(LiftSlot(exerciseIndex: 1, setIndex: set))
                    session.updateSet(LiftSlot(exerciseIndex: 1, setIndex: set), weightKg: 42.5, reps: 8,
                                      rpe: nil, isWarmup: false)
                    session.advance()
                }
                for set in 1...2 {
                    session.start(LiftSlot(exerciseIndex: 0, setIndex: set))
                    session.updateSet(LiftSlot(exerciseIndex: 0, setIndex: set), weightKg: 80, reps: 5,
                                      rpe: Double(6 + set), isWarmup: false)
                    session.advance()
                }
                if stage == .working { session.advance() }
            }
            session.isPresented = !minimised
            ready = true
        }
    }
}

/// DEBUG-only lift log seed: three programs and a few weeks of sessions, written once under fixed ids so
/// a relaunch does not duplicate them.
@MainActor
enum LiftDemoSeed {
    static let pushId = "demo-lift-push-a"
    static let pullId = "demo-lift-pull-a"
    static let legsId = "demo-lift-legs"

    private struct Line {
        let name: String
        let primary: LiftMuscle
        var secondary: [LiftMuscle] = []
        let sets: Int
        let reps: Int
        let kg: Double
        var rest = 120
    }

    private static let programs: [(id: String, name: String, lines: [Line])] = [
        (pushId, "Push A", [
            Line(name: "Bench press", primary: .chest, secondary: [.frontDelts, .triceps], sets: 4, reps: 5, kg: 80),
            Line(name: "Overhead press", primary: .frontDelts, secondary: [.triceps], sets: 3, reps: 8, kg: 42.5),
            Line(name: "Incline press", primary: .chest, secondary: [.frontDelts], sets: 3, reps: 10, kg: 26, rest: 90),
            Line(name: "Dips", primary: .triceps, secondary: [.chest], sets: 3, reps: 10, kg: 0, rest: 90),
            Line(name: "Lateral raises", primary: .sideDelts, sets: 3, reps: 15, kg: 10, rest: 60),
            Line(name: "Pushdown", primary: .triceps, sets: 3, reps: 12, kg: 30, rest: 60),
        ]),
        (pullId, "Pull A", [
            Line(name: "Barbell row", primary: .upperBack, secondary: [.lats, .biceps], sets: 4, reps: 8, kg: 70),
            Line(name: "Pull-ups", primary: .lats, secondary: [.biceps], sets: 4, reps: 8, kg: 0),
            Line(name: "Face pulls", primary: .rearDelts, sets: 3, reps: 15, kg: 20, rest: 60),
            Line(name: "Curls", primary: .biceps, sets: 3, reps: 12, kg: 14, rest: 60),
            Line(name: "Shrugs", primary: .traps, sets: 3, reps: 12, kg: 60, rest: 60),
        ]),
        (legsId, "Legs", [
            Line(name: "Squat", primary: .quads, secondary: [.glutes], sets: 5, reps: 5, kg: 105, rest: 180),
            Line(name: "Romanian deadlift", primary: .hamstrings, secondary: [.glutes, .lowerBack], sets: 3, reps: 8, kg: 90),
            Line(name: "Lunges", primary: .quads, secondary: [.glutes], sets: 3, reps: 10, kg: 20, rest: 90),
            Line(name: "Leg curl", primary: .hamstrings, sets: 3, reps: 12, kg: 40, rest: 60),
            Line(name: "Calf raises", primary: .calves, sets: 3, reps: 15, kg: 60, rest: 60),
            Line(name: "Hanging leg raise", primary: .abs, sets: 3, reps: 12, kg: 0, rest: 60),
        ]),
    ]

    /// Days ago each session ran, by program, newest first; a session lasts about 45 minutes.
    private static let sessions: [(program: Int, daysAgo: Int, minutes: Int)] = [
        (0, 2, 46), (1, 5, 44), (2, 6, 52), (0, 9, 48), (1, 12, 45), (2, 13, 55), (0, 16, 47), (1, 19, 43),
    ]

    static func seed(_ repo: Repository) async {
        guard let store = await repo.storeHandle() else { return }
        let device = repo.deviceId
        if let existing = try? await store.liftPrograms(deviceId: device), existing.contains(where: { $0.id == pushId }) {
            return
        }
        let now = Int(Date().timeIntervalSince1970)
        let today = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        var vocab: [LiftExerciseRow] = []
        for (pi, program) in programs.enumerated() {
            let row = LiftProgramRow(id: program.id, deviceId: device, name: program.name, note: nil,
                                     createdAt: now - 60 * 86_400, updatedAt: now - pi * 3_600, archived: false)
            _ = try? await store.upsertLiftPrograms([row])
            let items = program.lines.enumerated().map { ord, line in
                LiftProgramItemRow(id: "\(program.id)-\(ord)", deviceId: device, programId: program.id, ord: ord,
                                   exercise: line.name, targetSets: line.sets, targetRepsLow: line.reps,
                                   targetRepsHigh: line.reps, targetRpe: nil,
                                   targetWeightKg: line.kg > 0 ? line.kg : nil, restSec: line.rest, note: nil)
            }
            _ = try? await store.replaceLiftProgramItems(programId: program.id, items: items)
            vocab += program.lines.map {
                LiftExerciseRow(id: "demo-lift-ex-\($0.name)", deviceId: device, name: $0.name,
                                primaryMuscle: $0.primary, secondaryMuscles: $0.secondary,
                                createdAt: now - 60 * 86_400, lastUsedTs: now - 2 * 86_400)
            }
        }
        _ = try? await store.upsertLiftExercises(vocab)

        for (si, s) in sessions.enumerated() {
            let program = programs[s.program]
            let start = today - s.daysAgo * 86_400 + 18 * 3_600
            let id = "demo-lift-session-\(si)"
            _ = try? await store.upsertLiftSessions([
                LiftSessionRow(id: id, deviceId: device, startTs: start, endTs: start + s.minutes * 60,
                               sport: LiftSessionView.sport, programId: program.id, programName: program.name,
                               sessionRpe: 7, note: program.name),
            ])
            // Older sessions a little lighter, so the newest top set reads as progress.
            let older = Double(s.daysAgo / 7) * 2.5
            var sets: [LiftSetRow] = []
            var ord = 0
            for line in program.lines {
                for set in 1...line.sets {
                    let kg = line.kg > 0 ? max(0, line.kg - older) : nil
                    sets.append(LiftSetRow(
                        id: "\(id)-\(ord)", deviceId: device, sessionId: id, ord: ord, exercise: line.name,
                        primaryMuscle: line.primary, secondaryMuscles: line.secondary, setIndex: set,
                        weightKg: kg, reps: set == line.sets ? line.reps - 1 : line.reps, rpe: nil,
                        isWarmup: false, startTs: start + ord * 150, endTs: start + ord * 150 + 40,
                        restSec: line.rest, note: nil))
                    ord += 1
                }
            }
            _ = try? await store.upsertLiftSets(sets)
        }
        await repo.refresh()
    }
}
#endif
