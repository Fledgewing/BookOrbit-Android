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
    @Test fun usualUseClipsExactlySevenDaysAndIgnoresChargingAndGaps() {
        val rows=listOf(row(0,100,true),row(100,90),row(200,80),row(201,90,charging=true),row(202,100),row(210,80).copy(kind=Snap.START))
        val day=BatteryEstimate.usualDays(rows,t+210*h).single()
        assertEquals(58*60.0,day.screenMin,1e-9)
        assertEquals(101*60.0,day.standbyMin,1e-9)
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
