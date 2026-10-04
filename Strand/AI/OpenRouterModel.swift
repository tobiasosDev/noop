import Foundation

/// Text-chat entries from OpenRouter's catalogue. Prices are USD per token on the wire; no price is
/// bundled with the app. The Kotlin twin is `OpenRouterModel`.
struct OpenRouterModel: Equatable {
    let id: String
    var name: String = ""
    var inputPrice: Double?
    var outputPrice: Double?

    // Budget-focused starting points verified against /api/v1/models. The live catalogue is the
    // authority after refresh; the selected id is retained even if it was retired or typed manually.
    static let recommendedIDs = [
        "z-ai/glm-5.3-flash",
        "deepseek/deepseek-v4-flash",
        "minimax/minimax-m2.7",
        "qwen/qwen3.6-35b-a3b",
        "qwen/qwen3.6-flash",
        "google/gemini-3.1-flash-lite"
    ]
    static let recommendedNames = [
        "GLM 5.3 Flash", "DeepSeek V4 Flash", "MiniMax M2.7",
        "Qwen3.6 35B A3B", "Qwen3.6 Flash", "Gemini 3.1 Flash Lite"
    ]

    var displayName: String {
        if !name.isEmpty { return name }
        if let index = Self.recommendedIDs.firstIndex(of: id) { return Self.recommendedNames[index] }
        return id
    }

    /// Fixed USD figures for locale-independent comparison; UI localizes the input/output labels.
    var priceFigures: (input: String, output: String)? {
        guard let inputPrice, let outputPrice else { return nil }
        return (Self.priceFigure(inputPrice), Self.priceFigure(outputPrice))
    }

    private static func priceFigure(_ price: Double) -> String {
        if price == 0 { return "$0" }
        if price * 1_000_000 < 0.0001 { return "<$0.0001" }
        var figure = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), price * 1_000_000)
        while figure.hasSuffix("0") { figure.removeLast() }
        if figure.hasSuffix(".") { figure.removeLast() }
        return "$" + figure
    }

    static func parse(_ json: [String: Any]) -> [OpenRouterModel] {
        guard let rows = json["data"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let rawID = row["id"] as? String else { return nil }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !id.hasSuffix(":batch"),
                  let architecture = row["architecture"] as? [String: Any],
                  let inputs = architecture["input_modalities"] as? [String], inputs.contains("text"),
                  let outputs = architecture["output_modalities"] as? [String], outputs == ["text"],
                  seen.insert(id).inserted else { return nil }
            let pricing = row["pricing"] as? [String: Any] ?? [:]
            return OpenRouterModel(id: id,
                name: (row["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                inputPrice: parsePrice(pricing["prompt"]), outputPrice: parsePrice(pricing["completion"]))
        }
    }

    private static func parsePrice(_ value: Any?) -> Double? {
        guard let raw = value as? String, let price = Double(raw), price.isFinite, price >= 0,
              (price * 1_000_000).isFinite else { return nil }
        return price
    }

    static func orderedIDs(_ models: [OpenRouterModel], selected: String) -> [String] {
        let live = Set(models.map(\.id))
        var ids = recommendedIDs.filter { live.contains($0) } + live.subtracting(recommendedIDs).sorted()
        if !selected.isEmpty, !ids.contains(selected) { ids.insert(selected, at: 0) }
        return ids
    }
}
