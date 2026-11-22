package net.fledgewing.orbitcompanion

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PinLogicTest {
    private val own = Contract.PACKAGE
    private val settings = "com.android.settings"

    @Test
    fun hashVerifiesOnlyTheRightPinAndNeverHoldsIt() {
        val h = PinHash.hash("4821")
        assertTrue(PinHash.verify("4821", h))
        assertFalse(PinHash.verify("4822", h))
        assertFalse(PinHash.verify("", h))
        assertFalse("PIN not in the stored value", h.contains("4821"))
        assertTrue(h.startsWith("pbkdf2-sha256$${PinHash.ITERATIONS}$"))
        assertNotEquals("salted: same PIN, different hash", h, PinHash.hash("4821"))
        assertFalse(PinHash.verify("4821", null))
        assertFalse(PinHash.verify("4821", ""))
        assertFalse(PinHash.verify("4821", "md5\$1\$x\$y"))
    }

    @Test
    fun pinIsFourToEightDigits() {
        assertTrue(PinHash.valid("1234"))
        assertTrue(PinHash.valid("12345678"))
        assertFalse(PinHash.valid("123"))
        assertFalse(PinHash.valid("123456789"))
        assertFalse(PinHash.valid("12a4"))
    }

    @Test
    fun fiveFreeTriesThen30sDoublingTo5Minutes() {
        var b = PinBackoff()
        val now = 1_000_000L
        repeat(4) {
            b = b.fail(now)
            assertEquals(0L, b.waitMs(now))
        }
        val waits = (1..6).map { b = b.fail(now); b.waitMs(now) }
        assertEquals(listOf(30_000L, 60_000L, 120_000L, 240_000L, 300_000L, 300_000L), waits)
        assertEquals(0L, b.waitMs(now + 300_000L))
        assertEquals(PinBackoff(), b.success())
    }

    private val onyx = "com.onyx"
    private val onyxSettings = "com.onyx.settings.SettingsActivity"
    private val onyxHome = "com.onyx.launcher.HomeActivity"
    private val homeComponents = setOf(Guard.component(onyx, onyxHome))
    private val homePkgs = setOf(onyx)
    private val defaultGuard = setOf(settings, Guard.settingsEntry(onyx, onyxSettings, homePkgs))

    private fun gate(pin: Boolean = true) = PinGate().apply {
        pinSet = pin
        watching = true // the accessibility service is on (the hard cap is off)
        guarded = defaultGuard + "com.android.vending"
    }

    private fun fg(pkg: String, cls: String?, g: PinGate) =
        Guard.classify(pkg, cls, own, homeComponents, homePkgs, emptySet(), launchable = pkg != "com.onyx.overlay", guarded = g.guarded)

    /** What ClickerService does with each window change: note leaving/entering, then decide. */
    private fun front(g: PinGate, pkg: String, cls: String?, now: Long): Guard.Decision {
        fg(pkg, cls, g)?.let { g.onForeground(it, pkg, cls, now) }
        return g.decide(pkg, cls, own, now)
    }

    private val grace = PinGate.GRACE_MS
    private val sCls = "com.android.settings.Settings"

    @Test
    fun aPinSetIsLiveForTheVeryNextGuardedEvent() {
        val g = gate(pin = false)
        assertEquals(Guard.Decision.ALLOW, front(g, settings, sCls, 0))
        // Set in companion Settings (Pin.set: pinSet + unlocked for that visit), then Home.
        g.pinSet = true
        g.unlock(1)
        front(g, onyx, onyxHome, 2)
        // Inside the 2-minute grace: still open; after it, the very next event is gated.
        assertEquals(Guard.Decision.ALLOW, front(g, settings, sCls, 3))
        front(g, onyx, onyxHome, 4)
        assertEquals(Guard.Decision.GUARD, front(g, settings, sCls, 4 + grace))
        // The guard list is live too.
        g.guarded = g.guarded + "org.example.browser"
        assertEquals(Guard.Decision.GUARD, front(g, "org.example.browser", "Main", 5 + grace))
    }

    @Test
    fun booxSettingsGuardedByScreenNotTheLauncherPackage() {
        // Settings resolves into com.onyx, which also is the launcher: only that screen is guarded.
        assertEquals("com.onyx/$onyxSettings", Guard.settingsEntry(onyx, onyxSettings, homePkgs))
        assertEquals("org.vendor.settings", Guard.settingsEntry("org.vendor.settings", "X", homePkgs))
        assertEquals(settings, Guard.settingsEntry(settings, sCls, setOf(settings)))
        assertEquals("com.android.systemui/X", Guard.settingsEntry(Guard.SYSTEM_UI, "X", emptySet()))
        val g = gate()
        assertEquals(Guard.Decision.ALLOW, front(g, onyx, onyxHome, 0))
        assertEquals(Guard.Decision.ALLOW, front(g, onyx, "com.onyx.SomeTransition", 1))
        assertEquals(Guard.Decision.ALLOW, front(g, own, "net.fledgewing.orbitcompanion.LauncherActivity", 2))
        assertEquals(Guard.Decision.GUARD, front(g, onyx, onyxSettings, 3))
    }

    @Test
    fun leaveAndComeBackWithin2MinutesNeedsNoPin() {
        listOf(Koreader.PKG to "org.koreader.launcher.MainActivity", onyx to onyxHome, "org.example.notes" to "Main").forEach { (pkg, cls) ->
            val g = gate()
            g.unlock(0, listOf(settings)) // the keypad over Android Settings
            assertEquals(Guard.Decision.ALLOW, front(g, settings, "com.android.settings.SubSettings", 1))
            front(g, pkg, cls, 2)
            assertFalse("left to $pkg: outside", g.inside(3))
            assertEquals("back within 2 min from $pkg", Guard.Decision.ALLOW, front(g, settings, sCls, 2 + grace - 1))
            assertTrue("inside again", g.inside(2 + grace))
            // Leaving again starts a fresh 2 minutes.
            front(g, pkg, cls, 10 * grace)
            assertTrue(g.unlocked(10 * grace + grace - 1))
            assertEquals(Guard.Decision.GUARD, front(g, settings, sCls, 10 * grace + grace))
        }
    }

    @Test
    fun leaveAndWait2MinutesAsksAgain() {
        val g = gate()
        g.unlock(0) // companion Settings
        g.leave(5) // an open companion page (launcher)
        assertTrue(g.unlocked(5 + grace - 1))
        assertFalse(g.unlocked(5 + grace))
        assertEquals(Guard.Decision.GUARD, front(g, settings, sCls, 5 + grace))
        g.enter(5 + grace) // a protected page after the grace: still locked
        assertTrue(g.locked(5 + grace + 1))
    }

    @Test
    fun anotherGuardedAppInTheGraceNeedsNoPin() {
        val g = gate()
        g.unlock(0, listOf(settings))
        front(g, Koreader.PKG, null, 1)
        assertEquals(Guard.Decision.ALLOW, front(g, "com.android.vending", "Store", 2))
        assertTrue("a guarded app counts as inside", g.inside(3))
    }

    @Test
    fun movingWithinProtectedScreensNeverStartsTheGrace() {
        val g = gate()
        g.unlock(0) // companion Settings
        // Companion pages are handled by the pages (null: not the service's call).
        assertEquals(null, fg(own, "net.fledgewing.orbitcompanion.ClickersActivity", g))
        // A page opened from Settings (accessibility settings) joins the unlock.
        assertTrue(g.addScope(settings, 1))
        front(g, settings, "com.android.settings.SubSettings", 2)
        // Launcher overlays and system windows don't count as leaving.
        front(g, onyx, "com.onyx.SomeTransition", 3)
        front(g, "com.onyx.overlay", "Toast", 4)
        assertTrue(g.inside(10 * grace))
        // A locked gate takes no scope.
        assertFalse(gate().addScope(settings, 0))
    }

    @Test
    fun setupFixTargetStaysInTheFlow() {
        val g = gate()
        g.unlock(0)
        g.addScope(settings, 1) // the Fix's target (EinkActivity.tryStart while unlocked)
        assertEquals(Guard.Decision.ALLOW, front(g, settings, sCls, 2))
        front(g, Koreader.PKG, null, 3)
        assertEquals(Guard.Decision.GUARD, front(g, settings, sCls, 3 + grace))
    }

    @Test
    fun homeLeavesEvenWhenTheLauncherPackageIsInScope() {
        val g = gate()
        g.unlock(0, listOf(onyx)) // the keypad over Boox Settings (in com.onyx)
        assertEquals(Guard.Decision.ALLOW, front(g, onyx, onyxSettings, 1))
        front(g, onyx, onyxHome, 2)
        assertFalse(g.inside(3))
        assertTrue(g.locked(2 + grace))
    }

    @Test
    fun screenOffLocksAtOnce() {
        val g = gate()
        g.unlock(0)
        assertTrue(g.lock())
        assertTrue(g.locked(1))
        g.unlock(10)
        g.leave(20)
        g.lock()
        assertTrue("screen-off inside the grace", g.locked(21))
    }

    @Test
    fun hardCapOnlyWithoutTheAccessibilityService() {
        val g = gate()
        g.watching = false
        g.unlock(100)
        assertTrue(g.unlocked(100 + PinGate.CAP_MS - 1))
        assertFalse(g.unlocked(100 + PinGate.CAP_MS))
        g.watching = true
        g.unlock(100)
        assertTrue(g.unlocked(100 + 10 * PinGate.CAP_MS))
    }

    @Test
    fun koreaderMenuUnlockCoversKoreader() {
        val g = gate()
        g.unlock(0, listOf(Koreader.PKG)) // SHOW_PIN from the patch's menu
        front(g, Koreader.PKG, "org.koreader.launcher.MainActivity", 1)
        assertTrue(g.inside(2))
        front(g, onyx, onyxHome, 3)
        assertFalse(g.inside(4))
        assertTrue(g.locked(3 + grace))
    }

    private fun decide(
        pkg: String?,
        cls: String? = null,
        pinSet: Boolean = true,
        unlocked: Boolean = false,
        guarded: Set<String> = setOf(settings, "com.android.vending"),
        update: Boolean = false,
    ) = Guard.decide(pkg, cls, own, pinSet, unlocked, guarded, update)

    @Test
    fun guardedAppGetsTheKeypadOnlyWhileLocked() {
        assertEquals(Guard.Decision.GUARD, decide(settings))
        assertEquals(Guard.Decision.GUARD, decide("com.android.vending"))
        assertEquals(Guard.Decision.ALLOW, decide("org.example.notes"))
        assertEquals(Guard.Decision.ALLOW, decide(settings, unlocked = true))
        assertEquals(Guard.Decision.ALLOW, decide(settings, pinSet = false))
        assertEquals(Guard.Decision.ALLOW, decide(null))
    }

    @Test
    fun neverGuardedEvenIfListed() {
        val all = Guard.NEVER + own
        all.forEach { assertEquals(it, Guard.Decision.ALLOW, decide(it, guarded = all)) }
        assertFalse(Guard.canGuard(Koreader.PKG, own))
        assertFalse(Guard.canGuard(own, own))
        assertFalse(Guard.canGuard("com.android.systemui", own))
        assertTrue(Guard.canGuard(settings, own))
    }

    @Test
    fun installerAllowedOnlyDuringTheInstallWindow() {
        val inst = "com.google.android.packageinstaller"
        assertEquals(Guard.Decision.GUARD, decide(inst, guarded = setOf(inst)))
        assertEquals(Guard.Decision.ALLOW, decide(inst, guarded = setOf(inst), update = true))
        assertEquals(Guard.Decision.GUARD, decide(settings, update = true))
    }

    private val protect = "com.google.android.finsky.protectdialogs.activity.PlayProtectDialogsActivity"
    private val store = "com.android.vending"

    /** The Boox Page, 11-22: a guarded Play Store, Play Protect's dialog during an update. */
    @Test
    fun playProtectDuringAnUpdateGetsNoKeypadEvenWithThePlayStoreGuarded() {
        val g = gate()
        assertTrue(store in g.guarded)
        g.installStarted("update", 1_000)
        assertEquals(Guard.Decision.ALLOW, front(g, store, protect, 2_000))
        assertEquals(Guard.Decision.ALLOW, front(g, "com.google.android.packageinstaller", "com.android.packageinstaller.InstallStaging", 3_000))
        // The Play Store's own pages stay guarded during the window.
        assertEquals(Guard.Decision.GUARD, front(g, store, "com.google.android.finsky.activities.MainActivity", 4_000))
        assertEquals(Guard.Decision.GUARD, front(g, settings, sCls, 4_000))
        // The install ends: Play Protect's follow-up dialog within about 60 s still passes.
        g.installEnded("update", 10_000)
        assertEquals(Guard.Decision.ALLOW, front(g, store, protect, 10_000 + Guard.INSTALL_GRACE_MS - 1))
        assertEquals(Guard.Decision.GUARD, front(g, store, protect, 10_000 + Guard.INSTALL_GRACE_MS))
    }

    @Test
    fun playProtectWithNoUpdateRunningIsStillGated() {
        val g = gate()
        assertFalse(g.installing(5_000))
        assertEquals(Guard.Decision.GUARD, front(g, store, protect, 5_000))
        assertEquals(Guard.Decision.GUARD, front(g, store, null, 5_000))
    }

    @Test
    fun installWindowCoversEveryOpenInstallAndEndsAtTheCap() {
        val g = gate()
        g.installStarted("update", 0)
        g.installStarted("patch", 10)
        g.installEnded("patch", 20)
        assertTrue("one install still open", g.installing(20 + Guard.INSTALL_GRACE_MS + 1))
        assertFalse("a session that never reports stops counting", g.installing(Guard.INSTALL_CAP_MS))
        g.installEnded("update", Guard.INSTALL_CAP_MS)
        assertTrue(g.installing(Guard.INSTALL_CAP_MS + 1))
    }

    @Test
    fun installSurfacesByActivityAndVendor() {
        assertTrue(Guard.installSurface("com.miui.packageinstaller", "x.Y"))
        assertTrue(Guard.installSurface("com.samsung.android.packageinstaller", null))
        assertTrue(Guard.installSurface("com.google.android.permissioncontroller", null))
        assertTrue(Guard.installSurface(store, protect))
        assertTrue("no activity named: the package, for the window only", Guard.installSurface(store, null))
        assertTrue("a plain dialog window", Guard.installSurface(store, "android.app.Dialog"))
        assertFalse(Guard.installSurface(store, "com.android.vending.AssetBrowserActivity"))
        assertFalse(Guard.installSurface(settings, null))
    }

    /** Play Store popping up over KOReader by itself (auto-update, scan): back, no keypad. */
    @Test
    fun aBackgroundPopupIsDismissedWithNoKeypad() {
        val g = gate()
        val now = 100_000L
        val d = g.decide(store, "com.google.android.finsky.activities.MainActivity", own, now)
        assertEquals(Guard.Decision.GUARD, d)
        assertEquals(Guard.Decision.DISMISS, Popup.decide(d, Fg.KOREADER, Koreader.PKG, store, now, lastTapAt = 0))
        assertEquals("over another reader app", Guard.Decision.DISMISS, Popup.decide(d, Fg.APP, "org.example.reader", store, now, 0))
        assertTrue("nothing unlocked", g.locked(now))
    }

    @Test
    fun aUserOpenedGuardedAppGetsTheKeypad() {
        val g = gate()
        val now = 100_000L
        val d = g.decide(store, "com.google.android.finsky.activities.MainActivity", own, now)
        assertEquals("a launcher tap just before", Guard.Decision.GUARD, Popup.decide(d, Fg.KOREADER, Koreader.PKG, store, now, lastTapAt = now - 1_500))
        assertEquals("from the launcher", Guard.Decision.GUARD, Popup.decide(d, Fg.HOME, "com.onyx", store, now, 0))
        assertEquals("from recents", Guard.Decision.GUARD, Popup.decide(d, Fg.OTHER, Guard.SYSTEM_UI, store, now, 0))
        assertEquals("from the companion", Guard.Decision.GUARD, Popup.decide(d, null, null, store, now, 0))
        assertEquals("a stale tap doesn't count", Guard.Decision.DISMISS, Popup.decide(d, Fg.KOREADER, Koreader.PKG, store, now, now - 2_500))
        // The install window still lets Play Protect through.
        g.installStarted("update", now)
        assertEquals(Guard.Decision.ALLOW, Popup.decide(g.decide(store, protect, own, now), Fg.KOREADER, Koreader.PKG, store, now, 0))
    }

    @Test
    fun resetPinRefusedFromANonShellCaller() {
        assertFalse(PinReset.allowed(10_123))
        assertFalse(PinReset.allowed(1000))
        assertTrue(PinReset.allowed(PinReset.SHELL_UID))
        assertTrue(PinReset.allowed(0))
        // Android didn't say (pre-14, or the sender shares no identity): the DUMP permission decides.
        assertTrue(PinReset.allowed(null))
        assertTrue(PinReset.allowed(-1))
    }

    @Test
    fun setupRowNamesTheGuardWhenAPinIsSet() {
        assertEquals("Clicker buttons (accessibility)", ClickerRow.label(false))
        assertEquals("Clicker buttons / app guard (accessibility) on", ClickerRow.label(true))
        assertEquals(ClickerRowState.OFF, ClickerRow.state(mapped = true, enabledInSettings = false, connected = false))
    }

    // Boox Go Color 7, 11-22 02:37: opening the library (com.onyx MainActivity) asked for the PIN.
    private val booxHomes = setOf("com.onyx")
    private val booxSettings = setOf("com.android.settings", "com.onyx/com.onyx.common.setting.ui.WifiContainerActivity")

    @Test
    fun migrationDropsAWholeLauncherPackageAndKeepsItsSettingsScreens() {
        val saved = setOf("com.android.settings", "com.onyx", "com.android.vending")
        val (next, dropped) = Guard.migrate(saved, booxHomes, booxSettings)
        assertEquals(listOf("com.onyx"), dropped)
        assertEquals(setOf("com.android.settings", "com.onyx/com.onyx.common.setting.ui.WifiContainerActivity", "com.android.vending"), next)
        val (again, none) = Guard.migrate(next, booxHomes, booxSettings)
        assertTrue("once", none.isEmpty())
        assertEquals(next, again)
        assertTrue("system UI whole goes too", Guard.migrate(setOf(Guard.SYSTEM_UI), emptySet(), emptySet()).second.isNotEmpty())
        assertTrue("AOSP Settings whole stays", Guard.migrate(setOf(Guard.SETTINGS_PKG), setOf(Guard.SETTINGS_PKG), emptySet()).second.isEmpty())
    }

    @Test
    fun matchesIgnoresAWholeLauncherEntry() {
        val stale = setOf("com.onyx", "com.onyx/com.onyx.common.setting.ui.WifiContainerActivity")
        assertFalse("the library", Guard.matches(stale, "com.onyx", "com.onyx.reader.main.ui.MainActivity", booxHomes))
        assertTrue("its Wi-Fi settings screen", Guard.matches(stale, "com.onyx", "com.onyx.common.setting.ui.WifiContainerActivity", booxHomes))
        assertEquals(Guard.Decision.ALLOW, Guard.decide("com.onyx", "com.onyx.reader.main.ui.MainActivity", "own", true, false, stale, false, booxHomes))
        assertTrue("a normal app whole still matches", Guard.matches(setOf("com.android.vending"), "com.android.vending", "x.Main", booxHomes))
    }

    @Test
    fun keypadLabelIsAUserFacingName() {
        val pkg = "com.onyx"
        val cls = "com.onyx.reader.main.ui.MainActivity"
        assertEquals("Library", Guard.label("Library", "Onyx", pkg, cls))
        assertEquals("internal title: the app's", "Onyx", Guard.label("ContentBrowser", "Onyx", pkg, cls))
        assertEquals("class name: the app's", "Onyx", Guard.label("MainActivity", "Onyx", pkg, cls))
        assertEquals("Wi-Fi", Guard.label("Wi-Fi", "Settings", pkg, cls))
        assertEquals("Settings", Guard.label(null, "Settings", "com.android.settings", null))
        assertEquals("nothing readable: this app", null, Guard.label("ContentBrowser", "com.onyx", pkg, cls))
        assertEquals("Play Store", Guard.label("com.google.android.finsky.Main", "Play Store", "com.android.vending", null))
    }
}
