package com.noop.ble

import android.content.Context
import com.noop.data.WhoopRepository
import com.noop.protocol.DeviceFamily
import com.noop.protocol.extractHistoricalStreams
import java.io.File
import java.io.FileOutputStream

/**
 * Append-only on-device archive of HISTORICAL_DATA record frames that FAILED to decode (#77 / #91).
 *
 * WHY this exists: the strap FREES history once the phone acks its trim cursor. If a chunk's records
 * can't be decoded (CRC failure, or an unmapped firmware layout the v24 plausibility gate rejects),
 * acking anyway permanently destroys the user's ONLY copy of those records while the UI says "History
 * synced". So the Backfiller archives the raw bytes HERE — durably — BEFORE acking. The archive then
 * lets a later release that maps the layout recover the data, and is itself the corpus that mapping
 * needs. Frames carry sensor payloads, not identifiers (no serials/MACs).
 *
 * Format: one JSON object per line (JSONL) in the app-private filesDir, file [REJECTED_ARCHIVE_FILE]:
 *   {"capturedAtMs":<Long>,"trim":<Long>,"family":"whoop4"|"whoop5","frameHex":"<hex>"}
 * Each [append] flushes + fsyncs before returning, so a row is durable before the caller acks.
 *
 * Size cap ([maxBytes], ~5 MB): once the file reaches the cap, [append] does NOT write the frames but
 * still returns a SUCCESS result with [AppendResult.written] = false. That is deliberate — wedging the
 * whole offload on a full archive would be worse than dropping the newest few rejects, and by the time
 * 5 MB of rejects exist there is ample sample material to map the layout. The caller records the
 * not-written frames separately so the sync status never falsely claims they were preserved.
 *
 * A genuine WRITE FAILURE (I/O error) instead throws — the caller treats that as "do NOT ack", so the
 * strap keeps the records and re-sends them on the next offload. No data is lost either way.
 */
class RawHistoryArchive(
    private val context: Context,
    private val maxBytes: Long = REJECTED_ARCHIVE_MAX_BYTES,
) {
    /**
     * Outcome of an [append]. [ok] is true whenever the offload may proceed to ack; [written] is true
     * only when the bytes were actually persisted. (ok=true, written=false) is the archive-full case:
     * the offload continues but the frames were NOT preserved — surface that honestly.
     */
    data class AppendResult(val ok: Boolean, val written: Boolean)

    private val file: File get() = File(context.filesDir, REJECTED_ARCHIVE_FILE)

    /**
     * Durably append the given undecodable record [frames] (one JSONL line each). [trim] is the
     * HISTORY_END trim cursor the frames belong to; [family] tags the firmware generation so one
     * mapping toolchain can read both WHOOP 4 and 5/MG archives.
     *
     * Returns [AppendResult] (ok=true) on success, distinguishing actually-written from
     * archive-full-skipped. Throws [java.io.IOException] (and propagates other write errors) ONLY when
     * the bytes could not be made durable — the caller must then NOT ack so the strap re-sends.
     */
    fun append(frames: List<ByteArray>, trim: Long, family: DeviceFamily): AppendResult {
        if (frames.isEmpty()) return AppendResult(ok = true, written = false)

        val f = file
        // Cap reached: succeed WITHOUT writing so a full archive can't wedge the offload. The caller
        // tracks these as unarchived so the status stays honest.
        if (f.length() >= maxBytes) return AppendResult(ok = true, written = false)

        val familyTag = familyTag(family)
        val now = System.currentTimeMillis()
        // FileOutputStream in append mode; fsync the descriptor so the rows are durable BEFORE the ack
        // (the whole point of the archive). A throw here propagates → caller holds the ack.
        FileOutputStream(f, true).use { out ->
            val sb = StringBuilder()
            for (frame in frames) {
                sb.append(encodeLine(now, trim, familyTag, frame)).append('\n')
            }
            out.write(sb.toString().toByteArray(Charsets.UTF_8))
            out.flush()
            out.fd.sync()
        }
        return AppendResult(ok = true, written = true)
    }

    private fun encodeLine(capturedAtMs: Long, trim: Long, familyTag: String, frame: ByteArray): String =
        buildString {
            append("{\"capturedAtMs\":").append(capturedAtMs)
            append(",\"trim\":").append(trim)
            append(",\"family\":\"").append(familyTag).append('"')
            append(",\"frameHex\":\"").append(frame.toHex()).append("\"}")
        }

    private fun familyTag(family: DeviceFamily): String =
        if (family == DeviceFamily.WHOOP5) "whoop5" else "whoop4"

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    /**
     * Every archived frame with its strap family, oldest first — the read-back of the JSONL that
     * [append] writes. Malformed lines are skipped; an absent/empty file yields []. Mirrors the macOS
     * RawHistoryArchive.readAll (#151).
     */
    fun readAll(): List<Pair<ByteArray, DeviceFamily>> {
        val f = file
        if (!f.exists()) return emptyList()
        return f.readLines().mapNotNull { parseArchiveLine(it) }
    }

    /**
     * Re-decode every archived frame through the CURRENT decoder and insert whatever now decodes. The
     * strap freed these records when they were acked, so this archive is the ONLY way banked history
     * backfills after a newly-landed layout (e.g. WHOOP 4.0 v25). Idempotent: offloaded rows dedupe by
     * (deviceId, ts), so a re-run can't double-insert. Runs ONCE per [appVersion] (no manual
     * decoder-version constant to forget to bump — the archive is small, so the once-per-update cost is
     * negligible), and the gate advances ONLY when every insert succeeded: a failed insert leaves the
     * gate un-advanced so these records (whose only surviving copy is this archive) retry next launch.
     * Returns the rows recovered (for logging). Port of the macOS replay + BLEManager gate (#151, #152).
     */
    suspend fun replayIfNeeded(repository: WhoopRepository, deviceId: String, appVersion: String): Int {
        val prefs = context.getSharedPreferences(REPLAY_PREFS, Context.MODE_PRIVATE)
        if (prefs.getString(KEY_REPLAYED_APP_VERSION, null) == appVersion) return 0
        val archived = readAll()
        var rows = 0
        for (family in archived.map { it.second }.toSet()) {
            val frames = archived.filter { it.second == family }.map { it.first }
            // type-47 records carry their own real-unix ts (clock offset ignored), so an identity clock
            // ref is correct here — the same fallback the Backfiller uses when clockRef is nil.
            val decoded = extractHistoricalStreams(frames, 0, 0, family)
            // Count rows ACTUALLY inserted, not decoded: under the per-app-version gate the archive
            // replays every release, and dedupe makes those re-runs insert 0 — counting decoded rows
            // would log a false "retro-decoded N" success on every update. (#152)
            rows += try {
                repository.insert(decoded, deviceId).gravity
            } catch (t: Throwable) {
                // Do NOT advance the gate — retry the whole replay next launch (inserts are idempotent).
                return rows
            }
        }
        prefs.edit().putString(KEY_REPLAYED_APP_VERSION, appVersion).apply()
        return rows
    }

    companion object {
        /** Archive filename in the app-private filesDir. */
        const val REJECTED_ARCHIVE_FILE = "rejected_history.jsonl"

        /** ~5 MB cap; above this [append] reports success without writing (frames tracked as unarchived). */
        const val REJECTED_ARCHIVE_MAX_BYTES = 5L * 1024 * 1024

        /** Where the once-per-app-version replay marker lives. */
        const val REPLAY_PREFS = "noop_reject_replay"
        const val KEY_REPLAYED_APP_VERSION = "replayed_app_version"

        /**
         * Parse one archive JSONL line to (frame, family); null if malformed. Pure (no I/O) so the
         * read-back is unit-testable. Hand-parsed to match the hand-built [encodeLine] writer — the only
         * dynamic fields are `family` and the [0-9a-f] `frameHex`.
         */
        fun parseArchiveLine(line: String): Pair<ByteArray, DeviceFamily>? {
            val fam = jsonString(line, "family") ?: return null
            val hex = jsonString(line, "frameHex") ?: return null
            val family = if (fam == "whoop5") DeviceFamily.WHOOP5 else DeviceFamily.WHOOP4
            if (hex.length % 2 != 0) return null
            val bytes = try {
                ByteArray(hex.length / 2) {
                    ((hex[it * 2].digitToInt(16) shl 4) or hex[it * 2 + 1].digitToInt(16)).toByte()
                }
            } catch (e: IllegalArgumentException) { return null }
            return bytes to family
        }

        private fun jsonString(line: String, key: String): String? {
            val marker = "\"$key\":\""
            val i = line.indexOf(marker); if (i < 0) return null
            val start = i + marker.length
            val end = line.indexOf('"', start); if (end < 0) return null
            return line.substring(start, end)
        }
    }
}
