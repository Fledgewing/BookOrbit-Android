package net.fledgewing.orbitcompanion

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The shared settings (docs/design/companion-settings.md §4): the schema both apps build from,
 * and the per-key merge, against the same cases the plugin's test_logic.lua runs
 * (shared/fixtures/settings/merge.json).
 */
class SettingsSyncTest {
    private val schemaFile = File("../../../shared/settings/schema.json")
    private val schema = SettingsSchema.parse(schemaFile.readText())

    @Test
    fun schemaLoads() {
        assertEquals(8, schema.sections.size)
        assertTrue(schema.settings.size >= 30)
        for (d in schema.settings) {
            assertTrue(d.key, d.label.isNotBlank() && d.line.isNotBlank())
            assertTrue(d.key, schema.section(d.section) != null)
            d.parentKey?.let { assertTrue("${d.key} parent", schema.byKey[it] != null) }
            assertEquals("${d.key} default round-trips", d.default, SettingsSync.fromWire(d, d.default))
        }
    }

    /** The companion keeps every key the plugin shares (schema parity; the plugin checks its side). */
    @Test
    fun everySchemaKeyHasCompanionStorage() {
        val legacy = setOf("wifi_mode", "wifi_idle_min", "home_button", "reading_schedule") + SleepSettings.KEYS
        // Every legacy key the companion stored before is still one of the schema's keys.
        for (k in legacy) assertTrue(k, schema.byKey.containsKey(k))
        assertTrue(SettingsSync.LEGACY.all { schema.byKey.containsKey(it) })
    }

    @Test
    fun mergeCases() {
        // @fixture settings/merge.json
        val cases = JSONObject(File("../../../shared/fixtures/settings/merge.json").readText()).getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val name = c.getString("name")
            fun side(o: JSONObject): Map<String, SettingEntry> = o.keys().asSequence().associateWith { k ->
                val e = o.getJSONObject(k)
                val d = schema.byKey.getValue(k)
                SettingEntry(SettingsSync.fromWire(d, e.getString("v")) ?: e.getString("v"), if (e.has("at")) e.getLong("at") else null)
            }
            val local = side(c.getJSONObject("local")).toMutableMap()
            val remote = c.getJSONObject("remote").let { o -> o.keys().asSequence().associateWith { k -> o.getJSONObject(k).let { SettingEntry(it.getString("v"), it.getLong("at")) } } }
            val taken = SettingsSync.merge(schema, local, remote, c.getLong("now"), c.getBoolean("remote_wins_tie"))
            val want = c.getJSONArray("taken").let { a -> (0 until a.length()).map { a.getString(it) } }
            assertEquals(name, want, taken.map { it.key })
            taken.forEach { local[it.key] = SettingEntry(it.v, it.at) }
            val expect = c.getJSONObject("expect")
            for (k in expect.keys()) assertEquals("$name: $k", expect.getString(k), local[k]?.v)
        }
    }

    @Test
    fun visibleFollowsParents() {
        val v = mutableMapOf("sleep_mode" to "off", "sleep_style" to "overlay", "sync_on_sleep" to "1", "wifi_mode" to "jit")
        val get = { k: String -> v[k] ?: schema.byKey.getValue(k).default }
        assertFalse(SettingsSync.visible(schema, "sleep_text", get))
        assertFalse(SettingsSync.visible(schema, "sleep_text_position", get))
        v["sleep_mode"] = "current"
        assertTrue(SettingsSync.visible(schema, "sleep_text_position", get))
        assertFalse(SettingsSync.visible(schema, "sleep_from", get))
        v["sync_on_sleep"] = "0"
        assertFalse(SettingsSync.visible(schema, "sleep_cap", get))
        assertTrue(SettingsSync.visible(schema, "wifi_idle_min", get))
    }

    @Test
    fun pendingUntilThePluginEchoes() {
        val d = schema.byKey.getValue("sync_on_sleep")
        assertTrue(SettingsSync.pending(d, 5000, null))
        assertTrue(SettingsSync.pending(d, 5000, 4000))
        assertFalse(SettingsSync.pending(d, 5000, 5000))
        assertFalse("seeded at 1 ms is never waiting", SettingsSync.pending(d, 1, null))
        assertFalse("the companion reads it", SettingsSync.pending(schema.byKey.getValue("sleep_hours"), 5000, null))
    }

    @Test
    fun valuesRoundTrip() {
        val m = mapOf("sync_on_sleep" to SettingEntry("0", 7), "sleep_leave_out" to SettingEntry("tag:x\nscope:2", 9), "never" to SettingEntry("1", null))
        val back = SettingsSync.parseValues(SettingsSync.valuesJson(m))
        assertEquals(SettingEntry("0", 7), back["sync_on_sleep"])
        assertEquals("tag:x\nscope:2", back["sleep_leave_out"]?.v)
        assertNull(back["never"])
        assertTrue(SettingsSync.parseValues("[]").isEmpty())
    }

    @Test
    fun newCommandsWaitForAPluginThatKnowsThem() {
        assertNull(PluginCommands.allowed(HomeCommands.FULL_REFRESH, "0.11.2"))
        assertEquals(HomeCommands.FULL_REFRESH, PluginCommands.allowed(HomeCommands.FULL_REFRESH, "0.11.3-0.test.7"))
        assertEquals(HomeCommands.SYNC_SLEEP, PluginCommands.allowed(HomeCommands.SYNC_SLEEP, "0.12.0"))
    }

    @Test
    fun lookNowLine() {
        assertEquals("SETTINGS 42\n", ClickRoute.settingsLine(42))
    }
}

class SettingsUiTest {
    private val schema = SettingsSchema.parse(File("../../../shared/settings/schema.json").readText())

    @Test
    fun searchMatchesWordsLabelsAndExtras() {
        assertTrue(SettingsUi.search(schema, "lock screen").any { it.id == "sleep_mode" })
        assertTrue(SettingsUi.search(schema, "kid").any { it.id == "pin" })
        assertTrue(SettingsUi.search(schema, "test network").any { it.id == "do_test_network" })
        assertTrue(SettingsUi.search(schema, "recommended settings choices").none { it.id == "recommended_choice" })
        assertTrue(SettingsUi.search(schema, " ").isEmpty())
    }

    @Test
    fun hiddenRowsSayWhatShowsThem() {
        assertEquals("Shown when Sleep screen is Recommended cover", SettingsUi.shownWhen(schema, "sleep_from"))
        assertEquals("Shown when Sync when the screen goes off is on", SettingsUi.shownWhen(schema, "sleep_cap"))
    }

    @Test
    fun reviewChoicesMerge() {
        assertEquals("a=ours", SettingsUi.withChoice("", "a", "ours"))
        assertEquals("b=undo;a=mine", SettingsUi.withChoice("a=ours;b=undo", "a", "mine"))
        assertEquals("all=ours", SettingsUi.withChoice("a=ours", "all", "ours"))
        assertEquals("ours", SettingsUi.choiceFor("all=ours", "x"))
    }

    @Test
    fun choicesFileParses() {
        val c = SleepChoices.parse("""{"v":1,"at":5,"cached":true,"scopes":[{"id":3,"title":"Short reads","count":48},{"id":0}],"collections":[{"id":9,"title":"Book club"}],"tags":[{"tag":"a","label":"A","count":1},{"tag":"Age:18","count":14}]}""")!!
        assertEquals(1, c.scopes.size)
        assertEquals("Short reads (smart scope)", c.title("scope:3"))
        assertEquals("age:18", c.tags.first().tag)
        assertEquals("Smart scope 4 (not found)", c.ruleLabel("scope:4"))
        assertNull(SleepChoices.parse("nope"))
    }

    @Test
    fun theCompanionsScopesFileWinsWhenNewer() {
        val choices = """{"at":5,"scopes":[{"id":1,"title":"Old"}],"tags":[{"tag":"x","count":2}]}"""
        val scopes = """{"v":1,"at":9,"scopes":[{"id":2,"title":"New","count":3}],"collections":[]}"""
        val c = SleepChoices.combine(choices, scopes)!!
        assertEquals("New", c.scopes.single().title)
        assertEquals("x", c.tags.single().tag)
        assertEquals("Old", SleepChoices.combine(choices.replace("\"at\":5", "\"at\":99"), scopes)!!.scopes.single().title)
        assertEquals("New", SleepChoices.combine(null, scopes)!!.scopes.single().title)
    }

    @Test
    fun reviewFileParses() {
        val r = RecommendedReview.parse("""{"v":1,"at":1,"items":[{"id":"x","label":"X","state":"conflict","yours":"Off","orbit":"On"}]}""")!!
        assertEquals(listOf("ours", "mine"), r.items[0].offers)
        assertEquals("Yours: Off · Orbit's: On", r.items[0].stateLine)
    }

    @Test
    fun everyExtraIsInASection() {
        SettingsUi.EXTRAS.forEach { assertTrue(it.id, schema.section(it.section) != null) }
        assertEquals(SettingsUi.EXTRAS.size, SettingsUi.EXTRAS.map { it.id }.toSet().size)
    }
}

class EverySleepTest {
    private val schema = SettingsSchema.parse(File("../../../shared/settings/schema.json").readText())

    /** "Every sleep" (sleep_hours 0) is listed first, kept through the wire, and is the companion's first choice. */
    @Test
    fun everySleepIsFirstAndRotatesEachTime() {
        val d = schema.byKey.getValue("sleep_hours")
        assertEquals("0" to "Every sleep", d.values.first())
        assertEquals("0", SettingsSync.fromWire(d, "0"))
        assertEquals(0, SleepSettings.merge(SleepSettings.DEFAULT) { if (it == "sleep_hours") "0" else null }.hours)
        // The rotation itself (a random ready cover at each sleep, R4b) is SleepScreenLogicTest's.
        assertEquals("Every sleep", SleepSettings.hoursLabel(SleepSettings.EVERY_SLEEP))
        assertEquals(0, SleepSettings.HOURS.first())
    }
}
