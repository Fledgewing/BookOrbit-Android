// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

/** Native reader scalars arrive bounded; all marker normalization and labels run on the worker. */
object ReaderControls {
    fun project(native: Map<*, *>): Map<String, Any?> {
        fun number(value: Any?) = (value as? Number)?.toDouble()?.takeIf { it.isFinite() }
        val total = number(native["total"])?.toInt()?.takeIf { it > 0 }
        val page = number(native["page"])?.toInt()?.takeIf { total != null && it in 1..total }
        fun markers(key: String): List<Double> = if (total == null) emptyList() else
            (native[key] as? List<*>)?.take(64)?.mapNotNull { number(it)?.takeIf { n -> n in 1.0..total.toDouble() } }
                ?.distinct()?.sorted()?.map { it / total } ?: emptyList()
        val chapters = markers("chapters")
        val fraction = if (page != null && total != null) page.toDouble()/total else null
        val chapterTotal = number(native["chapter_total"])?.toInt()?.takeIf { it > 0 } ?: chapters.size
        val chapter = number(native["chapter_index"])?.toInt()?.takeIf { it in 1..chapterTotal }
            ?: fraction?.let { f -> if (chapterTotal <= 64) chapters.count { it <= f }.coerceAtLeast(1) else null }
        val title = (native["chapter_title"] as? String)?.take(256)?.takeIf { it.isNotBlank() }
        return mapOf("items" to listOf(mapOf("progress" to fraction,
            "position" to if (page != null) LuaValue.str("p. $page of $total · ${(fraction!!*100+.5).toInt()}%") else "Position not available yet",
            "chapter" to if (chapter != null && chapters.isNotEmpty()) "Chapter $chapter of $chapterTotal" else "Chapters not available yet",
            "chapter_title" to title?.let { LuaValue.str("$chapter · ${LuaValue.utf8(it)}") },
            "markers_reduced" to (chapterTotal > 64), "chapters" to chapters, "bookmarks" to markers("bookmarks"), "marked" to (native["marked"] == true))))
    }
}
