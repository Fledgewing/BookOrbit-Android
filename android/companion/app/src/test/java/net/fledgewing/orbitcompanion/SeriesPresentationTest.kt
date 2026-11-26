package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test

class SeriesPresentationTest {
    private fun book(n: Int, state: String = "unread", local: Boolean? = false) = mapOf<String, Any?>(
        "key" to "book-$n", "title" to "Book $n", "authors" to listOf("Author"), "series" to listOf("Orbit"),
        "series_key" to "opaque-series", "series_position" to n, "status" to state, "progress" to 45,
        "rating" to 4, "on_device" to local)
    @Test fun modelByteStringsPreserveUnicodeAuthorsAndRangeLabels() {
        val result=SeriesPresentation.series(listOf(book(1)+("authors" to listOf(LuaValue.str("Étoile"),LuaValue.str("星")))),"Orbit",0,8)
        assertEquals("Étoile · 星 · 1 book · 0 read, 0 reading",LuaValue.utf8(result["subtitle"].toString()))
        val unknown=SeriesPresentation.series(listOf(book(1,local=null)),"Orbit",0,8)
        assertTrue((unknown["next_books"] as List<*>).isEmpty())
    }
    @Test fun statesAndStatusOnlyRowsDoNotConfuseProgressWithReadingOrInventLocalCoverage() {
        assertEquals("Read · ★★★★", LuaValue.utf8(SeriesPresentation.row(book(1, "finished"))["status_text"].toString()))
        assertEquals("45% · reading", LuaValue.utf8(SeriesPresentation.row(book(2, "reading"))["status_text"].toString()))
        assertEquals("45% · reading", LuaValue.utf8(SeriesPresentation.row(book(2, "rereading"))["status_text"].toString()))
        assertEquals("On device", SeriesPresentation.row(book(3, local = true))["status_text"])
        assertEquals("On server", SeriesPresentation.row(book(4))["status_text"])
        assertEquals("Device state not saved", SeriesPresentation.row(book(5, local = null))["status_text"])
        assertEquals("unread", SeriesPresentation.state(book(6)))
    }
    @Test fun seriesCountsOrdersNextTitlesAndEveryPreviewIsCharged() {
        val books = listOf(book(5), book(2,"reading"), book(4,local=true), book(1,"finished"), book(3), book(6), book(7))
        val result = SeriesPresentation.series(books,"Orbit",0,8)
        assertEquals(listOf("book-1","book-2","book-3","book-4"),(result["items"] as List<*>).map { (it as Map<*,*>)["key"] })
        assertEquals(listOf("book-3","book-5","book-6"),(result["next_books"] as List<*>).map { (it as Map<*,*>)["key"] })
        assertEquals(8,result["row_count"])
        assertEquals("Author · 7 books · 1 read, 1 reading",LuaValue.utf8(result["subtitle"].toString()))
        assertEquals(listOf("read","reading","unread","unread","unread","unread","unread"),result["dots"])
        assertEquals(4,result["next"])
        val page=SeriesPresentation.series(books,"Orbit",4,8)
        assertEquals(3,(page["items"] as List<*>).size); assertNull(page["next"])
    }
    @Test fun savedEmptyUnknownAndLongSeriesNeverClaimUnknownBooksAreOnDevice() {
        assertEquals(true,SeriesPresentation.series(listOf(book(1,local=true)),"Orbit",0,8)["remaining_saved"])
        val unknown=SeriesPresentation.series(listOf(book(1,local=null)),"Orbit",0,8)
        assertEquals(false,unknown["remaining_saved"]); assertEquals(false,unknown["local_known"])
        assertEquals(0,SeriesPresentation.series(emptyList(),"Empty",0,8)["total"])
        val huge=SeriesPresentation.series((1..500).map { book(it) },"Orbit",0,8)
        assertEquals(24,(huge["dots"] as List<*>).size); assertEquals("Books 1–24 of 500",LuaValue.utf8(huge["dot_caption"].toString()))
        assertTrue(LuaValue.encode(huge).size<=16384)
    }
    @Test fun groupsKeepNamesIdentityReadingOrderCountsAndBoundedPreviews() {
        val books=(1..5).map { book(it) } + book(7).plus("series_key" to "same-title-different-series") +
            book(8).plus(mapOf("series_key" to null,"series" to emptyList<String>()))
        val groups=SeriesPresentation.groups(books,mapOf("group" to "series","sort" to "title","dir" to "desc"),0,8)
        val rows=groups["items"] as List<*>
        assertEquals(2,rows.size); assertTrue((groups["row_count"] as Int)<=8)
        val orbit=rows.map { it as Map<*,*> }.first { it["series_key"]=="opaque-series" }
        assertEquals("All 5",orbit["count_text"]); assertEquals(true,orbit["partial"])
        assertEquals(listOf(1,2,3),(orbit["books"] as List<*>).map { (it as Map<*,*>)["number"] })
        assertEquals(2,groups["next"])
        val last=SeriesPresentation.groups(books,mapOf("group" to "series"),2,8)
        assertEquals(1,(last["items"] as List<*>).size); assertNull(last["next"])
        val missing=(last["items"] as List<*>).single() as Map<*,*>
        assertEquals("Not in a series",missing["title"]); assertEquals("1 book",missing["count_text"])
    }
    @Test fun authorGroupsHonorSearchFilteringAndMissingSeriesDrilldownIsNeutral() {
        val books=(1..9).map { book(it) }.filter { LibraryFilter.matches(it,mapOf("q" to "Book 1")) }
        val result=SeriesPresentation.groups(books,mapOf("group" to "author"),0,8)
        assertEquals(1,result["total"])
        val row=(result["items"] as List<*>).single() as Map<*,*>
        assertEquals("1 book",row["count_text"]); assertEquals(false,row["partial"])
        assertTrue((row["dots"] as List<*>).isEmpty())
        assertTrue(LibraryFilter.matches(book(1)+("series" to emptyList<String>()),mapOf("without_series" to true)))
        assertFalse(LibraryFilter.matches(book(1),mapOf("without_series" to true)))
    }
}
