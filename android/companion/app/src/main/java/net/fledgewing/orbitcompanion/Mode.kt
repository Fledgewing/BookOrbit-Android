package net.fledgewing.orbitcompanion

import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.widget.LinearLayout
import kotlin.concurrent.thread

/**
 * Full and Add-on on the device (docs/design/addon-mode.md; the rules are AddonLogic's). Add-on
 * keeps the reader's own launcher: HomeActivity is disabled as a component, the service runs
 * only for a helper, and update checks and setup reminders run from a daily job.
 */
object Mode {
    fun mode(ctx: Context): OrbitMode? = Prefs(ctx).mode
    fun isAddon(ctx: Context): Boolean = Prefs(ctx).mode == OrbitMode.ADDON

    fun helpers(ctx: Context): Helpers {
        val p = Prefs(ctx)
        return Helpers(p.helperWifi, p.helperSleepSync, p.helperScreenOff, p.helperClicker, p.helperPin)
    }

    fun caps(ctx: Context): List<String> = ModeLogic.caps(mode(ctx), helpers(ctx), Net.adminActive(ctx))
    fun needsService(ctx: Context): Boolean = AddonLogic.needsService(mode(ctx), helpers(ctx))

    /** Orbit switches Wi-Fi: Full, or Add-on's Wi-Fi switching helper. */
    fun wifiAllowed(ctx: Context): Boolean = !isAddon(ctx) || Prefs(ctx).helperWifi

    /** The Settings PIN works: Full, or Add-on's PIN helper. Its hash is kept either way. */
    fun pinActive(ctx: Context): Boolean = !isAddon(ctx) || Prefs(ctx).helperPin

    private fun homeComponent(ctx: Context) = ComponentName(ctx, HomeActivity::class.java)

    fun homeEnabled(ctx: Context): Boolean =
        ctx.packageManager.getComponentEnabledSetting(homeComponent(ctx)) != PackageManager.COMPONENT_ENABLED_STATE_DISABLED

    fun setHomeEnabled(ctx: Context, on: Boolean) {
        ctx.packageManager.setComponentEnabledSetting(
            homeComponent(ctx),
            if (on) PackageManager.COMPONENT_ENABLED_STATE_DEFAULT else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP,
        )
        OLog.i("mode: Orbit's Home ${if (on) "enabled" else "disabled (Android's Home goes to the reader's launcher)"}")
    }

    fun isHome(ctx: Context): Boolean = ctx.packageManager.resolveActivity(
        Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME), PackageManager.MATCH_DEFAULT_ONLY,
    )?.activityInfo?.packageName == ctx.packageName

    fun otherHome(ctx: Context): Boolean = (Pin.homePackages(ctx) - ctx.packageName).isNotEmpty()

    /** Existing installs: Full when Orbit is Home or a Full-only step is done; else the choice shows. */
    fun migrate(ctx: Context, why: String) {
        val p = Prefs(ctx)
        if (p.mode != null) return
        val m = AddonLogic.migrate(null, isHome(ctx), Net.adminActive(ctx), ClickerStore.enabled(ctx)) ?: return
        p.mode = m
        OLog.i("mode: set to ${m.key} for an existing install ($why): no prompt")
    }

    /** Add-on: the daily job checks for updates and re-evaluates Setup (§7.2). */
    fun scheduleDaily(ctx: Context) {
        val js = ctx.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
        if (!isAddon(ctx)) {
            js.cancel(DailyJob.ID)
            return
        }
        if (js.getPendingJob(DailyJob.ID) != null) return
        val info = JobInfo.Builder(DailyJob.ID, ComponentName(ctx, DailyJob::class.java))
            .setPeriodic(24 * 60 * 60 * 1000L)
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setPersisted(true)
            .build()
        val r = js.schedule(info)
        OLog.i("mode: daily job ${if (r == JobScheduler.RESULT_SUCCESS) "scheduled" else "NOT scheduled"}")
    }

    /** What the service did for the app as a whole, when Add-on runs no service. */
    fun withoutService(ctx: Context, intent: Intent?, why: String) {
        val action = intent?.action
        OLog.i("mode: Add-on with no helper: no service (${Contract.shortName(action)}, $why)")
        when (action) {
            Intent.ACTION_MY_PACKAGE_REPLACED -> Updater.onReplaced(ctx)
        }
        scheduleDaily(ctx)
        Attention.evaluate(ctx.applicationContext, "add-on ${Contract.shortName(action ?: "start")}")
    }

    /** A helper changed (Settings): start or stop the service, tell the plugin. */
    fun helpersChanged(ctx: Context, why: String) {
        OLog.i("mode: helpers ${helpers(ctx)} ($why)")
        if (needsService(ctx)) OrbitService.start(ctx) else stopService(ctx)
        StatusFile.write(ctx, why)
        Attention.evaluate(ctx, why)
    }

    private fun stopService(ctx: Context) {
        if (!OrbitService.running) return
        try {
            ctx.startService(Intent(ctx, OrbitService::class.java).setAction(OrbitService.ACTION_MODE_CHANGED))
        } catch (e: Exception) {
            OLog.w("mode: could not reach the service to stop it", e)
        }
    }

    /** Runs a switch plan (AddonLogic.toAddon / toFull). Returns a note for the user, or null. */
    fun apply(a: EinkActivity, target: OrbitMode, keep: Helpers, steps: List<AddonLogic.Step>): String? {
        val p = Prefs(a)
        var note: String? = null
        OLog.i("mode: switch to ${target.key}: ${steps.joinToString()} (keep $keep)")
        for (s in steps) {
            when (s) {
                AddonLogic.Step.REFUSE_NO_HOME -> return "Your reader has no other Home app, so Orbit has to stay Home."
                AddonLogic.Step.SET_MODE -> {
                    p.mode = target
                    if (target == OrbitMode.ADDON) {
                        p.helperWifi = keep.wifi
                        p.helperSleepSync = keep.sleepSync
                        p.helperScreenOff = keep.screenOff
                        p.helperClicker = keep.clicker
                        p.helperPin = keep.pin
                    }
                }
                AddonLogic.Step.DISABLE_HOME -> setHomeEnabled(a, false)
                AddonLogic.Step.ENABLE_HOME -> setHomeEnabled(a, true)
                AddonLogic.Step.REMOVE_ADMIN -> runCatching {
                    (a.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager).removeActiveAdmin(AdminReceiver.component(a))
                    OLog.i("mode: lock-screen permission released")
                }.onFailure {
                    OLog.w("mode: device admin removal failed", it)
                    note = "Turn off Orbit in Settings › Security › Device admin apps."
                }
                AddonLogic.Step.STOP_ACCESSIBILITY -> {
                    val svc = ClickerService.instance
                    if (svc != null) {
                        svc.disableSelf()
                        OLog.i("mode: clicker accessibility service turned off")
                    } else {
                        OLog.i("mode: clicker service not connected; asking the user to turn it off")
                        note = "Turn off Orbit clicker in Accessibility."
                        a.tryStart(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS), "accessibility settings")
                    }
                }
                AddonLogic.Step.STOP_WIFI_TIMER, AddonLogic.Step.STOP_SERVICE -> stopService(a)
                AddonLogic.Step.START_SERVICE -> OrbitService.start(a)
                AddonLogic.Step.WRITE_STATUS -> {
                    scheduleDaily(a)
                    StatusFile.write(a, "mode ${target.key}")
                    Attention.evaluate(a, "mode ${target.key}")
                }
                AddonLogic.Step.OPEN_SETUP -> a.startActivity(Intent(a, SetupActivity::class.java))
            }
        }
        return note
    }
}

/** Add-on's daily job: the update check and the setup evaluation the service does in Full. */
class DailyJob : JobService() {
    companion object {
        const val ID = 4711
    }

    override fun onStartJob(params: JobParameters): Boolean {
        OLog.i("daily job: update check and setup")
        Handler(Looper.getMainLooper()).post {
            Updater.maybeAutoCheck(this, "daily job")
            Attention.evaluate(applicationContext, "daily job")
            jobFinished(params, false)
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean = false
}

/**
 * Restarts without the Home role (§7.4): the plugin starts this (KOReader is in front, so it may)
 * just before it quits; this invisible window then starts KOReader again once it has gone.
 */
class RelaunchActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setWindowAnimations(0)
        OLog.i("relaunch: KOReader is restarting; starting it again in 2.5 s")
        Handler(Looper.getMainLooper()).postDelayed({
            Koreader.start(this, "restart (add-on)", null)
            finish()
        }, 2_500)
    }
}

/**
 * The mode page (mockups 1 and 7): the first-run choice while no mode is set, else the switch
 * between Full and Add-on with what changes and which helpers to keep.
 */
class ModeActivity : EinkActivity() {
    override val pinGuarded get() = Prefs(this).mode != null
    private val keep = BooleanArray(4) // Wi-Fi switching, Sleep sync, Clicker buttons, Settings PIN

    override fun onResume() {
        super.onResume()
        render()
    }

    private fun render() {
        val p = Prefs(this)
        val root = page(scroll = true)
        val current = p.mode
        if (current == null) {
            root.addView(Ui.header(this, "How should Orbit run?", "Later") { finish() })
            root.addView(Ui.text(this, "You can switch later in Settings.", 17f, color = Ui.MID))
            card(root, "Full: Orbit runs the reader",
                "Orbit is the Home app: Home opens your book or BookOrbit. It switches Wi-Fi, keeps the reader awake for sleep syncs, and runs clicker buttons and the Settings PIN.",
                "Use Full") { choose(OrbitMode.FULL) }
            card(root, "Add-on: keep your launcher",
                "Your reader keeps its own Home screen and Wi-Fi. Orbit installs, updates and sets up KOReader, BookOrbit and the Orbit plugin. Wi-Fi switching, sleep sync, clicker buttons and the PIN are optional helpers, off until you turn them on.",
                "Use Add-on") { choose(OrbitMode.ADDON) }
            return
        }
        root.addView(Ui.header(this, "Mode: ${if (current == OrbitMode.ADDON) "Add-on" else "Full"}", "‹ Back") { finish() })
        val target = if (current == OrbitMode.ADDON) OrbitMode.FULL else OrbitMode.ADDON
        root.addView(Ui.text(this, "Switching to ${if (target == OrbitMode.ADDON) "Add-on" else "Full"}:", 20f, bold = true))
        (if (target == OrbitMode.ADDON) AddonLogic.TO_ADDON_CHANGES else AddonLogic.TO_FULL_CHANGES).forEach {
            root.addView(Ui.text(this, "• $it", 17f).apply { setPadding(0, Ui.dp(this@ModeActivity, 4), 0, 0) })
        }
        if (target == OrbitMode.ADDON) {
            root.addView(Ui.gap(this, 12))
            root.addView(Ui.text(this, "Keep helpers", 20f, bold = true))
            listOf("Wi-Fi switching", "Sleep sync (and screen off after it)", "Clicker buttons", "Settings PIN").forEachIndexed { i, label ->
                root.addView(Ui.row(this, label, null, Ui.toggle(this, keep[i]), onClick = {
                    keep[i] = !keep[i]
                    render()
                }))
            }
        }
        root.addView(Ui.gap(this, 12))
        root.addView(Ui.button(this, "Switch to ${if (target == OrbitMode.ADDON) "Add-on" else "Full"}") { switchTo(target) })
    }

    private fun card(root: LinearLayout, title: String, body: String, button: String, go: () -> Unit) {
        root.addView(Ui.gap(this, 12))
        val c = Ui.card(this)
        c.addView(Ui.text(this, title, 21f, bold = true))
        c.addView(Ui.text(this, body, 17f).apply { setPadding(0, Ui.dp(this@ModeActivity, 6), 0, Ui.dp(this@ModeActivity, 8)) })
        c.addView(Ui.button(this, button) { go() })
        root.addView(c)
    }

    private fun choose(m: OrbitMode) {
        OLog.i("mode: first-run choice ${m.key}")
        if (m == OrbitMode.FULL) {
            Prefs(this).mode = OrbitMode.FULL
            OrbitService.start(this)
            StatusFile.write(this, "first-run choice")
            finish()
            return
        }
        switchTo(OrbitMode.ADDON)
    }

    private fun switchTo(target: OrbitMode) {
        val p = Prefs(this)
        val keepH = Helpers(keep[0], keep[1], keep[1], keep[2], keep[3])
        val steps = if (target == OrbitMode.ADDON) {
            AddonLogic.toAddon(p.mode, Mode.homeEnabled(this), Mode.otherHome(this), keepH, Net.adminActive(this), ClickerStore.enabled(this), OrbitService.running)
        } else {
            AddonLogic.toFull(p.mode, Mode.homeEnabled(this), OrbitService.running)
        }
        val note = Mode.apply(this, target, keepH, steps)
        val summary = when {
            steps.firstOrNull() == AddonLogic.Step.REFUSE_NO_HOME -> note
            target == OrbitMode.ADDON -> "Now in Add-on mode. Home opens your reader's launcher.${note?.let { " $it" } ?: ""}"
            else -> "Now in Full mode.${note?.let { " $it" } ?: ""}"
        }
        if (summary != null) Ui.note(this, summary)
        if (steps.firstOrNull() != AddonLogic.Step.REFUSE_NO_HOME && target == OrbitMode.ADDON && note == null) finish() else render()
    }
}

/** Lines the Add-on checklist shows under Required (§4.3). */
object AddonSetup {
    fun optionalGranted(ctx: Context, id: String): Boolean = when (id) {
        "install_updates" -> ctx.packageManager.canRequestPackageInstalls()
        "notifications" -> Net.notificationsEnabled(ctx)
        "clicker" -> ClickerStore.enabled(ctx)
        "admin" -> Net.adminActive(ctx)
        else -> false
    }
}
