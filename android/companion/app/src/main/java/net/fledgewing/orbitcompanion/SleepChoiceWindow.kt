package net.fledgewing.orbitcompanion

/** Reuse the sleep owner's normalized choices; only this small page reaches Lua. Worker only. */
object SleepChoiceWindow {
    fun project(saved: SleepChoices?, args: Map<*, *>): Map<String, Any?> {
        val category = args["category"] as? String ?: "lists"
        require(category in setOf("lists", "collections", "libraries", "tags"))
        val limit = ((args["limit"] as? Number)?.toInt() ?: 6).coerceIn(1,6)
        val offset = ((args["offset"] as? Number)?.toInt() ?: 0).coerceAtLeast(0)
        val rows: List<Map<String, Any?>> = if (category == "tags") saved?.tags.orEmpty().map {
            mapOf("id" to "tag:${it.tag}", "title" to it.label, "count" to it.count)
        } else {
            val (prefix, items) = when(category) {
                "lists" -> "scope" to saved?.scopes.orEmpty()
                "collections" -> "collection" to saved?.collections.orEmpty()
                else -> "library" to saved?.libraries.orEmpty()
            }
            items.map { mapOf("id" to "$prefix:${it.id}", "title" to it.title, "count" to it.count) }
        }
        val page = rows.drop(offset).take(limit).map { it + mapOf("title" to LuaValue.boundedText(LuaValue.utf8(it["title"].toString()),80)) }
        return mapOf("items" to page, "total" to rows.size,
            "next" to (offset+page.size).takeIf { it < rows.size }, "freshness" to mapOf("saved" to (saved != null)))
    }
}
