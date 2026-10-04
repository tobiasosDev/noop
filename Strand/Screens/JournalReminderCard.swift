import SwiftUI
import StrandDesign

// MARK: - Journal widget (Today screen) — #627
//
// A persistent Today widget for the Journal: a WHOOP-style strip of the last `stripDays` days
// (filled = a journal entry that day, today ringed) plus an always-present tap-through to the journal.
// The Journal (behavioural logging that feeds Insights / "What Moves You") is otherwise only reachable
// inside the Insights screen, which isn't a primary destination — easy to forget, and the only proactive
// prompt is the once-a-morning sleep sheet — missed on any day you don't open Sleep. This surfaces it on
// Today where it can't be missed, and doubles as the "direct link to Insights" the report (#627) asked for.
//
// Opt-out via `PuffinExperiment.journalReminderKey` (default ON — the same key also gates the Android
// morning sleep sheet twin). Read-only: it never writes a journal entry. Twin of Android
// `JournalReminderCard` (android/.../ui/JournalReminder.kt). v2: a neutral card with the week as day
// cells, the same chrome as the other Today cards.

struct JournalReminderCard: View {

    @EnvironmentObject var repo: Repository
    @EnvironmentObject var router: NavRouter

    /// Default ON so the reminder works out of the box; the Settings toggle / this key opt out.
    @AppStorage(PuffinExperiment.journalReminderKey) private var reminderEnabled = true

    /// Which of the last `stripDays` day-keys carry a native journal entry. nil = still loading / read
    /// error → render nothing (never a misleading all-empty strip).
    @State private var loggedDays: Set<String>?

    private static let stripDays = 7

    var body: some View {
        // A real container while enabled, so the load `.task` attaches even before the first read lands
        // (on an empty `Group` the task has nothing to attach to, and the card would never appear).
        if reminderEnabled {
            VStack(spacing: 0) {
                if let logged = loggedDays {
                    card(logged)
                }
            }
            // Re-read whenever a sync bumps refreshSeq or the toggle flips (mirrors AutoWorkoutCard's task
            // id), so the strip and the "logged today" state stay current after the user logs and comes back.
            .task(id: JournalReminderLoadKey(seq: repo.refreshSeq, enabled: reminderEnabled)) {
                await reload()
            }
        }
    }

    /// The v2 journal card: the state line as its title (log today / catch up / logged), the week's
    /// logged-day count at the right, and the seven-day strip — each day its own tap target that
    /// deep-links the journal to that day (#656); today is the ink cell.
    private func card(_ logged: Set<String>) -> some View {
        let keys = Self.dayKeys()
        let todayKey = keys.last ?? ""
        let todayLogged = logged.contains(todayKey)
        // A recent PAST day with no entry — surfaces the tap-a-day-to-backfill interaction once today is
        // done (#656).
        let hasMissed = keys.contains { $0 != todayKey && !logged.contains($0) }
        let title: String = !todayLogged ? String(localized: "Log today's journal")
            : hasMissed ? String(localized: "Tap a day to catch up")
            : String(localized: "Logged today")
        let loggedCount = keys.filter { logged.contains($0) }.count
        // No outer Button: each day is its own tap target (#656), and nested SwiftUI buttons don't work —
        // so the header carries its own tap (→ today) and the days carry theirs. The regions don't
        // overlap, so a tap lands on exactly one.
        return VStack(alignment: .leading, spacing: 0) {
            NoopCardHeader(verbatim: title, icon: "notebook") {
                Text("\(loggedCount) of \(Self.stripDays) days")
            }
            .contentShape(Rectangle())
            .onTapGesture { router.openJournal() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text(String(localized: "Open journal")))
            .padding(.bottom, 2)
            HStack(spacing: 6) {
                ForEach(keys.indices, id: \.self) { i in
                    let key = keys[i]
                    let off = Self.stripDays - 1 - i          // keys[0] = 6 days ago … last = today
                    dayCell(key: key, isToday: off == 0, isLogged: logged.contains(key))
                        .contentShape(Rectangle())
                        .onTapGesture { router.openJournal(day: off) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(Self.barLabel(off))
                        .accessibilityValue(logged.contains(key) ? Text("Logged") : Text("Not logged"))
                }
            }
            .padding(.top, 14)
        }
        .padding(NoopVisualStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .noopPanel(cornerRadius: NoopVisualStyle.cardRadius)
    }

    /// One `.wk` day cell: the short weekday over a dot — ink when logged, faint when not; today is the
    /// ink cell with black type.
    private func dayCell(key: String, isToday: Bool, isLogged: Bool) -> some View {
        VStack(spacing: 4) {
            Text(verbatim: Self.weekdayLabel(key))
                .font(StrandFont.light(10))
                .foregroundStyle(isToday ? Color.black : StrandPalette.textTertiary)
            Circle()
                .fill(isToday ? Color.black.opacity(isLogged ? 1 : 0.25)
                              : (isLogged ? StrandPalette.textPrimary : NoopVisualStyle.quaternaryText))
                .frame(width: 6, height: 6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isToday ? StrandPalette.textPrimary : NoopVisualStyle.raised))
    }

    /// "Sun", "Mon" … for a day key, in the user's language.
    private static func weekdayLabel(_ key: String) -> String {
        guard let date = keyParser.date(from: key) else { return "" }
        return date.formatted(.dateTime.weekday(.abbreviated).locale(AppLanguage.activeLocale))
    }

    private static let keyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Screen-reader label for a strip bar (#656): the day it deep-links to. Twin of JournalLogCard's
    /// day-picker labels; "%lld days ago" is a String Catalog key so it stays localized.
    private static func barLabel(_ offset: Int) -> LocalizedStringKey {
        switch offset {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return "\(offset) days ago"
        }
    }

    private func reload() async {
        guard reminderEnabled else { loggedDays = nil; return }
        let keys = Self.dayKeys()
        loggedDays = await repo.nativeJournalDays(from: keys.first ?? "", to: keys.last ?? "")
    }

    /// The `stripDays` local-day keys (yyyy-MM-dd), oldest → today, matching Android's `journalDayKey`
    /// (civil-day arithmetic via Calendar so a DST edge can't mislabel a day).
    private static func dayKeys() -> [String] {
        let cal = Calendar.current
        let today = Date()
        return (0..<stripDays).reversed().map { n in
            Repository.localDayKey(cal.date(byAdding: .day, value: -n, to: today) ?? today)
        }
    }
}

/// Reload key: a sync (seq) or toggle flip re-reads completion. Mirrors `AutoWorkoutLoadKey`.
private struct JournalReminderLoadKey: Equatable {
    let seq: Int
    let enabled: Bool
}
