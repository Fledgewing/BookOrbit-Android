package net.fledgewing.orbitcompanion

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Private adapter normalization. No backend JSON or account profile reaches the UI. */
object AccountStats {
    private fun count(v: Any?): Long? = (v as? Number)?.toDouble()?.takeIf { it.isFinite() && it >= 0 && it <= Int.MAX_VALUE && it % 1.0 == 0.0 }?.toLong()
    fun zone(account: Map<*, *>?): ZoneId = runCatching {
        ZoneId.of(((account?.get("goal") as? Map<*, *>)?.get("timezone") as? String) ?: ZoneId.systemDefault().id)
    }.getOrDefault(ZoneId.systemDefault())

    /** Account fields win independently; absent/forbidden fields retain connector fallback.
     * Account routes expose no local upload watermark, so today's local minutes stay separate. */
    fun combine(local: Map<String, Any?>, connector: RemoteReadingStats?, account: Map<*, *>?, now: Long): Map<String, Any?> {
        if (account == null) return ReadingStats.combine(local, connector, now)
        val zone = zone(account)
        val today = Instant.ofEpochSecond(now).atZone(zone).toLocalDate()
        val days = (account["days"] as? Map<*, *>)?.entries?.associate { LocalDate.parse(it.key as String) to (it.value as Number).toLong() }
        val goal = account["goal"] as? Map<*, *>
        val remote = RemoteReadingStats(days = days ?: connector?.days,
            streak = connector?.streak, bestStreak = connector?.bestStreak,
            target = if (goal != null) count(goal["target"]) else connector?.target,
            goalAvailable = goal != null || connector?.goalAvailable == true,
            finished = count(account["finished"]) ?: connector?.finished,
            year = if (goal != null || account["finished"] != null) today.year.toLong() else connector?.year,
            at = (account["at"] as? Number)?.toLong()?.let { Instant.ofEpochSecond(it).toString() } ?: connector?.at,
            includedThrough = if (days != null) null else connector?.includedThrough)
        val result = ReadingStats.combine(local, remote, now, zone).toMutableMap()
        val sources = (result["sources"] as Map<*, *>).entries.associate { it.key.toString() to it.value }.toMutableMap()
        val capabilities = (result["capabilities"] as Map<*, *>).entries.associate { it.key.toString() to it.value }.toMutableMap()
        val hours = (account["hours"] as? List<*>)?.map { (it as Number).toLong() }
        if (hours != null) {
            val max = hours.maxOrNull() ?: 0L
            val total = hours.sum()
            result["hours"] = hours; result["hour_levels"] = hours.map { it.toDouble() / maxOf(1, max) }
            result["hour_intensity"] = hours.map { v -> when { v == 0L -> 0; v * 4 < max -> 1; v * 2 < max -> 2; v * 5 < max * 4 -> 3; else -> 4 } }
            result["peak_hour"] = if (max > 0) hours.indexOf(max) else null
            result["after_18_percent"] = if (total > 0) hours.drop(18).sum() * 100 / total else 0
            result["hours_available"] = true
            for (key in listOf("hours", "peak_hour", "after_18_percent")) sources[key] = "all your devices"
        }
        val sessions = account["sessions"] as? Map<*, *>
        if (sessions != null) {
            result["sessions"] = sessions
            val records = (result["records"] as? Map<*, *>).orEmpty().entries.associate { it.key.toString() to it.value }.toMutableMap()
            records["longest_session_seconds"] = sessions["longest_seconds"]
            records["longest_session_period"] = "week"
            result["records"] = records
            sources["longest_session_seconds"] = "all your devices"
        }
        capabilities["hours"] = hours != null; capabilities["sessions"] = sessions != null
        capabilities["yearReview"] = false; capabilities["activityDetails"] = false; capabilities["celebrations"] = false
        result["freshness"] = mapOf("saved" to true, "origin" to "cached-remote", "at" to account["at"], "stale" to (account["stale"] == true))
        result["sources"] = sources; result["capabilities"] = capabilities
        result["providers"] = mapOf("days" to if (days != null) "account" else "connector",
            "hours" to if (hours != null) "account" else "local", "sessions" to if (sessions != null) "account" else "local",
            "finished" to if (account["finished"] != null) "account" else "connector", "goal" to if (goal != null) "account" else "connector")
        if (hours != null || sessions != null) result["state"] = "ready"
        return result
    }

}
