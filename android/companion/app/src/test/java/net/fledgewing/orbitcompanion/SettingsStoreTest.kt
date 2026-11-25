package net.fledgewing.orbitcompanion

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
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
        SettingsStore.resetForTest()
        SettingsStore.useSchema(SettingsSchema.parse(java.io.File("../../../shared/settings/schema.json").readText()))
    }

    private fun echo(vararg kv: Pair<String, Pair<String, Long>>): String =
        SettingsSync.valuesJson(kv.associate { (k, e) -> k to SettingEntry(e.first, e.second) })

    /**
     * Settings defaults have one source, shared/settings/schema.json: a reader who never changed a
     * setting gets the schema's default here, as in the plugin (test_flows.lua "settings defaults").
     */
    @Test
    fun everySettingStartsAtTheSchemasDefault() {
        val schema = SettingsStore.schema(ctx)
        assertTrue(schema.settings.size >= 30)
        val wrong = schema.settings.filter { SettingsStore.get(ctx, it.key) != it.default }
            .map { "${it.key}: ${SettingsStore.get(ctx, it.key)}, schema ${it.default}" }
        assertEquals("", wrong.joinToString("\n"))
    }

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
    fun prefsAndTheSleepScreenReadTheSchemaStore() {
        SettingsStore.set(ctx, "wifi_mode", "always_on", "test")
        assertEquals(WifiMode.ALWAYS_ON, Prefs(ctx).wifiMode)
        Prefs(ctx).wifiIdleMin = 5
        assertEquals("5", SettingsStore.get(ctx, "wifi_idle_min"))
        SettingsStore.set(ctx, "sleep_text", "Bedtime\n8 pm", "test")
        assertEquals("Bedtime 8 pm", SleepScreen.settings(ctx).text)
        assertFalse("refused", SettingsStore.set(ctx, "sleep_style", "sideways", "test"))
        assertFalse("nothing in the old places", ctx.getSharedPreferences("orbit", Context.MODE_PRIVATE).contains("wifi_mode"))
        assertFalse(ctx.getSharedPreferences("orbit_sleep", Context.MODE_PRIVATE).contains("sleep_text"))
    }

    /**
     * An older companion kept wifi_mode, wifi_idle_min and home_button in Prefs ("orbit") and the
     * sleep screen's keys in "orbit_sleep". They move into the schema store once, so a reader's
     * choices survive the update; a value the schema refuses is dropped (the default then).
     */
    @Test
    fun anOlderCompanionsSettingsMoveIntoTheSchemaStore() {
        ctx.getSharedPreferences("orbit", Context.MODE_PRIVATE).edit()
            .putString("wifi_mode", "off_reading").putInt("wifi_idle_min", 5).putString("home_button", "bookorbit")
            .putString("home_app", "kept.app").commit()
        ctx.getSharedPreferences("orbit_sleep", Context.MODE_PRIVATE).edit()
            .putString("sleep_mode", "recommended").putString("sleep_hours", "12").putString("sleep_leave_out", "tag:a\ntag:b")
            .putString("sleep_battery", "1").putString("sleep_style", "sideways").putString("sleep_text", "old")
            .putLong("shown", 7L).commit()
        // A value already in the schema store (set by this version) wins over the old one.
        ctx.getSharedPreferences("orbit_settings", Context.MODE_PRIVATE).edit().putString("sleep_text", "new").commit()
        SettingsStore.resetForTest()

        assertEquals(WifiMode.OFF_READING, Prefs(ctx).wifiMode)
        assertEquals(5, Prefs(ctx).wifiIdleMin)
        assertEquals(HomeButton.BOOKORBIT, Prefs(ctx).homeButton)
        val s = SleepScreen.settings(ctx)
        assertEquals(SleepMode.RECOMMENDED, s.mode)
        assertEquals(12, s.hours)
        assertEquals(listOf("tag:a", "tag:b"), s.leaveOut)
        assertTrue(s.battery)
        assertEquals("refused, so the default", "bar", SettingsStore.get(ctx, "sleep_style"))
        assertEquals("new", s.text)
        // The old keys are gone; what else those files hold stays.
        val orbit = ctx.getSharedPreferences("orbit", Context.MODE_PRIVATE)
        val sleep = ctx.getSharedPreferences("orbit_sleep", Context.MODE_PRIVATE)
        assertFalse(orbit.contains("wifi_mode") || orbit.contains("wifi_idle_min") || orbit.contains("home_button"))
        assertTrue(SleepSettings.KEYS.none { sleep.contains(it) })
        assertEquals("kept.app", orbit.getString("home_app", null))
        assertEquals(7L, sleep.getLong("shown", 0L))
        // Once: an old key written again later (a downgrade and back) is not read.
        orbit.edit().putString("wifi_mode", "always_on").commit()
        SettingsStore.resetForTest()
        assertEquals(WifiMode.OFF_READING, Prefs(ctx).wifiMode)
    }

    private fun interceptCommit(file: String, commit: (SharedPreferences.Editor) -> Boolean): Context =
        object : ContextWrapper(ctx) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
                val prefs = ctx.getSharedPreferences(name, mode)
                if (name != file) return prefs
                return object : SharedPreferences by prefs {
                    override fun edit(): SharedPreferences.Editor {
                        val editor = prefs.edit()
                        return object : SharedPreferences.Editor by editor {
                            override fun commit(): Boolean = commit(editor)
                        }
                    }
                }
            }
        }

    @Test
    fun aFailedDestinationWriteLeavesTheOldSettingsForTheNextAttempt() {
        val old = ctx.getSharedPreferences("orbit", Context.MODE_PRIVATE)
        old.edit().putString("wifi_mode", "off_reading").putInt("wifi_idle_min", 5).commit()
        var attempted = false
        SettingsStore.migrate(interceptCommit("orbit_settings") {
            attempted = true
            false
        })
        assertTrue(attempted)
        assertEquals("off_reading", old.getString("wifi_mode", null))
        assertEquals(5, old.getInt("wifi_idle_min", 0))
        assertFalse(ctx.getSharedPreferences("orbit_settings", Context.MODE_PRIVATE).contains("_migrated"))
        // The same process can retry; it must not have cached migration as complete.
        SettingsStore.migrate(ctx)
        assertEquals(WifiMode.OFF_READING, Prefs(ctx).wifiMode)
        assertEquals(5, Prefs(ctx).wifiIdleMin)
        assertFalse(old.contains("wifi_mode"))
    }

    @Test
    fun anInterruptionDuringCleanupKeepsEveryReplacementDurable() {
        ctx.getSharedPreferences("orbit", Context.MODE_PRIVATE).edit()
            .putString("wifi_mode", "off_reading").putInt("wifi_idle_min", 5).commit()
        ctx.getSharedPreferences("orbit_sleep", Context.MODE_PRIVATE).edit()
            .putString("sleep_text", "Bedtime").commit()
        val stopped = IllegalStateException("simulated process interruption")
        try {
            SettingsStore.migrate(interceptCommit("orbit_sleep") { throw stopped })
            throw AssertionError("cleanup did not run")
        } catch (e: IllegalStateException) {
            assertTrue(e === stopped)
        }
        val saved = ctx.getSharedPreferences("orbit_settings", Context.MODE_PRIVATE)
        assertTrue(saved.getBoolean("_migrated", false))
        assertEquals("off_reading", saved.getString("wifi_mode", null))
        assertEquals("5", saved.getString("wifi_idle_min", null))
        assertEquals("Bedtime", saved.getString("sleep_text", null))
        SettingsStore.resetForTest()
        assertEquals(WifiMode.OFF_READING, Prefs(ctx).wifiMode)
        assertEquals("Bedtime", SettingsStore.get(ctx, "sleep_text"))
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
