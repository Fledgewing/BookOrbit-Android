package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class LibraryTest {
    private val owner = "fixture|https://library.invalid"
    private val book = mapOf<String, Any?>("key" to "b", "title" to "The Moon", "authors" to listOf("A", "B"), "series" to listOf("Orbit"),
        "tags" to listOf("Space"), "status" to "reading", "want_to_read" to true, "on_device" to true,
        "pages" to 200, "rating" to 4, "added" to "2026-11-01", "rank" to 0, "last_read" to "2026-11-03")

    @Test fun everyNeutralFieldHasLocalSemanticsAndAnExplicitTranslationPlan() {
        val cases = mapOf<String, Any>("show" to "reading", "wtr" to true, "where" to "on-device", "author" to listOf("B"), "series" to listOf("Orbit"), "tags" to listOf("space"),
            "length" to mapOf("min" to 100, "max" to 200), "len" to mapOf("max" to 200), "rating" to mapOf("min" to 4), "added" to mapOf("min" to "2026-01-01"),
            "group" to "author", "sort" to "title", "dir" to "desc", "q" to "moon A")
        for ((field, value) in cases) {
            val filter = mapOf(field to value)
            LibraryFilter.validate(filter)
            assertTrue(field, LibraryFilter.matches(book, filter))
            val (translated, local) = BookOrbitLibrary.translate(filter)
            assertTrue("$field must be translated or residual", field in local || translated.isNotEmpty())
        }
        for (f in listOf(mapOf("show" to "finished"), mapOf("where" to "server-only"), mapOf("author" to listOf("C")), mapOf("series" to listOf("Else")), mapOf("tags" to listOf("No")),
            mapOf("length" to mapOf("min" to 201)), mapOf("rating" to mapOf("max" to 3)), mapOf("added" to mapOf("max" to "2025-01-01")), mapOf("q" to "absent"))) assertFalse(f.toString(), LibraryFilter.matches(book, f))
        assertFalse(LibraryFilter.matches(book + ("on_device" to null), mapOf("where" to "server-only")))
        assertFalse(LibraryFilter.matches(book + ("pages" to null), mapOf("length" to mapOf("min" to 1))))
        assertFalse(LibraryFilter.matches(book + ("want_to_read" to false), mapOf("wtr" to true)))
        assertEquals(mapOf("author" to "A"), BookOrbitLibrary.translate(mapOf("author" to listOf("A"))).first)
        assertEquals(mapOf("series" to "Orbit"), BookOrbitLibrary.translate(mapOf("series" to listOf("Orbit"))).first)
        assertEquals("finished", BookOrbitLibrary.translate(mapOf("show" to "finished")).first["readStatus"])
        for ((neutral, backend) in mapOf("title" to "title", "author" to "author", "last" to "recently_read", "added" to "recently_added", "series" to "series")) {
            assertEquals(mapOf("sort" to backend, "order" to "desc"), BookOrbitLibrary.translate(mapOf("sort" to neutral, "dir" to "desc")).first)
        }
        for (field in listOf("where", "tags", "length", "rating", "added", "group", "q", "wtr")) assertTrue(BookOrbitLibrary.translate(mapOf(field to cases[field])).second.contains(field))
    }
    @Test fun groupsSortsTiesNullsAndSourceOrderAreDeterministic() {
        assertEquals("A", LibraryFilter.group(book, mapOf("group" to "author")))
        assertEquals("Orbit", LibraryFilter.group(book, mapOf("group" to "series")))
        assertEquals("", LibraryFilter.group(book, mapOf("group" to "none")))
        assertEquals("No series", LibraryFilter.group(emptyMap(), mapOf("group" to "series")))
        for ((sort, field) in mapOf("title" to "title", "author" to "authors", "last" to "last_read", "added" to "added", "rating" to "rating", "order" to "rank", "match" to "match", "series" to "series_position")) {
            val small: Any = if (field in setOf("rating", "rank", "match")) 1 else if (field == "authors") listOf("A") else "2"
            val large: Any = if (field in setOf("rating", "rank", "match")) 9 else if (field == "authors") listOf("Z") else if (field == "series_position") "10" else "9"
            val x=book + (field to small); val y=book + (field to large)
            assertTrue(sort, LibraryFilter.comparator(mapOf("sort" to sort)).compare(x,y)<0)
            assertTrue(sort, LibraryFilter.comparator(mapOf("sort" to sort,"dir" to "desc")).compare(x,y)>0)
            assertTrue(sort, LibraryFilter.comparator(mapOf("sort" to sort,"dir" to "desc")).compare(x, book + (field to null))<0)
        }
        assertTrue(LibraryFilter.comparator(emptyMap<Any,Any>()).compare(book + ("key" to "a"),book)<0)
        assertTrue(LibraryFilter.comparator(mapOf("group" to "author", "sort" to "rating", "dir" to "desc")).compare(book, book + ("authors" to listOf("Z")))<0)
    }
    @Test fun backendObjectsCannotEscapeAsNeutralDisplayFields() {
        val backend=mapOf("downloadUrl" to "/private")
        val row=BookOrbitLibrary.summary(owner,mapOf("id" to 1,"tags" to listOf(backend,"Space"),"formats" to listOf(backend,"epub"),"rating" to backend,"progressPercentage" to backend),0,null)
        assertEquals(listOf("Space"),row["tags"]); assertEquals(listOf("epub"),row["formats"])
        assertNull(row["rating"]); assertNull(row["progress"])
        assertFalse(row.toString().contains("downloadUrl"))
        val unknown=BookOrbitLibrary.summary(owner,mapOf("id" to 1,"readStatus" to "future-state"),0,null)
        assertEquals("unknown",unknown["status"]); assertEquals("future-state",unknown["status_raw"])
    }
    @Test fun modelByteStringsPreserveUnicodeSearchAndCaseFolding() {
        val b=book + ("title" to LuaValue.str("Étoiles")) + ("authors" to listOf(LuaValue.str("Zoë")))
        assertTrue(LibraryFilter.matches(b,mapOf("q" to LuaValue.str("étoiles ZOË"))))
        assertTrue(LibraryFilter.matches(b,mapOf("author" to listOf(LuaValue.str("ZOË")))))
    }
    @Test fun recordedCatalogSectionsUseTheAdaptersActualSeriesIdentity() {
        val fx=org.json.JSONObject(File("../../../shared/fixtures/catalog/bulk-refresh/catalog.json").readText())
        store().use { st ->
            seed(st)
            val section=fx.getJSONObject("sections").getJSONArray("series").getJSONObject(0)
            st.db().exec("INSERT INTO bulk_sections(g,section,pos,id) VALUES(1,'series',0,?)",section.getString("id"))
            st.db().exec("INSERT INTO bulk_members(g,kind,value,id) VALUES(1,'seriesId',?,1)",section.getLong("seriesId").toString())
            val source=mapOf("kind" to "series","key" to BookOrbitLibrary.key(owner,"series",section.getLong("seriesId")))
            assertEquals(1L,read(st,mapOf("op" to "counts","source" to source))["total"])
            val author=mapOf("kind" to "author","key" to "A")
            assertEquals(5L,read(st,mapOf("op" to "counts","source" to author))["total"])
            assertEquals(0L,read(st,mapOf("op" to "counts","source" to author,"query" to mapOf("author" to listOf("Other"))))["total"])
        }
    }
    private fun store() = CacheStore(Files.createTempDirectory("library-test").toFile(), {}) { JdbcSql(it) }.also { it.own(owner) }
    private fun seed(st: CacheStore) {
        st.setMeta("bulk_active", 1); st.setMeta("bulk_at", 1234); st.setMeta("bulk_complete", 1)
        for (i in 1L..5L) {
            val raw=mapOf("id" to i, "title" to "Book $i", "authors" to listOf("A"), "readStatus" to when(i) { 1L -> "reading"; 2L -> "read"; 3L -> "want_to_read"; else -> "unread" }, "addedAt" to "2026-11-0$i")
            st.db().exec("INSERT INTO bulk_books(g,id,item) VALUES(1,?,?)",i,LuaValue.encode(raw))
        }
    }
    private fun read(st: CacheStore, args: Map<String,Any?>): Map<*,*> {
        val request=String(LuaValue.encode(args),Charsets.ISO_8859_1)
        LibraryReadModel(st, {99}, {}).publish(owner,listOf(request))
        return st.db().query("SELECT body FROM library_views WHERE owner=? AND request=?", owner,request) { LuaValue.parse(it.bytes(0)!!) as Map<*,*> }.single()
    }
    @Test fun modeEstimatesAreSmallHonestWorkerSnapshots() {
        store().use { st ->
            val result = read(st, mapOf("op" to "mode-estimates", "limit" to 3))
            val items = result["items"] as List<*>
            assertEquals(listOf("saver", "balanced", "current"), items.map { (it as Map<*, *>)["id"] })
            for (item in items) {
                assertEquals(false, (item as Map<*, *>)["measured"])
                assertEquals("Estimate available after measured use", item["text"])
            }
            assertTrue(LuaValue.encode(result).size < 1024)
            assertEquals(1, (read(st, mapOf("op" to "mode-estimates", "limit" to 1))["items"] as List<*>).size)
        }
    }

    @Test fun readingStatsUsesExistingBoundedOwnerScopedProjection() {
        store().use { st ->
            val request=String(LuaValue.encode(mapOf("op" to "reading.stats", "limit" to 1, "bytes" to 16384)),Charsets.ISO_8859_1)
            var calls=0
            val model=LibraryReadModel(st,{99},{},readingStats={ calls++; mapOf("state" to "empty", "hours" to List(24) { 0 }) })
            model.publish("wrong-owner",listOf(request)); assertEquals(0,calls)
            model.publish(owner,listOf(request)); assertEquals(1,calls)
            val result=st.db().query("SELECT body FROM library_views WHERE owner=? AND request=?",owner,request) { it.bytes(0)!! }.single()
            assertTrue(result.size<=16384)
            assertEquals("empty",(LuaValue.parse(result) as Map<*,*>)["state"])
        }
    }
    @Test fun projectionsDistinguishMissingFromEmptyAndFilterBeforePaging() {
        store().use { st ->
            assertEquals("Not saved yet",read(st,mapOf("op" to "window","source" to "reading"))["empty"])
            seed(st)
            val r=read(st,mapOf("op" to "window","source" to "library/all","query" to mapOf("show" to "unread","sort" to "title","dir" to "desc"),"offset" to 1,"limit" to 1))
            assertEquals(3L,r["total"]); assertEquals(1,(r["items"] as List<*>).size)
            assertEquals("Book 4",((r["items"] as List<*>).single() as Map<*,*>)["title"])
            assertEquals("No books",read(st,mapOf("op" to "window","source" to "reading","query" to mapOf("show" to "finished")))["empty"])
            assertEquals(1L,read(st,mapOf("op" to "counts","source" to "want-to-read"))["total"])
            assertEquals(1L,read(st,mapOf("op" to "counts","source" to "finished"))["total"])
            assertEquals("Book 5",((read(st,mapOf("op" to "window","source" to "recently-added","limit" to 1))["items"] as List<*>).single() as Map<*,*>)["title"])
            assertEquals("Book 3",((read(st,mapOf("op" to "window","source" to "search","query" to mapOf("q" to "Book 3")))["items"] as List<*>).single() as Map<*,*>)["title"])
        }
    }
    @Test fun localLedgerIsOwnerScopedAndCheckedOnTheWorker() {
        store().use { st ->
            seed(st)
            assertEquals("Not saved yet",read(st,mapOf("op" to "window","source" to "on-device"))["empty"])
            val file=File(st.root,"one.epub").apply { writeText("fixture") }
            val ask=File(st.root,"copies/ask.lua").apply { parentFile!!.mkdirs() }
            fun ledger(o: String) = ask.writeBytes(LuaValue.encode(mapOf("owner" to o,"books" to listOf(mapOf("book_id" to 1,"path" to file.path)))))
            ledger(owner)
            assertEquals(1L,read(st,mapOf("op" to "counts","source" to "on-device"))["total"])
            assertEquals(4L,read(st,mapOf("op" to "counts","source" to "all","query" to mapOf("where" to "server-only")))["total"])
            file.delete(); assertEquals("No books",read(st,mapOf("op" to "window","source" to "on-device"))["empty"])
            ledger("other"); assertEquals("Not saved yet",read(st,mapOf("op" to "window","source" to "on-device"))["empty"])
        }
    }
    @Test fun identityCapabilitiesDetailsJobsAndAccountIsolation() {
        store().use { st ->
            seed(st)
            val caps=read(st,mapOf("op" to "capabilities")); assertEquals(false,(caps["lists"] as Map<*,*>)["save"])
            val key=BookOrbitLibrary.key(owner,"book",1)
            assertNull(BookOrbitLibrary.id(owner,"book","$key:2"))
            assertNull(BookOrbitLibrary.id(owner,"book",BookOrbitLibrary.key(owner,"file",1)))
            assertEquals("reading",read(st,mapOf("op" to "status","key" to key))["status"])
            assertEquals("missing",read(st,mapOf("op" to "book","key" to BookOrbitLibrary.key("other","book",1)))["error"])
            st.putDetail(1,mapOf("id" to 1,"description" to "<p>Plain text</p>","files" to listOf(mapOf("id" to 4,"format" to "epub","downloadUrl" to "/private"))),100)
            val detail=(read(st,mapOf("op" to "book","key" to key))["items"] as List<*>).single() as Map<*,*>
            assertEquals("Plain text",detail["description"]); assertFalse(detail.toString().contains("downloadUrl"))
            assertEquals(0L,read(st,mapOf("op" to "job","key" to BookOrbitLibrary.key(owner,"job","refresh")))["pending"])
            st.own("other"); assertEquals(0L,st.db().query("SELECT count(*) FROM library_views") { it.long(0) }.single())
            LibraryReadModel(st,{99},{}).publish(owner,listOf("{op=\"capabilities\"}"))
            assertEquals(0L,st.db().query("SELECT count(*) FROM library_views") { it.long(0) }.single())
        }
    }
    @Test fun incompleteMembershipIsNotAnEmptySourceAndRankIsPreserved() {
        store().use { st ->
            seed(st)
            st.setMeta("bulk_complete",null)
            val source=mapOf("kind" to "list","key" to BookOrbitLibrary.key(owner,"list",7))
            assertEquals("Not saved yet",read(st,mapOf("op" to "window","source" to source))["empty"])
            st.setMeta("bulk_complete",1)
            st.db().exec("INSERT INTO bulk_sections(g,section,pos,id) VALUES(1,'smart-scopes',0,'7')")
            for ((id,rank) in listOf(3L to 0,1L to 1)) st.db().exec("INSERT INTO bulk_members(g,kind,value,id,context) VALUES(1,'smartScopeId','7',?,?)",id,LuaValue.encode(mapOf("_booksyncRank" to rank)))
            val items=read(st,mapOf("op" to "window","source" to source))["items"] as List<*>
            assertEquals(listOf("Book 3","Book 1"),items.map { (it as Map<*,*>)["title"] })
            st.db().exec("INSERT INTO bulk_sections(g,section,pos,id) VALUES(1,'series',0,'series:9')")
            st.db().exec("INSERT INTO bulk_members(g,kind,value,id,context) VALUES(1,'seriesId','9',1,?)",LuaValue.encode(mapOf("seriesName" to "Secondary","seriesIndex" to "2")))
            val series=mapOf("kind" to "series","key" to BookOrbitLibrary.key(owner,"series",9))
            assertEquals(listOf("Secondary"),((read(st,mapOf("op" to "window","source" to series))["items"] as List<*>).single() as Map<*,*>)["series"])
        }
    }
    @Test fun materializationEnforcesRowAndByteLimitsAndRejectsMalformedFilters() {
        store().use { st ->
            seed(st)
            assertEquals(1,(read(st,mapOf("op" to "window","source" to "all","limit" to 1))["items"] as List<*>).size)
            assertEquals("budget",read(st,mapOf("op" to "window","source" to "all","bytes" to 256))["error"])
            for (filter in listOf(mapOf("extra" to 1),mapOf("where" to "wrong"),mapOf("length" to mapOf("min" to 10,"max" to 1)))) assertEquals("unsupported",read(st,mapOf("op" to "window","source" to "all","query" to filter))["error"])
            val sizes=st.db().query("SELECT length(body) FROM library_views") { it.long(0)!! }
            assertTrue(sizes.all { it<=16384 })
        }
    }
}
