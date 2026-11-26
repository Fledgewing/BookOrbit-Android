package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

/** Finite, non-search browse space from shared/fixtures/catalog/sections.json (P passes it in
 * the plan). Expansion runs on the companion writer, after the fresh section indexes land.
 * Screen size, page, offset, grid/list and letter jumps are windows of the same identity. */
class CatalogPlan(private val plan: CacheWorker.Plan) {
    private val catalog = plan.m["catalog"] as? Map<*, *> ?: emptyMap<String, Any?>()
    private fun values(key: String) = (catalog[key] as? List<*>)?.filterIsInstance<String>().orEmpty()

    private val limits = catalog["local_limits"] as? Map<*, *> ?: emptyMap<String, Any?>()
    val recentScanSize get() = (limits["not_on_device_scan_pages"] as? Number)?.toInt()?.times((limits["not_on_device_scan_size"] as? Number)?.toInt() ?: 100) ?: 500
    val absentLimit get() = (limits["not_on_device_max_ids"] as? Number)?.toInt() ?: 200

    fun sectionPaths(): Sequence<String> = sequence {
        for (section in listOf("authors", "series")) {
            for (sort in values("section_sorts")) for (filter in listOf("") + values("section_filters")) {
                val q = linkedMapOf<String, String>()
                if (sort != "name") q["sort"] = sort
                if (filter.isNotEmpty()) q["filter"] = filter
                yield(path("/koreader/plugin/catalog/sections/$section", q))
            }
        }
    }

    /** Every sort/direction/status/format/library/device combination offered by the book sheet.
     * Authors open in series order too; their page has no sheet, but legacy controls do. */
    fun bookPaths(base: String, libraries: List<String>, deviceIds: String?): Sequence<String> = sequence {
        if (catalog.isEmpty()) return@sequence
        val (endpoint, query) = MirrorLogic.splitPath(base)
        val scope = MirrorLogic.parseQuery(query).also {
            listOf("page", "size", "offset", "sort", "order", "buckets", "readStatus", "format").forEach(it::remove)
        }
        val series = "seriesId" in scope || "series" in scope
        val sorts = if (series) values("series_sorts") else (values("book_sorts") + values("list_sorts")).distinct()
        val libraryOptions = if (series) listOf(scope["libraryId"].orEmpty()) else (listOf(scope["libraryId"].orEmpty()) + libraries).distinct()
        val formats = if (series) listOf("") else listOf("") + values("formats")
        val devices = (listOf(scope["ids"].orEmpty()) + listOfNotNull(deviceIds)).distinct()
        for (sort in sorts) for (order in values("orders")) for (status in listOf("") + values("read_statuses")) {
            for (library in libraryOptions) for (format in formats) for (ids in if (series) listOf(scope["ids"].orEmpty()) else devices) {
                val q = LinkedHashMap(scope)
                q["sort"] = sort; q["order"] = order
                if (status.isNotEmpty()) q["readStatus"] = status
                if (library.isNotEmpty()) q["libraryId"] = library
                if (format.isNotEmpty()) q["format"] = format
                if (ids.isNotEmpty()) q["ids"] = ids
                // Both supported and legacy request shapes are browsable; cache keys include buckets.
                yield(path(endpoint, q))
                if (sort == "title" || sort == "author") { q["buckets"] = "1"; yield(path(endpoint, q)) }
            }
        }
    }

    private fun path(endpoint: String, q: Map<String, String>): String =
        endpoint + MirrorLogic.encQuery(q).let { if (it.isEmpty()) "" else "?$it" }

    /** Stable labels for the end-of-run audit, independent of ids and query ordering. */
    companion object {
        fun operation(action:String,state:Map<String,Any?>,limit:Long?,manual:Boolean,now:Long,last:Long):String? {
            require(action in setOf("full","resume","refresh","incremental","covers"))
            val left=(state["left"] as? Number)?.toLong() ?: 0L
            if(left>0 && state["op"]=="full") {
                val blocked=((state["limit_note"] as? Map<*,*>)?.get("limit") as? Number)?.toLong()
                return if(manual || blocked==null || limit==null || limit>blocked) "resume" else null
            }
            if(action=="resume") return null
            val at=(state["at"] as? Number)?.toLong() ?: 0L
            if(action=="incremental" && (at<=0 || now-last<900)) return null
            return if(action=="refresh") if(at>0) "revalidate" else "full" else action
        }

        /** Status contains no protocol data or credentials, and is one budgeted display row. */
        fun status(store: CacheStore): Map<String,Any?> {
            val file=java.io.File(store.root,"mirror/status.lua")
            val saved=if(file.isFile && file.length()<=16384) runCatching { LuaValue.parse(file.readBytes()) as? Map<*,*> }.getOrNull().orEmpty() else emptyMap<Any,Any>()
            // Existing bulk checkpoints are retained only with their matching private plan.
            val checkpointOwner=saved["owner"] ?: run {
                val plan=java.io.File(store.root,"mirror/plan.lua")
                if(plan.isFile && plan.length()<=131072) (runCatching { LuaValue.parse(plan.readBytes()) }.getOrNull() as? Map<*,*>)?.get("owner") else null
            }
            val raw=if(checkpointOwner!=null && checkpointOwner==store.meta("owner") && saved["engine"]=="bulk") saved else emptyMap<Any,Any>()
            val fields=listOf("run","running","beat","op","at","done","total","left","pct","rate","eta_s","skipped","errors","covers","cover_total","limit_note","revalidating","bytes","started_at","why")
            val result=fields.associateWith { raw[it] }.toMutableMap()
            val at=(raw["at"] as? Number)?.toLong()?.takeIf { it>0 }
            result["saved_label"]=if(at==null) "Not saved for offline yet (hold refresh for a Full refresh)" else
                "Saved for offline · "+java.text.SimpleDateFormat("EEE HH:mm",java.util.Locale.getDefault()).format(java.util.Date(at*1000))+
                    (if(raw["limit_note"]!=null) " · storage limit reached" else "")
            result["row_count"]=1L
            return result
        }

        // Protocol inventory stays in this adapter. CatalogPlanTest verifies the shared source.
        val inventory: Map<*, *> by lazy { LuaValue.fromJson(INVENTORY) as Map<*, *> }
        private const val INVENTORY = """{
  "schema": 1,
  "source_sha256": {
    "catalog": "44268faca149407f0a5bf5e37f733ded03af63d81669b3bef0e92e03458195ef",
    "catalog_board": "9b15c2a8db85e0be7d68f95faf886dcb82eed8bbea1d4b1b5ae4c6911acd2470",
    "catalog_lists": "06cba6b3e3ba56338f0ea899ab369f9efac428c4ef21b92527cb34c9558a45f1",
    "catalog_dashboard": "721ecd6ed4553460e08a175a30c6053816a879b95a7064c14f69f636485cad10",
    "catalog_util": "5842c592af18d716e3cadeb4d0d6ef11c47113e6edaf0cb5b432943c009aeb75",
    "dashboard_sections": "90bbb02b9d99033b4fe9b55d2c9dc04a3f00626d4335c0fda6f008f98b8f58bf",
    "api": "5055593ddaa37831c8cc8b696ef7c9f4cdaf127166540368aa6ecdd5d87acfe1"
  },
  "root_sections": [
    "continue-reading",
    "recent",
    "libraries",
    "collections",
    "smart-scopes",
    "authors",
    "series",
    "all-books"
  ],
  "root_books": {
    "continue-reading": {
      "sort": "recently_read",
      "readStatus": "reading"
    },
    "recent": {
      "sort": "recently_added"
    },
    "all-books": {
      "sort": "title"
    }
  },
  "sections": [
    "libraries",
    "collections",
    "smart-scopes",
    "authors",
    "series"
  ],
  "selectors": {
    "libraries": [
      "libraryId"
    ],
    "collections": [
      "collectionId"
    ],
    "smart-scopes": [
      "smartScopeId"
    ],
    "authors": [
      "author"
    ],
    "series": [
      "seriesId",
      "series"
    ]
  },
  "home_books": {
    "recently-added": {
      "sort": "recently_added"
    },
    "pick-back-up": {
      "readStatus": "reading",
      "sort": "recently_read",
      "order": "asc"
    },
    "finished": {
      "readStatus": "finished",
      "sort": "recently_read"
    },
    "in-progress": {
      "sort": "recently_read",
      "readStatus": "reading"
    },
    "random": {
      "sort": "title"
    }
  },
  "dashboard_sections": [
    "want-to-read",
    "up-next-in-series"
  ],
  "book_sorts": [
    "title",
    "author",
    "recently_added",
    "recently_updated",
    "recently_read",
    "series"
  ],
  "list_sorts": [
    "title",
    "author",
    "series",
    "recently_added",
    "recently_read"
  ],
  "series_sorts": [
    "series",
    "published",
    "title",
    "recently_read",
    "recently_added"
  ],
  "read_statuses": [
    "unread",
    "reading",
    "finished"
  ],
  "formats": [
    "epub",
    "pdf",
    "cbz",
    "cbr",
    "mobi",
    "azw3",
    "fb2",
    "djvu",
    "txt"
  ],
  "section_sorts": [
    "name",
    "books",
    "name_desc"
  ],
  "section_filters": [
    "reading",
    "finished"
  ],
  "orders": [
    "asc",
    "desc"
  ],
  "local_limits": {
    "on_device_max_ids": 200,
    "not_on_device_max_ids": 200,
    "not_on_device_scan_pages": 5,
    "not_on_device_scan_size": 100
  },
  "local_lists": [
    "on-device",
    "not-on-device"
  ],
  "entries": [
    "root",
    "dashboard",
    "dashboard/discover"
  ]
}"""

        /** Build protocol templates on the worker, never in a plugin paint or IPC payload. */
        fun create(owner: String, operation: String, localIds: List<Long>, covers: Boolean,
            directory: String, limit: Long?, manual: Boolean, run: String = java.util.UUID.randomUUID().toString(), server: String = owner.substringAfter('|')): CacheWorker.Plan {
            require(operation in setOf("full","resume","revalidate","incremental","covers"))
            fun path(endpoint: String, query: Map<String,String> = emptyMap()): String = endpoint +
                MirrorLogic.encQuery(query).let { if(it.isEmpty()) "" else "?$it" }
            val endpoint="/koreader/plugin/catalog/books"
            val sections=(inventory["sections"] as List<*>).filterIsInstance<String>()
            val selectors=inventory["selectors"] as Map<*,*>
            val templates=sections.associateWith { section ->
                val keys=(selectors[section] as List<*>).filterIsInstance<String>()
                keys.mapIndexed { i,key -> (if(i==0) "path" else "series_name_path") to
                    path(endpoint,mapOf(key to MirrorLogic.SENTINEL,"sort" to "recently_added","order" to "desc")) }.toMap()
            }
            val browse=listOf("home_books","root_books").flatMap { name ->
                (inventory[name] as Map<*,*>).values.map { raw ->
                    val q=(raw as Map<*,*>).entries.associate { it.key.toString() to it.value.toString() }.toMutableMap()
                    q.putIfAbsent("order",if(q["sort"]?.startsWith("recently_")==true) "desc" else "asc")
                    path(endpoint,q)
                }
            }.distinct()
            val ids=localIds.distinct().sorted()
            return CacheWorker.Plan(mapOf("run" to run,"owner" to owner,"op" to operation,"manual" to manual,
                "server" to server,"catalog" to inventory,"sentinel" to MirrorLogic.SENTINEL,"templates" to templates,
                "detail_template" to "$endpoint/${MirrorLogic.SENTINEL}","all_books" to path(endpoint,mapOf("sort" to "title","order" to "asc")),
                "sections" to sections.map { catalogSectionName -> "/koreader/plugin/catalog/sections/$catalogSectionName" },"browse_lists" to browse,
                "dynamic_lists" to browse.filter(CatalogPlan::dynamic),
                "seed_details" to ids,"seed_lists" to if(ids.isEmpty()) emptyList<String>() else listOf(path(endpoint,mapOf("ids" to ids.take(200).joinToString(","),"sort" to "title","order" to "asc"))),
                "entries" to (inventory["entries"] as List<*>).map { catalogEntryName -> "/koreader/plugin/catalog/$catalogEntryName" } +
                    (inventory["dashboard_sections"] as List<*>).map { catalogShelfName -> "/koreader/plugin/catalog/dashboard/sections/$catalogShelfName" },
                "covers_on" to covers,"cover_dir" to directory,"limit" to limit))
        }

        /** Library picks are already the global base's library dimension. Keep the first base
         * (All books), avoiding repeated expansion through Home aliases and per-library rows. */
        fun scope(path: String): String {
            val (endpoint, encoded) = MirrorLogic.splitPath(path)
            val q = MirrorLogic.parseQuery(encoded)
            listOf("page", "size", "offset", "sort", "order", "buckets", "readStatus", "format", "libraryId").forEach(q::remove)
            return endpoint + "?" + MirrorLogic.encQuery(q)
        }

        fun dynamic(identity: String): Boolean {
            val q = MirrorLogic.parseQuery(MirrorLogic.splitPath(identity).second)
            return "readStatus" in q || "filter" in q || q["sort"] in setOf("recently_added", "recently_read")
        }

        fun kind(identity: String): String {
            val w = MirrorLogic.listWindow(identity) ?: return "other"
            w.section?.let { return "index:$it" }
            val q = MirrorLogic.parseQuery(MirrorLogic.splitPath(identity).second)
            return when {
                "seriesId" in q || "series" in q -> "series"
                "author" in q -> "author"
                "collectionId" in q -> "collection"
                "smartScopeId" in q -> "smart-scope"
                "libraryId" in q -> "library"
                "ids" in q -> "device"
                q["readStatus"] == "finished" -> "finished"
                q["readStatus"] == "reading" -> "reading"
                q["sort"] == "recently_added" -> "recently-added"
                else -> "books"
            }
        }
    }
}
