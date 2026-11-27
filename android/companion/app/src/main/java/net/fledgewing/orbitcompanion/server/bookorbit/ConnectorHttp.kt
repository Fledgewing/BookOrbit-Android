package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONObject

/** No redirects, credential reflection or request logging. Existing UrlHttp owns streamed downloads. */
internal object ConnectorHttp : BookOrbitServerAdapter.ConnectorTransport {
    override fun request(server: String, path: String, method: String, body: Map<String, Any?>?, headers: Map<String, String>): BookOrbitAccount.Reply {
        val start = System.nanoTime()
        val c = URL(server + path).openConnection() as HttpURLConnection
        return try {
            c.instanceFollowRedirects = false; c.connectTimeout = 15000; c.readTimeout = 20000; c.requestMethod = method
            headers.forEach { (k,v) -> c.setRequestProperty(k,v) }
            if (body != null) {
                c.doOutput = true; c.setRequestProperty("Content-Type", "application/json")
                val bytes = JSONObject(body).toString().toByteArray(Charsets.UTF_8)
                // Worker batches have a transport cap; screen snapshots retain their 16 KiB cap.
                try { require(bytes.size <= 1048576); c.outputStream.use { it.write(bytes) } } finally { bytes.fill(0) }
            }
            val code = c.responseCode
            if (code !in 200..299) return BookOrbitAccount.Reply(code)
            val bytes = c.inputStream.use { input ->
                val out = java.io.ByteArrayOutputStream(); val buf = ByteArray(8192)
                while (true) {
                    val n = input.read(buf); if (n < 0) break
                    if (out.size() + n > AccountHttp.MAX_REPLY) return BookOrbitAccount.Reply(0)
                    out.write(buf,0,n)
                }
                out.toByteArray()
            }
            try {
                val text = String(bytes, Charsets.UTF_8)
                BookOrbitAccount.Reply(code, if ((path == "/opds" || path.startsWith("/opds/"))) text else if (bytes.isEmpty()) emptyMap<Any,Any>() else LuaValue.fromJson(text))
            } finally { bytes.fill(0) }
        } catch (_: Exception) { BookOrbitAccount.Reply(0) }
        finally { c.disconnect(); OLog.i("connector.http ms=${(System.nanoTime()-start)/1_000_000}") }
    }
    override fun transfer(server:String,path:String,headers:Map<String,String>,destination:File,
        progress:(Long,Long?)->Unit,canceled:()->Boolean):Boolean =
        BookTransferHttp().transfer(server,path,headers,destination,progress,canceled)
    override fun download(server: String, path: String, headers: Map<String, String>, destination: File): Boolean {
        val part = File(destination.parentFile, destination.name + ".part")
        val reply = AdapterWorker.UrlHttp.get(server + path, headers, part, 536870912)
        if (reply.code != 200 || !part.renameTo(destination)) { part.delete(); return false }
        return true
    }
}
