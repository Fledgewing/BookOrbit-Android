package net.fledgewing.orbitcompanion

import java.io.File
import java.security.MessageDigest

/** One serial owner for capture, policy state, consent, migration and every server write.
 * Native captures contain a locator and bounded geometry only; heavy sidecar/stat work stays here. */
class SyncOwner(private val journal: LifecycleQueue, private val settings: File,
    private val log: (String)->Unit = OLog::i, private val now: ()->Long = { System.currentTimeMillis()/1000 }) {
    private var active=false
    private var activatedOwner: String?=null
    private var readerEpoch: String?=null
    private var openPath: String?=null
    @Volatile private var previews: Map<String,Map<String,Any?>> = emptyMap()
    private fun map(value: Any?) = (value as? Map<*, *>)?.entries?.associate { it.key.toString() to it.value }.orEmpty()
    private fun number(value: Any?) = (value as? Number)?.toDouble()
    private fun time(value: Any?) = (value as? Number)?.toLong() ?: 0L
    private fun scope(a: ServerAdapter) = a.positionOwner() ?: throw ServerFailure("unauthorized")
    private fun record(a: ServerAdapter, document: String) = map(journal.record(a.id,scope(a),document))
    private fun projection(document: String, owner: String, record: Map<String,Any?>): Map<String,Any?> =
        record.filterKeys { it in setOf("path","marker","remote","token","pending") }+mapOf("document" to document,"owner" to owner)
    private fun save(a: ServerAdapter, document: String, record: Map<String,Any?>) {
        journal.record(a.id,scope(a),document,record)
        val path=record["path"] as? String ?: return
        val snapshot=record+mapOf("document" to document,"owner" to scope(a))
        previews=(previews+((a.id+"|"+scope(a)+"|"+path) to snapshot)).entries.toList().takeLast(300).associate { it.toPair() }
        val bytes=LuaValue.encode(projection(document,scope(a),record))
        if(bytes.size>16384) return // Keep the complete private record; oversized snapshots never reach Lua.
        val dir=File(settings,"orbit-cache/position").also { it.mkdirs() }
        val file=File(dir,MessageDigest.getInstance("MD5").digest(path.toByteArray(Charsets.ISO_8859_1)).joinToString("") { "%02x".format(it) }+".lua")
        val temp=File(dir,file.name+".tmp")
        temp.writeBytes(bytes); check(temp.renameTo(file))
    }
    fun restorePreviews(a: ServerAdapter, publish: Boolean=false) {
        val owner=a.positionOwner() ?: return
        for ((document,record) in journal.records(a.id,owner)) {
            val path=record["path"] as? String ?: continue
            previews=previews+((a.id+"|"+owner+"|"+path) to (record+mapOf("document" to document,"owner" to owner)))
            if(publish) save(a,document,record)
        }
    }
    fun activate(a: ServerAdapter, quiesced: Boolean, epoch: String="fixture"): Map<String,Any?> {
        check(quiesced)
        if(active && activatedOwner==a.positionOwner() && epoch==readerEpoch) return mapOf("ok" to true,"imported" to 0)
        if(readerEpoch!=epoch) openPath=null
        readerEpoch=epoch
        val count=a.importLifecycle(journal,settings,true)
        active=true
        activatedOwner=a.positionOwner()
        restorePreviews(a,true)
        return mapOf("ok" to true,"imported" to count)
    }
    private fun ensure() { if (!active) throw ServerFailure("writer-active") }
    fun needsRetry(a: ServerAdapter) = active && a.positionOwner()?.let { journal.pending(a.id,it)>0 }==true
    fun write(a: ServerAdapter, document: String, update: Map<String,Any?>): Map<String,Any?> {
        ensure()
        val fraction=number(update["percentage"]) ?: throw IllegalArgumentException("percentage")
        require(fraction.isFinite() && fraction in 0.0..1.0)
        val position=update["position"] as? String
        require(position==null || position.length<=4096)
        val intent=mapOf("percentage" to fraction,"position" to position,"capturedAt" to now())
        journal.enqueue(a.id,scope(a),document,a.positionIntent(document,intent),LifecycleQueue.PHASES.take(4).toSet())
        return drain(a)
    }
    fun command(a: ServerAdapter, op: String, args: Map<*, *>): Map<String,Any?> {
        val started=System.nanoTime()
        try {
            if (op=="sync.activate") {
                val result=activate(a,args["quiesced"]==true,args["epoch"] as? String ?: "unknown")
                openPath=args["path"] as? String
                return result
            }
            ensure()
            val owner=scope(a)
            if (op=="sync.drain") {
                if(args["closed_path"]==openPath && openPath!=null) openPath=null
                if(args["online"]==false) return mapOf("remaining" to journal.pending(a.id,owner))
                return drain(a)
            }
            val path=args["path"] as? String
            if (path!=null) openPath=path
            val capture=if (path!=null && op in setOf("sync.capture","sync.override","sync.pull")) a.captureLifecycle(args) else null
            val document=capture?.first ?: args["document"] as? String ?: throw IllegalArgumentException("document")
            var rec=record(a,document).toMutableMap()
            if (path!=null) rec["path"]=path
            val local=mapOf("percentage" to args["percentage"],"position" to args["position"],"at" to time(args["captured_at"]).takeIf { it>0 }.let { it ?: now() },"page" to args["page"],"turnAt" to args["turn_at"],"finished" to args["finished"],"released" to args["released"])
            when (op) {
                "sync.verify.next" -> return a.nextSyncVerification(owner,document)
                "sync.verify.result" -> {
                    a.syncVerification(owner,document,args["key"] as? String ?: throw IllegalArgumentException("key"),args["valid"]==true,(args["page"] as? Number)?.toInt())
                    return mapOf("ok" to true)
                }
                "sync.capture", "sync.override" -> {
                    requireNotNull(capture)
                    rec["local"]=local
                    if (op=="sync.override") { rec["override"]=local; rec.remove("declinedAt"); rec.remove("declinedReset") }
                    // Durable before any transport, also while offline. Sidecar work is done by the adapter.
                    journal.enqueue(a.id,owner,document,capture.second)
                    save(a,document,rec)
                    if (args["online"]==false) return mapOf("queued" to true,"document" to document)
                    return pull(a,document,rec)+mapOf("queued" to true)
                }
                "sync.pull" -> { rec["local"]=local; save(a,document,rec); return pull(a,document,rec) }
                "sync.decide" -> return decide(a,document,rec,args)
                "sync.answer" -> {
                    val remote=map(rec["remote"])
                    if (args["token"]!=rec["token"]) return mapOf("stale" to true)
                    if (args["yes"]==true) {
                        rec["allowPush"]=false; rec["policyToken"]=rec["token"]
                        rec["marker"]=remote; rec.remove("pending")
                    } else {
                        rec["allowPush"]=false; rec["policyToken"]=rec["token"]
                        rec["declinedAt"]=remote["at"]; rec["declinedReset"]=remote["reset"]==true
                        rec.remove("pending")
                    }
                    save(a,document,rec)
                    return mapOf("move" to (args["yes"]==true),"remote" to remote,"token" to rec["token"])
                }
                else -> throw IllegalArgumentException("sync operation")
            }
        } finally { log("sync.owner.$op ms=${(System.nanoTime()-started)/1_000_000}") }
    }
    private fun pull(a: ServerAdapter, document: String, rec: MutableMap<String,Any?>): Map<String,Any?> {
        val reply=a.position(document)
        (reply["error"] as? String)?.let { throw ServerFailure(it) }
        val remote=mapOf("percentage" to reply["percentage"],"position" to reply["position"],"at" to reply["timestamp"],
            "reset" to (reply["reset"]==true),"web" to (reply["web"]==true),"label" to reply["label"]).filterValues { it!=null }
        if (remote["reset"]!=true) rec.remove("declinedReset")
        if (map(rec["remote"])!=remote) rec["token"]=java.util.UUID.randomUUID().toString()
        rec["remote"]=remote
        save(a,document,rec)
        return mapOf("document" to document,"snapshot" to projection(document,scope(a),rec))
    }
    /** Read-only preview runs on an immutable publication: no SQL, network, writes or worker wait.
     * It is the only synchronous bridge, allowing an already-known move before the first draw. */
    fun preview(adapter: String, owner: String?, args: Map<*, *>): Map<String,Any?> {
        val rec=previews[adapter+"|"+owner+"|"+args["path"]] ?: return mapOf("pending" to true)
        if (args["token"]!=rec["token"]) return mapOf("stale" to true)
        val out=decision(rec,args)
        return mapOf("decision" to out.decision,"applied" to PositionPolicy.apply(out.decision,"prerender"),"remote" to rec["remote"],"token" to rec["token"],"document" to rec["document"])
    }
    private fun decision(rec: Map<String,Any?>, args: Map<*, *>): PositionPolicy.Decision {
        val remote=map(rec["remote"]); val marker=map(rec["marker"]); val local=map(rec["local"])
        val percentOnly=args["percent_only"]==true
        return PositionPolicy.decide(PositionPolicy.Input(number(args["page"]) ?: 0.0,number(args["remote_page"]),
            number(args["tolerance"]) ?: 1.0,time(remote["at"]),
            number(args["marker_page"])?.let { PositionPolicy.Marker(time(marker["at"]),it) },
            time(args["turn_at"] ?: local["turnAt"]),remote["reset"]==true,
            remote["web"]==true && args["same_chapter"]==true && (number(args["remote_page"]) ?: 0.0)-(number(args["marker_page"]) ?: 0.0)<=1,
            args["finished"]==true,args["released"]==true,
            if (remote["reset"]==true && rec["declinedReset"]==true) time(remote["at"]) else time(rec["declinedAt"]),
            map(rec["override"])["at"]?.let(::time),percentOnly))
    }
    private fun decide(a: ServerAdapter, document: String, rec: MutableMap<String,Any?>, args: Map<*, *>): Map<String,Any?> {
        if (args["token"]!=rec["token"]) return mapOf("stale" to true)
        val out=decision(rec,args); val moment=args["moment"] as? String ?: "reading"
        if (out.dropped) rec.remove("override")
        if (out.rule=="rule7" && out.decision=="push") rec["rereadAt"]=map(rec["remote"])["at"]
        if (out.decision=="same") { rec["marker"]=rec["remote"]; rec.remove("pending") }
        val applied=PositionPolicy.apply(out.decision,if(moment=="wake-local") "wake" else moment)
        if (applied=="wake") rec["pending"]=true
        rec["allowPush"]=out.decision in setOf("push","override")
        rec["policyToken"]=rec["token"]
        save(a,document,rec)
        val result=mapOf("decision" to out.decision,"applied" to applied,"remote" to rec["remote"],"token" to rec["token"],"document" to document)
        return result+if(moment=="wake-local") emptyMap() else drain(a)
    }
    fun drain(a: ServerAdapter): Map<String,Any?> {
        val started=System.nanoTime()
        try { return drainWindow(a,started) }
        finally { log("sync.owner.drain ms=${(System.nanoTime()-started)/1_000_000}") }
    }
    private fun drainWindow(a: ServerAdapter, started: Long): Map<String,Any?> {
        ensure(); val owner=scope(a)
        var error: String?=null
        for (entry in journal.window(a.id,owner)) {
            if (entry.source!=null && !entry.retired) continue
            var checkpoint=entry.checkpoint
            try { pull(a,entry.document,record(a,entry.document).toMutableMap()) }
            catch(e: ServerFailure) { error=e.kind; break }
            for (phase in LifecycleQueue.PHASES) {
                if((System.nanoTime()-started)/1_000_000>20000) { error="retryable"; break }
                if (phase in entry.acknowledged) continue
                try {
                    check(a.positionOwner()==owner)
                    if (phase=="progress") {
                        val rec=record(a,entry.document)
                        val remote=map(rec["remote"])
                        val capture=a.lifecyclePosition(entry.payload)
                        val override=map(rec["override"])
                        val remoteFraction=number(remote["percentage"])
                        val staleOverride=override.isNotEmpty() && time(remote["at"])>time(override["at"]) && time(remote["at"])!=time(map(rec["marker"])["at"])
                        if (staleOverride) { val changed=rec.toMutableMap(); changed.remove("override"); save(a,entry.document,changed) }
                        val fraction=if(staleOverride) capture.percentage else number(override["percentage"]) ?: capture.percentage
                        val exempt=override.isNotEmpty() && !staleOverride || rec["rereadAt"]==remote["at"] && remote["at"]!=null
                        val fallback=PositionPolicy.decide(PositionPolicy.Input((fraction ?: 0.0)*100,remoteFraction?.times(100),1.0,
                            time(remote["at"]),number(map(rec["marker"])["percentage"])?.let { PositionPolicy.Marker(time(map(rec["marker"])["at"]),it*100) },
                            time(map(rec["local"])["turnAt"]),remote["reset"]==true,finished=capture.finished,released=exempt,
                            overrideAt=if(exempt) time(override["at"]) else null,percentOnly=true))
                        val allowed=if(rec["policyToken"]==rec["token"] && number(map(rec["local"])["percentage"])==fraction) rec["allowPush"]==true
                            else fallback.decision in setOf("push","override")
                        val olderThanOverride=capture.capturedAt<time(rec["lastOverrideAt"])
                        if (olderThanOverride || !allowed || !PositionPolicy.mayPush(fraction?.times(100),remoteFraction?.times(100),1.0,exempt)) {
                            journal.acknowledge(entry.id,phase,checkpoint); continue
                        }
                        if (fraction!=null) {
                            val chosen=if(override.isNotEmpty() && exempt) override["position"] else capture.position
                            val sent=a.position(entry.document,mapOf("percentage" to fraction,"position" to chosen,"capturedAt" to (if (override.isNotEmpty() && exempt) override["at"] else capture.capturedAt)))
                            (sent["error"] as? String)?.let { throw ServerFailure(it) }
                            val changed=record(a,entry.document).toMutableMap()
                            if(override.isNotEmpty() && exempt) changed["lastOverrideAt"]=override["at"]
                            changed.remove("override"); changed.remove("rereadAt")
                            changed["marker"]=mapOf("at" to (sent["timestamp"] ?: now()),"percentage" to fraction,"position" to chosen)
                            save(a,entry.document,changed)
                        }
                        journal.acknowledge(entry.id,phase,checkpoint)
                    } else {
                        val result=a.lifecyclePhase(entry,phase,checkpoint,openPath)
                        checkpoint=result.checkpoint
                        if (result.complete) journal.acknowledge(entry.id,phase,checkpoint) else journal.checkpoint(entry.id,checkpoint)
                    }
                } catch (e: ServerFailure) { error=e.kind; break }
                catch (_: Exception) { error="unavailable"; break }
            }
            if (error!=null) break
            val current=journal.window(a.id,owner).firstOrNull { it.id==entry.id }
            if (current!=null && current.acknowledged.size==LifecycleQueue.PHASES.size && a.lifecycleComplete(current.checkpoint)) journal.finish(entry.id)
        }
        return mapOf("remaining" to journal.pending(a.id,owner),"error" to error)
    }
}
