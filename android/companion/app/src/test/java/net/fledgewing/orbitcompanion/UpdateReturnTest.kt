package net.fledgewing.orbitcompanion

import android.app.Application
import android.content.Intent
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

/**
 * M8C 11-23 22:47: Update tapped on the Status page, and after the replace the user was in
 * KOReader (the patch install's COMMAND=restart brought it to the front). An update started
 * from one of our pages ends on that page; one started elsewhere returns to KOReader as before.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class UpdateReturnTest {
    private lateinit var app: Application

    @Before
    fun setUp() {
        app = RuntimeEnvironment.getApplication()
        UpdateReturn.reset(app)
        Prefs(app).updateStatus = ""
        drain()
    }

    @After
    fun tearDown() {
        UpdateReturn.reset(app)
        Updater.pendingConfirm = null
    }

    private fun drain(): List<Intent> = generateSequence { shadowOf(app).nextStartedActivity }.toList()

    private fun confirm() = Intent("android.content.pm.action.CONFIRM_INSTALL").setPackage("com.android.packageinstaller")

    /** The Install tap: PinActivity.thenInstall from [from], then the keypad page (no PIN set) opens Android's prompt. */
    private fun install(from: android.content.Context) {
        val i = PinActivity.thenInstall(from, confirm())
        Robolectric.buildActivity(PinActivity::class.java, i).setup()
        drain()
    }

    private fun page(i: Intent) = i.component?.className

    @Test
    fun updateFromStatusPageEndsOnThatPageAndKoreaderWaits() {
        val status = Robolectric.buildActivity(StatusActivity::class.java).get()
        install(status)

        Updater.onReplaced(app)
        val started = drain()
        assertEquals(listOf(StatusActivity::class.java.name), started.mapNotNull { page(it) }.filter { it.startsWith(app.packageName) })
        assertTrue("KOReader is not brought to the front", started.none { it.component?.packageName == Koreader.PKG })
        assertTrue("the page shows the result", Prefs(app).updateStatus.startsWith("updated to v"))
        assertTrue(UpdateReturn.fromPage())
        assertFalse("the patch restart waits for the screen-off", UpdateReturn.restartNow(userConfirmed = true, fromPage = UpdateReturn.fromPage()))

        // A second MY_PACKAGE_REPLACED delivery (service and Add-on paths) opens nothing more.
        Updater.onReplaced(app)
        assertTrue(drain().isEmpty())
    }

    @Test
    fun updateFromTheNotificationReturnsToKoreader() {
        install(app) // the update-ready notification's tap: no page
        Updater.onReplaced(app)
        val started = drain()
        assertTrue("no companion page reopens", started.none { it.component?.className == StatusActivity::class.java.name })
        assertFalse(UpdateReturn.fromPage())
        assertTrue("KOReader restarts at once, as before", UpdateReturn.restartNow(userConfirmed = true, fromPage = UpdateReturn.fromPage()))
        assertNull("Home goes to KOReader as usual", UpdateReturn.forHome())
    }

    @Test
    fun packageReplacedHomeRelaunchShowsThePageNotKoreader() {
        val settings = Robolectric.buildActivity(SettingsActivity::class.java).get()
        install(settings)

        // MY_PACKAGE_REPLACED reaches the receiver: it only starts the service, never a page.
        CommandReceiver().onReceive(app, Intent(Intent.ACTION_MY_PACKAGE_REPLACED))
        val service = shadowOf(app).nextStartedService
        assertNotNull(service)
        assertEquals(Intent.ACTION_MY_PACKAGE_REPLACED, service!!.action)
        assertTrue(drain().isEmpty())

        // The service's handling, then Android relaunching Home (the old process took the pages down).
        Updater.onReplaced(app)
        assertEquals(SettingsActivity::class.java.name, drain().mapNotNull { page(it) }.single { it.startsWith(app.packageName) })
        val home = Robolectric.buildActivity(HomeActivity::class.java).setup().get()
        val fromHome = generateSequence { shadowOf(home).nextStartedActivity }.toList()
        assertEquals(listOf(SettingsActivity::class.java.name), fromHome.map { page(it) })
        // Only once: a later Home press goes to KOReader as usual.
        assertNull(UpdateReturn.forHome())
    }

    @Test
    fun oldOrForeignMarksAreIgnored() {
        val pkg = "net.fledgewing.orbitcompanion"
        val now = 10 * UpdateFlow.USER_UPDATE_MS
        assertEquals("$pkg.StatusActivity", UpdateReturn.page("$pkg.StatusActivity", now - 1_000, now, pkg))
        assertNull(UpdateReturn.page("$pkg.StatusActivity", now - UpdateFlow.USER_UPDATE_MS - 1, now, pkg))
        assertNull(UpdateReturn.page(UpdateReturn.ELSEWHERE, now - 1_000, now, pkg))
        assertNull(UpdateReturn.page("org.koreader.launcher.MainActivity", now - 1_000, now, pkg))
        assertNull(UpdateReturn.page(null, now, now, pkg))
    }
}
