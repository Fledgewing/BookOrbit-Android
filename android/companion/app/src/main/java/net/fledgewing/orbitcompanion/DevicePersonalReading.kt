// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import java.io.File
import java.time.Instant
import java.time.ZoneId

/** Read-only borrowed device data; executed solely on the companion worker. */
class DevicePersonalReading(private val roots: List<File>, private val statistics: File,
    private val open: (File) -> Sql = { AndroidSql(it, readOnly = true) }) : PersonalReadingSource {
    override val capabilities = PersonalReading.KINDS
    override fun read(kind: String, now: Long): List<PersonalReadingRecord> = when(kind) {
        "highlight" -> highlights()
        "yearago" -> if (!statistics.isFile) emptyList() else open(statistics).use { yearago(it, now) }
        else -> emptyList()
    }
    private fun highlights(): List<PersonalReadingRecord> {
        val out = linkedMapOf<String, PersonalReadingRecord>()
        for (book in DeviceLibrary.files(roots).sortedBy { it.canonicalPath }) {
            BulkWork.checkpoint()
            val file = File(book.parentFile, "${book.nameWithoutExtension}.sdr/metadata.${book.extension}.lua")
            if (!file.isFile || file.length() > 1048576 || Places.inside(file, roots) == null) continue
            val data = try {
                val literal = file.readText(Charsets.ISO_8859_1).replaceFirst(Regex("\\A(?:--[^\\n]*\\n)?\\s*return\\s+"), "")
                LuaValue.parse(literal.toByteArray(Charsets.ISO_8859_1)) as? Map<*, *>
            } catch (e: Exception) { if(e is InterruptedException) throw e; null } ?: continue
            val title = (data["doc_props"] as? Map<*, *>)?.get("title") as? String ?: LuaValue.str(book.nameWithoutExtension)
            val annotations = when(val a=data["annotations"]) { is List<*> -> a; is Map<*,*> -> a.entries.sortedBy { it.key.toString() }.map { it.value }; else -> emptyList<Any>() }
            for (raw in annotations) {
                val a = raw as? Map<*, *> ?: continue
                val passage = a["text"] as? String ?: continue
                if (passage.isBlank() || a["pos0"] == null) continue // exclude bookmarks and notes without a passage
                val identity = book.canonicalPath + ":" + a["pos0"] + ":" + passage
                out.putIfAbsent(identity, PersonalReadingRecord(identity, mapOf(
                    "passage" to LuaValue.boundedText(LuaValue.utf8(passage), 900),
                    "source" to LuaValue.boundedText(LuaValue.utf8(title), 160),
                    "book" to mapOf("title" to LuaValue.boundedText(LuaValue.utf8(title),160), "local_path" to LuaValue.str(book.canonicalPath)))))
            }
        }
        return out.values.toList()
    }
    companion object {
        /** Same calendar day one year back in the device zone; Feb 29 clamps to Feb 28.
         * SQL aggregates every visit, but decodes only the selected book's single display row. */
        fun yearago(db: Sql, now: Long, zone: ZoneId = ZoneId.systemDefault()): List<PersonalReadingRecord> {
            val day = Instant.ofEpochSecond(now).atZone(zone).toLocalDate().minusYears(1)
            val start = day.atStartOfDay(zone).toEpochSecond()
            val end = day.plusDays(1).atStartOfDay(zone).toEpochSecond()
            return db.query("""SELECT b.id,substr(b.title,1,160),SUM(MIN(MAX(p.duration,0),86400)),
                (SELECT q.page FROM page_stat_data q WHERE q.id_book=b.id AND q.start_time>=? AND q.start_time<? AND q.duration>0 ORDER BY q.start_time DESC,q.rowid DESC LIMIT 1)
                FROM page_stat_data p JOIN book b ON b.id=p.id_book
                WHERE p.start_time>=? AND p.start_time<? AND p.duration>0 GROUP BY b.id
                ORDER BY SUM(MIN(MAX(p.duration,0),86400)) DESC,b.id LIMIT 1""",start,end,start,end) {
                val minutes = (it.long(2) ?: 0)/60
                val page = it.long(3)
                PersonalReadingRecord("history:${it.long(0)}:$day", mapOf("source" to "On this reader",
                    "book_title" to LuaValue.str(it.text(1) ?: "Unknown book"), "minutes" to minutes, "days_read" to 1,
                    "stop_page" to page, "summary" to LuaValue.str("$minutes min · 1 day · " + (page?.let { n -> "stopped at p. $n" } ?: "Position unavailable")),
                    "date" to day.toString()))
            }
        }
    }
}
