package net.fledgewing.orbitcompanion

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The commands the plugin hands its work over with (docs/design/companion-worker.md) reach the
 * companion: each is in the plugin's Companion.ACTION table and accepted by CommandProvider.
 */
class PluginActionsTest {
    private fun file(vararg rels: String): String =
        rels.flatMap { listOf(File(it), File("app/$it"), File("../$it"), File("../../$it")) }.firstOrNull { it.isFile }?.readText()
            ?: error("${rels.first()} not found from ${File(".").absolutePath}")

    @Test
    fun workerActionsAreDeclaredOnBothSides() {
        val plugin = file("koreader/orbit.koplugin/ko/companion.lua", "android/koreader/orbit.koplugin/ko/companion.lua")
        for (action in CommandProvider.COMMANDS) {
            val short = action.substringAfterLast('.')
            assertTrue("$short in Companion.ACTION", plugin.contains("$short = Companion.PACKAGE .. \".action.$short\"") ||
                plugin.contains("Companion.ACTION.$short = Companion.PACKAGE .. \".action.$short\""))
        }
    }
}
