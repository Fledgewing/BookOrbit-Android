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
            val st = c.getJSONObject("state").let { SleepRotation.State(it.getLong("shown"), it.getLong("changed_at")) }
            val d = SleepRotation.decide(SleepMode.of(c.getString("mode"))!!, c.getInt("hours"), c.getLong("now"), pool, c.getBoolean("current"), st)
            val next = c.getJSONObject("next").let { SleepRotation.State(it.getLong("shown"), it.getLong("changed_at")) }
            assertEquals(c.getString("name"), c.getString("show"), d.show)
            assertEquals(c.getString("name"), next, d.next)
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
        assertTrue(SleepSetup.shown(SleepMode.RECOMMENDED, SleepSink.DREAM))
        assertFalse(SleepSetup.shown(SleepMode.OFF, SleepSink.DREAM))
        assertFalse(SleepSetup.shown(SleepMode.CURRENT, SleepSink.PICTURE))
    }
}
