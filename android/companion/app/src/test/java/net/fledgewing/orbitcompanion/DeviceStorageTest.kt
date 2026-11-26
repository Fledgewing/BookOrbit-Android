package net.fledgewing.orbitcompanion

import net.fledgewing.orbitcompanion.server.bookorbit.CacheStore
import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class DeviceStorageTest {
    private fun fixture(run: (File,CacheStore,MutableList<LocalBook>,DeviceStorage)->Unit) {
        val volume=Files.createTempDirectory("storage-fixture").toFile()
        val root=File(volume,"koreader/settings/orbit-cache").apply { mkdirs() }
        val files=mutableListOf<LocalBook>()
        val adapter=object: ServerAdapter {
            override val id="fixture"
            override fun localFiles(owner: String)=files
        }
        CacheStore(root,{}, { JdbcSql(it) }).use { store ->
            store.setMeta("owner","fixture")
            val storage=DeviceStorage(store,adapter,volume,File(volume,"covers"),{32_000_000_000L to 1_200_000_000L},{1_800_000_000L},{ it.md5?.toLongOrNull() })
            try { run(volume,store,files,storage) } finally { volume.deleteRecursively() }
        }
    }
    private fun book(volume: File,name: String,size: Int)=File(volume,"Books/$name.epub").apply { requireNotNull(parentFile).mkdirs(); writeBytes(ByteArray(size)) }
    private fun actions(data: Map<String,Any?>)=(data["actions"] as List<*>).map { it as Map<*,*> }
    @Test fun realFilesCapacityAndSmallSnapshot()=fixture { volume,_,files,storage ->
        files+=LocalBook(book(volume,"old",100),false,"1")
        files+=LocalBook(book(volume,"done",200),true,null)
        File(volume,"covers").mkdirs(); File(volume,"covers/1.jpg").writeBytes(ByteArray(70))
        val data=storage.summary("fixture")
        assertEquals(1_200_000_000L,data["free"]); assertEquals(32_000_000_000L,data["total"])
        assertEquals(2,data["on_device"]); assertTrue((data["warning"] as String).contains("Downloads still work"))
        val parts=data["parts"] as List<*>; assertEquals(300L,(parts[0] as Map<*,*>)["bytes"])
        assertEquals(listOf("old","finished","covers"),actions(data).map { it["id"] })
        assertTrue(LuaValue.encode(data).size<16384)
    }
    @Test fun removalKeepsSidecarsProgressAndServerCatalog()=fixture { volume,store,files,storage ->
        val file=book(volume,"done",200); files+=LocalBook(file,true,null)
        val sidecar=File(requireNotNull(file.parentFile),"done.sdr/metadata.epub.lua").apply { requireNotNull(parentFile).mkdirs(); writeText("progress") }
        val action=actions(storage.summary("fixture")).single()
        val result=storage.command("fixture","storage.free",mapOf("action" to "finished","token" to action["token"]))
        assertFalse(file.exists()); assertEquals("progress",sidecar.readText()); assertEquals("fixture",store.meta("owner"))
        assertTrue(actions(result).isEmpty()); assertEquals(0,result["on_device"])
    }
    @Test fun newlyEligibleOrReplacedFilesRequireNewConfirmation()=fixture { volume,_,files,storage ->
        val file=book(volume,"done",200); files+=LocalBook(file,true,null)
        val action=actions(storage.summary("fixture")).single()
        file.appendText("replacement")
        val result=storage.command("fixture","storage.free",mapOf("action" to "finished","token" to action["token"]))
        assertTrue((result["error"] as String).contains("Files changed"))
        assertTrue(file.exists())
    }
    @Test fun unknownLastOpenIsNotSixMonthsOldAndSymlinksCannotEscape()=fixture { volume,_,files,storage ->
        val file=book(volume,"unknown",100); files+=LocalBook(file,false,null)
        val outside=Files.createTempFile("storage-outside",".epub").toFile().apply { writeText("outside") }
        try {
            val link=File(volume,"Books/escape.epub"); Files.createSymbolicLink(link.toPath(),outside.toPath())
            files+=LocalBook(link,true,"1")
            val data=storage.summary("fixture")
            assertEquals(1,data["on_device"]); assertTrue(actions(data).isEmpty()); assertTrue(outside.exists())
        } finally { outside.delete() }
    }
    @Test fun missingCapacityNeverFabricatesBarOrCapacity()=fixture { volume,store,_,_ ->
        val storage=DeviceStorage(store,object:ServerAdapter { override val id="other" },volume,File(volume,"covers"),{ error("unavailable") })
        val data=storage.summary("fixture")
        assertEquals(false,data["available"]); assertNull(data["free"]); assertNull(data["total"])
        assertNull(data["on_device"]); assertTrue((data["parts"] as List<*>).isEmpty())
    }
    @Test fun foldersArePersistedAndValidatedByTheWorker()=fixture { volume,_,_,storage ->
        val result=storage.command("fixture","storage.folder",mapOf("folder" to "BookSync"))
        assertEquals("BookSync",storage.summary("fixture")["folder"])
        assertEquals(File(volume,"BookSync").path,LuaValue.utf8(result["download_path"] as String))
        assertTrue(File(volume,"BookSync").isDirectory)
        assertThrows(IllegalArgumentException::class.java) { storage.command("fixture","storage.folder",mapOf("folder" to "../escape")) }
        assertThrows(IllegalArgumentException::class.java) { storage.command("other","storage.folder",mapOf("folder" to "Books")) }
    }
    @Test fun normalCapacityHasNoWarningAndForegroundBookIsProtected()=fixture { volume,store,files,storage ->
        val file=book(volume,"open",100); files+=LocalBook(file,true,"1")
        val preview=storage.summary("fixture",file.path)
        assertTrue(actions(preview).isEmpty()); assertEquals(1,preview["on_device"])
        val adapter=object:ServerAdapter { override val id="fixture"; override fun localFiles(owner:String)=files }
        val normal=DeviceStorage(store,adapter,volume,File(volume,"covers"),{32_000_000_000L to 4_200_000_000L})
        assertNull(normal.summary("fixture")["warning"])
        assertEquals(32_000_000_000L,normal.summary("fixture")["total"])
    }

    @Test fun existingFolderIsDisplayedWithoutSilentlyChangingIt()=fixture { volume,_,_,storage ->
        val current=File(volume,"Existing books").apply { mkdirs() }
        val data=storage.summary("fixture",currentFolder=current.path)
        assertEquals("/Existing books",LuaValue.utf8(data["folder_label"] as String))
        assertEquals(current.canonicalPath,LuaValue.utf8(data["download_path"] as String))
        assertEquals("Not selected",storage.summary("fixture")["folder_label"])
    }

    @Test fun clearCoversIncludesOwnedAccountSubfolders()=fixture { volume,_,_,storage ->
        val cover=File(volume,"covers/account-cache/1.jpg").apply { requireNotNull(parentFile).mkdirs(); writeBytes(ByteArray(100)) }
        val action=actions(storage.summary("fixture")).single()
        assertEquals("covers",action["id"]); assertEquals(100L,action["bytes"])
        storage.command("fixture","storage.free",mapOf("action" to "covers","token" to action["token"]))
        assertFalse(cover.exists()); assertTrue(actions(storage.summary("fixture")).isEmpty())
    }

    @Test fun shallowProjectionRootsStillPublishUnavailableCapacity() {
        val store=object:ProjectionStore {
            override val root=File("/storage-fixture")
            override fun db():Sql=error("not used")
            override fun meta(k:String):String?=null
            override fun <T> transaction(block:()->T):T=block()
            override fun close() {}
        }
        val data=DeviceStorage(store,object:ServerAdapter { override val id="fixture" }).summary("fixture")
        assertEquals(false,data["available"]); assertNull(data["total"])
        assertEquals(store.root,DeviceStorage.downloadRoot(store.root).parentFile)
    }

}
