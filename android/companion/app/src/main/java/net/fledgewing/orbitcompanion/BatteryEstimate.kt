// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import java.time.ZoneId

/** Companion-only projection of the existing persisted statistics. Units are %, hours and ms.
 * No model constants pretend to measure a power policy: unseen patterns use pooled rates and
 * explicitly say estimate. Saver and Balanced share JIT Wi-Fi and therefore the same evidence.
 */
object BatteryEstimate {
    /** Exact trailing seven days, clipping observed intervals at the boundary. Unknown gaps and
     * charging are excluded; there is no assumed screen-off time between service sessions. */
    fun usualDays(rows: List<Snap>, now: Long): List<DayTotals> {
        val cutoff = now - 7*86_400_000L
        var on = 0.0
        var off = 0.0
        for ((a,b) in rows.zipWithNext()) {
            if (BatteryStats.gap(a,b) || a.charging) continue
            val minutes = (minOf(now,b.t)-maxOf(cutoff,a.t)).coerceAtLeast(0)/60_000.0
            if (a.screen) on += minutes else off += minutes
        }
        return listOf(DayTotals(0,screenMin=on,standbyMin=off))
    }

    /** Existing Settings consumer contract: three ready-to-draw preset rows, no Lua math. */
    fun modeRows(snapshot: Map<String, Any?>, limit: Int = 3): Map<String, Any?> {
        val ids = mapOf("battery-saver" to "saver", "balanced" to "balanced", "always-up-to-date" to "current")
        val modes = (snapshot["modes"] as? List<*>).orEmpty().mapNotNull { it as? Map<*, *> }
        val rows = modes.take(limit.coerceIn(1,3)).map { mode ->
            val hours = (mode["hours_usual_use"] as? Number)?.toDouble()
            val estimated = mode["estimated"] == true
            val duration = hours?.let {
                val whole = it.toLong()
                when {
                    it < 1 -> "${(it*60).toInt()} min"
                    whole < 24 -> "$whole h"
                    else -> "${whole/24} d ${whole%24} h"
                }
            }
            val text = if (duration == null) "Estimate available after measured use" else
                "≈ $duration at your usual use" + if (estimated) " (estimate: Wi-Fi pattern not measured yet)" else ""
            mapOf("id" to ids[mode["id"]], "text" to LuaValue.str(text), "hours_usual_use" to hours,
                "measured" to (hours != null && !estimated), "estimated" to estimated, "reason" to mode["reason"])
        }
        return mapOf("items" to rows, "freshness" to snapshot["freshness"])
    }

    /** Observed charge sessions, newest first. No extrapolation across service/clock gaps. */
    fun charges(segments: List<Segment>, last: Snap?): List<Map<String, Any?>> {
        // Merge contiguous charging segments split by a radio/settings change; never bridge gaps.
        val charges = mutableListOf<Map<String, Any?>>()
        var start: Segment? = null
        var end: Segment? = null
        fun finish() {
            val a = start ?: return
            val b = end!!
            if (a.startPct >= 0 && b.endPct >= a.startPct && b.end > a.start)
                charges += mapOf("start" to a.start, "end" to b.end, "from_pct" to a.startPct,
                    "to_pct" to b.endPct, "hours" to (b.end-a.start)/3_600_000.0,
                    "ongoing" to (last?.charging == true && b.end == segments.lastOrNull()?.end))
            start = null; end = null
        }
        for (s in segments) {
            if (s.key.state != PowerState.CHARGING || (end != null && end!!.end != s.start)) finish()
            if (s.key.state == PowerState.CHARGING) { if (start == null) start = s; end = s }
        }
        finish()
        return charges.takeLast(5).reversed()
    }

    /** Keep five sessions across pruning, including a raw suffix of an already archived charge. */
    fun retainCharges(saved: List<Map<String, Any?>>, recent: List<Map<String, Any?>>): List<Map<String, Any?>> {
        fun number(row: Map<String,Any?>, field: String) = (row[field] as? Number)?.toLong()
        fun identity(row: Map<String,Any?>): Pair<Long,Int>? {
            val start = number(row,"start") ?: return null
            val from = number(row,"from_pct") ?: return null
            return start to from.toInt()
        }
        val retained = linkedMapOf<Pair<Long,Int>, Map<String,Any?>>()
        val observed = mutableSetOf<Pair<Long,Int>>()
        for (row in saved.asReversed()) identity(row)?.let { retained[it] = row }
        for (row in recent.asReversed()) {
            val rawKey = identity(row) ?: continue
            val end = number(row,"end")
            val previous = if (rawKey in retained) null else retained.entries.firstOrNull { (key, old) ->
                val oldEnd = number(old,"end")
                val oldTo = number(old,"to_pct")
                val from = rawKey.second.toLong()
                key.first < rawKey.first && oldEnd != null && end != null && rawKey.first <= oldEnd &&
                    from >= key.second && ((end == oldEnd && number(row,"to_pct") == oldTo) ||
                    (old["ongoing"] == true && end >= oldEnd && oldTo != null && from <= oldTo))
            }
            val key = previous?.key ?: rawKey
            val value = if (previous == null) row else row + mapOf(
                "start" to key.first, "from_pct" to previous.value["from_pct"],
                "hours" to (number(row,"end")!!-key.first)/3_600_000.0,
                "ongoing" to (previous.value["ongoing"] == true && row["ongoing"] == true))
            retained.remove(key)
            retained[key] = value
            observed += key
        }
        return retained.entries.toList().takeLast(5).reversed().map { (key,row) ->
            if (key in observed) row else row + ("ongoing" to false)
        }
    }

    fun snapshot(totals: Map<String, Sums>, days: List<DayTotals>, last: Snap?, segments: List<Segment>,
                 now: Long, zone: ZoneId, usualDays: List<DayTotals>? = null,
                 recentCharges: List<Map<String, Any?>>? = null): Map<String, Any?> {
        fun sums(vararg cats: String): Sums? = cats.mapNotNull { totals[it] }.reduceOrNull { a, b -> a+b }
        fun on(pattern: String? = null): Rate? {
            // Historical screen-on includes both a foreground book and other interactive time.
            val suffix = pattern?.let { "|wifi_mode=$it" }.orEmpty()
            return BatteryStats.rate("screen-on", sums("reading$suffix", "awake$suffix"))
        }
        fun standby(pattern: String? = null) = ("standby" + pattern?.let { "|wifi_mode=$it" }.orEmpty()).let { BatteryStats.rate(it, totals[it]) }
        fun rate(r: Rate?): Map<String, Any?> = mapOf("pct_per_hour" to r?.takeIf { it.shown }?.pctPerH,
            "standard_error" to r?.takeIf { it.shown }?.se, "hours_measured" to (r?.hours ?: 0.0),
            "missing" to (r?.missing ?: if (r == null) "No measurements yet" else null))
        val today = BatteryStats.day(now, zone)
        val recent = usualDays ?: days.filter { it.day in (today-6)..today }
        val share = BatteryStats.onShare(recent)
        val level = last?.level?.takeIf { it in 0..100 && last.t <= now }
        val screenOn = on()
        val asleep = standby()
        val usual = BatteryStats.hoursLeft(level ?: -1, share, screenOn, asleep)
        val modes = listOf("battery-saver" to "jit", "balanced" to "jit", "always-up-to-date" to "always_on").map { (id, pattern) ->
            val measuredOn = on(pattern)?.takeIf { it.shown }
            val measuredOff = standby(pattern)?.takeIf { it.shown }
            val estimated = measuredOn == null || measuredOff == null
            mapOf("id" to id, "wifi_pattern" to pattern, "estimated" to estimated,
                "reason" to if (estimated) "Wi-Fi pattern not measured; pooled rates used" else null,
                "hours_usual_use" to BatteryStats.hoursLeft(level ?: -1, share, measuredOn ?: screenOn, measuredOff ?: asleep))
        }
        return mapOf("level" to level, "charging" to last?.charging, "screen_on" to rate(screenOn),
            "standby" to rate(asleep), "charging_rate" to rate(BatteryStats.rate("charging", totals["charging"])),
            "usual_use" to mapOf("screen_on_percent" to share?.times(100), "window_days" to 7,
                "hours_observed" to recent.sumOf { it.screenMin+it.standbyMin }/60,
                "missing" to if (share == null) "Needs 24 h of observed use" else null),
            "hours_usual_use" to usual, "hours_reading_nonstop" to BatteryStats.hoursLeftAt(level ?: -1, screenOn),
            "hours_standby_only" to BatteryStats.hoursLeftAt(level ?: -1, asleep),
            "pct_used_per_day" to days.filter { it.day in (today-13)..today }.sortedBy { it.day }.map {
                mapOf("day" to it.day, "used_pct" to it.usedPct, "screen_on_minutes" to it.screenMin, "charges" to it.charges)
            }, "recent_charges" to (recentCharges ?: charges(segments,last)).take(5), "modes" to modes,
            "freshness" to mapOf("saved" to (last != null), "origin" to "local-device", "at" to last?.t))
    }
}
