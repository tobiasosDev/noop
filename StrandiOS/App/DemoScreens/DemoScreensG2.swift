#if DEBUG
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

extension DemoScreensV2 {
    /// Group 2 demo screens for `--demo-screen <name>` (lowercase names).
    static func group2(_ name: String) -> AnyView? {
        switch name {
        // Long screens: a window further down than the `center` anchor reaches.
        case "trends-mid": return AnyView(G2OffsetHost(offset: 760) { TrendsView() })
        case "trends-low": return AnyView(G2OffsetHost(offset: 1500) { TrendsView() })
        case "trends-report": return AnyView(G2SheetHost { TrendsView() } sheet: { G2TrendsReport() })
        case "alarms": return AnyView(SmartAlarmView())
        case "alarms-low": return AnyView(G2OffsetHost(offset: 700) { SmartAlarmView() })
        case "sleep-mid": return AnyView(G2OffsetHost(offset: 760) { SleepView() })
        case "sleep-low": return AnyView(G2OffsetHost(offset: 1500) { SleepView() })
        case "sleep-cards": return AnyView(G2SleepCardsHost(offset: 0))
        case "sleep-cards-mid": return AnyView(G2SleepCardsHost(offset: 760))
        case "sleep-cards-low": return AnyView(G2SleepCardsHost(offset: 1520))
        case "sleep-bodyclock": return AnyView(G2BodyClockHost())
        case "sleep-hrchart": return AnyView(G2HRChartHost())
        default: return nil
        }
    }
}

/// A screen with one of its sheets presented over it, as the wearer sees it.
private struct G2SheetHost<Base: View, Sheet: View>: View {
    @ViewBuilder var base: () -> Base
    @ViewBuilder var sheet: () -> Sheet
    @State private var shown = false
    var body: some View {
        base()
            .sheet(isPresented: $shown) { sheet() }
            .task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                shown = true
            }
    }
}

private struct G2TrendsReport: View {
    @EnvironmentObject var repo: Repository
    var body: some View { TrendsReportSheet(days: repo.days) }
}

/// The Sleep tab's analytical cards alone, stacked in the order the v2 frames show them, built from the
/// same `SleepModel` the tab builds — so the cards can be compared with their frames while the tab itself
/// is being reworked.
private struct G2SleepCardsHost: View {
    @EnvironmentObject var repo: Repository
    let offset: CGFloat
    var body: some View {
        let model = SleepModel.build(SleepModelInputs(
            days: repo.days, sleeps: repo.sleeps, allSessions: [], importedSleep: repo.importedSleep,
            habitualMidsleepSec: nil, motionByStart: [:]))
        G2OffsetHost(offset: offset) {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    if let model {
                        SleepDebtLedgerCard(model: model)
                        BodyClockDialSection(
                            actualBedHour: SleepView.localClockHour(model.night.session.effectiveStartTs),
                            actualWakeHour: SleepView.localClockHour(model.night.session.endTs))
                        NightDetailCard(model: model)
                        StagesVsTypicalCard(model: model)
                        AsleepDurationCard(data: AsleepDurationData(points: model.trendPoints,
                                                                    typicalTotalMin: model.typicalTotalMin,
                                                                    needMin: model.sleepDebtLedger.needMin))
                        HoursVsNeededCard(model: model)
                        ConsistencyCard(model: model)
                    } else {
                        Text(verbatim: "No sleep model yet")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 120)
            }
        }
    }
}

/// The body-clock card with a fixed phase estimate (the demo seed computes none), so the dial can be
/// compared with its frame.
private struct G2BodyClockHost: View {
    var body: some View {
        ScrollView {
            BodyClockDialCard(estimate: CircadianEngine.PhaseEstimate(tempMinHour: 3.5, acrophaseHours: 15,
                                                                      offsetVsScheduleMinutes: 0,
                                                                      confidence: .solid, note: ""),
                              actualBedHour: 22.53, actualWakeHour: 6.27)
                .padding(.horizontal, 20)
                .padding(.top, 60)
        }
    }
}

/// The overnight heart-rate chart over a synthetic night (the demo seed stores no overnight HR), so the
/// chart's drawing can be compared with its frame.
private struct G2HRChartHost: View {
    var body: some View {
        let start = Date().addingTimeInterval(-9 * 3600)
        let span: TimeInterval = 7.7 * 3600
        let intervals = [
            SleepInterval(stage: .light, start: 0, end: 3000),
            SleepInterval(stage: .deep, start: 3000, end: 7200),
            SleepInterval(stage: .light, start: 7200, end: 12000),
            SleepInterval(stage: .rem, start: 12000, end: 14000),
            SleepInterval(stage: .deep, start: 14000, end: 16000),
            SleepInterval(stage: .light, start: 16000, end: 24000),
            SleepInterval(stage: .rem, start: 24000, end: span),
        ]
        let buckets: [HRBucket] = stride(from: 0, to: Int(span), by: 60).map { t in
            let x = Double(t) / span
            let bpm = 58 - 12 * sin(x * .pi) + 3 * sin(Double(t) / 700)
            return HRBucket(ts: Int(start.timeIntervalSince1970) + t, bpm: bpm, minBpm: bpm - 1, maxBpm: bpm + 1)
        }
        return SleepNightHRChart(buckets: buckets, intervals: intervals, origin: 0, span: span,
                                 nightStart: start, selectedStage: nil)
            .padding(.horizontal, 20)
            .padding(.top, 80)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Renders a screen taller than the display and shifted up, so a band below the first screenful can be
/// captured with the `top` anchor.
private struct G2OffsetHost<Content: View>: View {
    let offset: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View {
        GeometryReader { geo in
            content()
                .frame(width: geo.size.width, height: geo.size.height + offset)
                .offset(y: -offset)
        }
        .ignoresSafeArea(edges: .bottom)
    }
}
#endif
