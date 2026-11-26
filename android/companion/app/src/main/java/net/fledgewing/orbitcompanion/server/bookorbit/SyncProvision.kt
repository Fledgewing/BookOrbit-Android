package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import java.util.zip.ZipInputStream

/** Reads the server's supported preconfiguration as data. No Lua or archive code is executed. */
internal object SyncProvision {
    const val MAX_COMPRESSED = 8388608
    private const val MAX_EXPANDED = 33554432
    fun key(bytes: ByteArray, expectedUser: String): String? = runCatching {
        require(bytes.size <= MAX_COMPRESSED)
        var total = 0
        var entries = 0
        ZipInputStream(bytes.inputStream()).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                require(++entries <= 2048)
                val wanted = entry.name == "bookorbit.koplugin/bookorbit_provision.lua" && !entry.isDirectory
                val out = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val n = zip.read(buffer)
                    if (n < 0) break
                    total += n; require(total <= MAX_EXPANDED)
                    if (wanted) { require(out.size()+n <= 8192); out.write(buffer,0,n) }
                }
                if (wanted) {
                    val text = String(out.toByteArray(),Charsets.ISO_8859_1)
                    val fields = Regex("""(?m)^\s*(username|userkey)\s*=\s*("(?:\\.|[^"\\])*")\s*,\s*$""").findAll(text).toList()
                    require(fields.size == 2 && fields.map { it.groupValues[1] }.toSet() == setOf("username","userkey"))
                    val values = fields.associate { m ->
                        val encoded = "{[\"value\"]=" + m.groupValues[2] + "}"
                        m.groupValues[1] to ((LuaValue.parse(encoded.toByteArray(Charsets.ISO_8859_1)) as? Map<*, *>)?.get("value") as? String)
                    }
                    require(values["username"] == expectedUser)
                    return@runCatching values["userkey"]?.takeIf { it.matches(Regex("[a-fA-F0-9]{32}")) }?.lowercase()
                }
            }
        }
        null
    }.getOrNull()
}
