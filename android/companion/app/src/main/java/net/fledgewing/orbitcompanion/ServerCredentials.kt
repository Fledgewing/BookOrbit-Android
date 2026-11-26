package net.fledgewing.orbitcompanion

/** Three independent optional logins in one encrypted document. No secret-bearing toString. */
class ServerCredentials(private val vault: AccountVault) {
    internal class Login(val server: String, val user: String, val secret: String, val origin: String) {
        override fun toString() = "ServerLogin(redacted)"
        fun owner() = "login:" + BookOrbitLibrary.namespace(user + "|" + server).removePrefix("bo:")
        fun encoded() = mapOf("server" to server, "user" to LuaValue.str(user), "secret" to LuaValue.str(secret), "origin" to origin)
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
                if (value == null) {
                    data.remove("account")
                    // Adopted credentials have the same account provenance as newly created ones.
                    for (kind in KINDS) if (login(kind)?.origin == "account") data.remove(kind)
                } else data["account"] = value.toMap()
            }
        }
    }
    @Synchronized internal fun login(kind: String): Login? {
        require(kind in KINDS)
        val raw = data[kind] as? Map<*, *> ?: return null
        return Login(raw["server"] as String, LuaValue.utf8(raw["user"] as String), LuaValue.utf8(raw["secret"] as String), raw["origin"] as String)
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
    companion object { val KINDS = setOf("sync", "opds") }
}
