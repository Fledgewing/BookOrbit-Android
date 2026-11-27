// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class LegacyLoginAdoptionTest {
    private class Vault : AccountVault {
        var value: Map<String,Any?>? = null
        var failBefore=false
        var failAfter=false
        override fun load()=value
        override fun save(value: Map<String,Any?>?) {
            if(failBefore) error("fixture crash before checkpoint")
            this.value=value?.toMap()
            if(failAfter) error("fixture crash after checkpoint")
        }
    }
    private fun fixture(root: File): Pair<File,File> {
        val settings=File(root,"settings.reader.lua")
        settings.writeBytes(LuaValue.encode(mapOf("bookorbit" to mapOf("server_url" to "https://library.invalid/api/v1",
            "username" to LuaValue.str("fixture-读者"),"userkey" to "a".repeat(32)))).let { "return ".toByteArray()+it })
        val opds=File(root,"opds.lua")
        opds.writeText("return {[\"servers\"]={{[\"url\"]=\"https://library.invalid/api/v1/opds\",[\"username\"]=\"fixture-opds\",[\"password\"]=\"fixture-private\"}}}")
        return settings to opds
    }
    @Test fun upgradePreservesBothIndependentLoginsAndLegacyCatalogIdentity() {
        val root=Files.createTempDirectory("legacy-adopt").toFile()
        try {
            val (settings,opds)=fixture(root); val original=settings.readBytes(); val v=Vault()
            val c=ServerCredentials(v); LegacyLoginAdoption.run(c,settings,opds)
            for(kind in ServerCredentials.KINDS) {
                assertEquals(true,c.status(kind)["set"]); assertEquals("user",c.status(kind)["origin"])
                assertEquals(LegacyCoverSource.read(settings)!!.owner,c.login(kind)!!.owner())
            }
            assertEquals("fixture-读者",c.login("sync")!!.user)
            assertEquals("a".repeat(32),c.login("sync")!!.secret)
            assertEquals("fixture-private",c.login("opds")!!.secret)
            c.accountVault.save(mapOf("access" to "fixture")); c.accountVault.save(null)
            assertNotNull(c.login("sync")); assertNotNull(c.login("opds"))
            c.remove("sync"); c.remove("opds")
            val restarted=ServerCredentials(v); LegacyLoginAdoption.run(restarted,settings,opds)
            assertNull(restarted.login("sync")); assertNull(restarted.login("opds"))
            assertArrayEquals(original,settings.readBytes())
        } finally { root.deleteRecursively() }
    }
    @Test fun noLoginAndUnavailableStorageDoNotInventCredentials() {
        val root=Files.createTempDirectory("legacy-empty").toFile()
        try {
            val v=Vault(); val c=ServerCredentials(v); val settings=File(root,"settings.reader.lua"); val opds=File(root,"opds.lua")
            LegacyLoginAdoption.run(c,settings,opds); assertNull(v.value)
            settings.writeText("return {}")
            LegacyLoginAdoption.run(c,settings,opds)
            assertTrue(c.legacyImported()); assertNull(c.login("sync")); assertNull(c.login("opds"))
        } finally { root.deleteRecursively() }
    }
    @Test fun upgradeCanAdoptAnIndependentOpdsLoginWithoutSync() {
        val root=Files.createTempDirectory("legacy-opds-only").toFile()
        try {
            val (settings,opds)=fixture(root); settings.writeText("return {}")
            val c=ServerCredentials(Vault()); LegacyLoginAdoption.run(c,settings,opds)
            assertNull(c.login("sync")); assertEquals("user",c.status("opds")["origin"])
            assertEquals("fixture-private",c.login("opds")!!.secret)
        } finally { root.deleteRecursively() }
    }
    @Test fun crashesBeforeAndAfterTheAtomicCheckpointAreIdempotent() {
        val root=Files.createTempDirectory("legacy-crash").toFile()
        try {
            val (settings,opds)=fixture(root)
            for(after in listOf(false,true)) {
                val v=Vault().apply { failBefore=!after; failAfter=after }
                val c=ServerCredentials(v)
                assertThrows(IllegalStateException::class.java) { LegacyLoginAdoption.run(c,settings,opds) }
                assertNull(c.login("sync")); assertNull(c.login("opds"))
                v.failBefore=false; v.failAfter=false
                val restarted=ServerCredentials(v); LegacyLoginAdoption.run(restarted,settings,opds)
                assertTrue(restarted.legacyImported()); assertNotNull(restarted.login("sync")); assertNotNull(restarted.login("opds"))
            }
        } finally { root.deleteRecursively() }
    }
    @Test fun currentLoginsWinAndUnrelatedOpdsIsNeverAdopted() {
        val root=Files.createTempDirectory("legacy-current").toFile()
        try {
            val (settings,opds)=fixture(root); val c=ServerCredentials(Vault())
            c.set("sync",ServerCredentials.Login("https://other.invalid/api/v1","new-user","b".repeat(32),"user"))
            opds.writeText(opds.readText().replace("library.invalid","unrelated.invalid"))
            LegacyLoginAdoption.run(c,settings,opds)
            assertEquals("new-user",c.login("sync")!!.user); assertNull(c.login("opds"))
        } finally { root.deleteRecursively() }
    }
}
