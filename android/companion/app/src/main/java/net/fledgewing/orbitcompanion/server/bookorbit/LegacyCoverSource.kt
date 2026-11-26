// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import java.io.File

/** Read-only compatibility for existing catalog accounts. Never executes Lua, changes a login,
 * reassigns a catalog, persists a credential or activates any position/lifecycle writer. */
internal object LegacyCoverSource {
    class Account(val owner: String,val credentials: CacheWorker.Creds) {
        override fun toString() = "CoverAccount(redacted)"
    }
    fun read(file: File): Account? = runCatching {
        require(file.canonicalFile.parentFile==file.parentFile?.canonicalFile && file.length() in 1..4194304)
        val text=file.readText(Charsets.ISO_8859_1)
        val literal=StatusMarginRepair.literalTable(text,"bookorbit") ?: return null
        require(literal.length<=65536)
        val raw=LuaValue.parse(literal.toByteArray(Charsets.ISO_8859_1)) as? Map<*,*> ?: return null
        fun value(key: String)=LuaValue.utf8(raw[key] as? String ?: error("missing")).also { require(it.isNotEmpty() && it.length<=4096) }
        val server=CoverProtocol.apiBase(value("server_url")) ?: return null
        val user=value("username"); val key=value("userkey")
        require(server.startsWith("https://") || server.startsWith("http://"))
        Account(LuaValue.str(user)+"|"+LuaValue.str(server.lowercase(java.util.Locale.ROOT)),CacheWorker.Creds(server,user,key))
    }.getOrNull()
}
