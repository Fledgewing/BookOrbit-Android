package net.fledgewing.orbitcompanion

import java.io.File

/** The companion bulk executor calls this synchronously. Each page + cursor commits together;
 * networking, yielding and JSON decoding happen outside writer transactions. */
class FastCatalogRefresh(
    private val store: CacheStore,
    private val plan: CacheWorker.Plan,
    private val fetch: (String) -> Map<*, *>,
    private val idle: () -> Unit,
    private val stopped: () -> Boolean,
    private val stamp: () -> Long,
    private val progress: (Int) -> Unit,
    private val log: (String) -> Unit,
    private val clock: () -> Long = { System.nanoTime() / 1_000_000 },
    private val dataRoom: (Long) -> Boolean = { true },
) {
    private val db get() = store.db()
    private val base = "/koreader/plugin/catalog"
    private var generation = 0L
    private var requests = 0L
    class FetchFailure(val receivedBytes: Long = 0L) : RuntimeException("catalog unavailable")
    private var received = 0L
    private var failures = 0L
    private var percent = 0
    private var phaseLimit = 0
    private val old get() = store.meta("bulk_active")?.toLongOrNull()
    private fun key(s: String) = "bulk_stage_$s"
    private fun meta(s: String) = store.meta(key(s))
    private fun set(s: String, v: Any?) = store.setMeta(key(s), v)
    private fun tick(p: Int) {
        percent = maxOf(percent, p.coerceAtMost(99))
        set("pct", percent)
        progress(percent)
    }
    private fun boundary() {
        check(!stopped()) { "stopped" }
        idle()
        check(!stopped()) { "stopped" }
        plan.limit?.let { check(store.fileBytes() < it) { "storage limit" } }
        check(dataRoom(1)) { "storage limit" }
    }
    private fun ask(path: String): Map<*, *> {
        boundary()
        requests++
        val body = try { fetch(path) } catch(e:Exception) {
            failures++
            if(e is FetchFailure) received += e.receivedBytes
            throw e
        }
        // Model bytes are the actual UTF-8 reply bytes supplied by the transport callback below.
        received += (body["_bulkBytes"] as? Number)?.toLong() ?: 0
        check(dataRoom(LuaValue.encode(body).size * 4L + 4096)) { "storage limit" }
        return body
    }
    private fun <T> phase(name: String, job: () -> T): T {
        phaseLimit = when (name) {
            "manifest" -> 14; "section metadata" -> 19; "memberships" -> 34
            "dynamic selections" -> 49; "missing-row batches" -> 59; "ordering sequences" -> 84
            "local indexing/publication" -> 89; "secondary series" -> 98
            else -> percent
        }
        val start = clock(); val before = requests; val bytes = received; val failed = failures
        try { return job() } finally {
            log("bulk: $name requests=${requests-before} bytes=${received-bytes} failures=${failures-failed} elapsedMs=${clock()-start}")
        }
    }
    private fun items(body: Map<*, *>) = (body["items"] as? List<*>)?.map { it as? Map<*, *> ?: error("invalid item") } ?: error("items missing")
    private fun done(path: String, g: Long = generation) = db.query("SELECT 1 FROM bulk_pages WHERE g=? AND path=?", g, CacheStore.u(path)) { 1 }.isNotEmpty()
    private fun mark(path: String, g: Long = generation) = db.exec("INSERT OR IGNORE INTO bulk_pages VALUES (?,?)", g, CacheStore.u(path))
    private fun path(endpoint: String, q: Map<String, String>) = endpoint + "?" + MirrorLogic.encQuery(q)
    private fun member(kind: String, value: String, id: Long, context: Map<String, Any?>? = null, g: Long = generation) {
        if (g < 0 && db.query("SELECT 1 FROM bulk_books WHERE g=? AND id=?",generation,id) {1}.isEmpty()) {
            set("identity",null);error("catalog changed during enumeration")
        }
        val ix = BulkCatalog.indexParts(context?.get("seriesIndex"))
        db.exec("INSERT OR REPLACE INTO bulk_members VALUES (?,?,?,?,?,?,?,?)", g, kind, CacheStore.u(value), id,
            context?.let(LuaValue::encode), *ix.toTypedArray())
    }
    private fun rich(row: Map<*, *>) {
        val id = (row["id"] as? Number)?.toLong() ?: error("book id missing")
        val manifest = db.query("SELECT item,status FROM bulk_books WHERE g=? AND id=?", generation, id) { it.bytes(0)!! to (it.text(1)!=null) }.firstOrNull() ?: run {
            set("reconcile", true); return
        }
        val canonical = (LuaValue.parse(manifest.first) as Map<*, *>).entries.associate { it.key.toString() to it.value }.toMutableMap()
        var changed=false
        for (field in listOf("seriesId", "progressPercentage", "lastReadAt", "readStatus", "addedAt", "updatedAt", "hasCover", "thumbnailUrl", "detailUrl")) {
            if(canonical[field]!=row[field]){canonical[field]=row[field];changed=true}
        }
        if(manifest.second&&!changed)return
        db.exec("UPDATE bulk_books SET item=?,status=?,added=?,updated=? WHERE g=? AND id=?", LuaValue.encode(canonical),
            BulkCatalog.status(row["readStatus"]), row["addedAt"], row["updatedAt"], generation, id)
    }
    private fun context(row: Map<*, *>) = listOf("seriesId", "seriesName", "seriesIndex").associateWith { row[it] }
    private fun allBooks(): List<Map<*, *>> = db.query("SELECT item FROM bulk_books WHERE g=? ORDER BY id", generation) { LuaValue.parse(it.bytes(0)!!) as Map<*, *> }

    fun run(): String {
        log("bulk: start op=${plan.op}")
        BulkCatalog.initialize(db)
        val identity = plan.owner + "|" + plan.detailTemplate.orEmpty() + "|" + plan.strings("seed_lists").joinToString("|")
        if (plan.op == "full" || meta("identity") != identity || meta("g") == null) {
            // Clean only unpublished generations. The previous published cache stays intact.
            val keep = old ?: 0L
            store.transaction {
                for (table in BulkCatalog.tables) db.exec("DELETE FROM $table WHERE g<>?", keep)
                db.exec("DELETE FROM meta WHERE k LIKE 'bulk_stage_%'")
                generation = keep + 1
                set("g", generation); set("identity", identity); set("pct", 0)
            }
        } else generation = meta("g")!!.toLong()
        percent = meta("pct")?.toIntOrNull() ?: 0
        val start = clock()
        var outcome = "incomplete coverage"
        try {
            phase("manifest") { manifest() }; tick(15)
            phase("section metadata") { sections() }; tick(20)
            phase("memberships") { scopes() }; tick(35)
            phase("dynamic selections") { dynamic() }; tick(50)
            phase("missing-row batches") { hydrate() }; tick(60)
            phase("ordering sequences") { ordering() }; tick(85)
            if (meta("reconcile") != null) { set("identity", null); error("catalog changed during enumeration") }
            phase("local indexing/publication") { derive(); publishBase() }; tick(90)
            phase("secondary series") { secondary() }; tick(99)
            boundary()
            store.transaction {
                if (store.meta("run_op") == "full" || store.meta("full_at") == null) store.setMeta("full_at", stamp())
                plan.m["lib_version"]?.let { store.setMeta("lib_version", LuaValue.text(it)) }
                store.setMeta("bulk_complete", generation)
                db.exec("DELETE FROM meta WHERE k LIKE 'bulk_stage_%'")
                // Release old generations only after a complete successful run.
                for (table in BulkCatalog.tables) db.exec("DELETE FROM $table WHERE g<>?", generation)
            }
            store.retireLegacyCatalog()
            progress(100)
            outcome = "finished"
            return outcome
        } catch (e: Exception) {
            if (e.message?.contains("watchdog") == true || e.message == "page total changed during enumeration") {
                log("bulk: no-progress watchdog; staged cursor discarded")
                set("identity", null)
            }
            set("pct", percent)
            log("bulk: paused (${e.message?.takeIf { it in setOf("stopped", "storage limit") } ?: "incomplete coverage"}); published generation retained")
            outcome = if (stopped()) "stopped" else if (e.message == "storage limit") "storage limit" else "incomplete coverage"
            return outcome
        } finally {
            log("bulk: finish result=$outcome requests=$requests bytes=$received failures=$failures elapsedMs=${clock()-start} databaseBytes=${store.fileBytes()}")
        }
    }
    private fun manifest() {
        if (meta("manifest_done") != null) return
        var cursor = meta("cursor")
        var restarted = false
        while (true) {
            val query = linkedMapOf("size" to "200")
            val detailQuery = plan.detailTemplate?.let { MirrorLogic.parseQuery(MirrorLogic.splitPath(it).second) }.orEmpty()
            for (field in listOf("deviceId", "variant")) detailQuery[field]?.let { query[field] = it }
            cursor?.let { query["cursor"] = it }
            val request = path("$base/manifest", query)
            val body = ask(request)
            if (body["restartRequired"] == true) {
                check(!restarted) { "manifest repeatedly restarted" }; restarted = true
                store.transaction {
                    for (table in BulkCatalog.tables) db.exec("DELETE FROM $table WHERE g=?", generation)
                    set("cursor", null)
                }
                cursor = null; continue
            }
            log("bulk: manifest page=$requests rows=${items(body).size}")
            val next = body["nextCursor"] as? String
            val more = body["hasNext"] == true
            check(!more || (items(body).isNotEmpty() && !next.isNullOrEmpty() && next != cursor && !done("cursor:$next"))) { "manifest no-progress watchdog" }
            store.transaction {
                for (book in items(body)) {
                    val id = (book["id"] as? Number)?.toLong() ?: error("manifest id missing")
                    check(id > 0)
                    val ix = BulkCatalog.indexParts(book["seriesIndex"])
                    db.exec("INSERT OR REPLACE INTO bulk_books VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", generation, id, LuaValue.encode(book), java.security.MessageDigest.getInstance("SHA-256").digest(LuaValue.encode(book)),
                        book["title"]?.let { CacheStore.u(it.toString()) }, book["seriesName"]?.let { CacheStore.u(it.toString()) }, *ix.toTypedArray(), null, null, null)
                    for (author in (book["authors"] as? List<*>).orEmpty()) member("author", author.toString(), id)
                    for (format in (book["formats"] as? List<*>).orEmpty()) member("format", format.toString().lowercase(), id)
                }
                cursor?.let { mark("cursor:$it") }
                set("cursor", next)
                if (!more) set("manifest_done", true)
            }
            tick(minOf(phaseLimit, percent + 1))
            if (!more) return
            cursor = next
        }
    }
    /** One source, durable per page. Row consumers must be idempotent (membership/rank keys). */
    private fun pages(endpoint: String, query: Map<String, String>, tag: String, g: Long = generation, onPage: (Map<*, *>) -> Unit = {}, consume: (Map<*, *>, Int) -> Unit) {
        var page = 1
        var total = meta("total:$tag")?.toIntOrNull() ?: 0
        var previousPage = meta("fingerprint:$tag")
        var expectedTotal: Int? = meta("total:$tag")?.toIntOrNull()
        do {
            boundary() // Even a durable page hit must yield and honour cancellation.
            check(page <= 100_000) { "page watchdog: no completion" }
            val request = path(endpoint, query + mapOf("page" to page.toString(), "size" to "100"))
            if (!done(request, g)) {
                val body = ask(request)
                val rows = items(body)
                val signature = java.util.Base64.getEncoder().encodeToString(java.security.MessageDigest.getInstance("SHA-256").digest(LuaValue.encode(rows)))
                check(rows.isEmpty() || previousPage != signature) { "page no-progress watchdog" }
                previousPage = signature
                total = (body["total"] as? Number)?.toInt() ?: rows.size
                check(expectedTotal == null || expectedTotal == total) { "page total changed during enumeration" }
                expectedTotal = total
                check(total >= 0 && (rows.isNotEmpty() || (page-1)*100 >= total)) { "incomplete page" }
                store.transaction {
                    onPage(body)
                    rows.forEachIndexed { i, row -> consume(row, (page-1)*100+i) }
                    mark(request, g); set("total:$tag", total); set("fingerprint:$tag", signature)
                }
            }
            log("bulk: page page=$page total=$total")
            tick(minOf(phaseLimit, percent + 1))
            page++
        } while ((page-1)*100 < total)
    }
    private fun sections() {
        for (section in listOf("libraries", "collections", "smart-scopes", "authors", "series")) {
            pages("$base/sections/$section", emptyMap(), "section:$section") { row, pos ->
                db.exec("INSERT OR REPLACE INTO bulk_sections VALUES (?,?,?,?,?,?,?,?,?,?)", generation, section, pos, LuaValue.encode(row),
                    row["title"]?.let { CacheStore.u(it.toString()) }, row["count"] ?: 0L, row["readingCount"] ?: 0L, row["finishedCount"] ?: 0L, row["id"]?.let { CacheStore.u(it.toString()) }, row["letter"] ?: BulkCatalog.letter(row["title"]?.toString()?.let(LuaValue::utf8)))
            }
        }
        for(section in listOf("authors","series")) pages("$base/sections/$section",mapOf("sort" to "name_desc"),"section:$section:name_desc") { row,pos ->
            db.exec("INSERT OR REPLACE INTO bulk_section_ranks VALUES (?,?,?,?,?)",generation,section,"name_desc",row["id"]?.let { CacheStore.u(it.toString()) },pos)
        }
        val entries = (plan.strings("entries") + listOf("$base/root", "$base/dashboard", "$base/dashboard/discover",
            "$base/dashboard/sections/want-to-read", "$base/dashboard/sections/up-next-in-series")).distinct()
        for (request in entries) {
            if (done(request)) continue
            val fresh = ask(request).filterKeys { it != "_bulkBytes" }
            val saved = old?.let { prior -> db.query("SELECT body FROM bulk_replies WHERE g=? AND path=?",prior,CacheStore.u(request)) {LuaValue.parse(it.bytes(0)!!)}.firstOrNull() }
            val full = if(plan.op=="resume") (store.meta("run_op") ?: "full")=="full" else plan.op=="full"
            val body = LuaValue.settle(saved,fresh,if(full) "full" else "refresh")
            store.transaction { db.exec("INSERT OR REPLACE INTO bulk_replies VALUES (?,?,?)", generation, CacheStore.u(request), LuaValue.encode(body)); mark(request) }
        }
    }
    private fun entries(section: String) = db.query("SELECT item FROM bulk_sections WHERE g=? AND section=? ORDER BY pos", generation, section) { LuaValue.parse(it.bytes(0)!!) as Map<*, *> }
    private fun scopes() {
        for ((section, selector) in listOf("libraries" to "libraryId", "collections" to "collectionId", "smart-scopes" to "smartScopeId"))
            for (entry in entries(section)) {
                val value = entry["id"].toString()
                pages("$base/books", mapOf(selector to value), "$selector:$value") { row, _ ->
                    val id = (row["id"] as Number).toLong(); member(selector, value, id); rich(row)
                }
            }
    }
    private fun source(sort: String, direction: String, status: String? = null) {
        val q = linkedMapOf("sort" to sort, "order" to direction)
        status?.let { q["readStatus"] = it }
        if (sort == "author" || sort == "title") q["buckets"] = "1"
        var buckets = emptyList<Map<*, *>>()
        pages("$base/books", q, MirrorLogic.encQuery(q), onPage = { body ->
            buckets = (body["buckets"] as? List<*>)?.mapNotNull { it as? Map<*, *> }.orEmpty()
        }) { row, pos ->
            rich(row)
            if (status == null) {
                val letter = buckets.lastOrNull { ((it["index"] as? Number)?.toInt() ?: Int.MAX_VALUE) <= pos }?.get("key")?.toString()
                    ?: BulkCatalog.letter((if (sort == "title") row["title"] else (row["authors"] as? List<*>)?.firstOrNull())?.toString()?.let(LuaValue::utf8))
                db.exec("INSERT OR REPLACE INTO bulk_ranks VALUES (?,?,?,?,?,?)", generation, sort, direction, (row["id"] as Number).toLong(), pos, letter)
            }
        }
    }
    private fun dynamic() {
        source("recently_added", "desc")
        source("recently_read", "desc", "reading")
        source("recently_read", "desc", "finished")
    }
    private fun hydrate() {
        val missing = db.query("SELECT id FROM bulk_books WHERE g=? AND status IS NULL ORDER BY id", generation) { it.long(0)!! }
        for (ids in missing.chunked(100)) {
            val request = path("$base/books", mapOf("ids" to ids.joinToString(","), "size" to "100"))
            val body = ask(request)
            store.transaction {
                for (row in items(body)) rich(row)
                // Missing IDs are explicitly inaccessible/deleted, never endlessly retried.
                for (id in ids) db.exec("DELETE FROM bulk_books WHERE g=? AND id=? AND status IS NULL", generation, id)
            }
        }
    }
    private fun ordering() {
        // These sort keys are not projected by manifest/list rows (author sortName,
        // publication date, status-updated tie breaker). Retain both directions: ties
        // and NULLS LAST mean descending is not reverse(ascending).
        for (sort in listOf("title", "author", "published", "recently_read", "series")) for (dir in listOf("asc", "desc")) source(sort, dir)
    }
    private fun derive() {
        if (meta("derived") != null) return
        val series = entries("series")
        for (book in allBooks()) {
            boundary()
            val id = (book["id"] as Number).toLong()
            val name = book["seriesName"] as? String ?: continue
            val sid = book["seriesId"]?.toString()
            check(dataRoom(LuaValue.encode(context(book)).size * 4L + 16384)) { "storage limit" }
            val matching = if (sid != null) series.filter { it["seriesId"].toString() == sid } else series.filter { it["title"] == name }
            store.transaction {
                val c = context(book)
                member("series", name.trim().lowercase(), id, c)
                if (matching.size == 1) {
                    val sid = matching.single()["seriesId"].toString()
                    member("seriesId", sid, id, c); member("primarySeriesId", sid, id, c)
                }
            }
        }
        set("derived", true)
    }
    private fun publishBase() {
        if (meta("base_published") != null) return
        boundary()
        val searches=allBooks().map { it["id"] to CacheStore.searchText(it) }
        val heads=old?.let { prior -> db.query("SELECT coalesce(sum(length(head)),0) FROM bulk_heads WHERE g=?",prior) {it.long(0)!!}.first() } ?: 0L
        check(dataRoom(searches.sumOf {it.second.toByteArray(Charsets.UTF_8).size.toLong()}*2+heads+16384)) { "storage limit" }
        store.transaction {
            // Previously fetched detail-only fields survive until observed metadata changes.
            db.exec("UPDATE books SET detail=NULL,detail_at=NULL WHERE id IN (SELECT n.id FROM bulk_books n JOIN bulk_books o ON o.id=n.id WHERE n.g=? AND o.g=? AND (n.manifest<>o.manifest OR n.updated<>o.updated))", generation, old ?: 0L)
            db.exec("INSERT OR IGNORE INTO books(id) SELECT id FROM bulk_books WHERE g=?", generation)
            db.exec("UPDATE books SET item=NULL,item_at=? WHERE id IN (SELECT id FROM bulk_books WHERE g=?)", stamp(), generation)
            for ((id,text) in searches) db.exec("UPDATE books SET search=? WHERE id=?", text, id)
            db.exec("DELETE FROM books WHERE id NOT IN (SELECT id FROM bulk_books WHERE g=?)", generation)
            // Copy old secondary contexts before the base becomes visible.
            old?.takeIf { it != generation }?.let { prior ->
                set("previous", prior)
                db.exec("INSERT OR IGNORE INTO bulk_heads SELECT ?,identity,head FROM bulk_heads WHERE g=?",generation,prior)
                for (entry in entries("series")) {
                    val sid = entry["seriesId"]?.toString() ?: continue
                    val primary = db.query("SELECT count(*) FROM bulk_members WHERE g=? AND kind='primarySeriesId' AND value=?", generation, sid) { it.long(0)!! }.first()
                    if (primary == (entry["count"] as? Number)?.toLong()) continue
                    db.exec("INSERT OR IGNORE INTO bulk_members SELECT ?,kind,value,id,context,ix1,ix2,ix FROM bulk_members WHERE g=? AND kind='seriesId' AND value=? AND id IN (SELECT id FROM bulk_books WHERE g=?)", generation, prior, sid, generation)
                    entry["title"]?.toString()?.trim()?.lowercase()?.let { name ->
                        db.exec("INSERT OR IGNORE INTO bulk_members SELECT ?,kind,value,id,context,ix1,ix2,ix FROM bulk_members WHERE g=? AND kind='series' AND value=? AND id IN (SELECT id FROM bulk_books WHERE g=?)", generation, prior, CacheStore.u(name), generation)
                    }
                }
            }
            for ((request, bytes) in db.query("SELECT path,body FROM bulk_replies WHERE g=?", generation) { LuaValue.str(it.text(0)!!) to it.bytes(1)!! }) {
                val server = plan.owner.substringAfter('|')
                store.putEntry(MirrorLogic.key(plan.owner, server, request), request, LuaValue.parse(bytes), stamp())
            }
            store.setMeta("bulk_active", generation); store.setMeta("bulk_at", stamp()); set("base_published", true)
        }
    }
    private fun seriesNames(prior: Long?) {
        for ((name, rows) in entries("series").groupBy { it["title"]?.toString()?.trim()?.lowercase() }) {
            if (name == null) continue
            val series = rows.mapNotNull { it["seriesId"]?.toString() }.distinct()
            val ambiguous = series.size != 1
            val tag = "secondary-name:$name"
            val changed = prior == null || db.query("SELECT 1 FROM bulk_members m LEFT JOIN bulk_books o ON o.g=? AND o.id=m.id LEFT JOIN bulk_books n ON n.g=? AND n.id=m.id WHERE m.g IN (?,?) AND m.kind='series' AND m.value=? AND (o.id IS NULL OR n.id IS NULL OR n.manifest<>o.manifest OR coalesce(n.updated,'')<>coalesce(o.updated,'')) LIMIT 1", prior, generation, prior, generation, CacheStore.u(name)) { 1 }.isNotEmpty()
            val oldSeries = prior?.let { g -> db.query("SELECT item FROM bulk_sections WHERE g=? AND section='series'",g) { LuaValue.parse(it.bytes(0)!!) as Map<*,*> }.filter { it["title"]?.toString()?.trim()?.lowercase()==name }.mapNotNull { it["seriesId"]?.toString() }.toSet() }
            if (ambiguous && prior != null && !changed && oldSeries == series.toSet() && done(tag,prior)) {
                store.transaction {
                    db.exec("DELETE FROM bulk_members WHERE g=? AND kind='series' AND value=?",generation,CacheStore.u(name))
                    db.exec("INSERT INTO bulk_members SELECT ?,'series',value,id,context,ix1,ix2,ix FROM bulk_members WHERE g=? AND kind='series' AND value=?",generation,prior,CacheStore.u(name))
                    mark(tag)
                }
            } else if (ambiguous) {
                pages("$base/books",mapOf("series" to name,"sort" to "series","order" to "asc"),tag,-generation) {row,_->
                    member("series",name,(row["id"] as Number).toLong(),context(row),-generation)
                }
                boundary()
                store.transaction {
                    val expected = if(series.isEmpty()) meta("total:$tag")?.toLongOrNull() ?: -1L else db.query("SELECT count(DISTINCT id) FROM bulk_members WHERE g=? AND kind='seriesId' AND value IN (${series.joinToString(",") {"?"}})",generation,*series.toTypedArray()) {it.long(0)!!}.first()
                    val received = db.query("SELECT count(*) FROM bulk_members WHERE g=? AND kind='series' AND value=?",-generation,CacheStore.u(name)) {it.long(0)!!}.first()
                    check(expected==received) {"incomplete named series"}
                    db.exec("DELETE FROM bulk_members WHERE g=? AND kind='series' AND value=?",generation,CacheStore.u(name))
                    db.exec("INSERT INTO bulk_members SELECT ?,'series',value,id,context,ix1,ix2,ix FROM bulk_members WHERE g=? AND kind='series' AND value=?",generation,-generation,CacheStore.u(name))
                    mark(tag)
                }
            } else {
                // Rebuild even when the ID feed was reused: the copied contextual
                // membership must replace the primary row made by derive().
                store.transaction {
                    db.exec("DELETE FROM bulk_members WHERE g=? AND kind='series' AND value=?",generation,CacheStore.u(name))
                    for (sid in series) db.exec("INSERT OR REPLACE INTO bulk_members SELECT ?,'series',?,id,context,ix1,ix2,ix FROM bulk_members WHERE g=? AND kind='seriesId' AND value=?",generation,CacheStore.u(name),generation,sid)
                }
            }
        }
    }

    private fun secondary() {
        val prior = meta("previous")?.toLongOrNull()
        for (entry in entries("series")) {
            boundary()
            val sid = entry["seriesId"]?.toString() ?: continue
            val count = (entry["count"] as? Number)?.toLong() ?: 0L
            val primary = db.query("SELECT count(*) FROM bulk_members WHERE g=? AND kind='primarySeriesId' AND value=?", generation, sid) { it.long(0)!! }.first()
            if (primary == count) continue
            val known = db.query("SELECT count(*) FROM bulk_books b WHERE g=? AND id IN (SELECT id FROM bulk_members WHERE g=? AND kind='seriesId' AND value=?)", generation, generation, sid) { it.long(0)!! }.first()
            val previous = prior?.let { g -> db.query("SELECT item FROM bulk_sections WHERE g=? AND section='series'", g) { LuaValue.parse(it.bytes(0)!!) as Map<*, *> }.find { it["seriesId"].toString() == sid } }
            val changed = prior == null || db.query("SELECT 1 FROM bulk_members m LEFT JOIN bulk_books o ON o.g=? AND o.id=m.id LEFT JOIN bulk_books n ON n.g=? AND n.id=m.id WHERE m.g IN (?,?) AND m.kind='seriesId' AND m.value=? AND (o.id IS NULL OR n.id IS NULL OR n.manifest<>o.manifest OR coalesce(n.updated,'')<>coalesce(o.updated,'')) LIMIT 1", prior, generation, prior, generation, sid) { 1 }.isNotEmpty()
            if (known == count && (previous == null || (!changed && previous["count"] == entry["count"]))) continue
            val tag = "secondary:$sid"
            pages("$base/books", mapOf("seriesId" to sid, "sort" to "series", "order" to "asc"), tag, -generation) { row, _ ->
                member("seriesId", sid, (row["id"] as Number).toLong(), context(row), -generation)
            }
            boundary()
            val receivedCount = db.query("SELECT count(*) FROM bulk_members WHERE g=? AND kind='seriesId' AND value=?", -generation, sid) { it.long(0)!! }.first()
            if (receivedCount != count) { set("identity", null); error("series membership changed during enumeration") }
            store.transaction {
                db.exec("DELETE FROM bulk_members WHERE g=? AND kind='seriesId' AND value=?", generation, sid)
                db.exec("INSERT INTO bulk_members SELECT ?,kind,value,id,context,ix1,ix2,ix FROM bulk_members WHERE g=? AND kind='seriesId' AND value=?", generation, -generation, sid)
                // A name route is the union of distinct IDs, never a merge of server series identities.
                val name = entry["title"]?.toString()?.trim()?.lowercase()
                if (name != null) {
                    val matching = entries("series").filter { it["title"]?.toString()?.trim()?.lowercase() == name }.mapNotNull { it["seriesId"]?.toString() }
                    db.exec("DELETE FROM bulk_members WHERE g=? AND kind='series' AND value=?", generation, CacheStore.u(name))
                    for (id in matching.sorted()) db.exec("INSERT OR REPLACE INTO bulk_members SELECT ?,'series',?,id,context,ix1,ix2,ix FROM bulk_members WHERE g=? AND kind='seriesId' AND value=?", generation, CacheStore.u(name), generation, id)
                }
            }
        }
        seriesNames(prior)
    }
}
