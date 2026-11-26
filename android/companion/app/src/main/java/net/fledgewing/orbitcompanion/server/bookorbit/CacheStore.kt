package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import java.io.File

/**
 * The offline cache's database (docs/design/sqlite-cache.md): one SQLite file,
 * koreader/settings/orbit-cache/orbit.db, that the companion alone writes and the plugin reads
 * read-only (ko/store.lua). Rollback journal, never WAL. Lists reference books by id, so a book is
 * stored once however many lists name it. Values are the cache's Lua literal format
 * ([LuaValue.encode]), as blobs.
 *
 * Plain JVM over [Sql] (Android's SQLite on the device, JDBC in the unit tests). The schema is
 * shared/fixtures/cache/schema.sql, which CacheStoreTest compares with [SCHEMA].
 */
class CacheStore(val root: File, private val log: (String) -> Unit = { OLog.i(it) }, private val open: (File) -> Sql = { AndroidSql(it) }) : ProjectionStore {
    val file get() = File(root, FILE)
    private var sql: Sql? = null

    /** The open database: created on first use; a file of another schema version is replaced. */
    @Synchronized override fun db(): Sql {
        sql?.let { return it }
        NoMedia.directory(root)
        runCatching { File(root, ".nomedia").let { if (!it.exists()) it.createNewFile() } }
        var s: Sql = CacheSql(open(file), this)
        val v = s.pragma("user_version")?.toIntOrNull() ?: 0
        if (v != VERSION && v != 0) {
            s.close()
            listOf(FILE, "$FILE-journal").forEach { File(root, it).delete() }
            s = CacheSql(open(file), this)
        }
        if (v != VERSION) {
            s.transaction { SCHEMA.forEach { s.exec(it) } }
            s.exec("PRAGMA user_version = $VERSION")
        }
        sql = s
        BulkCatalog.initialize(s)
        LibraryReadModel.initialize(s)
        return s
    }

    @Synchronized override fun close() {
        sql?.close()
        sql = null
    }

    override fun <T> transaction(block: () -> T): T = db().transaction(block)

    // ------------------------------------------------------------------ meta

    override fun meta(k: String): String? = db().query("SELECT v FROM meta WHERE k = ?", k) { it.text(0)?.let(LuaValue::str) }.firstOrNull()

    fun setMeta(k: String, v: Any?) {
        if (v == null) db().exec("DELETE FROM meta WHERE k = ?", k)
        else db().exec("INSERT OR REPLACE INTO meta (k, v) VALUES (?, ?)", k, if (v is String) u(v) else v)
    }

    /** Another account or server: everything goes (the cache, the run's jobs and the pickers' tables). */
    fun wipe(why: String) {
        transaction { (TABLES + BulkCatalog.tables + "library_views").forEach { db().exec("DELETE FROM $it") } }
        log("store: cleared ($why)")
    }

    /** The owner ("user|server") the rows belong to; a different one wipes them first. */
    fun own(owner: String) {
        val was = meta("owner")
        if (was == owner) return
        if (was != null) wipe("account or server changed")
        setMeta("owner", owner)
    }

    // ------------------------------------------------------------------ writes

    /** A book as list pages show it. -> the row is new. */
    fun putItem(item: Map<*, *>, at: Long): Boolean {
        val id = item["id"] as? Long ?: return false
        val db = db()
        db.exec("INSERT OR IGNORE INTO books (id) VALUES (?)", id)
        db.exec("UPDATE books SET item = ?, item_at = ?, search = ? WHERE id = ?", LuaValue.encode(item), at, searchText(item), id)
        return true
    }

    fun putDetail(id: Long, body: Any?, at: Long) {
        val db = db()
        db.exec("INSERT OR IGNORE INTO books (id) VALUES (?)", id)
        db.exec("UPDATE books SET detail = ?, detail_at = ? WHERE id = ?", LuaValue.encode(body), at, id)
        (body as? Map<*, *>)?.let { b -> if (bookItem(id) == null) db.exec("UPDATE books SET search = ? WHERE id = ?", searchText(b), id) }
    }

    fun putEntry(key: String, path: String, body: Any?, at: Long, home: Boolean = MirrorLogic.isHome(path)) {
        val bytes = LuaValue.encode(body)
        db().exec("INSERT OR REPLACE INTO entries (key, path, body, fetched_at, validated_at, home, stale, bytes) VALUES (?, ?, ?, ?, ?, ?, NULL, ?)",
            u(key), u(path), bytes, at, at, if (home) 1L else null, bytes.size.toLong())
    }

    /**
     * One window of a list (a page of any size, at any offset): its positions now name these items.
     * The head (the page's other fields) is taken from the first window. -> the window changed
     * (false for a list saved for the first time).
     */
    fun putWindow(identity: String, kind: String, section: String?, offset: Int, body: Map<*, *>, at: Long): Boolean {
        val items = body["items"] as? List<*> ?: emptyList<Any?>()
        val total = (body["total"] as? Number)?.toInt() ?: (offset + items.size)
        val db = db()
        val known = db.query("SELECT total FROM lists WHERE identity = ?", u(identity)) { it.long(0) }.isNotEmpty()
        val before = if (known) window(identity, null, maxOf(1, items.size), offset) else null
        val head = if (offset == 0) LuaValue.encode(body.filterKeys { it !in PAGING }) else null
        if (!known) {
            db.exec("INSERT INTO lists (identity, kind, section, total, head, fetched_at, validated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                u(identity), kind, section?.let(::u), total.toLong(), head, at, at)
        } else {
            db.exec("UPDATE lists SET total = ?, fetched_at = ?, validated_at = ? WHERE identity = ?", total.toLong(), at, at, u(identity))
            if (head != null) db.exec("UPDATE lists SET head = ? WHERE identity = ?", head, u(identity))
        }
        db.exec("DELETE FROM list_items WHERE identity = ? AND pos >= ?", u(identity), total.toLong())
        items.forEachIndexed { i, it ->
            val item = it as? Map<*, *> ?: return@forEachIndexed
            val pos = (offset + i).toLong()
            val id = item["id"] as? Long
            if (kind == "books" && id != null) {
                putItem(item, at)
                db.exec("INSERT OR REPLACE INTO list_items (identity, pos, book_id, item) VALUES (?, ?, ?, NULL)", u(identity), pos, id)
            } else {
                db.exec("INSERT OR REPLACE INTO list_items (identity, pos, book_id, item) VALUES (?, ?, NULL, ?)", u(identity), pos, LuaValue.encode(item))
            }
        }
        if (before == null) return false
        val after = window(identity, null, maxOf(1, items.size), offset)
        return CacheRules.changed(before, after)
    }

    /** A check found the saved copy unchanged. */
    fun validated(what: Read, at: Long) {
        when (what.table) {
            "lists" -> db().exec("UPDATE lists SET validated_at = ? WHERE identity = ?", at, u(what.ref))
            "books" -> db().exec("UPDATE books SET detail_at = ? WHERE id = ?", at, what.ref.toLong())
            "entries" -> db().exec("UPDATE entries SET validated_at = ?, stale = NULL WHERE key = ?", at, u(what.ref))
        }
    }

    /**
     * A write the plugin made (Cache.writeEffect): the book's item and detail patched, and Home
     * marked stale. -> the number of rows patched.
     */
    fun patch(id: Long?, fields: Map<*, *>, staleHome: Boolean): Int {
        var n = 0
        transaction {
            if (id != null) {
                meta("bulk_active")?.toLongOrNull()?.let { g ->
                    val bytes = db().query("SELECT item FROM bulk_books WHERE g=? AND id=?", g, id) { it.bytes(0) }.firstOrNull()
                    val body = bytes?.let(LuaValue::parse) as? Map<*, *>
                    if (body != null) {
                        val updated = patched(body, id, fields) as Map<*, *>
                        db().exec("UPDATE bulk_books SET item=?,status=? WHERE g=? AND id=?", LuaValue.encode(updated), BulkCatalog.status(updated["readStatus"]), g, id)
                        n++
                    }
                }
                val row = db().query("SELECT item, detail FROM books WHERE id = ?", id) { it.bytes(0) to it.bytes(1) }.firstOrNull()
                if (row != null) {
                    val item = row.first?.let { LuaValue.parse(it) }
                    val detail = row.second?.let { LuaValue.parse(it) }
                    if (item is Map<*, *>) { db().exec("UPDATE books SET item = ? WHERE id = ?", LuaValue.encode(patched(item, id, fields)), id); n++ }
                    if (detail is Map<*, *>) { db().exec("UPDATE books SET detail = ? WHERE id = ?", LuaValue.encode(patched(detail, id, fields)), id); n++ }
                }
                // Other replies that name the book (Home's sections): patched where they are.
                for ((key, body) in db().query("SELECT key, body FROM entries") { it.text(0)!! to it.bytes(1) }) { // key: as stored
                    val b = body?.let { LuaValue.parse(it) } ?: continue
                    if (id !in CacheRules.ids(b)) continue
                    db().exec("UPDATE entries SET body = ? WHERE key = ?", LuaValue.encode(patched(b, id, fields)), key)
                    n++
                }
            }
            if (staleHome) db().exec("UPDATE entries SET stale = 1 WHERE home = 1")
        }
        return n
    }

    // ------------------------------------------------------------------ reads

    /** Where a read came from, for [validated]: table and key. */
    data class Read(val body: Any?, val validatedAt: Long, val stale: Boolean, val table: String, val ref: String)

    /**
     * A list window built from the rows (Cache.window): null when a position it needs isn't saved.
     * page, size, offset: the read's own (size null: the list's default).
     */
    fun window(identity: String, page: Int?, size: Int?, offset: Int?): Map<String, Any?>? {
        BulkCatalog.window(this, identity, page, size, offset)?.let { return it }
        val l = db().query("SELECT kind, total, head FROM lists WHERE identity = ?", u(identity)) {
            Triple(it.text(0) ?: "books", it.long(1)?.toInt() ?: 0, it.bytes(2))
        }.firstOrNull() ?: return null
        val (kind, total, head) = l
        val w = windowOf(kind, total, page, size, offset)
        val items = db().query("SELECT li.pos, COALESCE(b.item, li.item) FROM list_items li LEFT JOIN books b ON b.id = li.book_id " +
            "WHERE li.identity = ? AND li.pos >= ? AND li.pos < ? ORDER BY li.pos", u(identity), w.start.toLong(), w.stop.toLong()) {
            it.bytes(1)?.let { b -> LuaValue.parse(b) }
        }
        if (items.size != w.stop - w.start || items.any { it == null }) return null
        val out = java.util.TreeMap<String, Any?>()
        (head?.let { LuaValue.parse(it) } as? Map<*, *>)?.forEach { (k, v) -> if (k !in PAGING) out[k.toString()] = v }
        out["items"] = items
        out["total"] = total.toLong()
        out["size"] = w.size.toLong()
        out["page"] = (w.start / w.size + 1).toLong()
        if (offset != null) out["offset"] = offset.toLong()
        out["hasNext"] = w.stop < total
        out["hasPrevious"] = w.start > 0
        return out
    }

    fun bookItem(id: Long): Any? {
        val bytes = meta("bulk_active")?.toLongOrNull()?.let { g -> db().query("SELECT item FROM bulk_books WHERE g=? AND id=?", g, id) { it.bytes(0) }.firstOrNull() }
            ?: db().query("SELECT item FROM books WHERE id=?", id) { it.bytes(0) }.firstOrNull()
        return bytes?.let(LuaValue::parse)
    }

    /** A book's saved detail and when it was last checked. */
    fun detail(id: Long): Pair<Any?, Long>? =
        db().query("SELECT detail, detail_at FROM books WHERE id = ? AND detail IS NOT NULL", id) { LuaValue.parse(it.bytes(0)!!) to (it.long(1) ?: 0L) }.firstOrNull()

    fun hasDetail(id: Long): Boolean = db().query("SELECT 1 FROM books WHERE id = ? AND detail IS NOT NULL", id) { 1 }.isNotEmpty()

    /**
     * What the plugin would serve for a read (OC.read): a list window, a book's detail when the path
     * is the detail template filled with an id, else the entry under its key.
     */
    fun read(key: String, path: String, detailTemplate: String?, sentinel: String = MirrorLogic.SENTINEL): Read? {
        val w = MirrorLogic.listWindow(path)
        if (w != null) {
            val q = MirrorLogic.parseQuery(MirrorLogic.splitPath(path).second)
            val body = window(w.identity, q["page"]?.toIntOrNull(), q["size"]?.toIntOrNull(), q["offset"]?.toIntOrNull()) ?: return null
            val at = if (meta("bulk_active") != null) meta("bulk_at")?.toLongOrNull() ?: 0L else db().query("SELECT validated_at FROM lists WHERE identity = ?", u(w.identity)) { it.long(0) ?: 0L }.firstOrNull() ?: 0L
            return Read(body, at, false, "lists", w.identity)
        }
        detailId(path, detailTemplate, sentinel)?.let { id ->
            val saved = detail(id)
            if (saved != null) return Read(saved.first, saved.second, false, "books", id.toString())
            val stub = if (meta("bulk_active") != null) bookItem(id) else null
            return stub?.let { Read(it, 0L, true, "books", id.toString()) }
        }
        return db().query("SELECT body, validated_at, stale FROM entries WHERE key = ?", u(key)) {
            Read(it.bytes(0)?.let { b -> LuaValue.parse(b) }, it.long(1) ?: 0L, it.long(2) == 1L, "entries", key)
        }.firstOrNull()
    }

    /**
     * Saves a reply where [read] finds it again. mode "full" takes the reply as it is; otherwise
     * the saved random pick is kept (LuaValue.settle). -> the stored body.
     */
    fun save(key: String, path: String, reply: Any?, at: Long, detailTemplate: String?, sentinel: String = MirrorLogic.SENTINEL): Boolean {
        val w = MirrorLogic.listWindow(path)
        if (w != null && reply is Map<*, *>) {
            if (w.kind == "books" && BulkCatalog.saveObservedWindow(this, w.identity, reply, at)) return true
            val q = MirrorLogic.parseQuery(MirrorLogic.splitPath(path).second)
            val size = q["size"]?.toIntOrNull() ?: (if (w.kind == "books") 20 else (reply["items"] as? List<*>)?.size ?: 0)
            val offset = q["offset"]?.toIntOrNull() ?: (((q["page"]?.toIntOrNull() ?: 1) - 1) * maxOf(1, size))
            return transaction { putWindow(w.identity, w.kind, w.section, offset, reply, at) }
        }
        detailId(path, detailTemplate, sentinel)?.let { id -> transaction { putDetail(id, reply, at) }; return true }
        putEntry(key, path, reply, at)
        return true
    }

    // ------------------------------------------------------------------ the storage limit

    /** Browsing entries (not Home) with their sizes, oldest first: what the storage limit may drop. */
    fun entrySizes(): List<StorageLogic.Item> = db().query("SELECT key, bytes, fetched_at, home FROM entries") {
        StorageLogic.Item("e:" + LuaValue.str(it.text(0)!!), it.long(1) ?: 0L, it.long(2) ?: 0L, if (it.long(3) == 1L) "kept" else "cache")
    }

    fun dropEntry(key: String) = db().exec("DELETE FROM entries WHERE key = ?", u(key))

    /** Reusable SQLite pages and the transient rollback journal are not cache growth.
     * Charging them repeatedly prevented a smaller replacement generation from ever starting. */
    fun fileBytes(): Long {
        val pages = db().pragma("page_count")?.toLongOrNull() ?: 0L
        val free = db().pragma("freelist_count")?.toLongOrNull() ?: 0L
        val size = db().pragma("page_size")?.toLongOrNull() ?: 4096L
        return maxOf(0L, pages - free) * size
    }

    fun reclaimStorage() {
        val allocated = file.length()
        val live = fileBytes()
        log("storage: database allocated=$allocated live=$live reusable=${maxOf(0L, allocated-live)}")
        // Only the companion writer calls this, outside a transaction. Avoid rewriting
        // a healthy database on every count; native books are outside this database.
        if (allocated - live >= maxOf(16L * 1024 * 1024, allocated / 4)) db().exec("VACUUM")
    }

    /** A complete bulk generation supersedes the old combinatorial list crawl. */
    fun retireLegacyCatalog() = transaction {
        db().exec("DELETE FROM list_items")
        db().exec("DELETE FROM lists")
        db().exec("DELETE FROM jobs")
    }

    // ------------------------------------------------------------------ covers kept by "Save every cover"

    fun keepCovers(names: Collection<String>) = transaction { names.forEach { db().exec("INSERT OR IGNORE INTO cover_keep (name) VALUES (?)", it) } }

    fun coversKept(): Set<String> = db().query("SELECT name FROM cover_keep") { it.text(0)!! }.toHashSet()

    companion object {
        const val FILE = "orbit.db"

        /**
         * A model byte string (ISO-8859-1, one char per byte) as the text SQLite stores: its bytes are
         * UTF-8, so the plugin, binding the same bytes from Lua, finds the same row.
         */
        fun u(s: String): String = LuaValue.utf8(s)
        const val VERSION = 1

        /** shared/fixtures/cache/schema.sql, statement by statement. */
        val SCHEMA = listOf(
            "CREATE TABLE meta (k TEXT PRIMARY KEY, v) WITHOUT ROWID",
            "CREATE TABLE books (id INTEGER PRIMARY KEY, item BLOB, detail BLOB, item_at INTEGER, detail_at INTEGER, search TEXT)",
            "CREATE TABLE lists (identity TEXT PRIMARY KEY, kind TEXT, section TEXT, total INTEGER, head BLOB, fetched_at INTEGER, validated_at INTEGER) WITHOUT ROWID",
            "CREATE TABLE list_items (identity TEXT, pos INTEGER, book_id INTEGER, item BLOB, PRIMARY KEY (identity, pos)) WITHOUT ROWID",
            "CREATE INDEX list_items_book ON list_items (book_id)",
            "CREATE TABLE entries (key TEXT PRIMARY KEY, path TEXT, body BLOB, fetched_at INTEGER, validated_at INTEGER, home INTEGER, stale INTEGER, bytes INTEGER) WITHOUT ROWID",
            "CREATE TABLE cover_keep (name TEXT PRIMARY KEY) WITHOUT ROWID",
            "CREATE TABLE tags (name BLOB PRIMARY KEY, n INTEGER) WITHOUT ROWID",
            "CREATE TABLE scopes (kind TEXT, id TEXT, label BLOB, n INTEGER, PRIMARY KEY (kind, id)) WITHOUT ROWID",
            "CREATE TABLE leave_out (rule TEXT, book_id INTEGER, PRIMARY KEY (rule, book_id)) WITHOUT ROWID",
            "CREATE TABLE jobs (kind TEXT, ref TEXT, state INTEGER, tries INTEGER, PRIMARY KEY (kind, ref)) WITHOUT ROWID",
        )
        val TABLES = listOf("meta", "books", "lists", "list_items", "entries", "cover_keep", "tags", "scopes", "leave_out", "jobs")

        private val PAGING = setOf("items", "page", "size", "offset", "hasNext", "hasPrevious", "nextUrl", "previousUrl")

        data class Win(val start: Int, val stop: Int, val size: Int)

        /** Cache.window: the positions a read asks for. */
        fun windowOf(kind: String, total: Int, page: Int?, size: Int?, offset: Int?): Win {
            var sz = size ?: if (kind == "books") 20 else total
            if (sz < 1) sz = 1
            val start = offset ?: (((page ?: 1) - 1) * sz)
            return Win(start, maxOf(start, minOf(total, start + sz)), sz)
        }

        /** The book id when path is the detail template filled with an id (Cache.detailId). */
        fun detailId(path: String, template: String?, sentinel: String): Long? {
            if (template == null) return null
            val i = template.indexOf(sentinel)
            if (i < 0) return null
            val pre = template.substring(0, i)
            val post = template.substring(i + sentinel.length)
            if (!path.startsWith(pre) || !path.endsWith(post) || path.length <= pre.length + post.length) return null
            val mid = path.substring(pre.length, path.length - post.length)
            return mid.takeIf { s -> s.all { it in '0'..'9' } && s.length <= 12 }?.toLongOrNull()
        }

        /** books.search: title, authors and series on three lines (offline search; LIKE ignores ASCII case). */
        fun searchText(b: Map<*, *>): String {
            fun s(v: Any?) = (v as? String)?.let(LuaValue::utf8) ?: ""
            val authors = (b["authors"] as? List<*>)?.joinToString(", ") { s(it) } ?: ""
            return listOf(s(b["title"]), authors, s(b["seriesName"])).joinToString("\n")
        }

        /** On a copy: every table whose id is the book's gets the fields (an empty map clears one). */
        fun patched(v: Any?, id: Long, fields: Map<*, *>, depth: Int = 0): Any? {
            if (depth > 30) return v
            return when (v) {
                is Map<*, *> -> {
                    val out = java.util.TreeMap<String, Any?>()
                    for ((k, x) in v) out[k.toString()] = patched(x, id, fields, depth + 1)
                    if ((v["id"] as? Number)?.toLong() == id) for ((k, x) in fields) {
                        if ((x is Map<*, *> && x.isEmpty()) || (x is List<*> && x.isEmpty())) out.remove(k.toString()) else out[k.toString()] = x
                    }
                    out
                }
                is List<*> -> v.map { patched(it, id, fields, depth + 1) }
                else -> v
            }
        }
    }
}
