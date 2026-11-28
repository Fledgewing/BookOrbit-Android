// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit
import net.fledgewing.orbitcompanion.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
class UpNextSelectionTest {
    private val owner="fixture-owner"
    private val path="/koreader/plugin/catalog/dashboard/sections/up-next-in-series"
    private fun <T> fixture(block:(CacheStore)->T):T {
        val root=Files.createTempDirectory("upnext").toFile()
        try { return CacheStore(root,log={},open={JdbcSql(it)}).use { it.own(owner);block(it) } } finally { root.deleteRecursively() }
    }
    private fun seed(st:CacheStore,books:List<Any> = listOf(9L,2L,5L).map { mapOf("id" to it,"title" to "Book $it","readStatus" to "unread","seriesId" to 7L,"seriesName" to "Fixture") }) {
        st.putEntry("upnext",path,mapOf("section" to mapOf("type" to "up-next-in-series","books" to books)),100)
    }
    @Test fun cachedSelectionOrderSurvivesAbsentBulkCatalogAndPaging()=fixture { st ->
        seed(st)
        val first=BookOrbitProjection(st).project(owner,mapOf("op" to "window","source" to "series-next","limit" to 2))
        assertEquals(listOf("Book 9","Book 2"),(first["items"] as List<*>).map { (it as Map<*,*>)["title"] })
        assertEquals(3,first["total"]);assertEquals(2,first["next"])
        assertEquals("Saved selection · 3 books",LuaValue.utf8((first["context"] as Map<*,*>)["coverage"].toString()))
        assertTrue(LuaValue.encode(first).size<16384)
    }
    @Test fun filteredCountsAndFacetsUseOnlyTheSavedSelection()=fixture { st ->
        seed(st)
        val result=UpNextSelection.window(st,owner,mapOf("query" to mapOf("q" to "2")),100)
        assertEquals(1,result["total"])
        val sorted=UpNextSelection.window(st,owner,mapOf("query" to mapOf("sort" to "title")),100)
        assertEquals("Book 2",((sorted["items"] as List<*>).first() as Map<*,*>)["title"])
        val facets=UpNextSelection.window(st,owner,mapOf("op" to "facets","field" to "series"),100)
        val groups=UpNextSelection.window(st,owner,mapOf("op" to "groups","query" to mapOf("group" to "series"),"limit" to 24),100)
        assertEquals(1,groups["group_total"]);assertEquals(3,((groups["items"] as List<*>).single() as Map<*,*>)["count"])
        assertEquals(1,(facets["items"] as List<*>).size);assertEquals(3,((facets["items"] as List<*>).single() as Map<*,*>)["count"])
    }
    @Test fun missingMalformedAndKnownEmptySelectionsStayDistinctAndLocalDoesNotGuess()=fixture { st ->
        assertEquals(false,(UpNextSelection.window(st,owner,emptyMap<Any,Any>(),100)["freshness"] as Map<*,*>)["saved"])
        st.putEntry("upnext",path,mapOf("section" to mapOf("type" to "different","books" to emptyList<Any>())),100)
        assertEquals(false,(UpNextSelection.window(st,owner,emptyMap<Any,Any>(),100)["freshness"] as Map<*,*>)["saved"])
        seed(st,emptyList())
        val empty=UpNextSelection.window(st,owner,emptyMap<Any,Any>(),100)
        assertEquals(true,(empty["freshness"] as Map<*,*>)["saved"]);assertEquals(0,empty["total"])
        assertEquals(false,DeviceLibrary(emptyList()).capabilities(DeviceLibrary.OWNER)["retainedSeriesNext"])
        assertNotNull(DeviceLibrary(emptyList()).project(DeviceLibrary.OWNER,mapOf("op" to "window","source" to "series-next"))["error"])
    }
}
