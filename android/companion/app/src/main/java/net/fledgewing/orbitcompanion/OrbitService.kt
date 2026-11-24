package net.fledgewing.orbitcompanion

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.admin.DeviceAdminReceiver
import android.app.admin.DevicePolicyManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread

/**
 * The system's broadcasts (boot, this app replaced) and the companion's own alarms. Not exported:
 * KOReader's commands come through [CommandProvider], which checks the caller first.
 */
class CommandReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) = Commands.dispatch(ctx, intent)
}

/** Runs one command (android/docs/INTERFACE.md), from [CommandProvider] or [CommandReceiver]. */
object Commands {
    fun dispatch(ctx: Context, intent: Intent) {
        OLog.d("received ${Contract.shortName(intent.action)} extras=${intent.extras?.keySet()}")
        // A record action: kept here, no service needed (docs/design/addon-mode.md §7.1).
        if (intent.action == Contract.REPORT) return StatusFile.onReport(ctx, intent)
        // The sleep screen's files changed: a record action too (no service needed).
        if (intent.action == SleepScreen.ACTION_POOL) {
            // The plugin back from a real sleep: the wake, also without the service (Add-on mode).
            if (intent.getStringExtra("wake") == "1") return SleepScreen.onWake(ctx, "plugin resumed")
            return SleepScreen.onPool(ctx, intent.getStringExtra("reason") ?: "plugin")
        }
        // The cache worker's jobs (docs/design/companion-worker.md): every mode, no service needed.
        if (intent.action == Worker.ACTION_MIRROR || intent.action == Worker.ACTION_CHECK || intent.action == Worker.ACTION_STORAGE || intent.action == Worker.ACTION_COPIES || intent.action == Worker.ACTION_SLEEP_REFRESH || intent.action == Worker.ACTION_RECHECK || intent.action == Worker.ACTION_SQLITE_STRESS || intent.action == Worker.ACTION_PATCH) return Worker.onIntent(ctx, intent)
        // The plugin's "Check for updates": every mode (the plugin downloads nothing itself).
        if (intent.action == Updater.ACTION_UPDATE) return Updater.onPluginAsked(ctx.applicationContext, intent.getStringExtra("reason") ?: "plugin")
        val action = intent.action ?: return
        if (action == Intent.ACTION_BOOT_COMPLETED || action == Intent.ACTION_MY_PACKAGE_REPLACED) return OrbitService.start(ctx, intent)
        if (!Mode.isAddon(ctx)) return OrbitService.start(ctx, intent) // Full: exactly as before 0.11.0
        // By capability (docs/design/addon-mode.md §7.1); in Full every action reaches the service as before.
        when (AddonLogic.route(action, Mode.caps(ctx), Mode.needsService(ctx))) {
            AddonLogic.Route.SERVICE -> OrbitService.start(ctx, intent)
            AddonLogic.Route.RECORD -> record(ctx, intent)
            AddonLogic.Route.DROP -> OLog.i("${Contract.shortName(action)} dropped: not offered in this mode")
        }
    }

    /** Record actions, kept without the service. */
    private fun record(ctx: Context, intent: Intent) {
        when (intent.action) {
            Contract.SETUP_LATER -> Attention.laterFromKoreader(ctx)
            // Only the sleep screen's settings are used without the service (docs/design/lock-screen.md A2).
            Contract.SETTINGS -> SleepScreen.recordSettings(ctx, intent)
            Contract.STATS -> {
                Reading.onStats(ctx, intent)
                PatchInstaller.onBook(ctx, UpdateFlow.bookFromStats(intent.getStringExtra("reason"), intent.getStringExtra("open")), "KOReader: ${intent.getStringExtra("reason") ?: "stats"}")
            }
            else -> OLog.d("${Contract.shortName(intent.action)} kept no state without the service")
        }
    }
}

/** Device admin with only the force-lock policy, for SLEEP_NOW's lockNow(). */
class AdminReceiver : DeviceAdminReceiver() {
    override fun onEnabled(context: Context, intent: Intent) {
        OLog.i("device admin enabled (force-lock)")
    }

    override fun onDisabled(context: Context, intent: Intent) {
        OLog.i("device admin disabled")
    }

    companion object {
        fun component(ctx: Context) = ComponentName(ctx, AdminReceiver::class.java)
    }
}

class OrbitService : Service() {
    companion object {
        const val ACTION_START = "${Contract.PACKAGE}.internal.START"
        const val ACTION_WIFI_TIMER = "${Contract.PACKAGE}.internal.WIFI_TIMER"
        const val ACTION_REFRESH = "${Contract.PACKAGE}.internal.REFRESH"
        private const val CHANNEL_STATUS = "status"
        // "alerts" had a sound, which can't be changed once created: replaced by a quiet channel.
        private const val OLD_CHANNEL_ALERTS = "alerts"
        private const val CHANNEL_ALERTS = "alerts_quiet"
        private const val ID_STATUS = 1
        private const val ID_TAILSCALE_ALERT = 2
        private const val TAILSCALE_CHECK_MS = 20_000L

        @Volatile
        var running = false
            private set

        /** The running service, for the status call (CommandProvider); null when it isn't running. */
        @Volatile
        var current: OrbitService? = null
            private set

        /** Add-on: a helper went off or the mode changed; stop what is no longer needed. */
        const val ACTION_MODE_CHANGED = "${Contract.PACKAGE}.internal.MODE_CHANGED"

        fun start(ctx: Context, intent: Intent? = null) {
            Mode.migrate(ctx, Contract.shortName(intent?.action ?: "start"))
            // Add-on runs no service unless a helper needs it (docs/design/addon-mode.md §7.2).
            if (!Mode.needsService(ctx)) return Mode.withoutService(ctx, intent, "service not needed")
            val i = Intent(intent ?: Intent(ACTION_START)).setClass(ctx, OrbitService::class.java)
            try {
                ctx.startForegroundService(i)
            } catch (e: Exception) {
                OLog.w("could not start the service for ${Contract.shortName(i.action)}", e)
            }
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private lateinit var prefs: Prefs
    private lateinit var stats: StatsRecorder
    private lateinit var cm: ConnectivityManager
    private var wakeLock: PowerManager.WakeLock? = null
    private var wakeLockAt = 0L
    private var netUpAt = 0L // elapsedRealtime of a NET_UP still waiting for Wi-Fi; 0 = none
    private var netUpReason = ""
    private var netUpWantsTailscale = false
    private var offAtScreenOffUntil = 0L
    private val sleepLimiter = RateLimiter(5_000)
    private var statusServer: ServerSocket? = null
    private var lastNotificationText = ""

    private val tailscaleCheck = Runnable {
        val up = Net.vpnUp(this)
        OLog.i("tailscale check after ${TAILSCALE_CHECK_MS / 1000} s: ${if (up) "up" else "NOT up"}")
        if (!up && prefs.notifyTailscale && Net.installed(this, Net.TAILSCALE_PKG)) {
            // Never while reading (Reading); still down when it may show, or dropped.
            Reading.show(this, Reading.KEY_TAILSCALE, "Tailscale alert") { if (!Net.vpnUp(this)) showTailscaleAlert() }
        }
    }

    private val wifiCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = onWifiUp()
        override fun onLost(network: Network) {
            OLog.d("wifi network lost")
            updateNotification()
        }
    }

    private val vpnCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            OLog.i("tailscale (VPN) up")
            stats.record("vpn_up")
            main.removeCallbacks(tailscaleCheck)
            Reading.drop(Reading.KEY_TAILSCALE)
            notificationManager().cancel(ID_TAILSCALE_ALERT)
            updateNotification()
        }

        override fun onLost(network: Network) {
            OLog.i("tailscale (VPN) down")
            stats.record("vpn_down")
            updateNotification()
        }
    }

    // Who turned Wi-Fi on: us (recently asked, WifiOwnership.PENDING_MS) or the user.
    private val wifiStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            when (intent.getIntExtra(WifiManager.EXTRA_WIFI_STATE, WifiManager.WIFI_STATE_UNKNOWN)) {
                WifiManager.WIFI_STATE_ENABLED -> {
                    val now = System.currentTimeMillis()
                    val owner = WifiOwnership.onEnabled(now, prefs.wifiPendingAt, prefs.wifiPendingOwner)
                    prefs.wifiOwner = owner
                    prefs.wifiPendingAt = 0
                    OLog.i("wifi: is ON | owner ${owner.key}${if (owner == WifiOwner.MANUAL) " (not asked by us: the user)" else ""} | mode ${prefs.wifiMode.key}")
                    stats.record("wifi_on")
                }
                WifiManager.WIFI_STATE_DISABLED -> {
                    if (prefs.wifiOwner != WifiOwner.NONE) OLog.i("wifi: is OFF (was ${prefs.wifiOwner.key}) | mode ${prefs.wifiMode.key}")
                    prefs.wifiOwner = WifiOwner.NONE
                    stats.record("wifi_off")
                }
            }
        }
    }

    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            val level = intent.getIntExtra(android.os.BatteryManager.EXTRA_LEVEL, -1)
            val scale = intent.getIntExtra(android.os.BatteryManager.EXTRA_SCALE, -1)
            if (level >= 0 && scale > 0) SleepScreen.onBattery(this@OrbitService, level * 100 / scale)
        }
    }

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    Pin.onScreenOff()
                    Pin.packagesChanged()
                    if (!PatchInstaller.follow(this@OrbitService, "screen off", screenOff = true)) {
                        FontInstaller.follow(this@OrbitService, "screen off", screenOff = true)
                    }
                    if (offAtScreenOffUntil > SystemClock.elapsedRealtime()) {
                        OLog.i("screen off after sync and sleep: Wi-Fi off now (setting Off now)")
                        Net.setWifi(this@OrbitService, false, "after sleep sync, Off now")
                    }
                    offAtScreenOffUntil = 0
                    stats.record("screen_off")
                }
                Intent.ACTION_SCREEN_ON -> {
                    stats.record("screen_on")
                    SleepScreen.onWake(this@OrbitService, "screen on")
                    updateNotification(force = true)
                }
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val t0 = SystemClock.elapsedRealtime()
        running = true
        prefs = Prefs(this)
        current = this
        OLog.debug = prefs.debugLog
        cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        createChannels()
        startForeground(ID_STATUS, buildStatusNotification(statusText()))
        // Battery stats: state rows on change only (no alarms or polling), docs/design/STATS-DESIGN.md.
        stats = StatsRecorder(this, prefs)
        stats.start()
        cm.registerNetworkCallback(
            NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), wifiCallback, main,
        )
        cm.registerNetworkCallback(
            NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_VPN)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build(),
            vpnCallback, main,
        )
        registerReceiver(wifiStateReceiver, IntentFilter(WifiManager.WIFI_STATE_CHANGED_ACTION))
        // The sleep screen's picture is redrawn at every 1 % step (docs/design/lock-screen.md R7).
        registerReceiver(batteryReceiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        registerReceiver(screenReceiver, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
        })
        startStatusServer()
        // "Setup needs you": after an update and on every start (no timers).
        Attention.onStart(this)
        main.postDelayed({ Attention.evaluate(this, "service start") }, 5_000)
        // The last running patch reported is older than the file: same rule as on /status.
        main.postDelayed({ PatchInstaller.follow(this, "companion start") }, 5_000)
        // A timer that was pending when the process died is still in AlarmManager; nothing to do.
        OLog.i("service started v${BuildConfig.VERSION_NAME} in ${OLog.since(t0)} ms")
        main.postDelayed({ Updater.maybeAutoCheck(this, "service start") }, 30_000)
    }

    override fun onDestroy() {
        running = false
        try {
            cm.unregisterNetworkCallback(wifiCallback)
            cm.unregisterNetworkCallback(vpnCallback)
            unregisterReceiver(screenReceiver)
            unregisterReceiver(wifiStateReceiver)
            unregisterReceiver(batteryReceiver)
            stats.stop()
        } catch (e: Exception) {
            OLog.w("service teardown", e)
        }
        statusServer?.close()
        current = null
        releaseWakeLock("service stopped")
        OLog.i("service stopped")
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent != null) handle(intent)
        return START_STICKY
    }

    private fun handle(intent: Intent) {
        val t0 = SystemClock.elapsedRealtime()
        val action = intent.action
        val reason = intent.getStringExtra("reason") ?: ""
        noteSender(intent)
        val proto = intent.getStringExtra("proto")
        if (proto != null && proto != Contract.PROTOCOL) OLog.w("protocol $proto from the patch; this companion speaks ${Contract.PROTOCOL}")
        if (action == Contract.STATS) {
            // Reading or not (the reading gate), and the book's state.
            Reading.onStats(this, intent)
            PatchInstaller.onBook(this, UpdateFlow.bookFromStats(intent.getStringExtra("reason"), intent.getStringExtra("open")), "KOReader: ${intent.getStringExtra("reason") ?: "stats"}")
            return stats.onStats(intent)
        }
        if (action == Contract.SETUP_LATER) return Attention.laterFromKoreader(this)
        if (action == Contract.RELAUNCH) {
            // The patch saved and is quitting for a restart: start KOReader again once it's gone.
            // A restart sent with a book open reopens it (patch 0.5.5+, COMMAND=reopen_book).
            // The plugin read the restart: the next start may carry its own command (RestartLatch).
            Koreader.restartRead()
            val command = UpdateFlow.relaunchCommand(prefs.restartReopen == "1")
            prefs.restartReopen = ""
            OLog.i("koreader restart: relaunching in 2.5 s (${intent.getStringExtra("reason") ?: "-"})${if (command != null) ", reopening the book" else ""}")
            // The plugin that reads the relaunch's command is the one on disk, not the one that quit.
            val next = PatchInstaller.installedVersionCached() ?: prefs.patchVersionSeen.ifEmpty { null }
            main.postDelayed({ Koreader.start(this, "restart after patch update", command, plugin = next) }, 2_500)
            return
        }
        if (action == Contract.NET_UP || action == Contract.NET_DONE || action == Contract.SLEEP_NOW) {
            stats.record(Contract.shortName(action).lowercase())
        }
        when (action) {
            Contract.NET_UP -> netUp(intent, reason)
            Contract.NET_DONE -> netDone(intent, reason)
            Contract.WIFI_OFF -> wifiOff(intent, reason)
            Contract.SETTINGS -> applySettings(intent)
            Contract.SLEEP_NOW -> sleepNow(reason)
            ACTION_WIFI_TIMER -> wifiTimerFired()
            ACTION_REFRESH -> OLog.debug = prefs.debugLog
            ACTION_MODE_CHANGED -> modeChanged()
            Intent.ACTION_MY_PACKAGE_REPLACED -> Updater.onReplaced(this)
            else -> OLog.d("start: ${Contract.shortName(action)}")
        }
        if (action in setOf(Contract.NET_UP, Contract.NET_DONE, Contract.WIFI_OFF, Contract.SLEEP_NOW, Contract.SETTINGS)) {
            OLog.i("${Contract.shortName(action)} reason=${reason.ifEmpty { "-" }} handled in ${OLog.since(t0)} ms")
        }
        updateNotification()
    }

    /** Add-on: helpers off. No Wi-Fi switching: no timer; no service needed: stop. */
    private fun modeChanged() {
        if (!Mode.wifiAllowed(this)) cancelWifiTimer("mode changed")
        wakeLock?.let { if (it.isHeld) it.release() }
        if (!Mode.needsService(this)) {
            OLog.i("mode: no helper needs the service; stopping")
            stopForeground(true)
            stopSelf()
        }
    }

    private fun noteSender(intent: Intent) {
        if (intent.getStringExtra("sender") == Contract.PATCH_SENDER) {
            prefs.patchSeenAt = System.currentTimeMillis()
            prefs.patchSeenVia = Contract.shortName(intent.action)
            intent.getStringExtra("patch_version")?.takeIf { it.isNotEmpty() }?.let {
                prefs.patchVersionSeen = it
                PatchInstaller.onPatchSeen(this, it)
            }
        }
    }

    // NET_UP: cancel the Wi-Fi timer, wake lock (25 s cap), Wi-Fi on, Tailscale CONNECT_VPN.
    private fun netUp(intent: Intent, reason: String) {
        cancelWifiTimer("NET_UP")
        offAtScreenOffUntil = 0
        val id = intent.getStringExtra("request_id") ?: "-"
        val lockMs = WifiPolicy.wakeLockMs(intent.getStringExtra("wake_lock_s"), prefs.wakeLockEnabled)
        if (lockMs > 0) acquireWakeLock(lockMs)
        val wantWifi = intent.getStringExtra("wifi") != "0"
        val wantTailscale = intent.getStringExtra("tailscale") != "0"
        val owner = if (intent.getStringExtra("owner") == "manual") WifiOwner.MANUAL else WifiOwner.AUTO
        OLog.i("NET_UP reason=$reason id=$id wifi=$wantWifi tailscale=$wantTailscale owner=${owner.key} wake_lock=${lockMs} ms")
        if (wantWifi && !Net.wifiEnabled(this)) {
            Net.setWifi(this, true, "NET_UP reason=$reason", owner)
        } else if (wantWifi && owner == WifiOwner.MANUAL && prefs.wifiOwner != WifiOwner.MANUAL) {
            // Already on, and now the reader asked for it by hand: it's theirs from here.
            prefs.wifiOwner = WifiOwner.MANUAL
            OLog.i("wifi: already on; owner -> manual (asked by hand in KOReader) | mode ${prefs.wifiMode.key}")
        }
        if (Net.wifiConnected(this)) {
            recordNetReady(0, reason)
            netUpAt = 0
        } else {
            netUpAt = SystemClock.elapsedRealtime()
            netUpReason = reason
        }
        netUpWantsTailscale = wantTailscale
        if (wantTailscale) {
            Net.connectTailscale(this, "NET_UP reason=$reason")
            main.removeCallbacks(tailscaleCheck)
            if (!Net.vpnUp(this)) main.postDelayed(tailscaleCheck, TAILSCALE_CHECK_MS)
        }
    }

    // WIFI_OFF. auto="1": only Wi-Fi we turned on (never the user's own); otherwise unconditional
    // (KOReader's own Wi-Fi toggle, or "Off while reading" when a book opens).
    private fun wifiOff(intent: Intent, reason: String) {
        val auto = intent.getStringExtra("auto") == "1"
        val owner = prefs.wifiOwner
        val mode = intent.getStringExtra("mode")?.takeIf { it.isNotEmpty() } ?: prefs.wifiMode.key
        if (!WifiOwnership.allowOff(auto, owner)) {
            OLog.i("wifi: OFF refused ($reason): turned on by hand | owner ${owner.key} | mode $mode")
            return
        }
        if (auto && Updater.busy) {
            OLog.i("wifi: OFF deferred ($reason): an app update is downloading | owner ${owner.key} | mode $mode")
            main.postDelayed({ wifiOff(intent, reason) }, 5_000)
            return
        }
        if (auto && Worker.busy()) {
            OLog.i("wifi: OFF deferred ($reason): the cache worker is saving BookOrbit for offline | owner ${owner.key} | mode $mode")
            main.postDelayed({ wifiOff(intent, reason) }, 5_000)
            return
        }
        cancelWifiTimer("WIFI_OFF")
        if (!Net.wifiEnabled(this)) {
            OLog.d("wifi: OFF ($reason): already off")
            return
        }
        Net.setWifi(this, false, "WIFI_OFF $reason${if (auto) ", automatic" else ""}")
    }

    // SETTINGS from the patch's menu: newest settings_at wins.
    private fun applySettings(intent: Intent) {
        // Sync while reading: the patch's value, whatever settings_at says (it owns it).
        intent.getStringExtra("reading_schedule")?.takeIf { ReadingSchedule.valid(it) }?.let { v ->
            prefs.readingSchedule = v
            val applied = intent.getStringExtra("reading_schedule_applied_at")?.toLongOrNull()
            if (ReadingSchedule.requestDone(prefs.readingScheduleRequest, prefs.readingScheduleRequestAt, applied)) {
                OLog.i("sync while reading: the patch applied ${prefs.readingScheduleRequest}")
                prefs.readingScheduleRequest = ""
                prefs.readingScheduleRequestAt = 0
            }
            OLog.i("sync while reading in the patch: $v")
        }
        // Settings v2 (docs/design/companion-settings.md §4.4): per key, the newest change wins.
        intent.getStringExtra("values")?.let { v ->
            val taken = SettingsStore.fromPlugin(this, v, "SETTINGS ${intent.getStringExtra("reason") ?: ""}".trim())
            if (taken.any { it == "wifi_mode" || it == "wifi_idle_min" }) OLog.i("settings from the patch: wifi_mode=${prefs.wifiMode.key} wifi_idle_min=${prefs.wifiIdleMin}")
            return
        }
        val at = intent.getStringExtra("settings_at")?.toLongOrNull() ?: 0L
        if (at <= prefs.sharedSettingsAt) {
            OLog.i("settings from the patch ignored: older than ours ($at <= ${prefs.sharedSettingsAt})")
            return
        }
        intent.getStringExtra("wifi_mode")?.takeIf { WifiMode.valid(it) }?.let { prefs.wifiMode = WifiMode.fromKey(it) }
        intent.getStringExtra("wifi_idle_min")?.toIntOrNull()?.takeIf { SharedSettings.validIdle(it) }?.let { prefs.wifiIdleMin = it }
        intent.getStringExtra("home_button")?.takeIf { HomeButton.valid(it) }?.let { prefs.homeButton = HomeButton.fromKey(it) }
        SleepScreen.fromPlugin(this, intent)
        prefs.sharedSettingsAt = at
        OLog.i("settings from the patch: wifi_mode=${prefs.wifiMode.key} wifi_idle_min=${prefs.wifiIdleMin} home_button=${prefs.homeButton.key} (home opens ${HomeApp.kind(prefs.homeApp)})")
    }

    private fun onWifiUp() {
        val pending = netUpAt
        if (pending > 0) {
            recordNetReady(SystemClock.elapsedRealtime() - pending, netUpReason)
            netUpAt = 0
            if (netUpWantsTailscale && prefs.wakeTailscaleWithWifi) Net.connectTailscale(this, "Wi-Fi came up")
        } else {
            OLog.d("wifi network available")
        }
        updateNotification()
        // Daily self-update check, once Wi-Fi is up anyway (never turns Wi-Fi on for it).
        // A wake brought it up anyway; an automatic Wi-Fi off waits for a running download.
        main.postDelayed({ Updater.maybeAutoCheck(this, "Wi-Fi up") }, 2_000)
    }

    private fun recordNetReady(ms: Long, reason: String) {
        prefs.lastNetReadyAt = System.currentTimeMillis()
        prefs.lastNetReadyMs = ms
        OLog.i("network ready: Wi-Fi connected ${ms} ms after NET_UP (reason=$reason)")
    }

    private fun netDone(intent: Intent, reason: String) {
        releaseWakeLock("NET_DONE")
        val ok = intent.getStringExtra("ok") == "1"
        val seconds = intent.getStringExtra("seconds") ?: ""
        val detail = intent.getStringExtra("detail") ?: ""
        OLog.i("NET_DONE reason=$reason ok=$ok seconds=$seconds detail=$detail")
        val screenOn = Net.screenOn(this)
        val now = System.currentTimeMillis()
        // restore=off: Wi-Fi was off before this sleep sync; put it back unless the user turned it on.
        val restoreOff = intent.getStringExtra("restore") == "off" && prefs.wifiOwner != WifiOwner.MANUAL
        if (restoreOff) OLog.i("wifi: sleep sync found Wi-Fi off; restoring off | owner ${prefs.wifiOwner.key} | mode ${prefs.wifiMode.key}")
        val action = WifiPolicy.afterSleepSync(prefs.wifiAfterSleep, reason, screenOn, now, restoreOff) ?: return
        prefs.lastSleepSyncAt = now
        prefs.lastSleepSyncOk = ok
        prefs.lastSleepSyncSeconds = seconds
        when (action) {
            SleepWifiAction.KeepOn -> OLog.i("after sleep sync: Wi-Fi kept on (setting ${prefs.wifiAfterSleep.key}, screen ${if (screenOn) "on" else "off"})")
            SleepWifiAction.OffNow -> Net.setWifi(this, false, "after sleep sync, Off now")
            SleepWifiAction.OffAtNextScreenOff -> {
                offAtScreenOffUntil = SystemClock.elapsedRealtime() + WifiPolicy.SCREEN_OFF_GRACE_MS
                OLog.i("after sleep sync: Wi-Fi off when the screen goes off (within ${WifiPolicy.SCREEN_OFF_GRACE_MS / 1000} s)")
            }
            is SleepWifiAction.OffAt -> scheduleWifiTimer(action.deadlineMs)
        }
    }

    private fun sleepNow(reason: String) {
        if (!sleepLimiter.tryAcquire(SystemClock.elapsedRealtime())) {
            OLog.i("SLEEP_NOW ignored: another one under 5 s ago")
            return
        }
        if (!Net.adminActive(this)) {
            OLog.i("SLEEP_NOW reason=$reason: no device admin, the screen stays on (Setup › Allow lock screen)")
            return
        }
        try {
            (getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager).lockNow()
            OLog.i("SLEEP_NOW reason=$reason: lockNow() called")
        } catch (e: SecurityException) {
            OLog.w("SLEEP_NOW lockNow() refused", e)
        }
    }

    // Wake lock

    private fun acquireWakeLock(ms: Long) {
        val wl = wakeLock ?: (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "OrbitCompanion:sync")
            .also { it.setReferenceCounted(false); wakeLock = it }
        wl.acquire(ms) // the timeout is the hard cap: released even if NET_DONE never comes
        wakeLockAt = SystemClock.elapsedRealtime()
        OLog.i("wake lock held, released by NET_DONE or after $ms ms")
    }

    private fun releaseWakeLock(why: String) {
        val wl = wakeLock ?: return
        if (wl.isHeld) {
            wl.release()
            OLog.i("wake lock released ($why) after ${OLog.since(wakeLockAt)} ms")
        } else if (wakeLockAt > 0) {
            OLog.i("wake lock already released at its cap ($why, ${OLog.since(wakeLockAt)} ms after NET_UP)")
        }
        wakeLockAt = 0
    }

    // Wi-Fi-off timer (AlarmManager, so it fires in Doze)

    private fun timerIntent(): PendingIntent = PendingIntent.getBroadcast(
        this, 1, Intent(this, CommandReceiver::class.java).setAction(ACTION_WIFI_TIMER),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun alarms() = getSystemService(Context.ALARM_SERVICE) as AlarmManager

    private fun scheduleWifiTimer(deadline: Long) {
        prefs.wifiOffDeadline = deadline
        alarms().setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, deadline, timerIntent())
        OLog.i("after sleep sync: Wi-Fi off in ${WifiPolicy.minutesLeft(System.currentTimeMillis(), deadline)} min if the screen is still off")
    }

    private fun cancelWifiTimer(why: String) {
        if (prefs.wifiOffDeadline == 0L) return
        alarms().cancel(timerIntent())
        prefs.wifiOffDeadline = 0
        OLog.i("Wi-Fi-off timer cancelled ($why)")
    }

    private fun wifiTimerFired() {
        val verdict = WifiPolicy.onTimer(
            System.currentTimeMillis(), prefs.wifiOffDeadline, Net.screenOn(this), Net.wifiEnabled(this),
        )
        OLog.i("Wi-Fi-off timer fired: $verdict")
        if (verdict != TimerVerdict.NOT_DUE) prefs.wifiOffDeadline = 0
        if (verdict == TimerVerdict.TURN_OFF) Net.setWifi(this, false, "timer, screen still off")
    }

    // Notifications (mockup 10c)

    private fun notificationManager() = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun createChannels() {
        if (notificationManager().getNotificationChannel(OLD_CHANNEL_ALERTS) != null) notificationManager().deleteNotificationChannel(OLD_CHANNEL_ALERTS)
        notificationManager().createNotificationChannels(
            listOf(
                NotificationChannel(CHANNEL_STATUS, "Network status", NotificationManager.IMPORTANCE_LOW).apply {
                    setShowBadge(false)
                },
                NotificationChannel(CHANNEL_ALERTS, "Network alerts", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    setShowBadge(false)
                    enableVibration(false)
                    setSound(null, null)
                },
            ),
        )
    }

    private fun statusText(): String {
        val wifiOn = Net.wifiEnabled(this)
        val head = when {
            !wifiOn -> "Wi-Fi off"
            !Net.wifiConnected(this) -> "Wi-Fi connecting"
            Net.vpnUp(this) -> "Network ready"
            else -> "Wi-Fi on · Tailscale off"
        }
        val deadline = prefs.wifiOffDeadline
        val now = System.currentTimeMillis()
        val tail = if (wifiOn && deadline > now) " · Wi-Fi off in ${WifiPolicy.minutesLeft(now, deadline)} min" else ""
        return head + tail
    }

    private fun openStatus(): PendingIntent = PendingIntent.getActivity(
        this, 0, Intent(this, StatusActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun buildStatusNotification(text: String): Notification =
        Notification.Builder(this, CHANNEL_STATUS)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(openStatus())
            .build()

    private fun updateNotification(force: Boolean = false) {
        val text = statusText()
        if (!force && text == lastNotificationText) return
        lastNotificationText = text
        notificationManager().notify(ID_STATUS, buildStatusNotification(text))
    }

    private fun showTailscaleAlert() {
        val open = packageManager.getLaunchIntentForPackage(Net.TAILSCALE_PKG)
        val b = Notification.Builder(this, CHANNEL_ALERTS)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentText("Tailscale didn't connect. Open Tailscale to sign in again.")
            .setStyle(Notification.BigTextStyle().bigText("Tailscale didn't connect. Open Tailscale to sign in again."))
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
        if (open != null) {
            b.setContentIntent(PendingIntent.getActivity(this, 2, open, PendingIntent.FLAG_IMMUTABLE))
        }
        notificationManager().notify(ID_TAILSCALE_ALERT, b.build())
        OLog.i("alert shown: Tailscale didn't connect")
    }

    // Loopback status (INTERFACE "Optional: companion status over loopback")

    private fun statusJson(): String =
        "{\"proto\":\"${Contract.PROTOCOL}\",\"version\":\"${BuildConfig.VERSION_NAME}\"," +
            // Mode and capabilities (docs/design/addon-mode.md §6.1); older plugins ignore them.
            "\"mode\":\"${ModeLogic.effective(prefs.mode).key}\",\"caps\":${ModeLogic.caps(StatusFile.caps(this))}," +
            "\"wifi\":${Net.wifiConnected(this)},\"wifi_enabled\":${Net.wifiEnabled(this)}," +
            "\"wifi_owner\":\"${prefs.wifiOwner.key}\",\"tailscale\":${Net.vpnUp(this)}," +
            "\"screen_off_permission\":${Net.adminActive(this)},\"setup_needed\":${prefs.setupNeeded}," +
            // Clicker buttons: the accessibility service is running (it then takes mapped keys in KOReader too).
            "\"clicker_service\":${ClickerService.connected}," +
            // "Block connections without VPN" as Android reports it (null: unreadable): the
            // patch blames it for a failed update check only when this is true.
            "\"vpn_lockdown\":${Net.vpnLockdown(this)}," +
            "\"pin_locked\":${Pin.locked(this)}," +
            // Sync while reading chosen here, for the patch to apply (android/docs/INTERFACE.md).
            "\"reading_schedule_request\":${ReadingSchedule.statusJson(prefs.readingScheduleRequest, prefs.readingScheduleRequestAt)}," +
            // The KOReader setup box (android/docs/INTERFACE.md): only when unsnoozed rows need the user.
            "\"setup_prompt\":${setupPrompt()}," +
            // The sleep screen's picker is open: the plugin asks the worker for fresh lists (companion-settings §6.2).
            "\"want_choices\":${prefs.wantChoicesAt}," +
            "\"settings\":{\"wifi_mode\":\"${prefs.wifiMode.key}\",\"wifi_idle_min\":${prefs.wifiIdleMin}," +
            "\"home_button\":\"${prefs.homeButton.key}\",\"settings_at\":${prefs.sharedSettingsAt}," +
            // Companion-only "Home opens", for the patch's menu: koreader, launcher or app.
            "\"home_opens\":\"${HomeApp.kind(prefs.homeApp)}\"," +
            // Settings v2: every shared key with its time (docs/design/companion-settings.md §4.3).
            "\"values\":${SettingsStore.valuesJson(this)}," +
            // The sleep screen's settings (docs/design/lock-screen.md S1) and how it is shown.
            "${SleepScreen.settingsJson(this)}},\"sleep\":${SleepScreen.statusJson(this)}," +
            // Clicker buttons for the patch (keycode -> press/hold/double -> action), android/docs/INTERFACE.md.
            "\"keymap\":${ClickerStore.map(this).forPatch()}}"

    private fun setupPrompt(): String {
        val key = prefs.setupPromptKey
        if (key.isEmpty()) return "null"
        val rows = org.json.JSONArray(prefs.setupPromptRows.split('\n').filter { it.isNotEmpty() })
        return org.json.JSONObject().put("key", key).put("rows", rows).toString()
    }

    /**
     * The plugin's status call (CommandProvider, caller already checked): the status JSON.
     * [patchVersion]: the running plugin's version; [book]: "1" while a book is open.
     */
    fun answerStatus(patchVersion: String?, book: String?): String {
        val t0 = SystemClock.elapsedRealtime()
        val body = statusJson()
        prefs.patchSeenAt = System.currentTimeMillis()
        prefs.patchSeenVia = "status"
        patchVersion?.takeIf { Regex("^[0-9A-Za-z.+-]+$").matches(it) }?.let { v ->
            prefs.patchVersionSeen = v
            PatchInstaller.onPatchSeen(this, v)
        }
        if (book == "0" || book == "1") main.post { PatchInstaller.onBook(this, book == "1", "KOReader status") }
        // An older plugin running than the file on disk, however it got there (v0.5.4).
        main.post { PatchInstaller.follow(this, "KOReader status") }
        OLog.i("status call -> ${body.length} bytes in ${OLog.since(t0)} ms")
        return body
    }

    private fun startStatusServer() {
        thread(name = "orbit-status", isDaemon = true) {
            try {
                val ss = ServerSocket()
                ss.reuseAddress = true
                ss.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), Contract.STATUS_PORT), 8)
                statusServer = ss
                OLog.i("status endpoint on 127.0.0.1:${Contract.STATUS_PORT}")
                while (!ss.isClosed) {
                    val c = try {
                        ss.accept()
                    } catch (e: Exception) {
                        break
                    }
                    serve(c)
                }
            } catch (e: Exception) {
                OLog.w("status endpoint unavailable", e)
            }
        }
    }

    private fun serve(c: Socket) {
        val t0 = SystemClock.elapsedRealtime()
        try {
            c.soTimeout = 2_000
            val reader = BufferedReader(InputStreamReader(c.getInputStream(), Charsets.ISO_8859_1))
            val requestLine = reader.readLine() ?: return c.close()
            while (true) {
                val h = reader.readLine() ?: break
                if (h.isEmpty()) break
            }
            val parts = requestLine.split(' ')
            // GET /clicks: the patch's kept-open click channel (ClickChannel), not closed here.
            if (parts.size >= 2 && parts[0] == "GET" && parts[1].substringBefore('?') == "/clicks") {
                prefs.patchSeenAt = System.currentTimeMillis()
                prefs.patchSeenVia = "clicks"
                return ClickChannel.add(c, Regex("[?&]patch_version=([0-9A-Za-z.+-]+)").find(parts[1])?.groupValues?.get(1))
            }
            c.use { s ->
                val bytes = "{\"error\":\"not found\"}".toByteArray(Charsets.UTF_8)
                val head = "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n"
                s.getOutputStream().apply { write(head.toByteArray(Charsets.ISO_8859_1)); write(bytes); flush() }
                OLog.i("loopback request ${parts.getOrNull(1)?.substringBefore('?')} -> 404 in ${OLog.since(t0)} ms")
            }
        } catch (e: Exception) {
            OLog.w("status request failed", e)
            runCatching { c.close() }
        }
    }
}
