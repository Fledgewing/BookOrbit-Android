package net.fledgewing.orbitcompanion

import android.app.Activity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.security.MessageDigest

/**
 * Reading fonts against Robolectric: the Setup row as Setup builds it (off by default, Optional,
 * "Without it" / "On"), and the install applied to a folder with a fake download (no network).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w632dp-h840dp-port-xhdpi")
class ReadingFontsTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val activity: Activity = Robolectric.buildActivity(Activity::class.java).setup().get()

    private fun texts(v: View): List<String> = when (v) {
        is TextView -> listOf(v.text.toString())
        is ViewGroup -> (0 until v.childCount).flatMap { texts(v.getChildAt(it)) }
        else -> emptyList()
    }

    private fun buttons(v: View): List<String> = when (v) {
        is TextView -> if (v.hasOnClickListeners()) listOf(v.text.toString()) else emptyList()
        is ViewGroup -> (0 until v.childCount).flatMap { buttons(v.getChildAt(it)) }
        else -> emptyList()
    }

    private object NoTaps : ChecklistUi.Actions {
        override fun verb(i: Checklist.Item) = Unit
        override fun tap(i: Checklist.Item) = Unit
        override fun summaryButton() = Unit
        override fun group(key: String) = Unit
        override fun gotIt(tipId: String) = Unit
        override fun showHiddenTips() = Unit
        override fun details() = Unit
        override fun mode() = Unit
    }

    private fun drawOptional(row: Checklist.Row): LinearLayout {
        val done = Checklist.Row("koreader", "KOReader", true, "Version 2025.10")
        val page = Checklist.page(Checklist.items(listOf(done, row)))
        return LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            ChecklistUi.render(activity, this, page, ChecklistUi.Frame(tips = emptyList(), detailsLine = "", modeLine = "", open = Checklist.Group.OPTIONAL.name), NoTaps)
        }
    }

    @Test
    fun offByDefaultTheRowIsOptionalSaysWithoutItAndOffersTurnOn() {
        val row = Setup.readingFonts(activity).row()
        assertEquals("reading_fonts", row.id)
        assertEquals("Reading fonts: Bitter, Literata", row.label)
        assertTrue(row.optional)
        assertFalse(row.done)
        val items = Checklist.items(listOf(row))
        assertEquals("never counted", 0, Checklist.count(items))
        val root = drawOptional(row)
        val t = texts(root)
        assertTrue(t.contains("Reading fonts: Bitter, Literata"))
        assertTrue(t.any { it.contains("Without it: KOReader offers only its own fonts") })
        assertTrue(buttons(root).contains("Turn on"))
    }

    @Test
    fun onAndInstalledTheRowSaysOnAndOffersTurnOff() {
        val row = Checklist.Row(ReadingFonts.ID, ReadingFonts.LABEL, true, "On: ${Checklist.ON.getValue(ReadingFonts.ID)}",
            optional = true, verb = "Turn off")
        val root = drawOptional(row)
        val t = texts(root)
        assertTrue(t.any { it.contains("On: Bitter and Literata are in KOReader's font menu.") })
        assertTrue(buttons(root).contains("Turn off"))
        assertTrue(t.contains("Reading fonts: Bitter, Literata: on"))
    }

    // The install, on a folder, with ReadingFonts.FILES and a fake download.

    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    /** Writes [bytes] for [ok] names (by url) and returns their real hash, so the check decides. */
    private fun fakeFetch(good: Boolean, calls: MutableList<String>): (String, File) -> String = { url, to ->
        calls += url
        val f = ReadingFonts.FILES.first { it.url == url }
        val body = "font ${f.name}".toByteArray()
        to.writeBytes(body)
        if (good) f.sha256 else sha(body)
    }

    @Test
    fun installWritesEveryFileAndNoPartFiles() {
        val d = File(tmp.root, "koreader/fonts")
        val calls = mutableListOf<String>()
        val first = FontInstaller.apply(d, true, fakeFetch(good = true, calls))
        assertNull(first.error)
        assertEquals(ReadingFonts.FILES.size, first.installed)
        assertEquals(ReadingFonts.FILES.map { it.name }.sorted(), d.list()!!.sorted())
        assertFalse(d.list()!!.any { it.endsWith(ReadingFonts.PART) })
    }

    @Test
    fun aFileThatFailsItsChecksumIsNeverLeftBehind() {
        val d = tmp.newFolder("fonts")
        File(d, "Bitter-Regular.ttf${ReadingFonts.PART}").writeText("half")
        val out = FontInstaller.apply(d, true, fakeFetch(good = false, mutableListOf()))
        assertTrue(out.error!!.contains("failed its checksum"))
        assertEquals(0, out.installed)
        assertEquals("the stale part is gone and no font landed", emptyList<String>(), d.list()!!.toList())
    }

    @Test
    fun turningOffRemovesOurFilesButNotTheUsers() {
        val d = tmp.newFolder("fonts")
        val f = ReadingFonts.FILES.first()
        File(d, f.name).writeText("the user's own file of the same name")
        File(d, "Mine.ttf").writeText("x")
        val out = FontInstaller.apply(d, false) { _, _ -> error("no download when off") }
        assertNull(out.error)
        assertEquals(setOf(f.name, "Mine.ttf"), d.list()!!.toSet())
    }
}
