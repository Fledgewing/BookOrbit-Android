// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import kotlin.math.floor

/** The dashboard's 364-day calendar and merge run on the companion worker. */
object BoardYear {
    fun build(now: Long, year: Map<*, *>?, daily: Map<String, Long> = emptyMap()): Map<String, Any> {
        val day = 86400L
        val today = Calendar.getInstance().apply {
            timeInMillis = now * 1000; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        val midnight = today.timeInMillis / 1000
        val start = midnight + (7 - today.get(Calendar.DAY_OF_WEEK)) * day - 363 * day
        val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.ROOT)
        val server = HashMap<String, Double>()
        val first = (year?.get("startDate") as? String)?.let { runCatching { fmt.parse(it) }.getOrNull() }
        if (first != null) {
            val c = Calendar.getInstance().apply { time = first; set(Calendar.HOUR_OF_DAY, 12) }
            (year["minutes"] as? List<*>)?.forEachIndexed { i, value ->
                server[fmt.format(java.util.Date(c.timeInMillis + i * day * 1000))] = (value as? Number)?.toDouble() ?: 0.0
            }
        }
        val values = ArrayList<Long>()
        for (i in 0 until 364) {
            val t = start + i * day + 43200
            if (t > midnight + day) break
            val key = fmt.format(java.util.Date(t * 1000))
            values.add(floor(maxOf((daily[key] ?: 0L) / 60.0, server[key] ?: 0.0) + 0.5).toLong())
        }
        return sortedMapOf("values" to values, "start" to start + 43200, "today" to midnight)
    }
}
