package net.fledgewing.orbitcompanion

import java.io.File
import java.security.MessageDigest

/** BookOrbit authentication is private to this adapter; sync and OPDS also work on their own. */
internal class BookOrbitServerAdapter(private val credentials: ServerCredentials, private val account: BookOrbitAccount,
    private val transport: ConnectorTransport) : ServerAdapter {
    internal interface ConnectorTransport {
        fun request(server: String, path: String, method: String, body: Map<String, Any?>?, headers: Map<String, String>): BookOrbitAccount.Reply
        fun download(server: String, path: String, headers: Map<String, String>, destination: File): Boolean
    }
    private var dashboardUnavailableOwner: String? = null
    private var dashboard: Pair<String,RemoteReadingStats>? = null
    private val artifacts = linkedMapOf<String, String>()
    private fun login(kind: String): ServerCredentials.Login {
        val c = credentials.login(kind) ?: throw BookOrbitAccount.Failure("unauthorized")
        if (c.origin == "account" && account.state()["signedIn"] != true) throw BookOrbitAccount.Failure("unauthorized")
        return c
    }
    override fun state(): Map<String,Any?> {
        val accountState = account.state()
        fun status(kind: String): Map<String,Any?> {
            val c = credentials.login(kind)
            return credentials.status(kind) + ("available" to (c != null && (c.origin == "user" || accountState["signedIn"] == true)))
        }
        return mapOf("signedIn" to accountState["signedIn"], "expiresAt" to accountState["expiresAt"],
            "account" to mapOf("set" to (accountState["signedIn"] == true), "origin" to "user".takeIf { accountState["signedIn"] == true }),
            "sync" to status("sync"), "opds" to status("opds"), "owner" to owner())
    }
    override fun signIn(server: String, username: String, password: CharArray) {
        try {
            account.signIn(server, username, password)
            fill("sync", false); fill("opds", false)
        } finally { password.fill('\u0000') }
    }
    override fun signOut() {
        val previous = credentials.login("opds")?.owner()
        account.signOut()
        if (previous != credentials.login("opds")?.owner()) artifacts.clear()
    }
    override fun setLogin(kind: String, server: String, username: String, secret: CharArray, derivedKey: Boolean) {
        try {
            require(kind in ServerCredentials.KINDS && username.isNotBlank() && username.length <= 100 && secret.size in 1..1024)
            val value = if (kind == "sync") {
                if (derivedKey) String(secret).also { require(it.matches(Regex("[a-fA-F0-9]{32}"))) }.lowercase()
                else MessageDigest.getInstance("MD5").digest(String(secret).toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
            } else String(secret)
            val candidate = ServerCredentials.Login(BookOrbitAccount.normalizeServer(server), username, value, "user")
            check(transport.request(candidate.server, if (kind == "sync") "/koreader/users/auth" else "/opds", "GET", null, headers(candidate,kind)))
            credentials.set(kind, candidate)
            if (kind == "sync") { dashboardUnavailableOwner = null; account.forgetConnectorCandidate() }
            if (kind == "opds") artifacts.clear()
        } finally { secret.fill('\u0000') }
    }
    override fun removeLogin(kind: String) { credentials.remove(kind); if (kind == "sync") account.forgetConnectorCandidate(); if (kind == "opds") artifacts.clear() }
    override fun useAccountLogin(kind: String) { require(kind in ServerCredentials.KINDS); if (!fill(kind, true)) throw BookOrbitAccount.Failure("unavailable") }
    private fun fill(kind: String, replace: Boolean): Boolean {
        if (!replace && credentials.login(kind) != null) return true
        val candidate = if (kind == "sync") {
            account.setupConnector(credentials.login("sync")?.let { CacheWorker.Creds(it.server, it.user, it.secret) })
            account.connector()?.let { ServerCredentials.Login(it.server, it.user, it.key, "account", account.identity()) }
        } else account.setupOpds()?.let { ServerCredentials.Login(it.first, it.second.first, it.second.second, "account", account.identity()) }
        if (candidate != null) { credentials.set(kind, candidate, onlyIfUnset = !replace); if (kind == "sync") account.forgetConnectorCandidate(); if (kind == "opds") artifacts.clear() }
        return candidate != null
    }
    override fun fallbackReadingStats(): RemoteReadingStats? {
        val c = credentials.login("sync") ?: return null
        if (c.origin == "account" && account.state()["signedIn"] != true) return null
        return dashboard?.takeIf { it.first == c.owner() }?.second
    }
    override fun refreshStats() {
        try { account.refreshStats() } finally {
            val c = credentials.login("sync")
            if (c != null && dashboardUnavailableOwner != c.owner() && (c.origin == "user" || account.state()["signedIn"] == true)) {
                val reply = transport.request(c.server,"/koreader/plugin/catalog/dashboard","GET",null,headers(c,"sync"))
                if (reply.code in 200..299 && reply.value is Map<*, *>)
                    dashboard = c.owner() to BookOrbitLibrary.dashboardStats(reply.value)
                else if (reply.code in setOf(401,403,404)) { dashboard = null; dashboardUnavailableOwner = c.owner() }
            }
        }
    }
    override fun owner(): String? = (credentials.login("opds") ?: credentials.login("sync"))?.owner() ?: account.identity()
    override fun stats(owner: String): Map<*, *>? = if (owner == owner()) account.normalizedStats() else null
    private fun headers(login: ServerCredentials.Login, kind: String): Map<String, String> = if (kind == "sync")
        mapOf("Accept" to "application/json", "x-auth-user" to login.user, "x-auth-key" to login.secret)
        else mapOf("Accept" to "application/atom+xml", "Authorization" to "Basic " + java.util.Base64.getEncoder().encodeToString((login.user + ":" + login.secret).toByteArray(Charsets.UTF_8)))
    override fun position(document: String, update: Map<String, Any?>?): Map<String, Any?> {
        require(document.matches(Regex("[a-fA-F0-9]{32}")))
        val c = login("sync")
        val path = if (update == null) "/koreader/syncs/progress/$document" else "/koreader/syncs/progress"
        val body = update?.let {
            val percentage = (it["percentage"] as? Number)?.toDouble() ?: throw IllegalArgumentException("percentage")
            require(percentage.isFinite() && percentage in 0.0..1.0)
            val position = it["position"] as? String
            require(position == null || position.length <= 4096)
            mapOf("document" to document, "percentage" to percentage, "progress" to position?.let(LuaValue::utf8), "device" to "BookSync")
        }
        val reply = transport.request(c.server, path, if (body == null) "GET" else "PUT", body, headers(c,"sync"))
        check(reply)
        val raw = reply.value as? Map<*, *> ?: emptyMap<Any,Any>()
        val position = raw["progress"] as? String
        require(position == null || position.length <= 4096)
        return mapOf("position" to position, "percentage" to (raw["percentage"] as? Number), "timestamp" to (raw["timestamp"] as? Number))
    }
    override fun catalog(page: Int, limit: Int): Map<String, Any?> {
        require(page in 1..10000 && limit in 1..24)
        val c = login("opds")
        val reply = transport.request(c.server, "/opds/catalog?page=$page&size=$limit", "GET", null, headers(c,"opds"))
        check(reply)
        val parsed = OpdsCatalog.parse(reply.value as? String ?: throw BookOrbitAccount.Failure("invalid-response"), c.server, limit)
        val rows = parsed.items.map { book ->
            val id = java.net.URI(book.href).path.split('/')[2].toLong().also { require(it > 0) }
            val key = BookOrbitLibrary.key(c.owner(),"book",id)
            artifacts[key] = book.href
            while (artifacts.size > 200) artifacts.remove(artifacts.keys.first())
            mapOf("key" to key, "title" to LuaValue.str(book.title), "authors" to book.authors.map(LuaValue::str), "formats" to listOf(book.format), "downloadable" to true)
        }
        val result = mapOf("items" to rows, "next" to (page + 1).takeIf { parsed.hasNext }, "freshness" to mapOf("saved" to true, "origin" to "cached-remote"))
        require(LuaValue.encode(result).size <= 16384)
        return result
    }
    override fun download(key: String, destination: File): Boolean {
        val c = login("opds")
        require(BookOrbitLibrary.id(c.owner(),"book",key) != null)
        val path = artifacts[key] ?: throw BookOrbitAccount.Failure("missing")
        require(!destination.exists())
        return transport.download(c.server, path, headers(c,"opds") + ("Accept" to "application/octet-stream"), destination)
    }
    private fun check(reply: BookOrbitAccount.Reply) {
        if (reply.code !in 200..299) throw BookOrbitAccount.Failure(when(reply.code) { 401 -> "unauthorized"; 403 -> "forbidden"; else -> "unavailable" })
    }
}
