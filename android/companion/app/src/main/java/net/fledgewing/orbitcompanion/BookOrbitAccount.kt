package net.fledgewing.orbitcompanion

import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Instant
import java.net.URI

/** Account adapter. Only normalized state/statistics and connector credentials can leave it.
 * All methods are worker-only; synchronization serializes rotating refresh credentials. */
class BookOrbitAccount(private val vault: AccountVault, private val http: Http,
    private val now: () -> Long = { System.currentTimeMillis() / 1000 },
    private val log: (String) -> Unit = { OLog.i(it) }) {
    interface Http { fun request(server: String, path: String, method: String, body: Map<String, Any?>?, bearer: String?): Reply }
    class Reply(val code: Int, val value: Any? = null) { override fun toString() = "AccountReply($code)" }
    class Failure(val kind: String) : Exception(kind)
    private var session = vault.load()?.toMutableMap()
    private val blocked = mutableSetOf<String>()
    private var lastAttempt = 0L
    private fun persist() = vault.save(session)
    private fun number(v: Any?) = (v as? Number)?.toLong()
    private fun signedIn() = session != null && (number(session?.get("refreshExpiry")) ?: 0) > now()
    @Synchronized fun state(): Map<String, Any?> = mapOf("signedIn" to signedIn(),
        "connector" to (session?.get("connectorState") ?: "not-configured"))
    @Synchronized fun owner(): String? = if (signedIn()) (session?.get("connectorUser") as? String)?.let { it + "|" + (session!!["server"] as String).lowercase(java.util.Locale.ROOT) } else null
    @Synchronized fun connector(): CacheWorker.Creds? {
        val s = session ?: return null
        val user = s["connectorUser"] as? String ?: return null
        val key = s["connectorKey"] as? String ?: return null
        return CacheWorker.Creds(s["server"] as String, LuaValue.utf8(user), key)
    }
    @Synchronized fun stats(owner: String): Map<*, *>? = if (signedIn() && owner() == owner) session?.get("stats") as? Map<*, *> else null

    @Synchronized fun signIn(server: String, username: String, password: CharArray, legacy: CacheWorker.Creds? = null) = span("account.signIn") {
        try {
            val base = normalizeServer(server)
            require(username.length in 1..100 && password.size in 1..1024)
            val r = http.request(base, "/auth/login", "POST", mapOf("username" to username, "password" to String(password), "clientKind" to "native", "deviceLabel" to "BookSync"), null)
            if (r.code !in 200..299) throw Failure(if (r.code == 401) "unauthorized" else if (r.code == 403) "forbidden" else "unavailable")
            val reply = r.value as? Map<*, *> ?: throw Failure("invalid-response")
            val user = reply["user"] as? Map<*, *> ?: throw Failure("invalid-response")
            val id = number(user["id"]) ?: throw Failure("invalid-response")
            val next = mutableMapOf<String, Any?>("server" to base, "id" to id)
            credentials(next, reply)
            // Persist only after the complete response validates. Retire an older session best effort.
            val previous = session
            session = next; blocked.clear(); persist()
            if (previous != null) runCatching { http.request(previous["server"] as String, "/auth/logout", "POST", mapOf("refreshToken" to previous["refresh"]), null) }
            setupConnector(legacy)
            refreshStats(force = true)
        } finally { password.fill('\u0000') }
    }
    private fun credentials(target: MutableMap<String, Any?>, raw: Map<*, *>) {
        fun token(k: String) = (raw[k] as? String)?.takeIf { it.isNotEmpty() && it.length <= 8192 } ?: throw Failure("invalid-response")
        fun expiry(k: String) = runCatching { Instant.parse(token(k)).epochSecond }.getOrNull()?.takeIf { it > now() } ?: throw Failure("expired")
        val access = token("accessToken"); val refresh = token("refreshToken")
        val ae = expiry("accessTokenExpiresAt"); val re = expiry("refreshTokenExpiresAt")
        target.putAll(mapOf("access" to access, "refresh" to refresh, "accessExpiry" to ae, "refreshExpiry" to re))
    }
    private fun refresh() {
        val s = session ?: throw Failure("unauthorized")
        if (!signedIn()) { clear(); throw Failure("expired") }
        val r = http.request(s["server"] as String, "/auth/refresh", "POST", mapOf("refreshToken" to s["refresh"]), null)
        if (r.code == 401) { clear(); throw Failure("unauthorized") }
        if (r.code !in 200..299) throw Failure(if (r.code == 403) "forbidden" else "unavailable")
        val next = s.toMutableMap()
        credentials(next, r.value as? Map<*, *> ?: throw Failure("invalid-response"))
        session = next; persist()
    }
    /** Exact allowlist: never probe an attested route. 403 disables just this feature. */
    @Synchronized internal fun get(path: String, feature: String): Reply {
        require(path in READS || path == "/koreader/credentials")
        if (feature in blocked) return Reply(403)
        val s = session ?: throw Failure("unauthorized")
        if ((number(s["accessExpiry"]) ?: 0) <= now() + 30) refresh()
        fun request() = http.request(session!!["server"] as String, path, "GET", null, session!!["access"] as String)
        var r = request()
        if (r.code == 401) { refresh(); r = request(); if (r.code == 401) { clear(); throw Failure("unauthorized") } }
        if (r.code == 403) { blocked.add(feature) }
        return r
    }
    @Synchronized internal fun setupConnector(legacy: CacheWorker.Creds?) {
        val r = get("/koreader/credentials", "connector")
        val s = session ?: return
        if (r.code !in 200..299) { s["connectorState"] = "unavailable"; persist(); return }
        val existing = r.value as? Map<*, *>
        if (existing != null) {
            val user = existing["username"] as? String
            if (user != null) s["connectorUser"] = user
            val known = connector() ?: legacy
            if (user != null && known?.user == LuaValue.utf8(user) && normalizeServer(known.server) == s["server"]) {
                s["connectorUser"] = LuaValue.str(known.user); s["connectorKey"] = known.key; s["connectorState"] = "ready"
            } else { s["connectorState"] = "existing-login-needed" }
        } else if (r.value == null) {
            val random = ByteArray(24).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
            val user = "booksync-" + s["id"] + "-" + random.take(8)
            val created = http.request(s["server"] as String, "/koreader/credentials", "POST", mapOf("username" to user, "password" to random), s["access"] as String)
            if (created.code in 200..299) {
                s["connectorUser"] = user
                s["connectorKey"] = MessageDigest.getInstance("MD5").digest(random.toByteArray()).joinToString("") { "%02x".format(it) }
                s["connectorState"] = "ready"
            } else s["connectorState"] = if (created.code == 409) "existing-login-needed" else "unavailable"
        }
        persist()
    }
    @Synchronized fun refreshStats(force: Boolean = false) = span("account.refreshStats") {
        if (!signedIn() || (!force && lastAttempt > now() - 300)) return@span
        lastAttempt = now()
        val fields = linkedMapOf<String, Any?>()
        for ((path, feature) in READS) {
            val r = get(path, feature)
            if (r.code in 200..299) AccountStats.normalize(feature, r.value, java.time.Instant.ofEpochSecond(now()).atZone(java.time.ZoneOffset.UTC).toLocalDate())?.let { fields[feature] = it }
        }
        // Raw bounded account data stays private, normalized before library publication.
        session?.set("stats", fields + mapOf("at" to now())); persist()
    }
    @Synchronized fun signOut() = span("account.signOut") {
        val old = session
        clear() // Local revocation succeeds even when the server is offline.
        if (old != null) runCatching { http.request(old["server"] as String, "/auth/logout", "POST", mapOf("refreshToken" to old["refresh"]), null) }
        Unit
    }
    private fun clear() { session = null; blocked.clear(); persist() }
    private fun <T> span(id: String, block: () -> T): T {
        val start = System.nanoTime()
        try { return block() } finally { log("$id ms=${(System.nanoTime()-start)/1_000_000}") }
    }
    companion object {
        val READS = linkedMapOf("/user-statistics/daily-reading?days=365" to "days", "/user-statistics/peak-hours?days=365" to "hours",
            "/user-statistics/session-timeline" to "sessions", "/user-statistics/completion-timeline?days=365" to "finished", "/auth/me" to "goal")
        fun normalizeServer(raw: String): String {
            val uri = URI(raw.trim())
            require(uri.scheme in setOf("https", "http") && uri.host != null && uri.userInfo == null && uri.rawQuery == null && uri.fragment == null)
            val base = raw.trim().trimEnd('/')
            return if (uri.path.trimEnd('/').endsWith("/api/v1")) base else "$base/api/v1"
        }
    }
}
