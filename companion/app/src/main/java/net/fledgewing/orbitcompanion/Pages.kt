package net.fledgewing.orbitcompanion

import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.Gravity
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView

/** Lines shared by the launcher page and the status page. */
object Status {
    fun networkLine(ctx: Context): String = when {
        !Net.wifiEnabled(ctx) -> "Wi-Fi off"
        !Net.wifiConnected(ctx) -> "Wi-Fi connecting"
        Net.vpnUp(ctx) -> "Wi-Fi + Tailscale up"
        else -> "Wi-Fi up · Tailscale off"
    }

    fun lastSleepSync(ctx: Context): String {
        val p = Prefs(ctx)
        if (p.lastSleepSyncAt == 0L) return "none yet"
        val s = p.lastSleepSyncSeconds.ifEmpty { "?" }
        return "${Ui.clock(ctx, p.lastSleepSyncAt)} · ${if (p.lastSleepSyncOk) "done" else "failed"}, $s s"
    }

    fun lastNetReady(ctx: Context): String {
        val p = Prefs(ctx)
        if (p.lastNetReadyAt == 0L) return "none yet"
        return "${Ui.clock(ctx, p.lastNetReadyAt)} · ${Ui.secs(p.lastNetReadyMs)}"
    }

    fun wifiTimer(ctx: Context): String {
        val p = Prefs(ctx)
        val now = System.currentTimeMillis()
        return when {
            p.wifiOffDeadline > now && Net.wifiEnabled(ctx) -> "in ${WifiPolicy.minutesLeft(now, p.wifiOffDeadline)} min"
            p.wifiAfterSleep == WifiAfterSleep.KEEP_ON -> "never (Keep on)"
            else -> "no timer"
        }
    }
}

/**
 * Times Wi-Fi + Tailscale. Polls every 250 ms and reports once at the end (one e-ink redraw).
 * [offFirst]: the setup checklist's Wi-Fi off/on test, which also records whether Android
 * showed a prompt (a refused call, a state that never changed, or our window losing focus).
 */
class NetTest(private val ctx: Context, private val offFirst: Boolean, private val done: (Boolean, String) -> Unit) {
    private val h = Handler(Looper.getMainLooper())
    private var t0 = 0L
    private var onAt = 0L
    private var wifiMs = -1L
    private var phase = 0
    private var refused = false
    private var wasOn = true
    private var restored: Boolean? = null
    var focusLost = false
    var running = false
        private set

    fun start() {
        running = true
        t0 = SystemClock.elapsedRealtime()
        OLog.i("${if (offFirst) "Wi-Fi off/on test" else "network test"} started")
        if (offFirst) {
            // Leave Wi-Fi as found (WifiTestPlan): on -> off, on; off -> on (timed), off.
            wasOn = Net.wifiEnabled(ctx)
            OLog.i("Wi-Fi test: steps ${WifiTestPlan.steps(wasOn)} (Wi-Fi was ${if (wasOn) "on" else "off"})")
            if (wasOn) {
                refused = !Net.setWifi(ctx, false, "setup Wi-Fi test")
                phase = 0
            } else {
                wifiOn()
            }
        } else {
            wifiOn()
            Net.connectTailscale(ctx, "network test")
        }
        h.postDelayed(::tick, 250)
    }

    private fun wifiOn() {
        phase = 1
        onAt = SystemClock.elapsedRealtime()
        if (!Net.wifiEnabled(ctx) && !Net.setWifi(ctx, true, if (offFirst) "setup Wi-Fi test" else "network test")) refused = true
    }

    private fun tick() {
        val now = SystemClock.elapsedRealtime()
        when (phase) {
            0 -> when {
                !Net.wifiEnabled(ctx) -> wifiOn()
                now - t0 > 10_000 -> return finish(false, "Wi-Fi didn't turn off")
            }
            1 -> when {
                Net.wifiConnected(ctx) -> {
                    wifiMs = now - onAt
                    if (offFirst) {
                        if (!wasOn) restored = Net.setWifi(ctx, false, "setup Wi-Fi test: restoring off")
                        return finish(true, "")
                    }
                    Net.connectTailscale(ctx, "network test, Wi-Fi up")
                    phase = 2
                }
                now - onAt > 45_000 -> return finish(false, "Wi-Fi didn't reconnect in 45 s")
            }
            2 -> when {
                Net.vpnUp(ctx) -> return finish(true, "")
                now - onAt > 30_000 -> return finish(false, "Tailscale didn't connect")
            }
        }
        h.postDelayed(::tick, 250)
    }

    private fun finish(ok: Boolean, problem: String) {
        running = false
        if (offFirst && !wasOn && restored == null && Net.wifiEnabled(ctx)) restored = Net.setWifi(ctx, false, "setup Wi-Fi test: restoring off")
        val prompt = refused || focusLost
        val total = SystemClock.elapsedRealtime() - t0
        val summary = if (offFirst) {
            val reconnect = if (wifiMs >= 0) "${if (wasOn) "reconnected" else "connected"} in ${Ui.secs(wifiMs)}" else problem
            val p = if (prompt) "Android prompted or refused" else "no prompt"
            val back = when (restored) {
                true -> " · turned back off (it was off)"
                false -> " · could not turn it back off"
                null -> if (!wasOn && wifiMs < 0) " · left off" else ""
            }
            "$reconnect · $p$back"
        } else {
            val parts = mutableListOf<String>()
            if (wifiMs >= 0) parts.add("Wi-Fi ${Ui.secs(wifiMs)}")
            if (ok) parts.add("Tailscale ${Ui.secs(SystemClock.elapsedRealtime() - onAt - wifiMs)}")
            if (problem.isNotEmpty()) parts.add(problem)
            parts.joinToString(" · ")
        }
        OLog.i("${if (offFirst) "Wi-Fi off/on test" else "network test"} ${if (ok) "passed" else "FAILED"} in $total ms: $summary (refused=$refused focusLost=$focusLost)")
        done(ok && !(offFirst && prompt), summary)
    }

    fun cancel() {
        h.removeCallbacksAndMessages(null)
        running = false
    }
}

/** Mockup 3. Also opened by the patch (SHOW_STATUS) and from the launcher. */
class StatusActivity : EinkActivity() {
    private var testResult: String? = null
    private var test: NetTest? = null
    private var prompted = false

    override fun onResume() {
        super.onResume()
        OrbitService.start(this)
        // "Setup needs you": once per visit, only when a step needs the user or after an update.
        if (!prompted) {
            prompted = true
            val e = Attention.evaluate(this, "status page")
            if (Attention.shouldPrompt(e, this)) {
                startActivity(Intent(this, AttentionActivity::class.java))
            }
        }
        render()
    }

    override fun onPause() {
        super.onPause()
        test?.cancel()
    }

    private fun render() {
        val root = page()
        root.addView(Ui.header(this, "Orbit Companion", "Settings") { startActivity(Intent(this, SettingsActivity::class.java)) })
        val wifi = when {
            !Net.wifiEnabled(this) -> "Off"
            Net.wifiConnected(this) -> "On · connected"
            else -> "On · not connected"
        }
        val ts = when (Net.appState(this, Net.TAILSCALE_PKG)) {
            AppState.MISSING -> "Not installed"
            AppState.FROZEN -> AppStates.disabledShort(Vendor.disablerLabel(this))
            else -> if (Net.vpnUp(this)) "Connected" else "Not connected"
        }
        root.addView(Ui.row(this, "Wi-Fi", right = Ui.value(this, wifi)))
        root.addView(Ui.row(this, "Tailscale", right = Ui.value(this, ts)))
        root.addView(Ui.row(this, "Service", right = Ui.value(this, if (OrbitService.running) "Running" else "Starting")))
        root.addView(Ui.row(this, "Screen-off permission", right = Ui.value(this, if (Net.adminActive(this)) "Granted" else "Not granted")))
        root.addView(Ui.row(this, "Battery", "hours left, % per hour, by setting, history", Ui.value(this, "›"), onClick = {
            startActivity(Intent(this, BatteryActivity::class.java))
        }))
        root.addView(Ui.gap(this, 16))
        val card = Ui.card(this)
        card.addView(Ui.row(this, "Last sleep sync", "reported by the KOReader patch", Ui.value(this, Status.lastSleepSync(this))))
        card.addView(Ui.row(this, "Last wake network ready in", right = Ui.value(this, Status.lastNetReady(this))))
        card.addView(Ui.row(this, "Wi-Fi turns off", right = Ui.value(this, Status.wifiTimer(this))))
        root.addView(card)
        root.addView(Ui.gap(this, 16))
        val checks = Setup.checks(this)
        root.addView(
            Ui.weightRow(
                this,
                Ui.button(this, if (test?.running == true) "Testing…" else "Test network") { runTest() },
                Ui.button(this, "Setup (${checks.count { it.done }}/${checks.size})", solid = checks.any { !it.done }) {
                    startActivity(Intent(this, SetupActivity::class.java))
                },
            ),
        )
        testResult?.let { root.addView(Ui.text(this, it, 18f).apply { setPadding(0, Ui.dp(this@StatusActivity, 10), 0, 0) }) }
        Vendor.disabledApps(this).takeIf { it.isNotEmpty() }?.let { frozen ->
            root.addView(Ui.text(this, frozen.joinToString(" ") { Vendor.disabledMessage(this, it) }, 18f, bold = true).apply {
                setPadding(0, Ui.dp(this@StatusActivity, 10), 0, 0)
            })
        }
        root.addView(Ui.gap(this, 12))
        root.addView(Ui.row(this, "App version", Updater.statusLine(this), Ui.button(this, if (Updater.busy) "Checking…" else "Check for updates", heightDp = 56, sp = 18f) {
            Pin.run(this) {
                Updater.check(this, interactive = true, why = "status page") { if (!isFinishing) render() }
                render()
            }
        }))
    }

    private fun runTest() {
        if (test?.running == true) return
        testResult = "Testing: Wi-Fi on, Tailscale wake…"
        test = NetTest(this, offFirst = false) { ok, summary ->
            testResult = (if (ok) "Network test passed: " else "Network test failed: ") + summary
            render()
        }.also { it.start() }
        render()
    }
}

/** Mockup 4. */
class SettingsActivity : EinkActivity() {
    override val pinGuarded = true

    private lateinit var prefs: Prefs

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        prefs = Prefs(this)
    }

    override fun onResume() {
        super.onResume()
        render()
    }

    private fun changed() {
        OLog.debug = prefs.debugLog
        OLog.i(
            "settings: wifi_after_sleep=${prefs.wifiAfterSleep.key} wake_ts_with_wifi=${prefs.wakeTailscaleWithWifi} " +
                "wake_lock=${prefs.wakeLockEnabled} home_opens=${HomeApp.kind(prefs.homeApp)} " +
                "notify_tailscale=${prefs.notifyTailscale} debug=${prefs.debugLog} " +
                "auto_update=${prefs.autoUpdate} include_prereleases=${prefs.includePreReleases} " +
                "wifi_mode=${prefs.wifiMode.key} wifi_idle_min=${prefs.wifiIdleMin} home_button=${prefs.homeButton.key}",
        )
        OrbitService.start(this, Intent(OrbitService.ACTION_REFRESH))
        render()
    }

    private fun render() {
        val root = page(scroll = true)
        root.addView(Ui.header(this, "Settings", "‹ Back") { finish() })
        root.addView(Ui.text(this, "Wi-Fi after sleep sync", 21f).apply { setPadding(0, 0, 0, Ui.dp(this@SettingsActivity, 8)) })
        val seg = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            background = Ui.box(this@SettingsActivity, Ui.PAPER)
            val pad = Ui.dp(this@SettingsActivity, 2)
            setPadding(pad, pad, pad, pad)
        }
        listOf(
            WifiAfterSleep.KEEP_ON to "Keep on",
            WifiAfterSleep.OFF_AFTER_30 to "Off after 30 min",
            WifiAfterSleep.OFF_NOW to "Off now",
        ).forEach { (mode, label) ->
            val sel = prefs.wifiAfterSleep == mode
            val t = Ui.text(this, label, 18f, bold = sel, color = if (sel) Ui.PAPER else Ui.INK).apply {
                gravity = Gravity.CENTER
                minHeight = Ui.dp(this@SettingsActivity, 72)
                setBackgroundColor(if (sel) Ui.INK else Ui.PAPER)
            }
            Ui.clickable(t, {
                prefs.wifiAfterSleep = mode
                changed()
            })
            seg.addView(t, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }
        root.addView(seg)
        root.addView(
            Ui.text(this, "Short naps keep Wi-Fi up, so waking syncs in about 1 s. The timer only turns Wi-Fi off if the screen is still off.", 16f, color = Ui.MID)
                .apply { setPadding(0, Ui.dp(this@SettingsActivity, 6), 0, Ui.dp(this@SettingsActivity, 12)) },
        )
        segmented(root, "Wi-Fi", WifiMode.entries.map { it to it.label }, prefs.wifiMode) {
            prefs.wifiMode = it
            prefs.sharedSettingsAt = System.currentTimeMillis()
        }
        root.addView(
            Ui.text(this, when (prefs.wifiMode) {
                WifiMode.ALWAYS_ON -> "Wi-Fi stays as you set it. Syncs that have to turn it on turn it back off."
                WifiMode.OFF_READING -> "Off when a book opens (after its sync), back as it was when the book closes."
                WifiMode.JIT -> "Off unless something needs it. Wi-Fi you turn on by hand stays on until you turn it off."
            }, 16f, color = Ui.MID).apply { setPadding(0, Ui.dp(this@SettingsActivity, 6), 0, Ui.dp(this@SettingsActivity, 8)) },
        )
        if (prefs.wifiMode == WifiMode.JIT) {
            segmented(root, "Just in time: off after idle", SharedSettings.IDLE_MINUTES.map { it to "$it min" }, prefs.wifiIdleMin) {
                prefs.wifiIdleMin = it
                prefs.sharedSettingsAt = System.currentTimeMillis()
            }
        }
        val schedule = ReadingSchedule.shown(prefs.readingSchedule, prefs.readingScheduleRequest)
        root.addView(Ui.row(this, "Sync while reading", ReadingSchedule.label(schedule) +
            if (prefs.readingScheduleRequest.isNotEmpty()) " · applies when KOReader opens" else "",
            Ui.value(this, "›"), onClick = { startActivity(Intent(this, ReadingScheduleActivity::class.java)) }))
        val homeChoice = prefs.homeApp
        root.addView(Ui.row(this, "Home opens", HomeApp.summary(homeChoice, if (HomeApp.isApp(homeChoice)) HomeTarget.label(this, homeChoice) else null),
            Ui.value(this, "›"), onClick = { startActivity(Intent(this, HomeAppActivity::class.java)) }))
        if (HomeApp.showsHomeButton(homeChoice)) {
            segmented(root, HomeApp.HOME_BUTTON_TITLE, HomeButton.entries.map { it to it.label }, prefs.homeButton) {
                prefs.homeButton = it
                prefs.sharedSettingsAt = System.currentTimeMillis()
            }
        } else {
            root.addView(Ui.text(this, "Sync on sleep, Just in time Wi-Fi and BookOrbit home work only inside KOReader.", 16f, color = Ui.MID).apply {
                setPadding(0, Ui.dp(this@SettingsActivity, 6), 0, Ui.dp(this@SettingsActivity, 8))
            })
        }
        root.addView(Ui.row(this, "Clicker buttons", "Bluetooth page clicker: page turns, Home, Back, Sleep", Ui.value(this, "›"), onClick = {
            startActivity(Intent(this, ClickersActivity::class.java))
        }))
        root.addView(Ui.gap(this, 8))
        toggle(root, "Wake Tailscale with Wi-Fi", null, prefs.wakeTailscaleWithWifi) { prefs.wakeTailscaleWithWifi = it }
        toggle(root, "Wake lock while syncing", "released at the patch's 20 s cap · 25 s max", prefs.wakeLockEnabled) { prefs.wakeLockEnabled = it }
        toggle(root, "Notify if Tailscale won't connect", null, prefs.notifyTailscale) { prefs.notifyTailscale = it }
        toggle(root, "Debug log", "more detail in logcat, tag OrbitCompanion", prefs.debugLog) { prefs.debugLog = it }
        toggle(root, "Auto-update app", "daily check of the GitHub releases", prefs.autoUpdate) { prefs.autoUpdate = it }
        toggle(root, "Include pre-releases", null, prefs.includePreReleases) { prefs.includePreReleases = it }
        root.addView(Ui.row(this, "Check for updates", Updater.statusLine(this), Ui.value(this, if (Updater.busy) "…" else "›"), onClick = {
            Updater.check(this, interactive = true, why = "settings") { if (!isFinishing) render() }
            render()
        }))
        val skipped = prefs.setupIgnored
        if (skipped.isNotEmpty()) {
            root.addView(Ui.row(this, "Skipped setup steps: ${skipped.size}", "tap to be asked again", Ui.value(this, "›"), onClick = {
                Attention.unignoreAll(this)
                Attention.evaluate(this, "settings")
                render()
            }))
        }
        if (Pin.isSet(this)) {
            root.addView(Ui.row(this, "Settings PIN", "on · tap to change", Ui.value(this, "›"), onClick = {
                startActivity(PinActivity.intent(this, PinActivity.Mode.SET))
            }))
            root.addView(Ui.row(this, "Guarded apps", "${Pin.guarded(this).size} · open only after the PIN", Ui.value(this, "›"), onClick = {
                startActivity(Intent(this, GuardedAppsActivity::class.java))
            }))
            root.addView(Ui.row(this, "Turn the PIN off", null, Ui.value(this, "›"), onClick = {
                Pin.run(this) {
                    Pin.clear(this, "turned off in Settings")
                    render()
                }
            }))
        } else {
            root.addView(Ui.row(this, "Settings PIN", "off · keeps kids out of settings", Ui.value(this, "›"), onClick = {
                startActivity(PinActivity.intent(this, PinActivity.Mode.SET))
            }))
        }
        root.addView(Ui.row(this, "Open-source licenses", null, Ui.value(this, "›"), onClick = {
            startActivity(Intent(this, LicensesActivity::class.java))
        }))
    }

    private fun <T> segmented(root: LinearLayout, title: String, options: List<Pair<T, String>>, current: T, set: (T) -> Unit) {
        root.addView(Ui.text(this, title, 21f).apply { setPadding(0, Ui.dp(this@SettingsActivity, 8), 0, Ui.dp(this@SettingsActivity, 8)) })
        val seg = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            background = Ui.box(this@SettingsActivity, Ui.PAPER)
            val pad = Ui.dp(this@SettingsActivity, 2)
            setPadding(pad, pad, pad, pad)
        }
        options.forEach { (value, label) ->
            val sel = value == current
            val t = Ui.text(this, label, 17f, bold = sel, color = if (sel) Ui.PAPER else Ui.INK).apply {
                gravity = Gravity.CENTER
                minHeight = Ui.dp(this@SettingsActivity, 64)
                setBackgroundColor(if (sel) Ui.INK else Ui.PAPER)
            }
            Ui.clickable(t, {
                set(value)
                changed()
            })
            seg.addView(t, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }
        root.addView(seg)
    }

    private fun toggle(root: LinearLayout, label: String, sub: String?, on: Boolean, set: (Boolean) -> Unit) {
        root.addView(Ui.row(this, label, sub, Ui.toggle(this, on), onClick = {
            set(!on)
            changed()
        }))
    }
}

/** One checklist row (mockup 5). */
/**
 * A Setup row. pending: fine but waiting on something outside the app (shown, never counted).
 * action: the prompt's button label, null = no button (the detail says what to do).
 */
class Check(
    val label: String,
    val done: Boolean,
    val detail: String,
    val pending: Boolean = false,
    val action: String? = "Fix",
    val open: (EinkActivity) -> Unit,
)

object Setup {
    private const val BATTERY_DETAIL = "android.settings.VIEW_ADVANCED_POWER_USAGE_DETAIL"

    fun checks(ctx: Context): List<Check> {
        val prefs = Prefs(ctx)
        val list = mutableListOf<Check>()

        val home = ctx.packageManager.resolveActivity(
            Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME), android.content.pm.PackageManager.MATCH_DEFAULT_ONLY,
        )?.activityInfo?.packageName
        list.add(Check("Set Orbit as Home app", home == ctx.packageName, if (home == ctx.packageName) "done" else "now: ${home ?: "ask every time"}") { a ->
            a.tryStart(Intent(Settings.ACTION_HOME_SETTINGS), "Home app settings") ||
                a.tryStart(Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS), "default apps settings")
        })

        val notif = Net.notificationsEnabled(ctx)
        list.add(Check("Allow notifications", notif, if (notif) "done" else "off") { a ->
            a.tryStart(
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, ctx.packageName),
                "notification settings",
            )
        })

        // Some vendor launchers "freeze" (disable) apps behind our back (Vendor.kt).
        val frozen = Vendor.disabledApps(ctx)
        val disabler = Vendor.disablerLabel(ctx)
        list.add(
            Check(
                "Not disabled by the system (KOReader, Tailscale, Orbit)",
                frozen.isEmpty(),
                if (frozen.isEmpty()) "done" else "${AppStates.disabledShort(disabler)}: ${frozen.joinToString()} · re-enable${Vendor.profile(ctx).freezeHint?.let { h -> " in ${disabler ?: "the launcher"} › $h" } ?: " in Settings › Apps"}",
            ) { a ->
                a.tryStart(Vendor.reenablePage(ctx), "re-enable page")
            },
        )

        val canInstall = ctx.packageManager.canRequestPackageInstalls()
        list.add(Check("Install updates", canInstall, if (canInstall) "done" else "allow Orbit to install unknown apps (self-update)") { a ->
            a.tryStart(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${ctx.packageName}")), "install unknown apps")
        })

        listOf(ctx.packageName to "Orbit", Net.TAILSCALE_PKG to "Tailscale", Koreader.PKG to "KOReader").forEach { (pkg, name) ->
            val installed = Net.installed(ctx, pkg)
            val ok = installed && (ctx.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager).isIgnoringBatteryOptimizations(pkg)
            list.add(Check("Battery: Unrestricted ($name)", ok, if (!installed) "not installed" else if (ok) "done" else "set App battery usage › Unrestricted") { a ->
                if (installed) {
                    a.tryStart(Intent(BATTERY_DETAIL, Uri.parse("package:$pkg")), "battery page for $pkg") ||
                        a.tryStart(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg")), "app info for $pkg")
                }
            })
        }

        val tsState = Net.appState(ctx, Net.TAILSCALE_PKG)
        // Done when a VPN is up and it is Tailscale's (owner UID, where Android lets us read it).
        // Always-on is advice only: some firmwares hide "always_on_vpn_app" from apps (logged).
        val tsUp = Net.tailscaleVpnUp(ctx)
        val alwaysOnApp = Net.alwaysOnVpnApp(ctx)
        val alwaysOnNote = when (alwaysOnApp) {
            Net.TAILSCALE_PKG -> "Always-on on"
            null, "" -> "tip: VPN settings › Tailscale ⚙ › Always-on"
            else -> "tip: Always-on is set to another app"
        }
        // Tailscale routes only the tailnet: lockdown blocks everything else (updates included).
        val lockdown = Net.vpnLockdown(ctx) == true
        list.add(
            Check(
                "Tailscale signed in and connected",
                tsUp && !lockdown,
                when {
                    tsState == AppState.MISSING -> "not installed"
                    tsState == AppState.FROZEN -> Vendor.disabledMessage(ctx, "Tailscale")
                    !tsUp -> "not connected: open Tailscale and sign in"
                    lockdown -> NetErrors.LOCKDOWN_WARNING
                    else -> "connected · $alwaysOnNote"
                },
            ) { a ->
                when {
                    tsState == AppState.FROZEN -> a.tryStart(Vendor.reenablePage(ctx, Net.TAILSCALE_PKG), "re-enable page")
                    lockdown || tsUp -> a.tryStart(Intent(Settings.ACTION_VPN_SETTINGS), "VPN settings")
                    else -> ctx.packageManager.getLaunchIntentForPackage(Net.TAILSCALE_PKG)?.let { a.tryStart(it, "Tailscale") }
                }
            },
        )

        val admin = Net.adminActive(ctx)
        list.add(Check("Allow \"lock screen\" (device admin)", admin, if (admin) "done" else "for Sync and sleep") { a ->
            a.tryStart(
                Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                    .putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, AdminReceiver.component(ctx))
                    .putExtra(
                        DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                        "Lets \"Sync and sleep\" turn the screen off after syncing. It uses only the lock-screen permission.",
                    ),
                "device admin",
            )
        })

        // One-tap patch install (PatchInstaller): from this app's release, SHA-256 checked.
        // The file when readable (storage permission), else what the running patch reports.
        // Clicker buttons: shown only once a clicker is mapped (docs/BTKEYS-DESIGN.md "Staying on").
        // With a Settings PIN set the app guard needs the same service, so the row shows then too.
        val pinSet = Pin.isSet(ctx)
        val clicker = ClickerRow.state(ClickerStore.map(ctx).mapped || pinSet, ClickerStore.enabled(ctx), ClickerService.connected)
        if (clicker != ClickerRowState.HIDDEN) {
            list.add(Check(
                ClickerRow.label(pinSet),
                clicker == ClickerRowState.DONE,
                when (clicker) {
                    ClickerRowState.DONE -> "on · works in every app"
                    ClickerRowState.OFF -> "Off: was it frozen or turned off? Clicker buttons work only in KOReader until it's on. Orbit uses it only to see button presses, which app is in front, and to send page taps, Home and Back. It can't read what's on screen."
                    else -> "On in Android but not running yet: turn it off and on in Settings › Accessibility."
                },
            ) { a -> a.tryStart(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS), "accessibility settings") })
            val others = ClickerRow.others(ClickerStore.accessibilitySetting(ctx), ctx.packageName)
            others.firstOrNull()?.let { other ->
                val km = other == "io.github.sds100.keymapper"
                list.add(Check(
                    if (km) "Key Mapper also remaps keys" else "Another key mapper is on (${HomeTarget.label(ctx, other)})",
                    false,
                    "Turn it off once Orbit's buttons work; you can then uninstall it. Two key filters both see every key and can fight.",
                ) { a -> a.tryStart(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS), "accessibility settings") })
            }
        }

        // Orbit keyboard: shown only while a Send-key action is mapped (docs/BTKEYS-DESIGN.md "Send key").
        if (ClickerStore.map(ctx).sendsKeys) {
            val on = KeySender.enabled(ctx)
            list.add(Check(
                "Orbit keyboard enabled",
                on,
                if (on) "on · switches in only for a key press, then your keyboard comes back"
                else "Turn on \"Orbit clicker keys\" for Send Volume up/down and Send key. It has no keys, never stays your keyboard and never reads what you type; Android's warning about collecting text is the same for every keyboard.",
            ) { a -> a.tryStart(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS), "keyboard settings") })
        }

        // The file decides "outdated"; the version the running patch reports decides "restart".
        val fileV = PatchInstaller.installedVersion()
        val runningV = prefs.patchVersionSeen.takeIf { it.isNotEmpty() }
        val patchState = PatchRow.state(fileV, runningV, BuildConfig.VERSION_NAME)
        val patchV = fileV ?: runningV
        list.add(
            Check(
                "KOReader patch installed${patchV?.let { " (v$it)" } ?: ""}",
                patchState == PatchRowState.CURRENT || patchState == PatchRowState.RESTART,
                when {
                    PatchInstaller.busy -> "installing…"
                    patchState == PatchRowState.RESTART && UpdateFlow.autoRestart(runningV) ->
                        "KOReader restarts by itself to load it once no book is open (or when the device sleeps); it still runs v$runningV"
                    patchState == PatchRowState.RESTART -> if (PatchRow.canRestart(runningV)) "Restart KOReader to finish (KOReader still runs v$runningV)"
                        else "Restart KOReader to finish: close KOReader from recent apps and reopen it (it still runs v$runningV)"
                    patchState == PatchRowState.MISSING && prefs.patchInstallStatus.isNotEmpty() -> "${prefs.patchInstallStatus} · tap to try again"
                    patchState == PatchRowState.MISSING -> "tap to install it into koreader/patches/"
                    patchState == PatchRowState.OUTDATED -> "older than this app's release (v${BuildConfig.VERSION_NAME}) · tap to update"
                    else -> "up to date${prefs.patchInstallStatus.takeIf { it.startsWith("installed") }?.let { " · $it" } ?: ""}"
                },
                pending = patchState == PatchRowState.RESTART,
                action = when {
                    PatchInstaller.busy -> "Installing…"
                    patchState != PatchRowState.RESTART -> "Fix"
                    PatchRow.canRestart(runningV) -> "Restart KOReader"
                    else -> null
                },
            ) { a ->
                when {
                    PatchInstaller.busy -> Unit
                    patchState == PatchRowState.RESTART -> if (PatchRow.canRestart(runningV)) Koreader.restart(a, "setup: new patch installed")
                    else -> PatchInstaller.installFrom(a) { a.refresh() }
                }
                a.refresh()
            },
        )

        val seen = prefs.patchSeenAt
        list.add(
            Check(
                "KOReader patch answered",
                seen > 0,
                when {
                    seen > 0 -> "last ${Ui.clock(ctx, seen)} (${prefs.patchSeenVia})"
                    Koreader.problem(ctx) != null -> Koreader.problem(ctx)!!
                    else -> "open KOReader with the patch, or run its Test sync path"
                },
            ) { a ->
                if (Koreader.state(ctx) == AppState.FROZEN) {
                    a.tryStart(Vendor.reenablePage(ctx, Koreader.PKG), "re-enable page")
                } else if (!Koreader.start(a, "setup: patch check", null)) {
                    OLog.i("setup: KOReader not startable")
                }
            },
        )

        list.add(
            Check(
                "Wi-Fi off/on test",
                prefs.wifiTestOk,
                if (prefs.wifiTestAt > 0) "${Ui.clock(ctx, prefs.wifiTestAt)}: ${prefs.wifiTestSummary}" else "times the reconnect; checks for a prompt",
            ) { a -> (a as? SetupActivity)?.runWifiTest() },
        )
        return list
    }
}

/** Mockup 5. Rows re-check on resume. */
class SetupActivity : EinkActivity() {
    private var test: NetTest? = null

    override fun onResume() {
        super.onResume()
        render()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        val t = test
        if (!hasFocus && t != null && t.running) {
            t.focusLost = true
            OLog.i("Wi-Fi test: window lost focus (a system prompt?)")
        }
    }

    override fun onDestroy() {
        test?.cancel()
        super.onDestroy()
    }

    override fun refresh() {
        if (!isFinishing) render()
    }

    fun runWifiTest() {
        if (test?.running == true) return
        test = NetTest(this, offFirst = true) { ok, summary ->
            val prefs = Prefs(this)
            prefs.wifiTestAt = System.currentTimeMillis()
            prefs.wifiTestOk = ok
            prefs.wifiTestSummary = summary
            render()
        }.also { it.start() }
        render()
    }

    private fun render() {
        val root = page(scroll = true)
        val checks = Setup.checks(this)
        root.addView(Ui.header(this, "First-run setup (${checks.count { it.done }}/${checks.size})", "‹ Back") { finish() })
        checks.forEach { c ->
            val isTest = c.label == "Wi-Fi off/on test"
            val right: TextView = if (isTest) {
                Ui.button(this, if (test?.running == true) "Running…" else "Run", heightDp = 56, sp = 18f) { Pin.fix(this) { c.open(this) } }
            } else {
                Ui.value(this, if (c.done) "done" else "open ›", bold = !c.done)
            }
            root.addView(
                Ui.row(
                    this, c.label, if (c.done && c.detail == "done") null else c.detail, right,
                    onClick = { Pin.fix(this) { c.open(this) } },
                    left = Ui.check(this, c.done),
                ),
            )
        }
    }
}

/**
 * Settings › Home opens: KOReader + BookOrbit (default), then reader apps (KnownApps and the
 * vendor's), then every other launchable app A–Z. Paged, no scrolling.
 */
/** Settings › Sync while reading: the patch's options; the patch applies and keeps the choice. */
class ReadingScheduleActivity : EinkActivity() {
    override val pinGuarded = true

    override fun onResume() {
        super.onResume()
        render()
    }

    private fun render() {
        val prefs = Prefs(this)
        val root = page(scroll = true)
        root.addView(Ui.header(this, "Sync while reading", "‹ Back") { finish() })
        root.addView(Ui.text(this, "Syncs your place while a book is open. KOReader keeps this setting; a change here applies when KOReader next opens or comes back.", 16f, color = Ui.MID))
        val now = ReadingSchedule.shown(prefs.readingSchedule, prefs.readingScheduleRequest)
        ReadingSchedule.OPTIONS.forEach { (id, label) ->
            root.addView(Ui.row(this, label, null, Ui.value(this, if (id == now) "●" else " "), onClick = {
                if (id == prefs.readingSchedule) {
                    prefs.readingScheduleRequest = ""
                    prefs.readingScheduleRequestAt = 0
                } else {
                    prefs.readingScheduleRequest = id
                    prefs.readingScheduleRequestAt = System.currentTimeMillis()
                }
                OLog.i("sync while reading: chose $id here (the patch has ${prefs.readingSchedule.ifEmpty { "?" }})")
                render()
            }))
        }
    }
}

class HomeAppActivity : EinkActivity() {
    override val pinGuarded = true

    private var apps: List<Pair<String, String>> = emptyList()
    private var readers: Set<String> = emptySet()
    private var pageIndex = 0

    override fun onResume() {
        super.onResume()
        val pm = packageManager
        val main = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val found = pm.queryIntentActivities(main, 0)
            .filter { it.activityInfo.packageName != packageName }
            .map { it.activityInfo.packageName to it.loadLabel(pm).toString() }
        readers = KnownApps.readers(Vendor.profile(this))
        apps = HomeApp.order(found, readers)
        render()
    }

    private fun render() {
        val root = page()
        root.addView(Ui.header(this, "Home opens", "‹ Back") { finish() })
        val current = Prefs(this).homeApp
        val rows = listOf(HomeApp.KOREADER_BOOKORBIT to "KOReader + BookOrbit", HomeApp.LAUNCHER to HomeApp.LAUNCHER_LABEL) + apps
        val perPage = maxOf(3, (resources.displayMetrics.heightPixels / resources.displayMetrics.density).toInt().minus(300) / (Ui.ROW_DP + 4))
        val pages = maxOf(1, (rows.size + perPage - 1) / perPage)
        pageIndex = pageIndex.coerceIn(0, pages - 1)
        rows.drop(pageIndex * perPage).take(perPage).forEach { (pkg, label) ->
            val sub = when {
                pkg == HomeApp.KOREADER_BOOKORBIT -> "Smart Home, sync on sleep, Just in time Wi-Fi"
                pkg == HomeApp.LAUNCHER -> "Orbit's own page of apps"
                pkg in readers -> "reader app"
                else -> null
            }
            val chosen = if (HomeApp.isKoreader(current)) pkg == HomeApp.KOREADER_BOOKORBIT else pkg == current
            root.addView(Ui.row(this, label, sub, Ui.check(this, chosen), onClick = {
                Prefs(this).homeApp = pkg
                OLog.i("settings: Home opens ${if (pkg.isEmpty()) "KOReader + BookOrbit" else pkg}")
                finish()
            }))
        }
        root.addView(android.view.View(this), android.widget.LinearLayout.LayoutParams(1, 0, 1f))
        root.addView(Ui.text(this, "Another app: Home brings it back where it was; press Home twice for the launcher page. Sync on sleep, Just in time Wi-Fi and BookOrbit home work only inside KOReader.", 15f, color = Ui.MID))
        if (pages > 1) {
            root.addView(Ui.gap(this, 8))
            root.addView(Ui.weightRow(this,
                Ui.button(this, "‹ Back", heightDp = 64, sp = 18f) { if (pageIndex > 0) { pageIndex--; render() } },
                Ui.text(this, "${pageIndex + 1} / $pages", 17f, color = Ui.MID).apply { gravity = android.view.Gravity.CENTER },
                Ui.button(this, "Next ›", heightDp = 64, sp = 18f) { if (pageIndex < pages - 1) { pageIndex++; render() } }))
        }
    }
}
