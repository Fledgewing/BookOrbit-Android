package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

class AccountStatsTest {
    private val today = LocalDate.parse("2026-11-25")
    private val now = Instant.parse("2026-11-25T12:00:00Z").epochSecond
    private val local = mapOf<String, Any?>("state" to "ready", "hours" to List(24) { 1L },
        "records" to mapOf("recorded_pages" to 3, "longest_session_seconds" to 60, "streak" to 1, "best_streak" to 1),
        "goal" to mapOf("today_seconds" to 100L), "pending_today_seconds" to 20L, "pending_included_through" to 5L)
    @Test fun accountFieldsWinIndependentlyAndLocalTodayIsNeverDoubleCounted() {
        val connector = RemoteReadingStats(days = mapOf(today to 200L), target = 10, goalAvailable = true, finished = 2,
            streak = 3, bestStreak = 9, includedThrough = 5)
        val account = mapOf("days" to mapOf(today.toString() to 400L), "hours" to List(24) { if (it == 19) 500L else 0L },
            "finished" to 4L, "goal" to mapOf("target" to 12L, "timezone" to "UTC"),
            "sessions" to mapOf("count" to 4, "longest_seconds" to 900, "period" to "week", "complete" to true), "at" to now)
        val result = AccountStats.combine(local, connector, account, now)
        assertEquals(400L, (result["goal"] as Map<*, *>)["today_seconds"])
        assertEquals(12L, (result["goal"] as Map<*, *>)["target"])
        assertEquals(4L, (result["records"] as Map<*, *>)["books_this_year"])
        assertEquals(3L, (result["records"] as Map<*, *>)["streak"])
        assertEquals(900, (result["records"] as Map<*, *>)["longest_session_seconds"])
        assertEquals("week", (result["records"] as Map<*, *>)["longest_session_period"])
        assertEquals(19, result["peak_hour"])
        assertEquals(100L, result["local_today_seconds"])
        assertEquals("separate", result["today_merge"])
        assertTrue("one bounded stats row", LuaValue.encode(result).size <= 16384)
        assertEquals("account", (result["providers"] as Map<*, *>)["days"])
        assertEquals(false, (result["capabilities"] as Map<*, *>)["yearReview"])
        val fallback = AccountStats.combine(local, connector, emptyMap<Any,Any>(), now)
        assertEquals(220L, (fallback["goal"] as Map<*, *>)["today_seconds"])
        assertEquals(10L, (fallback["goal"] as Map<*, *>)["target"])
        assertEquals("connector", (fallback["providers"] as Map<*, *>)["days"])
    }
    @Test fun normalizationIsBoundedAndOmitsProfileAndBackendObjects() {
        val days = AccountStats.normalize("days", listOf(mapOf("day" to today.toString(), "readingSeconds" to 60)), today) as Map<*, *>
        assertEquals(60L, days[today.toString()])
        assertNull(AccountStats.normalize("days", List(367) { mapOf("day" to today.toString(), "readingSeconds" to 60) }, today))
        assertNull(AccountStats.normalize("hours", List(24) { mapOf("hour" to 2, "readingSeconds" to 10) }, today))
        assertNull(AccountStats.normalize("days", listOf(mapOf("day" to "bad", "readingSeconds" to -1)), today))
        val profile = AccountStats.normalize("goal", mapOf("email" to "private", "settings" to mapOf("timezone" to "UTC", "dashboardConfig" to emptyMap<Any,Any>())), today) as Map<*, *>
        assertNull(profile["target"]); assertFalse(profile.toString().contains("private"))
        val completion = AccountStats.normalize("finished", listOf(mapOf("year" to 2025, "count" to 99), mapOf("year" to 2026, "count" to 4)), today)
        assertEquals(4L, completion)
    }
    @Test fun sessionIdentityIsDeduplicatedAndThePeriodIsExplicit() {
        val session = mapOf("sessionId" to 9, "durationSeconds" to 500)
        val result = AccountStats.normalize("sessions", mapOf("items" to listOf(session,session)), today) as Map<*, *>
        assertEquals(1, result["count"]); assertEquals("week", result["period"])
        assertNull(AccountStats.normalize("sessions", mapOf("items" to List(3001) { session }), today))
    }
}
