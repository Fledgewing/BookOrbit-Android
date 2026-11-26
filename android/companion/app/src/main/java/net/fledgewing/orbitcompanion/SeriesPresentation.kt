package net.fledgewing.orbitcompanion

/** Companion-only presentation of normalized books. No protocol, catalog IO or UI-side joins. */
object SeriesPresentation {
    private val order = LibraryFilter.comparator(mapOf("sort" to "series", "dir" to "asc"))
    fun state(book: Map<String, Any?>): String = when {
        book["status"] == "finished" -> "read"
        book["status"] in setOf("reading", "rereading") -> "reading"
        else -> "unread"
    }
    fun row(book: Map<String, Any?>): Map<String, Any?> {
        val progress = (book["progress"] as? Number)?.toDouble()?.takeIf { it.isFinite() && it in 0.0..100.0 }
        val rating = (book["rating"] as? Number)?.toInt()?.coerceIn(0, 5) ?: 0
        val status = when (state(book)) {
            "read" -> "Read" + if (rating > 0) " · " + "★".repeat(rating) else ""
            "reading" -> (progress?.let { "${kotlin.math.round(it).toInt()}% · " } ?: "") + "reading"
            else -> when (book["on_device"]) { true -> "On device"; false -> "On server"; else -> "Device state not saved" }
        }
        return mapOf("key" to book["key"], "title" to book["title"], "authors" to book["authors"],
            "series_key" to book["series_key"], "number" to book["series_position"], "local_path" to book["local_path"],
            "status_text" to LuaValue.str(status), "dot" to state(book), "progress" to progress)
    }
    fun series(books: List<Map<String, Any?>>, title: String?, offset: Int, limit: Int): Map<String, Any?> {
        val sorted = books.sortedWith(order)
        val dotOffset = if (sorted.size <= 24) 0 else offset / 24 * 24
        val current = sorted.indexOfFirst { state(it) == "reading" }
        val remaining = sorted.drop(current + 1).filter { state(it) != "read" }
        val next = remaining.filter { it["on_device"] == false }.take(3).map(::row)
        // Summary and next previews consume rows too; every wire row is charged to the caller.
        val window = sorted.drop(offset).take((limit - 4).coerceAtLeast(0)).map(::row)
        val author = sorted.flatMap { (it["authors"] as? List<*>)?.filterIsInstance<String>().orEmpty() }.map(LuaValue::utf8).distinct().joinToString(" · ")
        return mapOf("items" to window, "row_count" to (1 + next.size + window.size), "title" to title,
            "subtitle" to LuaValue.str("${author}${if (author.isEmpty()) "" else " · "}${books.size} ${if (books.size == 1) "book" else "books"} · ${books.count { state(it) == "read" }} read, ${books.count { state(it) == "reading" }} reading"),
            "dots" to sorted.drop(dotOffset).take(24).map(::state), "dot_offset" to dotOffset, "dot_caption" to if (sorted.size > 24) LuaValue.str("Books ${dotOffset + 1}–${minOf(sorted.size, dotOffset + 24)} of ${sorted.size}") else null,
            "total" to books.size, "offset" to offset, "next" to (offset + window.size).takeIf { window.isNotEmpty() && it < sorted.size },
            "next_books" to next, "remaining_saved" to (remaining.isNotEmpty() && remaining.all { it["on_device"] == true }),
            "local_known" to books.all { it["on_device"] != null })
    }
    fun groups(books: List<Map<String, Any?>>, filter: Map<*, *>, offset: Int, limit: Int, preview: Int = 3, groupLimit: Int = limit / 4): Map<String, Any?> {
        val series = filter["group"] == "series"
        // Opaque identity distinguishes same-named series. Unassigned books have no invented key.
        val grouped = books.groupBy { if (series) it["series_key"] ?: "" else LibraryFilter.group(it, filter) }
            .values.sortedWith(compareBy<List<Map<String, Any?>>> { series && it.first()["series_key"] == null }
                .thenBy { LibraryFilter.group(it.first(), filter).let(LuaValue::utf8).lowercase(java.util.Locale.ROOT) }
                .thenBy { it.first()["series_key"].toString() })
        var used = 0
        val rows = mutableListOf<Map<String, Any?>>()
        for (group in grouped.drop(offset)) {
            val ordered = group.sortedWith(if (series) order else LibraryFilter.comparator(filter + mapOf("group" to "none")))
            val count = minOf(preview.coerceIn(1, 9), ordered.size, limit-1)
            if (used + 1 + count > limit || rows.size >= groupLimit) break
            val first = ordered.first()
            val key = if (series) first["series_key"] else null
            val name = if (series && key == null) "Not in a series" else LibraryFilter.group(first, filter)
            rows += mapOf("title" to name, "series_key" to key, "field" to if (series) "series" else "author",
                "value" to if (series && key == null) "" else name, "count" to ordered.size,
                "count_text" to if (ordered.size > count) "All ${ordered.size}" else "${ordered.size} ${if (ordered.size == 1) "book" else "books"}",
                "partial" to (ordered.size > count), "dots" to if (series) ordered.take(24).map(::state) else emptyList<String>(),
                "books" to ordered.take(count).map(::row))
            used += 1 + count
        }
        return mapOf("items" to rows, "row_count" to used, "total" to books.size, "group_total" to grouped.size,
            "offset" to offset, "next" to (offset + rows.size).takeIf { rows.isNotEmpty() && it < grouped.size })
    }
}
