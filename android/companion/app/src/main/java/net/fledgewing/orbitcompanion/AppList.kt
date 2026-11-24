package net.fledgewing.orbitcompanion

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.os.SystemClock

/** One launchable activity on the launcher's app list. [frozen]: its app is disabled (a vendor freeze). */
data class AppEntry(val pkg: String, val cls: String, val label: String, val frozen: Boolean = false)

/** The app list's rules: which activities are listed, their labels, merges and refreshes. Pure. */
object AppListLogic {
    /**
     * An activity found with MATCH_DISABLED_COMPONENTS is listed when a plain query also finds it,
     * or when its whole app is disabled: a vendor freeze (Boox, Meebook) disables the app, which
     * hides it from a plain query until it is unfrozen. An activity that its own enabled app
     * turned off (an icon alias) stays out.
     */
    fun listed(resolvesEnabled: Boolean, appFrozen: Boolean): Boolean = resolvesEnabled || appFrozen

    /** A label that failed to load, or is blank, falls back to the package name: never dropped. */
    fun label(loaded: String?, pkg: String): String = loaded?.trim()?.takeIf { it.isNotEmpty() } ?: pkg

    /**
     * The fresh query, plus the previous entries of packages that are being replaced (an update:
     * PACKAGE_REMOVED with EXTRA_REPLACING until PACKAGE_ADDED) and so missing from it for a moment.
     * One row per activity, A–Z.
     */
    fun merge(fresh: List<AppEntry>, previous: List<AppEntry>, replacing: Set<String>): List<AppEntry> {
        val freshPkgs = fresh.mapTo(HashSet()) { it.pkg }
        val kept = previous.filter { it.pkg in replacing && it.pkg !in freshPkgs }
        return (fresh + kept).distinctBy { it.pkg to it.cls }.sortedWith(compareBy({ it.label.lowercase() }, { it.pkg }, { it.cls }))
    }

    /** How many rows fit: those whose bottom is inside [height]. At least one, so a page always shows. */
    fun fits(rowBottoms: List<Int>, height: Int): Int = maxOf(1, rowBottoms.count { it <= height })
}

/** Packages in the middle of an update, from the package broadcasts. */
class ReplaceWindow {
    private val open = HashSet<String>()

    val packages: Set<String> get() = synchronized(open) { open.toSet() }

    fun onEvent(action: String?, pkg: String?, replacing: Boolean) {
        if (pkg == null) return
        synchronized(open) {
            when (action) {
                Intent.ACTION_PACKAGE_REMOVED -> if (replacing) open.add(pkg) else open.remove(pkg)
                Intent.ACTION_PACKAGE_ADDED, Intent.ACTION_PACKAGE_REPLACED, Intent.ACTION_PACKAGE_FULLY_REMOVED -> open.remove(pkg)
            }
        }
    }
}

/**
 * The launcher's list of launchable apps (Other apps, Home opens). Built on the main thread on each
 * resume and each package broadcast, so the newest load is always the one shown. LauncherApps is
 * not used: it hides frozen apps exactly as a plain query does.
 */
object AppList {
    private val replace = ReplaceWindow()

    @Volatile
    private var last: List<AppEntry> = emptyList()

    /** Every broadcast that can change the list. */
    fun filter(): IntentFilter = IntentFilter().apply {
        addAction(Intent.ACTION_PACKAGE_ADDED)
        addAction(Intent.ACTION_PACKAGE_REMOVED)
        addAction(Intent.ACTION_PACKAGE_FULLY_REMOVED)
        addAction(Intent.ACTION_PACKAGE_CHANGED)
        addAction(Intent.ACTION_PACKAGE_REPLACED)
        addDataScheme("package")
    }

    /** Suspend, unsuspend and media changes carry no package data, so they need their own filter. */
    fun bareFilter(): IntentFilter = IntentFilter().apply {
        addAction(Intent.ACTION_PACKAGES_SUSPENDED)
        addAction(Intent.ACTION_PACKAGES_UNSUSPENDED)
        addAction(Intent.ACTION_EXTERNAL_APPLICATIONS_AVAILABLE)
        addAction(Intent.ACTION_EXTERNAL_APPLICATIONS_UNAVAILABLE)
    }

    fun onPackageEvent(i: Intent) {
        val pkg = i.data?.schemeSpecificPart
        val replacing = i.getBooleanExtra(Intent.EXTRA_REPLACING, false)
        replace.onEvent(i.action, pkg, replacing)
        OLog.i("apps list: ${i.action?.substringAfterLast('.')} ${pkg ?: "-"}${if (replacing) " (replacing)" else ""}")
    }

    /** A receiver that records the event and then calls [onChange]; register it with both filters. */
    fun receiver(onChange: () -> Unit): BroadcastReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            onPackageEvent(i)
            onChange()
        }
    }

    fun register(ctx: Context, r: BroadcastReceiver) {
        ctx.registerReceiver(r, filter())
        ctx.registerReceiver(r, bareFilter())
    }

    /** [labelOf] is a seam for tests; a throw or null there falls back to the package name. */
    fun load(ctx: Context, labelOf: (ResolveInfo) -> CharSequence? = { it.loadLabel(ctx.packageManager) }): List<AppEntry> {
        val t0 = SystemClock.elapsedRealtime()
        val pm = ctx.packageManager
        val main = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val enabled = pm.queryIntentActivities(main, 0).mapTo(HashSet()) { it.activityInfo.packageName to it.activityInfo.name }
        val frozenByPkg = HashMap<String, Boolean>()
        val fresh = pm.queryIntentActivities(main, PackageManager.MATCH_DISABLED_COMPONENTS).mapNotNull { r ->
            val a = r.activityInfo
            if (a.packageName == ctx.packageName) return@mapNotNull null
            val frozen = frozenByPkg.getOrPut(a.packageName) { Net.appState(ctx, a.packageName) == AppState.FROZEN }
            if (!AppListLogic.listed((a.packageName to a.name) in enabled, frozen)) return@mapNotNull null
            val loaded = try {
                labelOf(r)?.toString()
            } catch (e: Exception) {
                OLog.w("apps list: label of ${a.packageName} failed, showing the package name", e)
                null
            }
            AppEntry(a.packageName, a.name, AppListLogic.label(loaded, a.packageName), frozen)
        }
        val replacing = replace.packages
        val merged = AppListLogic.merge(fresh, last, replacing)
        last = merged
        val held = merged.size - fresh.distinctBy { it.pkg to it.cls }.size
        OLog.d(
            "apps list: ${merged.size} apps (${merged.count { it.frozen }} frozen" +
                "${if (held > 0) ", $held kept while updating" else ""}) in ${OLog.since(t0)} ms",
        )
        return merged
    }

    /** Tests only: forget the previous list and open replace windows. */
    internal fun reset() {
        last = emptyList()
        replace.packages.forEach { replace.onEvent(Intent.ACTION_PACKAGE_FULLY_REMOVED, it, false) }
    }
}
