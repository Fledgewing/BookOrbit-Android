// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit
import net.fledgewing.orbitcompanion.*
import java.time.Instant
import java.time.ZoneId

internal object AchievementSummary {
    fun read(store:CacheStore):Map<String,Any?> {
        val entry=store.db().query("SELECT body,fetched_at,stale FROM entries WHERE path=? ORDER BY fetched_at DESC LIMIT 1","/koreader/plugin/catalog/dashboard") {
            Triple(it.bytes(0)?.let(LuaValue::parse) as? Map<*,*>,it.long(1),it.text(2))
        }.firstOrNull()
        return normalize(entry?.first)+mapOf("freshness" to mapOf("saved" to (entry?.first!=null),"origin" to "cached-remote","at" to entry?.second,"stale" to (entry?.third!=null)))
    }
    fun normalize(raw:Map<*,*>?,zone:ZoneId=ZoneId.systemDefault()):Map<String,Any?> {
        fun unavailable(reason:String)=mapOf("state" to "unavailable","reason" to reason,"row_count" to 1)
        if(raw==null) return unavailable("Account summary not saved yet")
        if(!raw.containsKey("achievements")) return unavailable("Achievements unsupported by this saved account summary")
        val a=raw["achievements"] as? Map<*,*> ?: return unavailable("Achievements unavailable or turned off")
        fun n(value:Any?)=(value as? Number)?.toDouble()?.takeIf { it.isFinite() && it in 0.0..1e12 }
        fun count(value:Any?)=n(value)?.takeIf { it%1.0==0.0 }?.toLong()
        fun label(v:Any?)=(v as? String)?.let(LuaValue::utf8)?.trim()?.takeIf { it.isNotEmpty() }?.take(80)
        val earned=count(a["earned"]);val total=count(a["total"])
        if(earned==null || total==null || earned>total) return unavailable("Saved achievement counts incomplete")
        val latest=a["latest"] as? Map<*,*>;val next=a["next"] as? Map<*,*>
        val latestName=label(latest?.get("name"));val nextName=label(next?.get("name"))
        val date=(latest?.get("awardedAt") as? String)?.let { runCatching { Instant.parse(it).atZone(zone).toLocalDate().toString() }.getOrNull() }
        val threshold=n(next?.get("threshold"))?.takeIf { it>0 };val progress=n(next?.get("currentProgress"))?.takeIf { threshold!=null && it<=threshold }
        fun number(v:Double)=if(v%1.0==0.0) v.toLong().toString() else "%.2f".format(java.util.Locale.ROOT,v).trimEnd('0').trimEnd('.')
        return mapOf("state" to "ready","row_count" to 1,"earned" to earned,"total" to total,
            "summary" to "$earned / $total earned","latest" to LuaValue.str(latestName?.let { "Latest: $it" } ?: "Latest: no award saved"),
            "latest_date" to if(latestName!=null) date ?: "Award date unknown" else "",
            "next" to LuaValue.str(nextName?.let { "Next: $it" } ?: "Next: none saved"),
            "progress" to LuaValue.str(if(nextName!=null && progress!=null && threshold!=null) "${number(progress)} / ${number(threshold)}" else if(nextName!=null) "Progress unavailable" else ""),
            "source" to "Saved account summary")
    }
}
