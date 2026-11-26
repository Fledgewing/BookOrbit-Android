package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

// @fixture reading-stats/dashboard.json
class ServerReadingStatsTest {
    private val zone = ZoneId.of("UTC")
    private val now = Instant.parse("2026-11-25T13:00:00Z").epochSecond
    private val today = LocalDate.parse("2026-11-25")
    private fun dashboard(): Map<*, *> = LuaValue.fromJson(File("../../../shared/fixtures/reading-stats/dashboard.json").readText()) as Map<*, *>
    private fun remote() = BookOrbitLibrary.dashboardStats(dashboard())
    private fun map(v: Map<*, *>, k: String) = v[k] as Map<*, *>
    private fun fixture(block: (Sql, Map<String, Any?>) -> Unit) {
        val dir = Files.createTempDirectory("server-stats").toFile()
        try { JdbcSql(File(dir,"statistics.db")).use { db ->
            db.exec("CREATE TABLE page_stat_data(start_time INTEGER, duration INTEGER)")
            db.exec("INSERT INTO page_stat_data VALUES(?,600)",now-3600)
            block(db,ReadingStats.aggregate(db,now,zone))
        } } finally { dir.deleteRecursively() }
    }
    @Test fun dashboardMapsMinutesStreakGoalsAndFullFinishCount() {
        val r=remote()
        assertEquals(1800L,r.days!![today]); assertEquals(12L,r.streak); assertEquals(42L,r.bestStreak)
        assertEquals(24L,r.target); assertEquals(17L,r.finished) // not capped shelf size 1
        assertEquals(mapOf("days" to true,"streak" to true,"goal" to true,"finished" to true),r.capabilities())
        assertNull(r.includedThrough) // generatedAt cannot prove inclusion
        assertEquals(RemoteReadingStats().capabilities(),BookOrbitLibrary.dashboardStats(emptyMap<Any,Any>()).capabilities())
    }
    @Test fun serverWinsPerFieldAndLocalTodayStaysSeparateWithoutWatermark() = fixture { _,local ->
        val v=ReadingStats.combine(local,remote(),now,zone)
        assertEquals(1800L,map(v,"goal")["today_seconds"])
        assertEquals(3600L,map(v,"week")["total_seconds"])
        assertEquals(600L,v["local_today_seconds"]); assertEquals("separate",v["today_merge"])
        assertEquals(12L,map(v,"records")["streak"]); assertEquals(17L,map(v,"records")["books_this_year"])
        assertEquals(24L,map(v,"goal")["target"]); assertEquals(true,map(v,"goal")["completion_available"])
        assertEquals(map(local,"records")["longest_session_seconds"],map(v,"records")["longest_session_seconds"])
        assertEquals(local["hours"],v["hours"])
        for (f in listOf("days","streak","goal","finished","today_seconds")) assertEquals("all your devices",map(v,"sources")[f])
        for (f in listOf("hours","peak_hour","longest_session_seconds")) assertEquals("this reader",map(v,"sources")[f])
        assertTrue(LuaValue.encode(v).size <= 16384)
    }
    @Test fun absenceAndCapabilityOffFallBackIndependently() = fixture { _,local ->
        for (r in listOf(null,remote())) {
            val v=ReadingStats.combine(local,r,now,zone,emptySet())
            assertEquals(local["year"],v["year"]); assertEquals(local["week"],v["week"])
            assertEquals(local["records"],v["records"]); assertEquals(local["goal"],v["goal"])
            assertTrue(map(v,"sources").values.all { it == "this reader" })
        }
        val v=ReadingStats.combine(local,remote().copy(days=null,goalAvailable=false),now,zone)
        assertEquals(local["week"],v["week"]); assertEquals(12L,map(v,"records")["streak"])
        assertNull(map(v,"goal")["target"]); assertEquals(17L,map(v,"goal")["books_this_year"])
    }
    @Test fun provenWatermarkAddsOnlyNewTodayEventsExactlyOnce() = fixture { db,_ ->
        val watermark=now-3600 // acknowledged first event (inclusive start-time semantics)
        db.exec("INSERT INTO page_stat_data VALUES(?,120)",now-120)
        db.exec("INSERT INTO page_stat_data VALUES(?,60)",now-60) // overlapping visit
        val local=ReadingStats.aggregate(db,now,zone,watermark)
        val r=remote().copy(includedThrough=watermark)
        val v=ReadingStats.combine(local,r,now,zone)
        assertEquals(1920L,map(v,"goal")["today_seconds"])
        assertEquals("watermarked",v["today_merge"]); assertNull(v["local_today_seconds"])
        // A stale/mismatched local delta must never be added to a new server snapshot.
        val mismatched=ReadingStats.combine(local,r.copy(includedThrough=watermark+1),now,zone)
        assertEquals(1800L,map(mismatched,"goal")["today_seconds"]); assertEquals("separate",mismatched["today_merge"])
    }
    @Test fun serverWorksWithoutLocalDatabaseAndInvalidPayloadIsNotAnEmptySuccess() {
        val missing=ReadingStats.read(File("/missing-stats-fixture"),now)
        val v=ReadingStats.combine(missing,remote(),now,zone)
        assertEquals("ready",v["state"]); assertEquals(false,v["hours_available"])
        assertEquals(17L,map(v,"records")["books_this_year"])
        val bad=dashboard().entries.associate { it.key.toString() to it.value }.toMutableMap().apply {
            put("readingYear",mapOf("startDate" to "bad","minutes" to listOf(-1)))
            put("readingStreak",mapOf("currentStreak" to -1,"longestStreak" to 42))
        }
        assertNull(BookOrbitLibrary.dashboardStats(bad).days); assertNull(BookOrbitLibrary.dashboardStats(bad).streak)
    }
    @Test fun cachedDashboardUsesOwnedProjectionAndOneAggregatePerBatchWithBudgetEnforcement() {
        val dir=Files.createTempDirectory("stats-projection").toFile()
        try { CacheStore(dir,{}) { JdbcSql(it) }.use { st ->
            st.own("fixture-owner")
            st.putEntry("fixture-dashboard","/koreader/plugin/catalog/dashboard",dashboard(),now)
            var calls=0
            val model=LibraryReadModel(st,{now},{},readingStats={calls++; mapOf("state" to "empty")})
            fun req(bytes: Int) = String(LuaValue.encode(mapOf("op" to "reading.stats","bytes" to bytes)),Charsets.ISO_8859_1)
            model.publish("other",listOf(req(16384))); assertEquals(0,calls)
            model.publish("fixture-owner",listOf(req(16384),req(256)))
            assertEquals(1,calls)
            val bodies=st.db().query("SELECT body FROM library_views ORDER BY length(body) DESC") { it.bytes(0)!! }
            assertTrue(bodies.first().size<=16384)
            assertEquals("ready",(LuaValue.parse(bodies.first()) as Map<*,*>)["state"])
            assertEquals("budget",(LuaValue.parse(bodies.last()) as Map<*,*>)["error"])
            st.own("other"); assertNull(BookOrbitLibrary.readingStats(st))
        } } finally { dir.deleteRecursively() }
    }
}
