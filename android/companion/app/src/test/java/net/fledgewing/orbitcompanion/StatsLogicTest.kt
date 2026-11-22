package net.fledgewing.orbitcompanion

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset

class StatsLogicTest {
    private val zone: ZoneId = ZoneOffset.UTC
    private val h = 3_600_000L
    private val t0 = LocalDateTime.of(2026, 11, 20, 8, 0).toInstant(ZoneOffset.UTC).toEpochMilli()

    private fun off(t: Long, level: Int, kind: String = "battery") =
        Snap(t, kind, level, charging = false, screen = false, radio = false, wmode = "jit")

    private fun reading(t: Long, level: Int, kind: String = "battery", pages: Int = 0, full: Int = 0, content: String = "text") =
        Snap(t, kind, level, charging = false, screen = true, radio = false, wmode = "jit", content = content, light = false, pages = pages, full = full)

    @Test
    fun segmentsSplitOnStateAndKeepTheTransitionPoint() {
        val rows = listOf(
            off(t0, 80, "start"),
            off(t0 + 5 * h, 79),
            off(t0 + 10 * h, 78),
            reading(t0 + 10 * h + 1, 78, "screen_on"),
            reading(t0 + 11 * h, 74, "stats", pages = 120, full = 12),
            off(t0 + 11 * h + 1, 74, "screen_off"),
        )
        val segs = BatteryStats.segments(rows)
        assertEquals(listOf(PowerState.STANDBY, PowerState.READING), segs.map { it.key.state })
        assertEquals(80, segs[0].startPct)
        assertEquals(78, segs[0].endPct)
        assertEquals(78, segs[1].startPct)
        assertEquals(74, segs[1].endPct)
        assertEquals(120, segs[1].pages)
        assertEquals(12, segs[1].full)
    }

    @Test
    fun rollupsLeaveOutTheOpenSegment() {
        val rows = listOf(off(t0, 80), off(t0 + 2 * h, 79), reading(t0 + 3 * h, 79, "screen_on"), reading(t0 + 4 * h, 75))
        assertEquals(2, BatteryStats.segments(rows).size)
        assertEquals(listOf(PowerState.STANDBY), BatteryStats.segments(rows, includeOpen = false).map { it.key.state })
        val live = BatteryStats.segments(rows, now = t0 + 5 * h)
        assertEquals(2.0, live.last().hours, 1e-9)
        assertEquals(75, live.last().endPct)
    }

    @Test
    fun startRowBreaksSegmentsWithoutBridgingTheGap() {
        val rows = listOf(off(t0, 80), off(t0 + 2 * h, 79), off(t0 + 20 * h, 60, Snap.START), off(t0 + 22 * h, 59))
        val segs = BatteryStats.segments(rows)
        assertEquals(2, segs.size)
        assertEquals(2.0, segs[0].hours, 1e-9)
        assertEquals(2.0, segs[1].hours, 1e-9)
    }

    @Test
    fun pooledSlopeMatchesAKnownLineAcrossSegments() {
        // Two standby stretches at exactly 0.2 %/h with different intercepts.
        val rows = mutableListOf<Snap>()
        for (i in 0..10) rows += off(t0 + i * 5 * h, 90 - i)
        rows += reading(t0 + 50 * h + 1, 80, "screen_on")
        for (i in 0..10) rows += off(t0 + 51 * h + i * 5 * h, 79 - i, if (i == 0) "screen_off" else "battery")
        val totals = BatteryStats.totals(BatteryStats.rollup(BatteryStats.segments(rows), zone))
        val r = BatteryStats.rate("standby", totals["standby"])!!
        assertEquals(0.2, r.pctPerH, 1e-9)
        assertTrue(r.shown)
        assertEquals(0.0, r.se!!, 1e-6)
        assertTrue(totals.containsKey("standby|wifi_mode=jit"))
        assertTrue(totals.containsKey("standby|radio=off"))
    }

    @Test
    fun rollupsAddUpToTheSameRateAsAllAtOnce() {
        val rows = mutableListOf<Snap>()
        var lvl = 100
        var t = t0
        repeat(6) { day ->
            rows += off(t, lvl, "screen_off"); t += 6 * h; lvl -= 1
            rows += off(t, lvl); t += 5 * h; lvl -= 1
            rows += reading(t, lvl, "screen_on"); t += h / 2; lvl -= 2
            rows += reading(t, lvl, pages = 50 + day); t += h / 2; lvl -= 2
            rows += reading(t, lvl)
        }
        val segs = BatteryStats.segments(rows)
        val cells = BatteryStats.rollup(segs, zone)
        val byDay = cells.keys.map { it.first }.toSet()
        assertTrue("spread over days", byDay.size > 2)
        val all = BatteryStats.rate("reading", BatteryStats.totals(cells)["reading"])!!
        val manual = segs.filter { it.key.state == PowerState.READING }.map { it.sums }.reduce { a, b -> a + b }
        assertEquals(BatteryStats.rate("reading", manual)!!.pctPerH, all.pctPerH, 1e-9)
        assertEquals(4.0, all.pctPerH, 1e-9)
    }

    @Test
    fun lowDataRatesAreHiddenWithWhatIsMissing() {
        val short = BatteryStats.segments(listOf(reading(t0, 50), reading(t0 + h / 2, 48)))
        val r = BatteryStats.rate("reading", BatteryStats.totals(BatteryStats.rollup(short, zone))["reading"])!!
        assertFalse(r.shown)
        assertEquals("0.5 h of 1 h needed", r.missing)
        val flat = BatteryStats.segments(listOf(off(t0, 50), off(t0 + 3 * h, 49), off(t0 + 5 * h, 48)))
        val f = BatteryStats.rate("standby", BatteryStats.totals(BatteryStats.rollup(flat, zone))["standby"])!!
        assertFalse("2% is not enough", f.shown)
        assertNull(BatteryStats.per100(f, 1000))
    }

    @Test
    fun per100NeedsAShownRateAndEnoughCounts() {
        val r = Rate(4.0, 0.1, 10.0, 40.0, 5, true, null)
        assertEquals(1.0, BatteryStats.per100(r, 4000)!!, 1e-9)
        assertNull(BatteryStats.per100(r, 99))
    }

    @Test
    fun estimateUsesTheOnShareAndBothRates() {
        val day = DayTotals(1, screenMin = 120.0, standbyMin = 1320.0)
        val f = BatteryStats.onShare(listOf(day))!!
        assertEquals(120.0 / 1440.0, f, 1e-9)
        val on = Rate(4.0, null, 30.0, 100.0, 9, true, null)
        val sb = Rate(0.2, null, 200.0, 40.0, 9, true, null)
        val hrs = BatteryStats.hoursLeft(64, f, on, sb)!!
        assertEquals(64 / (f * 4.0 + (1 - f) * 0.2), hrs, 1e-9)
        assertNull("under 24 h of data", BatteryStats.onShare(listOf(DayTotals(1, screenMin = 60.0, standbyMin = 600.0))))
        assertNull("rate hidden", BatteryStats.hoursLeft(64, f, on.copy(shown = false), sb))
        assertEquals(16.0, BatteryStats.hoursLeftAt(64, on)!!, 1e-9)
    }

    @Test
    fun dailyTotalsSplitAtMidnight() {
        val evening = LocalDateTime.of(2026, 11, 20, 22, 0).toInstant(ZoneOffset.UTC).toEpochMilli()
        val rows = listOf(off(evening, 70, "screen_off"), off(evening + 3 * h, 69), reading(evening + 4 * h, 69, "screen_on"),
            reading(evening + 5 * h, 65, pages = 200, full = 20))
        val d = BatteryStats.daily(rows, zone)
        val d20 = d[BatteryStats.day(evening, zone)]!!
        val d21 = d[BatteryStats.day(evening, zone) + 1]!!
        assertEquals(120.0, d20.standbyMin, 1e-6)
        assertEquals(120.0, d21.standbyMin, 1e-6)
        assertEquals(60.0, d21.screenMin, 1e-6)
        assertEquals(5, d21.usedPct)
        assertEquals(200, d21.pages)
    }

    @Test
    fun exportImportRoundTrip() {
        val rows = mutableListOf<Snap>()
        for (i in 0..20) rows += off(t0 + i * 5 * h, 95 - i)
        rows += reading(t0 + 100 * h + 1, 75, "screen_on")
        for (i in 1..8) rows += reading(t0 + 100 * h + i * h / 2, 75 - 2 * i, pages = 30, full = 15)
        val segs = BatteryStats.segments(rows)
        val totals = BatteryStats.totals(BatteryStats.rollup(segs, zone))
        val days = BatteryStats.daily(rows, zone).values.toList()
        val dev = StatsExport.Device("Haoqing", "M8C", "14", 3000, "power_profile")
        val json = StatsExport.build(dev, "0.3.0", t0 + 110 * h, zone, totals, days, segs)
        assertEquals("orbit-battery-stats/1", json.getString("schema"))
        assertEquals("android-companion", json.getString("source"))
        assertEquals("fuel_gauge", json.getString("battery_source"))
        assertTrue(json.getJSONArray("segments").getJSONObject(0).getString("start").startsWith("2026-11-20T08:00"))
        val back = StatsExport.parse(json.toString())
        assertEquals("Haoqing M8C", back.label)
        assertEquals("14", back.androidVersion)
        assertEquals(3000, back.capacityMah)
        assertEquals(totals.size, back.rates.size)
        assertEquals(BatteryStats.rate("standby", totals["standby"])!!.pctPerH, back.rates["standby"]!!.pctPerH, 1e-3)
        assertEquals(BatteryStats.rate("reading|content=text", totals["reading|content=text"])!!.pctPerH, back.rates["reading|content=text"]!!.pctPerH, 1e-3)
        assertNotNull(back.per100Pages)
    }

    @Test
    fun importsAMinimalFirmwareFileFromSegmentsOnly() {
        // An Xteink-like device: awake/asleep only, voltage-estimated %, no Android fields.
        val text = """
            {"schema":"orbit-battery-stats/1","source":"crossink-firmware","battery_source":"voltage_estimate",
             "device":{"manufacturer":"Xteink","model":"X4"},"future_field":{"x":1},
             "segments":[
              {"start":"2026-11-01T22:00:00Z","end":"2026-11-02T08:00:00Z","state":"standby","start_pct":90,"end_pct":89},
              {"start":"2026-11-02T08:00:00Z","end":"2026-11-02T10:00:00Z","state":"awake","start_pct":89,"end_pct":85},
              {"start":"2026-11-02T10:00:00Z","end":"2026-11-03T10:00:00Z","state":"standby","start_pct":85,"end_pct":83}]}
        """.trimIndent()
        val im = StatsExport.parse(text)
        assertEquals("crossink-firmware", im.source)
        assertEquals("voltage_estimate", im.batterySource)
        assertNull(im.androidVersion)
        assertNull(im.capacityMah)
        assertEquals(2.0, im.rates["awake"]!!.pctPerH, 1e-9)
        // Pooled over both stretches: Σsxy/Σsxx = (10·1 + 24·2)/2 ÷ (10² + 24²)/2
        assertEquals(29.0 / 338.0, im.rates["standby"]!!.pctPerH, 1e-9)
        assertTrue(im.rates["standby"]!!.shown)
    }

    @Test
    fun importsAFirmwareFileWithNoClock() {
        // Never-set clock: null/empty dates, durations only; unknown enum values kept as-is.
        val text = """
            {"schema":"orbit-battery-stats/1","source":"crossink-firmware","battery_source":"fuel_gauge",
             "generated":null,"device":{"manufacturer":"Xteink","model":"X4"},
             "period":{"first_day":null,"last_day":"","days":0},
             "daily":[{"day":null,"used_pct":9,"screen_on_min":80},{"day":"","used_pct":4}],
             "per_100":[{"state":"reading","unit":"pages","pct":0.4,"count":900},
                        {"state":"reading","unit":"full_refreshes","pct":0.9,"count":400}],
             "segments":[
              {"start":null,"end":null,"duration_s":36000,"state":"standby","start_pct":90,"end_pct":89},
              {"start":"","end":"","duration_s":7200,"state":"reading","content":"xtc","light":"off","start_pct":89,"end_pct":85,"pages":300},
              {"duration_s":7200,"state":"reading","content":"xtc","light":"off","start_pct":85,"end_pct":81},
              {"duration_s":3600,"state":"teleporting","start_pct":81,"end_pct":80},
              {"duration_s":86400,"state":"standby","start_pct":81,"end_pct":79}]}
        """.trimIndent()
        val im = StatsExport.parse(text)
        assertTrue(im.asleepAwake)
        assertEquals("fuel_gauge", im.batterySource)
        assertEquals(0, im.days)
        assertNull(im.androidVersion)
        assertEquals(2.0, im.rates["reading|content=xtc"]!!.pctPerH, 1e-9)
        assertEquals(2.0, im.rates["reading|light=off"]!!.pctPerH, 1e-9)
        assertTrue("unknown content shown, not rejected", im.rates["reading|content=xtc"]!!.shown)
        assertEquals(0.4, im.per100Pages!!, 1e-9)
        assertEquals(0.9, im.per100Full!!, 1e-9)
        assertEquals(10.0 + 4.0 + 24.0, im.hours, 1e-9)
    }

    @Test
    fun exportWritesOnOffAndDurations() {
        val rows = listOf(reading(t0, 80).copy(light = true), reading(t0 + 2 * h, 76).copy(light = true))
        val json = StatsExport.build(StatsExport.Device("X", "Y", null, null, null), "0.3.0", t0 + 3 * h, zone,
            BatteryStats.totals(BatteryStats.rollup(BatteryStats.segments(rows), zone)), emptyList(), BatteryStats.segments(rows))
        val seg = json.getJSONArray("segments").getJSONObject(0)
        assertEquals("on", seg.getString("light"))
        assertEquals("off", seg.getString("radio"))
        assertEquals(7200L, seg.getLong("duration_s"))
        assertFalse(json.getJSONObject("device").has("android_version"))
        assertTrue(StatsExport.parse(json.toString()).rates.containsKey("reading|light=on"))
    }

    @Test
    fun rejectsFilesThatArentSummaries() {
        for (bad in listOf("{}", "not json", """{"schema":"orbit-battery-stats/2"}""")) {
            try {
                StatsExport.parse(bad)
                throw AssertionError("accepted $bad")
            } catch (e: StatsExport.BadFile) {
                // expected
            }
        }
    }
}
