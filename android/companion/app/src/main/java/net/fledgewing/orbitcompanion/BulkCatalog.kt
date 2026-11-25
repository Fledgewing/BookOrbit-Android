package net.fledgewing.orbitcompanion

/** Optional generation tables in orbit.db. Publication changes one pointer; readers never
 * observe a half-enumerated manifest. Lists keep membership/ranks, not copies of book JSON. */
object BulkCatalog {
    val schema = listOf(
        "CREATE TABLE IF NOT EXISTS bulk_books (g INTEGER, id INTEGER, item BLOB, manifest BLOB, title TEXT, series TEXT, ix1 INTEGER, ix2 INTEGER, ix TEXT, status TEXT, added TEXT, updated TEXT, PRIMARY KEY(g,id)) WITHOUT ROWID",
        "CREATE TABLE IF NOT EXISTS bulk_members (g INTEGER, kind TEXT, value TEXT, id INTEGER, context BLOB, ix1 INTEGER, ix2 INTEGER, ix TEXT, PRIMARY KEY(g,kind,value,id)) WITHOUT ROWID",
        "CREATE INDEX IF NOT EXISTS bulk_members_id ON bulk_members(g,id)",
        "CREATE TABLE IF NOT EXISTS bulk_ranks (g INTEGER, kind TEXT, direction TEXT, id INTEGER, pos INTEGER, letter TEXT, PRIMARY KEY(g,kind,direction,id)) WITHOUT ROWID",
        "CREATE INDEX IF NOT EXISTS bulk_rank_window ON bulk_ranks(g,kind,direction,pos)",
        "CREATE TABLE IF NOT EXISTS bulk_sections (g INTEGER, section TEXT, pos INTEGER, item BLOB, name TEXT, n INTEGER, reading INTEGER, finished INTEGER, id TEXT, letter TEXT, PRIMARY KEY(g,section,pos)) WITHOUT ROWID",
        "CREATE TABLE IF NOT EXISTS bulk_section_ranks (g INTEGER, section TEXT, direction TEXT, id TEXT, pos INTEGER, PRIMARY KEY(g,section,direction,id)) WITHOUT ROWID",
        "CREATE TABLE IF NOT EXISTS bulk_replies (g INTEGER, path TEXT, body BLOB, PRIMARY KEY(g,path)) WITHOUT ROWID",
        "CREATE TABLE IF NOT EXISTS bulk_heads (g INTEGER, identity TEXT, head BLOB, PRIMARY KEY(g,identity)) WITHOUT ROWID",
        "CREATE TABLE IF NOT EXISTS bulk_pages (g INTEGER, path TEXT, PRIMARY KEY(g,path)) WITHOUT ROWID",
    )
    val tables = listOf("bulk_books", "bulk_members", "bulk_ranks", "bulk_sections", "bulk_replies", "bulk_pages", "bulk_heads", "bulk_section_ranks")
    fun initialize(db: Sql) = schema.forEach { db.exec(it) }
    fun indexParts(value: Any?): List<Any?> {
        val text = value?.toString() ?: return listOf(null, null, null)
        return listOf(text.substringBefore('.').toLongOrNull(), if ('.' in text) text.substringAfter('.').toLongOrNull() else -1L, text)
    }
    fun status(value: Any?) = when (value) {
        "reading", "rereading", "on_hold" -> "reading"
        "read", "skimmed", "abandoned", "finished" -> "finished"
        else -> "unread"
    }
    data class Selection(val from: String, val args: List<Any?>, val order: String, val context: Boolean)
    /** Identical query contract to ko/bulk.lua. Values always bind, never interpolate. */
    fun selection(g: Long, q: Map<String, String>): Selection? {
        if (!q["q"].isNullOrBlank()) return null
        val sort = q["sort"] ?: "recently_added"
        if (sort !in setOf("title", "author", "series", "published", "recently_added", "recently_updated", "recently_read")) return null
        val dir = q["order"] ?: if (sort.startsWith("recently_")) "desc" else "asc"
        if (dir !in setOf("asc", "desc")) return null
        val args = arrayListOf<Any?>(g)
        val cond = arrayListOf("b.g = ?")
        val seriesId = q["seriesId"] ?: q["series"]?.takeIf { it.startsWith("series:") }?.removePrefix("series:")
        val context = q["smartScopeId"] == null && (seriesId != null || q["series"] != null)
        var from = "bulk_books b"
        if (context) {
            from += " JOIN bulk_members s ON s.g=b.g AND s.id=b.id AND s.kind=? AND s.value=?"
            // JOIN arguments precede WHERE arguments.
            args.add(0, CacheStore.u(seriesId ?: q["series"]!!.trim().lowercase()))
            args.add(0, if (seriesId != null) "seriesId" else "series")
        }
        val smart = q["smartScopeId"]
        val selectors = if (smart != null) listOf("smartScopeId") else listOf("libraryId", "collectionId", "author", "format")
        for (key in selectors) q[key]?.takeIf { it.isNotEmpty() }?.let {
            cond.add("EXISTS (SELECT 1 FROM bulk_members m WHERE m.g=b.g AND m.id=b.id AND m.kind=? AND m.value=?)")
            args.add(key); args.add(CacheStore.u(it))
        }
        if (smart == null) {
            q["readStatus"]?.let { cond.add("b.status=?"); args.add(it) }
            q["ids"]?.let { ids ->
                val valid = ids.split(',').mapNotNull(String::toLongOrNull).take(200)
                if (valid.isEmpty()) cond.add("0") else { cond.add("b.id IN (${valid.joinToString(",") { "?" }})"); args.addAll(valid) }
            }
        }
        val sqlDir = dir.uppercase()
        val order = when (sort) {
            "title" -> {
                from += " JOIN bulk_ranks r ON r.g=b.g AND r.id=b.id AND r.kind=? AND r.direction=?"
                args.add(if (context) 2 else 0, sort); args.add(if (context) 3 else 1, dir)
                "r.pos"
            }
            "series" -> if(context) {
                from += " JOIN bulk_ranks tr ON tr.g=b.g AND tr.id=b.id AND tr.kind='title' AND tr.direction='asc'"
                "s.ix1 IS NULL,s.ix1 $sqlDir,s.ix2 $sqlDir,s.ix $sqlDir,tr.pos,b.id"
            } else {
                from += " JOIN bulk_ranks r ON r.g=b.g AND r.id=b.id AND r.kind=? AND r.direction=?"
                args.add(0,sort);args.add(1,dir)
                "r.pos"
            }
            "recently_added", "recently_updated" -> "b.${if (sort == "recently_added") "added" else "updated"} $sqlDir, b.id"
            else -> {
                from += " JOIN bulk_ranks r ON r.g=b.g AND r.id=b.id AND r.kind=? AND r.direction=?"
                args.add(if (context) 2 else 0, sort); args.add(if (context) 3 else 1, dir)
                "r.pos"
            }
        }
        return Selection("$from WHERE ${cond.joinToString(" AND ")}", args, order, context)
    }
    fun window(store: CacheStore, identity: String, page: Int?, size: Int?, offset: Int?): Map<String, Any?>? {
        val g = store.meta("bulk_active")?.toLongOrNull() ?: return null
        val w = MirrorLogic.listWindow(identity) ?: return null
        val q = MirrorLogic.parseQuery(MirrorLogic.splitPath(identity).second)
        val db = store.db()
        if (w.section != null) {
            val section = w.section
            val filter = q["filter"]
            if (filter != null && filter !in setOf("reading", "finished")) return null
            val descending = q["sort"] == "name_desc"
            val from = "bulk_sections b" + if (descending) " JOIN bulk_section_ranks r ON r.g=b.g AND r.section=b.section AND r.id=b.id AND r.direction='name_desc'" else ""
            val condition = "b.g=? AND b.section=?" + if (filter == null) "" else " AND b.$filter>0"
            val args = arrayOf<Any?>(g, section)
            val total = db.query("SELECT count(*) FROM $from WHERE $condition", *args) { it.long(0)!!.toInt() }.first()
            val win = CacheStore.windowOf("section", total, page, size, offset)
            val position = if(descending) "r.pos" else "b.pos"
            val order = if(q["sort"] == "books") "b.n DESC,b.pos" else position
            val items = db.query("SELECT b.item FROM $from WHERE $condition ORDER BY $order LIMIT ? OFFSET ?", *args, win.stop-win.start, win.start) { LuaValue.parse(it.bytes(0)!!) }
            return assemble(items, total, win, offset).apply {
                if(section in setOf("authors","series") && q["sort"] != "books") put("buckets",db.query("SELECT b.letter,min($position),count(*) FROM $from WHERE $condition GROUP BY b.letter ORDER BY min($position)",*args) {Triple(it.text(0) ?: "#",it.long(1)!!,it.long(2)!!)}.map {(letter,first,count)->
                    val index=db.query("SELECT count(*) FROM $from WHERE $condition AND $position<?",*args,first){it.long(0)!!}.first()
                    mapOf("key" to letter,"index" to index,"count" to count)
                })
            }
        }
        val s = selection(g, q) ?: return null
        val total = db.query("SELECT count(*) FROM ${s.from}", *s.args.toTypedArray()) { it.long(0)!!.toInt() }.first()
        val win = CacheStore.windowOf("books", total, page, size, offset)
        val items = db.query("SELECT b.item${if (s.context) ",s.context" else ""} FROM ${s.from} ORDER BY ${s.order} LIMIT ? OFFSET ?",
            *s.args.toTypedArray(), win.stop-win.start, win.start) {
            val item = (LuaValue.parse(it.bytes(0)!!) as Map<*, *>).entries.associate { e -> e.key.toString() to e.value }.toMutableMap()
            if (s.context) (it.bytes(1)?.let(LuaValue::parse) as? Map<*, *>)?.forEach { (k,v) -> item[k.toString()] = v }
            item
        }
        return assemble(items, total, win, offset).apply {
            db.query("SELECT head FROM bulk_heads WHERE g=? AND identity=?", g, CacheStore.u(identity)) { it.bytes(0) }.firstOrNull()?.let { bytes ->
                (LuaValue.parse(bytes) as? Map<*, *>)?.forEach { (k,v) -> put(k.toString(),v) }
            }
            if (q["buckets"] == "1" && q["sort"] in setOf("title", "author")) {
                val buckets = db.query("SELECT r.letter,min(r.pos),count(*) FROM ${s.from} GROUP BY r.letter ORDER BY min(r.pos)", *s.args.toTypedArray()) {
                    Triple(it.text(0) ?: "#", it.long(1)!!, it.long(2)!!)
                }.map { (letter, first, count) ->
                    val index = db.query("SELECT count(*) FROM ${s.from} AND r.pos<?", *s.args.toTypedArray(), first) { it.long(0)!! }.first()
                    mapOf("key" to letter, "index" to index, "count" to count)
                }
                put("buckets", buckets)
            }
            if (s.context) {
                val scope = selection(g, q - "readStatus")!!
                val counts = db.query("SELECT b.status,count(*) FROM ${scope.from} GROUP BY b.status", *scope.args.toTypedArray()) { (it.text(0) ?: "unread") to it.long(1)!! }.toMap()
                put("seriesSummary", mapOf("total" to total.toLong(), "reading" to (counts["reading"] ?: 0L), "finished" to (counts["finished"] ?: 0L)))
            }
        }
    }
    fun saveObservedWindow(store: CacheStore, identity: String, body: Map<*, *>, at: Long): Boolean {
        val g=store.meta("bulk_active")?.toLongOrNull() ?: return false
        store.transaction {
            val head=body.filterKeys {it in setOf("authorSummary")}
            if(head.isNotEmpty()) store.db().exec("INSERT OR REPLACE INTO bulk_heads VALUES (?,?,?)",g,CacheStore.u(identity),LuaValue.encode(head))
            for(value in (body["items"] as? List<*>).orEmpty()) {
                val row=value as? Map<*,*> ?: continue
                val id=(row["id"] as? Number)?.toLong() ?: continue
                val saved=store.bookItem(id) as? Map<*,*> ?: continue
                val updated=saved.entries.associate {it.key.toString() to it.value}.toMutableMap()
                for(field in listOf("progressPercentage","lastReadAt","readStatus","addedAt","updatedAt","hasCover","thumbnailUrl","detailUrl")) updated[field]=row[field]
                store.db().exec("UPDATE bulk_books SET item=?,status=?,added=?,updated=? WHERE g=? AND id=?",LuaValue.encode(updated),status(updated["readStatus"]),updated["addedAt"],updated["updatedAt"],g,id)
                store.db().exec("UPDATE books SET item_at=? WHERE id=?",at,id)
            }
        }
        return true
    }
    fun letter(text: String?): String {
        val folded = java.text.Normalizer.normalize(text.orEmpty().trim(), java.text.Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").uppercase(java.util.Locale.ROOT)
        return folded.firstOrNull()?.takeIf { it in 'A'..'Z' }?.toString() ?: "#"
    }
    private fun assemble(items: List<*>, total: Int, w: CacheStore.Companion.Win, offset: Int?) = sortedMapOf<String, Any?>(
        "items" to items, "total" to total.toLong(), "size" to w.size.toLong(), "page" to (w.start / w.size + 1).toLong(),
        "hasNext" to (w.stop < total), "hasPrevious" to (w.start > 0)).apply { if (offset != null) put("offset", offset.toLong()) }
}
