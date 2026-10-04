package com.noop.data

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Test

class JournalQuestionIdentityTest {
    @Test
    fun matchesStandaloneSwiftOracleForEveryAliasAndDistinctQuestions() {
        val inputs = JSONArray("""["Did you drink any alcohol?", "Did you drink alcohol?", "Alkohol konsumiert?", "Alkohol getrunken?", "Hast du Alkohol konsumiert?", "Hast du Alkohol getrunken?", "Did you have caffeine late in the day?", "Spät am Tag Koffein konsumiert?", "Koffein spät am Tag konsumiert?", "Hast du spät am Tag Koffein konsumiert?", "Did you view a screen in bed?", "Einen Bildschirm im Bett angesehen?", "Im Bett auf einen Bildschirm geschaut?", "Bildschirm im Bett genutzt?", "Hast du im Bett auf einen Bildschirm geschaut?", "Did you eat close to bedtime?", "Kurz vor dem Schlafengehen gegessen?", "Kurz vor dem Zubettgehen gegessen?", "Hast du kurz vor dem Schlafengehen gegessen?", "Did you feel stressed?", "Dich gestresst gefühlt?", "Gestresst gefühlt?", "Hast du dich gestresst gefühlt?", "Did you use a sauna?", "Eine Sauna benutzt?", "Eine Sauna genutzt?", "In der Sauna gewesen?", "Hast du eine Sauna benutzt?", "Did you share your bed?", "Dein Bett geteilt?", "Das Bett geteilt?", "Hast du dein Bett geteilt?", "Did you feel sick or ill?", "Did you feel sick?", "Dich krank gefühlt?", "Krank gefühlt?", "Hast du dich krank gefühlt?", "Did you take magnesium?", "Magnesium eingenommen?", "Hast du Magnesium eingenommen?", "Did you read before bed?", "Vor dem Schlafengehen gelesen?", "Vor dem Zubettgehen gelesen?", "Hast du vor dem Schlafengehen gelesen?", "Did you feel bloated?", "Did you experience bloating?", "Blähungen gehabt?", "Hast du Blähungen gehabt?", "Did you have an injury or wound?", "Eine Verletzung oder Wunde haben?", "Eine Verletzung oder Wunde gehabt?", "Hast du eine Verletzung oder Wunde gehabt?", "  MAGNESIUM EINGENOMMEN?\n", "DICH KRANK GEFÜHLT?", "Koffein konsumiert?", "Did you have caffeine?", "Did you drink any alcohol yesterday?", "  My custom question  ", ""]""")
        val actual = (0 until inputs.length()).joinToString("\n") {
            val input = inputs.getString(it)
            JournalQuestionIdentity.canonical(input).replace("\n", "\\n") + "|" + JournalQuestionIdentity.key(input)
        }
        // Verbatim stdout of swiftc -O JournalQuestionIdentity.swift main.swift.
        val expected = """
            Did you drink any alcohol?|did you drink any alcohol?
            Did you drink any alcohol?|did you drink any alcohol?
            Did you drink any alcohol?|did you drink any alcohol?
            Did you drink any alcohol?|did you drink any alcohol?
            Did you drink any alcohol?|did you drink any alcohol?
            Did you drink any alcohol?|did you drink any alcohol?
            Did you have caffeine late in the day?|did you have caffeine late in the day?
            Did you have caffeine late in the day?|did you have caffeine late in the day?
            Did you have caffeine late in the day?|did you have caffeine late in the day?
            Did you have caffeine late in the day?|did you have caffeine late in the day?
            Did you view a screen in bed?|did you view a screen in bed?
            Did you view a screen in bed?|did you view a screen in bed?
            Did you view a screen in bed?|did you view a screen in bed?
            Did you view a screen in bed?|did you view a screen in bed?
            Did you view a screen in bed?|did you view a screen in bed?
            Did you eat close to bedtime?|did you eat close to bedtime?
            Did you eat close to bedtime?|did you eat close to bedtime?
            Did you eat close to bedtime?|did you eat close to bedtime?
            Did you eat close to bedtime?|did you eat close to bedtime?
            Did you feel stressed?|did you feel stressed?
            Did you feel stressed?|did you feel stressed?
            Did you feel stressed?|did you feel stressed?
            Did you feel stressed?|did you feel stressed?
            Did you use a sauna?|did you use a sauna?
            Did you use a sauna?|did you use a sauna?
            Did you use a sauna?|did you use a sauna?
            Did you use a sauna?|did you use a sauna?
            Did you use a sauna?|did you use a sauna?
            Did you share your bed?|did you share your bed?
            Did you share your bed?|did you share your bed?
            Did you share your bed?|did you share your bed?
            Did you share your bed?|did you share your bed?
            Did you feel sick or ill?|did you feel sick or ill?
            Did you feel sick or ill?|did you feel sick or ill?
            Did you feel sick or ill?|did you feel sick or ill?
            Did you feel sick or ill?|did you feel sick or ill?
            Did you feel sick or ill?|did you feel sick or ill?
            Did you take magnesium?|did you take magnesium?
            Did you take magnesium?|did you take magnesium?
            Did you take magnesium?|did you take magnesium?
            Did you read before bed?|did you read before bed?
            Did you read before bed?|did you read before bed?
            Did you read before bed?|did you read before bed?
            Did you read before bed?|did you read before bed?
            Did you feel bloated?|did you feel bloated?
            Did you feel bloated?|did you feel bloated?
            Did you feel bloated?|did you feel bloated?
            Did you feel bloated?|did you feel bloated?
            Did you have an injury or wound?|did you have an injury or wound?
            Did you have an injury or wound?|did you have an injury or wound?
            Did you have an injury or wound?|did you have an injury or wound?
            Did you have an injury or wound?|did you have an injury or wound?
            Did you take magnesium?|did you take magnesium?
            Did you feel sick or ill?|did you feel sick or ill?
            Koffein konsumiert?|koffein konsumiert?
            Did you have caffeine?|did you have caffeine?
            Did you drink any alcohol yesterday?|did you drink any alcohol yesterday?
              My custom question  |my custom question
            |
        """.trimIndent()
        assertEquals(expected, actual)
    }
    @Test
    fun experimentCandidatesDeduplicateTranslationsAndRespectHiddenAliases() {
        // Standalone Swift candidates oracle: Did you share your bed?|Did you feel sick or ill?
        val candidates = JournalQuestionIdentity.candidates(
            logged = listOf("Did you share your bed?", "Did you drink any alcohol?"),
            imported = listOf("Dein Bett geteilt?", "Dich krank gefühlt?", "Did you feel sick or ill?"),
            hidden = listOf("Alkohol konsumiert?"), saved = "Dich krank gefühlt?",
        )
        assertEquals("Did you share your bed?|Did you feel sick or ill?", candidates.joinToString("|"))
        assertEquals(emptyList<String>(), JournalQuestionIdentity.candidates(emptyList(), emptyList(), emptyList(), ""))
    }

}
