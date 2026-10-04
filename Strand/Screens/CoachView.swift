import SwiftUI
import MarkdownUI
import StrandDesign

/// Coach, the one feature in NOOP that talks to the network.
///
/// It is strictly opt-in and bring-your-own-key: the user pastes their own OpenAI
/// or Anthropic API key (stored in the macOS Keychain by `AICoachEngine`), and only
/// a compact text summary of their metrics plus their question ever leaves the Mac.
/// Nothing is sent until a key is saved and a question asked.
///
/// This screen compiles against `AICoachEngine`'s public API (the macos-core agent's
/// contract): `hasKey`, `provider` / `provider.modelOptions`, `model`, `messages`,
/// `sending`, `errorText`, `setKey(_:)`, `clearKey()`, and `send(_:)`.
struct CoachView: View {
    @EnvironmentObject var coach: AICoachEngine
    /// K8: used by "Save to Journal" — saves the coach advice as a journal entry with the text
    /// in the notes field, so it appears alongside other journal entries in Insights.
    @EnvironmentObject var repo: Repository

    /// Draft text in the composer (the question being typed).
    /// K15: the composer draft is persisted to UserDefaults so it survives an app relaunch.
    /// Restored on first appear, saved on every change. Keyed identically to the Android twin.
    private static let draftKey = "coach.composerDraft"
    @State private var draft: String = UserDefaults.standard.string(forKey: "coach.composerDraft") ?? ""
    /// Pending key text in the setup card (never persisted here, handed to `setKey`).
    @State private var keyDraft: String = ""
    /// Whether the setup key field shows its text in the clear (the eye toggle).
    @State private var revealKey = false
    /// The replacement key, typed into the editor a rejection or Update key opens. Separate from
    /// `keyDraft` so the
    /// setup card's own field is untouched, and cleared on save so a secret does not sit in view state
    /// after it has been stored. Twin of the Kotlin `keyFix`.
    @State private var keyFix: String = ""
    @State private var showKeyEditor = false
    /// Whether the model selector is in free-text "Custom…" mode.
    @State private var customModel: Bool = false
    /// The id typed in the "Custom…" field.
    @State private var customModelDraft: String = ""
    @FocusState private var composerFocused: Bool

    /// K2: confirmation gate for the destructive "Clear conversation" toolbar action.
    @State private var showClearConfirm = false
    /// #2243: the coach settings, presented as a sheet. See `CoachSettingsView` for why a sheet
    /// rather than a push.
    @State private var showSettings = false
    /// The reply most recently saved to the journal, so its action reads "Saved" instead of offering
    /// the same save twice.
    @State private var savedReplyID: UUID?
    /// Height of the docked composer, measured so the transcript can scroll clear of it.
    @State private var dockHeight: CGFloat = 0
    #if os(iOS)
    /// The docked composer rides on the keyboard while it is up and above the floating tab bar
    /// otherwise; focus alone is not enough (a hardware keyboard focuses the field with no keyboard).
    @State private var keyboardVisible = false
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    /// Sentinel tag for the "Custom…" entry in the model Picker.
    private let customModelTag = "__custom__"
    /// Scroll target at the very end of the transcript.
    private let transcriptEndID = "coach.transcript.end"

    /// Contextual suggestion chips, derived from today's bands by `AICoachEngine.suggestions`
    /// (→ `CoachSuggestions`). Falls back to a stable generic set when there is no data. Recomputed
    /// on each body evaluation so a fresh sync immediately updates the chips.
    private var suggestions: [String] { coach.suggestions }

    var body: some View {
        screen
        // macOS only. On iOS these actions live in Coach settings instead, because this bar is hidden for
        // a primary tab root and VISIBLE in the pillar sheet, so leaving them here would render nothing
        // on the Coach tab and a duplicate of the menu in the sheet. One control per platform, reachable
        // in both of iOS's presentations. The `#if` sits on the CHAIN rather than inside the builder:
        // `ToolbarContentBuilder` is not relied on to accept an empty body, and the one other
        // conditional toolbar here (CoupledView) always yields an item on both platforms. (#2206)
        #if os(macOS)
        .toolbar {
            if coach.isConfigured {
                ToolbarItem {
                    Button {
                        toggleKeyEditor()
                    } label: {
                        Label("Update key", systemImage: "key.fill")
                    }
                }
                // K2: wipe the persisted + in-memory conversation. Confirmed, since it's destructive.
                ToolbarItem {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("Clear conversation", systemImage: "trash")
                    }
                    .help("Clear the saved conversation")
                    .accessibilityLabel("Clear conversation")
                    .disabled(coach.messages.isEmpty)
                }
                ToolbarItem {
                    Button(role: .destructive) {
                        coach.disconnect()
                        keyDraft = ""
                    } label: {
                        Label("Disconnect", systemImage: "gearshape")
                    }
                    .help("Forget the saved key and disconnect")
                    .accessibilityLabel("Disconnect provider")
                }
            }
        }
        #endif
        .noopHidesSystemNavBar()
        // #2243: coach settings. `repo` rides along because the scaffold's environment is not
        // inherited by a sheet's own view tree.
        .sheet(isPresented: $showSettings) {
            CoachSettingsView()
                .environmentObject(coach)
                .environmentObject(repo)
                #if os(iOS)
                .noopSheetPresentation(largeFirst: true)
                #endif
        }
        .confirmationDialog(
            "Clear conversation?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { coach.clearConversation() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the saved conversation from this device. Coach history is your own notes, not medical advice.")
        }
        // K2 + K5 ordering matters and every step gates on an EMPTY transcript, so this is ONE `.task`
        // running sequentially (separate `.task`s can interleave at their await points on the same
        // actor): restore whatever the prior launch persisted, THEN surface a brief the scheduled
        // notification already generated (if any), THEN the interactive first-open brief — so
        // `startBriefIfNeeded` only ever runs over the network when BOTH of the above left the
        // transcript genuinely empty.
        .task {
            await coach.loadPersistedMessagesIfNeeded()
            coach.retireStaleConversationIfNeeded()
            // Gated on the transcript BEFORE consuming. `consumeStoredBrief()` clears the unconsumed
            // flag, and `surfaceScheduledBrief` then drops the text if a transcript exists, so a brief
            // that arrived on a day with a conversation already open was consumed and thrown away, gone
            // for good. Android checked first and so only ever failed to SHOW it (#2087).
            if coach.messages.isEmpty, let stored = CoachBriefScheduler.consumeStoredBrief() {
                coach.surfaceScheduledBrief(stored)
            }
            CoachBriefScheduler.activateIfEnabled { await coach.generateBrief() }
            await coach.startBriefIfNeeded()
        }
        // #1862: a question handed over by the Today launcher sheet. Cleared BEFORE sending so a view
        // rebuild mid-flight cannot send it twice, and gated on `isConfigured` so an unconfigured handoff
        // (which the launcher does not produce, but a future caller might) degrades to showing setup
        // rather than a failed request.
        .task(id: coach.pendingPrompt) {
            guard let prompt = coach.pendingPrompt, !prompt.isEmpty else { return }
            coach.pendingPrompt = nil
            guard coach.isConfigured else { return }
            await coach.send(prompt)
        }
        // K15: persist the composer draft so it survives an app relaunch.
        .onChangeCompat(of: draft) { newValue in
            UserDefaults.standard.set(newValue, forKey: Self.draftKey)
        }
        // K14: haptic feedback when a reply arrives (sending goes true → false).
        .onChangeCompat(of: coach.sending) { isSending in
            if !isSending && !coach.messages.isEmpty {
                triggerReplyHaptic()
            }
        }
        // A consent toggle AFTER the initial load re-checks the brief (the original `.task(id:)`
        // behaviour); the guard inside `startBriefIfNeeded` (messages.isEmpty) keeps this a no-op once
        // a conversation exists.
        .onChangeCompat(of: coach.dataConsent) { _ in
            Task { await coach.startBriefIfNeeded() }
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        #endif
    }

    @ViewBuilder private var screen: some View {
        if coach.isConfigured {
            chatScreen
        } else {
            ScreenScaffold(title: nil) {
                header
                setupContent
            }
        }
    }

    // MARK: - Header

    /// The Coach header (`.chd`): a 17 pt title, the connection pill and the settings circle. On a
    /// presented Coach the shared screen header adds its back circle.
    private var header: some View {
        NoopScreenHeader("Coach") {
            providerPill
            // #2243: the way through to the coach settings (consent, instructions, brief, connection).
            NoopCircleButton("sliders-horizontal", accessibilityLabel: "Coach settings") {
                showSettings = true
            }
        }
        .padding(.bottom, 4)
    }

    /// The provider/model pill, or "Not connected" with a hollow dot before setup.
    private var providerPill: some View {
        let connected = coach.isConfigured
        return HStack(spacing: 7) {
            Circle()
                .fill(connected ? StrandPalette.textPrimary : Color.clear)
                .overlay(Circle().strokeBorder(connected ? Color.clear : StrandPalette.textTertiary, lineWidth: 1))
                .frame(width: 6, height: 6)
                .shadow(color: connected ? StrandPalette.textPrimary.opacity(0.6) : .clear, radius: 3)
            Group {
                if connected {
                    Text(verbatim: "\(coach.provider.v2ShortName) · \(coach.model)")
                } else {
                    Text("Not connected")
                }
            }
            .font(StrandFont.book(12, relativeTo: .caption))
            .foregroundStyle(connected ? StrandPalette.textSecondary : StrandPalette.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: 30)
        .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
        .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Setup (no key yet)

    @ViewBuilder private var setupContent: some View {
        setupHero
        NoopSectionTitle("Provider", captionKey: "Pick one")
        providerList
        if coach.provider == .custom { customServerFields }
        NoopSectionTitle(coach.provider == .custom ? "API key (optional)" : "API key") {
            Text(verbatim: coach.provider.v2ShortName)
        }
        setupKeyField
        Text("Kept in the Keychain on \(Platform.deviceNounPhrase). Never synced, never backed up.")
            .font(StrandFont.light(11.5, relativeTo: .caption))
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.top, -2)
        connectButton
            .padding(.top, 6)
        modelList
        // Whatever the last attempt from THIS card ran into. The setup card had no error line
        // at all, so every way it can fail before a key is committed failed silently: a Refresh
        // the provider turned away, a Connect to a server that wants auth. The wearer saw a
        // button do nothing. No repair affordance beside it, unlike the chat: the key field is
        // already on screen, which is the whole point of the card.
        if let error = coach.errorText, !error.isEmpty {
            errorBanner(error)
        }
        NoopSectionTitle("Try asking", captionKey: "After you connect")
        G3FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(suggestions, id: \.self) { G3PromptChip(text: $0) }
        }
        .opacity(0.5)
        .accessibilityHidden(true)
        privacyFootnote
            .padding(.top, 10)
    }

    /// The ink hero of the connect screen: what bring-your-own-key means, and the direct route from
    /// this device to the provider.
    private var setupHero: some View {
        NoopHeroCard(glow: .ink, padding: 22) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NoopIconBadge("Bring your own key", icon: "key")
                    Spacer(minLength: 8)
                    NoopPill("No server", compact: true)
                }
                Text("Connect a provider")
                    .font(StrandFont.title1)
                    .tracking(-0.56)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.top, 26)
                Text("Bring your own key. Questions go straight from \(Platform.deviceNounPhrase) to the provider you pick — NOOP runs no server.")
                    .font(StrandFont.light(14.5, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.8))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                routeDiagram
                    .padding(.top, 22)
            }
        }
        .padding(.top, 4)
    }

    /// This device ── DIRECT ── the provider: the request path, with no hop in between.
    private var routeDiagram: some View {
        HStack(alignment: .top, spacing: 10) {
            // A standalone label needs the nominative; the in-sentence "this %@" phrase cannot supply it in
            // gendered languages ("Diese iPhone").
            routeNode(icon: Platform.deviceNoun == "Mac" ? "desktop" : "device-mobile",
                      label: Text("This device"))
            ZStack {
                Rectangle()
                    .fill(.clear)
                    .frame(height: 1)
                    .overlay(
                        Line().stroke(StrandPalette.textPrimary.opacity(0.4),
                                      style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    )
                NoopTag("Direct", size: 12)
                    .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            routeNode(icon: coach.provider == .custom ? "hard-drives" : "cloud",
                      label: coach.provider == .custom ? Text("Your server") : Text("Your provider"))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Questions go directly to the provider"))
    }

    private func routeNode(icon: String, label: Text) -> some View {
        VStack(spacing: 7) {
            PhIcon(icon, size: 20)
                .frame(width: 46, height: 46)
                .background(Circle().fill(StrandPalette.textPrimary.opacity(0.10)))
                .overlay(Circle().strokeBorder(StrandPalette.textPrimary.opacity(0.16), lineWidth: 1))
            label
                .font(StrandFont.light(11, relativeTo: .caption2))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .frame(width: 70)
    }

    /// Single-choice provider list (`.list` + `.rad`), in the order the design lists them.
    private var providerList: some View {
        NoopList {
            ForEach([AIProvider.anthropic, .openAI, .gemini, .custom]) { p in
                providerRow(p)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Provider")
    }

    private func providerRow(_ p: AIProvider) -> some View {
        let selected = coach.provider == p
        return Button {
            coach.provider = p
        } label: {
            HStack(spacing: 14) {
                G3RowLabel(title: Text(verbatim: p.v2ShortName), caption: p.v2Caption, icon: p.v2Icon)
                G3RadioMark(isOn: selected)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .frame(minHeight: 52)
            .background(selected ? NoopVisualStyle.inset : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Server URL + key header for the Custom (OpenAI-compatible / local LLM) provider.
    @ViewBuilder private var customServerFields: some View {
        NoopSectionTitle("Server URL")
        HStack(spacing: 10) {
            PhIcon("hard-drives").opacity(0.5)
            TextField("http://localhost:11434/v1", text: $coach.customBaseURL)
                .textFieldStyle(.plain)
                .font(StrandFont.book(15, relativeTo: .body))
                .foregroundStyle(StrandPalette.textPrimary)
                .disableAutocorrection(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .accessibilityLabel("Server URL")
        }
        .g3FieldChrome()
        Text("Any OpenAI-compatible server: Ollama, LM Studio, llama.cpp, or your own gateway. Stays on your network; nothing leaves \(Platform.deviceNounPhrase).")
            .font(StrandFont.light(11.5, relativeTo: .caption))
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
        VStack(alignment: .leading, spacing: 8) {
            NoopOverline("Key header")
            SegmentedPillControl(CustomAIAuthHeader.allCases, selection: $coach.customAuthHeader,
                                 fillsAvailableWidth: true) { $0.displayName }
                .accessibilityLabel("Key header")
            Text("Use Bearer for most local servers; use x-api-key for gateways that require the key in that header.")
                .font(StrandFont.light(11.5, relativeTo: .caption))
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .padding(.top, 6)
    }

    /// The key field (`.fld`): lock, the secret (masked unless revealed), the eye toggle and Paste.
    private var setupKeyField: some View {
        HStack(spacing: 10) {
            PhIcon("lock-simple").opacity(0.5)
            Group {
                if revealKey {
                    TextField(setupKeyPlaceholder, text: $keyDraft)
                } else {
                    SecureField(setupKeyPlaceholder, text: $keyDraft)
                }
            }
            .textFieldStyle(.plain)
            .font(StrandFont.book(15, relativeTo: .body))
            .foregroundStyle(StrandPalette.textPrimary)
            .disableAutocorrection(true)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .onSubmit { coach.provider == .custom ? connectCustom() : saveKey() }
            .accessibilityLabel("API key")
            Button {
                revealKey.toggle()
            } label: {
                PhIcon(revealKey ? "eye" : "eye-slash").opacity(0.6)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealKey ? Text("Hide key") : Text("Show key"))
            Button(action: pasteKey) {
                NoopChip("Paste")
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .g3FieldChrome()
    }

    private var setupKeyPlaceholder: String {
        coach.provider == .custom
            ? String(localized: "Only if your server requires one")
            // The section caption already names the provider; the short form keeps the placeholder whole
            // beside the reveal and Paste controls in longer languages.
            : String(localized: "Paste your key")
    }

    @ViewBuilder private var connectButton: some View {
        if coach.provider == .custom {
            NoopButton("Connect", kind: .primary, fullWidth: true, action: connectCustom)
                .disabled(coach.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else {
            NoopButton("Connect", kind: .primary, fullWidth: true, action: saveKey)
                .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// Model selector + "Refresh models": a menu over `coach.availableModels` with a free-text
    /// "Custom…" path, and the button that fetches the provider's live list.
    @ViewBuilder private var modelList: some View {
        NoopList {
            Menu {
                Picker("Model", selection: modelPickerSelection) {
                    ForEach(coach.availableModels, id: \.self) { m in
                        Text(m).tag(m)
                    }
                    Divider()
                    Text("Custom…").tag(customModelTag)
                }
            } label: {
                HStack(spacing: 10) {
                    G3RowLabel(title: Text("Model"), caption: Text(verbatim: coach.provider.v2ShortName), icon: "cpu")
                    Text(verbatim: coach.model.isEmpty ? "—" : coach.model)
                        .font(StrandFont.light(14, relativeTo: .subheadline))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                    PhIcon("caret-up-down").opacity(0.6)
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
            .opacity(coach.hasKey ? 1 : 0.5)
            .help("Fetch the available models from \(coach.provider.displayName) using your saved key")
            .accessibilityLabel("Refresh models from provider")
        }
        if customModel {
            HStack(spacing: 10) {
                TextField("Enter a model id", text: $customModelDraft)
                    .textFieldStyle(.plain)
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .disableAutocorrection(true)
                    .onSubmit(applyCustomModel)
                    .accessibilityLabel("Custom model id")
                Button(action: applyCustomModel) { NoopChip("Use") }
                    .buttonStyle(.plain)
                    .disabled(customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Use custom model")
            }
            .g3FieldChrome()
        }
    }

    /// Bridges the model Picker to `coach.model`, with a "Custom…" sentinel that opens the free-text
    /// field instead of selecting a real id.
    private var modelPickerSelection: Binding<String> {
        Binding(
            get: { customModel ? customModelTag : coach.model },
            set: { newValue in
                if newValue == customModelTag {
                    customModel = true
                    if customModelDraft.isEmpty { customModelDraft = coach.model }
                } else {
                    customModel = false
                    coach.model = newValue
                }
            }
        )
    }

    private func applyCustomModel() {
        let trimmed = customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        coach.setCustomModel(trimmed)
        customModel = false
    }

    // MARK: - Connected state

    /// The conversation: its own scroll view (not `ScreenScaffold`) because the composer is docked
    /// over the bottom of the screen and the transcript has to scroll clear of it.
    private var chatScreen: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, 12)
                    chatHero
                    transcript
                    if let error = coach.errorText, !error.isEmpty {
                        errorBanner(error).padding(.top, 14)
                    }
                    if coach.keyRejected || showKeyEditor {
                        keyRepairPanel.padding(.top, 12)
                    }
                    // K7: show follow-up chips after each assistant reply (when the transcript is
                    // non-empty and the last message is from the assistant and not mid-send);
                    // otherwise the initial contextual chips.
                    if showFollowUpChips {
                        followUpChips.padding(.top, 14)
                    } else if !coach.sending {
                        suggestionChips
                    }
                    Color.clear
                        .frame(height: dockHeight + dockLift + 24)
                        .id(transcriptEndID)
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.top, 8)
                #if os(iOS)
                .frame(maxWidth: hSizeClass == .regular ? 700 : .infinity)
                .frame(maxWidth: .infinity)
                #endif
            }
            #if os(iOS)
            // #697 parity: this screen builds its OWN ScrollView rather than going through
            // ScreenScaffold, so it never inherited the scaffold's horizontal-bounce suppression and
            // could still rubber-band left-right on a purely vertical scroll. Same modifier, same
            // guard. `.basedOnSize` permits horizontal bounce only when content genuinely overflows
            // the width, so nothing that is meant to scroll sideways is affected. (#1532 follow-up)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .scrollDismissesKeyboard(.interactively)
            #endif
            #if os(iOS) && DEBUG
            .modifier(DemoScrollAnchor())
            #endif
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .overlay(alignment: .bottom) { composerDock }
            .onChangeCompat(of: coach.messages.count) { _ in
                scrollToEnd(proxy)
            }
            // A persisted conversation opens on its latest exchange, not on the hero above it.
            .onAppear {
                guard !coach.messages.isEmpty else { return }
                DispatchQueue.main.async { proxy.scrollTo(transcriptEndID, anchor: .bottom) }
            }
            .onChangeCompat(of: coach.sending) { _ in
                scrollToEnd(proxy)
            }
        }
    }

    /// The ink hero at the top of the conversation: what Coach answers from.
    private var chatHero: some View {
        NoopHeroCard(glow: .ink, padding: 0, cornerRadius: 30) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    NoopIconBadge("Your coach", icon: "sparkle")
                    Spacer(minLength: 8)
                    Group {
                        if coach.dataConsent {
                            Text("14 days of context")
                        } else {
                            Text("No data shared")
                        }
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.6))
                }
                Text("Ask about your charge, effort, rest and workouts, grounded in your own numbers.")
                    .font(StrandFont.light(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.86))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 20)
        }
    }

    /// The messages, top to bottom. The conversation is retired at the day boundary, so everything
    /// shown is from today.
    @ViewBuilder private var transcript: some View {
        if coach.messages.isEmpty {
            emptyTranscript
        } else {
            Text("Today")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 22)
                .padding(.bottom, 14)
            // Lazy so off-screen bubbles aren't all resident/laid-out at once; with the
            // `maxStoredMessages` cap the transcript is already bounded, this keeps render cost flat.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(coach.messages.enumerated()), id: \.element.id) { index, message in
                    if !isPendingReply(message, at: index) {
                        bubble(message, isLatest: index == coach.messages.count - 1)
                            .padding(.top, index == 0 ? 0 : (message.role == .user ? 22 : 14))
                            .id(message.id)
                    }
                }
                if showsThinking {
                    thinkingBubble.padding(.top, 16)
                }
            }
        }
    }

    /// The empty assistant placeholder `send` appends before the first streamed token; the thinking
    /// bubble stands in for it until text arrives.
    private func isPendingReply(_ message: ChatMessage, at index: Int) -> Bool {
        coach.sending && index == coach.messages.count - 1 && message.role == .assistant
            && message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showsThinking: Bool {
        guard coach.sending, let last = coach.messages.last else { return false }
        return last.role == .user || last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var emptyTranscript: some View {
        VStack(alignment: .leading, spacing: 14) {
            NoopSectionTitle("Ask your first question", topPadding: 30)
            Text("Coach reads a summary of your last two weeks plus 30-day averages and recent workouts, then answers in plain language. Try a suggestion below.")
                .font(StrandFont.light(14, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage, isLatest: Bool) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(StrandFont.book(14.5, relativeTo: .body))
                    .lineSpacing(3)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 13)
                    .background(
                        UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22,
                                               bottomTrailingRadius: 6, topTrailingRadius: 22,
                                               style: .continuous)
                            .fill(NoopVisualStyle.raised)
                    )
                    .overlay(
                        UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22,
                                               bottomTrailingRadius: 6, topTrailingRadius: 22,
                                               style: .continuous)
                            .strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 1)
                    )
                    .frame(maxWidth: 520, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You said: \(message.text)")
        case .assistant:
            VStack(alignment: .leading, spacing: 0) {
                replyCard(message)
                if isLatest && !coach.sending {
                    replyActions(message)
                        .padding(.top, 10)
                        .padding(.leading, 4)
                }
            }
        }
    }

    /// An assistant reply. LLM replies arrive as Markdown (bold, lists, headings, tables), rendered with
    /// the chat-sized Strand theme; user bubbles stay verbatim `Text` so typed `*`/`#` never turn into
    /// surprise formatting.
    private func replyCard(_ message: ChatMessage) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 8,
                                           bottomTrailingRadius: 24, topTrailingRadius: 24,
                                           style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            NoopCardHeader("Coach", icon: "sparkle", caption: nil)
            Markdown(message.text)
                .markdownTheme(.strand)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(G3CardSurface(shape: shape))
        .contentShape(shape)
        // K8: Copy / Share / Save context menu on every assistant reply (long-press / right-click).
        .contextMenu {
            Button {
                copyToPasteboard(message.text)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            ShareLink(item: message.text) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button {
                saveAdvice(message)
            } label: {
                Label("Save to Journal", systemImage: "square.and.pencil")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Coach said: \(message.text)")
    }

    /// K8: the same Copy / Share / Save actions, drawn under the latest reply.
    private func replyActions(_ message: ChatMessage) -> some View {
        HStack(spacing: 8) {
            Button { copyToPasteboard(message.text) } label: {
                G3ActionCapsule(title: "Copy", icon: "copy")
            }
            .buttonStyle(.plain)
            ShareLink(item: message.text) {
                G3ActionCapsule(title: "Share", icon: "share-network")
            }
            .buttonStyle(.plain)
            Button { saveAdvice(message) } label: {
                if savedReplyID == message.id {
                    G3ActionCapsule(title: "Saved", icon: "check")
                } else {
                    G3ActionCapsule(title: "Save to Journal", icon: "notebook")
                }
            }
            .buttonStyle(.plain)
            .disabled(savedReplyID == message.id)
        }
    }

    /// `.think`: three dots and "Thinking" while the reply has not started streaming.
    private var thinkingBubble: some View {
        HStack(spacing: 12) {
            ThinkingDots()
            Text("Thinking")
                .font(StrandFont.book(13.5, relativeTo: .subheadline))
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .background(G3CardSurface(shape: UnevenRoundedRectangle(
            topLeadingRadius: 22, bottomLeadingRadius: 6, bottomTrailingRadius: 22, topTrailingRadius: 22,
            style: .continuous)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Coach is thinking")
    }

    private func errorBanner(_ message: String) -> some View {
        NoopCard(padding: 16) {
            HStack(alignment: .top, spacing: 12) {
                PhIcon("warning-circle")
                    .foregroundStyle(NoopGlow.low.tint)
                    .padding(.top, 1)
                Text(message)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }

    /// The inline replacement-key editor, shown after a rejection or an Update key action.
    ///
    /// Saving goes through `setKey`, which replaces the stored key and leaves the transcript alone. The
    /// existing route was the Disconnect button, which also wipes the conversation and un-commits a
    /// custom provider: far more than correcting a typo asks for, and named for an outcome the wearer
    /// is trying to avoid. Twin of the Kotlin editor in `CoachChat`.
    private var keyRepairPanel: some View {
        NoopCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                NoopCardHeader("Update key", icon: "key", caption: nil)
                if coach.keyRejected {
                    Text("Paste the corrected key. Your conversation is kept.")
                        .font(StrandFont.light(13.5, relativeTo: .subheadline))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    PhIcon("lock-simple").opacity(0.5)
                    SecureField("Paste your \(coach.provider.displayName) API key", text: $keyFix)
                        .textFieldStyle(.plain)
                        .font(StrandFont.book(15, relativeTo: .body))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .onSubmit(saveRepairedKey)
                        .accessibilityLabel(coach.keyRejected ? Text("Corrected API key") : Text("API key"))
                }
                .foregroundStyle(StrandPalette.textPrimary)
                .g3FieldChrome()
                HStack(spacing: 10) {
                    NoopButton("Update key", kind: .primary, action: saveRepairedKey)
                        .disabled(keyFix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    if showKeyEditor && !coach.keyRejected {
                        NoopButton("Cancel", kind: .tertiary) { toggleKeyEditor() }
                    }
                }
            }
        }
    }

    /// Store the corrected key and drop it from view state. `setKey` clears the error and the rejection
    /// flag, which is what closes this panel.
    private func saveRepairedKey() {
        let trimmed = keyFix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        coach.setKey(trimmed)
        guard coach.errorText == nil else { return }
        keyFix = ""
        showKeyEditor = false
    }

    private func toggleKeyEditor() {
        showKeyEditor.toggle()
        if !showKeyEditor { keyFix = "" }
    }

    /// The initial contextual prompts: a wrapping "Try asking" block on an empty transcript, a
    /// sideways row once a conversation is under way.
    @ViewBuilder private var suggestionChips: some View {
        if coach.messages.isEmpty {
            G3FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(suggestions, id: \.self) { prompt in
                    promptButton(prompt, label: "Suggested prompt: \(prompt)")
                }
            }
            .padding(.top, 16)
        } else {
            promptRow(suggestions, label: { "Suggested prompt: \($0)" })
                .padding(.top, 14)
        }
    }

    /// K7: True when follow-up chips should show instead of the initial contextual chips —
    /// i.e. the transcript is non-empty, the last message is from the assistant, and a reply
    /// is not currently in flight.
    private var showFollowUpChips: Bool {
        guard let last = coach.messages.last, !coach.sending else { return false }
        return last.role == .assistant
    }

    /// K7: Follow-up suggestion chips shown after each assistant reply, so the user can dig
    /// deeper without typing. Uses the static `AICoachEngine.followUpSuggestions` list.
    private var followUpChips: some View {
        promptRow(AICoachEngine.followUpSuggestions, label: { "Follow-up prompt: \($0)" })
    }

    private func promptRow(_ prompts: [String], label: @escaping (String) -> LocalizedStringKey) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(prompts, id: \.self) { prompt in
                    promptButton(prompt, label: label(prompt))
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func promptButton(_ prompt: String, label: LocalizedStringKey) -> some View {
        Button {
            send(prompt)
        } label: {
            G3PromptChip(text: prompt)
        }
        // Liquid tap response: the physical settle-inward every tappable affordance gets.
        .buttonStyle(LiquidPressStyle())
        .disabled(coach.sending)
        .accessibilityLabel(label)
    }

    // MARK: - Docked composer

    /// How far the dock sits above the bottom of the screen: clear of the floating tab bar on iPhone
    /// (bar 66 + its 22 inset + a 12 gap), right on the keyboard while it is up.
    private var dockLift: CGFloat {
        #if os(iOS)
        return keyboardVisible ? 10 : 100
        #else
        return 16
        #endif
    }

    /// The composer docked over the bottom of the conversation: what the next request carries, the
    /// field and Send, on a fade so the transcript passes beneath it.
    private var composerDock: some View {
        VStack(spacing: 8) {
            HStack {
                Group {
                    if coach.dataConsent {
                        Text("Shares your last 14 days")
                    } else {
                        Text("Shares no personal data")
                    }
                }
                Spacer(minLength: 8)
                // K12: a rough token estimate for the next request (~4 chars/token, not a tokenizer).
                if let tokens = coach.estimatedTokens(forDraft: draft) {
                    tokenEstimate(tokens)
                }
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.horizontal, 14)
            composer
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { dockHeight = geo.size.height }
                    .onChangeCompat(of: geo.size.height) { dockHeight = $0 }
            }
        )
        .padding(.bottom, dockLift)
        .background(alignment: .bottom) {
            // Opaque by the caption line, so the transcript fades out above the dock rather than
            // running through its text.
            LinearGradient(
                stops: [.init(color: NoopVisualStyle.canvas.opacity(0), location: 0),
                        .init(color: NoopVisualStyle.canvas, location: 0.3)],
                startPoint: .top, endPoint: .bottom
            )
            .padding(.top, -64)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        #if os(iOS)
        .ignoresSafeArea(.container, edges: .bottom)
        #endif
        .animation(.easeOut(duration: 0.2), value: keyboardLiftKey)
    }

    /// Animation key for the dock's lift (macOS has no keyboard state).
    private var keyboardLiftKey: Bool {
        #if os(iOS)
        return keyboardVisible
        #else
        return false
        #endif
    }

    /// "~1.4k tokens", with the small-context warning past 8k.
    private func tokenEstimate(_ tokens: Int) -> some View {
        let count = tokens >= 1000
            ? String(format: "%.1fk", Double(tokens) / 1000)
            : "\(tokens)"
        return HStack(spacing: 4) {
            Text("~\(count) tokens")
            if tokens > 8000 {
                Text("· may exceed small context windows")
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    /// The input capsule (`.cmp`): the field and the mic inside, the round Send beside it.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                TextField("Ask Coach about your data…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(StrandFont.light(14.5, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .onSubmit { send(draft) }
                    .accessibilityLabel("Question")
                // K4: on-device voice input (iOS only). macOS compiles this section out entirely.
                #if os(iOS)
                CoachMicButton(draft: $draft, disabled: coach.sending)
                #endif
            }
            .padding(.leading, 20)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 54)
            .background(RoundedRectangle(cornerRadius: 27, style: .continuous).fill(NoopVisualStyle.inset))
            .overlay(RoundedRectangle(cornerRadius: 27, style: .continuous)
                .strokeBorder(composerFocused ? StrandPalette.textTertiary : NoopVisualStyle.borderHighlight,
                              lineWidth: 1))

            Button {
                send(draft)
            } label: {
                Group {
                    if coach.sending {
                        ProgressView().controlSize(.small).tint(NoopVisualStyle.canvas)
                    } else {
                        PhIcon("arrow-up", size: 20)
                    }
                }
                .foregroundStyle(NoopVisualStyle.canvas)
                .frame(width: 54, height: 54)
                .background(Circle().fill(StrandPalette.textPrimary))
                .opacity(sendDisabled && !coach.sending ? 0.45 : 1)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(sendDisabled)
            .accessibilityLabel("Send")
        }
    }

    private var sendDisabled: Bool {
        coach.sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var privacyFootnote: some View {
        HStack(alignment: .top, spacing: 10) {
            PhIcon("lock-simple", size: 14)
                .padding(.top, 1)
            Text(coach.provider == .custom
                 ? "Coach talks only to the server URL you set. Point it at a local model (Ollama, LM Studio, llama.cpp) to keep everything on your own machine. Nothing is sent until you ask."
                 : "This is the only feature that leaves \(Platform.deviceNounPhrase). It sends a summary of your metrics to \(coach.provider.displayName) using your own key. Nothing is sent until you ask.")
                .font(StrandFont.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(StrandPalette.textTertiary)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        coach.setKey(trimmed)
        keyDraft = ""
    }

    /// Commit the Custom (local) provider: save an optional key, then connect on the entered URL.
    private func connectCustom() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            coach.setKey(trimmed)
            keyDraft = ""
        }
        coach.connectCustom()
    }

    /// Fill the key field from the clipboard. Read only on this explicit tap.
    private func pasteKey() {
        #if os(macOS)
        let pasted = NSPasteboard.general.string(forType: .string)
        #else
        let pasted = UIPasteboard.general.string
        #endif
        if let pasted = pasted?.trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty {
            keyDraft = pasted
        }
    }

    private func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !coach.sending else { return }
        draft = ""
        composerFocused = false
        Task { await coach.send(trimmed) }
    }

    /// K14: Trigger a subtle haptic when the Coach reply arrives. On iOS, a light impact feedback.
    /// macOS doesn't have an equivalent simple API, so it's a no-op there.
    private func triggerReplyHaptic() {
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #endif
    }

    /// K8: Save a coach reply to the journal as a note, so it appears alongside other journal
    /// entries in Insights and can be reviewed later. Uses the existing journal API with a
    /// fixed question ("Coach advice") and the reply text in the notes field.
    private func saveAdvice(_ message: ChatMessage) {
        let day = Repository.localDayKey(Date())
        savedReplyID = message.id
        Task {
            await repo.saveJournalAnswer(
                day: day,
                question: "Coach advice",
                answeredYes: true,
                notes: message.text
            )
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(StrandMotion.fade) {
            proxy.scrollTo(transcriptEndID, anchor: .bottom)
        }
    }
}

/// Three dots fading in turn while the coach composes (`.think b i`).
private struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { context in
            let step = reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(StrandPalette.textPrimary)
                        .frame(width: 6, height: 6)
                        .opacity([1, 0.55, 0.25][(i - step + 3) % 3])
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A horizontal line through the middle of its rect (the dashed route in the connect hero).
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

extension AIProvider {
    /// The short name the v2 Coach screens print (the full `displayName` stays in sentences).
    var v2ShortName: String {
        switch self {
        case .openAI:    return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini:    return "Gemini"
        case .custom:    return String(localized: "Custom")
        }
    }

    /// The provider row's caption on the connect screen.
    var v2Caption: Text {
        switch self {
        case .anthropic: return Text("Claude models · api.anthropic.com")
        case .openAI:    return Text("GPT models · api.openai.com")
        case .gemini:    return Text("Google AI Studio key")
        // A plain String, so the URL is not turned into a Markdown link.
        case .custom:    return Text(String(localized: "OpenAI-compatible server, e.g. http://localhost:11434/v1"))
        }
    }

    /// The provider row's icon.
    var v2Icon: String {
        switch self {
        case .anthropic: return "chat-circle-text"
        case .openAI:    return "chats-teardrop"
        case .gemini:    return "diamond"
        case .custom:    return "hard-drives"
        }
    }
}
