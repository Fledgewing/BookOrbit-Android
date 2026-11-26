package net.fledgewing.orbitcompanion

import android.content.Context
import java.io.File

/** Trusted-provider commands: inputs/results are neutral and bounded; credentials never cross IPC. */
object ServerCommands {
    const val START = "${Contract.PACKAGE}.call.SERVER_COMMAND"
    const val RESULT = "${Contract.PACKAGE}.call.SERVER_RESULT"
    private class Pending(val at: Long, var body: Map<String,Any?>? = null)
    private val jobs = linkedMapOf<String,Pending>()
    @Synchronized fun start(ctx: Context, op: String, args: Map<*, *>): String {
        require(op in setOf("sync.read","sync.write","catalog.window","downloads.start"))
        val now = System.currentTimeMillis()
        jobs.entries.removeAll { now - it.value.at > 120000 }
        require(jobs.size < 32)
        val id = java.util.UUID.randomUUID().toString()
        jobs[id] = Pending(now)
        fun finish(result: Map<String,Any?>?, error: String?) = synchronized(this) {
            val body = if (error != null) mapOf("error" to error) else result ?: mapOf("ok" to true)
            jobs[id]?.body = if (LuaValue.encode(body).size <= 16384) body else mapOf("error" to "budget")
        }
        try { when (op) {
            "sync.read", "sync.write" -> {
                val document = args["document"] as? String ?: throw IllegalArgumentException("document")
                val update = if (op == "sync.write") mapOf("percentage" to args["percentage"], "position" to args["position"]) else null
                LibraryAccount.position(ctx,document,update,::finish)
            }
            "catalog.window" -> LibraryAccount.catalog(ctx,(args["page"] as? Number)?.toInt() ?: 1,(args["limit"] as? Number)?.toInt()?.coerceIn(1,24) ?: 24,::finish)
            "downloads.start" -> {
                val key = args["key"] as? String ?: throw IllegalArgumentException("key")
                val destination = File(LuaValue.utf8(args["destination"] as? String ?: throw IllegalArgumentException("destination")))
                LibraryAccount.download(ctx,key,destination) { finish(mapOf("local_path" to LuaValue.str(destination.path)),it) }
            }
        } } catch (e: Exception) { jobs.remove(id); throw e }
        return id
    }
    @Synchronized fun result(id: String): Map<String,Any?> {
        val job = jobs[id] ?: return mapOf("error" to "missing")
        val body = job.body ?: return mapOf("pending" to true)
        jobs.remove(id)
        return body
    }
}
