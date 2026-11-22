package net.fledgewing.orbitcompanion

import android.app.NotificationManager
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.util.Log

/** docs/INTERFACE.md, protocol 1. */
object Contract {
    const val PACKAGE = "net.fledgewing.orbitcompanion"
    const val PROTOCOL = "1"
    const val NET_UP = "$PACKAGE.action.NET_UP"
    const val NET_DONE = "$PACKAGE.action.NET_DONE"
    const val WIFI_OFF = "$PACKAGE.action.WIFI_OFF"
    const val SLEEP_NOW = "$PACKAGE.action.SLEEP_NOW"
    const val SHOW_STATUS = "$PACKAGE.action.SHOW_STATUS"
    const val SHOW_APPS = "$PACKAGE.action.SHOW_APPS"
    const val SHOW_LAUNCHER = "$PACKAGE.action.SHOW_LAUNCHER"
    const val SETTINGS = "$PACKAGE.action.SETTINGS"
    const val STATS = "$PACKAGE.action.STATS"
    const val RELAUNCH = "$PACKAGE.action.RELAUNCH"
    const val SETUP_LATER = "$PACKAGE.action.SETUP_LATER"
    const val SHOW_SETUP = "$PACKAGE.action.SHOW_SETUP"
    const val EXTRA_FROM = "$PACKAGE.extra.FROM"
    const val EXTRA_COMMAND = "$PACKAGE.extra.COMMAND"
    const val PATCH_SENDER = "org.koreader.launcher"
    const val STATUS_PORT = 47913

    fun shortName(action: String?): String = action?.substringAfterLast('.') ?: "null"
}

object OLog {
    const val TAG = "OrbitCompanion"

    @Volatile
    var debug = false

    fun i(msg: String) {
        Log.i(TAG, msg)
    }

    fun w(msg: String, e: Throwable? = null) {
        Log.w(TAG, msg, e)
    }

    /** Extra detail, only with Settings › Debug log on. */
    fun d(msg: String) {
        if (debug) Log.i(TAG, "debug: $msg")
    }

    fun since(t0: Long): Long = SystemClock.elapsedRealtime() - t0
}

class Prefs(ctx: Context) {
    private val sp: SharedPreferences = ctx.applicationContext.getSharedPreferences("orbit", Context.MODE_PRIVATE)

    private fun bool(key: String, def: Boolean) = sp.getBoolean(key, def)
    private fun setBool(key: String, v: Boolean) = sp.edit().putBoolean(key, v).apply()
    private fun long(key: String) = sp.getLong(key, 0L)
    private fun setLong(key: String, v: Long) = sp.edit().putLong(key, v).apply()
    private fun str(key: String) = sp.getString(key, "") ?: ""
    private fun setStr(key: String, v: String) = sp.edit().putString(key, v).apply()

    // Settings (mockup 4)
    var wifiAfterSleep: WifiAfterSleep
        get() = WifiAfterSleep.fromKey(sp.getString("wifi_after_sleep", null))
        set(v) = setStr("wifi_after_sleep", v.key)
    var wakeTailscaleWithWifi: Boolean
        get() = bool("wake_ts_with_wifi", true)
        set(v) = setBool("wake_ts_with_wifi", v)
    var wakeLockEnabled: Boolean
        get() = bool("wake_lock", true)
        set(v) = setBool("wake_lock", v)
    /** Clicker buttons: the KeyMap as JSON (ClickerStore). */
    var clickerMap: String
        get() = str("clicker_map")
        set(v) = setStr("clicker_map", v)

    /** "Home opens": "" = KOReader + BookOrbit, else an app's package (HomeApp). */
    var homeApp: String
        get() {
            // One-time move off the 0.4.7 toggle "Home always opens …" (HomeApp.migrate).
            if (sp.contains("home_opens_koreader")) {
                val v = HomeApp.migrate(str("home_app"), sp.getBoolean("home_opens_koreader", true))
                sp.edit().putString("home_app", v).remove("home_opens_koreader").apply()
                return v
            }
            return str("home_app")
        }
        set(v) = setStr("home_app", v)
    var notifyTailscale: Boolean
        get() = bool("notify_tailscale", true)
        set(v) = setBool("notify_tailscale", v)
    // Shared with the KOReader patch (docs/INTERFACE.md "Settings"); newest settings_at wins.
    var wifiMode: WifiMode
        get() = WifiMode.fromKey(sp.getString("wifi_mode", null))
        set(v) = setStr("wifi_mode", v.key)
    var wifiIdleMin: Int
        get() = sp.getInt("wifi_idle_min", 2)
        set(v) = sp.edit().putInt("wifi_idle_min", v).apply()
    var homeButton: HomeButton
        get() = HomeButton.fromKey(sp.getString("home_button", null))
        set(v) = setStr("home_button", v.key)
    var sharedSettingsAt by LongPref("shared_settings_at")
    /** Sync while reading as the patch last reported it ("" = not yet). */
    var readingSchedule: String
        get() = str("reading_schedule_patch")
        set(v) = setStr("reading_schedule_patch", v)
    /** A change made here, waiting for the patch ("" = none) (ReadingSchedule). */
    var readingScheduleRequest: String
        get() = str("reading_schedule_request")
        set(v) = setStr("reading_schedule_request", v)
    var readingScheduleRequestAt by LongPref("reading_schedule_request_at")

    // Who turned Wi-Fi on (WifiOwnership).
    var wifiOwner: WifiOwner
        get() = WifiOwner.fromKey(sp.getString("wifi_owner", null))
        set(v) = setStr("wifi_owner", v.key)
    var wifiPendingOwner: WifiOwner
        get() = WifiOwner.fromKey(sp.getString("wifi_pending_owner", null))
        set(v) = setStr("wifi_pending_owner", v.key)
    var wifiPendingAt by LongPref("wifi_pending_at")

    /** The patch version installed after an app update, until the running patch reports it (UpdateFlow). */
    var patchAwaitVersion: String
        get() = str("patch_await_version")
        set(v) = setStr("patch_await_version", v)

    var patchInstallStatus: String
        get() = sp.getString("patch_install_status", "") ?: ""
        set(v) = setStr("patch_install_status", v)

    // "Setup needs you" (Attention)
    private fun set(key: String): Set<String> = sp.getStringSet(key, emptySet())?.toSet() ?: emptySet()
    private fun setSet(key: String, v: Set<String>) = sp.edit().putStringSet(key, v).apply()
    var setupIgnored: Set<String>
        get() = set("setup_ignored")
        set(v) = setSet("setup_ignored", v)
    var setupSnoozeNotDone: Set<String>
        get() = set("setup_snooze_not_done")
        set(v) = setSet("setup_snooze_not_done", v)
    var setupLastDone: Set<String>
        get() = set("setup_last_done")
        set(v) = setSet("setup_last_done", v)
    /** Rows the last Home-press prompt showed (SetupAttention.homePrompt). */
    var setupHomePrompted: Set<String>
        get() = set("setup_home_prompted")
        set(v) = setSet("setup_home_prompted", v)
    /** SetupAttention.promptKey for /status (the KOReader box). */
    var setupPromptKey: String
        get() = sp.getString("setup_prompt_key", "") ?: ""
        set(v) = sp.edit().putString("setup_prompt_key", v).apply()
    var setupPromptRows: String
        get() = sp.getString("setup_prompt_rows", "") ?: ""
        set(v) = sp.edit().putString("setup_prompt_rows", v).apply()
    /** Send-key actions: keep the Orbit keyboard current instead of switching just in time. */
    var keepOrbitKeyboard: Boolean
        get() = sp.getBoolean("keep_orbit_keyboard", false)
        set(v) = sp.edit().putBoolean("keep_orbit_keyboard", v).apply()
    /** Just-in-time switches that timed out on this reader. */
    var imeSwitchFailures: Int
        get() = sp.getInt("ime_switch_failures", 0)
        set(v) = sp.edit().putInt("ime_switch_failures", v).apply()
    var setupSnoozeCode: Int
        get() = sp.getInt("setup_snooze_code", 0)
        set(v) = sp.edit().putInt("setup_snooze_code", v).apply()
    var setupNeeded: Int
        get() = sp.getInt("setup_needed", 0)
        set(v) = sp.edit().putInt("setup_needed", v).apply()
    var lastSeenVersionCode: Int
        get() = sp.getInt("last_seen_version_code", 0)
        set(v) = sp.edit().putInt("last_seen_version_code", v).apply()
    var whatsNewFromCode: Int
        get() = sp.getInt("whats_new_from_code", 0)
        set(v) = sp.edit().putInt("whats_new_from_code", v).apply()

    var settingsPinSeeded: Boolean
        get() = bool("settings_pin_seeded", false)
        set(v) = setBool("settings_pin_seeded", v)

    // Self-update (Settings › Updates)
    var autoUpdate: Boolean
        get() = bool("auto_update", true)
        set(v) = setBool("auto_update", v)
    var includePreReleases: Boolean
        get() = bool("include_prereleases", false)
        set(v) = setBool("include_prereleases", v)
    var updateCheckedAt by LongPref("update_checked_at")
    var updateStatusAt by LongPref("update_status_at")
    var updateStatus: String
        get() = str("update_status")
        set(v) = setStr("update_status", v)
    // Settings PIN (Pin): only the salted PBKDF2 hash; never the PIN.
    var pinHash: String
        get() = str("pin_hash")
        set(v) = setStr("pin_hash", v)
    var pinFailures: Int
        get() = sp.getInt("pin_failures", 0)
        set(v) = sp.edit().putInt("pin_failures", v).apply()
    var pinLockedUntil by LongPref("pin_locked_until")
    /** null = the default (Android Settings packages). */
    var guardedApps: Set<String>?
        get() = if (sp.contains("guarded_apps")) set("guarded_apps") else null
        set(v) = if (v == null) sp.edit().remove("guarded_apps").apply() else setSet("guarded_apps", v)
    var debugLog: Boolean
        get() = bool("debug_log", false)
        set(v) = setBool("debug_log", v)

    // Launcher pins: flattened ComponentNames, in order.
    var pins: List<String>?
        get() = if (sp.contains("pins")) str("pins").split('\n').filter { it.isNotBlank() } else null
        set(v) = setStr("pins", v.orEmpty().joinToString("\n"))

    // State reported by the patch and measured here (wall-clock ms; 0 = never)
    var lastSleepSyncAt by LongPref("last_sleep_sync_at")
    var lastSleepSyncOk: Boolean
        get() = bool("last_sleep_sync_ok", false)
        set(v) = setBool("last_sleep_sync_ok", v)
    var lastSleepSyncSeconds: String
        get() = str("last_sleep_sync_s")
        set(v) = setStr("last_sleep_sync_s", v)
    var lastNetReadyAt by LongPref("last_net_ready_at")
    var lastNetReadyMs by LongPref("last_net_ready_ms")
    var wifiOffDeadline by LongPref("wifi_off_deadline")
    var patchSeenAt by LongPref("patch_seen_at")
    /** PATCH_VERSION the patch reports in its broadcasts (patch 0.2.4+). */
    var patchVersionSeen: String
        get() = str("patch_version_seen")
        set(v) = setStr("patch_version_seen", v)
    var patchSeenVia: String
        get() = str("patch_seen_via")
        set(v) = setStr("patch_seen_via", v)
    var wifiTestAt by LongPref("wifi_test_at")
    var wifiTestOk: Boolean
        get() = bool("wifi_test_ok", false)
        set(v) = setBool("wifi_test_ok", v)
    var wifiTestSummary: String
        get() = str("wifi_test_summary")
        set(v) = setStr("wifi_test_summary", v)

    private inner class LongPref(private val key: String) {
        operator fun getValue(thisRef: Any?, p: kotlin.reflect.KProperty<*>): Long = long(key)
        operator fun setValue(thisRef: Any?, p: kotlin.reflect.KProperty<*>, v: Long) = setLong(key, v)
    }
}

/** Wi-Fi, Tailscale, screen and package checks. */
object Net {
    const val TAILSCALE_PKG = "com.tailscale.ipn"
    private const val TAILSCALE_RECEIVER = "com.tailscale.ipn.IPNReceiver"
    private const val TAILSCALE_CONNECT = "com.tailscale.ipn.CONNECT_VPN"

    private fun wifi(ctx: Context) = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private fun cm(ctx: Context) = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    fun wifiEnabled(ctx: Context): Boolean = wifi(ctx).isWifiEnabled

    /**
     * Works because targetSdk is 28; apps targeting 29+ get false and nothing happens.
     * [owner]: who this "on" is for (auto: a sync or KOReader needed it; manual: the user asked).
     * The service's WIFI_STATE_CHANGED receiver records it once Wi-Fi is actually on.
     */
    @Suppress("DEPRECATION")
    fun setWifi(ctx: Context, on: Boolean, why: String, owner: WifiOwner = WifiOwner.AUTO): Boolean {
        val prefs = Prefs(ctx)
        if (on) {
            prefs.wifiPendingOwner = owner
            prefs.wifiPendingAt = System.currentTimeMillis()
        }
        OLog.i("wifi: ${if (on) "ON" else "OFF"} ($why) | owner ${if (on) owner.key else prefs.wifiOwner.key} | mode ${prefs.wifiMode.key}")
        val t0 = SystemClock.elapsedRealtime()
        val ok = try {
            wifi(ctx).setWifiEnabled(on)
        } catch (e: SecurityException) {
            OLog.w("setWifiEnabled($on) denied", e)
            false
        }
        OLog.i("wifi ${if (on) "ON" else "OFF"} requested ($why): ${if (ok) "accepted" else "REFUSED"} in ${OLog.since(t0)} ms")
        return ok
    }

    private fun hasTransport(ctx: Context, transport: Int): Boolean {
        val cm = cm(ctx)
        @Suppress("DEPRECATION")
        return cm.allNetworks.any { cm.getNetworkCapabilities(it)?.hasTransport(transport) == true }
    }

    fun wifiConnected(ctx: Context) = hasTransport(ctx, NetworkCapabilities.TRANSPORT_WIFI)
    fun vpnUp(ctx: Context) = hasTransport(ctx, NetworkCapabilities.TRANSPORT_VPN)

    fun connectTailscale(ctx: Context, why: String): Boolean {
        val i = Intent(TAILSCALE_CONNECT)
            .setClassName(TAILSCALE_PKG, TAILSCALE_RECEIVER)
            .addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES or Intent.FLAG_RECEIVER_FOREGROUND)
        return try {
            ctx.sendBroadcast(i)
            OLog.i("tailscale CONNECT_VPN sent ($why)")
            true
        } catch (e: Exception) {
            OLog.w("tailscale CONNECT_VPN failed ($why)", e)
            false
        }
    }

    fun screenOn(ctx: Context) = (ctx.getSystemService(Context.POWER_SERVICE) as PowerManager).isInteractive

    /**
     * Missing, disabled (FROZEN: e.g. a vendor launcher's "app freeze" calls
     * setApplicationEnabledSetting; see Vendor.kt) or usable. A disabled package is only visible with MATCH_DISABLED_COMPONENTS.
     */
    fun appState(ctx: Context, pkg: String): AppState {
        val pm = ctx.packageManager
        val ai = try {
            pm.getApplicationInfo(pkg, PackageManager.MATCH_DISABLED_COMPONENTS)
        } catch (e: PackageManager.NameNotFoundException) {
            return AppState.MISSING
        }
        val setting = try {
            pm.getApplicationEnabledSetting(pkg)
        } catch (e: IllegalArgumentException) {
            return AppState.MISSING
        }
        val suspended = (ai.flags and ApplicationInfo.FLAG_SUSPENDED) != 0
        val state = AppStates.of(true, setting, ai.enabled, suspended)
        if (state == AppState.FROZEN) OLog.d("$pkg frozen: enabledSetting=$setting enabled=${ai.enabled} suspended=$suspended")
        return state
    }

    /** Present on the device, frozen or not. */
    fun installed(ctx: Context, pkg: String): Boolean = appState(ctx, pkg) != AppState.MISSING

    fun usable(ctx: Context, pkg: String): Boolean = appState(ctx, pkg) == AppState.OK

    /**
     * Tailscale owns the VPN that is up. The owner UID is only visible to the owner on API 29+
     * (it reads as -1 for us), so an unreadable owner counts as Tailscale when Tailscale is usable.
     */
    fun tailscaleVpnUp(ctx: Context): Boolean {
        if (!usable(ctx, TAILSCALE_PKG)) return false
        val cm = cm(ctx)
        val tsUid = try {
            ctx.packageManager.getApplicationInfo(TAILSCALE_PKG, 0).uid
        } catch (e: Exception) {
            -1
        }
        @Suppress("DEPRECATION")
        val vpns = cm.allNetworks.mapNotNull { cm.getNetworkCapabilities(it) }.filter { it.hasTransport(NetworkCapabilities.TRANSPORT_VPN) }
        if (vpns.isEmpty()) return false
        val owners = vpns.map { if (android.os.Build.VERSION.SDK_INT >= 30) it.ownerUid else -1 }
        val ok = owners.any { it == -1 || it == tsUid }
        OLog.d("vpn owners=$owners tailscaleUid=$tsUid -> ${if (ok) "tailscale" else "another app"}")
        return ok
    }

    /** "always_on_vpn_app" is readable on some firmwares and not others; null = unknown. Logged. */
    fun alwaysOnVpnApp(ctx: Context): String? {
        val v = try {
            Settings.Secure.getString(ctx.contentResolver, "always_on_vpn_app")
        } catch (e: Exception) {
            OLog.d("always_on_vpn_app unreadable: ${e.javaClass.simpleName}")
            return null
        }
        OLog.i("always_on_vpn_app reads ${v ?: "null"}")
        return v
    }

    /**
     * "Block connections without VPN" (Settings.Secure always_on_vpn_lockdown): true/false, or
     * null when it can't be read. With Tailscale (tailnet routes only) it blocks the internet.
     */
    fun vpnLockdown(ctx: Context): Boolean? {
        val v = try {
            Settings.Secure.getString(ctx.contentResolver, "always_on_vpn_lockdown")
        } catch (e: Exception) {
            OLog.d("always_on_vpn_lockdown unreadable: ${e.javaClass.simpleName}")
            return null
        }
        return NetErrors.lockdown(v).also { OLog.i("always_on_vpn_lockdown reads ${v ?: "null"}") }
    }

    fun adminActive(ctx: Context): Boolean =
        (ctx.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager)
            .isAdminActive(AdminReceiver.component(ctx))

    fun notificationsEnabled(ctx: Context): Boolean =
        (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).areNotificationsEnabled()
}

/** The "Home opens" app when it isn't KOReader (HomeApp): label, state, start. */
object HomeTarget {
    fun choice(ctx: Context): String = Prefs(ctx).homeApp

    fun label(ctx: Context, pkg: String): String = try {
        val pm = ctx.packageManager
        pm.getApplicationInfo(pkg, PackageManager.MATCH_DISABLED_COMPONENTS).loadLabel(pm).toString()
    } catch (e: Exception) {
        pkg
    }

    /** "Readest", or "KOReader" for the default. */
    fun name(ctx: Context): String = choice(ctx).let { if (HomeApp.isApp(it)) label(ctx, it) else "KOReader" }

    fun problem(ctx: Context, pkg: String): String? = when (Net.appState(ctx, pkg)) {
        AppState.MISSING -> "${label(ctx, pkg)} isn't installed."
        AppState.FROZEN -> Vendor.disabledMessage(ctx, label(ctx, pkg))
        AppState.OK -> if (ctx.packageManager.getLaunchIntentForPackage(pkg) == null) "${label(ctx, pkg)} can't be opened." else null
    }

    /** Brings the app to the front where it was (a launcher's start: NEW_TASK | RESET_TASK_IF_NEEDED). */
    fun start(ctx: Context, pkg: String, why: String): Boolean {
        val i = ctx.packageManager.getLaunchIntentForPackage(pkg) ?: return false
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        return try {
            ctx.startActivity(i)
            OLog.i("home app $pkg started ($why)")
            true
        } catch (e: Exception) {
            OLog.w("home app $pkg start FAILED ($why)", e)
            false
        }
    }
}

object Koreader {
    const val PKG = "org.koreader.launcher"
    private const val ACTIVITY = "org.koreader.launcher.MainActivity"

    fun state(ctx: Context) = Net.appState(ctx, PKG)

    fun installed(ctx: Context) = Net.installed(ctx, PKG)

    /** Why KOReader can't be started, or null when it can. */
    fun problem(ctx: Context): String? = when (state(ctx)) {
        AppState.MISSING -> "KOReader isn't installed."
        AppState.FROZEN -> Vendor.disabledMessage(ctx, "KOReader")
        AppState.OK -> null
    }

    /** INTERFACE "go home": explicit MainActivity, ACTION_MAIN, NEW_TASK, COMMAND per the Home button setting. */
    fun goHome(ctx: Context, why: String): Boolean = start(ctx, why, HomeCommands.forPress(Prefs(ctx).homeButton), HomeCommands.FROM_OTHER_APP)

    /** INTERFACE COMMAND=restart: the patch saves, quits, and asks us to start KOReader again (RELAUNCH). */
    fun restart(ctx: Context, why: String): Boolean = start(ctx, why, HomeCommands.RESTART)

    fun start(ctx: Context, why: String, command: String?, from: String? = null): Boolean {
        val t0 = SystemClock.elapsedRealtime()
        val i = Intent(Intent.ACTION_MAIN)
            .setComponent(ComponentName(PKG, ACTIVITY))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
        if (command != null) i.putExtra(Contract.EXTRA_COMMAND, command)
        if (command != null && from != null) i.putExtra(Contract.EXTRA_FROM, from)
        return try {
            ctx.startActivity(i)
            OLog.i("koreader started command=${command ?: "-"}${if (from != null) " from=$from" else ""} ($why) in ${OLog.since(t0)} ms")
            true
        } catch (e: Exception) {
            OLog.w("koreader start FAILED ($why)", e)
            false
        }
    }
}
