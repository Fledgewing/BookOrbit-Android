package net.fledgewing.orbitcompanion

import java.time.Instant
import java.time.ZoneOffset
import java.util.Locale

/** Counts run on the worker over the same source/overlay as windows. Only one page leaves it. */
internal class LibraryFacets(val field: String, private val query: Map<String, Any?>, now: Long) {
    companion object { val fields = setOf("show", "where", "author", "series", "tags", "len", "rating", "added") }
    private val multi = field in setOf("author", "series", "tags")
    private val options = linkedMapOf<String, Any?>()
    private val labels = mutableMapOf<String, String>()
    private val counts = mutableMapOf<String, Int>()
    val others = query - field - (if (field == "len") setOf("length") else if (field == "show") setOf("wtr") else emptySet())
    init {
        require(field in fields)
        fun add(id: String, label: String, value: Any? = null) { options[id] = value; labels[id] = if (multi) label else LuaValue.str(label) }
        when (field) {
            "show" -> { add("any", "All"); for ((id, label) in listOf("unread" to "Unread", "reading" to "Reading", "finished" to "Finished", "want-to-read" to "Want to read")) add(id, label, id) }
            "where" -> { add("any", "Anywhere"); add("on-device", "On this device", "on-device"); add("server-only", "Server only", "server-only") }
            "len" -> { add("any", "Any length"); add("short", "Short · under 250 pages", mapOf("max" to 249)); add("medium", "Medium · 250 to 450 pages", mapOf("min" to 250, "max" to 450)); add("long", "Long · over 450 pages", mapOf("min" to 451)) }
            "rating" -> { add("any", "Any rating"); for (n in 3..5) add("$n", if (n == 5) "5★ only" else "$n★ and up", mapOf("min" to n)) }
            "added" -> {
                add("any", "Any time")
                val today = Instant.ofEpochSecond(now).atZone(ZoneOffset.UTC).toLocalDate()
                for ((days, label) in listOf(7L to "This week", 31L to "This month", 365L to "This year")) add("$days", label, mapOf("min" to today.minusDays(days - 1).toString()))
            }
        }
        if (multi) for (v in (query[field] as? List<*>).orEmpty().filterIsInstance<String>()) add(v, v, v)
    }
    private fun chosen(value: Any?): Boolean {
        val current = query[field] ?: if (field == "len") query["length"] else null
        if (multi) return value in (current as? List<*>).orEmpty()
        if (value == null && field == "show" && query["wtr"] == true) return false
        if (value == null) return current == null || current == "all" || current == "anywhere" || (current is Map<*, *> && current.isEmpty())
        return LuaValue.encode(value).contentEquals(LuaValue.encode(current)) || (field == "show" && value == "want-to-read" && query["wtr"] == true)
    }
    fun include(book: Map<String, Any?>) {
        val values = if (multi) (book[if (field == "author") "authors" else field] as? List<*>).orEmpty().filterIsInstance<String>().distinct() else emptyList()
        for (v in values) { options[v] = v; labels[v] = v }
        if (!LibraryFilter.matches(book, others)) return
        if (multi) for (v in values) counts[v] = (counts[v] ?: 0) + 1
        else for ((id, value) in options) if (LibraryFilter.matches(book, if (value == null) emptyMap<String, Any?>() else mapOf(field to value))) counts[id] = (counts[id] ?: 0) + 1
    }
    fun page(offset: Int, limit: Int): Map<String, Any?> {
        val rows = options.map { (id, value) -> mapOf("id" to id, "label" to labels[id], "value" to value, "count" to (counts[id] ?: 0), "selected" to chosen(value)) }
            .sortedWith(compareBy<Map<String, Any?>> { (it["count"] as Int) == 0 }.thenBy { if (multi) LuaValue.utf8(it["label"].toString()).lowercase(Locale.ROOT) else "" }.thenBy { if (multi) it["id"].toString() else "" })
        val page = rows.drop(offset).take(limit)
        return mapOf("items" to page, "option_total" to rows.size, "offset" to offset, "next" to (offset + page.size).takeIf { it < rows.size }, "multi" to multi)
    }
}
