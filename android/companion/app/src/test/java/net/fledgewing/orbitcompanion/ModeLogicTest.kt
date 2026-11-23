package net.fledgewing.orbitcompanion

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ModeLogicTest {
    @Test
    fun capsPerModeHelperAndPermission() {
        val full = ModeLogic.caps(OrbitMode.FULL, Helpers(), adminGranted = true)
        assertEquals(listOf("install", "setup", "stats", "relaunch", "home", "apps", "wifi", "sleep_sync", "clicker", "pin", "screen_off"), full)
        assertFalse("screen_off needs device admin granted", "screen_off" in ModeLogic.caps(OrbitMode.FULL, Helpers(), adminGranted = false))
        assertEquals("unset behaves as Full", full, ModeLogic.caps(null, Helpers(), adminGranted = true))
        assertEquals(ModeLogic.BASE, ModeLogic.caps(OrbitMode.ADDON, Helpers(), adminGranted = true))
        val helped = ModeLogic.caps(OrbitMode.ADDON, Helpers(wifi = true, sleepSync = true, screenOff = true, clicker = true, pin = true), adminGranted = true)
        assertTrue(helped.containsAll(listOf("wifi", "sleep_sync", "screen_off", "clicker", "pin")))
        assertFalse("Add-on is never Home", "home" in helped || "apps" in helped)
        assertFalse("screen off is a sub-option of sleep sync",
            "screen_off" in ModeLogic.caps(OrbitMode.ADDON, Helpers(screenOff = true), adminGranted = true))
        assertFalse("screen off needs admin",
            "screen_off" in ModeLogic.caps(OrbitMode.ADDON, Helpers(sleepSync = true, screenOff = true), adminGranted = false))
    }

    @Test
    fun statusFileIsValidJsonWithModeCapsAndPrompt() {
        val body = ModeLogic.statusFileBody("0.11.0", null, listOf("install", "setup"), "signed_in", "Signed in to BookOrbit\nSay \"hi\"")
        val text = ModeLogic.statusFile(body, 1234)
        assertEquals(
            "{\"proto\":\"1\",\"version\":\"0.11.0\",\"mode\":\"full\",\"caps\":[\"install\",\"setup\"]," +
                "\"setup_prompt\":{\"key\":\"signed_in\",\"rows\":[\"Signed in to BookOrbit\",\"Say \\\"hi\\\"\"]},\"written_at\":1234}",
            text,
        )
        assertTrue(ModeLogic.statusFileBody("v", OrbitMode.ADDON, emptyList(), "", "").endsWith("\"mode\":\"addon\",\"caps\":[],\"setup_prompt\":null"))
    }

    @Test
    fun modeKeysRoundTrip() {
        assertEquals(OrbitMode.ADDON, OrbitMode.of("addon"))
        assertEquals(null, OrbitMode.of(""))
        assertEquals(OrbitMode.FULL, ModeLogic.effective(null))
    }

    @Test
    fun reportKeepsOnlyAYesNoAndTheRecommendedState() {
        assertEquals("1", PluginReport.signedIn("1"))
        assertEquals("", PluginReport.signedIn("https://books.example"))
        assertEquals("partial", PluginReport.recommended("partial"))
        assertEquals("", PluginReport.recommended("bogus"))
        assertEquals(2, PluginReport.conflicts("2"))
        assertEquals(0, PluginReport.conflicts("-3"))
        assertEquals(setOf("signed_in", "recommended", "conflicts"), PluginReport.KEPT)
    }

    @Test
    fun theTwoNewRows() {
        assertTrue(PluginReport.signedInRow("1").done)
        assertFalse(PluginReport.signedInRow("0").done)
        assertTrue("unknown waits for KOReader, never a step", PluginReport.signedInRow("").pending)
        assertTrue(PluginReport.recommendedRow("applied", 0).done)
        assertTrue(PluginReport.recommendedRow("reviewed", 0).done)
        val partial = PluginReport.recommendedRow("partial", 2)
        assertFalse(partial.done)
        assertEquals("2 to review · tap to open them in KOReader", partial.detail)
        assertTrue(PluginReport.recommendedRow("none", 0).pending)
        assertEquals("signed_in", SetupAttention.idOf("Signed in to BookOrbit"))
        assertEquals("recommended", SetupAttention.idOf("Recommended settings"))
    }

    @Test
    fun aSignedOutReaderIsASetupStepAndARecommendedConflictToo() {
        val rows = listOf("signed_in" to PluginReport.signedInRow("0").done, "recommended" to PluginReport.recommendedRow("partial", 1).done)
        val r = SetupAttention.evaluate(rows, SetupAttention.State(), 1)
        assertEquals(listOf("signed_in", "recommended"), r.needed)
        val waiting = SetupAttention.evaluate(listOf("signed_in" to false), SetupAttention.State(), 1, pending = setOf("signed_in"))
        assertTrue("unknown is never needed", waiting.needed.isEmpty())
    }
}
