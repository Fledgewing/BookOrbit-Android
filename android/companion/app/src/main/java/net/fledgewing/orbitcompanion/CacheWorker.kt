package net.fledgewing.orbitcompanion

import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * The Orbit cache's background work, done by the companion instead of KOReader
 * (docs/design/companion-worker.md, docs/design/sqlite-cache.md): the Full refresh, Refresh's
 * recheck and the covers, the cache's checks and stores, write patches, the storage limit and the
 * copies lookup. Everything the cache keeps is in one SQLite file, orbit-cache/orbit.db
 * ([CacheStore]), which only this class writes and the plugin reads.
 *
 * Small files stay files (android/docs/INTERFACE.md "The cache worker's files"): the plugin's
 * `mirror/plan.lua` and `mirror/stop` in, `mirror/status.lua` (the progress, every 2 s),
 * `mirror/summary.lua` and `events/<n>.lua` out; covers are image files beside their `.etag`.
 *
 * A Full refresh counts each book once: its detail is one job and its cover one job, whichever
 * lists name it, and the work is fixed once the library's size and the section indexes are in
 * (the all-books list and the sections' first pages). Requests run [parallel] at a time and
 * covers on their own pool; one thread writes the landed replies, up to [BATCH] per transaction.
 *
 * Plain JVM ([Sql] and an [Http] port), so the unit tests run it against a fake server and JDBC.
 */
class CacheWorker(
    val root: File,
    private val http: Http,
    private val now: () -> Long = { System.currentTimeMillis() / 1000 },
    private val log: (String) -> Unit = { OLog.i(it) },
    private val sleep: (Int) -> Unit = { Thread.sleep(it * 1000L) },
    /** Requests in flight at once (1: strictly one after another). */
    private val parallel: Int = PARALLEL,
    private val openSql: (File) -> Sql = { AndroidSql(it) },
    private val clockMs: () -> Long = { System.currentTimeMillis() },
) {
    /** A GET. sink: write the body there (a cover) instead of returning it. */
    fun interface Http {
        fun get(url: String, headers: Map<String, String>, sink: File?, maxBytes: Long): Reply
    }

    /** code: the HTTP status, or 0 with err (no answer: a timeout, a network error). */
    data class Reply(val code: Int, val body: ByteArray? = null, val etag: String? = null, val contentType: String? = null, val err: String? = null)

    data class Creds(val server: String, val user: String, val key: String)

    val mirrorDir get() = File(root, "mirror")
    private val eventsDir get() = File(root, "events")

    val store: CacheStore by lazy { CacheStore(root, log, openSql).also { removeOldFiles() } }

    private fun headers(c: Creds, accept: String = "application/json") =
        mapOf("accept" to accept, "x-auth-user" to c.user, "x-auth-key" to c.key)

    private fun url(c: Creds, path: String) = c.server + LuaValue.utf8(path)

    // ------------------------------------------------------------------ files

    private fun write(f: File, bytes: ByteArray): Boolean {
        f.parentFile?.mkdirs()
        val tmp = File(f.parentFile, f.name + ".tmp" + (Math.random() * 1e9).toLong())
        return try {
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(f)) { tmp.delete(); false } else true
        } catch (e: Exception) {
            tmp.delete(); false
        }
    }

    private fun read(f: File): Any? = if (f.isFile) LuaValue.parse(f.readBytes()) else null

    /**
     * The files of the cache before the database (0.11.x): entries, the index, the mirror's pages
     * and queue. No backwards compatibility: they go, and the next Full refresh saves everything.
     */
    private fun removeOldFiles() {
        var n = 0
        val entry = Regex("^[0-9a-f]{8}\\.lua$")
        for (dir in listOf(root, mirrorDir)) for (f in dir.listFiles() ?: emptyArray()) {
            if (f.isFile && (entry.matches(f.name) || f.name in OLD_FILES || f.name.contains(".lua.tmp"))) { f.delete(); n++ }
        }
        if (n > 0) log("store: removed $n files of the cache before the database")
    }

    /** The detail template saved with the last plan (what a check of a detail path needs). */
    private fun detailTemplate(): String? = store.meta("detail_template")

    // ------------------------------------------------------------------ checks and stores

    /**
     * A background check or a store (the plugin's OC.check): mode "open" | "refresh" | "full", or
     * "store" (the plugin read it from the server; save it). template: the plugin's detail request.
     */
    data class Check(val key: String, val path: String, val mode: String, val creds: Creds, val owner: String, val template: String? = null)

    /**
     * Asks the server, compares with what the plugin would serve, saves a changed reply where the
     * plugin reads it, and answers: { kind = "checked", key, changed | unchanged, saved, at } or
     * { kind, key, err }.
     */
    fun check(c: Check) {
        val r = http.get(url(c.creds, c.path), headers(c.creds), null, MAX_BODY)
        val ev = sortedMapOf<String, Any?>("kind" to "checked", "key" to c.key)
        if (r.code != 200 || r.body == null) {
            ev["err"] = r.err ?: r.code.toString()
            return event(ev)
        }
        val reply = try { LuaValue.fromJson(String(r.body, Charsets.UTF_8)) } catch (e: Exception) { null }
        if (reply !is Map<*, *> && reply !is List<*>) {
            ev["err"] = "not json"
            return event(ev)
        }
        val st = store
        st.own(c.owner)
        val template = c.template ?: detailTemplate()
        if (c.template != null && c.template != st.meta("detail_template")) st.setMeta("detail_template", c.template)
        val saved = st.read(c.key, c.path, template)
        val t = now()
        if (saved != null && !LuaValue.changed(saved.body, reply)) {
            st.validated(saved, t)
            ev["unchanged"] = true
            ev["saved"] = true
            return event(ev)
        }
        try {
            st.save(c.key, c.path, LuaValue.settle(saved?.body, reply, c.mode), t, template)
        } catch (e: Exception) {
            ev["err"] = "not saved"
            return event(ev)
        }
        ev["changed"] = true
        ev["at"] = t
        event(ev)
    }

    /** A write the plugin made (PATCH): { id, fields (a Lua literal), stale_home }, or a wipe. */
    fun patch(id: Long?, fields: Map<*, *>, staleHome: Boolean, wipe: Boolean) {
        if (wipe) { store.wipe("the plugin asked"); return }
        val n = store.patch(id, fields, staleHome)
        if (n > 0) log("store: a write patched $n saved replies")
    }

    // ------------------------------------------------------------------ the storage limit

    /** The plugin's STORAGE: count, and over [limit] remove (StorageLogic). [mirrorCovers]: "Save every cover" is on. */
    data class StorageAsk(val reason: String, val limit: Long?, val coverDir: String?, val mirrorCovers: Boolean)

    /** Everything Orbit stores: the database (browsing entries apart, as they can go) and the cover folder's files. */
    fun storageItems(coverDir: String?, mirrorCovers: Boolean): List<StorageLogic.Item> {
        val st = store
        val entries = st.entrySizes()
        val items = ArrayList<StorageLogic.Item>(entries)
        items.add(StorageLogic.Item("db", maxOf(0L, st.fileBytes() - entries.sumOf { it.bytes }), 0L, "kept"))
        val dir = coverDir?.let { File(it) }
        if (dir != null && dir.isDirectory) {
            val keep = if (mirrorCovers) st.coversKept() else emptySet()
            for (f in dir.listFiles() ?: emptyArray()) {
                if (!f.name.endsWith(".jpg") || !f.isFile) continue
                val etag = File(dir, f.name + ".etag")
                items.add(StorageLogic.Item("c:${f.name}", f.length() + (if (etag.isFile) etag.length() else 0L), f.lastModified() / 1000,
                    if (f.name in keep) "mirror_cover" else "cover"))
            }
        }
        return items
    }

    /**
     * Counts, and over the limit removes browsing entries and covers itself. Answers with
     * { kind = "storage", why, totals, removed = { cache, cover, mirror_cover }, used, after, limit };
     * the totals are also kept in the database (meta "storage") for the plugin's start.
     */
    fun storage(a: StorageAsk) {
        val items = storageItems(a.coverDir, a.mirrorCovers)
        val plan = StorageLogic.plan(items, a.limit)
        val byK = items.associateBy { it.k }
        val removed = sortedMapOf("cache" to 0L, "cover" to 0L, "mirror_cover" to 0L)
        store.transaction {
            for (k in plan.drop) {
                val it = byK[k] ?: continue
                if (k.startsWith("e:")) store.dropEntry(k.removePrefix("e:"))
                else if (k.startsWith("c:") && a.coverDir != null) {
                    File(a.coverDir, k.removePrefix("c:")).delete()
                    File(a.coverDir, k.removePrefix("c:") + ".etag").delete()
                }
                removed[it.kind] = (removed[it.kind] ?: 0L) + 1
            }
        }
        val totals = StorageLogic.totals(items, plan.drop)
        store.setMeta("storage", String(LuaValue.encode(sortedMapOf<String, Any?>("totals" to totals, "at" to now())), Charsets.ISO_8859_1))
        val ev = sortedMapOf<String, Any?>("kind" to "storage", "why" to a.reason, "totals" to totals,
            "removed" to removed, "used" to plan.used, "after" to plan.after)
        a.limit?.let { ev["limit"] = it }
        event(ev)
        if (plan.drop.isNotEmpty()) {
            log("storage: ${"%.1f".format(java.util.Locale.ROOT, plan.used / MB)} MB over ${a.limit?.let { it / (1024 * 1024) }} MB (${a.reason}); " +
                "${removed["cache"]} browsing entries, ${removed["cover"]} covers, ${removed["mirror_cover"]} saved-for-offline covers go -> " +
                "%.1f MB".format(java.util.Locale.ROOT, plan.after / MB))
        }
    }

    // ------------------------------------------------------------------ copies, tags, covers on screen

    /**
     * Tags in the saved book details, at most [max] details, for the Leave out tag picker. Model
     * byte strings, as saved.
     */
    fun detailTags(max: Int): List<List<String>> =
        store.db().query("SELECT detail FROM books WHERE detail IS NOT NULL LIMIT ?", max.toLong()) { it.bytes(0) }.mapNotNull { b ->
            ((b?.let { LuaValue.parse(it) } as? Map<*, *>)?.get("tags") as? List<*>)?.mapNotNull { it as? String }
        }

    /**
     * A Full refresh's covers on screen, asked again If-None-Match (was the plugin's forked
     * "cover recheck"). items: book id and the plugin's cover file, each with its .etag. Answers
     * with a `covers_rechecked` event naming the replaced ones.
     */
    fun recheckCovers(why: String, creds: Creds, items: List<Pair<Long, String>>) {
        val changed = ArrayList<Long>()
        var failed = 0L
        for ((id, path) in items) {
            val f = File(path)
            val etagFile = File("$path.etag")
            if (!f.isFile || !etagFile.isFile) continue
            val h = headers(creds, "image/jpeg,image/*").toMutableMap()
            h["Accept-Encoding"] = "identity"
            h["If-None-Match"] = etagFile.readText()
            val part = File("$path.part")
            val r = http.get(creds.server + "/koreader/plugin/catalog/books/$id/thumbnail", h, part, MAX_COVER)
            when {
                r.code == 304 -> { part.delete(); f.setLastModified(now() * 1000) }
                r.code == 200 && r.contentType?.lowercase()?.trim()?.startsWith("image/") == true && part.isFile && part.length() > 0 && part.renameTo(f) -> {
                    if (r.etag != null) write(etagFile, r.etag.toByteArray()) else etagFile.delete()
                    changed.add(id)
                }
                else -> { part.delete(); failed++ }
            }
        }
        log("worker: covers re-asked: ${items.size} checked, ${changed.size} replaced, $failed failed ($why)")
        event(sortedMapOf("kind" to "covers_rechecked", "why" to why, "checked" to items.size.toLong(), "changed" to changed, "failed" to failed))
    }

    /**
     * The plugin's COPIES: which copies on this reader changed in the library. The ask
     * (copies/ask.lua, written by the plugin; no login in it): `books` ({ md5, path, book_id,
     * file_id, incompatible }), `eob` (book id -> { files, saved_at }: the end-of-book cache).
     * The details come from the newer of the end-of-book cache and the database (CopiesLogic).
     * Answers with { kind = "copies", why, checked, found = { { md5, path, book_id, file_id, why } }, gone }.
     */
    fun copies(why: String) {
        val ask = read(File(root, "copies/ask.lua")) as? Map<*, *>
        if (ask == null) {
            event(sortedMapOf("kind" to "copies", "why" to why, "err" to "no ask"))
            return
        }
        val books = (ask["books"] as? List<*>)?.mapNotNull { it as? Map<*, *> } ?: emptyList()
        val want = books.mapNotNull { (it["book_id"] as? Long)?.toString() }.toHashSet()
        val details = HashMap<String, CopiesLogic.Detail>()
        for ((k, v) in ask["eob"] as? Map<*, *> ?: emptyMap<Any?, Any?>()) {
            val d = v as? Map<*, *> ?: continue
            details[k.toString()] = CopiesLogic.Detail(d["files"] as? List<*>, (d["saved_at"] as? Number)?.toLong() ?: 0L)
        }
        for (id in want) {
            val (body, at) = store.detail(id.toLong()) ?: continue
            val files = (body as? Map<*, *>)?.get("files") as? List<*> ?: continue
            if (CopiesLogic.newer(details[id], at)) details[id] = CopiesLogic.Detail(files, at)
        }
        val found = CopiesLogic.candidates(books, details)
        val present = found.filter { File(LuaValue.utf8(it["path"] as String)).isFile }
        event(sortedMapOf("kind" to "copies", "why" to why, "checked" to books.size.toLong(), "found" to present,
            "gone" to (found.size - present.size).toLong()))
    }

    private var eventSeq = 0

    /** An answer for the plugin in events/ (it drains them while it waits for one). */
    fun event(ev: Map<String, Any?>) {
        eventSeq++
        write(File(eventsDir, "${now()}-0-c$eventSeq.lua"), LuaValue.encode(ev))
    }

    // ------------------------------------------------------------------ the plan

    /** What the plugin asks for (mirror/plan.lua, written by the plugin; no credentials in it). */
    data class Plan(val m: Map<*, *>) {
        val run get() = m["run"]?.toString() ?: ""
        val op get() = m["op"] as? String ?: "resume"
        val reason get() = m["reason"] as? String
        val owner get() = m["owner"] as? String ?: ""
        val sentinel get() = m["sentinel"] as? String ?: MirrorLogic.SENTINEL
        val templates get() = m["templates"] as? Map<*, *> ?: emptyMap<String, Any?>()
        val detailTemplate get() = m["detail_template"] as? String
        val allBooks get() = m["all_books"] as? String
        val coversOn get() = m["covers_on"] == true
        val coverDir get() = m["cover_dir"] as? String
        val limit get() = (m["limit"] as? Long)?.takeIf { it > 0 }
        fun strings(k: String) = (m[k] as? List<*>)?.mapNotNull { it as? String } ?: emptyList()
        fun ids(k: String) = (m[k] as? List<*>)?.mapNotNull { it as? Long } ?: emptyList()
    }

    /** The plugin's cover file name: Cache.coverName (shared/fixtures/cache/worker.json "covers"). */
    fun coverName(book: Map<*, *>): String? {
        val id = book["id"] as? Long ?: return null
        if (id < 1 || id > 2147483647L) return null
        val raw = book["updatedAt"]?.let { LuaValue.text(it) }
        var token = raw?.filter { it in '0'..'9' } ?: "0"
        if (token.length > 32) token = token.substring(0, 16) + token.substring(token.length - 16)
        if (token.isEmpty()) token = "0"
        return "${if (book["author_photo"] != null && book["author_photo"] != false) "a" else ""}${id}_$token.jpg"
    }

    /** The plugin's cover file name (bookorbit_catalog_thumbnails.lua:62-85 coverToken, memoKey). */
    fun coverPath(plan: Plan, book: Map<*, *>): String? {
        val dir = plan.coverDir ?: return null
        if (book["hasCover"] != true) return null
        return coverName(book)?.let { "$dir/$it" }
    }

    // ------------------------------------------------------------------ the run

    /**
     * One job of the run (the `jobs` table: kind and ref, de-duplicated by both).
     * - page: ref "<page>|<size>|<identity>", one list page (MirrorLogic.mirrorPage);
     * - recheck: the same, for Refresh (a changed page fetches only new books' details);
     * - detail: ref "<book id>";
     * - cover: ref "<book id>" (the book's saved item names its cover).
     */
    private data class Job(val kind: String, val ref: String) {
        val page get() = ref.substringBefore('|').toInt()
        val size get() = ref.substringAfter('|').substringBefore('|').toInt()
        val identity get() = ref.substringAfter('|').substringAfter('|')
        val id get() = ref.toLong()
    }

    private fun pageJob(kind: String, identity: String, page: Int, size: Int = MirrorLogic.PAGE) = Job(kind, "$page|$size|$identity")

    /** A fetched job, back from a pool thread. body: a page's or detail's reply; cover: the cover's outcome. */
    private class Landed(val job: Job, val reply: Reply?, val path: String?, val cover: String? = null, val coverBytes: Long = 0, val coverWritten: Map<String, Any?>? = null)

    /** The run's counters, in memory; the jobs table is the durable part. */
    private class Run(val plan: Plan) {
        var done = 0L; var total = 0L; var skipped = 0L; var requests = 0L; var pct = 0L; var estimate = 0L
        var covers = longArrayOf(0, 0, 0, 0) // ok, not modified, failed, bytes
        var coverTotal = 0L
        var startedMs = 0L; var batches = 0L; var writeMs = 0L; var writeMax = 0L
        var limitNote: Map<String, Any?>? = null
        var errors = 0L
        val changed = ArrayList<String>()
        val written = ArrayList<Map<String, Any?>>()
        var writtenMore = false
        var details = 0L
        var lists = HashSet<String>()
    }


    private fun addJob(j: Job) = store.db().exec("INSERT OR IGNORE INTO jobs (kind, ref, state, tries) VALUES (?, ?, 0, 0)", j.kind, CacheStore.u(j.ref))

    private fun count(sql: String, vararg a: Any?): Long = store.db().query(sql, *a) { it.long(0) ?: 0L }.firstOrNull() ?: 0L

    private fun metaLong(k: String) = store.meta(k)?.toLongOrNull()

    private fun detailPath(plan: Plan, id: Long): String? = plan.detailTemplate?.let { MirrorLogic.fillBytes(it, plan.sentinel, id.toString()) }

    private fun addList(identityOrPath: String, kind: String = "page") {
        val w = MirrorLogic.listWindow(identityOrPath) ?: return
        addJob(pageJob(kind, w.identity, 1))
    }

    /** Seeds a Full refresh: the all-books list, the sections, On device, every list saved, the books on the reader. */
    private fun seed(plan: Plan) {
        plan.allBooks?.let { addList(it) }
        plan.strings("seed_lists").forEach { addList(it) }
        plan.strings("sections").forEach { addList(it) }
        // Every list saved before (the plugin's browsing too): saved again.
        store.db().query("SELECT identity FROM lists") { LuaValue.str(it.text(0)!!) }.forEach { addList(it) }
        val ids = sortedSetOf<Long>()
        ids.addAll(plan.ids("seed_details"))
        // Continue reading and Home's shelves, from the saved Home entries.
        for (body in store.db().query("SELECT body FROM entries WHERE home = 1") { it.bytes(0) }) {
            val b = body?.let { LuaValue.parse(it) } as? Map<*, *> ?: continue
            for (field in listOf("continueReading", "items", "books")) {
                for (x in b[field] as? List<*> ?: emptyList<Any?>()) ((x as? Map<*, *>)?.get("id") as? Long)?.let { ids.add(it) }
            }
        }
        for (id in ids) {
            addJob(Job("detail", id.toString()))
            if (plan.coversOn) addJob(Job("cover", id.toString()))
        }
    }

    /** Refresh's delta: every saved page of every list, rechecked. */
    private fun seedRecheck() {
        for ((identity, total) in store.db().query("SELECT identity, total FROM lists") { LuaValue.str(it.text(0)!!) to (it.long(1) ?: 0L).toInt() }) {
            for (n in 1..MirrorLogic.pageCount(total, null)) addJob(pageJob("recheck", identity, n))
        }
    }

    /** "Save every cover for offline" turned on: the cover of every saved book. */
    private fun seedCovers() {
        store.db().query("SELECT id FROM books WHERE item IS NOT NULL") { it.long(0)!! }.forEach { addJob(Job("cover", it.toString())) }
    }

    /**
     * The work, fixed once the library's size and the section indexes are known: every book's
     * detail (and cover with "Save every cover"), every list a section names, and the pages of the
     * all-books list and the sections. A list longer than one page adds its other pages as it lands.
     */
    private fun estimate(r: Run): Long {
        val plan = r.plan
        val books = plan.allBooks?.let { MirrorLogic.listWindow(it) }?.let { w ->
            store.db().query("SELECT total FROM lists WHERE identity = ?", CacheStore.u(w.identity)) { it.long(0) }.firstOrNull()
        } ?: return 0L
        var est = MirrorLogic.pageCount(books.toInt(), null).toLong() + books + (if (plan.coversOn) books else 0L)
        for (s in plan.strings("sections")) {
            val w = MirrorLogic.listWindow(s) ?: continue
            val n = store.db().query("SELECT total FROM lists WHERE identity = ?", CacheStore.u(w.identity)) { it.long(0) }.firstOrNull() ?: return 0L
            est += MirrorLogic.pageCount(n.toInt(), null) + n
        }
        return est
    }

    private fun shortPath(p: String) = LuaValue.utf8(p).removePrefix("/koreader/plugin/catalog") // orbify:not-a-route: a log line's prefix, not a call

    /** Fetches a job on a pool thread: a page or detail reply, or a cover written to its file. */
    private fun fetch(r: Run, creds: Creds, job: Job): Landed {
        val plan = r.plan
        return when (job.kind) {
            "page", "recheck" -> {
                val path = MirrorLogic.mirrorPage(job.identity, job.page, job.size.takeIf { it != MirrorLogic.PAGE })
                Landed(job, http.get(url(creds, path), headers(creds), null, MAX_BODY), path)
            }
            "detail" -> {
                val path = detailPath(plan, job.id) ?: return Landed(job, Reply(404), null)
                Landed(job, http.get(url(creds, path), headers(creds), null, MAX_BODY), path)
            }
            else -> fetchCover(plan, creds, job)
        }
    }

    /** The cover's book item is read on the writer thread (the pool never touches the database): see [coverJobs]. */
    private val coverItems = java.util.concurrent.ConcurrentHashMap<Long, Map<*, *>>()

    private fun fetchCover(plan: Plan, creds: Creds, job: Job): Landed {
        val book = coverItems.remove(job.id) ?: return Landed(job, null, null, "none")
        val path = coverPath(plan, book) ?: return Landed(job, null, null, "none")
        val f = File(path)
        val etagFile = File("$path.etag")
        val exists = f.isFile
        // A file the plugin saved without an ETag is left alone.
        if (exists && !etagFile.isFile) return Landed(job, null, null, "kept")
        val h = headers(creds, "image/jpeg,image/*").toMutableMap()
        h["Accept-Encoding"] = "identity"
        if (exists) h["If-None-Match"] = etagFile.readText()
        val part = File("$path.part${Thread.currentThread().id}")
        part.parentFile?.mkdirs()
        val rep = http.get(creds.server + "/koreader/plugin/catalog/books/${job.id}/thumbnail", h, part, MAX_COVER)
        return when {
            rep.code == 304 && exists -> { part.delete(); Landed(job, rep, null, "not_modified") }
            rep.code == 200 && rep.contentType?.lowercase()?.trim()?.startsWith("image/") == true && part.isFile && part.length() > 0 && part.renameTo(f) -> {
                if (rep.etag != null) write(etagFile, rep.etag.toByteArray()) else etagFile.delete()
                Landed(job, rep, null, "ok", f.length(), sortedMapOf("id" to job.id, "updatedAt" to book["updatedAt"]?.let { LuaValue.text(it) }))
            }
            rep.code == 0 -> { part.delete(); Landed(job, rep, null, "transport") }
            else -> { part.delete(); Landed(job, rep, null, "failed") }
        }
    }

    /** Saves a landed page or detail and queues what it names. Runs on the writer thread, in its batch's transaction. */
    private fun landPage(r: Run, job: Job, path: String, body: Map<*, *>) {
        val plan = r.plan
        val t = now()
        r.requests++
        if (job.kind == "detail") {
            store.putDetail(job.id, body, t)
            r.details++
            // The next unread book of its series (the reader's neighbour).
            val mine = (body["seriesIndex"] as? Number)?.toDouble() ?: 0.0
            for (m in body["seriesMembers"] as? List<*> ?: emptyList<Any?>()) {
                val sm = m as? Map<*, *> ?: continue
                val id = (sm["id"] as? Long) ?: continue
                if (id != job.id && sm["readStatus"] != "read" && ((sm["seriesIndex"] as? Number)?.toDouble() ?: 0.0) > mine) {
                    addJob(Job("detail", id.toString()))
                    break
                }
            }
            return
        }
        val w = MirrorLogic.listWindow(job.identity) ?: return
        val recheck = job.kind == "recheck"
        val oldTotal = if (job.page == 1) store.db().query("SELECT total FROM lists WHERE identity = ?", CacheStore.u(w.identity)) { it.long(0) }.firstOrNull() else null
        val changed = store.putWindow(w.identity, w.kind, w.section, (job.page - 1) * job.size, body, t)
        r.lists.add(w.identity)
        val total = (body["total"] as? Number)?.toInt() ?: 0
        if (job.page == 1) {
            val pages = MirrorLogic.pageCount(total, job.size)
            if (!recheck || oldTotal?.toInt() != total) for (n in 2..pages) addJob(pageJob(job.kind, w.identity, n, job.size))
            if (recheck && oldTotal != null && oldTotal.toInt() != total) log("mirror: ${shortPath(w.identity)} total $oldTotal -> $total; re-paged")
        }
        val items = body["items"] as? List<*> ?: emptyList<Any?>()
        if (w.kind == "section") {
            val section = w.section ?: return
            for (e in items) {
                val entry = e as? Map<*, *> ?: continue
                MirrorLogic.entryPath(plan.templates, plan.sentinel, section, entry)?.let { addList(it, job.kind) }
            }
        } else if (!recheck || changed) {
            for (b in items) ((b as? Map<*, *>)?.get("id") as? Long)?.let { id ->
                if (!recheck || !store.hasDetail(id)) addJob(Job("detail", id.toString()))
                if (plan.coversOn) addJob(Job("cover", id.toString()))
            }
        }
        if (recheck && changed && r.changed.size < CHANGED_MAX) r.changed.add(w.identity)
    }

    /** The storage limit (counted at the run's start, plus what it saved since). -> the job may not run. */
    private fun limited(r: Run, kind: String, baseCovers: Long): Boolean {
        val limit = r.plan.limit ?: return false
        val covers = kind == "cover"
        if (covers && !r.plan.coversOn) return false
        val used = store.fileBytes() + baseCovers + r.covers[3]
        if (used < limit || r.limitNote != null && !covers) return used >= limit
        val text: String
        if (covers) {
            val n = count("SELECT count(*) FROM jobs WHERE kind = 'cover' AND state = 0")
            store.db().exec("UPDATE jobs SET state = 2 WHERE kind = 'cover' AND state = 0")
            r.skipped += n
            text = MirrorLogic.limitText(true, (r.covers[0] + r.covers[1]).toInt(), r.coverTotal.toInt())
        } else {
            store.db().exec("UPDATE jobs SET state = 2 WHERE state = 0")
            text = MirrorLogic.limitText(false, r.done.toInt(), r.total.toInt())
        }
        r.limitNote = sortedMapOf("text" to text, "at" to now(), "limit" to limit)
        log("mirror: $text")
        return true
    }

    private fun status(r: Run, running: Boolean, why: String? = null): Map<String, Any?> {
        val left = maxOf(0L, r.total - r.done)
        val secs = maxOf(1L, (clockMs() - r.startedMs) / 1000)
        val rate = r.done.toDouble() / secs
        return sortedMapOf(
            "v" to 4L, "runner" to "companion", "run" to r.plan.run, "running" to running.takeIf { it }, "beat" to now(),
            "op" to store.meta("run_op"), "at" to metaLong("full_at"), "lib_version" to store.meta("lib_version"),
            "done" to r.done, "total" to r.total, "left" to left, "pct" to r.pct, "rate" to Math.round(rate * 10) / 10.0,
            "eta_s" to (if (rate > 0 && left > 0) (left / rate).toLong() else null), "skipped" to r.skipped, "errors" to r.errors,
            "covers" to sortedMapOf<String, Any?>("ok" to r.covers[0], "not_modified" to r.covers[1], "failed" to r.covers[2], "bytes" to r.covers[3]),
            "cover_total" to r.coverTotal, "limit_note" to r.limitNote, "revalidating" to (store.meta("run_op") == "revalidate" && running).takeIf { it },
            "bytes" to store.fileBytes(), "started_at" to metaLong("run_started"), "why" to why)
    }

    private fun writeStatus(r: Run, running: Boolean) = write(File(mirrorDir, "status.lua"), LuaValue.encode(status(r, running)))

    /** The run's counts, from the jobs table; the % never goes down and is 100 only at the end. */
    private fun recount(r: Run, finished: Boolean) {
        val rows = store.db().query("SELECT kind, state, count(*) FROM jobs GROUP BY kind, state") { Triple(it.text(0)!!, it.long(1) ?: 0L, it.long(2) ?: 0L) }
        r.total = rows.sumOf { it.third }
        r.done = rows.filter { it.second != 0L }.sumOf { it.third }
        r.coverTotal = rows.filter { it.first == "cover" }.sumOf { it.third }
        if (r.estimate == 0L && store.meta("run_op") == "full") {
            r.estimate = estimate(r)
            if (r.estimate > 0) {
                store.setMeta("run_estimate", r.estimate)
                log("mirror: Full refresh: about ${r.estimate} requests (books, lists and pages, each once)")
            }
        }
        val total = maxOf(r.total, r.estimate)
        val pct = if (finished) 100L else if (total == 0L) 0L else minOf(99L, r.done * 100 / total)
        r.pct = maxOf(r.pct, pct)
        store.setMeta("run_pct", r.pct)
    }

    /**
     * A run. stop: the plugin's mirror/stop file, asked between batches, as are the checks waiting
     * ([yieldTo]: the worker answers them and comes back). Returns when the work is done, stopped
     * or nothing answers.
     */
    fun run(plan: Plan, creds: Creds, yieldTo: () -> Unit = {}): String {
        mirrorDir.mkdirs()
        val st = store
        st.own(plan.owner)
        plan.detailTemplate?.let { st.setMeta("detail_template", it) }
        val r = Run(plan)
        r.startedMs = clockMs()
        val pendingBefore = count("SELECT count(*) FROM jobs WHERE state = 0")
        when (plan.op) {
            "full" -> st.transaction {
                st.db().exec("DELETE FROM jobs")
                st.setMeta("run_op", "full"); st.setMeta("run_started", now()); st.setMeta("run_pct", 0L); st.setMeta("run_estimate", null)
                seed(plan)
            }
            "revalidate" -> {
                if (metaLong("full_at") == null || pendingBefore > 0) {
                    writeStatus(r, false)
                    summary(plan, "busy", r, 0)
                    return "busy"
                }
                st.transaction {
                    st.db().exec("DELETE FROM jobs")
                    st.setMeta("run_op", "revalidate"); st.setMeta("run_started", now()); st.setMeta("run_pct", 0L); st.setMeta("run_estimate", null)
                    seedRecheck()
                }
            }
            "covers" -> st.transaction {
                if (pendingBefore == 0L) { st.db().exec("DELETE FROM jobs"); st.setMeta("run_op", "covers"); st.setMeta("run_started", now()); st.setMeta("run_pct", 0L) }
                seedCovers()
            }
        }
        r.pct = metaLong("run_pct") ?: 0L
        r.estimate = metaLong("run_estimate") ?: 0L
        val baseCovers = if (plan.limit != null) storageItems(plan.coverDir, plan.coversOn).filter { it.k.startsWith("c:") }.sumOf { it.bytes } else 0L
        recount(r, false)
        log("mirror: ${st.meta("run_op")} (${plan.reason}): ${r.total - r.done} jobs to go, $parallel requests at a time")
        writeStatus(r, true)
        val why = pump(r, creds, baseCovers, yieldTo)
        val secs = (clockMs() - r.startedMs) / 1000.0
        recount(r, why == "finished")
        val rate = r.done / maxOf(0.001, secs)
        log(String.format(java.util.Locale.ROOT, "mirror: run %s (%s): %d requests, %d books' details in %.1f s (%.1f items/s, %d at a time); write %d ms a batch (max %d), %d batches",
            plan.run, why, r.requests, r.details, secs, rate, parallel, if (r.batches > 0) r.writeMs / r.batches else 0, r.writeMax, r.batches))
        var saved = false
        var revalidated = false
        if (why == "finished") {
            when (st.meta("run_op")) {
                "full" -> {
                    st.setMeta("full_at", now()); plan.m["lib_version"]?.let { st.setMeta("lib_version", LuaValue.text(it)) }
                    val books = count("SELECT count(*) FROM books")
                    val lists = count("SELECT count(*) FROM lists")
                    log(String.format(java.util.Locale.ROOT, "mirror: Full refresh done: %d books, %d lists, %d jobs in %.0f s (%.1f items/s), %d skipped; " +
                        "covers %d new, %d unchanged (304), %d failed; %.1f MB", books, lists, r.done, secs, rate, r.skipped,
                        r.covers[0], r.covers[1], r.covers[2], st.fileBytes() / MB))
                    saved = true
                }
                "revalidate" -> { log("mirror: Refresh rechecked ${r.done} pages in ${secs.toLong()} s"); revalidated = true }
            }
            st.db().exec("DELETE FROM jobs")
        }
        writeStatus(r, false)
        summary(plan, why, r, r.done, saved, revalidated)
        return why
    }

    /** The pipeline: requests in flight up to [parallel] (covers on their own pool), landed replies written in batches. */
    private fun pump(r: Run, creds: Creds, baseCovers: Long, yieldTo: () -> Unit): String {
        val st = store
        val pool = Executors.newFixedThreadPool(maxOf(1, parallel)) { x -> Thread(x, "orbit-cache-fetch").also { it.isDaemon = true } }
        val coverPool = Executors.newFixedThreadPool(COVER_PARALLEL) { x -> Thread(x, "orbit-cache-cover").also { it.isDaemon = true } }
        val landed = LinkedBlockingQueue<Landed>()
        val inFlight = HashSet<Job>()
        val notBefore = HashMap<Job, Long>()
        var transport = 0
        var statusAt = 0L
        var loggedAt = clockMs()
        var why = "finished"
        try {
            while (true) {
                if (File(mirrorDir, "stop").isFile) { why = "stopped"; break }
                yieldTo()
                // Refill: the next jobs by kind (lists first), those not in flight and not waiting to retry.
                // AHEAD times the pool's size queued, so the pools never wait while the writer writes.
                val reqSlots = parallel * AHEAD - inFlight.count { it.kind != "cover" }
                val coverSlots = COVER_PARALLEL * AHEAD - inFlight.count { it.kind == "cover" }
                if (reqSlots > 0 || coverSlots > 0) {
                    val tnow = clockMs()
                    // Requests (lists first) and covers each from their own end of the queue: covers run
                    // alongside the details, not after them.
                    val skip = (inFlight.size + notBefore.size).toLong()
                    val next = st.db().query("SELECT kind, ref FROM jobs WHERE state = 0 AND kind <> 'cover' ORDER BY CASE kind WHEN 'page' THEN 0 WHEN 'recheck' THEN 1 ELSE 2 END LIMIT ?",
                        skip + parallel * AHEAD) { Job(it.text(0)!!, LuaValue.str(it.text(1)!!)) } +
                        st.db().query("SELECT kind, ref FROM jobs WHERE state = 0 AND kind = 'cover' LIMIT ?", skip + COVER_PARALLEL * AHEAD) { Job(it.text(0)!!, LuaValue.str(it.text(1)!!)) }
                    var rs = reqSlots
                    var cs = coverSlots
                    for (j in next) {
                        if (j in inFlight || (notBefore[j] ?: 0L) > tnow) continue
                        if (j.kind == "cover") {
                            if (cs <= 0) continue
                            if (limited(r, "cover", baseCovers)) continue
                            // The book's list item names its cover (else its detail); a book not saved yet waits for the lists.
                            val item = (st.bookItem(j.id) ?: st.detail(j.id)?.first) as? Map<*, *>
                            if (item == null) {
                                if (inFlight.any { it.kind != "cover" } || count("SELECT count(*) FROM jobs WHERE state = 0 AND kind <> 'cover'") > 0) continue
                                st.db().exec("UPDATE jobs SET state = 2 WHERE kind = 'cover' AND ref = ?", CacheStore.u(j.ref)); continue
                            }
                            coverItems[j.id] = item
                            cs--
                            inFlight.add(j); coverPool.submit { landed.put(try { fetch(r, creds, j) } catch (e: Exception) { Landed(j, Reply(0, err = e.javaClass.simpleName), null, "transport") }) }
                        } else {
                            if (rs <= 0) continue
                            if (limited(r, j.kind, baseCovers)) break
                            rs--
                            inFlight.add(j); pool.submit { landed.put(try { fetch(r, creds, j) } catch (e: Exception) { Landed(j, Reply(0, err = e.javaClass.simpleName), null) }) }
                        }
                    }
                }
                if (inFlight.isEmpty()) {
                    // Only retries left: wait for the first of them.
                    if (count("SELECT count(*) FROM jobs WHERE state = 0") == 0L) break
                    val first = notBefore.values.minOrNull() ?: break
                    sleep(maxOf(1L, (first - clockMs() + 999) / 1000).toInt())
                    continue
                }
                // Land a batch: the first reply waits, then what lands within BATCH_MS joins it (up to
                // BATCH): one commit for many replies (a commit on shared storage costs milliseconds),
                // while the pool keeps fetching from the jobs queued ahead.
                val batch = ArrayList<Landed>()
                landed.poll(30, TimeUnit.SECONDS)?.let { batch.add(it) } ?: continue
                val until = clockMs() + BATCH_MS
                while (batch.size < BATCH && batch.size < inFlight.size) {
                    landed.drainTo(batch, BATCH - batch.size)
                    if (batch.size >= BATCH || batch.size >= inFlight.size) break
                    val wait = until - clockMs()
                    if (wait <= 0) break
                    landed.poll(wait, TimeUnit.MILLISECONDS)?.let { batch.add(it) } ?: break
                }
                val t0 = clockMs()
                var allTransport = true
                st.transaction {
                    for (l in batch) {
                        inFlight.remove(l.job)
                        val j = l.job
                        val ref = CacheStore.u(j.ref)
                        if (j.kind == "cover") {
                            when (l.cover) {
                                "ok" -> { r.covers[0]++; r.covers[3] += l.coverBytes; l.coverWritten?.let { if (r.written.size < WRITTEN_MAX) r.written.add(it) else r.writtenMore = true } }
                                "not_modified" -> r.covers[1]++
                                "failed", "transport" -> r.covers[2]++
                            }
                            if (l.cover != "transport") allTransport = false
                            // "Save every cover": the pruner keeps this file.
                            if (r.plan.coversOn && l.cover in setOf("ok", "not_modified", "kept")) (st.bookItem(j.id) as? Map<*, *>)?.let { coverName(it) }
                                ?.let { st.db().exec("INSERT OR IGNORE INTO cover_keep (name) VALUES (?)", it) }
                            st.db().exec("UPDATE jobs SET state = 1 WHERE kind = ? AND ref = ?", j.kind, ref)
                            continue
                        }
                        val rep = l.reply
                        val body = if (rep != null && rep.code == 200 && rep.body != null) try { LuaValue.fromJson(String(rep.body, Charsets.UTF_8)) } catch (e: Exception) { null } else null
                        if (body is Map<*, *> && l.path != null) {
                            allTransport = false
                            notBefore.remove(j)
                            st.db().exec("UPDATE jobs SET state = 1 WHERE kind = ? AND ref = ?", j.kind, ref)
                            try { landPage(r, j, l.path, body) } catch (e: Exception) { r.errors++; log("mirror: step failed: $e") }
                            continue
                        }
                        val status = rep?.code?.takeIf { it in 1..499 }
                        if (status != null) allTransport = false
                        val tries = (st.db().query("SELECT tries FROM jobs WHERE kind = ? AND ref = ?", j.kind, ref) { it.long(0) ?: 0L }.firstOrNull() ?: 0L) + 1
                        val p = l.path?.let { shortPath(it) } ?: j.ref
                        val whyFail = rep?.err ?: rep?.code?.takeIf { it != 0 }?.toString() ?: "no answer"
                        val retry = if (status != null) MirrorLogic.Retry(true) else MirrorLogic.retry(tries.toInt(), if (j.kind == "page" || j.kind == "recheck") j.size else null, if (j.kind == "detail") null else j.page)
                        if (retry.skip) {
                            log("mirror: $p skipped after $tries tries ($whyFail); the rest continues")
                            r.skipped++
                            notBefore.remove(j)
                            st.db().exec("UPDATE jobs SET state = 2, tries = ? WHERE kind = ? AND ref = ?", tries, j.kind, ref)
                        } else if ((j.kind == "page" || j.kind == "recheck") && retry.size != null && retry.size != j.size) {
                            // A list's first page the server is slow to give by 100: in smaller pages.
                            log("mirror: $p failed ($whyFail), try $tries of ${MirrorLogic.TRIES}; again in ${retry.waitS}s, in pages of ${retry.size}")
                            notBefore.remove(j)
                            st.db().exec("UPDATE jobs SET state = 2 WHERE kind = ? AND ref = ?", j.kind, ref)
                            val smaller = pageJob(j.kind, j.identity, 1, retry.size)
                            addJob(smaller)
                            st.db().exec("UPDATE jobs SET tries = ? WHERE kind = ? AND ref = ?", tries, smaller.kind, CacheStore.u(smaller.ref))
                            notBefore[smaller] = clockMs() + retry.waitS * 1000L
                        } else {
                            log("mirror: $p failed ($whyFail), try $tries of ${MirrorLogic.TRIES}; again in ${retry.waitS}s")
                            st.db().exec("UPDATE jobs SET tries = ? WHERE kind = ? AND ref = ?", tries, j.kind, ref)
                            notBefore[j] = clockMs() + retry.waitS * 1000L
                        }
                    }
                }
                val ms = clockMs() - t0
                r.batches++; r.writeMs += ms; r.writeMax = maxOf(r.writeMax, ms)
                recount(r, false)
                transport = if (allTransport) transport + batch.size else 0
                if (transport >= maxOf(4, parallel * 2)) { why = "no answer"; break }
                if (clockMs() - statusAt >= STATUS_EVERY_MS) { writeStatus(r, true); statusAt = clockMs() }
                if (clockMs() - loggedAt >= PROGRESS_EVERY_MS) {
                    loggedAt = clockMs()
                    val secs = maxOf(0.001, (clockMs() - r.startedMs) / 1000.0)
                    val rate = r.done / secs
                    val left = maxOf(0L, maxOf(r.total, r.estimate) - r.done)
                    log(String.format(java.util.Locale.ROOT, "mirror: %d/%d (%d%%) · %.1f items/s · write %d ms/batch (max %d) · ETA %s",
                        r.done, maxOf(r.total, r.estimate), r.pct, rate, if (r.batches > 0) r.writeMs / r.batches else 0, r.writeMax,
                        if (rate > 0) "${(left / rate / 60).toLong()} min ${((left / rate) % 60).toLong()} s" else "?"))
                }
            }
        } finally {
            pool.shutdownNow()
            coverPool.shutdownNow()
            coverItems.clear()
        }
        // Replies still in flight when it stopped: their jobs stay pending for the next run.
        return why
    }

    private fun summary(plan: Plan, why: String, r: Run, jobs: Long, saved: Boolean = false, revalidated: Boolean = false) {
        write(File(mirrorDir, "summary.lua"), LuaValue.encode(sortedMapOf<String, Any?>(
            "run" to plan.run, "why" to why, "jobs" to jobs, "status" to status(r, false, why),
            "changed" to r.changed.toList(), "written" to r.written.toList(), "written_more" to r.writtenMore.takeIf { it },
            "saved" to saved.takeIf { it }, "revalidated" to revalidated.takeIf { it },
            "cover_bytes_delta" to r.covers[3])))
    }

    companion object {
        /** The cache's files before the database (0.11.x), removed at the first open. */
        val OLD_FILES = setOf("index.lua", "storage.lua", "worker-state.lua", "cover_keep.lua")
        /** Requests in flight at once: tuned with the stage 0 kit (docs/design/sqlite-cache.md "Speed"). */
        const val PARALLEL = 6
        const val COVER_PARALLEL = 4
        /** Landed replies written in one transaction, at most (or what landed within BATCH_MS). */
        const val BATCH = 100
        const val BATCH_MS = 250L
        /** Jobs queued per pool thread (a batch's write must not starve the pools). */
        const val AHEAD = 4
        const val CHANGED_MAX = 50
        const val WRITTEN_MAX = 100
        const val STATUS_EVERY_MS = 2000L
        const val PROGRESS_EVERY_MS = 10_000L
        const val MAX_BODY = 32L * 1024 * 1024
        const val MAX_COVER = 4L * 1024 * 1024
        const val MB = 1048576.0
    }
}
