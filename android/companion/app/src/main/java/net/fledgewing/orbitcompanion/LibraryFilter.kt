package net.fledgewing.orbitcompanion

import java.util.Locale

/** Neutral filter semantics; executed only on the companion worker. Never paginates before filtering. */
object LibraryFilter {
    val fields = setOf("show", "wtr", "where", "author", "series", "tags", "length", "len", "rating", "added", "group", "sort", "dir", "q", "without_series")
    fun validate(f: Map<*, *>) {
        require(f.keys.all { it in fields }) { "unsupported filter" }
        fun choice(k: String, values: Set<String>) { require(f[k] == null || f[k] in values) { "invalid $k" } }
        choice("show", setOf("all", "want-to-read", "unread", "reading", "finished", "rereading", "on-hold", "abandoned", "unknown"))
        choice("where", setOf("anywhere", "on-device", "server-only"))
        choice("group", setOf("none", "author", "series"))
        choice("sort", setOf("order", "match", "title", "author", "last", "added", "rating", "series"))
        choice("dir", setOf("asc", "desc"))
        require(f["without_series"] == null || f["without_series"] is Boolean)
        require(f["wtr"] == null || f["wtr"] is Boolean)
        require(f["q"] == null || f["q"] is String && (f["q"] as String).length <= 512)
        for (k in listOf("author", "series", "tags")) require(f[k] == null || f[k] is List<*> && (f[k] as List<*>).size <= 100 && (f[k] as List<*>).all { it is String })
        for (k in listOf("length", "len", "rating", "added")) {
            val range = f[k] ?: continue
            require(range is Map<*, *> && range.keys.all { it == "min" || it == "max" }) { "invalid $k range" }
            require(range.values.all { if (k == "added") it is String else it is Number })
            val lo = range["min"]; val hi = range["max"]
            require(lo == null || hi == null || compare(lo, hi) <= 0) { "reversed $k range" }
        }
    }
    private fun fold(v: Any?) = v?.toString()?.let(LuaValue::utf8)?.lowercase(Locale.ROOT).orEmpty()
    private fun compare(a: Any, b: Any): Int = if (a is Number && b is Number) a.toDouble().compareTo(b.toDouble()) else fold(a).compareTo(fold(b))
    private fun range(v: Any?, r: Any?): Boolean {
        val m = r as? Map<*, *> ?: return true
        if (v == null) return false
        return (m["min"] == null || compare(v, m["min"]!!) >= 0) && (m["max"] == null || compare(v, m["max"]!!) <= 0)
    }
    fun matches(b: Map<String, Any?>, f: Map<*, *>): Boolean {
        if (f["without_series"] == true && !(b["series"] as? List<*>).isNullOrEmpty()) return false
        val show = f["show"] ?: "all"
        if (show == "want-to-read" && b["want_to_read"] != true) return false
        if (show != "all" && show != "want-to-read" && b["status"] != show && !(show == "reading" && b["status"] == "rereading")) return false
        if (f["wtr"] == true && b["want_to_read"] != true) return false
        if (f["where"] == "on-device" && b["on_device"] != true) return false
        if (f["where"] == "server-only" && b["on_device"] != false) return false // unknown is not server-only
        for ((k, field) in listOf("author" to "authors", "series" to "series", "tags" to "tags")) {
            val wanted = (f[k] as? List<*>)?.map(::fold).orEmpty()
            if (wanted.isNotEmpty() && (b[field] as? List<*>).orEmpty().none { fold(it) in wanted }) return false
        }
        if (!range(b["pages"], f["length"] ?: f["len"]) || !range(b["rating"], f["rating"]) || !range(b["added"], f["added"])) return false
        val text = fold(listOf(b["title"], (b["authors"] as? List<*>)?.joinToString(" "), (b["series"] as? List<*>)?.joinToString(" ")).joinToString(" "))
        return fold(f["q"]).split(Regex("\\s+")).filter { it.isNotEmpty() }.all { it in text }
    }
    fun group(b: Map<String, Any?>, f: Map<*, *>): String = when (f["group"]) {
        "author" -> (b["authors"] as? List<*>)?.firstOrNull()?.toString() ?: "Unknown author"
        "series" -> (b["series"] as? List<*>)?.firstOrNull()?.toString() ?: "No series"
        else -> ""
    }
    fun comparator(f: Map<*, *>): Comparator<Map<String, Any?>> = Comparator { a, b ->
        val grouped = fold(group(a, f)).compareTo(fold(group(b, f)))
        if (grouped != 0) grouped else {
            val field = when (f["sort"]) { "title" -> "title"; "author" -> "authors"; "last" -> "last_read"; "added" -> "added"; "rating" -> "rating"; "series" -> "series_position"; "match" -> "match"; else -> "rank" }
            fun value(row: Map<String, Any?>): Any? = row[field].let { if (it is List<*>) it.firstOrNull() else if (field == "series_position") it?.toString()?.toDoubleOrNull() else it }
            val x = value(a); val y = value(b)
            val c = when { x == null && y == null -> 0; x == null -> 1; y == null -> -1; else -> compare(x, y) * if (f["dir"] == "desc") -1 else 1 }
            if (c != 0) c else a["key"].toString().compareTo(b["key"].toString())
        }
    }
}
