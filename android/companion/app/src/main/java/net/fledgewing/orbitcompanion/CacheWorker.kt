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
 * (the all-books list and the sections' first pages). Requests and covers share one fetcher; one thread writes the landed replies, up to [BATCH] per transaction.
 *
 * Plain JVM ([Sql] and an [Http] port), so the unit tests run it against a fake server and JDBC.
 */
class CacheWorker(
    val root: File,
    private val http: Http,
    private val now: () -> Long = { System.currentTimeMillis() / 1000 },
    private val log: (String) -> Unit = { OLog.i(it) },
    private val sleep: (Int) -> Unit = { Thread.sleep(it * 1000L) },
    /** Queue capacity, capped at [PARALLEL] even for callers requesting the former high fan-out. */
    parallel: Int = PARALLEL,
    private val openSql: (File) -> Sql = { AndroidSql(it) },
    private val clockMs: () -> Long = { System.currentTimeMillis() },
    /** The run's % (never down; 100 at the end), each time the status is written; null when it ends. */
    private val onProgress: (Long?) -> Unit = {},
    /** The folders a command may touch files in ([Places]); a path outside them is refused. */
    private val places: List<File> = listOf(root),
    private val resizeThumbnail: (File, Int, Int) -> Unit = { _, _, _ -> },
    private val checkpoint: () -> Unit = {},
    private val decodeJson: (String) -> Any? = LuaValue::fromJson,
    private val cpuMs: () -> Long = { 0L },
    private val threadFactory: (String, Runnable) -> Thread = { name, task -> Thread(task, name).apply { isDaemon = true; priority = Thread.MIN_PRIORITY } },
) {
    private val parallel = parallel.coerceIn(1, PARALLEL)

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

    private var thumbnailWidth = 0
    private var thumbnailHeight = 0
    private var runProtected = emptySet<Long>()
    private fun thumbnail(f: File) {
        if (!f.path.contains("/orbit-sleep/")) { checkpoint(); resizeThumbnail(f, thumbnailWidth, thumbnailHeight) }
    }

    // ------------------------------------------------------------------ files

    private fun write(f: File, bytes: ByteArray): Boolean {
        f.parentFile?.let(NoMedia::directory)
        val tmp = File(f.parentFile, f.name + ".tmp" + (Math.random() * 1e9).toLong())
        return try {
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(f)) { tmp.delete(); false } else true
        } catch (e: Exception) {
            tmp.delete(); false
        }
    }

    private fun read(f: File): Any? = if (f.isFile) LuaValue.parse(f.readBytes()) else null

    /** A path a command named, resolved, when it lies in [places]; else null (refused). */
    private fun allowed(path: String?): File? = Places.inside(path, places)

    /**
     * The files of the cache before the database (0.11.x): entries, the index, the mirror's pages
     * and queue. No backwards compatibility: they go, and the next Full refresh saves everything.
     */
    private fun removeOldFiles() {
        SqliteStress.cleanup(root)
        var n = 0
        val entry = Regex("^[0-9a-f]{8}\\.lua$")
        for (dir in listOf(root, mirrorDir)) for (f in dir.listFiles() ?: emptyArray()) {
            checkpoint()
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
        val reply = try { decodeJson(String(r.body, Charsets.UTF_8)) } catch (e: Exception) { null }
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
        if (wipe) { store.wipe("the plugin asked"); eventsDir.listFiles()?.forEach { it.delete() }; File(root, "events-batch.lua").delete(); return }
        val n = store.patch(id, fields, staleHome)
        if (n > 0) log("store: a write patched $n saved replies")
    }

    private class CoverUsage(items: List<StorageLogic.Item>) {
        private val sizes = HashMap(items.filter { it.k.startsWith("c:") }.associate { it.k to it.bytes })
        private var bytes = sizes.values.sum()
        @Synchronized fun replace(key: String, size: Long) { bytes += size - (sizes.put(key, size) ?: 0L) }
        @Synchronized fun total(): Long = bytes
    }
    @Volatile private var coverUsage: CoverUsage? = null

    // ------------------------------------------------------------------ the storage limit

    /** The plugin's STORAGE: count, and over [limit] remove (StorageLogic). [mirrorCovers]: "Save every cover" is on. */
    data class StorageAsk(val reason: String, val limit: Long?, val coverDir: String?, val mirrorCovers: Boolean)

    /** Everything Orbit stores: the database (browsing entries apart, as they can go) and the cover folder's files. */
    fun storageItems(coverDir: String?, mirrorCovers: Boolean): List<StorageLogic.Item> {
        checkpoint()
        val st = store
        SqliteStress.cleanup(root)
        val entries = st.entrySizes()
        val items = ArrayList<StorageLogic.Item>(entries)
        items.add(StorageLogic.Item("db", maxOf(0L, st.fileBytes() - entries.sumOf { it.bytes }), 0L, "kept"))
        val dir = allowed(coverDir)
        if (coverDir != null && dir == null) log("storage: cover folder outside Orbit's folders; not counted")
        if (dir != null && dir.isDirectory) {
            val protected = protectedIds()
            val keep = if (mirrorCovers) st.coversKept() else emptySet()
            for (f in dir.listFiles() ?: emptyArray()) {
                checkpoint()
                if (f.name.endsWith(".etag") && !File(f.path.removeSuffix(".etag")).isFile) { f.delete(); continue }
                if (!f.name.endsWith(".jpg") || !f.isFile || allowed(f.path) == null) continue
                val etag = File(dir, f.name + ".etag")
                items.add(StorageLogic.Item("c:${f.name}", f.length() + (if (etag.isFile) etag.length() else 0L), f.lastModified() / 1000,
                    if (f.name.substringBefore('_').toLongOrNull() in protected) "kept" else if (f.name in keep) "mirror_cover" else "cover"))
            }
        }
        return items
    }

    private fun protectedIds(): Set<Long> {
        val ids = HashSet<Long>(runProtected)
        val copies = read(File(root, "copies/ask.lua")) as? Map<*, *>
        (copies?.get("books") as? List<*>)?.forEach { ((it as? Map<*, *>)?.get("book_id") as? Long)?.let(ids::add) }
        val plan = read(File(mirrorDir, "plan.lua")) as? Map<*, *>
        (plan?.get("seed_details") as? List<*>)?.filterIsInstance<Long>()?.let(ids::addAll)
        store.db().query("SELECT body FROM entries WHERE home = 1") { it.bytes(0) }.forEach { bytes ->
            val home = bytes?.let { LuaValue.parse(it) } as? Map<*, *>
            (home?.get("continueReading") as? List<*>)?.forEach { ((it as? Map<*, *>)?.get("id") as? Long)?.let(ids::add) }
        }
        val pool = File(root.parentFile, "orbit-sleep/pool.json")
        val model = runCatching { decodeJson(pool.readText()) as? Map<*, *> }.getOrNull()
        (model?.get("items") as? List<*>)?.forEach { ((it as? Map<*, *>)?.get("id") as? Long)?.let(ids::add) }
        return ids
    }

    /**
     * Counts, and over the limit removes browsing entries and covers itself. Answers with
     * { kind = "storage", why, totals, removed = { cache, cover, mirror_cover }, used, after, limit };
     * the totals are also kept in the database (meta "storage") for the plugin's start.
     */
    fun storage(a: StorageAsk) {
        val items = storageItems(a.coverDir, a.mirrorCovers)
        val coverDir = allowed(a.coverDir)
        val plan = StorageLogic.plan(items, a.limit)
        val byK = items.associateBy { it.k }
        val removed = sortedMapOf("cache" to 0L, "cover" to 0L, "mirror_cover" to 0L)
        checkpoint()
        store.transaction {
            for (k in plan.drop) {
                val it = byK[k] ?: continue
                if (k.startsWith("e:")) store.dropEntry(k.removePrefix("e:"))
                else if (k.startsWith("c:") && coverDir != null) {
                    allowed(File(coverDir, k.removePrefix("c:")).path)?.delete()
                    allowed(File(coverDir, k.removePrefix("c:") + ".etag").path)?.delete()
                    allowed(File(coverDir, ".thumbnails/" + k.removePrefix("c:") + ".done").path)?.delete()
                    val f = File(coverDir, k.removePrefix("c:"))
                    val etag = File(f.path + ".etag")
                    coverUsage?.replace(k, f.length() + etag.length())
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

    fun coversShown(paths: List<String>) {
        for (path in paths.take(100)) {
            val f = allowed(path) ?: continue
            if (!f.name.endsWith(".jpg") || !f.isFile) continue
            f.setLastModified(now() * 1000)
            coverUsage?.replace("c:${f.name}", f.length() + File(f.path + ".etag").length())
        }
    }

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
        for ((id, asked) in items) {
            checkpoint()
            val f = allowed(asked)
            if (f == null) { failed++; continue }
            val path = f.path
            val etagFile = allowed("$path.etag") ?: run { failed++; null } ?: continue
            if (!f.isFile || !etagFile.isFile) continue
            val h = headers(creds, "image/jpeg,image/*").toMutableMap()
            h["Accept-Encoding"] = "identity"
            h["If-None-Match"] = etagFile.readText()
            val part = allowed("$path.part") ?: run { failed++; null } ?: continue
            part.delete()
            val r = http.get(creds.server + "/koreader/plugin/catalog/books/$id/thumbnail", h, part, MAX_COVER)
            when {
                r.code == 304 -> { part.delete(); thumbnail(f) }
                r.code == 200 && r.contentType?.lowercase()?.trim()?.startsWith("image/") == true && part.isFile && part.length() > 0 && part.renameTo(f) -> {
                    thumbnail(f)
                    if (r.etag != null) write(etagFile, r.etag.toByteArray()) else etagFile.delete()
                    changed.add(id)
                }
                else -> { part.delete(); failed++ }
            }
            coverUsage?.replace("c:${f.name}", f.length() + etagFile.length())
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
        checkpoint()
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
            checkpoint()
            val saved = store.detail(id.toLong()) ?: store.bookItem(id.toLong())?.let { it to (store.db().query("SELECT item_at FROM books WHERE id=?", id.toLong()) { row -> row.long(0) ?: 0L }.firstOrNull() ?: 0L) } ?: continue
            val (body, at) = saved
            val files = (body as? Map<*, *>)?.get("files") as? List<*> ?: continue
            if (CopiesLogic.newer(details[id], at)) details[id] = CopiesLogic.Detail(files, at)
        }
        val found = CopiesLogic.candidates(books, details)
        val present = found.filter { File(LuaValue.utf8(it["path"] as String)).isFile }
        event(sortedMapOf("kind" to "copies", "why" to why, "checked" to books.size.toLong(), "found" to present,
            "gone" to (found.size - present.size).toLong()))
    }

    /** Acknowledged mailbox; listing/parsing event files belongs to this worker only. */
    private val mailbox by lazy { EventMailbox(root, checkpoint) }
    fun drainEvents(ack: String?) = mailbox.publish(ack)

    private var eventSeq = 0

    /** An answer for the plugin in events/ (it drains them while it waits for one). */
    fun event(ev: Map<String, Any?>) {
        eventSeq++
        write(File(eventsDir, "${now()}-0-c$eventSeq.lua"), LuaValue.encode(ev))
        drainEvents(null)
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

    /** KOReader's BookOrbit plugin's cover file name (shared/fixtures/cache/worker.json "covers"). */
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
        val dir = allowed(plan.coverDir)?.path ?: return null
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
    private class Landed(val job: Job, val reply: Reply?, val path: String?, val cover: String? = null, val coverBytes: Long = 0, val coverWritten: Map<String, Any?>? = null, val part: File? = null, val target: File? = null)

    /** The run's counters, in memory; the jobs table is the durable part. */
    private class Run(val plan: Plan) {
        var done = 0L; var total = 0L; var skipped = 0L; var requests = 0L; var pct = 0L; var estimate = 0L
        var covers = longArrayOf(0, 0, 0, 0) // ok, not modified, failed, bytes
        var coverTotal = 0L
        var startedMs = 0L; var batches = 0L; var writeMs = 0L; var writeMax = 0L
        var limitNote: Map<String, Any?>? = null
        var storageBlocked = false
        var errors = 0L
        val changed = ArrayList<String>()
        val written = ArrayList<Map<String, Any?>>()
        var writtenMore = false
        var details = 0L
        val fetchCpu = java.util.concurrent.atomic.AtomicLong()
        var parseCpu = 0L; var writeCpu = 0L
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
        plan.strings("browse_lists").forEach { addList(it) }
        seedDynamic(plan, false)
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

    /** Home replies and every page of volatile shelves, including lists never opened before. */
    private fun seedDynamic(plan: Plan, recheck: Boolean) {
        plan.strings("entries").forEach { addJob(Job("entry", it)) }
        for (path in plan.strings("dynamic_lists")) {
            val w = MirrorLogic.listWindow(path) ?: continue
            val total = store.db().query("SELECT total FROM lists WHERE identity = ?", CacheStore.u(w.identity)) { it.long(0) }.firstOrNull() ?: 0L
            for (page in 1..MirrorLogic.pageCount(total.toInt(), null)) addJob(pageJob(if (recheck) "recheck" else "page", w.identity, page))
        }
    }

    /** Expand using fresh indexes, never on KOReader's UI thread. Jobs deduplicate identities.
     * Recheck queues all existing pages, even when membership moves without changing the total. */
    private fun seedCatalogVariants(r: Run, recheck: Boolean, yieldTo: () -> Unit): Boolean {
        val plan = r.plan
        if (plan.m["catalog"] !is Map<*, *>) return true
        val catalog = CatalogPlan(plan)
        val libraries = ArrayList<String>()
        val bases = linkedSetOf<String>()
        plan.allBooks?.let(bases::add)
        bases.addAll(plan.strings("seed_lists"))
        bases.addAll(plan.strings("browse_lists"))
        val entries = store.db().query("SELECT DISTINCT l.section, li.item FROM lists l JOIN list_items li ON l.identity = li.identity WHERE l.kind = 'section'") {
            it.text(0) to it.bytes(1)
        }
        for ((section, bytes) in entries) {
            val entry = bytes?.let { LuaValue.parse(it) } as? Map<*, *> ?: continue
            if (section == "libraries") entry["id"]?.let { libraries.add(LuaValue.text(it)) }
            if (section != null) MirrorLogic.entryPath(plan.templates, plan.sentinel, section, entry)?.let(bases::add)
        }
        val device = plan.strings("seed_lists").map { MirrorLogic.parseQuery(MirrorLogic.splitPath(it).second)["ids"] }.firstOrNull { it != null }
        // Not on device walks at most 500 recent items and takes the first 200 absent ids.
        val deviceSet = plan.ids("seed_details").toSet()
        val recentIdentity = plan.strings("dynamic_lists").firstOrNull {
            val q = MirrorLogic.parseQuery(MirrorLogic.splitPath(it).second)
            q["sort"] == "recently_added" && q["readStatus"] == null
        }?.let { MirrorLogic.listWindow(it)?.identity }
        val recentItems = recentIdentity?.let { store.window(it, 1, catalog.recentScanSize, null)?.get("items") as? List<*> }.orEmpty()
        val recent = recentItems.mapNotNull { (it as? Map<*, *>)?.get("id") as? Long }.filter { it !in deviceSet }.take(catalog.absentLimit)
        if (recent.isNotEmpty()) bases.add("/koreader/plugin/catalog/books?ids=${recent.joinToString(",")}&sort=recently_added&order=desc")
        val batch = ArrayList<Job>()
        var statusAt = clockMs()
        fun flush() {
            if (batch.isNotEmpty()) { store.transaction { batch.forEach(::addJob) }; batch.clear() }
            if (clockMs() - statusAt >= STATUS_EVERY_MS) { recount(r, false); writeStatus(r, true); statusAt = clockMs() }
            yieldTo()
        }
        fun queue(path: String) {
            val w = MirrorLogic.listWindow(path) ?: return
            val known = if (recheck) store.db().query("SELECT total FROM lists WHERE identity = ?", CacheStore.u(w.identity)) { it.long(0) }.firstOrNull() else null
            if (recheck && known != null && !CatalogPlan.dynamic(w.identity)) return
            val total = known ?: 0L
            for (page in 1..MirrorLogic.pageCount(total.toInt(), null)) {
                batch.add(pageJob(if (recheck) "recheck" else "page", w.identity, page))
                if (batch.size >= 500) flush()
            }
        }
        val paths = catalog.sectionPaths() + bases.asSequence().distinctBy(CatalogPlan::scope).flatMap { catalog.bookPaths(it, libraries.distinct(), device) }
        for (path in paths) {
            if (File(mirrorDir, "stop").isFile) { flush(); return false }
            queue(path)
        }
        flush()
        return true
    }

    /** Refresh's delta: every saved page of every list, rechecked. */
    private fun seedRecheck() {
        for ((identity, total) in store.db().query("SELECT identity, total FROM lists") { LuaValue.str(it.text(0)!!) to (it.long(1) ?: 0L).toInt() }) {
            for (n in 1..MirrorLogic.pageCount(total, null)) addJob(pageJob("recheck", identity, n))
        }
    }

    /** No server-side since/ETag exists. Walk newest first, stopping below the saved
     * watermark; include its entire timestamp tie. Fetch details only for changed items.
     * Membership replies have no version, so recheck saved list pages when a book changed.
     * No network or parsing happens inside a write transaction. */
    private fun newestStamp(): String? = store.db().query("SELECT item FROM books WHERE item IS NOT NULL") { it.bytes(0) }
            .mapNotNull { (it?.let { b -> LuaValue.parse(b) } as? Map<*, *>)?.get("updatedAt")?.let { v -> LuaValue.text(v) } }
            .maxOrNull()

    private fun seedIncremental(r: Run, creds: Creds): Long {
        val plan = r.plan
        if (plan.m["catalog"] is Map<*, *>) plan.strings("sections").forEach { addList(it, "recheck") }
        seedDynamic(plan, true)
        val newest = store.meta("incremental_watermark") ?: newestStamp() ?: return 0L
        var target = newest
        var page = 1
        var changed = store.meta("incremental_lists_dirty") != null || plan.m["lib_version"]?.let { LuaValue.text(it) != store.meta("lib_version") } == true
        val base = "/koreader/plugin/catalog/books?order=desc&sort=recently_updated"
        while (!File(mirrorDir, "stop").exists()) {
            val path = MirrorLogic.mirrorPage(base, page, 100)
            val reply = http.get(url(creds, path), headers(creds), null, MAX_BODY)
            check(reply.code == 200) { "incremental scan unavailable" }
            val body = reply.body?.let { decodeJson(String(it, Charsets.UTF_8)) } as? Map<*, *> ?: error("incremental scan invalid")
            val items = body["items"] as? List<*> ?: error("incremental items missing")
            var older = false
            for (v in items) {
                val item = v as? Map<*, *> ?: continue
                val id = item["id"] as? Long ?: continue
                val stamp = item["updatedAt"]?.let { LuaValue.text(it) } ?: continue
                if (stamp > target) target = stamp
                if (stamp < newest) { older = true; continue }
                if (LuaValue.changed(store.bookItem(id), item) || !store.hasDetail(id) || store.meta("incremental_dirty_$id") != null) {
                    changed = true
                    store.transaction {
                        for (identity in store.db().query("SELECT DISTINCT identity FROM list_items WHERE book_id = ?", id) { LuaValue.str(it.text(0)!!) }) {
                            if (r.changed.size < CHANGED_MAX && identity !in r.changed) r.changed.add(identity)
                        }
                        store.putItem(item, now())
                        store.setMeta("incremental_dirty_$id", true)
                        store.setMeta("incremental_lists_dirty", true)
                        addJob(Job("detail", id.toString()))
                        if (plan.coversOn) addJob(Job("cover", id.toString()))
                    }
                }
            }
            if (older || page * 100 >= ((body["total"] as? Number)?.toInt() ?: 0) || items.isEmpty()) break
            page++
        }
        check(!File(mirrorDir, "stop").exists()) { "incremental scan stopped" }
        if (changed) seedRecheck()
        store.setMeta("incremental_target", target)
        store.setMeta("incremental_scan_complete", true)
        log("mirror: incremental checked $page newest pages; changed books only queued for details")
        return page.toLong()
    }

    /** "Save every cover for offline" turned on: the cover of every saved book. */
    private fun seedCovers() {
        store.db().query(if (store.meta("bulk_active") != null) "SELECT id FROM bulk_books WHERE g=" + store.meta("bulk_active")!!.toLong() else "SELECT id FROM books WHERE item IS NOT NULL") { it.long(0)!! }.forEach { addJob(Job("cover", it.toString())) }
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
        checkpoint()
        val start = cpuMs()
        try { return fetchJob(r, creds, job) } finally { r.fetchCpu.addAndGet(cpuMs() - start) }
    }

    private fun fetchJob(r: Run, creds: Creds, job: Job): Landed {
        val plan = r.plan
        return when (job.kind) {
            "entry" -> Landed(job, http.get(url(creds, job.ref), headers(creds), null, MAX_BODY), job.ref)
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
        val f = allowed(path) ?: return Landed(job, null, null, "none")
        val etagFile = allowed("$path.etag") ?: return Landed(job, null, null, "none")
        val exists = f.isFile
        // A file the plugin saved without an ETag is left alone.
        if (exists && !etagFile.isFile) return Landed(job, null, null, "kept", target = f)
        val h = headers(creds, "image/jpeg,image/*").toMutableMap()
        h["Accept-Encoding"] = "identity"
        if (exists) h["If-None-Match"] = etagFile.readText()
        val part = allowed("$path.part${Thread.currentThread().id}") ?: return Landed(job, null, null, "none")
        part.parentFile?.let(NoMedia::directory)
        part.delete()
        val rep = http.get(creds.server + "/koreader/plugin/catalog/books/${job.id}/thumbnail", h, part, MAX_COVER)
        if (Thread.currentThread().isInterrupted) { part.delete(); return Landed(job, rep, null, "transport") }
        return when {
            rep.code == 304 && exists -> { part.delete(); Landed(job, rep, null, "not_modified", target = f) }
            rep.code == 200 && rep.contentType?.lowercase()?.trim()?.startsWith("image/") == true && part.isFile && part.length() > 0 -> {
                thumbnail(part)
                Landed(job, rep, null, "ok", part.length(), sortedMapOf("id" to job.id, "updatedAt" to book["updatedAt"]?.let { LuaValue.text(it) }), part, f)
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
        if (job.kind == "entry") {
            val account = plan.owner
            val server = plan.owner.substringAfter('|')
            store.putEntry(MirrorLogic.key(account, server, path), path, body, t)
            return
        }
        if (job.kind == "detail") {
            store.putDetail(job.id, body, t)
            store.setMeta("incremental_dirty_${job.id}", null)
            r.details++
            // The next unread book of its series (the reader's neighbour).
            val mine = (body["seriesIndex"] as? Number)?.toDouble() ?: 0.0
            for (m in body["seriesMembers"] as? List<*> ?: emptyList<Any?>()) {
                val sm = m as? Map<*, *> ?: continue
                val id = (sm["id"] as? Long) ?: continue
                if ((store.meta("run_op") == "full" || !store.hasDetail(id)) && id != job.id && sm["readStatus"] != "read" && ((sm["seriesIndex"] as? Number)?.toDouble() ?: 0.0) > mine) {
                    addJob(Job("detail", id.toString()))
                    break
                }
            }
            return
        }
        val w = MirrorLogic.listWindow(job.identity) ?: return
        val recheck = job.kind == "recheck"
        val oldTotal = if (job.page == 1) store.db().query("SELECT total FROM lists WHERE identity = ?", CacheStore.u(w.identity)) { it.long(0) }.firstOrNull() else null
        val changedBooks = if (recheck && w.kind == "books") (body["items"] as? List<*> ?: emptyList<Any?>()).mapNotNull { b ->
            val item = b as? Map<*, *> ?: return@mapNotNull null
            val id = item["id"] as? Long ?: return@mapNotNull null
            id.takeIf { !store.hasDetail(id) || LuaValue.changed(store.bookItem(id), item) }
        }.toSet() else emptySet()
        val changed = store.putWindow(w.identity, w.kind, w.section, (job.page - 1) * job.size, body, t)
        val total = (body["total"] as? Number)?.toInt() ?: 0
        if (job.page == 1) {
            val pages = MirrorLogic.pageCount(total, job.size)
            for (n in 2..pages) addJob(pageJob(job.kind, w.identity, n, job.size))
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
                if (!recheck || id in changedBooks) addJob(Job("detail", id.toString()))
                if (plan.coversOn && (!recheck || id in changedBooks)) addJob(Job("cover", id.toString()))
            }
        }
        if (recheck && changed && r.changed.size < CHANGED_MAX) r.changed.add(w.identity)
    }

    /** Committed bytes plus net growth, never the transient rollback journal's duplicate pages. */
    private fun room(r: Run, growth: Long, covers: Boolean, databaseBytes: Long): Boolean {
        val limit = r.plan.limit ?: return true
        if (growth <= 0) return true
        var used = databaseBytes + (coverUsage?.total() ?: 0L)
        if (!covers && used + growth > limit) {
            // Saved list/book data wins over every eligible cover, in last-shown order.
            val items = storageItems(r.plan.coverDir, r.plan.coversOn)
            // Try every eligible candidate: an undeletable file must not hide later candidates.
            val candidates = StorageLogic.evictableCovers(items)
            for (item in candidates) {
                if (used + growth <= limit) break
                val f = allowed(r.plan.coverDir)?.let { File(it, item.k.removePrefix("c:")) } ?: continue
                if (!f.delete()) continue
                File(f.path + ".etag").delete()
                coverUsage?.replace(item.k, 0)
                used = databaseBytes + (coverUsage?.total() ?: 0L)
                log("storage: evicted cover for list/book data (${item.bytes} bytes)")
            }
        }
        if (used + growth <= limit) return true
        if (!covers) r.storageBlocked = true
        val text = MirrorLogic.limitText(covers, r.done.toInt(), r.total.toInt())
        r.limitNote = sortedMapOf("text" to text, "at" to now(), "limit" to limit, "used" to used)
        log("mirror: $text")
        return false
    }

    /** Only rows touched by this reply; includes fixed row/index overhead for new rows. */
    private fun footprint(job: Job, body: Map<*, *>): Long {
        val ids = if (job.kind == "detail") listOf(job.id) else
            (body["items"] as? List<*>)?.mapNotNull { (it as? Map<*, *>)?.get("id") as? Long } ?: emptyList()
        var bytes = ids.distinct().chunked(400).sumOf { chunk ->
            count("SELECT coalesce(sum(coalesce(length(item),0)+coalesce(length(detail),0)+coalesce(length(CAST(search AS BLOB)),0)+64),0) FROM books WHERE id IN (${chunk.joinToString(",") { "?" }})", *chunk.toTypedArray())
        }
        if (job.kind != "detail") {
            val identity = CacheStore.u(job.identity)
            bytes += count("SELECT coalesce(length(head),0)+length(CAST(identity AS BLOB))+128 FROM lists WHERE identity = ?", identity)
            bytes += count("SELECT coalesce(sum(coalesce(length(item),0)+32),0) FROM list_items WHERE identity = ?", identity)
        }
        return bytes
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

    private fun writeStatus(r: Run, running: Boolean): Boolean {
        onProgress(if (running && store.meta("run_op") == "full") r.pct else null)
        return write(File(mirrorDir, "status.lua"), LuaValue.encode(status(r, running)))
    }

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
        val phasePct = if (!finished && r.plan.m["catalog"] is Map<*, *> && store.meta("catalog_expanded") == null) minOf(5L, pct) else pct
        r.pct = maxOf(r.pct, phasePct)
        store.setMeta("run_pct", r.pct)
    }

    /**
     * A run. stop: the plugin's mirror/stop file, asked between batches, as are the checks waiting
     * ([yieldTo]: the worker answers them and comes back). Returns when the work is done, stopped
     * or nothing answers.
     */
    fun run(plan: Plan, creds: Creds, yieldTo: () -> Unit = {}): String {
        checkpoint()
        NoMedia.directory(mirrorDir)
        thumbnailWidth = (plan.m["cover_width"] as? Number)?.toInt() ?: 0
        thumbnailHeight = (plan.m["cover_height"] as? Number)?.toInt() ?: 0
        runProtected = plan.ids("seed_details").toSet()
        val st = store
        st.own(plan.owner)
        plan.detailTemplate?.let { st.setMeta("detail_template", it) }
        val r = Run(plan)
        r.startedMs = clockMs()
        if (plan.m["catalog"] is Map<*, *> && plan.op in setOf("full", "incremental", "revalidate", "resume")) {
            st.setMeta("run_op", if (plan.op == "resume") st.meta("run_op") ?: "full" else plan.op)
            st.setMeta("run_started", now())
            r.total = 100
            if(plan.limit!=null)storage(StorageAsk("before refresh",plan.limit,plan.coverDir,plan.coversOn))
            coverUsage=if(plan.limit!=null)CoverUsage(storageItems(plan.coverDir,plan.coversOn)) else null
            val fast = FastCatalogRefresh(st, plan, { path ->
                val reply = http.get(url(creds, path), headers(creds), null, MAX_BODY)
                if(reply.code != 200 || reply.body == null) throw FastCatalogRefresh.FetchFailure(reply.body?.size?.toLong() ?: 0L)
                val body = try { decodeJson(String(reply.body, Charsets.UTF_8)) as? Map<*, *> } catch(_:Exception) { null }
                    ?: throw FastCatalogRefresh.FetchFailure(reply.body.size.toLong())
                body.entries.associate { it.key.toString() to it.value } + ("_bulkBytes" to reply.body.size.toLong())
            }, { yieldTo(); checkpoint() }, { File(mirrorDir, "stop").isFile }, now, { pct ->
                r.pct = pct.toLong(); r.done = pct.toLong(); writeStatus(r, true)
            }, log, dataRoom={growth -> plan.limit==null || room(r,growth,false,st.fileBytes())})
            val why = fast.run()
            if (why != "finished") r.errors++
            writeStatus(r, false)
            summary(plan, why, r, r.done, why == "finished" && st.meta("run_op") == "full", why == "finished" && st.meta("run_op") == "revalidate")
            return why
        }
        val pendingBefore = count("SELECT count(*) FROM jobs WHERE state = 0")
        when (plan.op) {
            "full" -> st.transaction {
                st.db().exec("DELETE FROM jobs")
                st.setMeta("run_op", "full"); st.setMeta("run_started", now()); st.setMeta("run_pct", 0L); st.setMeta("run_estimate", null); st.setMeta("catalog_expanded", null)
                seed(plan)
            }
            "incremental" -> {
                if (pendingBefore == 0L) {
                    st.db().exec("DELETE FROM jobs")
                    st.setMeta("run_op", "incremental")
                    st.setMeta("run_started", now()); st.setMeta("run_pct", 0L); st.setMeta("run_estimate", null); st.setMeta("catalog_expanded", null)
                    st.setMeta("incremental_scan_complete", null)
                    try { r.requests += seedIncremental(r, creds) } catch (_: Exception) {
                        log("mirror: incremental probe unavailable; watermark kept")
                        writeStatus(r, false)
                        summary(plan, "no answer", r, 0)
                        return "no answer"
                    }
                }
            }
            "revalidate" -> {
                if (metaLong("full_at") == null || pendingBefore > 0) {
                    writeStatus(r, false)
                    summary(plan, "busy", r, 0)
                    return "busy"
                }
                st.transaction {
                    st.db().exec("DELETE FROM jobs")
                    st.setMeta("run_op", "revalidate"); st.setMeta("run_started", now()); st.setMeta("run_pct", 0L); st.setMeta("run_estimate", null); st.setMeta("catalog_expanded", null)
                    seedRecheck()
                    plan.strings("sections").forEach { addList(it, "recheck") }
                    seedDynamic(plan, true)
                }
            }
            "covers" -> st.transaction {
                if (pendingBefore == 0L) { st.db().exec("DELETE FROM jobs"); st.setMeta("run_op", "covers"); st.setMeta("run_started", now()); st.setMeta("run_pct", 0L) }
                seedCovers()
            }
        }
        r.pct = metaLong("run_pct") ?: 0L
        r.estimate = metaLong("run_estimate") ?: 0L
        // Prune browsing data before the first limit decision, using the same byte units and
        // db + live journal + covers + etags accounting as Storage settings.
        if (plan.limit != null) storage(StorageAsk("before refresh", plan.limit, plan.coverDir, plan.coversOn))
        coverUsage = if (plan.limit != null) CoverUsage(storageItems(plan.coverDir, plan.coversOn)) else null
        recount(r, false)
        log("mirror: ${st.meta("run_op")} (${plan.reason}): ${r.total - r.done} jobs to go, $parallel requests at a time")
        writeStatus(r, true)
        val why = try {
            var why = pump(r, creds, yieldTo)
            if (why == "finished" && st.meta("catalog_expanded") == null && st.meta("run_op") in setOf("full", "incremental", "revalidate")) {
                if (seedCatalogVariants(r, st.meta("run_op") != "full", yieldTo)) st.setMeta("catalog_expanded", true)
                recount(r, false)
                why = pump(r, creds, yieldTo)
            }
            why
        } finally { coverUsage = null; runProtected = emptySet() }
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
                        "covers %d new, %d unchanged (304), %d failed; database %.1f MB", books, lists, r.done, secs, rate, r.skipped,
                        r.covers[0], r.covers[1], r.covers[2], st.fileBytes() / MB))
                    val kinds = sortedMapOf<String, Int>()
                    // Collapse pages in SQL; do not retain a large run's paths in memory just to log counts.
                    st.db().query("SELECT DISTINCT substr(tail, instr(tail, '|') + 1) FROM " +
                        "(SELECT substr(ref, instr(ref, '|') + 1) AS tail FROM jobs WHERE state = 1 AND kind IN ('page', 'recheck'))") {
                        val kind = CatalogPlan.kind(LuaValue.str(it.text(0)!!))
                        kinds[kind] = (kinds[kind] ?: 0) + 1
                    }
                    log("mirror: lists saved by kind: " + kinds.entries.joinToString(", ") { "${it.key}=${it.value}" })
                    newestStamp()?.let { st.setMeta("incremental_watermark", it) }
                    saved = true
                }
                "incremental" -> {
                    if (r.skipped == 0L && r.errors == 0L && st.meta("incremental_scan_complete") != null) {
                        st.setMeta("incremental_lists_dirty", null)
                        st.meta("incremental_target")?.let { st.setMeta("incremental_watermark", it) }
                        plan.m["lib_version"]?.let { st.setMeta("lib_version", LuaValue.text(it)) }
                    }
                    st.setMeta("incremental_target", null)
                    st.setMeta("incremental_scan_complete", null)
                }
                "revalidate" -> { log("mirror: Refresh rechecked ${r.done} pages in ${secs.toLong()} s"); revalidated = true }
            }
            st.db().exec("DELETE FROM jobs")
        }
        writeStatus(r, false)
        summary(plan, why, r, r.done, saved, revalidated)
        return why
    }

    /** The pipeline: one fetcher shared by pages and covers, at most two queued replies, one writer. */
    private fun pump(r: Run, creds: Creds, yieldTo: () -> Unit): String {
        val st = store
        val pool = Executors.newSingleThreadExecutor { x -> threadFactory("orbit-cache-fetch", x) }
        val coverPool = pool
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
                checkpoint()
                // Refill: the next jobs by kind (lists first), those not in flight and not waiting to retry.
                // AHEAD times the pool's size queued, so the pools never wait while the writer writes.
                val reqSlots = parallel * AHEAD - inFlight.count { it.kind != "cover" }
                val coverSlots = COVER_PARALLEL * AHEAD - inFlight.count { it.kind == "cover" }
                if (!r.storageBlocked && (reqSlots > 0 || coverSlots > 0)) {
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
                            rs--
                            inFlight.add(j); pool.submit { landed.put(try { fetch(r, creds, j) } catch (e: Exception) { Landed(j, Reply(0, err = e.javaClass.simpleName), null) }) }
                        }
                    }
                }
                if (inFlight.isEmpty()) {
                    if (r.storageBlocked) { why = "storage limit"; break }
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
                checkpoint()
                val t0 = clockMs()
                val cpuStart = cpuMs()
                // Migrate existing images before opening a database transaction. A reading pause
                // must never hold a writer transaction across an entire reading session.
                for (l in batch) if (l.job.kind == "cover" && l.part == null && l.target?.isFile == true) thumbnail(l.target)
                var allTransport = true
                val databaseBytes = st.file.length()
                var batchGrowth = 0L
                st.transaction {
                    for (l in batch) {
                        inFlight.remove(l.job)
                        val j = l.job
                        val ref = CacheStore.u(j.ref)
                        if (r.storageBlocked) { l.part?.delete(); continue }
                        if (j.kind == "cover") {
                            // Existing images are mutated only by the writer, alongside eviction.
                            if (l.part == null && l.target != null && l.target.isFile) {
                                coverUsage?.replace("c:${l.target.name}", l.target.length() + File(l.target.path + ".etag").length())
                            }
                            if (l.part != null && l.target != null) {
                                val tag = File(l.target.path + ".etag")
                                val growth = l.part.length() + (l.reply?.etag?.toByteArray()?.size ?: 0) - l.target.length() - tag.length()
                                if (!room(r, growth, true, databaseBytes + batchGrowth)) {
                                    l.part.delete()
                                    st.db().exec("UPDATE jobs SET state = 2 WHERE kind = ? AND ref = ?", j.kind, ref)
                                    r.skipped++
                                    continue
                                }
                                val shown = l.target.lastModified()
                                if (!l.part.renameTo(l.target)) { l.part.delete(); continue }
                                if (shown > 0) l.target.setLastModified(shown)
                                l.reply?.etag?.let { write(tag, it.toByteArray()) } ?: tag.delete()
                                coverUsage?.replace("c:${l.target.name}", l.target.length() + tag.length())
                            }
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
                        val parseStart = cpuMs()
                        val body = if (rep != null && rep.code == 200 && rep.body != null) try { decodeJson(String(rep.body, Charsets.UTF_8)) } catch (e: Exception) { null } else null
                        r.parseCpu += cpuMs() - parseStart
                        if (body is Map<*, *> && l.path != null) {
                            allTransport = false
                            notBefore.remove(j)
                            val before = if (r.plan.limit != null) footprint(j, body) else 0L
                            val requests = r.requests; val details = r.details
                            val changedSize = r.changed.size
                            st.db().exec("SAVEPOINT storage_write")
                            try {
                                landPage(r, j, l.path, body)
                                val growth = if (r.plan.limit != null) footprint(j, body) - before else 0L
                                if (!room(r, growth, false, databaseBytes + batchGrowth)) {
                                    st.db().exec("ROLLBACK TO storage_write")
                                    r.requests = requests; r.details = details
                                    while (r.changed.size > changedSize) r.changed.removeAt(r.changed.lastIndex)
                                } else {
                                    batchGrowth += growth
                                    st.db().exec("UPDATE jobs SET state = 1 WHERE kind = ? AND ref = ?", j.kind, ref)
                                }
                            } finally { st.db().exec("RELEASE storage_write") }
                            continue
                        }
                        val status = rep?.code?.takeIf { it in 1..499 }
                        if (status != null) allTransport = false
                        val tries = (st.db().query("SELECT tries FROM jobs WHERE kind = ? AND ref = ?", j.kind, ref) { it.long(0) ?: 0L }.firstOrNull() ?: 0L) + 1
                        val p = l.path?.let { shortPath(it) } ?: j.ref
                        val whyFail = rep?.err ?: rep?.code?.takeIf { it != 0 }?.toString() ?: "no answer"
                        val retry = if (status != null) MirrorLogic.Retry(true) else MirrorLogic.retry(tries.toInt(), if (j.kind == "page" || j.kind == "recheck") j.size else null, if (j.kind == "page" || j.kind == "recheck") j.page else null)
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
                r.writeCpu += cpuMs() - cpuStart
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
            coverPool.awaitTermination(5, TimeUnit.SECONDS)
            val abandoned = ArrayList<Landed>()
            landed.drainTo(abandoned)
            abandoned.forEach { it.part?.delete() }
            coverItems.clear()
        }
        log("mirror: phase CPU fetch ${r.fetchCpu.get()} ms; parse ${r.parseCpu} ms; land/write ${r.writeCpu} ms (includes parse)")
        // Replies still in flight when it stopped: their jobs stay pending for the next run.
        return if (why == "finished" && r.limitNote != null) "storage limit" else why
    }

    private fun summary(plan: Plan, why: String, r: Run, jobs: Long, saved: Boolean = false, revalidated: Boolean = false) {
        write(File(mirrorDir, "summary.lua"), LuaValue.encode(sortedMapOf<String, Any?>(
            "run" to plan.run, "why" to why, "jobs" to jobs, "status" to status(r, false, why),
            "changed" to r.changed.toList(), "written" to r.written.toList(), "written_more" to r.writtenMore.takeIf { it },
            "saved" to saved.takeIf { it }, "revalidated" to revalidated.takeIf { it })))
    }

    companion object {
        /** The cache's files before the database (0.11.x), removed at the first open. */
        val OLD_FILES = setOf("index.lua", "storage.lua", "worker-state.lua", "cover_keep.lua")
        /** A bulk refresh must leave CPU and RAM for reading and Android system services. */
        const val PARALLEL = 1
        const val COVER_PARALLEL = 1
        /** Landed replies written in one transaction, at most (or what landed within BATCH_MS). */
        const val BATCH = 8
        const val BATCH_MS = 20L
        /** Jobs queued per pool thread (a batch's write must not starve the pools). */
        const val AHEAD = 1
        const val CHANGED_MAX = 50
        const val WRITTEN_MAX = 100
        const val STATUS_EVERY_MS = 2000L
        const val PROGRESS_EVERY_MS = 10_000L
        const val MAX_BODY = 32L * 1024 * 1024
        const val MAX_COVER = 4L * 1024 * 1024
        const val MB = 1048576.0
    }
}
