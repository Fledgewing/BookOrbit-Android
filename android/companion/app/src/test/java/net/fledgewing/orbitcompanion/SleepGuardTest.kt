package net.fledgewing.orbitcompanion

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * WRITE_SECURE_SETTINGS (docs/design/lock-screen.md P1) lets the companion write any secure
 * setting. It writes only the three screen-saver keys: one Settings.Secure write in the whole app,
 * in SleepScreen.putSecure, which refuses any key not in SleepSystem.KEYS.
 */
class SleepGuardTest {
    @Test
    fun onlyTheScreenSaverKeysAreWritten() {
        val dir = listOf(File("src/main/java/net/fledgewing/orbitcompanion"), File("app/src/main/java/net/fledgewing/orbitcompanion")).first { it.isDirectory }
        val writes = dir.listFiles { f -> f.extension == "kt" }!!.sortedBy { it.name }.flatMap { f ->
            f.readLines().mapIndexedNotNull { i, l ->
                val t = l.trim()
                if (!t.startsWith("//") && !t.startsWith("*") && Regex("""Secure\.put""").containsMatchIn(l)) "${f.name}:${i + 1}" else null
            }
        }
        assertEquals(1, writes.size)
        assertEquals("SleepScreen.kt", writes[0].substringBefore(':'))
        assertEquals(listOf("screensaver_components", "screensaver_enabled", "screensaver_activate_on_sleep"), SleepSystem.KEYS)
        val src = File(dir, "SleepScreen.kt").readText()
        assertEquals(1, Regex("""require\(key in SleepSystem\.KEYS\)""").findAll(src).count())
    }
}
