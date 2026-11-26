package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.time.Instant
import java.time.ZoneId

class ReadingStatsTest {
    private val zone = ZoneId.of("UTC")
    private fun at(s: String) = Instant.parse(s).epochSecond
    private fun fixture(block: (Sql) -> Unit) {
        val dir = Files.createTempDirectory("reading-fixture").toFile()
        try { JdbcSql(java.io.File(dir,"statistics.db")).use { db ->
            db.exec("CREATE TABLE page_stat_data(id_book INTEGER, page INTEGER, start_time INTEGER, duration INTEGER)")
            block(db)
        } } finally { dir.deleteRecursively() }
    }
    private fun row(db: Sql, time: String, seconds: Long) = db.exec("INSERT INTO page_stat_data VALUES(1,1,?,?)",at(time),seconds)
    @Suppress("UNCHECKED_CAST")
    @Test fun calendarWeekHoursRecordsStreakAndGoalAreSmallMaterializedValues() = fixture { db ->
        row(db,"2026-11-23T17:30:00Z",3600)
        row(db,"2026-11-24T23:30:00Z",3600)
        row(db,"2026-11-25T12:00:00Z",-1)
        val v=ReadingStats.aggregate(db,at("2026-11-25T13:00:00Z"),zone)
        val year=v["year"] as Map<String,Any>
        assertEquals(365,(year["seconds"] as List<*>).size)
        assertEquals(3,year["days_read"])
        val week=v["week"] as Map<String,Any>
        assertEquals(listOf(3600L,1800L,1800L,0L,0L,0L,0L),week["seconds"])
        assertEquals(1800L,(v["hours"] as List<Long>)[0])
        assertEquals(50,v["after_18_percent"])
        assertEquals(0,v["peak_hour"])
        val records=v["records"] as Map<String,Any?>
        assertEquals(2L,records["recorded_pages"])
        assertEquals(3600L,records["longest_session_seconds"])
        assertEquals(3,records["streak"])
        assertNull(records["books_this_year"])
        assertTrue(LuaValue.encode(v).size < LibraryReadModel.MAX_BYTES)
    }
    @Test fun emptyMissingInvalidAndLeapYearStayExplicit() = fixture { db ->
        val now=at("2024-03-01T00:00:00Z")
        assertEquals("empty",ReadingStats.aggregate(db,now,zone)["state"])
        row(db,"2024-02-29T12:00:00Z",60)
        row(db,"2025-01-01T00:00:00Z",60)
        val v=ReadingStats.aggregate(db,now,zone)
        assertEquals("ready",v["state"])
        assertEquals("not-saved",ReadingStats.read(java.io.File("/missing-reading-fixture"),now)["state"])
    }
    @Suppress("UNCHECKED_CAST")
    @Test fun chunkBoundarySessionMergingAndDstAreDeterministic() = fixture { db ->
        val base=at("2026-11-01T05:00:00Z")
        for (i in 0..300) db.exec("INSERT INTO page_stat_data VALUES(1,?, ?,60)",i,base+i*60)
        val v=ReadingStats.aggregate(db,base+301*60,ZoneId.of("America/New_York"))
        assertEquals(301*60L,(v["records"] as Map<String,Any>)["longest_session_seconds"])
        val h=v["hours"] as List<Long>
        assertEquals(7200L,h[1]) // both occurrences of 01:00 on the fall-back day
        assertEquals(301*60L,h.sum())
        assertTrue(LuaValue.encode(v).size <= 16384)
    }
}
