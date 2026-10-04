package com.noop.data

import androidx.room.Room
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class JournalAnswerStoreTest {
    @Test
    fun saveAndClearReplaceAliasesWithinSourceAndDayOnly() = runBlocking {
        val db = Room.inMemoryDatabaseBuilder(
            InstrumentationRegistry.getInstrumentation().targetContext,
            WhoopDatabase::class.java,
        ).allowMainThreadQueries().build()
        try {
            val dao = db.whoopDao()
            val day = "2026-10-01"
            val alias = JournalEntry("noop-journal", day, "Magnesium eingenommen?", true, notes = "imported")
            val english = alias.copy(question = "Did you take magnesium?", answeredYes = false, notes = null)
            val other = alias.copy(question = "Did you read before bed?", answeredYes = false, notes = null)
            val previous = alias.copy(day = "2026-09-30", notes = null)
            val imported = alias.copy(deviceId = "my-whoop")
            dao.upsertJournal(listOf(alias, english, other, previous, imported))
            dao.saveJournalAnswers(listOf(alias.copy(notes = "edited", numericValue = 200.0)))
            val saved = dao.journal("noop-journal", day, day)
            assertEquals(2, saved.size)
            assertEquals(english.copy(answeredYes = true, notes = "edited", numericValue = 200.0),
                saved.first { it.question == english.question })
            // A legacy backup may restore an alias beside the canonical answer.
            dao.upsertJournal(listOf(alias))
            dao.deleteJournalAnswers("noop-journal", day, alias.question)
            assertEquals(listOf(previous, other), dao.journal("noop-journal", "2026-09-30", day))
            assertEquals(listOf(imported), dao.journal("my-whoop", day, day))
        } finally {
            db.close()
        }
    }
}
