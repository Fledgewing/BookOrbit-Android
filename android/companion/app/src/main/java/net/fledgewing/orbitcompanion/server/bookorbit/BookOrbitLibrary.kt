package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import java.security.MessageDigest

/** Backend normalization and query plans for the companion's 0.12 projection worker. No network on reads. */
object BookOrbitLibrary {
    /** Reuse Copies' account-scoped file ledger. Existence checks stay on the worker. */
    fun localEntries(store: CacheStore, owner: String): List<Map<*, *>>? {
        val file = java.io.File(store.root, "copies/ask.lua")
        val ask = if (file.isFile) LuaValue.parse(file.readBytes()) as? Map<*, *> else null
        if (ask?.get("owner") != owner) return null
        return (ask["books"] as? List<*>).orEmpty().mapNotNull { it as? Map<*, *> }
    }
    fun localBooks(store: CacheStore, owner: String): Set<Long>? = localPaths(store, owner)?.keys
    fun localPaths(store: CacheStore, owner: String): Map<Long, String>? {
        val entries = localEntries(store, owner) ?: return null
        return entries.mapNotNull { b ->
            val path = b["path"] as? String ?: return@mapNotNull null
            (b["book_id"] as? Number)?.toLong()?.takeIf { java.io.File(LuaValue.utf8(path)).isFile }?.let { it to path }
        }.toMap()
    }
    fun namespace(owner: String): String = "bo:" + MessageDigest.getInstance("SHA-256").digest(owner.toByteArray()).take(12).joinToString("") { "%02x".format(it) }
    fun key(owner: String, kind: String, id: Any) = "${namespace(owner)}:$kind:$id"
    fun id(owner: String, kind: String, key: Any?): Long? {
        val prefix = "${namespace(owner)}:$kind:"
        return (key as? String)?.takeIf { it.startsWith(prefix) }?.removePrefix(prefix)?.toLongOrNull()?.takeIf { it > 0 }
    }

    /** Existing cached catalog vocabulary (BulkCatalog.selection). Residuals always run locally.
     * This is a plan, not a network request; unverified server fields are deliberately residual. */
    fun translate(f: Map<*, *>): Pair<Map<String, String>, Set<String>> {
        LibraryFilter.validate(f)
        val query = linkedMapOf<String, String>()
        val residual = f.keys.map { it.toString() }.toMutableSet()
        val status = when (f["show"]) { "unread" -> "unread"; "finished" -> "finished"; else -> null }
        // Bulk status buckets are broader than canonical statuses (e.g. abandoned).
        // Keep the local predicate even when pushing down a safe candidate bucket.
        if (status != null) query["readStatus"] = status
        for ((field, target) in listOf("author" to "author", "series" to "series")) {
            val values = f[field] as? List<*>
            if (values?.size == 1) { query[target] = values.single().toString(); residual.remove(field) }
        }
        val sort = mapOf("title" to "title", "author" to "author", "last" to "recently_read", "added" to "recently_added", "series" to "series")[f["sort"]]
        if (sort != null) { query["sort"] = sort; query["order"] = f["dir"]?.toString() ?: "asc"; residual.remove("sort"); residual.remove("dir") }
        return query to residual
    }
    fun summary(owner: String, raw: Map<*, *>, rank: Long, local: Boolean?): Map<String, Any?> {
        val id = (raw["id"] as? Number)?.toLong() ?: throw IllegalArgumentException("missing book identity")
        val status = raw["readStatus"]?.toString()
        val canonical = when (status) { null, "unread", "want_to_read" -> "unread"; "reading", "rereading", "abandoned" -> status; "read" -> "finished"; "on_hold" -> "on-hold"; else -> "unknown" }
        val series = listOfNotNull(raw["seriesName"] as? String)
        return linkedMapOf("key" to key(owner, "book", id), "title" to (raw["title"] as? String),
            "authors" to (raw["authors"] as? List<*>).orEmpty().filterIsInstance<String>(), "series" to series,
            "series_key" to (raw["seriesId"] as? Number)?.let { key(owner, "series", it.toLong()) }, "series_position" to raw["seriesIndex"]?.takeIf { it is String || it is Number },
            "status" to canonical, "status_raw" to status, "want_to_read" to (status == "want_to_read"),
            "progress" to (raw["progressPercentage"] as? Number), "last_read" to (raw["lastReadAt"] as? String), "added" to (raw["addedAt"] as? String),
            "rating" to (raw["rating"] as? Number), "pages" to (raw["pageCount"] as? Number), "tags" to (raw["tags"] as? List<*>)?.filterIsInstance<String>(), "on_device" to local,
            "rank" to rank, "formats" to (raw["formats"] as? List<*>)?.filterIsInstance<String>(), "available" to mapOf("detail" to false, "cover" to false,
                "pages" to (raw["pageCount"] is Number), "rating" to (raw["rating"] is Number), "tags" to (raw["tags"] is List<*>),
                "local" to (local != null)))
    }
}
