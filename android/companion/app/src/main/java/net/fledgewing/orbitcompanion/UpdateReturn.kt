package net.fledgewing.orbitcompanion

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.SystemClock

/**
 * Where an app update the user started came from, so it finishes there (M8C 11-23 22:47:
 * Update tapped on the Status page, and the user landed in KOReader). Android kills the old
 * process and every page with it ("app died, no saved state"); the new process reads the mark
 * in [onReplaced] and reopens that page, which shows the result ("Updated to v…"). From a page,
 * KOReader's restart for the new patch waits for the next screen-off instead of coming to the
 * front ([restartNow]). An update started outside our pages (the update-ready notification,
 * shown over KOReader) keeps the restart at once and returns to KOReader as before.
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

    /** Pure: the page class to reopen, or null (started elsewhere, no mark, or too old). */
    fun page(from: String?, atMs: Long, nowMs: Long, pkg: String): String? = from?.takeIf {
        it.startsWith("$pkg.") && atMs > 0 && nowMs - atMs in 0..UpdateFlow.USER_UPDATE_MS
    }

    /** Pure: KOReader restarts at once after the patch install only when the user confirmed it away from our pages. */
    fun restartNow(userConfirmed: Boolean, fromPage: Boolean): Boolean = userConfirmed && !fromPage

    /** The user started an update from [from] (one of our pages), or from elsewhere (null). */
    fun mark(ctx: Context, from: Activity?) = mark(ctx, from?.javaClass?.name)

    fun mark(ctx: Context, from: String?) {
        val name = from ?: ELSEWHERE
        prefs(ctx).edit().putString(KEY_FROM, name).putLong(KEY_AT, System.currentTimeMillis()).apply()
        OLog.i("update: started from ${name.substringAfterLast('.')}")
    }

    @Volatile
    private var replaced: String? = null

    @Volatile
    private var handled = false

    @Volatile
    private var reopenedAt = 0L

    @Volatile
    private var homeShown = false

    /**
     * MY_PACKAGE_REPLACED (Updater.onReplaced, may arrive twice): takes the mark once per process
     * and reopens its page. Returns the page (also on a repeat call), or null.
     */
    @Synchronized
    fun onReplaced(ctx: Context): String? {
        if (handled) return replaced
        handled = true
        val sp = prefs(ctx)
        replaced = page(sp.getString(KEY_FROM, null), sp.getLong(KEY_AT, 0), System.currentTimeMillis(), ctx.packageName)
        sp.edit().clear().apply()
        val p = replaced ?: return null
        reopenedAt = SystemClock.elapsedRealtime()
        open(ctx, p, "after the update")
        return p
    }

    /** The update was started from one of our pages (after [onReplaced] ran in this process). */
    fun fromPage(): Boolean = replaced != null

    /** HomeActivity's first decision right after the reopen: the page again, once, never KOReader. */
    @Synchronized
    fun forHome(nowElapsed: Long = SystemClock.elapsedRealtime()): String? {
        val p = replaced ?: return null
        if (homeShown || nowElapsed - reopenedAt !in 0..HOME_HOLD_MS) return null
        homeShown = true
        return p
    }

    fun open(ctx: Context, page: String, why: String): Boolean = try {
        ctx.startActivity(Intent().setClassName(ctx.packageName, page).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION))
        OLog.i("update: back to ${page.substringAfterLast('.')} ($why)")
        true
    } catch (e: Exception) {
        OLog.w("update: could not reopen $page ($why)", e)
        false
    }

    /** For tests: a fresh process. */
    @Synchronized
    internal fun reset(ctx: Context) {
        replaced = null
        handled = false
        reopenedAt = 0
        homeShown = false
        prefs(ctx).edit().clear().commit()
    }

    private fun prefs(ctx: Context) = ctx.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
}
