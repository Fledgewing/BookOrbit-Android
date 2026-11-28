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
    /** Measured fractional-page pace survives layout changes (page_stat_data.total_pages).
     * Five sane visits are required; missing identity/locator/pace never becomes a guess. */
    fun forecast(db: Sql, md5: String, fraction: Double?, now: Long, dailySeconds: Long,
                 zone: ZoneId = ZoneId.systemDefault()): Map<String, Any?> {
        if (fraction == null || !fraction.isFinite() || fraction !in 0.0..1.0) return emptyMap()
        if (fraction == 1.0) return mapOf("time_left" to "Finished", "finish_forecast" to "Finished")
        val pace = db.query("""SELECT COUNT(*),SUM(p.duration),SUM(1.0/p.total_pages)
            FROM page_stat_data p JOIN book b ON b.id=p.id_book
            WHERE b.md5=? AND p.total_pages>0 AND p.page BETWEEN 1 AND p.total_pages
            AND p.duration BETWEEN 1 AND 600 AND p.start_time>0 AND p.start_time<?""", md5, now) {
            Triple(it.long(0) ?: 0, it.long(1) ?: 0, it.text(2)?.toDoubleOrNull() ?: 0.0)
        }.single()
        if (pace.first < 5 || pace.third <= 0) return emptyMap()
        val estimate = (1-fraction)*pace.second/pace.third
        if (!estimate.isFinite() || estimate !in 0.0..3153600000.0) return emptyMap()
        val remaining = kotlin.math.ceil(estimate).toLong()
        val minutes = (remaining+59)/60
        val duration = if (minutes>=60) "${minutes/60} h ${minutes%60} m left" else "$minutes m left"
        val days = if (dailySeconds>0) kotlin.math.ceil(remaining.toDouble()/dailySeconds).toLong() else null
        val date = days?.takeIf { it<=36500 }?.let { Instant.ofEpochSecond(now).atZone(zone).toLocalDate().plusDays(it) }
        return mapOf("time_left" to LuaValue.str(duration), "finish_forecast" to date?.let {
            LuaValue.str("Done by " + it.format(java.time.format.DateTimeFormatter.ofPattern("EEE d MMM"))) },
            "forecast_source" to "this reader")
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
            "week" to mapOf("start" to monday.toString(), "seconds" to week, "total_seconds" to week.sum(), "previous_seconds" to (1L..7L).sumOf { daily[monday.minusDays(it)] ?: 0 }, "levels" to week.map { it.toDouble() / maxOf(1, week.maxOrNull() ?: 0) }),
            "hours" to hours.toList(), "hour_levels" to hours.map { it.toDouble() / maxOf(1, hours.maxOrNull() ?: 0) },
            "hour_intensity" to hours.map { v -> when { v == 0L -> 0; v * 4 < (hours.maxOrNull() ?: 0) -> 1; v * 2 < (hours.maxOrNull() ?: 0) -> 2; v * 5 < (hours.maxOrNull() ?: 0) * 4 -> 3; else -> 4 } }, "peak_hour" to peak,
            "after_18_percent" to if (total > 0) (hours.drop(18).sum() * 100 / total).toInt() else null,
            "records" to mapOf("recorded_pages" to visits,"today_pages" to (pages[today] ?: 0L), "longest_session_seconds" to longest,
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
                out["week"] = mapOf("start" to monday.toString(), "seconds" to week, "total_seconds" to week.sum(), "previous_seconds" to (1L..7L).sumOf { days[monday.minusDays(it)] ?: 0 },
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
    /** Display labels are projected after per-field precedence, never on the UI thread. */
    fun display(data: Map<String, Any?>, now: Long, zone: ZoneId = ZoneId.systemDefault()): Map<String, Any?> {
        val today = Instant.ofEpochSecond(now).atZone(zone).toLocalDate()
        fun duration(value: Any?): String {
            val minutes = ((value as? Number)?.toLong() ?: 0) / 60
            return if (minutes >= 60) "${minutes / 60} h ${minutes % 60} m" else "$minutes m"
        }
        val week = data["week"] as? Map<*, *>
        val seconds = (week?.get("seconds") as? List<*>)?.map { (it as Number).toLong() }
        val best = seconds?.maxOrNull()?.takeIf { it > 0 }?.let { seconds.indexOf(it) }
        val previous = (week?.get("previous_seconds") as? Number)?.toLong()?.takeIf { it > 0 }
        val total = (week?.get("total_seconds") as? Number)?.toLong()
        val comparison = if (previous != null && total != null) {
            val percent = kotlin.math.round((total.toDouble() / previous - 1) * 100).toInt()
            "${if (percent >= 0) "+" else ""}$percent% on last week"
        } else null
        val year = data["year"] as? Map<*, *>
        val start = (year?.get("start") as? String)?.let { LocalDate.parse(it) }
        val months = if (start == null) emptyList() else (0L..364L).mapNotNull { offset ->
            val day = start.plusDays(offset)
            if ((offset == 0L && day.dayOfMonth <= 15) || day.dayOfMonth == 1) mapOf("day" to offset.toInt(), "label" to LuaValue.str(day.format(java.time.format.DateTimeFormatter.ofPattern("MMM")))) else null
        }
        val records = data["records"] as? Map<*, *>
        val peak = (data["peak_hour"] as? Number)?.toInt()
        val period = peak?.let { when (it) { in 0..5 -> "Nights"; in 6..11 -> "Mornings"; in 12..17 -> "Afternoons"; else -> "Evenings" } }
        return data + ("display" to mapOf(
            "week_total" to duration(week?.get("total_seconds")), "week_comparison" to comparison, "today_index" to today.dayOfWeek.value,
            "best_index" to best?.plus(1), "best_duration" to best?.let { duration(seconds!![it]) },
            "best_day" to best?.let { LuaValue.str(java.time.DayOfWeek.of(it+1).getDisplayName(java.time.format.TextStyle.FULL, java.util.Locale.getDefault())) },
            "months" to months, "period" to period, "peak" to peak?.let { "$it:00" },
            "record_day" to (records?.get("best_day") as? String)?.let { LuaValue.str(LocalDate.parse(it).format(java.time.format.DateTimeFormatter.ofPattern("d MMM"))) },
            "pages" to (records?.get("recorded_pages") as? Number)?.let { LuaValue.str(java.text.NumberFormat.getIntegerInstance().format(it)) },
            "longest" to records?.get("longest_session_seconds")?.let { duration(it) },
            "local_today" to data["local_today_seconds"]?.let { LuaValue.str("${duration(it)} today · this reader (separate)") }
        ))
    }
    private fun intensity(values: List<Long>): List<Int> {
        val max = values.maxOrNull() ?: 0
        return values.map { v -> when { v == 0L -> 0; v * 4 < max -> 1; v * 2 < max -> 2; v * 5 < max * 4 -> 3; else -> 4 } }
    }
}
