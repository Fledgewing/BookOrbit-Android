package net.fledgewing.orbitcompanion

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Per-app actions and the just-in-time keyboard switch (docs/BTKEYS-DESIGN.md "Send key"). */
class KeysLogicTest {
    private val readest = "com.bilingify.readest"
    private val button = ClickerButton(
        87, 163, "Media next",
        mapOf(PressKind.PRESS to ClickAction.NEXT, PressKind.HOLD to ClickAction.SLEEP),
        appActions = mapOf(readest to mapOf(PressKind.PRESS to ClickAction.SEND_VOL_DOWN)),
    )
    private val clicker = Clicker("BT-Remote", 0x05ac, 0x022c, listOf(button))
    private val map = KeyMap(listOf(clicker))

    @Test
    fun anAppOverrideWinsAndOtherKindsKeepTheDefault() {
        assertEquals(mapOf(PressKind.PRESS to ClickAction.SEND_VOL_DOWN, PressKind.HOLD to ClickAction.SLEEP), map.lookup("BT-Remote", 0x05ac, 0x022c, 87, readest))
        assertEquals(mapOf(PressKind.PRESS to ClickAction.NEXT, PressKind.HOLD to ClickAction.SLEEP), map.lookup("BT-Remote", 0x05ac, 0x022c, 87, "com.other"))
        assertEquals(ClickAction.NEXT, map.lookup("BT-Remote", 0x05ac, 0x022c, 87, null)!![PressKind.PRESS])
    }

    @Test
    fun overridesAreSetClearedAndSaved() {
        val id = clicker.id
        val m = map.setAppAction(id, 87, "com.moon", PressKind.HOLD, ClickAction.BACK)
        assertEquals(ClickAction.BACK, m.lookup("BT-Remote", 0x05ac, 0x022c, 87, "com.moon")!![PressKind.HOLD])
        val back = KeyMap.fromJson(m.toJson().toString())
        assertEquals(m, back)
        val cleared = back.setAppAction(id, 87, readest, PressKind.PRESS, null)
        assertFalse("an empty override is dropped", cleared.clicker(id)!!.button(87)!!.appActions.containsKey(readest))
        val noHold = m.setAction(id, 87, PressKind.HOLD, null)
        assertFalse("stop using hold drops its overrides", noHold.clicker(id)!!.button(87)!!.appActions.containsKey("com.moon"))
    }

    @Test
    fun koreaderGetsItsOverrideAndSentKeysAsPageTurns() {
        assertEquals("next", map.forPatch().getJSONObject("87").getString("press"))
        val m = map.setAppAction(clicker.id, 87, HomeApp.KOREADER_PKG, PressKind.PRESS, ClickAction.SEND_VOL_UP)
        assertEquals("prev", m.forPatch().getJSONObject("87").getString("press"))
        assertEquals(ClickAction.NEXT, ClickAction.SEND_SPACE.inKoreader)
        assertEquals(ClickAction.HOME, ClickAction.HOME.inKoreader)
    }

    @Test
    fun sendKeyActionsNeedTheKeyboard() {
        assertTrue(map.sendsKeys)
        assertFalse(KeyMap(listOf(clicker.copy(buttons = listOf(button.copy(appActions = emptyMap()))))).sendsKeys)
        assertEquals(25, ClickAction.SEND_VOL_DOWN.sendKeycode)
        assertEquals(93, ClickAction.SEND_PAGE_DOWN.sendKeycode)
        assertNull(ClickAction.NEXT.sendKeycode)
        assertEquals(ClickAction.entries.toSet(), (ClickAction.MAIN + ClickAction.MORE_KEYS).toSet())
    }

    @Test
    fun keyboardIds() {
        val pkg = "net.fledgewing.orbitcompanion"
        val cls = "$pkg.OrbitKeysIme"
        assertTrue(ImeIds.enabledIn("com.a/.Ime:$pkg/.OrbitKeysIme;123", pkg, cls))
        assertTrue(ImeIds.enabledIn("$pkg/$cls", pkg, cls))
        assertFalse(ImeIds.enabledIn("com.a/.Ime", pkg, cls))
        assertFalse(ImeIds.enabledIn(null, pkg, cls))
        assertTrue(ImeIds.isCurrent("$pkg/.OrbitKeysIme", pkg, cls))
        assertFalse(ImeIds.isCurrent("com.a/.Ime", pkg, cls))
    }

    @Test
    fun textFieldsAreToldByClassAndInputType() {
        assertTrue(Keyboard.isTextField("android.widget.EditText", false))
        assertTrue(Keyboard.isTextField("androidx.appcompat.widget.AppCompatEditText", false))
        assertTrue(Keyboard.isTextField("android.view.View", true))
        assertFalse(Keyboard.isTextField("android.webkit.WebView", false))
        assertFalse(Keyboard.isTextField(null, false))
        assertTrue(Keyboard.takesText(android.text.InputType.TYPE_CLASS_TEXT))
        assertFalse(Keyboard.takesText(android.text.InputType.TYPE_NULL))
    }

    private val prev = "com.a/.Ime"

    @Test
    fun aPressSwitchesSendsWhenBoundAndRestores() {
        val s = ImeSwitch()
        val o = s.press(0, 25, prev, orbitCurrent = false, keepActive = false, editorFocused = false)
        assertTrue(o.switchToOrbit)
        assertEquals(ImeSwitch.Phase.SWITCHING, s.phase)
        val b = s.bound(120, textEditor = false)
        assertEquals(listOf(25), b.send)
        assertEquals(prev, b.restore)
        assertTrue(b.log!!.contains("120 ms"))
        assertEquals(ImeSwitch.Phase.RESTORING, s.phase)
        val r = s.restored(200, prev)
        assertFalse(r.switchToOrbit)
        assertEquals(ImeSwitch.Phase.IDLE, s.phase)
        assertEquals(0, s.failures)
    }

    @Test
    fun pressesDuringTheSwitchAreQueuedAndSentTogether() {
        val s = ImeSwitch()
        s.press(0, 25, prev, false, false, false)
        val q = s.press(50, 25, prev, false, false, false)
        assertFalse("no second switch", q.switchToOrbit)
        s.press(80, 93, prev, false, false, false)
        assertEquals(listOf(25, 25, 93), s.bound(150, false).send)
    }

    @Test
    fun aPressWhileRestoringSwitchesAgainOnceRestored() {
        val s = ImeSwitch()
        s.press(0, 25, prev, false, false, false)
        s.bound(100, false)
        s.press(120, 24, "orbit", false, false, false)
        val r = s.restored(160, prev)
        assertTrue(r.switchToOrbit)
        assertEquals(listOf(24), s.bound(260, false).send)
    }

    @Test
    fun noBindWithin700msFailsDropsTheQueueAndRestores() {
        val s = ImeSwitch()
        s.press(0, 25, prev, false, false, false)
        assertEquals(700L, s.nextDue())
        assertNull(s.tick(699).restore)
        val t = s.tick(700)
        assertTrue(t.failed)
        assertEquals(prev, t.restore)
        assertEquals(1, s.failures)
        assertEquals(ImeSwitch.Phase.IDLE, s.phase)
        assertTrue(s.queued.isEmpty())
        assertTrue("a late bind does nothing", s.bound(900, false).send.isEmpty())
    }

    @Test
    fun aFocusedTextFieldSkipsThePress() {
        val s = ImeSwitch()
        val o = s.press(0, 25, prev, false, false, editorFocused = true)
        assertFalse(o.switchToOrbit)
        assertTrue(o.log!!.contains("skipped"))
        assertEquals(ImeSwitch.Phase.IDLE, s.phase)
        // Not seen by the service: the keyboard binds to a text editor, sends nothing, restores.
        s.press(10, 25, prev, false, false, false)
        val b = s.bound(100, textEditor = true)
        assertTrue(b.send.isEmpty())
        assertEquals(prev, b.restore)
    }

    @Test
    fun keptActiveSendsAtOnce() {
        val s = ImeSwitch()
        val o = s.press(0, 93, "orbit", orbitCurrent = true, keepActive = true, editorFocused = false)
        assertEquals(listOf(93), o.send)
        assertFalse(o.switchToOrbit)
        assertNull(o.restore)
        assertEquals(ImeSwitch.Phase.IDLE, s.phase)
    }
}
