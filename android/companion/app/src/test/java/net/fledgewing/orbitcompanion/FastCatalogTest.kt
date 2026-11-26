package net.fledgewing.orbitcompanion

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject

// @fixture catalog/bulk-refresh/catalog.json @fixture catalog/bulk-refresh/schema.sql
class FastCatalogTest {
    private val fixture = LuaValue.fromJson(File("../../../shared/fixtures/catalog/bulk-refresh/catalog.json").readText()) as Map<*, *>
    private val inventory = LuaValue.fromJson(File("../../../shared/fixtures/catalog/sections.json").readText()) as Map<*, *>
    private val base = "/koreader/plugin/catalog"
    private val books = (fixture["manifest"] as List<*>).map { it as Map<*, *> }
    private val rows = (fixture["rows"] as List<*>).map { it as Map<*, *> }
    private val sections = fixture["sections"] as Map<*, *>
    private val memberships = fixture["memberships"] as Map<*, *>
    private val ranks = fixture["ranks"] as Map<*, *>
    private fun ids(items: List<*>) = items.map { (it as Map<*, *>)["id"] as Long }
    private fun plan(op: String = "full") = CacheWorker.Plan(mapOf("op" to op, "run" to "bulk", "owner" to "reader|https://books.example/api/v1", "catalog" to inventory, "detail_template" to "$base/books/BOOK_ID?deviceId=fixture-reader&variant=original"))
    private class CatalogFailure : RuntimeException()
    private fun reply(request: String): Map<*, *> {
        val (endpoint, encoded) = MirrorLogic.splitPath(request)
        val q = MirrorLogic.parseQuery(encoded)
        val size = q["size"]?.toInt() ?: 100
        val page = q["page"]?.toInt() ?: 1
        if (endpoint.endsWith("/manifest")) {
            val start = q["cursor"]?.toInt() ?: 0
            val next = minOf(start+size, books.size)
            return mapOf("items" to books.subList(start,next), "hasNext" to (next<books.size), "nextCursor" to if (next<books.size) next.toString() else null)
        }
        if (endpoint.contains("/sections/") && !endpoint.contains("/dashboard/")) {
            val items = sections[endpoint.substringAfterLast('/')] as List<*>
            return mapOf("items" to items.drop((page-1)*size).take(size), "total" to items.size.toLong())
        }
        if (!endpoint.endsWith("/books")) return emptyMap<String,Any?>()
        var selected = rows
        for (selector in listOf("libraryId","collectionId","smartScopeId","seriesId")) q[selector]?.let {
            val set = (memberships["$selector:$it"] as List<*>).toSet()
            selected = selected.filter { row -> row["id"] in set }
        }
        q["series"]?.let { name -> selected = selected.filter { row -> row["seriesName"].toString().lowercase() == name.lowercase() } }
        q["ids"]?.let { value -> selected = selected.filter { (it["id"] as Long) in value.split(',').map(String::toLong) } }
        q["readStatus"]?.let { s -> selected = selected.filter { BulkCatalog.status(it["readStatus"]) == s } }
        val rank = ranks["${q["sort"]}:${q["order"]}"] as? List<*>
        selected = if(q["sort"]=="title") selected.sortedWith { a,b ->
            val c=a["title"].toString().compareTo(b["title"].toString())
            if(c!=0) if(q["order"]=="desc") -c else c else (a["id"] as Long).compareTo(b["id"] as Long)
        } else selected.sortedBy { if (rank != null) rank.indexOf(it["id"]) else (it["id"] as Long).toInt() }
        if(q["sort"]=="series" && q["order"]=="desc")selected=selected.reversed()
        if (q["seriesId"] != null || q["series"] != null) selected = selected.map { row ->
            val c = (fixture["secondary_context"] as Map<*, *>)["seriesId:${q["seriesId"] ?: "202"}:${row["id"]}"] as? Map<*, *>
            if (c == null) row else row.entries.associate { it.key to it.value } + c
        }.sortedBy { (it["seriesIndex"]?.toString()?.toDoubleOrNull() ?: 0.0) }
        return mapOf("items" to selected.drop((page-1)*size).take(size), "total" to selected.size.toLong())
    }
    private fun run(store: CacheStore, op: String = "full", request: (String) -> Map<*, *> = ::reply, progress: (Int)->Unit = {}) =
        FastCatalogRefresh(store, plan(op), request, {}, {false}, {1000}, progress, { println(it) }).run()

    @Test fun refreshLogsStartEachPhaseAndFinish() {
        val root = Files.createTempDirectory("bulk-observable").toFile()
        try {
            CacheStore(root, {}, ::JdbcSql).use { store ->
                val logs = arrayListOf<String>()
                assertEquals("finished", FastCatalogRefresh(store, plan(), ::reply, {}, { false }, { 1000 }, {}, logs::add).run())
                assertTrue(logs.any { it.startsWith("bulk: start") })
                assertTrue(logs.any { it.startsWith("bulk: manifest requests=") })
                assertTrue(logs.any { it.startsWith("bulk: finish result=finished") })
            }
        } finally { root.deleteRecursively() }
    }

    @Test fun workerReplacesCrawlStatusWithFreshZeroBeforeFetchingAndReportsBulkCompletion() {
        val root = Files.createTempDirectory("bulk-fresh-status").toFile()
        val status = File(root, "mirror/status.lua").apply {
            parentFile!!.mkdirs()
            writeBytes(LuaValue.encode(mapOf("run" to "old", "done" to 85L, "left" to 15L, "at" to 1L, "bytes" to 3032748032L)))
        }
        val logs = arrayListOf<String>()
        val progress = arrayListOf<Long?>()
        var requests = 0
        fun state() = LuaValue.parse(status.readBytes()) as Map<*, *>
        val worker = CacheWorker(root, { url, _, _, _ ->
            if (requests++ == 0) {
                assertEquals("bulk", state()["engine"])
                assertEquals("bulk", state()["run"])
                assertEquals(0L, state()["pct"])
                assertEquals(0L, state()["done"])
                assertTrue((state()["bytes"] as Long) < 1024 * 1024)
                assertTrue((state()["beat"] as Long) > 1L)
            }
            CacheWorker.Reply(200, JSONObject(reply(url.substringAfter("/api/v1"))).toString().toByteArray())
        }, now = { 2000L }, log = logs::add, openSql = ::JdbcSql, onProgress = progress::add)
        try {
            assertEquals("finished", worker.run(plan(), CacheWorker.Creds("https://books.example/api/v1", "reader", "key")))
            assertTrue(requests > 0)
            assertEquals(0L, progress.first())
            assertTrue(progress.filterNotNull().any { it in 1L..99L })
            assertEquals(100L, state()["pct"])
            assertEquals(0L, state()["left"])
            assertEquals(2000L, state()["at"])
            assertTrue(logs.any { it.startsWith("bulk: start op=full") })
            assertTrue(logs.any { it.startsWith("bulk: manifest requests=") })
            assertTrue(logs.any { it.startsWith("bulk: finish result=finished") })
        } finally { worker.store.close(); root.deleteRecursively() }
    }

    @Test fun storageRetirementJoinsARunningMirrorTransaction() = nestedMirrorWrite(true)
    @Test fun patchJoinsARunningMirrorTransaction() = nestedMirrorWrite(false)

    private fun nestedMirrorWrite(retire: Boolean) {
        val root = Files.createTempDirectory("bulk-nested-writes").toFile()
        lateinit var worker: CacheWorker
        var nested = false
        val creds = CacheWorker.Creds("https://books.example/api/v1", "reader", "key")
        worker = CacheWorker(root, { url, _, _, _ ->
            CacheWorker.Reply(200, JSONObject(reply(url.substringAfter("/api/v1"))).toString().toByteArray())
        }, log = {}, openSql = { file ->
            val jdbc = JdbcSql(file)
            object : Sql by jdbc {
                override fun exec(sql: String, vararg args: Any?) {
                    jdbc.exec(sql, *args)
                    // Re-enter the public helpers while a mirror page is landing.
                    if (!nested && sql.startsWith("INSERT OR REPLACE INTO bulk_books")) {
                        nested = true
                        worker.store.setMeta("bulk_active", 1L)
                        if (retire) worker.storage(CacheWorker.StorageAsk("during mirror", null, null, false))
                        else {
                            worker.patch(1L, mapOf("rating" to 4L), true, false)
                            assertEquals(4L, (worker.store.bookItem(1L) as Map<*, *>)["rating"])
                        }
                    }
                }
            }
        })
        try {
            assertEquals("finished", worker.run(plan(), creds))
            assertTrue(nested)
            val summary = LuaValue.parse(File(root, "mirror/summary.lua").readBytes()) as Map<*, *>
            assertEquals("finished", summary["why"])
        } finally { worker.store.close(); root.deleteRecursively() }
    }

    @Test fun failedRunWritesSummaryAndResumeKeepsSavedProgressAndPages() {
        val root = Files.createTempDirectory("bulk-failed-summary").toFile()
        val creds = CacheWorker.Creds("https://books.example/api/v1", "reader", "key")
        var fail = false
        val requested = arrayListOf<String>()
        val progress = arrayListOf<Long?>()
        val worker = CacheWorker(root, { url, _, _, _ ->
            val path = url.substringAfter("/api/v1")
            requested.add(path)
            CacheWorker.Reply(200, JSONObject(reply(path)).toString().toByteArray())
        }, log = {}, openSql = ::JdbcSql, onProgress = progress::add,
            checkpoint = { if (fail) { fail = false; error("injected storage failure") } })
        fun state(name: String) = LuaValue.parse(File(root, "mirror/$name.lua").readBytes()) as Map<*, *>
        try {
            var stop = false
            assertEquals("incomplete coverage", FastCatalogRefresh(worker.store, plan(), ::reply,
                { if (stop) throw CatalogFailure() }, { false }, { 1000 }, { if (it == 15) { assertEquals("15", worker.store.meta("bulk_stage_pct")); stop = true } }, {}).run())
            assertEquals("15", worker.store.meta("bulk_stage_pct"))
            fail = true
            try {
                worker.run(plan("resume"), creds)
                throw AssertionError("expected failure")
            } catch (_: IllegalStateException) { }
            assertEquals("failed", state("summary")["why"])
            val saved = state("summary")["status"] as Map<*, *>
            assertEquals(15L, saved["done"])
            assertEquals(85L, saved["left"])
            progress.clear()
            assertEquals("finished", worker.run(plan("resume"), creds))
            assertEquals(15L, progress.first())
            assertTrue(requested.none { "/manifest" in it })
            assertEquals(100L, state("status")["done"])
        } finally { worker.store.close(); root.deleteRecursively() }
    }

    @Test fun failedDatabaseSessionStillRepliesAndIsReopenedOnRetry() {
        val root = Files.createTempDirectory("bulk-broken-session").toFile()
        var broken = false
        var opens = 0
        val worker = CacheWorker(root, { url, _, _, _ ->
            CacheWorker.Reply(200, JSONObject(reply(url.substringAfter("/api/v1"))).toString().toByteArray())
        }, log = {}, openSql = { file ->
            opens++
            val jdbc = JdbcSql(file)
            object : Sql by jdbc {
                override fun <T> query(sql: String, vararg args: Any?, row: (Sql.Row) -> T): List<T> {
                    check(!broken) { "broken SQLite session" }
                    return jdbc.query(sql, *args, row = row)
                }
                override fun close() { jdbc.close(); broken = false }
            }
        })
        try {
            worker.store.db()
            File(root, "mirror/status.lua").apply {
                parentFile!!.mkdirs()
                writeBytes(LuaValue.encode(mapOf("engine" to "bulk", "op" to "full", "done" to 15L, "total" to 100L, "left" to 85L)))
            }
            broken = true
            try {
                worker.run(plan("resume"), CacheWorker.Creds("https://books.example/api/v1", "reader", "key"))
                throw AssertionError("expected broken session")
            } catch (e: IllegalStateException) { assertEquals("broken SQLite session", e.message) }
            val summary = LuaValue.parse(File(root, "mirror/summary.lua").readBytes()) as Map<*, *>
            assertEquals("failed", summary["why"])
            assertEquals(15L, (summary["status"] as Map<*, *>)["done"])
            assertEquals("finished", worker.run(plan("resume"), CacheWorker.Creds("https://books.example/api/v1", "reader", "key")))
            assertEquals(2, opens)
        } finally { worker.store.close(); root.deleteRecursively() }
    }

    @Test fun schemaMatchesThePluginFixture() {
        assertEquals(BulkCatalog.schema,File("../../../shared/fixtures/catalog/bulk-refresh/schema.sql").readLines().filter(String::isNotBlank).map {it.removeSuffix(";")})
    }
    @Test fun offlineWindowsUseCanonicalBooksAndContextualSeries() {
        val root = Files.createTempDirectory("bulk-catalog").toFile()
        CacheStore(root, {}, ::JdbcSql).use { store ->
            val requests = ArrayList<String>()
            val progress = ArrayList<Int>()
            assertEquals("finished", run(store, request = { requests.add(it); reply(it) }, progress = progress::add))
            assertEquals(progress.sorted(), progress)
            assertEquals(100, progress.last())
            assertTrue(requests.none { Regex("/books/[0-9]+").containsMatchIn(it) })
            assertTrue(requests.filter { "/manifest?" in it }.all {
                val q = MirrorLogic.parseQuery(MirrorLogic.splitPath(it).second)
                q["deviceId"] == "fixture-reader" && q["variant"] == "original"
            })
            assertEquals(1, requests.count { "seriesId=" in it })
            assertEquals(1, requests.count { "series=" in it })
            for (value in fixture["windows"] as List<*>) {
                val w = value as Map<*, *>
                val identity = "$base/books?${w["query"]}"
                assertEquals(identity, w["ids"], ids(store.window(identity,1,100,null)!!["items"] as List<*>))
                val expected = w["ids"] as List<*>
                for (offset in 0..expected.size+1) for (size in listOf(1,3,100)) {
                    assertEquals("$identity offset=$offset size=$size", expected.drop(offset).take(size), ids(store.window(identity,null,size,offset)!!["items"] as List<*>))
                }
            }
            assertEquals("2", (store.bookItem(2) as Map<*, *>)["seriesIndex"])
            assertFalse(store.hasDetail(2))
            val before = requests.size
            assertEquals("finished", run(store, "incremental", { requests.add(it); reply(it) }))
            assertEquals("unchanged series makes no requests", 0, requests.drop(before).count { "seriesId=" in it || "series=" in it })
            assertEquals(listOf(1L,3L,4L,5L,6L,7L,8L,2L),ids(store.window("$base/books?series=Shared%20name&sort=series&order=asc",1,100,null)!!["items"] as List<*>))
            assertEquals(8L, store.db().query("SELECT count(*) FROM bulk_books") { it.long(0) }.single())
        }
        root.deleteRecursively()
    }
    @Test fun generationRollKeepsLazyAuthorMetadataAndCheckedDiscover() {
        val root=Files.createTempDirectory("bulk-heads").toFile()
        CacheStore(root,{},::JdbcSql).use {store->
            fun withPick(id:Long):(String)->Map<*,*> = {request ->
                val body=reply(request)
                if(MirrorLogic.splitPath(request).first.endsWith("/dashboard")) body+mapOf("discover" to listOf(mapOf("id" to id))) else body
            }
            assertEquals("finished",run(store,request=withPick(1)))
            val identity=MirrorLogic.listWindow("$base/books?author=Author%20B&sort=title")!!.identity
            BulkCatalog.saveObservedWindow(store,identity,mapOf("authorSummary" to mapOf("name" to "Author B","biography" to "Saved bio"),"items" to emptyList<Any>()),1000)
            assertEquals("finished",run(store,"incremental",withPick(2)))
            assertEquals("Saved bio",(store.window(identity,1,100,null)!!["authorSummary"] as Map<*,*>)["biography"])
            val request="$base/dashboard"
            val key=MirrorLogic.key(plan().owner,plan().owner.substringAfter('|'),request)
            fun pick()=(((store.read(key,request,null)!!.body as Map<*,*>)["discover"] as List<*>).first() as Map<*,*>)["id"]
            assertEquals(1L,pick())
            assertEquals("finished",run(store,request=withPick(3)))
            assertEquals(3L,pick())
            assertEquals("Saved bio",(store.window(identity,1,100,null)!!["authorSummary"] as Map<*,*>)["biography"])
        }
        root.deleteRecursively()
    }

    @Test fun bulkWorkerCountsCoversAndKeepsProtectedDataAtTheSharedLimit() {
        for(protected in listOf(false,true)) {
            val root=Files.createTempDirectory("bulk-budget").toFile()
            val covers=File(root,"covers").apply {mkdirs()}
            val cover=File(covers,"999_1.jpg").apply {writeBytes(ByteArray(2_000_000))}
            var requests=0
            val worker=CacheWorker(root,{url,_,sink,_->
                assertNull(sink);requests++
                CacheWorker.Reply(200,JSONObject(reply(url.substringAfter("/api/v1"))).toString().toByteArray())
            },log={},openSql=::JdbcSql)
            try {
                val m=plan().m+mapOf("limit" to 1_000_000L,"cover_dir" to covers.path,"seed_details" to if(protected)listOf(999L) else emptyList<Long>())
                val result=worker.run(CacheWorker.Plan(m),CacheWorker.Creds("https://books.example/api/v1","reader","key"))
                if(protected) {
                    assertEquals("storage limit",result);assertEquals(0,requests);assertTrue(cover.isFile)
                    assertNull(worker.store.meta("bulk_active"))
                } else {
                    assertEquals("finished",result);assertFalse(cover.exists())
                    assertTrue(worker.storageItems(covers.path,false).sumOf {it.bytes}<=1_000_000L)
                }
            } finally {worker.store.close();root.deleteRecursively()}
        }
    }

    @Test fun contextualSeriesTiesUseTheServerTitleRank() {
        val root=Files.createTempDirectory("bulk-title-ties").toFile()
        CacheStore(root,{},::JdbcSql).use {store->
            assertEquals("finished",run(store,request={request->
                val body=reply(request)
                val items=(body["items"] as? List<*>)?.map { value->
                    val row=value as Map<*,*>
                    if(row["id"]==3L)row+mapOf("seriesIndex" to "1") else row
                }
                val q=MirrorLogic.parseQuery(MirrorLogic.splitPath(request).second)
                val order=listOf(3L,1L,2L,4L,5L,6L,7L,8L)
                if(items==null)body else body+mapOf("items" to if(q["sort"]=="title"&&q["order"]=="asc")items.sortedBy {order.indexOf(it["id"])} else items)
            }))
            // Server collation ranks Book 03 before Book 01. Equal series indexes
            // must use that rank rather than SQLite's text comparison.
            assertEquals(listOf(3L,1L,2L,4L),ids(store.window("$base/books?seriesId=101&sort=series&order=asc",1,100,null)!!["items"] as List<*>))
        }
        root.deleteRecursively()
    }

    private fun expectedOrder(q: Map<String,String>, candidates: Set<Long>): List<Long> {
        val sort=q["sort"] ?: "recently_added"
        val dir=q["order"] ?: if(sort.startsWith("recently_")) "desc" else "asc"
        val rank=ranks["$sort:$dir"] as? List<*>
        if(rank!=null)return rank.filterIsInstance<Long>().filter {it in candidates}
        fun cmp(a:Any?,b:Any?,descending:Boolean=true):Int {
            if(a==null || b==null)return if(a==b)0 else if(a==null)1 else -1
            val c=if(a is Number && b is Number)a.toLong().compareTo(b.toLong()) else a.toString().compareTo(b.toString())
            return if(descending && dir=="desc")-c else c
        }
        fun book(id:Long):Map<*,*> {
            val row=rows.single {it["id"]==id}
            val sid=q["seriesId"]
            val key=if(sid!=null)"seriesId:$sid:$id" else if(q["series"]!=null)"seriesId:202:$id" else ""
            val c=(fixture["secondary_context"] as Map<*,*>)[key] as? Map<*,*>
            return if(c!=null && q["smartScopeId"]==null)row+c else row
        }
        return candidates.sortedWith {a,b->
            val x=book(a);val y=book(b)
            var result=0
            when(sort) {
                "title"->result=cmp(x["title"],y["title"])
                "series"->{
                    val scoped=q["smartScopeId"]==null && (q["seriesId"]!=null || q["series"]!=null)
                    if(!scoped)result=cmp(x["seriesName"],y["seriesName"])
                    val ix=BulkCatalog.indexParts(x["seriesIndex"]);val iy=BulkCatalog.indexParts(y["seriesIndex"])
                    for(i in ix.indices)if(result==0)result=cmp(ix[i],iy[i])
                    if(result==0 && scoped)result=cmp(x["title"],y["title"],false)
                }
                "recently_added","recently_updated"->result=cmp(x[if(sort=="recently_added")"addedAt" else "updatedAt"],y[if(sort=="recently_added")"addedAt" else "updatedAt"])
            }
            if(result==0)a.compareTo(b) else result
        }
    }

    @Test fun everyFiniteIdentityAndLaterWindowWorksOffline() {
        val root=Files.createTempDirectory("bulk-coverage").toFile()
        CacheStore(root,{},::JdbcSql).use {store->
            assertEquals("finished",run(store))
            val planner=CatalogPlan(plan())
            val selectors=listOf("", "libraryId=1", "collectionId=7", "smartScopeId=9", "author=Author%20B", "seriesId=202", "series=Shared%20name", "ids=2,6,8")
            var checked=0
            for(selector in selectors) for(identity in planner.bookPaths("$base/books?$selector",listOf("1"),"2,6,8")) {
                val q=MirrorLogic.parseQuery(MirrorLogic.splitPath(identity).second)
                val all=store.window(identity,1,100,null)
                assertNotNull(identity,all)
                val got=ids(all!!["items"] as List<*>)
                val expectedSet=rows.filter {row->
                    val id=row["id"] as Long
                    if(q["smartScopeId"]!=null) id in (memberships["smartScopeId:${q["smartScopeId"]}"] as List<*>)
                    else {
                        listOf("libraryId","collectionId","seriesId").all {key->q[key]==null || id in (memberships["$key:${q[key]}"] as List<*>)} &&
                        (q["author"]==null || q["author"] in (row["authors"] as List<*>)) &&
                        (q["readStatus"]==null || BulkCatalog.status(row["readStatus"])==q["readStatus"]) &&
                        (q["format"]==null || q["format"] in (row["formats"] as List<*>)) &&
                        (q["ids"]==null || id in q["ids"]!!.split(',').map(String::toLong))
                    }
                }.map {it["id"] as Long}.toSet()
                assertEquals(identity,expectedSet,got.toSet())
                assertEquals("order $identity",expectedOrder(q,expectedSet),got)
                assertEquals("no duplicated memberships $identity",got.size,got.toSet().size)
                val later=store.window(identity,null,3,2)!!
                assertEquals("later window $identity",got.drop(2).take(3),ids(later["items"] as List<*>))
                if(q["buckets"]=="1" && q["sort"] in setOf("title","author")) {
                    val buckets=all["buckets"] as List<*>
                    assertEquals(identity,got.size.toLong(),buckets.sumOf {((it as Map<*,*>)["count"] as Long)})
                }
                checked++
            }
            assertTrue("coverage enumerated $checked identities",checked>10000)
            for(identity in planner.sectionPaths()) assertNotNull(identity,store.window(identity,1,3,null))
            println("BULK offline coverage: $checked identities plus index variants, no transport attached")
        }
        root.deleteRecursively()
    }

    @Test fun interruptedStagingKeepsPublishedGenerationAndResumesWithoutDetails() {
        val root = Files.createTempDirectory("bulk-resume").toFile()
        CacheStore(root, {}, ::JdbcSql).use { store ->
            assertEquals("finished", run(store))
            val published = store.meta("bulk_active")
            assertEquals("incomplete coverage", run(store, request = { if (it.contains("recently_added")) throw CatalogFailure() else reply(it) }))
            assertEquals(published, store.meta("bulk_active"))
            assertNotNull(store.window("$base/books?sort=title",1,100,null))
            val resumed = ArrayList<String>()
            assertEquals("finished",run(store,"resume",{ resumed.add(it); reply(it) }))
            assertTrue(resumed.none { "/manifest" in it || "/sections/authors" in it })
        }
        root.deleteRecursively()
    }
    @Test fun metadataAndStatusChangesStayLazyAndOnlyAffectedSecondarySeriesAreReconciled() {
        val root=Files.createTempDirectory("bulk-changes").toFile()
        CacheStore(root,{},::JdbcSql).use {store->
            assertEquals("finished",run(store))
            store.putDetail(2,mapOf("id" to 2L,"description" to "Previously opened"),1000)
            val asked=ArrayList<String>()
            assertEquals("finished",run(store,"incremental",{path->
                asked.add(path)
                val body=reply(path).toMutableMap()
                val items=body["items"] as? List<*>
                if(items!=null && !path.contains("/sections/")) body["items"]=items.map {value->
                    val b=value as Map<*,*>
                    if(b["id"]==2L) b.entries.associate {it.key to it.value}+mapOf("title" to "Changed title","readStatus" to "reading","updatedAt" to "2026-02-01") else b
                }
                body
            }))
            assertNull("changed metadata invalidates details without fetching",store.detail(2))
            assertEquals("Changed title",(store.bookItem(2) as Map<*,*>)["title"])
            assertEquals(1,asked.count {"seriesId=" in it})
            assertTrue(asked.filter {"seriesId=" in it}.all {"seriesId=202" in it})
            assertTrue(store.patch(2,mapOf("readStatus" to "read"),false)>0)
            assertEquals("read",(store.bookItem(2) as Map<*,*>)["readStatus"])
            val cached=store.read("","$base/books/2","$base/books/${MirrorLogic.SENTINEL}")!!
            assertEquals("Changed title",(cached.body as Map<*,*>)["title"])
            assertTrue(cached.stale)
        }
        root.deleteRecursively()
    }
    @Test fun serverRestartDiscardsOnlyStagedEnumeration() {
        val root=Files.createTempDirectory("bulk-restart").toFile()
        CacheStore(root,{},::JdbcSql).use {store->
            assertEquals("finished",run(store))
            val old=store.meta("bulk_active")
            var first=true
            assertEquals("finished",run(store,request={path->
                if(first && "/manifest" in path) {first=false;assertEquals(old,store.meta("bulk_active"));mapOf("restartRequired" to true)} else reply(path)
            }))
            assertEquals(8L,store.db().query("SELECT count(*) FROM books"){it.long(0)}.single())
        }
        root.deleteRecursively()
    }

    @Test fun repeatedCursorCannotPublishOrDeleteBooks() {
        val root = Files.createTempDirectory("bulk-cursor").toFile()
        CacheStore(root, {}, ::JdbcSql).use { store ->
            assertEquals("finished",run(store))
            val published = store.meta("bulk_active")
            assertEquals("incomplete coverage",run(store,request={ if (it.contains("/manifest")) mapOf("items" to books,"hasNext" to true,"nextCursor" to "same") else reply(it) }))
            assertEquals(published,store.meta("bulk_active"))
        }
        root.deleteRecursively()
    }
}
