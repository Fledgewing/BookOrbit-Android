// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

/** Transport fixtures moved from the retired Lua interpreter. SQL/filter/refresh behavior also
 * remains exercised by CacheStoreTest, BulkCatalogTest, FastCatalogTest and CacheWorkerTest. */
class CatalogControlTest {
    private val inventory get() = LuaValue.fromJson(File("../../../shared/fixtures/catalog/sections.json").readText())
    private val owner="fixture|https://library.example/api/v1"
    private fun <T> store(block:(CacheStore)->T):T {
        val root=Files.createTempDirectory("catalog-control").toFile()
        return try { CacheStore(root,{},::JdbcSql).use { it.own(owner); block(it) } } finally { root.deleteRecursively() }
    }
    private fun request(args: Map<String,Any?>) = String(LuaValue.encode(mapOf("bytes" to 16384L,"limit" to 24L)+args),Charsets.ISO_8859_1)
    private fun snapshot(store:CacheStore,args:Map<String,Any?>):Map<*,*> {
        val request=request(args)
        LibraryReadModel(store,log={}).publish(owner,listOf(request))
        val bytes=store.db().query("SELECT body FROM library_views WHERE owner=? AND request=?",owner,LuaValue.utf8(request)) { it.bytes(0)!! }.single()
        assertTrue(bytes.size<=16384)
        return LuaValue.parse(bytes) as Map<*,*>
    }
    @Test fun plannerOwnsTheSharedInventoryAndEveryTemplate() {
        assertEquals(inventory,CatalogPlan.inventory)
        val plan=CatalogPlan.create(owner,"full",listOf(3L,1L,3L),true,"/fixture/covers",1234L,true,run="fixture")
        assertEquals(listOf(1L,3L),plan.ids("seed_details"))
        assertEquals("full",plan.op);assertEquals(1234L,plan.limit);assertTrue(plan.coversOn)
        assertEquals(5,plan.templates.size);assertEquals(5,plan.strings("sections").size)
        assertTrue(plan.strings("entries").contains("/koreader/plugin/catalog/dashboard/sections/want-to-read"))
        assertTrue(plan.strings("browse_lists").any { "order=asc" in it && "readStatus=reading" in it })
        assertTrue(plan.detailTemplate!!.endsWith(MirrorLogic.SENTINEL))
        assertFalse(LuaValue.encode(plan.m).toString(Charsets.ISO_8859_1).contains("secret"))
    }
    @Test fun opaqueManagedOwnerDoesNotBecomeAServerLocator() {
        val plan=CatalogPlan.create("login:opaque","resume",emptyList(),false,"/fixture/covers",null,false,server="https://library.example/api/v1")
        assertEquals("login:opaque",plan.owner);assertEquals("https://library.example/api/v1",plan.server)
    }
    @Test fun offlineLegacyWindowsAndSearchDecodeOnlyDisplayRows() = store { st ->
        val path="/koreader/plugin/catalog/books?sort=title&order=asc&page=1&size=80"
        val books=(1L..80L).map { mapOf("id" to it,"title" to "Book $it","authors" to listOf("Fixture author"),"hasCover" to true,"updatedAt" to "2026-11-26") }
        st.save(MirrorLogic.key(owner,owner.substringAfter('|'),path),path,mapOf("items" to books,"total" to 80L),1000L,null)
        val result=snapshot(st,mapOf("op" to "connector.catalog","view" to "books","selection" to mapOf("sort" to "title","direction" to "asc"),"offset" to 24L))
        val rows=result["items"] as List<*>
        assertEquals(24,rows.size);assertEquals(25L,(rows.first() as Map<*,*>)["reference"]);assertEquals(80L,result["total"])
        val encoded=LuaValue.encode(result).toString(Charsets.ISO_8859_1)
        for(word in listOf("hasCover","updatedAt","readStatus","userkey","thumbnailUrl")) assertFalse(word,encoded.contains(word))
        val search=snapshot(st,mapOf("op" to "connector.catalog","view" to "books","selection" to mapOf("search" to "Fixture author"),"limit" to 5L))
        assertEquals(80L,search["total"]);assertEquals(5,(search["items"] as List<*>).size)
        assertEquals(0L,st.search("%' OR 1=1 --",0,24)["total"])
        assertEquals(0L,st.search("_",0,24)["total"])
    }
    @Test fun detailAndIndexShapesAreNeutralAndAccountScoped() = store { st ->
        val path="/koreader/plugin/catalog/books/7"
        st.save("detail",path,mapOf("id" to 7L,"title" to "Saved detail","readStatus" to "reading","files" to listOf(mapOf("id" to 8L,"format" to "epub","size" to 12L))),2L,"/koreader/plugin/catalog/books/${MirrorLogic.SENTINEL}")
        val result=snapshot(st,mapOf("op" to "connector.catalog","view" to "book","reference" to 7L,"limit" to 1L))
        val row=(result["items"] as List<*>).single() as Map<*,*>
        assertEquals("Saved detail",row["title"]);assertEquals(8L,((row["files"] as List<*>).single() as Map<*,*>)["reference"])
        val request=request(mapOf("op" to "connector.catalog","view" to "book","reference" to 7L))
        assertFalse(LibraryReadModel(st,log={}).publish("other",listOf(request)))
        assertEquals(owner,st.meta("owner"))
    }
    @Test fun progressIsOneBoundedSnapshotWithoutCredentialsOrLargeSummary() = store { st ->
        File(st.root,"mirror/status.lua").apply { parentFile!!.mkdirs(); writeBytes(LuaValue.encode(mapOf("engine" to "bulk","owner" to owner,"run" to "r","running" to true,"pct" to 42L,"done" to 42L,"total" to 100L,"left" to 58L,"beat" to 123L,"userkey" to "private","lib_version" to "private"))) }
        val result=snapshot(st,mapOf("op" to "catalog.state","limit" to 1L))
        assertEquals(1L,result["row_count"]);assertEquals(42L,result["pct"]);assertEquals(true,result["running"])
        assertFalse(result.containsKey("userkey"));assertFalse(result.containsKey("lib_version"))
    }
    @Test fun oversizedSnapshotFailsClosedBeforeThePluginCanDecodeIt() = store { st ->
        val path="/koreader/plugin/catalog/books?sort=title&size=24"
        val books=(1L..24L).map { mapOf("id" to it,"title" to "x".repeat(2000)) }
        st.save("large",path,mapOf("items" to books,"total" to 24L),1L,null)
        val result=snapshot(st,mapOf("op" to "connector.catalog","view" to "books","selection" to mapOf("sort" to "title")))
        assertEquals("budget",result["error"]);assertTrue((result["items"] as List<*>).isEmpty())
    }
    @Test fun otherAdaptersCanExplicitlyDeclineCatalogControl() {
        var called=false
        val adapter=object:ServerAdapter { override val id="fixture" }
        adapter.catalogControl("opaque","full",true) { result,error -> called=true;assertNull(result);assertEquals("unsupported",error) }
        assertTrue(called)
    }    @Test fun catalogCommandsCaptureOnlyTheOriginatingAccountsCredentials() {
        val vault=object:AccountVault {
            override fun load():Map<String,Any?>?=null
            override fun save(value:Map<String,Any?>?) {}
        }
        val credentials=ServerCredentials(vault)
        val account=BookOrbitAccount(credentials.accountVault,object:BookOrbitAccount.Http {
            override fun request(server:String,path:String,method:String,body:Map<String,Any?>?,token:String?):BookOrbitAccount.Reply = error("catalog enqueue must not make account HTTP calls")
        })
        val login=CacheWorker.Creds("https://library.example/api/v1","fixture","private-fixture-key")
        var legacy:LegacyCoverSource.Account?=LegacyCoverSource.Account("native-opaque",login)
        var queued=0
        val adapter=BookOrbitServerAdapter(credentials,account,object:BookOrbitServerAdapter.ConnectorTransport {
            override fun request(server:String,path:String,method:String,body:Map<String,Any?>?,headers:Map<String,String>):BookOrbitAccount.Reply = error("enqueue cannot fetch")
            override fun download(server:String,path:String,headers:Map<String,String>,destination:File)=error("enqueue cannot download")
        },legacyAccount={legacy},catalogJob={ c,origin,action,manual,done ->
            queued++;assertSame(login,c);assertEquals("native-opaque",origin);assertEquals("full",action);assertTrue(manual)
            done(mapOf("running" to true),null)
        })
        assertEquals("native-opaque",adapter.owner())
        assertEquals(true,(adapter.state()["catalog"] as Map<*,*>)["cachedDetail"])
        adapter.catalogControl("native-opaque","full",true) { result,error -> assertNull(error);assertEquals(true,result!!["running"]) }
        assertEquals(1,queued)
        legacy=LegacyCoverSource.Account("later-account",login)
        try { adapter.catalogControl("native-opaque","full",true) { _,_->fail("stale command accepted") };fail("stale account accepted") }
        catch(e:ServerFailure) { assertEquals("canceled",e.kind) }
        assertEquals(1,queued)
    }
    @Test fun refreshPolicyResumesWithoutResettingAndDoesNotLoopUnderStoragePressure() {
        val state=mapOf("op" to "full","left" to 58L,"done" to 42L,"limit_note" to mapOf("limit" to 100L))
        assertNull(CatalogPlan.operation("incremental",state,100L,false,2000,0))
        assertEquals("resume",CatalogPlan.operation("full",state,100L,true,2000,0))
        assertEquals("resume",CatalogPlan.operation("resume",state,200L,false,2000,0))
        assertEquals(42L,state["done"])
        assertNull(CatalogPlan.operation("incremental",emptyMap(),null,false,2000,0))
        assertEquals("full",CatalogPlan.operation("refresh",emptyMap(),null,true,2000,0))
        assertEquals("revalidate",CatalogPlan.operation("refresh",mapOf("at" to 1L),null,true,2000,0))
        assertNull(CatalogPlan.operation("incremental",mapOf("at" to 1L),null,false,2000,1999))
    }
    @Test fun legacyProgressRequiresItsMatchingPrivatePlanAndNeverCrossesOwners() = store { st ->
        val dir=File(st.root,"mirror").apply { mkdirs() }
        File(dir,"status.lua").writeBytes(LuaValue.encode(mapOf("engine" to "bulk","op" to "full","done" to 42L,"left" to 58L)))
        assertNull(CatalogPlan.status(st)["done"])
        File(dir,"plan.lua").writeBytes(LuaValue.encode(mapOf("owner" to owner)))
        assertEquals(42L,CatalogPlan.status(st)["done"])
        st.own("other")
        assertNull(CatalogPlan.status(st)["done"])
        assertTrue(CatalogPlan.status(st)["saved_label"].toString().startsWith("Not saved"))
    }
    @Test fun qualifiedOfflineCoversStayMarkedInBothScopedAndGlobalStorageCounts() {
        val root=Files.createTempDirectory("catalog-cover-scope").toFile()
        val worker=CacheWorker(root,{_,_,_,_->error("storage cannot fetch")},log={},openSql=::JdbcSql)
        try {
            worker.store.own(owner)
            val covers=File(root,"covers").apply { mkdirs() }
            val folder=File(covers,BookOrbitLibrary.namespace(owner)).apply { mkdirs() }
            File(folder,"7_1.jpg").writeText("fixture")
            worker.store.keepCovers(listOf("${folder.name}/7_1.jpg"))
            assertEquals("mirror_cover",worker.storageItems(covers.path,true).single { it.k.startsWith("c:") }.kind)
            assertEquals("mirror_cover",worker.storageItems(folder.path,true).single { it.k.startsWith("c:") }.kind)
        } finally { worker.store.close();root.deleteRecursively() }
    }
    @Test fun crawlEraProgressCannotBeShownOrResumedAsBulkWork() = store { st ->
        File(st.root,"mirror/status.lua").apply { parentFile!!.mkdirs();writeBytes(LuaValue.encode(mapOf("owner" to owner,"engine" to "crawl","op" to "full","done" to 85L,"left" to 15L))) }
        val state=CatalogPlan.status(st)
        assertNull(state["done"])
        assertEquals("full",CatalogPlan.operation("full",state,null,true,1000,0))
    }

}
