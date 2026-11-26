package net.fledgewing.orbitcompanion.server.bookorbit

import java.time.LocalDate

internal object AccountStatsProjection {
    private fun count(v: Any?): Long? = (v as? Number)?.toDouble()?.takeIf { it.isFinite() && it >= 0 && it <= Int.MAX_VALUE && it % 1.0 == 0.0 }?.toLong()
    fun normalize(feature: String, raw: Any?, today: LocalDate): Any? { return when (feature) {
        "days" -> (raw as? List<*>)?.takeIf { it.size <= 366 }?.let { rows ->
            val result = linkedMapOf<String, Long>()
            for (value in rows) {
                val row = value as? Map<*, *> ?: return null
                val day = runCatching { LocalDate.parse(row["day"] as? String) }.getOrNull() ?: return null
                val seconds = count(row["readingSeconds"]) ?: return null
                if (day in today.minusDays(364)..today) result[day.toString()] = seconds
            }
            result
        }
        "hours" -> (raw as? List<*>)?.takeIf { it.size == 24 }?.let { rows ->
            val result = LongArray(24); val seen = mutableSetOf<Long>()
            for (value in rows) {
                val row = value as? Map<*, *> ?: return null
                val hour = count(row["hour"])?.takeIf { it in 0..23 && seen.add(it) } ?: return null
                result[hour.toInt()] = count(row["readingSeconds"]) ?: return null
            }
            result.toList()
        }
        "sessions" -> (raw as? Map<*, *>)?.let { data ->
            val rows = data["items"] as? List<*> ?: return null
            if (rows.size > 3000) return null
            var longest = 0L
            val seen = mutableSetOf<Long>()
            for (value in rows) {
                val row = value as? Map<*, *> ?: return null
                val id = count(row["sessionId"]) ?: return null
                if (!seen.add(id)) continue
                longest = maxOf(longest, count(row["durationSeconds"]) ?: return null)
            }
            mapOf("count" to seen.size, "longest_seconds" to longest, "period" to "week", "complete" to (rows.size < 3000))
        }
        "finished" -> (raw as? List<*>)?.takeIf { it.size <= 14 }?.let { rows ->
            var total = 0L
            for (value in rows) {
                val row = value as? Map<*, *> ?: return null
                if (count(row["year"]) == today.year.toLong()) total += count(row["count"]) ?: return null
            }
            total
        }
        "goal" -> (raw as? Map<*, *>)?.let { user ->
            val settings = user["settings"] as? Map<*, *>
            val dashboard = settings?.get("dashboardConfig") as? Map<*, *>
            val goal = dashboard?.get("readingGoal")
            // Missing stored goal is explicitly absent, never the trajectory endpoint's default.
            mapOf("target" to count(goal), "year" to today.year, "timezone" to (settings?.get("timezone") as? String)?.take(100))
        }
        else -> null
    } }
}
