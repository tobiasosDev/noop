import SwiftUI
import StrandDesign

/// Coach settings, split out of `CoachView` so the coach screen is the conversation and nothing else
/// (#2243). Holds the surfaces that used to stack above the transcript: the model, the data-sharing
/// consent, the two further opt-ins that depend on it, the editable coach instructions and the morning
/// brief — and, since the v2 Coach header carries only the connection pill and this screen's button,
/// the connection itself: Update key, Clear conversation and Disconnect.
///
/// Presented as a sheet rather than pushed. CoachView appears in three places between the two
/// platforms (a macOS route, an iPhone tab root whose navigation bar is hidden, and an iPhone pillar
/// sheet), and a sheet is the one presentation that behaves the same in all three without depending on
/// an enclosing NavigationStack.
struct CoachSettingsView: View {
    @EnvironmentObject var coach: AICoachEngine
    @Environment(\.dismiss) private var dismiss

    /// Morning-brief settings, read from `CoachBriefScheduler` on init exactly as `CoachView` did
    /// before the split. This screen can now be the first to render them.
    @State private var briefEnabled: Bool = CoachBriefScheduler.isEnabled
    @State private var briefMinutes: Int = CoachBriefScheduler.timeMinutes
    @State private var briefGenerating = false
    @State private var briefStatus: String?

    /// The coach-instructions editor text, seeded from the engine when the screen appears.
    @State private var promptDraft: String = ""
    @State private var promptLoaded = false

    /// The inline replacement-key editor (Update key). Cleared on save so a secret does not sit in view
    /// state after it has been stored.
    @State private var showKeyEditor = false
    @State private var keyFix = ""
    @State private var showClearConfirm = false
    @State private var showDisconnectConfirm = false

    var body: some View {
        // The back circle of the shared header closes the sheet. ScreenScaffold is a bare ScrollView with
        // no NavigationStack, so a toolbar item presented in a sheet would render nowhere, and a macOS
        // sheet has no swipe-to-dismiss: without the in-content control this screen would have no way
        // out. (#2206 is the same mistake in the other direction.)
        ScreenScaffold(title: nil) {
            NoopScreenHeader("Coach settings")
                .accessibilityHint(Text("Close coach settings"))
                .padding(.bottom, 4)
            statusHero
            NoopSectionTitle("Provider") { modelsRefreshedCaption }
            modelList
            NoopSectionTitle("What the coach sees", captionKey: "Per question")
            sharingList
            NoopSectionTitle("Coach instructions", captionKey: "Sent with every question")
            instructionsEditor
            NoopSectionTitle("Morning brief", captionKey: "Local notification")
            morningBriefList
            if coach.isConfigured {
                connectionList
                    .padding(.top, 18)
                Text("Disconnecting deletes the key and this conversation from \(Platform.deviceNounPhrase).")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
            }
        }
        .noopHidesSystemNavBar()
        // Opening this screen is the moment a stale catalogue is worth refreshing: a key exists here by
        // definition, and the picker above is about to be read. Rate-limited and silent on failure.
        .task { await coach.refreshModelsIfStale() }
        .onAppear {
            guard !promptLoaded else { return }
            promptDraft = coach.customSystemPrompt
            promptLoaded = true
        }
        .confirmationDialog("Clear conversation?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { coach.clearConversation() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the saved conversation from this device. Coach history is your own notes, not medical advice.")
        }
        .confirmationDialog("Disconnect provider?", isPresented: $showDisconnectConfirm, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Forget the saved key and disconnect")
        }
    }

    // MARK: - Hero

    private var questionsToday: Int { coach.messages.filter { $0.role == .user }.count }
    private var repliesToday: Int { coach.messages.filter { $0.role == .assistant }.count }

    /// The ink status hero: whether a provider is connected, how much of today's conversation there is,
    /// and what the next request carries.
    private var statusHero: some View {
        NoopHeroCard(glow: .ink, padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if coach.isConfigured {
                        NoopIconBadge("Connected", icon: "plugs-connected")
                    } else {
                        NoopIconBadge("Not connected", icon: "plugs")
                    }
                    Spacer(minLength: 8)
                    NoopPill(verbatim: coach.provider.v2ShortName, compact: true)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    NoopDotNumber("\(questionsToday)", size: 72)
                    Text("questions\ntoday")
                        .font(StrandFont.light(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary.opacity(0.78))
                        .lineSpacing(2)
                        .padding(.bottom, 8)
                }
                .padding(.top, 26)
                NoopMetricRow {
                    NoopMetric(value: tokenValue, unit: tokenUnit, label: "Next request")
                    NoopMetric(value: coach.dataConsent ? "14" : "0", unit: String(localized: "days"),
                               label: "Context window")
                    NoopMetric(value: "\(repliesToday)", label: "Replies today")
                }
                .padding(.top, 22)
            }
        }
    }

    /// The K12 estimate for the next request, split into number + unit ("1.2" + "k").
    private var tokenEstimate: Int? { coach.estimatedTokens(forDraft: "") }
    private var tokenValue: String {
        guard let t = tokenEstimate else { return "—" }
        return t >= 1000 ? String(format: "%.1f", Double(t) / 1000) : "\(t)"
    }
    private var tokenUnit: String? {
        guard let t = tokenEstimate else { return nil }
        return t >= 1000 ? "k" : String(localized: "tokens")
    }

    // MARK: - Provider

    /// When this provider's live catalogue was last pulled (the weekly refresh or a manual one).
    @ViewBuilder private var modelsRefreshedCaption: some View {
        let last = UserDefaults.standard.double(forKey: AICoachEngine.modelsRefreshedKey(coach.provider))
        if last > 0 {
            Text("Models refreshed \(relativeAgo(last))")
        }
    }

    /// Which model answers, and the control that refreshes the list of them.
    ///
    /// This lives HERE rather than on the setup card because of where a key exists. `setupCard` renders
    /// only while `isConfigured` is false, which for a cloud provider means no key is stored, and the
    /// Refresh control is `.disabled(!coach.hasKey)` — gated on having a key inside a screen that only
    /// appears when there is none. So for OpenAI, Anthropic and Gemini that button was permanently
    /// disabled and the live catalogue those three publish was unreachable. A key exists by definition
    /// on this screen, so the picker and the refresh both work.
    ///
    /// The PROVIDER deliberately stays on the setup card. A stored key records which provider it
    /// belongs to and is never sent anywhere else, so switching provider here would leave a key that
    /// cannot be used and a screen that cannot fix it. Kotlin twin: `CoachModelCard`.
    @ViewBuilder private var modelList: some View {
        if coach.provider == .openRouter {
            OpenRouterModelSelection()
        } else {
            NoopList {
                Menu {
                    Picker("Model", selection: $coach.model) {
                        ForEach(coach.availableModels, id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        G3RowLabel(title: Text("Model"), caption: Text(verbatim: coach.provider.v2ShortName), icon: "cpu")
                        Text(verbatim: coach.model.isEmpty ? "—" : coach.model)
                            .font(StrandFont.light(14, relativeTo: .subheadline))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(1)
                        PhIcon("caret-up-down").opacity(0.55)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 15)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityLabel("Model")

                Button {
                    Task { await coach.refreshModels() }
                } label: {
                    G3RowLabel(title: Text("Refresh models"), icon: "arrows-clockwise")
                        .padding(.horizontal, 18)
                        .padding(.vertical, 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!coach.hasKey)
                .opacity(coach.hasKey ? 1 : 0.45)
                .accessibilityLabel("Refresh models from provider")
            }
        }
    }

    // MARK: - What the coach sees

    /// The three opt-ins, in dependency order. The second and third only mean anything once data access
    /// is on (the engine gates them behind `dataConsent` too), so they stay visible but dimmed until it
    /// is; the chart image is additionally Gemini-only.
    private var sharingList: some View {
        NoopList {
            // Explicit, revocable permission for the coach to read & send the user's data. Off by
            // default. The ON line NAMES what a session carries rather than saying "workouts" and leaving
            // the reader to guess how much that is: the sport, how long, how far and how hard, per
            // session. This toggle is the only place someone is asked to agree to it. Android says the
            // same sentence (#2033).
            G3ToggleRow(
                title: Text("Let the coach use my data"),
                caption: coach.dataConsent
                    ? Text("On: your charge, rest, HRV and workouts are sent to the provider, each workout with its sport, duration, distance and heart rate.")
                    : Text("Off: the coach answers generally and sends none of your metrics."),
                icon: "database",
                isOn: $coach.dataConsent
            )
            .accessibilityLabel("Let the coach use my data")

            // v5: a SECOND opt-in folds a SUMMARY of the new on-device signals (strongest n-of-1
            // patterns + Lab Book markers) into the coach context. Summary-only, never raw readings.
            G3ToggleRow(
                title: Text("Also share my patterns & Lab Book"),
                caption: coach.includeOnDeviceSignals
                    ? Text("On: a short summary of your strongest patterns and logged health numbers is added. Summaries only, never raw readings.")
                    : Text("Off: only your core metrics are shared, not your patterns or Lab Book."),
                icon: "flask",
                isOn: $coach.includeOnDeviceSignals
            )
            .disabled(!coach.dataConsent)
            .opacity(coach.dataConsent ? 1 : 0.45)
            .accessibilityLabel("Also share my patterns and Lab Book with the coach")

            // K11: a third opt-in — a chart image alongside the text, for Gemini's multimodal API only.
            G3ToggleRow(
                title: Text("Send chart image to Gemini"),
                caption: coach.provider != .gemini
                    ? Text("Only for Gemini")
                    : coach.multimodalChartEnabled
                        ? Text("On: a chart snapshot of your trends is sent with each question. Gemini can analyze the visual.")
                        : Text("Off: only text is sent. Enable to let Gemini see your charts."),
                icon: "image-square",
                isOn: $coach.multimodalChartEnabled
            )
            .disabled(!chartImageAvailable)
            .opacity(chartImageAvailable ? 1 : 0.45)
            .accessibilityLabel("Send chart image to Gemini")
        }
    }

    private var chartImageAvailable: Bool { coach.dataConsent && coach.provider == .gemini }

    // MARK: - Instructions

    /// Editable system prompt, the instructions that frame the coach. Edits persist to UserDefaults
    /// through the engine and take effect on the next message; Reset restores the built-in default.
    private var instructionsEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $promptDraft)
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textPrimary.opacity(0.84))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120, maxHeight: 240)
                .onChangeCompat(of: promptDraft) { newValue in
                    guard promptLoaded else { return }
                    coach.customSystemPrompt = newValue
                }
                .accessibilityLabel("Coach instructions editor")
            Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
                .padding(.top, 12)
            HStack {
                Button {
                    coach.resetSystemPrompt()
                    promptDraft = coach.customSystemPrompt
                } label: {
                    HStack(spacing: 6) {
                        PhIcon("arrow-counter-clockwise", size: 15)
                        Text("Reset to default").font(StrandFont.book(13, relativeTo: .footnote))
                    }
                    .foregroundStyle(StrandPalette.textPrimary)
                }
                .buttonStyle(.plain)
                .disabled(!coach.hasCustomSystemPrompt)
                .opacity(coach.hasCustomSystemPrompt ? 1 : 0.45)
                .accessibilityLabel("Reset coach instructions to default")
                Spacer()
                Text(coach.hasCustomSystemPrompt ? "Customised" : "Default")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(NoopVisualStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1))
    }

    // MARK: - Morning brief

    /// K5: the scheduled morning-brief notification settings — enable toggle, time-of-day picker, and an
    /// explicit "Generate now" button. Mirrors the `ScheduledDebugExport` settings row shape (TestCentreView).
    @ViewBuilder private var morningBriefList: some View {
        NoopList {
            G3ToggleRow(
                title: Text("Morning brief"),
                caption: briefEnabled
                    ? Text("A local notification with today's readiness + training plan, generated on-device each morning.")
                    : Text("Off: nothing is generated or sent on a schedule."),
                icon: "sun-horizon",
                isOn: $briefEnabled
            )
            .accessibilityLabel("Morning brief")
            .onChangeCompat(of: briefEnabled) { on in
                CoachBriefScheduler.setEnabled(on, generateBrief: { await coach.generateBrief() }) { outcome in
                    if outcome == .denied {
                        briefEnabled = false
                        briefStatus = "Notifications are off for NOOP — enable them in Settings first."
                    }
                }
            }
            if briefEnabled {
                HStack(spacing: 14) {
                    G3RowLabel(title: Text("Time"), icon: "clock")
                    DatePicker("", selection: briefTimeBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .accessibilityLabel("Morning brief time")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(minHeight: 52)

                Button(action: generateBriefNow) {
                    HStack(spacing: 14) {
                        G3RowLabel(title: briefGenerating ? Text("Generating…") : Text("Generate now"),
                                   icon: "sparkle")
                        if briefGenerating { ProgressView().controlSize(.small) }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 15)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(briefGenerating)
            }
        }
        if briefEnabled {
            Text("At \(Platform.deviceNounPhrase == "Mac" ? "this time" : "or soon after"), NOOP will use your key to generate today's brief. Best-effort: \(Platform.deviceNounPhrase) decides exactly when a backgrounded app wakes.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        if let briefStatus {
            Text(briefStatus)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.horizontal, 4)
        }
    }

    private var briefTimeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = briefMinutes / 60
                c.minute = briefMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let m = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                briefMinutes = m
                CoachBriefScheduler.setTimeMinutes(m, generateBrief: { await coach.generateBrief() })
            }
        )
    }

    private func generateBriefNow() {
        Task {
            briefGenerating = true
            briefStatus = nil
            defer { briefGenerating = false }
            let text = await CoachBriefScheduler.generateNow { await coach.generateBrief() }
            if let text {
                coach.appendGeneratedBrief(text)
            } else {
                briefStatus = "Couldn't generate a brief right now — check your key and data access."
            }
        }
    }

    // MARK: - Connection

    /// #2206: Update key, Clear conversation and Disconnect, drawn where every presentation of Coach can
    /// reach them. `RootTabView` hides the navigation bar of every primary tab root, so toolbar items on
    /// the Coach tab rendered nowhere, and Disconnect was at one time the only route back to the setup
    /// card: a key could be set once and never changed. This sheet opens from the Coach header in each
    /// presentation (tab, pillar sheet, macOS route), so the actions are reachable in all of them.
    ///
    /// Worth knowing before changing `disconnect()`: neither `hasKey` nor `isConfigured` is published,
    /// since `hasKey` reads the Keychain on each evaluation. The setup card reappears because
    /// `disconnect()` ALSO assigns the published `messages`, which is what re-evaluates the body. A
    /// future disconnect that stopped clearing the transcript would clear the key and leave the Coach
    /// screen showing a chat for a connection that no longer exists.
    @ViewBuilder private var connectionList: some View {
        NoopList {
            Button {
                showKeyEditor.toggle()
                if !showKeyEditor { keyFix = "" }
            } label: {
                HStack(spacing: 14) {
                    G3RowLabel(title: Text("Update key"), icon: "key")
                    PhIcon(showKeyEditor ? "caret-down" : "caret-right", size: 14)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showKeyEditor { keyEditor }

            Button {
                showClearConfirm = true
            } label: {
                HStack(spacing: 14) {
                    G3RowLabel(title: Text("Clear conversation"), icon: "chat-circle-dots")
                    Text("\(coach.messages.count) messages")
                        .font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(coach.messages.isEmpty)
            .opacity(coach.messages.isEmpty ? 0.45 : 1)
            .accessibilityLabel("Clear conversation")

            Button(role: .destructive) {
                showDisconnectConfirm = true
            } label: {
                HStack(spacing: 14) {
                    PhIcon("plugs", size: 17)
                        .foregroundStyle(NoopGlow.heart.tint)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: NoopVisualStyle.tileRadius, style: .continuous)
                            .fill(NoopVisualStyle.raised))
                    Text("Disconnect")
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(NoopGlow.heart.tint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Disconnect provider")
        }
    }

    /// The replacement-key field under Update key. Saving goes through `setKey`, which replaces the
    /// stored key and leaves the transcript alone.
    private var keyEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PhIcon("lock-simple").opacity(0.5)
                SecureField("Paste your \(coach.provider.displayName) API key", text: $keyFix)
                    .textFieldStyle(.plain)
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .onSubmit(saveKey)
                    .accessibilityLabel("API key")
            }
            .foregroundStyle(StrandPalette.textPrimary)
            .g3FieldChrome()
            NoopButton("Update key", kind: .primary, fullWidth: true, action: saveKey)
                .disabled(keyFix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let error = coach.errorText, !error.isEmpty {
                Text(error)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func saveKey() {
        let trimmed = keyFix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        coach.setKey(trimmed)
        guard coach.errorText == nil else { return }
        keyFix = ""
        showKeyEditor = false
    }

    /// Forget the key and the conversation, then close: the Coach screen behind returns to setup.
    private func disconnect() {
        coach.disconnect()
        keyFix = ""
        showKeyEditor = false
        dismiss()
    }
}
