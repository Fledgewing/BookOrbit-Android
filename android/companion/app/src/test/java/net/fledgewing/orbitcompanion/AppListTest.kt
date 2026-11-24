package net.fledgewing.orbitcompanion

import android.app.Application
import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Looper
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** The app list's rules alone. */
class AppListLogicTest {
    private fun e(pkg: String, label: String = pkg, cls: String = "$pkg.Main") = AppEntry(pkg, cls, label)

    @Test
    fun frozenAppsAreListedButTurnedOffAliasesAreNot() {
        assertTrue(AppListLogic.listed(resolvesEnabled = true, appFrozen = false))
        assertTrue("a vendor freeze hides the app from a plain query", AppListLogic.listed(resolvesEnabled = false, appFrozen = true))
        assertFalse("an alias its own app turned off", AppListLogic.listed(resolvesEnabled = false, appFrozen = false))
    }

    @Test
    fun aFailedOrBlankLabelFallsBackToThePackage() {
        assertEquals("Readest", AppListLogic.label(" Readest ", "com.bilingify.readest"))
        assertEquals("com.bilingify.readest", AppListLogic.label(null, "com.bilingify.readest"))
        assertEquals("com.bilingify.readest", AppListLogic.label("  ", "com.bilingify.readest"))
    }

    @Test
    fun anAppBeingReplacedKeepsItsRow() {
        val before = listOf(e("a", "Alpha"), e("b", "Beta"))
        val merged = AppListLogic.merge(listOf(e("a", "Alpha")), before, replacing = setOf("b"))
        assertEquals(listOf("a", "b"), merged.map { it.pkg })
    }

    @Test
    fun anAppRemovedForGoodLeaves() {
        val before = listOf(e("a", "Alpha"), e("b", "Beta"))
        assertEquals(listOf("a"), AppListLogic.merge(listOf(e("a", "Alpha")), before, replacing = emptySet()).map { it.pkg })
    }

    @Test
    fun theFreshRowWinsOverTheKeptOne() {
        val before = listOf(e("b", "Beta old"))
        val merged = AppListLogic.merge(listOf(e("b", "Beta new")), before, replacing = setOf("b"))
        assertEquals(listOf("Beta new"), merged.map { it.label })
    }

    @Test
    fun mergeIsOneRowPerActivityAToZ() {
        val merged = AppListLogic.merge(listOf(e("z", "zebra"), e("a", "Apple"), e("z", "zebra"), e("m", "Mango", "m.Other"), e("m", "Mango")), emptyList(), emptySet())
        assertEquals(listOf("Apple", "Mango", "Mango", "zebra"), merged.map { it.label })
        assertEquals(4, merged.size)
    }

    @Test
    fun replaceWindowOpensOnReplacingRemoveAndClosesOnAdd() {
        val w = ReplaceWindow()
        w.onEvent(Intent.ACTION_PACKAGE_REMOVED, "b", replacing = true)
        assertEquals(setOf("b"), w.packages)
        w.onEvent(Intent.ACTION_PACKAGE_CHANGED, "b", replacing = false)
        assertEquals("a change mid-update keeps it open", setOf("b"), w.packages)
        w.onEvent(Intent.ACTION_PACKAGE_ADDED, "b", replacing = true)
        assertEquals(emptySet<String>(), w.packages)
        w.onEvent(Intent.ACTION_PACKAGE_REMOVED, "c", replacing = true)
        w.onEvent(Intent.ACTION_PACKAGE_REMOVED, "c", replacing = false)
        assertEquals("a plain remove closes it", emptySet<String>(), w.packages)
        w.onEvent(Intent.ACTION_PACKAGE_REMOVED, null, replacing = true)
        assertEquals(emptySet<String>(), w.packages)
    }

    @Test
    fun rowsThatFitAreThoseInsideTheList() {
        assertEquals(3, AppListLogic.fits(listOf(80, 160, 240), 240))
        assertEquals("a wrapped label pushes the last row out", 2, AppListLogic.fits(listOf(80, 200, 280), 240))
        assertEquals("always one", 1, AppListLogic.fits(listOf(300), 240))
    }
}

/** AppList against Robolectric's PackageManager and package broadcasts. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AppListTest {
    private lateinit var app: Application

    @Before
    fun setUp() {
        app = RuntimeEnvironment.getApplication()
        AppList.reset()
        install("com.example.alpha", "Alpha")
        install("com.example.beta", "Beta")
    }

    @After
    fun tearDown() = AppList.reset()

    private fun pm() = shadowOf(app.packageManager)

    private fun install(pkg: String, label: String, cls: String = "$pkg.Main") {
        val c = ComponentName(pkg, cls)
        pm().addActivityIfNotPresent(c)
        pm().addIntentFilterForActivity(c, IntentFilter(Intent.ACTION_MAIN).apply { addCategory(Intent.CATEGORY_LAUNCHER) })
        pm().getInternalMutablePackageInfo(pkg).applicationInfo!!.apply {
            nonLocalizedLabel = label
            enabled = true
        }
        pm().getInternalMutablePackageInfo(pkg).activities.orEmpty().forEach { it.nonLocalizedLabel = label }
    }

    private fun uninstall(pkg: String, cls: String = "$pkg.Main") {
        val c = ComponentName(pkg, cls)
        pm().clearIntentFilterForActivity(c)
        pm().removeActivity(c)
        pm().removePackage(pkg)
    }

    private fun pkgs() = AppList.load(app).map { it.pkg }

    private fun broadcast(action: String, pkg: String, replacing: Boolean = false) {
        app.sendBroadcast(Intent(action, Uri.fromParts("package", pkg, null)).putExtra(Intent.EXTRA_REPLACING, replacing))
        shadowOf(Looper.getMainLooper()).idle()
    }

    @Test
    fun listsLauncherAppsWithLabels() {
        val list = AppList.load(app)
        assertEquals(listOf("Alpha", "Beta"), list.map { it.label })
        assertFalse(list.any { it.frozen })
    }

    @Test
    fun aFrozenAppStaysOnTheListMarkedFrozen() {
        // A Boox freeze: the app is disabled, which hides it from a plain launcher query.
        app.packageManager.setApplicationEnabledSetting("com.example.beta", PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER, 0)
        pm().getInternalMutablePackageInfo("com.example.beta").applicationInfo!!.enabled = false
        val list = AppList.load(app)
        assertEquals(listOf("com.example.alpha", "com.example.beta"), list.map { it.pkg })
        assertTrue(list.single { it.pkg == "com.example.beta" }.frozen)
    }

    @Test
    fun aTurnedOffAliasOfAnEnabledAppStaysOut() {
        install("com.example.alpha", "Alpha alias", "com.example.alpha.Alias")
        app.packageManager.setComponentEnabledSetting(
            ComponentName("com.example.alpha", "com.example.alpha.Alias"),
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            0,
        )
        assertEquals(listOf("com.example.alpha.Main"), AppList.load(app).filter { it.pkg == "com.example.alpha" }.map { it.cls })
    }

    @Test
    fun aFailedLabelLoadKeepsTheApp() {
        val list = AppList.load(app) { r ->
            if (r.activityInfo.packageName == "com.example.beta") throw RuntimeException("resources gone") else "Alpha"
        }
        assertEquals(listOf("Alpha", "com.example.beta"), list.map { it.label })
    }

    @Test
    fun theReceiverRefreshesOnEveryPackageEvent() {
        var calls = 0
        val r = AppList.receiver { calls++ }
        AppList.register(app, r)
        listOf(
            Intent.ACTION_PACKAGE_ADDED,
            Intent.ACTION_PACKAGE_REMOVED,
            Intent.ACTION_PACKAGE_FULLY_REMOVED,
            Intent.ACTION_PACKAGE_CHANGED,
            Intent.ACTION_PACKAGE_REPLACED,
        ).forEach { broadcast(it, "com.example.beta") }
        app.sendBroadcast(Intent(Intent.ACTION_PACKAGES_SUSPENDED))
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(6, calls)
        app.unregisterReceiver(r)
    }

    @Test
    fun aNewlyInstalledAppAppearsOnTheNextLoad() {
        assertEquals(2, pkgs().size)
        install("com.example.gamma", "Gamma")
        broadcast(Intent.ACTION_PACKAGE_ADDED, "com.example.gamma")
        assertTrue("com.example.gamma" in pkgs())
    }

    @Test
    fun anUpdatingAppKeepsItsRowThroughTheReplaceWindow() {
        val r = AppList.receiver {}
        AppList.register(app, r)
        assertEquals(2, pkgs().size)
        // The update: the old package goes (REMOVED + EXTRA_REPLACING), the list reloads, then it comes back.
        uninstall("com.example.beta")
        broadcast(Intent.ACTION_PACKAGE_REMOVED, "com.example.beta", replacing = true)
        assertEquals(listOf("com.example.alpha", "com.example.beta"), pkgs())
        install("com.example.beta", "Beta 2")
        broadcast(Intent.ACTION_PACKAGE_ADDED, "com.example.beta", replacing = true)
        assertEquals(listOf("Alpha", "Beta 2"), AppList.load(app).map { it.label })
        // Then removed for good: it leaves.
        uninstall("com.example.beta")
        broadcast(Intent.ACTION_PACKAGE_REMOVED, "com.example.beta")
        assertEquals(listOf("com.example.alpha"), pkgs())
        app.unregisterReceiver(r)
    }

    @Test
    fun theAppsPageReloadsOnABroadcastWhileShowing() {
        val c = Robolectric.buildActivity(AppsActivity::class.java).setup()
        val page = c.get()
        assertTrue(page.apps.any { it.component.packageName == "com.example.beta" })
        install("com.example.gamma", "Gamma")
        broadcast(Intent.ACTION_PACKAGE_ADDED, "com.example.gamma")
        assertTrue(page.apps.any { it.component.packageName == "com.example.gamma" })
        c.pause()
        install("com.example.delta", "Delta")
        broadcast(Intent.ACTION_PACKAGE_ADDED, "com.example.delta")
        assertFalse("not listening while paused", page.apps.any { it.component.packageName == "com.example.delta" })
        c.resume()
        assertTrue("and reloaded on resume", page.apps.any { it.component.packageName == "com.example.delta" })
        c.pause().stop().destroy()
    }
}
