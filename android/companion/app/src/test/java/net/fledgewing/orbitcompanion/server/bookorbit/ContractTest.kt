package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The companion's side of shared/contract/companion.json: every command, call, page, launch
 * extra, status key, shared file and the database the contract names is the one this app
 * implements, and nothing it offers KOReader is missing from the contract. The plugin's side is
 * test_flows.lua "contract".
 */
class ContractTest {
    private fun find(rel: String): File =
        listOf(File(rel), File("../$rel"), File("../../$rel"), File("../../../$rel")).firstOrNull { it.exists() }
            ?: error("$rel not found from ${File(".").absolutePath}")

    private val c = JSONObject(find("shared/contract/companion.json").readText())
    private val manifest = find("android/companion/app/src/main/AndroidManifest.xml").readText()
    private val sources = find("android/companion/app/src/main/java/net/fledgewing/orbitcompanion").walkTopDown()
        .filter { it.isFile && it.name.endsWith(".kt") }.joinToString("\n") { it.readText() }

    private fun JSONArray.objects() = (0 until length()).map { getJSONObject(it) }
    private fun JSONArray.strings() = (0 until length()).map { getString(it) }
    private fun used(name: String, what: String) = assertTrue("$what \"$name\" is read or written in the companion", sources.contains("\"$name\""))

    @Test fun identity() {
        assertEquals(1, c.getInt("version"))
        assertEquals(Contract.PACKAGE, c.getString("package"))
        assertEquals(CommandProvider.AUTHORITY, c.getString("authority"))
        assertTrue(manifest.contains("android:authorities=\"${CommandProvider.AUTHORITY}\""))
    }

    @Test fun everyCommandIsAcceptedAndNothingElse() {
        val cmds = c.getJSONArray("commands").objects()
        assertEquals(CommandProvider.COMMANDS, cmds.map { it.getString("method") }.toSet())
        cmds.forEach { assertEquals("${Contract.PACKAGE}.action.${it.getString("name")}", it.getString("method")) }
        (cmds.flatMap { it.getJSONArray("extras").strings() } + c.getJSONArray("common_extras").strings()).toSet().forEach { used(it, "extra") }
    }

    @Test fun everyCallIsTheProvidersOwn() {
        val calls = c.getJSONArray("calls").objects().associate { it.getString("name") to it }
        assertEquals(mapOf("STATUS" to CommandProvider.STATUS, "TAKE_COMMAND" to CommandProvider.TAKE_COMMAND, "CLICKS" to CommandProvider.CLICKS,
            "RESTART_KOREADER" to CommandProvider.RESTART_KOREADER,
            "SERVER_STATE" to LibraryAccount.STATE, "SERVER_COMMAND" to ServerCommands.START,
            "SERVER_RESULT" to ServerCommands.RESULT, "ACCOUNT_OPEN" to LibraryAccount.OPEN,
            "DEVICE_SETTINGS" to CommandProvider.DEVICE_SETTINGS), calls.mapValues { it.value.getString("method") })
        assertEquals("shell", calls.getValue("RESTART_KOREADER").getString("caller"))
        calls.values.forEach { o -> (o.getJSONArray("extras").strings() + o.getJSONArray("answer").strings()).forEach { used(it, "call field") } }
        c.getJSONArray("answer").strings().forEach { used(it, "answer field") }
    }

    /** Every action on an exported component of ours is a contract page or a USB action. */
    @Test fun everyPageIsInTheManifestAndNoOtherIsOffered() {
        val pages = c.getJSONArray("activities").objects().map { it.getString("action") }
        val usb = c.getJSONArray("usb").objects().map { it.getString("action") }
        val exported = Regex("<(activity|receiver|service|provider)\\b([^>]*[^/])>(.*?)</\\1>", RegexOption.DOT_MATCHES_ALL).findAll(manifest)
            .filter { it.groupValues[2].contains("android:exported=\"true\"") }
            .flatMap { m -> Regex("<action android:name=\"(${Regex.escape(Contract.PACKAGE)}\\.action\\.[A-Z_]+)\"").findAll(m.groupValues[3]).map { it.groupValues[1] } }
            .toSet()
        assertEquals(exported, (pages + usb).toSet())
        assertTrue(manifest.substringAfter("android:name=\".PinResetReceiver\"").substringBefore("</receiver>").contains("android.permission.DUMP"))
    }

    @Test fun koreadersStartCarriesTheContractsExtrasAndCommands() {
        val k = c.getJSONObject("koreader_start")
        val extras = k.getJSONObject("extras")
        assertEquals(Contract.EXTRA_COMMAND, extras.getString("COMMAND"))
        assertEquals(Contract.EXTRA_FROM, extras.getString("FROM"))
        assertEquals(Contract.EXTRA_ROTATION, extras.getString("ROTATION"))
        assertEquals(HomeCommands.ALL, k.getJSONArray("commands").strings())
        assertEquals(HomeCommands.ALL.toSet(), HomeCommands.ALL.toSet() + PluginCommands.SINCE.keys)
    }

    @Test fun theLoopbackAndTheStatus() {
        val lb = c.getJSONObject("loopback")
        assertEquals(Contract.STATUS_PORT, lb.getInt("port"))
        val lines = listOf(ClickRoute.proofLine("p"), ClickRoute.serviceLine(true), ClickRoute.clickLine(ClickAction.values().first { it.inKoreader.key.isNotEmpty() }, 1), ClickRoute.settingsLine(1))
        assertEquals(lb.getJSONArray("lines").strings(), lines.map { it.substringBefore(' ') })
        c.getJSONArray("status").strings().forEach { k -> assertTrue("status key $k", sources.contains("\\\"$k\\\":")) }
    }

    @Test fun everySharedFileAndTheDatabase() {
        c.getJSONArray("files").objects().forEach { f ->
            val name = f.optString("via").ifEmpty { f.getString("path") }.trimEnd('/').substringAfterLast('/')
            assertTrue("file $name", sources.contains("\"$name") || sources.contains("/$name\"") || sources.contains("$name\""))
        }
        val db = c.getJSONObject("db")
        assertEquals(CacheStore.VERSION, db.getInt("user_version"))
        assertTrue(sources.contains("\"" + db.getString("file").substringAfterLast('/') + "\""))
        val schema = find(db.getString("schema")).readText()
        val tables = Regex("CREATE TABLE (\\w+)").findAll(schema).map { it.groupValues[1] }.toList()
        assertEquals(db.getJSONArray("tables").strings(), tables)
        assertEquals(tables, CacheStore.SCHEMA.mapNotNull { Regex("CREATE TABLE (\\w+)").find(it)?.groupValues?.get(1) })
    }
}
