// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test
import java.time.ZoneOffset

class BatteryEstimateTest {
    private val zone = ZoneOffset.UTC
    private val h = 3_600_000L
    private val t = 1_700_000_000_000L
    private fun row(hours: Int, pct: Int, screen: Boolean = false, charging: Boolean = false) =
        Snap(t+hours*h, "battery", pct, charging, screen, wmode="jit", elapsed=hours*h)
    private fun snapshot(rows: List<Snap>, days: List<DayTotals> = emptyList()): Map<String, Any?> {
        val segs = BatteryStats.segments(rows)
        return BatteryEstimate.snapshot(BatteryStats.totals(BatteryStats.rollup(segs,zone)),days,rows.lastOrNull(),segs,rows.lastOrNull()?.t ?: t,zone)
    }
    @Test fun presentationIsBoundedAndKeepsLearningAndClockBoundaries() {
        val future = row(10,78)
        val learning = BatteryEstimate.snapshot(emptyMap(),emptyList(),future,emptyList(),t,zone)
        val d = learning["display"] as Map<*, *>
        fun text(key: String) = LuaValue.utf8(d[key] as String)
        assertEquals("—",text("level"))
        assertTrue(text("estimate").contains("Learning"))
        assertFalse(text("estimate").contains("78"))
        assertTrue(text("used_week").contains("Needs measured"))
        assertTrue(LuaValue.utf8((d["overview"] as List<*>)[2] as String).contains("24 h"))
        val ready = BatteryEstimate.display(mapOf("level" to 78,"hours_usual_use" to 54.0,
            "hours_reading_nonstop" to 19.0,"hours_standby_only" to 142.0,
            "recent_charges" to List(5) { mapOf("start" to t,"hours" to 2.0,"from_pct" to 12,"to_pct" to 100) },
            "pct_used_per_day" to List(14) { mapOf("day" to 19000L+it,"used_pct" to 5.0,"screen_on_minutes" to 60.0,"charges" to 1) }),zone,t)
        val shown = ready["display"] as Map<*, *>
        assertTrue(LuaValue.utf8(shown["estimate"] as String).endsWith("at your usual use"))
        assertTrue(LuaValue.utf8(shown["narrow_estimate"] as String).endsWith("· usual use"))
        assertTrue(LuaValue.utf8(shown["page_estimate"] as String).contains("left at your usual use"))
        assertEquals(14,shown["daily_count"]); assertEquals(5,shown["charges_count"])
        assertTrue(LuaValue.encode(ready).size <= 16384)
        assertTrue(LuaValue.utf8((shown["charges"] as List<*>)[0] as String).contains("12% → 100%"))
        val today = BatteryStats.day(t,zone)
        val sparse = BatteryEstimate.display(mapOf("pct_used_per_day" to listOf(
            mapOf("day" to today-10,"used_pct" to 90),mapOf("day" to today,"used_pct" to 4))),zone,t)
        assertEquals("4.0% used this week",LuaValue.utf8((sparse["display"] as Map<*,*>)["used_week"] as String))
        val bounded = BatteryEstimate.snapshot(emptyMap(),List(14) { DayTotals(today-it,usedPct=5) },row(0,78),
            emptyList(),t,zone,recentCharges=List(5) { mapOf("start" to t,"from_pct" to 12,"to_pct" to 100,"hours" to 2.0) })
        assertTrue(LuaValue.encode(bounded).size<=16384)

    }
    @Test fun usualUseClipsExactlySevenDaysAndIgnoresChargingAndGaps() {
        val rows=listOf(row(0,100,true),row(100,90),row(200,80),row(201,90,charging=true),row(202,100),row(210,80).copy(kind=Snap.START))
        val day=BatteryEstimate.usualDays(rows,t+210*h).single()
        assertEquals(58*60.0,day.screenMin,1e-9)
        assertEquals(101*60.0,day.standbyMin,1e-9)
        val sparse=BatteryEstimate.usualDays(listOf(row(0,90,true),row(1,86,true)),t+100*h)
        assertNull("Waiting without observations must not create 24 h of evidence",BatteryStats.onShare(sparse))
    }
    @Test fun settingsModeLinesUseMeasuredHoursAndExplicitPatternEstimates() {
        val model=mapOf<String,Any?>("modes" to listOf(
            mapOf("id" to "battery-saver","hours_usual_use" to 60.5,"estimated" to false),
            mapOf("id" to "balanced","hours_usual_use" to 10.0,"estimated" to false),
            mapOf("id" to "always-up-to-date","hours_usual_use" to 20.0,"estimated" to true)))
        val rows=BatteryEstimate.modeRows(model)["items"] as List<*>
        assertEquals(listOf("saver","balanced","current"),rows.map { (it as Map<*,*>)["id"] })
        assertEquals("≈ 2 d 12 h at your usual use",LuaValue.utf8((rows[0] as Map<*,*>)["text"] as String))
        assertEquals(true,(rows[0] as Map<*,*>)["measured"])
        assertTrue(LuaValue.utf8((rows[2] as Map<*,*>)["text"] as String).contains("estimate:"))
        assertEquals(false,(rows[2] as Map<*,*>)["measured"])
        assertEquals(1,(BatteryEstimate.modeRows(model,1)["items"] as List<*>).size)
        assertTrue(LuaValue.encode(BatteryEstimate.modeRows(model)).size<=16384)
    }
    @Test fun retainedChargeUpdatesReplaceAnOpenSessionWithoutDuplicates() {
        val old=listOf(mapOf<String,Any?>("start" to 1L,"from_pct" to 20,"to_pct" to 60,"ongoing" to true))
        val done=listOf(mapOf<String,Any?>("start" to 1L,"from_pct" to 20,"to_pct" to 100,"ongoing" to false))
        val rows=BatteryEstimate.retainCharges(old,done)
        assertEquals(1,rows.size); assertEquals(100,rows.single()["to_pct"])
        assertEquals(false,rows.single()["ongoing"])
        assertEquals(false,BatteryEstimate.retainCharges(old,emptyList()).single()["ongoing"])
    }
    @Test fun pruningAChargePrefixKeepsItsOriginalLevelAndDuration() {
        fun charge(start:Long,end:Long,from:Int,to:Int,ongoing:Boolean) = mapOf<String,Any?>(
            "start" to start,"end" to end,"from_pct" to from,"to_pct" to to,"hours" to (end-start)/h.toDouble(),"ongoing" to ongoing)
        val complete=charge(0,2*h,20,100,false)
        val suffix=charge(h,2*h,60,100,false)
        val kept=BatteryEstimate.retainCharges(listOf(complete),listOf(suffix))
        assertEquals(1,kept.size); assertEquals(20,kept.single()["from_pct"])
        assertEquals(2.0,kept.single()["hours"] as Double,1e-9)
        val extended=BatteryEstimate.retainCharges(listOf(charge(0,h,20,60,true)),listOf(charge(h/2,2*h,40,100,false)))
        assertEquals(1,extended.size); assertEquals(0L,extended.single()["start"])
        assertEquals(2.0,extended.single()["hours"] as Double,1e-9)
        val clockOverlap=BatteryEstimate.retainCharges(listOf(complete),listOf(charge(h,3*h,20,100,false)))
        assertEquals("Separate completed sessions may overlap after a clock correction",2,clockOverlap.size)
    }
    @Test fun nonpositiveOrNonfiniteFitsNeverCreateArtificiallyLongLifetimes() {
        val noisy=snapshot(listOf(row(0,100,true),row(1,50,true),row(2,99,true),row(3,95,true)))
        assertNull((noisy["screen_on"] as Map<*,*>)["pct_per_hour"])
        assertNotNull((noisy["screen_on"] as Map<*,*>)["missing"])
        val measured=Rate(1.0,0.0,24.0,24.0,1,true,null)
        for (bad in listOf(-1.0,0.0,Double.POSITIVE_INFINITY,Double.NaN)) {
            assertNull(BatteryStats.hoursLeft(50,0.25,measured.copy(pctPerH=bad),measured))
            assertNull(BatteryStats.hoursLeftAt(50,measured.copy(pctPerH=bad)))
        }
    }
    @Test fun newDeviceHasExplicitMissingEvidenceAndNoInventedLifetime() {
        val s = snapshot(emptyList())
        assertNull(s["level"]); assertNull(s["hours_usual_use"])
        assertEquals(emptyList<Any>(),s["recent_charges"])
        assertTrue((s["modes"] as List<*>).all { (it as Map<*,*>)["estimated"] == true })
        assertNotNull((s["screen_on"] as Map<*,*>)["missing"])
    }
    @Test fun syntheticDrainBlendsRatesAndExcludesOldDaysRatherThanTakingLastSevenRows() {
        val rows = listOf(row(0,100,true), row(1,96,true), row(2,92,true),row(3,88), row(13,78),row(23,68),row(33,58))
        val today = BatteryStats.day(rows.last().t,zone)
        val days = listOf(DayTotals(today,screenMin=360.0,standbyMin=1080.0), DayTotals(today-20,screenMin=10000.0))
        val s = snapshot(rows,days)
        assertEquals(4.0,((s["screen_on"] as Map<*,*>)["pct_per_hour"] as Double),1e-9)
        assertEquals(1.0,((s["standby"] as Map<*,*>)["pct_per_hour"] as Double),1e-9)
        assertEquals(58/1.75,s["hours_usual_use"] as Double,1e-9)
        assertEquals(14.5,s["hours_reading_nonstop"] as Double,1e-9)
        assertEquals(58.0,s["hours_standby_only"] as Double,1e-9)
        assertEquals(25.0,(s["usual_use"] as Map<*,*>)["screen_on_percent"] as Double,1e-9)
        val modes = s["modes"] as List<*>
        assertEquals(false,(modes[0] as Map<*,*>)["estimated"])
        assertEquals(true,(modes[2] as Map<*,*>)["estimated"])
        assertTrue(LuaValue.encode(s).size <= LibraryReadModel.MAX_BYTES)
    }
    @Test fun chargesAndServiceGapsNeverBecomeDrain() {
        val rows = listOf(row(0,80),row(10,70),row(11,69,true,true),row(12,89,true,true),row(13,100),
            row(20,80).copy(kind=Snap.START),row(30,70))
        val s = snapshot(rows)
        val charges = s["recent_charges"] as List<*>
        assertEquals(1,charges.size)
        assertEquals(69,(charges.single() as Map<*,*>)["from_pct"])
        assertEquals(100,(charges.single() as Map<*,*>)["to_pct"])
        assertEquals(21,BatteryStats.daily(rows,zone).values.sumOf { it.usedPct })
        assertTrue(BatteryStats.segments(rows).filter { it.key.state != PowerState.CHARGING }.all { it.sums.change >= 0 })
    }
    @Test fun liveDailyTailKeepsMonotonicTimeConsistent() {
        val rows=listOf(row(0,90),row(2,88))
        assertEquals(3*60.0,BatteryStats.daily(rows,zone,t+3*h).values.sumOf { it.standbyMin },1e-9)
    }
    @Test fun clockChangesInEitherDirectionAndRebootBreakTheInterval() {
        for (delta in listOf(-20*h,20*h)) {
            val rows = listOf(row(0,90),row(2,88),row(3,40).copy(t=t+3*h+delta),row(4,39).copy(t=t+4*h+delta))
            val segments = BatteryStats.segments(rows)
            assertEquals(3.0,segments.sumOf { it.hours },1e-9)
            assertEquals(3,BatteryStats.daily(rows,zone).values.sumOf { it.usedPct })
        }
        val rows = listOf(row(0,90),row(2,88),row(3,40).copy(elapsed=1),row(4,39).copy(elapsed=h+1))
        assertEquals(3.0,BatteryStats.segments(rows).sumOf { it.hours },1e-9)
    }
    @Test fun recentChargesAndDailyRowsAreBounded() {
        val rows = (0..30).map { row(it,if(it%3==0) 20 else if(it%3==1) 50 else 80,charging=it%3!=2) }
        val today=BatteryStats.day(rows.last().t,zone)
        val s=snapshot(rows,(0..100).map { DayTotals(today-it,usedPct=10) })
        assertEquals(5,(s["recent_charges"] as List<*>).size)
        assertEquals(14,(s["pct_used_per_day"] as List<*>).size)
    }
}
