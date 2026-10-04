import WidgetKit
import SwiftUI
import StrandDesign

// MARK: - NOOP watch-face complication
//
// The headline feature of M3: Charge (recovery) on the wrist. The iPhone is the brain
// (M1 computes Charge / Effort / Rest with confidence + provenance); this complication ONLY
// displays the latest `WatchScoreSnapshot` the phone pushed into the shared app group. It never
// recomputes a score.
//
// The honesty rule carries through from M1: a CALIBRATING score has a nil number plus its
// Calibrating flag set, and we render a dash with a subtle "cal" marker, never a fabricated
// number. When there is no snapshot at all we show a NEUTRAL placeholder (a dash + the NOOP
// glyph), not a zero, so an empty face never reads as "your Charge is 0".
//
// Families: accessoryCircular (ring + number), accessoryCorner (number + bezel arc), accessoryInline
// (text), and accessoryRectangular (all three scores as bars).

// MARK: - Snapshot access
//
// We read the app group directly here rather than depending on a loader symbol from the bridge
// lane, so this extension only needs the shared `WatchScoreSnapshot` type from StrandDesign. The
// suite + key match the cross-lane contract: the phone-side bridge writes the latest snapshot under
// `latestWatchSnapshot` to whatever app group `WatchScoreSnapshot.appGroupId` resolves to (the
// extension's own AppGroupIdentifier Info.plist key, injected from $(APP_GROUP_ID)/$(BUNDLE_ID_PREFIX)
// in project.yml, falling back to the canonical upstream group), and the watch app + this
// complication read the same value.

enum WatchSnapshotAccess {
    /// `Bundle.main` is process-global, so this is exactly the lookup `WatchScoreSnapshot.appGroupId`
    /// itself performs — deferring to it directly keeps the resolution in ONE place so the writer and
    /// every reader can never desync on it.
    static let suiteName: String = WatchScoreSnapshot.appGroupId

    static let storageKey = WatchScoreSnapshot.storageKey

    /// The last snapshot the phone pushed, or nil if nothing has synced yet.
    static func load() -> WatchScoreSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: storageKey),
              let snap = try? JSONDecoder().decode(WatchScoreSnapshot.self, from: data) else { return nil }
        return snap
    }
}

// MARK: - Timeline

/// One timeline entry, backed by the latest snapshot (or nil when nothing has synced).
struct ChargeEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchScoreSnapshot?
}

struct ChargeProvider: TimelineProvider {
    /// A friendly stand-in for the gallery / first paint. Shows a real-looking Charge so the
    /// complication previews well, but it is never persisted and the live view falls back to the
    /// neutral placeholder when there is genuinely no snapshot.
    func placeholder(in context: Context) -> ChargeEntry {
        ChargeEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (ChargeEntry) -> Void) {
        // In the gallery (isPreview) show the friendly preview; on a real face show what synced.
        let snap = context.isPreview ? WatchScoreSnapshot.preview : WatchSnapshotAccess.load()
        completion(ChargeEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ChargeEntry>) -> Void) {
        let snap = WatchSnapshotAccess.load()
        // The phone forces a reload (WidgetCenter.reloadAllTimelines) whenever it pushes a fresh
        // snapshot, so this periodic refresh is just a backstop. Roughly every 30 minutes keeps the
        // "as of …" age honest without burning the watch's complication budget.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())
            ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [ChargeEntry(date: Date(), snapshot: snap)], policy: .after(next)))
    }
}

// MARK: - Preview snapshot

private extension WatchScoreSnapshot {
    /// A representative snapshot for the widget gallery: a primed Charge, a mid Effort, a calibrating
    /// Rest (so the gallery also shows the cal marker), a live HR and a short sleep line.
    static var preview: WatchScoreSnapshot {
        WatchScoreSnapshot(
            charge: 74, chargeCalibrating: false,
            effort: 41, effortCalibrating: false,
            rest: nil, restCalibrating: true,
            hr: 58,
            sleepSummary: "7h 12m",
            asOf: Date()
        )
    }
}

// MARK: - Score read-out helpers
//
// One place decides how a (value, calibrating) pair renders, so the four family views can never
// disagree and the honesty rule is enforced once.

/// How a single score should be drawn: a real number, a calibrating dash, or simply absent.
private enum ScoreReadout {
    case value(Int)
    case calibrating
    case missing

    /// Map the snapshot's (optional number + Calibrating flag) into a readout. A calibrating score
    /// (number nil + flag true) is `.calibrating`; a present number is `.value`; everything else is
    /// `.missing`. We never invent a number for a calibrating score.
    init(value: Double?, calibrating: Bool) {
        if let v = value {
            self = .value(Int(v.rounded()))
        } else if calibrating {
            self = .calibrating
        } else {
            self = .missing
        }
    }

    /// The fraction (0...1) to fill a ring/gauge with. Calibrating + missing read as an empty track.
    var fraction: Double {
        if case let .value(v) = self { return min(max(Double(v) / 100.0, 0), 1) }
        return 0
    }

    /// The big number, or a dash for calibrating / missing.
    var numberText: String {
        if case let .value(v) = self { return "\(v)" }
        return "–"
    }
}

// MARK: - The complication view

struct NOOPChargeView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ChargeEntry

    // MARK: One shared staleness decision
    //
    // Every family routes through `isStale` so they stay consistent: a days-old snapshot must never
    // read as live in ANY family. When stale we collapse each score to the SAME calibrating dash the
    // missing/calibrating path already draws, rather than painting an old number. Mirrors how
    // ScoreReadout centralises the calibrating/missing call so the four views can never disagree.

    /// True when we have a snapshot but it is too old to present as current. nil snapshot is handled
    /// separately as the neutral placeholder, so this is purely about an aged-out real snapshot.
    private var isStale: Bool {
        guard let snap = entry.snapshot else { return false }
        return snap.isStale(now: entry.date)
    }

    /// Map one score, but force the calibrating dash when the whole snapshot is stale. Centralising it
    /// here means circular / corner / inline / rectangular all degrade identically.
    private func readout(_ value: Double?, _ calibrating: Bool) -> ScoreReadout {
        if isStale { return .calibrating }
        return ScoreReadout(value: value, calibrating: calibrating)
    }

    private var charge: ScoreReadout {
        readout(entry.snapshot?.charge, entry.snapshot?.chargeCalibrating ?? false)
    }
    private var effort: ScoreReadout {
        readout(entry.snapshot?.effort, entry.snapshot?.effortCalibrating ?? false)
    }
    private var rest: ScoreReadout {
        readout(entry.snapshot?.rest, entry.snapshot?.restCalibrating ?? false)
    }

    /// True when nothing has ever synced from the phone. Drives the neutral placeholder.
    private var noSnapshot: Bool { entry.snapshot == nil }

    /// The honest recency label for the families that have room for one, straight from the contract.
    private var freshness: String? {
        guard let snap = entry.snapshot else { return nil }
        return snap.freshnessText(now: entry.date)
    }

    /// True when the snapshot's scores read as current ("Today" / "just now"). The families below skip
    /// the recency label in that case because it adds no information next to a live-looking number.
    /// Decided by the SEMANTIC flag on the shared contract, never by comparing the localized display
    /// text `freshness` returns; a display-text comparison would silently stop matching in every
    /// language the string catalogs translate.
    private var isFreshToday: Bool {
        entry.snapshot?.isFreshToday(now: entry.date) ?? false
    }

    var body: some View {
        switch family {
        case .accessoryCircular:    circular
        case .accessoryCorner:      corner
        case .accessoryInline:      inline
        case .accessoryRectangular: rectangular
        default:                    circular
        }
    }

    // MARK: Charge tint
    //
    // Tinted to the Charge colour world only when we have a real number. A calibrating or missing
    // Charge stays neutral so the empty ring never borrows a "good"/"bad" colour it did not earn.

    private var chargeTint: Color {
        if case let .value(v) = charge { return StrandPalette.recoveryColor(Double(v)) }
        return StrandPalette.textTertiary
    }

    // MARK: accessoryCircular — a ring + the Charge number
    //
    // The v2 ring at complication size: a faint track, the Charge arc (tinted to its band where we have a
    // real value) with a white knob at its end, and the number in the dot-matrix face. A small "cal"
    // marker replaces the number when Charge is calibrating. The arc is accentable so tinted faces keep it.

    private var circular: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 4.5)
            if charge.fraction > 0 {
                Circle()
                    .trim(from: 0, to: charge.fraction)
                    .stroke(chargeTint, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
                ringKnob(fraction: charge.fraction, lineWidth: 4.5)
            }
            VStack(spacing: 0) {
                Text(charge.numberText)
                    .font(StrandFont.dot(16))
                    .tracking(StrandFont.dotTracking(16))
                    .minimumScaleFactor(0.6)
                    .padding(.leading, 2)
                if case .calibrating = charge {
                    calPip
                }
            }
        }
        // The ring sits a few points inside the face's disc, as the board draws it.
        .padding(4.5)
        // The curved label carries the recency so even the tiny circle is honest: "Charge · 2h ago"
        // when aging, plain "Charge" when fresh, a sync hint when nothing has synced.
        .widgetLabel(circularLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityCharge)
    }

    /// The white knob at the end of the Charge arc, as on every v2 ring. Placed by geometry so it follows
    /// whatever diameter the face gives the complication; a stroked circle's line is centred on the
    /// frame's radius, so that is where the knob sits.
    private func ringKnob(fraction: Double, lineWidth: CGFloat) -> some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let r = side / 2
            let a = Angle.degrees(-90 + 360 * fraction).radians
            Circle()
                .fill(Color.white)
                .frame(width: lineWidth * 1.25, height: lineWidth * 1.25)
                .position(x: geo.size.width / 2 + r * CGFloat(cos(a)),
                          y: geo.size.height / 2 + r * CGFloat(sin(a)))
        }
    }

    /// The circular family's curved widgetLabel. Appends the freshness once a snapshot starts aging so
    /// the number above it is never read as live; stays "Charge" while it is fresh.
    private var circularLabel: String {
        guard let fresh = freshness else { return String(localized: "Charge") }
        if isStale { return String(localized: "Charge · \(fresh)") }
        // A current snapshot's label adds no information next to a live-looking ring, so keep it clean.
        if isFreshToday { return String(localized: "Charge") }
        return String(localized: "Charge · \(fresh)")
    }

    // MARK: accessoryCorner — the number in the corner, the Charge arc (or its status) along the bezel

    @ViewBuilder
    private var corner: some View {
        if case .value = charge, !isStale, isFreshToday {
            // A current, earned Charge rides the bezel as an arc.
            cornerNumber
                .widgetLabel {
                    Gauge(value: charge.fraction, in: 0...1) {
                        Text("Charge")
                    }
                    .tint(chargeTint)
                }
                .accessibilityLabel(accessibilityCharge)
        } else {
            // Anything else says what it is in words along the bezel: the age, "cal", or a sync hint.
            cornerNumber
                .widgetLabel {
                    Text(cornerLabel)
                }
                .accessibilityLabel(accessibilityCharge)
        }
    }

    private var cornerNumber: some View {
        Text(charge.numberText)
            .font(StrandFont.dot(22))
            .tracking(StrandFont.dotTracking(22))
            .foregroundStyle(StrandPalette.textPrimary)
            .widgetAccentable()
    }

    private var cornerLabel: String {
        switch charge {
        case .value:
            // Real number: ride the bezel with the recency so an aging score stays honest. A current
            // snapshot keeps the plain label (semantic flag, not a display-text comparison).
            guard let fresh = freshness, !isFreshToday else { return String(localized: "Charge") }
            return String(localized: "Charge · \(fresh)")
        case .calibrating:
            // When the dash is here because the whole snapshot went stale, say so plainly rather than
            // "cal" (which means "needs more data", a different thing).
            if isStale {
                let fresh = freshness ?? String(localized: "stale")
                return String(localized: "Charge · \(fresh)")
            }
            return String(localized: "Charge · cal")
        case .missing:
            return noSnapshot ? String(localized: "Open NOOP") : String(localized: "Charge")
        }
    }

    // MARK: accessoryInline — a single line of text along the top of the face

    /// The wordmark in medium weight ahead of the line, so it reads as NOOP's among the face's other
    /// inline complications. The "open on iPhone" hint already leads with it.
    private var inline: Text {
        if noSnapshot { return Text(inlineText) }
        return Text(verbatim: "NOOP ").fontWeight(.medium) + Text(inlineText)
    }

    private var inlineText: String {
        if noSnapshot { return String(localized: "NOOP · open on iPhone") }
        // When the snapshot has aged out we never print the old number; we say it is stale and how old.
        if isStale {
            let fresh = freshness ?? String(localized: "old")
            return String(localized: "Charge stale · \(fresh)")
        }
        switch charge {
        case .value(let v):
            // A fresh number reads as live, so append the recency once it starts to age. The synced heart
            // rate stays off this line: behind the wordmark the slot has no room for it, and a truncated
            // "6…" says less than nothing. The glance carries the wrist's own live reading.
            return String(localized: "Charge \(v)\(inlineFreshnessSuffix)")
        case .calibrating:
            return String(localized: "Charge calibrating")
        case .missing:
            return String(localized: "Charge –")
        }
    }

    /// " · 2h ago" appended to the inline line once a snapshot ages, empty while it is fresh so a live
    /// reading stays uncluttered. Keyed off the semantic flag, never the localized display text.
    private var inlineFreshnessSuffix: String {
        guard let fresh = freshness, !isFreshToday else { return "" }
        return " · \(fresh)"
    }

    // MARK: accessoryRectangular — a compact card showing all three scores
    //
    // The richest family: a NOOP header line with the snapshot's age, then Charge / Effort / Rest as a
    // label, a thin bar and the number (or a dash + cal marker). This is the only place all three scores
    // live, so it doubles as the "everything at a glance" face.

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header: the wordmark + the snapshot age (or a sync hint when empty).
            HStack(spacing: 4) {
                Text(verbatim: "NOOP")
                    .font(StrandFont.medium(11))
                    .tracking(0.2)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: "· \(headerTrailing)")
                    .font(StrandFont.light(11))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            scoreRow(String(localized: "Charge"), readout: charge, tint: chargeTint)
            scoreRow(String(localized: "Effort"), readout: effort, tint: effortTint)
            scoreRow(String(localized: "Rest"), readout: rest, tint: restTint)
        }
        .widgetAccentable()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityRectangular)
    }

    /// The trailing header text: a sync hint when empty, otherwise the honest recency label so a stale
    /// snapshot reads as "Yesterday" / "2h ago" rather than implying it is live. The rows below already
    /// collapse to the calibrating dash when stale, so the header and the numbers agree.
    private var headerTrailing: String {
        guard let snap = entry.snapshot else { return String(localized: "open iPhone") }
        return snap.freshnessText(now: entry.date)
    }

    /// One labelled score in the rectangular card: the label, a bar filled to the score in its colour (an
    /// empty track when calibrating or missing), and the number or a dash with a tiny "cal" marker.
    private func scoreRow(_ label: String, readout: ScoreReadout, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(StrandFont.light(11))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    if readout.fraction > 0 {
                        Capsule().fill(tint)
                            .frame(width: max(5, geo.size.width * readout.fraction))
                    }
                }
            }
            .frame(height: 5)
            HStack(spacing: 1) {
                Text(readout.numberText)
                    .font(StrandFont.dot(12))
                    .foregroundStyle(readoutIsValue(readout) ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                if case .calibrating = readout { calPip }
            }
            .frame(width: 26, alignment: .trailing)
        }
    }

    private func readoutIsValue(_ r: ScoreReadout) -> Bool {
        if case .value = r { return true }
        return false
    }

    // MARK: Effort / Rest tints (rectangular only)

    private var effortTint: Color {
        if case .value = effort { return StrandPalette.effortColor }
        return StrandPalette.textTertiary
    }
    private var restTint: Color {
        if case .value = rest { return StrandPalette.restColor }
        return StrandPalette.textTertiary
    }

    // MARK: The "cal" marker
    //
    // A subtle, lowercase "cal" pill. Small and tertiary so it reads as a status footnote, not an
    // alarm. This is what the honesty rule looks like on a tiny face: a dash plus this, never a number.

    private var calPip: some View {
        Text("cal")
            .font(StrandFont.medium(7))
            .foregroundStyle(StrandPalette.textTertiary)
    }

    // MARK: Accessibility

    private var accessibilityCharge: String {
        // A stale snapshot collapses to the calibrating dash visually, but for VoiceOver we say WHY it
        // is a dash plainly so it is never mistaken for "still calibrating".
        if isStale {
            let fresh = freshness ?? String(localized: "a while ago")
            return String(localized: "Charge out of date, last synced \(fresh). Open NOOP on iPhone.")
        }
        switch charge {
        case .value(let v):    return String(localized: "Charge \(v) out of 100")
        case .calibrating:     return String(localized: "Charge calibrating, needs more data")
        case .missing:         return noSnapshot ? String(localized: "No data, open NOOP on iPhone")
                                                 : String(localized: "Charge unavailable")
        }
    }

    private var accessibilityRectangular: String {
        if noSnapshot { return String(localized: "NOOP. No data yet, open NOOP on your iPhone to sync.") }
        if isStale {
            let fresh = freshness ?? String(localized: "a while ago")
            return String(localized: "NOOP. Scores out of date, last synced \(fresh). Open NOOP on iPhone to refresh.")
        }
        func phrase(_ label: String, _ r: ScoreReadout) -> String {
            switch r {
            case .value(let v):  return String(localized: "\(label) \(v)")
            case .calibrating:   return String(localized: "\(label) calibrating")
            case .missing:       return String(localized: "\(label) unavailable")
            }
        }
        let chargePhrase = phrase(String(localized: "Charge"), charge)
        let effortPhrase = phrase(String(localized: "Effort"), effort)
        let restPhrase = phrase(String(localized: "Rest"), rest)
        return String(localized: "NOOP. \(chargePhrase), \(effortPhrase), \(restPhrase).")
    }

    // Snapshot recency now comes straight from the shared contract (`freshnessText` / `isStale` on
    // WatchScoreSnapshot) so the watch app glance and this complication phrase age identically. The
    // old local ageString helper was retired with that move.
}

// MARK: - Widget declaration

struct NOOPChargeComplication: Widget {
    let kind = "NOOPChargeComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ChargeProvider()) { entry in
            NOOPChargeView(entry: entry)
                .containerBackground(NoopVisualStyle.canvas, for: .widget)
        }
        .configurationDisplayName("NOOP Charge")
        .description("Your Charge (recovery) on the watch face, with Effort and Rest in the rectangular card.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular
        ])
    }
}
