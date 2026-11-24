package net.fledgewing.orbitcompanion

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The broadcasts the plugin hands its work over with (docs/design/companion-worker.md) reach the
 * companion: each is in the plugin's Companion.ACTION table and on CommandReceiver in the manifest.
 */
class PluginActionsTest {
    private fun file(vararg rels: String): String =
        rels.flatMap { listOf(File(it), File("app/$it"), File("../$it"), File("../../$it")) }.firstOrNull { it.isFile }?.readText()
            ?: error("${rels.first()} not found from ${File(".").absolutePath}")

    @Test
    fun workerActionsAreDeclaredOnBothSides() {
        val manifest = file("src/main/AndroidManifest.xml")
        val plugin = file("koreader/orbit.koplugin/ko/companion.lua", "android/koreader/orbit.koplugin/ko/companion.lua")
        for (action in listOf(Worker.ACTION_MIRROR, Worker.ACTION_CHECK, Worker.ACTION_STORAGE, Worker.ACTION_COPIES, Updater.ACTION_UPDATE)) {
            assertTrue("$action on CommandReceiver", manifest.contains("<action android:name=\"$action\" />"))
            val short = action.substringAfterLast('.')
            assertTrue("$short in Companion.ACTION", plugin.contains("$short = Companion.PACKAGE .. \".action.$short\""))
        }
    }
}
