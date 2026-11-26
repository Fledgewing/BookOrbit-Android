package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

class ReadingStatsWidgetTest {
    private val zone=ZoneId.of("UTC")
    private val now=Instant.parse("2026-11-25T21:42:00Z").epochSecond
    @Test fun labelsFollowResolvedFieldsAndDoNotInventMissingRecords() {
        val local=mapOf("state" to "ready", "hours" to List(24) { 0 }, "peak_hour" to 22,
            "records" to mapOf("longest_session_seconds" to 7200),
            "week" to mapOf("seconds" to listOf(60,120,0,0,0,0,0),"total_seconds" to 180),
            "year" to mapOf("start" to "2025-11-26"),"local_today_seconds" to 600,
            "sources" to mapOf("longest_session_seconds" to "all your devices"))
        val out=ReadingStats.display(local,now,zone)
        val d=out["display"] as Map<*, *>
        assertEquals("3 m",d["week_total"]); assertEquals(3,d["today_index"])
        assertEquals(2,d["best_index"]); assertEquals("2 m",d["best_duration"])
        assertEquals("Evenings",d["period"]); assertEquals("22:00",d["peak"])
        assertEquals("2 h 0 m",d["longest"])
        assertEquals("10 m today · this reader (separate)",LuaValue.utf8(d["local_today"] as String))
        assertEquals(local["sources"],out["sources"])
        assertEquals(12,(d["months"] as List<*>).size)
        assertFalse((out["records"] as Map<*, *>).containsKey("books_this_year"))
        assertTrue(LuaValue.encode(out).size<=16384)
        val empty=ReadingStats.display(emptyMap(),now,zone)["display"] as Map<*, *>
        assertNull(empty["peak"]); assertNull(empty["best_index"]); assertNull(empty["longest"])
    }
    @Test fun clockFormatsDeviceTimeWeekRolloverAndUnavailableBattery() {
        val v=ClockWidget.snapshot(now,mapOf("level" to 78),zone)
        assertEquals("21:42",v["time"]); assertEquals("25 November",v["date"])
        val days=v["days"] as List<*>
        assertEquals(7,days.size); assertEquals(true,(days[2] as Map<*, *>)["today"])
        assertEquals("▭ 78% ›",LuaValue.utf8(v["battery"] as String))
        assertEquals("9:42 PM",ClockWidget.snapshot(now,emptyMap(),zone,true)["time"])
        assertEquals("Battery ›",LuaValue.utf8(ClockWidget.snapshot(now,emptyMap(),zone)["battery"] as String))
        assertEquals("not-saved",ClockWidget.snapshot(0,emptyMap(),zone)["state"])
        val rollover=ClockWidget.snapshot(Instant.parse("2027-01-01T00:01:00Z").epochSecond,emptyMap(),zone)
        assertEquals("1 January",rollover["date"])
        val saved=LuaValue.parse(LuaValue.encode(v)) as Map<*, *>
        assertEquals("▭ 78% ›",LuaValue.utf8(saved["battery"] as String))
        assertTrue(LuaValue.encode(v).size<=16384)
    }
}
