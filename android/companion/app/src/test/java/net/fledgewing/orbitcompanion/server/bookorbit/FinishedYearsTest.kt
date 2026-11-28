// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit
import net.fledgewing.orbitcompanion.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
class FinishedYearsTest {
    private val path="/koreader/plugin/catalog/dashboard"
    private val owner="fixture-owner"
    private fun dashboard(year:Int,total:Any?=100L,n:Int=12)=mapOf("readingGoal" to mapOf("year" to year,"completedBooks" to total),"finishedThisYear" to (1..n).map { mapOf("id" to it.toLong(),"title" to LuaValue.str("Book 二 $it"),"authors" to listOf("Fixture"),"finishedOn" to "$year-06-01") })
    private fun <T> fixture(block:(CacheStore)->T):T {
        val root=Files.createTempDirectory("finished-year").toFile()
        try { return CacheStore(root,log={},open={JdbcSql(it)}).use { it.own(owner);block(it) } }
        finally { root.deleteRecursively() }
    }
    @Test fun rolloverRetainsPastSelectionAndNeverTreatsTwelveBooksAsAccountTotal()=fixture { st ->
        st.putEntry("dashboard",path,dashboard(2025),100)
        st.putEntry("dashboard",path,dashboard(2026,4L,4),200)
        val result=FinishedYears.window(st,owner,2025,mapOf("limit" to 5))
        assertEquals(12,result["total"]);assertEquals(5,(result["items"] as List<*>).size)
        val context=result["context"] as Map<*,*>;assertEquals(100L,context["finished_total"])
        assertEquals("Saved selection · 12 books",LuaValue.utf8(context["coverage"].toString()))
        assertEquals("Book 二 1",LuaValue.utf8(((result["items"] as List<*>)[0] as Map<*,*>)["title"].toString()))
        assertEquals(listOf("year:2026","year:2025"),FinishedYears.options(st,owner,1780000000).map { it["src"] })
    }
    @Test fun oldCachedEntrySeedsAdditivelyAndUnknownNewYearStaysPending()=fixture { st ->
        st.db().exec("INSERT INTO entries(key,path,body,fetched_at,bytes) VALUES(?,?,?,?,?)","old",path,LuaValue.encode(dashboard(2025)),10,100)
        val version=st.db().pragma("user_version")
        assertEquals(12,FinishedYears.window(st,owner,2025,emptyMap<Any,Any>())["total"])
        val pending=FinishedYears.window(st,owner,2026,emptyMap<Any,Any>())
        assertEquals(false,(pending["freshness"] as Map<*,*>)["saved"])
        assertNull((pending["context"] as Map<*,*>)["finished_total"])
        assertEquals(version,st.db().pragma("user_version"));assertNotNull(st.meta("owner"))
    }
    @Test fun missingCountsAndDatesStayUnknownAndOwnerChangeClearsArchive()=fixture { st ->
        st.putEntry("dashboard",path,mapOf("readingGoal" to mapOf("year" to 2026),"finishedThisYear" to listOf(mapOf("id" to 1L,"title" to "Unknown date"))),100)
        val result=FinishedYears.window(st,owner,2026,emptyMap<Any,Any>())
        assertNull((result["context"] as Map<*,*>)["finished_total"])
        assertEquals("Finish date unknown",((result["items"] as List<*>).single() as Map<*,*>)["status_note"])
        st.own("other-fixture-owner")
        assertEquals(0L,st.db().query("SELECT count(*) FROM ${FinishedYears.TABLE}") { it.long(0)!! }.single())
        assertEquals(false,(FinishedYears.window(st,owner,2026,emptyMap<Any,Any>())["freshness"] as Map<*,*>)["saved"])
    }
    @Test fun filtersAndPagingApplyToSavedSelectionAndKnownEmptyIsDistinct()=fixture { st ->
        st.putEntry("dashboard",path,dashboard(2026,0L,0),100)
        assertEquals(true,(FinishedYears.window(st,owner,2026,emptyMap<Any,Any>())["freshness"] as Map<*,*>)["saved"])
        st.putEntry("dashboard",path,dashboard(2026),200)
        val result=FinishedYears.window(st,owner,2026,mapOf("query" to mapOf("q" to "12")))
        assertEquals(1,result["total"]);assertNull(result["next"])
        assertTrue(LuaValue.encode(result).size<16384)
        val projected=BookOrbitProjection(st).project(owner,mapOf("op" to "window","source" to mapOf("kind" to "finished-year","key" to "2026"),"limit" to 3))
        assertEquals(3,(projected["items"] as List<*>).size)
    }
    @Test fun pendingCompletionsAreSeparateFromAccountCountAndAcknowledgementSurvivesCappedShelf()=fixture { st ->
        val file=java.io.File(st.root,"workflows/${BookOrbitLibrary.namespace(owner)}.lua").apply { parentFile.mkdirs() }
        file.writeBytes(LuaValue.encode(mapOf("year_pending" to mapOf("20" to mapOf("book_id" to 20L,"date" to "2026-06-01","at" to 100L)))))
        st.putEntry("dashboard",path,dashboard(2026,100L),200)
        val before=FinishedYears.window(st,owner,2026,emptyMap<Any,Any>())
        assertEquals(13,before["total"]);assertEquals(100L,(before["context"] as Map<*,*>)["finished_total"])
        assertTrue((before["context"] as Map<*,*>)["coverage"].toString().contains("1 local pending"))
        st.putEntry("dashboard",path,mapOf("readingGoal" to mapOf("year" to 2026,"completedBooks" to 101L),"finishedThisYear" to listOf(mapOf("id" to 20L,"title" to "Acknowledged","finishedOn" to "2026-06-01"))),300)
        assertEquals(1,FinishedYears.window(st,owner,2026,emptyMap<Any,Any>())["total"])
        st.putEntry("dashboard",path,dashboard(2026,101L),400)
        val capped=FinishedYears.window(st,owner,2026,emptyMap<Any,Any>())
        assertEquals(12,capped["total"]);assertFalse((capped["context"] as Map<*,*>)["coverage"].toString().contains("pending"))
    }

    @Test fun boundedArchiveRetainsSeriesActionsWithoutOversizedMetadata()=fixture { st ->
        val books=(1..12).map { mapOf("id" to it.toLong(),"title" to LuaValue.str("二".repeat(1000)),"authors" to List(100) { "Fixture".repeat(100) },"seriesId" to 7L,"seriesName" to "Series".repeat(1000),"seriesIndex" to it,"readStatus" to "read","formats" to List(100) { "EPUB" }) }
        st.putEntry("dashboard",path,mapOf("readingGoal" to mapOf("year" to 2026,"completedBooks" to 100),"finishedThisYear" to books),100)
        val r=FinishedYears.window(st,owner,2026,mapOf("limit" to 12))
        assertEquals(12,(r["items"] as List<*>).size);assertTrue(LuaValue.encode(r).size<16384)
        assertEquals(BookOrbitLibrary.key(owner,"series",7),((r["items"] as List<*>).first() as Map<*,*>)["series_key"])
        val grouped=FinishedYears.window(st,owner,2026,mapOf("op" to "groups","query" to mapOf("group" to "series"),"limit" to 24))
        assertEquals(1,grouped["group_total"]);assertEquals(12,((grouped["items"] as List<*>).single() as Map<*,*>)["count"])
    }

}
