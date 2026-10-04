package com.noop.ai

import org.json.JSONObject
import java.util.Locale

/** Text-chat catalogue entries. Prices are USD per token; the app bundles no prices. Swift twin: OpenRouterModel. */
data class OpenRouterModel(
    val id: String,
    val name: String = "",
    val inputPrice: Double? = null,
    val outputPrice: Double? = null,
) {
    val displayName: String get() = name.ifEmpty {
        val index = recommendedIDs.indexOf(id)
        if (index >= 0) recommendedNames[index] else id
    }
    val priceFigures: Pair<String, String>? get() {
        val input = inputPrice ?: return null
        val output = outputPrice ?: return null
        return priceFigure(input) to priceFigure(output)
    }

    companion object {
        val recommendedIDs = listOf(
            "z-ai/glm-5.3-flash",
            "deepseek/deepseek-v4-flash",
            "minimax/minimax-m2.7",
            "qwen/qwen3.6-35b-a3b",
            "qwen/qwen3.6-flash",
            "google/gemini-3.1-flash-lite",
        )
        private val recommendedNames = listOf(
            "GLM 5.3 Flash", "DeepSeek V4 Flash", "MiniMax M2.7",
            "Qwen3.6 35B A3B", "Qwen3.6 Flash", "Gemini 3.1 Flash Lite",
        )

        private fun priceFigure(price: Double): String = when {
            price == 0.0 -> "$0"
            price * 1_000_000 < 0.0001 -> "<$0.0001"
            else -> "$" + String.format(Locale.US, "%.4f", price * 1_000_000).trimEnd('0').trimEnd('.')
        }

        fun parse(text: String): List<OpenRouterModel> {
            val rows = runCatching { JSONObject(text) }.getOrNull()?.optJSONArray("data") ?: return emptyList()
            val seen = HashSet<String>()
            return buildList {
                for (i in 0 until rows.length()) {
                    val row = rows.optJSONObject(i) ?: continue
                    val id = (row.opt("id") as? String)?.trim().orEmpty()
                    if (id.isEmpty() || id.endsWith(":batch")) continue
                    val architecture = row.optJSONObject("architecture") ?: continue
                    val inputs = architecture.optJSONArray("input_modalities") ?: continue
                    val outputs = architecture.optJSONArray("output_modalities") ?: continue
                    if (!(0 until inputs.length()).any { inputs.optString(it) == "text" }
                        || outputs.length() != 1 || outputs.optString(0) != "text" || !seen.add(id)) continue
                    val prices = row.optJSONObject("pricing")
                    add(OpenRouterModel(id, (row.opt("name") as? String)?.trim().orEmpty(),
                        parsePrice(prices?.opt("prompt")), parsePrice(prices?.opt("completion"))))
                }
            }
        }

        private fun parsePrice(value: Any?): Double? {
            val price = (value as? String)?.toDoubleOrNull() ?: return null
            return price.takeIf { it.isFinite() && it >= 0 && (it * 1_000_000).isFinite() }
        }

        fun orderedIDs(models: List<OpenRouterModel>, selected: String): List<String> {
            val live = models.map { it.id }.toSet()
            val ids = recommendedIDs.filter { it in live } + (live - recommendedIDs.toSet()).sorted()
            return if (selected.isNotEmpty() && selected !in ids) listOf(selected) + ids else ids
        }
    }
}
