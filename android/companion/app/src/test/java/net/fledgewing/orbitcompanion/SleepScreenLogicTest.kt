package net.fledgewing.orbitcompanion

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The sleep screen's decisions (docs/design/lock-screen.md), with no Android. */
class SleepScreenLogicTest {
    /** shared/fixtures/sleep/cases.json: the rotation rule (R4) and the fallbacks (F1, F4). */
    @Test
    fun rotationFollowsTheSharedCases() {
        val doc = JSONObject(File("../../../shared/fixtures/sleep/cases.json").readText())
        val cases = doc.getJSONArray("cases")
        assertTrue(cases.length() >= 10)
        for (n in 0 until cases.length()) {
            val c = cases.getJSONObject(n)
            val pool = c.getJSONArray("pool").let { a -> (0 until a.length()).map { a.getLong(it) } }
            val st = c.getJSONObject("state").let { SleepRotation.State(it.getLong("shown"), it.getLong("changed_at"), shows(it)) }
            // Every sleep's draws, in order (n -> 0 until n); the X4's host test reads the same.
            val draws = c.optJSONArray("rand")?.let { a -> (0 until a.length()).map { a.getInt(it) } } ?: emptyList()
            var drawn = 0
            val d = SleepRotation.decide(
                SleepMode.of(c.getString("mode"))!!, c.getInt("hours"), c.getLong("now"), pool, c.getBoolean("current"), st,
                advance = c.optBoolean("advance", true),
            ) { draws.getOrElse(drawn++) { 0 } }
            val next = c.getJSONObject("next").let { SleepRotation.State(it.getLong("shown"), it.getLong("changed_at"), shows(it)) }
            assertEquals(c.getString("name"), c.getString("show"), d.show)
            assertEquals(c.getString("name"), next, d.next)
        }
    }

    private fun shows(o: JSONObject): Map<Long, Int> =
        o.optJSONObject("shows")?.let { s -> s.keys().asSequence().associate { it.toLong() to s.getInt(it) } } ?: emptyMap()

    /** shared/fixtures/sleep/cases.json "batch": Every sleep's carry at a refresh (R4b), the X4's too. */
    @Test
    fun everySleepCarryFollowsTheSharedCases() {
        val batch = JSONObject(File("../../../shared/fixtures/sleep/cases.json").readText()).getJSONArray("batch")
        assertTrue(batch.length() >= 3)
        for (n in 0 until batch.length()) {
            val c = batch.getJSONObject(n)
            val prev = c.getJSONArray("prev").let { a -> (0 until a.length()).map { a.getJSONObject(it) } }
            val (carry, retired) = SleepPoolLogic.carry(prev.map { it.getLong("id") }, prev.associate { it.getLong("id") to it.getInt("shows") })
            val ids = { k: String -> c.getJSONArray(k).let { a -> (0 until a.length()).map { a.getLong(it) } } }
            assertEquals(c.getString("name"), ids("carry"), carry)
            assertEquals(c.getString("name"), ids("retired"), retired.toList())
        }
    }

    @Test
    fun settingsFromThePluginKeepWhatIsMissingAndDefaultWhatIsBad() {
        val base = SleepSettings.DEFAULT.copy(mode = SleepMode.CURRENT, hours = 12)
        val extras = mapOf(
            "sleep_mode" to "recommended", "sleep_from" to "scope:12", "sleep_leave_out" to "tag: Age:18 \nscope:3\nbogus\nscope:3",
            "sleep_battery" to "1", "sleep_style" to "halo", "sleep_text_position" to "top", "sleep_text" to "x".repeat(80),
        )
        val s = SleepSettings.merge(base) { extras[it] }
        assertEquals(SleepMode.RECOMMENDED, s.mode)
        assertEquals("scope:12", s.from)
        assertEquals(listOf("tag:age:18", "scope:3"), s.leaveOut)
        assertEquals(12, s.hours) // not sent: kept
        assertTrue(s.battery)
        assertEquals(SleepStyle.BAR, s.style) // bad: the default
        assertEquals(TextPosition.TOP, s.textPosition)
        assertEquals(60, s.text.length)
        assertEquals(s, SleepSettings.merge(SleepSettings.DEFAULT) { s.toMap()[it] }) // round trip
        assertEquals(SleepSettings.DEFAULT, SleepSettings.merge(SleepSettings.DEFAULT) { null }) // an older plugin
        assertEquals("up_next", SleepSettings.merge(base) { if (it == "sleep_from") "scope:0" else null }.from)
        assertEquals("Bedtime 8 pm", SleepSettings.cleanText("  Bedtime\n8 pm "))
        assertEquals(60, SleepSettings.cleanText("😀".repeat(70)).codePointCount(0, 120))
    }

    @Test
    fun theBatteryMovesAwayFromTheText() {
        assertEquals(Corner.TOP_LEFT, SleepLayout.batteryCorner(Corner.BOTTOM_LEFT, TextPosition.BOTTOM, hasText = true))
        assertEquals(Corner.BOTTOM_RIGHT, SleepLayout.batteryCorner(Corner.TOP_RIGHT, TextPosition.TOP, hasText = true))
        assertEquals(Corner.BOTTOM_LEFT, SleepLayout.batteryCorner(Corner.BOTTOM_RIGHT, TextPosition.RIGHT, hasText = true))
        assertEquals(Corner.TOP_RIGHT, SleepLayout.batteryCorner(Corner.TOP_LEFT, TextPosition.LEFT, hasText = true))
        assertEquals(Corner.BOTTOM_LEFT, SleepLayout.batteryCorner(Corner.BOTTOM_LEFT, TextPosition.RIGHT, hasText = true))
        assertEquals(Corner.BOTTOM_LEFT, SleepLayout.batteryCorner(Corner.BOTTOM_LEFT, TextPosition.BOTTOM, hasText = false))
    }

    @Test
    fun layoutOnEachPanel() {
        for ((w, h) in listOf(1404 to 1872, 1264 to 1680, 480 to 800)) {
            val band = SleepLayout.bandHeight(h, 1)
            assertEquals(Math.round(h * 0.07).toInt(), band)
            assertEquals(Math.round(h * 0.10).toInt(), SleepLayout.bandHeight(h, 2))
            // A 2:3 cover fits above the band, centred, never under it.
            val c = SleepLayout.cover(w, h, band, 400, 600)
            assertTrue(c.bottom <= h - band)
            assertNear(w - c.right, c.left)
            val inset = SleepLayout.inset(w, h)
            for (pos in TextPosition.entries) {
                val p = SleepLayout.textPlate(w, h, pos, 500, 40, 19)
                assertTrue("$pos inside", p.left >= inset && p.top >= inset && p.right <= w - inset && p.bottom <= h - inset)
                when (pos) {
                    TextPosition.RIGHT -> assertEquals(w - inset, p.right)
                    TextPosition.LEFT -> assertEquals(inset, p.left)
                    TextPosition.TOP -> assertEquals(inset, p.top)
                    TextPosition.BOTTOM -> assertEquals(h - inset, p.bottom)
                }
            }
            for (corner in Corner.entries) {
                val b = SleepLayout.batteryPlate(w, h, corner, 120, 40, 19)
                assertEquals(corner.left, b.left == inset)
                assertEquals(corner.top, b.top == inset)
            }
        }
        assertEquals(28, SleepLayout.inset(1404, 1872))
        assertEquals(25, SleepLayout.inset(1264, 1680))
        assertEquals(38, SleepLayout.fontPx(304f)) // 9 pt at the M8C's ~300 dpi
    }

    private fun assertNear(a: Int, b: Int) = assertTrue("$a vs $b", Math.abs(a - b) <= 1)

    @Test
    fun textWrapsToTwoLinesAndIsCut() {
        val m: (String) -> Float = { it.length * 10f }
        assertEquals(listOf("If found, please", "return to the front"), SleepLayout.wrap("If found, please return to the front", 200, 2, m))
        val cut = SleepLayout.wrap("If found, please return to the front desk today", 200, 2, m)
        assertEquals(2, cut.size)
        assertTrue(cut[1].endsWith("…") && m(cut[1]) <= 200)
        assertEquals(listOf("Short"), SleepLayout.wrap("Short", 200, 1, m))
        val one = SleepLayout.wrap("A very long line on one edge only", 120, 1, m)
        assertEquals(1, one.size)
        assertTrue(one[0].endsWith("…") && m(one[0]) <= 120)
        assertEquals(emptyList<String>(), SleepLayout.wrap("", 100, 2, m))
    }

    private val every = SleepSettings.EVERY_SLEEP

    private fun sleep(pool: List<Long>, st: SleepRotation.State, r: java.util.Random, now: Long = 1L) =
        SleepRotation.decide(SleepMode.RECOMMENDED, every, now, pool, false, st, advance = true) { r.nextInt(it) }

    @Test
    fun everySleepIsRandomNeverTwiceInARowAndCapsAtThreeShows() {
        val pool = (1L..24L).toList()
        val r = java.util.Random(7)
        var st = SleepRotation.State()
        val seen = mutableListOf<Long>()
        // 72 sleeps: every cover exactly 3 times, never the same twice in a row.
        repeat(72) {
            val d = sleep(pool, st, r)
            assertTrue(d.poolId != st.shown)
            st = d.next
            seen += d.poolId!!
        }
        assertEquals(pool.toSet(), seen.toSet())
        assertTrue(seen.groupingBy { it }.eachCount().values.all { it == 3 })
        assertTrue("random, not the pool's order", seen.take(24) != pool)
        // Offline, nothing new: it keeps cycling the used-up ones, still never twice in a row.
        repeat(10) {
            val d = sleep(pool, st, r)
            assertTrue(d.poolId in pool && d.poolId != st.shown)
            st = d.next
        }
    }

    @Test
    fun everySleepRetiredCoversLeaveAndFreshOnesComeFirst() {
        val r = java.util.Random(3)
        // 1 and 2 used up; the plugin's top-up replaced 1 with 30 (2 still here: nothing else came).
        val st = SleepRotation.State(shown = 5, changedAt = 1, shows = mapOf(1L to 3, 2L to 3, 5L to 1))
        val pool = listOf(2L, 5L, 30L)
        repeat(20) {
            val d = sleep(pool, st, r)
            assertEquals(30L, d.poolId) // 2 is used up, 5 was just shown
            assertEquals(mapOf(2L to 3, 5L to 1, 30L to 1), d.next.shows) // 1 left the pool: its count goes
        }
        // One cover only: it is shown again rather than nothing.
        assertEquals(9L, sleep(listOf(9L), SleepRotation.State(9, 1, mapOf(9L to 3)), r).poolId)
        // A preview or a battery redraw keeps the current one and counts nothing.
        val keep = SleepRotation.decide(SleepMode.RECOMMENDED, every, 2, pool, false, st, advance = false)
        assertEquals(5L, keep.poolId)
        assertEquals(st, keep.next)
    }

    @Test
    fun everySleepCountsSurviveARebootAndReachThePlugin() {
        val st = SleepRotation.State(12, 99, mapOf(12L to 2, 40L to 1))
        assertEquals(st.shows, SleepRotation.decodeShows(SleepRotation.encodeShows(st.shows)))
        assertEquals(emptyMap<Long, Int>(), SleepRotation.decodeShows(null))
        assertEquals(mapOf(3L to 1), SleepRotation.decodeShows("3:1,x:2,4:0,:5"))
        val j = JSONObject(SleepRotation.stateJson(st))
        assertEquals(12L, j.getLong("shown"))
        assertEquals(2, j.getJSONObject("shows").getInt("12"))
        assertEquals("Every sleep", SleepSettings.hoursLabel(0))
        assertEquals("6 h", SleepSettings.hoursLabel(6))
        assertEquals(0, SleepSettings.merge(SleepSettings.DEFAULT) { if (it == "sleep_hours") "0" else null }.hours)
    }

    @Test
    fun sharpCoversKeepAsManyOfTheBatchAsFit() {
        // 24 covers of 1.5 MB under the 24 MB cap: the 16 used most recently stay.
        val cap = SharpCoversLogic.maxBytes(0)
        val stored = (1L..24L).map { SharpCoversLogic.Stored(it, 1_572_864L, usedAt = it) }
        val gone = SharpCoversLogic.prune(stored, stored.map { it.id }.toSet(), cap)
        assertEquals((1L..8L).toList(), gone.sorted())
        // Small covers: all 24 stay.
        assertTrue(SharpCoversLogic.prune(stored.map { it.copy(bytes = 400_000) }, (1L..24L).toSet(), cap).isEmpty())
    }

    @Test
    fun sinkAndHowItIsShown() {
        assertEquals(SleepSink.DREAM, SleepSystem.sink("haoqing"))
        assertEquals(SleepSink.PICTURE, SleepSystem.sink("onyx"))
        assertEquals(SleepSink.DREAM, SleepSystem.sink("generic"))
        val ours = "net.fledgewing.orbitcompanion/net.fledgewing.orbitcompanion.SleepDream"
        assertTrue(SleepSystem.oursChosen(ours, ours))
        assertFalse(SleepSystem.oursChosen(null, ours))
        assertFalse(SleepSystem.oursChosen("com.haoqing.wallpaper/.view.service.HaoqingDreamService", ours))
        assertEquals("Orbit screen saver ✓", SleepSystem.shownBy(SleepSink.DREAM, true, false))
        assertEquals("Set up ›", SleepSystem.shownBy(SleepSink.DREAM, false, true))
        assertEquals(listOf(ours, "1", "1"), SleepSystem.ourValues(ours))
    }

    /**
     * Setup's screen-saver row shows only when it helps on this reader now (M8C feedback,
     * 2026-11-24): a screen-saver reader, no permission, no Screen saver page, and what it shows
     * asleep doesn't match Sleep screen. The M8C (Orbit's screen saver chosen, Sleep screen on) hides it.
     */
    @Test
    fun screenSaverRowOnlyWhenItHelpsNow() {
        fun shown(mode: SleepMode = SleepMode.RECOMMENDED, sink: SleepSink = SleepSink.DREAM, granted: Boolean = false, ours: Boolean = false, page: Boolean = false) =
            SleepSetup.shown(mode, sink, granted, ours, page)
        assertTrue("on, the reader's own still chosen, no page", shown())
        assertTrue("off, Orbit's still chosen, no page", shown(mode = SleepMode.OFF, ours = true))
        assertFalse("the M8C: on and Orbit's chosen: works without it", shown(ours = true))
        assertFalse("off and the reader's own: nothing to change", shown(mode = SleepMode.OFF))
        assertFalse("granted: Orbit switches it itself", shown(granted = true))
        assertFalse("the reader's Screen saver page does it by hand", shown(page = true))
        assertFalse("a picture reader (Boox) has no screen saver to switch", shown(sink = SleepSink.PICTURE))
        assertTrue(SleepSetup.stateLine(SleepMode.CURRENT).contains("Orbit's cover doesn't show"))
        assertTrue(SleepSetup.how(SleepMode.CURRENT).contains("--sleep-screen on"))
        assertTrue(SleepSetup.how(SleepMode.OFF).contains("--sleep-screen off"))
        assertTrue("says why you'd grant it", SleepSetup.how(SleepMode.OFF).contains("Orbit switches the screen saver itself"))
        assertFalse("the loss line names what is lost, not a command", Checklist.LOSS.getValue(SleepSetup.ID).startsWith("turning"))
    }

    @Test
    fun oneWakeHeardTwiceCountsOnce() {
        assertTrue(SleepWake.due(0L, 5_000L))
        assertTrue(!SleepWake.due(5_000L, 5_000L + SleepWake.SAME_WAKE_MS - 1))
        assertTrue(SleepWake.due(5_000L, 5_000L + SleepWake.SAME_WAKE_MS))
        assertTrue("after a reboot", SleepWake.due(900_000L, 1_000L))
    }
}
