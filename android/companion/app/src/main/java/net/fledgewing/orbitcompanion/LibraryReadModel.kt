package net.fledgewing.orbitcompanion

/** Worker-owned projections in the existing cache DB. Plugin reads one small blob per operation.
 * Additive table: no schema reset, no second catalog, sync writer, credentials or network client. */
class LibraryReadModel(
    private val store: ProjectionStore,
    private val clock: () -> Long = { System.currentTimeMillis() / 1000 },
    private val log: (String) -> Unit = { OLog.i(it) },
    private val readingStats: () -> Map<String, Any?> = {
        mapOf("state" to "not-saved", "freshness" to mapOf("saved" to false))
    },
    private val adapter: ServerAdapter = ServerAdapters.forStore(store, clock = clock),
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
        val stats by lazy { ReadingStats.combine(readingStats(), adapter.cachedReadingStats(owner), clock()) }
        for (encoded in requests) {
            val start = System.nanoTime()
            val request = encoded as? String ?: continue
            if (request.length > 8192) continue
            val args = LuaValue.parse(request.toByteArray(Charsets.ISO_8859_1)) as? Map<*, *> ?: continue
            store.transaction {
                if (store.meta("owner") != owner) return@transaction
                val result = try { when (args["op"]) {
                    "reading.stats" -> stats
                    "battery" -> mapOf("available" to false, "freshness" to mapOf("saved" to false))
                    else -> adapter.project(owner, args)
                } } catch (_: IllegalArgumentException) { mapOf("error" to "unsupported", "items" to emptyList<Any>()) }
                var body = LuaValue.encode(result)
                val budget = ((args["bytes"] as? Number)?.toInt() ?: MAX_BYTES).coerceIn(256, MAX_BYTES)
                val rows = (result["items"] as? List<*>)?.size ?: 0
                val rowBudget = ((args["limit"] as? Number)?.toInt() ?: MAX_ROWS).coerceIn(1, MAX_ROWS)
                if (body.size > budget || rows > rowBudget) body = LuaValue.encode(mapOf(
                    "error" to "budget", "items" to emptyList<Any>(), "freshness" to mapOf("saved" to false)))
                val previous = store.db().query("SELECT body FROM library_views WHERE owner=? AND request=?", LuaValue.utf8(owner), LuaValue.utf8(request)) { it.bytes(0) }.firstOrNull()
                if (previous == null || !previous.contentEquals(body)) changed = true
                store.db().exec("INSERT OR REPLACE INTO library_views VALUES (?,?,?,?)", LuaValue.utf8(owner), LuaValue.utf8(request), body, clock())
                // Bounded projection cache; catalog and reading intents are untouched.
                store.db().exec("DELETE FROM library_views WHERE (owner,request) IN (SELECT owner,request FROM library_views ORDER BY at DESC,request LIMIT -1 OFFSET 64)")
                log("library ${args["op"]} ms=${(System.nanoTime()-start)/1_000_000} rows=$rows bytes=${body.size}")
            }
        }
        return changed
    }
}
