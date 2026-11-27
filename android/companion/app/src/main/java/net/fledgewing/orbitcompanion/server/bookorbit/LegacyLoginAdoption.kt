// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import java.io.File

/** Worker-only upgrade bridge. Source files remain owned by their existing writers.
 * No HTTP, plaintext destination, password logging or position-writer activation. */
internal object LegacyLoginAdoption {
    fun run(credentials: ServerCredentials, settings: File, opds: File) {
        if (credentials.legacyImported()) return
        // Storage may not be accessible on the first process launch. Retry after it is granted.
        if (!settings.isFile && !opds.isFile) return
        if (settings.isFile && !settings.canRead() || opds.isFile && !opds.canRead()) return
        val legacy = LegacyCoverSource.read(settings)
        val logins = mutableMapOf<String, ServerCredentials.Login>()
        legacy?.let {
            logins["sync"] = ServerCredentials.Login(it.credentials.server, it.credentials.user,
                it.credentials.key, "user", it.owner)
        }
        // KOReader's independent OPDS login is optional. Only the current server is eligible;
        // multiple matching logins are ambiguous and must remain under native OPDS ownership.
        if (opds.isFile && opds.length() in 1..4194304) {
            val text = opds.readText(Charsets.ISO_8859_1)
            val literal = StatusMarginRepair.literalTable(text, "servers")
            val rows = literal?.let { LuaValue.parse(it.toByteArray(Charsets.ISO_8859_1)) as? List<*> }.orEmpty()
            fun server(row: Map<*,*>): String? {
                val url=(row["url"] as? String)?.let(LuaValue::utf8) ?: return null
                val base=url.substringBefore("/opds").takeIf { url == "$it/opds" || url.startsWith("$it/opds/") } ?: return null
                return base.takeIf { it.endsWith("/api/v1") && (legacy==null || it==legacy.credentials.server) }
            }
            val matches = rows.mapNotNull { it as? Map<*, *> }.filter { server(it)!=null }
            matches.singleOrNull()?.let { row ->
                val user = (row["username"] as? String)?.let(LuaValue::utf8)
                val secret = (row["password"] as? String)?.let(LuaValue::utf8)
                val base=server(row)!!
                if (!user.isNullOrBlank() && !secret.isNullOrEmpty())
                    logins["opds"] = ServerCredentials.Login(base,user,secret,"user",legacy?.owner)
            }
        }
        credentials.adoptLegacy(logins)
    }
}
