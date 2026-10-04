package com.noop.ai

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class OpenRouterRoutingTest {
    @Test
    fun everyRequestVariantRequiresZDR() {
        for (modern in listOf(false, true)) {
            for (stream in listOf(false, true)) {
                val body = AiCoach.openAiCompatibleBody(
                    AiProvider.OPENROUTER, "vendor/model", JSONArray(), modern, stream)
                assertEquals(true, body.getJSONObject("provider").getBoolean("zdr"))
                assertEquals(4096, body.getInt(if (modern) "max_completion_tokens" else "max_tokens"))
                assertEquals(stream, body.optBoolean("stream"))
            }
        }
    }

    @Test
    fun otherProvidersDoNotReceiveOpenRouterRoutingParameters() {
        for (provider in listOf(AiProvider.OPENAI, AiProvider.CUSTOM)) {
            val body = AiCoach.openAiCompatibleBody(provider, "model", JSONArray())
            assertFalse(body.has("provider"))
        }
    }
}
