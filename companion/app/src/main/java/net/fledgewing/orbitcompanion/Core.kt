package net.fledgewing.orbitcompanion

import android.app.NotificationManager
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.PowerManager
import android.os.SystemClock
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
    var homeOpensKoreader: Boolean
        get() = bool("home_opens_koreader", true)
        set(v) = setBool("home_opens_koreader", v)
    var notifyTailscale: Boolean
        get() = bool("notify_tailscale", true)
        set(v) = setBool("notify_tailscale", v)
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

    /** Works because targetSdk is 28; apps targeting 29+ get false and nothing happens. */
    @Suppress("DEPRECATION")
    fun setWifi(ctx: Context, on: Boolean, why: String): Boolean {
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

    fun installed(ctx: Context, pkg: String): Boolean = try {
        ctx.packageManager.getApplicationInfo(pkg, 0).enabled
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    fun adminActive(ctx: Context): Boolean =
        (ctx.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager)
            .isAdminActive(AdminReceiver.component(ctx))

    fun notificationsEnabled(ctx: Context): Boolean =
        (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).areNotificationsEnabled()
}

object Koreader {
    const val PKG = "org.koreader.launcher"
    private const val ACTIVITY = "org.koreader.launcher.MainActivity"

    fun installed(ctx: Context) = Net.installed(ctx, PKG)

    /** INTERFACE "go home": explicit MainActivity, ACTION_MAIN, NEW_TASK, COMMAND = "home". */
    fun goHome(ctx: Context, why: String): Boolean = start(ctx, why, "home")

    fun start(ctx: Context, why: String, command: String?): Boolean {
        val t0 = SystemClock.elapsedRealtime()
        val i = Intent(Intent.ACTION_MAIN)
            .setComponent(ComponentName(PKG, ACTIVITY))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
        if (command != null) i.putExtra(Contract.EXTRA_COMMAND, command)
        return try {
            ctx.startActivity(i)
            OLog.i("koreader started command=${command ?: "-"} ($why) in ${OLog.since(t0)} ms")
            true
        } catch (e: Exception) {
            OLog.w("koreader start FAILED ($why)", e)
            false
        }
    }
}
