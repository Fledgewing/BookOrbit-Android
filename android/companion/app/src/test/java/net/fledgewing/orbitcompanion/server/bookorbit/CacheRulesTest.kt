package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The cache rules the companion took over from the plugin (MirrorLogic, LuaValue.settle) against
 * the shared table shared/fixtures/cache/cases.json. The plugin's tests check the fake
 * companion's copies against the same cases (android/koreader/test/companion_rules.lua).
 */
class CacheRulesTest {
    private val cases = JSONObject(File("../../../shared/fixtures/cache/cases.json").readText())

    private fun JSONArray.objects() = (0 until length()).map { getJSONObject(it) }
    private fun JSONArray.ints() = (0 until length()).map { getInt(it) }
    private fun lua(v: Any?) = LuaValue.encode(v).toString(Charsets.ISO_8859_1)

    @Test
    fun aCheckKeepsTheSavedRandomPick() {
        // @fixture cache/cases.json#settle
        val all = cases.getJSONArray("settle").objects()
        assertTrue(all.isNotEmpty())
        for (c in all) {
            val got = CacheRules.settle(LuaValue.fromJsonValue(c.get("cached")), LuaValue.fromJsonValue(c.get("reply")), c.getString("mode"))
            assertEquals(c.getString("name"), lua(LuaValue.fromJsonValue(c.get("expect"))), lua(got))
        }
    }

    @Test
    fun aListWhoseTotalMovedIsRepaged() {
        // @fixture cache/cases.json#mirror.repage
        val all = cases.getJSONObject("mirror").getJSONArray("repage").objects()
        assertTrue(all.isNotEmpty())
        for (c in all) {
            val (fetch, drop) = MirrorLogic.repage(c.getInt("old"), c.getInt("new"), null)
            assertEquals(c.getString("name") + " fetch", c.getJSONArray("fetch").ints(), fetch)
            assertEquals(c.getString("name") + " drop", c.getJSONArray("drop").ints(), drop)
        }
    }

    @Test
    fun aRequestWithNoAnswerIsRetriedInSmallerPagesThenSkipped() {
        // @fixture cache/cases.json#mirror.retry
        val all = cases.getJSONObject("mirror").getJSONArray("retry").objects()
        assertTrue(all.isNotEmpty())
        for (c in all) {
            val name = c.getString("name")
            val size = if (c.isNull("size")) null else c.getInt("size")
            val page = if (c.isNull("page")) null else c.getInt("page")
            val r = MirrorLogic.retry(c.getInt("tries"), size, page)
            assertEquals("$name skip", c.optBoolean("skip"), r.skip)
            if (!r.skip) {
                assertEquals("$name wait", c.getInt("wait_s"), r.waitS)
                assertEquals("$name size", if (c.isNull("size_next")) null else c.getInt("size_next"), r.size)
            }
        }
    }

    @Test
    fun theMirrorSaysWhyItStoppedAtTheLimit() {
        // @fixture cache/cases.json#storage.notes
        val all = cases.getJSONObject("storage").getJSONArray("notes").objects()
        assertTrue(all.isNotEmpty())
        for (c in all) assertEquals(c.getString("text"), MirrorLogic.limitText(c.getString("what") == "covers", c.getInt("done"), c.getInt("total")))
    }
}
