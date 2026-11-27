package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

/** Three independent optional logins in one encrypted document. No secret-bearing toString. */
class ServerCredentials(private val vault: AccountVault) {
    internal class Login(val server: String, val user: String, val secret: String, val origin: String, private val accountOwner: String? = null, val adopted: Boolean = false) {
        override fun toString() = "ServerLogin(redacted)"
        fun owner() = accountOwner ?: ("login:" + BookOrbitLibrary.namespace(user + "|" + server).removePrefix("bo:"))
        fun encoded() = mapOf("server" to server, "user" to LuaValue.str(user), "secret" to LuaValue.str(secret), "origin" to origin, "accountOwner" to accountOwner, "adopted" to adopted)
    }
    private var data = vault.load().orEmpty().toMutableMap()
    private fun mutate(block: () -> Unit) {
        val before = data.toMap()
        try { block(); vault.save(data.takeIf { it.isNotEmpty() }) }
        catch (e: Exception) { data = before.toMutableMap(); throw e }
    }
    val accountVault = object : AccountVault {
        @Synchronized override fun load(): Map<String, Any?>? = synchronized(this@ServerCredentials) {
            (data["account"] as? Map<*, *>)?.entries?.associate { it.key.toString() to it.value }
        }
        @Synchronized override fun save(value: Map<String, Any?>?) = synchronized(this@ServerCredentials) {
            mutate {
                val previous = data["account"] as? Map<*, *>
                if (value == null || previous?.get("id") != value["id"] || previous?.get("server") != value["server"]) {
                    for (kind in KINDS) if (login(kind)?.origin == "account") data.remove(kind)
                }
                if (value == null) data.remove("account") else data["account"] = value.toMap()
            }
        }
    }
    @Synchronized internal fun login(kind: String): Login? {
        require(kind in KINDS)
        val raw = data[kind] as? Map<*, *> ?: return null
        return Login(raw["server"] as String, LuaValue.utf8(raw["user"] as String), LuaValue.utf8(raw["secret"] as String), raw["origin"] as String, raw["accountOwner"] as? String, raw["adopted"] == true)
    }
    @Synchronized fun status(kind: String): Map<String, Any?> {
        val login = login(kind)
        return mapOf("set" to (login != null), "origin" to login?.origin)
    }
    @Synchronized internal fun set(kind: String, login: Login, onlyIfUnset: Boolean = false): Boolean {
        require(kind in KINDS && login.origin in setOf("user", "account"))
        if (onlyIfUnset && login(kind) != null) return false
        mutate { data[kind] = login.encoded() }
        return true
    }
    @Synchronized fun remove(kind: String) { require(kind in KINDS); mutate { data.remove(kind) } }
    @Synchronized internal fun legacyImported() = data["legacyImported"] == true

    /** One atomic encrypted checkpoint. A restart cannot expose half the imported logins,
     * overwrite a newer login, or resurrect one the reader subsequently removed. */
    @Synchronized internal fun adoptLegacy(logins: Map<String, Login>) {
        if (data["legacyImported"] == true) return
        mutate {
            for ((kind, login) in logins) {
                require(kind in KINDS && login.origin == "user")
                if (data[kind] == null) data[kind] = login.encoded() + mapOf("adopted" to true)
            }
            data["legacyImported"] = true
        }
    }
    companion object { val KINDS = setOf("sync", "opds") }
}
