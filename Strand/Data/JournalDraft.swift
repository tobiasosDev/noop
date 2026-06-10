import Foundation
import WhoopStore

/// In-progress answers for one day, before they are written to the journal table.
/// `answers[question] == nil` means "not answered" (the — state) and is omitted on save.
struct JournalDraft {
    let day: String                                  // YYYY-MM-DD (Repository.localDayKey)
    var answers: [String: Bool] = [:]                // question → yes/no
    var notes: [String: String] = [:]                // question → free text

    /// Build the persistable entries: only answered questions; empty notes normalise to nil.
    func entries() -> [JournalEntry] {
        answers.compactMap { (question, yes) in
            let note = notes[question]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return JournalEntry(day: day, question: question,
                                answeredYes: yes,
                                notes: (note?.isEmpty == false) ? note : nil)
        }
    }
}
