// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion
import org.junit.Assert.*
import org.junit.Test
class SeriesDownloadPlanTest {
    private fun b(n:Int,status:String="unread",local:Boolean?=false)=mapOf<String,Any?>("key" to "b$n","title" to "Book $n","series_position" to n,"status" to status,"on_device" to local)
    @Test fun currentReaderWinsRecentReadingAndLastFinishedWithoutWrapping() {
        val books=listOf(b(1),b(2,"reading")+mapOf("last_read" to 100L),b(3),b(4,"reading")+mapOf("last_read" to 200L),b(5),b(6,"finished"))
        assertEquals(listOf("b5"),SeriesDownloadPlan.select(books).books.map { it["key"] })
        assertEquals(listOf("b3","b5"),SeriesDownloadPlan.select(books,currentKey="b2").books.map { it["key"] })
        assertTrue(SeriesDownloadPlan.select(books,currentKey="b6").books.isEmpty())
        assertEquals("b1",SeriesDownloadPlan.select(books).earlier?.get("key"))
    }
    @Test fun lastFinishedAnchorSkipsUnknownLocalActiveAndOtherStatuses() {
        val books=listOf(b(1),b(2,"finished"),b(3,local=null),b(4,local=true),b(5,"want-to-read"),b(6),b(7),b(8))
        assertEquals(listOf("b7","b8"),SeriesDownloadPlan.select(books,active=setOf("b6")).books.map { it["key"] })
        assertEquals(listOf("b1","b6"),SeriesDownloadPlan.select(books,2,startKey="b1").books.map { it["key"] })
        assertNull(SeriesDownloadPlan.select(books,startKey="b1").earlier)
    }
    @Test fun absentAnchorBeginsAtFirstAndCountIsValidated() {
        val books=(1..12).map(::b)
        assertEquals(3,SeriesDownloadPlan.select(books).books.size)
        assertEquals(10,SeriesDownloadPlan.select(books,10).books.size)
        for(n in listOf(0,11)) try { SeriesDownloadPlan.select(books,n);fail("count") } catch(_:IllegalArgumentException) {}
        try { SeriesDownloadPlan.select(books,startKey="other");fail("identity") } catch(_:IllegalArgumentException) {}
    }
}
