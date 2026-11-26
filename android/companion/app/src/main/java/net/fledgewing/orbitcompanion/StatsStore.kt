package net.fledgewing.orbitcompanion

import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import java.time.LocalDate
import java.time.ZoneId

/**
 * Battery stats storage (docs/design/STATS-DESIGN.md "Storage and retention"): app-private SQLite.
 * Raw rows for 90 days, daily rollups forever. Rolled up when the Battery page opens or the
 * service starts, never on a timer.
 */
class StatsStore private constructor(ctx: Context) : SQLiteOpenHelper(ctx.applicationContext, "stats.db", null, 2) {
    companion object {
        @Volatile
        private var inst: StatsStore? = null
        fun get(ctx: Context): StatsStore = inst ?: synchronized(this) { inst ?: StatsStore(ctx).also { inst = it } }

        private const val DAY_MS = 86_400_000L
        private const val LOOKBACK_DAYS = 8
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE snap(t INTEGER NOT NULL, kind TEXT NOT NULL, level INTEGER, charging INTEGER, screen INTEGER, " +
                "radio INTEGER, vpn INTEGER, wmode TEXT, content TEXT, light INTEGER, bright INTEGER, " +
                "pages INTEGER, full INTEGER, partial INTEGER, temp INTEGER, volt INTEGER, elapsed INTEGER)",
        )
        db.execSQL("CREATE INDEX snap_t ON snap(t)")
        db.execSQL(
            "CREATE TABLE daily(day INTEGER PRIMARY KEY, used_pct INTEGER, screen_min REAL, standby_min REAL, " +
                "charge_min REAL, pages INTEGER, full INTEGER, partial INTEGER, charges INTEGER)",
        )
        db.execSQL(
            "CREATE TABLE daily_cat(day INTEGER NOT NULL, cat TEXT NOT NULL, n INTEGER, sxx REAL, sxy REAL, syy REAL, " +
                "hours REAL, change REAL, segments INTEGER, pages INTEGER, full INTEGER, partial INTEGER, PRIMARY KEY(day, cat))",
        )
        db.execSQL("CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) db.execSQL("ALTER TABLE snap ADD COLUMN elapsed INTEGER")
    }

    private fun Boolean?.toInt(): Int? = this?.let { if (it) 1 else 0 }
    private fun Cursor.intOrNull(i: Int): Int? = if (isNull(i)) null else getInt(i)
    private fun Cursor.boolOrNull(i: Int): Boolean? = if (isNull(i)) null else getInt(i) != 0

    @Synchronized
    fun insert(s: Snap) {
        val v = ContentValues().apply {
            put("t", s.t); put("kind", s.kind); put("level", s.level); put("charging", s.charging.toInt()); put("screen", s.screen.toInt())
            put("radio", s.radio.toInt()); put("vpn", s.vpn.toInt()); put("wmode", s.wmode); put("content", s.content)
            put("light", s.light.toInt()); put("bright", s.bright); put("pages", s.pages); put("full", s.full); put("partial", s.partial)
            put("temp", s.temp); put("volt", s.volt); put("elapsed", s.elapsed)
        }
        writableDatabase.insert("snap", null, v)
    }

    fun snapsSince(t: Long): List<Snap> {
        val out = ArrayList<Snap>()
        readableDatabase.rawQuery(
            "SELECT t, kind, level, charging, screen, radio, vpn, wmode, content, light, bright, pages, full, partial, temp, volt, elapsed " +
                "FROM snap WHERE t >= ? ORDER BY rowid",
            arrayOf(t.toString()),
        ).use { c ->
            while (c.moveToNext()) {
                out += Snap(
                    c.getLong(0), c.getString(1), c.getInt(2), c.getInt(3) != 0, c.getInt(4) != 0, c.boolOrNull(5), c.boolOrNull(6),
                    c.getString(7), c.getString(8), c.boolOrNull(9), c.intOrNull(10), c.getInt(11), c.getInt(12), c.getInt(13),
                    c.intOrNull(14), c.intOrNull(15), if (c.isNull(16)) null else c.getLong(16),
                )
            }
        }
        return out
    }

    private fun firstT(): Long? = readableDatabase.rawQuery("SELECT MIN(t) FROM snap", null).use { c ->
        if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else null
    }

    private fun meta(k: String): String? = readableDatabase.rawQuery("SELECT v FROM meta WHERE k = ?", arrayOf(k)).use { c ->
        if (c.moveToFirst()) c.getString(0) else null
    }

    private fun setMeta(db: SQLiteDatabase, k: String, v: String) {
        db.insertWithOnConflict("meta", null, ContentValues().apply { put("k", k); put("v", v) }, SQLiteDatabase.CONFLICT_REPLACE)
    }

    private fun savedCharges(): List<Map<String, Any?>> {
        val bytes = meta("battery_recent_charges")?.toByteArray(Charsets.ISO_8859_1) ?: return emptyList()
        return (LuaValue.parse(bytes) as? List<*>).orEmpty().take(5).mapNotNull { it as? Map<*,*> }
            .map { row -> row.entries.associate { it.key.toString() to it.value } }
    }

    private fun retainCharges(db: SQLiteDatabase) {
        val rows = snapsSince(Long.MIN_VALUE)
        val recent = BatteryEstimate.charges(BatteryStats.segments(rows), rows.lastOrNull())
        val retained = BatteryEstimate.retainCharges(savedCharges(), recent)
        val encoded = String(LuaValue.encode(retained), Charsets.ISO_8859_1)
        if (meta("battery_recent_charges") != encoded) setMeta(db, "battery_recent_charges", encoded)
    }

    private fun dayStart(day: Long, zone: ZoneId) = LocalDate.ofEpochDay(day).atStartOfDay(zone).toInstant().toEpochMilli()

    /** Days up to yesterday go into the rollups; raw rows past 90 days (and already rolled) are deleted. */
    @Synchronized
    fun rollup(now: Long, zone: ZoneId) {
        val first = firstT() ?: return
        val today = BatteryStats.day(now, zone)
        val rolled = meta("rolled_until")?.toLongOrNull() ?: (BatteryStats.day(first, zone) - 1)
        val db = writableDatabase
        if (rolled < today - 1) {
            val rows = snapsSince(dayStart(rolled + 1, zone) - LOOKBACK_DAYS * DAY_MS)
            val range = (rolled + 1)..(today - 1)
            val cells = BatteryStats.rollup(BatteryStats.segments(rows, includeOpen = false), zone).filterKeys { it.first in range }
            val days = BatteryStats.daily(rows, zone, now).filterKeys { it in range }
            db.beginTransaction()
            try {
                for ((k, s) in cells) {
                    db.insertWithOnConflict("daily_cat", null, ContentValues().apply {
                        put("day", k.first); put("cat", k.second); put("n", s.n); put("sxx", s.sxx); put("sxy", s.sxy); put("syy", s.syy)
                        put("hours", s.hours); put("change", s.change); put("segments", s.segments); put("pages", s.pages)
                        put("full", s.full); put("partial", s.partial)
                    }, SQLiteDatabase.CONFLICT_REPLACE)
                }
                for (d in days.values) {
                    db.insertWithOnConflict("daily", null, ContentValues().apply {
                        put("day", d.day); put("used_pct", d.usedPct); put("screen_min", d.screenMin); put("standby_min", d.standbyMin)
                        put("charge_min", d.chargeMin); put("pages", d.pages); put("full", d.full); put("partial", d.partial); put("charges", d.charges)
                    }, SQLiteDatabase.CONFLICT_REPLACE)
                }
                setMeta(db, "rolled_until", (today - 1).toString())
                db.setTransactionSuccessful()
            } finally {
                db.endTransaction()
            }
            OLog.i("stats: rolled up ${range.last - range.first + 1} day(s), ${cells.size} cells")
        }
        // Preserve the latest five session details before deleting their raw evidence.
        retainCharges(db)
        val keepFrom = minOf(now - BatteryStats.RAW_DAYS * DAY_MS, dayStart(today, zone) - LOOKBACK_DAYS * DAY_MS)
        val n = db.delete("snap", "t < ?", arrayOf(keepFrom.toString()))
        if (n > 0) OLog.i("stats: deleted $n raw rows older than ${BatteryStats.RAW_DAYS} days")
    }

    /** Everything the Battery page and the export show: rollups plus the live part since. */
    class View(
        val totals: Map<String, Sums>,
        val days: List<DayTotals>,
        val last: Snap?,
        val rawSince: Long,
    )

    @Synchronized
    fun view(now: Long, zone: ZoneId, dayLimit: Int? = null): View {
        rollup(now, zone)
        val rolled = meta("rolled_until")?.toLongOrNull() ?: (BatteryStats.day(now, zone) - 1)
        val totals = HashMap<String, Sums>()
        readableDatabase.rawQuery("SELECT cat, SUM(n), SUM(sxx), SUM(sxy), SUM(syy), SUM(hours), SUM(change), SUM(segments), SUM(pages), SUM(full), SUM(partial) FROM daily_cat GROUP BY cat", null).use { c ->
            while (c.moveToNext()) {
                totals[c.getString(0)] = Sums(c.getInt(1), c.getDouble(2), c.getDouble(3), c.getDouble(4), c.getDouble(5), c.getDouble(6), c.getInt(7), c.getLong(8), c.getLong(9), c.getLong(10))
            }
        }
        val days = ArrayList<DayTotals>()
        readableDatabase.rawQuery("SELECT day, used_pct, screen_min, standby_min, charge_min, pages, full, partial, charges FROM daily " + (dayLimit?.let { "WHERE day >= ${BatteryStats.day(now, zone)-it+1} " } ?: "") + "ORDER BY day", null).use { c ->
            while (c.moveToNext()) days += DayTotals(c.getLong(0), c.getInt(1), c.getDouble(2), c.getDouble(3), c.getDouble(4), c.getInt(5), c.getInt(6), c.getInt(7), c.getInt(8))
        }
        val rows = snapsSince(dayStart(rolled + 1, zone) - LOOKBACK_DAYS * DAY_MS)
        val live = BatteryStats.rollup(BatteryStats.segments(rows, now), zone).filterKeys { it.first > rolled }
        for ((k, s) in live) totals[k.second] = (totals[k.second] ?: Sums()) + s
        days += BatteryStats.daily(rows, zone, now).values.filter { it.day > rolled }.sortedBy { it.day }
        return View(totals, days.filter { dayLimit == null || it.day >= BatteryStats.day(now, zone)-dayLimit+1 }, rows.lastOrNull(), firstT() ?: now)
    }

    /** Worker-only normalized snapshot. Raw measurements stay in stats.db, never in Lua. */
    @Synchronized
    fun batterySnapshot(now: Long, zone: ZoneId): Map<String, Any?> {
        val raw = snapsSince(now - BatteryStats.RAW_DAYS * DAY_MS)
        val rollupAhead = (meta("rolled_until")?.toLongOrNull() ?: Long.MIN_VALUE) >= BatteryStats.day(now, zone)
        val v = if (rollupAhead) {
            // A backwards clock correction must not let a future day cursor hide current data.
            // Keep archived statistics intact and project only observed raw intervals here.
            rollup(now, zone)
            val segments = BatteryStats.segments(raw)
            View(BatteryStats.totals(BatteryStats.rollup(segments, zone)),
                BatteryStats.daily(raw, zone).values.toList(), raw.lastOrNull(), firstT() ?: now)
        } else view(now, zone, 14)
        return BatteryEstimate.snapshot(v.totals, v.days, v.last, emptyList(), now, zone,
            BatteryEstimate.usualDays(raw, now), recentCharges = savedCharges())
    }

    /** Segments over the raw window, for the export. */
    fun exportSegments(now: Long): List<Segment> = BatteryStats.segments(snapsSince(now - BatteryStats.RAW_DAYS * DAY_MS), now)
}

/**
 * Records battery-relevant state changes (docs/design/STATS-DESIGN.md "What is recorded"). Lives in
 * the foreground service; uses only broadcasts the system sends anyway: no alarms, no polling.
 */
class StatsRecorder(private val ctx: Context, private val prefs: Prefs) {
    private val store = StatsStore.get(ctx)
    private var level = -1
    private var charging = false
    private var temp: Int? = null
    private var volt: Int? = null
    private var content: String? = null
    private var contentAt = 0L
    private var registered = false

    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_TIME_CHANGED) record(Snap.START)
            else if (readBattery(intent)) record("battery")
        }
    }

    /** True when the level or the plug state changed (temperature and voltage ride along). */
    private fun readBattery(i: Intent): Boolean {
        val raw = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
        val lvl = if (raw >= 0 && scale > 0) raw * 100 / scale else -1
        val plugged = i.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0
        temp = i.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE).takeIf { it != Int.MIN_VALUE }
        volt = i.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1).takeIf { it > 0 }
        val changed = lvl != level || plugged != charging
        level = lvl
        charging = plugged
        return changed
    }

    fun start() {
        val filter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        ctx.registerReceiver(null, filter)?.let { readBattery(it) }
        record(Snap.START)
        ctx.registerReceiver(batteryReceiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED).apply { addAction(Intent.ACTION_TIME_CHANGED) })
        registered = true
        try {
            store.rollup(System.currentTimeMillis(), ZoneId.systemDefault())
        } catch (e: Exception) {
            OLog.w("stats: rollup failed", e)
        }
    }

    fun stop() {
        if (registered) ctx.unregisterReceiver(batteryReceiver)
        registered = false
    }

    /** A STATS batch from the patch: counts for the time before it, and the book now open (or none). */
    fun onStats(i: Intent) {
        fun n(k: String) = i.getStringExtra(k)?.toIntOrNull()?.coerceAtLeast(0) ?: 0
        val c = i.getStringExtra("content")?.takeIf { it in setOf("text", "comic", "webtoon", "pdf") }
        content = if (i.getStringExtra("open") == "1") c else null
        contentAt = System.currentTimeMillis()
        record("stats", n("pages"), n("full"), n("partial"))
        OLog.d("stats: ${i.getStringExtra("reason")} ${n("pages")} pages, ${n("full")}/${n("partial")} refreshes, ${content ?: "no book"}")
    }

    fun record(kind: String, pages: Int = 0, full: Int = 0, partial: Int = 0) {
        try {
            val now = System.currentTimeMillis()
            val screen = (ctx.getSystemService(Context.POWER_SERVICE) as PowerManager).isInteractive
            val book = content?.takeIf { now - contentAt <= BatteryStats.CONTENT_FRESH_MS }
            val cr = ctx.contentResolver
            val bright = try { Settings.System.getInt(cr, Settings.System.SCREEN_BRIGHTNESS) } catch (e: Exception) { null }
            val light = Vendor.profile(ctx).lightKey?.let { k ->
                when (Settings.System.getString(cr, k)?.lowercase()) {
                    "true", "1" -> true
                    "false", "0" -> false
                    else -> null
                }
            }
            store.insert(Snap(now, kind, level, charging, screen, Net.wifiEnabled(ctx), Net.vpnUp(ctx), prefs.wifiMode.key,
                book, light, bright, pages, full, partial, temp, volt, android.os.SystemClock.elapsedRealtime()))
        } catch (e: Exception) {
            OLog.w("stats: record $kind failed", e)
        }
    }

    companion object {
        /** Battery capacity: the fuel gauge's charge counter, else the power profile (hidden API, greylisted). */
        fun capacity(ctx: Context): Pair<Int, String>? {
            try {
                val bm = ctx.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                val uah = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER)
                val lvl = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                if (uah > 0 && lvl in 5..100) return (uah.toLong() * 100 / lvl / 1000).toInt() to "charge_counter"
            } catch (e: Exception) {
                OLog.d("stats: no charge counter: $e")
            }
            return try {
                val cls = Class.forName("com.android.internal.os.PowerProfile")
                val pp = cls.getConstructor(Context::class.java).newInstance(ctx)
                val mah = (cls.getMethod("getBatteryCapacity").invoke(pp) as Double).toInt()
                if (mah > 0) mah to "power_profile" else null
            } catch (e: Throwable) {
                OLog.d("stats: no power profile: $e")
                null
            }
        }

        fun device(ctx: Context): StatsExport.Device {
            val cap = capacity(ctx)
            return StatsExport.Device(Build.MANUFACTURER, Build.MODEL, Build.VERSION.RELEASE, cap?.first, cap?.second)
        }
    }
}
