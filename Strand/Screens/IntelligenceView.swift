import SwiftUI
import StrandDesign
import StrandAnalytics

/// Intelligence — NOOP's own recovery/strain/sleep scores, computed on-device from raw strap data
/// using the WHOOP model shape. Makes the app independent of WHOOP's cloud for live-collected days.
///
/// i18n: the By-Day core labels (Effort/Charge/Rest/HRV/RHR) and the Charge-model "Effort" heading are
/// looked up via `String(localized:)` so non-English locales (e.g. German, issue #1020) actually
/// translate them instead of rendering the English literal. pt-PT catalog strings adopted from
/// tigercraft4's PR #1018 (marked needs_review — machine ES→PT conversion pending native review).
struct IntelligenceView: View {
    @EnvironmentObject var intelligence: IntelligenceEngine
    // NOTE: IntelligenceView deliberately does NOT observe `LiveState`. A connected strap publishes at
    // ~1 Hz, which would re-evaluate this body (and its lazy By-Day list) on every tick. The only live
    // dependency — the "Syncing strap history…" note shown over the empty state — owns its OWN
    // `@EnvironmentObject var live` in the `IntelSyncingNote` leaf below (mirrors the Today/Sleep
    // leaf-scoping pattern), so a tick refreshes only that note.

    @State private var range: IntelRange = .month
    /// Recent table (the last week at a glance) or the per-day cards with their drivers.
    @State private var mode: ScoresMode = .recent
    @State private var showHowItWorks = false

    // Effort display scale (#268) — routes every Effort value/label on this screen. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    var body: some View {
        // `lazy` so the trailing By-Day `ForEach` renders day cards on demand. With an 800+ day
        // imported history, an eager VStack built every card up-front on the main thread and froze
        // the app when ALL was tapped (#345); LazyVStack only materialises what's on screen.
        ScreenScaffold(title: nil, lazy: true) {
            NoopScreenHeader(verbatim: "") {
                NoopCircleButton("arrows-clockwise", accessibilityLabel: "Recompute") {
                    Task { await intelligence.analyzeRecent() }
                }
                .disabled(intelligence.computing)
                .opacity(intelligence.computing ? 0.45 : 1)
            }
            .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 6) {
                Text("Intelligence")
                    .font(StrandFont.title1)
                    .tracking(-0.56)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("NOOP scores your charge, effort and rest itself: on-device, no cloud.")
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 8)
            if let f = forecast { forecastHero(f) }
            scoresSection
            chargeModelSection
        }
        .noopHidesSystemNavBar()
        .task { if intelligence.results.isEmpty { await intelligence.analyzeRecent() } }
        .sheet(isPresented: $showHowItWorks) {
            HowNoopWorksView(onClose: { showHowItWorks = false })
        }
    }

    /// The day list narrowed to the selected window. `nil` cutoff (ALL) shows everything.
    private var filtered: [IntelligenceEngine.Computed] {
        guard let n = range.days else { return intelligence.results }
        let date = Calendar.current.date(byAdding: .day, value: -(n - 1), to: Date()) ?? Date()
        let cutoff = Self.dayFmt.string(from: date)
        return intelligence.results.filter { $0.day >= cutoff }
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Evening forecast of tomorrow-morning Charge from tonight's known levers. Anchored to
    /// the recent Charge baseline, nudged by today's Effort vs your norm and how much sleep
    /// you typically bank, then mean-reverted. `results` is newest-first; the forecaster wants
    /// oldest→newest, so each series is reversed. `nil` (and the card hidden) until there are
    /// enough scored nights to anchor honestly — never a fabricated number.
    private var forecast: RecoveryForecast? {
        let charge = intelligence.results.compactMap { $0.recovery }.reversed()
        let effort = intelligence.results.compactMap { $0.strain }.reversed()
        // Planned sleep tonight = the recent typical night (the honest "if you sleep ~Xh"
        // assumption surfaced in the card), from the scored nights that have a sleep total.
        let sleeps = intelligence.results.compactMap { $0.sleepMin }
        let plannedHours = sleeps.isEmpty ? RecoveryForecaster.defaultNeedHours
            : (sleeps.reduce(0, +) / Double(sleeps.count)) / 60.0
        return RecoveryForecaster.forecast(recentCharge: Array(charge),
                                           recentEffort: Array(effort),
                                           todayEffort: intelligence.results.first?.strain,
                                           plannedSleepHours: plannedHours)
    }

    // MARK: - Forecast hero

    /// Tomorrow-morning Charge as the screen's hero, in the glow of the band it lands in. The number,
    /// ± band and copy are the forecaster's; the range is that band around it.
    private func forecastHero(_ f: RecoveryForecast) -> some View {
        let lo = Int(max(0, f.charge - f.band).rounded()), hi = Int(min(100, f.charge + f.band).rounded())
        return VStack(alignment: .leading, spacing: 10) {
            NoopHeroCard(glow: NoopGlow.charge(f.charge), padding: 22) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        NoopIconBadge("Tomorrow's Charge", icon: "moon-stars")
                        Spacer(minLength: 8)
                        NoopPill("Evening forecast", compact: true)
                    }
                    HStack(alignment: .bottom, spacing: 10) {
                        NoopDotNumber("\(Int(f.charge.rounded()))", size: 96)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(verbatim: "± \(Int(f.band.rounded()))")
                                .font(StrandFont.light(20, relativeTo: .title3))
                                .foregroundStyle(StrandPalette.textPrimary.opacity(0.8))
                            NoopTag(verbatim: StrandPalette.recoveryState(f.charge))
                        }
                        .padding(.bottom, 8)
                    }
                    .padding(.top, 28)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Tomorrow's Charge estimate \(Int(f.charge.rounded())) plus or minus \(Int(f.band.rounded()))")
                    Text("You'll likely wake around \(Int(f.charge.rounded())) ± \(Int(f.band.rounded())) Charge if you sleep about \(sleepHoursLabel(f.plannedSleepHours)) tonight.")
                        .font(StrandFont.light(17, relativeTo: .title3))
                        .foregroundStyle(StrandPalette.textPrimary.opacity(0.88))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                    NoopMetricRow {
                        NoopMetric(value: "\(lo)–\(hi)", unit: "%", label: "Likely range")
                        NoopMetric(value: Self.clock(hours: f.needHours), unit: "h", label: "Sleep needed")
                        NoopMetric(value: "\(f.nights)", unit: String(localized: "nights"), label: "Baseline")
                    }
                    .padding(.top, 20)
                }
            }
            Text("Estimate from today's effort, your typical sleep and your \(f.nights)-night recovery baseline, not a measurement. Your real Charge is scored from tomorrow's HRV when you wake.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    /// "~7h" / "~7h 30m" for the planned-sleep assumption (hours rounded to the nearest 30 min).
    private func sleepHoursLabel(_ hours: Double) -> String {
        let half = (hours * 2).rounded() / 2
        let h = Int(half)
        let m = Int((half - Double(h)) * 60)
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// "7:50" for a duration in hours.
    private static func clock(hours: Double) -> String {
        let mins = Int((hours * 60).rounded())
        return String(format: "%d:%02d", mins / 60, mins % 60)
    }

    // MARK: - Your scores

    @ViewBuilder private var scoresSection: some View {
        NoopSectionTitle("Your scores") {
            Text("Computed on \(Platform.deviceNounPhrase)")
        }
        if intelligence.computing {
            statusCard(icon: nil, text: Text("Crunching your raw streams…"))
        } else if let note = intelligence.note {
            statusCard(icon: "moon-stars", text: Text(note))
        } else if intelligence.results.isEmpty {
            // While the strap is mid-offload, say so — "no days" reads as final otherwise (#77). The
            // note owns the `LiveState` observation in its own leaf so the chunk count ticks without
            // re-rendering Intelligence (identical output to the prior inline check).
            IntelSyncingNote()
            NoopCard(padding: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    NoopCardHeader("Building from your strap", icon: "brain", caption: nil)
                    Text("This builds from the strap as it syncs. Effort and rest appear after you have worn it and slept a night. Charge needs about four nights of sleep to learn your baseline (you'll see \"Calibrating\" until then), and keeps sharpening over your first couple of weeks. On a WHOOP 5 or MG the strap banks little history, so the night count can climb slowly or sit at 0 of 4 until you have worn it across a few nights. That's its sync limit, not a fault. Import your WHOOP export to skip the wait.")
                        .font(StrandFont.light(14, relativeTo: .subheadline))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            SegmentedPillControl(ScoresMode.allCases, selection: $mode, fillsAvailableWidth: true) { $0.label }
                .accessibilityLabel("Scores view")
            switch mode {
            case .recent:
                recentTable
            case .byDay:
                byDayList
            }
        }
    }

    private func statusCard(icon: String?, text: Text) -> some View {
        NoopCard(padding: 18) {
            HStack(alignment: .top, spacing: 12) {
                if let icon {
                    PhIcon(icon).foregroundStyle(StrandPalette.textPrimary)
                } else {
                    ProgressView().controlSize(.small)
                }
                text.font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    /// The last seven scored days as a table (`.tb`), oldest at the top and today highlighted.
    private var recentTable: some View {
        let rows = Array(intelligence.results.prefix(7).reversed())
        let today = Self.dayFmt.string(from: Date())
        return VStack(spacing: 0) {
            ScoreTableRow(isHeader: true) {
                Text("Day")
            } cells: {
                tableHeader("Charge", unit: "%")
                tableHeader("Effort", unit: String(localized: "of \(UnitFormatter.effortScaleMax(effortScale))"))
                tableHeader("Rest", unit: "h")
                tableHeader("HRV", unit: "ms")
                tableHeader("RHR", unit: "bpm")
            }
            .padding(.top, 2)
            .padding(.bottom, 10)
            ForEach(rows) { d in
                let isToday = d.day == today
                Rectangle().fill(isToday ? Color.clear : NoopVisualStyle.border).frame(height: 1)
                ScoreTableRow(isHeader: false) {
                    Text(verbatim: Self.weekday(d.day))
                        .foregroundStyle(isToday ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                } cells: {
                    HStack(spacing: 6) {
                        Circle()
                            // The same band edge the hero glow uses, so the dot and the glow agree.
                            .fill(d.recovery != nil && NoopGlow.charge(d.recovery) == .recovery
                                  ? NoopGlow.recovery.accent.opacity(0.8) : NoopVisualStyle.quaternaryText)
                            .frame(width: 5, height: 5)
                        Text(verbatim: d.recovery.map { "\(Int($0.rounded()))" } ?? "—")
                    }
                    Text(verbatim: d.strain.map { UnitFormatter.effortDisplay($0, scale: effortScale) } ?? "—")
                    Text(verbatim: d.sleepMin.map { Self.clock(hours: $0 / 60) } ?? "—")
                    Text(verbatim: d.hrv.map { "\(Int($0.rounded()))" } ?? "—")
                    Text(verbatim: d.rhr.map { "\($0)" } ?? "—")
                }
                .padding(.vertical, 11)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isToday ? StrandPalette.textPrimary.opacity(0.05) : Color.clear)
                )
                .padding(.horizontal, -10)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .noopPanel()
    }

    private func tableHeader(_ title: LocalizedStringKey, unit: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title)
                .font(StrandFont.light(10.5, relativeTo: .caption2))
                .foregroundStyle(StrandPalette.textTertiary)
            Text(verbatim: unit)
                .font(StrandFont.light(9.5, relativeTo: .caption2))
                .foregroundStyle(NoopVisualStyle.quaternaryText)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    /// "Mon" for a yyyy-MM-dd key.
    private static func weekday(_ day: String) -> String {
        guard let date = dayFmt.date(from: day) else { return day }
        let locale = AppLanguage.activeLocale
        // One formatter per locale rather than one per table row.
        if weekdayFmt?.locale != locale {
            let f = DateFormatter()
            f.locale = locale
            f.setLocalizedDateFormatFromTemplate("EEE")
            weekdayFmt = f
        }
        return weekdayFmt?.string(from: date) ?? day
    }
    private static var weekdayFmt: DateFormatter?

    /// The per-day cards over a selectable window, each with its drivers.
    @ViewBuilder private var byDayList: some View {
        // Narrows the per-day list to a recent window (lexicographic yyyy-MM-dd compare == chronological).
        HStack(alignment: .center) {
            // Whole-phrase variants per count so translators never see a stitched plural.
            Text(filtered.count == 1 ? "1 day" : "\(filtered.count) days")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            SegmentedPillControl(IntelRange.allCases, selection: $range) { $0.label }
        }
        if filtered.isEmpty {
            statusCard(icon: "calendar-blank",
                       text: Text("No scored days in this window. Widen the range or import more history."))
        } else {
            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, day in
                dayCard(day)
                    .staggeredAppear(index: index)
            }
        }
    }

    private func dayCard(_ d: IntelligenceEngine.Computed) -> some View {
        NoopCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(d.day).font(StrandFont.book(15, relativeTo: .body)).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    // A3: the existing per-day Charge confidence as a small dot + tier tag pill
                    // (CALIBRATING / EST. / REL.) next to the source badge. Pure presentation of
                    // `d.confidence` , only shown once there's a Charge to qualify.
                    if d.recovery != nil {
                        ConfidenceTierChip(confidence: d.confidence)
                    }
                    // The REAL source of the day's dashboard headline, not a hard-coded "NOOP-computed".
                    // The By-Day numbers are always NOOP's on-device scores, but when an import covers the
                    // day it WINS the dashboard merge, so the badge says so ("Whoop" / "Apple Health") and
                    // a strap-scored night reads "On-device". Dynamic String → wrap in "\()" so it's shown
                    // verbatim, not looked up as a LocalizedStringKey (the String≠LocalizedStringKey
                    // SwiftUI footgun).
                    SourceBadge("\(d.source.badge)", tint: StrandPalette.textSecondary)
                }
                NoopMetricRow {
                    NoopMetric(value: d.recovery.map { "\(Int($0.rounded()))" } ?? "—",
                               unit: d.recovery == nil ? nil : "%", labelText: String(localized: "Charge"))
                    NoopMetric(value: d.strain.map { UnitFormatter.effortDisplay($0, scale: effortScale) } ?? "—",
                               labelText: String(localized: "Effort"))
                    NoopMetric(value: d.sleepMin.map { Self.clock(hours: $0 / 60) } ?? "—",
                               unit: d.sleepMin == nil ? nil : "h", labelText: String(localized: "Rest"))
                    NoopMetric(value: d.hrv.map { "\(Int($0.rounded()))" } ?? "—",
                               unit: d.hrv == nil ? nil : "ms", labelText: String(localized: "HRV"))
                    NoopMetric(value: d.rhr.map { "\($0)" } ?? "—",
                               unit: d.rhr == nil ? nil : "bpm", labelText: String(localized: "RHR"))
                }
                // Effort load meter (0–100): at-a-glance cardio load for the day.
                if let s = d.strain {
                    NoopTrack(fraction: min(1, max(0, s / 100)), height: 10)
                }
                // A1: "What shaped it" , one row per engine-supplied Charge driver. Gated on a non-empty
                // list so a cold-start / calibrating night (no real contributions to attribute) shows
                // nothing here rather than a fake breakdown. A5's relative skin-temp marker rides at the
                // foot when the night carries one.
                if !d.drivers.isEmpty {
                    ChargeBreakdownSection(drivers: d.drivers,
                                           confidence: d.confidence,
                                           skinTempRel: d.skinTempRel)
                        .padding(.top, NoopMetrics.space1)
                }
            }
        }
    }

    // MARK: - Charge model

    /// The five fixed Charge weights, in model order, with the ink step each is drawn in.
    private var chargeWeights: [(label: String, share: Double, ink: Double)] {
        [(String(localized: "HRV"), 0.55, 0.88),
         (String(localized: "Resting HR"), 0.20, 0.56),
         (String(localized: "Rest quality"), 0.15, 0.34),
         (String(localized: "Respiration"), 0.05, 0.20),
         (String(localized: "Skin temp"), 0.05, 0.12)]
    }

    @ViewBuilder private var chargeModelSection: some View {
        NoopSectionTitle("Charge model", captionKey: "Fixed weights")
        NoopCard(padding: 18) {
            VStack(alignment: .leading, spacing: 0) {
                NoopCardHeader("What drives your Charge", icon: "sliders-horizontal", captionKey: "Weights")
                    .padding(.bottom, 12)
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(chargeWeights, id: \.label) { w in
                            Rectangle()
                                .fill(StrandPalette.textPrimary.opacity(w.ink))
                                .frame(width: max(0, (geo.size.width - 8) * w.share))
                        }
                    }
                    .clipShape(Capsule(style: .continuous))
                }
                .frame(height: 16)
                .accessibilityHidden(true)
                HStack {
                    Text(verbatim: "0"); Spacer(); Text(verbatim: "50 %"); Spacer(); Text(verbatim: "100 %")
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.top, 8)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible())],
                          alignment: .leading, spacing: 12) {
                    ForEach(chargeWeights, id: \.label) { w in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(StrandPalette.textPrimary.opacity(w.ink))
                                .frame(width: 9, height: 9)
                            Text(verbatim: w.label)
                                .font(StrandFont.book(13, relativeTo: .footnote))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 4)
                            Text(verbatim: "\(Int(w.share * 100)) %")
                                .font(StrandFont.light(13, relativeTo: .footnote))
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(w.label): \(Int(w.share * 100))% of Charge")
                    }
                }
                .padding(.top, 18)
                Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
                    .padding(.top, 18)
                NoopInsightRow(text: Text("Charge weighs your HRV against your personal baseline (~55%), resting heart rate (~20%), rest quality (~15%), respiration (~5%) and skin-temperature deviation (~5%). Effort is a 0-\(UnitFormatter.effortScaleMax(effortScale)) cardiovascular load from time in heart-rate zones. Rest is staged from movement and heart rate. Everything is computed here from the strap's raw data. It works for any day NOOP collected raw streams."))
                    .padding(.top, 14)
            }
        }
        NoopList {
            Button { showHowItWorks = true } label: {
                NoopRow("How this works", caption: "Clean-room formulas, open source", icon: "book-open", chevron: true) {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
        }
    }
}

/// The Recent table's two views.
private enum ScoresMode: CaseIterable, Hashable {
    case recent, byDay
    var label: String {
        switch self {
        case .recent: return String(localized: "Recent")
        case .byDay:  return String(localized: "By Day")
        }
    }
}

/// One `.tb` row: a 44 pt day column and five right-aligned equal columns.
private struct ScoreTableRow<Day: View, Cells: View>: View {
    let isHeader: Bool
    @ViewBuilder var day: () -> Day
    @ViewBuilder var cells: () -> Cells
    var body: some View {
        HStack(spacing: 0) {
            day()
                .font(isHeader ? StrandFont.light(10.5, relativeTo: .caption2) : StrandFont.book(13, relativeTo: .footnote))
                .foregroundStyle(isHeader ? StrandPalette.textTertiary : StrandPalette.textSecondary)
                .frame(width: 44, alignment: .leading)
            _VariadicView.Tree(EqualColumns()) { cells() }
                .font(StrandFont.value(15))
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct EqualColumns: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        HStack(spacing: 0) {
            ForEach(children) { child in
                child.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

/// The "Syncing strap history…" note, shown only while a historical offload is running (#77). Owns the
/// `LiveState` observation in its own leaf (scroll-stutter isolation) so the chunk count ticks without
/// re-rendering IntelligenceView. Renders byte-for-byte what the prior inline `live.backfilling` check did.
private struct IntelSyncingNote: View {
    @EnvironmentObject private var live: LiveState
    var body: some View {
        if live.backfilling { SyncingHistoryNote(chunks: live.syncChunksThisSession) }
    }
}

/// Recent-window options for the By Day list. `days == nil` means show everything.
private enum IntelRange: Int, CaseIterable, Hashable {
    case week = 7, month = 30, quarter = 90, half = 180, year = 365, all = 0

    /// Trailing days the window spans; `nil` for ALL.
    var days: Int? { self == .all ? nil : rawValue }

    var label: String {
        switch self {
        case .week: return String(localized: "W")
        case .month: return String(localized: "M")
        case .quarter: return String(localized: "3M")
        case .half: return String(localized: "6M")
        case .year: return String(localized: "1Y")
        case .all: return String(localized: "ALL")
        }
    }
}
