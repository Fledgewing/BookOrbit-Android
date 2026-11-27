package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

/**
 * Keep copies current (docs/design/keep-copies-current.md), the lookup half: which copies on the
 * reader no longer match their library file (was the plugin's Copies.details and
 * CopiesPlan.candidates; the replacement download stays in the plugin).
 */
object CopiesLogic {
    fun pick(files: List<*>, id: Any?): Map<*,*>? {
        val rows=files.mapNotNull { it as? Map<*,*> }.filter { (it["format"] as? String)?.lowercase() in setOf("epub","pdf","cbz","fb2","mobi","azw3","djvu","txt","html","rtf","doc") }
        return rows.firstOrNull { id!=null && it["id"]==id } ?: rows.firstOrNull { it["role"]=="primary" } ?: rows.firstOrNull()
    }
    fun decide(local: String, file: Map<*,*>): String {
        val hash=file["fileHash"] as? String
        return if(hash.isNullOrBlank()) "unknown" else if(hash.equals(local,true)) "same" else "replace"
    }

    /** A saved book detail's files, and when it was saved (os.time seconds). */
    data class Detail(val files: List<*>?, val at: Long)

    private val DETAIL = Regex("/catalog/books/(\\d+)(\\?.*)?$")

    /** The book id of a saved detail's path ("/koreader/plugin/catalog/books/12?variant=…"), or null. */
    fun detailId(path: String?): String? = path?.let { DETAIL.find(it)?.groupValues?.get(1) }

    /** The newer of two saved details wins; a tie goes to the later source. */
    fun newer(cur: Detail?, at: Long): Boolean = cur == null || at >= cur.at

    /**
     * books: { md5, path, book_id, file_id, incompatible }; details: book id -> Detail.
     * -> { md5, path, book_id, file_id, why = "incompatible" | "hash" }, by path.
     */
    fun candidates(books: List<Map<*, *>>, details: Map<String, Detail>): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        for (b in books) {
            val md5 = b["md5"] as? String ?: continue
            val path = b["path"] as? String ?: continue
            val id = b["book_id"] ?: continue
            var why: String? = if (b["incompatible"] == true) "incompatible" else null
            if (why == null) {
                for (f in details[id.toString()]?.files ?: emptyList<Any?>()) {
                    val m = f as? Map<*, *> ?: continue
                    val hash = m["fileHash"] as? String
                    if (m["id"] == b["file_id"] && hash != null && hash != md5) why = "hash"
                }
            }
            if (why != null) out.add(sortedMapOf("md5" to md5, "path" to path, "book_id" to id, "file_id" to b["file_id"], "why" to why))
        }
        return out.sortedBy { it["path"] as String }
    }
}
