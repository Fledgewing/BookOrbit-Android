// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import java.io.File

/** Four retained bounded queues; the catalog worker executes their files sequentially.
 * Each completed row is checkpointed here before control-plane history may evict it. */
internal class SeriesTransfers(private val root:File,private val transfers:CatalogTransfers) {
    private val file=File(root,"series-transfer-queues.lua")
    private val batches=CatalogWorkflow.load(file).entries.associate { it.key.toString() to (it.value as Map<*,*>).toMutableMap() }.toMutableMap()
    private fun save() {
        root.mkdirs();val tmp=File(file.path+".new")
        tmp.outputStream().use { it.write(LuaValue.encode(batches));it.fd.sync() };check(tmp.renameTo(file))
    }
    private fun owned(owner:String,id:String)=batches[id]?.takeIf { it["owner"]==owner } ?: throw ServerFailure("missing")
    private fun rows(batch:Map<*,*>)=(batch["rows"] as? List<*>).orEmpty().map { (it as Map<*,*>).entries.associate { e -> e.key.toString() to e.value }.toMutableMap() }
    private fun refresh(owner:String,batch:MutableMap<Any?,Any?>):List<MutableMap<String,Any?>> {
        val rows=rows(batch)
        for(row in rows) {
            val id=row["id"] as? String ?: continue
            val current=runCatching { transfers.read(owner,id) }.getOrNull()
            if(current!=null) row.putAll(current)
        }
        batch["rows"]=rows;return rows
    }
    @Synchronized fun start(owner:String,series:String,choices:List<Map<String,Any?>>,skipped:Int=0):Map<String,Any?> {
        require(choices.size in 1..10 && skipped in 0..10)
        val duplicate=batches.values.firstOrNull { it["owner"]==owner && it["series"]==series && rows(it).any { r -> r["state"] in CatalogTransfers.activeStates && r["failure"]==null } }
        if(duplicate!=null) return read(owner,duplicate["id"] as String)
        while(batches.size>=4) {
            val old=batches.entries.firstOrNull { (_,b) -> rows(b).all { it["state"] in setOf("complete","canceled","skipped") || it["failure"]!=null } } ?: throw ServerFailure("busy")
            batches.remove(old.key)
        }
        require(choices.map { it["key"] }.distinct().size==choices.size)
        val active=transfers.activeKeys(owner)
        transfers.makeRoom(owner,choices.count { it["key"] !in active && it["skip"]!=true && it["failure"]==null })
        val id=java.util.UUID.randomUUID().toString()
        val records=choices.map { choice ->
            val key=choice["key"] as? String ?: throw ServerFailure("invalid")
            (choice+mapOf("id" to null,"state" to if(key in active || choice["skip"]==true) "skipped" else if(choice["failure"]!=null) "error" else "paused","error" to choice["failure"],"progress_text" to "No supported file".takeIf { choice["failure"]!=null })).toMutableMap()
        }
        val order=(batches.values.maxOfOrNull { (it["order"] as? Number)?.toLong() ?: 0L } ?: 0L)+1
        val batch=mutableMapOf<Any?,Any?>("order" to order,"id" to id,"owner" to owner,"series" to series,"rows" to records,"skipped" to skipped)
        // Save the exact choices first. A crash between job creation and checkpoint
        // is recovered by the transfer plane's owner/file/variant deduplication.
        batches[id]=batch;save()
        for(row in records) if(row["state"]=="paused") { row.putAll(transfers.start(owner,row));save() }
        return read(owner,id)
    }
    @Synchronized fun read(owner:String,id:String):Map<String,Any?> {
        val b=owned(owner,id);val rows=refresh(owner,b)
        val saved=rows.count { it["state"]=="complete" }
        val skipped=rows.count { it["state"] in setOf("skipped","canceled") }+((b["skipped"] as? Number)?.toInt() ?: 0)
        val failed=rows.count { it["state"]=="error" }
        val paused=rows.any { it["state"] in setOf("paused","error") && it["failure"]==null }
        val active=rows.any { it["state"] in setOf("queued","running","canceling") }
        val total=rows.size+((b["skipped"] as? Number)?.toInt() ?: 0)
        val label="$saved saved · $skipped skipped · $failed failed · $total requested"
        return mapOf("id" to id,"series" to b["series"],"items" to rows.map { r -> r.filterKeys { it in setOf("id","key","title","state","received","total","sequence","local_path","error","progress_text") } },
            "sequence" to rows.sumOf { (it["sequence"] as? Number)?.toLong() ?: 0L },"requested" to total,"saved" to saved,"skipped" to skipped,"failed" to failed,
            "state" to if(active) "running" else if(paused) "paused" else "complete","summary" to label,"row_count" to (1+rows.size))
    }
    @Synchronized fun find(owner:String,series:String):Map<String,Any?>? = batches.values.filter { it["owner"]==owner && it["series"]==series }
        .sortedByDescending { (it["order"] as? Number)?.toLong() ?: 0L }.firstOrNull()?.let { read(owner,it["id"] as String) }
    @Synchronized fun cancel(owner:String,id:String):Map<String,Any?> {
        val b=owned(owner,id)
        val rows=refresh(owner,b)
        for(row in rows) {
            val job=row["id"] as? String
            if(job==null && row["state"]!="skipped" && row["failure"]==null) row["state"]="canceled"
            else if(job!=null && row["state"]!="complete") transfers.cancel(owner,job)
        }
        b["rows"]=rows;refresh(owner,b);save();return read(owner,id)
    }
    @Synchronized fun resume(owner:String,id:String):Map<String,Any?> {
        val b=owned(owner,id)
        val rows=refresh(owner,b)
        for(row in rows) {
            if(row["state"] !in setOf("paused","error") || row["failure"]!=null) continue
            if(row["id"]==null) { row.putAll(transfers.start(owner,row));b["rows"]=rows;save() }
            transfers.resume(owner,row["id"] as String)
        }
        refresh(owner,b);save();return read(owner,id)
    }
    /** One file per actor turn, so visible Library reads can run between files. */
    fun step(owner:String,id:String,perform:(Map<String,Any?>)->Map<String,Any?>):Boolean {
        val job=synchronized(this) { refresh(owner,owned(owner,id)).firstOrNull { it["state"]=="queued" }?.get("id") as? String } ?: return false
        transfers.run(owner,job,perform)
        val result=transfers.read(owner,job)
        val stop=result["state"]!="canceled" && result["error"] in setOf("offline","unauthorized","canceled")
        return synchronized(this) {
            val b=owned(owner,id)
            if(stop) for(row in refresh(owner,b)) (row["id"] as? String)?.let { transfers.pause(owner,it) }
            val remaining=refresh(owner,b).any { it["state"]=="queued" };save();remaining
        }
    }
    fun run(owner:String,id:String,perform:(Map<String,Any?>)->Map<String,Any?>) { while(step(owner,id,perform)) { } }
}
