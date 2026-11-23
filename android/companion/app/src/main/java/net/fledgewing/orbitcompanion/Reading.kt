package net.fledgewing.orbitcompanion

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper

/**
 * The one gate for "nothing interrupts reading" (ReadingLogic): every notification and every
 * page start the user didn't ask for goes through [show]. While reading it is held, and posted
 * at the next moment that isn't reading with the screen on; its action checks again that it is
 * still wanted (an update already installed, a step already fixed) and does nothing if not.
 * The reading state is kept in Prefs (the process may die between STATS); held actions live in
 * memory: their sources offer them again on the next evaluation.
 */
// Holds only the application context.
@SuppressLint("StaticFieldLeak")
object Reading {
    const val KEY_UPDATE = "update"
    const val KEY_SETUP = "setup"
    const val KEY_TAILSCALE = "tailscale"
    const val KEY_KEYBOARD = "keyboard"
    fun installKey(key: String) = "install:$key"

    private val main = Handler(Looper.getMainLooper())
    private val gate = ReadingGate()
    private val actions = HashMap<String, () -> Unit>()
    @SuppressLint("StaticFieldLeak")
    private var appCtx: Context? = null
    private val releaseTask = Runnable { appCtx?.let { release(it, "not reading") } }
    private val expiryTask = Runnable { appCtx?.let { release(it, "no reading report for ${ReadingLogic.FRESH_MS / 60_000} min") } }

    /** KOReader is in front with a book open in the foreground (as last reported). */
    fun now(ctx: Context): Boolean = ReadingLogic.reading(Prefs(ctx).readingAt, System.currentTimeMillis())

    /** [post] now when nobody is reading and the screen is on; else held under [key] until then. */
    @Synchronized
    fun show(ctx: Context, key: String, what: String, post: () -> Unit) {
        val app = ctx.applicationContext
        appCtx = app
        val reading = now(app)
        val screen = Net.screenOn(app)
        if (gate.offer(key, reading, screen)) {
            actions.remove(key)
            post()
            return
        }
        val first = key !in actions
        actions[key] = post
        if (first) OLog.i("reading gate: $what held (${if (reading) "reading" else "screen off"}): shown at the next moment that isn't reading")
        if (reading) scheduleExpiry(app)
    }

    /** No longer wanted: never posted. */
    @Synchronized
    fun drop(key: String) {
        if (gate.drop(key)) OLog.d("reading gate: $key dropped")
        actions.remove(key)
    }

    /** STATS from the plugin: reading=1|0 (0.11.1+), else derived from open and the reason. */
    fun onStats(ctx: Context, intent: Intent) {
        val reason = intent.getStringExtra("reason")
        val r = ReadingLogic.fromStats(reason, intent.getStringExtra("open"), intent.getStringExtra("reading")) ?: return
        set(ctx, r, "KOReader: ${reason ?: "stats"}")
    }

    /** A companion page came to the front: KOReader isn't. */
    fun onCompanionPage(ctx: Context) = set(ctx, false, "companion page")

    private fun set(ctx: Context, reading: Boolean, why: String) {
        val app = ctx.applicationContext
        appCtx = app
        val p = Prefs(app)
        val was = now(app)
        p.readingAt = if (reading) System.currentTimeMillis() else 0
        if (was != reading) OLog.d("reading gate: ${if (reading) "reading" else "not reading"} ($why)")
        if (reading) {
            main.removeCallbacks(releaseTask)
            scheduleExpiry(app)
        } else {
            main.removeCallbacks(releaseTask)
            main.postDelayed(releaseTask, ReadingLogic.SETTLE_MS)
        }
    }

    private fun scheduleExpiry(ctx: Context) {
        val at = ReadingLogic.expiresAt(Prefs(ctx).readingAt) ?: return
        main.removeCallbacks(expiryTask)
        main.postDelayed(expiryTask, (at - System.currentTimeMillis()).coerceAtLeast(0))
    }

    @Synchronized
    private fun release(ctx: Context, why: String) {
        val keys = gate.release(now(ctx), Net.screenOn(ctx))
        for (k in keys) {
            val a = actions.remove(k) ?: continue
            OLog.i("reading gate: $k shown now ($why)")
            try {
                a()
            } catch (e: Exception) {
                OLog.w("reading gate: $k failed", e)
            }
        }
    }
}
