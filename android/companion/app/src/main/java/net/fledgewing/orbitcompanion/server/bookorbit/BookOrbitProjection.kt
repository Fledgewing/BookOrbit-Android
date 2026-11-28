package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import net.fledgewing.orbitcompanion.LibraryReadModel.Companion.MAX_ROWS
import net.fledgewing.orbitcompanion.LibraryReadModel.Companion.MAX_BYTES
import net.fledgewing.orbitcompanion.LibraryReadModel.Companion.MAX_BATCH

internal class BookOrbitProjection(private val store: CacheStore, private val clock: () -> Long = { System.currentTimeMillis()/1000 },
    private val fallbackReadingStats: (String) -> RemoteReadingStats? = { BookOrbitLibrary.readingStats(store) },
    private val accountState: () -> Map<String, Any?> = { mapOf("signedIn" to false) },
    private val accountStats: (String) -> Map<*, *>? = { null }) : ServerAdapter {
    override val id = "bookorbit"
    private var statusOverrides:Map<Long,CatalogStatusOverride> = emptyMap()
    private fun summary(owner:String,raw:Map<*,*>,rank:Long,local:Boolean?):Map<String,Any?> {
        val id=(raw["id"] as? Number)?.toLong()
        val override=id?.let(statusOverrides::get)
        return BookOrbitLibrary.summary(owner,if(override==null) raw else raw+mapOf("readStatus" to override.status),rank,local)+
            mapOf("status_note" to "Not synced".takeIf { override?.pending==true })
    }
    override fun localFiles(owner: String): List<LocalBook>? = BookOrbitLibrary.localEntries(store, owner)?.mapNotNull { entry ->
        val path = (entry["path"] as? String)?.let(LuaValue::utf8) ?: return@mapNotNull null
        val id = (entry["book_id"] as? Number)?.toLong() ?: return@mapNotNull null
        val raw = store.bookItem(id) as? Map<*, *> ?: emptyMap<Any, Any>()
        val book = summary(owner, raw, 0, true)
        LocalBook(java.io.File(path), book["status"] == "finished", entry["md5"] as? String)
    }

    override fun cachedReadingStats(owner: String): RemoteReadingStats? =
        if (store.meta("owner") == owner) fallbackReadingStats(owner) else null
    private fun freshness(saved: Boolean): Map<String, Any?> = mapOf("saved" to saved,
        "generation" to store.meta("bulk_active"), "origin" to "cached-remote", "at" to if (saved) store.meta("bulk_at")?.toLongOrNull() else null)
    private fun empty(saved: Boolean) = mapOf("items" to emptyList<Any>(), "total" to 0, "freshness" to freshness(saved), "empty" to if (saved) "No books" else "Not saved yet")
    /** Compatibility renderer input: neutral selectors in, bounded normalized display rows out.
     * CacheStore owns SQL/ranks/search and BulkCatalog owns generation materialization. */
    private fun connectorCatalog(owner: String, args: Map<*,*>): Map<String,Any?> {
        val view=args["view"] as? String ?: "books"
        val limit=((args["limit"] as? Number)?.toInt() ?: 24).coerceIn(1,24)
        val offset=((args["offset"] as? Number)?.toInt() ?: 0).coerceAtLeast(0)
        val selection=args["selection"] as? Map<*,*> ?: emptyMap<Any,Any>()
        val names=mapOf("library" to "libraryId","collection" to "collectionId","list" to "smartScopeId",
            "series" to "seriesId","series_name" to "series","author" to "author","format" to "format",
            "status" to "readStatus","ids" to "ids","search" to "q","direction" to "order","section_filter" to "filter")
        require(selection.keys.all { it in names || it=="sort" })
        require(selection.values.all { it is String && it.length<=4096 })
        val q=selection.entries.associate { (key,value) -> (names[key] ?: "sort") to value.toString() }.toMutableMap()
        q["sort"]?.let { sort -> q["sort"]=mapOf("added" to "recently_added","updated" to "recently_updated","last" to "recently_read")[sort] ?: sort }
        q["offset"]=offset.toString();q["size"]=limit.toString()
        val reference=args["reference"]
        val endpoint=when(view) {
            "books" -> "/koreader/plugin/catalog/books"
            "book" -> {
                val id=(reference as? Number)?.toLong() ?: BookOrbitLibrary.id(owner,"book",reference)
                require(id!=null && id>0)
                "/koreader/plugin/catalog/books/$id"
            }
            "index" -> {
                val category=args["category"] as? String
                require(category in setOf("libraries","collections","lists","authors","series"))
                "/koreader/plugin/catalog/sections/"+(if(category=="lists") "smart-scopes" else category)
            }
            else -> throw IllegalArgumentException("view")
        }
        val path=if(view=="book") endpoint else endpoint+"?"+MirrorLogic.encQuery(q)
        val body=if(view=="books" && !q["q"].isNullOrBlank()) store.search(q["q"]!!,offset,limit) else
            store.read(MirrorLogic.key(owner,store.meta("catalog_server") ?: owner.substringAfter('|'),path),path,"/koreader/plugin/catalog/books/${MirrorLogic.SENTINEL}")?.body as? Map<*,*>
            ?: return empty(false)
        val raw=if(view=="book") listOf(body) else (body["items"] as? List<*>).orEmpty()
        val items=raw.take(limit).mapNotNull { it as? Map<*,*> }.map { row ->
            if(view=="index") mapOf("reference" to row["id"],"title" to (row["name"] ?: row["title"]),"count" to (row["count"] ?: row["bookCount"]),
                "series_reference" to row["seriesId"],"reading" to row["readingCount"],"finished" to row["finishedCount"])
            else summary(owner,row,0,null) + mapOf("reference" to row["id"],"cover_revision" to row["updatedAt"],
                "cover_available" to (row["hasCover"]==true),"series_reference" to row["seriesId"],
                "description" to (row["description"] as? String)?.take(2048),
                "files" to (row["files"] as? List<*>).orEmpty().take(8).mapNotNull { it as? Map<*,*> }.map { file ->
                    mapOf("reference" to file["id"],"format" to file["format"],"bytes" to (file["sizeBytes"] ?: file["size"]),"digest" to (file["fileHash"] ?: file["md5"]),"revision" to file["contentVersion"],
                        "role" to file["role"],"filename" to file["filename"],"delivery" to file["downloadVariant"],"requested_delivery" to file["requestedVariant"],"local_path" to file["devicePath"])
                })
        }
        return mapOf("items" to items,"total" to (body["total"] ?: items.size),"offset" to offset,"limit" to limit,
            "more" to (offset+items.size<((body["total"] as? Number)?.toInt() ?: items.size)),"freshness" to freshness(true))
    }
    private fun connectorHome(owner: String, args: Map<*,*>): Map<String,Any?> {
        val shelves=(args["shelves"] as? List<*>).orEmpty(); val names=(args["names"] as? List<*>).orEmpty()
        require(shelves.size<=6 && names.size<=2)
        var rows=1
        val displays=linkedMapOf<String,Any?>()
        for(raw in shelves) {
            val shelf=raw as? Map<*,*> ?: continue
            val slot=shelf["slot"] as? String ?: continue
            require(slot.length<=100)
            val limit=minOf(4,24-rows)
            if(limit<=0) break
            val result=connectorCatalog(owner,mapOf("view" to "books","selection" to shelf["selection"],"limit" to limit))
            val items=(result["items"] as? List<*>).orEmpty()
            rows+=items.size; displays[slot]=items
        }
        val labels=linkedMapOf<String,Any?>()
        for(category in names.filterIsInstance<String>()) {
            val limit=minOf(4,24-rows)
            if(limit<=0) break
            val result=connectorCatalog(owner,mapOf("view" to "index","category" to category,"limit" to limit))
            val items=(result["items"] as? List<*>).orEmpty()
            rows+=items.size;labels[category]=items.mapNotNull { (it as? Map<*,*>)?.get("title") }
        }
        val cachedDashboardEndpoint="/koreader/plugin/catalog/dashboard"
        val raw=store.read(MirrorLogic.key(owner,store.meta("catalog_server") ?: owner.substringAfter('|'),cachedDashboardEndpoint),cachedDashboardEndpoint,null)?.body as? Map<*,*>
        val goal=raw?.get("readingGoal") as? Map<*,*>
        val streak=raw?.get("readingStreak") as? Map<*,*>
        val year=raw?.get("readingYear") as? Map<*,*>
        return mapOf("shelves" to displays,"names" to labels,"row_count" to maxOf(1,rows),
            "greeting" to raw?.get("displayName"),"account_label" to raw?.get("username"),"total" to (raw?.get("totalBooks") ?: raw?.get("bookCount")),
            "goal" to mapOf("year" to goal?.get("year"),"target" to goal?.get("goalBooks"),"completed" to goal?.get("completedBooks")),
            "streak" to mapOf("current" to streak?.get("currentStreak"),"best" to streak?.get("longestStreak")),
            "activity" to mapOf("start_date" to year?.get("startDate"),"minutes" to (year?.get("minutes") as? List<*>)?.take(371)),
            "freshness" to freshness(raw!=null || store.meta("bulk_active")!=null))
    }
    private fun connectorRoot(owner:String):Map<String,Any?> {
        val catalogRootEndpoint="/koreader/plugin/catalog/root"
        val body=store.read(MirrorLogic.key(owner,store.meta("catalog_server") ?: owner.substringAfter('|'),catalogRootEndpoint),catalogRootEndpoint,null)?.body as? Map<*,*>
        val categories=(body?.get("sections") as? List<*>).orEmpty().take(24).mapNotNull { it as? Map<*,*> }.map { section ->
            val kind=section["section"] ?: section["id"]
            mapOf("kind" to if(kind=="smart-scopes") "lists" else kind,"title" to section["title"],"count" to section["count"])
        }
        return mapOf("items" to categories,"freshness" to freshness(body!=null))
    }
    override fun personalCatalog(owner: String) = projectSaved(owner, mapOf("op" to "window", "source" to "all"), true)
    override fun project(owner: String, a: Map<*, *>): Map<String, Any?> = projectSaved(owner, a, false)
    private fun projectSaved(owner: String, a: Map<*, *>, personal: Boolean): Map<String, Any?> {
        statusOverrides=CatalogWorkflow.statusOverrides(store,owner)
        if (store.meta("owner") != owner) return mapOf("error" to "unauthorized", "items" to emptyList<Any>())
        val op = a["op"]
        if (op == "copies.state") {
            val state=CatalogWorkflow.load(java.io.File(store.root,"workflows/${BookOrbitLibrary.namespace(owner)}.lua"))
            return mapOf("pending" to (state["copies"] as? List<*>).orEmpty().size,"row_count" to 1)
        }
        if (op == "reader.finish") return FinishLogic.snapshot(store,owner,a)
        if (op == "connector.root") return connectorRoot(owner)
        if (op == "connector.home") return connectorHome(owner,a)
        if (op == "connector.catalog") return connectorCatalog(owner,a)
        if (op == "catalog.state") return CatalogPlan.status(store)
        if (op == "reader") {
            val path = a["path"] as? String ?: return empty(false)
            val entry = BookOrbitLibrary.localEntries(store, owner)?.firstOrNull { it["path"] == path }
                ?: return empty(false)
            val id = (entry["book_id"] as? Number)?.toLong() ?: return empty(false)
            val result = project(owner, a + mapOf("op" to "book", "key" to BookOrbitLibrary.key(owner, "book", id)))
            val current = (a["native_progress"] as? Number)?.toDouble()?.takeIf { it.isFinite() && it in 0.0..1.0 }
            val book = (result["items"] as? List<*>)?.singleOrNull() as? Map<*, *>
            return if (current != null && book != null) result + mapOf("items" to listOf(book +
                mapOf("progress" to current * 100, "progress_origin" to "local-reader"))) else result
        }
        if (op == "cover.reference") {
            val reference=a["reference"] as? String ?: return mapOf("error" to "missing")
            require(reference.length<=4096)
            val saved=store.meta("cover_ref_"+MirrorLogic.hash(reference))?.let { LuaValue.parse(it.toByteArray(Charsets.ISO_8859_1)) } as? Map<*,*>
            val path=if (saved?.get("reference")==reference) (saved["local_path"] as? String)?.let(LuaValue::utf8) else null
            return mapOf("local_path" to path?.takeIf { java.io.File(it).isFile }?.let(LuaValue::str),
                "stale" to (saved?.get("stale")==true),"freshness" to freshness(path!=null && java.io.File(path).isFile))
        }
        if (op == "cover") {
            val id = BookOrbitLibrary.id(owner,"book",a["key"]) ?: return mapOf("error" to "missing")
            val path = store.meta("cover_file_$id")?.let(LuaValue::utf8)
            val file = path?.let { java.io.File(it) }
            return mapOf("local_path" to file?.takeIf { it.isFile }?.path?.let(LuaValue::str),
                "stale" to (store.meta("cover_stale_$id") != null), "freshness" to freshness(file?.isFile == true))
        }
        if (op == "account.state") return accountState()
        if (op == "capabilities") {
            val remote = fallbackReadingStats(owner)
            val a = accountStats(owner).orEmpty()
            val server = accountState()
            val cachedDetail=(server["catalog"] as? Map<*,*>)?.get("cachedDetail")==true
            val managed = server["owner"] == owner
            val opds = (server["opds"] as? Map<*, *>)?.get("available") == true
            val sync = (server["sync"] as? Map<*, *>)?.get("available") == true
            return mapOf("collections" to (!managed || cachedDetail), "catalog" to (!managed || opds || cachedDetail), "detail" to (!managed || cachedDetail), "download" to opds,
                "lists" to mapOf("read" to (!managed || cachedDetail), "save" to false), "progress" to mapOf("read" to (!managed || sync || cachedDetail), "write" to sync, "syncCurrent" to (!managed || cachedDetail)),
                "status" to mapOf("read" to true, "write" to ((server["catalog"] as? Map<*,*>)?.get("canWriteStatus")==true)), "ratings" to mapOf("read" to true, "write" to false),
                "account" to server,
                "stats" to mapOf("days" to (a["days"] != null || remote?.days != null), "streak" to (remote?.streak != null),
                    "hours" to (a["hours"] != null), "sessions" to (a["sessions"] != null),
                    "goal" to (a["goal"] != null || remote?.goalAvailable == true),
                    "finished" to (a["finished"] != null || remote?.finished != null),
                    "yearReview" to false, "activityDetails" to false, "celebrations" to false),
                "retainedFinishedYears" to true,"retainedSeriesNext" to true,"readingStats" to true, "wantToRead" to true, "customFields" to false, "onDevice" to true,
                "series" to mapOf("read" to true, "downloadNext" to opds),
                "jobs" to mapOf("refresh" to BookOrbitLibrary.key(owner, "job", "refresh").takeIf { !managed || (server["catalog"] as? Map<*,*>)?.get("canRefresh")==true }),
                "limits" to mapOf("rows" to MAX_ROWS, "bytes" to MAX_BYTES, "batch" to MAX_BATCH))
        }
        val requestedSource=a["source"] as? Map<*,*>
        if(op in setOf("window","counts","facets","groups") && requestedSource?.get("kind")=="finished-year") {
            val year=if(requestedSource["key"]=="current") java.time.Instant.ofEpochSecond(clock()).atZone(java.time.ZoneId.systemDefault()).year else requestedSource["key"].toString().toIntOrNull() ?: throw IllegalArgumentException("invalid year")
            return FinishedYears.window(store,owner,year,a)
        }
        if(op in setOf("window","counts","facets","groups") && a["source"]=="series-next") return UpNextSelection.window(store,owner,a,clock())
        if (op == "sources") {
            val category=a["category"] as? String ?: "builtin"
            require(category in setOf("builtin","lists","series","authors","collections","libraries"))
            val offset=((a["offset"] as? Number)?.toInt() ?: 0).coerceAtLeast(0)
            val limit=((a["limit"] as? Number)?.toInt() ?: 6).coerceIn(1,6)
            if (category=="lists" && a["allow_lists"]==false || category=="collections" && a["allow_collections"]==false) return empty(true)
            if (category in setOf("lists","series","collections","libraries")) return BookOrbitLibrary.sourceSections(store,owner,category,offset,limit)
            if (category=="authors") {
                val page=project(owner,mapOf("op" to "facets","source" to "library/all","field" to "author","offset" to offset,"limit" to limit))
                val rows=(page["items"] as? List<*>).orEmpty().map { raw ->
                    val row=raw as Map<*,*>
                    mapOf("src" to "author:${row["value"]}","title" to LuaValue.boundedText(LuaValue.utf8(row["label"].toString()),80),"count" to row["count"])
                }
                return page + mapOf("items" to rows,"total" to page["option_total"])
            }
            val definitions=listOf(Triple("custom","Custom filter","library/all"),Triple("recent","Recently added","recently-added"),
                Triple("wtr","Want to read","want-to-read"),Triple("reading","Reading now","reading"),
                Triple("finished","All finished","finished"),Triple("device","On this device","on-device"),Triple("pickup","Pick back up","pick-back-up"),Triple("upnext","Up next in series","series-next"),Triple("unopened","Unopened on this reader","unopened"))
                .filter { (src,_,_) -> !(src=="wtr" && a["allow_wtr"]==false || src=="device" && a["allow_device"]==false) }
            val builtins=definitions.map { (src,title,source) ->
                val count=if(src=="unopened") emptyMap() else project(owner,mapOf("op" to "counts","source" to source,"exclude_current" to (src=="reading")))
                mapOf("src" to src,"title" to title,"default_sort" to 0.takeIf { src in setOf("pickup","upnext","unopened") },"count" to if ((count["freshness"] as? Map<*,*>)?.get("saved")==true) count["total"] else null)
            }
            val options=builtins+FinishedYears.options(store,owner,clock())
            val rows=options.drop(offset).take(limit)
            return mapOf("items" to rows,"total" to options.size,"next" to (offset+rows.size).takeIf { it<options.size },
                "freshness" to freshness(store.meta("bulk_active")!=null))
        }
        if (op == "collections") {
            val g=store.meta("bulk_active")?.toLongOrNull() ?: return empty(false)
            if(store.meta("bulk_complete")?.toLongOrNull()!=g) return empty(false)
            val limit=((a["limit"] as? Number)?.toInt() ?: 6).coerceIn(1,6)
            val offset=((a["offset"] as? Number)?.toInt() ?: 0).coerceAtLeast(0)
            val rows=store.db().query("SELECT id,name,n FROM bulk_sections WHERE g=? AND section='collections' ORDER BY pos LIMIT ? OFFSET ?",g,limit+1,offset) {
                mapOf("key" to BookOrbitLibrary.key(owner,"collection",it.text(0) ?: ""),"title" to LuaValue.boundedText(it.text(1) ?: "",80),"count" to it.long(2))
            }
            return mapOf("items" to rows.take(limit),"next" to (offset+limit).takeIf { rows.size>limit },"freshness" to freshness(true))
        }
        if (op == "lists") {
            val g = store.meta("bulk_active")?.toLongOrNull() ?: return empty(false)
            if (store.meta("bulk_complete")?.toLongOrNull() != g) return empty(false)
            val limit = ((a["limit"] as? Number)?.toInt() ?: 8).coerceIn(1, MAX_ROWS)
            val offset = ((a["offset"] as? Number)?.toInt() ?: 0).coerceAtLeast(0)
            val rows = store.db().query("SELECT id,name,n FROM bulk_sections WHERE g=? AND section='smart-scopes' ORDER BY pos LIMIT ? OFFSET ?", g, limit, offset) {
                mapOf("key" to BookOrbitLibrary.key(owner, "list", it.text(0) ?: ""), "title" to it.text(1), "count" to it.long(2))
            }
            return mapOf("items" to rows, "freshness" to freshness(true))
        }
        if (op == "job") {
            require(a["key"] == BookOrbitLibrary.key(owner, "job", "refresh"))
            val states = store.db().query("SELECT state,count(*) FROM jobs GROUP BY state") { (it.long(0) ?: 0) to (it.long(1) ?: 0) }.toMap()
            return mapOf("key" to a["key"], "pending" to (states[0L] ?: 0), "done" to (states[1L] ?: 0), "failed" to (states[2L] ?: 0), "freshness" to freshness(true))
        }
        if (op in setOf("book", "progress", "status")) {
            val id = BookOrbitLibrary.id(owner, "book", a["key"]) ?: return mapOf("error" to "missing")
            val raw = store.bookItem(id) as? Map<*, *> ?: return mapOf("error" to "missing", "freshness" to freshness(false))
            val summary = summary(owner, raw, 0, null).toMutableMap()
            if (op == "book") {
                val entry = BookOrbitLibrary.localEntries(store, owner)?.firstOrNull { (it["book_id"] as? Number)?.toLong() == id }
                summary["stats"] = ReaderBookStats.read(store.root, entry)
            }
            val detail = store.detail(id)
            if (op == "book" && detail?.first is Map<*, *>) {
                val d = detail.first as Map<*, *>
                summary["description"] = (d["description"] as? String)?.let(LuaValue::utf8)?.replace(Regex("<[^>]*>"), "")?.take(2048)?.let(LuaValue::str)
                summary["files"] = (d["files"] as? List<*>)?.mapNotNull { it as? Map<*, *> }?.map { f ->
                    mapOf("key" to (f["id"] as? Number)?.let { BookOrbitLibrary.key(owner, "file", it.toLong()) }, "format" to (f["format"] as? String), "bytes" to (f["size"] as? Number), "revision" to (f["contentVersion"] as? String))
                }
                summary["available"] = (summary["available"] as? Map<*, *>).orEmpty() + mapOf("detail" to true, "cover" to false)
            }
            return when (op) {
                "progress" -> mapOf("key" to a["key"], "progress" to summary["progress"], "last_read" to summary["last_read"], "freshness" to freshness(true))
                "status" -> mapOf("key" to a["key"], "status" to summary["status"], "status_raw" to summary["status_raw"], "freshness" to freshness(true))
                else -> mapOf("items" to listOf(summary), "freshness" to freshness(true), "detail_at" to detail?.second)
            }
        }
        require(op == "series.preview" || op == "series" || op == "groups" || op == "window" || op == "counts" || op == "facets" || op == "library.summary")
        val f = a["query"] as? Map<*, *> ?: emptyMap<Any, Any>()
        BookOrbitLibrary.translate(f) // validates; same plan is available to future remote checks
        val source = if (op == "library.summary") "library/all" else if (op in setOf("series","series.preview")) mapOf("kind" to "series", "key" to a["key"]) else a["source"]
        val kind = if (source is String) source else (source as? Map<*, *>)?.get("kind") as? String
        val sourceKey = (source as? Map<*, *>)?.get("key")
        require(kind in setOf("library/all", "all", "reading", "want-to-read", "recently-added", "finished", "pick-back-up", "on-device", "list", "collection", "library", "series", "author", "search", "selection"))
        val activeGeneration = store.meta("bulk_active")?.toLongOrNull() ?: return empty(false)
        val completeGeneration=store.meta("bulk_complete")?.toLongOrNull()
        val incomplete=completeGeneration!=activeGeneration
        if(op=="series.preview" && incomplete) return mapOf("error" to "incomplete","items" to emptyList<Any>(),"row_count" to 1)
        val seriesContext=kind=="series" || op=="groups" && f["group"]=="series"
        val g=if(seriesContext && incomplete) completeGeneration ?: return empty(false) else activeGeneration
        // Secondary contexts are not complete at base publication; never turn an unknown source into an empty list.
        if (kind in setOf("list", "collection", "library") && incomplete) return empty(false)

        val localPaths = BookOrbitLibrary.localPaths(store, owner)
        val local = localPaths?.keys
        if ((a["field"] == "where" || kind == "on-device" || f["where"] in setOf("on-device", "server-only")) && local == null) return empty(false)
        val membership = when (kind) {
            "selection" -> {
                val selection=(source as? Map<*,*>)?.get("selection") as? Map<*,*> ?: emptyMap<Any,Any>()
                val selected=linkedMapOf<Long,Map<*,*>>()
                var offset=0
                while(true) {
                    val window=connectorCatalog(owner,mapOf("view" to "books","selection" to selection,"offset" to offset,"limit" to 24))
                    if((window["freshness"] as? Map<*,*>)?.get("saved")!=true) return empty(false)
                    val rows=(window["items"] as? List<*>).orEmpty()
                    for(raw in rows) {
                        val b=raw as? Map<*,*> ?: continue
                        (b["reference"] as? Number)?.toLong()?.let { selected[it]=emptyMap<Any,Any>() }
                    }
                    if(rows.isEmpty() || window["more"]!=true) break
                    offset+=rows.size
                }
                selected
            }
            "list", "series", "collection", "library" -> {
                val id = BookOrbitLibrary.id(owner, kind, sourceKey) ?: return mapOf("error" to "missing")
                val section = when(kind) { "list" -> "smart-scopes"; "collection" -> "collections";"library" -> "libraries"; else -> "series" }
                val exists = store.db().query("SELECT 1 FROM bulk_sections WHERE g=? AND section=? AND id=? LIMIT 1", g, section, if (kind == "series") "series:$id" else id.toString()) { true }.isNotEmpty()
                if (!exists) return mapOf("error" to "missing")
                store.db().query("SELECT id,context FROM bulk_members WHERE g=? AND kind=? AND value=?", g, when(kind) { "list" -> "smartScopeId"; "collection" -> "collectionId";"library" -> "libraryId"; else -> "seriesId" }, id.toString()) {
                    it.long(0)!! to (it.bytes(1)?.let(LuaValue::parse) as? Map<*, *>).orEmpty()
                }.toMap()
            }
            else -> null
        }
        val filter = f.entries.associate { it.key.toString() to it.value }.toMutableMap()
        val sourceFilter = mutableMapOf<String, Any?>()
        val excludeCurrent=a["exclude_current"]==true || kind=="pick-back-up"
        when (kind) {
            "reading" -> { sourceFilter["show"] = "reading"; if (filter["sort"] == null) { filter["sort"] = "last"; filter["dir"] = "desc" } }
            "pick-back-up" -> { sourceFilter["show"]="reading";if(filter["sort"]==null) { filter["sort"]="last";filter["dir"]="asc" } }
            "want-to-read" -> sourceFilter["wtr"] = true
            "finished" -> sourceFilter["show"] = "finished"
            "recently-added" -> if (filter["sort"] == null) { filter["sort"] = "added"; filter["dir"] = "desc" }
            "author" -> { require(sourceKey is String); sourceFilter["author"] = listOf(sourceKey) }
            "on-device" -> sourceFilter["where"] = "on-device"
            "series" -> if (filter["sort"] == null) filter["sort"] = "series"
            "search" -> if (filter["sort"] == null) filter["sort"] = "match"
        }
        val facet = if (op == "facets" && a["field"] != null) LibraryFacets(a["field"].toString(), filter, clock()) else null
        val selected = ArrayList<Map<String, Any?>>()
        // Bounded DB chunks; parsing, filter fallback, joins, sort and counts stay off KOReader.
        var current: Map<String, Any?>? = null
        val currentOrder=LibraryFilter.comparator(mapOf("sort" to "last","dir" to "desc"))
        var after = -1L
        while (true) {
            val batch = store.db().query("SELECT id,item FROM bulk_books WHERE g=? AND id>? ORDER BY id LIMIT 256", g, after) { it.long(0)!! to it.bytes(1)!! }
            if (batch.isEmpty()) break
            for ((id, bytes) in batch) {
                val raw = LuaValue.parse(bytes) as? Map<*, *> ?: continue
                val context = membership?.get(id).orEmpty()
                val enriched = raw.entries.associate { it.key to it.value } + context
                val b = summary(owner, enriched, (context["_booksyncRank"] as? Number)?.toLong() ?: id, local?.contains(id)).toMutableMap()
                b["local_path"] = localPaths?.get(id)
                val q = f["q"]?.toString()?.let(LuaValue::utf8)?.lowercase(java.util.Locale.ROOT).orEmpty()
                val title = b["title"]?.toString()?.let(LuaValue::utf8)?.lowercase(java.util.Locale.ROOT).orEmpty()
                b["match"] = when { title == q -> 0; title.startsWith(q) -> 1; q in title -> 2; else -> 3 }
                if (excludeCurrent && kind in setOf("reading","pick-back-up") && LibraryFilter.matches(b,mapOf("show" to "reading")) &&
                    (current==null || currentOrder.compare(b,current!!)<0)) current=b.toMap()
                if(kind=="pick-back-up" && (b["last_read"]==null || (b["last_read"] as? String)?.isBlank()==true)) {
                    b["last_read"]=null // the shared comparator keeps unknowns after dated rows
                    b["status_note"]=(b["status_note"] as? String)?.let { "$it; last read unknown" } ?: "Last read unknown"
                }
                if ((membership == null || id in membership) && LibraryFilter.matches(b, sourceFilter)) {
                    facet?.include(b)
                    if (LibraryFilter.matches(b, filter)) selected.add(b)
                }
            }
            after = batch.last().first
        }
        if (excludeCurrent && kind in setOf("reading","pick-back-up") && current!=null) {
            selected.removeAll { it["key"]==current!!["key"] }
            facet?.include(current!!,-1)
        }
        if(op=="series.preview") {
            if(incomplete || local==null) return mapOf("error" to "incomplete","items" to emptyList<Any>(),"row_count" to 1)
            val currentKey=localPaths.entries.firstOrNull { it.value==a["open_path"] }?.key?.let { BookOrbitLibrary.key(owner,"book",it) }
            val plan=SeriesDownloadPlan.select(selected,((a["count"] as? Number)?.toInt() ?: 3),currentKey,a["start_key"] as? String,CatalogTransfers.activeKeys(store.root,owner))
            val rows=plan.books.map { b ->
                val id=BookOrbitLibrary.id(owner,"book",b["key"])!!
                val d=store.detail(id)?.first as? Map<*,*>
                val files=(d?.get("files") as? List<*>).orEmpty().mapNotNull { it as? Map<*,*> }.filter { CopiesLogic.pick(listOf(it),it["id"])!=null }
                mapOf("key" to b["key"],"title" to b["title"],"number" to b["series_position"],"bytes" to files.singleOrNull()?.get("size"))
            }
            val fingerprint=LuaValue.encode(mapOf("g" to g,"series" to sourceKey,"anchor" to plan.anchor,"keys" to rows.map { it["key"] }))
            val token=java.security.MessageDigest.getInstance("SHA-256").digest(fingerprint).joinToString("") { "%02x".format(it) }
            return mapOf("items" to rows,"token" to token,"earlier_key" to plan.earlier?.get("key"),"earlier_title" to plan.earlier?.get("title"),"row_count" to (1+rows.size),"freshness" to freshness(true))
        }
        val total = selected.size
        if (op == "facets") {
            val offset = ((a["offset"] as? Number)?.toInt() ?: 0).coerceAtLeast(0)
            val limit = ((a["limit"] as? Number)?.toInt() ?: MAX_ROWS).coerceIn(1, MAX_ROWS)
            return (facet?.page(offset, limit) ?: mapOf("items" to emptyList<Any>())) + mapOf("total" to total, "freshness" to freshness(true))
        }
        if (op == "library.summary") {
            // Root counts are known only after every secondary index is published.
            val roots=if(incomplete) emptyMap<String,Long>() else store.db().query(
                "SELECT section,count(*) FROM bulk_sections WHERE g=? AND section IN ('libraries','authors','series','collections','smart-scopes') GROUP BY section",g) { it.text(0)!! to it.long(1)!! }.toMap()
            val browse=mapOf("complete" to !incomplete)+listOf("libraries","authors","series","collections","lists").associateWith { name ->
                if(incomplete) null else roots[if(name=="lists") "smart-scopes" else name] ?: 0L
            }
            return mapOf("total" to total,"in_progress" to selected.count { it["status"] in setOf("reading","rereading") },
                "on_device" to local?.let { selected.count { b -> b["local_path"] != null } },"browse" to browse,
                "coverage" to if(incomplete) "Catalog indexes updating" else "Saved catalog indexes","freshness" to freshness(true))
        }
        val counts = selected.groupingBy { it["status"].toString() }.eachCount()
        if (op == "counts") return mapOf("total" to total, "statuses" to counts, "freshness" to freshness(true))
        if (op == "series" || op == "groups") {
            if (op == "groups") require(filter["group"] in setOf("series", "author"))
            val offset = ((a["offset"] as? Number)?.toInt() ?: 0).coerceAtLeast(0)
            val limit = ((a["limit"] as? Number)?.toInt() ?: 12).coerceIn(5, MAX_ROWS)
            val result = if (op == "groups") SeriesPresentation.groups(selected, filter, offset, limit,
                ((a["preview"] as? Number)?.toInt() ?: 3).coerceIn(1,9), ((a["group_limit"] as? Number)?.toInt() ?: limit/4).coerceIn(1,6)) else {
                val id = BookOrbitLibrary.id(owner, "series", sourceKey)!!
                val title = store.db().query("SELECT name FROM bulk_sections WHERE g=? AND section='series' AND id=?", g, "series:$id") { it.text(0)?.let(LuaValue::str) }.firstOrNull()
                SeriesPresentation.series(selected, title, offset, limit)
            }
            val projected = if (op == "groups" && filter["group"] == "series") {
                val rows = (result["items"] as List<*>).map { raw ->
                    @Suppress("UNCHECKED_CAST") val row = raw as Map<String,Any?>
                    val key = row["series_key"]
                    if (key == null) row else {
                        val series = project(owner, mapOf("op" to "series","key" to key,"limit" to 5))
                        row + mapOf("dots" to series["dots"],"dot_caption" to series["dot_caption"])
                    }
                }
                result + mapOf("items" to rows)
            } else result
            return projected + mapOf("membership_incomplete" to incomplete,"freshness" to (freshness(true)+mapOf("stale" to incomplete)))
        }
        // Internal worker input only; UI window requests keep their original row cap.
        if (personal) return mapOf("items" to selected, "freshness" to freshness(true))
        selected.sortWith(LibraryFilter.comparator(filter))
        val offset = ((a["offset"] as? Number)?.toInt() ?: 0).coerceAtLeast(0)
        val limit = ((a["limit"] as? Number)?.toInt() ?: MAX_ROWS).coerceIn(1, MAX_ROWS)
        val window = selected.drop(offset).take(limit).map { it + ("group" to LibraryFilter.group(it, filter)) }
        return mapOf("items" to window, "total" to total, "offset" to offset, "next" to (offset + window.size).takeIf { it < total },
            "freshness" to freshness(true), "local_coverage" to if (local == null) "not-saved" else "tracked-files", "empty" to if (total == 0) "No books" else null)
    }
}
