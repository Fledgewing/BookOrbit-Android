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

}
