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
        guarded = defaultGuard + "com.android.vending"
    }

    private fun fg(pkg: String, cls: String?, g: PinGate) =
        Guard.classify(pkg, cls, own, homeComponents, homePkgs, emptySet(), launchable = pkg != "com.onyx.overlay", guarded = g.guarded)

    /** What ClickerService does with each window change: end an unlock it leaves, then decide. */
    private fun front(g: PinGate, pkg: String, cls: String?, now: Long): Guard.Decision {
        fg(pkg, cls, g)?.let { g.onForeground(it, pkg, now) }
        return g.decide(pkg, cls, own, now)
    }

    @Test
    fun aPinSetIsLiveForTheVeryNextGuardedEvent() {
        val g = gate(pin = false)
        assertEquals(Guard.Decision.ALLOW, front(g, settings, "com.android.settings.Settings", 0))
        // Set in companion Settings (Pin.set: pinSet + unlocked for that visit), then Home.
        g.pinSet = true
        g.unlock(1)
        front(g, onyx, onyxHome, 2)
        assertEquals(Guard.Decision.GUARD, front(g, settings, "com.android.settings.Settings", 3))
        // The guard list is live too.
        g.guarded = g.guarded + "org.example.browser"
        assertEquals(Guard.Decision.GUARD, front(g, "org.example.browser", "Main", 4))
    }

    @Test
    fun booxSettingsGuardedByScreenNotTheLauncherPackage() {
        // Settings resolves into com.onyx, which also is the launcher: only that screen is guarded.
        assertEquals("com.onyx/$onyxSettings", Guard.settingsEntry(onyx, onyxSettings, homePkgs))
        assertEquals("org.vendor.settings", Guard.settingsEntry("org.vendor.settings", "X", homePkgs))
        assertEquals(settings, Guard.settingsEntry(settings, "com.android.settings.Settings", setOf(settings)))
        assertEquals("com.android.systemui/X", Guard.settingsEntry(Guard.SYSTEM_UI, "X", emptySet()))
        val g = gate()
        assertEquals(Guard.Decision.ALLOW, front(g, onyx, onyxHome, 0))
        assertEquals(Guard.Decision.ALLOW, front(g, onyx, "com.onyx.SomeTransition", 1))
        assertEquals(Guard.Decision.ALLOW, front(g, own, "net.fledgewing.orbitcompanion.LauncherActivity", 2))
        assertEquals(Guard.Decision.GUARD, front(g, onyx, onyxSettings, 3))
    }

    @Test
    fun unlockEndsWhenTheUserLeavesToKoreaderHomeOrAnotherApp() {
        listOf(Koreader.PKG to "org.koreader.launcher.MainActivity", onyx to onyxHome, "org.example.notes" to "Main").forEach { (pkg, cls) ->
            val g = gate()
            g.unlock(0, listOf(settings)) // the keypad over Android Settings
            assertEquals(Guard.Decision.ALLOW, front(g, settings, "com.android.settings.SubSettings", 1))
            front(g, pkg, cls, 2)
            assertFalse("left to $pkg", g.unlocked(3))
            assertEquals(Guard.Decision.GUARD, front(g, settings, "com.android.settings.Settings", 4))
        }
    }

    @Test
    fun unlockStaysWhileMovingWithinProtectedScreens() {
        val g = gate()
        g.unlock(0) // companion Settings
        // Companion pages are handled by the pages (null: not the service's call).
        assertEquals(null, fg(own, "net.fledgewing.orbitcompanion.ClickersActivity", g))
        // A page opened from Settings (accessibility settings) joins the unlock.
        assertTrue(g.addScope(settings, 1))
        assertEquals(Guard.Decision.ALLOW, front(g, settings, "com.android.settings.SubSettings", 2))
        // Launcher overlays and system windows don't end it.
        front(g, onyx, "com.onyx.SomeTransition", 3)
        front(g, "com.onyx.overlay", "Toast", 4)
        assertTrue(g.unlocked(5))
        // A locked gate takes no scope.
        val l = gate()
        assertFalse(l.addScope(settings, 0))
    }

    @Test
    fun setupFixTargetAllowedOnlyInThatFlow() {
        val g = gate()
        g.unlock(0)
        g.addScope(settings, 1) // the Fix's target (EinkActivity.tryStart while unlocked)
        assertEquals(Guard.Decision.ALLOW, front(g, settings, "com.android.settings.Settings", 2))
        front(g, Koreader.PKG, null, 3)
        assertEquals(Guard.Decision.GUARD, front(g, settings, "com.android.settings.Settings", 4))
    }

    @Test
    fun homeEndsAnUnlockEvenWhenTheLauncherPackageIsInScope() {
        val g = gate()
        g.unlock(0, listOf(onyx)) // the keypad over Boox Settings (in com.onyx)
        assertEquals(Guard.Decision.ALLOW, front(g, onyx, onyxSettings, 1))
        front(g, onyx, onyxHome, 2)
        assertTrue(g.locked(3))
    }

    @Test
    fun screenOffAndTheHardCapLock() {
        val g = gate()
        g.unlock(0)
        assertTrue(g.lock()) // screen off
        assertTrue(g.locked(1))
        g.unlock(100)
        assertTrue(g.unlocked(100 + PinGate.CAP_MS - 1))
        assertFalse(g.unlocked(100 + PinGate.CAP_MS))
    }

    @Test
    fun koreaderMenuUnlockSurvivesKoreaderInFront() {
        val g = gate()
        g.unlock(0, listOf(Koreader.PKG)) // SHOW_PIN from the patch's menu
        front(g, Koreader.PKG, "org.koreader.launcher.MainActivity", 1)
        assertFalse(g.locked(2))
        front(g, onyx, onyxHome, 3)
        assertTrue(g.locked(4))
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
    fun installerAllowedOnlyDuringASelfUpdate() {
        val inst = "com.google.android.packageinstaller"
        assertEquals(Guard.Decision.GUARD, decide(inst, guarded = setOf(inst)))
        assertEquals(Guard.Decision.ALLOW, decide(inst, guarded = setOf(inst), update = true))
        assertEquals(Guard.Decision.GUARD, decide(settings, update = true))
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
}
