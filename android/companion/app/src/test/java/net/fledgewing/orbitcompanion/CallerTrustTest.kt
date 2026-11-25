package net.fledgewing.orbitcompanion

import android.app.Application
import android.os.Bundle
import android.os.Looper
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowBinder
import java.io.File

/** The caller check (docs/design/security.md): only the pinned KOReader reaches the companion. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class CallerTrustTest {
    private lateinit var app: Application
    private val signers = HashMap<String, Set<String>>()
    private val defaultSigners = KoreaderTrust.signersOf
    private val ko = Koreader.PKG
    private val koUid = 10_123
    private val otherUid = 10_456

    @Before
    fun setUp() {
        app = RuntimeEnvironment.getApplication()
        app.getSharedPreferences("caller_trust", 0).edit().clear().commit()
        KoreaderTrust.signersOf = { _, pkg -> signers[pkg] ?: emptySet() }
        shadowOf(app.packageManager).setPackagesForUid(koUid, ko)
        shadowOf(app.packageManager).setPackagesForUid(otherUid, "com.example.other")
        signers[ko] = setOf("AA:01")
        signers["com.example.other"] = setOf("BB:02")
    }

    @After
    fun tearDown() {
        KoreaderTrust.signersOf = defaultSigners
        ShadowBinder.reset()
    }

    private fun call(uid: Int, method: String, extras: Bundle? = null): Bundle? {
        ShadowBinder.setCallingUid(uid)
        val p = Robolectric.setupContentProvider(CommandProvider::class.java, CommandProvider.AUTHORITY)
        return p.call(method, null, extras).also { shadowOf(Looper.getMainLooper()).idle() }
    }

    @Test fun theRuleIsPinOnFirstUseThenAcceptOnlyThatCopy() {
        val sig = mapOf(ko to setOf("AA"), KoreaderRelease.FDROID_PKG to setOf("FD"), "x" to setOf("CC"))
        val first = CallerTrust.decide(null, listOf(ko), sig::getValue)
        assertEquals(CallerTrust.Verdict.PIN, first.verdict)
        val pin = first.pin!!
        assertEquals(CallerTrust.Verdict.ACCEPT, CallerTrust.decide(pin, listOf(ko)) { setOf("AA", "RR") }.verdict) // a rotation keeps the old one
        assertEquals(CallerTrust.Verdict.CHANGED, CallerTrust.decide(pin, listOf(ko)) { setOf("ZZ") }.verdict)
        assertEquals("the other KOReader package", CallerTrust.Verdict.CHANGED, CallerTrust.decide(pin, listOf(KoreaderRelease.FDROID_PKG), sig::getValue).verdict)
        assertEquals(CallerTrust.Verdict.REFUSE, CallerTrust.decide(pin, listOf("x"), sig::getValue).verdict)
        assertEquals(CallerTrust.Verdict.REFUSE, CallerTrust.decide(null, listOf("x"), sig::getValue).verdict)
        assertEquals("unreadable certificate", CallerTrust.Verdict.REFUSE, CallerTrust.decide(null, listOf(ko)) { emptySet() }.verdict)
        assertEquals(pin, CallerTrust.Pin.decode(pin.encode()))
        assertNull(CallerTrust.Pin.decode("")); assertNull(CallerTrust.Pin.decode("pkg|"))
    }

    @Test fun koreaderIsPinnedAndAcceptedAnotherAppIsRefused() {
        assertEquals("1", call(koUid, Contract.SETUP_LATER)?.getString("ok"))
        assertEquals(CallerTrust.Pin(ko, setOf("AA:01")), KoreaderTrust.pin(app))
        val r = call(otherUid, Worker.ACTION_STORAGE, Bundle().apply { putString("cover_dir", "/sdcard/DCIM") })
        assertEquals("0", r?.getString("ok"))
        assertEquals("caller", r?.getString("why"))
        assertEquals("the pin stays", CallerTrust.Pin(ko, setOf("AA:01")), KoreaderTrust.pin(app))
        assertEquals("an unknown method", "0", call(koUid, "${Contract.PACKAGE}.action.DELETE_EVERYTHING")?.getString("ok"))
    }

    @Test fun nothingIsAcceptedBeforeKoreaderFromAnotherApp() {
        assertEquals("0", call(otherUid, Contract.SETUP_LATER)?.getString("ok"))
        assertNull("another app is never pinned", KoreaderTrust.pin(app))
    }

    @Test fun aReplacedKoreaderIsRefusedUntilTheUserTrustsIt() {
        call(koUid, Contract.SETUP_LATER)
        signers[ko] = setOf("EE:99") // KOReader reinstalled from another source
        assertEquals("0", call(koUid, Contract.SETUP_LATER)?.getString("ok"))
        val changed = KoreaderTrust.changed(app)
        assertNotNull("Setup shows KOReader changed", changed)
        assertFalse("its command is dropped", KoreaderTrust.koreaderTrusted(app))
        // The Setup row: label, the question, its Trust button; then trusted.
        val row = Setup.checks(app).single { it.id == KoreaderTrust.ROW_ID }
        assertTrue(row.detail.startsWith("KOReader changed: trust this copy?"))
        assertEquals("Trust", row.action)
        KoreaderTrust.trustChanged(app)
        assertEquals(CallerTrust.Pin(ko, setOf("EE:99")), KoreaderTrust.pin(app))
        assertNull(KoreaderTrust.changed(app))
        assertEquals("1", call(koUid, Contract.SETUP_LATER)?.getString("ok"))
        assertTrue(Setup.checks(app).none { it.id == KoreaderTrust.ROW_ID })
    }

    @Test fun theOldCopyBackClearsTheQuestion() {
        call(koUid, Contract.SETUP_LATER)
        signers[ko] = setOf("EE:99")
        call(koUid, Contract.SETUP_LATER)
        signers[ko] = setOf("AA:01")
        assertNull(KoreaderTrust.changed(app))
        assertEquals("1", call(koUid, Contract.SETUP_LATER)?.getString("ok"))
    }

    /** Every command KOReader sends is one the provider accepts, and the receiver no longer takes any. */
    @Test fun theReceiverIsNotExportedAndTakesNoCommands() {
        val manifest = listOf(File("src/main/AndroidManifest.xml"), File("app/src/main/AndroidManifest.xml")).first { it.isFile }.readText()
        val receiver = manifest.substringAfter("android:name=\".CommandReceiver\"").substringBefore("</receiver>")
        assertTrue(receiver.contains("android:exported=\"false\""))
        CommandProvider.COMMANDS.forEach { assertFalse("$it not on the receiver", receiver.contains(it)) }
        val provider = manifest.substringAfter("android:name=\".CommandProvider\"").substringBefore("/>")
        assertTrue(provider.contains("android:authorities=\"${CommandProvider.AUTHORITY}\""))
    }
}
