// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class CatalogSyncHandoffTest {
    private class Vault:AccountVault {
        var data:Map<String,Any?>?=null
        override fun load()=data
        override fun save(value:Map<String,Any?>?) { data=value }
    }
    private fun fixture(existing:Boolean,check:(BookOrbitServerAdapter,ServerCredentials,String,File)->Unit) {
        val root=Files.createTempDirectory("catalog-sync-handoff").toFile()
        try {
            val settings=File(root,"settings").also { it.mkdirs() }
            val server="https://library.example/api/v1";val user="reader";val secret="a".repeat(32)
            val legacyOwner="$user|$server"
            val vault=Vault();val credentials=ServerCredentials(vault)
            if(existing) credentials.set("sync",ServerCredentials.Login(server,user,secret,"user"))
            val account=BookOrbitAccount(credentials.accountVault,object:BookOrbitAccount.Http {
                override fun request(server:String,path:String,method:String,body:Map<String,Any?>?,bearer:String?):BookOrbitAccount.Reply = error("migration is local")
            },setupOnSignIn={false})
            val adapter=BookOrbitServerAdapter(credentials,account,object:BookOrbitServerAdapter.ConnectorTransport {
                override fun request(server:String,path:String,method:String,body:Map<String,Any?>?,headers:Map<String,String>):BookOrbitAccount.Reply = error("migration cannot fetch")
                override fun download(server:String,path:String,headers:Map<String,String>,destination:File):Boolean = error("migration cannot download")
            },legacyAccount={LegacyCoverSource.Account(legacyOwner,CacheWorker.Creds(server,user,secret))},
                actionJob={ c,owner,action,_,done -> assertEquals(server,c.server);assertEquals(user,c.user);assertEquals("initialize",action);done(mapOf("owner" to owner),null) })
            val document="b".repeat(32);val id="entry_${document}_100_1"
            fun literal(file:File,data:Map<String,Any?>) { file.parentFile?.mkdirs();file.writeBytes("return ".toByteArray()+LuaValue.encode(data)) }
            literal(File(root,"settings.reader.lua"),mapOf("bookorbit" to mapOf("server_url" to server,"username" to user,"userkey" to secret)))
            literal(File(settings,"bookorbit_sync_state.lua"),mapOf("account_identity" to "$server|$user","books" to mapOf(document to mapOf("file" to "/fixture/book.epub","bookId" to 7L))))
            literal(File(settings,"bookorbit-lifecycle-outbox/${id}_g1.lua"),mapOf("version" to 1,"id" to id,"generation" to 1,"payload_generation" to 1,"digest" to document,"acknowledged" to emptyMap<String,Any>()))
            literal(File(settings,"bookorbit-lifecycle-outbox/${id}_payload_g1.lua"),mapOf("version" to 1,"id" to id,"digest" to document,"snapshot" to mapOf("digest" to document,"file" to "/fixture/book.epub","ts" to 100,"percentage" to .5)))
            val before=adapter.owner()!!
            val pending=File(settings,"orbit-cache/workflows/${BookOrbitLibrary.namespace(before)}.lua")
            literal(pending,mapOf("migrated" to true,"finishes" to mapOf(document to mapOf("ready" to true))))
            JdbcSql(File(root,"journal.db")).use { sql -> assertEquals(1,adapter.importLifecycle(LifecycleQueue(sql),settings,true)) }
            assertEquals(before,adapter.owner())
            assertTrue(pending.isFile)
            assertEquals(pending.name,BookOrbitLibrary.namespace(adapter.owner()!!)+".lua")
            adapter.catalogAction(adapter.owner()!!,"initialize",emptyMap<Any,Any>()) { result,error -> assertNull(error);assertEquals(before,result!!["owner"]) }
            check(adapter,credentials,legacyOwner,pending)
        } finally { root.deleteRecursively() }
    }
    @Test fun adoptingLegacySyncKeepsCatalogCacheAndWorkflowProvenance()=fixture(false) { adapter,credentials,legacy,_ ->
        assertEquals(legacy,adapter.owner());assertEquals(legacy,credentials.login("sync")!!.owner())
        assertEquals(true,(adapter.state()["catalog"] as Map<*,*>)["cachedDetail"])
    }
    @Test fun anExistingManagedLoginKeepsItsOriginalNamespace()=fixture(true) { adapter,credentials,legacy,_ ->
        assertNotEquals(legacy,adapter.owner());assertEquals(credentials.login("sync")!!.owner(),adapter.owner())
    }
}
