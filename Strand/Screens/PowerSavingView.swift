import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Power saving (#477)
//
// Lifted out of Settings into its own screen: on iPhone it is a first-class More row (between Test
// Centre and Settings) and on macOS its own sidebar item, so the strap-battery levers are one tap away
// instead of buried in the middle of the Settings scroll. The controls, their prefs and their wiring are
// UNCHANGED — `AppModel.applyPowerSaving()` still reads every value from `PuffinExperiment`, so moving
// the surface cannot alter behaviour.
//
// The master gates the sub-options: the threshold slider, "Pause HRV capture" and "Low refresh" only
// apply while Power saving is on — `applyPowerSaving` ANDs each one with the master — so they stay
// visible but disabled while it is off.
struct PowerSavingView: View {
    @EnvironmentObject var model: AppModel

    @AppStorage(PuffinExperiment.powerSavingKey) private var powerSavingEnabled = false
    @AppStorage(PuffinExperiment.powerSavingBatteryPctKey) private var powerSavingPct = 20
    /// Stored INVERTED so the default (absent = false) reads as "HRV pause on". The toggle shows `!this`.
    @AppStorage(PuffinExperiment.pauseHrvDisabledKey) private var pauseHrvDisabled = false
    @AppStorage(PuffinExperiment.lowRefreshKey) private var lowRefreshEnabled = false

    /// The header's info button shows how power saving works.
    @State private var showsInfo = false

    var body: some View {
        ScreenScaffold(title: nil) {
            NoopScreenHeader("Power saving") {
                NoopCircleButton("info", accessibilityLabel: "How power saving works") {
                    withAnimation(StrandMotion.interactive) { showsInfo.toggle() }
                }
            }
            .padding(.bottom, 6)
            if showsInfo {
                NoopInsightRow("The strap keeps banking data on its own, so nothing is lost — NOOP just talks to it less often to help it last until you can charge it.",
                               icon: "info")
                    .padding(.horizontal, 4)
                    .padding(.bottom, 6)
            }
            PowerSavingBatteryHero(threshold: powerSavingPct, savingOn: powerSavingEnabled,
                                   deviceName: model.deviceRegistry?.devices.first { $0.status == .active }?.displayName)
            masterCard
            NoopSectionTitle("While it's on", caption: String(localized: "Pick what to give up"))
            optionsCard
            PowerSavingProjection(threshold: powerSavingPct)
        }
        .noopHidesSystemNavBar()
    }

    private var masterCard: some View {
        NoopList {
            Toggle(isOn: $powerSavingEnabled) {
                HStack(alignment: .top, spacing: 14) {
                    G6IconTile(icon: "leaf", size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Power saving mode")
                            .font(StrandFont.book(15, relativeTo: .body))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Slows background strap-sync (every 45 min instead of 15) while your strap's battery is low. No data loss — the strap banks everything, so sync just batches into larger, less frequent pulls.")
                            .font(StrandFont.light(12.5, relativeTo: .caption))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(.noop)
            .onChangeCompat(of: powerSavingEnabled) { _ in model.applyPowerSaving() }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            G6Block("Kick in at (strap battery)", caption: Text(verbatim: "\(powerSavingPct) %")) {
                VStack(spacing: 6) {
                    // 10…35 in 5s. 35 buys one more step of strap life than the old 30 ceiling: the levers
                    // engage ~5% earlier in the discharge, at the cost of a slightly longer stretch of
                    // quieter syncing.
                    Slider(
                        value: Binding(get: { Double(powerSavingPct) }, set: { powerSavingPct = Int($0) }),
                        in: 10...35, step: 5,
                        onEditingChanged: { editing in if !editing { model.applyPowerSaving() } }
                    )
                    .tint(StrandPalette.textPrimary)
                    .accessibilityLabel("Kick in at (strap battery)")
                    HStack {
                        Text(verbatim: "10 %")
                        Spacer()
                        Text(verbatim: "35 %")
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .disabled(!powerSavingEnabled)
            .opacity(powerSavingEnabled ? 1 : 0.45)
        }
    }

    private var optionsCard: some View {
        NoopList {
            // HRV pause: a sub-option, ON by default when the master is on (stored inverted).
            optionRow(icon: "heartbeat", title: "Pause HRV capture",
                      detail: "While your strap's battery is low, stop the always-on background HRV stream — the biggest continuous drain on the strap. A Live screen still shows heart rate, and it re-arms automatically once the strap is charged.",
                      isOn: Binding(get: { !pauseHrvDisabled }, set: { pauseHrvDisabled = !$0 }))
                .onChangeCompat(of: pauseHrvDisabled) { _ in model.applyPowerSaving() }
            // Low refresh: a sub-option that applies at ANY charge, not just below the threshold.
            optionRow(icon: "timer", title: "Low refresh",
                      detail: "Sync in the background every hour instead of every 15 minutes, whatever the strap's charge — fewer reconnections is the biggest saving on a WHOOP 4.0. Nothing is lost: the strap banks everything and hands it over in larger batches. Pull to sync still runs straight away, and live heart rate is untouched.",
                      isOn: $lowRefreshEnabled)
                .onChangeCompat(of: lowRefreshEnabled) { _ in model.applyPowerSaving() }
        }
        .disabled(!powerSavingEnabled)
        .opacity(powerSavingEnabled ? 1 : 0.45)
    }

    private func optionRow(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey,
                           isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(alignment: .top, spacing: 14) {
                G6IconTile(icon: icon, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(detail)
                        .font(StrandFont.light(12.5, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.noop)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

// MARK: - Battery hero

/// The strap battery: the live charge in the dot face, the runtime estimate, a 0–100 scale with the
/// power-saving threshold and the current charge marked, and the drain figures the estimate implies.
/// Its own view holding `LiveState`, so a strap tick re-renders the hero only.
private struct PowerSavingBatteryHero: View {
    @EnvironmentObject private var live: LiveState
    let threshold: Int
    let savingOn: Bool
    let deviceName: String?

    /// The strap's charge only while it is the connected active device (#2208).
    private var pct: Int? {
        guard live.connected, live.activeIsWhoop, let p = live.batteryPct else { return nil }
        return Int(p.rounded())
    }

    private var estimate: BatteryEstimator.Estimate? {
        guard pct != nil, live.charging != true, let e = live.batteryEstimate,
              e.hoursRemaining.isFinite, e.hoursRemaining > 0 else { return nil }
        return e
    }

    var body: some View {
        NoopHeroCard(glow: .ink, padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    NoopIconBadge("Strap battery", icon: "battery-high")
                    Spacer(minLength: 8)
                    if let deviceName { NoopPill(verbatim: deviceName, compact: true) }
                }
                NoopDotNumber(pct.map { "\($0)" } ?? "--", unit: pct == nil ? nil : "%", size: 96, unitSize: 40)
                    .padding(.top, 26)
                Group {
                    if live.charging == true {
                        Text("Charging")
                    } else if let estimate {
                        Text(verbatim: Self.runtimeLabel(estimate.hoursRemaining))
                    } else {
                        Text(pct == nil ? "Strap not connected" : "Estimating runtime…")
                    }
                }
                .font(StrandFont.light(16, relativeTo: .body))
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.top, 14)
                scale
                    .padding(.top, 22)
                HStack(alignment: .top, spacing: 0) {
                    G6HeroMetric(value: drainRate.map { String(format: "%.1f", $0) } ?? "—", unit: "% / h",
                                 label: Text("Drain rate"))
                    G6HeroMetric(value: savingOn ? "\(threshold)" : "—", unit: savingOn ? "%" : nil,
                                 label: Text("Saving kicks in"))
                    G6HeroMetric(value: emptyBy ?? "—", label: Text("Recharge by"))
                }
                .padding(.top, 22)
            }
            .padding(.top, 20)
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
    }

    /// Charge per hour implied by the estimate: the current charge spread over the hours left.
    private var drainRate: Double? {
        guard let estimate else { return nil }
        return estimate.currentSoc / estimate.hoursRemaining
    }

    /// When the strap reaches empty at the estimated pace ("Tue 09:40").
    private var emptyBy: String? {
        guard let estimate else { return nil }
        let date = Date().addingTimeInterval(estimate.hoursRemaining * 3600)
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func runtimeLabel(_ hours: Double) -> String {
        if hours < 48 { return String(localized: "~\(Int(hours.rounded()))h left") }
        let days = Int((hours / 24).rounded())
        return days == 1 ? String(localized: "~1 day left") : String(localized: "~\(days) days left")
    }

    /// Empty → Full ticks with the threshold (dashed) and the current charge (glowing) marked.
    private var scale: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Empty")
                Spacer()
                if savingOn { Text("Saving kicks in at \(threshold) %") }
                Spacer()
                Text("Full")
            }
            .font(StrandFont.light(10.5))
            .foregroundStyle(Color.white.opacity(0.55))
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    NoopTickScale(marker: pct.map { Double($0) / 100 }, height: 26)
                    if savingOn {
                        Path { p in
                            p.move(to: CGPoint(x: w * CGFloat(threshold) / 100, y: -4))
                            p.addLine(to: CGPoint(x: w * CGFloat(threshold) / 100, y: 30))
                        }
                        .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                }
            }
            .frame(height: 26)
            HStack {
                Text(verbatim: "0")
                Spacer()
                Text(verbatim: "50")
                Spacer()
                Text(verbatim: "100")
            }
            .font(StrandFont.light(10.5))
            .foregroundStyle(Color.white.opacity(0.45))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Battery scale"))
    }
}

// MARK: - Projection

/// The charge projected forward at the estimated pace, down to empty, with the threshold line. Shown
/// only once the estimator has a runtime to project.
private struct PowerSavingProjection: View {
    @EnvironmentObject private var live: LiveState
    let threshold: Int

    var body: some View {
        if live.connected, live.activeIsWhoop, live.charging != true, let e = live.batteryEstimate,
           e.hoursRemaining.isFinite, e.hoursRemaining > 0 {
            NoopSectionTitle("Projected battery", caption: String(localized: "At the current pace"))
            NoopCard {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack(alignment: .topLeading) {
                        NoopAreaChart(values: Self.series(soc: e.currentSoc, hours: e.hoursRemaining),
                                      range: 0...100, line: StrandPalette.metricCyan, fill: StrandPalette.effortColor,
                                      cursor: 0)
                        GeometryReader { geo in
                            Path { p in
                                let y = geo.size.height * (1 - CGFloat(threshold) / 100)
                                p.move(to: CGPoint(x: 0, y: y))
                                p.addLine(to: CGPoint(x: geo.size.width, y: y))
                            }
                            .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        }
                    }
                    .frame(height: 110)
                    HStack {
                        Text("Now")
                        Spacer()
                        Text(verbatim: Date().addingTimeInterval(e.hoursRemaining * 3600)
                            .formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    G6Footnote(text: Text("At today's pace: \(PowerSavingBatteryHero.runtimeLabel(e.hoursRemaining)). The dotted line marks where power saving kicks in."))
                }
            }
        }
    }

    /// A straight line from the current charge to empty, sampled for the chart.
    static func series(soc: Double, hours: Double) -> [Double] {
        (0...24).map { i in soc * (1 - Double(i) / 24) }
    }
}
