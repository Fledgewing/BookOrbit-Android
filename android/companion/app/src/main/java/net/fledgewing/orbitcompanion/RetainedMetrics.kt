// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** One compact worker snapshot for the retained read-only metric cards.
 * Inputs have already passed account/local precedence and Today overlap rules. */
object RetainedMetrics {
    private fun count(v:Any?):Long?=(v as? Number)?.toDouble()?.takeIf { it.isFinite() && it>=0 && it<=Int.MAX_VALUE.toDouble() && it%1.0==0.0 }?.toLong()
    private fun duration(n:Long):String { val m=n/60;return if(m>=60) "${m/60} h ${m%60} m" else "$m m" }
    private fun text(s:String)=LuaValue.str(s)
    fun snapshot(data:Map<String,Any?>,now:Long,zone:ZoneId=ZoneId.systemDefault()):Map<String,Any?> {
        val today=Instant.ofEpochSecond(now).atZone(zone).toLocalDate()
        val records=(data["records"] as? Map<*,*>).orEmpty()
        val goal=(data["goal"] as? Map<*,*>).orEmpty()
        val sources=(data["sources"] as? Map<*,*>).orEmpty()
        fun source(field:String)=sources[field] as? String ?: "this reader"
        fun metric(reason:String)=mapOf<String,Any?>("state" to "unavailable","reason" to reason)
        val metrics=linkedMapOf<String,Map<String,Any?>>()
        val seconds=count(goal["today_seconds"])
        metrics["today"]=seconds?.let { mapOf("state" to "ready","source" to source("today"),"value" to text(duration(it)),
            "separate" to count(data["local_today_seconds"])?.let { local -> text("${duration(local)} · this reader, separate") }) } ?: metric("Reading time unavailable")
        val year=(data["year"] as? Map<*,*>).orEmpty()
        val start=(year["start"] as? String)?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
        val daily=(year["seconds"] as? List<*>)?.takeIf { it.size==365 }?.map { count(it) }
            ?.takeIf { it.all { n -> n!=null } }?.map { it!! }
        val streak=count(records["streak"])
        metrics["reading-streak"]=streak?.let { mapOf("state" to "ready","source" to source("streak"),"value" to text("$it days"),
            "best" to count(records["best_streak"])?.let { best -> text("Longest: $best days") },
            "days" to daily?.takeLast(7)?.map { s -> if(s>0) 4 else 0 },
            "days_source" to text("Last seven days · ${source("days")}")) } ?: metric("Reading streak unavailable")
        val target=count(goal["target"]);val completed=count(goal["books_this_year"])
        val goalYear=count(goal["year"])?.takeIf { it in 1..9999 }
        metrics["reading-goal"]=if(goalYear==null || source("goal")!="all your devices") metric("Account reading goal unavailable")
            else if(target==null || target==0L) mapOf("state" to "ready","source" to source("goal"),"value" to text("No goal set for $goalYear"))
            else {
                val remaining=completed?.let { (target-it).coerceAtLeast(0) }
                val current=goalYear==today.year.toLong()
                val pace=if(current && remaining!=null) text("Need ${String.format(Locale.US,"%.1f",remaining*7.0/(today.lengthOfYear()-today.dayOfYear+1))} books / week") else null
                val expected=if(current) target*today.dayOfYear.toDouble()/today.lengthOfYear() else null
                val difference=if(expected!=null && completed!=null) completed-kotlin.math.round(expected).toLong() else null
                val status=when { remaining==0L -> "Goal reached";difference==null -> if(current) "Completion count unavailable" else "Saved goal for $goalYear";
                    difference>0 -> "$difference ${if(difference==1L) "book" else "books"} ahead";difference<0 -> "${-difference} ${if(difference == -1L) "book" else "books"} behind";else -> "On pace" }
                mapOf("state" to "ready","source" to source("goal"),"value" to text(if(completed!=null) "$completed / $target books · $goalYear" else "Target $target · $goalYear"),
                    "fraction" to completed?.let { (it.toDouble()/target).coerceIn(0.0,1.0) },"pace" to pace,"status" to text(status))
            }
        val lifetime=count(records["recorded_pages"]);val todayPages=count(records["today_pages"])
        metrics["pages-read"]=if(lifetime!=null && todayPages!=null) mapOf("state" to "ready","source" to "this reader",
            "today" to text(java.text.NumberFormat.getIntegerInstance().format(todayPages)),"lifetime" to text(java.text.NumberFormat.getIntegerInstance().format(lifetime)),
            "definition" to "Timed page visits") else metric("Page records unavailable")
        metrics["monthly-reading"]=if(start==null || daily==null) metric("Reading days unavailable") else {
            val first=today.withDayOfMonth(1).minusMonths(11)
            val totals=LongArray(12)
            for((i,value) in daily.withIndex()) {
                val date=start.plusDays(i.toLong())
                val month=java.time.temporal.ChronoUnit.MONTHS.between(first,date.withDayOfMonth(1)).toInt()
                if(month in 0..11 && !date.isAfter(today)) totals[month]+=value
            }
            val maximum=totals.maxOrNull() ?: 0L
            mapOf("state" to "ready","source" to source("days"),"labels" to (0L..11L).map { text(first.plusMonths(it).format(DateTimeFormatter.ofPattern("MMM"))) },
                "levels" to totals.map { it.toDouble()/maxOf(1,maximum) },"total" to text(duration(totals.sum())),
                "previous" to text("Previous month: ${duration(totals[10])}"),"period" to text(first.format(DateTimeFormatter.ofPattern("MMM yyyy"))+" – "+today.format(DateTimeFormatter.ofPattern("MMM yyyy"))))
        }
        return mapOf("metrics" to metrics,"state" to data["state"],"freshness" to data["freshness"],"row_count" to 1)
    }
}
