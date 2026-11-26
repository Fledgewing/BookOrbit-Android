package net.fledgewing.orbitcompanion

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/*
 * Battery stats, pure part (docs/design/STATS-DESIGN.md). No Android here, so it is unit-tested:
 * segmenting, the pooled slope, low-data hiding, the estimate, daily totals, and the
 * orbit-battery-stats/1 export and import.
 */

/** One recorded row: the whole state after an event. level -1 = unknown. */
data class Snap(
    val t: Long,
    val kind: String,
    val level: Int,
    val charging: Boolean,
    val screen: Boolean,
    val radio: Boolean? = null,
    val vpn: Boolean? = null,
    val wmode: String? = null,
    val content: String? = null,
    val light: Boolean? = null,
    val bright: Int? = null,
    val pages: Int = 0,
    val full: Int = 0,
    val partial: Int = 0,
    val temp: Int? = null,
    val volt: Int? = null,
    val elapsed: Long? = null,
) {
    companion object {
        /** The service (re)started: nothing is known about the time before this row. */
        const val START = "start"
    }
}

/** standby = screen off; reading = a book in front (from the patch); awake = screen on, anything else. */
enum class PowerState(val key: String) {
    STANDBY("standby"), READING("reading"), AWAKE("awake"), CHARGING("charging");

    companion object {
        fun of(s: Snap): PowerState = when {
            s.charging -> CHARGING
            !s.screen -> STANDBY
            s.content != null -> READING
            else -> AWAKE
        }

        fun fromKey(k: String?): PowerState? = values().firstOrNull { it.key == k }
    }
}

/** What makes two rows part of the same segment. */
data class SegKey(
    val state: PowerState,
    val radio: Boolean?,
    val vpn: Boolean?,
    val wmode: String?,
    val content: String?,
    val light: Boolean?,
) {
    companion object {
        fun of(s: Snap): SegKey {
            val st = PowerState.of(s)
            val on = st == PowerState.READING || st == PowerState.AWAKE
            return SegKey(st, s.radio, s.vpn, s.wmode, if (st == PowerState.READING) s.content else null, if (on) s.light else null)
        }
    }
}

/**
 * Sufficient statistics of a fixed-effects (per-segment intercept) least-squares fit of level
 * on time, t in hours: sums of squares centred within each segment, which add across segments
 * and days. So rates are exact from the daily rollups after the raw rows are gone.
 */
data class Sums(
    val n: Int = 0,
    val sxx: Double = 0.0,
    val sxy: Double = 0.0,
    val syy: Double = 0.0,
    val hours: Double = 0.0,
    val change: Double = 0.0,
    val segments: Int = 0,
    val pages: Long = 0,
    val full: Long = 0,
    val partial: Long = 0,
) {
    operator fun plus(o: Sums) = Sums(
        n + o.n, sxx + o.sxx, sxy + o.sxy, syy + o.syy, hours + o.hours, change + o.change,
        segments + o.segments, pages + o.pages, full + o.full, partial + o.partial,
    )
}

data class Segment(
    val start: Long,
    val end: Long,
    val key: SegKey,
    val startPct: Int,
    val endPct: Int,
    val sums: Sums,
    val pages: Int,
    val full: Int,
    val partial: Int,
) {
    val hours: Double get() = (end - start) / 3_600_000.0
}

data class Rate(val pctPerH: Double, val se: Double?, val hours: Double, val change: Double, val segments: Int, val shown: Boolean, val missing: String?)

data class DayTotals(
    val day: Long,
    val usedPct: Int = 0,
    val screenMin: Double = 0.0,
    val standbyMin: Double = 0.0,
    val chargeMin: Double = 0.0,
    val pages: Int = 0,
    val full: Int = 0,
    val partial: Int = 0,
    val charges: Int = 0,
)

object BatteryStats {
    const val MIN_HOURS = 1.0
    const val MIN_HOURS_CHARGING = 0.5
    const val MIN_CHANGE_PCT = 2.0
    const val MIN_COUNT_PER_100 = 100L
    const val ESTIMATE_WINDOW_DAYS = 7
    const val ESTIMATE_MIN_HOURS = 24.0

    /** The patch's last STATS says a book is open; it counts for this long without a new one. */
    const val CONTENT_FRESH_MS = 6 * 60_000L
    const val RAW_DAYS = 90

    private const val H = 3_600_000.0

    private class Builder(val first: Snap) {
        val key = SegKey.of(first)
        var last: Snap = first
        var firstPct = -1
        var lastPct = -1
        var n = 0
        var st = 0.0
        var sy = 0.0
        var stt = 0.0
        var sty = 0.0
        var syy = 0.0
        var pages = 0
        var full = 0
        var partial = 0

        init {
            point(first)
        }

        fun point(s: Snap) {
            last = s
            if (s.level < 0) return
            if (firstPct < 0) firstPct = s.level
            lastPct = s.level
            val t = (s.t - first.t) / H
            val y = s.level.toDouble()
            n++; st += t; sy += y; stt += t * t; sty += t * y; syy += y * y
        }

        fun counts(s: Snap) {
            pages += s.pages; full += s.full; partial += s.partial
        }

        fun build(): Segment {
            val sums = if (n == 0) Sums(segments = 1) else {
                val change = if (firstPct >= 0) (if (key.state == PowerState.CHARGING) lastPct - firstPct else firstPct - lastPct).toDouble() else 0.0
                Sums(
                    n = n,
                    sxx = max(0.0, stt - st * st / n),
                    sxy = sty - st * sy / n,
                    syy = max(0.0, syy - sy * sy / n),
                    change = change,
                    segments = 1,
                )
            }
            val hours = (last.t - first.t) / H
            return Segment(first.t, last.t, key, firstPct, lastPct,
                sums.copy(hours = hours, pages = pages.toLong(), full = full.toLong(), partial = partial.toLong()),
                pages, full, partial)
        }
    }

    /**
     * Splits rows (sorted by time) into segments of one state. A row that changes the state
     * ends the current segment (its level is that segment's last point) and starts the next.
     * Counts in a row (STATS) cover the time before it, so they go to the segment it ends or
     * continues. A START row ends the segment at the previous row: the gap is unknown.
     * includeOpen = false leaves out the last, still-open segment (rollups only take final ones).
     * [now] closes the open segment with the current level (it hasn't changed since, or there'd be a row).
     */
    fun segments(rows: List<Snap>, now: Long? = null, includeOpen: Boolean = true): List<Segment> {
        val out = mutableListOf<Segment>()
        var cur: Builder? = null
        for (s in rows) {
            val b = cur
            if (b != null) {
                if (gap(b.last, s)) {
                    out += b.build()
                    cur = null
                } else {
                    b.point(s)
                    b.counts(s)
                    if (SegKey.of(s) != b.key) {
                        out += b.build()
                        cur = null
                    }
                }
            }
            if (cur == null) cur = Builder(s)
        }
        if (includeOpen) cur?.let { b ->
            if (now != null && now > b.last.t) b.point(b.last.copy(t = now, kind = "now", pages = 0, full = 0, partial = 0))
            if (b.last.t > b.first.t) out += b.build()
        }
        return out
    }

    /** A restart, backwards clock or wall/monotonic disagreement makes the gap unknown. */
    fun gap(a: Snap, b: Snap): Boolean = b.kind == Snap.START || b.t <= a.t ||
        (a.elapsed != null && b.elapsed != null &&
            (b.elapsed <= a.elapsed || kotlin.math.abs((b.t-a.t)-(b.elapsed-a.elapsed)) > 60_000))

    /** The rate categories a segment adds to: "state" and "state|dimension=value". */
    fun categories(k: SegKey): List<String> {
        val s = k.state.key
        fun onOff(b: Boolean?) = b?.let { if (it) "on" else "off" }
        val dims = when (k.state) {
            PowerState.STANDBY -> listOf("wifi_mode" to k.wmode, "radio" to onOff(k.radio))
            PowerState.READING -> listOf("content" to k.content, "wifi_mode" to k.wmode, "light" to onOff(k.light))
            PowerState.AWAKE -> listOf("wifi_mode" to k.wmode, "light" to onOff(k.light))
            PowerState.CHARGING -> emptyList()
        }
        return listOf(s) + dims.filter { it.second != null }.map { "$s|${it.first}=${it.second}" }
    }

    fun day(t: Long, zone: ZoneId): Long = Instant.ofEpochMilli(t).atZone(zone).toLocalDate().toEpochDay()

    private fun dayStart(day: Long, zone: ZoneId): Long = LocalDate.ofEpochDay(day).atStartOfDay(zone).toInstant().toEpochMilli()

    /** Per (day of the segment's end, category) sums. */
    fun rollup(segs: List<Segment>, zone: ZoneId): Map<Pair<Long, String>, Sums> {
        val out = HashMap<Pair<Long, String>, Sums>()
        for (g in segs) {
            val d = day(g.end, zone)
            for (c in categories(g.key)) out[d to c] = (out[d to c] ?: Sums()) + g.sums
        }
        return out
    }

    fun totals(cells: Map<Pair<Long, String>, Sums>): Map<String, Sums> {
        val out = HashMap<String, Sums>()
        for ((k, v) in cells) out[k.second] = (out[k.second] ?: Sums()) + v
        return out
    }

    /** %/h from pooled sums: drain as a positive number, charging as a positive rise. */
    fun rate(cat: String, s: Sums?): Rate? {
        if (s == null || s.segments == 0) return null
        val charging = cat.startsWith(PowerState.CHARGING.key)
        val slope = if (s.sxx > 0) s.sxy / s.sxx else 0.0
        val v = if (charging) slope else -slope
        val df = s.n - s.segments - 1
        val se = if (s.sxx > 0 && df > 0) sqrt(max(0.0, s.syy - slope * s.sxy) / df / s.sxx) else null
        val minH = if (charging) MIN_HOURS_CHARGING else MIN_HOURS
        val missing = when {
            s.hours < minH -> String.format(java.util.Locale.US, "%.1f h of %.0f h needed", s.hours, minH)
            s.change <= MIN_CHANGE_PCT -> String.format(java.util.Locale.US, "%.0f%% change of >2%% needed", s.change)
            s.sxx <= 0 -> "no change seen yet"
            !v.isFinite() || v <= 0 -> "more samples needed for a positive rate"
            else -> null
        }
        return Rate(v, se, s.hours, s.change, s.segments, missing == null, missing)
    }

    /** "%" per 100 units: rate × hours ÷ count × 100; null when the rate or the count is too small. */
    fun per100(r: Rate?, count: Long): Double? {
        if (r == null || !r.shown || count < MIN_COUNT_PER_100) return null
        return r.pctPerH * r.hours / count * 100
    }

    /** Days, split at midnight: % used (drops while not charging), minutes per state, counts. */
    fun daily(rows: List<Snap>, zone: ZoneId, now: Long? = null): Map<Long, DayTotals> {
        val out = HashMap<Long, DayTotals>()
        fun upd(d: Long, f: (DayTotals) -> DayTotals) {
            out[d] = f(out[d] ?: DayTotals(d))
        }
        val all = if (now != null && rows.isNotEmpty() && now > rows.last().t) rows + rows.last().copy(t = now, kind = "now", pages = 0, full = 0, partial = 0,
            elapsed = rows.last().elapsed?.plus(now-rows.last().t)) else rows
        for (i in all.indices) {
            val b = all[i]
            if (b.pages + b.full + b.partial > 0) upd(day(b.t, zone)) { it.copy(pages = it.pages + b.pages, full = it.full + b.full, partial = it.partial + b.partial) }
            if (i == 0 || gap(all[i-1], b)) continue
            val a = all[i - 1]
            val st = PowerState.of(a)
            if (!a.charging && a.level >= 0 && b.level >= 0 && b.level < a.level) {
                upd(day(b.t, zone)) { it.copy(usedPct = it.usedPct + (a.level - b.level)) }
            }
            if (!a.charging && b.charging) upd(day(b.t, zone)) { it.copy(charges = it.charges + 1) }
            var t0 = a.t
            while (t0 < b.t) {
                val d = day(t0, zone)
                val t1 = min(b.t, dayStart(d + 1, zone))
                val m = (t1 - t0) / 60_000.0
                upd(d) {
                    when (st) {
                        PowerState.CHARGING -> it.copy(chargeMin = it.chargeMin + m)
                        PowerState.STANDBY -> it.copy(standbyMin = it.standbyMin + m)
                        else -> it.copy(screenMin = it.screenMin + m)
                    }
                }
                t0 = t1
            }
        }
        return out
    }

    /** Screen-on share of the not-charging time over the days given; null under 24 h of data. */
    fun onShare(days: Collection<DayTotals>): Double? {
        val on = days.sumOf { it.screenMin }
        val off = days.sumOf { it.standbyMin }
        if ((on + off) / 60 < ESTIMATE_MIN_HOURS) return null
        return on / (on + off)
    }

    /** Hours left at [level]% with screen-on share f: level ÷ (f·R_on + (1−f)·R_standby). */
    fun hoursLeft(level: Int, f: Double?, rOn: Rate?, rStandby: Rate?): Double? {
        if (f == null || level < 0 || rOn?.shown != true || rStandby?.shown != true) return null
        if (!rOn.pctPerH.isFinite() || !rStandby.pctPerH.isFinite() || rOn.pctPerH <= 0 || rStandby.pctPerH <= 0) return null
        val per = f * rOn.pctPerH + (1 - f) * rStandby.pctPerH
        return if (per > 0) level / per else null
    }

    fun hoursLeftAt(level: Int, r: Rate?): Double? =
        if (level < 0 || r?.shown != true || !r.pctPerH.isFinite() || r.pctPerH <= 0) null else level / r.pctPerH
}

/** orbit-battery-stats/1: the device-comparison file (docs/design/STATS-DESIGN.md "Export JSON"). */
object StatsExport {
    const val SCHEMA = "orbit-battery-stats/1"
    const val SOURCE_ANDROID = "android-companion"
    const val SOURCE_FIRMWARE = "crossink-firmware"

    data class Device(
        val manufacturer: String,
        val model: String,
        val androidVersion: String?,
        val capacityMah: Int?,
        val capacitySource: String?,
    )

    fun iso(t: Long, zone: ZoneId): String =
        java.time.format.DateTimeFormatter.ISO_OFFSET_DATE_TIME.format(OffsetDateTime.ofInstant(Instant.ofEpochMilli(t), zone).withNano(0))

    private fun JSONObject.opt(k: String, v: Any?): JSONObject = if (v == null) this else put(k, v)

    private fun onOff(b: Boolean?): String? = b?.let { if (it) "on" else "off" }

    /** "on"/"off" (the format), also true/false; anything else is unknown. */
    private fun onOffOf(o: JSONObject, k: String): String? {
        if (!o.has(k) || o.isNull(k)) return null
        return when (val v = o.get(k)) {
            is Boolean -> if (v) "on" else "off"
            else -> v.toString().lowercase().takeIf { it == "on" || it == "off" }
        }
    }

    /** A timestamp, or null when missing, null or empty (a device whose clock was never set). */
    private fun time(o: JSONObject, k: String): Long? {
        val v = o.optString(k)
        if (o.isNull(k) || v.isBlank()) return null
        return runCatching { OffsetDateTime.parse(v).toInstant().toEpochMilli() }.getOrNull()
    }

    private fun r1(v: Double) = Math.round(v * 10) / 10.0
    private fun r3(v: Double) = Math.round(v * 1000) / 1000.0

    /** "reading|content=text" -> {"state":"reading","content":"text"}. */
    fun catFields(cat: String): JSONObject {
        val o = JSONObject().put("state", cat.substringBefore('|'))
        cat.split('|').drop(1).forEach { d -> o.put(d.substringBefore('='), d.substringAfter('=')) }
        return o
    }

    fun catOf(o: JSONObject): String? {
        val state = o.optString("state").takeIf { PowerState.fromKey(it) != null } ?: return null
        val dims = listOf("content", "wifi_mode", "radio", "light").mapNotNull { k ->
            val v = if (k == "radio" || k == "light") onOffOf(o, k) else o.optString(k).takeIf { !o.isNull(k) && it.isNotBlank() }
            v?.let { "$k=$it" }
        }
        return if (dims.size > 1) null else listOf(state).plus(dims).joinToString("|")
    }

    fun build(
        device: Device,
        version: String,
        generated: Long,
        zone: ZoneId,
        totals: Map<String, Sums>,
        days: List<DayTotals>,
        segments: List<Segment>,
    ): JSONObject {
        val rates = JSONArray()
        val per100 = JSONArray()
        for ((cat, s) in totals.toSortedMap()) {
            val r = BatteryStats.rate(cat, s) ?: continue
            if (s.hours <= 0) continue
            rates.put(catFields(cat).put("pct_per_h", r3(r.pctPerH)).opt("se", r.se?.let { r3(it) })
                .put("hours", r1(r.hours)).put("change_pct", r1(r.change)).put("segments", r.segments))
            if (cat.startsWith("reading") && !cat.contains("wifi_mode") && !cat.contains("light")) {
                BatteryStats.per100(r, s.pages)?.let { per100.put(catFields(cat).put("unit", "pages").put("pct", r3(it)).put("count", s.pages)) }
                BatteryStats.per100(r, s.full)?.let { per100.put(catFields(cat).put("unit", "full_refreshes").put("pct", r3(it)).put("count", s.full)) }
            }
        }
        val sortedDays = days.sortedBy { it.day }
        val daily = JSONArray()
        sortedDays.forEach { d ->
            daily.put(JSONObject().put("day", LocalDate.ofEpochDay(d.day).toString()).put("used_pct", d.usedPct)
                .put("screen_on_min", Math.round(d.screenMin)).put("standby_min", Math.round(d.standbyMin))
                .put("charge_min", Math.round(d.chargeMin)).put("pages", d.pages).put("full", d.full)
                .put("partial", d.partial).put("charges", d.charges))
        }
        val segs = JSONArray()
        segments.forEach { g ->
            val o = JSONObject().put("start", iso(g.start, zone)).put("end", iso(g.end, zone))
                .put("duration_s", (g.end - g.start) / 1000).put("state", g.key.state.key)
            if (g.startPct >= 0) o.put("start_pct", g.startPct).put("end_pct", g.endPct)
            o.opt("wifi_mode", g.key.wmode).opt("radio", onOff(g.key.radio)).opt("vpn", onOff(g.key.vpn))
                .opt("content", g.key.content).opt("light", onOff(g.key.light))
            if (g.pages + g.full + g.partial > 0) o.put("pages", g.pages).put("full", g.full).put("partial", g.partial)
            segs.put(o)
        }
        val dev = JSONObject().put("manufacturer", device.manufacturer).put("model", device.model)
            .opt("android_version", device.androidVersion).opt("capacity_mah", device.capacityMah)
            .opt("capacity_source", device.capacitySource)
        val o = JSONObject().put("schema", SCHEMA).put("source", SOURCE_ANDROID).put("source_version", version)
            .put("generated", iso(generated, zone)).put("device", dev).put("battery_source", "fuel_gauge")
        if (sortedDays.isNotEmpty()) {
            o.put("period", JSONObject().put("first_day", LocalDate.ofEpochDay(sortedDays.first().day).toString())
                .put("last_day", LocalDate.ofEpochDay(sortedDays.last().day).toString()).put("days", sortedDays.size))
        }
        return o.put("rates", rates).put("per_100", per100).put("daily", daily).put("segments", segs)
    }

    /** An imported summary, ready for Compare. */
    data class Imported(
        val label: String,
        val androidVersion: String?,
        val source: String,
        val batterySource: String?,
        val capacityMah: Int?,
        val days: Int,
        val rates: Map<String, Rate>,
        val per100Pages: Double?,
        val per100Full: Double?,
        /** Hours of data behind the rates (sum over states), for files without dates. */
        val hours: Double,
    ) {
        /** Firmware readers only know asleep/awake: standby = asleep, screen-on = awake. */
        val asleepAwake: Boolean get() = source == SOURCE_FIRMWARE
    }

    class BadFile(msg: String) : Exception(msg)

    /** Reads any orbit-battery-stats/1 file. Unknown fields are ignored; rates missing are fitted from the segments. */
    fun parse(text: String): Imported {
        val o = try { JSONObject(text) } catch (e: Exception) { throw BadFile("not JSON") }
        val schema = o.optString("schema")
        if (!schema.startsWith("orbit-battery-stats/")) throw BadFile("not a battery summary (no \"schema\")")
        if (schema != SCHEMA) throw BadFile("format $schema is newer than this app reads")
        val dev = o.optJSONObject("device") ?: JSONObject()
        val label = listOf(dev.optString("manufacturer"), dev.optString("model")).filter { it.isNotBlank() }.joinToString(" ").ifBlank { "Unknown device" }
        val rates = HashMap<String, Rate>()
        o.optJSONArray("rates")?.let { a ->
            for (i in 0 until a.length()) {
                val r = a.optJSONObject(i) ?: continue
                val cat = catOf(r) ?: continue
                if (!r.has("pct_per_h")) continue
                val hours = r.optDouble("hours", 0.0)
                val change = r.optDouble("change_pct", 0.0)
                val minH = if (cat.startsWith("charging")) BatteryStats.MIN_HOURS_CHARGING else BatteryStats.MIN_HOURS
                val shown = hours >= minH && change > BatteryStats.MIN_CHANGE_PCT
                rates[cat] = Rate(r.getDouble("pct_per_h"), if (r.has("se")) r.optDouble("se") else null, hours, change,
                    r.optInt("segments", 0), shown, if (shown) null else String.format(java.util.Locale.US, "%.1f h", hours))
            }
        }
        // Fit what wasn't given from the segments' start and end (two points each).
        val fitted = HashMap<String, Sums>()
        o.optJSONArray("segments")?.let { a ->
            for (i in 0 until a.length()) {
                val g = a.optJSONObject(i) ?: continue
                val state = PowerState.fromKey(g.optString("state")) ?: continue
                if (!g.has("start_pct") || !g.has("end_pct")) continue
                // Times first; without a clock, duration_s alone is enough for a rate.
                val t0 = time(g, "start")
                val t1 = time(g, "end")
                val ms = if (t0 != null && t1 != null) t1 - t0 else g.optLong("duration_s", -1) * 1000
                if (ms <= 0) continue
                val y0 = g.getInt("start_pct").toDouble()
                val y1 = g.getInt("end_pct").toDouble()
                val dt = ms / 3_600_000.0
                val s = Sums(2, dt * dt / 2, dt * (y1 - y0) / 2, (y1 - y0) * (y1 - y0) / 2, dt,
                    if (state == PowerState.CHARGING) y1 - y0 else y0 - y1, 1, g.optLong("pages"), g.optLong("full"), g.optLong("partial"))
                fun onOff(k: String) = onOffOf(g, k)
                val key = SegKey(state, null, null, g.optString("wifi_mode").ifBlank { null }, g.optString("content").ifBlank { null }, null)
                val cats = BatteryStats.categories(key).toMutableList()
                onOff("light")?.let { if (state == PowerState.READING || state == PowerState.AWAKE) cats += "${state.key}|light=$it" }
                onOff("radio")?.let { if (state == PowerState.STANDBY) cats += "${state.key}|radio=$it" }
                for (c in cats) fitted[c] = (fitted[c] ?: Sums()) + s
            }
        }
        for ((c, s) in fitted) if (c !in rates) BatteryStats.rate(c, s)?.let { rates[c] = it }
        var p100pages: Double? = null
        var p100full: Double? = null
        o.optJSONArray("per_100")?.let { a ->
            for (i in 0 until a.length()) {
                val r = a.optJSONObject(i) ?: continue
                if (r.optString("state") != "reading" || r.has("content")) continue
                when (r.optString("unit")) {
                    "pages" -> p100pages = r.optDouble("pct")
                    "full_refreshes" -> p100full = r.optDouble("pct")
                }
            }
        }
        if (p100pages == null) p100pages = BatteryStats.per100(rates["reading"], fitted["reading"]?.pages ?: 0)
        if (p100full == null) p100full = BatteryStats.per100(rates["reading"], fitted["reading"]?.full ?: 0)
        // Per-day history only from rows with a real date.
        var dated = 0
        o.optJSONArray("daily")?.let { a ->
            for (i in 0 until a.length()) {
                val d = a.optJSONObject(i) ?: continue
                if (!d.isNull("day") && runCatching { LocalDate.parse(d.optString("day")) }.isSuccess) dated++
            }
        }
        val days = o.optJSONObject("period")?.optInt("days", 0)?.takeIf { it > 0 } ?: dated
        return Imported(
            label = label,
            androidVersion = dev.optString("android_version").ifBlank { null },
            source = o.optString("source").ifBlank { "unknown" },
            batterySource = o.optString("battery_source").ifBlank { null },
            capacityMah = if (dev.has("capacity_mah")) dev.optInt("capacity_mah") else null,
            days = days,
            rates = rates,
            per100Pages = p100pages,
            per100Full = p100full,
            hours = rates.filterKeys { !it.contains('|') }.values.sumOf { it.hours },
        )
    }
}
