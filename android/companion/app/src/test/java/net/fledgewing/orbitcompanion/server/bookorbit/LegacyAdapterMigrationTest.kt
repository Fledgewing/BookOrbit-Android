package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class LegacyAdapterMigrationTest {
    private class Vault : AccountVault {
        var value: Map<String,Any?>?=null
        override fun load()=value
        override fun save(value: Map<String,Any?>?) { this.value=value }
    }
    @Test fun entryProvenanceUsesItsOldAccountWithoutRebindingCurrentLogin() {
        val root=Files.createTempDirectory("sync-provenance").toFile()
        try {
            val settings=File(root,"settings").also { it.mkdirs() }
            val old=ServerCredentials.Login("https://old.invalid/api/v1","old-reader","a".repeat(32),"user")
            val current=ServerCredentials.Login("https://new.invalid/api/v1","new-reader","b".repeat(32),"user")
            val credentials=ServerCredentials(Vault()).also { it.set("sync",current) }
            val account=BookOrbitAccount(credentials.accountVault,object : BookOrbitAccount.Http {
                override fun request(server: String,path: String,method: String,body: Map<String,Any?>?,bearer: String?): BookOrbitAccount.Reply = error("migration must not use network")
            },setupOnSignIn={false})
            val adapter=BookOrbitServerAdapter(credentials,account,object : BookOrbitServerAdapter.ConnectorTransport {
                override fun request(server: String,path: String,method: String,body: Map<String,Any?>?,headers: Map<String,String>): BookOrbitAccount.Reply = error("migration must not use network")
                override fun download(server: String,path: String,headers: Map<String,String>,destination: File): Boolean = error("migration must not download")
            })
            val digest="a".repeat(32); val id="entry_${digest}_100_1"
            fun literal(file: File,value: Map<String,Any?>) { file.parentFile!!.mkdirs(); file.writeBytes("return ".toByteArray()+LuaValue.encode(value)) }
            literal(File(root,"settings.reader.lua"),mapOf("bookorbit" to mapOf("server_url" to current.server,"username" to current.user)))
            literal(File(settings,"bookorbit_sync_state.lua"),mapOf("account_identity" to "${old.server}|${old.user}","books" to mapOf(digest to mapOf("file" to "/fixture/one.epub","ratingSyncedKnown" to true,"ratingSynced" to 4,"reviewSyncedKnown" to true,"reviewSyncedNote" to "old review"))))
            literal(File(settings,"bookorbit-lifecycle-outbox/${id}_g1.lua"),mapOf("version" to 1,"id" to id,"generation" to 1,"payload_generation" to 1,"digest" to digest,"acknowledged" to emptyMap<String,Any>()))
            literal(File(settings,"bookorbit-lifecycle-outbox/${id}_payload_g1.lua"),mapOf("version" to 1,"id" to id,"digest" to digest,"snapshot" to mapOf("digest" to digest,"file" to "/fixture/one.epub","ts" to 100,"percentage" to .5)))
            JdbcSql(File(root,"journal.db")).use { sql ->
                val queue=LifecycleQueue(sql)
                assertEquals(1,adapter.importLifecycle(queue,settings,true))
                assertEquals(1,queue.pending(adapter.id,old.owner()))
                assertEquals(0,queue.pending(adapter.id,current.owner()))
                assertEquals(current.owner(),credentials.login("sync")!!.owner())
                assertEquals(current.secret,credentials.login("sync")!!.secret)
                assertTrue(queue.window(adapter.id,old.owner()).single().retired)
                val known=sql.query("SELECT body FROM adapter_sync_books WHERE owner=? AND document=?",old.owner(),digest) { LuaValue.parse(it.bytes(0)!!) as Map<*, *> }.single()
                assertEquals(4L,known["ratingSynced"]); assertEquals("old review",known["reviewSyncedNote"])
                assertEquals(true,known["ratingSyncedKnown"]); assertEquals(true,known["reviewSyncedKnown"])
                assertTrue(sql.query("SELECT body FROM adapter_sync_books WHERE owner=?",current.owner()) { it.bytes(0)!! }.isEmpty())
            }
        } finally { root.deleteRecursively() }
    }
}
