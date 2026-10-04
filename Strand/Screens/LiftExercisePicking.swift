import SwiftUI
import StrandDesign
import WhoopStore

// What the two exercise pickers share: the program line editor (`LiftProgramItemSheet`) and the running
// session's Add exercise sheet (`LiftSessionExerciseSheet`). The user's own exercise names offered back,
// a name remembered with its muscles, and the muscle classification itself — one copy of each, so the two
// pickers cannot drift about what a name is or which muscles it works.

/// The user's own exercise names (`liftExercise`), as the pickers read and write them.
enum LiftExerciseVocabulary {

    /// Names matching what has been typed so far, minus an exact match (no point suggesting the thing
    /// already in the box), most recently used first as the store orders them. Capped — this is a hint,
    /// not a browser.
    static func suggestions(_ vocabulary: [LiftExerciseRow], matching typed: String,
                            limit: Int = 6) -> [LiftExerciseRow] {
        let query = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return Array(vocabulary.prefix(limit)) }
        return Array(vocabulary
            .filter { $0.name.lowercased().contains(query) && $0.name.lowercased() != query }
            .prefix(limit))
    }

    /// Remember `name` with its muscles, so it is offered back next time. `upsertLiftExercises` is keyed
    /// on (deviceId, name), so a known name is updated — its muscles, and when it was last used — never
    /// duplicated. Throws `WhoopStore.LiftExerciseVocabularyFull` for a NEW name once the vocabulary is
    /// full, which the caller explains rather than dropping the name silently.
    static func remember(_ name: String, primary: LiftMuscle?, secondaries: [LiftMuscle],
                         known vocabulary: [LiftExerciseRow], deviceId: String,
                         in store: WhoopStore) async throws {
        let now = Int(Date().timeIntervalSince1970)
        let existing = vocabulary.first { $0.name == name }
        _ = try await store.upsertLiftExercises([LiftExerciseRow(
            id: existing?.id ?? UUID().uuidString,
            deviceId: deviceId,
            name: name,
            primaryMuscle: primary,
            secondaryMuscles: secondaries,
            createdAt: existing?.createdAt ?? now,
            lastUsedTs: now)])
    }

    /// Secondaries in the vocabulary's canonical order rather than `Set` iteration order, so the stored
    /// list is stable between saves instead of reshuffling on every edit.
    static func ordered(_ secondaries: Set<LiftMuscle>, excluding primary: LiftMuscle?) -> [LiftMuscle] {
        LiftMuscle.ordered.filter { secondaries.contains($0) && $0 != primary }
    }
}

/// One remembered exercise as a picker lists it: its name, and the muscles it is known by.
struct LiftExerciseSuggestionLabel: View {
    let row: LiftExerciseRow

    var body: some View {
        HStack(spacing: 8) {
            PhIcon("arrow-up-left", size: 14)
                .foregroundStyle(StrandPalette.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(StrandFont.book(15, relativeTo: .body))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(LiftMuscleSummary.line(primary: row.primaryMuscle, secondaries: row.secondaryMuscles))
                    .font(StrandFont.light(12, relativeTo: .caption))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// The muscle classification: the primary muscle (a direct set) and the muscles an exercise also works
/// (half a set each). Asked once per exercise and remembered with its name; leaving it unset is allowed —
/// an unclassified exercise still counts toward volume and session load, it simply claims no muscle it
/// was never assigned.
struct LiftMusclePicker: View {
    @Binding var primary: LiftMuscle?
    @Binding var secondaries: Set<LiftMuscle>

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopSectionTitle("Muscles", captionKey: "Counted once per exercise", topPadding: 0)
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Primary").strandOverline()
                        Menu {
                            Button("Not classified") { primary = nil }
                            ForEach(LiftMuscle.Region.allCases, id: \.self) { region in
                                Section(region.displayName) {
                                    ForEach(LiftMuscle.inRegion(region), id: \.self) { muscle in
                                        Button(muscle.displayName) { select(primary: muscle) }
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(primary?.displayName ?? String(localized: "Not classified"))
                                    .font(StrandFont.body)
                                    .foregroundStyle(primary == nil
                                                     ? StrandPalette.textTertiary
                                                     : StrandPalette.textPrimary)
                                Spacer(minLength: 0)
                                PhIcon("caret-up-down", size: 14)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Primary muscle")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Also works (counted as half a set)").strandOverline()
                        // Content-sized chips that wrap, like the kit's `.chip`: a fixed three-column grid cut
                        // the longer German names ("Seitliche Schulter", "Schräge Bauchmuskeln") short.
                        LiftChipFlow(spacing: 8, lineSpacing: 8) {
                            ForEach(LiftMuscle.allCases, id: \.self) { muscle in
                                if muscle != primary {
                                    secondaryChip(muscle)
                                }
                            }
                        }
                    }

                    Text("Direct sets count once, indirect sets count as a half. That split is what makes the weekly per-muscle figures mean anything.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func secondaryChip(_ muscle: LiftMuscle) -> some View {
        let on = secondaries.contains(muscle)
        return Button {
            if on { secondaries.remove(muscle) } else { secondaries.insert(muscle) }
        } label: {
            Text(muscle.displayName)
                .font(StrandFont.book(12, relativeTo: .caption))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(on ? StrandPalette.goldDeepText : StrandPalette.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule(style: .continuous).fill(on ? StrandPalette.gold : NoopVisualStyle.inset))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(on ? Color.clear : NoopVisualStyle.border, lineWidth: 1))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// Setting a primary that is also ticked as a secondary drops it from the secondaries: one
    /// muscle can never be credited twice for the same set.
    private func select(primary muscle: LiftMuscle) {
        primary = muscle
        secondaries.remove(muscle)
    }
}

/// A leading-aligned wrapping row of chips: each keeps its natural width and a line breaks before the
/// chip that would overflow it.
struct LiftChipFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    private func lines(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var out: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > width {
                out.append([])
                x = 0
            }
            x += (x > 0 ? spacing : 0) + size.width
            out[out.count - 1].append((i, size))
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let ls = lines(subviews, width: width)
        let height = ls.reduce(CGFloat(0)) { $0 + ($1.map(\.1.height).max() ?? 0) }
            + lineSpacing * CGFloat(max(ls.count - 1, 0))
        let lineWidths: [CGFloat] = ls.map { line in
            let contentWidth: CGFloat = line.reduce(0) { $0 + $1.1.width }
            let gapWidth: CGFloat = spacing * CGFloat(max(line.count - 1, 0))
            return contentWidth + gapWidth
        }
        let widest: CGFloat = lineWidths.max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            let lineHeight = line.map(\.1.height).max() ?? 0
            var x = bounds.minX
            for (i, size) in line {
                subviews[i].place(at: CGPoint(x: x, y: y + (lineHeight - size.height) / 2),
                                  proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += lineHeight + lineSpacing
        }
    }
}
