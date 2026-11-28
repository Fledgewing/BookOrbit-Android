package net.fledgewing.orbitcompanion

import android.content.Context
import android.os.Looper
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ReaderCompanionTest {
    private lateinit var ctx: Context
    @Before fun setup() {
        ctx = RuntimeEnvironment.getApplication()
        ctx.getSharedPreferences("orbit", Context.MODE_PRIVATE).edit().clear().commit()
        SettingsStore.resetForTest()
        SettingsStore.useSchema(SettingsSchema.parse(java.io.File("../../../shared/settings/schema.json").readText()))
    }
    private fun helpers(): List<Map<*, *>> = (ReaderCompanion.snapshot(ctx)["helpers"] as List<*>).map { it as Map<*, *> }
    private fun command(vararg args: Pair<String, Any?>): String? {
        var error: String? = "pending"
        ReaderCompanion.command(ctx,mapOf(*args)) { _, value -> error = value }
        shadowOf(Looper.getMainLooper()).idle()
        return error
    }
    @Test fun addonStartsOffAndSnapshotStaysBoundedWithoutChecklistOrCatalog() {
        Prefs(ctx).mode=OrbitMode.ADDON
        assertTrue(helpers().all { it["on"]==false && it["mutable"]==true })
        assertTrue(LuaValue.encode(ReaderCompanion.snapshot(ctx)).size<=16384)
        assertEquals(3,helpers().size)
        assertTrue((ReaderCompanion.snapshot(ctx)["sync"] as String).contains("unknown"))
    }
    @Test fun fullPreservesExistingHelpersAndRejectsAddonMutations() {
        Prefs(ctx).mode=OrbitMode.FULL
        assertTrue(helpers().all { it["on"]==true && it["mutable"]==false })
        assertEquals("mode",command("action" to "set","helper" to "wifi","on" to false))
        assertFalse(Prefs(ctx).helperWifi)
    }
    @Test fun missingScreenOffPermissionNeverEnablesHelper() {
        Prefs(ctx).mode=OrbitMode.ADDON
        assertEquals(false,helpers()[2]["permission"])
        assertEquals("permission",command("action" to "set","helper" to "screen","on" to true))
        assertFalse(Prefs(ctx).helperScreenOff)
    }
    @Test fun permissionActionDoesNotChangeAnyHelper() {
        Prefs(ctx).mode=OrbitMode.ADDON
        val before=Mode.helpers(ctx)
        val intent=ReaderCompanion.systemIntent(ctx,"permission")!!
        assertEquals(before,Mode.helpers(ctx))
        assertEquals(android.app.admin.DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN,intent.action)
        assertEquals(0,intent.flags and android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    @Test fun unknownActionOrHelperCannotMutatePreferences() {
        Prefs(ctx).mode=OrbitMode.ADDON
        val before=Mode.helpers(ctx)
        assertEquals("unavailable",command("action" to "set","helper" to "unknown","on" to true))
        assertEquals("unavailable",command("action" to "unknown"))
        assertEquals(before,Mode.helpers(ctx))
    }
    @Test fun systemActionsAreAnExplicitAllowlist() {
        assertNull(ReaderCompanion.systemIntent(ctx,"unknown"))
        assertNull(ReaderCompanion.systemIntent(ctx,null))
        assertNotNull(ReaderCompanion.systemIntent(ctx,"protected"))
        assertNotNull(ReaderCompanion.systemIntent(ctx,"recovery"))
        assertNotNull(ReaderCompanion.systemIntent(ctx,"setup"))
    }
    @Test fun savedSyncFailureRemainsDeliveryPending() {
        val p=Prefs(ctx);p.lastSleepSyncAt=1234;p.lastSleepSyncOk=false
        assertTrue((ReaderCompanion.snapshot(ctx)["sync"] as String).contains("delivery pending"))
        assertTrue((ReaderCompanion.snapshot(ctx)["sync"] as String).contains("stale"))
        p.lastSleepSyncOk=true
        assertTrue((ReaderCompanion.snapshot(ctx)["sync"] as String).contains("sent"))
    }
    @Test fun protectionIsRecheckedAfterTheReaderSnapshot() {
        val p=Prefs(ctx);p.mode=OrbitMode.ADDON;p.helperPin=true
        var error: String?="pending"
        ReaderCompanion.command(ctx,mapOf("action" to "set","helper" to "wifi","on" to true)) { _, e -> error=e }
        Pin.set(ctx,"0000")
        Pin.onScreenOff()
        try {
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals("protected",error)
            assertFalse(p.helperWifi)
        } finally { Pin.clear(ctx,"synthetic test cleanup") }
    }
    @Test fun explicitUnprotectedChoiceEnablesOnlyTheRequestedHelper() {
        Prefs(ctx).mode=OrbitMode.ADDON
        assertNull(command("action" to "set","helper" to "wifi","on" to true))
        assertTrue(Prefs(ctx).helperWifi)
        assertFalse(Prefs(ctx).helperSleepSync)
        assertFalse(Prefs(ctx).helperScreenOff)
    }

    @Test fun unicodeAndOversizedSavedUpdateLabelsRemainBoundedOnTheWire() {
        val p=Prefs(ctx);p.updateStatusAt=1;p.updateStatus="Résumé · ".repeat(10000)
        val snapshot=ReaderCompanion.snapshot(ctx)
        assertTrue(LuaValue.encode(snapshot).size<=16384)
        assertTrue((snapshot["updates"] as String).length<=256)
        assertTrue(LuaValue.transportText(snapshot).contains("Résumé"))
        assertFalse(LuaValue.transportText(snapshot).contains("�"))
    }

}
