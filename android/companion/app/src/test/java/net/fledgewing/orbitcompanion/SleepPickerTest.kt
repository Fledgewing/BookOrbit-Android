package net.fledgewing.orbitcompanion

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.TextView
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.shadows.ShadowAlertDialog
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.Executor

/** Hold disk/sync work indefinitely: opening and repeated taps must still work on the same page. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SleepPickerTest {
    private lateinit var app: Application
    private lateinit var previous: Executor
    private val pending = mutableListOf<Runnable>()

    @Before fun before() {
        app = RuntimeEnvironment.getApplication()
        SettingsPage.forceLocked = false
        EinkActivity.forgetPages()
        previous = SleepPickerWork.executor
        SleepPickerWork.executor = Executor { pending += it }
        SleepPickerWork.choices = SleepChoices(1, true,
            listOf(SleepChoices.Item(7, "Short books", 12)),
            listOf(SleepChoices.Item(8, "Favourites", 4)),
            listOf(SleepChoices.Tag("age:18", "Age:18", 3)),
            libraries = listOf(SleepChoices.Item(9, "Fiction", 6)))
        SettingsStore.store(app, "sleep_from", "up_next")
        SettingsStore.store(app, "sleep_leave_out", "")
    }

    @After fun after() {
        SleepPickerWork.executor = previous
        SleepPickerWork.choices = null
        SettingsPage.forceLocked = null
        EinkActivity.forgetPages()
    }

    private fun all(v: View): List<View> = listOf(v) + if (v is ViewGroup) (0 until v.childCount).flatMap { all(v.getChildAt(it)) } else emptyList()
    private fun row(a: Activity, tag: String) = all(a.window.decorView).first { it.tag == tag }
    private fun checked(a: Activity, tag: String, selected: Boolean) {
        val r = row(a, tag)
        assertEquals("visible selection on $tag", selected, r.isSelected)
        assertEquals("painted checkmark on $tag", selected, all(r).filterIsInstance<TextView>().any { it.text == "✓" })
    }

    @Test fun removedSourceCanBeDroppedEvenWhenItIsTheLastPick() {
        SleepPickerWork.choices = SleepChoices.parse("""{"at":5,"scopes":[],"collections":[],"libraries":[]}""")
        SettingsStore.store(app, "sleep_from", "scope:99")
        val pick = Robolectric.buildActivity(SettingChoiceActivity::class.java,
            Intent(app, SettingChoiceActivity::class.java).putExtra(SettingsPage.EXTRA_KEY, "sleep_from")).setup()
        val missing = row(pick.get(), "option:scope:99")
        assertTrue(all(missing).filterIsInstance<TextView>().any { it.text.contains("Removed on the server") })
        missing.performClick()
        assertEquals("up_next", SettingsStore.get(app, "sleep_from"))
        pick.pause().stop().destroy()
    }

    @Test fun namedLibraryReplacesWholeLibraryInBothPickers() {
        SettingsStore.store(app, "sleep_from", "library")
        val pick = Robolectric.buildActivity(SettingChoiceActivity::class.java,
            Intent(app, SettingChoiceActivity::class.java).putExtra(SettingsPage.EXTRA_KEY, "sleep_from")).setup()
        row(pick.get(), "option:library:9").performClick()
        assertEquals("library:9", SettingsStore.get(app, "sleep_from"))
        checked(pick.get(), "option:library", false)
        checked(pick.get(), "option:library:9", true)
        pick.pause().stop().destroy()
        SettingsStore.store(app, "sleep_leave_out", "library")
        val leave = Robolectric.buildActivity(LeaveOutActivity::class.java).setup()
        row(leave.get(), "pick:library:9").performClick()
        assertEquals("library:9", SettingsStore.get(app, "sleep_leave_out"))
        assertFalse(all(leave.get().findViewById(android.R.id.content)).any { it.tag == "pick:library" })
        checked(leave.get(), "pick:library:9", true)
        leave.pause().stop().destroy()
    }

    @Test fun pickFromOpensAndTogglesWithoutWaitingForListsOrSync() {
        val intent = Intent(app, SettingChoiceActivity::class.java).putExtra(SettingsPage.EXTRA_KEY, "sleep_from")
        val page = Robolectric.buildActivity(SettingChoiceActivity::class.java, intent).setup()
        val a = page.get()
        assertTrue("load is queued, never awaited", pending.isNotEmpty())
        val original = row(a, "option:scope:7")
        original.performClick()
        assertSame("ordinary taps keep existing rows", original, row(a, "option:scope:7"))
        checked(a, "option:scope:7", true)
        assertEquals("up_next\nscope:7", SettingsStore.get(app, "sleep_from"))
        row(a, "option:collection:8").performClick()
        checked(a, "option:collection:8", true)
        row(a, "option:scope:7").performClick()
        checked(a, "option:scope:7", false)
        assertEquals("up_next\ncollection:8", SettingsStore.get(app, "sleep_from"))
        assertTrue(SettingsStore.pending(app, "sleep_from"))
        assertFalse(a.isFinishing)
        page.pause().stop().destroy()
        val reopened = Robolectric.buildActivity(SettingChoiceActivity::class.java, intent).setup()
        checked(reopened.get(), "option:collection:8", true)
        assertEquals("up_next\ncollection:8", SettingsStore.stored(app, "sleep_from"))
        reopened.pause().stop().destroy()
    }

    @Test fun leaveOutTagsScopesCollectionsAndLibraryToggleOnTheSamePageAndPersist() {
        val page = Robolectric.buildActivity(LeaveOutActivity::class.java).setup()
        val a = page.get()
        assertTrue(pending.isNotEmpty())
        for (rule in listOf("tag:age:18", "scope:7", "collection:8")) {
            row(a, "pick:$rule").performClick()
            checked(a, "pick:$rule", true)
        }
        assertEquals("tag:age:18\nscope:7\ncollection:8", SettingsStore.get(app, "sleep_leave_out"))
        val original = row(a, "pick:tag:age:18")
        original.performClick()
        assertSame("tag taps update the row in place", original, row(a, "pick:tag:age:18"))
        checked(a, "pick:tag:age:18", false)
        row(a, "pick:library:9").performClick()
        checked(a, "pick:library:9", true)
        checked(a, "pick:scope:7", true)
        row(a, "pick:tag:age:18").performClick()
        checked(a, "pick:tag:age:18", true)
        assertEquals("scope:7\ncollection:8\nlibrary:9\ntag:age:18", SettingsStore.get(app, "sleep_leave_out"))
        assertTrue(SettingsStore.pending(app, "sleep_leave_out"))
        assertFalse(a.isFinishing)
        page.pause().stop().destroy()
        val reopened = Robolectric.buildActivity(LeaveOutActivity::class.java).setup()
        checked(reopened.get(), "pick:tag:age:18", true)
        assertEquals("scope:7\ncollection:8\nlibrary:9\ntag:age:18", SettingsStore.stored(app, "sleep_leave_out"))
        reopened.pause().stop().destroy()
    }

    @Test fun coldOpenLoadsSavedCompanionListsOnTheWorkerAndRedraws() {
        SleepPickerWork.choices = null
        val dir = SleepScreen.dir().apply { mkdirs() }
        val scopes = java.io.File(dir, SleepChoices.SCOPES_FILE)
        val tags = java.io.File(dir, SleepChoices.TAGS_FILE)
        val oldScopes = scopes.takeIf { it.exists() }?.readText()
        val oldTags = tags.takeIf { it.exists() }?.readText()
        scopes.writeText("""{"at":1,"scopes":[{"id":7,"title":"Short books","count":12}]}""")
        tags.writeText("""{"at":1,"tags":[{"tag":"age:18","count":3}]}""")
        val page = Robolectric.buildActivity(LeaveOutActivity::class.java).setup()
        try {
            assertTrue("Leave out draws before disk work", all(page.get().window.decorView).filterIsInstance<TextView>().any { it.text == "Leave out" })
            val work = pending.removeAt(0)
            val worker = Thread { work.run() }.apply { start() }
            worker.join(5000)
            assertFalse("list load finished without blocking the UI", worker.isAlive)
            shadowOf(android.os.Looper.getMainLooper()).idle()
            row(page.get(), "pick:tag:age:18").performClick()
            checked(page.get(), "pick:tag:age:18", true)
            row(page.get(), "pick:scope:7").performClick()
            checked(page.get(), "pick:scope:7", true)
        } finally {
            page.pause().stop().destroy()
            // Execute observer teardown so it cannot leak across tests.
            pending.toList().lastOrNull()?.run()
            if (oldScopes == null) scopes.delete() else scopes.writeText(oldScopes)
            if (oldTags == null) tags.delete() else tags.writeText(oldTags)
        }
    }

    @Test fun typedTagIsVisibleImmediatelyAndCanBeUnticked() {
        val page = Robolectric.buildActivity(LeaveOutActivity::class.java).setup()
        val a = page.get()
        val text = all(a.window.decorView).filterIsInstance<TextView>().first { it.text == "Type a tag…" }
        (text.parent.parent as View).performClick()
        val dialog = ShadowAlertDialog.getLatestAlertDialog()
        all(dialog.window!!.decorView).filterIsInstance<EditText>().single().setText("Custom:Tag")
        dialog.getButton(android.app.AlertDialog.BUTTON_POSITIVE).performClick()
        shadowOf(android.os.Looper.getMainLooper()).idle()
        checked(a, "pick:tag:custom:tag", true)
        assertEquals("tag:custom:tag", SettingsStore.stored(app, "sleep_leave_out"))
        row(a, "pick:tag:custom:tag").performClick()
        assertEquals("", SettingsStore.get(app, "sleep_leave_out"))
        page.pause().stop().destroy()
    }
}
