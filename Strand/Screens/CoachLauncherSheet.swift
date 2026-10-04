import SwiftUI
import MarkdownUI
import StrandDesign

/// The compact Coach launcher opened from the optional Today card (#1862).
///
/// Coach is otherwise reachable only through More/Insights, which makes it easy to miss and means
/// leaving Today to try it. This is the shortcut — and deliberately ONLY a shortcut.
///
/// It owns no send, stream, error or consent surface of its own. Picking a suggestion or submitting the
/// composer hands the question to `AICoachEngine.pendingPrompt` and routes to `CoachView`, which already
/// has all of that. A second chat UI would drift from the first, and the issue explicitly defers the
/// persistent-workspace redesign (threads, retention, backup policy) to a follow-up.
///
/// NO PROVIDER REQUEST IS MADE BY OPENING THIS. Everything shown is local: `isConfigured` reads the
/// stored key, the prompts are static copy and the brief card shows the text the scheduled brief
/// already stored. The first network call still happens where it always did — inside
/// `AICoachEngine.send`, after an explicit user action.
struct CoachLauncherSheet: View {
    @EnvironmentObject var coach: AICoachEngine
    @EnvironmentObject var router: NavRouter
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if coach.isConfigured {
                NoopSheetHeader("Quick ask", doneTitle: "Send", doneEnabled: !trimmedDraft.isEmpty,
                                onCancel: { dismiss() }, onDone: submitDraft)
            } else {
                NoopSheetHeader("Quick ask", doneTitle: nil, onCancel: { dismiss() })
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if coach.isConfigured {
                        configured
                    } else {
                        unconfigured
                    }
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
        }
        .background(NoopSheetBackground())
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #else
        .frame(minWidth: 440, minHeight: 560)
        #endif
    }

    // MARK: Configured — a compact composer, suggestions and the latest brief

    @ViewBuilder
    private var configured: some View {
        composer
        HStack {
            Text(verbatim: "\(coach.provider.v2ShortName) · \(coach.model)")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let tokens = coach.estimatedTokens(forDraft: draft) {
                Text(tokens >= 1000
                     ? "~\(String(format: "%.1fk", Double(tokens) / 1000)) tokens"
                     : "~\(String(tokens)) tokens")
            }
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .padding(.horizontal, 6)
        .padding(.top, 10)

        NoopOverline("Suggested")
            .padding(.horizontal, 2)
            .padding(.top, 26)
            .padding(.bottom, 12)
        G3FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(Array(CoachPrompts.suggestions.enumerated()), id: \.element) { index, prompt in
                Button { hand(off: prompt) } label: {
                    HStack(spacing: 7) {
                        PhIcon(CoachPrompts.icons[index % CoachPrompts.icons.count], size: 14).opacity(0.6)
                        Text(prompt).font(StrandFont.book(13, relativeTo: .footnote)).lineLimit(1)
                    }
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
                    .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Suggested prompt: \(prompt)"))
            }
        }

        if CoachBriefScheduler.isEnabled, let brief = CoachBriefScheduler.storedBrief,
           !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            briefCard(brief)
                .padding(.top, 26)
        }
    }

    /// The question field (`.qf`): a tall rounded field with what is attached, the mic and Send.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Ask your coach…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(StrandFont.light(17, relativeTo: .body))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(2...6)
                .focused($fieldFocused)
                .onSubmit { submitDraft() }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    PhIcon("paperclip", size: 14).opacity(0.8)
                    if coach.dataConsent {
                        Text("Today's numbers attached")
                    } else {
                        Text("No data attached")
                    }
                }
                .font(StrandFont.book(12, relativeTo: .caption))
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule(style: .continuous).fill(NoopVisualStyle.inset))
                .overlay(Capsule(style: .continuous).strokeBorder(NoopVisualStyle.border, lineWidth: 1))
                Spacer(minLength: 0)
                #if os(iOS)
                CoachMicButton(draft: $draft)
                #endif
                Button(action: submitDraft) {
                    PhIcon("arrow-up", size: 18)
                        .foregroundStyle(NoopVisualStyle.canvas)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(StrandPalette.textPrimary))
                        .opacity(trimmedDraft.isEmpty ? 0.45 : 1)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(trimmedDraft.isEmpty)
                .accessibilityLabel(Text("Send"))
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(minHeight: 132)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(NoopVisualStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(StrandPalette.textPrimary.opacity(fieldFocused ? 0.3 : 0.13), lineWidth: 1))
        // The focus halo: a faint 4 pt ring just outside the field.
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
            .stroke(StrandPalette.textPrimary.opacity(fieldFocused ? 0.04 : 0), lineWidth: 4)
            .padding(-2))
        .onAppear { fieldFocused = true }
    }

    /// The latest scheduled brief, as already stored by `CoachBriefScheduler`. Opening Coach from it
    /// sends nothing.
    private func briefCard(_ brief: String) -> some View {
        NoopCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                NoopCardHeader("Latest morning brief", icon: "sun-horizon", caption: nil)
                Markdown(brief)
                    .markdownTheme(.strand)
                    .fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(NoopVisualStyle.border).frame(height: 1)
                    .padding(.top, 2)
                HStack {
                    Text("Grounded in your last 14 days")
                        .font(StrandFont.light(12, relativeTo: .caption))
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer(minLength: 8)
                    Button {
                        dismiss()
                        router.openCoach()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Open in Coach").font(StrandFont.book(13, relativeTo: .footnote))
                            PhIcon("caret-right", size: 14)
                        }
                        .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Not configured — explain the opt-in and route to the existing setup

    @ViewBuilder
    private var unconfigured: some View {
        // The SAME explanation the Coach screen shows, so the bring-your-own-key model is described
        // once. The button routes to that screen, which stays the only place a key is entered.
        NoopHeroCard(glow: .ink, padding: 22) {
            VStack(alignment: .leading, spacing: 14) {
                NoopIconBadge("Bring your own key", icon: "key")
                Text("Coach uses your own API key. Pick a provider, paste a key, and choose a model. Your key is stored securely in the Keychain and never leaves \(Platform.deviceNounPhrase) except as the request you make.")
                    .font(StrandFont.light(14.5, relativeTo: .subheadline))
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.8))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        NoopButton("Connect a provider", kind: .primary, fullWidth: true) {
            dismiss()
            router.openCoach()
        }
        .padding(.top, 18)
    }

    // MARK: Handoff

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitDraft() {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        hand(off: text)
    }

    /// Dismiss, park the question, and open Coach. Deliberately NOT `coach.send` from here: the launcher
    /// never performs a provider request, so a user who opens this sheet and changes their mind has cost
    /// nothing and sent nothing.
    private func hand(off prompt: String) {
        coach.pendingPrompt = prompt
        draft = ""
        dismiss()
        router.openCoach()
    }
}
