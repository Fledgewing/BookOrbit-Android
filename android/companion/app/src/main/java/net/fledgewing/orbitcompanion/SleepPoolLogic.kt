package net.fledgewing.orbitcompanion

/**
 * The sleep screen's pool rules (docs/design/lock-screen.md R1-R4b, X1-X7), moved from the
 * plugin's logic/sleep_pool.lua with the pool refresh (docs/design/companion-worker.md): the
 * sources (Pick from), the Leave out rules, the shuffle bag. Pure. [rand] is Lua's: n -> 1..n.
 */
object SleepPoolLogic {
    const val BATCH = 24
    const val BAG_MAX = 2000
    const val LEAVE_OUT_MAX = 4000
    const val PAGE_SIZE = 100
    const val DAY_S = 86_400L
    const val PROBE_MAX = 48
    const val SHOWS_MAX = 3

    /** Pick from's dashboard lists, in the order an empty one falls back (B koreader.ts:443-449). */
    val LISTS = listOf("up_next" to "up-next-in-series", "want_to_read" to "want-to-read", "discover" to "random")

    /** Pick from's and Leave out's item for every book the account can see (R1c, X8). */
    const val LIBRARY = "library"

    /** kind: list (with [type]), library, scope or collection (with [id]). */
    data class From(val kind: String, val id: Long = 0, val type: String = "") {
        /** Listed by its members into the shuffle bag (library, scope, collection), not a dashboard list. */
        val members get() = kind != "list"
    }

    data class Rule(val kind: String, val id: Long = 0, val tag: String = "") {
        val key get() = when (kind) { "tag" -> "tag:$tag"; LIBRARY -> if (id == 0L) LIBRARY else "library:$id"; else -> "$kind:$id" }
    }

    private val REF = Regex("^([A-Za-z]+):(\\d+)$")

    /** Lua's lower(): ASCII only, so UTF-8 bytes are never touched. */
    fun lower(s: String): String = buildString { s.forEach { append(if (it in 'A'..'Z') it + 32 else it) } }

    fun parseFrom(v: String?): From? {
        if (v == null) return null
        if (v == LIBRARY) return From(LIBRARY)
        LISTS.firstOrNull { it.first == v }?.let { return From("list", type = it.second) }
        val m = REF.find(v) ?: return null
        val id = m.groupValues[2].toLongOrNull() ?: return null
        return if ((m.groupValues[1] == "scope" || m.groupValues[1] == "collection" || m.groupValues[1] == "library") && id > 0) From(m.groupValues[1], id) else null
    }

    fun parseRule(v: String?): Rule? {
        if (v == null) return null
        if (v.trim() == LIBRARY) return Rule(LIBRARY)
        if (v.startsWith("tag:")) {
            val tag = lower(v.removePrefix("tag:").trim())
            return if (tag.isEmpty()) null else Rule("tag", tag = tag)
        }
        val m = REF.find(v) ?: return null
        val id = m.groupValues[2].toLongOrNull() ?: return null
        return if ((m.groupValues[1] == "scope" || m.groupValues[1] == "collection" || m.groupValues[1] == "library") && id > 0) Rule(m.groupValues[1], id) else null
    }

    /** Leave out as stored: valid, unique, in order; Library alone leaves out every book, so it stands for all (X8). */
    fun rules(lines: String?): List<String> {
        val out = (lines ?: "").split('\n').mapNotNull { parseRule(it)?.key }.distinct()
        return if (LIBRARY in out) listOf(LIBRARY) else out
    }

    /**
     * Pick from as stored (R1c): its items, one per line in the wire value, valid, unique, in the
     * order picked. Library is every book, so it stands alone; nothing valid is the default, Up next.
     */
    fun sources(lines: String?): List<String> {
        val out = (lines ?: "").split('\n').map { it.trim() }.filter { parseFrom(it) != null }.distinct()
        return when {
            LIBRARY in out -> listOf(LIBRARY)
            out.isEmpty() -> listOf(LISTS[0].first)
            else -> out
        }
    }

    /**
     * Pick from with [id] ticked or unticked (R1c): Library clears the others and another clears
     * Library; the last one stays ticked (none would be Up next anyway). Lua: SleepPool.togglePick.
     */
    fun togglePick(lines: String?, id: String): String {
        val items = sources(lines)
        if (id in items) return (items - id).ifEmpty { items }.joinToString("\n")
        if (id == LIBRARY) return LIBRARY
        return sources((items.filter { it != LIBRARY } + id).joinToString("\n")).joinToString("\n")
    }

    /** Leave out with [rule] added or removed (X8): Library stands for every rule. */
    fun toggleRule(lines: String?, rule: String): String {
        val r = rules(lines)
        val key = parseRule(rule)?.key ?: return r.joinToString("\n")
        return (if (key in r) r - key else r + key).let { rules(it.joinToString("\n")) }.joinToString("\n")
    }

    /** The picked sources listed by their members: one shuffle bag over all of them (R1c). */
    fun memberSources(sources: List<String>): List<From> = sources.mapNotNull { parseFrom(it) }.filter { it.members }

    /**
     * The order a refresh tries books in (R1c): each picked dashboard list is a stream in the
     * server's order, and the bag over every picked library, scope and collection is one more,
     * where its first source was picked. The streams are taken in turn, a book once. Only when
     * every stream is empty, Up next, Want to read and Discover (not picked) are tried in that
     * order. [lists]: a list id -> its books. Returns the ids and the fallback list used, if any.
     */
    fun candidates(sources: List<String>, lists: Map<String, List<Long>>, bag: List<Long>): Pair<List<Long>, String?> {
        val streams = ArrayList<List<Long>>()
        var bagAdded = false
        for (src in sources) {
            val f = parseFrom(src) ?: continue
            if (f.members) { if (!bagAdded) { streams.add(bag); bagAdded = true } }
            else streams.add(lists[src].orEmpty())
        }
        if (streams.all { it.isEmpty() }) {
            val fb = LISTS.map { it.first }.firstOrNull { it !in sources && lists[it].orEmpty().isNotEmpty() } ?: return emptyList<Long>() to null
            return lists[fb].orEmpty().distinct() to fb
        }
        val out = LinkedHashSet<Long>()
        val longest = streams.maxOf { it.size }
        for (i in 0 until longest) for (st in streams) if (i < st.size) out.add(st[i])
        return out.toList() to null
    }

    fun needsTags(rules: List<String>) = rules.any { parseRule(it)?.kind == "tag" }

    /** The rules checked by membership lists: smart scopes and collections (Library needs none). */
    fun memberRules(rules: List<String>) = rules.mapNotNull { parseRule(it) }.filter { it.kind == "scope" || it.kind == "collection" || (it.kind == LIBRARY && it.id > 0) }

    /** R2: a cover, not read, not the book open now. */
    fun eligible(b: Map<String, Any?>?, openId: Long?): Boolean {
        val id = (b?.get("id") as? Number)?.toLong() ?: return false
        if (b["cover_available"] == false) return false
        if (b["status"] == "finished") return false
        return openId == null || id != openId
    }

    /** One book against the rules, OR-ed: "keep", "out" or "unknown" (failed closed by the caller, X7). */
    fun check(id: Long, rules: List<String>, members: Map<String, Set<Long>>, tags: List<String>?): String {
        var unknown = false
        for (r in rules) {
            val p = parseRule(r) ?: continue
            if (p.kind == LIBRARY && p.id == 0L) return "out"
            if (p.kind == "tag") {
                if (tags == null) unknown = true
                else if (tags.any { lower(it.trim()) == p.tag }) return "out"
            } else {
                val set = members[p.key]
                if (set == null) unknown = true else if (id in set) return "out"
            }
        }
        return if (unknown) "unknown" else "keep"
    }

    data class Tag(val tag: String, val label: String, val count: Int)

    /** Tags seen in saved book details, with counts, most used first (X3's picker). One list of tags per detail. */
    fun tagCounts(details: List<List<String>>): List<Tag> {
        val counts = HashMap<String, Int>()
        val shown = HashMap<String, String>()
        for (d in details) {
            val seen = HashSet<String>()
            for (t in d) {
                val k = lower(t.trim())
                if (k.isNotEmpty() && seen.add(k)) {
                    counts[k] = (counts[k] ?: 0) + 1
                    shown.putIfAbsent(k, t.trim())
                }
            }
        }
        return counts.map { (k, n) -> Tag(k, shown[k]!!, n) }.sortedWith(compareBy<Tag>({ -it.count }, { it.tag }))
    }

    /** A member list is due: never listed, a day old, or the clock went back. */
    fun due(at: Long?, now: Long): Boolean = at == null || now < at || now - at >= DAY_S

    // ---------------------------------------------------------------- the shuffle bag (R1b)

    /** order, pos (the last shown, 0 none), prev (the id shown last). */
    class Bag(var source: String = "", var order: MutableList<Long> = ArrayList(), var pos: Int = 0, var prev: Long? = null, var at: Long? = null) {
        fun toModel(): Map<String, Any?> {
            val m = sortedMapOf<String, Any?>("source" to source, "order" to order.toList(), "pos" to pos.toLong())
            prev?.let { m["prev"] = it }
            at?.let { m["at"] = it }
            return m
        }

        companion object {
            fun of(m: Map<*, *>?): Bag = Bag(
                (m?.get("source") as? String) ?: "",
                ((m?.get("order") as? List<*>)?.mapNotNull { (it as? Number)?.toLong() } ?: emptyList()).toMutableList(),
                (m?.get("pos") as? Number)?.toInt() ?: 0, (m?.get("prev") as? Number)?.toLong(), (m?.get("at") as? Number)?.toLong(),
            )
        }
    }

    /** Fisher-Yates; the book just shown never comes first. */
    fun shuffle(ids: List<Long>, rand: (Int) -> Int, avoidFirst: Long?): MutableList<Long> {
        val out = ids.toMutableList()
        for (i in out.size downTo 2) {
            val j = rand(i)
            val t = out[i - 1]; out[i - 1] = out[j - 1]; out[j - 1] = t
        }
        if (avoidFirst != null && out.size > 1 && out[0] == avoidFirst) {
            val j = 1 + rand(out.size - 1)
            val t = out[0]; out[0] = out[j - 1]; out[j - 1] = t
        }
        return out
    }

    /** The companion showed [shown]: the bag moves to it, never back. */
    fun bagSeek(bag: Bag, shown: Long?): Boolean {
        if (shown == null || shown == bag.prev) return false
        for (i in bag.pos + 1..bag.order.size) {
            if (bag.order[i - 1] == shown) { bag.pos = i; bag.prev = shown; return true }
        }
        return false
    }

    /** Listed again: those that left come out, new ones go in at random places among the books not shown yet. */
    fun bagSync(bag: Bag, members: List<Long>, rand: (Int) -> Int) {
        val want = members.toHashSet()
        val kept = HashSet<Long>()
        val out = ArrayList<Long>()
        var pos = bag.pos
        bag.order.forEachIndexed { i, id ->
            if (id in want && kept.add(id)) out.add(id) else if (i + 1 <= pos) pos--
        }
        for (id in members) {
            if (kept.add(id)) {
                val at = pos + rand(out.size - pos + 1)
                out.add(at - 1, id)
            }
        }
        bag.order = out
        bag.pos = maxOf(0, pos)
    }

    /** The ids not shown yet; a used-up bag is shuffled again first. */
    fun bagNext(bag: Bag, rand: (Int) -> Int): List<Long> {
        if (bag.order.isEmpty()) return emptyList()
        if (bag.pos >= bag.order.size) {
            bag.order = shuffle(bag.order, rand, bag.prev)
            bag.pos = 0
        }
        return bag.order.subList(bag.pos, bag.order.size).toList()
    }

    /** Every sleep (R4b): the ready covers carried on, in order, and the retired (shown [max] times). */
    fun carry(prevIds: List<Long>, shows: Map<Long, Int>, max: Int = SHOWS_MAX): Pair<List<Long>, Set<Long>> {
        val carry = ArrayList<Long>()
        val retired = LinkedHashSet<Long>()
        val seen = HashSet<Long>()
        for (id in prevIds) {
            if (!seen.add(id)) continue
            if ((shows[id] ?: 0) >= max) retired.add(id) else carry.add(id)
        }
        return carry to retired
    }

    /** Every sleep with a bag: the books taken into the batch count as shown. */
    fun bagTake(bag: Bag, taken: Set<Long>) {
        var pos = bag.pos
        for (i in bag.pos + 1..bag.order.size) if (bag.order[i - 1] in taken) pos = i
        if (pos != bag.pos) { bag.pos = pos; bag.prev = null }
    }
}
