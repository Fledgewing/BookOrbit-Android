package net.fledgewing.orbitcompanion

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** One device-local row; the host owns refresh and the existing battery page action. */
object ClockWidget {
    fun snapshot(now: Long, power: Map<String, Any?>, zone: ZoneId = ZoneId.systemDefault(), twelve: Boolean = false): Map<String, Any?> {
        if (now <= 0) return mapOf("state" to "not-saved")
        val time = Instant.ofEpochSecond(now).atZone(zone)
        val monday = time.toLocalDate().minusDays((time.dayOfWeek.value-1).toLong())
        val level = (power["level"] as? Number)?.toInt()?.takeIf { it in 0..100 }
        return mapOf("state" to "ready", "freshness" to mapOf("saved" to true),
            "time" to LuaValue.str(time.format(DateTimeFormatter.ofPattern(if (twelve) "h:mm a" else "HH:mm"))),
            "weekday" to LuaValue.str(time.format(DateTimeFormatter.ofPattern("EEEE"))),
            "date" to LuaValue.str(time.format(DateTimeFormatter.ofPattern("d MMMM"))),
            "days" to (0L..6L).map { val day = monday.plusDays(it)
                mapOf("label" to LuaValue.str(day.format(DateTimeFormatter.ofPattern("EEEEE"))), "date" to day.dayOfMonth.toString(), "today" to (day == time.toLocalDate())) },
            "battery" to LuaValue.str(level?.let { "▭ $it% ›" } ?: "Battery ›"))
    }
}
