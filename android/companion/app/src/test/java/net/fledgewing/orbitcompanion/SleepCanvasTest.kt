package net.fledgewing.orbitcompanion

import android.app.Application
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

/** The sleep screen's renderer and files on Android's own classes (Robolectric). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE) // real pixels
class SleepCanvasTest {
    private lateinit var app: Application

    @Before
    fun setUp() {
        app = RuntimeEnvironment.getApplication()
    }

    private fun cover(): Bitmap = Bitmap.createBitmap(400, 600, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.GRAY) }

    private fun input(s: SleepSettings, battery: Int? = 82, cover: Bitmap? = cover(), kind: String = "pool") =
        SleepCanvas.Input(1404, 1872, 38, s, cover, kind, title = "A Made-Up Book", authors = "Ann Example", battery = battery)

    @Test
    fun barHoldsTextAndBatteryBelowTheCover() {
        val s = SleepSettings.DEFAULT.copy(mode = SleepMode.RECOMMENDED, text = "If found, please return", battery = true)
        val (bmp, d) = SleepCanvas.render(input(s))
        assertEquals(1404, bmp.width)
        assertEquals(1872, bmp.height)
        val band = d.band!!
        assertEquals(1872 - 131, band.top)
        assertTrue("cover above the band", d.cover!!.bottom <= band.top)
        assertTrue("battery in the band, right", d.battery!!.top >= band.top && d.battery!!.right <= 1404 - 28)
        assertEquals(1, d.lines.size)
        assertEquals(Color.BLACK, bmp.getPixel(700, band.top))
        assertNull(d.text)
    }

    @Test
    fun noExtrasNoBand() {
        val (_, d) = SleepCanvas.render(input(SleepSettings.DEFAULT.copy(mode = SleepMode.CURRENT), battery = null))
        assertNull(d.band)
        assertEquals(1872, d.cover!!.bottom + d.cover!!.top) // centred on the full height
    }

    @Test
    fun overlayPlatesOnTheEdgeAndInTheCorner() {
        val s = SleepSettings.DEFAULT.copy(mode = SleepMode.RECOMMENDED, text = "Bedtime 8 pm", battery = true, style = SleepStyle.OVERLAY)
        val (bmp, d) = SleepCanvas.render(input(s))
        assertNull(d.band)
        val t = d.text!!
        assertEquals(1404 - 28, t.right) // Right, the default
        assertTrue("rotated: taller than wide", t.height > t.width)
        assertEquals(Corner.BOTTOM_LEFT, d.corner)
        assertEquals(Color.WHITE, bmp.getPixel(t.left + 4, (t.top + t.bottom) / 2 - t.height / 3))
        // Text at the bottom: the battery moves up.
        val (_, d2) = SleepCanvas.render(input(s.copy(textPosition = TextPosition.BOTTOM)))
        assertEquals(Corner.TOP_LEFT, d2.corner)
        assertEquals(1872 - 28, d2.text!!.bottom)
    }

    @Test
    fun fallbacksDrawWithoutACover() {
        val s = SleepSettings.DEFAULT.copy(mode = SleepMode.CURRENT)
        val (_, drawn) = SleepCanvas.render(input(s, cover = null, kind = "current"))
        assertNull(drawn.cover)
        val (bmp, def) = SleepCanvas.render(input(s, cover = null, kind = "default"))
        assertNull(def.cover)
        assertEquals(Color.WHITE, bmp.getPixel(2, 2))
    }

    @Test
    fun poolReadsOnlyCoversOnTheDeviceInsideTheFolder() {
        val dir = File(app.cacheDir, "orbit-sleep").apply { deleteRecursively(); mkdirs() }
        File(dir, "covers").mkdirs()
        File(dir, "covers/5.jpg").writeText("x")
        File(dir, "pool.json").writeText(
            """{"v":1,"items":[{"id":5,"title":"Five","file":"covers/5.jpg"},{"id":7,"file":"covers/7.jpg"},{"id":9,"file":"../escape.jpg"}]}""",
        )
        File(dir.parentFile, "escape.jpg").writeText("x")
        val pool = SleepScreen.pool(dir)
        assertEquals(listOf(5L), pool.map { it.id })
        assertEquals("Five", pool[0].title)
        assertTrue(SleepScreen.pool(File(app.cacheDir, "none")).isEmpty())
        File(dir, "current.json").writeText("""{"v":1,"title":"A Made-Up Book","authors":"Ann Example"}""")
        val cur = SleepScreen.current(dir)!!
        assertEquals("A Made-Up Book", cur.title)
        assertNull(cur.file) // no cover: the drawn one (F3)
    }

    @Test
    fun settingsFromThePluginAreKeptAndReported() {
        val i = Intent("x").putExtra("sleep_mode", "current").putExtra("sleep_hours", "3").putExtra("sleep_battery", "1")
        SleepScreen.fromPlugin(app, i)
        val s = SleepScreen.settings(app)
        assertEquals(SleepMode.CURRENT, s.mode)
        assertEquals(3, s.hours)
        assertTrue(s.battery)
        assertTrue(SleepScreen.settingsJson(app).contains("\"sleep_mode\":\"current\""))
        assertNotNull(org.json.JSONObject(SleepScreen.statusJson(app)).getString("shown_by"))
        // Recorded without the service only when newer than ours.
        Prefs(app).sharedSettingsAt = 5_000
        SleepScreen.recordSettings(app, Intent("x").putExtra("sleep_mode", "off").putExtra("settings_at", "4000"))
        assertEquals(SleepMode.CURRENT, SleepScreen.settings(app).mode)
        SleepScreen.recordSettings(app, Intent("x").putExtra("sleep_mode", "off").putExtra("settings_at", "6000"))
        assertEquals(SleepMode.OFF, SleepScreen.settings(app).mode)
        assertEquals(6_000, Prefs(app).sharedSettingsAt)
    }

    @Test
    fun withoutThePermissionNothingIsSwitched() {
        // Robolectric grants nothing: the companion says how instead (P2).
        assertEquals(false, SleepScreen.canSwitch(app))
        assertEquals(false, SleepScreen.chooseOurs(app, "test"))
        assertEquals(false, SleepScreen.restoreVendor(app, "test"))
    }
}
