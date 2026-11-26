package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.time.Instant

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ServerAdapterTest {
    private class Vault : AccountVault {
        var value: Map<String,Any?>? = null
        override fun load() = value
        override fun save(value: Map<String,Any?>?) { this.value = value?.toMap() }
    }
    private class Kit {
        val vault = Vault()
        val credentials = ServerCredentials(vault)
        val logs = mutableListOf<String>()
        val calls = mutableListOf<Pair<String,Map<String,String>>>()
        var existing: Any? = null
        var syncCreates = 0; var opdsCreates = 0
        var lastDownload = false
        val now = Instant.parse("2026-11-25T12:00:00Z").epochSecond
        val account = BookOrbitAccount(credentials.accountVault, object : BookOrbitAccount.Http {
            override fun request(server: String, path: String, method: String, body: Map<String, Any?>?, bearer: String?): BookOrbitAccount.Reply = when {
                path == "/auth/login" -> BookOrbitAccount.Reply(200,mapOf("accessToken" to "private-access", "refreshToken" to "private-refresh", "accessTokenExpiresAt" to Instant.ofEpochSecond(now+900).toString(), "refreshTokenExpiresAt" to Instant.ofEpochSecond(now+604800).toString(), "user" to mapOf("id" to 7)))
                path == "/koreader/credentials" && method == "GET" -> BookOrbitAccount.Reply(200,existing)
                path == "/koreader/credentials" && method == "POST" -> { syncCreates++; existing = mapOf("username" to body!!["username"]); BookOrbitAccount.Reply(201) }
                path == "/opds-users" && method == "POST" -> { opdsCreates++; BookOrbitAccount.Reply(201) }
                else -> BookOrbitAccount.Reply(200,emptyList<Any>())
            }
        }, {now}, logs::add, setupOnSignIn = { false })
        val adapter = BookOrbitServerAdapter(credentials,account,object : BookOrbitServerAdapter.ConnectorTransport {
            override fun request(server: String, path: String, method: String, body: Map<String, Any?>?, headers: Map<String, String>): BookOrbitAccount.Reply {
                calls.add(path to headers)
                return BookOrbitAccount.Reply(200, when {
                    path.startsWith("/opds/catalog") -> """<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>Moon</title><author><name>Fixture</name></author><link rel="http://opds-spec.org/acquisition" href="/api/v1/opds/1/download?fileId=1" type="application/epub+zip"/></entry></feed>"""
                    else -> mapOf("progress" to "position", "percentage" to 0.5, "userkey" to "must-not-escape")
                })
            }
            override fun download(server: String,path: String,headers: Map<String,String>,destination: File): Boolean { calls.add(path to headers); lastDownload = true; return true }
        })
        fun user(kind: String) = adapter.setLogin(kind,"https://library.invalid","direct-$kind","separate-secret".toCharArray())
        fun account() = adapter.signIn("https://library.invalid","fixture","account-password".toCharArray())
        fun set(kind: String) = (adapter.state()[kind] as Map<*,*>)["set"]
        fun origin(kind: String) = (adapter.state()[kind] as Map<*,*>)["origin"]
        fun canSync() = adapter.position("a".repeat(32))
    }
    @Test fun syncAndOpdsWorkIndividuallyWithoutAccountAndNeverReturnSecrets() {
        val sync = Kit(); sync.user("sync")
        assertEquals(false,sync.adapter.state()["signedIn"]); assertEquals(true,sync.set("sync")); assertEquals(false,sync.set("opds"))
        assertEquals(32,sync.credentials.login("sync")!!.secret.length)
        val position = sync.canSync(); assertEquals(0.5,position["percentage"])
        assertFalse(position.toString().contains("must-not-escape"))
        assertNotNull(sync.calls.last().second["x-auth-key"])
        val opds = Kit(); opds.user("opds")
        assertEquals(false,opds.set("sync")); assertEquals(true,opds.set("opds"))
        val catalog = opds.adapter.catalog(); val row = (catalog["items"] as List<*>).single() as Map<*,*>
        assertEquals("Moon",row["title"]); assertFalse(row.toString().contains("/opds/"))
        assertTrue(opds.adapter.download(row["key"] as String,File("unused-test-destination")))
        for (result in listOf(position,sync.adapter.state(),opds.adapter.state(),catalog,sync.logs,opds.logs)) {
            for (secret in listOf("separate-secret","private-access","private-refresh","must-not-escape")) assertFalse(result.toString(),result.toString().contains(secret))
        }
    }
    @Test fun accountOnlySignOutRemovesBothConnectorsAndStopsSyncAndDownloads() {
        val k = Kit(); k.account()
        assertEquals("account",k.origin("sync")); assertEquals("account",k.origin("opds")); k.canSync()
        val row = ((k.adapter.catalog()["items"] as List<*>).single() as Map<*,*>)
        k.adapter.signOut()
        assertEquals(false,k.set("sync")); assertEquals(false,k.set("opds")); assertNull(k.vault.value)
        try { k.canSync(); fail() } catch (e: BookOrbitAccount.Failure) { assertEquals("unauthorized",e.kind) }
        try { k.adapter.download(row["key"] as String,File("unused")); fail() } catch (e: BookOrbitAccount.Failure) { assertEquals("unauthorized",e.kind) }
    }
    @Test fun userLoginsAreNotOverwrittenByAccountAndSurviveItsSignOut() {
        val k = Kit(); k.user("sync"); k.user("opds")
        val key = k.credentials.login("sync")!!.secret
        k.account(); assertEquals(0,k.syncCreates); assertEquals(0,k.opdsCreates)
        assertEquals(key,k.credentials.login("sync")!!.secret)
        k.adapter.signOut(); assertEquals("user",k.origin("sync")); assertEquals("user",k.origin("opds")); k.canSync(); k.adapter.catalog()
    }
    @Test fun mixedOriginsRemoveOnlyAccountLoginsAndEachRemovalIsIndependent() {
        val k = Kit(); k.user("sync"); k.account()
        assertEquals("account",k.origin("opds")); k.adapter.signOut()
        assertEquals(true,k.set("sync")); assertEquals(false,k.set("opds")); k.canSync()
        val other = Kit(); other.user("opds"); other.account()
        val row = ((other.adapter.catalog()["items"] as List<*>).single() as Map<*,*>)
        other.adapter.removeLogin("sync"); assertEquals(true,other.set("opds")); assertEquals(true,other.adapter.state()["signedIn"])
        other.adapter.signOut(); assertEquals(true,other.set("opds")); assertTrue(other.adapter.download(row["key"] as String,File("unused")))
    }
    @Test fun explicitlyAdoptedExistingSyncLoginCountsAsAccountOrigin() {
        val k = Kit(); k.user("sync"); k.existing = mapOf("username" to "direct-sync"); k.account()
        assertEquals("user",k.origin("sync"))
        k.adapter.useAccountLogin("sync"); assertEquals("account",k.origin("sync")); assertEquals(0,k.syncCreates)
        k.adapter.signOut(); assertEquals(false,k.set("sync"))
    }
    @Test fun changingAnAccountFilledLoginExplicitlyMakesItUserOrigin() {
        val k = Kit(); k.account(); k.user("sync"); k.adapter.signOut()
        assertEquals(true,k.set("sync")); assertEquals(false,k.set("opds")); k.canSync()
        k.adapter.removeLogin("sync"); assertEquals(false,k.set("sync"))
    }
    @Test fun accountRemainsUsableWhenBothOptionalConnectorsAreRemoved() {
        val k = Kit(); k.account()
        k.adapter.removeLogin("sync"); k.adapter.removeLogin("opds")
        assertEquals(true,k.adapter.state()["signedIn"])
        val owner = k.adapter.owner()!!
        assertTrue(owner.startsWith("account:")); assertNotNull(k.adapter.stats(owner))
        assertEquals(false,k.set("sync")); assertEquals(false,k.set("opds"))
    }

}
