package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class BookOrbitAccountTest {
    private class Vault : AccountVault {
        var data: Map<String, Any?>? = null
        override fun load() = data
        override fun save(value: Map<String, Any?>?) { data = value?.toMap() }
    }
    private class Kit {
        val vault = Vault()
        var time = Instant.parse("2026-11-25T12:00:00Z").epochSecond
        val logs = mutableListOf<String>()
        val calls = mutableListOf<String>()
        var access = "access-private"
        var existing: Any? = mapOf("username" to "fixture")
        var answer: (String, String, Map<String, Any?>?, String?) -> BookOrbitAccount.Reply = { p, m, _, _ ->
            when {
                p == "/auth/login" -> BookOrbitAccount.Reply(200, tokens() + ("user" to mapOf("id" to 7)))
                p == "/auth/refresh" -> BookOrbitAccount.Reply(200, tokens())
                p == "/koreader/credentials" && m == "GET" -> BookOrbitAccount.Reply(200, existing)
                p == "/koreader/credentials" && m == "POST" -> BookOrbitAccount.Reply(201)
                p == "/auth/me" -> BookOrbitAccount.Reply(200, mapOf("settings" to mapOf("dashboardConfig" to mapOf("readingGoal" to 12))))
                else -> BookOrbitAccount.Reply(200, emptyList<Any>())
            }
        }
        fun tokens() = mapOf("accessToken" to access, "refreshToken" to "refresh-private", "accessTokenExpiresAt" to Instant.ofEpochSecond(time + 900).toString(), "refreshTokenExpiresAt" to Instant.ofEpochSecond(time + 604800).toString())
        val account = BookOrbitAccount(vault, object : BookOrbitAccount.Http {
            override fun request(server: String, path: String, method: String, body: Map<String, Any?>?, bearer: String?): BookOrbitAccount.Reply {
                calls.add("$method $path")
                return answer(path, method, body, bearer)
            }
        }, { time }, logs::add)
        fun login(legacy: CacheWorker.Creds? = null) {
            val secret = "password-private".toCharArray()
            account.signIn("https://library.invalid", "fixture", secret, legacy)
            assertTrue(secret.all { it == '\u0000' })
        }
    }
    @Test fun passwordAndTokensNeverAppearInStateLogsOrConnector() {
        val k = Kit(); k.login()
        assertFalse(k.vault.data.toString().contains("password-private"))
        for (value in listOf(k.account.state().toString(), k.logs.toString(), k.account.connector().toString()))
            for (secret in listOf("password-private", "access-private", "refresh-private")) assertFalse(value, value.contains(secret))
        assertEquals(true, k.account.state()["signedIn"])
        assertEquals("existing-login-needed", k.account.state()["connector"])
    }
    @Test fun existingConnectorIsPreservedAndKnownKeyIsReused() {
        val k = Kit(); k.login(CacheWorker.Creds("https://library.invalid/api/v1", "fixture", "sync-key"))
        assertEquals("sync-key", k.account.connector()?.key)
        assertFalse(k.calls.any { it == "POST /koreader/credentials" })
        assertEquals("fixture|https://library.invalid/api/v1", k.account.owner())
    }
    @Test fun absentConnectorIsCreatedOnceWithAnIndependentRandomSecret() {
        val k = Kit(); k.existing = null
        val original = k.answer
        var posted: Map<String, Any?>? = null
        k.answer = { p,m,b,t -> if (p == "/koreader/credentials" && m == "POST") posted = b; original(p,m,b,t) }
        k.login()
        assertEquals(1, k.calls.count { it == "POST /koreader/credentials" })
        assertNotEquals("password-private", posted!!["password"])
        assertNotNull(k.account.connector())
        assertFalse(k.vault.data.toString().contains(posted!!["password"] as String))
        assertEquals(32, k.account.connector()!!.key.length)
    }
    @Test fun expiryRefreshesOnceAndRotatedTokenPersists() {
        val k = Kit(); k.login(); k.calls.clear(); k.time += 890; k.access = "access-rotated"
        k.account.get("/auth/me", "goal")
        assertEquals(1, k.calls.count { it == "POST /auth/refresh" })
        assertEquals("access-rotated", k.vault.data!!["access"])
    }
    @Test fun unauthorizedReplaysOnceButForbiddenDisablesOnlyItsFeature() {
        val k = Kit(); k.login(); k.calls.clear()
        var gets = 0; val original = k.answer
        k.answer = { p,m,b,t -> if (p == "/auth/me") { gets++; BookOrbitAccount.Reply(401) } else original(p,m,b,t) }
        try { k.account.get("/auth/me", "goal"); fail() } catch (e: BookOrbitAccount.Failure) { assertEquals("unauthorized", e.kind) }
        assertEquals(2, gets); assertEquals(1, k.calls.count { it == "POST /auth/refresh" }); assertNull(k.vault.data)
        val f = Kit(); f.login(); f.calls.clear()
        f.answer = { _,_,_,_ -> BookOrbitAccount.Reply(403) }
        assertEquals(403, f.account.get("/auth/me", "goal").code)
        assertEquals(403, f.account.get("/auth/me", "goal").code)
        assertEquals(1, f.calls.size); assertEquals(true, f.account.state()["signedIn"])
        try { f.account.get("/user-statistics/activity-overview", "days"); fail() } catch (_: IllegalArgumentException) { }
    }
    @Test fun refreshExpiryAndOfflineLogoutClearPrivateState() {
        val k = Kit(); k.login(); k.time += 604801
        try { k.account.get("/auth/me", "goal"); fail() } catch (e: BookOrbitAccount.Failure) { assertEquals("expired", e.kind) }
        assertNull(k.vault.data)
        val f = Kit(); f.login(); f.answer = { _,_,_,_ -> throw java.io.IOException("private-server") }
        f.account.signOut(); assertNull(f.vault.data); assertNull(f.account.owner()); assertNull(f.account.connector())
        assertFalse(f.logs.toString().contains("private-server"))
    }
    @Test fun credentialsCannotTravelToAUrlWithUserInfoQueryOrFragment() {
        for (s in listOf("https://u:p@library.invalid", "https://library.invalid?x=y", "https://library.invalid/#x", "file:///tmp/x")) {
            try { BookOrbitAccount.normalizeServer(s); fail(s) } catch (_: IllegalArgumentException) { }
        }
    }
    @Test fun lostCreationResponseRecoversTheCheckpointedKeyWithoutAnotherCreation() {
        val k = Kit(); k.existing = null
        val original = k.answer
        k.answer = { p,m,b,t ->
            if (p == "/koreader/credentials" && m == "POST") {
                k.existing = mapOf("username" to b!!["username"])
                BookOrbitAccount.Reply(0)
            } else original(p,m,b,t)
        }
        k.login(); assertNull(k.account.connector())
        val checkpoint = k.vault.data!!["pendingKey"]
        k.account.setupConnector(null)
        assertEquals(checkpoint, k.account.connector()!!.key)
        assertEquals(1, k.calls.count { it == "POST /koreader/credentials" })
    }
    @Test fun reloginPreservesTheKnownConnectorAndAccountSwitchDoesNotReuseIt() {
        val k = Kit(); k.login(CacheWorker.Creds("https://library.invalid/api/v1", "fixture", "key"))
        k.login(); assertEquals("key", k.account.connector()!!.key)
        k.existing = mapOf("username" to "other")
        k.account.setupConnector(null)
        assertNull(k.account.connector())
        assertEquals("existing-login-needed", k.account.state()["connector"])
    }
    @Test fun transientStatsErrorsRetainCacheWhileForbiddenFieldsAreRemoved() {
        val k = Kit(); k.login()
        val owner = k.account.owner()!!
        val before = k.account.stats(owner)!!["days"]
        k.answer = { p,_,_,_ -> BookOrbitAccount.Reply(if (p.contains("peak-hours")) 403 else 0) }
        k.account.refreshStats(force = true)
        val cached = k.account.stats(owner)!!
        assertEquals(before, cached["days"]); assertNull(cached["hours"]); assertEquals(true, cached["stale"])
    }

    @Test fun unavailableEncryptedStorageNeverFallsBackToAnInMemorySession() {
        val k = Kit()
        val vault = object : AccountVault {
            override fun load(): Map<String, Any?>? = null
            override fun save(value: Map<String, Any?>?) { if (value != null) throw IllegalStateException("private") }
        }
        val a = BookOrbitAccount(vault, object : BookOrbitAccount.Http {
            override fun request(server: String, path: String, method: String, body: Map<String, Any?>?, bearer: String?) =
                BookOrbitAccount.Reply(200, k.tokens() + ("user" to mapOf("id" to 7)))
        }, { k.time }, k.logs::add)
        val password = "private-password".toCharArray()
        try { a.signIn("https://library.invalid", "fixture", password); fail() }
        catch (e: BookOrbitAccount.Failure) { assertEquals("storage-unavailable", e.kind) }
        assertEquals(false, a.state()["signedIn"]); assertNull(a.connector())
        assertTrue(password.all { it == '\u0000' })
        assertFalse(k.logs.toString().contains("private"))
    }

}
