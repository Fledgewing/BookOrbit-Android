package net.fledgewing.orbitcompanion

import java.io.File

/**
 * The Orbit cache's background work, done by the companion instead of KOReader
 * (docs/design/companion-worker.md): the offline mirror (a Full refresh, Refresh's recheck,
 * covers) and the cache's background checks. KOReader runs everything on one Lua thread; the
 * plugin only sends the job and reads the result files.
 *
 * Files, under koreader/settings/orbit-cache/ (the plugin reads them; formats in
 * android/docs/INTERFACE.md "The cache worker's files"):
 * - `<hash>.lua`: a checked entry (the plugin's own browsing cache);
 * - `mirror/<hash>.lua`: the mirror's pages and details; `mirror/status.lua`, `mirror/summary.lua`,
 *   `mirror/cover_keep.lua`; `mirror/worker-state.lua` (this worker's queue, private);
 * - `events/<n>.lua`: a check's answer, a storage count; `storage.lua`: the last count's totals.
 *
 * Plain JVM (java.io and an [Http] port), so the unit tests run it against a fake server.
 */
class CacheWorker(
    val root: File,
    private val http: Http,
    private val now: () -> Long = { System.currentTimeMillis() / 1000 },
    private val log: (String) -> Unit = { OLog.i(it) },
    private val sleep: (Int) -> Unit = { Thread.sleep(it * 1000L) },
    /** Requests in flight at once (1: strictly in queue order). */
    private val parallel: Int = PARALLEL,
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

    /** A saved entry's body (the cache's format: { key, body, ... } with the key checked). */
    fun entryBody(f: File, key: String): Any? {
        val e = read(f) as? Map<*, *> ?: return null
        if (e["key"] != key) return null
        return e["body"] as? Map<*, *> ?: e["body"] as? List<*>
    }

    private fun entry(key: String, path: String, body: Any?, fetched: Long, validated: Long): ByteArray =
        LuaValue.encode(sortedMapOf<String, Any?>("key" to key, "body" to body, "fetched_at" to fetched, "validated_at" to validated, "path" to path))

    // ------------------------------------------------------------------ checks

    /** A background check (the plugin's OC.check): mode "open" | "refresh" | "full". */
    data class Check(val key: String, val path: String, val mode: String, val creds: Creds, val owner: String)

    /**
     * Asks the server, compares with what the plugin would serve (its own entry, else a list page
     * cut from the mirror), saves a changed reply under the key, and answers with an event:
     * { kind = "checked", key, changed | unchanged, saved, bytes, ids, at } or { kind, key, err }.
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
        val own = entryBody(File(root, MirrorLogic.hash(c.key) + ".lua"), c.key)
        val saved = own ?: mirrorSlice(c.owner, c.creds.server, c.path)
        if (!LuaValue.changed(saved, reply)) {
            ev["unchanged"] = true
            if (own != null) ev["saved"] = true
            return event(ev)
        }
        val body = LuaValue.settle(saved, reply, c.mode)
        val t = now()
        val bytes = entry(c.key, c.path, body, t, t)
        if (!write(File(root, MirrorLogic.hash(c.key) + ".lua"), bytes)) {
            ev["err"] = "not saved"
            return event(ev)
        }
        ev["changed"] = true
        ev["bytes"] = bytes.size.toLong()
        ev["ids"] = LuaValue.ids(body).toList()
        ev["at"] = t
        event(ev)
    }

    // ------------------------------------------------------------------ the storage limit

    /** The plugin's STORAGE: count, and over [limit] remove (StorageLogic). [mirrorCovers]: "Save every cover" is on. */
    data class StorageAsk(val reason: String, val limit: Long?, val coverDir: String?, val mirrorCovers: Boolean)

    /**
     * Everything Orbit stores: the cache's entries (from its index), the index, the offline
     * mirror's lists and details ([mirrorBytes]), and the cover folder's files.
     */
    fun storageItems(coverDir: String?, mirrorCovers: Boolean, mirrorBytes: Long): List<StorageLogic.Item> {
        val items = ArrayList<StorageLogic.Item>()
        val index = File(root, "index.lua")
        val entries = (read(index) as? Map<*, *>)?.get("entries") as? Map<*, *> ?: emptyMap<Any?, Any?>()
        for ((k, v) in entries) {
            val e = v as? Map<*, *> ?: continue
            items.add(StorageLogic.Item("e:$k", (e["bytes"] as? Number)?.toLong() ?: 0L, (e["used_at"] as? Number)?.toLong() ?: 0L,
                if (e["keep"] == true) "kept" else "cache"))
        }
        items.add(StorageLogic.Item("index", if (index.isFile) index.length() else 0L, 0L, "kept"))
        items.add(StorageLogic.Item("mirror", mirrorBytes, 0L, "kept"))
        val dir = coverDir?.let { File(it) }
        if (dir != null && dir.isDirectory) {
            val keep = if (mirrorCovers) (read(File(mirrorDir, "cover_keep.lua")) as? Map<*, *>)?.keys?.map { it.toString() }?.toHashSet() ?: emptySet() else emptySet()
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
     * Counts, and over the limit removes covers itself; the cache entries to drop go to the plugin
     * (it owns its index) in the event: { kind = "storage", why, drop = { {key, used_at} }, totals,
     * removed = { cache, cover, mirror_cover }, used, after, limit }. The totals also go to
     * storage.lua, which the plugin reads at start.
     */
    fun storage(a: StorageAsk) {
        val items = storageItems(a.coverDir, a.mirrorCovers, loadState()?.bytes ?: 0L)
        val plan = StorageLogic.plan(items, a.limit)
        val byK = items.associateBy { it.k }
        val drop = ArrayList<Map<String, Any?>>()
        val removed = sortedMapOf("cache" to 0L, "cover" to 0L, "mirror_cover" to 0L)
        for (k in plan.drop) {
            val it = byK[k] ?: continue
            if (k.startsWith("e:")) drop.add(sortedMapOf("key" to k.removePrefix("e:"), "used_at" to it.at))
            else if (k.startsWith("c:") && a.coverDir != null) {
                File(a.coverDir, k.removePrefix("c:")).delete()
                File(a.coverDir, k.removePrefix("c:") + ".etag").delete()
            }
            removed[it.kind] = (removed[it.kind] ?: 0L) + 1
        }
        val totals = StorageLogic.totals(items, plan.drop)
        write(File(root, "storage.lua"), LuaValue.encode(sortedMapOf<String, Any?>("totals" to totals, "at" to now())))
        val ev = sortedMapOf<String, Any?>("kind" to "storage", "why" to a.reason, "drop" to drop, "totals" to totals,
            "removed" to removed, "used" to plan.used, "after" to plan.after)
        a.limit?.let { ev["limit"] = it }
        event(ev)
        if (plan.drop.isNotEmpty()) {
            log("storage: ${"%.1f".format(java.util.Locale.ROOT, plan.used / MB)} MB over ${a.limit?.let { it / (1024 * 1024) }} MB (${a.reason}); " +
                "${removed["cache"]} browsing entries, ${removed["cover"]} covers, ${removed["mirror_cover"]} saved-for-offline covers go -> " +
                "%.1f MB".format(java.util.Locale.ROOT, plan.after / MB))
        }
    }

    // ------------------------------------------------------------------ copies (keep-copies-current.md)

    /**
     * The plugin's COPIES: which copies on this reader changed in the library. The ask
     * (copies/ask.lua, written by the plugin; no login in it): `books` ({ md5, path, book_id,
     * file_id, incompatible }), `eob` (book id -> { files, saved_at }: the end-of-book cache),
     * `owner`, `server`, `detail_template`, `sentinel`. The details come from the newer of the
     * end-of-book cache, the cache's entries and the mirror's (CopiesLogic). Answers with
     * { kind = "copies", why, checked, found = { { md5, path, book_id, file_id, why } }, gone }.
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
        // The cache's saved details: the index names them by path.
        val entries = (read(File(root, "index.lua")) as? Map<*, *>)?.get("entries") as? Map<*, *> ?: emptyMap<Any?, Any?>()
        for ((key, v) in entries) {
            val meta = v as? Map<*, *> ?: continue
            val id = CopiesLogic.detailId(meta["path"] as? String) ?: continue
            if (id !in want) continue
            val at = (meta["validated_at"] as? Number)?.toLong() ?: 0L
            if (!CopiesLogic.newer(details[id], at)) continue
            val body = entryBody(File(root, MirrorLogic.hash(key.toString()) + ".lua"), key.toString()) as? Map<*, *> ?: continue
            (body["files"] as? List<*>)?.let { details[id] = CopiesLogic.Detail(it, at) }
        }
        // The offline mirror's details: one file per wanted book.
        val owner = ask["owner"] as? String
        val server = ask["server"] as? String
        val template = ask["detail_template"] as? String
        val sentinel = ask["sentinel"] as? String ?: "987654321"
        if (owner != null && server != null && template != null) {
            for (id in want) {
                val key = MirrorLogic.key(owner, server, MirrorLogic.fillBytes(template, sentinel, id))
                val e = read(File(mirrorDir, MirrorLogic.hash(key) + ".lua")) as? Map<*, *> ?: continue
                if (e["key"] != key) continue
                val at = (e["validated_at"] as? Number)?.toLong() ?: 0L
                val files = (e["body"] as? Map<*, *>)?.get("files") as? List<*> ?: continue
                if (CopiesLogic.newer(details[id], at)) details[id] = CopiesLogic.Detail(files, at)
            }
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

    /** `OC.lookup`'s mirror half: a list read answered from the mirror's pages. */
    fun mirrorSlice(owner: String, server: String, path: String): Any? {
        val w = MirrorLogic.listWindow(path) ?: return null
        val (_, q) = MirrorLogic.splitPath(path)
        val query = MirrorLogic.parseQuery(q)
        for (size in listOf<Int?>(null, 50, 25)) {
            val firstKey = MirrorLogic.key(owner, server, MirrorLogic.mirrorPage(w.identity, 1, size))
            val first = entryBody(File(mirrorDir, MirrorLogic.hash(firstKey) + ".lua"), firstKey) as? Map<*, *> ?: continue
            val pages = HashMap<Int, Any?>()
            pages[1] = first
            val n = MirrorLogic.pageCount((first["total"] as? Number)?.toInt() ?: 0, size)
            for (i in 2..n) {
                val k = MirrorLogic.key(owner, server, MirrorLogic.mirrorPage(w.identity, i, size))
                pages[i] = entryBody(File(mirrorDir, MirrorLogic.hash(k) + ".lua"), k)
            }
            return LuaValue.slice(w.kind, query["page"]?.toIntOrNull(), query["size"]?.toIntOrNull(), query["offset"]?.toIntOrNull(), pages, size ?: MirrorLogic.PAGE)
        }
        return null
    }

    // ------------------------------------------------------------------ the mirror

    /** One queued request. k: "page" | "detail" | "covers". */
    data class Job(
        val k: String, val identity: String? = null, val page: Int = 1, val kind: String? = null, val section: String? = null,
        var size: Int? = null, val check: Boolean = false, val seed: Boolean = false, val path: String? = null, val id: Long? = null,
        val nextOf: Long? = null, var tries: Int = 0, val batch: List<Cover> = emptyList(),
    ) {
        fun seenId() = "$k|${identity ?: path ?: ""}|${if (k == "page") page.toString() else ""}"
        fun toModel(): Map<String, Any?> = sortedMapOf("k" to k, "identity" to identity, "page" to page.toLong(), "kind" to kind,
            "section" to section, "size" to size?.toLong(), "check" to check.takeIf { it }, "seed" to seed.takeIf { it }, "path" to path,
            "id" to id, "next_of" to nextOf, "tries" to tries.toLong().takeIf { it > 0 }, "batch" to batch.map { it.toModel() }.takeIf { it.isNotEmpty() })

        companion object {
            fun of(m: Map<*, *>) = Job(m["k"] as String, m["identity"] as? String, (m["page"] as? Long)?.toInt() ?: 1, m["kind"] as? String,
                m["section"] as? String, (m["size"] as? Long)?.toInt(), m["check"] == true, m["seed"] == true, m["path"] as? String,
                m["id"] as? Long, m["next_of"] as? Long, (m["tries"] as? Long)?.toInt() ?: 0,
                (m["batch"] as? List<*>)?.mapNotNull { (it as? Map<*, *>)?.let(Cover::of) } ?: emptyList())
        }
    }

    data class Cover(val id: Long, val path: String, val updatedAt: String?) {
        fun toModel(): Map<String, Any?> = sortedMapOf("id" to id, "path" to path, "updatedAt" to updatedAt)
        companion object { fun of(m: Map<*, *>) = Cover(m["id"] as Long, m["path"] as String, m["updatedAt"] as? String) }
    }

    data class ListInfo(val total: Int, val kind: String?, val section: String?, val size: Int?)

    /** The run's state, kept in mirror/worker-state.lua across runs. */
    class State {
        val queues = linkedMapOf("seed" to ArrayDeque<Job>(), "lists" to ArrayDeque(), "details" to ArrayDeque(), "covers" to ArrayDeque())
        val seen = HashSet<String>()
        val lists = java.util.TreeMap<String, ListInfo>()
        val sizes = HashMap<String, Long>()
        val digests = HashMap<String, String>()
        val coverKeep = java.util.TreeSet<String>()
        var done = 0; var total = 0; var skipped = 0; var requests = 0; var bytes = 0L
        var coverTotal = 0; var coverBatch = 0
        var covers = longArrayOf(0, 0, 0, 0) // ok, not modified, failed, bytes
        var at: Long? = null; var libVersion: Any? = null; var op: String? = null; var reason: String? = null
        var startedAt: Long = 0; var revalidating = false; var limitNote: Map<String, Any?>? = null; var keepN = 0L
        var keepDirty = false
        var detailsDone = 0
        /** This run's starting cover bytes, and what else counts toward the limit (counted at its start). */
        var runCover0 = 0L; var baseOther = 0L; var baseMirrorCover = 0L

        fun left() = queues.values.sumOf { it.size }
        fun peek(): Pair<String, Job>? = queues.entries.firstOrNull { it.value.isNotEmpty() }?.let { it.key to it.value.first() }

        fun push(job: Job): Boolean {
            if (!seen.add(job.seenId())) return false
            val q = when { job.k == "covers" -> "covers"; job.seed -> "seed"; job.k == "detail" -> "details"; else -> "lists" }
            queues.getValue(q).addLast(job)
            total++
            return true
        }

        fun toModel(): Map<String, Any?> = sortedMapOf(
            "v" to 3L, "queues" to queues.mapValues { (_, q) -> q.map { it.toModel() } }, "seen" to seen.toList(),
            "lists" to lists.mapValues { (_, l) -> sortedMapOf<String, Any?>("total" to l.total.toLong(), "kind" to l.kind, "section" to l.section, "size" to l.size?.toLong()) },
            "sizes" to sizes, "digests" to digests, "cover_keep" to coverKeep.toList(), "done" to done.toLong(), "total" to total.toLong(),
            "skipped" to skipped.toLong(), "requests" to requests.toLong(), "bytes" to bytes, "cover_total" to coverTotal.toLong(),
            "cover_batch" to coverBatch.toLong(), "covers" to covers.toList(), "at" to at, "lib_version" to libVersion, "op" to op,
            "reason" to reason, "started_at" to startedAt, "revalidating" to revalidating.takeIf { it }, "limit_note" to limitNote, "keep_n" to keepN)

        companion object {
            fun of(m: Map<*, *>): State? {
                if (m["v"] != 3L) return null
                val s = State()
                (m["queues"] as? Map<*, *>)?.forEach { (name, q) ->
                    val dq = s.queues[name.toString()] ?: return@forEach
                    (q as? List<*>)?.forEach { j -> (j as? Map<*, *>)?.let { dq.addLast(Job.of(it)) } }
                }
                (m["seen"] as? List<*>)?.forEach { s.seen.add(it.toString()) }
                (m["lists"] as? Map<*, *>)?.forEach { (k, v) ->
                    val l = v as? Map<*, *> ?: return@forEach
                    s.lists[k.toString()] = ListInfo((l["total"] as? Long)?.toInt() ?: 0, l["kind"] as? String, l["section"] as? String, (l["size"] as? Long)?.toInt())
                }
                (m["sizes"] as? Map<*, *>)?.forEach { (k, v) -> s.sizes[k.toString()] = (v as? Long) ?: 0 }
                (m["digests"] as? Map<*, *>)?.forEach { (k, v) -> s.digests[k.toString()] = v.toString() }
                (m["cover_keep"] as? List<*>)?.forEach { s.coverKeep.add(it.toString()) }
                fun n(k: String) = (m[k] as? Long) ?: 0
                s.done = n("done").toInt(); s.total = n("total").toInt(); s.skipped = n("skipped").toInt(); s.requests = n("requests").toInt()
                s.bytes = n("bytes"); s.coverTotal = n("cover_total").toInt(); s.coverBatch = n("cover_batch").toInt(); s.keepN = n("keep_n")
                (m["covers"] as? List<*>)?.let { c -> s.covers = LongArray(4) { (c.getOrNull(it) as? Long) ?: 0 } }
                s.at = m["at"] as? Long; s.libVersion = m["lib_version"]; s.op = m["op"] as? String; s.reason = m["reason"] as? String
                s.startedAt = n("started_at"); s.revalidating = m["revalidating"] == true
                @Suppress("UNCHECKED_CAST")
                s.limitNote = m["limit_note"] as? Map<String, Any?>
                return s
            }
        }
    }

    /** What the plugin asks for (mirror/plan.lua, written by the plugin; no credentials in it). */
    data class Plan(val m: Map<*, *>) {
        val run get() = m["run"]?.toString() ?: ""
        val op get() = m["op"] as? String ?: "resume"
        val reason get() = m["reason"] as? String
        val owner get() = m["owner"] as? String ?: ""
        val sentinel get() = m["sentinel"] as? String ?: "987654321"
        val templates get() = m["templates"] as? Map<*, *> ?: emptyMap<String, Any?>()
        val detailTemplate get() = m["detail_template"] as? String
        val coversOn get() = m["covers_on"] == true
        val coverDir get() = m["cover_dir"] as? String
        val limit get() = (m["limit"] as? Long)?.takeIf { it > 0 }
        fun strings(k: String) = (m[k] as? List<*>)?.mapNotNull { it as? String } ?: emptyList()
        fun ids(k: String) = (m[k] as? List<*>)?.mapNotNull { it as? Long } ?: emptyList()
    }

    /** A run's output for the plugin (mirror/summary.lua). */
    class Out {
        val changed = ArrayList<String>()
        val written = ArrayList<Map<String, Any?>>()
        var writtenMore = false
        var saved = false
        var revalidated = false
    }

    fun loadState(): State? = (read(File(mirrorDir, STATE)) as? Map<*, *>)?.let { State.of(it) }

    fun saveState(s: State) {
        write(File(mirrorDir, STATE), LuaValue.encode(s.toModel()))
    }

    private fun status(s: State, plan: Plan, running: Boolean): Map<String, Any?> = sortedMapOf(
        "v" to 3L, "runner" to "companion", "run" to plan.run, "running" to running.takeIf { it }, "beat" to now(), "op" to s.op,
        "at" to s.at, "lib_version" to s.libVersion, "done" to s.done.toLong(), "total" to s.total.toLong(), "left" to s.left().toLong(),
        "skipped" to s.skipped.toLong(), "covers" to sortedMapOf<String, Any?>("ok" to s.covers[0], "not_modified" to s.covers[1],
            "failed" to s.covers[2], "bytes" to s.covers[3]),
        "cover_total" to s.coverTotal.toLong(), "limit_note" to s.limitNote, "revalidating" to s.revalidating.takeIf { it },
        "bytes" to s.bytes, "cover_keep_n" to s.keepN, "started_at" to s.startedAt)

    fun writeStatus(s: State, plan: Plan, running: Boolean) {
        write(File(mirrorDir, "status.lua"), LuaValue.encode(status(s, plan, running)))
    }

    private fun mirrorKey(plan: Plan, creds: Creds, path: String) = MirrorLogic.key(plan.owner, creds.server, path)

    private fun detailPath(plan: Plan, id: Long): String? = plan.detailTemplate?.let { MirrorLogic.fillBytes(it, plan.sentinel, id.toString()) }

    private fun addList(s: State, path: String, seed: Boolean = false) {
        val w = MirrorLogic.listWindow(path) ?: return
        s.push(Job("page", identity = w.identity, page = 1, kind = w.kind, section = w.section, seed = seed))
    }

    private fun addDetail(s: State, plan: Plan, id: Long, seed: Boolean, nextOf: Long? = null) {
        val p = detailPath(plan, id) ?: return
        s.push(Job("detail", path = p, id = id, seed = seed, nextOf = nextOf))
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

    private fun coversFor(s: State, plan: Plan, items: List<*>, all: Boolean) {
        val batch = ArrayList<Cover>()
        fun flush() {
            if (batch.isEmpty()) return
            s.coverBatch++
            s.push(Job("covers", path = "covers#${s.coverBatch}", batch = ArrayList(batch)))
            batch.clear()
        }
        for (b in items) {
            val book = b as? Map<*, *> ?: continue
            val p = coverPath(plan, book) ?: continue
            batch.add(Cover(book["id"] as Long, p, book["updatedAt"]?.let { LuaValue.text(it) }))
            s.coverTotal++
            if (all) { s.coverKeep.add(p.substringAfterLast('/')); s.keepDirty = true }
            if (batch.size >= COVER_BATCH) flush()
        }
        flush()
    }

    /** Seeds a Full refresh from the plan: On device and the books on the reader first, then the lists. */
    fun seed(s: State, plan: Plan) {
        plan.strings("seed_lists").forEach { addList(s, it, seed = true) }
        plan.strings("legacy_lists").forEach { addList(s, it) }
        plan.strings("sections").forEach { addList(s, it) }
        val ids = sortedSetOf<Long>()
        ids.addAll(plan.ids("seed_details"))
        // Every list the plugin has read, and Home's entries, from its index (read here, not on
        // KOReader's UI thread: up to Cache.MAX_ENTRIES of them).
        val index = (read(File(root, "index.lua")) as? Map<*, *>)?.get("entries") as? Map<*, *> ?: emptyMap<String, Any?>()
        val homeKeys = ArrayList<String>()
        val paths = java.util.TreeSet<String>()
        for ((key, meta) in index) {
            val m = meta as? Map<*, *> ?: continue
            if (m["mirror"] == true) continue
            (m["path"] as? String)?.let { paths.add(it) }
            if (m["home"] == true) homeKeys.add(key.toString())
        }
        paths.forEach { addList(s, it) }
        // Continue reading and Home's shelves, from the plugin's own saved Home entries.
        for (key in homeKeys) {
            val body = entryBody(File(root, MirrorLogic.hash(key) + ".lua"), key) as? Map<*, *> ?: continue
            for (field in listOf("continueReading", "items", "books")) {
                for (b in body[field] as? List<*> ?: emptyList<Any?>()) ((b as? Map<*, *>)?.get("id") as? Long)?.let { ids.add(it) }
            }
        }
        ids.forEach { addDetail(s, plan, it, seed = true) }
    }

    /** "Save every cover for offline" turned on: the covers of every books list saved. */
    fun coverPass(s: State, plan: Plan, creds: Creds) {
        val n0 = s.left()
        for ((identity, l) in s.lists) {
            if (l.kind != "books") continue
            for (n in 1..MirrorLogic.pageCount(l.total, l.size)) {
                val key = mirrorKey(plan, creds, MirrorLogic.mirrorPage(identity, n, l.size))
                val body = entryBody(File(mirrorDir, MirrorLogic.hash(key) + ".lua"), key) as? Map<*, *> ?: continue
                coversFor(s, plan, body["items"] as? List<*> ?: emptyList<Any?>(), true)
            }
        }
        log("mirror: every cover for offline (${plan.reason}): ${s.left() - n0} batch(es) queued")
    }

    /** Refresh's delta: every saved page of every list. */
    fun recheck(s: State) {
        s.seen.clear(); s.done = 0; s.total = 0; s.requests = 0; s.skipped = 0; s.coverTotal = 0
        s.covers = longArrayOf(0, 0, 0, 0)
        s.revalidating = true; s.op = "revalidate"; s.startedAt = now()
        for ((identity, l) in s.lists) {
            for (n in 1..MirrorLogic.pageCount(l.total, l.size)) {
                s.push(Job("page", identity = identity, page = n, kind = l.kind, section = l.section, check = true, size = l.size))
            }
        }
        log("mirror: Refresh rechecks ${s.total} saved pages")
    }

    /** Saves an entry. -> true when it changed from a page saved before (false for a new one). */
    private fun store(s: State, key: String, path: String, body: Any?): Boolean {
        val h = MirrorLogic.hash(key)
        val digest = java.security.MessageDigest.getInstance("SHA-1").digest(LuaValue.encode(LuaValue.normalize(body)))
            .joinToString("") { String.format(java.util.Locale.ROOT, "%02x", it) }
        val f = File(mirrorDir, "$h.lua")
        val changed = s.digests[h] != null && s.digests[h] != digest
        val t = now()
        val bytes = entry(key, path, body, t, t)
        if (write(f, bytes)) {
            s.bytes += bytes.size - (s.sizes[h] ?: 0)
            s.sizes[h] = bytes.size.toLong()
            s.digests[h] = digest
        }
        return changed
    }

    private fun drop(s: State, key: String) {
        val h = MirrorLogic.hash(key)
        File(mirrorDir, "$h.lua").delete()
        s.bytes -= s.sizes.remove(h) ?: 0
        s.digests.remove(h)
    }

    private fun limited(s: State, plan: Plan, q: String, job: Job): Boolean {
        val limit = plan.limit ?: return false
        val covers = job.k == "covers"
        if (covers && !plan.coversOn) return false
        val kept = s.baseOther + s.bytes
        val room = if (covers) kept + s.baseMirrorCover + s.covers[3] - s.runCover0 < limit else kept < limit
        if (room) return false
        val text: String
        if (covers) {
            val n = s.queues.getValue("covers").size
            s.queues.getValue("covers").clear()
            s.total -= n
            text = MirrorLogic.limitText(true, (s.covers[0] + s.covers[1]).toInt(), s.coverTotal)
        } else {
            text = MirrorLogic.limitText(false, s.done, s.total)
            s.queues.values.forEach { it.clear() }
            s.total = s.done
        }
        s.limitNote = sortedMapOf("text" to text, "at" to now(), "limit" to limit)
        log("mirror: $text")
        return true
    }

    private fun shortPath(p: String) = LuaValue.utf8(p).removePrefix("/koreader/plugin/catalog") // orbify:not-a-route: a log line's prefix, not a call

    /** One saved list page or detail: what it names joins the queue. */
    private fun landed(s: State, plan: Plan, creds: Creds, job: Job, path: String, body: Map<*, *>, out: Out) {
        s.requests++
        val key = mirrorKey(plan, creds, path)
        val changed = store(s, key, path, body)
        if (job.k == "detail") {
            s.detailsDone++
            if (job.nextOf == null) {
                val mine = (body["seriesIndex"] as? Number)?.toDouble() ?: 0.0
                for (m in body["seriesMembers"] as? List<*> ?: emptyList<Any?>()) {
                    val sm = m as? Map<*, *> ?: continue
                    val id = (sm["id"] as? Long) ?: continue
                    if (id != job.id && sm["readStatus"] != "read" && ((sm["seriesIndex"] as? Number)?.toDouble() ?: 0.0) > mine) {
                        addDetail(s, plan, id, job.seed, nextOf = job.id)
                        break
                    }
                }
            }
            if (job.seed || plan.coversOn) coversFor(s, plan, listOf(body), plan.coversOn)
            return
        }
        val total = (body["total"] as? Number)?.toInt() ?: (body["items"] as? List<*>)?.size ?: 0
        val identity = job.identity ?: return
        if (job.page == 1) {
            val l = s.lists[identity]
            var oldTotal = l?.total
            fun dropPage(n: Int, size: Int?) = drop(s, mirrorKey(plan, creds, MirrorLogic.mirrorPage(identity, n, size)))
            if (l != null && l.size != job.size) {
                for (n in 2..MirrorLogic.pageCount(l.total, l.size)) dropPage(n, l.size)
                dropPage(1, l.size)
                oldTotal = null
            }
            s.lists[identity] = ListInfo(total, job.kind, job.section, job.size)
            if (!job.check || oldTotal != total) {
                val (fetch, gone) = MirrorLogic.repage(if (job.check) oldTotal ?: 0 else 0, total, job.size)
                fetch.forEach { s.push(Job("page", identity = identity, page = it, kind = job.kind, section = job.section, check = job.check, size = job.size, seed = job.seed)) }
                gone.forEach { dropPage(it, job.size) }
                if (job.check && oldTotal != total) log("mirror: ${shortPath(identity)} total $oldTotal -> $total; re-paged")
            }
        }
        val items = body["items"] as? List<*> ?: emptyList<Any?>()
        if (job.kind == "section") {
            val section = job.section ?: return
            for (e in items) {
                val entry = e as? Map<*, *> ?: continue
                MirrorLogic.entryPath(plan.templates, plan.sentinel, section, entry)?.let { addList(s, it) }
            }
        } else if (job.kind == "books" && (!job.check || changed)) {
            // A rechecked page that changed: its new books' details, and its covers (304 when unchanged).
            for (b in items) ((b as? Map<*, *>)?.get("id") as? Long)?.let { id ->
                val known = job.check && detailPath(plan, id)?.let { File(mirrorDir, MirrorLogic.hash(mirrorKey(plan, creds, it)) + ".lua").isFile } == true
                if (!known) addDetail(s, plan, id, false)
            }
            if (plan.coversOn) coversFor(s, plan, items, true)
        }
        if (job.check && changed && out.changed.size < CHANGED_MAX) out.changed.add(identity)
    }

    private fun coverBatch(s: State, creds: Creds, job: Job, out: Out) {
        for (c in job.batch) {
            val f = File(c.path)
            val etagFile = File(c.path + ".etag")
            val exists = f.isFile
            // A file the plugin saved without an ETag is left alone.
            if (exists && !etagFile.isFile) continue
            val h = headers(creds, "image/jpeg,image/*").toMutableMap()
            h["Accept-Encoding"] = "identity"
            if (exists) h["If-None-Match"] = etagFile.readText()
            val part = File(c.path + ".part")
            part.parentFile?.mkdirs()
            val r = http.get(creds.server + "/koreader/plugin/catalog/books/${c.id}/thumbnail", h, part, MAX_COVER)
            when {
                r.code == 304 && exists -> { part.delete(); s.covers[1]++ }
                r.code == 200 && r.contentType?.lowercase()?.trim()?.startsWith("image/") == true && part.isFile && part.length() > 0 -> {
                    if (part.renameTo(f)) {
                        if (r.etag != null) write(etagFile, r.etag.toByteArray()) else etagFile.delete()
                        s.covers[0]++
                        s.covers[3] += f.length()
                        if (out.written.size < WRITTEN_MAX) out.written.add(sortedMapOf("id" to c.id, "updatedAt" to c.updatedAt)) else out.writtenMore = true
                    } else { part.delete(); s.covers[2]++ }
                }
                else -> { part.delete(); s.covers[2]++ }
            }
        }
    }

    /** Replies fetched ahead, by job (PARALLEL at a time over kept-alive connections). */
    private val ahead = java.util.IdentityHashMap<Job, Reply>()
    private val pool by lazy { java.util.concurrent.Executors.newFixedThreadPool(parallel) { r -> Thread(r, "orbit-cache-fetch").also { it.isDaemon = true } } }

    private fun jobPath(job: Job) = if (job.k == "page") MirrorLogic.mirrorPage(job.identity!!, job.page, job.size) else job.path!!

    /** The next AHEAD jobs of queue q that are requests, fetched at once (each still lands in order). */
    private fun fetchAhead(s: State, creds: Creds, q: String) {
        val jobs = s.queues.getValue(q).asSequence().filter { it.k != "covers" && it !in ahead }.take(AHEAD).toList()
        if (parallel < 2 || jobs.size < 2) return
        val futures = jobs.map { j -> j to pool.submit<Reply> { http.get(url(creds, jobPath(j)), headers(creds), null, MAX_BODY) } }
        for ((j, f) in futures) ahead[j] = try { f.get() } catch (e: Exception) { Reply(0, err = e.javaClass.simpleName) }
    }

    /** One job, retried in place (5 s, 10 s; a list's first page in smaller pages), then skipped. -> true: skipped for no answer. */
    private fun doJob(s: State, plan: Plan, creds: Creds, q: String, job: Job, out: Out): Boolean {
        if (job.k == "covers") {
            coverBatch(s, creds, job, out)
            s.queues.getValue(q).removeFirst()
            s.done++
            return false
        }
        if (job !in ahead) fetchAhead(s, creds, q)
        while (true) {
            val path = jobPath(job)
            val r = ahead.remove(job) ?: http.get(url(creds, path), headers(creds), null, MAX_BODY)
            val body = if (r.code == 200 && r.body != null) try { LuaValue.fromJson(String(r.body, Charsets.UTF_8)) } catch (e: Exception) { null } else null
            if (body is Map<*, *>) {
                s.queues.getValue(q).removeFirst()
                s.done++
                try { landed(s, plan, creds, job, path, body, out) } catch (e: Exception) { log("mirror: step failed: $e") }
                return false
            }
            val why = r.err ?: if (r.code != 0) r.code.toString() else "no answer"
            job.tries++
            val status = r.code.takeIf { it in 1..499 }
            val retry = if (status != null) MirrorLogic.Retry(true) else MirrorLogic.retry(job.tries, if (job.k == "page") job.size ?: MirrorLogic.PAGE else null, job.page)
            if (retry.skip) {
                log("mirror: ${shortPath(path)} skipped after ${job.tries} tries ($why); the rest continues")
                s.skipped++
                s.queues.getValue(q).removeFirst()
                s.done++
                return status == null
            }
            val smaller = retry.size != null && retry.size != (job.size ?: MirrorLogic.PAGE)
            if (smaller) job.size = retry.size
            log("mirror: ${shortPath(path)} failed ($why), try ${job.tries} of ${MirrorLogic.TRIES}; again in ${retry.waitS}s${if (smaller) ", in pages of ${retry.size}" else ""}")
            sleep(retry.waitS)
        }
    }

    /** v0.11.2's mirror files (in the plugin's folder, named by the plan): moved into mirror/. */
    private fun moveLegacy(s: State, plan: Plan) {
        var moved = 0
        for (h in plan.strings("legacy")) {
            val from = File(root, "$h.lua")
            val to = File(mirrorDir, "$h.lua")
            if (from.isFile && from.renameTo(to)) { s.sizes[h] = to.length(); s.bytes += to.length(); moved++ }
        }
        if (moved > 0) log("mirror: moved $moved saved pages and details of v0.11.2's mirror into mirror/")
    }

    /**
     * A run. stop: asked between jobs (the plugin's mirror/stop file, or a check waiting: the
     * worker answers it and comes back). Returns when the queue is done, stopped or nothing answers.
     */
    fun run(plan: Plan, creds: Creds, yieldTo: () -> Unit = {}): String {
        mirrorDir.mkdirs()
        var s = loadState()
        when (plan.op) {
            "full" -> {
                val prev = s
                s = State()
                if (prev != null) {
                    s.at = prev.at; s.libVersion = prev.libVersion; s.lists.putAll(prev.lists); s.sizes.putAll(prev.sizes)
                    s.digests.putAll(prev.digests); s.bytes = prev.bytes; s.coverKeep.addAll(prev.coverKeep); s.keepN = prev.keepN
                }
                s.op = "full"; s.reason = plan.reason; s.startedAt = now()
                moveLegacy(s, plan)
                seed(s, plan)
                log("mirror: Full refresh (${plan.reason}): ${s.left()} lists and books to save first")
            }
            "revalidate" -> {
                if (s == null || s.at == null || s.left() > 0) {
                    val st = s ?: State()
                    writeStatus(st, plan, false)
                    summary(plan, "busy", st, Out(), 0)
                    return "busy"
                }
                recheck(s)
            }
            "covers" -> {
                if (s == null) s = State()
                coverPass(s, plan, creds)
            }
            else -> if (s == null) s = State()
        }
        val st = s!!
        st.runCover0 = st.covers[3]
        if (plan.limit != null) {
            // Everything else that counts toward the limit, as it stands now (StorageLogic).
            val items = storageItems(plan.coverDir, plan.coversOn, 0L)
            st.baseOther = items.filter { it.kind == "kept" }.sumOf { it.bytes }
            st.baseMirrorCover = items.filter { it.kind == "mirror_cover" }.sumOf { it.bytes }
        }
        val out = Out()
        val bytes0 = st.bytes
        val coverBytes0 = st.covers[3]
        var jobs = 0
        val runStartMs = System.currentTimeMillis()
        val details0 = st.detailsDone
        val requests0 = st.requests
        var transport = 0
        var statusAt = 0L
        var stateAt = now()
        var why: String
        writeStatus(st, plan, true)
        while (true) {
            val next = st.peek()
            if (next == null) { why = "finished"; break }
            if (File(mirrorDir, "stop").isFile) { why = "stopped"; break }
            yieldTo()
            val (q, job) = next
            jobs++
            if (!limited(st, plan, q, job)) {
                if (doJob(st, plan, creds, q, job, out)) {
                    transport++
                    if (transport >= 2) { why = "no answer"; break }
                } else transport = 0
                progress(st)
            }
            if (now() - statusAt >= STATUS_EVERY_S) { writeStatus(st, plan, true); statusAt = now() }
            if (now() - stateAt >= STATE_EVERY_S) { persist(st); stateAt = now() }
        }
        ahead.clear()
        val runMs = System.currentTimeMillis() - runStartMs
        log(String.format(java.util.Locale.ROOT, "mirror: run %s (%s): %d jobs, %d books' details, %d requests in %.1f s (%.1f requests/s, %d at a time)",
            plan.run, why, jobs, st.detailsDone - details0, st.requests - requests0, runMs / 1000.0, (st.requests - requests0) * 1000.0 / maxOf(1L, runMs), parallel))
        if (why == "finished") {
            val secs = now() - st.startedAt
            if (st.revalidating) {
                log("mirror: Refresh rechecked ${st.done} pages in ${secs}s, ${st.requests} requests")
                st.revalidating = false
                out.revalidated = true
            } else if (plan.op == "full" || st.op == "full") {
                st.at = now(); st.libVersion = plan.m["lib_version"]
                log("mirror: Full refresh saved for offline in ${secs}s: ${st.lists.size} lists, ${st.requests} requests, ${st.skipped} skipped, " +
                    String.format(java.util.Locale.ROOT, "%.1f MB", st.bytes / 1048576.0) + "; covers ${st.covers[0]} new, ${st.covers[1]} unchanged (304), ${st.covers[2]} failed")
                out.saved = true
            }
            st.seen.clear()
        }
        persist(st)
        writeStatus(st, plan, false)
        summary(plan, why, st, out, jobs, st.bytes - bytes0, st.covers[3] - coverBytes0)
        return why
    }

    private fun persist(s: State) {
        saveState(s)
        if (s.keepDirty) {
            s.keepN++
            write(File(mirrorDir, "cover_keep.lua"), LuaValue.encode(s.coverKeep.associateWith { true }))
            s.keepDirty = false
        }
    }

    private var loggedAt = 0L

    private fun progress(s: State) {
        if (now() - loggedAt < 10 && s.left() > 0) return
        loggedAt = now()
        log("mirror: ${s.done}/${s.total} saved" + if (s.coverTotal > 0) ", covers ${s.covers[0] + s.covers[1] + s.covers[2]}/${s.coverTotal}" else "")
    }

    private fun summary(plan: Plan, why: String, s: State, out: Out, jobs: Int, bytesDelta: Long = 0, coverBytesDelta: Long = 0) {
        write(File(mirrorDir, "summary.lua"), LuaValue.encode(sortedMapOf<String, Any?>(
            "run" to plan.run, "why" to why, "jobs" to jobs.toLong(), "status" to status(s, plan, false),
            "changed" to out.changed.toList(), "written" to out.written.toList(), "written_more" to out.writtenMore.takeIf { it },
            "saved" to out.saved.takeIf { it }, "revalidated" to out.revalidated.takeIf { it },
            "bytes_delta" to bytesDelta, "cover_bytes_delta" to coverBytesDelta)))
    }

    companion object {
        const val STATE = "worker-state.lua"
        const val COVER_BATCH = 20
        /** Requests in flight at once: polite to a home server, and ~4x one connection's rate over Tailscale. */
        const val PARALLEL = 4
        const val AHEAD = 16
        const val CHANGED_MAX = 50
        const val WRITTEN_MAX = 100
        const val STATUS_EVERY_S = 5
        const val STATE_EVERY_S = 30
        const val MAX_BODY = 32L * 1024 * 1024
        const val MAX_COVER = 4L * 1024 * 1024
        const val MB = 1048576.0
    }
}
