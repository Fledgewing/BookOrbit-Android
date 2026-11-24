package net.fledgewing.orbitcompanion

import android.app.Application
import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** Setup's "Screen mode for Orbit" (companion-checklist.md §3.3): visibility, the two ways to finish, the loss line. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ScreenModeSetupTest {
    private lateinit var app: Application

    @Before
    fun setUp() {
        app = RuntimeEnvironment.getApplication()
        app.getSharedPreferences("orbit", Context.MODE_PRIVATE).edit().clear().commit()
        app.getSharedPreferences("orbit_sleep", Context.MODE_PRIVATE).edit().clear().commit()
    }

    private fun sleepOn() = SleepScreen.save(app, SleepScreen.settings(app).copy(mode = SleepMode.CURRENT), "test", shared = false)

    @Test
    fun shownOnlyWhileTheSleepScreenIsOrbits() {
        assertNull(ScreenModeSetup.row(SleepMode.OFF, ScreenModeSetup.Way.NONE))
        SleepMode.entries.filter { it != SleepMode.OFF }.forEach { assertNotNull(it.key, ScreenModeSetup.row(it, ScreenModeSetup.Way.NONE)) }
        assertNull(ScreenModeSetup.check(app))
        sleepOn()
        assertNotNull(ScreenModeSetup.check(app))
    }

    @Test
    fun leftAloneItIsOptionalNeverCountedAndSaysWhatIsLost() {
        val r = ScreenModeSetup.row(SleepMode.RECOMMENDED, ScreenModeSetup.Way.NONE)!!
        assertTrue(r.optional)
        assertEquals("How", r.verb)
        assertEquals(ScreenModeSetup.HINT, r.stateLine)
        val item = Checklist.items(listOf(r)).single()
        assertEquals(Checklist.State.OFF, item.state)
        assertEquals(Checklist.Group.OPTIONAL, item.group)
        assertEquals("Without it: the sleep screen may show ghosting from the last page.", item.loss)
        assertEquals(0, Checklist.count(listOf(item)))
        assertTrue(Checklist.needsYou(listOf(item)).isEmpty())
        assertEquals(Checklist.Summary.AllSet(optionalBelow = true), Checklist.summary(listOf(item), firstRun = true))
        assertNull(NewIn.SINCE[ScreenModeSetup.ID]) // no badge
        // No brand names in what the user reads.
        listOf(ScreenModeSetup.HINT, ScreenModeSetup.HOW, SleepFlash.ABOUT).forEach { t ->
            listOf("Boox", "Onyx", "Meebook", "Haoqing", "Kindle", "Kobo").forEach { b -> assertFalse("$b in: $t", t.contains(b, ignoreCase = true)) }
        }
    }

    @Test
    fun iveSetItFinishesTheStepAndIsKept() {
        sleepOn()
        assertFalse(ScreenModeSetup.check(app)!!.done)
        ScreenModeSetup.markSet(app)
        assertTrue(Prefs(app).screenModeDone)
        val c = ScreenModeSetup.check(app)!!
        assertTrue(c.done)
        assertNull(c.action)
        assertEquals("On: ${Checklist.ON.getValue(ScreenModeSetup.ID)}", c.detail)
        assertFalse(SleepScreen.settings(app).flash) // the flash stays off
    }

    @Test
    fun useAClearingFlashTurnsItOnAndFinishesTheStep() {
        sleepOn()
        ScreenModeSetup.useFlash(app)
        assertTrue(SleepScreen.settings(app).flash)
        assertFalse(Prefs(app).screenModeDone)
        val c = ScreenModeSetup.check(app)!!
        assertTrue(c.done)
        assertEquals(ScreenModeSetup.FLASH_ON, c.detail)
        // Turning the flash off again (Sleep screen page) reopens the optional step.
        SleepScreen.save(app, SleepScreen.settings(app).copy(flash = false), "test", shared = false)
        assertFalse(ScreenModeSetup.check(app)!!.done)
    }
}
