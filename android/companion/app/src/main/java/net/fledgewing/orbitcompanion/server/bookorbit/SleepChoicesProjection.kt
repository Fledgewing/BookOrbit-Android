package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

/** Normalize existing cached section rows before the sleep picker sees them. Worker only. */
object SleepChoicesProjection : CachedListProjection {
    override fun read(sql: Sql, saved: SleepChoices?): SleepChoices? {
            var out = saved ?: SleepChoices(0, true, emptyList(), emptyList(), emptyList())
            var found = saved != null
            for ((kind, section) in listOf("scope" to "smart-scopes", "collection" to "collections", "library" to "libraries")) {
                val bulk = sql.query("SELECT v FROM meta WHERE k='bulk_active'") { it.text(0)?.toLongOrNull() }.firstOrNull()
                val head = if (bulk != null) Triple("", sql.query("SELECT count(*) FROM bulk_sections WHERE g=? AND section=?", bulk, section) { it.long(0)!! }.first(),
                    sql.query("SELECT v FROM meta WHERE k='bulk_at'") { it.text(0)?.toLongOrNull() ?: 0L }.firstOrNull() ?: 0L)
                else sql.query("SELECT identity, total, MAX(fetched_at, validated_at) FROM lists WHERE kind = 'section' AND section = ? ORDER BY MAX(fetched_at, validated_at) DESC LIMIT 1", section) {
                    Triple(it.text(0)!!, it.long(1) ?: 0, it.long(2) ?: 0)
                }.firstOrNull() ?: continue
                if (saved != null && kind in saved.listed && head.third < saved.at) continue
                val rows = if (bulk != null) sql.query("SELECT item FROM bulk_sections WHERE g=? AND section=? ORDER BY pos", bulk, section) {
                    it.bytes(0)?.let { b -> LuaValue.parse(b) as? Map<*, *> }
                } else sql.query("SELECT item FROM list_items WHERE identity = ? ORDER BY pos", head.first) {
                    it.bytes(0)?.let { b -> LuaValue.parse(b) as? Map<*, *> }
                }
                if (rows.size.toLong() != head.second || rows.any { it == null }) continue
                val items = rows.filterNotNull().mapNotNull { r ->
                    val id = (r["id"] as? Number)?.toLong() ?: r["id"]?.toString()?.toLongOrNull() ?: return@mapNotNull null
                    val title = r["title"]?.let { LuaValue.text(it) } ?: return@mapNotNull null
                    SleepChoices.Item(id, title, (r["count"] as? Number)?.toInt())
                }
                if (items.size != rows.size) continue
                out = when (kind) {
                    "scope" -> out.copy(scopes = items)
                    "collection" -> out.copy(collections = items)
                    else -> out.copy(libraries = items)
                }.copy(at = maxOf(out.at, head.third), listed = out.listed + kind)
                found = true
            }
            return out.takeIf { found }
        }

}
