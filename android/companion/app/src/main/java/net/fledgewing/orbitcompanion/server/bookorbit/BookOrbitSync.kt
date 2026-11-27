package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

/** The sync protocol's only transport owner. Source snapshots/checkpoints stay private here. */
internal class BookOrbitSync(private val settings: File,
    private val request: (String,Map<String,Any?>)->Map<*, *>,
    private val journal: Sql,
    private val openSql: (File)->Sql = { AndroidSql(it,readOnly=true) },
    private val allowed: (File)->Boolean = { Places.inside(it,Places.roots())!=null }) {
    private fun map(value: Any?) = (value as? Map<*, *>)?.entries?.associate { it.key.toString() to it.value }.orEmpty()
    private fun list(value: Any?) = value as? List<*> ?: emptyList<Any>()
    private fun text(value: Any?) = value as? String
    private fun bounded(value: Any?, bytes: Int): String? = (value as? String)?.let { LuaValue.boundedText(LuaValue.utf8(it),bytes) }
    private fun locator(value: Any?): String? = when(value) {
        is String -> value
        is Number -> value.toString()
        is Map<*, *> -> LuaValue.str(org.json.JSONObject(value).toString())
        else -> null
    }
    private fun md5(value: ByteArray) = MessageDigest.getInstance("MD5").digest(value).joinToString("") { "%02x".format(it) }
    private val hashes=mutableMapOf<String,String>()
    private val global=LegacyLifecycleImport.literal(File(settings.parentFile,"settings.reader.lua")).orEmpty()
    init {
        journal.exec("CREATE TABLE IF NOT EXISTS adapter_sync_books (owner TEXT NOT NULL,document TEXT NOT NULL,body BLOB NOT NULL,PRIMARY KEY(owner,document))")
        journal.exec("CREATE TABLE IF NOT EXISTS adapter_sync_verifications (owner TEXT NOT NULL,document TEXT NOT NULL,k TEXT NOT NULL,body BLOB NOT NULL,ready INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(owner,document,k))")
    }
    private fun file(snapshot: Map<*, *>) = (snapshot["file"] as? String)?.let { File(LuaValue.utf8(it)) }?.also {
        require(allowed(it)); (snapshot["digest"] as? String)?.let { hash -> hashes[it.path]=hash }
    }
    private val sidecars by lazy { ReaderSidecar(settings,{ hashes[it.path] },allowed) }
    private fun readSidecar(book:File)=sidecars.read(book)
    private fun writeSidecar(book:File,data:Map<String,Any?>)=sidecars.write(book,data)
    fun directions(): PositionDirections {
        val root=LegacyLifecycleImport.literal(File(settings.parentFile,"settings.reader.lua")).orEmpty()
        val owned=map(root["orbit_android"]); val legacy=map(root["bookorbit"])
        val saved=map(owned["osm_saved_plugin"])
        val source=if(legacy["sync_forward"]==3L && legacy["sync_backward"]==3L && saved.isNotEmpty()) saved else legacy
        fun strategy(key: String, fallback: String)=when((source[key] as? Number)?.toInt()) { 1->"ask"; 2->"follow"; 3->"keep"; else->fallback }
        return PositionDirections(owned["sync_mode"]!="custom",strategy("sync_forward","ask"),strategy("sync_backward","keep"))
    }
    fun capture(args: Map<*, *>): Pair<String,ByteArray> {
        val percentage=(args["percentage"] as? Number)?.toDouble()
        require(percentage==null || percentage.isFinite() && percentage in 0.0..1.0)
        val position=locator(args["position"])
        require(position==null || position.length<=4096)
        val book=File(LuaValue.utf8(args["path"] as? String ?: throw IllegalArgumentException("path")))
        require(allowed(book))
        val hash=MessageDigest.getInstance("MD5")
        if(book.isFile) RandomAccessFile(book,"r").use { input ->
            val bytes=ByteArray(1024)
            for (i in -1..10) { val offset=if(i<0) 0L else 1024L shl (2*i)
                input.seek(offset); val n=input.read(bytes); if(n<0) break; hash.update(bytes,0,n) }
        }
        val digest=if(book.isFile) hash.digest().joinToString("") { "%02x".format(it) }
            else (args["document"] as? String)?.takeIf { it.matches(Regex("[a-fA-F0-9]{32}")) } ?: throw ServerFailure("missing")
        hashes[book.path]=digest
        val data=readSidecar(book)
        var summary=map(data["summary"])+map(args["summary"])
        var nativeToken=args["native_status_token"] ?: data["booksync_status_token"]
        var manualStatusPending=false
        (args["catalog_owner"] as? String)?.let { owner ->
            val state=CatalogWorkflow.load(File(settings,"orbit-cache/workflows/${BookOrbitLibrary.namespace(owner)}.lua"))
            val manual=(state["finishes"] as? Map<*,*>).orEmpty().values.mapNotNull { it as? Map<*,*> }
                .firstOrNull { it["hash"]==digest && it["manual_status"]!=null }
            if(manual!=null) {
                manualStatusPending=true
                // Until the Undo control closes, background captures retain the previous status.
                val fields=map(manual[if(manual["ready"]==true) "native_summary" else "before_native"])
                summary=summary.filterKeys { it !in setOf("status","modified") }+fields
                nativeToken=manual["native_token"] ?: manual["token"]
            }
        }
        val statsId=(args["stats_id"] as? Number)?.toLong()
        val ids=if(statsId!=null) listOf(statsId) else if(File(settings,"statistics.sqlite3").isFile)
            openSql(File(settings,"statistics.sqlite3")).use { sql -> sql.query("SELECT id FROM book WHERE md5=?",digest) { it.long(0)!! } } else emptyList()
        val snapshot=mapOf("digest" to digest,"file" to LuaValue.str(book.path),"percentage" to percentage,
            "progress" to position,"status" to summary["status"],"status_modified" to summary["modified"],
            "rating" to (summary["rating"] as? Number)?.toInt()?.takeIf { it in 1..5 },"review_note" to bounded(summary["note"],10000),"ts" to args["captured_at"],
            "title" to (data["doc_props"] as? Map<*, *>)?.get("title"),"authors" to (data["doc_props"] as? Map<*, *>)?.get("authors"),
            "stats_ids" to ids,"annotations" to annotations(data,false),"bookmarks" to annotations(data,true),"native_capture" to true,"native_status_token" to nativeToken,"manual_status_pending" to manualStatusPending,
            "annotation_sync" to ((LegacyLifecycleImport.literal(File(settings.parentFile,"settings.reader.lua"))?.get("bookorbit") as? Map<*, *>)?.get("annotation_sync")!=false))
        return digest to LuaValue.encode(snapshot)
    }
    private fun annotations(data: Map<*, *>, bookmarks: Boolean): List<Map<String,Any?>> = list(data["annotations"]).mapNotNull { raw ->
        val a=map(raw); val date=(a["datetime"] as? String)?.takeIf { it.matches(Regex("\\d{4}-\\d\\d-\\d\\d \\d\\d:\\d\\d:\\d\\d")) } ?: return@mapNotNull null
        val start=a[if(bookmarks) "page" else "pos0"] ?: return@mapNotNull null
        if ((a["drawer"]==null)!=bookmarks) return@mapNotNull null
        if (a["bookorbit_pending_verification"]==true || a["booksync_pending_verification"]==true) return@mapNotNull null
        if (bookmarks && start !is String) return@mapNotNull null
        if (!bookmarks && locator(start)==null) return@mapNotNull null
        if (bookmarks) mapOf("datetime" to date,"datetimeUpdated" to a["datetime_updated"],"pos" to bounded(start,4000),
            "pageno" to a["pageno"],"chapter" to bounded(a["chapter"],500),"note" to bounded(a["note"],500))
        else mapOf("datetime" to date,"datetimeUpdated" to a["datetime_updated"],"pos0" to bounded(locator(start),4000),"pos1" to bounded(locator(a["pos1"]),4000),
            "posFormat" to if(start is String) "xpointer" else "page","drawer" to a["drawer"],"color" to a["color"],
            "text" to bounded(a["text"],10000),"note" to bounded(a["note"],5000),"chapter" to bounded(a["chapter"],500),"pageno" to a["pageno"])
    }
    private fun result(body: Map<*, *>, digest: String): Map<String,Any?> {
        if (digest in list(body["unmatched"])) throw ServerFailure("missing")
        if (digest in list(body["positionIncompatible"])) throw ServerFailure("incompatible")
        return map(list(body["results"]).firstOrNull())
    }
    private fun device(body: Map<String,Any?>) = body+mapOf("deviceId" to deviceId(),"deviceModel" to "BookSync",
        "deviceTime" to LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")))
    fun deviceId(): String {
        val path=File(settings,"booksync-sync-device")
        if(path.isFile) return path.readText().also { require(it.matches(Regex("[A-Za-z0-9-]{1,100}"))) }
        settings.mkdirs(); val id=(global["device_id"] as? String)?.takeIf { it.matches(Regex("[A-Za-z0-9-]{1,100}")) } ?: java.util.UUID.randomUUID().toString()
        val temp=File(settings,path.name+".tmp"); temp.writeText(id); check(temp.renameTo(path)); return id
    }
    fun phase(entry: LifecycleQueue.Entry, phase: String, encoded: ByteArray, openPath: String?): SyncPhaseResult {
        val snap=map(LuaValue.parse(entry.payload)); val checkpoint=map(LuaValue.parse(encoded)).toMutableMap()
        val book=file(snap); val isOpen=snap["file"]==openPath
        fun done(complete: Boolean=true) = SyncPhaseResult(LuaValue.encode(checkpoint),complete)
        when(phase) {
            "match" -> {
                val match=request("/koreader/plugin/match-check",device(mapOf("hashes" to listOf(entry.document),"books" to listOf(mapOf(
                    "hash" to entry.document,"title" to snap["title"],"authors" to snap["authors"],"lastOpen" to snap["last_open"],"source" to "current_file")))))
                val found=list(match["matches"]).map(::map).firstOrNull { it["hash"]==entry.document } ?: throw ServerFailure("missing")
                checkpoint["match"]=found
                return done()
            }
            "stats" -> {
                if (snap["stats_metadata_ambiguous"]==true) return done()
                val db=File(settings,"statistics.sqlite3"); if(!db.isFile) return done()
                val cursor=list(checkpoint["stats_cursor"]).map { (it as Number).toLong() }
                val at=cursor.getOrElse(0) { 0 }; val page=cursor.getOrElse(1) { -1 }; val row=cursor.getOrElse(2) { -1 }
                val captured=(snap["ts"] as? Number)?.toLong() ?: Long.MAX_VALUE
                val events=openSql(db).use { sql ->
                    val ids=list(snap["stats_ids"]).mapNotNull { (it as? Number)?.toLong() }.ifEmpty {
                        sql.query("SELECT id FROM book WHERE md5=?",entry.document) { it.long(0)!! }
                    }
                    if(ids.isEmpty()) emptyList() else {
                        val marks=ids.joinToString(",") { "?" }
                        sql.query("SELECT page,start_time,duration,total_pages,id_book FROM page_stat_data WHERE id_book IN ($marks) AND total_pages>0 AND start_time<=? AND (start_time>? OR (start_time=? AND page>?) OR (start_time=? AND page=? AND id_book>?)) ORDER BY start_time,page,id_book LIMIT 256",
                            *(ids+listOf(captured,at,at,page,at,page,row)).toTypedArray()) { r -> mapOf("page" to r.long(0),"startTime" to r.long(1),
                                "durationSeconds" to (r.long(2) ?: 0).coerceIn(0,86400),"totalPages" to r.long(3),"row" to r.long(4)) }
                    }
                }
                if(events.isEmpty()) return done()
                val upload=mutableMapOf<String,Any?>("hash" to entry.document,"events" to events.map { it-"row" })
                if(snap["stats_row_ambiguous"]==true) {
                    var match=map(checkpoint["match"])
                    if(match["bookFileId"]==null) {
                        val reply=request("/koreader/plugin/match-check",device(mapOf("hashes" to listOf(entry.document),"books" to listOf(mapOf("hash" to entry.document,"title" to snap["title"],"authors" to snap["authors"])))))
                        match=list(reply["matches"]).map(::map).firstOrNull { it["hash"]==entry.document } ?: throw ServerFailure("missing")
                        checkpoint["match"]=match
                    }
                    upload["bookFileId"]=match["bookFileId"] ?: throw ServerFailure("missing")
                }
                result(request("/koreader/plugin/page-stats",device(mapOf("books" to listOf(upload)))),entry.document)
                val last=events.last(); checkpoint["stats_cursor"]=listOf(last["startTime"],last["page"],last["row"])
                return done(events.size<256)
            }
            "annotations" -> {
                if(map(checkpoint["match"])["positionCompatible"]==false) return done()
                val pending=map(checkpoint["remote_pending"]).toMutableMap()
                val enabled=map(checkpoint["legacy"])["annotation_sync"]!=false && snap["annotation_sync"]!=false
                if(!enabled && pending["annotations"]==null && pending["bookmarks"]==null) return done()
                var incomplete=false
                if(!isOpen && book!=null && book.isFile) cleanVerified(entry.owner,entry.document,book)
                for ((kind,bookmark) in listOf("annotations" to false,"bookmarks" to true)) {
                    val key="exchange_$kind"
                    val progress=map(checkpoint[key]).toMutableMap()
                    if(progress["done"]==true && pending[kind]==null) continue
                    val existing=map(pending[kind])
                    if(existing.isNotEmpty()) {
                        if(book==null || !book.isFile || isOpen) { incomplete=true; continue }
                        val ack=applyRemote(entry,book,kind,map(existing["to_apply"]))
                        request("/koreader/plugin/$kind/exchange-ack",device(mapOf("books" to listOf(mapOf("hash" to entry.document)+ack))))
                        pending.remove(kind)
                        if(progress["done"]==true && existing["more"]!=true) { checkpoint[key]=progress; continue }
                    }
                    if(!enabled) continue // Complete imported pending applications, but do not restart disabled exchanges.
                    val changes=if(progress.containsKey("changes")) list(progress["changes"]).map(::map) else {
                        val captured=if(snap["native_capture"]==true && !isOpen && book!=null) annotations(readSidecar(book),bookmark) else list(snap[kind]).map(::map)
                        progress["changes"]=captured; captured
                    }
                    val cursor=(progress["cursor"] as? Number)?.toInt() ?: 0
                    val chunk=changes.drop(cursor).take(16)
                    // A historical queued snapshot never establishes absence/deletion of newer notes.
                    val completeKeys=snap["native_capture"]==true && !isOpen && book!=null && readSidecar(book)["booksync_sync_known"]==true
                    val keys=if(cursor==0 && completeKeys) changes.map { a -> mapOf("k" to md5(((a["datetime"] as String)+"|"+a[if(bookmark) "pos" else "pos0"]).toByteArray(Charsets.ISO_8859_1)),"dt" to a["datetime"]) } else emptyList()
                    val response=result(request("/koreader/plugin/$kind/exchange",device(mapOf("books" to listOf(mapOf("hash" to entry.document,
                        "keys" to keys,"keysComplete" to completeKeys,"changes" to chunk))))),entry.document)
                    val toApply=map(response["toApply"])
                    if(toApply.values.any { list(it).isNotEmpty() }) {
                        pending[kind]=mapOf("to_apply" to toApply,"more" to response["more"])
                        incomplete=true
                    }
                    progress["cursor"]=cursor+chunk.size
                    progress["done"]=cursor+chunk.size>=changes.size && response["more"]!=true
                    if(progress["done"]!=true) incomplete=true
                    checkpoint[key]=progress
                }
                checkpoint["remote_pending"]=pending
                if(enabled && !incomplete && !isOpen && book!=null && book.isFile) writeSidecar(book,readSidecar(book)+("booksync_sync_known" to true))
                return done(!incomplete)
            }
            "state" -> {
                val pending=map(checkpoint["remote_pending"]).toMutableMap()
                var state=map(pending["state"])
                if(state.isEmpty()) {
                    val known=journal.query("SELECT body FROM adapter_sync_books WHERE owner=? AND document=?",entry.owner,entry.document) { map(LuaValue.parse(it.bytes(0)!!)) }.firstOrNull().orEmpty()
                    val sent=mutableMapOf<String,Any?>("hash" to entry.document)
                    if(snap["status"]!=null && snap["manual_status_pending"]!=true) { sent["status"]=snap["status"]; if(snap["status_modified"]!=null) sent["statusModified"]=snap["status_modified"] }
                    if(snap["rating"]!=null) sent["rating"]=snap["rating"]
                    else if(known["ratingSyncedKnown"]==true && known["ratingSynced"]!=null) sent["ratingCleared"]=true
                    if(snap["review_note"]!=null) sent["reviewNote"]=snap["review_note"]
                    else if(known["reviewSyncedKnown"]==true && known["reviewSyncedNote"]!=null) sent["reviewCleared"]=true
                    if(snap["review_modified"]!=null || snap["status_modified"]!=null) sent["reviewModified"]=snap["review_modified"] ?: snap["status_modified"]
                    val reply=result(request("/koreader/plugin/book-states",device(mapOf("books" to listOf(sent)))),entry.document)
                    state=mapOf("status_known" to (reply["statusSet"]==true),"status" to reply["status"],"status_modified" to (reply["statusUpdatedAt"] as? String)?.take(10),
                        "rating_known" to (reply["ratingSet"] is Boolean),"rating" to reply["rating"].takeIf { reply["ratingSet"]==true },
                        "review_known" to (reply["reviewNoteSet"] is Boolean),"review_note" to reply["reviewNote"].takeIf { reply["reviewNoteSet"]==true })
                    if(state.values.all { it==null || it==false }) return done()
                    journal.exec("INSERT OR REPLACE INTO adapter_sync_books VALUES (?,?,?)",entry.owner,entry.document,LuaValue.encode(known+mapOf(
                        "ratingSyncedKnown" to state["rating_known"],"ratingSynced" to state["rating"],"reviewSyncedKnown" to state["review_known"],"reviewSyncedNote" to state["review_note"])))
                    pending["state"]=state; checkpoint["remote_pending"]=pending
                }
                if(book==null || !book.isFile || isOpen) return done(false)
                val data=readSidecar(book); val summary=map(data["summary"]).toMutableMap()
                // A late application from an older capture cannot replace a newer explicit mark/Undo.
                if(state["status_known"]==true && snap["manual_status_pending"]!=true && data["booksync_status_token"]==snap["native_status_token"]) {
                    summary["status"]=state["status"]; summary["modified"]=state["status_modified"]
                }
                if(state["rating_known"]==true) summary["rating"]=state["rating"]
                if(state["review_known"]==true) summary["note"]=state["review_note"]
                writeSidecar(book,data+("summary" to summary)); pending.remove("state"); checkpoint["remote_pending"]=pending
                return done()
            }
            else -> throw IllegalArgumentException("phase")
        }
    }
    fun nextVerification(owner: String, document: String): Map<String,Any?> {
        val found=journal.query("SELECT k,body FROM adapter_sync_verifications WHERE owner=? AND document=? AND ready=0 LIMIT 1",owner,document) {
            it.text(0)!! to map(LuaValue.parse(it.bytes(1)!!))
        }.firstOrNull() ?: return emptyMap()
        return mapOf("row" to mapOf("key" to found.first,"start" to found.second["pos0"],"end" to found.second["pos1"]))
    }
    fun verification(owner: String, document: String, key: String, valid: Boolean, page: Int?) {
        val raw=journal.query("SELECT body FROM adapter_sync_verifications WHERE owner=? AND document=? AND k=? AND ready=0",owner,document,key) { map(LuaValue.parse(it.bytes(0)!!)) }.firstOrNull() ?: return
        val ack=mapOf("serverId" to raw["serverId"],"version" to raw["version"],"status" to if(valid) "applied" else "failed",
            "verified" to valid,"pos0" to raw["pos0"],"pos1" to raw["pos1"],"pageno" to page,"datetimeUpdated" to raw["datetimeUpdated"])
        request("/koreader/plugin/annotations/exchange-ack",device(mapOf("books" to listOf(mapOf("hash" to document,"applied" to listOf(ack),"deleted" to emptyList<Any>())))))
        journal.exec("UPDATE adapter_sync_verifications SET ready=? WHERE owner=? AND document=? AND k=?",if(valid) 1 else 2,owner,document,key)
    }
    private fun cleanVerified(owner: String, document: String, book: File) {
        val keys=journal.query("SELECT k FROM adapter_sync_verifications WHERE owner=? AND document=? AND ready=1 LIMIT 1024",owner,document) { it.text(0)!! }.toSet()
        if(keys.isEmpty()) return
        val data=readSidecar(book)
        val annotations=list(data["annotations"]).map { a ->
            val row=map(a)
            if(row["booksync_verification"] in keys) row-filterOfPending else row
        }
        writeSidecar(book,data+("annotations" to annotations))
        for(key in keys) journal.exec("DELETE FROM adapter_sync_verifications WHERE owner=? AND document=? AND k=?",owner,document,key)
    }
    private val filterOfPending=setOf("booksync_verification","booksync_pending_verification","bookorbit_pending_verification")
    private fun applyRemote(job: LifecycleQueue.Entry, book: File, kind: String, changes: Map<String,Any?>): Map<String,Any?> {
        val data=readSidecar(book); val entries=list(data["annotations"]).map { map(it).toMutableMap() }.toMutableList()
        val applied=mutableListOf<Map<String,Any?>>()
        val deleted=mutableListOf<Map<String,Any?>>()
        val verification=mutableMapOf<String,Map<String,Any?>>()
        val bookmark=kind=="bookmarks"
        fun find(change: Map<String,Any?>) = entries.indexOfFirst { a ->
            val position=a[if(bookmark) "page" else "pos0"]
            (a["drawer"]==null)==bookmark && (a["booksync_remote_id"]==change["serverId"] && change["serverId"]!=null ||
                a["datetime"]==change["datetime"] && locator(position)==change[if(bookmark) "pos" else "pos0"] ||
                (change["key"] ?: change["k"])==md5(("${a["datetime"]}|${locator(position)}").toByteArray(Charsets.ISO_8859_1))) }
        for(op in listOf("add","edit","delete")) for(raw in list(changes[op])) {
            val change=map(raw); val index=find(change)
            if(op=="delete") { if(index>=0) entries.removeAt(index); deleted+=mapOf("serverId" to change["serverId"],"status" to "applied"); continue }
            val position=change[if(bookmark) "pos" else "pos0"]
            if(!bookmark && change["posFormat"]!="xpointer" && index<0) {
                applied+=mapOf("serverId" to change["serverId"],"version" to change["version"],"status" to "failed"); continue
            }
            val annotation=if(index>=0) entries[index] else mutableMapOf<String,Any?>().also { entries+=it }
            for(key in listOf("datetime","drawer","color","text","note","chapter","pageno","pos0","pos1")) if(change.containsKey(key) && !(key=="text" && change[key]=="")) annotation[key]=change[key]
            annotation["note"]=change["note"]
            if(change["datetimeUpdated"]!=null) annotation["datetime_updated"]=change["datetimeUpdated"]
            annotation["page"]=position; annotation["booksync_remote_id"]=change["serverId"]
            if(bookmark) { annotation.remove("drawer"); annotation["note"]=change["title"] ?: change["note"] }
            else {
                val key=md5("${job.owner}|${job.document}|${change["serverId"]}|${change["version"]}".toByteArray(Charsets.UTF_8))
                annotation["booksync_verification"]=key; annotation["booksync_pending_verification"]=true
                verification[key]=change
            }
            applied+=if(bookmark) mapOf("serverId" to change["serverId"],"status" to "applied","key" to md5(((annotation["datetime"] as? String ?: "")+"|"+position).toByteArray(Charsets.ISO_8859_1)),"datetime" to annotation["datetime"],"pos" to position)
                else mapOf("serverId" to change["serverId"],"version" to change["version"],"status" to "applied","verified" to false,"pos0" to position,"pos1" to change["pos1"],"datetimeUpdated" to change["datetimeUpdated"])
        }
        writeSidecar(book,data+mapOf("annotations" to entries,"annotations_externally_modified" to true))
        for((key,body) in verification) journal.exec("INSERT OR IGNORE INTO adapter_sync_verifications(owner,document,k,body) VALUES (?,?,?,?)",job.owner,job.document,key,LuaValue.encode(body))
        return mapOf("applied" to applied,"deleted" to deleted)
    }
}
