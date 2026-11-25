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

    @Test fun sleepAndReadingUseTheSharedBatteryDrawingProgram() {
        // One declarative drawing function, interpreted by each platform's canvas adapter.
        val root = File("../../..").canonicalFile
        val reader = File(root, "android/koreader/orbit.koplugin/ko/status_layout.lua").readText()
        val sleep = File(root, "android/companion/app/src/main/java/net/fledgewing/orbitcompanion/SleepCanvas.kt").readText()
        assertTrue(reader.contains("BatteryGlyph.draw("))
        assertTrue(sleep.contains("BatteryGlyph.draw("))
        val packaged = checkNotNull(javaClass.getResourceAsStream("/battery.json")).bufferedReader().use { it.readText() }
        assertEquals(File(root, "shared/ui/battery.json").readText(), packaged)
        val bitmap = Bitmap.createBitmap(100, 40, Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(bitmap)
        for (level in listOf(0, 50, 100)) {
            bitmap.eraseColor(Color.WHITE)
            BatteryGlyph.draw(canvas, 10f, 10f, 40f, level)
            assertEquals(Color.BLACK, bitmap.getPixel(10, 10)) // outline
            assertEquals(Color.BLACK, bitmap.getPixel(68, 22)) // terminal
            assertEquals(if (level > 0) Color.BLACK else Color.WHITE, bitmap.getPixel(15, 15))
            assertEquals(if (level == 100) Color.BLACK else Color.WHITE, bitmap.getPixel(60, 15))
        }
        bitmap.recycle()
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

    @Test
    fun everySleepOnBooxWritesTheNextPictureAfterEachSleep() {
        val dir = SleepScreen.dir().apply { deleteRecursively(); File(this, "covers").mkdirs() }
        val ids = listOf(11L, 12L, 13L)
        ids.forEach { id ->
            File(dir, "covers/$id.jpg").outputStream().use { cover().compress(Bitmap.CompressFormat.JPEG, 80, it) }
        }
        File(dir, "pool.json").writeText("""{"v":1,"items":[""" + ids.joinToString(",") { """{"id":$it,"title":"","file":"covers/$it.jpg"}""" } + "]}")
        SleepScreen.sinkForTest = SleepSink.PICTURE
        try {
            val pic = SleepScreen.picture().apply { delete() }
            SleepScreen.save(app, SleepSettings.DEFAULT.copy(mode = SleepMode.RECOMMENDED, hours = SleepSettings.EVERY_SLEEP), "test", shared = false)
            BulkWork.executor.submit {}.get(10, java.util.concurrent.TimeUnit.SECONDS)
            assertTrue("written when turned on", pic.isFile)
            val first = SleepScreen.state(app)
            assertTrue(first.shown in ids)
            // A battery step redraws the same cover; only a wake moves on.
            SleepScreen.redrawPicture(app, "battery 81%")
            BulkWork.executor.submit {}.get(10, java.util.concurrent.TimeUnit.SECONDS)
            assertEquals(first.shown, SleepScreen.state(app).shown)
            pic.delete()
            // The plugin's resume after a real sleep, through the manifest receiver: no service
            // needed, so Add-on mode moves on too (#43).
            CommandReceiver().onReceive(app, Intent(SleepScreen.ACTION_POOL).putExtra("reason", "wake").putExtra("wake", "1"))
            BulkWork.executor.submit {}.get(10, java.util.concurrent.TimeUnit.SECONDS)
            val second = SleepScreen.state(app)
            assertTrue("a new picture for the next sleep", pic.isFile)
            assertTrue(second.shown in ids && second.shown != first.shown)
            assertEquals(1, second.shows[second.shown])
            // On disk for the plugin, and kept for after a reboot (read back from the prefs).
            val j = org.json.JSONObject(File(dir, "state.json").readText())
            assertEquals(second.shown, j.getLong("shown"))
            assertEquals(second.shows, SleepScreen.state(app).shows)
            // The service's SCREEN_ON for the same wake: counted once.
            SleepScreen.onWake(app, "screen on")
            BulkWork.executor.submit {}.get(10, java.util.concurrent.TimeUnit.SECONDS)
            assertEquals(second, SleepScreen.state(app))
            // The next wake moves on again.
            org.robolectric.shadows.ShadowSystemClock.advanceBy(java.time.Duration.ofMillis(SleepWake.SAME_WAKE_MS))
            SleepScreen.onWake(app, "screen on")
            BulkWork.executor.submit {}.get(10, java.util.concurrent.TimeUnit.SECONDS)
            val third = SleepScreen.state(app)
            assertTrue(third.shown in ids && third.shown != second.shown)
        } finally {
            SleepScreen.sinkForTest = null
            SleepScreen.save(app, SleepSettings.DEFAULT, "test", shared = false)
            dir.deleteRecursively()
        }
    }
}
