package net.fledgewing.orbitcompanion

import android.Manifest
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.BatteryManager
import android.os.Environment
import android.provider.Settings
import android.util.DisplayMetrics
import android.view.WindowManager
import org.json.JSONObject
import java.io.File

/**
 * The sleep screen on the companion's side (docs/design/lock-screen.md): its settings (shared with
 * the Orbit plugin through SETTINGS, newest settings_at wins), the files the plugin writes in
 * koreader/settings/orbit-sleep/ (android/docs/INTERFACE.md "Sleep screen"), the rotation state,
 * and the two sinks: the screen saver (SleepDream) and the picture (Pictures/Orbit/sleep.png).
 * Nothing here runs while a book is read: the dream starts at sleep, the picture is redrawn from
 * broadcasts and a non-wakeup alarm.
 */
object SleepScreen {
    private const val PREFS = "orbit_sleep"
    const val ACTION_REDRAW = "${Contract.PACKAGE}.internal.SLEEP_REDRAW"
    /** From the plugin (android/docs/INTERFACE.md): the files in orbit-sleep/ changed. */
    const val ACTION_POOL = "${Contract.PACKAGE}.action.SLEEP_POOL"

    fun dir(): File = File(Environment.getExternalStorageDirectory(), "koreader/settings/orbit-sleep")
    fun picture(): File = File(Environment.getExternalStorageDirectory(), "Pictures/Orbit/sleep.png")

    private fun sp(ctx: Context) = ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun settings(ctx: Context): SleepSettings {
        val p = sp(ctx)
        return SleepSettings.merge(SleepSettings.DEFAULT) { k -> if (p.contains(k)) p.getString(k, null) else null }
    }

    /** Stores [s]; [shared]: a change made here, so settings_at moves and the plugin takes it. */
    fun save(ctx: Context, s: SleepSettings, why: String, shared: Boolean) {
        val before = settings(ctx)
        val e = sp(ctx).edit()
        s.toMap().forEach { (k, v) -> e.putString(k, v) }
        e.apply()
        if (shared) Prefs(ctx).sharedSettingsAt = System.currentTimeMillis()
        OLog.i("sleep screen: settings ${s.mode.key} from=${s.from} rules=${s.leaveOut.size} every=${s.hours}h text=${s.text.length} chars battery=${s.battery} style=${s.style.key} text_at=${s.textPosition.key} battery_at=${s.batteryCorner.key} flash=${s.flash} ($why)")
        if (before.mode != s.mode) modeChanged(ctx, before.mode, s.mode, why)
        StatusFile.write(ctx, "sleep screen settings")
        redrawPicture(ctx, "settings")
    }

    /** SETTINGS from the plugin, already newer than ours (OrbitService.applySettings, or recorded without it). */
    fun fromPlugin(ctx: Context, intent: Intent) {
        if (SleepSettings.KEYS.none { intent.hasExtra(it) }) return
        val s = SleepSettings.merge(settings(ctx)) { intent.getStringExtra(it) }
        if (s != settings(ctx)) save(ctx, s, "from the plugin", shared = false)
    }

    /** Add-on without the service: SETTINGS is recorded here (only the sleep screen's keys matter then). */
    fun recordSettings(ctx: Context, intent: Intent) {
        val at = intent.getStringExtra("settings_at")?.toLongOrNull() ?: 0L
        val p = Prefs(ctx)
        if (at <= p.sharedSettingsAt) return
        fromPlugin(ctx, intent)
        p.sharedSettingsAt = at
    }

    /** For /status and the status file: `"sleep_mode":"…",…` (no braces). */
    fun settingsJson(ctx: Context): String = settings(ctx).toMap().entries.joinToString(",") { (k, v) -> "${ModeLogic.str(k)}:${ModeLogic.str(v)}" }

    /** For /status and the status file: `{"shown_by":"…","sink":"dream"}`. */
    fun statusJson(ctx: Context): String =
        "{\"shown_by\":${ModeLogic.str(shownBy(ctx))},\"sink\":\"${sink(ctx).name.lowercase()}\"}"

    // ---------------------------------------------------------------- the sinks

    /** Tests only: the sink without a vendor profile. */
    @Volatile var sinkForTest: SleepSink? = null

    fun sink(ctx: Context): SleepSink = sinkForTest ?: SleepSystem.sink(Vendor.profile(ctx).id)

    fun dreamComponent(ctx: Context): String = ComponentName(ctx, SleepDream::class.java).flattenToString()

    fun oursChosen(ctx: Context): Boolean =
        SleepSystem.oursChosen(Settings.Secure.getString(ctx.contentResolver, SleepSystem.KEYS[0]), dreamComponent(ctx))

    fun shownBy(ctx: Context): String = SleepSystem.shownBy(sink(ctx), oursChosen(ctx), picture().isFile)

    /** WRITE_SECURE_SETTINGS, granted once over USB (tools/install-usb.sh --grant-screen-saver). */
    fun canSwitch(ctx: Context): Boolean =
        ctx.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED

    /** The only Settings.Secure write in the app (SleepGuardTest): one of SleepSystem.KEYS. */
    private fun putSecure(ctx: Context, key: String, value: String?): Boolean {
        require(key in SleepSystem.KEYS) { "not a sleep-screen key: $key" }
        return try {
            Settings.Secure.putString(ctx.contentResolver, key, value)
        } catch (e: SecurityException) {
            OLog.w("sleep screen: $key not written (no permission)", e)
            false
        }
    }

    /**
     * P1: ours becomes the screen saver; the vendor's three values are kept once, to put back.
     * -> false without the permission (the page then shows the USB command, P2).
     */
    fun chooseOurs(ctx: Context, why: String): Boolean {
        if (sink(ctx) != SleepSink.DREAM || !canSwitch(ctx)) return false
        val p = sp(ctx)
        if (!p.getBoolean("vendor_saved", false)) {
            val e = p.edit().putBoolean("vendor_saved", true)
            SleepSystem.KEYS.forEach { k -> e.putString("vendor_$k", Settings.Secure.getString(ctx.contentResolver, k)) }
            e.apply()
        }
        val ok = SleepSystem.KEYS.zip(SleepSystem.ourValues(dreamComponent(ctx))).all { (k, v) -> putSecure(ctx, k, v) }
        OLog.i("sleep screen: Orbit's screen saver ${if (ok) "chosen" else "NOT chosen"} ($why)")
        return ok
    }

    /** A4: the vendor's screen saver back, exactly as it was. */
    fun restoreVendor(ctx: Context, why: String): Boolean {
        val p = sp(ctx)
        if (!p.getBoolean("vendor_saved", false) || !canSwitch(ctx)) return false
        val ok = SleepSystem.KEYS.all { k -> putSecure(ctx, k, p.getString("vendor_$k", null)) }
        if (ok) p.edit().putBoolean("vendor_saved", false).apply()
        OLog.i("sleep screen: the vendor's screen saver ${if (ok) "restored" else "NOT restored"} ($why)")
        return ok
    }

    private fun modeChanged(ctx: Context, was: SleepMode, now: SleepMode, why: String) {
        if (now != SleepMode.OFF && was == SleepMode.OFF) {
            chooseOurs(ctx, why)
        } else if (now == SleepMode.OFF) {
            restoreVendor(ctx, why)
            if (picture().delete()) OLog.i("sleep screen: picture deleted (off)")
        }
        Attention.evaluate(ctx.applicationContext, "sleep screen $why")
    }

    // ---------------------------------------------------------------- the files

    data class PoolItem(val id: Long, val title: String, val file: File)
    data class Current(val title: String, val authors: String, val file: File?)

    /** pool.json's items whose cover is on the device, in order. */
    fun pool(dir: File = dir()): List<PoolItem> = try {
        val items = JSONObject(File(dir, "pool.json").readText()).optJSONArray("items") ?: org.json.JSONArray()
        (0 until items.length()).mapNotNull { n ->
            val o = items.optJSONObject(n) ?: return@mapNotNull null
            val f = File(dir, o.optString("file"))
            val id = o.optLong("id")
            if (id > 0 && f.isFile && f.canonicalPath.startsWith(dir.canonicalPath)) PoolItem(id, o.optString("title"), f) else null
        }
    } catch (e: Exception) {
        emptyList()
    }

    fun current(dir: File = dir()): Current? = try {
        val o = JSONObject(File(dir, "current.json").readText())
        val f = o.optString("file").takeIf { it.isNotEmpty() }?.let { File(dir, it) }?.takeIf { it.isFile }
        Current(o.optString("title"), o.optString("authors"), f)
    } catch (e: Exception) {
        null
    }

    fun state(ctx: Context): SleepRotation.State {
        val p = sp(ctx)
        return SleepRotation.State(p.getLong("shown", 0L), p.getLong("changed_at", 0L), SleepRotation.decodeShows(p.getString("shows", null)))
    }

    /** Kept here, and in state.json for the plugin (its shuffle bag moves to what was shown). */
    private fun saveState(ctx: Context, st: SleepRotation.State) {
        // commit, not apply: the counts must survive a power-off right after the sleep.
        sp(ctx).edit().putLong("shown", st.shown).putLong("changed_at", st.changedAt)
            .putString("shows", SleepRotation.encodeShows(st.shows)).commit()
        runCatching {
            val d = dir()
            if (!d.isDirectory) return
            val tmp = File(d, "state.json.orbit-new")
            tmp.writeText(SleepRotation.stateJson(st))
            if (!tmp.renameTo(File(d, "state.json"))) tmp.delete()
        }
    }

    fun battery(ctx: Context): Int? {
        val i = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return null
        val level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        return if (level < 0 || scale <= 0) null else level * 100 / scale
    }

    /** The panel's real size and density. */
    fun panel(ctx: Context): Triple<Int, Int, Float> {
        val dm = DisplayMetrics()
        @Suppress("DEPRECATION")
        (ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay.getRealMetrics(dm)
        // L1: always portrait.
        return Triple(minOf(dm.widthPixels, dm.heightPixels), maxOf(dm.widthPixels, dm.heightPixels), dm.ydpi.takeIf { it > 0 } ?: dm.densityDpi.toFloat())
    }

    private fun decode(f: File?, w: Int, h: Int): Bitmap? {
        if (f == null) return null
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(f.path, o)
        if (o.outWidth <= 0) return null
        var sample = 1
        while (o.outWidth / (sample * 2) >= w && o.outHeight / (sample * 2) >= h) sample *= 2
        return BitmapFactory.decodeFile(f.path, BitmapFactory.Options().apply { inSampleSize = sample })
    }

    /**
     * What to show now, drawn. [advance]: the rotation moves on (a real sleep, a picture redraw);
     * a preview never moves it. A cover that can't be read (F6) is removed and the next case drawn.
     */
    fun render(ctx: Context, w: Int, h: Int, dpi: Float, advance: Boolean, why: String): Bitmap {
        val s = settings(ctx)
        val now = System.currentTimeMillis()
        val dir = dir()
        var pool = pool(dir)
        val cur = current(dir)
        var tries = 0
        while (true) {
            val d = SleepRotation.decide(s.mode, s.hours, now, pool.map { it.id }, cur != null, state(ctx), advance)
            val item = d.poolId?.let { id -> pool.firstOrNull { it.id == id } }
            val cover = when {
                // L7: BookOrbit's full-size cover, fitted to this panel, when it is here; else the thumbnail.
                item != null -> SharpCovers.fileFor(ctx, item.id)?.let { decode(it, w, h) } ?: decode(item.file, w, h)
                d.show == "current" -> cur?.file?.let { decode(it, w, h) }
                else -> null
            }
            if (item != null && cover == null && tries++ < 3) {
                OLog.i("sleep screen: cover ${item.id} unreadable; removed (F6)")
                item.file.delete()
                pool = pool - item
                continue
            }
            if (advance && d.next != state(ctx)) saveState(ctx, d.next)
            val kind = when {
                item != null -> "pool"
                d.show == "current" -> "current"
                else -> "default"
            }
            val inp = SleepCanvas.Input(
                w, h, SleepLayout.fontPx(dpi), s, cover, kind,
                title = cur?.title.orEmpty(), authors = cur?.authors.orEmpty(), battery = if (s.battery) battery(ctx) else null,
            )
            val (bmp, drawn) = SleepCanvas.render(inp)
            OLog.i("sleep screen: ${s.mode.key} -> ${d.show} ($why)${if (drawn.lines.isNotEmpty()) ", text ${drawn.lines.size} line(s)" else ""}${inp.battery?.let { ", battery $it%" } ?: ""}")
            cover?.recycle()
            return bmp
        }
    }

    // ---------------------------------------------------------------- the picture sink (R7)

    /** The plugin's files changed (SLEEP_POOL), a setting, the battery, or the alarm. */
    fun onPool(ctx: Context, why: String) {
        OLog.i("sleep screen: files changed ($why)")
        redrawPicture(ctx, why)
        // The plugin refreshes the pool only while the network is up: the time to fetch sharp covers.
        SharpCovers.sync(ctx, why)
    }

    @Volatile private var lastBattery = -1

    fun onBattery(ctx: Context, level: Int) {
        if (level == lastBattery) return
        val first = lastBattery < 0
        lastBattery = level
        if (!first && settings(ctx).battery) redrawPicture(ctx, "battery $level%")
    }

    /**
     * Every sleep on the picture sink: the reader shows the picture it already has, so the next
     * one is written when it wakes (R4b), ready for the next sleep.
     */
    @Synchronized
    fun onWake(ctx: Context, from: String) {
        val s = settings(ctx)
        if (s.mode != SleepMode.RECOMMENDED || s.hours != SleepSettings.EVERY_SLEEP) return
        // Two reporters, one wake: the service's SCREEN_ON and the plugin's resume (SleepWake).
        val now = android.os.SystemClock.elapsedRealtime()
        val p = sp(ctx)
        if (!SleepWake.due(p.getLong(KEY_WOKE_AT, 0L), now)) {
            OLog.d("sleep screen: wake ($from) already handled")
            return
        }
        p.edit().putLong(KEY_WOKE_AT, now).apply()
        redrawPicture(ctx, "woke ($from)", wake = true)
    }

    private const val KEY_WOKE_AT = "sleep_woke_at"

    /** [wake]: after a sleep; with Every sleep only that moves to a new cover, other redraws keep it. */
    fun redrawPicture(ctx: Context, why: String, wake: Boolean = false) {
        val s = settings(ctx)
        if (s.mode == SleepMode.OFF || sink(ctx) != SleepSink.PICTURE) return
        val out = picture()
        runCatching {
            val (w, h, dpi) = panel(ctx)
            // Every sleep: a wake moves on; so does a picture whose cover left the batch (or none yet).
            val advance = s.hours != SleepSettings.EVERY_SLEEP || wake || state(ctx).shown !in pool().map { it.id }
            val bmp = render(ctx, w, h, dpi, advance = advance, why = "picture: $why")
            out.parentFile?.mkdirs()
            val tmp = File(out.parentFile, "sleep.png.orbit-new")
            tmp.outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bmp.recycle()
            if (!tmp.renameTo(out)) {
                tmp.delete()
                error("rename failed")
            }
        }.onFailure { OLog.w("sleep screen: picture not written ($why)", it) }
        scheduleAlarm(ctx)
    }

    /** A non-wakeup alarm at last change + X: delivered at the next wake after it (R7). */
    private fun scheduleAlarm(ctx: Context) {
        val s = settings(ctx)
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = PendingIntent.getBroadcast(
            ctx, 7, Intent(ctx, SleepReceiver::class.java).setAction(ACTION_REDRAW),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        if ((s.mode != SleepMode.RECOMMENDED && s.mode != SleepMode.CURRENT) || s.hours == SleepSettings.EVERY_SLEEP) return am.cancel(pi)
        val at = state(ctx).changedAt + s.hours * 3_600_000L
        am.set(AlarmManager.RTC, maxOf(at, System.currentTimeMillis() + 60_000L), pi)
    }
}

/** The picture sink's alarm (R7). */
class SleepReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action == SleepScreen.ACTION_REDRAW) SleepScreen.redrawPicture(ctx, "alarm")
    }
}
