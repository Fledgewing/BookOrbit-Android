package net.fledgewing.orbitcompanion

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * Every page scrolls (v0.5.5: the status page ran off the M8C's 1404x1872 screen, and the
 * Boox Page is smaller). EinkActivity.page() scrolls by default; only pages that page their
 * own content by height opt out, and only these.
 */
class UiPagesTest {
    @Test
    fun onlyKnownPagesOptOutOfScrolling() {
        val dir = File("src/main/java/net/fledgewing/orbitcompanion")
        val optOuts = dir.listFiles { f -> f.extension == "kt" }!!.sortedBy { it.name }.flatMap { f ->
            f.readLines().filter { it.contains("page(scroll = false)") }.map { f.name }
        }
        // Launcher.kt: "Other apps", paged by the measured height; Updater.kt: licenses, own ScrollView.
        assertEquals(listOf("Launcher.kt", "Updater.kt"), optOuts)
    }
}
