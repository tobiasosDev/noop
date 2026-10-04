import WidgetKit
import SwiftUI
import StrandDesign

/// K10: A Lock Screen / Home Screen widget showing the stored Coach morning brief.
///
/// Design contract (see PRD-K10 + D8):
/// - The widget reads **stored** brief text from the App Group — it NEVER calls the network.
///   The brief is generated on a schedule by `CoachBriefScheduler` (K5) and mirrored into the
///   App Group via `publishToWidget`. The widget just displays whatever text is there.
/// - Tap → opens the Coach tab (via the app's URL scheme / deeplink).
/// - Supported families: `accessoryRectangular` (Lock Screen), `systemSmall` (Home Screen).
///   The Lock Screen accessory shows the first line; the Home Screen widget shows more.
struct CoachBriefEntry: TimelineEntry {
    let date: Date
    let briefText: String?
    let briefDate: Date?
}

struct CoachBriefProvider: TimelineProvider {
    /// App Group keys — must match `CoachBriefScheduler.K.widgetBriefKey` / `.widgetBriefDateKey`.
    private static let briefKey = "coachBrief.widgetText"
    private static let briefDateKey = "coachBrief.widgetDate"

    func placeholder(in context: Context) -> CoachBriefEntry {
        CoachBriefEntry(
            date: Date(),
            briefText: "Recovery is strong today — consider a higher-intensity session this afternoon.",
            briefDate: Date()
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (CoachBriefEntry) -> Void) {
        let entry = loadEntry()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CoachBriefEntry>) -> Void) {
        let entry = loadEntry()
        // Refresh every 30 minutes — the app pushes a reload via WidgetCenter when a new brief is
        // published, so this is just a safety net for when the app isn't running.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())
            ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadEntry() -> CoachBriefEntry {
        let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName)
        let text = defaults?.string(forKey: CoachBriefProvider.briefKey)
        let date = defaults?.object(forKey: CoachBriefProvider.briefDateKey) as? Date
        return CoachBriefEntry(date: Date(), briefText: text, briefDate: date)
    }
}

struct CoachBriefWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CoachBriefEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            rectangular
        case .accessoryInline:
            inline
        default:
            small
        }
    }

    // MARK: - Lock Screen: accessoryRectangular

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                PhIcon("sparkle", size: 11)
                Text("Coach")
                    .font(StrandFont.medium(11))
                Spacer(minLength: 0)
                if let date = entry.briefDate {
                    Text(date, style: .time)
                        .font(StrandFont.light(10))
                        .foregroundStyle(HierarchicalShapeStyle.secondary)
                }
            }
            Text(briefDisplay)
                .font(StrandFont.book(11))
                .lineLimit(3)
                .minimumScaleFactor(0.8)
        }
    }

    // MARK: - Lock Screen: accessoryInline

    private var inline: some View {
        Text(briefOneLine)
    }

    // MARK: - Home Screen: systemSmall

    /// The brief's first sentence as the headline and the rest under it, with the brief's time at the
    /// foot (`Coach` header with the sparkle, as in the app).
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(icon: "sparkle", title: Text("Coach"))
            if entry.briefText == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No brief yet")
                        .font(StrandFont.book(13.5))
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text("Enable Morning Brief in Coach settings to see today's readiness here.")
                        .font(StrandFont.light(11))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 12)
            } else {
                let parts = briefParts
                VStack(alignment: .leading, spacing: 6) {
                    Text(parts.head)
                        .font(StrandFont.book(13.5))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(parts.tail == nil ? 5 : 3)
                        .minimumScaleFactor(0.85)
                    if let tail = parts.tail {
                        Text(tail)
                            .font(StrandFont.light(11.5))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }
                }
                .padding(.top, 12)
            }
            Spacer(minLength: 0)
            if let date = entry.briefDate {
                HStack(spacing: 3) {
                    Text("Brief")
                    Text(verbatim: "·")
                    Text(date, format: .dateTime.hour().minute())
                }
                .font(StrandFont.light(10))
                .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    /// The brief split after its first sentence, so the opening line can lead and the rest support it.
    private var briefParts: (head: String, tail: String?) {
        let text = briefDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        let enders: [Character] = [".", "!", "?", "\n"]
        guard let cut = text.firstIndex(where: { enders.contains($0) }),
              text.index(after: cut) < text.endIndex else { return (text, nil) }
        let head = String(text[...cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = String(text[text.index(after: cut)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (head, tail.isEmpty ? nil : tail)
    }

    private var briefDisplay: String {
        entry.briefText ?? "No brief available."
    }

    /// One-line summary for the inline accessory (capped at ~100 chars).
    private var briefOneLine: String {
        guard let text = entry.briefText else { return "Coach: no brief yet" }
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 100 else { return "Coach: \(trimmed)" }
        let cut = trimmed.index(trimmed.startIndex, offsetBy: 100)
        return "Coach: \(trimmed[..<cut].trimmingCharacters(in: .whitespaces))…"
    }
}

struct CoachBriefWidget: Widget {
    static let kind = "CoachBriefWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: CoachBriefProvider()) { entry in
            if #available(iOS 17.0, *) {
                CoachBriefWidgetView(entry: entry)
                    .containerBackground(for: .widget) { WidgetCardBackground() }
            } else {
                CoachBriefWidgetView(entry: entry)
                    .padding()
                    .background(WidgetCardBackground())
            }
        }
        .configurationDisplayName("Coach Brief")
        .description("Today's coaching brief at a glance. Tap to open Coach.")
        .supportedFamilies([
            .systemSmall,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}
