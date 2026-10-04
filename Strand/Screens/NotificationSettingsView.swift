import SwiftUI
import AppKit
import StrandDesign

/// Notifications — choose which Mac apps tap your wrist, and how.
/// Real app icons via NSWorkspace; per-app on/off + buzz pattern; quiet hours.
struct NotificationSettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @StateObject private var store = NotificationSettingsStore()

    var body: some View {
        ScreenScaffold(title: "Notifications",
                       subtitle: "Buzz your strap when these apps notify you. Everything runs on \(Platform.deviceNounPhrase).") {
            hero
                .staggeredAppear(index: 0)
            // #926: the "every pattern buzzes the same on a 5/MG" note that used to sit here is GONE —
            // the limitation it described is fixed. overallLoop (byte 11 of the maverick haptic body)
            // is now written as `loops - 1` by `MaverickHaptics.notificationBuzz`, which `send` builds
            // the 5/MG body with, so all four patterns are distinct on that family too. Leaving the
            // note would be worse than never having had it: a caption telling the user their setting
            // does nothing, next to a control that now works. Kotlin twin carries the same note.
            deliveryNote
            NoopList {
                G6ToggleRow("Enable wrist alerts", isOn: $store.masterEnabled)
            }
            if store.activeCategories.isEmpty {
                emptyAppsCard
                    .staggeredAppear(index: 1)
            } else {
                ForEach(Array(store.activeCategories.enumerated()), id: \.element.id) { idx, cat in
                    categorySection(cat, apps: store.apps(in: cat))
                        .staggeredAppear(index: idx + 1)
                }
            }
            behaviourSection
                .staggeredAppear(index: store.activeCategories.count + 1)
        }
    }

    // MARK: - Hero

    /// The ink hero: what wrist alerts do, the strap's state, how many apps are on, and the test buzz.
    private var hero: some View {
        NoopHeroCard(glow: .ink, padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge("Wrist alerts", icon: "bell-ringing")
                    Spacer(minLength: 8)
                    HStack(spacing: 7) {
                        Circle().fill(strapStateColor).frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(verbatim: strapPillTitle)
                            .font(StrandFont.book(12, relativeTo: .caption))
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule(style: .continuous).fill(Color.white.opacity(0.07)))
                    .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                }
                Text("When on, NOOP taps your wrist for the apps you pick below, so you can leave the \(Platform.deviceNoun) and still feel what matters.")
                    .font(StrandFont.light(19, relativeTo: .title3))
                    .tracking(-0.2)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 22)
                HStack(alignment: .center, spacing: 10) {
                    NoopPill(verbatim: store.enabledCount == 1 ? String(localized: "1 app on")
                                                               : String(localized: "\(store.enabledCount) apps on"),
                             compact: true)
                    Spacer(minLength: 8)
                    Button {
                        model.buzz(loops: 2)
                    } label: {
                        HStack(spacing: 8) {
                            PhIcon("wave-sine", size: 16)
                            Text("Test buzz")
                        }
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))
                    .disabled(!live.bonded)
                    .help(live.bonded ? "Fire a test buzz now" : "Connect your strap to test")
                    .accessibilityHint(live.bonded ? "Fires a test buzz on your strap" : "Connect your strap to enable")
                }
                .padding(.top, 20)
            }
        }
    }

    private var deliveryNote: some View {
        G13WarnNote("Wrist delivery isn't live yet. It needs a small on-device watcher (coming in an update) to read macOS notifications. Everything stays on this Mac. Your choices are saved now and will apply automatically once delivery ships.",
                    icon: "info")
    }

    /// Strap status — mirrors SettingsView's three-state mapping so the label and its state dot always
    /// agree (and never read "connected" while the strap is offline).
    private var strapPillTitle: String {
        if live.connected { return String(localized: "Strap connected") }
        if live.bonded { return String(localized: "Strap idle") }          // paired but offline — won't deliver
        return String(localized: "Strap not connected")
    }
    private var strapStateColor: Color {
        if live.connected { return StrandPalette.statusPositive }
        if live.bonded { return StrandPalette.statusWarning }
        return StrandPalette.statusCritical
    }

    // MARK: - Category section

    private func categorySection(_ cat: NotifCategory, apps: [NotifApp]) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle(verbatim: cat.rawValue) {
                PhIcon(Self.phosphor(cat.symbol), size: 16)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            NoopList {
                ForEach(apps) { app in appRow(app) }
            }
        }
        .opacity(store.masterEnabled ? 1 : StrandPalette.disabledOpacity)
        .disabled(!store.masterEnabled)
    }

    private var emptyAppsCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                NoopCardHeader("No supported apps found", icon: "bell-slash") { EmptyView() }
                    .padding(.bottom, -2)
                Text("NOOP looks for known notification apps on \(Platform.deviceNounPhrase): Mail, Outlook, WhatsApp, Teams, Messages, Slack and similar. Install one and it'll appear here automatically.")
                    .font(StrandFont.light(14, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func appRow(_ app: NotifApp) -> some View {
        let enabled = store.isEnabled(app.id)
        return HStack(spacing: 14) {
            appIcon(app)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(enabled ? "Buzzes your wrist" : "Off")
                    .font(StrandFont.light(12, relativeTo: .caption))
                    .foregroundStyle(StrandPalette.textTertiary)
            }

            Spacer(minLength: 8)

            if enabled {
                patternMenu(app)
                testButton(app)
            }

            Toggle("", isOn: Binding(
                get: { store.isEnabled(app.id) },
                set: { store.setEnabled(app.id, $0) }))
                .labelsHidden()
                .toggleStyle(.noop)
                .fixedSize()
                .accessibilityLabel("\(app.name) wrist alerts")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minHeight: 58)
    }

    private func appIcon(_ app: NotifApp) -> some View {
        Group {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                NoopIconTile(Self.phosphor(app.fallbackSymbol))
            }
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private func patternMenu(_ app: NotifApp) -> some View {
        Menu {
            ForEach(BuzzPattern.allCases) { p in
                Button {
                    store.setPattern(app.id, p)
                } label: {
                    if store.pattern(app.id) == p {
                        Label(p.label, systemImage: "checkmark")
                    } else {
                        Text(p.label)
                    }
                }
            }
        } label: {
            NoopChip(verbatim: store.pattern(app.id).label, icon: "wave-sine")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the buzz pattern for \(app.name)")
    }

    private func testButton(_ app: NotifApp) -> some View {
        Button {
            model.buzz(loops: store.pattern(app.id).loops)
        } label: {
            NoopCircleIcon("play", size: 30)
        }
        .buttonStyle(.plain)
        .disabled(!live.bonded)
        .opacity(live.bonded ? 1 : 0.4)
        .help(live.bonded ? "Test \(app.name) buzz" : "Connect your strap to test")
        .accessibilityLabel("Test \(app.name) buzz")
        .accessibilityHint(live.bonded ? "Fires a test buzz on your strap" : "Connect your strap to enable")
    }

    // MARK: - Behaviour

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("Behaviour")
            G6Footnote("Fine-tune when alerts reach your wrist.")
                .padding(.horizontal, 4)
            NoopList {
                G6ToggleRow("Only buzz when worn",
                            caption: Text("Skip alerts when the strap is off your wrist."),
                            isOn: $store.onlyWhenWorn)
                G6ToggleRow("Quiet hours",
                            caption: Text("Mute wrist alerts overnight."),
                            isOn: $store.quietHoursEnabled)
                if store.quietHoursEnabled {
                    quietHoursRow
                }
            }
        }
    }

    private var quietHoursRow: some View {
        HStack(spacing: 12) {
            Text("From")
                .font(StrandFont.book(15, relativeTo: .body))
                .foregroundStyle(StrandPalette.textPrimary)
            DatePicker("", selection: quietStartBinding, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)
                .accessibilityLabel("Quiet hours start")
            Text("to")
                .font(StrandFont.light(15, relativeTo: .body))
                .foregroundStyle(StrandPalette.textSecondary)
            DatePicker("", selection: quietEndBinding, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)
                .accessibilityLabel("Quiet hours end")
            Spacer(minLength: 0)
        }
        .tint(StrandPalette.textPrimary)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minHeight: 54)
    }

    // MARK: - Quiet-hours bindings

    private var quietStartBinding: Binding<Date> {
        Binding(get: { Self.date(fromMinutes: store.quietStartMinutes) },
                set: { store.quietStartMinutes = Self.minutes(from: $0) })
    }
    private var quietEndBinding: Binding<Date> {
        Binding(get: { Self.date(fromMinutes: store.quietEndMinutes) },
                set: { store.quietEndMinutes = Self.minutes(from: $0) })
    }
    private static func date(fromMinutes m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
    private static func minutes(from d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// The Phosphor glyph for a category/app symbol (the store names SF Symbols).
    private static func phosphor(_ sf: String) -> String {
        switch sf {
        case "envelope.fill": return "envelope"
        case "message.fill": return "chat-circle"
        case "video.fill": return "video-camera"
        case "calendar": return "calendar"
        case "paperplane.fill": return "paper-plane-tilt"
        case "checklist": return "list-checks"
        default: return "bell"
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Notifications") {
    let model = AppModel()
    model.live.bonded = true
    model.live.connected = true
    return NotificationSettingsView()
        .environmentObject(model)
        .environmentObject(model.live)
        .frame(width: 760, height: 940)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}
#endif
