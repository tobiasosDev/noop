import Foundation

/// Whether the iOS app should auto-present yesterday's journal on becoming active.
///
/// The shell still checks the reminder opt-out, first-run gates, and that no other sheet is up.
/// This function is only the part that can be decided without the view: the morning window,
/// whether this calendar day already presented, and whether yesterday already has answers.
enum JournalMorningPrompt {
    /// Local calendar day (`yyyy-MM-dd`) on which the iOS app last auto-presented yesterday's journal.
    ///
    /// While `noopJournalReminder` is on, opening the app between 04:00 and 12:00 local presents
    /// yesterday's journal once per day, and only when yesterday has no native answers. Writing
    /// this key at presentation time stops a dismissal from opening the sheet again the same morning.
    static let shownDayKey = "noopJournalMorningShownDay"

    /// 04:00 inclusive through 12:00 exclusive, wall-clock time in `calendar`.
    /// `todayKey` is the local calendar day of `now` (not the 04:00 logical day).
    /// `shownDay` equal to `todayKey` means this morning already presented.
    static func shouldPresent(now: Date, calendar: Calendar, shownDay: String?,
                              todayKey: String, yesterdayAnswered: Bool) -> Bool {
        guard !yesterdayAnswered else { return false }
        guard shownDay != todayKey else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return minutes >= 4 * 60 && minutes < 12 * 60
    }
}
