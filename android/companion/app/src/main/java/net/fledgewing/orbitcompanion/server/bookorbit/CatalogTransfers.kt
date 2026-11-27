// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import java.io.File

/** Small durable control plane. Transfer IO still runs on the catalog's sole worker;
 * status/cancel never wait behind that IO. No credentials or expiring locators persist here. */
internal class CatalogTransfers(private val root:File) {
    private val file=File(root,"transfer-jobs.lua")
    private val jobs=linkedMapOf<String,MutableMap<String,Any?>>()
    init {
        val saved=CatalogWorkflow.load(file)["jobs"] as? List<*>
        for(raw in saved.orEmpty().takeLast(128)) {
            val row=raw as? Map<*,*> ?: continue
            val id=row["id"] as? String ?: continue
            val j=row.entries.associate { it.key.toString() to it.value }.toMutableMap()
            if(j["state"] in setOf("queued","running","canceling")) j["state"]="paused"
            jobs[id]=j
        }
    }
    companion object {
        val activeStates=setOf("queued","running","paused","canceling","error")
        fun activeKeys(root:File,owner:String):Set<String> = ((CatalogWorkflow.load(File(root,"transfer-jobs.lua"))["jobs"] as? List<*>).orEmpty())
            .mapNotNull { it as? Map<*,*> }.filter { it["owner"]==owner && it["state"] in activeStates }.mapNotNull { it["key"] as? String }.toSet()
    }
    @Synchronized fun activeKeys(owner:String)=jobs.values.filter { it["owner"]==owner && it["state"] in activeStates }.mapNotNull { it["key"] as? String }.toSet()
    @Synchronized fun makeRoom(owner:String,count:Int) {
        require(count in 0..10)
        val terminal=setOf("complete","canceled")
        if(jobs.values.count { it["owner"]==owner && it["state"] !in terminal }+count>32 ||
            jobs.values.count { it["state"] !in terminal }+count>128) throw ServerFailure("busy")
        while(jobs.values.count { it["owner"]==owner }+count>32) jobs.remove(jobs.entries.first { it.value["owner"]==owner && it.value["state"] in terminal }.key)
        while(jobs.size+count>128) jobs.remove(jobs.entries.first { it.value["state"] in terminal }.key)
    }
    private fun discardStage(job:Map<String,Any?>) {
        val destination=job["destination"] as? String ?: return
        val stage=job["staging"] as? String
        if(stage!=null && !stage.matches(Regex("[a-f0-9-]{36}"))) return
        // Old interrupted jobs retain their original staging name. Never discard
        // a legacy shared stage while another old job is actively writing it.
        if(stage==null && jobs.values.any { it!==job && it["destination"]==destination && it["staging"]==null && it["state"] in setOf("running","canceling") }) return
        val volume=root.parentFile?.parentFile?.parentFile ?: return
        val name=LuaValue.utf8(destination)+".booksync-part"+(stage?.let { ".$it" } ?: "")
        for(suffix in listOf("",".http-resume",".http-resume.new")) {
            val candidate=File(name+suffix)
            if(Places.inside(candidate,listOf(volume))!=null && !java.nio.file.Files.isSymbolicLink(candidate.toPath())) candidate.delete()
        }
    }
    private fun save() {
        root.mkdirs();val tmp=File(file.path+".new")
        tmp.outputStream().use { it.write(LuaValue.encode(mapOf("jobs" to jobs.values.toList())));it.fd.sync() }
        check(tmp.renameTo(file))
    }
    private fun owned(owner:String,id:String):MutableMap<String,Any?> = jobs[id]?.takeIf { it["owner"]==owner } ?: throw ServerFailure("missing")
    @Synchronized fun start(owner:String,args:Map<*,*>):Map<String,Any?> {
        val key=args["key"] as? String ?: throw ServerFailure("invalid")
        require(key.length in 1..512)
        val reference=args["file_reference"]
        jobs.values.firstOrNull { it["owner"]==owner && it["key"]==key && it["file_reference"]==reference && it["variant"]==args["variant"] && it["state"] in activeStates }?.let { return snapshot(it) }
        makeRoom(owner,1)
        val id=java.util.UUID.randomUUID().toString()
        jobs[id]=mutableMapOf("id" to id,"owner" to owner,"key" to key,"file_reference" to reference,
            "destination" to args["destination"],"root" to args["root"],"staging" to id,"variant" to args["variant"],"state" to "queued","received" to 0L,"sequence" to 0L)
        save();return snapshot(jobs[id]!!)
    }
    private fun snapshot(j:Map<String,Any?>):Map<String,Any?> {
        val received=(j["received"] as? Number)?.toLong() ?: 0L
        val total=(j["total"] as? Number)?.toLong()?.takeIf { it>0 }
        val bytesText=DeviceStorage.format(received)+(total?.let { " / "+DeviceStorage.format(it) } ?: " received")
        val label=when(j["state"]) {
            "complete"->"Saved on this reader"
            "canceled"->"Canceled · $bytesText"
            "canceling"->"Canceling · $bytesText"
            "paused"->"Paused · $bytesText"
            "error"->when(j["error"]) {"space"->"Not enough free space";"unauthorized"->"Sign in to download";"offline"->"Connection lost · Resume when online";"invalid"->"File validation failed · Retry";else->"Download stopped · Retry"}
            else->bytesText
        }
        return j.filterKeys { it in setOf("id","key","state","received","total","sequence","local_path","error") }+
            mapOf("progress_text" to label,"row_count" to 1)
    }
    private fun advance(j:MutableMap<String,Any?>) { j["sequence"]=((j["sequence"] as? Number)?.toLong() ?: 0L)+1 }
    @Synchronized fun read(owner:String,id:String)=snapshot(owned(owner,id))
    @Synchronized fun cancel(owner:String,id:String):Map<String,Any?> {
        val j=owned(owner,id)
        if(j["state"] in setOf("running","canceling")) j["state"]="canceling"
        else if(j["state"]!="complete") j["state"]="canceled"
        advance(j);save();if(j["state"]=="canceled") discardStage(j);return snapshot(j)
    }
    @Synchronized fun resume(owner:String,id:String):Map<String,Any?> {
        val j=owned(owner,id)
        if(j["state"] in setOf("paused","error","canceled")) { if(j["state"]=="canceled") j["received"]=0L;j["state"]="queued";j.remove("error");advance(j);save() }
        return snapshot(j)
    }
    @Synchronized fun pause(owner:String,id:String) {
        val j=owned(owner,id)
        if(j["state"]=="queued") { j["state"]="paused";advance(j);save() }
    }
    @Synchronized fun canceled(owner:String,id:String)=owned(owner,id)["state"] in setOf("canceling","canceled")
    @Synchronized fun progress(owner:String,id:String,bytes:Long,total:Long?) {
        val j=owned(owner,id)
        if(j["state"]!="running") return
        j["received"]=bytes;j["total"]=total;j["sequence"]=((j["sequence"] as? Number)?.toLong() ?: 0L)+1;save()
    }
    fun run(owner:String,id:String,perform:(Map<String,Any?>)->Map<String,Any?>) {
        val args=synchronized(this) {
            val j=owned(owner,id)
            if(j["state"]!="queued") return
            j["state"]="running";advance(j);save();j.toMap()
        }
        val result=runCatching { perform(args).also { require(it["local_path"] is String) } }
        synchronized(this) {
            val j=owned(owner,id)
            result.fold({ value ->
                // Publication wins a final Cancel race, but the UI's canceled intent never opens it.
                j["local_path"]=value["local_path"];j["state"]="complete"
            },{ failure ->
                j["state"]=if(j["state"]=="canceling") "canceled" else "error"
                j["error"]=(failure as? ServerFailure)?.kind ?: "retryable"
            })
            j["sequence"]=((j["sequence"] as? Number)?.toLong() ?: 0L)+1;save()
        }
    }
}
