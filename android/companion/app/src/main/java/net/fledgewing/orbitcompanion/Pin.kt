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

/** A companion page's place in the PIN flow (EinkActivity.pinPage). */
enum class PinPage {
    /** Behind the PIN; staying on these keeps an unlock. */
    PROTECTED,
    /** Neither: the keypad itself, licenses. */
    NEUTRAL,
    /** Launcher, status, setup…: showing one ends an unlock. */
    OPEN,
}

/**
 * Settings PIN runtime (android/docs/DESIGN.md "Settings PIN"). The hash and the back-off live in the
 * app's private prefs; the live state (PIN set, guard list, unlock) in one [PinGate] that every
 * gate reads, so a change counts at once. The unlock is memory only (a restart locks).
 */
object Pin {
    private val gate = PinGate()
    @Volatile
    private var loaded = false
    /** What to do after the PIN page's next success (same process). */
    private var pending: (() -> Unit)? = null

    private fun now() = SystemClock.elapsedRealtime()

    private fun live(ctx: Context): PinGate {
        if (!loaded) {
            synchronized(this) {
                if (!loaded) {
                    val p = Prefs(ctx)
                    gate.pinSet = p.pinHash.isNotEmpty()
                    gate.guarded = p.guardedApps?.let { migrate(ctx, p, it) } ?: defaultGuarded(ctx)
                    loaded = true
                }
            }
        }
        return gate
    }

    /** Saved entries from an older default (Guard.migrate): fixed and saved once, logged. */
    private fun migrate(ctx: Context, p: Prefs, saved: Set<String>): Set<String> {
        val homes = homePackages(ctx)
        if (saved.none { '/' !in it && Guard.neverWhole(it, homes) }) return saved
        val (next, dropped) = Guard.migrate(saved, homes, defaultGuarded(ctx))
        p.guardedApps = next
        OLog.i("pin: guarded apps migrated: removed ${dropped.joinToString()} (whole; it hosts the launcher or system UI), now ${next.joinToString()}")
        return next
    }

    /** Add-on without the PIN helper: the PIN is off (its hash is kept for when it comes back). */
    fun isSet(ctx: Context): Boolean = Mode.pinActive(ctx) && live(ctx).pinSet

    fun unlocked(): Boolean = watch().unlocked(now())

    fun locked(ctx: Context): Boolean = Mode.pinActive(ctx) && live(ctx).also { watch() }.locked(now())

    /** The hard cap applies only while the accessibility service can't see the user leave. */
    private fun watch(): PinGate = gate.also { it.watching = ClickerService.connected }

    fun backoff(ctx: Context): PinBackoff = Prefs(ctx).let { PinBackoff(it.pinFailures, it.pinLockedUntil) }

    /** Check an entered PIN; right: unlocked for [scope]. Returns null when right, else the message. */
    fun check(ctx: Context, pin: String, scope: Collection<String>): String? {
        val p = Prefs(ctx)
        val wall = System.currentTimeMillis()
        val b = backoff(ctx)
        val wait = b.waitMs(wall)
        if (wait > 0) return "Too many wrong tries. Wait ${(wait + 999) / 1000} s."
        if (PinHash.verify(pin, p.pinHash)) {
            save(p, b.success())
            live(ctx).unlock(now(), scope)
            OLog.i("pin: unlocked${if (scope.isEmpty()) "" else " for ${scope.joinToString()}"} (while inside, then ${PinGate.GRACE_MS / 60_000} min; screen-off locks)")
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

    /** Set from Settings (a protected page): live at once; this Settings visit stays unlocked. */
    fun set(ctx: Context, pin: String) {
        val p = Prefs(ctx)
        p.pinHash = PinHash.hash(pin)
        save(p, PinBackoff())
        live(ctx).pinSet = true
        gate.unlock(now())
        OLog.i("pin: set (live now; guarding ${gate.guarded.joinToString()})")
    }

    fun clear(ctx: Context, why: String) {
        val p = Prefs(ctx)
        p.pinHash = ""
        save(p, PinBackoff())
        live(ctx).pinSet = false
        gate.lock()
        OLog.i("pin: removed ($why)")
    }

    fun guarded(ctx: Context): Set<String> = live(ctx).guarded

    fun setGuarded(ctx: Context, entries: Set<String>) {
        Prefs(ctx).guardedApps = entries
        live(ctx).guarded = entries
    }

    fun onScreenOff() {
        if (gate.lock()) OLog.i("pin: locked (screen off)")
    }

    /** A companion page came to the front: protected → inside; open → the grace starts. */
    fun onPage(page: PinPage, name: String) {
        val t = now()
        when (page) {
            PinPage.PROTECTED -> watch().enter(t)
            PinPage.OPEN -> if (watch().leave(t)) OLog.i("pin: left to $name; unlocked for ${PinGate.GRACE_MS / 60_000} more min")
            PinPage.NEUTRAL -> Unit
        }
    }

    /** Run [action] now if no PIN is set or it's unlocked; else after the PIN page succeeds. */
    fun run(a: Activity, action: () -> Unit) {
        if (!locked(a)) return action()
        pending = action
        a.startActivity(PinActivity.intent(a, PinActivity.Mode.UNLOCK))
    }

    /** A Setup "Fix": behind the PIN; the page it opens joins the unlock (EinkActivity.tryStart). */
    fun fix(a: Activity, action: () -> Unit) = run(a, action)

    /** A page started while unlocked joins the unlock (Setup Fix targets, pages opened from Settings). */
    fun opened(pkg: String) {
        if (gate.addScope(pkg, now())) OLog.i("pin: $pkg joins the unlock")
    }

    /** The install window (Guard.installSurface): an install the companion starts, by [key]. */
    fun installStarted(key: String) {
        gate.installStarted(key, now())
        OLog.i("pin: install window open ($key)")
    }

    fun installEnded(key: String) {
        gate.installEnded(key, now())
        OLog.i("pin: install $key ended; window open ${Guard.INSTALL_GRACE_MS / 1000} s more")
    }

    internal fun succeeded() {
        val p = pending
        pending = null
        p?.invoke()
    }

    internal fun cancelled() {
        pending = null
    }

    private fun homes(ctx: Context): List<android.content.pm.ResolveInfo> =
        ctx.packageManager.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME), 0)

    /** Packages with the Home role (launchers). */
    fun homePackages(ctx: Context): Set<String> = homes(ctx).map { it.activityInfo.packageName }.toSet()

    fun homeComponents(ctx: Context): Set<String> = homes(ctx).map { Guard.component(it.activityInfo.packageName, it.activityInfo.name) }.toSet()

    /** Android Settings, by the screens its intents resolve to (Guard.settingsEntry). */
    fun defaultGuarded(ctx: Context): Set<String> {
        val pm = ctx.packageManager
        val homesP = homePackages(ctx)
        val intents = listOf(
            Intent(Settings.ACTION_SETTINGS), Intent(Settings.ACTION_WIRELESS_SETTINGS),
            Intent(Settings.ACTION_APPLICATION_SETTINGS), Intent(Settings.ACTION_MANAGE_APPLICATIONS_SETTINGS),
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:${ctx.packageName}")),
            Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS), Intent(Settings.ACTION_SECURITY_SETTINGS),
        )
        val found = intents.flatMap { i -> pm.queryIntentActivities(i, 0).map { it.activityInfo.packageName to it.activityInfo.name } }
            .filter { (pkg, _) -> Guard.canGuard(pkg, ctx.packageName) }
            .map { (pkg, cls) -> Guard.settingsEntry(pkg, cls, homesP) }
        return (found + Guard.SETTINGS_PKG).toSet().also { OLog.i("pin: Android Settings guard entries: ${it.joinToString()}") }
    }

    private val launchable = HashMap<String, Boolean>()
    private var homeCache: Pair<Set<String>, Set<String>>? = null
    private var imeCache: Set<String>? = null

    /** The accessibility service saw [pkg]/[cls] come to the front: end an unlock that it leaves, then gate. */
    fun onForeground(ctx: Context, pkg: String, cls: String?): Guard.Decision {
        val g = live(ctx)
        if (!g.pinSet) return Guard.Decision.ALLOW
        val (hp, hc) = homeCache ?: (homePackages(ctx) to homeComponents(ctx)).also { homeCache = it }
        g.homePkgs = hp
        val ime = imeCache ?: try {
            (ctx.getSystemService(Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager)
                .inputMethodList.map { it.packageName }.toSet()
        } catch (e: Exception) {
            emptySet()
        }.also { imeCache = it }
        val canLaunch = synchronized(launchable) {
            launchable.getOrPut(pkg) { ctx.packageManager.getLaunchIntentForPackage(pkg) != null }
        }
        val fg = Guard.classify(pkg, cls, ctx.packageName, hc, hp, ime, canLaunch, g.guarded)
        val prev = prevFg
        val prevP = prevPkg
        prevFg = fg
        prevPkg = if (fg == null) null else pkg
        if (fg == null) return Guard.Decision.ALLOW
        val t = now()
        watch()
        if (g.onForeground(fg, pkg, cls, t)) OLog.i("pin: left to $pkg/$cls ($fg); unlocked for ${PinGate.GRACE_MS / 60_000} more min")
        val d = Popup.decide(g.decide(pkg, cls, ctx.packageName, t), prev, prevP, pkg, t, lastTapAt)
        OLog.d("pin: gate $pkg/$cls ($fg, after ${prevP ?: "-"}) -> $d")
        return d
    }

    /** What was in front before the current window (Popup). */
    @Volatile
    private var prevFg: Fg? = null
    @Volatile
    private var prevPkg: String? = null
    @Volatile
    private var lastTapAt = 0L

    /** A tap (accessibility click) in [pkg]: one on a launcher, recents or the companion opens apps. */
    fun onTap(ctx: Context, pkg: String) {
        val hp = homeCache?.first ?: homePackages(ctx)
        if (pkg in hp || pkg == Guard.SYSTEM_UI || pkg == ctx.packageName) lastTapAt = now()
    }

    /** Home role or launch intents changed (rare): forget the caches. */
    fun packagesChanged() {
        homeCache = null
        imeCache = null
        synchronized(launchable) { launchable.clear() }
    }
}

/** The full-screen keypad: unlock, set a new PIN (twice), or the guard's cover over an app. */
class PinActivity : EinkActivity() {
    enum class Mode { UNLOCK, SET, GUARD }

    override val pinPage = PinPage.NEUTRAL

    companion object {
        const val SHOW_PIN = "${Contract.PACKAGE}.action.SHOW_PIN"

        /** The page an update install was started from (UpdateReturn); none from the notification. */
        const val EXTRA_FROM = "update_from"

        fun intent(ctx: Context, mode: Mode, guarded: String? = null, cls: String? = null): Intent =
            Intent(ctx, PinActivity::class.java).putExtra("mode", mode.name).putExtra("guarded", guarded).putExtra("guarded_cls", cls)

        /** The keypad's name for the app in front (Guard.label): its screen's label, else the app's. */
        fun guardLabel(ctx: Context, pkg: String, cls: String?): String? {
            val pm = ctx.packageManager
            val activity = cls?.let {
                try {
                    pm.getActivityInfo(android.content.ComponentName(pkg, it), android.content.pm.PackageManager.MATCH_DISABLED_COMPONENTS).loadLabel(pm).toString()
                } catch (e: Exception) {
                    null
                }
            }
            return Guard.label(activity, HomeTarget.label(ctx, pkg), pkg, cls)
        }

        /** The update-ready notification: PIN first, then Android's install prompt. The prompt
         * itself stays in memory (Updater.pendingConfirm), never taken from an extra. */
        fun thenInstall(ctx: Context, confirm: Intent): Intent {
            Updater.pendingConfirm = confirm
            // Status's Install button names its page; the notification (over KOReader) names none (UpdateReturn).
            val from = (ctx as? Activity)?.javaClass?.name
            return intent(ctx, Mode.UNLOCK).putExtra("install", true).putExtra(EXTRA_FROM, from).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
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
        if (intent.getBooleanExtra("install", false)) {
            // Finishing an update: Android's own confirm follows; it changes no setting, so no PIN.
            OLog.i("pin: update install: no keypad")
            installNow()
            finish()
            return
        }
        if (mode != Mode.SET && !Pin.locked(this)) {
            OLog.i("pin: keypad not needed (no PIN or unlocked)")
            done()
        }
    }

    private fun installNow() {
        val confirm = Updater.pendingConfirm
        Updater.pendingConfirm = null
        if (confirm != null) {
            Prefs(this).userUpdateAt = System.currentTimeMillis()
            UpdateReturn.mark(this, intent.getStringExtra(EXTRA_FROM))
            Pin.installStarted(Updater.INSTALL_KEY)
            tryStart(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), "the install prompt")
        } else {
            OLog.i("pin: install prompt gone (app restarted); check for updates again")
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
                Prefs(this).userUpdateAt = System.currentTimeMillis()
                UpdateReturn.mark(this, intent.getStringExtra(EXTRA_FROM))
                Pin.installStarted(Updater.INSTALL_KEY)
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
        Mode.GUARD -> "PIN to open ${intent.getStringExtra("guarded")?.let { guardLabel(this, it, intent.getStringExtra("guarded_cls")) } ?: "this app"}"
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
        val scope = when {
            mode == Mode.GUARD -> listOfNotNull(intent.getStringExtra("guarded"))
            intent.action == SHOW_PIN -> listOf(Koreader.PKG) // KOReader's Android sync menu
            else -> emptyList()
        }
        val err = Pin.check(this, pin, scope)
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
        val settings = Pin.defaultGuarded(this)
        val homes = Pin.homePackages(this)
        val guarded = Pin.guarded(this)
        root.addView(Ui.row(this, "Android Settings", settings.joinToString(), Ui.toggle(this, settings.all { it in guarded }), onClick = {
            val now = Pin.guarded(this)
            val on = settings.all { it in now }
            Pin.setGuarded(this, if (on) now - settings else now + settings)
            OLog.i("pin: guard ${if (on) "off" else "on"} for Android Settings")
            render()
        }))
        // Whole apps only; a launcher (Home role) is never guarded whole.
        val apps = pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
            .map { it.activityInfo.packageName to it.loadLabel(pm).toString() }
            .filter { (pkg, _) -> Guard.canGuard(pkg, packageName) && pkg !in homes && pkg !in settings }
            .distinctBy { it.first }
            .sortedBy { it.second.lowercase() }
        apps.forEach { (pkg, label) ->
            root.addView(Ui.row(this, label, null, Ui.toggle(this, pkg in guarded), onClick = {
                val now = Pin.guarded(this)
                Pin.setGuarded(this, if (pkg in now) now - pkg else now + pkg)
                OLog.i("pin: guard ${if (pkg in now) "off" else "on"} for $pkg")
                render()
            }))
        }
        // Every other saved entry, even one the picker wouldn't offer, so any can be turned off.
        val shown = settings + apps.map { it.first }
        guarded.filter { it !in shown }.sorted().forEach { e ->
            val pkg = e.substringBefore('/')
            val cls = e.substringAfter('/', "").ifEmpty { null }
            val name = PinActivity.guardLabel(this, pkg, cls) ?: e
            root.addView(Ui.row(this, name, e, Ui.toggle(this, true), onClick = {
                Pin.setGuarded(this, Pin.guarded(this) - e)
                OLog.i("pin: guard off for $e")
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
