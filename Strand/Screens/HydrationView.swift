import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Hydration detail (MVP, opt-in, local-only)
//
// v2: the goal ring sits in the blue glow with the day's figure and three small reads under it, the
// containers are a row of four quick-add tiles (the custom one resized by a long press or the header's
// sliders), today's drinks are a timed list (tap to edit or delete), and the last seven days are bars
// against the goal. BYTE-PARITY twin of the Android `HydrationScreen`: the day total + history come from
// the local-only `HydrationStore` series (additive day total), and the goal is the pure `HydrationGoal`
// engine (profile sex + today's Effort bump). The day total stays the source of truth; the per-drink list
// (#798) is the editable detail behind it.
struct HydrationView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    /// Today's running total (ml) + the 7-day history (oldest→newest), loaded off the gesture path and
    /// refreshed after each log. A reload key the taps bump so the `.task` re-reads the store.
    @State private var totalML: Double = 0
    @State private var history: [(day: String, value: Double)] = []
    @State private var reloadTick = 0
    /// The animated fill the hero ring drives to on appear and after each log, so the arc sweeps
    /// smoothly rather than snapping (the Today HeroScoreCell idiom).
    @State private var heroFraction: Double = 0
    /// #798 - today's individual logged drinks (for tap-to-edit + delete), and the entry being edited in
    /// the amount sheet (nil when the sheet is closed).
    @State private var entries: [HydrationEntry] = []
    /// Water imported from Apple Health for today (#949) — part of `totalML`, surfaced separately so the
    /// drinks list can show it as its own, non-editable line.
    @State private var importedML: Double = 0
    @State private var editingEntry: HydrationEntry?
    /// #798 - the user's custom container size (ml), editable from the custom-size sheet. Persisted local-only.
    @AppStorage(HydrationStore.customSizeKey) private var customSizeML = HydrationGoal.cupML
    @State private var showCustomSizeSheet = false

    /// "Card transparency" (0–100, default 100): fades the hydration cards in lockstep with the frosted
    /// cards; content stays readable. Mirrors Kotlin `NoopPrefs.cardOpacityPercent`.
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }

    private var goalML: Int { repo.hydrationGoalML(profileSex: profile.sex) }
    private var fraction: Double { HydrationGoal.fraction(totalML: totalML, goalML: goalML) }
    private var percent: Int { min(100, Int((fraction * 100).rounded(.towardZero))) }

    var body: some View {
        ScreenScaffold(title: nil, onRefresh: { await reload() }) {
            NoopScreenHeader("Hydration") {
                NoopCircleButton("sliders-horizontal", accessibilityLabel: "Set custom container size") {
                    showCustomSizeSheet = true
                }
            }
            .padding(.bottom, 6)
            heroSection
            NoopSectionTitle("Quick add", captionKey: "Hold Custom to resize")
            quickAddRow
            NoopSectionTitle("Today's drinks", caption: totalML > 0 ? Self.mlText(totalML) : nil)
            drinksSection
            NoopSectionTitle("Last 7 days", caption: goalMetCaption)
            historyCard
            footer
        }
        .noopHidesSystemNavBar()
        // Sweep the hero ring to the current fill on appear, and re-draw when a log moves it.
        // macOS-13-safe single-param onChange.
        .onChangeCompat(of: fraction) { newFraction in
            withAnimation(.easeOut(duration: 0.9)) { heroFraction = newFraction }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { heroFraction = fraction }
        }
        .task(id: reloadTick) { await reload() }
        // #798 - edit (or delete) a logged drink.
        .sheet(item: $editingEntry) { entry in
            HydrationAmountSheet(title: "Edit drink", initialML: entry.amountMl) { newML in
                editingEntry = nil
                Task { await updateEntry(entry, to: newML) }
            } onCancel: {
                editingEntry = nil
            } onDelete: {
                editingEntry = nil
                Task { await deleteEntry(entry) }
            }
        }
        // #798 - set the custom container size.
        .sheet(isPresented: $showCustomSizeSheet) {
            HydrationAmountSheet(title: "Custom size", initialML: customSizeML) { newML in
                customSizeML = newML
                showCustomSizeSheet = false
            } onCancel: { showCustomSizeSheet = false }
        }
    }

    // MARK: - Hero (the goal ring, in the blue glow)

    private var heroSection: some View {
        NoopHeroCard(glow: .strain, padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    NoopIconBadge("Water", icon: "drop")
                    Spacer(minLength: 8)
                    NoopPill(verbatim: String(localized: "Goal \(Self.mlText(Double(goalML)))"), compact: true)
                }
                ZStack {
                    G1bProgressRing(fraction: heroFraction, tint: StrandPalette.metricCyan,
                                    diameter: 176, knob: 13, halo: 24)
                    VStack(spacing: 6) {
                        NoopDotNumber("\(percent)", unit: "%", size: 80, unitSize: 34)
                            .fixedSize()
                            .padding(.vertical, -4)
                        Text("of today's goal")
                            .font(StrandFont.footnote)
                            .foregroundStyle(Color.white.opacity(0.62))
                    }
                }
                .frame(width: 200, height: 200)
                .padding(.top, 20)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Hydration today")
                .accessibilityValue("\(String(format: "%.1f", HydrationGoal.litres(fromML: totalML))) of \(String(format: "%.1f", HydrationGoal.litres(fromML: Double(goalML)))) litres")
                Text(verbatim: String(localized: "\(Self.mlNumber(totalML)) of \(Self.mlText(Double(goalML)))"))
                    .font(StrandFont.light(19))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.top, 18)
                HStack(spacing: 0) {
                    G1bCenteredMetric(value: Self.mlNumber(max(0, Double(goalML) - totalML)), unit: "ml",
                                      label: Text("To go"))
                    G1bCenteredMetric(value: "\(entries.count)", label: Text("Drinks"))
                    G1bCenteredMetric(value: entries.last.map { Self.entryTimeFmt.string(from: $0.loggedAt) } ?? "—",
                                      label: Text("Last drink"))
                }
                .padding(.top, 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Quick add (Sip / Cup / Bottle / Custom)

    private var quickAddRow: some View {
        HStack(spacing: 8) {
            quickTile("Sip", icon: "drop-simple", ml: HydrationGoal.sipML)
            quickTile("Cup", icon: "drop-half-bottom", ml: HydrationGoal.cupML)
            quickTile("Bottle", icon: "drop-fill", ml: HydrationGoal.bottleML)
            customTile
        }
    }

    /// One preset container: tap logs its amount and refreshes.
    private func quickTile(_ title: LocalizedStringKey, icon: String, ml: Int) -> some View {
        Button {
            Task { await add(ml: ml) }
        } label: {
            tileFace(title, icon: icon, ml: ml)
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel("Log \(title)")
    }

    /// #798 - the custom container the user sizes themselves: a tap logs it, a long press (or the
    /// header's sliders) opens the size editor so a one-off mug / flask / glass is set once and reused.
    private var customTile: some View {
        tileFace("Custom", icon: "pencil-simple", ml: customSizeML)
            .onTapGesture { Task { await add(ml: customSizeML) } }
            .onLongPressGesture(minimumDuration: 0.45) { showCustomSizeSheet = true }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Log custom \(customSizeML) millilitres")
            .accessibilityAction { Task { await add(ml: customSizeML) } }
            .accessibilityAction(named: Text("Set custom container size")) { showCustomSizeSheet = true }
    }

    private func tileFace(_ title: LocalizedStringKey, icon: String, ml: Int) -> some View {
        VStack(spacing: 4) {
            PhIcon(icon, size: 24)
                .padding(.bottom, 8)
            // Scales further than the other labels: "Benutzerdefiniert" is twice the width of a quarter
            // tile and truncated to "Benutzerde…" at 0.8.
            Text(title)
                .font(StrandFont.book(14))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(verbatim: "\(ml) ml")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .padding(.horizontal, 6)
        .noopPanel(cornerRadius: 22, surfaceOpacity: cardOpacity)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Today's logged drinks (#798) - tap to edit or delete

    @ViewBuilder private var drinksSection: some View {
        // Also shown when the only water today came from Apple Health (#949) — otherwise the ring would
        // count drinks the screen never accounts for, and the day would look like it appeared from nowhere.
        if !entries.isEmpty || importedML > 0 {
            VStack(alignment: .leading, spacing: 10) {
                // #842 — rows render in a plain stack inside the page ScrollView (a nested List clipped
                // rows past the third). Newest first, as the day reads back.
                NoopList {
                    ForEach(entries.reversed()) { entry in
                        entryRow(entry)
                    }
                    if importedML > 0 { importedRow }
                }
                if !entries.isEmpty {
                    Text("Tap a drink to edit or delete it.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.horizontal, 4)
                }
            }
        } else {
            Text("No drinks logged yet. Tap Sip, Cup or Bottle to start.")
                .font(StrandFont.light(14))
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .noopPanel(cornerRadius: NoopVisualStyle.listRadius, surfaceOpacity: cardOpacity)
        }
    }

    /// Water Apple Health already had, from a hydration app or a smart bottle (#949).
    ///
    /// Deliberately not tappable and with no delete: NOOP does not own these drinks, and "deleting" one
    /// here would be a lie — the next sync re-reads the same day from Health and the figure would come
    /// straight back. Removing it for real means removing it in the app that logged it.
    private var importedRow: some View {
        drinkRow(time: nil, icon: "heart-half", title: Text("From Apple Health"),
                 caption: Text("Logged in another app"), ml: Int(importedML.rounded()))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(Int(importedML.rounded())) millilitres from Apple Health. Edit it in the app that logged it.")
    }

    /// One logged drink: the time it was logged, the container it matches, its amount. Tap edits (the
    /// sheet also deletes); a long press offers both directly.
    private func entryRow(_ entry: HydrationEntry) -> some View {
        let time = Self.entryTimeFmt.string(from: entry.loggedAt)
        let container = containerName(entry.amountMl)
        return Button { editingEntry = entry } label: {
            drinkRow(time: time, icon: container?.icon ?? "drop-simple", title: Text("Water"),
                     caption: container.map { Text($0.name) }, ml: entry.amountMl)
        }
        // Liquid tap response: the same physical settle-inward every tappable liquid row gets.
        .buttonStyle(LiquidPressStyle())
        .contextMenu {
            Button { editingEntry = entry } label: { Label("Edit drink", systemImage: "pencil") }
            Button(role: .destructive) {
                Task { await deleteEntry(entry) }
            } label: { Label("Delete", systemImage: "trash") }
        }
        .accessibilityLabel("Logged \(entry.amountMl) millilitres at \(time)")
        .accessibilityHint("Tap to edit the amount")
        .accessibilityAction(named: Text("Delete the \(entry.amountMl) millilitre drink logged at \(time)")) {
            Task { await deleteEntry(entry) }
        }
    }

    private func drinkRow(time: String?, icon: String, title: Text, caption: Text?, ml: Int) -> some View {
        HStack(spacing: 14) {
            Text(verbatim: time ?? "")
                .font(StrandFont.light(13))
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 40, alignment: .leading)
            NoopIconTile(icon)
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(StrandFont.book(15))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let caption {
                    caption
                        .font(StrandFont.light(12))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: Self.mlNumber(Double(ml)))
                    .font(StrandFont.value(15))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: "ml")
                    .font(StrandFont.book(10))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    /// The quick-add container a logged amount matches (Sip / Cup / Bottle / Custom), so the list can name
    /// it; nil for an amount edited to something none of them pour.
    private func containerName(_ ml: Int) -> (name: LocalizedStringKey, icon: String)? {
        switch ml {
        case HydrationGoal.sipML:    return ("Sip", "drop-simple")
        case HydrationGoal.cupML:    return ("Cup", "drop-half-bottom")
        case HydrationGoal.bottleML: return ("Bottle", "drop-fill")
        case customSizeML:           return ("Custom", "pencil-simple")
        default:                     return nil
        }
    }

    /// #1821: routed through AppClock so the Clock format setting reaches this label. Was a `static
    /// let`, which would have frozen the reader's choice at first use until the app relaunched.
    private static var entryTimeFmt: DateFormatter { AppClock.hourMinuteFormatter() }

    // MARK: - 7-day history (bars against the goal, today on the right)

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let avg = priorAverage {
                HStack(alignment: .bottom, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(verbatim: Self.mlNumber(avg.ml))
                            .font(StrandFont.light(26))
                            .tracking(-0.52)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(verbatim: "ml")
                            .font(StrandFont.book(11))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Text(verbatim: String(localized: "daily average, \(avg.range)"))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.bottom, 5)
                }
                .padding(.bottom, 14)
            }
            historyBars
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .noopPanel(surfaceOpacity: cardOpacity)
    }

    @ViewBuilder private var historyBars: some View {
        if history.isEmpty {
            Text("No history yet.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        } else {
            // Scale to the LARGER of the goal and the biggest day plus headroom, so an over-goal day
            // doesn't clip and the goal line keeps room for its label.
            let ceiling = max(Double(max(goalML, 1)), history.map(\.value).max() ?? 0, 1) * 1.18
            let lastIndex = history.count - 1
            let chartHeight: CGFloat = 104
            VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(Array(history.enumerated()), id: \.element.day) { idx, bar in
                            let frac = min(1.0, max(0.0, bar.value / ceiling))
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(idx == lastIndex ? NoopGlow.strain.accent : NoopGlow.ink.deep)
                                .frame(width: 30, height: max(3, chartHeight * CGFloat(frac)))
                                .frame(maxWidth: .infinity)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(weekdayShort(bar.day)): \(String(format: "%.1f", HydrationGoal.litres(fromML: bar.value))) litres")
                        }
                    }
                    .frame(height: chartHeight, alignment: .bottom)
                    goalLine(y: chartHeight * CGFloat(1 - Double(goalML) / ceiling))
                }
                .frame(height: chartHeight)
                HStack(spacing: 0) {
                    ForEach(Array(history.enumerated()), id: \.element.day) { idx, bar in
                        Text(verbatim: weekdayShort(bar.day))
                            .font(StrandFont.footnote)
                            .foregroundStyle(idx == lastIndex ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    /// Today's goal as a dashed rule across the bars, labelled at its right end.
    private func goalLine(y: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            Path { p in
                p.move(to: .zero)
                p.addLine(to: CGPoint(x: 2_000, y: 0))
            }
            .stroke(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            .frame(height: 1)
            .clipped()
            Text(verbatim: String(localized: "Goal \(Self.mlNumber(Double(goalML)))"))
                .font(StrandFont.light(10))
                .foregroundStyle(StrandPalette.textPrimary.opacity(0.5))
                .offset(y: -14)
        }
        .offset(y: y)
        .accessibilityHidden(true)
    }

    /// The mean of the earlier days in the window that have any water, and the weekday span it covers
    /// ("Sun–Fri"). nil before there is an earlier logged day.
    private var priorAverage: (ml: Double, range: String)? {
        let prior = Array(history.dropLast())
        let logged = prior.filter { $0.value > 0 }
        guard !logged.isEmpty, let first = prior.first, let last = prior.last else { return nil }
        let mean = logged.map(\.value).reduce(0, +) / Double(logged.count)
        return (mean, "\(weekdayShort(first.day))–\(weekdayShort(last.day))")
    }

    /// "Goal met 4 of 6 days" over the earlier logged days, each judged against ITS OWN day's goal (the
    /// same `HydrationGoal` engine fed that day's Effort), never today's.
    private var goalMetCaption: String? {
        let logged = history.dropLast().filter { $0.value > 0 }
        guard !logged.isEmpty else { return nil }
        let met = logged.filter { bar in
            let effort = repo.days.first(where: { $0.day == bar.day })?.strain
            return bar.value >= Double(HydrationGoal.dailyGoalML(sex: profile.sex, effort: effort))
        }.count
        return String(localized: "Goal met \(met) of \(logged.count) days")
    }

    // MARK: - Insight + footnotes

    /// The week's best earlier day, and what today's Effort adds to the goal — both read off data the
    /// screen already holds. nil when neither applies.
    private var insightText: String? {
        var parts: [String] = []
        if let best = history.dropLast().filter({ $0.value > 0 }).max(by: { $0.value < $1.value }) {
            let litres = HydrationGoal.litres(fromML: best.value)
                .formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.activeLocale))
            parts.append(String(localized: "\(weekdayName(best.day)) was your best day this week at \(litres) l."))
        }
        let bump = HydrationGoal.effortBump(effort: repo.today?.strain)
        if bump > 0 {
            parts.append(String(localized: "Today's Effort adds \(bump) ml to your goal."))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let insightText {
                NoopInsightRow(verbatim: insightText)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("A simple goal that adjusts to your effort. General wellness guidance, not medical advice.")
                Text("Your fluid intake today, on \(Platform.deviceNounPhrase) only.")
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
        .padding(.horizontal, 4)
    }

    // MARK: - Formatting

    /// "1,550" — a whole-ml figure, grouped for the reader's locale.
    static func mlNumber(_ ml: Double) -> String {
        Int(ml.rounded()).formatted(.number.locale(AppLanguage.activeLocale))
    }

    /// "1,550 ml".
    static func mlText(_ ml: Double) -> String { "\(mlNumber(ml)) ml" }

    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "Sun" for a yyyy-MM-dd key in the reader's language, or "·" when unparseable.
    private func weekdayShort(_ dayKey: String) -> String {
        guard let date = Self.dayKeyParser.date(from: dayKey) else { return "·" }
        return date.formatted(.dateTime.weekday(.abbreviated).locale(AppLanguage.activeLocale))
    }

    /// "Friday" for a yyyy-MM-dd key in the reader's language.
    private func weekdayName(_ dayKey: String) -> String {
        guard let date = Self.dayKeyParser.date(from: dayKey) else { return "·" }
        return date.formatted(.dateTime.weekday(.wide).locale(AppLanguage.activeLocale))
    }

    // MARK: - Data

    /// Log `ml` (additive day total + a per-entry row, #798) and refresh.
    private func add(ml: Int) async {
        guard ml > 0 else { return }
        _ = await repo.logHydration(amountMl: ml)
        reloadTick &+= 1
    }

    /// #798 - delete a logged drink, re-deriving the day total, then refresh.
    private func deleteEntry(_ entry: HydrationEntry) async {
        _ = await repo.deleteHydrationEntry(id: entry.id)
        reloadTick &+= 1
    }

    /// #798 - set a logged drink's amount, re-deriving the day total, then refresh.
    private func updateEntry(_ entry: HydrationEntry, to ml: Int) async {
        _ = await repo.updateHydrationEntry(id: entry.id, amountMl: ml)
        reloadTick &+= 1
    }

    /// Load today's total + the 7-day history + today's per-entry list from the store.
    private func reload() async {
        totalML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
        history = await repo.hydrationHistory(days: 7)
        entries = repo.hydrationEntries()
        // #949: `totalML` already includes this; read it separately so the drinks list can name where
        // the difference came from instead of leaving an unexplained gap between the ring and the list.
        importedML = await repo.hydrationImportedTotal(day: Repository.localDayKey(Date()))
    }
}

// MARK: - Amount sheet (#798) - edit a drink / set the custom size

/// A small sheet for an ml amount: the figure in dot matrix between − and + circles, Cancel / Save in the
/// sheet header, and — when editing a logged drink — a Delete button. Reused by the edit-entry and
/// custom-size flows. Clamps to a sane range so the value stays a real container size.
private struct HydrationAmountSheet: View {
    let title: LocalizedStringKey
    let initialML: Int
    let onSave: (Int) -> Void
    let onCancel: () -> Void
    let onDelete: (() -> Void)?

    @State private var ml: Int

    /// Bounds for a plausible single container (10 ml up to 3 L), stepping in 10 ml increments.
    private static let minML = 10
    private static let maxML = 3000
    private static let stepML = 10

    init(title: LocalizedStringKey, initialML: Int, onSave: @escaping (Int) -> Void,
         onCancel: @escaping () -> Void, onDelete: (() -> Void)? = nil) {
        self.title = title
        self.initialML = initialML
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        _ml = State(initialValue: Self.clamp(initialML))
    }

    static func clamp(_ value: Int) -> Int { min(maxML, max(minML, value)) }

    var body: some View {
        VStack(spacing: 0) {
            NoopSheetHeader(title, doneTitle: "Save", onCancel: onCancel, onDone: { onSave(Self.clamp(ml)) })
            HStack(spacing: 16) {
                NoopCircleButton("minus", size: 52, accessibilityLabel: "Decrease amount") {
                    ml = Self.clamp(ml - Self.stepML)
                }
                .modifier(RepeatingPress())
                VStack(spacing: 8) {
                    NoopDotNumber("\(ml)", unit: "ml", size: 56, unitSize: 22)
                        .fixedSize()
                    Text("Amount")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Amount in millilitres")
                .accessibilityValue("\(ml) millilitres")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: ml = Self.clamp(ml + Self.stepML)
                    case .decrement: ml = Self.clamp(ml - Self.stepML)
                    @unknown default: break
                    }
                }
                NoopCircleButton("plus", size: 52, accessibilityLabel: "Increase amount") {
                    ml = Self.clamp(ml + Self.stepML)
                }
                .modifier(RepeatingPress())
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            if let onDelete {
                NoopButton("Delete drink", kind: .destructive, fullWidth: true) { onDelete() }
                    .padding(.horizontal, 20)
                    .padding(.top, 26)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(NoopSheetBackground())
        // iOS-only sheet sizing - macOS sheets are free-floating windows and reject detents (see the
        // shared `noopSheetPresentation` note); the call site stays cross-platform via this guard.
        #if os(iOS)
        .presentationDetents([.height(onDelete == nil ? 250 : 330)])
        .presentationDragIndicator(.visible)
        .presentationBackground { NoopSheetBackground() }
        .presentationCornerRadius(NoopVisualStyle.heroRadius)
        #else
        .frame(minWidth: 360, minHeight: onDelete == nil ? 220 : 300)
        #endif
    }
}

/// Holding − or + keeps stepping, as the system Stepper did, where the OS supports button repeat.
private struct RepeatingPress: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            content.buttonRepeatBehavior(.enabled)
        } else {
            content
        }
    }
}
