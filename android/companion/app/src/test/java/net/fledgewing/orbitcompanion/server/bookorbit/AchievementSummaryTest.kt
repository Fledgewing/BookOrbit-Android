// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit
import net.fledgewing.orbitcompanion.*
import org.junit.Assert.*
import org.junit.Test
import java.time.ZoneId
class AchievementSummaryTest {
    private fun normalize(a:Any?)=AchievementSummary.normalize(mapOf("achievements" to a),ZoneId.of("UTC"))
    private fun text(r:Map<String,Any?>,key:String)=LuaValue.utf8(r[key].toString())
    @Test fun missingUnsupportedOffAndIncompleteAreDistinctFromZeroEarned() {
        val missing=AchievementSummary.normalize(null);val unsupported=AchievementSummary.normalize(emptyMap<Any,Any>());val off=normalize(null)
        assertNotEquals(missing["reason"],unsupported["reason"]);assertNotEquals(unsupported["reason"],off["reason"])
        for(r in listOf(missing,unsupported,off,normalize(mapOf("earned" to 0)))) { assertEquals("unavailable",r["state"]);assertNull(r["earned"]) }
        val zero=normalize(mapOf("earned" to 0,"total" to 10));assertEquals("ready",zero["state"]);assertEquals(0L,zero["earned"]);assertEquals("Latest: no award saved",text(zero,"latest"))
    }
    @Test fun latestAndNextBothRemainVisibleWithTheirOwnDateAndProgress() {
        val raw=mapOf("achievements" to mapOf("earned" to 3,"total" to 20,"latest" to mapOf("name" to LuaValue.str("Read 二"),"awardedAt" to "2026-11-27T00:30:00Z"),"next" to mapOf("name" to "Next milestone","currentProgress" to 2.5,"threshold" to 10)))
        val r=AchievementSummary.normalize(raw,ZoneId.of("America/Los_Angeles"))
        assertEquals("3 / 20 earned",r["summary"]);assertEquals("Latest: Read 二",text(r,"latest"));assertEquals("2026-11-26",r["latest_date"])
        assertEquals("Next: Next milestone",text(r,"next"));assertEquals("2.5 / 10",text(r,"progress"));assertTrue(LuaValue.encode(r).size<16384)
    }
    @Test fun malformedCountsAndProgressNeverBecomeFalseSuccess() {
        for(count in listOf(-1,Double.NaN,1.5,Double.POSITIVE_INFINITY)) assertEquals("unavailable",normalize(mapOf("earned" to count,"total" to 10))["state"])
        assertEquals("unavailable",normalize(mapOf("earned" to 11,"total" to 10))["state"])
        for(n in listOf(-1,Double.NaN,Double.POSITIVE_INFINITY,11)) {
            val r=normalize(mapOf("earned" to 0,"total" to 10,"next" to mapOf("name" to "Next","currentProgress" to n,"threshold" to 10)))
            assertEquals("Progress unavailable",text(r,"progress"))
        }
        assertEquals("Award date unknown",normalize(mapOf("earned" to 1,"total" to 10,"latest" to mapOf("name" to "Latest","awardedAt" to "invalid")))["latest_date"])
    }
}
