package com.noop.data

/** Explicit equivalents of journal questions. Unknown/custom questions keep their original key.
 * No fuzzy/keyword matching: different behaviours and time windows must remain separate.
 * Mirrors Swift JournalQuestionIdentity; imported rows remain unchanged on disk. */
object JournalQuestionIdentity {
    /** Swift twin: `JournalQuestionIdentity.canonical`. */
    fun canonical(question: String): String = when (normalise(question)) {
        "did you drink any alcohol?", "did you drink alcohol?", "alkohol konsumiert?", "alkohol getrunken?", "hast du alkohol konsumiert?", "hast du alkohol getrunken?" ->
            "Did you drink any alcohol?"
        "did you have caffeine late in the day?", "spät am tag koffein konsumiert?", "koffein spät am tag konsumiert?", "hast du spät am tag koffein konsumiert?" ->
            "Did you have caffeine late in the day?"
        "did you view a screen in bed?", "einen bildschirm im bett angesehen?", "im bett auf einen bildschirm geschaut?", "bildschirm im bett genutzt?", "hast du im bett auf einen bildschirm geschaut?" ->
            "Did you view a screen in bed?"
        "did you eat close to bedtime?", "kurz vor dem schlafengehen gegessen?", "kurz vor dem zubettgehen gegessen?", "hast du kurz vor dem schlafengehen gegessen?" ->
            "Did you eat close to bedtime?"
        "did you feel stressed?", "dich gestresst gefühlt?", "gestresst gefühlt?", "hast du dich gestresst gefühlt?" ->
            "Did you feel stressed?"
        "did you use a sauna?", "eine sauna benutzt?", "eine sauna genutzt?", "in der sauna gewesen?", "hast du eine sauna benutzt?" ->
            "Did you use a sauna?"
        "did you share your bed?", "dein bett geteilt?", "das bett geteilt?", "hast du dein bett geteilt?" ->
            "Did you share your bed?"
        "did you feel sick or ill?", "did you feel sick?", "dich krank gefühlt?", "krank gefühlt?", "hast du dich krank gefühlt?" ->
            "Did you feel sick or ill?"
        "did you take magnesium?", "magnesium eingenommen?", "hast du magnesium eingenommen?" ->
            "Did you take magnesium?"
        "did you read before bed?", "vor dem schlafengehen gelesen?", "vor dem zubettgehen gelesen?", "hast du vor dem schlafengehen gelesen?" ->
            "Did you read before bed?"
        "did you feel bloated?", "did you experience bloating?", "blähungen gehabt?", "hast du blähungen gehabt?" ->
            "Did you feel bloated?"
        "did you have an injury or wound?", "eine verletzung oder wunde haben?", "eine verletzung oder wunde gehabt?", "hast du eine verletzung oder wunde gehabt?" ->
            "Did you have an injury or wound?"
        else -> question
    }

    /** Swift twin: `JournalQuestionIdentity.key`. */
    fun key(question: String): String = normalise(canonical(question))

    /** Eligible experiment questions share the same identity as history and catalog hiding.
     * Swift twin: `JournalQuestionIdentity.candidates`. */
    fun candidates(logged: List<String>, imported: List<String>, hidden: List<String>, saved: String): List<String> {
        val hiddenKeys = hidden.map(::key).toHashSet()
        val seen = HashSet<String>()
        return (logged.sorted() + imported + saved).map { canonical(it.trim()) }.filter {
            it.isNotEmpty() && key(it) !in hiddenKeys && seen.add(key(it))
        }
    }

    /** Swift twin: `JournalQuestionIdentity.normalise`. */
    // Char.isWhitespace handles Unicode spaces without Android-unsupported regex flags.
    private fun normalise(question: String): String = buildString {
        var previousSpace = true
        for (c in question) {
            if (c.isWhitespace()) {
                if (!previousSpace) append(' ')
                previousSpace = true
            } else {
                append(c)
                previousSpace = false
            }
        }
    }.trim().lowercase(java.util.Locale.ROOT)
}

/** One row per day/identity. Within one source an already canonical row wins over an alias,
 * since new native writes use that key. Otherwise the last row wins, matching existing reads.
 * Notes and numeric values travel with the winning answer; no answer is invented or averaged. */
fun canonicalJournalEntries(rows: List<JournalEntry>): List<JournalEntry> {
    val byKey = LinkedHashMap<Pair<String, String>, JournalEntry>()
    val canonicalKeys = HashSet<Pair<String, String>>()
    for (row in rows) {
        val question = JournalQuestionIdentity.canonical(row.question)
        val key = row.day to question
        if (key in canonicalKeys && row.question != question) continue
        byKey[key] = row.copy(question = question)
        if (row.question == question) canonicalKeys.add(key)
    }
    return byKey.values.sortedWith(compareBy({ it.day }, { it.question }))
}
