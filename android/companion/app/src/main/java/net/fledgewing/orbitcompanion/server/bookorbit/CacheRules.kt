package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.LuaValue

/** Cached protocol comparison, kept separate from the shared Lua serializer. */
object CacheRules {
    /** `Cache.VOLATILE` and `Cache.KEEP_SAVED`: not compared. */
    private val VOLATILE = setOf("generatedAt")
    private val KEEP_SAVED = setOf("discover")

    fun normalize(body: Any?): Any? {
        if (body !is Map<*, *>) return body
        return body.filterKeys { it !in VOLATILE && it !in KEEP_SAVED }
    }

    /** `Cache.revalidate`: does the reply differ from what is saved? */
    fun changed(saved: Any?, reply: Any?): Boolean = !LuaValue.encode(normalize(saved)).contentEquals(LuaValue.encode(normalize(reply)))

    /** The reply, with the saved random pick kept (a Full refresh takes the new). */
    fun settle(saved: Any?, reply: Any?, mode: String?): Any? {
        if (saved !is Map<*, *> || reply !is Map<*, *> || mode == "full") return reply
        val out = java.util.TreeMap<String, Any?>()
        for ((k, v) in reply) out[k.toString()] = v
        for (k in KEEP_SAVED) saved[k]?.let { out[k] = it }
        return out
    }

    // ------------------------------------------------------------------ the cache's rules

    /** `Cache.ids`: the book ids a body names. */
    fun ids(body: Any?, out: MutableSet<Long> = sortedSetOf(), depth: Int = 0): MutableSet<Long> {
        if (depth > 30) return out
        when (body) {
            is Map<*, *> -> {
                when (val id = body["id"]) {
                    is Long -> out.add(id)
                    is Double -> if (id == Math.floor(id)) out.add(id.toLong())
                    is String -> id.toLongOrNull()?.let { out.add(it) }
                }
                for (v in body.values) if (v is Map<*, *> || v is List<*>) ids(v, out, depth + 1)
            }
            is List<*> -> for (v in body) if (v is Map<*, *> || v is List<*>) ids(v, out, depth + 1)
        }
        return out
    }

    private val PAGING = setOf("items", "page", "size", "offset", "hasNext", "hasPrevious", "nextUrl", "previousUrl")

    /**
     * `Cache.slice`: one list page cut from the mirror's pages. window: the read's page, size and
     * offset; pages: page number -> body; per: the mirror's page size. null when a page it needs
     * isn't saved.
     */
    fun slice(kind: String, page: Int?, size: Int?, offset: Int?, pages: Map<Int, Any?>, per: Int): Map<String, Any?>? {
        val first = pages[1] as? Map<*, *> ?: return null
        val firstItems = first["items"] as? List<*> ?: if ((first["items"] as? Map<*, *>)?.isEmpty() == true) emptyList<Any?>() else return null
        val total = (first["total"] as? Number)?.toInt() ?: firstItems.size
        var sz = size ?: if (kind == "books") 20 else total
        if (sz < 1) sz = 1
        val start = offset ?: (((page ?: 1) - 1) * sz)
        val stop = minOf(total, start + sz)
        val items = ArrayList<Any?>()
        for (i in start + 1..stop) {
            val n = (i - 1) / per + 1
            val p = pages[n] as? Map<*, *> ?: return null
            val its = p["items"] as? List<*> ?: return null
            val item = its.getOrNull(i - (n - 1) * per - 1) ?: return null
            items.add(item)
        }
        val out = java.util.TreeMap<String, Any?>()
        for ((k, v) in first) if (k !in PAGING) out[k.toString()] = v
        out["items"] = items
        out["total"] = total.toLong()
        out["size"] = sz.toLong()
        out["page"] = (start / sz + 1).toLong()
        if (offset != null) out["offset"] = offset.toLong()
        out["hasNext"] = stop < total
        out["hasPrevious"] = start > 0
        return out
    }
}
