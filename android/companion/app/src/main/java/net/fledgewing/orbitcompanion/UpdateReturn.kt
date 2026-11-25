package net.fledgewing.orbitcompanion

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.SystemClock

/**
 * Where an app update the user started came from, so it finishes there (M8C 11-23 22:47:
 * Update tapped on the Status page, and the user landed in KOReader). Android kills the old
 * process and every page with it ("app died, no saved state"); the new process reads the mark
 * in [onReplaced] and reopens those pages, which show the result ("Updated to v…").
 *
 * The mark is the page's whole back stack, each page with its extras (M8C 11-24 15:55: an
 * update from Settings › Updates reopened a bare SettingsSectionActivity, so the wrong section,
 * and Back from it fell out to KOReader). It lands once: after the reopened page has shown, a
 * Home press is an ordinary Home press ([forHome]).
 *
 * From a page, KOReader's restart for the new patch never brings it to the front ([restartNow]):
 * the plugin quits it in the background and the new patch loads at its next start. An update
 * started outside our pages (the update-ready notification, shown over KOReader) keeps the
 * restart at once and returns to KOReader as before.
 * Kept in its own preferences file: the mark must outlive the process that wrote it.
 */
object UpdateReturn {
    /** The mark for an update started outside our pages. */
    const val ELSEWHERE = "elsewhere"

    /** After the reopen, the system's Home relaunch (HomeActivity) shows the page, not KOReader. */
    const val HOME_HOLD_MS = 15_000L

    private const val FILE = "update_return"
    private const val KEY_FROM = "from"
    private const val KEY_AT = "at"

    /** The mark for an update started on [top]: its back stack, one intent URI per line. */
    fun encode(top: Activity): String = encode(EinkActivity.returnStack(top))

    fun encode(pages: List<Intent>): String = pages.joinToString("\n") { it.toUri(0) }

    /**
     * Pure: the pages a mark names, oldest first, each rebuilt as our own class plus its extras.
     * A line naming anything else drops the whole mark (the top page must be ours). A bare class
     * name (marks written by v0.11.3-rc.8 and older) is read as that page with no extras.
     */
    fun decode(from: String?, pkg: String): List<Intent> {
        if (from.isNullOrEmpty() || from == ELSEWHERE) return emptyList()
        val pages = from.split('\n').filter { it.isNotBlank() }.map { line ->
            val parsed = if ("#Intent;" in line) runCatching { Intent.parseUri(line, 0) }.getOrNull() ?: return emptyList() else null
            val cls = parsed?.component?.let { if (it.packageName == pkg) it.className else null } ?: if (parsed == null) line else return emptyList()
            if (!cls.startsWith("$pkg.") || !isPage(cls)) return emptyList()
            Intent().setClassName(pkg, cls).apply { parsed?.extras?.let { putExtras(it) } }
        }
        return pages
    }

    private fun isPage(cls: String): Boolean = runCatching {
        val c = Class.forName(cls)
        EinkActivity::class.java.isAssignableFrom(c) && c != PinActivity::class.java
    }.getOrDefault(false)

    /** Pure: the pages to reopen, or empty (started elsewhere, no mark, foreign, or too old). */
    fun pages(from: String?, atMs: Long, nowMs: Long, pkg: String): List<Intent> =
        if (atMs > 0 && nowMs - atMs in 0..UpdateFlow.USER_UPDATE_MS) decode(from, pkg) else emptyList()

    /** Pure: KOReader restarts at once after the patch install only when the user confirmed it away from our pages. */
    fun restartNow(userConfirmed: Boolean, fromPage: Boolean): Boolean = userConfirmed && !fromPage

    /** The user started an update from [from] (one of our pages), or from elsewhere (null). */
    fun mark(ctx: Context, from: Activity?) = mark(ctx, from?.let { encode(it) })

    /** [from]: an [encode]d mark, or null for elsewhere. */
    fun mark(ctx: Context, from: String?) {
        val value = from?.takeIf { it.isNotEmpty() } ?: ELSEWHERE
        prefs(ctx).edit().putString(KEY_FROM, value).putLong(KEY_AT, System.currentTimeMillis()).apply()
        OLog.i("update: started from ${describe(decode(value, ctx.packageName)) ?: ELSEWHERE}")
    }

    @Volatile
    private var replaced: List<Intent> = emptyList()

    @Volatile
    private var handled = false

    @Volatile
    private var reopenedAt = 0L

    /** The reopened page has shown: the return is done, nothing reopens it again. */
    @Volatile
    private var landed = false

    /**
     * MY_PACKAGE_REPLACED (Updater.onReplaced, may arrive twice): takes the mark once per process
     * and reopens its pages. Returns the top page's class (also on a repeat call), or null.
     */
    @Synchronized
    fun onReplaced(ctx: Context): String? {
        if (handled) return top()
        handled = true
        val sp = prefs(ctx)
        replaced = pages(sp.getString(KEY_FROM, null), sp.getLong(KEY_AT, 0), System.currentTimeMillis(), ctx.packageName)
        sp.edit().clear().apply()
        if (replaced.isEmpty()) return null
        reopenedAt = SystemClock.elapsedRealtime()
        open(ctx, replaced, "after the update")
        return top()
    }

    private fun top(): String? = replaced.lastOrNull()?.component?.className

    /** The update was started from one of our pages (after [onReplaced] ran in this process). */
    fun fromPage(): Boolean = replaced.isNotEmpty()

    fun awaitingLanding(): Boolean = replaced.isNotEmpty() && !landed && SystemClock.elapsedRealtime() - reopenedAt in 0..HOME_HOLD_MS

    /** A page resumed (EinkActivity): once the reopened page shows, the return has landed. */
    fun onPageShown(a: Activity) {
        if (!landed && replaced.isNotEmpty() && a.javaClass.name == top()) {
            landed = true
            OLog.i("update: landed on ${a.javaClass.simpleName}")
        }
    }

    /**
     * HomeActivity's decision right after the reopen: the system's Home relaunch must not cover
     * the reopened page with KOReader. Only before that page has shown; after it, a Home
     * press is the user's and goes where Home always goes (M8C 11-24 15:56:01: it reopened the
     * page a second time).
     */
    @Synchronized
    fun forHome(nowElapsed: Long = SystemClock.elapsedRealtime()): List<Intent>? {
        if (replaced.isEmpty() || landed || nowElapsed - reopenedAt !in 0..HOME_HOLD_MS) return null
        return replaced
    }

    /**
     * Reopens [pages] as one task, oldest first, so Back walks them as before the update.
     * [reuse]: when the reopened page's task is still there (Home covered it), bring it forward.
     */
    fun open(ctx: Context, pages: List<Intent>, why: String, reuse: Boolean = false): Boolean = try {
        if (reuse) {
            // startActivities was already dispatched by onReplaced. A Home relaunch may race
            // its first resume, before appTasks exposes the top page: never dispatch it twice.
            val moved = bringToFront(ctx, pages)
            OLog.i("update: ${if (moved) "back to" else "waiting for"} ${describe(pages)} ($why, already dispatched)")
        } else {
            val list = pages.mapIndexed { i, p ->
                Intent(p).addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION or if (i == 0) Intent.FLAG_ACTIVITY_NEW_TASK else 0)
            }
            ctx.startActivities(list.toTypedArray())
            OLog.i("update: back to ${describe(pages)} ($why)")
        }
        true
    } catch (e: Exception) {
        OLog.w("update: could not reopen ${describe(pages)} ($why)", e)
        false
    }

    /** The reopened page's task is still there (only covered): to the front, no second copy. */
    private fun bringToFront(ctx: Context, pages: List<Intent>): Boolean {
        val top = pages.lastOrNull()?.component ?: return false
        val am = ctx.getSystemService(ActivityManager::class.java) ?: return false
        val task = runCatching { am.appTasks }.getOrNull()?.firstOrNull { runCatching { it.taskInfo.topActivity == top }.getOrDefault(false) } ?: return false
        return runCatching { task.moveToFront() }.isSuccess
    }

    /** "Launcher › Settings › SettingsSection (section=updates)" for the log. */
    private fun describe(pages: List<Intent>): String? = pages.takeIf { it.isNotEmpty() }?.joinToString(" › ") { p ->
        val name = p.component?.className?.substringAfterLast('.')?.removeSuffix("Activity") ?: "?"
        val section = p.getStringExtra(SettingsPage.EXTRA_SECTION)
        if (section != null) "$name ($section)" else name
    }

    /** For tests: a fresh process. */
    @Synchronized
    internal fun reset(ctx: Context) {
        replaced = emptyList()
        handled = false
        reopenedAt = 0
        landed = false
        EinkActivity.forgetPages()
        prefs(ctx).edit().clear().commit()
    }

    private fun prefs(ctx: Context) = ctx.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
}
