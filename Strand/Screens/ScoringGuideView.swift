import SwiftUI
import StrandDesign

// MARK: - Scoring guide
//
// "How your scores work" — the one honest explainer for NOOP's three daily scores
// (Charge, Effort, Rest) and the confidence labels. Presented as a sheet, mirroring
// WhatsNewView's presentation + dismiss + layout idiom: a fixed header with a close
// button, a scrollable column of cards, and a "Got it" footer. Reachable from
// Settings → About, the ⓘ on each Today score, and the one-time first-run card.
//
// All copy here is the single approved source of truth, shared verbatim across
// macOS / iOS / Android. Each score section is tinted with the SAME Reset accent the
// rest of the app uses for that score's hero ring (Charge = green, Effort = blue
// accent, Rest = restColor slate), so a glance maps a section to its Today ring.

/// The three score sections the guide can deep-link to. The raw value is used as the
/// ScrollViewReader anchor id. The Android port mirrors these case names exactly.
enum ScoreSection: String, CaseIterable, Identifiable {
    case charge
    case effort
    case rest

    var id: String { rawValue }

    /// The accent each section uses — the SAME Reset score token its Today hero ring draws with, so a
    /// section reads as that score's colour. No gold / strain / sleep-purple: Charge = chargeColor green,
    /// Effort = effortColor blue accent, Rest = restColor slate (Design Reset, 2026-06-23).
    var accent: Color {
        switch self {
        case .charge: return StrandPalette.chargeColor     // Charge hero ring — green
        case .effort: return StrandPalette.effortColor     // Effort hero ring — blue accent
        case .rest:   return StrandPalette.restColor       // Rest hero ring — slate
        }
    }

    /// A representative sample fraction (0–1) for the section's illustrative gauge — a
    /// "what a strong day looks like" reading, purely decorative in the guide.
    var sampleFraction: Double {
        switch self {
        case .charge: return 0.82
        case .effort: return 0.64
        case .rest:   return 0.88
        }
    }

    /// The number shown inside the sample gauge (the 0–100 score the fraction maps to).
    var sampleNumber: String {
        "\(Int((sampleFraction * 100).rounded()))"
    }

    /// The Phosphor glyph for the score (the same one its Today hero badge carries).
    var icon: String {
        switch self {
        case .charge: return "lightning"
        case .effort: return "fire"
        case .rest:   return "moon"
        }
    }

    /// The bands the app itself uses on this score's 0–100 axis: the Charge state words
    /// (`StrandPalette.recoveryState`, whose edges the hero glow and scale share), the Effort
    /// band words (LIGHT / MODERATE / STRENUOUS / HIGH on 0–21, rescaled), and the Sleep tab's Rest words.
    var bands: [ScoringBand] {
        switch self {
        case .charge:
            return [ScoringBand(label: String(localized: "Depleted"), lower: 0),
                    ScoringBand(label: String(localized: "Low"), lower: 25),
                    ScoringBand(label: String(localized: "Moderate"), lower: 50),
                    ScoringBand(label: String(localized: "Primed"), lower: 70),
                    ScoringBand(label: String(localized: "Peak"), lower: 88)]
        case .effort:
            return [ScoringBand(label: String(localized: "Light"), lower: 0),
                    ScoringBand(label: String(localized: "Moderate"), lower: (6.0 / 21 * 100).rounded()),
                    ScoringBand(label: String(localized: "Strenuous"), lower: (10.0 / 21 * 100).rounded()),
                    ScoringBand(label: String(localized: "High"), lower: (14.0 / 21 * 100).rounded())]
        case .rest:
            return [ScoringBand(label: String(localized: "Poor"), lower: 0),
                    ScoringBand(label: String(localized: "Fair"), lower: 50),
                    ScoringBand(label: String(localized: "Good"), lower: 70),
                    ScoringBand(label: String(localized: "Optimal"), lower: 85)]
        }
    }

    /// The scale caption beside the section title.
    func scaleCaption(_ effortScale: EffortScale) -> String {
        switch self {
        case .charge: return "0–100 %"
        case .effort: return effortScale == .whoop ? "0–21" : "0–100"
        case .rest: return "0–100"
        }
    }

    /// Localized display name for the section (the raw value stays the stable anchor id).
    var displayName: String {
        switch self {
        case .charge: return String(localized: "Charge")
        case .effort: return String(localized: "Effort")
        case .rest:   return String(localized: "Rest")
        }
    }
}

/// Today's three scores as the guide's hero shows them, resolved by the presenting Today screen. The
/// guide is also opened from Settings, where there is no day in view, so every field is optional.
struct ScoringGuideScores: Equatable {
    var charge: Double?
    /// 0–100 Effort (the stored axis); the guide prints it on the user's chosen scale.
    var effort: Double?
    var rest: Double?
    /// "Saturday 3 October", the day the scores belong to.
    var dayLine: String?
    /// "WHOOP" — the provider of the scores, when one resolved.
    var source: String?
}

struct ScoringGuideView: View {
    /// When set, the guide scrolls to (and briefly highlights) this section on appear —
    /// used by the score badges on the Today screen so each opens at its own score.
    var initialSection: ScoreSection? = nil
    /// The selected day's scores, when the guide is opened from Today.
    var scores: ScoringGuideScores? = nil
    let onClose: () -> Void

    /// Drives the brief highlight pulse on the deep-linked section.
    @State private var highlighted: ScoreSection? = nil
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        hero
                        VStack(alignment: .leading, spacing: 0) {
                            introCard
                                .padding(.top, 24)
                            scoreSection(.charge,
                                         headline: String(localized: "Charge: how recovered are you?"),
                                         body: String(localized: "Led by your heart-rate variability (HRV) measured against your own personal baseline, plus resting heart rate, last night's Rest, breathing rate, and a skin-temperature signal (an early illness or overreach flag). Higher HRV versus your baseline means more Charge. NOOP needs a few nights to learn your baseline first. Until then you'll see “Calibrating”."),
                                         vsWhoop: String(localized: "Same core idea as WHOOP's Recovery % (HRV-led recovery), but our weighting and baseline maths are our own, and openly documented."))
                            scoreSection(.effort,
                                         headline: String(localized: "Effort: how hard did your heart work?"),
                                         body: String(localized: "Your cardiovascular load. NOOP turns every second of heart rate into a training-impulse using heart-rate-reserve zones (Karvonen), weights time in harder zones more heavily (Edwards / Banister), and places it on a logarithmic 0-100 scale, so easy days sit low and an all-out day approaches 100, which stays genuinely rare. A long walk with little cardio still counts, through a steps / active-energy floor."),
                                         vsWhoop: effortVsWhoop)
                            scoreSection(.rest,
                                         headline: String(localized: "Rest: how restorative was your sleep?"),
                                         body: String(localized: "A blend of how long you slept versus your personal need (the biggest factor), how efficiently (asleep versus in bed), how much was restorative (deep + REM sleep), and how consistent your sleep and wake timing is."),
                                         vsWhoop: String(localized: "Similar in spirit to WHOOP's Sleep Performance %; our composite is our own."))
                            confidenceSection
                            NoopInsightRow(verbatim: String(localized: "These are independent approximations from a consumer strap, built on open science: not medical advice, and not WHOOP's official scores."))
                                .padding(.top, 20)
                                .padding(.horizontal, 4)
                        }
                        .padding(.horizontal, NoopMetrics.screenHPadding)
                        .padding(.bottom, 130)
                    }
                }
                #if os(iOS)
                // #697/#horizontal-swipe parity, see ScreenScaffold.
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                #endif
                #if os(iOS) && DEBUG
                .modifier(DemoScrollAnchor())
                #endif
                .onAppear { jump(to: initialSection, using: proxy) }
            }
            footerBar
        }
        .background(NoopVisualStyle.canvas.ignoresSafeArea())
        .noopHidesSystemNavBar()
        // Same sizing split as WhatsNewView: a fixed window on macOS, fill the presented
        // sheet on iOS so nothing runs off a narrow phone screen (#185).
        #if os(macOS)
        .frame(width: 560, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A long explainer scroll → open full-height, with a grabber for swipe-to-dismiss.
        .noopSheetPresentation(largeFirst: true)
        #endif
    }

    // MARK: - Hero

    /// The ink glow hero: close circle, title, and — opened from Today — the day's three scores.
    private var hero: some View {
        NoopHeroCard(glow: .ink, padding: 22, bleed: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    NoopCircleButton("x", accessibilityLabel: "Close", action: onClose)
                    Text("Scoring guide")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    NoopPill("3 min read", compact: true)
                }
                .padding(.horizontal, -2)
                NoopOverline("YOUR DAILY SCORES")
                    .padding(.top, 30)
                Text("How your scores work")
                    .font(StrandFont.title1)
                    .tracking(-0.56)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.top, 10)
                    .accessibilityAddTraits(.isHeader)
                Text("Charge · Effort · Rest")
                    .font(StrandFont.light(14))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.top, 6)
                if let scores, scores.charge != nil || scores.effort != nil || scores.rest != nil {
                    HStack(spacing: 0) {
                        trioCell(scores.charge.map { "\(Int($0.rounded()))" }, label: String(localized: "Charge %"),
                                 key: NoopGlow.recovery.accent)
                        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1)
                        trioCell(scores.effort.map { effortNumber($0) }, label: String(localized: "Effort"),
                                 key: NoopGlow.strain.accent)
                        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1)
                        trioCell(scores.rest.map { "\(Int($0.rounded()))" }, label: String(localized: "Rest"),
                                 key: NoopGlow.sleep.accent)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 30)
                    if let line = sourceLine(scores) {
                        Text(verbatim: line)
                            .font(StrandFont.light(13))
                            .foregroundStyle(Color.white.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 22)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
    }

    private func trioCell(_ value: String?, label: String, key: Color) -> some View {
        VStack(spacing: 12) {
            NoopDotNumber(value ?? "–", size: 62)
                .fixedSize()
                .padding(.vertical, -6)
            HStack(spacing: 6) {
                Circle().fill(key).frame(width: 7, height: 7)
                Text(verbatim: label)
            }
            .font(StrandFont.light(12))
            .foregroundStyle(Color.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func sourceLine(_ scores: ScoringGuideScores) -> String? {
        switch (scores.dayLine, scores.source) {
        case let (day?, source?): return String(localized: "\(day) · from your \(source)")
        case let (day?, nil): return day
        case let (nil, source?): return String(localized: "From your \(source)")
        default: return nil
        }
    }

    private func effortNumber(_ strain: Double) -> String {
        let v = UnitFormatter.effortValue(strain, scale: effortScale)
        return effortScale == .whoop
            ? String(format: "%.1f", locale: AppLanguage.activeLocale, v)
            : String(Int(v.rounded()))
    }

    // MARK: - Footer

    /// "Got it", floating over the fade at the foot of the sheet.
    private var footerBar: some View {
        VStack(spacing: 0) {
            NoopTabBarFade(height: 130)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottom) {
                    NoopButton("Got it", kind: .primary, fullWidth: true, action: onClose)
                        .keyboardShortcut(.defaultAction)
                        .padding(.horizontal, NoopMetrics.screenHPadding)
                        .padding(.bottom, 12)
                }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Cards

    private var introCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                NoopCardHeader("The three scores", icon: "gauge")
                Text("NOOP gives you three daily scores (Charge, Effort and Rest), each on a 0-100 scale. They're built from your strap's raw signals using published, peer-reviewed sport science, and computed entirely on your device. They are NOT WHOOP's scores: we don't have WHOOP's private algorithms and don't pretend to. They aim at the same three questions using open science, so they'll usually track WHOOP's in direction, but won't match number-for-number. And that's the point.")
                    .font(StrandFont.light(13))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One score: its ring + title + scale caption, then a card with the explainer, the band scale (the
    /// band holding today's value lit), and the vs-WHOOP note.
    private func scoreSection(_ section: ScoreSection, headline: String, body: String, vsWhoop: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                NoopRingGauge(fraction: ringFraction(section) ?? 0, lineWidth: 2.5, tint: section.accent,
                              showsKnob: false)
                    .frame(width: 22, height: 22)
                    .frame(width: 26, height: 26)
                Text(section.displayName)
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text(verbatim: section.scaleCaption(effortScale))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            NoopCard {
                VStack(alignment: .leading, spacing: 0) {
                    Text(headline)
                        .font(StrandFont.light(14))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(body)
                        .font(StrandFont.light(13))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                    ScoringBandScale(bands: section.bands, value: bandValue(section))
                        .padding(.top, 18)
                    HStack(alignment: .top, spacing: 12) {
                        PhIcon("arrows-left-right", size: 15)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(NoopVisualStyle.raised))
                        (Text("vs WHOOP").font(StrandFont.book(13)).foregroundColor(StrandPalette.textPrimary)
                         + Text(verbatim: " — ")
                         + Text(verbatim: vsWhoop))
                            .font(StrandFont.light(13))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 16)
                    .overlay(alignment: .top) {
                        Rectangle().fill(NoopVisualStyle.border).frame(height: 1).offset(y: 0)
                    }
                    .padding(.top, 16)
                }
            }
            // Deep-link highlight: a brief brightening of the card edge when arrived at from Today.
            .overlay(
                RoundedRectangle(cornerRadius: NoopVisualStyle.cardRadius, style: .continuous)
                    .strokeBorder(NoopVisualStyle.borderHighlight, lineWidth: 2)
                    .opacity(highlighted == section ? 1 : 0)
            )
            .animation(.easeOut(duration: 0.35), value: highlighted)
        }
        .padding(.top, 34)
        .id(section.id)
    }

    /// The day's value on the 0–100 axis, for the section ring and the lit band.
    private func bandValue(_ section: ScoreSection) -> Double? {
        switch section {
        case .charge: return scores?.charge
        case .effort: return scores?.effort
        case .rest: return scores?.rest
        }
    }

    private func ringFraction(_ section: ScoreSection) -> Double? {
        bandValue(section).map { max(0, min(1, $0 / 100)) } ?? section.sampleFraction
    }

    /// The approved vs-WHOOP line, plus today's Effort on the Strain axis when the guide knows it.
    private var effortVsWhoop: String {
        let base = String(localized: "Same cardiovascular-load idea as WHOOP's Day Strain (0-21). We rescaled the top of the ladder from 21 to 100 so all three scores share one scale. The rungs didn't move, so a 100 is as rare as a 21.0 was.")
        guard let effort = scores?.effort, effortScale == .hundred else { return base }
        let strain = String(format: "%.1f", locale: AppLanguage.activeLocale,
                            UnitFormatter.effortValue(effort, scale: .whoop))
        return base + " " + String(localized: "Today's \(Int(effort.rounded())) is a Strain of about \(strain).")
    }

    private var confidenceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            NoopSectionTitle("How sure is NOOP?", captionKey: "Shown on every score", topPadding: 0)
            NoopList {
                confidenceRow(.solid, title: "Full inputs present", caption: "Trust day-to-day changes")
                confidenceRow(.building, title: "Enough to show, but thin", caption: "Direction is right, size may shift")
                confidenceRow(.calibrating, title: "Still learning your baseline", caption: "Read it as a first guess")
            }
            Text("Every score carries a small honesty label. Calibrating means NOOP is still learning your baseline, or doesn't have enough data yet. Building means there's enough to show, but it's thin. Solid means full inputs are present. When NOOP can't compute a score honestly, it shows nothing rather than a fake number.")
                .font(StrandFont.light(13))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .padding(.top, 34)
    }

    private func confidenceRow(_ state: ScoreState, title: LocalizedStringKey, caption: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ScoreStatePill(state)
                .frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(StrandFont.book(14)).foregroundStyle(StrandPalette.textPrimary)
                Text(caption).font(StrandFont.light(12)).foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    // MARK: - Deep-link

    /// Scroll to the requested section and pulse its highlight, then fade it.
    private func jump(to section: ScoreSection?, using proxy: ScrollViewProxy) {
        guard let section else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(section.id, anchor: .top)
            }
            highlighted = section
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if highlighted == section { highlighted = nil }
            }
        }
    }
}

/// One named band of a score's 0–100 axis.
struct ScoringBand: Hashable {
    let label: String
    let lower: Double
}

/// The guide's band scale: rounded segments sized by each band's share of 0–100, the band holding
/// `value` lit in ink with its label, and the band edges as numbers underneath.
struct ScoringBandScale: View {
    let bands: [ScoringBand]
    let value: Double?

    private func upper(_ i: Int) -> Double { i + 1 < bands.count ? bands[i + 1].lower : 100 }
    private func isLit(_ i: Int) -> Bool {
        guard let value else { return false }
        return value >= bands[i].lower && (value < upper(i) || (i == bands.count - 1 && value <= 100))
    }

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 3
            let usable = geo.size.width - gap * CGFloat(max(bands.count - 1, 0))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: gap) {
                    ForEach(bands.indices, id: \.self) { i in
                        Capsule(style: .continuous)
                            .fill(isLit(i) ? StrandPalette.textPrimary : Color(light: "#D8D7D3", dark: "#2A2A31"))
                            .frame(width: usable * CGFloat((upper(i) - bands[i].lower) / 100), height: 8)
                    }
                }
                HStack(spacing: gap) {
                    ForEach(bands.indices, id: \.self) { i in
                        Text(verbatim: bands[i].label)
                            .font(isLit(i) ? StrandFont.book(11) : StrandFont.light(11))
                            .foregroundStyle(isLit(i) ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(width: usable * CGFloat((upper(i) - bands[i].lower) / 100), alignment: .leading)
                    }
                }
                .padding(.top, 8)
                HStack(spacing: gap) {
                    ForEach(bands.indices, id: \.self) { i in
                        Text(verbatim: "\(Int(bands[i].lower))")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: usable * CGFloat((upper(i) - bands[i].lower) / 100), alignment: .leading)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(height: 46)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: bands.map(\.label).joined(separator: ", ")))
    }
}

#if DEBUG
#Preview("Scoring guide") {
    ScoringGuideView(initialSection: .effort, onClose: {})
        .preferredColorScheme(.dark)
}
#endif
