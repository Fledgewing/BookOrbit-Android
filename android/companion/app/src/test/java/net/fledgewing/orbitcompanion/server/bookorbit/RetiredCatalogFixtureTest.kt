// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** Historical Lua catalog fixtures now exercise the existing companion implementation. */
class RetiredCatalogFixtureTest {
    private val fixtures=File("../../../shared/fixtures")
    private fun fixture(name:String)=LuaValue.fromJson(File(fixtures,name).readText()) as Map<*,*>
    private fun num(v:Any?)=(v as Number).toInt()
    // @fixture cache/cases.json#mirror.windows
    @Test fun windowIdentityIsIndependentOfDisplayPaging() {
        val rows=((fixture("cache/cases.json")["mirror"] as Map<*,*>)["windows"] as List<*>).map { it as Map<*,*> }
        for(r in rows) {
            val actual=MirrorLogic.listWindow(r["path"] as String)
            if(r["list"]==false) assertNull(actual)
            else assertEquals(r["same"],actual?.identity==MirrorLogic.listWindow(r["identity_of"] as String)?.identity)
        }
    }
    // @fixture cache/cases.json#mirror.slices
    // @fixture cache/cases.json#mirror.small_pages
    @Test fun savedPagesAnswerSmallDisplayWindowsAndMissingPagesStayMissing() {
        val mirror=fixture("cache/cases.json")["mirror"] as Map<*,*>
        for(raw in (mirror["slices"] as List<*>)+(mirror["small_pages"] as List<*>)) {
            val r=raw as Map<*,*>;val window=r["window"] as Map<*,*>
            val root=Files.createTempDirectory("retired-window").toFile()
            try { CacheStore(root,{}, {JdbcSql(it)}).use { store ->
                store.own("fixture")
                val total=num(r["total"]);val size=(r["page_size"] as? Number)?.toInt() ?: 100
                val base=if(window["kind"]=="books") "/koreader/plugin/catalog/books" else "/koreader/plugin/catalog/sections/series"
                for(page in r["saved_pages"] as List<*>) {
                    val offset=(num(page)-1)*size
                    val items=(offset+1..minOf(offset+size,total)).map { mapOf("id" to it.toLong(),"title" to "Book $it") }
                    val path="$base?page=${num(page)}&size=$size"
                    store.save(MirrorLogic.key("fixture","https://library.example",path),path,mapOf("items" to items,"total" to total.toLong(),"page" to num(page).toLong(),"size" to size.toLong()),1,null)
                }
                val q=window.filterKeys { it!="kind" }.entries.joinToString("&") { "${it.key}=${it.value}" }
                val path="$base?$q"
                val result=store.read(MirrorLogic.key("fixture","https://library.example",path),path,null)
                if(r["items"]==null) assertNull(r["name"].toString(),result)
                else {
                    val body=result!!.body as Map<*,*>;val items=body["items"] as List<*>
                    val expected=r["items"] as List<*>
                    assertEquals(r["name"].toString(),num(expected.first()),num((items.first() as Map<*,*>)["id"]))
                    assertEquals(r["name"].toString(),num(expected.last()),num((items.last() as Map<*,*>)["id"]))
                    assertTrue(items.size<=num(window["size"]))
                }
            } } finally { root.deleteRecursively() }
        }
    }
    // @fixture bookorbit/catalog-sections.collections.json
    // @fixture bookorbit/catalog-sections.smart-scopes.json
    @Test fun recordedNativeSectionsRemainReadableFromTheCompanionStore() {
        for(kind in listOf("collections","smart-scopes")) {
            val body=fixture("bookorbit/catalog-sections.$kind.json")
            val items=body["items"] as List<*>
            val root=Files.createTempDirectory("retired-sections").toFile()
            try { CacheStore(root,{}, {JdbcSql(it)}).use { store ->
                store.own("fixture")
                val path="/koreader/plugin/catalog/sections/$kind"
                store.save("fixture:$kind",path,body+mapOf("total" to items.size.toLong()),1,null)
                val result=store.read("fixture:$kind",path,null)!!.body as Map<*,*>
                assertEquals(items.size,(result["items"] as List<*>).size)
                assertEquals((items.first() as Map<*,*>)["title"],((result["items"] as List<*>).first() as Map<*,*>)["title"])
            } } finally { root.deleteRecursively() }
        }
    }
}
