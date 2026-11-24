package net.fledgewing.orbitcompanion

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URLEncoder

/**
 * The sleep screen's pool refresh (docs/design/lock-screen.md R1-R4b, X1-X7), on the cache
 * worker's thread (docs/design/companion-worker.md; was the plugin's Sleep.build in a forked
 * child). Lists what is due (Leave out's member lists once a day, the shuffle bag), picks and
 * checks the books, fetches their covers by ETag and writes the files in koreader/settings/
 * orbit-sleep/ (android/docs/INTERFACE.md "Sleep screen"): pool.json, covers/, leave_out.lua,
 * bag.lua and scopes.json. Never logs or writes the login.
 */
class SleepPoolBuilder(
    private val dir: File,
    private val http: CacheWorker.Http,
    private val now: () -> Long = { System.currentTimeMillis() / 1000 },
    private val rand: (Int) -> Int = { n -> 1 + kotlin.random.Random.nextInt(n) },
) {
    /**
     * from: Pick from; rules: Leave out (one per line); openId: the book open now (never shown);
     * every: Every sleep; storageLimitMb: for pool.json (the sharp covers' share).
     */
    data class Ask(val from: String, val rules: List<String>, val openId: Long?, val every: Boolean, val storageLimitMb: Long?, val creds: CacheWorker.Creds)

    private fun get(c: CacheWorker.Creds, path: String): Any? {
        val r = http.get(c.server + path, mapOf("accept" to "application/json", "x-auth-user" to c.user, "x-auth-key" to c.key), null, CacheWorker.MAX_BODY)
        if (r.code != 200 || r.body == null) return null
        return try { org.json.JSONTokener(String(r.body, Charsets.UTF_8)).nextValue() } catch (e: Exception) { null }
    }

    private fun q(path: String, params: List<Pair<String, Any>>) =
        path + "?" + params.joinToString("&") { (k, v) -> k + "=" + URLEncoder.encode(v.toString(), "UTF-8") }

    private fun book(o: JSONObject): Map<String, Any?> = mapOf("id" to o.optLong("id").takeIf { it > 0 }, "title" to o.optString("title"),
        "hasCover" to (if (o.has("hasCover")) o.optBoolean("hasCover") else null), "readStatus" to o.optString("readStatus").ifEmpty { null },
        "tags" to o.optJSONArray("tags")?.let { a -> (0 until a.length()).map { a.optString(it) } })

    /** Every page of a smart scope's or collection's books, up to [max] ids. */
    fun listMembers(c: CacheWorker.Creds, kind: String, id: Long, max: Int): List<Long>? {
        val ids = LinkedHashSet<Long>()
        for (page in 1..(max + SleepPoolLogic.PAGE_SIZE - 1) / SleepPoolLogic.PAGE_SIZE) {
            val body = get(c, q("/koreader/plugin/catalog/books", listOf("page" to page, "size" to SleepPoolLogic.PAGE_SIZE,
                "sort" to "recently_added", "order" to "desc", (if (kind == "scope") "smartScopeId" else "collectionId") to id))) as? JSONObject ?: return null
            val items = body.optJSONArray("items") ?: JSONArray()
            for (i in 0 until items.length()) {
                val bid = items.optJSONObject(i)?.optLong("id") ?: 0
                if (bid > 0 && ids.size < max) ids.add(bid)
            }
            if (!body.optBoolean("hasNext") || ids.size >= max) break
        }
        return ids.toList()
    }

    private fun readLua(name: String): Map<*, *>? = File(dir, name).takeIf { it.isFile }?.let { runCatching { LuaValue.parse(it.readBytes()) as? Map<*, *> }.getOrNull() }

    private fun write(f: File, bytes: ByteArray): Boolean {
        f.parentFile?.mkdirs()
        val tmp = File(f.parentFile, f.name + ".orbit-new")
        return try { tmp.writeBytes(bytes); tmp.renameTo(f) || run { tmp.delete(); false } } catch (e: Exception) { tmp.delete(); false }
    }

    /** The cover by its ETag (a 304 keeps the file). */
    private fun download(c: CacheWorker.Creds, id: Long, f: File): Boolean {
        val etag = File(f.path + ".etag")
        val h = HashMap(mapOf("accept" to "image/jpeg,image/*", "Accept-Encoding" to "identity", "x-auth-user" to c.user, "x-auth-key" to c.key))
        if (f.isFile && etag.isFile) h["If-None-Match"] = etag.readText()
        val part = File(f.path + ".part")
        val r = http.get(c.server + "/koreader/plugin/catalog/books/$id/thumbnail", h, part, CacheWorker.MAX_COVER)
        if (r.code == 304 && f.isFile) { f.setLastModified(System.currentTimeMillis()); return true }
        if (r.code != 200 || !part.isFile || part.length() == 0L) { part.delete(); return false }
        if (!part.renameTo(f)) { part.delete(); return false }
        if (r.etag != null) etag.writeText(r.etag) else etag.delete()
        return true
    }

    /** The companion's own state.json and pool.json: what it showed, how often, and the ready covers. */
    private fun shown(): Pair<Long?, Map<Long, Int>> = try {
        val o = JSONObject(File(dir, "state.json").readText())
        val shows = HashMap<Long, Int>()
        o.optJSONObject("shows")?.let { s -> s.keys().forEach { k -> k.toLongOrNull()?.let { shows[it] = s.optInt(k) } } }
        o.optLong("shown").takeIf { it > 0 } to shows
    } catch (e: Exception) { null to emptyMap() }

    private fun prevIds(): List<Long> = try {
        val a = JSONObject(File(dir, "pool.json").readText()).optJSONArray("items") ?: JSONArray()
        (0 until a.length()).mapNotNull { a.optJSONObject(it)?.optLong("id")?.takeIf { id -> id > 0 } }
    } catch (e: Exception) { emptyList() }

    /** Returns the summary: { items, kept, probed, left_out, unknown, skipped, carried, retired, fallback, listed, scopes }. */
    fun build(a: Ask): Map<String, Any?> {
        File(dir, "covers").mkdirs()
        val t = now()
        val sum = sortedMapOf<String, Any?>()
        var probed = 0; var leftOut = 0; var unknown = 0; var skipped = 0
        val listed = ArrayList<String>()
        // Leave out's member lists, once a day (X5).
        val lo = HashMap<String, Any?>()
        (readLua("leave_out.lua") ?: emptyMap<Any?, Any?>()).forEach { (k, v) -> lo[k.toString()] = v }
        val memberRules = SleepPoolLogic.memberRules(a.rules)
        for (p in memberRules) {
            val e = lo[p.key] as? Map<*, *>
            if (e == null || SleepPoolLogic.due((e["at"] as? Number)?.toLong(), t)) {
                val ids = listMembers(a.creds, p.kind, p.id, SleepPoolLogic.LEAVE_OUT_MAX)
                if (ids != null) { lo[p.key] = sortedMapOf<String, Any?>("at" to t, "ids" to ids); listed.add("${p.key}=${ids.size}") }
                else listed.add("${p.key} failed")
            }
        }
        val members = HashMap<String, Set<Long>>()
        val keepLo = sortedMapOf<String, Any?>()
        for (p in memberRules) {
            val e = lo[p.key] as? Map<*, *> ?: continue
            members[p.key] = (e["ids"] as? List<*>)?.mapNotNull { (it as? Number)?.toLong() }?.toHashSet() ?: emptySet()
            keepLo[p.key] = e
        }
        write(File(dir, "leave_out.lua"), LuaValue.encode(keepLo))

        // The candidates, in the order they would be shown.
        val candidates = ArrayList<Long>()
        val known = HashMap<Long, Map<String, Any?>>()
        val from = SleepPoolLogic.parseFrom(a.from) ?: SleepPoolLogic.From("list", type = SleepPoolLogic.LISTS[0].second)
        var bag: SleepPoolLogic.Bag? = null
        val (shown, shows) = shown()
        if (from.kind == "list") {
            val order = listOf(from.type) + SleepPoolLogic.LISTS.map { it.second }.filter { it != from.type }
            for (type in order) {
                val books = ((get(a.creds, "/koreader/plugin/catalog/dashboard/sections/$type") as? JSONObject)
                    ?.optJSONObject("section")?.optJSONArray("books")) ?: JSONArray()
                if (books.length() == 0) continue
                for (i in 0 until books.length()) {
                    val b = books.optJSONObject(i)?.let { book(it) } ?: continue
                    val id = b["id"] as? Long ?: continue
                    candidates.add(id); known[id] = b
                }
                if (type != from.type) sum["fallback"] = type
                break
            }
        } else {
            bag = SleepPoolLogic.Bag.of(readLua("bag.lua"))
            if (bag.source != a.from) bag = SleepPoolLogic.Bag(a.from)
            if (SleepPoolLogic.due(bag.at, t)) {
                val ids = listMembers(a.creds, from.kind, from.id, SleepPoolLogic.BAG_MAX)
                if (ids != null) { SleepPoolLogic.bagSync(bag, ids, rand); bag.at = t; listed.add("${a.from}=${ids.size}") }
                else listed.add("${a.from} failed")
            }
            if (!a.every) SleepPoolLogic.bagSeek(bag, shown)
            candidates.addAll(SleepPoolLogic.bagNext(bag, rand))
        }

        // Checked one by one, covers fetched for the ones kept: BATCH of them (R3).
        val items = ArrayList<Map<String, Any?>>()
        val wanted = HashSet<String>()
        val taken = HashSet<Long>()
        val (carry, retired) = if (a.every) SleepPoolLogic.carry(prevIds(), shows) else emptyList<Long>() to emptySet()
        fun cover(id: Long) = File(dir, "covers/$id.jpg")
        fun tryBook(id: Long) {
            if (!taken.add(id)) return
            probed++
            var b = known[id]
            var detail: Map<String, Any?>? = null
            if (b == null || SleepPoolLogic.needsTags(a.rules)) {
                detail = (get(a.creds, "/koreader/plugin/catalog/books/$id") as? JSONObject)?.let { book(it) }
                b = b ?: detail
            }
            if (!SleepPoolLogic.eligible(b, a.openId)) { skipped++; return }
            @Suppress("UNCHECKED_CAST")
            when (SleepPoolLogic.check(id, a.rules, members, detail?.get("tags") as? List<String>)) {
                "out" -> { leftOut++; return }
                "unknown" -> { unknown++; return } // failed closed (X7)
            }
            if (download(a.creds, id, cover(id)) && cover(id).isFile) {
                items.add(mapOf("id" to id, "title" to (b!!["title"] ?: ""), "file" to "covers/$id.jpg"))
                wanted.add("$id.jpg")
            } else skipped++
        }
        // The bag's last shown book stays first, so the companion's "next" is the bag's next.
        val prev = bag?.prev
        if (bag != null && !a.every && prev != null && cover(prev).isFile && SleepPoolLogic.check(prev, a.rules, members, null) == "keep") {
            items.add(mapOf("id" to prev, "title" to "", "file" to "covers/$prev.jpg"))
            wanted.add("$prev.jpg")
        }
        val first = items.size
        fun full() = items.size - first >= SleepPoolLogic.BATCH || probed >= SleepPoolLogic.PROBE_MAX
        for (id in carry) { if (full()) break; tryBook(id) }
        sum["carried"] = (items.size - first).toLong()
        val fresh = HashSet<Long>()
        for (id in candidates) {
            if (full()) break
            if (id in retired || id in taken) continue
            val before = items.size
            tryBook(id)
            if (items.size > before) fresh.add(id)
        }
        // A bag whose rest is all left out or read: shuffled again, once.
        if (bag != null && items.size == first && bag.order.isNotEmpty() && probed < SleepPoolLogic.PROBE_MAX) {
            bag.pos = bag.order.size
            for (id in SleepPoolLogic.bagNext(bag, rand)) { if (full()) break; tryBook(id) }
        }
        // Every retired one and nothing new: they stay, and the companion keeps cycling them.
        if (items.size == first && retired.isNotEmpty()) {
            for (id in prevIds()) {
                if (id in retired) { taken.remove(id); tryBook(id) }
                if (items.size - first >= SleepPoolLogic.BATCH) break
            }
        }
        if (bag != null && a.every) SleepPoolLogic.bagTake(bag, fresh)
        if (bag != null) write(File(dir, "bag.lua"), LuaValue.encode(bag.toModel()))
        // Covers no longer in the pool go.
        File(dir, "covers").listFiles()?.forEach { f ->
            if (Regex("^\\d+\\.jpg$").matches(f.name) && f.name !in wanted) { f.delete(); File(f.path + ".etag").delete() }
        }
        val doc = JSONObject().put("v", 1).put("at", t * 1000).put("source", a.from)
            .put("items", JSONArray(items.map { JSONObject(it) }))
            .put("server", a.creds.server).put("user", a.creds.user)
        a.storageLimitMb?.let { doc.put("storage_limit_mb", it) }
        write(File(dir, "pool.json"), doc.toString().toByteArray())
        if (scopes(a.creds)) sum["scopes"] = true
        sum["items"] = items.size.toLong(); sum["kept"] = (items.size - first).toLong(); sum["probed"] = probed.toLong()
        sum["left_out"] = leftOut.toLong(); sum["unknown"] = unknown.toLong(); sum["skipped"] = skipped.toLong()
        sum["retired"] = retired.size.toLong(); sum["listed"] = listed; sum["every"] = a.every
        return sum
    }

    /** Pick from's and Leave out's choices, for the plugin's pickers: scopes.json. */
    fun scopes(c: CacheWorker.Creds): Boolean {
        val scopes = listSection(c, "smart-scopes") ?: return false
        val collections = listSection(c, "collections") ?: return false
        return write(File(dir, "scopes.json"), JSONObject().put("v", 1).put("at", now()).put("scopes", scopes).put("collections", collections).toString().toByteArray())
    }

    /** Leave out's tag picker: the tags in the saved book details, with counts (tags.json). [details]: model byte strings. */
    fun tags(details: List<List<String>>): Int {
        val tags = SleepPoolLogic.tagCounts(details).take(TAGS_MAX)
        val a = JSONArray(tags.map { JSONObject().put("tag", LuaValue.utf8(it.tag)).put("label", LuaValue.utf8(it.label)).put("count", it.count) })
        write(File(dir, "tags.json"), JSONObject().put("v", 1).put("at", now()).put("details", details.size).put("tags", a).toString().toByteArray())
        return tags.size
    }

    companion object {
        const val TAGS_MAX = 200
        const val TAG_DETAILS_MAX = 2000
    }

    /** Every page of one section list: { id, title, count }. */
    fun listSection(c: CacheWorker.Creds, section: String): JSONArray? {
        val out = JSONArray()
        val seen = HashSet<Long>()
        for (page in 1..20) {
            val body = get(c, q("/koreader/plugin/catalog/sections/$section", listOf("page" to page, "size" to SleepPoolLogic.PAGE_SIZE))) as? JSONObject
                ?: return if (page == 1) null else out
            var new = 0
            val items = body.optJSONArray("items") ?: JSONArray()
            for (i in 0 until items.length()) {
                val e = items.optJSONObject(i) ?: continue
                val id = e.optLong("id")
                if (id > 0 && seen.add(id)) {
                    val o = JSONObject().put("id", id).put("title", e.optString("title"))
                    if (e.has("count") && !e.isNull("count")) o.put("count", e.optLong("count"))
                    out.put(o); new++
                }
            }
            if (!body.optBoolean("hasNext") || new == 0) break
        }
        return out
    }
}
