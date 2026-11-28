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
    fun controls(native:Map<*,*>,now:Long):Map<String,Any?> {
        val at=(native["at"] as? Number)?.toLong()?.takeIf { it>0 && it<=now }
        val known=native["kind"] in setOf("menu_sync","sync_and_sleep") && at!=null && native["ok"] is Boolean
        val busy=native["sync_busy"]==true
        val result=when { busy -> "Syncing…";!known -> "No saved sync check";native["ok"]==true -> "Last sync check succeeded";else -> "Saved here · sync check failed" }
        val age=if(known) (now-at!!).let { if(it<60) "Just checked" else if(it<3600) "Checked ${it/60} min ago" else if(it<86400) "Checked ${it/3600} h ago" else "Checked ${it/86400} d ago" } else "Reading sync · not catalog Refresh"
        val wifi=native["wifi_available"]==true && native["wifi_on"] is Boolean
        return row("ready",result)+mapOf("result" to LuaValue.str(result),"age" to LuaValue.str(age),
            "sync_enabled" to (native["sync_available"]==true && !busy),"sync_label" to LuaValue.str(if(busy) "Syncing…" else "Sync now"),
            "wifi_enabled" to (wifi && native["wifi_busy"]!=true),"wifi_label" to when { !wifi -> "Wi-Fi unavailable";native["wifi_busy"]==true -> "Wi-Fi busy";native["wifi_on"]==true -> "Wi-Fi on";else -> "Wi-Fi off" },
            "night_label" to if(native["night"]==true) "Night on" else "Night off","rotate_enabled" to (native["rotate_available"]==true),"rotate_label" to "Rotate")
    }
    fun light(native: Map<*, *>): Map<String, Any?> {
        val level = (native["level"] as? Number)?.toInt()?.takeIf { it in 0..100 }
        return if (native["supported"] != true || level == null) row("unavailable", "Frontlight unavailable on this reader")
        else row("ready", "Light · $level%") + mapOf("level" to level)
    }
}
