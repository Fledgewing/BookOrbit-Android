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
    private val battery: () -> Map<String, Any?> = { BatteryEstimate.snapshot(emptyMap(), emptyList(), null, emptyList(), clock()*1000, java.time.ZoneOffset.UTC) },
    private val fallbackReadingStats: ((String) -> RemoteReadingStats?)? = null,
    private val accountState: () -> Map<String, Any?> = { mapOf("signedIn" to false) },
    private val accountStats: (String) -> Map<*, *>? = { null },
    private val vocabulary: () -> java.io.File = { java.io.File(SleepScreen.dir().parentFile, "vocabulary_builder.sqlite3") },
    private val adapter: ServerAdapter? = null,
    private val personalDevice: (() -> PersonalReadingSource)? = null,
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
        if (owner != DeviceLibrary.OWNER && store.meta("owner") != owner) return false
        val local = owner == DeviceLibrary.OWNER
        val projection = if (local) DeviceLibrary(DeviceStorage.folders.map {
            java.io.File(store.root.parentFile?.parentFile?.parentFile ?: store.root,it)
        } + DeviceStorage.downloadRoot(store.root)) else adapter ?: ServerAdapters.forStore(store, clock = clock,
            fallbackReadingStats = fallbackReadingStats, accountState = accountState, accountStats = accountStats)
        val personal by lazy {
            val roots = DeviceStorage.folders.map { java.io.File(store.root.parentFile?.parentFile?.parentFile ?: store.root,it) } + DeviceStorage.downloadRoot(store.root)
            PersonalReading(listOf(personalDevice?.invoke() ?: DevicePersonalReading(roots, java.io.File(store.root.parentFile,"statistics.sqlite3"))) +
                if (local) emptyList() else projection.personalReadingSources(owner))
        }
        val localStats by lazy { readingStats() }
        val storage by lazy { DeviceStorage(store, projection) }
        val power by lazy { battery() }
        val account by lazy { if (local) null else accountStats(owner) }
        val stats by lazy { ReadingStats.display(AccountStats.combine(localStats, if (local) null else projection.cachedReadingStats(owner), account, clock()), clock(), AccountStats.zone(account)) }
        for (encoded in requests) {
            val start = System.nanoTime()
            val request = encoded as? String ?: continue
            if (request.length > 8192) continue
            val args = LuaValue.parse(request.toByteArray(Charsets.ISO_8859_1)) as? Map<*, *> ?: continue
            store.transaction {
                if (!local && store.meta("owner") != owner) return@transaction
                val result = try { when (args["op"]) {
                    "storage.summary" -> storage.summary(owner,(args["exclude_path"] as? String)?.let(LuaValue::utf8),(args["current_folder"] as? String)?.let(LuaValue::utf8))
                    "reader.controls" -> ReaderControls.project(args["native"] as? Map<*, *> ?: emptyMap<Any, Any>())

                    "personal.reading" -> personal.window(args["kind"] as? String ?: "", clock())
                    "reading.stats" -> stats
                    "local.word" -> LocalWidgets.word(vocabulary(), clock())
                    "local.buddy" -> LocalWidgets.buddy(localStats)
                    "local.light" -> LocalWidgets.light(args["native"] as? Map<*, *> ?: emptyMap<Any, Any>())
                    "device.clock" -> ClockWidget.snapshot(clock(), power, twelve = args["twelve_hour"] == true)
                    "mode-estimates" -> BatteryEstimate.modeRows(power, (args["limit"] as? Number)?.toInt() ?: 3)
                    "battery" -> power
                    "sleep.choices" -> SleepChoiceWindow.project(SleepChoices.read(SleepScreen.dir()), args)
                    "capabilities" -> projection.capabilities(owner) + mapOf("battery" to true)
                    else -> projection.project(owner, args)
                } } catch (_: IllegalArgumentException) { mapOf("error" to "unsupported", "items" to emptyList<Any>()) }
                val items = result["items"] as? List<*>
                val measuredRows = items.orEmpty().size + items.orEmpty().sumOf {
                    ((it as? Map<*, *>)?.get("books") as? List<*>)?.size ?: 0
                } + ((result["next_books"] as? List<*>)?.size ?: 0) +
                    (if (args["op"] == "series" && result.containsKey("subtitle")) 1 else 0)
                val rows = maxOf(measuredRows, (result["row_count"] as? Number)?.toInt() ?: 0)
                val boundedResult = if (result.containsKey("row_count")) result + mapOf("row_count" to rows) else result
                var body = LuaValue.encode(boundedResult)
                val budget = ((args["bytes"] as? Number)?.toInt() ?: MAX_BYTES).coerceIn(256, MAX_BYTES)
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
    /** Local removal changes every cached file join, including grouped/Series previews.
     * Keep unrelated account, reading and battery materializations intact. */
    fun refreshLocalFiles(owner: String): Boolean {
        val operations=setOf("storage.summary","library.summary","window","book","reader","cover","cover.reference",
            "groups","series","counts","facets","sources")
        val requests=store.db().query("SELECT request FROM library_views WHERE owner=?",LuaValue.utf8(owner)) { it.text(0)!! }
            .filter { raw -> (LuaValue.parse(raw.toByteArray(Charsets.ISO_8859_1)) as? Map<*,*>)?.get("op") in operations }
        var changed=false
        requests.chunked(MAX_BATCH).forEach { if(publish(owner,it)) changed=true }
        return changed
    }

}
