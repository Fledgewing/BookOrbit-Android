// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

/** Worker-only providers return neutral records. Registration order wins duplicate identities.
 * Providers may read saved data only: acquisition is a separate worker operation. */
interface PersonalReadingSource {
    val capabilities: Set<String>
    fun read(kind: String, now: Long): List<PersonalReadingRecord>
}
data class PersonalReadingRecord(val identity: String, val fields: Map<String, Any?>)

class PersonalReading(private val sources: List<PersonalReadingSource>) {
    companion object { val KINDS = setOf("highlight", "yearago") }
    fun window(kind: String, now: Long): Map<String, Any?> {
        require(kind in KINDS)
        val merged = linkedMapOf<String, PersonalReadingRecord>()
        var succeeded = false
        for (source in sources) {
            if (kind !in source.capabilities) continue
            try {
                val records = source.read(kind, now)
                records.forEach { merged.putIfAbsent(it.identity, it) }
                succeeded = true
            } catch (e: Exception) { if (e is InterruptedException) throw e }
        }
        val day = java.time.Instant.ofEpochSecond(now).atZone(java.time.ZoneId.systemDefault()).toLocalDate().toEpochDay()
        val records = merged.values.toList()
        // Round-robin over a stable pool: no repetition within a complete cycle, no process state.
        val selected = if (records.isEmpty()) null else records[if (kind == "highlight") Math.floorMod(day, records.size.toLong()).toInt() else 0]
        val result = (selected?.fields ?: emptyMap()) + mapOf("state" to if (selected != null) "ready" else if (succeeded) "empty" else "error",
            "message" to LuaValue.str(if (kind == "yearago") "No reading from a year ago on this device yet" else "Save a highlight while reading."),
            "row_count" to 1, "freshness" to mapOf("saved" to succeeded))
        return if (LuaValue.encode(result).size <= LibraryReadModel.MAX_BYTES) result
        else mapOf("state" to "error", "row_count" to 1, "message" to "Reading data exceeds this widget's budget")
    }
}
