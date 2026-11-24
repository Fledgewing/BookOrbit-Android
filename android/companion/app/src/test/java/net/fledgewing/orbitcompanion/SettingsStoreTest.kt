package net.fledgewing.orbitcompanion

import android.content.Context
import org.robolectric.RuntimeEnvironment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The companion's store of shared settings against Robolectric: a change made while KOReader is
 * closed waits ("Waiting for KOReader") until the plugin echoes it; a newer KOReader change wins
 * for that key only (docs/design/companion-settings.md §4.4-§4.6).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SettingsStoreTest {
    private lateinit var ctx: Context

    @Before
    fun setUp() {
        ctx = RuntimeEnvironment.getApplication()
        SettingsStore.useSchema(SettingsSchema.parse(java.io.File("../../../shared/settings/schema.json").readText()))
    }

    private fun echo(vararg kv: Pair<String, Pair<String, Long>>): String =
        SettingsSync.valuesJson(kv.associate { (k, e) -> k to SettingEntry(e.first, e.second) })

    @Test
    fun queuedChangeWaitsForKoreaderThenClears() {
        assertTrue(SettingsStore.set(ctx, "sync_on_sleep", "0", "test"))
        assertEquals("0", SettingsStore.get(ctx, "sync_on_sleep"))
        assertTrue("waiting while KOReader is closed", SettingsStore.pending(ctx, "sync_on_sleep"))
        // The values the plugin will read at its start carry the change.
        val sent = SettingsSync.parseValues(SettingsStore.valuesJson(ctx))
        val at = sent.getValue("sync_on_sleep").at!!
        assertEquals("0", sent.getValue("sync_on_sleep").v)
        // KOReader started, applied it, and echoed it with the same time.
        SettingsStore.fromPlugin(ctx, echo("sync_on_sleep" to ("0" to at)), "test")
        assertFalse(SettingsStore.pending(ctx, "sync_on_sleep"))
    }

    @Test
    fun aNewerKoreaderChangeWinsForThatKeyOnly() {
        SettingsStore.set(ctx, "storage_limit_mb", "500", "test")
        val mine = SettingsStore.at(ctx, "storage_limit_mb")!!
        SettingsStore.set(ctx, "sleep_hours", "12", "test")
        val taken = SettingsStore.fromPlugin(ctx, echo("storage_limit_mb" to ("1024" to mine + 10), "sleep_hours" to ("6" to 5)), "test")
        assertEquals(listOf("storage_limit_mb"), taken)
        assertEquals("1024", SettingsStore.get(ctx, "storage_limit_mb"))
        assertEquals("12", SettingsStore.get(ctx, "sleep_hours"))
        assertTrue(SettingsStore.fromPluginAt(ctx, "storage_limit_mb") != null)
    }

    @Test
    fun legacyKeysKeepTheirStorage() {
        SettingsStore.set(ctx, "wifi_mode", "always_on", "test")
        assertEquals(WifiMode.ALWAYS_ON, Prefs(ctx).wifiMode)
        SettingsStore.set(ctx, "sleep_text", "Bedtime\n8 pm", "test")
        assertEquals("Bedtime 8 pm", SleepScreen.settings(ctx).text)
        assertFalse("refused", SettingsStore.set(ctx, "sleep_style", "sideways", "test"))
    }

    @Test
    fun readingScheduleAlsoQueuesTheOldRequest() {
        SettingsStore.set(ctx, "reading_schedule", "pg50", "test")
        assertEquals("pg50", Prefs(ctx).readingScheduleRequest)
        assertEquals("pg50", SettingsStore.get(ctx, "reading_schedule"))
        SettingsStore.fromPlugin(ctx, echo("reading_schedule" to ("pg50" to SettingsStore.at(ctx, "reading_schedule")!!)), "test")
        assertEquals("", Prefs(ctx).readingScheduleRequest)
        assertEquals("pg50", SettingsStore.get(ctx, "reading_schedule"))
    }
}
