import SwiftUI
import StrandDesign

/// Shared by first-run setup and Coach settings; only an explicit refresh contacts OpenRouter here.
struct OpenRouterModelSelection: View {
    @EnvironmentObject var coach: AICoachEngine
    @State private var choosingModel = false
    @State private var refreshing = false

    private var selected: OpenRouterModel {
        coach.modelDetails[coach.model] ?? OpenRouterModel(id: coach.model)
    }

    var body: some View {
        NoopList {
            Button { choosingModel = true } label: {
                HStack(spacing: NoopVisualStyle.itemGap) {
                    G3RowLabel(title: Text("Model"), caption: Text(verbatim: selected.displayName), icon: "cpu")
                    PhIcon("caret-up-down")
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .padding(NoopVisualStyle.cardPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Model"))
            .accessibilityValue(Text(verbatim: selected.displayName))

            Button {
                Task {
                    refreshing = true
                    await coach.refreshModels()
                    refreshing = false
                }
            } label: {
                G3RowLabel(title: Text("Refresh models"), icon: "arrows-clockwise")
                    .padding(NoopVisualStyle.cardPadding)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!coach.hasKey || refreshing)
        }
        Group {
            if let figures = selected.priceFigures {
                Text("Input \(figures.input) · Output \(figures.output) / 1M tokens (USD)")
            } else {
                Text("Refresh models to load current prices.")
            }
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $choosingModel) {
            OpenRouterModelPicker()
                .environmentObject(coach)
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 560)
                #endif
        }
    }
}

private struct OpenRouterModelPicker: View {
    @EnvironmentObject var coach: AICoachEngine
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filteredIDs: [String] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return coach.availableModels.filter { id in
            search.isEmpty || id.localizedCaseInsensitiveContains(search)
                || (coach.modelDetails[id] ?? OpenRouterModel(id: id)).displayName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ScreenScaffold(title: nil) {
            NoopScreenHeader("OpenRouter models")
            HStack(spacing: NoopVisualStyle.itemGap) {
                PhIcon("magnifying-glass")
                TextField("Search models or enter a model id", text: $query)
                    .textFieldStyle(.plain)
                    .disableAutocorrection(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            .font(StrandFont.body)
            .foregroundStyle(StrandPalette.textPrimary)
            .g3FieldChrome()

            let budget = filteredIDs.filter { OpenRouterModel.recommendedIDs.contains($0) }
            let other = filteredIDs.filter { !OpenRouterModel.recommendedIDs.contains($0) }
            if !budget.isEmpty {
                NoopSectionTitle("Budget picks")
                modelRows(budget)
            }
            if !other.isEmpty {
                NoopSectionTitle("All models")
                modelRows(other)
            }
            let customID = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !customID.isEmpty, !coach.availableModels.contains(customID) {
                NoopButton("Use custom model", kind: .secondary, fullWidth: true) {
                    coach.setCustomModel(customID)
                    dismiss()
                }
            }
            Text("Prices from the current OpenRouter catalogue. Routing, caching and fees can change the final cost.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .noopHidesSystemNavBar()
    }

    private func modelRows(_ ids: [String]) -> some View {
        NoopList {
            ForEach(ids, id: \.self) { id in
                let option = coach.modelDetails[id] ?? OpenRouterModel(id: id)
                Button {
                    coach.model = id
                    dismiss()
                } label: {
                    HStack(spacing: NoopVisualStyle.itemGap) {
                        VStack(alignment: .leading, spacing: NoopVisualStyle.itemGap / 2) {
                            Text(verbatim: option.displayName)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(verbatim: id)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                            if let figures = option.priceFigures {
                                Text("Input \(figures.input) · Output \(figures.output) / 1M tokens (USD)")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        G3RadioMark(isOn: coach.model == id)
                    }
                    .padding(NoopVisualStyle.cardPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(coach.model == id ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}
