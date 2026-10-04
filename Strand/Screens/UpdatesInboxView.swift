import SwiftUI
import StrandDesign

// MARK: - Updates inbox
//
// The sheet behind the Today header's bell. A calm, newest-first log of what's new — release notes,
// "new data arrived" readings, strap heads-ups, and the Today info-cards the user swiped away (which
// can be restored from here). Tapping an actionable row routes via NavRouter; a dismissed-card row
// offers "Restore to Today". Everything is on-device and non-clinical — informational, never a verdict.
//
// Sheet idiom matches WhatsNewView: a FIXED macOS frame (a macOS sheet hosting a ScrollView collapses
// without one) and iOS presentationDetents via `noopSheetPresentation`.
struct UpdatesInboxView: View {
    @EnvironmentObject var updateStore: UpdateStore
    @EnvironmentObject var router: NavRouter
    let onClose: () -> Void

    private var unread: [UpdateItem] { updateStore.sortedItems.filter { !$0.read } }
    private var read: [UpdateItem] { updateStore.sortedItems.filter { $0.read } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                topBar
                titleBlock
                    .padding(.bottom, 10)
                if updateStore.items.isEmpty {
                    emptyState
                } else {
                    // The newest unread item leads as the hero; the rest list below it.
                    if let lead = unread.first {
                        UpdateLeadCard(item: lead, onTap: { handleTap(lead) },
                                       onMarkRead: { markRead(lead) }, onRestore: { restore(lead) })
                    }
                    let rest = updateStore.sortedItems.filter { $0.id != unread.first?.id }
                    let restUnread = rest.filter { !$0.read }
                    if !restUnread.isEmpty {
                        section("New", trailing: String(localized: "\(restUnread.count) unread"), items: restUnread)
                    }
                    if !read.isEmpty {
                        section("Earlier", trailing: nil, items: read)
                    }
                    footer
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        #if os(iOS)
        // #697/#horizontal-swipe parity, see ScreenScaffold.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        #if os(iOS) && DEBUG
        .modifier(DemoScrollAnchor())
        #endif
        #if os(macOS)
        // A fixed frame is mandatory — a macOS sheet hosting a ScrollView collapses to nothing without
        // one (same reason WhatsNewView pins 560×640).
        .frame(width: 460, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceBase)
    }

    // MARK: Header

    /// Close on the left, "Mark all read" on the right.
    private var topBar: some View {
        HStack(spacing: 12) {
            NoopCircleButton("caret-left", accessibilityLabel: "Close", action: onClose)
            Spacer()
            Button {
                StrandHaptic.selection.play()
                withAnimation(StrandMotion.interactive) { updateStore.markAllRead() }
            } label: {
                NoopPill("Mark all read", icon: "checks")
            }
            .buttonStyle(.plain)
            .disabled(updateStore.unreadCount == 0)
            .opacity(updateStore.unreadCount == 0 ? 0.45 : 1)
        }
        .padding(.bottom, 6)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            NoopOverline("Inbox")
            Text("Updates")
                .font(StrandFont.title1)
                .tracking(-0.56)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var subtitle: String {
        let n = updateStore.unreadCount
        if updateStore.items.isEmpty { return String(localized: "What's new in the app and your data") }
        return n == 0 ? String(localized: "All caught up") : String(localized: "\(n) unread")
    }

    // MARK: Content

    private func section(_ label: LocalizedStringKey, trailing: String?, items: [UpdateItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                NoopOverline(label)
                Spacer()
                if let trailing {
                    Text(verbatim: trailing)
                        .font(StrandFont.book(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .padding(.horizontal, 4)
            NoopList {
                ForEach(items) { item in
                    UpdateRow(item: item, onTap: { handleTap(item) }, onRestore: { restore(item) })
                }
            }
        }
        .padding(.top, 18)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            PhIcon("checks", size: 20)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 56, height: 56)
                .background(Circle().fill(NoopVisualStyle.inset))
                .overlay(Circle().strokeBorder(NoopVisualStyle.border, lineWidth: 1))
            Text("You're all caught up.")
                .font(StrandFont.light(18, relativeTo: .headline))
                .foregroundStyle(StrandPalette.textPrimary)
            Text("New release notes and fresh data will land here.")
                .font(StrandFont.light(12.5, relativeTo: .caption))
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 32)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                StrandHaptic.selection.play()
                withAnimation(StrandMotion.interactive) { updateStore.clearAll() }
            } label: {
                NoopChip("Clear all", icon: "trash")
            }
            .buttonStyle(.plain)
            .disabled(updateStore.items.isEmpty)
            Spacer()
        }
        .padding(.top, 18)
    }

    private func markRead(_ item: UpdateItem) {
        StrandHaptic.selection.play()
        withAnimation(StrandMotion.interactive) { updateStore.markRead(item.id) }
    }

    // MARK: Actions

    /// Tapping a row marks it read, then routes if it carries a known deep link (else just stays open).
    private func handleTap(_ item: UpdateItem) {
        StrandHaptic.selection.play()
        withAnimation(StrandMotion.interactive) { updateStore.markRead(item.id) }
        guard let key = item.deepLink, let dest = NavRouter.Destination(deepLinkKey: key) else { return }
        // Route via the shell, then close this sheet so the destination is visible.
        router.requestedDestination = dest
        onClose()
    }

    /// Restore a dismissed Today card: flip its `@AppStorage` flag back (so it reappears), drop the
    /// inbox item, and close so the card is on screen.
    private func restore(_ item: UpdateItem) {
        StrandHaptic.selection.play()
        if let payload = item.restorePayload {
            // Clear the dismissed flag directly using the SAME key TodayView writes, so a Today that's
            // already mounted under the sheet picks the card back up immediately.
            UserDefaults.standard.set(false, forKey: TodayCardDismissal.flagKey(payload))
        }
        updateStore.requestRestore(item)
        onClose()
    }
}

// MARK: - Rows

/// The Phosphor glyph and the plain label of each update kind.
private extension UpdateItem.Kind {
    var icon: String {
        switch self {
        case .dismissedCard: return "cards"
        case .whatsNew:      return "sparkle"
        case .reading:       return "pulse"
        case .strapAlert:    return "warning"
        // Distinct from `.whatsNew`'s sparkle on purpose: this is something you have NOT got yet.
        case .newVersion:    return "download-simple"
        }
    }
}

/// Short relative time for an update ("Yesterday", "2 hours ago").
private func updateRelativeDate(_ date: Date) -> String {
    updateRelativeFormatter.localizedString(for: date, relativeTo: Date())
}

/// Built once: every inbox row asks for its relative date on each render.
private let updateRelativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    f.dateTimeStyle = .named
    return f
}()

/// The newest unread update as the screen's hero: its title and message, then its action (open the
/// destination, or restore a dismissed card) beside Mark read.
private struct UpdateLeadCard: View {
    let item: UpdateItem
    let onTap: () -> Void
    let onMarkRead: () -> Void
    let onRestore: () -> Void

    var body: some View {
        NoopHeroCard(glow: .ink, padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    NoopIconBadge(verbatim: item.title, icon: item.kind.icon)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Circle().fill(StrandPalette.textPrimary).frame(width: 6, height: 6)
                        Text(verbatim: updateRelativeDate(item.date))
                    }
                    .font(StrandFont.light(12, relativeTo: .caption))
                    .foregroundStyle(Color.white.opacity(0.65))
                    .fixedSize()
                }
                Text(item.message)
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(Color.white.opacity(0.84))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 22)
                HStack(spacing: 8) {
                    if item.kind == .dismissedCard {
                        Button(action: onRestore) { heroChip("Restore to Today", primary: true) }
                            .buttonStyle(.plain)
                    } else if item.deepLink != nil {
                        Button(action: onTap) { heroChip("See what changed", primary: true) }
                            .buttonStyle(.plain)
                    }
                    Button(action: onMarkRead) { heroChip("Mark read", primary: false) }
                        .buttonStyle(.plain)
                }
                .padding(.top, 22)
            }
            .padding(.top, 20)
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Unread. \(item.title). \(item.message)"))
    }

    private func heroChip(_ title: LocalizedStringKey, primary: Bool) -> some View {
        Text(title)
            .font(StrandFont.book(13, relativeTo: .subheadline))
            .foregroundStyle(primary ? NoopVisualStyle.canvas : StrandPalette.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Capsule(style: .continuous).fill(primary ? StrandPalette.textPrimary : Color.white.opacity(0.08)))
            .overlay(Capsule(style: .continuous).strokeBorder(primary ? Color.clear : Color.white.opacity(0.14), lineWidth: 1))
    }
}

private struct UpdateRow: View {
    let item: UpdateItem
    let onTap: () -> Void
    let onRestore: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            G6IconTile(icon: item.kind.icon, size: 34)
                .overlay(alignment: .topTrailing) {
                    if !item.read {
                        Circle().fill(StrandPalette.textPrimary)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(NoopVisualStyle.surface, lineWidth: 1.5))
                            .offset(x: 3, y: -3)
                            .accessibilityHidden(true)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(item.read ? StrandPalette.textSecondary : StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(verbatim: updateRelativeDate(item.date))
                        .font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize()
                }
                Text(item.message)
                    .font(StrandFont.light(12.5, relativeTo: .caption))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if item.kind == .dismissedCard {
                    Button(action: onRestore) {
                        NoopChip("Restore to Today", icon: "arrow-counter-clockwise")
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.read ? "\(item.title). \(item.message)"
                                       : "Unread. \(item.title). \(item.message)")
    }
}

// MARK: - Today card dismissal keys (shared)
//
// The Today info-cards persist their dismissed state in `@AppStorage` under a stable per-card key. The
// inbox restores a card by clearing that same key, so the key shape lives in ONE place both sides use.
enum TodayCardDismissal {
    /// The `@AppStorage` bool key for a Today info-card's dismissed flag, by stable card id.
    static func flagKey(_ cardID: String) -> String { "noop.todayCard.\(cardID).dismissed" }
}
