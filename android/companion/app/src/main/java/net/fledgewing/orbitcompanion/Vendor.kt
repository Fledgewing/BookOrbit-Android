package net.fledgewing.orbitcompanion

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build

/**
 * Vendor quirks, in one place (android/docs/DESIGN.md "Vendor profiles"). Everything else in the app is
 * generic Android. A profile is chosen by Build.MANUFACTURER / Build.BRAND or by a known
 * package being installed (VendorProfiles.pick, unit-tested).
 *
 * - launcherPkg: the vendor's own launcher. On these readers it also "freezes" (disables) apps,
 *   so it is named as the likely disabler and its freeze page is opened to undo it.
 * - home: the vendor launcher's home activity, shown as a "<name> home" tile on the apps page.
 * - freezeHint: where the user re-enables a frozen app, in the vendor's own words.
 */
data class VendorProfile(
    val id: String,
    val name: String,
    val manufacturers: List<String>,
    val launcherPkg: String?,
    val home: ComponentName?,
    val freezeHint: String?,
    val verified: Boolean,
    /** The vendor's own reader app(s), listed first in "Home opens". */
    val readerPkgs: List<String> = emptyList(),
    /** Clicker page taps per reader app (package -> next/prev -> zone); users can override them. */
    val tapZones: Map<String, Map<ClickAction, Zone>> = emptyMap(),
    /** Settings.System key that says whether the frontlight is on (battery stats), or null. */
    val lightKey: String? = null,
)

/** Well-known reader apps by package name, listed first in "Home opens" (unverified ones are harmless). */
object KnownApps {
    val READERS = setOf(
        "com.bilingify.readest", // Readest
        "com.flyersoft.moonreader", "com.flyersoft.moonreaderp", // Moon+ Reader (free, Pro)
        "org.readera", "org.readera.premium", // ReadEra
        "com.foobnix.pdf.reader", "com.foobnix.pro.pdf.reader", // Librera
        "org.geometerplus.zlibrary.ui.android", // FBReader
        "com.amazon.kindle", "com.kobobooks.android", "com.google.android.apps.books",
        "com.obreey.reader", // PocketBook
        "com.neverland.alreader", // AlReader
        "com.faultexception.reader", // Lithium
        "com.rookiestudio.perfectviewer", // Perfect Viewer (comics)
        "app.mihon", "eu.kanade.tachiyomi", // Mihon / Tachiyomi (manga)
    )

    fun readers(profile: VendorProfile): Set<String> = READERS + profile.readerPkgs
}

object VendorProfiles {
    /**
     * Meebook (Haoqing), measured on an M8C: the launcher com.haoqing.app.hqreader has "Freeze
     * management" (LauncherAppFreezeFragment, "automatically_freeze" after install) and disables
     * apps with setApplicationEnabledSetting (dumpsys: enabled=2, lastDisabledCaller = it).
     */
    val HAOQING = VendorProfile(
        id = "haoqing",
        name = "Meebook",
        manufacturers = listOf("haoqing", "meebook"),
        launcherPkg = "com.haoqing.app.hqreader",
        home = ComponentName("com.haoqing.app.hqreader", "com.haoqing.app.hqreader.view.activity.LauncherActivity"),
        freezeHint = "Freeze management",
        verified = true,
        // Read on an M8C with `settings list system` (also haoqing_warm_light, key_warm_value,
        // key_cold_value); the meaning is inferred from the name and the light being on.
        lightKey = "isLightOn",
        // The reader is part of the vendor launcher on the M8C.
        readerPkgs = listOf("com.haoqing.app.hqreader"),
        // Unverified: the Meebook reader turns pages on side taps like most readers.
        tapZones = mapOf("com.haoqing.app.hqreader" to mapOf(ClickAction.NEXT to Zone.RIGHT_THIRD, ClickAction.PREV to Zone.LEFT_THIRD)),
    )

    /**
     * Boox (Onyx), UNVERIFIED stub: Boox documents an app freeze under Apps › App Management ›
     * Freeze Settings (help.boox.com/hc/en-us/articles/8569441562004), and owners report frozen
     * apps show as disabled. The launcher package "com.onyx" is from community reports, not
     * checked on a device; home is unknown, so no tile.
     */
    val ONYX = VendorProfile(
        id = "onyx",
        name = "Boox",
        manufacturers = listOf("onyx", "boox"),
        launcherPkg = "com.onyx",
        home = null,
        freezeHint = "Apps › App Management › Freeze Settings",
        verified = false,
        readerPkgs = listOf("com.onyx.kreader"),
    )

    val GENERIC = VendorProfile("generic", "Android", emptyList(), null, null, null, verified = true)

    val ALL = listOf(HAOQING, ONYX)

    /** By manufacturer or brand first, then by the vendor launcher being installed. */
    fun pick(manufacturer: String?, brand: String?, installed: (String) -> Boolean): VendorProfile {
        val ids = listOfNotNull(manufacturer, brand).map { it.lowercase() }
        ALL.firstOrNull { p -> p.manufacturers.any { m -> ids.any { it.contains(m) } } }?.let { return it }
        ALL.firstOrNull { p -> p.launcherPkg != null && installed(p.launcherPkg) }?.let { return it }
        return GENERIC
    }
}

/** The profile for this device, and what it means for the UI. */
object Vendor {
    @Volatile
    private var cached: VendorProfile? = null

    fun profile(ctx: Context): VendorProfile = cached ?: VendorProfiles.pick(Build.MANUFACTURER, Build.BRAND) {
        Net.installed(ctx, it)
    }.also {
        cached = it
        OLog.i("vendor profile: ${it.id} (${Build.MANUFACTURER}/${Build.BRAND})${if (it.verified) "" else " [unverified]"}")
    }

    /** The vendor launcher's label, read at run time (e.g. "Meebook Launcher"); null if none. */
    fun disablerLabel(ctx: Context): String? {
        val pkg = profile(ctx).launcherPkg ?: return null
        return try {
            val pm = ctx.packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(pkg, PackageManager.MATCH_DISABLED_COMPONENTS)).toString()
        } catch (e: Exception) {
            null
        }
    }

    fun disabledMessage(ctx: Context, app: String): String =
        AppStates.disabledMessage(app, disablerLabel(ctx), profile(ctx).freezeHint)

    /** "<Vendor> home" tile, or null when the profile has none or it isn't installed. */
    fun homeTile(ctx: Context): Pair<String, ComponentName>? {
        val p = profile(ctx)
        val home = p.home ?: return null
        if (!Net.installed(ctx, home.packageName)) return null
        return "${p.name} home" to home
    }

    /** An exported freeze page in the vendor launcher, else the launcher, else Settings › Apps. */
    fun reenablePage(ctx: Context, appPkg: String? = null): Intent {
        val pkg = profile(ctx).launcherPkg
        if (pkg != null && Net.installed(ctx, pkg)) {
            val freeze = try {
                @Suppress("DEPRECATION")
                ctx.packageManager.getPackageInfo(pkg, PackageManager.GET_ACTIVITIES).activities.orEmpty()
                    .firstOrNull { it.exported && it.name.contains("freeze", ignoreCase = true) }
            } catch (e: Exception) {
                null
            }
            OLog.i("re-enable page: ${freeze?.name ?: "no exported freeze page; the vendor launcher"}")
            if (freeze != null) {
                return Intent(Intent.ACTION_MAIN).setComponent(ComponentName(pkg, freeze.name)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            ctx.packageManager.getLaunchIntentForPackage(pkg)?.let { return it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
            profile(ctx).home?.let { return Intent(Intent.ACTION_MAIN).setComponent(it).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
        }
        val i = if (appPkg != null) {
            Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:$appPkg"))
        } else {
            Intent(android.provider.Settings.ACTION_APPLICATION_SETTINGS)
        }
        return i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    /** Disabled apps among the three this setup needs. */
    fun disabledApps(ctx: Context): List<String> =
        listOf(Koreader.PKG to "KOReader", Net.TAILSCALE_PKG to "Tailscale", ctx.packageName to "BookSync")
            .filter { (pkg, _) -> Net.appState(ctx, pkg) == AppState.FROZEN }
            .map { it.second }
}
