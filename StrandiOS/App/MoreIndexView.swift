#if os(iOS)
import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - More index (iPhone)
//
// The More tab's catch-all index: a strap summary hero, then the four collapsible groups (Insights, Body,
// Data, App). Lives outside `RootTabView` so the DEBUG demo harness can render it on its own; the tab's
// NavigationStack and its single `navigationDestination(for: MoreDestination.self)` stay in the shell.

/// The More tab's root screen. Rows push `MoreDestination` VALUES so a re-tap of the More tab can pop them
/// off the tab's bound path (#135/#198).
struct MoreIndexView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore

    /// Which groups are expanded (S2). Insights + Body stay open at rest; Data + App collapse to a one-line
    /// summary until tapped. Persisted (#860 item 2) so the choice survives leaving the tab and relaunch:
    /// an `@AppStorage` CSV keyed identically to the Android `MoreSectionPrefs`, bridged to a `Set<String>`.
    @AppStorage(MoreSectionPrefs.storageKey) private var expandedCSV = MoreSectionPrefs.defaultCSV
    private var expanded: Set<String> { MoreSectionPrefs.decode(expandedCSV) }

    /// The header's search: a field under the title that filters every row of every group by name.
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScreenScaffold(title: "More", subtitle: "Everything else, one tap away",
                       onRefresh: { await repo.refresh() },
                       topBackground: liquidScaffoldSky(),
                       trailing: { headerButtons }) {
            if searching { searchField }
            if trimmedQuery.isEmpty {
                let groups = MoreGroup.all
                MoreStrapHero()
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    groupView(group, previousExpanded: index == 0 || expanded.contains(groups[index - 1].id))
                }
                footer
            } else {
                searchResults
            }
        }
    }

    // MARK: Header

    private var headerButtons: some View {
        HStack(spacing: 10) {
            NoopCircleButton(searching ? "x" : "magnifying-glass",
                             accessibilityLabel: searching ? "Close search" : "Search") {
                withAnimation(StrandMotion.interactive) {
                    searching.toggle()
                    if !searching { query = "" }
                }
                searchFocused = searching
            }
            // The avatar opens Settings, where the profile (and its photo) is edited.
            NavigationLink(value: MoreDestination.settings) {
                ProfileAvatarView(imageData: profile.avatarImageData, size: 42, placeholder: .disc)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Settings"))
        }
        .padding(.bottom, 2)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            PhIcon("magnifying-glass", size: 17)
                .foregroundStyle(StrandPalette.textTertiary)
            TextField(String(localized: "Search More"), text: $query)
                .font(StrandFont.book(15, relativeTo: .body))
                .foregroundStyle(StrandPalette.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    PhIcon("x", size: 14).foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(Capsule(style: .continuous).fill(NoopVisualStyle.surface))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
        .transition(.opacity)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    @ViewBuilder private var searchResults: some View {
        let matches = MoreGroup.all.flatMap(\.items).filter {
            $0.title.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        if matches.isEmpty {
            Text("No matches")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 30)
        } else {
            NoopList { ForEach(matches) { MoreRow(item: $0) } }
        }
    }

    // MARK: Groups

    /// One group: an open group is an overline header (title · count · caret) over its rows; a closed group
    /// collapses to a single summary card naming its first rows. Either way the header is the toggle.
    @ViewBuilder
    private func groupView(_ group: MoreGroup, previousExpanded: Bool) -> some View {
        let isOpen = expanded.contains(group.id)
        if isOpen {
            VStack(alignment: .leading, spacing: 12) {
                Button { toggle(group) } label: {
                    HStack(spacing: 10) {
                        overline(group)
                        Spacer(minLength: 8)
                        Text(verbatim: "\(group.items.count)")
                            .font(StrandFont.book(12, relativeTo: .caption))
                            .foregroundStyle(StrandPalette.textTertiary)
                        PhIcon("caret-up", size: 14).foregroundStyle(StrandPalette.textPrimary).opacity(0.5)
                    }
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(GroupToggleAccessibility(title: group.title, isOpen: true))
                NoopList { ForEach(group.items) { MoreRow(item: $0) } }
            }
            .padding(.top, 18)
        } else {
            Button { toggle(group) } label: {
                HStack(spacing: 12) {
                    overline(group).frame(width: 52, alignment: .leading)
                    // The "+N" sits outside the truncating names, so long (German) titles never cut it off.
                    HStack(spacing: 4) {
                        Text(verbatim: group.previewNames)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if group.previewRest > 0 {
                            Text(verbatim: "+\(group.previewRest)")
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .font(StrandFont.light(12.5, relativeTo: .caption))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: "\(group.items.count)")
                        .font(StrandFont.book(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Capsule(style: .continuous).fill(NoopVisualStyle.raised))
                    PhIcon("caret-down", size: 14).foregroundStyle(StrandPalette.textPrimary).opacity(0.5)
                }
                .padding(.leading, 18)
                .padding(.trailing, 16)
                .padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: NoopVisualStyle.listRadius, style: .continuous)
                    .fill(NoopVisualStyle.surface))
                .overlay(RoundedRectangle(cornerRadius: NoopVisualStyle.listRadius, style: .continuous)
                    .strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(GroupToggleAccessibility(title: group.title, isOpen: false))
            // A summary card right after an open group (or the hero) keeps the 30 pt section break; a run
            // of collapsed cards stacks at the column's 12 pt gap.
            .padding(.top, previousExpanded ? 18 : 0)
        }
    }

    private func overline(_ group: MoreGroup) -> some View {
        Text(verbatim: group.title)
            .font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .textCase(.uppercase)
            .foregroundStyle(StrandPalette.textSecondary)
    }

    private func toggle(_ group: MoreGroup) {
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
            // Persist through the CSV-backed @AppStorage (#860 item 2); MoreSectionPrefs owns encode/decode.
            var open = expanded
            if open.contains(group.id) { open.remove(group.id) } else { open.insert(group.id) }
            expandedCSV = MoreSectionPrefs.encode(open)
        }
    }

    private var footer: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return Text("NOOP \(version) · offline by design · nothing leaves this phone")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
    }
}

/// VoiceOver for a group header: the group name, its expanded state, and what a double tap does.
private struct GroupToggleAccessibility: ViewModifier {
    let title: String
    let isOpen: Bool
    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityValue(Text(isOpen ? String(localized: "Expanded") : String(localized: "Collapsed")))
            .accessibilityHint(Text(isOpen ? String(localized: "Double tap to collapse")
                                           : String(localized: "Double tap to expand")))
    }
}

// MARK: - Groups and rows

/// What a row shows at its trailing edge besides the chevron.
private enum MoreRowAccessory: Hashable {
    case none
    /// The Live row's connection hint, resolved by a leaf that observes `LiveState` on its own.
    case liveStatus
    /// A dot-matrix status tag (Rhythm's "Beta").
    case tag(String)
}

/// One destination in the index.
private struct MoreItem: Identifiable, Hashable {
    let title: String
    let icon: String
    let route: MoreDestination
    var accessory: MoreRowAccessory = .none
    var id: MoreDestination { route }
}

/// One collapsible group. `id` is the persisted key (`MoreSectionPrefs`), so it stays the English title.
private struct MoreGroup: Identifiable {
    let id: String
    let title: String
    let items: [MoreItem]

    /// "Your Data, Fused, Apple Health" + "+5": the collapsed card's summary of what is inside.
    var previewNames: String { items.prefix(2).map(\.title).joined(separator: ", ") }
    var previewRest: Int { max(items.count - 2, 0) }

    static var all: [MoreGroup] {
        [
            MoreGroup(id: "Insights", title: String(localized: "Insights"), items: [
                MoreItem(title: String(localized: "What Moves You"), icon: "graph", route: .insightsHub),
                MoreItem(title: String(localized: "Intelligence"), icon: "brain", route: .intelligence),
                // K3: Coach is a top-level tab, no longer listed under More.
                MoreItem(title: String(localized: "Insights"), icon: "lightbulb-filament", route: .insights),
                MoreItem(title: String(localized: "Explore"), icon: "compass", route: .explore),
                MoreItem(title: String(localized: "Compare"), icon: "git-diff", route: .compare),
            ]),
            MoreGroup(id: "Body", title: String(localized: "Body"), items: [
                MoreItem(title: String(localized: "Live"), icon: "heartbeat", route: .live, accessory: .liveStatus),
                MoreItem(title: String(localized: "Workouts"), icon: "person-simple-run", route: .workouts),
                MoreItem(title: String(localized: "Lift Log"), icon: "barbell", route: .liftLog),
                MoreItem(title: String(localized: "Health"), icon: "first-aid-kit", route: .health),
                MoreItem(title: String(localized: "Lab Book"), icon: "flask", route: .labBook),
                MoreItem(title: String(localized: "Stress"), icon: "wave-sine", route: .stress),
                MoreItem(title: String(localized: "Breathe"), icon: "wind", route: .breathe),
                MoreItem(title: String(localized: "Intervals"), icon: "timer", route: .intervals),
                // Experimental beat-to-beat regularity visualization — self-gates on its own consent.
                MoreItem(title: String(localized: "Rhythm"), icon: "pulse", route: .rhythm,
                         accessory: .tag(String(localized: "Beta"))),
            ]),
            MoreGroup(id: "Data", title: String(localized: "Data"), items: [
                MoreItem(title: String(localized: "Your Data, Fused"), icon: "stack", route: .fusedRecord),
                MoreItem(title: String(localized: "Apple Health"), icon: "heart", route: .appleHealth),
                MoreItem(title: String(localized: "Mi Band"), icon: "watch", route: .miBand),
                MoreItem(title: String(localized: "Data Sources"), icon: "database", route: .dataSources),
                MoreItem(title: String(localized: "Backup & Sync"), icon: "hard-drives", route: .backupSync),
                // #155: HealthKit-free Apple Health path for sideloaded installs (Siri Shortcut reads the
                // opt-in Documents/noop_sync.txt drop file).
                MoreItem(title: String(localized: "Shortcuts Export"), icon: "export", route: .shortcutsExport),
                // The plain 4.0 vs 5.0/MG capability grid — what NOOP reads live off each strap.
                MoreItem(title: String(localized: "NOOP Limitations"), icon: "list-checks", route: .noopLimitations),
            ]),
            MoreGroup(id: "App", title: String(localized: "App"), items: [
                // #805/#811: the v7.3.1 #766 alarm consolidation moved Smart Alarm under a single "Alarms"
                // sidebar entry (RootView .smartAlarm) but the regression dropped the row from the iPhone
                // More list, leaving Alarms unreachable on iPhone. Restored here (SmartAlarmView, the
                // cross-platform iOS/macOS surface).
                //
                // Notifications (RootView .notifications) is deliberately NOT listed: that screen is
                // macOS-only (it picks which Mac apps tap your wrist via NSWorkspace, imports AppKit, and
                // project.yml excludes Screens/NotificationSettingsView.swift from the iOS target).
                // iPhone's wrist-alert controls live on the Automations screen instead.
                MoreItem(title: String(localized: "Alarms"), icon: "alarm", route: .alarms),
                MoreItem(title: String(localized: "Automations"), icon: "magic-wand", route: .automations),
                // The Test Centre (the diagnostics + bug-report hub) gets a first-class home here, not just
                // buried in Settings, so the feedback loop is one tap from the More tab.
                MoreItem(title: String(localized: "Test Centre"), icon: "stethoscope", route: .testCentre),
                MoreItem(title: String(localized: "Siri & Shortcuts"), icon: "microphone", route: .siriShortcuts),
                // #477 lives here rather than inside Settings: the strap-battery levers are the ones people
                // reach for when a strap is running down, so they get their own row.
                MoreItem(title: String(localized: "Power saving"), icon: "battery-low", route: .powerSaving),
                MoreItem(title: String(localized: "Settings"), icon: "gear", route: .settings),
            ]),
        ]
    }
}

/// One tappable destination row: a 38 pt icon tile, the title, an optional trailing hint, and a chevron.
private struct MoreRow: View {
    let item: MoreItem

    var body: some View {
        NavigationLink(value: item.route) {
            HStack(spacing: 14) {
                PhIcon(item.icon, size: 18)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NoopVisualStyle.raised))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                Text(verbatim: item.title)
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                accessory
                PhIcon("caret-right", size: 15)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .opacity(0.38)
            }
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var accessory: some View {
        switch item.accessory {
        case .none:
            EmptyView()
        case .liveStatus:
            MoreLiveStatusHint()
        case .tag(let label):
            NoopTag(verbatim: label, size: 11)
        }
    }
}

/// The Live row's trailing hint. Its own view holding `LiveState`, so a connected strap's ~1 Hz publish
/// re-renders this caption only, never the index.
private struct MoreLiveStatusHint: View {
    @EnvironmentObject private var live: LiveState
    var body: some View {
        if live.connected {
            Text("Strap ready")
                .font(StrandFont.light(12.5, relativeTo: .caption))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
        }
    }
}

// MARK: - Strap hero

/// The strap summary at the top of More: the active device, its battery ring, last sync, runtime estimate
/// and firmware, with shortcuts to Devices and a manual sync. Waits for the device registry like Devices.
private struct MoreStrapHero: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if let registry = model.deviceRegistry {
            MoreStrapHeroLive(registry: registry)
        } else {
            MoreStrapHeroCard(summary: .empty, canSync: false, syncing: false, onSync: {})
        }
    }
}

/// Resolves the hero's figures from the registry and `LiveState` (the same sources Devices binds).
private struct MoreStrapHeroLive: View {
    @ObservedObject var registry: DeviceRegistry
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    private var active: PairedDevice? { registry.devices.first { $0.status == .active } }

    /// Same gate as Health's Sync now and `BLEManager.syncNow`'s own guard.
    private var canSync: Bool { live.connected && live.bonded && live.historyReady && !live.backfilling }

    var body: some View {
        MoreStrapHeroCard(summary: summary, canSync: canSync, syncing: live.backfilling,
                          onSync: { model.ble.syncNow() })
    }

    private var summary: MoreStrapSummary {
        guard let device = active else { return .empty }
        let isWhoop = SourceCoordinator.isWhoop(device)
        // The live battery belongs to the ACTIVE + connected device; a ring reports its own charge (#2075).
        let pct = live.connected
            ? LiveConsoleReadout.batteryPercent(activeIsWhoop: isWhoop, whoopPct: live.batteryPct,
                                                ringPct: live.ouraBatteryPct)
            : nil
        // Firmware for THIS device, never the last strap to connect (#1633), as Devices resolves it.
        let firmware = FirmwareAttribution.resolve(
            live: live.strapFirmware,
            perDevice: isWhoop ? FirmwareAttribution.prefKey(peripheralId: device.peripheralId)
                .flatMap { UserDefaults.standard.string(forKey: $0) } : nil,
            legacyGlobal: isWhoop ? UserDefaults.standard.string(forKey: "noop.lastFirmware") : nil,
            pairedCount: registry.devices.count)
        return MoreStrapSummary(
            name: device.displayName,
            isWhoop: isWhoop,
            status: live.connected ? .connected : (live.rebootInProgress ? .reconnecting : .offline),
            batteryPct: pct,
            runtime: live.connected && isWhoop ? runtime : nil,
            syncLine: syncLine,
            firmware: firmware)
    }

    /// "~3 days" / "~20 h" left, or "Charging". Under 48 h shows hours; nil when no discharge is banked
    /// yet, so the hero only ever shows an estimate the app trusts (#713/#992).
    private var runtime: (value: String, unit: String?)? {
        if live.charging == true { return (String(localized: "Charging"), nil) }
        guard let est = live.batteryEstimate else { return nil }
        let hours = est.hoursRemaining
        guard hours.isFinite, hours > 0 else { return nil }
        if hours < 48 { return ("~\(Int(hours.rounded()))", String(localized: "h")) }
        let days = Int((hours / 24).rounded())
        return ("~\(days)", days == 1 ? String(localized: "day") : String(localized: "days"))
    }

    private var syncLine: String? {
        if live.backfilling {
            return live.syncChunksThisSession > 0
                ? String(localized: "Syncing… \(live.syncChunksThisSession) chunks")
                : String(localized: "Syncing…")
        }
        if let ts = live.lastSyncedAt { return String(localized: "Synced \(relativeAgo(ts))") }
        return nil
    }
}

/// The figures the hero shows. `nil` name = no active device yet.
private struct MoreStrapSummary {
    enum Status { case connected, reconnecting, offline }
    var name: String?
    var isWhoop = true
    var status: Status = .offline
    var batteryPct: Int?
    var runtime: (value: String, unit: String?)?
    var syncLine: String?
    var firmware: String?

    static let empty = MoreStrapSummary()
}

/// The hero card itself: pure presentation over a `MoreStrapSummary`.
private struct MoreStrapHeroCard: View {
    let summary: MoreStrapSummary
    let canSync: Bool
    let syncing: Bool
    let onSync: () -> Void

    var body: some View {
        NoopHeroCard(glow: .ink, padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge(summary.isWhoop ? "Strap" : "Device", icon: "watch")
                    Spacer(minLength: 8)
                    if summary.name != nil { statusPill }
                }
                HStack(alignment: .center, spacing: 20) {
                    MoreBatteryRing(percent: summary.batteryPct)
                    details
                }
                .padding(.top, 20)
                HStack(spacing: 8) {
                    NavigationLink(value: MoreDestination.devices) {
                        MoreHeroChip(title: summary.name == nil ? "Add a device" : "Manage devices",
                                     icon: "devices", primary: true)
                    }
                    .buttonStyle(.plain)
                    if summary.name != nil {
                        Button(action: onSync) {
                            MoreHeroChip(title: syncing ? "Syncing…" : "Sync now", icon: "arrows-clockwise",
                                         primary: false)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSync)
                        .opacity(canSync || syncing ? 1 : 0.45)
                        .accessibilityHint(syncHint)
                    }
                }
                .padding(.top, 22)
            }
            .padding(.top, 20)
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
    }

    private var syncHint: Text {
        if canSync { return Text("Pulls your strap's stored history immediately, without waiting for the next automatic sync.") }
        return syncing ? Text("A sync is already in progress.") : Text("Connect your strap first.")
    }

    private var statusPill: some View {
        let connected = summary.status == .connected
        return HStack(spacing: 7) {
            Circle()
                .fill(Color.white.opacity(connected ? 1 : 0.4))
                .frame(width: 6, height: 6)
                .shadow(color: .white.opacity(connected ? 0.9 : 0), radius: 4)
            Group {
                switch summary.status {
                case .connected:    Text("Connected")
                case .reconnecting: Text("Reconnecting…")
                case .offline:      Text("Offline")
                }
            }
            .font(StrandFont.book(12, relativeTo: .caption))
            .foregroundStyle(StrandPalette.textPrimary)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let name = summary.name { Text(verbatim: name) } else { Text("No device yet") }
            }
            .font(StrandFont.light(23, relativeTo: .title2))
            .tracking(-0.46)
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Group {
                if summary.name == nil {
                    Text("Pair a strap to start recording.")
                } else if let line = summary.syncLine {
                    Text(verbatim: line)
                }
            }
            .font(StrandFont.light(12, relativeTo: .caption))
            .foregroundStyle(Color.white.opacity(0.6))
            .padding(.top, 4)
            if summary.name != nil {
                HStack(alignment: .top, spacing: 0) {
                    heroMetric(value: summary.runtime?.value ?? "—", unit: summary.runtime?.unit,
                               label: "Battery left")
                    heroMetric(value: summary.firmware ?? "—", unit: nil, label: "Firmware")
                }
                .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heroMetric(value: String, unit: String?, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value)
                    .font(StrandFont.value(19))
                    .tracking(-0.38)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let unit {
                    Text(verbatim: unit)
                        .font(StrandFont.book(10))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Text(label)
                .font(StrandFont.light(10.5))
                .foregroundStyle(Color.white.opacity(0.55))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The hero's 132 pt battery dial: a dotted outer ring, a faint track, the charge arc with a white knob
/// at its end, and the percent in the dot-matrix face.
private struct MoreBatteryRing: View {
    let percent: Int?

    var body: some View {
        let f = min(max(Double(percent ?? 0) / 100, 0), 1)
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [1, 4.5]))
                .frame(width: 126, height: 126)
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 5)
                .frame(width: 108, height: 108)
            if percent != nil, f > 0 {
                Circle()
                    .trim(from: 0, to: f)
                    .stroke(StrandPalette.textPrimary.opacity(0.92), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 108, height: 108)
                let a = Angle.degrees(-90 + 360 * f).radians
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .offset(x: 54 * CGFloat(cos(a)), y: 54 * CGFloat(sin(a)))
            }
            VStack(spacing: 7) {
                if let percent {
                    NoopDotNumber("\(percent)", unit: "%", size: 46, unitSize: 20)
                } else {
                    NoopDotNumber("--", size: 46)
                }
                Text("battery")
                    .font(StrandFont.light(11, relativeTo: .caption2))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        }
        .frame(width: 132, height: 132)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Battery"))
        .accessibilityValue(percent.map { Text(verbatim: "\($0)%") } ?? Text("Unknown"))
    }
}

/// The hero's 34 pt action capsule: ink-filled for the primary action, glass for the secondary one.
private struct MoreHeroChip: View {
    let title: LocalizedStringKey
    let icon: String
    let primary: Bool

    var body: some View {
        HStack(spacing: 6) {
            PhIcon(icon, size: 15)
            // German "Jetzt synchronisieren" overruns the half-width chip; scale it rather than cut it.
            Text(title).font(StrandFont.book(13, relativeTo: .subheadline)).lineLimit(1).minimumScaleFactor(0.75)
        }
        .foregroundStyle(primary ? NoopVisualStyle.canvas : StrandPalette.textPrimary)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Capsule(style: .continuous)
            .fill(primary ? StrandPalette.textPrimary : Color.white.opacity(0.08)))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(primary ? Color.clear : Color.white.opacity(0.14), lineWidth: 1))
        .contentShape(Capsule(style: .continuous))
    }
}

// MARK: - Destinations

/// Every screen the More index links to, as a `Hashable` value the tab's `NavigationPath` can carry
/// (#198): a closure-destination push would bypass the path and be un-poppable on tab re-tap. The
/// per-screen chrome lives at the single `navigationDestination(for:)` registration in `RootTabView.moreTab`.
enum MoreDestination: Hashable {
    case insightsHub, intelligence, coach, insights, explore, compare
    case live, workouts, liftLog, health, labBook, stress, breathe, intervals, rhythm
    case fusedRecord, appleHealth, miBand, dataSources, backupSync, shortcutsExport, noopLimitations
    case alarms, automations, testCentre, siriShortcuts, powerSaving, settings
    case devices

    @ViewBuilder var destination: some View {
        switch self {
        case .insightsHub:     InsightsHubView()
        case .intelligence:    IntelligenceView()
        case .coach:           CoachView()
        case .insights:        InsightsView()
        case .explore:         MetricExplorerView()
        case .compare:         CompareView()
        case .live:            LiveView()
        case .workouts:        WorkoutsView()
        case .liftLog:         LiftLogView()
        case .health:          HealthView()
        case .labBook:         LabBookView()
        case .stress:          StressView()
        case .breathe:         BreathingView()
        case .intervals:       IntervalTimerView()
        case .rhythm:          RhythmHost()
        case .fusedRecord:     FusedRecordHost()
        case .appleHealth:     AppleHealthView()
        case .miBand:          XiaomiBandView()
        case .dataSources:     DataSourcesView()
        case .noopLimitations: NoopLimitationsView()
        case .backupSync:      BackupSyncView()
        case .shortcutsExport: ShortcutExportSettingsView()
        case .alarms:          SmartAlarmView()
        case .automations:     AutomationsView()
        case .testCentre:      TestCentreView()
        case .siriShortcuts:   SiriShortcutsSettingsView()
        case .powerSaving:     PowerSavingView()
        case .settings:        SettingsView()
        case .devices:         DevicesView()
        }
    }
}
#endif
