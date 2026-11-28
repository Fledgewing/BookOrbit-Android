// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
class NextStopTest {
    private val native=mapOf<String,Any?>("path" to "/fixture/book.epub","page" to 100,"total" to 200,"chapter_total" to 5,"chapter_index" to 2,"chapter_exact" to true,"toc_loaded" to true,"chapter_title" to LuaValue.str("Chapter 二"),"next_page" to 130,"next_title" to "Chapter 3","next_exists" to true)
    private fun text(result:Map<String,Any?>,field:String)=LuaValue.utf8(result[field].toString())
    @Test fun measuredFractionalPaceGivesNextEndAndRemainingWithoutAChapterScan() {
        val result=NextStop.snapshot(native,mapOf("seconds_per_fraction" to 10000.0))
        assertEquals("Now: Chapter 二",text(result,"current"));assertEquals("Next: Chapter 3",text(result,"next"))
        assertEquals("≈ 25 min to next",text(result,"to_next"));assertEquals("≈ 1 h 24 min to end",text(result,"to_end"))
        assertEquals("3 contents entries left",result["remaining"]);assertTrue(text(result,"source").startsWith("Measured pace"))
        assertTrue(LuaValue.encode(result).size<16384)
    }
    @Test fun missingTocMissingPaceAndInvalidNextMarkersStayExplicit() {
        val unloaded=NextStop.snapshot(native+mapOf("toc_loaded" to false),mapOf("seconds_per_fraction" to 10000.0))
        assertEquals("Next: Open Contents once",text(unloaded,"next"));assertEquals("Contents count unavailable",unloaded["remaining"])
        assertEquals("Chapter time unavailable",text(unloaded,"to_next"));assertTrue(text(unloaded,"to_end").startsWith("≈ "))
        val noPace=NextStop.snapshot(native);assertEquals("Not enough reading yet",text(noPace,"to_next"));assertEquals("End time unavailable",text(noPace,"to_end"))
        val bad=NextStop.snapshot(native+mapOf("next_page" to 900),mapOf("seconds_per_fraction" to 10000.0))
        assertEquals("Next: Contents position unavailable",text(bad,"next"));assertEquals("Chapter time unavailable",text(bad,"to_next"))
        for(n in listOf(Double.NaN,-1.0,Double.POSITIVE_INFINITY)) assertEquals("Not enough reading yet",text(NextStop.snapshot(native,mapOf("seconds_per_fraction" to n)),"to_next"))
    }
    @Test fun closedInvalidAndEndPositionsNeverInferCompletionOrUnknownZeroes() {
        assertEquals("unavailable",NextStop.snapshot(emptyMap<String,Any>())["state"])
        assertEquals("unavailable",NextStop.snapshot(native+mapOf("page" to 0))["state"])
        val end=NextStop.snapshot(native+mapOf("page" to 200,"chapter_index" to 5,"next_page" to null,"next_exists" to false))
        assertEquals("At end of book",text(end,"to_next"));assertEquals("0 contents entries left",end["remaining"])
        assertFalse(end.containsKey("finished"))
        val unknown=NextStop.snapshot(native+mapOf("chapter_total" to null))
        assertEquals("Contents count unavailable",unknown["remaining"])
    }
    @Test fun invalidIdentityNeverOpensTheBorrowedDatabaseAndNativeFractionDrivesTheEstimate() {
        val root=Files.createTempDirectory("next-stop").toFile()
        try {
            val file=java.io.File(root,"statistics.sqlite3").apply { writeText("fixture") };var opened=0
            val bad=NextStop.read(native+mapOf("md5" to "invalid"),file,100) { opened++;error("must not open") }
            assertEquals(0,opened);assertEquals("Not enough reading yet",text(bad,"to_next"))
            val md5="0".repeat(32)
            JdbcSql(java.io.File(root,"measured.sqlite3")).use { db ->
                db.exec("CREATE TABLE book(id INTEGER,md5 TEXT)");db.exec("INSERT INTO book VALUES(1,?)",md5)
                db.exec("CREATE TABLE page_stat_data(id_book INTEGER,page INTEGER,total_pages INTEGER,start_time INTEGER,duration INTEGER)")
                repeat(5) { db.exec("INSERT INTO page_stat_data VALUES(1,?,100,?,100)",it+1,it+1) }
            }
            val result=NextStop.read(native+mapOf("md5" to md5),java.io.File(root,"measured.sqlite3"),100) { JdbcSql(it) }
            assertEquals("≈ 25 min to next",text(result,"to_next"))
        } finally { root.deleteRecursively() }
    }
}
