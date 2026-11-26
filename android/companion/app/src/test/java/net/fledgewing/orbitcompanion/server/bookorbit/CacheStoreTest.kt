package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * The offline cache's database (docs/design/sqlite-cache.md) against shared/fixtures/cache/db.json
 * and schema.sql, which the plugin's tests read too: the replies saved through [CacheStore.save]
 * answer every read as the plugin's Store.read must.
 */
class CacheStoreTest {
    // @fixture cache/db.json @fixture cache/schema.sql
    private val shared = File("../../../shared/fixtures/cache")
    private val fx = JSONObject(File(shared, "db.json").readText())
    private val owner = fx.getString("owner")
    private val server = owner.substringAfter('|')
    private val template = fx.getString("detail_template")

    private fun s(v: String) = LuaValue.str(v)
    private fun key(o: JSONObject) = if (o.has("key")) s(o.getString("key")) else MirrorLogic.key(s(owner.substringBefore('|')), server, s(o.getString("path")))

    private fun store(): CacheStore {
        val dir = Files.createTempDirectory("orbit-store").toFile()
        val st = CacheStore(dir, {}) { JdbcSql(it) }
        st.own(s(owner))
        for (i in 0 until fx.getJSONArray("saves").length()) {
            val o = fx.getJSONArray("saves").getJSONObject(i)
            st.save(key(o), s(o.getString("path")), LuaValue.fromJsonValue(o.get("reply")), 1000L + i, s(template))
        }
        return st
    }

    @Test fun sleepNamesComeFromCompleteCurrentDatabaseLists() {
        val root = java.nio.file.Files.createTempDirectory("choices-db").toFile()
        CacheStore(root, log = {}, open = { JdbcSql(it) }).use { store ->
            val path = "/koreader/plugin/catalog/sections/smart-scopes"
            val body = mapOf("total" to 1L, "items" to listOf(mapOf("id" to 2L, "title" to LuaValue.str("Cosy reads"))))
            store.putWindow(path, "section", "smart-scopes", 0, body, 20L)
            val stale = SleepChoices.parse("""{"at":1,"scopes":[{"id":2,"title":"Old name"}]}""")
            val choices = SleepChoices.fromSql(store.db(), stale)!!
            assertEquals("Cosy reads (list)", choices.title("scope:2"))
            assertEquals("List 3 (Removed on the server)", choices.missingLabel("scope:3"))
            assertTrue(SleepChoices.fallback("scope:3").contains("Lists not loaded yet"))
        }
    }

    @Test
    fun schemaIsTheSharedOne() {
        val file = File(shared, "schema.sql").readLines().filter { it.isNotBlank() && !it.startsWith("--") }.map { it.removeSuffix(";") }
        assertEquals(file, CacheStore.SCHEMA)
    }

    @Test
    fun readsAnswerFromTheRows() {
        val st = store()
        val reads = fx.getJSONArray("reads")
        for (i in 0 until reads.length()) {
            val r = reads.getJSONObject(i)
            val path = r.getString("path")
            val got = st.read(key(r), s(path), s(template))
            if (r.optBoolean("null")) { assertNull(path, got); continue }
            assertNotNull(path, got)
            val body = got!!.body as Map<*, *>
            r.optJSONArray("ids")?.let { ids ->
                val items = body["items"] as List<*>
                assertEquals(path, (0 until ids.length()).map { ids.getLong(it) }, items.map { (it as Map<*, *>)["id"] })
                if (r.has("read_status_2")) assertEquals(s(r.getString("read_status_2")), items.map { it as Map<*, *> }.first { it["id"] == 2L }["readStatus"])
            }
            for (k in listOf("total", "page", "size", "offset")) if (r.has(k)) assertEquals("$path $k", r.getLong(k), body[k])
            for (k in listOf("hasNext", "hasPrevious")) if (r.has(k)) assertEquals("$path $k", r.getBoolean(k), body[k])
            r.optJSONArray("no")?.let { no -> for (j in 0 until no.length()) assertTrue("$path no ${no.getString(j)}", no.getString(j) !in body) }
            r.optJSONObject("head")?.let { assertEquals(2L, (body["authorSummary"] as Map<*, *>)["bookCount"]) }
            r.optJSONArray("titles")?.let { t -> assertEquals((0 until t.length()).map { s(t.getString(it)) }, (body["items"] as List<*>).map { (it as Map<*, *>)["title"] }) }
            if (r.has("detail")) {
                assertEquals(r.getLong("detail"), body["id"])
                assertEquals(r.getInt("files"), (body["files"] as List<*>).size)
            }
            r.optJSONArray("continue")?.let { assertEquals(it.getLong(0), ((body["continueReading"] as List<*>)[0] as Map<*, *>)["id"]) }
        }
        st.close()
    }

    @Test
    fun eachBookIsOneRow() {
        val st = store()
        assertEquals(fx.getInt("books_rows").toLong(), st.db().query("SELECT count(*) FROM books") { it.long(0) }.single())
        val search = fx.getJSONObject("search_text")
        for (id in search.keys()) assertEquals(search.getString(id), st.db().query("SELECT search FROM books WHERE id = ?", id.toLong()) { it.text(0) }.single())
        st.close()
    }

    @Test
    fun anotherOwnerWipesAndAnotherVersionStartsAgain() {
        val st = store()
        st.own("someone|http://elsewhere")
        assertEquals(0L, st.db().query("SELECT count(*) FROM books") { it.long(0) }.single())
        st.db().exec("INSERT INTO books (id) VALUES (1)")
        st.db().exec("PRAGMA user_version = 99")
        st.close()
        val again = CacheStore(st.root, {}) { JdbcSql(it) }
        assertEquals("1", again.db().pragma("user_version"))
        assertEquals(0L, again.db().query("SELECT count(*) FROM books") { it.long(0) }.single())
        assertTrue(File(st.root, ".nomedia").isFile)
        again.close()
    }

    @Test
    fun aWriteIsPatchedIntoTheBookAndHomeGoesStale() {
        val st = store()
        val n = st.patch(2L, sortedMapOf("readStatus" to s("unread")), staleHome = true)
        assertEquals(2, n) // the item and the detail
        val all = st.read("", s("/koreader/plugin/catalog/books?order=asc&page=1&sort=title"), s(template))!!.body as Map<*, *>
        assertEquals(s("unread"), (all["items"] as List<*>).map { it as Map<*, *> }.first { it["id"] == 2L }["readStatus"])
        val home = JSONObject().put("path", "/koreader/plugin/catalog/dashboard").put("key", fx.getJSONArray("reads").getJSONObject(10).getString("key"))
        assertTrue(st.read(key(home), s(home.getString("path")), s(template))!!.stale)
        // A rating cleared (Cache.NULL is an empty table).
        st.patch(2L, sortedMapOf("readStatus" to emptyMap<String, Any?>()), staleHome = false)
        assertNull((st.detail(2L)!!.first as Map<*, *>)["readStatus"])
        st.close()
    }

    /**
     * shared/fixtures/cache/cases.json "writes": the effect the plugin sends (Cache.writeEffect,
     * checked by test_logic.lua) patched into every cached reply as the shared table expects. A
     * null field is cleared: on the wire it is an empty table (Cache.NULL).
     */
    @Test
    fun writesPatchWhatTheSharedCasesExpect() {
        // @fixture cache/cases.json#writes
        val writes = JSONObject(File(shared, "cases.json").readText()).getJSONArray("writes")
        assertTrue(writes.length() >= 3)
        for (i in 0 until writes.length()) {
            val c = writes.getJSONObject(i)
            val name = c.getString("name")
            val entries = c.getJSONObject("entries")
            val effect = c.optJSONObject("effect")
            val stale = mutableListOf<String>()
            val got = entries.keys().asSequence().associateWith { k ->
                val body = LuaValue.fromJsonValue(entries.get(k))
                if (effect == null) body else {
                    val f = effect.getJSONObject("fields")
                    val fields = f.keys().asSequence().associate { k2 -> s(k2) to (if (f.isNull(k2)) emptyMap<String, Any?>() else LuaValue.fromJsonValue(f.get(k2))) }
                    CacheStore.patched(body, effect.getLong("id"), fields)
                }
            }
            if (effect?.optBoolean("stale_home") == true) stale += "dashboard"
            val expect = c.getJSONObject("expect")
            for (k in expect.keys()) assertEquals("$name $k", lua(LuaValue.fromJsonValue(expect.get(k))), lua(got[k]))
            assertEquals("$name stale", c.getJSONArray("stale").strings().sorted(), stale.sorted())
        }
    }

    @Test
    fun aRecheckedWindowSaysWhetherItChanged() {
        val st = store()
        val path = s("/koreader/plugin/catalog/books?author=Ann%20Leckie&order=asc&page=1&size=100&sort=title")
        val same = st.read("", path, null)!!.body
        assertEquals(false, st.save("", path, same, 2000L, null))
        val fewer = (same as Map<*, *>).toMutableMap().also { it["items"] = (it["items"] as List<*>).take(1); it["total"] = 1L }
        assertEquals(true, st.save("", path, fewer, 2001L, null))
        assertEquals(1L, st.db().query("SELECT count(*) FROM list_items WHERE identity LIKE '%Leckie%'") { it.long(0) }.single())
        st.close()
    }

    private fun lua(v: Any?) = LuaValue.encode(v).toString(Charsets.ISO_8859_1)

    private fun JSONArray.strings() = (0 until length()).map { getString(it) }
}
