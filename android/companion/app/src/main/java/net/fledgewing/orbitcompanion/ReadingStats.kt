package net.fledgewing.orbitcompanion

import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Adapter-owned normalized fields. An inclusion watermark is optional and must prove
 * that all local events through this inclusive start time are in this exact snapshot. */
data class RemoteReadingStats(
    val days: Map<LocalDate, Long>? = null,
    val streak: Long? = null, val bestStreak: Long? = null,
    val target: Long? = null, val goalAvailable: Boolean = false,
    val finished: Long? = null, val year: Long? = null, val at: String? = null,
    val includedThrough: Long? = null,
) {
    fun capabilities() = mapOf("days" to (days != null), "streak" to (streak != null),
        "goal" to goalAvailable, "finished" to (finished != null))
}

/** Local KOReader statistics adapter. Never writes the borrowed database or infers completions
 * from page coverage. Work is on Worker's queue; only the small result enters library_views. */
object ReadingStats {
    fun read(file: File, now: Long, zone: ZoneId = ZoneId.systemDefault(), includedThrough: Long? = null): Map<String, Any?> {
        if (!file.isFile) return unavailable("not-saved")
        return runCatching {
            AndroidSql(file, readOnly = true).use { db -> aggregate(db, now, zone, includedThrough) }
        }.getOrElse { if (it is InterruptedException) throw it; unavailable("error") }
    }
    private fun unavailable(state: String) = mapOf<String, Any?>("state" to state, "freshness" to mapOf("saved" to false, "origin" to "local-reader"))

    /** Keyset chunks bound cursor memory. Dates/hours use the device zone, including DST.
     * A recorded page is one timed KOReader page visit, not a unique page or physical turn.
     * Sessions join timed visits separated by at most five minutes, excluding the gap. */
    fun aggregate(db: Sql, now: Long, zone: ZoneId, includedThrough: Long? = null): Map<String, Any?> = db.transaction {
        val today = Instant.ofEpochSecond(now).atZone(zone).toLocalDate()
        val first = today.minusDays(364)
        val monday = today.minusDays((today.dayOfWeek.value - 1).toLong())
        val daily = sortedMapOf<LocalDate, Long>()
        val pages = mutableMapOf<LocalDate, Long>()
        val hours = LongArray(24)
        var lastTime = -1L
        var lastRow = 0L
        var visits = 0L
        var sessionEnd = 0L
        var sessionSeconds = 0L
        var longest = 0L
        var pendingToday = 0L
        var pendingEnd = 0L
        while (true) {
            BulkWork.checkpoint()
            val rows = db.query("SELECT rowid,start_time,duration FROM page_stat_data WHERE (start_time>? OR (start_time=? AND rowid>?)) ORDER BY start_time,rowid LIMIT 256", lastTime, lastTime, lastRow) {
                Triple(it.long(0)!!, it.long(1) ?: 0, it.long(2) ?: 0)
            }
            if (rows.isEmpty()) break
            for ((_, start, duration) in rows) {
                if (start <= 0 || start >= now || duration <= 0) continue
                val end = minOf(now, start + duration.coerceAtMost(86400))
                if (start > sessionEnd + 300) sessionSeconds = 0
                sessionSeconds += (end - maxOf(start, sessionEnd)).coerceAtLeast(0)
                sessionEnd = maxOf(sessionEnd, end)
                longest = maxOf(longest, sessionSeconds)
                visits++
                val day = Instant.ofEpochSecond(start).atZone(zone).toLocalDate()
                pages[day] = (pages[day] ?: 0) + 1
                var t = start
                while (t < end) {
                    val z = Instant.ofEpochSecond(t).atZone(zone)
                    val boundary = z.withMinute(0).withSecond(0).withNano(0).plusHours(1).toEpochSecond()
                    val stop = minOf(end, boundary)
                    daily[z.toLocalDate()] = (daily[z.toLocalDate()] ?: 0) + stop - t
                    if (includedThrough != null && start > includedThrough && z.toLocalDate() == today) {
                        pendingToday += (stop - maxOf(t, pendingEnd)).coerceAtLeast(0)
                        pendingEnd = maxOf(pendingEnd, stop)
                    }
                    if (!z.toLocalDate().isBefore(first)) hours[z.hour] += stop - t
                    t = stop
                }
            }
            lastRow = rows.last().first; lastTime = rows.last().second
        }
        val seconds = (0L..364L).map { daily[first.plusDays(it)] ?: 0 }
        val max = seconds.maxOrNull() ?: 0
        val intensity = seconds.map { v -> when { v == 0L -> 0; v * 4 < max -> 1; v * 2 < max -> 2; v * 5 < max * 4 -> 3; else -> 4 } }
        val week = (0L..6L).map { daily[monday.plusDays(it)] ?: 0 }
        var run = 0; var best = 0; var previous: LocalDate? = null
        for (day in daily.keys) {
            run = if (previous?.plusDays(1) == day) run + 1 else 1
            best = maxOf(best, run); previous = day
        }
        var streak = 0
        var cursor = if ((daily[today] ?: 0) > 0) today else today.minusDays(1)
        while ((daily[cursor] ?: 0) > 0) { streak++; cursor = cursor.minusDays(1) }
        val peak = hours.maxOrNull()?.takeIf { it > 0 }?.let { hours.indexOf(it) }
        val total = hours.sum()
        val bestDay = pages.maxByOrNull { it.value }
        mapOf("state" to if (visits == 0L) "empty" else "ready", "source" to "koreader-statistics",
            "freshness" to mapOf("saved" to true, "origin" to "local-reader", "at" to now),
            "pending_today_seconds" to pendingToday.takeIf { includedThrough != null },
            "pending_included_through" to includedThrough,
            "year" to mapOf("start" to first.toString(), "weekday" to first.dayOfWeek.value - 1, "seconds" to seconds, "intensity" to intensity, "days_read" to seconds.count { it > 0 }),
            "week" to mapOf("start" to monday.toString(), "seconds" to week, "total_seconds" to week.sum(), "levels" to week.map { it.toDouble() / maxOf(1, week.maxOrNull() ?: 0) }),
            "hours" to hours.toList(), "hour_levels" to hours.map { it.toDouble() / maxOf(1, hours.maxOrNull() ?: 0) },
            "hour_intensity" to hours.map { v -> when { v == 0L -> 0; v * 4 < (hours.maxOrNull() ?: 0) -> 1; v * 2 < (hours.maxOrNull() ?: 0) -> 2; v * 5 < (hours.maxOrNull() ?: 0) * 4 -> 3; else -> 4 } }, "peak_hour" to peak,
            "after_18_percent" to if (total > 0) (hours.drop(18).sum() * 100 / total).toInt() else null,
            "records" to mapOf("recorded_pages" to visits, "longest_session_seconds" to longest,
                "best_day_pages" to (bestDay?.value ?: 0), "best_day" to bestDay?.key?.toString(), "books_this_year" to null,
                "streak" to streak, "best_streak" to best),
            "goal" to mapOf("today_seconds" to (daily[today] ?: 0), "week_seconds" to week.sum(),
                "books_this_year" to null, "target" to null, "completion_available" to false))
    }

    /** Per-field precedence; never infer overlap from fetch time or max(local, server). */
    fun combine(local: Map<String, Any?>, remote: RemoteReadingStats?, now: Long,
                zone: ZoneId = ZoneId.systemDefault(), enabled: Set<String> = setOf("days", "streak", "goal", "finished")): Map<String, Any?> {
        val today = Instant.ofEpochSecond(now).atZone(zone).toLocalDate()
        val out = local.toMutableMap()
        fun localMap(key: String) = (local[key] as? Map<*, *>).orEmpty().entries.associate { it.key.toString() to it.value }.toMutableMap()
        val records = localMap("records")
        val goal = localMap("goal")
        val sources = mutableMapOf<String, String>()
        for (field in listOf("days", "streak", "goal", "finished", "hours", "peak_hour", "records", "today")) sources[field] = "this reader"
        if (remote != null) {
            if ("days" in enabled && remote.days != null) {
                val days = remote.days.toMutableMap()
                val watermark = remote.includedThrough
                val pending = (local["pending_today_seconds"] as? Number)?.toLong()
                val reconciled = watermark != null && watermark <= now &&
                    (local["pending_included_through"] as? Number)?.toLong() == watermark && pending != null
                if (reconciled) days[today] = (days[today] ?: 0) + pending!!
                else out["local_today_seconds"] = goal["today_seconds"] // separate, possibly overlapping
                out["today_merge"] = if (reconciled) "watermarked" else "separate"
                val first = today.minusDays(364)
                val seconds = (0L..364L).map { days[first.plusDays(it)] ?: 0L }
                val monday = today.minusDays((today.dayOfWeek.value - 1).toLong())
                val week = (0L..6L).map { days[monday.plusDays(it)] ?: 0L }
                out["year"] = mapOf("start" to first.toString(), "weekday" to first.dayOfWeek.value - 1,
                    "seconds" to seconds, "intensity" to intensity(seconds), "days_read" to seconds.count { it > 0 })
                out["week"] = mapOf("start" to monday.toString(), "seconds" to week, "total_seconds" to week.sum(),
                    "levels" to week.map { it.toDouble() / maxOf(1, week.maxOrNull() ?: 0) })
                goal["today_seconds"] = days[today] ?: 0L; goal["week_seconds"] = week.sum()
                sources["days"] = "all your devices"; sources["today"] = "all your devices"
            }
            if ("streak" in enabled && remote.streak != null) {
                records["streak"] = remote.streak; records["best_streak"] = remote.bestStreak
                sources["streak"] = "all your devices"
            }
            if ("goal" in enabled && remote.goalAvailable) {
                goal["target"] = remote.target; goal["year"] = remote.year
                sources["goal"] = "all your devices"
            }
            if ("finished" in enabled && remote.finished != null) {
                records["books_this_year"] = remote.finished; goal["books_this_year"] = remote.finished
                goal["completion_available"] = true; sources["finished"] = "all your devices"
            }
            if (sources.values.any { it == "all your devices" }) {
                out["state"] = "ready"
                out["freshness"] = mapOf("saved" to true, "origin" to "cached-remote", "at" to remote.at)
            }
        }
        // Server-only accounts still get bounded, explicitly absent local fields.
        out["hours_available"] = local["hours"] != null
        out["records_available"] = local["records"] != null
        for ((field, group) in mapOf("year" to "days", "week" to "days", "peak_hour" to "hours",
            "after_18_percent" to "hours", "recorded_pages" to "records", "longest_session_seconds" to "records",
            "best_day_pages" to "records", "best_day" to "records", "best_streak" to "streak",
            "target" to "goal", "books_this_year" to "finished", "today_seconds" to "today", "week_seconds" to "days")) {
            sources[field] = sources.getValue(group)
        }
        out["sources"] = sources; out["records"] = records; out["goal"] = goal
        out["capabilities"] = (remote?.capabilities() ?: RemoteReadingStats().capabilities()).mapValues { (k, v) -> v && k in enabled }
        return out
    }
    private fun intensity(values: List<Long>): List<Int> {
        val max = values.maxOrNull() ?: 0
        return values.map { v -> when { v == 0L -> 0; v * 4 < max -> 1; v * 2 < max -> 2; v * 5 < max * 4 -> 3; else -> 4 } }
    }
}
