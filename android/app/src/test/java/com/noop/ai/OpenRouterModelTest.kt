package com.noop.ai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OpenRouterModelTest {
    private val fixture = """
        {"data":[{"id":" z-ai/glm-5.3-flash ","name":" GLM 5.3 Flash ","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"pricing":{"prompt":"0.00000015","completion":"0.0000005"}},{"id":"vendor/free","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"pricing":{"prompt":"0","completion":"-0"}},{"id":"vendor/tiny","name":"Tiny","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"pricing":{"prompt":"0.00000000001","completion":"0.00000000004"}},{"id":"vendor/unknown","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"pricing":{"prompt":"NaN","completion":"-1"}},{"id":"vendor/invalid","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"pricing":{"prompt":"Infinity","completion":"1e308"}},{"id":"vendor/fraction","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"pricing":{"prompt":"0.0000000352","completion":"0.00000234567"}},{"id":"vendor/number","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"pricing":{"prompt":0,"completion":"0"}},{"id":"z-ai/glm-5.3-flash","name":"duplicate","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}},{"id":"vendor/image","architecture":{"input_modalities":["text"],"output_modalities":["image"]}},{"id":"vendor/embedding","architecture":{"input_modalities":["text"],"output_modalities":["embeddings"]}},{"id":"vendor/audio","architecture":{"input_modalities":["audio"],"output_modalities":["text"]}},{"id":"z-ai/glm-5.3-flash:batch","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}},{"id":" ","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}},{"id":"vendor/missing"},{"id":123,"architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}}]}
    """.trimIndent()

    // Verbatim stdout from swiftc -O OpenRouterModel.swift main.swift, not a hand-transcribed expectation.
    private val expected = """
        z-ai/glm-5.3-flash|GLM 5.3 Flash|${'$'}0.15/${'$'}0.5
        vendor/free|vendor/free|${'$'}0/${'$'}0
        vendor/tiny|Tiny|<${'$'}0.0001/<${'$'}0.0001
        vendor/unknown|vendor/unknown|unknown
        vendor/invalid|vendor/invalid|unknown
        vendor/fraction|vendor/fraction|${'$'}0.0352/${'$'}2.3457
        vendor/number|vendor/number|unknown
        vendor/manual,z-ai/glm-5.3-flash,vendor/fraction,vendor/free,vendor/invalid,vendor/number,vendor/tiny,vendor/unknown
    """.trimIndent()

    @Test fun catalogueAndPricesMatchSwiftOracle() {
        val models = OpenRouterModel.parse(fixture)
        val lines = models.map { m ->
            val price = m.priceFigures?.let { it.first + "/" + it.second } ?: "unknown"
            m.id + "|" + m.displayName + "|" + price
        } + OpenRouterModel.orderedIDs(models, "vendor/manual").joinToString(",")
        assertEquals(expected, lines.joinToString("\n"))
        assertEquals(models.map { it.id }, AiCoach.parseOpenAiCompatibleModels(AiProvider.OPENROUTER, fixture))
    }

    @Test fun liveListDropsUnavailableRecommendationsButPreservesSelection() {
        val live = listOf(OpenRouterModel("vendor/new"), OpenRouterModel("minimax/minimax-m2.7"))
        assertEquals(listOf("retired/model", "minimax/minimax-m2.7", "vendor/new"),
            OpenRouterModel.orderedIDs(live, "retired/model"))
        assertEquals(listOf("minimax/minimax-m2.7", "vendor/new"),
            OpenRouterModel.orderedIDs(live, "vendor/new"))
    }

    @Test fun providerDefaultsAndMalformedCatalogues() {
        assertEquals("z-ai/glm-5.3-flash", AiProvider.OPENROUTER.defaultModel)
        assertEquals(OpenRouterModel.recommendedIDs, AiProvider.OPENROUTER.models)
        assertEquals(AiProvider.OPENROUTER, AiProvider.fromName("OPENROUTER"))
        assertEquals("https://openrouter.ai/api/v1/chat/completions", AiProvider.OPENROUTER.endpoint)
        assertTrue(OpenRouterModel.parse("{}").isEmpty())
        assertTrue(OpenRouterModel.parse("invalid json").isEmpty())
    }
}
