// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import java.io.File
import java.time.Instant
import java.time.ZoneId

/** Local projections only. Borrowed vocabulary is read-only, on the existing worker. */
object LocalWidgets {
    private fun row(state: String, message: String) = mapOf<String, Any?>(
        "state" to state, "message" to LuaValue.str(message), "row_count" to 1,
        "freshness" to mapOf("saved" to true, "origin" to "local-reader"))

    fun word(file: File, now: Long): Map<String, Any?> {
        if (!file.isFile) return row("empty", "Look up a word while reading.")
        return try { AndroidSql(file, readOnly = true).use { word(it, now) } }
        catch (e: Exception) { if (e is InterruptedException) throw e; row("error", "Vocabulary unavailable") }
    }
    fun word(db: Sql, now: Long, zone: ZoneId = ZoneId.systemDefault()): Map<String, Any?> {
        val day = Instant.ofEpochSecond(now).atZone(zone).toLocalDate().toEpochDay()
        // One SELECT uses one read snapshot, with at most one decoded record.
        return db.query("SELECT substr(v.word,1,96),substr(v.prev_context,1,120),substr(v.next_context,1,120),substr(t.name,1,100) FROM vocabulary v LEFT JOIN title t ON t.id=v.title_id ORDER BY v.word LIMIT 1 OFFSET (SELECT ((? % max(count(*),1)) + max(count(*),1)) % max(count(*),1) FROM vocabulary)", day) {
            row("ready", "On this reader") + mapOf(
                "word" to LuaValue.str(it.text(0).orEmpty()),
                "context" to LuaValue.str(listOfNotNull(it.text(1),it.text(0),it.text(2)).joinToString(" ").replace('\n',' ')),
                "source" to LuaValue.str(it.text(3) ?: "Source unavailable"))
        }.firstOrNull() ?: row("empty", "Look up a word while reading.")
    }

    fun buddy(stats: Map<String, Any?>): Map<String, Any?> {
        val records = stats["records"] as? Map<*, *>
        val streak = (records?.get("streak") as? Number)?.toLong()
        val pages = (records?.get("recorded_pages") as? Number)?.toLong()
        return when {
            stats["state"] == "error" -> row("error", "Reading activity unavailable")
            pages == null || pages == 0L -> row("empty", "Your next chapter is waiting.")
            streak != null && streak > 0 -> row("ready", "$streak day reading streak · On this reader")
            else -> row("ready", "Welcome back. Your next chapter is waiting.")
        }
    }
    fun light(native: Map<*, *>): Map<String, Any?> {
        val level = (native["level"] as? Number)?.toInt()?.takeIf { it in 0..100 }
        return if (native["supported"] != true || level == null) row("unavailable", "Frontlight unavailable on this reader")
        else row("ready", "Light · $level%") + mapOf("level" to level)
    }
}
