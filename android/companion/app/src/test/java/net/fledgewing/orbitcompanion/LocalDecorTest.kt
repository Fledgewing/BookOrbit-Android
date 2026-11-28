// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.ZoneId
class LocalDecorTest {
    private val utc=ZoneId.of("UTC")
    private fun at(s:String)=Instant.parse(s).epochSecond
    @Test fun meanLunationShowsPrimaryPhasesAndExplicitApproximation() {
        val epoch=at("2000-01-06T18:14:00Z")
        val new=LocalDecor.snapshot("moon",epoch,utc)
        assertEquals("New moon",new["phase"]);assertEquals(0,new["illumination"])
        assertTrue(LuaValue.utf8(new["next"].toString()).startsWith("Next: First quarter · ≈ "))
        assertEquals("Approximate · local date",LuaValue.utf8(new["source"].toString()))
        val full=LocalDecor.snapshot("moon",epoch+(29.530588*86400/2).toLong(),utc)
        assertEquals("Full moon",full["phase"]);assertEquals(100,full["illumination"])
        assertTrue(LuaValue.encode(full).size<16384)
    }
    @Test fun nextPrimaryDateUsesTheReadersTimezoneAndValuesStayBounded() {
        val epoch=at("2000-01-06T18:14:00Z")
        val a=LocalDecor.snapshot("moon",epoch,utc)
        val b=LocalDecor.snapshot("moon",epoch,ZoneId.of("America/Los_Angeles"))
        assertNotEquals(a["next"],b["next"]);assertEquals(a["illumination"],b["illumination"])
        for(day in 0L..365L) {
            val s=LocalDecor.snapshot("moon",at("2026-01-01T12:00:00Z")+day*86400,utc)
            assertTrue((s["illumination"] as Int) in 0..100)
        }
    }
    @Test fun dailyLatinSampleIsStableLocalDayAwareAndCarriesNameCodePointAndSource() {
        val now=at("2026-07-01T00:30:00Z")
        val a=LocalDecor.snapshot("glyph",now,utc)
        assertEquals(a,LocalDecor.snapshot("glyph",now+3600,utc))
        val next=LocalDecor.snapshot("glyph",now+86400,utc)
        val prior=LocalDecor.snapshot("glyph",now,ZoneId.of("America/Los_Angeles"))
        assertEquals(65+((a["codepoint"] as Int)-65+1)%26,next["codepoint"])
        assertNotEquals(a["codepoint"],prior["codepoint"])
        assertEquals((a["codepoint"] as Int).toChar().toString(),a["sample"])
        assertTrue(a["name"].toString().startsWith("Latin capital letter "))
        assertTrue(a["code"].toString().matches(Regex("U\\+00[45][0-9A-F]")))
        assertEquals("KOReader interface font",a["source"]);assertEquals(1,a["row_count"])
    }
    @Test fun invalidClockAndUnsupportedKindsDoNotInventADateOrGlyph() {
        for(kind in listOf("moon","glyph")) for(time in listOf(0L,Long.MAX_VALUE,at("2101-01-01T00:00:00Z"))) {
            val result=LocalDecor.snapshot(kind,time,utc)
            assertEquals("unavailable",result["state"]);assertNull(result["phase"]);assertNull(result["sample"])
        }
        assertThrows(IllegalArgumentException::class.java) { LocalDecor.snapshot("unknown",0,utc) }
    }
}
