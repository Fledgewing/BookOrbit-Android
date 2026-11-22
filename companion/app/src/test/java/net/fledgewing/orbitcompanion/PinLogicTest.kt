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

    @Test
    fun unlockLastsFiveMinutesOrUntilScreenOff() {
        val s = PinSession()
        assertFalse(s.unlocked(0))
        s.unlock(1_000)
        assertTrue(s.unlocked(1_000 + PinSession.WINDOW_MS - 1))
        assertFalse(s.unlocked(1_000 + PinSession.WINDOW_MS))
        s.unlock(2_000)
        s.lock() // screen off (Pin.onScreenOff)
        assertFalse(s.unlocked(2_001))
    }

    private fun decide(
        pkg: String?,
        pinSet: Boolean = true,
        unlocked: Boolean = false,
        guarded: Set<String> = setOf(settings, "com.android.vending"),
        fix: Set<String> = emptySet(),
        update: Boolean = false,
    ) = Guard.decide(pkg, own, pinSet, unlocked, guarded, fix, update)

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
    fun setupFixPageIsAllowed() {
        assertEquals(Guard.Decision.ALLOW, decide(settings, fix = setOf(settings)))
        assertEquals(Guard.Decision.GUARD, decide("com.android.vending", fix = setOf(settings)))
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
