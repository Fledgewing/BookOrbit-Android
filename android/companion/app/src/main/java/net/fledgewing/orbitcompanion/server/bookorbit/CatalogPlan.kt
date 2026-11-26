package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

/** Finite, non-search browse space from shared/fixtures/catalog/sections.json (P passes it in
 * the plan). Expansion runs on the companion writer, after the fresh section indexes land.
 * Screen size, page, offset, grid/list and letter jumps are windows of the same identity. */
class CatalogPlan(private val plan: CacheWorker.Plan) {
    private val catalog = plan.m["catalog"] as? Map<*, *> ?: emptyMap<String, Any?>()
    private fun values(key: String) = (catalog[key] as? List<*>)?.filterIsInstance<String>().orEmpty()

    private val limits = catalog["local_limits"] as? Map<*, *> ?: emptyMap<String, Any?>()
    val recentScanSize get() = (limits["not_on_device_scan_pages"] as? Number)?.toInt()?.times((limits["not_on_device_scan_size"] as? Number)?.toInt() ?: 100) ?: 500
    val absentLimit get() = (limits["not_on_device_max_ids"] as? Number)?.toInt() ?: 200

    fun sectionPaths(): Sequence<String> = sequence {
        for (section in listOf("authors", "series")) {
            for (sort in values("section_sorts")) for (filter in listOf("") + values("section_filters")) {
                val q = linkedMapOf<String, String>()
                if (sort != "name") q["sort"] = sort
                if (filter.isNotEmpty()) q["filter"] = filter
                yield(path("/koreader/plugin/catalog/sections/$section", q))
            }
        }
    }

    /** Every sort/direction/status/format/library/device combination offered by the book sheet.
     * Authors open in series order too; their page has no sheet, but legacy controls do. */
    fun bookPaths(base: String, libraries: List<String>, deviceIds: String?): Sequence<String> = sequence {
        if (catalog.isEmpty()) return@sequence
        val (endpoint, query) = MirrorLogic.splitPath(base)
        val scope = MirrorLogic.parseQuery(query).also {
            listOf("page", "size", "offset", "sort", "order", "buckets", "readStatus", "format").forEach(it::remove)
        }
        val series = "seriesId" in scope || "series" in scope
        val sorts = if (series) values("series_sorts") else (values("book_sorts") + values("list_sorts")).distinct()
        val libraryOptions = if (series) listOf(scope["libraryId"].orEmpty()) else (listOf(scope["libraryId"].orEmpty()) + libraries).distinct()
        val formats = if (series) listOf("") else listOf("") + values("formats")
        val devices = (listOf(scope["ids"].orEmpty()) + listOfNotNull(deviceIds)).distinct()
        for (sort in sorts) for (order in values("orders")) for (status in listOf("") + values("read_statuses")) {
            for (library in libraryOptions) for (format in formats) for (ids in if (series) listOf(scope["ids"].orEmpty()) else devices) {
                val q = LinkedHashMap(scope)
                q["sort"] = sort; q["order"] = order
                if (status.isNotEmpty()) q["readStatus"] = status
                if (library.isNotEmpty()) q["libraryId"] = library
                if (format.isNotEmpty()) q["format"] = format
                if (ids.isNotEmpty()) q["ids"] = ids
                // Both supported and legacy request shapes are browsable; cache keys include buckets.
                yield(path(endpoint, q))
                if (sort == "title" || sort == "author") { q["buckets"] = "1"; yield(path(endpoint, q)) }
            }
        }
    }

    private fun path(endpoint: String, q: Map<String, String>): String =
        endpoint + MirrorLogic.encQuery(q).let { if (it.isEmpty()) "" else "?$it" }

    /** Stable labels for the end-of-run audit, independent of ids and query ordering. */
    companion object {
        /** Library picks are already the global base's library dimension. Keep the first base
         * (All books), avoiding repeated expansion through Home aliases and per-library rows. */
        fun scope(path: String): String {
            val (endpoint, encoded) = MirrorLogic.splitPath(path)
            val q = MirrorLogic.parseQuery(encoded)
            listOf("page", "size", "offset", "sort", "order", "buckets", "readStatus", "format", "libraryId").forEach(q::remove)
            return endpoint + "?" + MirrorLogic.encQuery(q)
        }

        fun dynamic(identity: String): Boolean {
            val q = MirrorLogic.parseQuery(MirrorLogic.splitPath(identity).second)
            return "readStatus" in q || "filter" in q || q["sort"] in setOf("recently_added", "recently_read")
        }

        fun kind(identity: String): String {
            val w = MirrorLogic.listWindow(identity) ?: return "other"
            w.section?.let { return "index:$it" }
            val q = MirrorLogic.parseQuery(MirrorLogic.splitPath(identity).second)
            return when {
                "seriesId" in q || "series" in q -> "series"
                "author" in q -> "author"
                "collectionId" in q -> "collection"
                "smartScopeId" in q -> "smart-scope"
                "libraryId" in q -> "library"
                "ids" in q -> "device"
                q["readStatus"] == "finished" -> "finished"
                q["readStatus"] == "reading" -> "reading"
                q["sort"] == "recently_added" -> "recently-added"
                else -> "books"
            }
        }
    }
}
