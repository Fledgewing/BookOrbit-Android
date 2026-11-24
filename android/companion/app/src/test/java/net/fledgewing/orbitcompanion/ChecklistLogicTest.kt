package net.fledgewing.orbitcompanion

import net.fledgewing.orbitcompanion.Checklist.Group
import net.fledgewing.orbitcompanion.Checklist.Row
import net.fledgewing.orbitcompanion.Checklist.State
import net.fledgewing.orbitcompanion.Checklist.Summary
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The Setup checklist's rules alone (docs/design/companion-checklist.md §6). */
class ChecklistLogicTest {
    private fun full(vararg open: String, pending: Set<String> = emptySet()): List<Row> = listOf(
        Row("koreader", "KOReader", "koreader" !in open, short = "KOReader 2025.10", verb = "Install"),
        Row("plugin", "BookOrbit plugin", "plugin" !in open, verb = "Install"),
        Row("patch", "Orbit plugin", "patch" !in open, short = "Orbit plugin 0.11.2", pinFree = true, verb = "Update", pending = "patch" in pending),
        Row("signed_in", "BookOrbit account", "signed_in" !in open, short = "Signed in", verb = if ("signed_in" in pending) null else "Sign in", pending = "signed_in" in pending),
        Row("recommended", "Recommended settings", "recommended" !in open, short = "recommended settings on", verb = "Review"),
        Row("home", "Home app", "home" !in open, verb = "Set"),
        Row("install_updates", "Install apps", "install_updates" !in open, verb = "Allow"),
        Row("notifications", "Notifications", "notifications" !in open, verb = "Allow"),
        Row("admin", "Screen lock", "admin" !in open, verb = "Allow"),
        Row("keyboard", "Orbit keyboard", "keyboard" !in open, verb = "Turn on"),
        Row("tailscale", "Tailscale", "tailscale" !in open, short = "Tailscale connected", verb = "Connect"),
        Row("wifi_test", "Wi-Fi off/on test", true, short = "Wi-Fi test passed 17:02", info = true, verb = "Run"),
    )

    private fun items(rows: List<Row>, ignored: Set<String> = emptySet(), lastDone: Set<String> = emptySet()) =
        Checklist.items(rows, ignored, lastDone)

    // Summary

    @Test
    fun allSetWithNothingOptional() {
        val s = Checklist.summary(items(full()))
        assertEquals(Summary.AllSet(optionalBelow = false), s)
        assertEquals("All set", Checklist.summaryTitle(s))
        assertEquals("Everything this reader needs is done.", Checklist.summaryLine(s))
        assertNull(Checklist.summaryButton(s))
    }

    @Test
    fun allSetSaysOptionalItemsBelowWhenSomethingIsOffOrSkipped() {
        val skipped = Checklist.summary(items(full("keyboard"), ignored = setOf("keyboard")))
        assertEquals(Summary.AllSet(optionalBelow = true), skipped)
        assertEquals("Everything this reader needs is done. Optional items below.", Checklist.summaryLine(skipped))
        val optional = Checklist.summary(items(full() + Row("screen_saver", "Screen saver from Orbit", false, optional = true, verb = "Show how")))
        assertEquals(Summary.AllSet(optionalBelow = true), optional)
    }

    @Test
    fun thingsNeedYouWithFixNext() {
        val s = Checklist.summary(items(full("signed_in", "notifications")))
        assertEquals(Summary.NeedsYou(2), s)
        assertEquals("2 things need you", Checklist.summaryTitle(s))
        assertEquals("Fix next", Checklist.summaryButton(s))
        assertEquals("1 thing needs you", Checklist.summaryTitle(Checklist.summary(items(full("home")))))
    }

    @Test
    fun checkingOnlyWhenNothingNeedsYou() {
        assertEquals(Summary.Checking, Checklist.summary(items(full(pending = setOf("signed_in")))))
        assertEquals("Waiting for KOReader to report. Open KOReader once.", Checklist.summaryLine(Summary.Checking))
        assertEquals(Summary.NeedsYou(1), Checklist.summary(items(full("home", pending = setOf("signed_in")))))
    }

    @Test
    fun restartPendingWithAButtonIsReadyNowNotChecking() {
        val its = items(full(pending = setOf("patch")).map { if (it.id == "patch") it.copy(verb = "Restart KOReader") else it })
        assertEquals(Summary.AllSet(false), Checklist.summary(its))
        assertEquals(listOf("patch"), Checklist.page(its).ready.map { it.id })
    }

    @Test
    fun firstRunOffersStartWithNumberedSteps() {
        val its = items(full("koreader", "plugin", "home"))
        val p = Checklist.page(its, firstRun = true)
        assertEquals(Summary.FirstRun(3), p.summary)
        assertEquals("Start", Checklist.summaryButton(p.summary))
        assertTrue(p.numbered)
        // Nothing left: never "Let's set up" again.
        assertEquals(Summary.AllSet(false), Checklist.summary(items(full()), firstRun = true))
    }

    @Test
    fun walkingNamesTheStepWithStop() {
        val s = Checklist.summary(items(full("notifications")), walk = Triple(3, 8, "Notifications"))
        assertEquals("Step 3 of 8: Notifications", Checklist.summaryTitle(s))
        assertEquals("Stop", Checklist.summaryButton(s))
    }

    // Needs you, states and counts

    @Test
    fun needsYouOrderPutsWhatBlocksMostFirst() {
        val its = items(full("tailscale", "notifications", "signed_in", "install_updates", "koreader"))
        assertEquals(listOf("install_updates", "koreader", "signed_in", "notifications", "tailscale"), Checklist.needsYou(its).map { it.id })
    }

    @Test
    fun requiredNotDoneSaysUntilThenAndRegressionsSayStopped() {
        val i = items(full("signed_in"), lastDone = setOf("signed_in")).single { it.id == "signed_in" }
        assertEquals(State.NEEDS_YOU, i.state)
        assertEquals("Until then: nothing syncs.", i.loss)
        assertTrue(i.regressed)
        assertFalse(items(full("signed_in")).single { it.id == "signed_in" }.regressed)
    }

    @Test
    fun skippedStepIsOffInItsGroupNeverCounted() {
        val its = items(full("keyboard"), ignored = setOf("keyboard"))
        val k = its.single { it.id == "keyboard" }
        assertEquals(State.OFF, k.state)
        assertTrue(k.skipped)
        assertEquals(Group.PERMISSIONS, k.group)
        assertTrue(k.loss!!.startsWith("Without it: "))
        assertEquals(0, Checklist.count(its))
        assertTrue(Checklist.needsYou(its).isEmpty())
    }

    @Test
    fun setByTheReaderCountsAsDone() {
        val its = items(full() + Row("battery", "Battery", true, setByReader = true))
        assertEquals(State.SET_BY_READER, its.last().state)
        assertEquals(Summary.AllSet(false), Checklist.summary(its))
        assertNull(its.last().loss)
    }

    @Test
    fun checkingNeverCounted() {
        val its = items(full(pending = setOf("signed_in")))
        assertEquals(State.CHECKING, its.single { it.id == "signed_in" }.state)
        assertEquals(0, Checklist.count(its))
    }

    @Test
    fun countsPerMode() {
        // Full: every open step counts.
        assertEquals(3, Checklist.count(items(full("home", "notifications", "signed_in"))))
        // Add-on: only the four required rows; its permissions are optional, the rest info.
        val addon = listOf(
            Row("koreader", "KOReader", true),
            Row("plugin", "BookOrbit plugin", true),
            Row("patch", "Orbit plugin", true),
            Row("signed_in", "BookOrbit account", false, verb = "Sign in"),
            Row("recommended", "Recommended settings", false, info = true, verb = "Review"),
            Row("tailscale", "Tailscale", false, info = true),
            Row("notifications", "Notifications", false, optional = true, verb = "Allow"),
            Row("battery", "Battery", false, optional = true, verb = "Allow"),
            Row("sleep_sync", "Sleep sync", true, stateLine = "On: syncs finish as the reader sleeps.", optional = true),
        )
        val its = items(addon)
        assertEquals(1, Checklist.count(its))
        assertEquals(Group.OPTIONAL, its.single { it.id == "notifications" }.group)
        assertEquals(Group.OPTIONAL, its.single { it.id == "battery" }.group)
        assertEquals("Without it: you see updates and steps only in KOReader and when you open Orbit.", its.single { it.id == "notifications" }.loss)
        assertEquals("1 of 3 on", Checklist.groups(its).single { it.group == Group.OPTIONAL }.line)
    }

    // Groups

    @Test
    fun everyRowIdMapsToOneGroup() {
        Checklist.NEED_ORDER.forEach { id -> assertTrue("$id has a group", id in Checklist.GROUP_OF) }
        assertEquals(Group.OPTIONAL, Checklist.groupOf(Row("home", "Home app", false, optional = true)))
    }

    @Test
    fun collapsedLinesWhenFine() {
        val g = Checklist.groups(items(full())).associateBy { it.group }
        assertEquals("KOReader 2025.10, BookOrbit plugin, Orbit plugin 0.11.2", g.getValue(Group.APPS).line)
        assertEquals("Signed in · recommended settings on", g.getValue(Group.BOOKORBIT).line)
        assertEquals("5 of 5 allowed", g.getValue(Group.PERMISSIONS).line)
        assertEquals("Tailscale connected · Wi-Fi test passed 17:02", g.getValue(Group.CONNECTION).line)
        assertTrue(g.values.all { it.state == State.DONE })
        assertFalse("no Optional group without optional rows", Group.OPTIONAL in g)
    }

    @Test
    fun groupLinesWithOpenSkippedAndSetByReaderRows() {
        val rows = full("signed_in", "notifications", "keyboard") + Row("battery", "Battery", true, setByReader = true)
        val g = Checklist.groups(items(rows, ignored = setOf("keyboard"))).associateBy { it.group }
        assertEquals("1 needs you · recommended settings on", g.getValue(Group.BOOKORBIT).line)
        assertEquals(State.NEEDS_YOU, g.getValue(Group.BOOKORBIT).state)
        assertEquals("1 needs you · 4 of 6 · Orbit keyboard skipped · set by the reader: Battery", g.getValue(Group.PERMISSIONS).line)
    }

    @Test
    fun optionalGroupWithOneRowNamesIt() {
        val g = Checklist.groups(items(full() + Row("screen_saver", "Screen saver from Orbit", false, optional = true))).single { it.group == Group.OPTIONAL }
        assertEquals("Screen saver from Orbit: off", g.line)
        assertEquals(State.OFF, g.state)
    }

    @Test
    fun oneGroupOpenAtATime() {
        assertEquals("APPS", Checklist.toggle(null, "APPS"))
        assertEquals("PERMISSIONS", Checklist.toggle("APPS", "PERMISSIONS"))
        assertNull(Checklist.toggle("APPS", "APPS"))
    }

    // Loss lines (D11)

    @Test
    fun everyRowSetupCanShowHasALossLine() {
        // Setup's rows are built in Pages.kt (Setup.allChecks, addonChecks): every id it names.
        val src = File("src/main/java/net/fledgewing/orbitcompanion/Pages.kt").readText()
        val ids = Regex("""\bid = "([a-z_]+)"""").findAll(src).map { it.groupValues[1] }.toSet()
        val notRows = SetupTips.IDS + "keymapper" // tips, and the Clicker row's extra line
        val rowIds = ids - notRows + Checklist.GROUP_OF.keys + AddonLogic.OPTIONAL.map { it.id } + "battery"
        assertTrue("found Setup's ids in the source: $ids", ids.containsAll(listOf("koreader", "home", "wifi_test")))
        rowIds.forEach { id -> assertTrue("$id has a loss line in Checklist.LOSS", !Checklist.LOSS[id].isNullOrBlank()) }
        // Optional rows also say what you get with them.
        AddonLogic.OPTIONAL.forEach { o -> assertTrue("${o.id} has an On line", !Checklist.ON[o.id].isNullOrBlank()) }
    }

    @Test
    fun fullAndAddonReadTheSameLossText() {
        AddonLogic.OPTIONAL.forEach { o ->
            assertEquals(Checklist.LOSS[o.id], o.without)
            assertEquals("Without it: ${Checklist.LOSS[o.id]}", AddonLogic.optionalLine(o, AddonLogic.OptState.NEVER))
            // The same id, skipped in Full, says the same.
            val skipped = Checklist.items(listOf(Row(o.id, o.title, false)), ignored = setOf(o.id)).single()
            assertEquals("Without it: ${Checklist.LOSS[o.id]}", skipped.loss)
        }
    }

    // PIN (§3.9)

    @Test
    fun lockedViewHasNoVerbButPinFreeFollowThrough() {
        val rows = full("tailscale", "notifications").map { if (it.id == "patch") it.copy(pending = true, verb = "Restart KOReader") else it }
        val its = items(rows)
        val p = Checklist.page(its, locked = true)
        assertEquals(Summary.NeedsGrownUp(2), p.summary)
        assertEquals("2 things need a grown-up", Checklist.summaryTitle(p.summary))
        assertEquals("Unlock to fix", Checklist.summaryButton(p.summary))
        assertTrue(p.needs.none { Checklist.verbShown(it, locked = true) })
        assertTrue(p.ready.all { Checklist.verbShown(it, locked = true) })
        assertTrue(its.filter { Checklist.verbShown(it, locked = true) }.all { it.row.pinFree })
        // Unlocked, the parent's view is the normal page.
        assertTrue(p.needs.all { Checklist.verbShown(it, locked = false) })
        assertEquals(Summary.NeedsYou(2), Checklist.page(its, locked = false).summary)
    }

    // Battery merge (§3.5)

    @Test
    fun batteryMergesAppsAndKeepsPerAppIds() {
        val ok = BatteryRow.Row(true, "done")
        val bad = BatteryRow.Row(false, "set App battery usage › Unrestricted")
        val apps = listOf(BatteryMerge.App("Orbit", ok), BatteryMerge.App("KOReader", bad), BatteryMerge.App("Tailscale", ok))
        val r = BatteryMerge.row(apps)
        assertFalse(r.done)
        assertEquals("KOReader is restricted", r.stateLine)
        assertEquals("Fix", r.verb)
        assertEquals(listOf("battery:KOReader"), r.ids)
        // A skip on one app survives: that app's row is skipped, not needed.
        val i = Checklist.items(listOf(r), ignored = setOf("battery:KOReader")).single()
        assertEquals(State.OFF, i.state)
        assertTrue(i.skipped)
        val t = Checklist.items(listOf(BatteryMerge.row(apps.map { if (it.name == "Tailscale") it.copy(row = bad) else it })), ignored = setOf("battery:Tailscale")).single()
        assertEquals("KOReader still needs you", State.NEEDS_YOU, t.state)
        assertEquals("Unrestricted for Orbit, KOReader, Tailscale", BatteryMerge.row(apps.map { it.copy(row = ok) }).stateLine)
    }

    @Test
    fun batterySetByTheReader() {
        val ok = BatteryRow.Row(true, "done")
        val orbit = BatteryMerge.App("Orbit", ok, locked = true)
        assertEquals(BatteryMerge.AppState.SET_BY_READER, BatteryMerge.state(orbit))
        assertEquals("Set by the reader", BatteryMerge.appLine(orbit))
        val r = BatteryMerge.row(listOf(orbit, BatteryMerge.App("KOReader", ok)))
        assertTrue(r.done)
        assertEquals("Unrestricted for KOReader · set by the reader for Orbit", r.stateLine)
        assertTrue(BatteryMerge.row(listOf(orbit)).setByReader)
        // Locked the wrong way: Needs you, with Help instead of a verb (§3.4).
        val wrong = BatteryMerge.App("Orbit", BatteryRow.Row(false, "x"), locked = true)
        assertEquals(BatteryMerge.AppState.LOCKED_WRONG, BatteryMerge.state(wrong))
        assertEquals("Help", BatteryMerge.row(listOf(wrong)).verb)
        assertEquals("Orbit: can't be changed in Settings on this reader", BatteryMerge.row(listOf(wrong)).stateLine)
    }

    // New in (§3.8, D14)

    @Test
    fun newInTagUntilDoneOrTheNextUpdate() {
        val since = mapOf("keyboard" to "0.12.0")
        val v0112 = Version.parse("0.11.2")
        val v012 = Version.parse("0.12.0")
        assertEquals("New in 0.12", NewIn.tag("keyboard", done = false, updatedFrom = v0112, current = v012, since = since))
        assertNull("done", NewIn.tag("keyboard", done = true, updatedFrom = v0112, current = v012, since = since))
        assertNull("the next update", NewIn.tag("keyboard", done = false, updatedFrom = v012, current = Version.parse("0.12.1"), since = since))
        assertNull("fresh install", NewIn.tag("keyboard", done = false, updatedFrom = null, current = v012, since = since))
        assertNull("older row", NewIn.tag("home", done = false, updatedFrom = v0112, current = v012, since = since))
        assertEquals(Version(0, 11, 2), NewIn.versionOf(1102))
        assertNull(NewIn.versionOf(0))
    }

    @Test
    fun newRowTagsItsGroup() {
        val its = Checklist.items(full() + Row("screen_saver", "Screen saver from Orbit", false, optional = true)) { r ->
            if (r.id == "screen_saver") "New in 0.12" else null
        }
        val g = Checklist.groups(its)
        assertTrue(g.single { it.group == Group.OPTIONAL }.newTag)
        assertTrue(g.filter { it.group != Group.OPTIONAL }.none { it.newTag })
        // Optional: never prompts, never counted.
        assertEquals(0, Checklist.count(its))
    }

    // Status page (§3.8)

    @Test
    fun statusCardSaysAllSetOrWhatNeedsYou() {
        assertEquals("Setup: all set ✓", Checklist.statusTitle(Summary.AllSet(false)))
        val its = items(full("keyboard"))
        val s = Checklist.summary(its)
        assertEquals("Setup: 1 thing needs you ›", Checklist.statusTitle(s))
        assertEquals("Orbit keyboard · tap to fix", Checklist.statusLine(s, its))
    }

    @Test
    fun detailsCopyText() {
        assertEquals("Orbit Companion 1.0.0 setup details\nA: b\nC: d", SetupDetails.copyText("1.0.0", listOf("A" to "b", "C" to "d")))
    }
}
