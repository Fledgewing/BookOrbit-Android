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
 * from one of our pages restores its progress page, then completes the plugin update in KOReader.
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

    /** Started activities in start order (Robolectric hands back the newest first). */
    private fun drain(): List<Intent> = generateSequence { shadowOf(app).nextStartedActivity }.toList().reversed()

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
        assertTrue("a companion-started update restarts KOReader too", UpdateReturn.restartNow(userConfirmed = true, fromPage = UpdateReturn.fromPage()))

        // A second MY_PACKAGE_REPLACED delivery (service and Add-on paths) opens nothing more.
        Updater.onReplaced(app)
        assertTrue(drain().isEmpty())
    }

    @Test
    fun updateFromTheNotificationReturnsToKoreader() {
        install(app) // the update-ready notification's tap: no page
        Updater.onReplaced(app)
        val started = drain()
        assertTrue("no companion page reopens", started.none { it.component?.packageName == app.packageName })
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
        assertTrue("Home never dispatches a second copy of the stack", fromHome.isEmpty())
        assertTrue("the restored page has not resumed yet", UpdateReturn.awaitingLanding())
        // A second package broadcast or Home callback before resume also opens nothing.
        Updater.onReplaced(app)
        assertTrue(drain().isEmpty())
        Robolectric.buildActivity(SettingsActivity::class.java).setup()
        assertNull("after landing, Home is ordinary again", UpdateReturn.forHome())
    }

    /** M8C 11-24 15:55: Settings › Updates came back as a bare SettingsSectionActivity (the default section, no stack under it). */
    @Test
    fun updateFromASettingsSectionReturnsToThatSectionWithItsBackStack() {
        Robolectric.buildActivity(LauncherActivity::class.java).create()
        Robolectric.buildActivity(SettingsActivity::class.java).create()
        val section = Robolectric.buildActivity(SettingsSectionActivity::class.java, SettingsPage.section(app, "updates")).create().get()
        drain()
        install(section)

        Updater.onReplaced(app)
        val started = drain().filter { it.component?.packageName == app.packageName }
        assertEquals(
            "the stack the user had, oldest first",
            listOf(LauncherActivity::class.java.name, SettingsActivity::class.java.name, SettingsSectionActivity::class.java.name),
            started.map { page(it) },
        )
        val top = started.last()
        assertEquals("the same section", "updates", top.getStringExtra(SettingsPage.EXTRA_SECTION))
        assertEquals("at the App version row", SettingsPage.UPDATE_ROW, top.getStringExtra(SettingsPage.EXTRA_FOCUS))
        assertTrue("one task: only the first page starts it", started.first().flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
        assertTrue("the page shows the result", Prefs(app).updateStatus.startsWith("updated to v"))
    }

    /** M8C 11-24 15:56:01: a Home press 10 s after the page showed reopened it a second time. */
    @Test
    fun theReturnLandsOnceAndALaterHomePressIsAnOrdinaryHomePress() {
        val section = Robolectric.buildActivity(SettingsSectionActivity::class.java, SettingsPage.section(app, "updates")).create().get()
        install(section)
        Updater.onReplaced(app)
        val reopened = drain().filter { it.component?.packageName == app.packageName }
        assertEquals(1, reopened.size)

        // The reopened page shows.
        Robolectric.buildActivity(SettingsSectionActivity::class.java, reopened.single()).setup().pause()
        drain()

        Updater.onReplaced(app) // a repeat MY_PACKAGE_REPLACED
        val home = Robolectric.buildActivity(HomeActivity::class.java).setup().get()
        val after = drain() + generateSequence { shadowOf(home).nextStartedActivity }.toList()
        assertTrue("no second reopen: $after", after.none { page(it) == SettingsSectionActivity::class.java.name })
        assertNull(UpdateReturn.forHome())
    }

    @Test
    fun legacyUpdateMarkRestoresThePersistedSection() {
        for (id in listOf("sleep", "sync", "updates")) {
            UpdateReturn.reset(app)
            val section = Robolectric.buildActivity(SettingsSectionActivity::class.java, SettingsPage.section(app, id)).create()
            section.destroy()
            // rc.8's mark carries no extras; simulate its process being killed at install.
            UpdateReturn.mark(app, SettingsSectionActivity::class.java.name)
            Updater.onReplaced(app)
            val top = drain().last { it.component?.packageName == app.packageName }
            assertEquals(id, top.getStringExtra(SettingsPage.EXTRA_SECTION))
            val reopened = Robolectric.buildActivity(SettingsSectionActivity::class.java, top).setup()
            assertEquals(id, reopened.get().returnIntent().getStringExtra(SettingsPage.EXTRA_SECTION))
            reopened.pause().stop().destroy()
        }
    }

    @Test
    fun legacyVersionWithoutPersistedSectionReturnsToUpdates() {
        app.getSharedPreferences("settings_ui", 0).edit().clear().commit()
        UpdateReturn.mark(app, SettingsSectionActivity::class.java.name)
        Updater.onReplaced(app)
        assertEquals("updates", drain().last().getStringExtra(SettingsPage.EXTRA_SECTION))
    }

    @Test
    fun updateFromTheLauncherReturnsToTheLauncher() {
        val launcher = Robolectric.buildActivity(LauncherActivity::class.java).create().get()
        install(launcher)
        Updater.onReplaced(app)
        val started = drain()
        assertEquals(listOf(LauncherActivity::class.java.name), started.mapNotNull { page(it) }.filter { it.startsWith(app.packageName) })
        assertTrue("KOReader is not brought to the front", started.none { it.component?.packageName == Koreader.PKG })
    }

    /** M8C 11-24 15:56: the patch installed after the update while the user was on a companion page. */
    @Test
    fun aManualPatchInstallWhileAPageIsInFrontBringsKoreaderForward() {
        val p = Prefs(app)
        try {
            p.patchVersionSeen = "0.11.3-rc.6"
            p.patchAwaitVersion = "0.11.3-rc.8"
            p.patchRestartNow = "0.11.3-rc.8" // a restart the user asked for
            p.patchRestartSentFor = ""
            val page = Robolectric.buildActivity(SettingsSectionActivity::class.java, SettingsPage.section(app, "updates")).setup()
            drain()

            assertTrue("a page is resumed", EinkActivity.pageResumed())
            assertTrue("a manual update completes over its page", PatchInstaller.follow(app, "patch installed"))
            assertTrue(drain().any { it.component?.packageName == Koreader.PKG })
            assertEquals("0.11.3-rc.8", p.patchRestartSentFor)
            assertTrue(p.restartUserStarted)
            // RELAUNCH must finish the same manual update even while the page is still visible.
            Koreader.restartRead()
            assertTrue(Koreader.relaunch(app, "manual update", HomeCommands.REOPEN_BOOK,
                plugin = "0.11.3-rc.8", fromCompanion = true, userStarted = p.restartUserStarted))
            assertEquals(HomeCommands.REOPEN_BOOK, drain().last().getStringExtra(Contract.EXTRA_COMMAND))
            page.pause().stop().destroy()
        } finally {
            p.patchVersionSeen = ""
            p.patchAwaitVersion = ""
            p.patchRestartNow = ""
            p.patchRestartSentFor = ""
        }
    }

    @Test
    fun delayedRelaunchCannotCoverACompanionPageEvenAtScreenOff() {
        val page = Robolectric.buildActivity(SettingsSectionActivity::class.java, SettingsPage.section(app, "sleep")).setup()
        drain()
        assertFalse(Koreader.relaunch(app, "plugin quit", null))
        val p = Prefs(app)
        p.patchVersionSeen = "0.11.3-rc.6"
        p.patchAwaitVersion = "0.11.3-rc.8"
        p.patchRestartSentFor = ""
        assertFalse("screen-off cannot start KOReader over a companion page", PatchInstaller.follow(app, "screen off", screenOff = true))
        assertTrue(drain().none { it.component?.packageName == Koreader.PKG })
        page.pause().stop().destroy()
        org.robolectric.shadows.ShadowSystemClock.advanceBy(java.time.Duration.ofSeconds(3))
        assertFalse("the page was in front when the delayed request arrived", Koreader.relaunch(app, "delayed plugin quit", null, fromCompanion = true))
        assertTrue(drain().none { it.component?.packageName == Koreader.PKG })
        p.patchVersionSeen = ""
        p.patchAwaitVersion = ""
    }

    @Test
    fun addonRelaunchRechecksFocusAfterTheDelay() {
        val relaunch = Robolectric.buildActivity(RelaunchActivity::class.java).create()
        val page = Robolectric.buildActivity(SettingsActivity::class.java).setup()
        drain()
        shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(3))
        assertTrue(relaunch.get().isFinishing)
        assertTrue(drain().none { it.component?.packageName == Koreader.PKG })
        page.pause().stop().destroy()
    }

    @Test
    fun oldOrForeignMarksAreIgnored() {
        val pkg = app.packageName
        val now = 10 * UpdateFlow.USER_UPDATE_MS
        fun pages(from: String?, at: Long) = UpdateReturn.pages(from, at, now, pkg).map { it.component?.className }
        val section = SettingsPage.section(app, "updates")
        val mark = UpdateReturn.encode(listOf(Intent().setClassName(pkg, "$pkg.LauncherActivity"), section))
        assertEquals(listOf("$pkg.LauncherActivity", "$pkg.SettingsSectionActivity"), pages(mark, now - 1_000))
        assertEquals("updates", UpdateReturn.pages(mark, now - 1_000, now, pkg).last().getStringExtra(SettingsPage.EXTRA_SECTION))
        // A mark written by v0.11.3-rc.8 and older: the class name alone.
        assertEquals(listOf("$pkg.StatusActivity"), pages("$pkg.StatusActivity", now - 1_000))
        assertTrue(pages("$pkg.StatusActivity", now - UpdateFlow.USER_UPDATE_MS - 1).isEmpty())
        assertTrue(pages(UpdateReturn.ELSEWHERE, now - 1_000).isEmpty())
        assertTrue(pages("org.koreader.launcher.MainActivity", now - 1_000).isEmpty())
        assertTrue(pages(Intent().setClassName("org.koreader.launcher", "org.koreader.launcher.MainActivity").toUri(0), now - 1_000).isEmpty())
        assertTrue("never the keypad or a non-page", pages("$pkg.PinActivity\n$pkg.HomeActivity", now - 1_000).isEmpty())
        assertTrue(pages(null, now).isEmpty())
    }
}
