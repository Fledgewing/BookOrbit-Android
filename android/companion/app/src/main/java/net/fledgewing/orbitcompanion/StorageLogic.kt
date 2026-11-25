package net.fledgewing.orbitcompanion

/**
 * The storage limit's rule (was the plugin's Cache.storagePlan; docs/design/companion-worker.md):
 * one limit on everything Orbit stores. Over it, the least recently used browsing entries and
 * covers go first, then the covers saved for offline; lists and books saved for offline and the
 * index ("kept") never go.
 */
object StorageLogic {
    /** [k]: "e:<cache key>", "c:<cover file name>", "index" or "mirror"; [kind]: cache, cover, mirror_cover or kept. */
    data class Item(val k: String, val bytes: Long, val at: Long, val kind: String)

    data class Plan(val drop: List<String>, val used: Long, val after: Long)

    val KINDS = listOf("kept", "cache", "cover", "mirror_cover")

    fun plan(items: List<Item>, limit: Long?): Plan {
        val used = items.sumOf { it.bytes }
        if (limit == null || limit <= 0 || used <= limit) return Plan(emptyList(), used, used)
        val drop = ArrayList<String>()
        var after = used
        for (tier in listOf(setOf("cache", "cover"), setOf("mirror_cover"))) {
            val list = items.filter { it.kind in tier }.sortedWith(compareBy<Item> { it.at }.thenBy { it.k })
            for (e in list) {
                if (after <= limit) return Plan(drop, used, after)
                drop.add(e.k)
                after -= e.bytes
            }
        }
        return Plan(drop, used, after)
    }

    data class Admission(val growth: Long, val drop: List<String>, val allowed: Boolean)

    /** Shared with the firmware's W9 limit: replacements spend only their positive delta. */
    fun admit(used: Long, oldBytes: Long, newBytes: Long, limit: Long?, items: List<Item>, data: Boolean): Admission {
        val growth = maxOf(0L, newBytes - oldBytes)
        if (growth == 0L || limit == null || limit <= 0) return Admission(growth, emptyList(), true)
        var after = used + growth
        val drop = ArrayList<String>()
        if (data) for (item in items.filter { it.kind in setOf("cover", "mirror_cover") }
            .sortedWith(compareBy<Item> { it.at }.thenBy { it.k })) {
            if (after <= limit) break
            drop.add(item.k)
            after -= item.bytes
        }
        return Admission(growth, drop, after <= limit)
    }

    /** { used, kept, cache, cover, mirror_cover } bytes, without [drop]. */
    fun totals(items: List<Item>, drop: Collection<String> = emptyList()): Map<String, Long> {
        val gone = drop.toHashSet()
        val t = linkedMapOf("used" to 0L)
        KINDS.forEach { t[it] = 0L }
        for (e in items) if (e.k !in gone) {
            t["used"] = t.getValue("used") + e.bytes
            t[e.kind] = (t[e.kind] ?: 0L) + e.bytes
        }
        return t
    }
}
