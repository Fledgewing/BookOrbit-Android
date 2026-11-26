package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONObject

/** Bounded account transport. Never redirects credentials or logs URLs, bodies or exceptions. */
object AccountHttp : BookOrbitAccount.Http {
    const val MAX_REPLY = 1048576
    override fun request(server: String, path: String, method: String, body: Map<String, Any?>?, bearer: String?): BookOrbitAccount.Reply {
        val start = System.nanoTime()
        val provision = path.startsWith("/koreader/plugin-package?origin=")
        val maxBytes = if (provision) SyncProvision.MAX_COMPRESSED else MAX_REPLY
        val connection = URL(server + path).openConnection() as HttpURLConnection
        return try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15000; connection.readTimeout = 20000
            connection.requestMethod = method
            connection.setRequestProperty("Accept", if (provision) "application/zip" else "application/json")
            bearer?.let { connection.setRequestProperty("Authorization", "Bearer $it") }
            if (body != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                val encoded = JSONObject(body).toString().toByteArray(Charsets.UTF_8)
                try { connection.setFixedLengthStreamingMode(encoded.size); connection.outputStream.use { it.write(encoded) } }
                finally { encoded.fill(0) }
            }
            val code = connection.responseCode
            if (code !in 200..299) return BookOrbitAccount.Reply(code)
            if (connection.contentLengthLong > maxBytes) return BookOrbitAccount.Reply(0)
            val bytes = connection.inputStream.use { it.readBytesBounded(maxBytes) } ?: return BookOrbitAccount.Reply(0)
            try { BookOrbitAccount.Reply(code, if (provision) bytes.copyOf() else if (bytes.isEmpty()) null else LuaValue.fromJson(String(bytes, Charsets.UTF_8))) }
            finally { bytes.fill(0) }
        } catch (_: Exception) { BookOrbitAccount.Reply(0) }
        finally { connection.disconnect(); OLog.i("account.http ms=${(System.nanoTime()-start)/1_000_000}") }
    }
    private fun java.io.InputStream.readBytesBounded(max: Int): ByteArray? {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val n = read(buffer)
            if (n < 0) return out.toByteArray()
            if (out.size() + n > max) return null
            out.write(buffer, 0, n)
        }
    }
}
