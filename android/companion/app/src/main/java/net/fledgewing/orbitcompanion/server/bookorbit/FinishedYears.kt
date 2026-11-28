// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Additive cache history, never a migration of reader data or a completion ledger. */
internal object FinishedYears {
    const val TABLE="booksync_finished_years"
    const val ACKS="booksync_finished_acks"
    private const val PATH="/koreader/plugin/catalog/dashboard"
    fun initialize(db:Sql) {
        db.exec("CREATE TABLE IF NOT EXISTS $TABLE(owner TEXT NOT NULL,year INTEGER NOT NULL,body BLOB NOT NULL,PRIMARY KEY(owner,year))")
        db.exec("CREATE TABLE IF NOT EXISTS $ACKS(owner TEXT NOT NULL,book INTEGER NOT NULL,day TEXT NOT NULL,PRIMARY KEY(owner,book))")
    }
    private fun count(v:Any?)=(v as? Number)?.toDouble()?.takeIf { it.isFinite() && it>=0 && it<=Int.MAX_VALUE && it%1.0==0.0 }?.toLong()
    fun capture(store:CacheStore,path:String,body:Any?,at:Long) {
        if(path!=PATH) return
        val owner=store.meta("owner") ?: return
        val raw=body as? Map<*,*> ?: return
        val goal=raw["readingGoal"] as? Map<*,*> ?: return
        val year=count(goal["year"])?.takeIf { it in 2000..2100 } ?: return
        val rows=raw["finishedThisYear"] as? List<*> ?: return
        // Retain only the bounded connector selection, not an invented full-year list.
        val books=rows.take(12).mapIndexedNotNull { rank,v ->
            val b=v as? Map<*,*> ?: return@mapIndexedNotNull null
            if(count(b["id"])?.takeIf { it>0 }==null) return@mapIndexedNotNull null
            val bounded=mapOf("id" to count(b["id"])!!,
                "title" to LuaValue.boundedText((b["title"] as? String)?.let(LuaValue::utf8).orEmpty(),160),
                "authors" to (b["authors"] as? List<*>).orEmpty().filterIsInstance<String>().take(3).map { LuaValue.boundedText(LuaValue.utf8(it),80) },
                "readStatus" to (b["readStatus"] as? String)?.take(32),"progressPercentage" to b["progressPercentage"],
                "seriesName" to (b["seriesName"] as? String)?.let { LuaValue.boundedText(LuaValue.utf8(it),120) },
                "seriesId" to count(b["seriesId"]),"seriesIndex" to b["seriesIndex"]?.toString()?.take(24),
                "formats" to (b["formats"] as? List<*>)?.filterIsInstance<String>()?.take(10)?.map { it.take(12) })
            val normalized=BookOrbitLibrary.summary(owner,bounded,rank.toLong(),null).filterKeys { it in setOf("key","title","authors","series","series_key","series_position","status","progress","formats","rank","on_device","available") }

            val date=(b["finishedOn"] as? String)?.let(LuaValue::utf8)?.let { value ->
                runCatching { LocalDate.parse(value.take(10)) }.getOrNull()?.takeIf { it.year.toLong()==year }?.toString()
            }
            if(date!=null) {
                val id=count(b["id"])!!;val key=BookOrbitLibrary.namespace(owner)
                val previous=store.db().query("SELECT day FROM $ACKS WHERE owner=? AND book=?",key,id) { it.text(0) }.firstOrNull()
                if(previous==null || previous<date) store.db().exec("INSERT OR REPLACE INTO $ACKS(owner,book,day) VALUES(?,?,?)",key,id,date)
            }
            normalized + mapOf("finished_on" to date,"status_note" to if(date==null) "Finish date unknown" else "Finished $date")
        }
        val value=mapOf("items" to books,"year" to year,"finished_total" to count(goal["completedBooks"]),"at" to at)
        store.db().exec("INSERT OR REPLACE INTO $TABLE(owner,year,body) VALUES(?,?,?)",BookOrbitLibrary.namespace(owner),year,LuaValue.encode(value))
    }
    private fun seed(store:CacheStore) {
        store.db().query("SELECT body,fetched_at FROM entries WHERE path=? ORDER BY fetched_at",PATH) { it.bytes(0) to it.long(1) }.forEach { (body,at) ->
            if(body!=null) capture(store,PATH,LuaValue.parse(body),at ?: 0)
        }
    }
    fun options(store:CacheStore,owner:String,now:Long):List<Map<String,Any?>> {
        seed(store)
        val current=Instant.ofEpochSecond(now).atZone(ZoneId.systemDefault()).year
        val saved=store.db().query("SELECT year,body FROM $TABLE WHERE owner=? ORDER BY year DESC",BookOrbitLibrary.namespace(owner)) {
            it.long(0)!!.toInt() to ((it.bytes(1)?.let(LuaValue::parse)) as? Map<*,*>).orEmpty()
        }.toMap()
        val workflow=CatalogWorkflow.load(java.io.File(store.root,"workflows/${BookOrbitLibrary.namespace(owner)}.lua"))
        val localYears=(workflow["year_pending"] as? Map<*,*>).orEmpty().values.mapNotNull { raw -> ((raw as? Map<*,*>)?.get("date") as? String)?.let { runCatching { LocalDate.parse(it).year }.getOrNull() } }.filter { it in 2000..2100 }
        return (saved.keys+current+localYears).distinct().sortedDescending().map { year -> mapOf("src" to "year:$year","title" to "Finished in $year","count" to saved[year]?.get("finished_total"),"default_sort" to 0) }
    }
    fun window(store:CacheStore,owner:String,year:Int,args:Map<*,*>):Map<String,Any?> {
        require(year in 2000..2100)
        seed(store)
        val data=store.db().query("SELECT body FROM $TABLE WHERE owner=? AND year=?",BookOrbitLibrary.namespace(owner),year) { it.bytes(0)?.let(LuaValue::parse) as? Map<*,*> }.firstOrNull()
        val query=args["query"] as? Map<*,*> ?: emptyMap<Any,Any>();LibraryFilter.validate(query)
        val rows=(data?.get("items") as? List<*>).orEmpty().mapNotNull { it as? Map<*,*> }.map { raw -> raw.entries.associate { it.key.toString() to it.value } }
        val state=CatalogWorkflow.load(java.io.File(store.root,"workflows/${BookOrbitLibrary.namespace(owner)}.lua"))
        val pending=(state["year_pending"] as? Map<*,*>).orEmpty().values.mapNotNull { it as? Map<*,*> }.mapNotNull { proof ->
            val date=(proof["date"] as? String)?.takeIf { runCatching { LocalDate.parse(it).year==year }.getOrDefault(false) } ?: return@mapNotNull null
            val id=count(proof["book_id"]) ?: return@mapNotNull null
            val ack=store.db().query("SELECT day FROM $ACKS WHERE owner=? AND book=?",BookOrbitLibrary.namespace(owner),id) { it.text(0) }.firstOrNull()
            if(ack!=null && ack>=date) return@mapNotNull null
            val raw=(store.bookItem(id) as? Map<*,*>) ?: (store.detail(id)?.first as? Map<*,*>) ?: emptyMap<Any,Any>()
            mapOf("key" to BookOrbitLibrary.key(owner,"book",id),"title" to LuaValue.boundedText((raw["title"] as? String)?.let(LuaValue::utf8) ?: "Saved completion",160),
                "authors" to emptyList<Any>(),"status" to "finished","rank" to -1,"finished_on" to date,"status_note" to "Marked read $date · awaiting account acknowledgement")
        }
        val pendingKeys=pending.map { it["key"] }.toSet()
        val display=pending+rows.filter { it["key"] !in pendingKeys }
        val selected=display.filter { LibraryFilter.matches(it,query) }.sortedWith(LibraryFilter.comparator(query))
        val offset=((args["offset"] as? Number)?.toInt() ?: 0).coerceAtLeast(0)
        val limit=((args["limit"] as? Number)?.toInt() ?: 12).coerceIn(1,32)
        if(args["op"]=="groups") return SeriesPresentation.groups(selected,query,offset,limit,
            ((args["preview"] as? Number)?.toInt() ?: 3).coerceIn(1,9),((args["group_limit"] as? Number)?.toInt() ?: 3).coerceIn(1,6))+
            mapOf("context" to mapOf("coverage" to LuaValue.str("Saved selection · ${rows.size} books")),"freshness" to mapOf("saved" to (data!=null || pending.isNotEmpty()),"origin" to "cached-remote"))
        if(args["op"]=="facets") {
            val facet=LibraryFacets(args["field"].toString(),query.entries.associate { it.key.toString() to it.value },System.currentTimeMillis()/1000)
            display.forEach { facet.include(it) }
            return facet.page(offset,limit)+mapOf("total" to selected.size,"freshness" to mapOf("saved" to (data!=null),"origin" to "cached-remote"))
        }
        val window=selected.drop(offset).take(limit)
        val total=data?.get("finished_total")
        val label="Finished in $year · ${total ?: "—"} total"
        return mapOf("items" to window,"total" to selected.size,"next" to (offset+window.size).takeIf { it<selected.size },
            "context" to mapOf("title" to LuaValue.str(label),"coverage" to LuaValue.str((if(data==null) "Account year summary pending" else "Saved selection · ${rows.size} books") + if(pending.isNotEmpty()) " · ${pending.size} local pending" else ""),"year" to year,"finished_total" to total),
            "freshness" to mapOf("saved" to (data!=null || pending.isNotEmpty()),"origin" to "cached-remote","at" to data?.get("at")),"row_count" to window.size)
    }
}
