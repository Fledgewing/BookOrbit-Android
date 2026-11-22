package net.fledgewing.orbitcompanion

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ClickerLogicTest {
    private val remote = Clicker(
        "BT-Remote", 0x05ac, 0x022c,
        listOf(
            ClickerButton(25, 114, "Vol −", mapOf(PressKind.PRESS to ClickAction.NEXT), builtinToo = true),
            ClickerButton(87, 163, "Media next", mapOf(PressKind.PRESS to ClickAction.NEXT, PressKind.HOLD to ClickAction.SLEEP)),
            ClickerButton(66, 28, "Enter", mapOf(PressKind.PRESS to ClickAction.LIGHT, PressKind.DOUBLE to ClickAction.HOME)),
            ClickerButton(62, 57, "Space", mapOf(PressKind.PRESS to ClickAction.NOTHING)),
        ),
    )
    private val map = KeyMap(listOf(remote))

    @Test
    fun keysMapToActionsOnlyForTheCapturedClicker() {
        assertEquals(mapOf(PressKind.PRESS to ClickAction.NEXT, PressKind.HOLD to ClickAction.SLEEP), map.lookup("BT-Remote", 0x05ac, 0x022c, 87))
        assertNull("another device with the same key", map.lookup("gpio-keys", 0, 0, 87))
        assertNull("unmapped key", map.lookup("BT-Remote", 0x05ac, 0x022c, 19))
        assertNull("'nothing' lets the key through", map.lookup("BT-Remote", 0x05ac, 0x022c, 62))
        assertTrue(map.mapped)
        assertFalse(KeyMap(listOf(remote.copy(buttons = listOf(remote.buttons[3])))).mapped)
    }

    @Test
    fun patchGetsKeycodesWithoutBuiltinOnesOrNothing() {
        val p = map.forPatch()
        assertEquals(setOf("87", "66"), p.keys().asSequence().toSet())
        assertEquals("next", p.getJSONObject("87").getString("press"))
        assertEquals("sync_sleep", p.getJSONObject("87").getString("hold"))
        assertEquals("home", p.getJSONObject("66").getString("double"))
    }

    @Test
    fun mapSurvivesJsonAndEdits() {
        var m = map.setZone("com.bilingify.readest", ClickAction.NEXT, Zone.BOTTOM_HALF).copy(showTaps = true)
        m = KeyMap.fromJson(m.toJson().toString())
        assertEquals(map.clickers, m.clickers)
        assertTrue(m.showTaps)
        assertEquals(Zone.BOTTOM_HALF, m.zoneFor("com.bilingify.readest", ClickAction.NEXT, emptyMap()))
        m = m.setAction(remote.id, 87, PressKind.HOLD, null)
        assertEquals(mapOf(PressKind.PRESS to ClickAction.NEXT), m.clicker(remote.id)!!.button(87)!!.actions)
        m = m.removeButton(remote.id, 87).forget("nope")
        assertNull(m.clicker(remote.id)!!.button(87))
        assertEquals(KeyMap(), KeyMap.fromJson("garbage"))
    }

    @Test
    fun zonesOverrideThenVendorThenThirds() {
        val vendor = mapOf("com.haoqing.app.hqreader" to mapOf(ClickAction.NEXT to Zone.BOTTOM_HALF))
        assertEquals(Zone.BOTTOM_HALF, map.zoneFor("com.haoqing.app.hqreader", ClickAction.NEXT, vendor))
        assertEquals(Zone.LEFT_THIRD, map.zoneFor("com.haoqing.app.hqreader", ClickAction.PREV, vendor))
        assertEquals(Zone.RIGHT_THIRD, map.zoneFor("x.y", ClickAction.NEXT, vendor))
        val m = map.setZone("com.haoqing.app.hqreader", ClickAction.NEXT, Zone.NONE)
        assertEquals(Zone.NONE, m.zoneFor("com.haoqing.app.hqreader", ClickAction.NEXT, vendor))
    }

    @Test
    fun zoneToTap() {
        val r = Zones.gesture(Zone.RIGHT_THIRD, 1404, 1872)!!
        assertTrue(r.isTap)
        assertEquals(1170f, r.x1, 0.01f)
        assertEquals(936f, r.y1, 0.01f)
        assertEquals(234f, Zones.gesture(Zone.LEFT_THIRD, 1404, 1872)!!.x1, 0.01f)
        assertEquals(1404f, Zones.gesture(Zone.BOTTOM_HALF, 1404, 1872)!!.y1, 0.01f)
        assertEquals(468f, Zones.gesture(Zone.TOP_HALF, 1404, 1872)!!.y1, 0.01f)
        val s = Zones.gesture(Zone.SWIPE_LEFT, 1000, 800)!!
        assertFalse(s.isTap)
        assertTrue("swipe left moves left", s.x2 < s.x1)
        assertEquals(Zones.SWIPE_MS, s.durationMs)
        assertNull(Zones.gesture(Zone.NONE, 1000, 800))
        // Landscape: the same rule on the rotated size.
        assertEquals(1560f, Zones.gesture(Zone.RIGHT_THIRD, 1872, 1404)!!.x1, 0.01f)
    }

    @Test
    fun plainPressFiresOnKeyDownWithNoDelay() {
        val t = PressTimer()
        assertEquals(PressKind.PRESS, t.down(0, setOf(PressKind.PRESS)))
        assertNull("key repeat while held", t.down(30, setOf(PressKind.PRESS)))
        assertNull(t.up(80))
        assertNull(t.nextDue())
    }

    @Test
    fun holdFiresAtSixTenthsWhileDown() {
        val k = setOf(PressKind.PRESS, PressKind.HOLD)
        val t = PressTimer()
        assertNull(t.down(1000, k))
        assertEquals(1600L, t.nextDue())
        assertNull(t.tick(1599))
        assertEquals(PressKind.HOLD, t.tick(1600))
        assertNull("release after a hold", t.up(2000))
        val q = PressTimer()
        q.down(0, k)
        assertEquals("short press", PressKind.PRESS, q.up(200))
        assertNull(q.nextDue())
    }

    @Test
    fun doubleWithinTheWindowElseSingleAfterIt() {
        val k = setOf(PressKind.PRESS, PressKind.DOUBLE)
        val t = PressTimer()
        assertNull(t.down(0, k))
        assertNull(t.up(100))
        assertEquals(450L, t.nextDue())
        assertEquals(PressKind.DOUBLE, t.down(300, k))
        assertNull(t.up(380))
        assertNull(t.tick(1000))
        val s = PressTimer()
        s.down(0, k)
        s.up(100)
        assertNull(s.tick(449))
        assertEquals(PressKind.PRESS, s.tick(450))
        assertNull(s.nextDue())
        val late = PressTimer()
        late.down(0, k)
        late.up(100)
        assertEquals("tick missed: the first press still counts", PressKind.PRESS, late.down(900, k))
    }

    @Test
    fun setupRowStates() {
        assertEquals(ClickerRowState.HIDDEN, ClickerRow.state(mapped = false, enabledInSettings = false, connected = false))
        assertEquals(ClickerRowState.OFF, ClickerRow.state(true, false, false))
        assertEquals(ClickerRowState.NOT_CONNECTED, ClickerRow.state(true, true, false))
        assertEquals(ClickerRowState.DONE, ClickerRow.state(true, true, true))
        val pkg = "net.fledgewing.orbitcompanion"
        val setting = "io.github.sds100.keymapper/io.github.sds100.keymapper.system.accessibility.MyAccessibilityService:$pkg/.ClickerService"
        assertTrue(ClickerRow.enabledIn(setting, pkg, "$pkg.ClickerService"))
        assertTrue(ClickerRow.enabledIn("$pkg/$pkg.ClickerService", pkg, "$pkg.ClickerService"))
        assertFalse(ClickerRow.enabledIn("io.github.sds100.keymapper/x", pkg, "$pkg.ClickerService"))
        assertFalse(ClickerRow.enabledIn(null, pkg, "$pkg.ClickerService"))
        assertEquals(listOf("io.github.sds100.keymapper"), ClickerRow.others(setting, pkg))
    }

    @Test
    fun regressionWhenTheServiceIsTurnedOff() {
        // Done, then a freeze turns it off: "Setup needs you" fires again.
        var r = SetupAttention.evaluate(listOf("clicker" to true), SetupAttention.State(), 400)
        assertFalse(r.show)
        r = SetupAttention.evaluate(listOf("clicker" to false), r.next, 400)
        assertTrue(r.show)
        assertEquals(setOf("clicker"), r.regressed)
        assertEquals("clicker", SetupAttention.idOf("Clicker buttons (accessibility)"))
    }
}
