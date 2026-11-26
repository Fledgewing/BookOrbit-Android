package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import java.io.File
import java.security.MessageDigest

/** BookOrbit authentication is private to this adapter; sync and OPDS also work on their own. */
internal class BookOrbitServerAdapter(private val credentials: ServerCredentials, private val account: BookOrbitAccount,
    private val transport: ConnectorTransport,
    private val coverReferenceJob: (CacheWorker.Creds?, String, String, Boolean, (Map<String, Any?>?, String?) -> Unit) -> Unit =
        { _, _, _, _, done -> done(null,"unsupported") },
    private val coverJob: (CacheWorker.Creds, String, Long, (Map<String, Any?>?, String?) -> Unit) -> Unit =
        { _, _, _, done -> done(null,"unsupported") }) : ServerAdapter {
    override val id = "bookorbit"
    internal interface ConnectorTransport {
        fun request(server: String, path: String, method: String, body: Map<String, Any?>?, headers: Map<String, String>): BookOrbitAccount.Reply
        fun download(server: String, path: String, headers: Map<String, String>, destination: File): Boolean
    }
    private var dashboardUnavailableOwner: String? = null
    private var dashboard: Pair<String,RemoteReadingStats>? = null
    private val artifacts = linkedMapOf<String, String>()
    private var sync: BookOrbitSync? = null
    override fun importLifecycle(queue: LifecycleQueue, settings: File, quiesced: Boolean): Int {
        check(quiesced)
        sync = BookOrbitSync(settings, { path, body ->
            val c=login("sync")
            fun native(value: Any?): Any? = when(value) {
                is String -> LuaValue.utf8(value)
                is Map<*, *> -> value.entries.associate { it.key.toString() to native(it.value) }
                is List<*> -> value.map { native(it) }
                else -> value
            }
            @Suppress("UNCHECKED_CAST")
            val reply=transport.request(c.server,path,"POST",native(body) as Map<String,Any?>,headers(c,"sync"))
            check(reply); reply.value as? Map<*, *> ?: throw ServerFailure("invalid-response")
        },queue.sql)
        var legacyOwner: String? = null
        val stateFiles=settings.listFiles().orEmpty().filter { it.name.matches(Regex("bookorbit_sync_state(?:_[a-f0-9]{32})?\\.lua")) }
        require(stateFiles.size<=128 && stateFiles.sumOf { it.length() }<=LifecycleQueue.MAX_BYTES)
        val states=stateFiles.mapNotNull { f -> LegacyLifecycleImport.literal(f)?.let { f to it } }
        fun namespace(identity: String): String? {
            val server=identity.substringBeforeLast('|',""); val user=identity.substringAfterLast('|',"")
            if(server.isBlank() || user.isBlank()) return null
            val normalized=runCatching { BookOrbitAccount.normalizeServer(LuaValue.utf8(server)) }.getOrNull() ?: return null
            val current=credentials.login("sync")
            return if(current?.server==normalized && current.user==LuaValue.utf8(user)) current.owner()
                else ServerCredentials.Login(normalized,LuaValue.utf8(user),"","user").owner()
        }
        val count=LegacyLifecycleImport(queue,settings,{ old ->
            val server=(old["server_url"] as? String)?.let { runCatching { BookOrbitAccount.normalizeServer(LuaValue.utf8(it)) }.getOrNull() }
            val user=(old["username"] as? String)?.let(LuaValue::utf8)
            if(server==null || user.isNullOrBlank()) null else {
                val current=credentials.login("sync")
                if(current==null) {
                    val key=(old["userkey"] as? String)?.takeIf { it.matches(Regex("[a-fA-F0-9]{32}")) }
                    if(key!=null) credentials.set("sync",ServerCredentials.Login(server,user,key,"user"))
                }
                val selected=credentials.login("sync")
                val fallback=if(selected?.server==server && selected.user==user) selected.owner()
                    else ServerCredentials.Login(server,user,"","user").owner()
                val snapshot=old["_snapshot"] as? Map<*, *>
                if(snapshot==null) { legacyOwner=fallback; fallback }
                else {
                    val identity=(old["server_url"] as String).trimEnd('/')+"|"+(old["username"] as String)
                    val namedHash=MessageDigest.getInstance("MD5").digest(identity.toByteArray(Charsets.ISO_8859_1)).joinToString("") { "%02x".format(it) }
                    val matches=states.filter { (_,state) ->
                        val book=(state["books"] as? Map<*, *>)?.get(snapshot["digest"]) as? Map<*, *>
                        book!=null && (book["file"]==null || book["file"]==snapshot["file"])
                    }
                    val proven=matches.map { (file,state) -> (state["account_identity"] as? String)
                        ?: identity.takeIf { file.name=="bookorbit_sync_state_$namedHash.lua" } }.distinct()
                    when {
                        matches.size==1 && proven.singleOrNull()!=null -> namespace(proven.single()!!)
                        matches.isEmpty() && (states.isEmpty() || states.size==1 && states.single().second["account_identity"]==identity) -> fallback
                        else -> null // Multiple editions/accounts in the legacy store: never guess current credentials.
                    }
                }
            }
        }).run(true)
        // This local decision state never contains credentials. Import once; later companion state wins.
        val root=LegacyLifecycleImport.literal(File(settings.parentFile,"settings.reader.lua"))
        val old=(root?.get("orbit_android") as? Map<*, *>)?.get("orbismart") as? Map<*, *>
        val bound=legacyOwner
        if(bound!=null) queue.sql.transaction {
            val configured=(root?.get("bookorbit") as? Map<*, *>).orEmpty()
            val identity=(configured["server_url"] as? String)?.trimEnd('/')+"|"+configured["username"]
            val namedHash=MessageDigest.getInstance("MD5").digest(identity.toByteArray(Charsets.ISO_8859_1)).joinToString("") { "%02x".format(it) }
            val selected=states.firstOrNull { it.second["account_identity"]==identity || it.first.name=="bookorbit_sync_state_$namedHash.lua" }?.second
            val books=(selected?.get("books") as? Map<*, *>).orEmpty()
            // Queued snapshots can belong to an older account. Preserve its known state too:
            // null rating/review captures mean explicit clears only with that account's history.
            for((file,state) in states) {
                val proven=(state["account_identity"] as? String)
                    ?: identity.takeIf { file.name=="bookorbit_sync_state_$namedHash.lua" }
                val stateOwner=proven?.let(::namespace) ?: continue
                for((doc,book) in (state["books"] as? Map<*, *>).orEmpty()) if(doc is String && book is Map<*, *>) {
                    queue.sql.exec("INSERT OR IGNORE INTO adapter_sync_books VALUES (?,?,?)",stateOwner,doc,LuaValue.encode(book))
                }
            }
            for((document,value) in old.orEmpty()) {
                if(document !is String || value !is Map<*, *> || queue.record(id,bound,document).isNotEmpty()) continue
                if(states.isNotEmpty() && document !in books) continue
                fun remote(raw: Any?): Map<String,Any?> {
                    val r=raw as? Map<*, *> ?: return emptyMap()
                    return mapOf("at" to r["at"],"percentage" to r["pct"],"position" to r["progress"],
                        "reset" to (r["device_id"]=="bookorbit-web" && (r["pct"] as? Number)?.toDouble()==0.0),"web" to (r["device"]=="web"),"label" to (r["device_name"] ?: r["device"]))
                }
                queue.record(id,bound,document,mapOf("marker" to remote(value["m"]),"remote" to remote(value["server"]),
                    "override" to remote(value["override"]),"declinedAt" to value["declined_at"],"declinedReset" to value["declined_reset"],
                    "path" to ((books[document] as? Map<*, *>)?.get("file")),"pending" to value["pending"],"rereadAt" to value["reread_at"],"token" to java.util.UUID.randomUUID().toString()))
            }
        }
        return count
    }
    override fun positionDirections() = sync?.directions() ?: PositionDirections()
    override fun captureLifecycle(capture: Map<*, *>) = (sync ?: throw ServerFailure("writer-active")).capture(capture)
    override fun positionIntent(document: String, update: Map<String,Any?>) = LuaValue.encode(mapOf(
        "digest" to document,"percentage" to update["percentage"],"progress" to update["position"],"ts" to update["capturedAt"]))
    override fun lifecyclePosition(payload: ByteArray): CapturedPosition {
        val raw=LuaValue.parse(payload) as? Map<*, *> ?: throw ServerFailure("invalid")
        return CapturedPosition((raw["percentage"] as? Number)?.toDouble(),raw["progress"] as? String,
            (raw["ts"] as? Number)?.toLong() ?: 0L,raw["status"]=="complete")
    }
    override fun lifecyclePhase(entry: LifecycleQueue.Entry, phase: String, checkpoint: ByteArray, openPath: String?) =
        (sync ?: throw ServerFailure("writer-active")).phase(entry,phase,checkpoint,openPath)
    override fun lifecycleComplete(checkpoint: ByteArray): Boolean =
        ((LuaValue.parse(checkpoint) as? Map<*, *>)?.get("remote_pending") as? Map<*, *>).isNullOrEmpty()
    override fun nextSyncVerification(owner: String, document: String) =
        (sync ?: throw ServerFailure("writer-active")).nextVerification(owner,document)
    override fun syncVerification(owner: String, document: String, key: String, valid: Boolean, page: Int?) =
        (sync ?: throw ServerFailure("writer-active")).verification(owner,document,key,valid,page)
    private fun login(kind: String): ServerCredentials.Login {
        val c = credentials.login(kind) ?: throw BookOrbitAccount.Failure("unauthorized")
        if (c.origin == "account" && account.state()["signedIn"] != true) throw BookOrbitAccount.Failure("unauthorized")
        return c
    }
    override fun state(): Map<String,Any?> {
        val accountState = account.state()
        fun status(kind: String): Map<String,Any?> {
            val c = credentials.login(kind)
            return credentials.status(kind) + mapOf("server" to c?.server, "username" to c?.user?.let(LuaValue::str),
                "outcome" to if (kind == "sync") accountState["connectorOutcome"] else "created") + ("available" to (c != null && (c.origin == "user" || accountState["signedIn"] == true)))
        }
        return mapOf("signedIn" to accountState["signedIn"], "expiresAt" to accountState["expiresAt"],
            "username" to accountState["username"], "server" to accountState["server"],
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
    override fun positionOwner(): String? = credentials.login("sync")?.takeIf {
        it.origin == "user" || account.state()["signedIn"] == true
    }?.owner()
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
            val capturedAt = (it["capturedAt"] as? Number)?.toLong()
            require(capturedAt == null || capturedAt > 0)
            mapOf("document" to document, "percentage" to percentage, "progress" to position?.let(LuaValue::utf8), "device" to "BookSync", "device_id" to sync?.deviceId()) +
                (if (capturedAt != null) mapOf("timestamp" to capturedAt) else emptyMap())
        }
        val reply = transport.request(c.server, path, if (body == null) "GET" else "PUT", body, headers(c,"sync"))
        if(update==null && reply.code==404) return emptyMap()
        check(reply)
        val raw = reply.value as? Map<*, *> ?: emptyMap<Any,Any>()
        val position = raw["progress"] as? String
        require(position == null || position.length <= 4096)
        return mapOf("position" to position, "percentage" to (raw["percentage"] as? Number), "timestamp" to (raw["timestamp"] as? Number),
            "reset" to (raw["device_id"]=="bookorbit-web" && (raw["percentage"] as? Number)?.toDouble()==0.0),
            "web" to (raw["device"]=="web"),"label" to ((raw["device_name"] ?: raw["device"]) as? String)?.let { LuaValue.boundedText(LuaValue.utf8(it),100) })
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
    override fun acquireCoverReference(reference: String, refresh: Boolean, owner: String, done: (Map<String, Any?>?, String?) -> Unit) {
        require(reference.length in 1..4096)
        require(owner.length in 1..4096)
        val c=credentials.login("sync")?.takeIf { it.owner()==owner }?.let { login("sync") }
        coverReferenceJob(c?.let { CacheWorker.Creds(it.server,it.user,it.secret) },owner,reference,refresh,done)
    }
    override fun acquireCover(key: String, done: (Map<String, Any?>?, String?) -> Unit) {
        val c = login("sync")
        val owner = c.owner()
        val id = BookOrbitLibrary.id(owner,"book",key) ?: throw BookOrbitAccount.Failure("missing")
        coverJob(CacheWorker.Creds(c.server,c.user,c.secret),owner,id,done)
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
