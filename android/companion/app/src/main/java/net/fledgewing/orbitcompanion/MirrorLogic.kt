package net.fledgewing.orbitcompanion

/**
 * The offline mirror's rules (docs/design/companion-worker.md "Step 2"): the cache's keys and
 * file names, which must match the plugin's (orbit.koplugin logic/cache.lua `Cache.key`,
 * `Cache.hash`, `Cache.listWindow`), mirror pages, the retry plan, re-paging and the limit note,
 * which only the companion runs, and the cache's entry format (a Lua literal that `Cache.decode`
 * loads). Pure, and checked against shared/fixtures/cache/worker.json (CacheWorkerTest;
 * test_logic.lua reads the same file) and cases.json (CacheRulesTest).
 *
 * Keys and paths are byte strings, as in Lua: held here as ISO-8859-1 strings (one char per
 * byte), so a percent-decoded UTF-8 name keeps its bytes and its hash.
 */
object MirrorLogic {
    const val PAGE = 100
    /** The id a plan's templates carry in place of each entry's (Mirror.SENTINEL). */
    const val SENTINEL = "987654321"

    /** Home's replies (kept, marked stale by a write). */
    fun isHome(path: String): Boolean = splitPath(path).first.contains("/catalog/dashboard")
    const val SMALL_PAGE = 25
    const val TRIES = 3
    const val RETRY_S = 5

    private fun isUnreserved(c: Char): Boolean =
        c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c == '-' || c == '_' || c == '.' || c == '~'

    /** `unescape`: "+" is a space, %XX a byte. */
    fun unescape(s: String): String {
        val out = StringBuilder()
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '+') { out.append(' '); i++; continue }
            if (c == '%' && i + 2 < s.length) {
                val h = s.substring(i + 1, i + 3)
                if (h.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) {
                    out.append(h.toInt(16).toChar()); i += 3; continue
                }
            }
            out.append(c)
            i++
        }
        return out.toString()
    }

    /** `escape`: every byte but [A-Za-z0-9-_.~] as %XX. */
    fun escape(s: String): String {
        val out = StringBuilder()
        for (c in s) {
            if (isUnreserved(c)) out.append(c) else out.append('%').append(String.format(java.util.Locale.ROOT, "%02X", c.code and 0xff))
        }
        return out.toString()
    }

    fun splitPath(path: String): Pair<String, String> {
        val i = path.indexOf('?')
        return if (i < 0) path to "" else path.substring(0, i) to path.substring(i + 1)
    }

    /** `Cache.parseQuery`: name -> value; later duplicates win. */
    fun parseQuery(q: String): MutableMap<String, String> {
        val out = LinkedHashMap<String, String>()
        for (pair in q.split('&')) {
            if (pair.isEmpty()) continue
            val eq = pair.indexOf('=')
            val k = if (eq < 0) pair else pair.substring(0, eq)
            val v = if (eq < 0) "" else pair.substring(eq + 1)
            if (k.isNotEmpty()) out[unescape(k)] = unescape(v)
        }
        return out
    }

    private fun sortedKeys(query: Map<String, String>): List<String> =
        query.filterValues { it.isNotEmpty() }.keys.sortedWith { a, b -> a.compareTo(b) }

    fun normQuery(query: Map<String, String>): String = sortedKeys(query).joinToString("&") { "$it=${query[it]}" }

    fun encQuery(query: Map<String, String>): String = sortedKeys(query).joinToString("&") { "${escape(it)}=${escape(query[it]!!)}" }

    fun normServer(s: String): String = s.lowercase().trimEnd('/')

    /** `Cache.key` for a GET of path (path may carry its query). */
    fun key(account: String, server: String, path: String): String {
        val (p, q) = splitPath(path)
        return listOf(account, normServer(server), "GET", p, normQuery(parseQuery(q))).joinToString("|")
    }

    /**
     * `Cache.hash`: the entry's file name. FNV-1a as the plugin computes it in LuaJIT, step for
     * step: bit.bxor and bit.tobit work on signed 32-bit values and the multiply is a double (its
     * low bits rounded off), so this is not textbook FNV-1a; the names must match the plugin's.
     */
    fun hash(key: String): String {
        var h = 2166136261.0
        for (c in key) {
            val x = tobit(h) xor (c.code and 0xff)
            h = tobit(luaMod(x.toDouble() * 16777619.0, 4294967296.0)).toDouble()
        }
        return String.format(java.util.Locale.ROOT, "%08x", luaMod(h, 4294967296.0).toLong())
    }

    /** LuaJIT's bit.tobit: the number's low 32 bits, signed. */
    private fun tobit(d: Double): Int = luaMod(d, 4294967296.0).toLong().toInt()

    /** Lua's a % b on numbers: a - floor(a / b) * b. */
    private fun luaMod(a: Double, b: Double): Double = a - Math.floor(a / b) * b

    data class Window(val identity: String, val kind: String, val section: String?)

    private val SECTION = Regex("/catalog/sections/([A-Za-z0-9-]+)$")

    /** `Cache.listWindow`: a books list or a section index (not a search), by identity. */
    fun listWindow(path: String): Window? {
        val (p, q) = splitPath(path)
        val books = p.endsWith("/catalog/books")
        val section = SECTION.find(p)?.groupValues?.get(1)
        if (!books && section == null) return null
        val query = parseQuery(q)
        if (!query["q"].isNullOrEmpty()) return null
        query.remove("page"); query.remove("size"); query.remove("offset")
        val rest = encQuery(query)
        return Window(p + if (rest.isNotEmpty()) "?$rest" else "", if (books) "books" else "section", section)
    }

    /** A list identity's mirror page. size: null for PAGE (shared/fixtures/cache/worker.json "windows"). */
    fun mirrorPage(identity: String, page: Int, size: Int?): String {
        val (p, q) = splitPath(identity)
        val query = parseQuery(q)
        query["page"] = page.toString()
        query["size"] = (size ?: PAGE).toString()
        return p + "?" + encQuery(query)
    }

    fun pageCount(total: Int, size: Int?): Int = if (total <= 0) 1 else (total + (size ?: PAGE) - 1) / (size ?: PAGE)

    /** Pages to fetch (2..new) and to drop (past the new end). */
    fun repage(oldTotal: Int, newTotal: Int, size: Int?): Pair<List<Int>, List<Int>> {
        val o = pageCount(oldTotal, size)
        val n = pageCount(newTotal, size)
        return (2..n).toList() to ((n + 1)..o).toList()
    }

    data class Retry(val skip: Boolean, val waitS: Int = 0, val size: Int? = null)

    /** A mirror request with no answer: wait, a smaller page, or skip (cases.json "mirror.retry"). size: the list page's size (null: not a list page). */
    fun retry(tries: Int, size: Int?, page: Int?): Retry {
        if (tries >= TRIES) return Retry(true)
        var s = size
        if (size != null && page == 1 && size > SMALL_PAGE) s = maxOf(SMALL_PAGE, size / 2)
        return Retry(false, RETRY_S * (1 shl (tries - 1)), s)
    }

    /** The companion's status line while a Full refresh saves (docs/design/sqlite-cache.md "Progress display"). */
    fun progressLine(pct: Long?): String? = pct?.let { "Saving BookOrbit for offline · ${it.coerceIn(0, 100)}%" }

    /** The note when the mirror stops at the storage limit (cases.json "storage.notes"). */
    fun limitText(covers: Boolean, done: Int, total: Int): String =
        "Storage limit reached: $done of $total ${if (covers) "covers" else "lists and books"} saved. Raise the limit in Orbit settings."

    // ------------------------------------------------------------------ the plan's paths

    /**
     * The book list a section entry opens (the plugin's paramsForEntry, through the templates the
     * plugin built with the sentinel id). templates: section -> { path, series_name_path }; entry:
     * a section page item (LuaValue model).
     */
    fun entryPath(templates: Map<*, *>, sentinel: String, section: String, entry: Map<*, *>): String? {
        val t = templates[section] as? Map<*, *> ?: return null
        if (section == "series") {
            val sid = entry["seriesId"]
            val path = t["path"] as? String
            if (sid != null && path != null) return fillBytes(path, sentinel, LuaValue.text(sid))
            val name = entry["id"] ?: return null
            val byName = t["series_name_path"] as? String ?: return null
            return fillBytes(byName, sentinel, LuaValue.text(name))
        }
        val id = entry["id"] ?: return null
        val path = t["path"] as? String ?: return null
        return fillBytes(path, sentinel, LuaValue.text(id))
    }

    /** A path template with the plan's sentinel id, filled in (the value, a byte string, escaped as the plugin's query does). */
    fun fillBytes(template: String, sentinel: String, value: String): String = template.replace(sentinel, escape(value))
}
