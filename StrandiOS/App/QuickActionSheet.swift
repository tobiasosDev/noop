#if os(iOS)
import SwiftUI
import StrandDesign

/// The destinations the centre FAB can present. `.menu` is the action sheet itself; the rest
/// route to existing screens. `Identifiable` so it drives `.sheet(item:)`.
enum QuickAction: Int, Identifiable {
    case menu, live, workout, journal, breathe
    var id: Int { rawValue }
}

/// The bottom sheet of quick actions opened by Today's + button: a grab handle, the QUICK ACTIONS
/// overline with a close circle, four action rows that route to existing screens, and the Updates inbox
/// row when the host can open it.
struct QuickActionSheet: View {
    /// Called with the picked destination (the host swaps the menu for that screen).
    let onPick: (QuickAction) -> Void
    /// Opens the Updates inbox. nil hides the row, so the sheet never offers a destination the host
    /// cannot reach.
    var onUpdates: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var updates = UpdateStore.shared
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    /// Journal entries in the last seven days, nil until read (the caption then omits the count).
    @State private var journalDays: Int?

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(width: 38, height: 5)
                .padding(.top, 9)
                .accessibilityHidden(true)

            HStack {
                NoopOverline("QUICK ACTIONS")
                Spacer()
                NoopCircleButton("x", size: 34, accessibilityLabel: "Close") { dismiss() }
            }
            .padding(.leading, 22)
            .padding(.trailing, 20)
            .padding(.top, 12)
            .padding(.bottom, 14)

            VStack(spacing: 10) {
                NoopList {
                    row("Live HR", caption: Text("Stream your heart rate"), icon: "heartbeat", status: liveStatus) {
                        onPick(.live)
                    }
                    row("Start workout", caption: Text(verbatim: workoutCaption), icon: "person-simple-run") {
                        onPick(.workout)
                    }
                    row("Log journal", caption: Text(verbatim: journalCaption), icon: "notebook") {
                        onPick(.journal)
                    }
                    row("Breathe", caption: Text("Paced breathing"), icon: "wind") { onPick(.breathe) }
                }
                if let onUpdates {
                    NoopList { updatesRow(onUpdates) }
                }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(NoopSheetBackground())
        .task(id: repo.refreshSeq) { await loadJournalDays() }
    }

    // MARK: Rows

    /// One `.qa .li` row: 46 pt gradient icon tile, 16 pt title (with an optional inline status), a
    /// 12.5 pt caption, and a faint chevron.
    private func row(_ title: LocalizedStringKey, caption: Text, icon: String, status: Text? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                PhIcon(icon, size: 21)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 46, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(LinearGradient(colors: [Color(light: "#EDECE8", dark: "#232327"),
                                                          Color(light: "#E2E1DD", dark: "#18181B")],
                                                 startPoint: .top, endPoint: .bottom))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(NoopVisualStyle.border, lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(StrandFont.book(16, relativeTo: .body))
                            .foregroundStyle(StrandPalette.textPrimary)
                        if let status {
                            HStack(spacing: 5) {
                                Circle().fill(StrandPalette.textPrimary).frame(width: 6, height: 6)
                                status
                            }
                            .font(StrandFont.book(11, relativeTo: .caption2))
                            .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    caption
                        .font(StrandFont.light(12.5, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PhIcon("caret-right", size: 16)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .opacity(0.4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func updatesRow(_ open: @escaping () -> Void) -> some View {
        let unread = updates.unreadCount
        return Button(action: open) {
            HStack(spacing: 14) {
                NoopIconTile("bell-simple")
                HStack(spacing: 4) {
                    Text("Updates")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                    if unread > 0 {
                        Text("· \(unread) new")
                            .font(StrandFont.light(15, relativeTo: .body))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if unread > 0 {
                    Circle().fill(StrandPalette.textPrimary).frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                PhIcon("caret-right", size: 16)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .opacity(0.4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Captions (all from data the app already holds)

    /// "Strap ready" only when a strap link is up; nothing is claimed otherwise.
    private var liveStatus: Text? {
        live.connected ? Text("Strap ready") : nil
    }

    /// "Live zones · Effort target 67–86" — the window comes from today's own scored Charge through the
    /// same resolver Today uses; no Charge yet, no window.
    private var workoutCaption: String {
        let scale = UnitPrefs.resolveEffortScale(effortScaleRaw)
        guard let target = TodayEffortTarget.text(recovery: repo.today?.recovery, scale: scale) else {
            return String(localized: "Live zones")
        }
        return String(localized: "Live zones · Effort target \(target)")
    }

    private var journalCaption: String {
        guard let journalDays else { return String(localized: "Tonight's check-in") }
        return String(localized: "Tonight's check-in · \(journalDays) of 7 days")
    }

    /// The same seven local days the Today journal strip reads (`JournalReminderCard`).
    private func loadJournalDays() async {
        let cal = Calendar.current
        let today = Date()
        let from = Repository.localDayKey(cal.date(byAdding: .day, value: -6, to: today) ?? today)
        let to = Repository.localDayKey(today)
        journalDays = await repo.nativeJournalDays(from: from, to: to).count
    }
}
#endif
