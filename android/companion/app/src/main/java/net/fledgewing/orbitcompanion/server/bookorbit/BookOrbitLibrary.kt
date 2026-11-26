package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.CacheStore
import net.fledgewing.orbitcompanion.LibraryFilter
import net.fledgewing.orbitcompanion.LuaValue
import net.fledgewing.orbitcompanion.RemoteReadingStats

import java.security.MessageDigest

/** Backend normalization and query plans for the companion's 0.12 projection worker. No network on reads. */
object BookOrbitLibrary {
    /** Cached connector response only. fetched/generated time is NOT an inclusion watermark. */
    fun readingStats(store: CacheStore): RemoteReadingStats? {
        val dashboardCachePath = "/koreader/plugin/catalog/dashboard"
        val raw = store.db().query("SELECT body FROM entries WHERE path=? ORDER BY fetched_at DESC LIMIT 1", dashboardCachePath) {
            it.bytes(0)?.let(LuaValue::parse) as? Map<*, *>
        }.firstOrNull() ?: return null
        return dashboardStats(raw)
    }
    fun dashboardStats(raw: Map<*, *>): RemoteReadingStats {
        fun count(value: Any?) = (value as? Number)?.toDouble()?.takeIf { it.isFinite() && it >= 0 && it <= Int.MAX_VALUE && it % 1.0 == 0.0 }?.toLong()
        val year = raw["readingYear"] as? Map<*, *>
        val start = (year?.get("startDate") as? String)?.let { runCatching { java.time.LocalDate.parse(it) }.getOrNull() }
        val minutes = year?.get("minutes") as? List<*>
        val days = if (start != null && minutes != null && minutes.size in 1..371 && minutes.all { count(it) != null })
            minutes.mapIndexed { i, m -> start.plusDays(i.toLong()) to count(m)!! * 60 }.toMap() else null
        val streak = raw["readingStreak"] as? Map<*, *>
        val current = count(streak?.get("currentStreak")); val best = count(streak?.get("longestStreak"))
        val goal = raw["readingGoal"] as? Map<*, *>
        val goalYear = count(goal?.get("year"))
        // finishedThisYear is a capped shelf, never a total (pinned connector service:332).
        return RemoteReadingStats(days = days, streak = current.takeIf { best != null }, bestStreak = best,
            target = count(goal?.get("goalBooks")), goalAvailable = goalYear != null && goal?.containsKey("goalBooks") == true &&
                (goal["goalBooks"] == null || count(goal["goalBooks"]) != null),
            finished = count(goal?.get("completedBooks")).takeIf { goalYear != null }, year = goalYear,
            at = (raw["generatedAt"] as? String)?.takeIf { runCatching { java.time.Instant.parse(it) }.isSuccess })
    }
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
    /** Paged backend section identities normalized before the editor can see them. */
    fun sourceSections(store: CacheStore, owner: String, category: String, offset: Int, limit: Int): Map<String, Any?> {
        val g=store.meta("bulk_active")?.toLongOrNull()
        val saved=g != null && store.meta("bulk_complete")?.toLongOrNull()==g
        if (!saved) return mapOf("items" to emptyList<Any>(), "freshness" to mapOf("saved" to false))
        val section=if (category=="lists") "smart-scopes" else "series"
        val kind=if (category=="lists") "list" else "series"
        val total=store.db().query("SELECT count(*) FROM bulk_sections WHERE g=? AND section=?",g,section) { it.long(0)!! }.single()
        val rows=store.db().query("SELECT id,name,n FROM bulk_sections WHERE g=? AND section=? ORDER BY pos,id LIMIT ? OFFSET ?",g,section,limit,offset) {
            val id=it.text(0).orEmpty().removePrefix("series:")
            mapOf("src" to "$kind:${key(owner,kind,id)}", "title" to LuaValue.boundedText(it.text(1).orEmpty(),80), "count" to it.long(2))
        }
        return mapOf("items" to rows,"total" to total,"next" to (offset+rows.size).takeIf { it<total },"freshness" to mapOf("saved" to true))
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
