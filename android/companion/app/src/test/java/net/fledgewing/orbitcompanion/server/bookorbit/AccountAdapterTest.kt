package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.time.Instant

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AccountAdapterTest {
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
        var provision: ByteArray? = null
        var syncCreates = 0; var opdsCreates = 0
        var selection = "first"
        var dashboardCode = 200
        var lastBody: Map<String,Any?>? = null
        var lastDownload = false
        val now = Instant.parse("2026-11-25T12:00:00Z").epochSecond
        val account = BookOrbitAccount(credentials.accountVault, object : BookOrbitAccount.Http {
            override fun request(server: String, path: String, method: String, body: Map<String, Any?>?, bearer: String?): BookOrbitAccount.Reply = when {
                path.startsWith("/koreader/plugin-package?") -> BookOrbitAccount.Reply(200,provision?.copyOf())
                path == "/auth/login" -> BookOrbitAccount.Reply(200,mapOf("accessToken" to "private-access", "refreshToken" to "private-refresh", "accessTokenExpiresAt" to Instant.ofEpochSecond(now+900).toString(), "refreshTokenExpiresAt" to Instant.ofEpochSecond(now+604800).toString(), "user" to mapOf("id" to 7)))
                path == "/koreader/credentials" && method == "GET" -> BookOrbitAccount.Reply(200,existing)
                path == "/koreader/credentials" && method == "POST" -> { syncCreates++; existing = mapOf("username" to body!!["username"]); BookOrbitAccount.Reply(201) }
                path == "/opds-users" && method == "POST" -> { opdsCreates++; BookOrbitAccount.Reply(201) }
                else -> BookOrbitAccount.Reply(200,emptyList<Any>())
            }
        }, {now}, logs::add, setupOnSignIn = { false })
        var coverOwner: String? = null
        var coverId: Long? = null
        val adapter = BookOrbitServerAdapter(credentials,account,object : BookOrbitServerAdapter.ConnectorTransport {
            override fun request(server: String, path: String, method: String, body: Map<String, Any?>?, headers: Map<String, String>): BookOrbitAccount.Reply {
                calls.add(path to headers); lastBody = body
                if (path == "/koreader/plugin/catalog/dashboard" && dashboardCode != 200) return BookOrbitAccount.Reply(dashboardCode)
                return BookOrbitAccount.Reply(200, when {
                    path == "/koreader/plugin/catalog/dashboard" -> mapOf("readingYear" to mapOf("startDate" to "2026-11-25","minutes" to listOf(3)),
                        "readingGoal" to mapOf("year" to 2026,"goalBooks" to 12,"completedBooks" to 2))
                    path.startsWith("/opds/catalog") -> """<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>Moon</title><author><name>Fixture</name></author><link rel="http://opds-spec.org/acquisition" href="/api/v1/opds/1/download?fileId=1&amp;selection=$selection" type="application/epub+zip"/></entry></feed>"""
                    else -> mapOf("progress" to "position", "percentage" to 0.5, "userkey" to "must-not-escape")
                })
            }
            override fun download(server: String,path: String,headers: Map<String,String>,destination: File): Boolean { calls.add(path to headers); lastDownload = true; return true }
        }) { _, owner, id, done ->
            coverOwner=owner; coverId=id; done(mapOf("local_path" to "/fixture/cover.jpg"),null)
        }
        fun user(kind: String) = adapter.setLogin(kind,"https://library.invalid","direct-$kind","separate-secret".toCharArray())
        fun account() = adapter.signIn("https://library.invalid","fixture","account-password".toCharArray())
        fun set(kind: String) = (adapter.state()[kind] as Map<*,*>)["set"]
        fun origin(kind: String) = (adapter.state()[kind] as Map<*,*>)["origin"]
        fun canSync() = adapter.position("a".repeat(32))
    }
    @Test fun coverCommandResolvesOnlyCurrentAccountKeysInsideAdapter() {
        val k=Kit(); k.user("sync")
        val owner=k.credentials.login("sync")!!.owner()
        var result: Map<String,Any?>? = null
        k.adapter.acquireCover(BookOrbitLibrary.key(owner,"book",7)) { value,error ->
            assertNull(error); result=value
        }
        assertEquals(owner,k.coverOwner); assertEquals(7L,k.coverId)
        assertEquals("/fixture/cover.jpg",result!!["local_path"])
        k.coverId=null
        try {
            k.adapter.acquireCover(BookOrbitLibrary.key("another-account","book",7)) { _,_ -> fail() }
            fail()
        } catch (e: ServerFailure) { assertEquals("missing",e.kind) }
        assertNull(k.coverId)
        k.adapter.removeLogin("sync")
        try { k.adapter.acquireCover(BookOrbitLibrary.key(owner,"book",7)) { _,_ -> fail() }; fail() }
        catch (e: ServerFailure) { assertEquals("unauthorized",e.kind) }
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

    @Test fun accountRefillReusesItsKnownKeyAndExplicitAdoptionUsesTheCurrentUserKey() {
        val k = Kit(); k.account()
        val known = k.credentials.login("sync")!!
        k.provision = SyncProvisionTest.archive(known.user,known.secret)
        k.adapter.removeLogin("sync"); k.account()
        assertEquals(known.secret,k.credentials.login("sync")!!.secret)
        val direct = "f".repeat(32)
        k.adapter.setLogin("sync",known.server,known.user,direct.toCharArray(),derivedKey=true)
        k.adapter.useAccountLogin("sync")
        assertEquals(direct,k.credentials.login("sync")!!.secret)
        assertEquals("account",k.origin("sync"))
    }

    @Test fun standaloneSyncPreservesLocatorsAndRejectsOversizeWritesWithoutSendingThem() {
        val k = Kit(); k.user("sync")
        k.adapter.position("a".repeat(32),mapOf("percentage" to 0.5,"position" to LuaValue.str("位置")))
        assertEquals("位置",k.lastBody!!["progress"])
        val count = k.calls.size
        try { k.adapter.position("a".repeat(32),mapOf("percentage" to 0.5,"position" to "x".repeat(4097))); fail() }
        catch (_: IllegalArgumentException) { }
        assertEquals(count,k.calls.size)
    }

    @Test fun durableWritesKeepCaptureTimeAndUseSyncOwnershipEvenWithAnIndependentCatalog() {
        val k = Kit(); k.user("sync")
        val syncOwner = k.adapter.positionOwner()
        k.user("opds")
        assertEquals(syncOwner,k.adapter.positionOwner())
        assertNotEquals(k.adapter.owner(),k.adapter.positionOwner())
        k.adapter.position("a".repeat(32),mapOf("percentage" to 0.5,"position" to "locator","capturedAt" to 1234L))
        assertEquals(1234L,k.lastBody!!["timestamp"])
        val count = k.calls.size
        assertThrows(IllegalArgumentException::class.java) {
            k.adapter.position("a".repeat(32),mapOf("percentage" to 0.5,"capturedAt" to -1L))
        }
        assertEquals(count,k.calls.size)
        k.adapter.removeLogin("sync")
        assertNull(k.adapter.positionOwner())
        assertNotNull(k.adapter.owner())
    }

    @Test fun failedExplicitAccountReplacementKeepsTheDirectLoginAndReportsFailure() {
        val k = Kit(); k.user("sync"); k.existing = mapOf("username" to "other-sync"); k.account()
        val key = k.credentials.login("sync")!!.secret
        try { k.adapter.useAccountLogin("sync"); fail() }
        catch (e: BookOrbitAccount.Failure) { assertEquals("unavailable",e.kind) }
        assertEquals("user",k.origin("sync")); assertEquals(key,k.credentials.login("sync")!!.secret); k.canSync()
    }

    @Test fun existingServerSyncProvisionIsAdoptedAsAccountOriginAndRemovedOnSignOut() {
        val k = Kit(); k.existing = mapOf("username" to "existing-sync")
        k.provision = SyncProvisionTest.archive("existing-sync","c".repeat(32))
        k.account()
        assertEquals(0,k.syncCreates); assertEquals("account",k.origin("sync"))
        assertEquals("c".repeat(32),k.credentials.login("sync")!!.secret)
        k.canSync(); k.adapter.signOut()
        assertEquals(false,k.set("sync")); assertEquals(false,k.set("opds"))
        try { k.canSync(); fail() } catch (e: BookOrbitAccount.Failure) { assertEquals("unauthorized",e.kind) }
    }

    @Test fun directSyncProvidesConnectorStatisticsAfterAccountSignOut() {
        val k = Kit(); k.user("sync"); k.account(); k.adapter.refreshStats()
        assertEquals(12L,k.adapter.fallbackReadingStats()!!.target)
        k.adapter.signOut()
        assertEquals(2L,k.adapter.fallbackReadingStats()!!.finished)
        k.adapter.refreshStats(); assertEquals(12L,k.adapter.fallbackReadingStats()!!.target)
        k.adapter.removeLogin("sync"); assertNull(k.adapter.fallbackReadingStats())
    }

    @Test fun unsupportedConnectorStatisticsDisableOnlyThatFeatureWithoutRetries() {
        val k = Kit(); k.user("sync"); k.dashboardCode = 403
        k.adapter.refreshStats(); k.adapter.refreshStats()
        assertEquals(1,k.calls.count { it.first == "/koreader/plugin/catalog/dashboard" })
        assertNull(k.adapter.fallbackReadingStats()); k.canSync()
    }

    @Test fun accountCatalogIdentitySurvivesDeliveryLocatorChangesAndRelogin() {
        val k = Kit(); k.account()
        fun key() = ((k.adapter.catalog()["items"] as List<*>).single() as Map<*,*>)["key"]
        val first = key()
        k.selection = "second"; assertEquals(first,key())
        k.adapter.signOut(); k.account(); assertEquals(first,key())
    }

    @Test fun removingSyncDeletesItsSecretWithoutRemovingAccountOrOpds() {
        val k = Kit(); k.account()
        val secret = k.credentials.login("sync")!!.secret
        k.adapter.removeLogin("sync")
        assertFalse(k.vault.value.toString().contains(secret))
        assertEquals(true,k.adapter.state()["signedIn"]); assertEquals(true,k.set("opds"))
    }

    @Test fun displayStateUsesEachLoginsOwnAddressAndNameWithoutExportingSecrets() {
        val k = Kit(); k.user("sync"); k.account()
        val state = k.adapter.state()
        assertEquals("fixture", LuaValue.utf8(state["username"] as String))
        assertEquals("https://library.invalid/api/v1", state["server"])
        val sync = state["sync"] as Map<*, *>
        assertEquals(k.credentials.login("sync")!!.server,sync["server"])
        assertEquals(k.credentials.login("sync")!!.user,LuaValue.utf8(sync["username"] as String))
        assertEquals("user",sync["origin"])
        assertEquals("created",(state["opds"] as Map<*, *>)["outcome"])
        for (key in listOf("password","secret","access","refresh","key")) assertFalse(state.toString(),state.toString().contains("$key="))
    }

}
