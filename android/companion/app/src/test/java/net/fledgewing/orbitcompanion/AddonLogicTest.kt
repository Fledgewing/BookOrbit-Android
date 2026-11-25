package net.fledgewing.orbitcompanion

import net.fledgewing.orbitcompanion.AddonLogic.Route
import net.fledgewing.orbitcompanion.AddonLogic.Step
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AddonLogicTest {
    private val full = ModeLogic.caps(OrbitMode.FULL, Helpers(), adminGranted = true)
    private val addon = ModeLogic.caps(OrbitMode.ADDON, Helpers(), adminGranted = true)

    @Test
    fun existingInstallsStayFullWithNoPrompt() {
        assertEquals(OrbitMode.FULL, AddonLogic.migrate(null, isHome = true, adminActive = false, accessibilityOn = false))
        assertEquals(OrbitMode.FULL, AddonLogic.migrate(null, isHome = false, adminActive = true, accessibilityOn = false))
        assertEquals(OrbitMode.FULL, AddonLogic.migrate(null, isHome = false, adminActive = false, accessibilityOn = true))
        assertNull("nothing Full-only: the choice shows", AddonLogic.migrate(null, isHome = false, adminActive = false, accessibilityOn = false))
        assertEquals("a choice made is kept", OrbitMode.ADDON, AddonLogic.migrate(OrbitMode.ADDON, isHome = true, adminActive = true, accessibilityOn = true))
    }

    @Test
    fun serviceOnlyInFullOrWithAHelper() {
        assertTrue(AddonLogic.needsService(null, Helpers()))
        assertTrue(AddonLogic.needsService(OrbitMode.FULL, Helpers()))
        assertFalse(AddonLogic.needsService(OrbitMode.ADDON, Helpers()))
        for (h in listOf(Helpers(wifi = true), Helpers(sleepSync = true), Helpers(clicker = true), Helpers(pin = true))) {
            assertTrue("$h", AddonLogic.needsService(OrbitMode.ADDON, h))
        }
        assertFalse("screen off alone is a sub-option", AddonLogic.needsService(OrbitMode.ADDON, Helpers(screenOff = true)))
    }

    @Test
    fun receiverRoutingPerActionAndCaps() {
        val all = listOf(Contract.NET_UP, Contract.NET_DONE, Contract.WIFI_OFF, Contract.SLEEP_NOW, Contract.RELAUNCH, Contract.SETTINGS, Contract.STATS)
        for (a in all) assertEquals("Full: $a as today", Route.SERVICE, AddonLogic.route(a, full, service = true))
        for (a in listOf(Contract.NET_UP, Contract.NET_DONE, Contract.WIFI_OFF, Contract.SLEEP_NOW, Contract.RELAUNCH)) {
            assertEquals("Add-on, no helper: $a dropped", Route.DROP, AddonLogic.route(a, addon, service = false))
        }
        assertEquals(Route.RECORD, AddonLogic.route(Contract.STATS, addon, service = false))
        assertEquals(Route.RECORD, AddonLogic.route(Contract.SETTINGS, addon, service = false))
        assertEquals(Route.RECORD, AddonLogic.route(Contract.SETUP_LATER, full, service = true))
        assertEquals(Route.RECORD, AddonLogic.route(Contract.REPORT, addon, service = false))
        val sleepOnly = ModeLogic.caps(OrbitMode.ADDON, Helpers(sleepSync = true), adminGranted = false)
        assertEquals("sleep sync: the wake lock", Route.SERVICE, AddonLogic.route(Contract.NET_UP, sleepOnly, service = true))
        assertEquals(Route.DROP, AddonLogic.route(Contract.WIFI_OFF, sleepOnly, service = true))
        assertEquals(Route.DROP, AddonLogic.route(Contract.SLEEP_NOW, sleepOnly, service = true))
        assertEquals("Add-on restarts through the relaunch activity", Route.DROP, AddonLogic.route(Contract.RELAUNCH, sleepOnly, service = true))
    }

    @Test
    fun addonCountsOnlyTheFourRequiredRows() {
        val rows = listOf("koreader" to true, "plugin" to true, "patch" to false, "signed_in" to true, "install_updates" to false,
            "notifications" to false, "battery:Orbit" to false, "admin" to false, "home" to false, "clicker" to false, "recommended" to true)
        val r = SetupAttention.evaluate(AddonLogic.attentionRows(OrbitMode.ADDON, rows), SetupAttention.State(), 1)
        assertEquals(listOf("patch"), r.needed)
        val f = SetupAttention.evaluate(AddonLogic.attentionRows(OrbitMode.FULL, rows), SetupAttention.State(), 1)
        assertTrue(f.needed.containsAll(listOf("patch", "install_updates", "home", "admin")))
        // Declining or later revoking an optional permission never makes a step or a prompt.
        val before = SetupAttention.evaluate(AddonLogic.attentionRows(OrbitMode.ADDON, rows.map { if (it.first == "clicker") it.first to true else it }), SetupAttention.State(), 1)
        val after = SetupAttention.evaluate(AddonLogic.attentionRows(OrbitMode.ADDON, rows), before.next, 1)
        assertTrue(after.regressed.isEmpty())
        assertEquals("Add-on: four required rows", listOf("koreader", "plugin", "patch", "signed_in"), AddonLogic.REQUIRED)
    }

    @Test
    fun optionalRowsSayWhatIsLost() {
        val o = AddonLogic.optional("notifications")!!
        assertTrue(AddonLogic.optionalLine(o, AddonLogic.optState(granted = false, asked = false)).startsWith("Without it: you see updates"))
        // Allowed once and now off still says what is lost (companion-checklist §3.7).
        assertEquals(AddonLogic.optionalLine(o, AddonLogic.OptState.NEVER), AddonLogic.optionalLine(o, AddonLogic.optState(granted = false, asked = true)))
        assertTrue(AddonLogic.optionalLine(o, AddonLogic.optState(granted = true, asked = true)).startsWith("On: "))
        assertEquals("no battery, admin, Home or Wi-Fi test rows without helpers",
            listOf("install_updates", "notifications", "wifi_switching", "sleep_sync"), AddonLogic.optionalIds(Helpers(), false, false, false))
        assertEquals(listOf("install_updates", "notifications", "clicker", "keyboard", "wifi_switching", "sleep_sync", "admin", "battery"),
            AddonLogic.optionalIds(Helpers(sleepSync = true), clickerMapped = true, pinSet = false, sendKeyMapped = true))
        assertEquals(listOf("install_updates", "notifications", "wifi_switching", "sleep_sync", "battery"), AddonLogic.optionalIds(Helpers(wifi = true), false, false, false))
    }

    @Test
    fun switchToAddonAndBackAndTwiceIsANoOp() {
        assertEquals(listOf(Step.REFUSE_NO_HOME), AddonLogic.toAddon(OrbitMode.FULL, homeEnabled = true, otherHome = false, keep = Helpers(), adminActive = true, accessibilityOn = true, serviceRunning = true))
        val plan = AddonLogic.toAddon(OrbitMode.FULL, homeEnabled = true, otherHome = true, keep = Helpers(), adminActive = true, accessibilityOn = true, serviceRunning = true)
        assertEquals(listOf(Step.SET_MODE, Step.DISABLE_HOME, Step.REMOVE_ADMIN, Step.STOP_ACCESSIBILITY, Step.STOP_WIFI_TIMER, Step.STOP_SERVICE, Step.WRITE_STATUS), plan)
        val keepPin = AddonLogic.toAddon(OrbitMode.FULL, true, true, Helpers(pin = true), adminActive = true, accessibilityOn = true, serviceRunning = true)
        assertFalse("the PIN kept keeps accessibility and the service", Step.STOP_ACCESSIBILITY in keepPin || Step.STOP_SERVICE in keepPin)
        val again = AddonLogic.toAddon(OrbitMode.ADDON, homeEnabled = false, otherHome = true, keep = Helpers(wifi = true), adminActive = false, accessibilityOn = false, serviceRunning = true)
        assertTrue("finished: nothing to do", again.isEmpty())
        assertEquals(listOf(Step.SET_MODE, Step.ENABLE_HOME, Step.START_SERVICE, Step.WRITE_STATUS, Step.OPEN_SETUP),
            AddonLogic.toFull(OrbitMode.ADDON, homeEnabled = false, serviceRunning = false))
        assertTrue(AddonLogic.toFull(OrbitMode.FULL, homeEnabled = true, serviceRunning = true).isEmpty())
        assertTrue("a first-run Add-on choice needs no other Home: BookSync was never Home",
            AddonLogic.toAddon(null, homeEnabled = false, otherHome = false, keep = Helpers(), adminActive = false, accessibilityOn = false, serviceRunning = false).first() == Step.SET_MODE)
    }
}
