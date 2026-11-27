// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

/** Worker-only providers return neutral records. Registration order wins duplicate identities.
 * Providers may read saved data only: acquisition is a separate worker operation. */
interface PersonalReadingSource {
    fun card(book: Map<String, Any?>, now: Long, dailySeconds: Long): Map<String, Any?> = emptyMap()
    val capabilities: Set<String>
    fun read(kind: String, now: Long): List<PersonalReadingRecord>
}
data class PersonalReadingRecord(val identity: String, val fields: Map<String, Any?>)

class PersonalReading(private val sources: List<PersonalReadingSource>,
    private val discoverRank: (String) -> String = { text ->
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(text.toByteArray())
        val hex = "0123456789abcdef"
        buildString(64) { for (byte in digest) { val n = byte.toInt() and 255; append(hex[n ushr 4]); append(hex[n and 15]) } }
    }) {
    companion object { val KINDS = setOf("highlight", "yearago", "recommended", "discover") }
    // One instance belongs to one LibraryReadModel worker batch. Duplicate tiles/picks
    // share provider reads and ranks; a changed time rebuilds rather than serving stale data.
    private data class Pool(val now: Long, val records: List<PersonalReadingRecord>, val succeeded: Boolean)
    private val pools = mutableMapOf<String, Pool>()
    /** Source precedence belongs here; card callers never select a provider. */
    fun card(book: Map<String, Any?>, now: Long, dailySeconds: Long): Map<String, Any?> {
        val fields = linkedMapOf<String, Any?>()
        for (source in sources) try {
            source.card(book, now, dailySeconds).forEach { (key, value) -> if (value != null) fields.putIfAbsent(key, value) }
        } catch (e: Exception) { if (e is InterruptedException) throw e }
        return book + fields
    }
    fun window(kind: String, now: Long, pick: Long = 0): Map<String, Any?> {
        require(kind in KINDS)
        val day = java.time.Instant.ofEpochSecond(now).atZone(java.time.ZoneId.systemDefault()).toLocalDate().toEpochDay()
        val pool = pools[kind]?.takeIf { it.now == now } ?: run {
            val merged = linkedMapOf<String, PersonalReadingRecord>()
            var succeeded = false
            for (source in sources) {
                if (kind !in source.capabilities) continue
                try {
                    source.read(kind, now).forEach { merged.putIfAbsent(it.identity, it) }
                    succeeded = true
                } catch (e: Exception) { if (e is InterruptedException) throw e }
            }
            // Decorate once: sortedBy's selector runs on every comparison. Hashing and
            // formatting there amplified 10k books into hundreds of thousands of digests.
            val records = if (kind == "discover") merged.values.map {
                discoverRank("$day:" + it.identity) to it
            }.sortedBy { it.first }.map { it.second } else merged.values.toList()
            Pool(now, records, succeeded).also { pools[kind] = it }
        }
        val records = pool.records
        val succeeded = pool.succeeded
        // Round-robin over a stable pool: no repetition within a complete cycle, no process state.
        val selected = if (records.isEmpty()) null else records[if (kind == "highlight") Math.floorMod(day, records.size.toLong()).toInt() else if (kind == "discover") (pick.coerceIn(0, 1000000000) % records.size).toInt() else 0]
        val result = (selected?.fields ?: emptyMap()) + mapOf("state" to if (selected != null) "ready" else if (succeeded) "empty" else "error",
            "message" to LuaValue.str(when(kind) { "yearago" -> "No reading from a year ago on this device yet"; "recommended", "discover" -> "No unread books saved yet"; else -> "Save a highlight while reading." }),
            "row_count" to 1, "freshness" to mapOf("saved" to succeeded))
        return if (LuaValue.encode(result).size <= LibraryReadModel.MAX_BYTES) result
        else mapOf("state" to "error", "row_count" to 1, "message" to "Reading data exceeds this widget's budget")
    }
}
