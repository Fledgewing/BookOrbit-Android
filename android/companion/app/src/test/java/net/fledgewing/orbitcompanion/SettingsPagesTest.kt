package net.fledgewing.orbitcompanion

import android.app.Activity
import android.content.Intent
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.TextView
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
import org.robolectric.shadows.ShadowLooper
import java.io.File

/**
 * The Settings pages against Robolectric (docs/design/companion-settings.md §5): the top page's
 * eight sections and search, each section's rows from the schema, the queued-change mark, and the
 * read-only view behind the PIN.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w632dp-h840dp-port-xhdpi")
class SettingsPagesTest {
    private val schema = SettingsSchema.parse(File("../../../shared/settings/schema.json").readText())

    @Before
    fun setUp() {
        SettingsStore.useSchema(schema)
        Prefs(RuntimeEnvironment.getApplication()).mode = OrbitMode.FULL
        SettingsPage.forceLocked = false
    }

    @After
    fun tearDown() {
        SettingsPage.forceLocked = null
    }

    private fun all(v: View): List<View> = listOf(v) + if (v is ViewGroup) (0 until v.childCount).flatMap { all(v.getChildAt(it)) } else emptyList()
    private fun texts(a: Activity): List<String> = all(a.window.decorView).filterIsInstance<TextView>().map { it.text.toString() }
    private fun tagged(a: Activity, tag: String): View? = all(a.window.decorView).firstOrNull { it.tag == tag }

    private inline fun <reified T : Activity> open(intent: Intent? = null): T =
        (if (intent == null) Robolectric.buildActivity(T::class.java) else Robolectric.buildActivity(T::class.java, intent)).setup().get()

    private fun section(id: String, focus: String? = null): SettingsSectionActivity =
        open(SettingsPage.section(RuntimeEnvironment.getApplication(), id, focus).setClass(RuntimeEnvironment.getApplication(), SettingsSectionActivity::class.java))

    @Test
    fun topPageListsTheEightSections() {
        val a = open<SettingsActivity>()
        schema.sections.forEach { s -> assertNotNull(s.id, tagged(a, "section:${s.id}")) }
        assertTrue(texts(a).contains("Sync and Wi-Fi"))
    }

    @Test
    fun searchFindsBySearchWordsAfterAPause() {
        val a = open<SettingsActivity>()
        (tagged(a, "search") as EditText).setText("screensaver")
        assertNotNull("sections stay until the pause", tagged(a, "section:sleep"))
        ShadowLooper.idleMainLooper(SettingsActivity.SEARCH_PAUSE_MS, java.util.concurrent.TimeUnit.MILLISECONDS)
        assertNull(tagged(a, "section:sleep"))
        assertNotNull(tagged(a, "hit:sleep_mode"))
        (tagged(a, "search") as EditText).setText("zzzz")
        ShadowLooper.idleMainLooper(SettingsActivity.SEARCH_PAUSE_MS, java.util.concurrent.TimeUnit.MILLISECONDS)
        assertTrue(texts(a).any { it.startsWith("Nothing matches") })
    }

    @Test
    fun everyShownKeyHasARowInItsSection() {
        // Defaults: sleep screen off hides its children; Wi-Fi rows need the wifi cap (Full has it).
        val hiddenByDefault = setOf("sleep_from", "sleep_leave_out", "sleep_hours", "sleep_text", "sleep_battery", "sleep_style",
            "sleep_text_position", "sleep_battery_corner", "home_button", "wifi_idle_min")
        schema.sections.filter { it.id != "sleep" }.forEach { s ->
            val a = section(s.id)
            schema.settings.filter { it.section == s.id && !it.hidden && it.key !in hiddenByDefault }.forEach { d ->
                assertNotNull("${s.id}: ${d.key}", tagged(a, "key:${d.key}"))
            }
        }
    }

    @Test
    fun aChangeShowsWaitingForKoreaderUntilEchoed() {
        val a = section("library")
        tagged(a, "key:mirror_covers")!!.performClick()
        assertEquals("1", SettingsStore.get(a, "mirror_covers"))
        assertTrue(texts(a).any { it.contains("Waiting for KOReader") })
        val at = SettingsStore.at(a, "mirror_covers")!!
        SettingsStore.fromPlugin(a, SettingsSync.valuesJson(mapOf("mirror_covers" to SettingEntry("1", at))), "test")
        val b = section("library")
        assertFalse(texts(b).any { it.contains("Waiting for KOReader") })
    }

    @Test
    fun lockedIsReadOnlyWithUnlock() {
        SettingsPage.forceLocked = true
        val a = section("library")
        assertTrue(texts(a).contains("Unlock"))
        val row = tagged(a, "key:mirror_covers")!!
        assertFalse("no control while locked", row.hasOnClickListeners())
        assertFalse(texts(a).contains("Do now"))
        val top = open<SettingsActivity>()
        assertTrue("the top page still opens", tagged(top, "section:sync")!!.hasOnClickListeners())
    }

    @Test
    fun sleepScreenEditsPickFromLeaveOutAndText() {
        SettingsStore.set(RuntimeEnvironment.getApplication(), "sleep_mode", "recommended", "test")
        val a = open<SleepScreenActivity>()
        listOf("sleep_from", "sleep_leave_out", "sleep_text", "sleep_hours").forEach { k ->
            val row = tagged(a, "key:$k")
            assertNotNull(k, row)
        }
        assertNotNull("Sharp covers' slot sits in the section", tagged(a, "slot:sharp_covers"))
        assertNotNull("the clearing flash", tagged(a, "key:sleep_flash"))
        val hours = open<SettingChoiceActivity>(Intent(a, SettingChoiceActivity::class.java).putExtra(SettingsPage.EXTRA_KEY, "sleep_hours"))
        val options = all(hours.window.decorView).mapNotNull { (it.tag as? String)?.takeIf { t -> t.startsWith("option:") } }
        assertEquals("Every sleep is listed first", "option:0", options.first())
        assertTrue("Pick from opens the picker", tagged(a, "key:sleep_from")!!.hasOnClickListeners())
        tagged(a, "key:sleep_from")!!.performClick()
        assertEquals(SettingChoiceActivity::class.java.name, shadowOf(a).nextStartedActivity.component?.className)
    }

    /** R1c, X8: Pick from and Leave out tick several items on one page; Library stands alone; both sync per key. */
    @Test
    fun pickFromAndLeaveOutAreMultiSelectWithLibrary() {
        val app = RuntimeEnvironment.getApplication()
        SettingsStore.set(app, "sleep_mode", "recommended", "test")
        val pick = open<SettingChoiceActivity>(Intent(app, SettingChoiceActivity::class.java).putExtra(SettingsPage.EXTRA_KEY, "sleep_from"))
        assertNotNull("Library is an item", tagged(pick, "option:library"))
        tagged(pick, "option:want_to_read")!!.performClick()
        assertFalse("the page stays for more", pick.isFinishing)
        assertEquals("up_next\nwant_to_read", SettingsStore.get(app, "sleep_from"))
        tagged(pick, "option:discover")!!.performClick()
        assertEquals("up_next\nwant_to_read\ndiscover", SettingsStore.get(app, "sleep_from"))
        assertTrue("sent to KOReader, per key", SettingsStore.pending(app, "sleep_from"))
        val wire = SettingsSync.valuesJson(mapOf("sleep_from" to SettingEntry(SettingsStore.get(app, "sleep_from"), 1L)))
        assertTrue("the set travels as one value", wire.contains("up_next\\nwant_to_read\\ndiscover"))
        tagged(pick, "option:up_next")!!.performClick()
        assertEquals("unticked", "want_to_read\ndiscover", SettingsStore.get(app, "sleep_from"))
        tagged(pick, "option:library")!!.performClick()
        assertEquals("Library alone", "library", SettingsStore.get(app, "sleep_from"))
        assertEquals("Library", SettingsUi.valueLabel(schema.byKey.getValue("sleep_from"), "library"))
        assertEquals("Want to read, Discover", SettingsUi.valueLabel(schema.byKey.getValue("sleep_from"), "want_to_read\ndiscover"))

        val lo = open<LeaveOutActivity>()
        all(lo.window.decorView).filterIsInstance<TextView>().first { it.text.toString().startsWith("Library, smart scopes") }.let { (it.parent.parent as View).performClick() }
        tagged(lo, "pick:library")!!.performClick()
        assertEquals("library", SettingsStore.get(app, "sleep_leave_out"))
        assertNotNull("the list page stays for more", tagged(lo, "pick:library"))
        tagged(lo, "pick:library")!!.performClick()
        assertEquals("ticked off again", "", SettingsStore.get(app, "sleep_leave_out"))
    }

    @Test
    fun aSearchHitOpensItsSectionAtTheRow() {
        SettingsStore.set(RuntimeEnvironment.getApplication(), "sync_mode", "custom", "test")
        val a = section("sync", focus = "sync_on_wake")
        assertNotNull(tagged(a, "key:sync_on_wake")!!.foreground)
    }

    @Test
    fun launcherButtonOpensSettings() {
        val a = open<LauncherActivity>()
        val b = all(a.window.decorView).filterIsInstance<TextView>().first { it.text.toString().contains("Settings") }
        b.performClick()
        assertEquals(SettingsActivity::class.java.name, shadowOf(a).nextStartedActivity.component?.className)
        assertNotNull("status moved to the launcher page", tagged(a, "status:service"))
    }
}
