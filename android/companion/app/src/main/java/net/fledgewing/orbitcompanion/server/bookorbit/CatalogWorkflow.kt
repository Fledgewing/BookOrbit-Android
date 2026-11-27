// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import java.io.File
import java.security.MessageDigest

internal data class CatalogStatusOverride(val status:String,val pending:Boolean)

/** Catalog actions share CacheWorker's sole writer. Queue files are account scoped and survive
 * cache resets. No lifecycle/position queue is drained or rewritten here. */
internal class CatalogWorkflow(private val worker: CacheWorker, private val creds: CacheWorker.Creds,
    private val owner: String, private val transport: BookOrbitServerAdapter.ConnectorTransport,
    private val reading: () -> Boolean = { false }, private val current: () -> Boolean = { true },
    private val checkpoint: () -> Unit = {}, private val now: () -> Long = { System.currentTimeMillis()/1000 },
    private val retainPartial:()->Boolean = { false }, private val staging:String?=null) {
    private val store get()=worker.store
    private val file=File(worker.root,"workflows/${BookOrbitLibrary.namespace(owner)}.lua")
    private val state=load(file).toMutableMap()
    private val jobs=(state["finishes"] as? Map<*,*>).orEmpty().entries.associate { it.key.toString() to (it.value as Map<*,*>).toMutableMap() }.toMutableMap()
    private val copies=(state["copies"] as? List<*>).orEmpty().mapNotNull { it as? Map<*,*> }.toMutableList()
    private val downloads=(state["downloads"] as? Map<*,*>).orEmpty().toMutableMap()
    private val statusUndo=(state["status_undo"] as? Map<*,*>).orEmpty().toMutableMap()
    private fun check() { if(!current() || store.meta("owner")!=owner) throw ServerFailure("canceled") }
    private fun save() {
        check(); state["finishes"]=jobs;state["copies"]=copies;state["downloads"]=downloads;state["status_undo"]=statusUndo
        file.parentFile?.mkdirs(); val tmp=File(file.path+".new")
        tmp.outputStream().use { it.write(LuaValue.encode(state)); it.fd.sync() }
        check(); check(tmp.renameTo(file))
    }
    private fun request(path:String,method:String="GET",body:Map<String,Any?>?=null):Map<*,*> {
        checkpoint();check()
        val r=transport.request(creds.server,path,method,body,mapOf("Accept" to "application/json","x-auth-user" to creds.user,"x-auth-key" to creds.key))
        if(r.code !in 200..299) throw HttpFailure(r.code)
        return r.value as? Map<*,*> ?: emptyMap<Any,Any>()
    }
    private class HttpFailure(val code:Int):Exception()
    private fun number(v:Any?)=(v as? Number)?.toLong() ?: (v as? String)?.toLongOrNull()
    private fun id(args:Map<*,*>):Long? = BookOrbitLibrary.id(owner,"book",args["key"])
        ?: number(args["reference"])?.takeIf { it>0 }
        ?: (args["path"] as? String)?.let { p -> ledger().firstOrNull { it["path"]==p }?.get("book_id") }?.let(::number)
    private fun settings():Map<*,*> {
        val f=File(worker.root.parentFile?.parentFile,"settings.reader.lua")
        if(!f.isFile || f.length()>4194304) return emptyMap<Any,Any>()
        return StatusMarginRepair.literalTable(f.readText(Charsets.ISO_8859_1),"bookorbit")?.let {
            LuaValue.parse(it.toByteArray(Charsets.ISO_8859_1)) as? Map<*,*>
        }.orEmpty()
    }
    private fun delivery():Map<String,String> {
        val preferences=settings()
        val key=LuaValue.str(creds.server)+"|"+LuaValue.str(creds.user)
        val remote=(preferences["catalog_delivery_server_profiles"] as? Map<*,*>)?.get(key) as? String
        val legacy=(preferences["catalog_delivery_profiles"] as? Map<*,*>)?.get(key)
        val variant=remote?.takeIf { it in setOf("original","audioless_epub") } ?: if(legacy=="original") "original" else "audioless_epub"
        val device=globalSetting("device_id") as? String
        return mapOf("variant" to variant)+(device?.let { mapOf("deviceId" to it) } ?: emptyMap())
    }
    private fun globalSetting(key:String):Any? {
        val f=File(worker.root.parentFile?.parentFile,"settings.reader.lua")
        if(!f.isFile || f.length()>4194304) return null
        // Settings contains executable headers in some KOReader versions. Parse literals only.
        val text=f.readText(Charsets.ISO_8859_1)
        val field=Regex("\\[\\s*[\"']"+Regex.escape(key)+"[\"']\\s*]\\s*=\\s*(\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*')").find(text)?.groupValues?.get(1) ?: return null
        return LuaValue.parse(("return {value="+field+"}").toByteArray(Charsets.ISO_8859_1)).let { (it as? Map<*,*>)?.get("value") }
    }

    private fun detail(id:Long,variant:String?=null):Map<*,*> {
        val raw=request("/koreader/plugin/catalog/books/$id?"+MirrorLogic.encQuery(delivery()+(variant?.let { mapOf("variant" to it) } ?: emptyMap())))
        require(number(raw["id"])==id);store.putDetail(id,raw,now());return raw
    }
    /** Reads the account's persisted native state on the worker; never asks Lua to scan it. */
    private fun ledger():List<Map<*,*>> {
        val nativeOwner=LuaValue.str(creds.server.trimEnd('/'))+"|"+LuaValue.str(creds.user)
        val dir=worker.root.parentFile
        val legacy=File(dir,"bookorbit_sync_state.lua")
        val primary=load(legacy)
        val native=if(primary["account_identity"]==nativeOwner) primary else {
            val hash=MessageDigest.getInstance("MD5").digest(nativeOwner.toByteArray(Charsets.ISO_8859_1)).joinToString("") { "%02x".format(it) }
            load(File(dir,"bookorbit_sync_state_$hash.lua" ))
        }
        val loaded=(native["books"] as? Map<*,*>)?.mapNotNull { (hash,value) ->
            val b=value as? Map<*,*> ?: return@mapNotNull null
            val path=b["file"] as? String ?: return@mapNotNull null
            if(b["bookId"]==null) return@mapNotNull null
            mapOf("md5" to hash,"path" to path,"book_id" to b["bookId"],"file_id" to b["fileId"],"incompatible" to b["positionIncompatible"])
        }
        val ask=load(File(worker.root,"copies/ask.lua"))
        val previous=if(ask["owner"]==owner) (ask["books"] as? List<*>).orEmpty().mapNotNull { it as? Map<*,*> } else emptyList()
        val books=(loaded ?: previous).toMutableList()
        for(row in previous) {
            if(row["awaiting_native"]!=true && row["owned_sync"]!=true) continue
            val path=row["path"] as? String ?: continue
            if(row["owned_sync"]!=true && books.any { it["path"]==path && it["md5"]==row["md5"] && it["book_id"]==row["book_id"] && it["awaiting_native"]!=true }) continue
            if(!File(LuaValue.utf8(path)).isFile) continue
            books.removeAll { it["path"]==path };books.add(row)
            if(row["awaiting_native"]==true) worker.event(mapOf("kind" to "download.saved","owner" to owner,"path" to path,"document" to row["md5"],"reference" to row["book_id"],"file_reference" to row["file_id"]))
        }
        val dest=File(worker.root,"copies/ask.lua");dest.parentFile?.mkdirs()
        val tmp=File(dest.path+".new");tmp.writeBytes(LuaValue.encode(mapOf("owner" to owner,"books" to books)));check(tmp.renameTo(dest))
        return books
    }
    /** Checkpoint complete legacy queues before marking their sources imported. Sources remain
     * intact for recovery; the durable marker prevents retry resurrection after acknowledgement. */
    private fun migrate() {
        if(state["migrated"]==true) return
        val ask=load(File(worker.root,"copies/ask.lua"))
        val claim=File(worker.root,"workflows/legacy-owner.lua")
        val priorOwner=load(claim)["owner"]
        val sourceOwner=priorOwner ?: ask["owner"]
        if(sourceOwner!=null && sourceOwner!=owner) {
            // Preserve the source's owner even if this account refreshes the local file ledger.
            if(!claim.exists()) {
                claim.parentFile?.mkdirs();val tmp=File(claim.path+".new")
                tmp.outputStream().use { it.write(LuaValue.encode(mapOf("owner" to sourceOwner)));it.fd.sync() }
                check();check(tmp.renameTo(claim))
            }
            state["migrated"]=true;save();return
        }
        val legacy=load(File(worker.root,"plugin-state.lua"))
        for(raw in ((legacy["copies"] as? Map<*,*>)?.get("queue") as? List<*>).orEmpty()) {
            val job=raw as? Map<*,*> ?: continue
            if(copies.none { it["path"]==job["path"] }) copies.add(job)
        }
        val finish=load(File(worker.root.parentFile,"orbit-finish-queue.lua"))
        for((hash,raw) in (finish["jobs"] as? Map<*,*>).orEmpty()) {
            val j=raw as? Map<*,*> ?: continue
            jobs.putIfAbsent(hash.toString(),(j+mapOf("token" to (j["token"] ?: java.util.UUID.randomUUID().toString()))).toMutableMap())
        }
        downloads.putAll((finish["downloads"] as? Map<*,*>).orEmpty())
        // Claim the source for this account before publishing the migration marker. A crash
        // leaves the untouched source retryable by the same owner, never by another account.
        if(!claim.exists()) {
            claim.parentFile?.mkdirs();val tmp=File(claim.path+".new")
            tmp.outputStream().use { it.write(LuaValue.encode(mapOf("owner" to owner)));it.fd.sync() }
            check();check(tmp.renameTo(claim))
        }
        val details=load(File(worker.root.parentFile,"orbit-detail-cache.lua"))["books"] as? Map<*,*>
        for((key,value) in details.orEmpty()) {
            val id=number(key) ?: continue;val d=value as? Map<*,*> ?: continue
            val at=number(d["saved_at"]) ?: 0L
            if(CopiesLogic.newer(store.detail(id)?.let { CopiesLogic.Detail(null,it.second) },at)) store.putDetail(id,d,at)
        }
        state["migrated"]=true; save()
    }
    private val sidecars by lazy { ReaderSidecar(worker.root.parentFile!!,{ partial(it) },{ Places.inside(it,listOf(worker.root.parentFile!!.parentFile!!.parentFile!!))!=null }) }
    private fun statusMark(args:Map<*,*>,undo:Boolean):Map<String,Any?> {
        val book=id(args) ?: throw ServerFailure("missing")
        val before=(store.detail(book)?.first ?: store.bookItem(book)) as? Map<*,*> ?: throw ServerFailure("missing")
        val prior=statusUndo[book.toString()] as? Map<*,*>
        if(undo && (prior==null || prior["token"]!=args["token"])) throw ServerFailure("stale")
        if(undo && jobs.values.none { it["token"]==args["token"] && it["ready"]==false }) throw ServerFailure("stale")
        val target=if(undo) prior!!["before_status"] as? String else when(args["status"]) { "finished"->"read";"unread"->"unread";else->null }
        require(target in setOf("unread","want_to_read","reading","on_hold","read","abandoned"))
        val previous=when(args["before_status"]) { "finished"->"read";"on-hold"->"on_hold";"rereading"->"reading";"unread","reading","abandoned"->args["before_status"] as String;else->before["readStatus"] as? String ?: "unread" }
        val local=ledger().firstOrNull { number(it["book_id"])==book && (it["path"] as? String)?.let { p -> File(LuaValue.utf8(p)).isFile }==true }
        val path=local?.get("path") as? String
        val file=path?.let(::bookFile)
        val hash=file?.let(::partial)
        val native=file?.let { sidecars.read(it) }
        val isOpen=path!=null && (args["open_path"] as? String)?.let { File(LuaValue.utf8(it)).canonicalFile==file?.canonicalFile }==true
        val oldSummary=(args["before_native"] as? Map<*,*>)?.takeIf { isOpen } ?: native?.get("summary") as? Map<*,*>
        if(undo && file!=null && native?.get("booksync_status_token")!=prior!!["token"] &&
            !(isOpen && args["native_token"]==prior["token"])) throw ServerFailure("stale")
        if(undo && file!=null && prior?.get("document")!=hash) throw ServerFailure("changed")
        val token=java.util.UUID.randomUUID().toString()
        val document=hash ?: "catalog:$book"
        val activeCapture=(args["native_capture"] as? Map<*,*>)?.takeIf { isOpen }
        val nativeSummary=if(undo) prior!!["before_native"] as? Map<*,*> else mapOf("status" to if(target=="read") "complete" else "new",
            "modified" to java.time.Instant.ofEpochSecond(now()).atZone(java.time.ZoneId.systemDefault()).toLocalDate().toString())
        val existing=jobs.values.firstOrNull { number(it["book_id"])==book }
        // An explicit newer mark replaces only this book's finish intent, retaining its rating.
        jobs.entries.removeAll { number(it.value["book_id"])==book }
        val job=mutableMapOf<Any?,Any?>("book_id" to book,"file" to path,"hash" to hash,"token" to token,"created_at" to now(),
            "ready" to undo,"manual_status" to target,"before_native" to oldSummary?.filterKeys { it in setOf("status","modified") },"native_token" to token,"captured" to (file==null),"position_done" to (file==null),"native_pending" to (file!=null),
            "native_summary" to nativeSummary,"rating" to existing?.get("rating"))
        if(file!=null) job["native_capture"]=activeCapture ?: mapOf("path" to path,"document" to hash,
            "percentage" to native?.get("percent_finished"),"position" to (native?.get("last_xpointer") ?: native?.get("last_page")),"summary" to oldSummary)
        jobs[document]=job
        state["status_sequence"]=(number(state["status_sequence"]) ?: 0L)+1
        statusUndo[book.toString()]=mapOf("sequence" to state["status_sequence"],"token" to token,"document" to hash,"before_status" to previous,"before_native" to oldSummary?.filterKeys { it in setOf("status","modified") },"after_status" to target)
        while(statusUndo.size>32) statusUndo.remove(statusUndo.entries.minByOrNull { number((it.value as? Map<*,*>)?.get("sequence")) ?: 0L }!!.key)
        save()
        applyStatusNative(job,args["open_path"] as? String)
        worker.patch(book,mapOf("readStatus" to target),true,false)
        worker.libraryReadModel().refreshLocalFiles(owner)
        return mapOf("ok" to true,"token" to token,"document" to document,"path" to path,"native_summary" to nativeSummary,"native_token" to token)
    }
    private fun applyStatusNative(job:MutableMap<Any?,Any?>,open:String?):Boolean {
        if(job["native_pending"]!=true) return true
        val path=job["file"] as? String ?: return true
        val file=bookFile(path)
        if(open!=null && file.canonicalFile==File(LuaValue.utf8(open)).canonicalFile) return false
        if(!file.isFile) { job["native_pending"]=false;save();return true }
        if(!partial(file).equals(job["hash"] as? String,true)) throw ServerFailure("changed")
        val data=sidecars.read(file)
        val summary=(data["summary"] as? Map<*,*>).orEmpty().filterKeys { it !in setOf("status","modified") }+(job["native_summary"] as? Map<*,*>).orEmpty()
        sidecars.write(file,data+mapOf("summary" to summary,"booksync_status_token" to (job["native_token"] ?: job["token"])))
        job["native_pending"]=false;save();return true
    }
    private fun statusCapture(open:String?):Map<String,Any?> {
        val manual=jobs.values.filter { it["manual_status"]!=null && it["ready"]==true && it["phase"]!="writeback" }
        for(job in manual) {
            if(job["captured"]==true) continue
            val path=job["file"] as? String ?: continue
            val native=job["native_capture"] as? Map<*,*>
            val applied=applyStatusNative(job,open)
            if(!applied && native==null) continue
            val data=sidecars.read(bookFile(path))
            val capture=(native?.entries?.associate { it.key.toString() to it.value } ?: mapOf("path" to path,"document" to job["hash"],
                "percentage" to data["percent_finished"],"position" to (data["last_xpointer"] ?: data["last_page"]),
                "summary" to ((data["summary"] as? Map<*,*>).orEmpty().filterKeys { it !in setOf("status","modified") }+(job["native_summary"] as? Map<*,*>).orEmpty())))+mapOf("summary" to ((data["summary"] as? Map<*,*>).orEmpty().filterKeys { it !in setOf("status","modified") }+(job["native_summary"] as? Map<*,*>).orEmpty()),"native_status_token" to (job["native_token"] ?: job["token"]),"current" to false,"online" to false,"captured_at" to now())
            return mapOf("has_status" to true,"token" to job["token"],"capture" to capture)
        }
        return mapOf("has_status" to manual.isNotEmpty())
    }
    fun command(action:String,args:Map<*,*>):Map<String,Any?> = try { execute(action,args) }
    catch(e:HttpFailure) { throw ServerFailure(when(e.code) {401,403->"unauthorized";404->"missing";0->"offline";else->"retryable"}) }
    private fun execute(action:String,args:Map<*,*>):Map<String,Any?> {
        check(); migrate()
        val path=args["path"] as? String
        val hash=args["document"] as? String
        when(action) {
            "status.mark" -> return statusMark(args,false)
            "status.undo" -> return statusMark(args,true)
            "status.leave" -> {
                val j=jobs.values.firstOrNull { it["manual_status"]!=null && it["token"]==args["token"] } ?: return mapOf("error" to "stale")
                if(j["ready"]!=true) { j["ready"]=true;j["native_token"]=java.util.UUID.randomUUID().toString();j["native_pending"]=j["file"]!=null;j["native_notified"]=false;save() }
                applyStatusNative(j,args["open_path"] as? String)
                return mapOf("ok" to true,"native_token" to j["native_token"],"path" to j["file"])
            }
            "status.capture" -> return statusCapture(args["open_path"] as? String)
            "status.positioned" -> {
                val j=jobs.values.firstOrNull { it["token"]==args["token"] } ?: return mapOf("missing" to true)
                j["position_done"]=true;save();return mapOf("ok" to true)
            }
            "status.captured" -> { jobs.values.filter { it["token"]==args["token"] }.forEach { it["captured"]=true };save() }
            "copies.check" -> if(args["enabled"]!=false && !reading()) checkCopies(args["open_path"] as? String)
            "copies.ack" -> {
                copies.removeAll { it["token"]==args["token"] && it["phase"]=="identity" };save()
            }
            "finish.mark" -> {
                require(hash!=null && Regex("[a-fA-F0-9]{32}").matches(hash))
                if(args["complete"]==true) {
                    val book=id(args)
                    val status=(book?.let { store.detail(it)?.first } as? Map<*,*>)?.get("readStatus")
                    jobs[hash]=mutableMapOf("hash" to hash,"book_id" to book,"file" to path,"ready" to false,
                        "token" to java.util.UUID.randomUUID().toString(),"created_at" to now(),"finished_on" to java.time.Instant.ofEpochSecond(now()).atZone(java.time.ZoneId.systemDefault()).toLocalDate().toString(),
                        "final_pos" to mapOf("percentage" to args["percentage"]),"status_seen" to status,"rating" to jobs[hash]?.get("rating"))
                } else jobs.remove(hash)
                save()
                id(args)?.let { book -> worker.patch(book,mapOf("readStatus" to if(args["complete"]==true) "read" else "reading",
                    "progressPercentage" to ((args["percentage"] as? Number)?.toDouble()?.times(100))),true,false) }
            }
            "finish.rate" -> { jobs[hash]?.set("rating", args["rating"] ?: "clear"); save() }
            "finish.leave" -> { if(jobs[hash]?.get("manual_status")==null) jobs[hash]?.set("ready",true); save() }
            "finish.validate" -> return mapOf("apply" to (jobs[hash]?.get("phase")=="writeback" && jobs[hash]?.get("token")==args["token"]))
            "finish.ack" -> {
                val j=jobs[hash]
                if(j?.get("phase")=="writeback" && j["token"]==args["token"]) {
                    if(j["manual_status"]!=null && !applyStatusNative(j,args["open_path"] as? String)) {
                        j["native_notified"]=true;save();return mapOf("ok" to true,"retained" to true)
                    }
                    jobs.remove(hash)
                }
                save()
            }
            "finish.drain" -> if(!reading()) { drain(args["manual"]==true,args["open_path"] as? String); pendingDownloads() }
            "download.prepare" -> return downloadOptions(args)
            "series.choices" -> {
                val books=(args["items"] as? List<*>) ?: throw ServerFailure("invalid")
                require(books.size in 1..10)
                val selected=(args["choices"] as? Map<*,*>).orEmpty()
                return mapOf("items" to books.map { raw ->
                    val b=raw as Map<*,*>;val key=b["key"] as? String ?: throw ServerFailure("invalid")
                    val options=downloadOptions(mapOf("key" to key,"root" to args["root"]),cachedOnly=true)["items"] as List<*>
                    val wanted=selected[key] as? Map<*,*>
                    val option=if(wanted==null) options.singleOrNull() as? Map<*,*> else options.map { it as Map<*,*> }.firstOrNull { number(it["file_reference"])==number(wanted["file_reference"]) && it["variant"]==wanted["variant"] }
                    if(option==null && options.isNotEmpty()) throw ServerFailure("changed")
                    if(option==null) mapOf("key" to key,"title" to b["title"],"failure" to "unsupported")
                    else option.entries.associate { it.key.toString() to it.value }+mapOf("key" to key,"title" to b["title"],"root" to args["root"])
                })
            }
            "finish.download" -> {
                val book=id(args) ?: throw ServerFailure("missing")
                if(args["later"]==true) { downloads[book.toString()]=mapOf("book_id" to book);save() }
                else {
                    val target=args["destination"] as? String
                    var selected=if(args["file_reference"]!=null) { val wanted=args["file_reference"];CopiesLogic.pick((detail(book,args["variant"] as? String)["files"] as? List<*>).orEmpty(),wanted)?.takeIf { number(it["id"])==number(wanted) } ?: throw ServerFailure("missing") } else null
                    if(args["variant"]!=null) {
                        val variant=args["variant"] as? String
                        require(variant in setOf("original","audioless_epub"))
                        selected=selected?.plus(mapOf("downloadVariant" to variant))
                    }
                    return mapOf("local_path" to download(book,target,selected,catalog=true,root=args["root"] as? String))
                }
            }
            "local.observe" -> {
                val book=number(args["reference"]) ?: throw ServerFailure("missing")
                require(path!=null && hash!=null && Regex("[a-fA-F0-9]{32}").matches(hash))
                if(bookFile(path).isFile) recordLocal(book,args["file_reference"],path,hash,ownedSync=true)
            }
            "finish.prepare" -> {
                val book=id(args)
                if(args["local_only"]!=true && !reading()) book?.let { detail(it) }
                return mapOf("key" to book?.let { BookOrbitLibrary.key(owner,"book",it) },"reference" to book,"document" to hash,"path" to path,"owner" to owner,"row_count" to 1)
            }
            "initialize" -> {
                ledger()
                // A restarted reader no longer has the user-opened Undo control.
                for(j in jobs.values) if(j["manual_status"]!=null && j["ready"]==false) {
                    j["ready"]=true;j["native_token"]=java.util.UUID.randomUUID().toString();j["native_pending"]=j["file"]!=null;j["native_notified"]=false
                }
                save()
            }
            else -> throw ServerFailure("unsupported")
        }
        worker.libraryReadModel().refreshReadingIntents(owner)
        return mapOf("ok" to true,"status_pending" to jobs.values.any { it["manual_status"]!=null && it["ready"]==true && it["parked"]!=true })
    }
    private fun checkCopies(open:String?) {
        val books=ledger()
        for(job in worker.changedCopies(books).found) if(copies.none { it["path"]==job["path"] }) copies.add(job)
        save()
        for(job in copies.toList()) {
            checkpoint();check(); if(reading()) break
            if(job["phase"]=="identity") { copyEvent(job);continue }
            if(job["phase"]=="transfer") {
                val path=job["path"] as? String ?: continue
                if(path==open) continue
                if(runCatching { partial(bookFile(path))==job["new"] }.getOrDefault(false)) {
                    val landed=job+mapOf("phase" to "identity");copies[copies.indexOf(job)]=landed;save();copyEvent(landed);continue
                }
            }
            val path=job["path"] as? String ?: continue
            if(path==open) continue
            try {
                val before=(job["old"] as? String) ?: partial(bookFile(path))
                val book=number(job["book_id"]) ?: continue
                val d=detail(book)
                val f=CopiesLogic.pick((d["files"] as? List<*>).orEmpty(),job["file_id"]) ?: continue
                if(CopiesLogic.decide(before,f)!="replace") { copies.remove(job);save();continue }
                // Save replacement identity before changing bytes. A crash after rename can
                // finish identity repair from this checkpoint without downloading again.
                val token=java.util.UUID.randomUUID().toString()
                val prepared=job+mapOf("token" to token,"old" to before,"new" to f["fileHash"],"file_id" to f["id"],"phase" to "transfer")
                copies[copies.indexOf(job)]=prepared;save()
                download(book,path,f)
                val landed=prepared+mapOf("phase" to "identity")
                copies[copies.indexOf(prepared)]=landed;save()
                copyEvent(landed)
            } catch(_:Exception) { /* durable retry; the old file remains until verified rename */ }
        }
    }
    private fun repair(job:Map<*,*>) {
        val old=job["old"] as? String ?: return;val new=job["new"] as? String ?: return
        HashSidecar.carry(File(worker.root.parentFile?.parentFile,"hashdocsettings"),old,new,checkpoint)
        worker.carryCopySettings(job["path"] as String,old,new)
    }
    private fun copyEvent(job:Map<*,*>) {
        repair(job)
        val book=number(job["book_id"]) ?: throw ServerFailure("missing")
        val path=job["path"] as String;val hash=job["new"] as String
        recordLocal(book,job["file_id"],path,hash)
        worker.event(mapOf("kind" to "copy.identity","owner" to owner,"path" to path,"before" to job["old"],"after" to hash,
            "reference" to book,"file_reference" to job["file_id"],"token" to job["token"]))
    }
    private fun downloadDirectory(requested:String?=null):File {
        val external=worker.root.parentFile?.parentFile?.parentFile ?: throw ServerFailure("forbidden")
        val path=requested ?: (globalSetting("download_dir") ?: globalSetting("home_dir") ?: globalSetting("lastdir")) as? String
        val directory=path?.let { File(LuaValue.utf8(it)) } ?: File(external,"books")
        require(Places.inside(directory,listOf(external))!=null)
        return directory
    }
    private fun destination(book:Long,f:Map<*,*>,d:Map<*,*>,requested:String?=null):File {
        val external=worker.root.parentFile?.parentFile?.parentFile ?: throw ServerFailure("forbidden")
        val directory=downloadDirectory(requested)
        val relative=(f["devicePath"] as? String)?.let(LuaValue::utf8)
        require(relative==null || !relative.startsWith("/") && !relative.startsWith("\\") && !Regex("^[A-Za-z]:").containsMatchIn(relative))
        val devicePath=relative?.split('/','\\')?.filter { it.isNotEmpty() }
        require(devicePath==null || devicePath.all { it!="." && it!=".." && it.length<=255 })
        val title=(d["title"] as? String)?.let(LuaValue::utf8) ?: "book-$book"
        val authors=(d["authors"] as? List<*>)?.firstOrNull()?.toString()?.let(LuaValue::utf8)
        val filename=(title+(if(authors!=null) " - $authors" else "")).replace(Regex("[/:*?\"<>|\\\\]+")," ")
            .replace(Regex("\\s+")," ").trim().ifBlank { "book-$book" }+"."+(f["format"] as? String ?: "epub").lowercase()
        var destination=File(directory,devicePath?.joinToString("/") ?: filename)
        require(Places.inside(destination,listOf(external))!=null)
        val expected=f["fileHash"] as? String
        if(destination.isFile && !partial(destination).equals(expected,true)) {
            destination=File(destination.parentFile,destination.nameWithoutExtension+"-$book-"+(expected ?: "unknown").take(8)+"."+destination.extension)
            require(Places.inside(destination,listOf(external))!=null)
            if(destination.isFile && !partial(destination).equals(expected,true)) throw ServerFailure("exists")
        }
        return destination
    }
    private fun downloadOptions(args:Map<*,*>,cachedOnly:Boolean=false):Map<String,Any?> {
        val book=id(args) ?: throw ServerFailure("missing")
        val d=(store.detail(book)?.first as? Map<*,*>) ?: if(cachedOnly) throw ServerFailure("changed") else detail(book)
        val files=(d["files"] as? List<*>).orEmpty().mapNotNull { it as? Map<*,*> }.filter {
            CopiesLogic.pick(listOf(it),it["id"])!=null && (it["fileHash"] as? String)?.matches(Regex("[a-fA-F0-9]{32}"))==true
        }
        require(files.size<=8)
        val root=args["root"] as? String
        val rows=files.mapIndexed { index,f ->
            val target=destination(book,f,d,root)
            val format=(f["format"] as? String) ?: "File"
            val duplicate=files.count { it["format"]==f["format"] }>1
            mapOf("file_reference" to f["id"],"variant" to (f["downloadVariant"] ?: delivery()["variant"]),
                "label" to (format+if(duplicate) " · file ${index+1}" else ""),"bytes" to f["size"],
                "destination" to LuaValue.str(target.path),"destination_label" to LuaValue.boundedText(downloadDirectory(root).path,160))
        }
        return mapOf("items" to rows,"root" to LuaValue.str(downloadDirectory(root).path),"row_count" to rows.size)
    }
    private fun download(book:Long,target:String?,selected:Map<*,*>?=null,deferred:Boolean=false,catalog:Boolean=false,root:String?=null):String {
        val local=BookOrbitLibrary.localPaths(store,owner)?.get(book)
        if(target==null && local!=null) return local
        val d=if(selected==null) detail(book) else null
        val f=selected ?: CopiesLogic.pick((d?.get("files") as? List<*>).orEmpty(),null) ?: throw ServerFailure("missing")
        val expected=f["fileHash"] as? String ?: throw ServerFailure("invalid")
        require(Regex("[a-fA-F0-9]{32}").matches(expected))
        val destination=if(target!=null) bookFile(target) else destination(book,f,d.orEmpty(),root)
        if((target==null || catalog) && destination.isFile) {
            if(!partial(destination).equals(expected,true)) throw ServerFailure("exists")
            recordDownload(book,f,destination,expected,deferred,d?.get("title"))
            return LuaValue.str(destination.path)
        }
        require(staging==null || staging.matches(Regex("[a-f0-9-]{36}")))
        val part=File(destination.path+".booksync-part"+(staging?.let { ".$it" } ?: ""));destination.parentFile?.mkdirs()
        require(!java.nio.file.Files.isSymbolicLink(part.toPath()))
        val params=mapOf("variant" to (f["downloadVariant"] as? String ?: delivery()["variant"].orEmpty()),"selection" to (f["selection"] as? String ?: ""))
        try {
            checkpoint();check()
            val ok=transport.download(creds.server,"/koreader/plugin/catalog/files/${f["id"]}/download?"+MirrorLogic.encQuery(params),
                mapOf("x-auth-user" to creds.user,"x-auth-key" to creds.key,"Accept" to "application/octet-stream"),part)
            if(!ok || !part.isFile) throw ServerFailure("retryable")
            if(!partial(part).equals(expected,true)) {
                part.delete();File(part.path+".http-resume").delete();throw ServerFailure("invalid")
            }
            check(); if(reading() && target!=null) throw ServerFailure("reading")
            check(part.renameTo(destination))
            if(target==null || catalog) recordDownload(book,f,destination,expected,deferred,d?.get("title"))
            return LuaValue.str(destination.path)
        } finally { if(!retainPartial() || !part.isFile) { part.delete();File(part.path+".http-resume").delete() } }
    }
    private fun bookFile(path:String):File {
        val file=File(LuaValue.utf8(path))
        require(Places.inside(file,listOf(worker.root.parentFile!!.parentFile!!.parentFile!!))!=null)
        return file
    }
    private fun recordLocal(book:Long,fileReference:Any?,path:String,hash:String,ownedSync:Boolean=true) {
        check()
        val ask=load(File(worker.root,"copies/ask.lua"))
        val rows=if(ask["owner"]==owner) (ask["books"] as? List<*>).orEmpty().mapNotNull { it as? Map<*,*> } else emptyList()
        val kept=rows.filter { it["path"]!=path }+mapOf("md5" to hash,"path" to path,"book_id" to book,"file_id" to fileReference,"awaiting_native" to !ownedSync,"owned_sync" to ownedSync)
        val dest=File(worker.root,"copies/ask.lua");dest.parentFile?.mkdirs();val tmp=File(dest.path+".new")
        tmp.outputStream().use { it.write(LuaValue.encode(mapOf("owner" to owner,"books" to kept)));it.fd.sync() }
        check();check(tmp.renameTo(dest))
    }
    private fun recordDownload(book:Long,f:Map<*,*>,destination:File,hash:String,deferred:Boolean,title:Any?) {
        val path=LuaValue.str(destination.path)
        recordLocal(book,f["id"],path,hash)
        worker.libraryReadModel().refreshLocalFiles(owner)
        worker.libraryReadModel().refreshLocalFiles(DeviceLibrary.OWNER)
        worker.event(mapOf("kind" to "library_source","owner" to owner))
        worker.event(mapOf("kind" to "download.saved","owner" to owner,"path" to path,"document" to hash,"reference" to book,"file_reference" to f["id"],"deferred" to deferred,"title" to title))
    }
    private fun drain(manual:Boolean,open:String?) {
        for((hash,job) in jobs.entries.sortedBy { number(it.value["created_at"]) ?: 0L }) {
            check(); if(reading()) return
            if(job["manual_status"]!=null && (job["captured"]!=true || job["position_done"]!=true)) continue
            if(job["phase"]=="writeback") {
                if(job["manual_status"]!=null) applyStatusNative(job,open)
                if(job["native_pending"]!=true || job["native_notified"]!=true) finishEvent(hash,job)
                continue
            }
            if(job["ready"]!=true || !manual && (job["parked"]==true || (number(job["next_try_at"]) ?: 0L)>now())) continue
            try {
                val id=number(job["book_id"])
                if(id==null) { jobs.remove(hash);save();continue }
                val remote=detail(id)
                val target=job["manual_status"] as? String ?: "read"
                val write=job["manual_status"]!=null || FinishLogic.sendStatus(job["status_seen"],remote["readStatus"])
                if(write) request("/koreader/plugin/catalog/books/$id/read-status","PUT",mapOf("status" to target))
                if(job["rating"]!=null && (job["manual_status"]==null || job["manual_status"]=="read")) request("/koreader/plugin/catalog/books/$id/rating","PUT",mapOf("rating" to job["rating"].takeIf { it!="clear" }))
                job["phase"]="writeback";job["status_written"]=write
                if(job["manual_status"]!=null) {
                    val undo=statusUndo[id.toString()] as? Map<*,*>
                    if(undo?.get("token")==job["token"]) statusUndo[id.toString()]=undo!!+mapOf("blocked_generations" to listOfNotNull(store.meta("bulk_active"),store.meta("bulk_stage_g")).distinct())
                }
                save();finishEvent(hash,job)
            } catch(e:HttpFailure) {
                when(e.code) {
                    401 -> { if(job["manual_status"]!=null) { job["parked"]=true;save() };return }
                    400,403,404 -> { if(job["manual_status"]!=null) job["parked"]=true else jobs.remove(hash);save() }
                    else -> retry(job)
                }
            } catch(_:Exception) { retry(job) }
        }
    }
    private fun retry(job:MutableMap<Any?,Any?>) {
        val attempts=(number(job["attempts"]) ?: 0L)+1;job["attempts"]=attempts
        job["next_try_at"]=now()+minOf(3600,60L shl (attempts-1).coerceAtMost(6).toInt());job["parked"]=attempts>=5;save()
    }
    private fun finishEvent(hash:String,j:Map<*,*>) = worker.event(mapOf("kind" to "finish.applied","owner" to owner,"document" to hash,
        "token" to j["token"],"path" to j["file"],"native_summary" to j["native_summary"],"native_token" to j["native_token"],"complete" to j["status_written"],"date" to j["finished_on"],"rated" to (j["rating"]!=null),"rating" to j["rating"].takeIf { it!="clear" }))
    private fun pendingDownloads() {
        for((key,value) in downloads.toMap()) {
            if(reading()) return
            val id=number((value as? Map<*,*>)?.get("book_id")) ?: continue
            try { download(id,null,deferred=true);downloads.remove(key);save() } catch(_:Exception) { }
        }
    }
    companion object {
        internal fun statusOverrides(store:CacheStore,owner:String):Map<Long,CatalogStatusOverride> {
            val state=load(File(store.root,"workflows/${BookOrbitLibrary.namespace(owner)}.lua"))
            val generation=store.meta("bulk_active")
            val out=mutableMapOf<Long,CatalogStatusOverride>()
            for((id,raw) in (state["status_undo"] as? Map<*,*>).orEmpty()) {
                val row=raw as? Map<*,*> ?: continue
                val blocked=(row["blocked_generations"] as? List<*>).orEmpty()
                val target=row["after_status"] as? String ?: continue
                if(row.containsKey("blocked_generations") && (generation==null || generation in blocked)) id.toString().toLongOrNull()?.let { out[it]=CatalogStatusOverride(target,false) }
            }
            for(raw in (state["finishes"] as? Map<*,*>).orEmpty().values) {
                val row=raw as? Map<*,*> ?: continue
                val id=(row["book_id"] as? Number)?.toLong() ?: continue
                (row["manual_status"] as? String)?.let { out[id]=CatalogStatusOverride(it,row["phase"]!="writeback") }
            }
            return out
        }
        internal fun load(file:File):Map<*,*> {
            if(!file.isFile) return emptyMap<Any,Any>()
            require(file.length()<=16777216) { "workflow source exceeds import limit" }
            val parsed=LuaValue.parse(file.readBytes())
            require(parsed is Map<*,*> || parsed is List<*> && parsed.isEmpty()) { "invalid workflow source" }
            return (parsed as? Map<*,*>).orEmpty()
        }
        internal fun partial(file:File):String {
            val digest=MessageDigest.getInstance("MD5")
            java.io.RandomAccessFile(file,"r").use { input ->
                val bytes=ByteArray(1024)
                for(offset in listOf(0L)+(0..10).map { 1024L shl (2*it) }) {
                    input.seek(offset);val n=input.read(bytes);if(n<0) break;digest.update(bytes,0,n)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
    }
}
