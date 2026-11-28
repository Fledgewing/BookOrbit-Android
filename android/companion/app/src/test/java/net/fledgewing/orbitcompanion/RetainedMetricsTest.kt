// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
class RetainedMetricsTest {
    private val zone=ZoneId.of("UTC")
    private fun at(s:String)=Instant.parse(s).epochSecond
    private fun metric(result:Map<String,Any?>,id:String)=((result["metrics"] as Map<*,*>)[id] as Map<*,*>)
    private fun source(now:Long)=mapOf<String,Any?>("state" to "ready","freshness" to mapOf("saved" to true),
        "sources" to mapOf("today" to "all your devices","days" to "all your devices","streak" to "all your devices","goal" to "all your devices"),
        "year" to mapOf("start" to Instant.ofEpochSecond(now).atZone(zone).toLocalDate().minusDays(364).toString(),"seconds" to List(365) { 60L }),
        "goal" to mapOf("today_seconds" to 3600L,"target" to 12L,"books_this_year" to 6L,"year" to 2026L),
        "local_today_seconds" to 600L,"records" to mapOf("streak" to 7L,"best_streak" to 20L,"recorded_pages" to 300L,"today_pages" to 8L))
    @Test fun metricCardsKeepAccountAndLocalSourcesAndOverlappingTodaySeparate() {
        val now=at("2026-07-01T12:00:00Z");val result=RetainedMetrics.snapshot(source(now),now,zone)
        assertEquals("1 h 0 m",metric(result,"today")["value"])
        assertEquals("10 m · this reader, separate",LuaValue.utf8(metric(result,"today")["separate"].toString()))
        assertEquals("all your devices",metric(result,"reading-streak")["source"])
        assertEquals(List(7) { 4 },metric(result,"reading-streak")["days"])
        assertEquals("this reader",metric(result,"pages-read")["source"])
        assertEquals("8",metric(result,"pages-read")["today"])
        assertTrue(LuaValue.encode(result).size<16384);assertEquals(1,result["row_count"])
    }
    @Test fun currentGoalHasBoundedProgressPaceAndYearAwareStatus() {
        val now=at("2026-07-01T12:00:00Z");val input=source(now)
        val result=metric(RetainedMetrics.snapshot(input,now,zone),"reading-goal")
        assertEquals("6 / 12 books · 2026",LuaValue.utf8(result["value"].toString()));assertEquals(.5,result["fraction"])
        assertEquals("On pace",result["status"]);assertTrue(result["pace"].toString().startsWith("Need "))
        val saved=input+mapOf("goal" to mapOf("target" to 12L,"books_this_year" to 2L,"year" to 2025L))
        val prior=metric(RetainedMetrics.snapshot(saved,now,zone),"reading-goal")
        assertNull(prior["pace"]);assertEquals("Saved goal for 2025",prior["status"])
        val unknown=input+mapOf("goal" to mapOf("target" to 12L,"year" to 2026L))
        assertEquals("Completion count unavailable",metric(RetainedMetrics.snapshot(unknown,now,zone),"reading-goal")["status"])
    }
    @Test fun unsupportedFieldsDoNotBecomeZeroAndZeroGoalStaysUnset() {
        val now=at("2026-01-01T00:00:00Z")
        val empty=RetainedMetrics.snapshot(mapOf("state" to "not-saved"),now,zone)
        for(id in listOf("today","reading-streak","pages-read","monthly-reading","reading-goal")) assertEquals("unavailable",metric(empty,id)["state"])
        val unset=source(now)+mapOf("goal" to mapOf("year" to 2026L,"target" to 0L))
        assertEquals("No goal set for 2026",metric(RetainedMetrics.snapshot(unset,now,zone),"reading-goal")["value"])
    }
    @Test fun twelveCalendarMonthsHandleLeapDayAndCurrentMonthWithoutBorrowingFutureDays() {
        val now=at("2024-03-01T12:00:00Z")
        val first=LocalDate.of(2023,3,3)
        val seconds=List(365) { i -> when(first.plusDays(i.toLong())) { LocalDate.of(2024,2,29) -> 3600L;LocalDate.of(2024,3,1) -> 1800L;else -> 0L } }
        val input=source(now)+mapOf("year" to mapOf("start" to first.toString(),"seconds" to seconds))
        val months=metric(RetainedMetrics.snapshot(input,now,zone),"monthly-reading")
        assertEquals(12,(months["levels"] as List<*>).size)
        assertEquals("1 h 30 m",months["total"]);assertEquals("Previous month: 1 h 0 m",months["previous"])
        assertEquals("Apr 2023 – Mar 2024",LuaValue.utf8(months["period"].toString()))
        assertEquals(1.0,(months["levels"] as List<*>)[10]);assertEquals(.5,(months["levels"] as List<*>)[11])
    }
}
