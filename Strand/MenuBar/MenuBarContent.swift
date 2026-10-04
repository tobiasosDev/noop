import SwiftUI
import Foundation
import StrandDesign
import WhoopStore
import StrandAnalytics

// MARK: - Menu-Bar Extra (NOOP)
//
// A glanceable presence in the macOS menu bar. The label shows a tiny heart-dot
// tinted by the current HR zone plus the live HR (or "—" when not streaming).
// The popover gives the v2 score card (Charge / Effort / Rest rings, the live HR, the
// strap battery), the overnight vitals, and a small action area to start/stop the live
// feed or reconnect.
//
// The MenuBarExtra Scene itself is wired in StrandApp centrally; this file only
// supplies the two content views.

// MARK: - Label

/// The compact menu-bar item: a zone-tinted dot + the live HR number.
public struct MenuBarLabel: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var model: AppModel

    public init() {}

    /// HR to display: the spike-filtered median (model.bpm, #39) when available, else reported, else R-R.
    private var displayHR: Int? {
        if let hr = model.bpm, hr > 0 { return hr }
        if let hr = live.heartRate, hr > 0 { return hr }
        if let last = live.rr.last, last > 0 { return Int((60_000.0 / Double(last)).rounded()) }
        return nil
    }

    // A glanceable HR-zone estimate using a typical adult max (~190 bpm). The full
    // profile-aware zoning lives on the main screens; the menu bar only needs a tint.
    private let assumedHrMax: Double = 190

    /// HR zone 1...5 from %max, or nil when there's no live reading.
    private var zone: Int? {
        guard let hr = displayHR else { return nil }
        let pct = Double(hr) / assumedHrMax
        switch pct {
        case ..<0.60: return 1
        case ..<0.70: return 2
        case ..<0.80: return 3
        case ..<0.90: return 4
        default:      return 5
        }
    }

    private var dotColor: Color {
        guard live.connected else { return StrandPalette.textTertiary }
        if let zone { return StrandPalette.hrZoneColor(zone) }
        return StrandPalette.statusPositive
    }

    public var body: some View {
        HStack(spacing: 4) {
            // The menu bar renders only plain images and text in a status item, so the heart stays an SF
            // Symbol here; the number takes the kit's sans.
            Image(systemName: live.connected ? "heart.fill" : "heart")
                .font(StrandFont.medium(11))
                .foregroundStyle(dotColor)
            Text(verbatim: displayHR.map(String.init) ?? "—")
                .font(StrandFont.medium(12))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayHR.map { "Heart rate \($0) beats per minute" } ?? "Strap not connected")
    }
}

// MARK: - Popover content

/// The popover shown when the menu-bar item is clicked: the v2 score card (the Widgets board's Medium
/// layout, lit by the Charge band), the overnight vitals, the honest sync line and the strap actions.
public struct MenuBarContent: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var model: AppModel
    /// The menu-bar popover is a SEPARATE scene from the main window, so it doesn't inherit the
    /// window's appearance — drive it from the same setting directly.
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.defaultMode.rawValue
    /// #313: the Effort ring reads on the user's chosen scale, like every other Effort read-out.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    /// Today's Rest (`sleep_performance`), read when the popover opens; nil until then or with no score.
    @State private var rest: Double?

    public init() {}

    // MARK: Derived values

    private var displayHR: Int? {
        if let hr = model.bpm, hr > 0 { return hr }        // #39: spike-filtered median, not raw
        if let hr = live.heartRate, hr > 0 { return hr }
        if let last = live.rr.last, last > 0 { return Int((60_000.0 / Double(last)).rounded()) }
        return nil
    }

    private var recovery: Double? { repo.today?.recovery }

    /// True when HR is actively streaming. A live Oura ring has no WHOOP-style encrypted bond, so it
    /// signals via `streamingLiveHR`; the WHOOP path still keys off `bonded` (its encrypted-bond + buzz
    /// semantics). Either one being true means HR is actively streaming.
    private var isStreaming: Bool { live.streamingLiveHR || live.bonded }

    private var link: MenuBarScoreSnapshot.Link {
        isStreaming ? .streaming : live.connected ? .connected : .offline
    }

    /// #2208: the strap's charge, or nil when it is not the active device's to report. This surface read
    /// `live.batteryPct` with NO gate, so it showed the strap's last percentage with nothing connected and
    /// under an active ring alike.
    private var strapBatteryPct: Double? {
        (live.connected && live.activeIsWhoop) ? live.batteryPct : nil
    }

    private var snapshot: MenuBarScoreSnapshot {
        let strain = repo.today?.strain
        let scale = UnitPrefs.resolveEffortScale(effortScaleRaw)
        return MenuBarScoreSnapshot(
            dateText: Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
                .locale(AppLanguage.activeLocale)),
            link: link,
            charge: recovery,
            // Stored Effort is on NOOP's 0–100 axis; the fill is scale-independent, the number is not.
            effortFraction: strain.map { $0 / StrainScorer.maxStrain },
            effortText: strain.map { UnitFormatter.effortDisplay($0, scale: scale) },
            rest: rest,
            liveHR: displayHR,
            strapBattery: strapBatteryPct
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MenuBarScoreCard(snapshot: snapshot)
            vitalsRow
            syncLine
            actions
        }
        .padding(14)
        .frame(width: 340)
        .background(NoopSheetBackground())
        .preferredColorScheme(AppearanceMode.resolve(appearanceRaw).colorScheme)
        // Rest is a merged series read rather than a column on today's row, so it loads here: the same
        // `sleep_performance` series and freshness rule the Today Rest ring uses, for today's row.
        .task(id: "\(repo.refreshSeq)|\(repo.today?.day ?? "")") { await loadRest() }
    }

    private func loadRest() async {
        guard let day = repo.today?.day else { rest = nil; return }
        let series = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        let byDay = Dictionary(series.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        rest = TodayView.freshRestScore(todayValue: byDay[day], lastDay: series.last?.day,
                                        lastValue: series.last?.value, isTodaySelected: true, todayKey: day)
    }

    // MARK: Vitals

    /// Today's resting heart rate and HRV as a v2 metric row (the strap's charge moved into the card).
    private var vitalsRow: some View {
        let rhr = repo.today?.restingHr
        let hrv = repo.today?.avgHrv
        return NoopMetricRow {
            NoopMetric(value: rhr.map { "\($0)" } ?? "—", unit: rhr == nil ? nil : "bpm",
                       labelText: String(localized: "Resting heart rate"))
            NoopMetric(value: hrv.map { "\(Int($0.rounded()))" } ?? "—", unit: hrv == nil ? nil : "ms",
                       labelText: String(localized: "Heart rate variability"))
        }
        .padding(.horizontal, 4)
    }

    // MARK: Sync status

    /// Honest sync line (ports the Android Live line, ed6a31d): a pulsing note while an offload runs,
    /// the stalled-offload error if the last one died, else "History synced N ago". The popover body
    /// is rebuilt on every open, so the relative label is fresh without a timer.
    ///
    /// The slot always reserves its height, even with nothing to say (never synced, no error): the
    /// MenuBarExtra panel animates every height change, so the note<->text<->empty swaps (sync state
    /// lands right after first layout; `backfilling` toggles per offload chunk) made the popover
    /// visibly slide into place from the corner on open and bounce while open. Pinning a constant
    /// 24pt height stops the panel resizing under those swaps. A rare multi-line error may still grow it.
    private var syncLine: some View {
        ZStack(alignment: .leading) {
            if live.backfilling {
                HStack(spacing: 8) {
                    SyncPulseDot()
                    Text("Syncing strap history…")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            } else if let error = live.lastSyncError {
                HStack(alignment: .top, spacing: 6) {
                    PhIcon("warning-circle", size: 13)
                        .foregroundStyle(StrandPalette.statusWarning)
                    Text(error)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let at = live.lastSyncedAt {
                Text("History synced \(relativeAgo(at))")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 24, alignment: .leading)
    }

    // MARK: Actions

    /// The one primary action as the ink pill (start/stop the feed, or scan), the strap chores as quiet
    /// pills beneath it.
    private var actions: some View {
        VStack(spacing: 8) {
            if live.bonded {
                menuButton(live.liveFeedActive ? "Stop live feed" : "Start live feed",
                           icon: live.liveFeedActive ? "pause" : "play", iconWeight: .fill, primary: true) {
                    if live.liveFeedActive { model.stopRealtimeHR() } else { model.startRealtimeHR() }
                }
            } else {
                menuButton(live.connected ? "Re-scan strap" : "Scan & connect",
                           icon: "bluetooth", primary: true) {
                    model.scan()
                }
            }

            HStack(spacing: 8) {
                menuButton("Refresh battery", icon: "battery-high") {
                    model.getBattery()
                }
                if live.connected {
                    menuButton("Disconnect", icon: "link-break") {
                        model.disconnect()
                    }
                }
            }
        }
    }

    private func menuButton(
        _ title: LocalizedStringKey,
        icon: String,
        iconWeight: PhosphorWeight = .light,
        primary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                PhIcon(icon, weight: iconWeight, size: 14)
                Text(title)
            }
        }
        .buttonStyle(MenuBarPillButtonStyle(primary: primary))
        .accessibilityLabel(Text(title))
    }
}

/// The syncing note's dot: an ink dot with an expanding ring, held still when motion should be quiet.
private struct SyncPulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode / "Reduce motion in NOOP": a never-settling loop belongs behind the same gate as the
    /// other ambient motion.
    @ObservedObject private var motion = NoopMotionState.shared
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(StrandPalette.textPrimary, lineWidth: 1.5)
                .frame(width: 7, height: 7)
                .scaleEffect(pulsing ? 2.4 : 1)
                .opacity(pulsing ? 0 : 0.8)
            Circle().fill(StrandPalette.textPrimary).frame(width: 7, height: 7)
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
        .onAppear {
            guard !motion.poseStill(reduceMotion) else { return }
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulsing = true }
        }
    }
}

#if DEBUG
private extension DailyMetric {
    static func sample(recovery: Double, restingHr: Int, hrv: Double) -> DailyMetric {
        DailyMetric(
            day: "2026-06-06",
            totalSleepMin: 452, efficiency: 92, deepMin: 96, remMin: 110, lightMin: 240,
            disturbances: 7, restingHr: restingHr, avgHrv: hrv, recovery: recovery,
            strain: 12.4, exerciseCount: 1, spo2Pct: 97, skinTempDevC: 0.2, respRateBpm: 14.6
        )
    }
}

@MainActor
private func previewEnv(
    connected: Bool,
    bonded: Bool,
    hr: Int?,
    battery: Double?,
    metric: DailyMetric?
) -> (Repository, LiveState, AppModel) {
    let repo = Repository(deviceId: "preview")
    if let metric { repo.days = [metric] }
    repo.loaded = true
    let model = AppModel()
    let live = model.live
    live.connected = connected
    live.bonded = bonded
    live.heartRate = hr
    live.batteryPct = battery
    return (repo, live, model)
}

#Preview("Label — zones") {
    let (repo, live, model) = previewEnv(
        connected: true, bonded: true, hr: 148, battery: 78,
        metric: .sample(recovery: 71, restingHr: 51, hrv: 62)
    )
    return HStack(spacing: 20) {
        MenuBarLabel()
        MenuBarLabel()
    }
    .padding(24)
    .background(StrandPalette.surfaceBase)
    .environmentObject(repo)
    .environmentObject(live)
    .environmentObject(model)
    .preferredColorScheme(.dark)
}

#Preview("Popover — streaming") {
    let (repo, live, model) = previewEnv(
        connected: true, bonded: true, hr: 132, battery: 78,
        metric: .sample(recovery: 71, restingHr: 51, hrv: 62)
    )
    return MenuBarContent()
        .environmentObject(repo)
        .environmentObject(live)
        .environmentObject(model)
}

#Preview("Popover — offline / no data") {
    let (repo, live, model) = previewEnv(
        connected: false, bonded: false, hr: nil, battery: nil, metric: nil
    )
    return MenuBarContent()
        .environmentObject(repo)
        .environmentObject(live)
        .environmentObject(model)
}
#endif
