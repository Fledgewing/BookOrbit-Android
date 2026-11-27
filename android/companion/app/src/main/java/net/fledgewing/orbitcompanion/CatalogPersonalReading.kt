// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

/** Worker-only ranking over saved neutral device/catalog rows. No transport or acquisition.
 * Remote recommendation providers can later implement PersonalReadingSource instead. */
class CatalogPersonalReading(private val catalog: () -> Map<String, Any?>) : PersonalReadingSource {
    override val capabilities = setOf("recommended", "discover")
    private val books by lazy {
        val result = catalog()
        check((result["freshness"] as? Map<*, *>)?.get("saved") == true)
        @Suppress("UNCHECKED_CAST")
        (result["items"] as? List<Map<String, Any?>>).orEmpty()
    }
    override fun read(kind: String, now: Long): List<PersonalReadingRecord> {
        if (kind !in capabilities) return emptyList()
        val history = books.filter { it["status"] in setOf("reading", "finished") }
        fun authors(b: Map<String, Any?>) = (b["authors"] as? List<*>)?.filterIsInstance<String>().orEmpty()
        fun number(b: Map<String, Any?>) = b["series_position"]?.toString()?.toDoubleOrNull()?.takeIf { it.isFinite() }
        val affinity = history.flatMap(::authors).groupingBy { it }.eachCount()
        val finished = history.filter { it["status"] == "finished" && it["series_key"] != null && number(it) != null }
            .groupBy { it["series_key"] }.mapValues { (_, rows) -> rows.maxOf { number(it)!! } }
        val unread = books.filter { it["status"] == "unread" && it["key"] is String }
        // The first known unread volume after the last finished volume, never a later one.
        val next = unread.filter { b -> number(b)?.let { it > (finished[b["series_key"]] ?: Double.POSITIVE_INFINITY) } == true }
            .groupBy { it["series_key"] }.mapValues { (_, rows) -> rows.minBy { number(it)!! }["key"] }.values.toSet()
        val ordered = if (kind == "discover") unread.sortedBy { it["key"].toString() }
            else unread.sortedWith(compareByDescending<Map<String, Any?>> { it["key"] in next }
                .thenByDescending { authors(it).sumOf { author -> affinity[author] ?: 0 } }.thenBy { it["key"].toString() })
        return ordered.map { b ->
            val reason = if (kind == "discover") "Unread · saved on this reader" else if (b["key"] in next) "Next in your series"
                else if (authors(b).any { it in affinity }) "An author you've read" else "Unread · saved on this reader"
            val display = b.filterKeys { it in setOf("key", "title", "authors", "local_path", "on_device", "status", "progress") }
            // A tracked file in a mirror and a device row share the file identity; device wins.
            PersonalReadingRecord((b["local_path"] ?: b["key"]).toString(), mapOf("book" to display, "source" to reason))
        }
    }
}
