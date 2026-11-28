// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import android.os.Environment
import java.io.File
import java.util.concurrent.Executors

/** Library's device-local reading service, shared by companion Settings and reader commands.
 * A separate durable file survives account cache wipes; all IO runs off either UI thread. */
object LibraryLocalReading {
    private val queue = Executors.newSingleThreadExecutor()
    private val lock = Any()
    private fun file(settings: File) = File(settings,"booksync-local-reading.sqlite3")
    private fun settings() = File(Environment.getExternalStorageDirectory(),"koreader/settings")
    private fun legacy(settings: File): Map<*, *>? {
        val source=File(settings,"orbit-finish-queue.lua")
        if(!source.isFile || source.length()>1048576) return null
        return runCatching {
            val text=source.readText(Charsets.ISO_8859_1).replaceFirst(Regex("\\A(?:--[^\\n]*\\n)?\\s*return\\s+"),"")
            LuaValue.parse(text.toByteArray(Charsets.ISO_8859_1)) as? Map<*,*>
        }.getOrNull()
    }
    private var importedSource: String? = null
    private fun importLegacy(settings: File, ledger: LocalCompletion) {
        val source=File(settings,"orbit-finish-queue.lua")
        val stamp="${source.absolutePath}:${source.length()}:${source.lastModified()}"
        if(importedSource==stamp) return
        // Reader metadata may live anywhere on the external volume, as in the
        // existing native sync adapter; cache-write roots are deliberately narrower.
        val roots=listOf(settings.parentFile!!.parentFile!!)
        for((document,raw) in (legacy(settings)?.get("jobs") as? Map<*,*>).orEmpty()) {
            BulkWork.checkpoint()
            val job=raw as? Map<*,*> ?: continue
            val path=(job["file"] as? String)?.let(LuaValue::utf8) ?: continue
            val data=DeviceLibrary.metadata(File(path),roots) ?: continue
            val digest=data["partial_md5_checksum"] as? String ?: continue
            if(document!=digest || job["hash"]!=digest || !digest.matches(Regex("[a-fA-F0-9]{32}"))) continue
            val summary=data["summary"] as? Map<*,*> ?: continue
            ledger.import011(digest,summary,job)
        }
        importedSource=stamp
    }
    fun snapshot(settings: File): Map<String,Any?> = synchronized(lock) {
        runCatching { AndroidSql(file(settings)).use {
            val ledger=LocalCompletion(it,{ System.currentTimeMillis()/1000 })
            importLegacy(settings,ledger)
            ledger.snapshot()
        } }.getOrElse { if(it is InterruptedException) throw it; mapOf("error" to "unavailable", "completion_available" to false) }
    }
    fun catalogIntent(settings: File, document: String, token: String, complete: Boolean, undo: String? = null, order: Long = System.currentTimeMillis()*1000) = synchronized(lock) {
        AndroidSql(file(settings)).use { LocalCompletion(it,{System.currentTimeMillis()/1000}).catalogIntent(document,token,complete,undo,order) }
    }
    fun command(op: String, args: Map<*, *>, done: (Map<String,Any?>?,String?)->Unit) {
        queue.execute {
            val start=System.nanoTime()
            val result=runCatching { synchronized(lock) {
                val settings=settings()
                AndroidSql(file(settings)).use { sql ->
                    val ledger=LocalCompletion(sql,{ System.currentTimeMillis()/1000 })
                    when(op) {
                        "reading.local.goal" -> {
                            require(args["target"]==null || args["target"] is String)
                            ledger.setGoal(args["target"] as? String)
                        }
                        "reading.local.event" -> ledger.event(args["document"] as String,(args["revision"] as Number).toLong(),args["token"] as String,args["complete"] as Boolean,(args["at"] as Number).toLong())
                        "reading.local.prepare" -> {
                            val document=args["document"] as String
                            val raw=legacy(settings)
                            val job=(raw?.get("jobs") as? Map<*,*>)?.get(document) as? Map<*,*>
                            if(job!=null) ledger.import011(document,args["summary"] as? Map<*,*> ?: emptyMap<Any,Any>(),job)
                        }
                        "reading.local.read" -> importLegacy(settings,ledger)
                        else -> throw IllegalArgumentException("unsupported")
                    }
                    ledger.snapshot() + ((args["document"] as? String)?.let { mapOf("revision" to ledger.revision(it)) } ?: emptyMap())
                }
            } }
            OLog.i("library.local-reading ms=${(System.nanoTime()-start)/1_000_000} rows=1")
            result.fold({done(it,null)},{done(null,if(it is IllegalArgumentException) "invalid" else "unavailable")})
        }
    }
}
