package net.fledgewing.orbitcompanion

/** Worker-owned projections in the existing cache DB. Plugin reads one small blob per operation.
 * Additive table: no schema reset, no second catalog, sync writer, credentials or network client. */
class LibraryReadModel(
    private val store: CacheStore,
    private val clock: () -> Long = { System.currentTimeMillis() / 1000 },
    private val log: (String) -> Unit = { OLog.i(it) },
    private val accountState: () -> Map<String, Any?> = { mapOf("signedIn" to false) },
    private val accountStats: (String) -> Map<*, *>? = { null },
    private val readingStats: () -> Map<String, Any?> = {
        mapOf("state" to "not-saved", "freshness" to mapOf("saved" to false))
    },
) {
    companion object {
        const val MAX_BYTES = 16384
        const val MAX_ROWS = 24
        const val MAX_BATCH = 16
        fun initialize(db: Sql) = db.exec("CREATE TABLE IF NOT EXISTS library_views (owner TEXT, request TEXT, body BLOB, at INTEGER, PRIMARY KEY(owner,request)) WITHOUT ROWID")
    }
    /** Each request is its exact Lua literal: no hash collision or backend URL in the UI key. */
    fun publish(owner: String, requests: List<*>): Boolean {
        var changed = false
        require(requests.size <= MAX_BATCH)
        // Never take ownership from a read command, nor expose a prior account's data.
        if (store.meta("owner") != owner) return false
        // Different widget byte budgets can encode distinct requests for the same paint.
        val stats by lazy { AccountStats.combine(readingStats(), BookOrbitLibrary.readingStats(store), accountStats(owner), clock()) }
        for (encoded in requests) {
            val start = System.nanoTime()
            val request = encoded as? String ?: continue
            if (request.length > 8192) continue
            val args = LuaValue.parse(request.toByteArray(Charsets.ISO_8859_1)) as? Map<*, *> ?: continue
            store.transaction {
                if (store.meta("owner") != owner) return@transaction
                val result = try { if (args["op"] == "reading.stats") stats else project(owner, args) } catch (_: IllegalArgumentException) { mapOf("error" to "unsupported", "items" to emptyList<Any>()) }
                var body = LuaValue.encode(result)
                val budget = ((args["bytes"] as? Number)?.toInt() ?: MAX_BYTES).coerceIn(256, MAX_BYTES)
                if (body.size > budget) body = LuaValue.encode(mapOf("error" to "budget", "items" to emptyList<Any>(), "freshness" to freshness(false)))
                val previous = store.db().query("SELECT body FROM library_views WHERE owner=? AND request=?", CacheStore.u(owner), CacheStore.u(request)) { it.bytes(0) }.firstOrNull()
                if (previous == null || !previous.contentEquals(body)) changed = true
                store.db().exec("INSERT OR REPLACE INTO library_views VALUES (?,?,?,?)", CacheStore.u(owner), CacheStore.u(request), body, clock())
                // Bounded projection cache; catalog and reading intents are untouched.
                store.db().exec("DELETE FROM library_views WHERE (owner,request) IN (SELECT owner,request FROM library_views ORDER BY at DESC,request LIMIT -1 OFFSET 64)")
                log("library ${args["op"]} ms=${(System.nanoTime()-start)/1_000_000} bytes=${body.size}")
            }
        }
        return changed
    }
    private fun freshness(saved: Boolean): Map<String, Any?> = mapOf("saved" to saved,
        "generation" to store.meta("bulk_active"), "origin" to "cached-remote", "at" to if (saved) store.meta("bulk_at")?.toLongOrNull() else null)
    private fun empty(saved: Boolean) = mapOf("items" to emptyList<Any>(), "total" to 0, "freshness" to freshness(saved), "empty" to if (saved) "No books" else "Not saved yet")
    private fun project(owner: String, a: Map<*, *>): Map<String, Any?> {
        val op = a["op"]
        // Local-only placeholder until the battery slice supplies its measured projection.
        if (op == "battery") return mapOf("available" to false, "freshness" to freshness(false))
        if (op == "reader") {
            val path = a["path"] as? String ?: return empty(false)
            val entry = BookOrbitLibrary.localEntries(store, owner)?.firstOrNull { it["path"] == path }
                ?: return empty(false)
            val id = (entry["book_id"] as? Number)?.toLong() ?: return empty(false)
            val result = project(owner, a + mapOf("op" to "book", "key" to BookOrbitLibrary.key(owner, "book", id)))
            val current = (a["native_progress"] as? Number)?.toDouble()?.takeIf { it.isFinite() && it in 0.0..1.0 }
            val book = (result["items"] as? List<*>)?.singleOrNull() as? Map<*, *>
            return if (current != null && book != null) result + mapOf("items" to listOf(book +
                mapOf("progress" to current * 100, "progress_origin" to "local-reader"))) else result
        }
        if (op == "account.state") return accountState()
        if (op == "capabilities") {
            val remote = BookOrbitLibrary.readingStats(store)
            val a = accountStats(owner).orEmpty()
            return mapOf("catalog" to true, "detail" to true, "download" to ((accountState()["opds"] as? Map<*, *>)?.get("set") == true),
                "lists" to mapOf("read" to true, "save" to false), "progress" to mapOf("read" to true, "write" to false, "syncCurrent" to true),
                "status" to mapOf("read" to true, "write" to false), "ratings" to mapOf("read" to true, "write" to false),
                "account" to accountState(),
                "stats" to mapOf("days" to (a["days"] != null || remote?.days != null), "streak" to (remote?.streak != null),
                    "hours" to (a["hours"] != null), "sessions" to (a["sessions"] != null),
                    "goal" to (a["goal"] != null || remote?.goalAvailable == true),
                    "finished" to (a["finished"] != null || remote?.finished != null),
                    "yearReview" to false, "activityDetails" to false, "celebrations" to false),
                "readingStats" to true, "wantToRead" to true, "customFields" to false, "onDevice" to true,
                "jobs" to mapOf("refresh" to BookOrbitLibrary.key(owner, "job", "refresh")),
                "limits" to mapOf("rows" to MAX_ROWS, "bytes" to MAX_BYTES, "batch" to MAX_BATCH))
        }
        if (op == "lists") {
            val g = store.meta("bulk_active")?.toLongOrNull() ?: return empty(false)
            if (store.meta("bulk_complete")?.toLongOrNull() != g) return empty(false)
            val limit = ((a["limit"] as? Number)?.toInt() ?: 8).coerceIn(1, MAX_ROWS)
            val offset = ((a["offset"] as? Number)?.toInt() ?: 0).coerceAtLeast(0)
            val rows = store.db().query("SELECT id,name,n FROM bulk_sections WHERE g=? AND section='smart-scopes' ORDER BY pos LIMIT ? OFFSET ?", g, limit, offset) {
                mapOf("key" to BookOrbitLibrary.key(owner, "list", it.text(0) ?: ""), "title" to it.text(1), "count" to it.long(2))
            }
            return mapOf("items" to rows, "freshness" to freshness(true))
        }
        if (op == "job") {
            require(a["key"] == BookOrbitLibrary.key(owner, "job", "refresh"))
            val states = store.db().query("SELECT state,count(*) FROM jobs GROUP BY state") { (it.long(0) ?: 0) to (it.long(1) ?: 0) }.toMap()
            return mapOf("key" to a["key"], "pending" to (states[0L] ?: 0), "done" to (states[1L] ?: 0), "failed" to (states[2L] ?: 0), "freshness" to freshness(true))
        }
        if (op in setOf("book", "progress", "status")) {
            val id = BookOrbitLibrary.id(owner, "book", a["key"]) ?: return mapOf("error" to "missing")
            val raw = store.bookItem(id) as? Map<*, *> ?: return mapOf("error" to "missing", "freshness" to freshness(false))
            val summary = BookOrbitLibrary.summary(owner, raw, 0, null).toMutableMap()
            if (op == "book") {
                val entry = BookOrbitLibrary.localEntries(store, owner)?.firstOrNull { (it["book_id"] as? Number)?.toLong() == id }
                summary["stats"] = ReaderBookStats.read(store.root, entry)
            }
            val detail = store.detail(id)
            if (op == "book" && detail?.first is Map<*, *>) {
                val d = detail.first as Map<*, *>
                summary["description"] = (d["description"] as? String)?.let(LuaValue::utf8)?.replace(Regex("<[^>]*>"), "")?.take(2048)?.let(LuaValue::str)
                summary["files"] = (d["files"] as? List<*>)?.mapNotNull { it as? Map<*, *> }?.map { f ->
                    mapOf("key" to (f["id"] as? Number)?.let { BookOrbitLibrary.key(owner, "file", it.toLong()) }, "format" to (f["format"] as? String), "bytes" to (f["size"] as? Number), "revision" to (f["contentVersion"] as? String))
                }
                summary["available"] = (summary["available"] as? Map<*, *>).orEmpty() + mapOf("detail" to true, "cover" to false)
            }
            return when (op) {
                "progress" -> mapOf("key" to a["key"], "progress" to summary["progress"], "last_read" to summary["last_read"], "freshness" to freshness(true))
                "status" -> mapOf("key" to a["key"], "status" to summary["status"], "status_raw" to summary["status_raw"], "freshness" to freshness(true))
                else -> mapOf("items" to listOf(summary), "freshness" to freshness(true), "detail_at" to detail?.second)
            }
        }
        require(op == "window" || op == "counts" || op == "facets")
        val f = a["query"] as? Map<*, *> ?: emptyMap<Any, Any>()
        BookOrbitLibrary.translate(f) // validates; same plan is available to future remote checks
        val source = a["source"]
        val kind = if (source is String) source else (source as? Map<*, *>)?.get("kind") as? String
        val sourceKey = (source as? Map<*, *>)?.get("key")
        require(kind in setOf("library/all", "all", "reading", "want-to-read", "recently-added", "finished", "on-device", "list", "series", "author", "search"))
        val g = store.meta("bulk_active")?.toLongOrNull() ?: return empty(false)
        // Secondary contexts are not complete at base publication; never turn an unknown source into an empty list.
        if (kind in setOf("series", "list") && store.meta("bulk_complete")?.toLongOrNull() != g) return empty(false)
        val localPaths = BookOrbitLibrary.localPaths(store, owner)
        val local = localPaths?.keys
        if ((a["field"] == "where" || kind == "on-device" || f["where"] in setOf("on-device", "server-only")) && local == null) return empty(false)
        val membership = when (kind) {
            "list", "series" -> {
                val id = BookOrbitLibrary.id(owner, kind, sourceKey) ?: return mapOf("error" to "missing")
                val section = if (kind == "list") "smart-scopes" else "series"
                val exists = store.db().query("SELECT 1 FROM bulk_sections WHERE g=? AND section=? AND id=? LIMIT 1", g, section, if (kind == "series") "series:$id" else id.toString()) { true }.isNotEmpty()
                if (!exists) return mapOf("error" to "missing")
                store.db().query("SELECT id,context FROM bulk_members WHERE g=? AND kind=? AND value=?", g, if (kind == "list") "smartScopeId" else "seriesId", id.toString()) {
                    it.long(0)!! to (it.bytes(1)?.let(LuaValue::parse) as? Map<*, *>).orEmpty()
                }.toMap()
            }
            else -> null
        }
        val filter = f.entries.associate { it.key.toString() to it.value }.toMutableMap()
        val sourceFilter = mutableMapOf<String, Any?>()
        when (kind) {
            "reading" -> { sourceFilter["show"] = "reading"; if (filter["sort"] == null) { filter["sort"] = "last"; filter["dir"] = "desc" } }
            "want-to-read" -> sourceFilter["wtr"] = true
            "finished" -> sourceFilter["show"] = "finished"
            "recently-added" -> if (filter["sort"] == null) { filter["sort"] = "added"; filter["dir"] = "desc" }
            "author" -> { require(sourceKey is String); sourceFilter["author"] = listOf(sourceKey) }
            "on-device" -> sourceFilter["where"] = "on-device"
            "series" -> if (filter["sort"] == null) filter["sort"] = "series"
            "search" -> if (filter["sort"] == null) filter["sort"] = "match"
        }
        val facet = if (op == "facets" && a["field"] != null) LibraryFacets(a["field"].toString(), filter, clock()) else null
        val selected = ArrayList<Map<String, Any?>>()
        // Bounded DB chunks; parsing, filter fallback, joins, sort and counts stay off KOReader.
        var after = -1L
        while (true) {
            val batch = store.db().query("SELECT id,item FROM bulk_books WHERE g=? AND id>? ORDER BY id LIMIT 256", g, after) { it.long(0)!! to it.bytes(1)!! }
            if (batch.isEmpty()) break
            for ((id, bytes) in batch) {
                val raw = LuaValue.parse(bytes) as? Map<*, *> ?: continue
                val context = membership?.get(id).orEmpty()
                val enriched = raw.entries.associate { it.key to it.value } + context
                val b = BookOrbitLibrary.summary(owner, enriched, (context["_booksyncRank"] as? Number)?.toLong() ?: id, local?.contains(id)).toMutableMap()
                b["local_path"] = localPaths?.get(id)
                val q = f["q"]?.toString()?.let(LuaValue::utf8)?.lowercase(java.util.Locale.ROOT).orEmpty()
                val title = b["title"]?.toString()?.let(LuaValue::utf8)?.lowercase(java.util.Locale.ROOT).orEmpty()
                b["match"] = when { title == q -> 0; title.startsWith(q) -> 1; q in title -> 2; else -> 3 }
                if ((membership == null || id in membership) && LibraryFilter.matches(b, sourceFilter)) {
                    facet?.include(b)
                    if (LibraryFilter.matches(b, filter)) selected.add(b)
                }
            }
            after = batch.last().first
        }
        val total = selected.size
        if (op == "facets") {
            val offset = ((a["offset"] as? Number)?.toInt() ?: 0).coerceAtLeast(0)
            val limit = ((a["limit"] as? Number)?.toInt() ?: MAX_ROWS).coerceIn(1, MAX_ROWS)
            return (facet?.page(offset, limit) ?: mapOf("items" to emptyList<Any>())) + mapOf("total" to total, "freshness" to freshness(true))
        }
        val counts = selected.groupingBy { it["status"].toString() }.eachCount()
        if (op == "counts") return mapOf("total" to total, "statuses" to counts, "freshness" to freshness(true))
        selected.sortWith(LibraryFilter.comparator(filter))
        val offset = ((a["offset"] as? Number)?.toInt() ?: 0).coerceAtLeast(0)
        val limit = ((a["limit"] as? Number)?.toInt() ?: MAX_ROWS).coerceIn(1, MAX_ROWS)
        val window = selected.drop(offset).take(limit).map { it + ("group" to LibraryFilter.group(it, filter)) }
        return mapOf("items" to window, "total" to total, "offset" to offset, "next" to (offset + window.size).takeIf { it < total },
            "freshness" to freshness(true), "local_coverage" to if (local == null) "not-saved" else "tracked-files", "empty" to if (total == 0) "No books" else null)
    }
}
