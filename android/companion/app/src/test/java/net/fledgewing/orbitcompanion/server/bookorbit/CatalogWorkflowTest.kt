// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class CatalogWorkflowTest {
    private class World : AutoCloseable {
        val external=Files.createTempDirectory("catalog-actions").toFile()
        val root=File(external,"koreader/settings/orbit-cache")
        val owner="reader|https://books.example"
        val creds=CacheWorker.Creds("https://books.example","reader","synthetic-key")
        val old=File(external,"books/old.epub").apply { parentFile!!.mkdirs();writeText("old bytes") }
        val replacement="new book bytes".toByteArray()
        val hash=File(external,"sample").let { it.writeBytes(replacement);CatalogWorkflow.partial(it).also { _ -> it.delete() } }
        val worker=CacheWorker(root,{_,_,_,_->error("unexpected legacy HTTP")},log={},openSql={JdbcSql(it)},bookRoots=listOf(external))
        var reading=false;var current=true;var code=200;var downloadOk=true;var readStatus="unread";var clock=100L
        var fileReference=70L
        val localIntents=mutableListOf<List<Any?>>()
        val calls=mutableListOf<String>()
        val writes=mutableListOf<Map<String,Any?>?>()
        val transport=object:BookOrbitServerAdapter.ConnectorTransport {
            override fun request(server:String,path:String,method:String,body:Map<String,Any?>?,headers:Map<String,String>):BookOrbitAccount.Reply {
                calls.add("$method $path")
                if(method=="PUT") writes.add(body)
                assertEquals("synthetic-key",headers["x-auth-key"])
                return BookOrbitAccount.Reply(code,if(method=="GET") detail() else emptyMap<Any,Any>())
            }
            override fun download(server:String,path:String,headers:Map<String,String>,destination:File):Boolean {
                calls.add("DOWNLOAD $path");if(downloadOk) destination.writeBytes(replacement);return downloadOk
            }
        }
        fun detail()=mapOf("id" to 7L,"title" to "A synthetic book","authors" to listOf("Example writer"),"readStatus" to readStatus,
            "files" to listOf(mapOf("id" to fileReference,"format" to "EPUB","role" to "primary","fileHash" to hash,"devicePath" to "Fiction/Next.epub","downloadVariant" to "audioless_epub","selection" to "revision")))
        init {
            worker.store.own(owner)
            File(root.parentFile,"bookorbit_sync_state.lua").writeBytes(LuaValue.encode(mapOf("account_identity" to "https://books.example|reader",
                "books" to mapOf(CatalogWorkflow.partial(old) to mapOf("file" to old.path,"bookId" to 7L,"fileId" to 70L,"positionIncompatible" to true)))))
            worker.store.putDetail(7,detail(),100)
        }
        fun run(action:String,args:Map<String,Any?> = emptyMap())=CatalogWorkflow(worker,creds,owner,transport,{reading},{current},now={clock},localIntent={d,t,c,u,_ -> localIntents.add(listOf(d,t,c,u))}).command(action,args)
        fun state()=CatalogWorkflow.load(File(root,"workflows/${BookOrbitLibrary.namespace(owner)}.lua"))
        fun jobs()=(state()["finishes"] as? Map<*,*>).orEmpty()
        fun copies()=state()["copies"] as List<*>
        fun events()=File(root,"events").listFiles().orEmpty().filter { it.extension=="lua" }.mapNotNull { LuaValue.parse(it.readBytes()) as? Map<*,*> }
        fun mark()=run("finish.mark",mapOf("path" to old.path,"document" to CatalogWorkflow.partial(old),"complete" to true,"percentage" to 1.0))
        override fun close() { worker.store.close();external.deleteRecursively() }
    }
    private fun sidecar(w:World):File = File(w.old.parentFile,"old.sdr/metadata.epub.lua").apply {
        parentFile!!.mkdirs();writeBytes("return ".toByteArray()+LuaValue.encode(mapOf("summary" to mapOf("status" to "reading","modified" to "2026-01-01","rating" to 4L),
            "percent_finished" to .4,"last_xpointer" to "locator:old","annotations" to listOf(mapOf("text" to "saved note")))))
    }
    @Test fun explicitStatusIsLocalDurableAndHeldForUndoWithoutAnyTransport()=World().use { w ->
        val sidecar=sidecar(w)
        val result=w.run("status.mark",mapOf("reference" to 7L,"status" to "finished","before_status" to "reading"))
        assertNotNull(result["token"]);assertEquals("read",(w.worker.store.detail(7)!!.first as Map<*,*>)["readStatus"])
        assertEquals("complete",((LegacyLifecycleImport.literal(sidecar)!!["summary"] as Map<*,*>)["status"]))
        w.run("finish.drain",mapOf("manual" to true))
        assertTrue(w.calls.isEmpty());assertNull(w.run("status.capture")["capture"])
        w.run("status.undo",mapOf("reference" to 7L,"token" to result["token"]))
        val restored=LegacyLifecycleImport.literal(sidecar)!!
        assertEquals("reading",(restored["summary"] as Map<*,*>)["status"])
        assertEquals(4L,(restored["summary"] as Map<*,*>)["rating"])
        assertEquals("2026-01-01",(restored["summary"] as Map<*,*>)["modified"])
        assertEquals("saved note",((restored["annotations"] as List<*>).single() as Map<*,*>)["text"])
        assertEquals(.4,restored["percent_finished"])
        assertEquals(2,w.localIntents.size)
        assertEquals(true,w.localIntents[0][2]);assertEquals(false,w.localIntents[1][2])
        assertEquals(result["token"],w.localIntents[1][3])
    }
    @Test fun statusDeliveryWaitsForCaptureCheckpointAndRejectsStaleAcknowledgements()=World().use { w ->
        sidecar(w)
        val first=w.run("status.mark",mapOf("reference" to 7L,"status" to "finished"))
        val release=w.run("status.leave",mapOf("token" to first["token"]))
        assertNotEquals(first["native_token"],release["native_token"])
        w.run("finish.drain",mapOf("manual" to true));assertTrue(w.calls.isEmpty())
        val capture=w.run("status.capture")
        assertEquals(first["token"],capture["token"])
        assertEquals(.4,(capture["capture"] as Map<*,*>)["percentage"])
        assertTrue(LuaValue.encode(capture).size<=16384)
        w.run("status.captured",mapOf("token" to capture["token"]))
        w.run("finish.drain",mapOf("manual" to true));assertTrue(w.calls.isEmpty())
        w.run("status.positioned",mapOf("token" to capture["token"]))
        w.run("finish.drain",mapOf("manual" to true))
        assertEquals("read",w.writes.single()!!["status"])
        val hash=CatalogWorkflow.partial(w.old)
        w.run("finish.ack",mapOf("document" to hash,"token" to "obsolete"));assertEquals(1,w.jobs().size)
        w.run("finish.ack",mapOf("document" to hash,"token" to first["token"]));assertTrue(w.jobs().isEmpty())
        try { w.run("status.undo",mapOf("reference" to 7L,"token" to first["token"]));fail("closed Undo control") } catch(e:ServerFailure) { assertEquals("stale",e.kind) }
    }
    @Test fun readerRestartReleasesHeldIntentButOrdinarySleepDoesNot()=World().use { w ->
        sidecar(w)
        val mark=w.run("status.mark",mapOf("reference" to 7L,"status" to "finished"))
        val hash=CatalogWorkflow.partial(w.old)
        w.run("finish.leave",mapOf("document" to hash))
        assertNull(w.run("status.capture")["capture"])
        w.run("initialize")
        assertEquals(mark["token"],w.run("status.capture")["token"])
    }
    @Test fun manualStatusSurvivesStaleResponsesAndTheInFlightCatalogGeneration()=World().use { w ->
        sidecar(w)
        w.worker.store.putItem(w.detail(),100)
        w.worker.store.setMeta("bulk_active","1");w.worker.store.setMeta("bulk_stage_g","2")
        val mark=w.run("status.mark",mapOf("reference" to 7L,"status" to "finished"))
        w.worker.store.putDetail(7,w.detail(),101)
        assertEquals("read",CatalogWorkflow.statusOverrides(w.worker.store,w.owner)[7L]!!.status)
        assertTrue(CatalogWorkflow.statusOverrides(w.worker.store,w.owner)[7L]!!.pending)
        w.run("status.leave",mapOf("token" to mark["token"]))
        w.run("status.captured",mapOf("token" to mark["token"]))
        w.run("status.positioned",mapOf("token" to mark["token"]))
        w.run("finish.drain",mapOf("manual" to true))
        w.run("finish.ack",mapOf("document" to CatalogWorkflow.partial(w.old),"token" to mark["token"]))
        assertFalse(CatalogWorkflow.statusOverrides(w.worker.store,w.owner)[7L]!!.pending)
        w.worker.store.setMeta("bulk_active","2")
        assertEquals("read",CatalogWorkflow.statusOverrides(w.worker.store,w.owner)[7L]!!.status)
        w.worker.store.setMeta("bulk_active","3")
        assertNull(CatalogWorkflow.statusOverrides(w.worker.store,w.owner)[7L])
    }
    @Test fun undoAfterReplacementCannotRewriteTheNewFilesReadingState()=World().use { w ->
        val meta=sidecar(w)
        val mark=w.run("status.mark",mapOf("reference" to 7L,"status" to "finished"))
        w.old.appendText("replacement bytes")
        val before=meta.readBytes()
        try { w.run("status.undo",mapOf("reference" to 7L,"token" to mark["token"]));fail("changed file") } catch(e:ServerFailure) { assertEquals("changed",e.kind) }
        assertArrayEquals(before,meta.readBytes())
    }
    @Test fun rejectedManualStatusRemainsDurableAndCanBeRetriedExplicitly()=World().use { w ->
        sidecar(w)
        val mark=w.run("status.mark",mapOf("reference" to 7L,"status" to "finished"))
        w.run("status.leave",mapOf("token" to mark["token"]))
        w.run("status.captured",mapOf("token" to mark["token"]))
        w.run("status.positioned",mapOf("token" to mark["token"]))
        w.code=403;w.run("finish.drain",mapOf("manual" to true))
        assertEquals(1,w.jobs().size);assertTrue(CatalogWorkflow.statusOverrides(w.worker.store,w.owner)[7L]!!.pending)
        val count=w.calls.size;w.run("finish.drain");assertEquals(count,w.calls.size)
        w.code=200;w.run("finish.drain",mapOf("manual" to true))
        assertEquals("writeback",(w.jobs().values.single() as Map<*,*>)["phase"])
    }
    @Test fun openBookNativeWritebackWaitsForCloseAndKeepsItsAnnotationAndLocator()=World().use { w ->
        val meta=sidecar(w);val original=meta.readBytes()
        val mark=w.run("status.mark",mapOf("reference" to 7L,"status" to "finished","open_path" to w.old.path,
            "before_native" to mapOf("status" to "reading","modified" to "2026-01-01")))
        assertArrayEquals(original,meta.readBytes())
        w.run("status.leave",mapOf("token" to mark["token"],"open_path" to w.old.path))
        assertNotNull(w.run("status.capture",mapOf("open_path" to w.old.path))["capture"])
        w.run("status.captured",mapOf("token" to mark["token"]))
        w.run("status.positioned",mapOf("token" to mark["token"]))
        w.run("finish.drain",mapOf("manual" to true,"open_path" to w.old.path))
        val args=mapOf("document" to CatalogWorkflow.partial(w.old),"token" to mark["token"])
        assertEquals(true,w.run("finish.ack",args+mapOf("open_path" to w.old.path))["retained"])
        assertArrayEquals(original,meta.readBytes());assertEquals(1,w.jobs().size)
        w.run("finish.drain");w.run("finish.ack",args)
        assertTrue(w.jobs().isEmpty())
        val saved=LegacyLifecycleImport.literal(meta)!!
        assertEquals("complete",(saved["summary"] as Map<*,*>)["status"])
        assertEquals(.4,saved["percent_finished"]);assertEquals("locator:old",saved["last_xpointer"])
        assertEquals("saved note",((saved["annotations"] as List<*>).single() as Map<*,*>)["text"])
    }
    @Test fun downloadOptionsUseSavedSupportedManifestsWithoutFetchingAndRejectUnsafePaths()=World().use { w ->
        val key=BookOrbitLibrary.key(w.owner,"book",7)
        val epub=(w.detail()["files"] as List<*>).single() as Map<*,*>
        val pdf=epub+mapOf("id" to 71L,"format" to "PDF","devicePath" to "Fiction/Next.pdf")
        w.worker.store.putDetail(7,w.detail()+mapOf("files" to listOf(epub,pdf,epub+mapOf("format" to "exe"))),100)
        val options=w.run("download.prepare",mapOf("key" to key))["items"] as List<*>
        assertEquals(2,options.size);assertTrue(w.calls.isEmpty())
        assertTrue((options.first() as Map<*,*>)["destination"].toString().endsWith("Fiction/Next.epub"))
        val chosen=File(w.external,"Chosen")
        val explicit=(w.run("download.prepare",mapOf("key" to key,"root" to chosen.path))["items"] as List<*>).first() as Map<*,*>
        assertTrue(explicit["destination"].toString().startsWith(chosen.path+"/"));assertEquals(chosen.path,explicit["destination_label"])
        for(path in listOf("/absolute.epub","../escape.epub","C:/outside.epub")) {
            w.worker.store.putDetail(7,w.detail()+mapOf("files" to listOf(epub+mapOf("devicePath" to path))),100)
            assertThrows(IllegalArgumentException::class.java) { w.run("download.prepare",mapOf("key" to key)) }
        }
    }
    @Test fun selectingAMissingRevisionCannotDownloadADifferentPrimaryFile()=World().use { w ->
        try { w.run("finish.download",mapOf("reference" to 7L,"file_reference" to 999L));fail("missing revision") }
        catch(e:ServerFailure) { assertEquals("missing",e.kind) }
        assertFalse(w.calls.any { it.startsWith("DOWNLOAD") })
    }
    @Test fun catalogDownloadNeverOverwritesAnUnrelatedExplicitDestination()=World().use { w ->
        val target=File(w.external,"books/collision.epub").apply { writeText("unrelated bytes") }
        try { w.run("finish.download",mapOf("reference" to 7L,"destination" to target.path,"file_reference" to 70L));fail("collision") }
        catch(e:ServerFailure) { assertEquals("exists",e.kind) }
        assertEquals("unrelated bytes",target.readText());assertFalse(w.calls.any { it.startsWith("DOWNLOAD") })
    }
    @Test fun ownedSyncMatchSurvivesNativeLedgerRefreshAndPreparesOfflineFinish()=World().use { w ->
        val matched=File(w.external,"books/matched.epub").apply { writeText("matched bytes") }
        val hash=CatalogWorkflow.partial(matched)
        w.run("local.observe",mapOf("reference" to 8L,"file_reference" to 80L,"path" to matched.path,"document" to hash))
        w.run("initialize")
        w.reading=true
        val prepared=w.run("finish.prepare",mapOf("path" to matched.path,"document" to hash,"local_only" to true))
        assertEquals(BookOrbitLibrary.key(w.owner,"book",8),prepared["key"])
        assertEquals(8L,prepared["reference"]);assertEquals(1,prepared["row_count"])
        assertTrue(LuaValue.encode(prepared).size<=16384);assertTrue(w.calls.isEmpty())
        assertTrue(w.events().none { it["kind"]=="download.saved" })
    }
    @Test fun ownedSyncObservationRejectsAnOutsideFile()=World().use { w ->
        val outside=Files.createTempFile("catalog-outside",".epub").toFile()
        try {
            try { w.run("local.observe",mapOf("reference" to 8L,"path" to outside.path,"document" to CatalogWorkflow.partial(outside)));fail("outside path") }
            catch(_:IllegalArgumentException) { }
        } finally { outside.delete() }
    }
    @Test fun offlineFinishAndUndoImmediatelyPatchTheOwnedCatalogWithoutNetwork()=World().use { w ->
        w.reading=true;w.mark()
        assertEquals("read",(w.worker.store.detail(7)!!.first as Map<*,*>)["readStatus"])
        w.run("finish.mark",mapOf("path" to w.old.path,"document" to CatalogWorkflow.partial(w.old),"complete" to false,"percentage" to .9))
        assertEquals("reading",(w.worker.store.detail(7)!!.first as Map<*,*>)["readStatus"])
        assertTrue(w.calls.isEmpty());assertTrue(w.jobs().isEmpty())
    }
    @Test fun nativeRecommendationLabelsAreProjectedAndAllTenRowsFitTheBudget() {
        val definitions=RecommendedSettings.items
        val observations=definitions.associate { it["id"] as String to mapOf("available" to true,"current" to it["ours"]) }
        val result=RecommendationPlan.evaluate(definitions,mapOf("observations" to observations))
        assertEquals(10,(result["items"] as List<*>).size);assertTrue(LuaValue.encode(result).size<=16384)
        val row=(result["items"] as List<*>).map { it as Map<*,*> }.single { it["id"]=="g.sync_all" }
        assertEquals("BookSync: Sync all books",row["orbit"])
    }
    @Test fun activeCatalogCommandKeepsAutomaticWifiOffWaitingAfterDequeue() {
        assertFalse(AdapterWorker.busy())
        AdapterWorker.catalogActionWork { assertTrue(AdapterWorker.busy()) }
        assertFalse(AdapterWorker.busy())
    }
    @Test fun failedCatalogCommandAlwaysReleasesTheAutomaticWifiHold() {
        try { AdapterWorker.catalogActionWork { assertTrue(AdapterWorker.busy());error("synthetic failure") };fail("expected failure") }
        catch(_:IllegalStateException) { }
        assertFalse(AdapterWorker.busy())
    }
    // @fixture bookorbit/catalog-book.delivery-variants.json
    @Test fun preparedDeliveryFixtureSelectsReadableVariantAndArtifactHash() {
        val fixture=LuaValue.fromJson(File("../../../shared/fixtures/bookorbit/catalog-book.delivery-variants.json").readText()) as Map<*,*>
        val prepared=fixture["with_variant"] as Map<*,*>
        val source=fixture["without_variant"] as Map<*,*>
        val selected=CopiesLogic.pick(prepared["files"] as List<*>,901L)!!
        assertEquals(902L,selected["id"]);assertEquals("audioless_epub",selected["downloadVariant"])
        assertEquals("sel-902",selected["selection"])
        assertNotEquals((CopiesLogic.pick(source["files"] as List<*>,902L)!!)["fileHash"],selected["fileHash"])
    }
    @Test fun anotherAccountCannotClaimLegacyQueuesByRefreshingTheLedgerFirst()=World().use { w ->
        File(w.root,"copies").mkdirs()
        File(w.root,"copies/ask.lua").writeBytes(LuaValue.encode(mapOf("owner" to w.owner,"books" to emptyList<Any>())))
        File(w.root.parentFile,"orbit-finish-queue.lua").writeBytes(LuaValue.encode(mapOf("jobs" to mapOf("old-intent" to mapOf("ready" to true,"book_id" to 7L)))))
        val other="other|https://books.example"
        w.worker.store.own(other)
        CatalogWorkflow(w.worker,CacheWorker.Creds(w.creds.server,"other","synthetic-key"),other,w.transport).command("initialize",emptyMap<Any,Any>())
        w.worker.store.own(w.owner);w.run("initialize")
        assertTrue(w.jobs().containsKey("old-intent"))
    }
    @Test fun accountSpecificNativeStateDoesNotRequireARedundantOwnerProperty()=World().use { w ->
        val primary=File(w.root.parentFile,"bookorbit_sync_state.lua")
        val native=CatalogWorkflow.load(primary);primary.writeBytes(LuaValue.encode(mapOf("account_identity" to "other")))
        val identity="https://books.example|reader"
        val digest=java.security.MessageDigest.getInstance("MD5").digest(identity.toByteArray()).joinToString("") { "%02x".format(it) }
        File(w.root.parentFile,"bookorbit_sync_state_$digest.lua").writeBytes(LuaValue.encode(mapOf("books" to native["books"])))
        w.run("initialize")
        assertEquals(7L,BookOrbitLibrary.localEntries(w.worker.store,w.owner)!!.single()["book_id"])
    }
    @Test fun staleFinishEventCannotAcknowledgeANewerMark()=World().use { w ->
        val hash=CatalogWorkflow.partial(w.old);w.mark();w.run("finish.leave",mapOf("document" to hash));w.run("finish.drain")
        val old=w.events().single { it["kind"]=="finish.applied" }
        assertEquals(true,w.run("finish.validate",mapOf("document" to hash,"token" to old["token"]))["apply"])
        w.mark()
        assertEquals(false,w.run("finish.validate",mapOf("document" to hash,"token" to old["token"]))["apply"])
        w.run("finish.ack",mapOf("document" to hash,"token" to old["token"]));assertEquals(1,w.jobs().size)
    }
    @Test fun copyFetchUsesCompanionDeliveryAndVerifiedAtomicReplacement()=World().use { w ->
        w.run("copies.check")
        assertArrayEquals(w.replacement,w.old.readBytes())
        assertTrue(w.calls.any { it.contains("variant=audioless_epub") })
        assertTrue(w.calls.any { it.startsWith("DOWNLOAD") && it.contains("selection=revision") })
        val identity=w.events().single { it["kind"]=="copy.identity" }
        assertEquals(w.hash,identity["after"]);assertEquals(1,w.copies().size)
        val request=String(LuaValue.encode(mapOf("op" to "copies.state","limit" to 1,"bytes" to 16384)),Charsets.ISO_8859_1)
        LibraryReadModel(w.worker.store,log={}).publish(w.owner,listOf(request))
        val snapshot=w.worker.store.db().query("SELECT body FROM library_views WHERE request=?",request) { it.bytes(0)!! }.single()
        assertTrue(snapshot.size<=16384)
        val counts=LuaValue.parse(snapshot) as Map<*,*>;assertEquals(1L,counts["pending"]);assertEquals(1L,counts["row_count"])
        w.run("copies.ack",mapOf("token" to identity["token"]));assertTrue(w.copies().isEmpty())
    }
    @Test fun replacementToAnotherPrimaryFilePublishesTheNewHashAndFileReference()=World().use { w ->
        w.fileReference=71L;w.worker.store.putDetail(7,w.detail(),101)
        w.run("copies.check")
        val event=w.events().single { it["kind"]=="copy.identity" }
        assertEquals(71L,event["file_reference"])
        val local=BookOrbitLibrary.localEntries(w.worker.store,w.owner)!!.single { it["path"]==w.old.path }
        assertEquals(w.hash,local["md5"]);assertEquals(71L,local["file_id"])
    }
    @Test fun failedTransferKeepsOldBytesAndDurableQueue()=World().use { w ->
        val before=w.old.readBytes();w.downloadOk=false;w.run("copies.check")
        assertArrayEquals(before,w.old.readBytes());assertEquals(1,w.copies().size)
        w.downloadOk=true;w.run("copies.check");assertArrayEquals(w.replacement,w.old.readBytes())
    }
    @Test fun replacementNeverRunsWhileReadingOrForTheOpenBook()=World().use { w ->
        w.reading=true;w.run("copies.check");assertTrue(w.calls.isEmpty())
        w.reading=false;w.run("copies.check",mapOf("open_path" to w.old.path));assertTrue(w.calls.isEmpty());assertEquals(1,w.copies().size)
    }
    @Test fun disabledCopiesDoNoNetworkOrReplacement()=World().use { w -> w.run("copies.check",mapOf("enabled" to false));assertTrue(w.calls.isEmpty()) }
    @Test fun restartAfterRenameFinishesIdentityBeforeRetiringTheJob()=World().use { w ->
        val before=CatalogWorkflow.partial(w.old)
        w.run("initialize")
        val dest=File(w.root,"workflows/${BookOrbitLibrary.namespace(w.owner)}.lua")
        dest.writeBytes(LuaValue.encode(w.state()+mapOf("copies" to listOf(mapOf("path" to w.old.path,"book_id" to 7L,"file_id" to 70L,"old" to before,"new" to w.hash,"phase" to "transfer","token" to "recovered")))))
        w.old.writeBytes(w.replacement);w.run("copies.check")
        assertTrue(w.calls.isEmpty());assertEquals("recovered",w.events().single { it["kind"]=="copy.identity" }["token"])
    }
    @Test fun legacyQueuesAreCheckpointedOnceAndSurviveCacheReset()=World().use { w ->
        File(w.root,"plugin-state.lua").writeBytes(LuaValue.encode(mapOf("copies" to mapOf("queue" to listOf(mapOf("path" to w.old.path,"book_id" to 7L))))))
        File(w.root.parentFile,"orbit-finish-queue.lua").writeBytes(LuaValue.encode(mapOf("jobs" to mapOf("legacy" to mapOf("hash" to "legacy","book_id" to 7L,"ready" to true,"phase" to "writeback")))))
        w.run("initialize");assertEquals(1,w.copies().size);assertEquals(1,w.jobs().size)
        w.run("finish.ack",mapOf("document" to "legacy","token" to (w.jobs()["legacy"] as Map<*,*>)["token"]));w.run("initialize");assertTrue(w.jobs().isEmpty())
        w.worker.store.own("other");w.worker.store.own(w.owner);w.run("initialize");assertEquals(1,w.copies().size)
        assertTrue(File(w.root.parentFile,"orbit-finish-queue.lua").isFile)
    }
    @Test fun otherAccountCannotRunCapturedWork()=World().use { w ->
        w.current=false
        try { w.run("copies.check");fail("owner changed") } catch(e:ServerFailure) { assertEquals("canceled",e.kind) }
        assertTrue(w.calls.isEmpty())
    }
    @Test fun finishWaitsForLeaveAndNativeOutboxThenStatusRatingWritebackAck()=World().use { w ->
        val hash=CatalogWorkflow.partial(w.old);w.mark();w.run("finish.drain");assertTrue(w.calls.isEmpty())
        w.run("finish.rate",mapOf("document" to hash,"rating" to 4L));w.run("finish.leave",mapOf("document" to hash));w.run("finish.drain")
        assertEquals(listOf("GET","PUT","PUT"),w.calls.map { it.substringBefore(' ') })
        val ev=w.events().single { it["kind"]=="finish.applied" };assertEquals(4L,ev["rating"]);assertEquals(true,ev["complete"])
        assertTrue(w.jobs().isNotEmpty());w.run("finish.ack",mapOf("document" to hash,"token" to ev["token"]));assertTrue(w.jobs().isEmpty())
    }
    @Test fun undoCancelsUnsentFinish()=World().use { w ->
        w.mark();w.run("finish.mark",mapOf("document" to CatalogWorkflow.partial(w.old),"complete" to false));assertTrue(w.jobs().isEmpty());w.run("finish.drain");assertTrue(w.calls.isEmpty())
    }
    @Test fun finishServerErrorBacksOffAndManualRetryKeepsRating()=World().use { w ->
        val hash=CatalogWorkflow.partial(w.old);w.mark();w.run("finish.leave",mapOf("document" to hash));w.code=500;w.run("finish.drain")
        assertEquals(1L,(w.jobs()[hash] as Map<*,*>)["attempts"])
        val count=w.calls.size;w.run("finish.drain");assertEquals(count,w.calls.size)
        w.code=200;w.run("finish.drain",mapOf("manual" to true));assertTrue(w.events().any { it["kind"]=="finish.applied" })
    }
    @Test fun authPreservesFinishAndPermanentRefusalDropsIt()=World().use { w ->
        val hash=CatalogWorkflow.partial(w.old);w.mark();w.run("finish.leave",mapOf("document" to hash));w.code=401;w.run("finish.drain");assertEquals(1,w.jobs().size)
        w.code=404;w.run("finish.drain");assertTrue(w.jobs().isEmpty())
    }
    @Test fun readingNeverDrainsFinishOrFetchesDetail()=World().use { w -> w.mark();w.reading=true;w.run("finish.drain");w.run("finish.prepare",mapOf("path" to w.old.path));assertTrue(w.calls.isEmpty()) }
    @Test fun deliberateRemoteStatusIsKeptWhileRatingIsSent()=World().use { w ->
        val hash=CatalogWorkflow.partial(w.old);w.mark();w.run("finish.leave",mapOf("document" to hash));w.readStatus="abandoned"
        w.run("finish.rate",mapOf("document" to hash,"rating" to 5L));w.run("finish.drain")
        assertFalse(w.calls.any { it.endsWith("read-status") });assertTrue(w.calls.any { it.endsWith("rating") })
    }
    @Test fun deferredDownloadUsesCompanionTransportAndKeepsFolderLayout()=World().use { w ->
        val key=BookOrbitLibrary.key(w.owner,"book",7)
        w.run("finish.download",mapOf("key" to key,"later" to true));assertTrue(w.calls.isEmpty())
        w.run("finish.drain");assertTrue(File(w.external,"books/Fiction/Next.epub").isFile)
        val saved=w.events().single { it["kind"]=="download.saved" }
        // Assert spelling too: a case-insensitive host otherwise hides a legacy path regression.
        assertEquals(File(w.external,"books/Fiction/Next.epub").path,saved["path"])
        assertTrue((w.state()["downloads"] as? Map<*,*>).orEmpty().isEmpty())
    }
    @Test fun explicitNativeCatalogDestinationUsesNeutralReferenceAndPublishesLocalLedgerImmediately()=World().use { w ->
        val target=File(w.external,"books/chosen.epub")
        val result=w.run("finish.download",mapOf("reference" to 7L,"destination" to target.path,"file_reference" to 70L))
        assertEquals(target.path,result["local_path"]);assertArrayEquals(w.replacement,target.readBytes())
        assertEquals(target.path,BookOrbitLibrary.localPaths(w.worker.store,w.owner)!![7L])
        w.run("finish.download",mapOf("reference" to 7L,"destination" to target.path,"file_reference" to 70L))
        assertEquals(1,w.calls.count { it.startsWith("DOWNLOAD") })
        // The native event reader can be delayed by foreground reading or a process restart.
        w.run("initialize")
        assertTrue(BookOrbitLibrary.localEntries(w.worker.store,w.owner)!!.any { it["path"]==target.path })
        assertTrue(w.events().any { it["kind"]=="download.saved" && it["path"]==target.path })
    }
    @Test fun finishedSheetReadsOnlyBoundedSnapshotWithNextAndSuggestion()=World().use { w ->
        w.run("initialize")
        w.worker.store.putDetail(7,w.detail()+mapOf("seriesId" to 1L,"seriesIndex" to 1L,
            "seriesMembers" to (2L..300L).map { mapOf("id" to it+10,"title" to "Book $it","seriesIndex" to it,"readStatus" to "unread") },
            "relatedSections" to listOf(mapOf("id" to "author","books" to (500L..800L).map { mapOf("id" to it,"title" to "Suggestion $it") }))),100)
        val result=FinishLogic.snapshot(w.worker.store,w.owner,mapOf("path" to w.old.path))
        assertEquals(3,result["row_count"]);assertNotNull(result["next"]);assertNotNull(result["suggestion"])
        assertTrue(LuaValue.encode(result).size<=16384);assertFalse(result.containsKey("seriesMembers"));assertTrue(w.calls.isEmpty())
        val request=String(LuaValue.encode(mapOf("op" to "reader.finish","path" to w.old.path,"limit" to 2,"bytes" to 16384)),Charsets.ISO_8859_1)
        LibraryReadModel(w.worker.store,log={}).publish(w.owner,listOf(request))
        val bounded=w.worker.store.db().query("SELECT body FROM library_views WHERE request=?",request) { LuaValue.parse(it.bytes(0)!!) as Map<*,*> }.single()
        assertEquals("budget",bounded["error"])
    }
    @Test fun finishSeriesIdentitySurvivesOfflineLastBookAndMissingOrder()=World().use { w ->
        w.run("initialize")
        val base=w.detail()
        for (position in listOf(1L,2L,null)) {
            w.worker.store.putDetail(7,base+mapOf("seriesId" to 42L,"seriesIndex" to position,
                "seriesMembers" to listOf(mapOf("id" to 8L,"title" to "Next","seriesIndex" to 2L,"readStatus" to "read"))),100)
            val result=FinishLogic.snapshot(w.worker.store,w.owner,mapOf("path" to w.old.path))
            assertEquals(BookOrbitLibrary.key(w.owner,"series",42),result["series_key"])
            if(position==1L) assertEquals(BookOrbitLibrary.key(w.owner,"book",8),(result["next"] as Map<*,*>)["book_id"])
            if(position==2L) assertEquals("You've finished the series",(result["next"] as Map<*,*>)["line"])
            assertTrue((result["row_count"] as Int)<=3)
            assertTrue(LuaValue.encode(result).size<=16384)
        }
        w.worker.store.putDetail(7,base+mapOf("seriesId" to null),100)
        val none=FinishLogic.snapshot(w.worker.store,w.owner,mapOf("path" to w.old.path))
        assertNull(none["series_key"]);assertNull(none["next"])
        assertTrue(w.calls.isEmpty()) // Saved snapshots do not acquire data, even offline.
    }
    @Test fun nextGapIsNotSkippedAndReadSuggestionsAreExcluded()=World().use { w ->
        w.run("initialize");w.worker.store.putDetail(7,w.detail()+mapOf("seriesId" to 1L,"seriesIndex" to 1L,
            "seriesMembers" to listOf(mapOf("id" to 9L,"seriesIndex" to 3L,"readStatus" to "read")),
            "relatedSections" to listOf(mapOf("id" to "author","books" to listOf(mapOf("id" to 9L,"title" to "Read"),mapOf("id" to 10L,"title" to "Unread"))))),100)
        val result=FinishLogic.snapshot(w.worker.store,w.owner,mapOf("path" to w.old.path))
        assertEquals("Book 2 isn't in your library",(result["next"] as Map<*,*>)["line"])
        assertEquals("Unread",(result["suggestion"] as Map<*,*>)["title"])
    }
    @Test fun seriesFilePlanUsesOnlyCachedManifestsAndRejectsChangedChoice()=World().use { w ->
        val key=BookOrbitLibrary.key(w.owner,"book",7L)
        val args=mapOf("items" to listOf(mapOf("key" to key,"title" to "Book")),"root" to File(w.external,"Chosen").path)
        assertEquals(File(w.external,"Chosen").path,w.run("download.prepare",mapOf("key" to key,"root" to File(w.external,"Chosen").path))["root"])
        val rows=w.run("series.choices",args)["items"] as List<*>
        val choice=rows.single() as Map<*,*>
        assertEquals(70L,choice["file_reference"])
        assertTrue(LuaValue.utf8(choice["destination"].toString()).startsWith(File(w.external,"Chosen").path+"/"))
        assertTrue(w.calls.isEmpty())
        try { w.run("series.choices",args+mapOf("choices" to mapOf(key to mapOf("file_reference" to 71L,"variant" to "audioless_epub"))));fail("changed selection") }
        catch(e:ServerFailure) { assertEquals("changed",e.kind) }
        assertTrue(w.calls.isEmpty())
    }
    @Test fun queuedVariantIsRequestedAgainEvenWhenDeliveryPreferencesChange()=World().use { w ->
        w.run("finish.download",mapOf("key" to BookOrbitLibrary.key(w.owner,"book",7L),"file_reference" to 70L,"variant" to "original"))
        assertTrue(w.calls.any { it.startsWith("GET ") && "variant=original" in it })
        assertTrue(w.calls.any { it.startsWith("DOWNLOAD ") && "variant=original" in it })
    }

}
