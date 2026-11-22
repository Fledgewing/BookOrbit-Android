package net.fledgewing.orbitcompanion

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import android.view.Gravity
import android.view.ViewGroup
import android.widget.LinearLayout

/**
 * Settings PIN runtime (docs/DESIGN.md "Settings PIN"). The hash and the back-off live in the
 * app's private prefs; the unlock window lives in memory only (a restart locks).
 */
object Pin {
    private val session = PinSession()
    private val fixAllowed = HashMap<String, Long>()
    @Volatile
    private var selfUpdateUntil = 0L
    /** A Setup "Fix" is opening a page right now (EinkActivity.tryStart records it). */
    @Volatile
    var fixing = false
        private set
    /** What to do after the PIN page's next success (same process). */
    private var pending: (() -> Unit)? = null

    private fun now() = SystemClock.elapsedRealtime()

    fun isSet(ctx: Context): Boolean = Prefs(ctx).pinHash.isNotEmpty()

    fun unlocked(): Boolean = session.unlocked(now())

    fun locked(ctx: Context): Boolean = isSet(ctx) && !unlocked()

    fun backoff(ctx: Context): PinBackoff = Prefs(ctx).let { PinBackoff(it.pinFailures, it.pinLockedUntil) }

    /** Check an entered PIN. Returns null when right, else the message to show. */
    fun check(ctx: Context, pin: String): String? {
        val p = Prefs(ctx)
        val wall = System.currentTimeMillis()
        val b = backoff(ctx)
        val wait = b.waitMs(wall)
        if (wait > 0) return "Too many wrong tries. Wait ${(wait + 999) / 1000} s."
        if (PinHash.verify(pin, p.pinHash)) {
            save(p, b.success())
            session.unlock(now())
            OLog.i("pin: unlocked for ${PinSession.WINDOW_MS / 60_000} min")
            return null
        }
        val nb = b.fail(wall)
        save(p, nb)
        OLog.i("pin: wrong PIN (${nb.failures} in a row)")
        val w = nb.waitMs(wall)
        return if (w > 0) "Wrong PIN. Wait ${(w + 999) / 1000} s." else "Wrong PIN."
    }

    private fun save(p: Prefs, b: PinBackoff) {
        p.pinFailures = b.failures
        p.pinLockedUntil = b.lockedUntil
    }

    fun set(ctx: Context, pin: String) {
        val p = Prefs(ctx)
        p.pinHash = PinHash.hash(pin)
        save(p, PinBackoff())
        session.unlock(now())
        OLog.i("pin: set")
    }

    fun clear(ctx: Context, why: String) {
        val p = Prefs(ctx)
        p.pinHash = ""
        save(p, PinBackoff())
        session.lock()
        OLog.i("pin: removed ($why)")
    }

    /** Screen off: lock, and end any Setup-fix allowance. */
    fun onScreenOff() {
        if (session.unlocked(now())) OLog.i("pin: locked (screen off)")
        session.lock()
        synchronized(fixAllowed) { fixAllowed.clear() }
    }

    /** Run [action] now if no PIN is set or it's unlocked; else after the PIN page succeeds. */
    fun run(a: Activity, action: () -> Unit) {
        if (!locked(a)) return action()
        pending = action
        a.startActivity(PinActivity.intent(a, PinActivity.Mode.UNLOCK))
    }

    /** A Setup "Fix": behind the PIN; the page it opens is allowed by the guard for a while. */
    fun fix(a: Activity, action: () -> Unit) = run(a) {
        fixing = true
        try {
            action()
        } finally {
            fixing = false
        }
    }

    fun allowAfterFix(pkg: String) {
        synchronized(fixAllowed) { fixAllowed[pkg] = now() + Guard.FIX_WINDOW_MS }
        OLog.i("pin: guard allows $pkg for a Setup fix")
    }

    fun selfUpdateStarted() {
        selfUpdateUntil = now() + Guard.UPDATE_WINDOW_MS
    }

    internal fun succeeded() {
        val p = pending
        pending = null
        p?.invoke()
    }

    internal fun cancelled() {
        pending = null
    }

    /** Android's own Settings packages (and vendor equivalents): guarded by default. */
    fun settingsPackages(ctx: Context): Set<String> {
        val pm = ctx.packageManager
        val found = listOf(Settings.ACTION_SETTINGS, Settings.ACTION_WIRELESS_SETTINGS, Settings.ACTION_APPLICATION_SETTINGS)
            .flatMap { a -> pm.queryIntentActivities(Intent(a), 0).map { it.activityInfo.packageName } }
        return (found + "com.android.settings").filter { Guard.canGuard(it, ctx.packageName) }.toSet()
    }

    fun guarded(ctx: Context): Set<String> = Prefs(ctx).guardedApps ?: settingsPackages(ctx)

    fun decide(ctx: Context, pkg: String?): Guard.Decision {
        val t = now()
        val fix = synchronized(fixAllowed) { fixAllowed.filterValues { it > t }.keys }
        return Guard.decide(pkg, ctx.packageName, isSet(ctx), unlocked(), guarded(ctx), fix, selfUpdateUntil > t)
    }
}

/** The full-screen keypad: unlock, set a new PIN (twice), or the guard's cover over an app. */
class PinActivity : EinkActivity() {
    enum class Mode { UNLOCK, SET, GUARD }

    companion object {
        const val SHOW_PIN = "${Contract.PACKAGE}.action.SHOW_PIN"

        fun intent(ctx: Context, mode: Mode, guarded: String? = null): Intent =
            Intent(ctx, PinActivity::class.java).putExtra("mode", mode.name).putExtra("guarded", guarded)

        /** The update-ready notification: PIN first, then Android's install prompt. The prompt
         * itself stays in memory (Updater.pendingConfirm), never taken from an extra. */
        fun thenInstall(ctx: Context, confirm: Intent): Intent {
            Updater.pendingConfirm = confirm
            return intent(ctx, Mode.UNLOCK).putExtra("install", true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        @Volatile
        var showing = false
            private set
    }

    private var mode = Mode.UNLOCK
    private var entered = StringBuilder()
    private var first: String? = null
    private var message: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // SHOW_PIN (KOReader's locked menu) carries no mode: unlock. SET comes from Settings only,
        // which is behind the PIN; from outside it is treated as an unlock.
        val asked = runCatching { Mode.valueOf(intent.getStringExtra("mode") ?: "") }.getOrDefault(Mode.UNLOCK)
        mode = if (intent.action == SHOW_PIN || (asked == Mode.SET && Pin.locked(this))) Mode.UNLOCK else asked
        if (mode != Mode.SET && !Pin.locked(this)) {
            OLog.i("pin: keypad not needed (no PIN or unlocked)")
            done()
        }
    }

    /** Unlocked: the pending action, the install prompt, then close. */
    private fun done() {
        setResult(RESULT_OK)
        Pin.succeeded()
        if (intent.getBooleanExtra("install", false)) {
            val confirm = Updater.pendingConfirm
            Updater.pendingConfirm = null
            if (confirm != null) {
                Pin.selfUpdateStarted()
                tryStart(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), "the install prompt")
            } else {
                OLog.i("pin: install prompt gone (app restarted); check for updates again")
            }
        }
        finish()
    }

    override fun onResume() {
        super.onResume()
        showing = true
        render()
    }

    override fun onPause() {
        super.onPause()
        showing = false
    }

    private fun title() = when (mode) {
        Mode.SET -> if (first == null) "New PIN (4–8 digits)" else "Enter it again"
        Mode.GUARD -> "PIN to open ${intent.getStringExtra("guarded")?.let { HomeTarget.label(this, it) } ?: "this app"}"
        Mode.UNLOCK -> "Settings PIN"
    }

    private fun render() {
        val root = page()
        root.addView(Ui.header(this, title(), "Cancel") { cancel() })
        root.addView(Ui.text(this, if (entered.isEmpty()) " " else "●".repeat(entered.length).toCharArray().joinToString(" "), 40f, bold = true).apply {
            gravity = Gravity.CENTER
        })
        root.addView(Ui.text(this, message ?: " ", 18f, color = Ui.MID).apply { gravity = Gravity.CENTER })
        root.addView(Ui.gap(this, 8))
        val keys = listOf(listOf("1", "2", "3"), listOf("4", "5", "6"), listOf("7", "8", "9"), listOf("⌫", "0", "OK"))
        keys.forEach { row ->
            val views = row.map { k -> Ui.button(this, k, solid = k == "OK", heightDp = 96, sp = 32f) { key(k) } }
            root.addView(Ui.weightRow(this, *views.toTypedArray()), LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = Ui.dp(this@PinActivity, 10)
            })
        }
    }

    private fun key(k: String) {
        when (k) {
            "⌫" -> if (entered.isNotEmpty()) entered.setLength(entered.length - 1)
            "OK" -> return submit()
            else -> if (entered.length < 8) entered.append(k)
        }
        message = null
        render()
    }

    private fun submit() {
        val pin = entered.toString()
        entered = StringBuilder()
        if (mode == Mode.SET) {
            if (!PinHash.valid(pin)) {
                message = "4 to 8 digits"
            } else if (first == null) {
                first = pin
            } else if (first == pin) {
                Pin.set(this, pin)
                return done()
            } else {
                first = null
                message = "They didn't match. Start again."
            }
            return render()
        }
        val err = Pin.check(this, pin)
        if (err == null) return done()
        message = err
        render()
    }

    private fun cancel() {
        Pin.cancelled()
        setResult(RESULT_CANCELED)
        if (mode == Mode.GUARD) {
            // Cancel goes Home: the guarded app stays behind the lock.
            startActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        finish()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() = cancel()
}

/** Settings › Guarded apps: Android Settings by default, plus any launchable app. */
class GuardedAppsActivity : EinkActivity() {
    override val pinGuarded = true

    override fun onResume() {
        super.onResume()
        render()
    }

    private fun render() {
        val root = page(scroll = true)
        root.addView(Ui.header(this, "Guarded apps", "‹ Back") { finish() })
        root.addView(Ui.text(this, "With the PIN set, these open only after the PIN. Needs Settings › Accessibility › Orbit clicker buttons.", 16f, color = Ui.MID))
        val pm = packageManager
        val settings = Pin.settingsPackages(this)
        val apps = (pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
            .map { it.activityInfo.packageName to it.loadLabel(pm).toString() } + settings.map { it to HomeTarget.label(this, it) })
            .filter { Guard.canGuard(it.first, packageName) }
            .distinctBy { it.first }
            .sortedWith(compareBy({ it.first !in settings }, { it.second.lowercase() }))
        val guarded = Pin.guarded(this)
        apps.forEach { (pkg, label) ->
            root.addView(Ui.row(this, label, if (pkg in settings) "Android Settings" else null, Ui.toggle(this, pkg in guarded), onClick = {
                val now = Pin.guarded(this)
                Prefs(this).guardedApps = if (pkg in now) now - pkg else now + pkg
                OLog.i("pin: guard ${if (pkg in now) "off" else "on"} for $pkg")
                render()
            }))
        }
    }
}

/**
 * USB-only recovery: `adb shell am broadcast -n net.fledgewing.orbitcompanion/.PinResetReceiver
 * -a net.fledgewing.orbitcompanion.action.RESET_PIN`. The manifest requires DUMP, which only the
 * shell holds; on Android 14+ the sender uid is checked too (PinReset.allowed).
 */
class PinResetReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION = "${Contract.PACKAGE}.action.RESET_PIN"
    }

    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != ACTION) return
        val uid = if (Build.VERSION.SDK_INT >= 34) sentFromUid else null
        if (!PinReset.allowed(uid)) {
            OLog.w("pin: RESET_PIN refused (sender uid $uid is not the shell)")
            return
        }
        Pin.clear(ctx, "RESET_PIN over adb")
    }
}
