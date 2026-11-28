// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import java.io.File
import kotlin.math.ceil

/** Bounded cached native geometry plus the existing measured fractional-book pace. */
object NextStop {
    private fun number(v:Any?)=(v as? Number)?.toDouble()?.takeIf { it.isFinite() }
    private fun whole(v:Any?,low:Int=0)=number(v)?.takeIf { it>=low && it<=Int.MAX_VALUE && it%1.0==0.0 }?.toInt()
    private fun title(v:Any?)=(v as? String)?.let(LuaValue::utf8)?.replace(Regex("[\\r\\n\\t]")," ")?.trim()?.take(128)?.takeIf { it.isNotEmpty() }
    private fun duration(seconds:Double):String {
        val minutes=ceil(seconds/60).toLong();val hours=minutes/60
        return if(hours>=24) "${hours/24} d ${hours%24} h" else if(hours>0) "$hours h ${minutes%60} min" else "$minutes min"
    }
    fun snapshot(native:Map<*,*>,forecast:Map<String,Any?> = emptyMap()):Map<String,Any?> {
        if((native["path"] as? String).isNullOrBlank()) return mapOf("state" to "unavailable","reason" to "Open a book to see its next stop","row_count" to 1)
        val total=whole(native["total"],1);val page=whole(native["page"],1)?.takeIf { total!=null && it<=total }
        if(total==null || page==null) return mapOf("state" to "unavailable","reason" to "Position not available yet","row_count" to 1)
        val count=whole(native["chapter_total"])
        val loaded=native["toc_loaded"]==true && native["chapter_exact"]==true && count!=null
        val index=(if(native["chapter_index"]==null) 0 else whole(native["chapter_index"]))?.takeIf { count!=null && it<=count }
        val next=whole(native["next_page"],1)?.takeIf { loaded && it>page && it<=total }
        val nextUnknown=loaded && next==null && (native["next_exists"]==true || index==null || index<count!!)
        val pace=number(forecast["seconds_per_fraction"])?.takeIf { it>0 && it<=3153600000.0 }
        fun time(distance:Int)=pace?.let { distance.toDouble()/total*it }
        val end=if(page==total) 0.0 else time(total-page)
        val nextSeconds=if(next!=null) time(next-page) else if(loaded && !nextUnknown) end else null
        val current=when { !loaded -> "Contents not loaded";count==0 -> "No contents entries";index==0 -> "Before the first contents entry";else -> title(native["chapter_title"]) ?: "Current contents entry" }
        val following=when { !loaded -> "Open Contents once";nextUnknown -> "Contents position unavailable";next!=null -> title(native["next_title"]) ?: "Next contents entry";else -> "End of book" }
        val result=mapOf("state" to "ready","row_count" to 1,"freshness" to mapOf("saved" to true,"origin" to "local-reader"),
            "current" to LuaValue.str("Now: $current"),"next" to LuaValue.str("Next: $following"),
            "to_next" to LuaValue.str(when { page==total -> "At end of book";nextSeconds!=null -> "≈ ${duration(nextSeconds)} to ${if(next!=null) "next" else "end"}";!loaded || nextUnknown -> "Chapter time unavailable";else -> "Not enough reading yet" }),
            "to_end" to LuaValue.str(end?.let { "≈ ${duration(it)} to end" } ?: "End time unavailable"),
            "remaining" to if(loaded && count!=null && index!=null) "${count-index} contents ${if(count-index==1) "entry" else "entries"} left" else "Contents count unavailable",
            "source" to LuaValue.str(if(pace!=null) "Measured pace · this reader" else "On this reader · pace unavailable"))
        require(LuaValue.encode(result).size<=16384);return result
    }
    fun read(native:Map<*,*>,statistics:File,now:Long,open:(File)->Sql={AndroidSql(it,readOnly=true)}):Map<String,Any?> {
        val total=whole(native["total"],1);val page=whole(native["page"],1)
        val fraction=if(total!=null && page!=null && page<=total) page.toDouble()/total else null
        val md5=(native["md5"] as? String)?.takeIf { Regex("[0-9a-f]{32}").matches(it) }
        val forecast=if(!(native["path"] as? String).isNullOrBlank() && md5!=null && fraction!=null && statistics.isFile) runCatching {
            open(statistics).use { ReadingStats.forecast(it,md5,fraction,now,0,includePace=true) }
        }.getOrElse { if(it is InterruptedException) throw it;emptyMap() } else emptyMap()
        return snapshot(native,forecast)
    }
}
