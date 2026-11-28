// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.roundToInt

/** Local date-derived decor. A mean-lunation estimate, never a fetched ephemeris. */
object LocalDecor {
    // NASA phase table: 2000-01-06 18:14 UT; mean synodic period, not individual lunations.
    // https://eclipse.gsfc.nasa.gov/phase/phases1901.html
    // https://eclipse.gsfc.nasa.gov/help/moonorbit.html
    private val epoch=Instant.parse("2000-01-06T18:14:00Z").epochSecond
    private const val period=29.530588*86400.0
    private val phases=listOf("New moon","Waxing crescent","First quarter","Waxing gibbous","Full moon","Waning gibbous","Last quarter","Waning crescent")
    fun snapshot(kind:String,now:Long,zone:ZoneId=ZoneId.systemDefault()):Map<String,Any?> {
        require(kind in setOf("moon","glyph"))
        val date=runCatching { Instant.ofEpochSecond(now).atZone(zone) }.getOrNull()
        if(date==null || date.year !in 2000..2100) return mapOf("state" to "unavailable","reason" to "Set the reader's date","row_count" to 1)
        val fields=if(kind=="glyph") {
            // Original, deterministic Latin alphabet sample; no downloaded glyph artwork.
            val cp=65+Math.floorMod(date.toLocalDate().toEpochDay(),26L).toInt()
            mapOf("sample" to cp.toChar().toString(),"codepoint" to cp,"code" to "U+%04X".format(cp),"name" to "Latin capital letter ${cp.toChar()}","source" to "KOReader interface font")
        } else {
            val elapsed=(now-epoch)/period
            val fraction=elapsed-floor(elapsed)
            val next=floor(fraction*4)+1
            val nextTime=Instant.ofEpochSecond(now+((next/4-fraction)*period).toLong()).atZone(zone)
            mapOf("phase" to phases[((fraction*8+.5).toInt())%8],"illumination" to ((1-cos(2*PI*fraction))*50).roundToInt().coerceIn(0,100),
                "next" to LuaValue.str("Next: ${phases[(next.toInt()%4)*2]} · ≈ ${nextTime.format(DateTimeFormatter.ofPattern("d MMM"))}"),
                "source" to LuaValue.str("Approximate · local date"))
        }
        return fields+mapOf("state" to "ready","freshness" to mapOf("saved" to true,"origin" to "local-date"),"row_count" to 1)
    }
}
