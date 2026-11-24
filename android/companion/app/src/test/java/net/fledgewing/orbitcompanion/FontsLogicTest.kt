package net.fledgewing.orbitcompanion

import net.fledgewing.orbitcompanion.ReadingFonts.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Reading fonts (docs/design/reading-fonts.md): the manifest, the SHA-256 check, the plan, the restart. */
class FontsLogicTest {
    private val pin = "https://raw.githubusercontent.com/o/r/" + "a".repeat(40)
    private val a = File("Fam-Regular.ttf", "$pin/Fam-Regular.ttf", "1".repeat(64), 10)
    private val b = File("Fam-Bold.ttf", "$pin/Fam-Bold.ttf", "2".repeat(64), 20)
    private val ofl = File("Fam-OFL.txt", "$pin/OFL.txt", "3".repeat(64), 5)
    private val files = listOf(a, b, ofl)

    @Test
    fun theShippedManifestIsPinnedHashedAndLicensed() {
        assertEquals(emptyList<String>(), ReadingFonts.problems())
        val names = ReadingFonts.FILES.map { it.name }
        for (fam in listOf("Bitter", "Literata")) {
            for (style in listOf("Regular", "Italic", "Bold", "BoldItalic")) assertTrue("$fam-$style", "$fam-$style.ttf" in names)
            assertTrue("$fam-OFL.txt" in names)
        }
        // Static instances only: a variable font file is named Family[wght].ttf upstream.
        assertFalse(names.any { '[' in it })
    }

    @Test
    fun problemsCatchAnUnpinnedUrlABadHashADuplicateAndAMissingLicense() {
        assertEquals(emptyList<String>(), ReadingFonts.problems(files))
        val main = a.copy(url = "https://raw.githubusercontent.com/o/r/main/Fam-Regular.ttf")
        assertTrue(ReadingFonts.problems(listOf(main, b, ofl)).single().contains("isn't pinned"))
        assertTrue(ReadingFonts.problems(listOf(a.copy(url = a.url.replace("https", "http")), b, ofl)).single().contains("isn't pinned"))
        assertTrue(ReadingFonts.problems(listOf(a.copy(sha256 = "1".repeat(63)), b, ofl)).single().contains("sha256"))
        assertTrue(ReadingFonts.problems(listOf(a.copy(sha256 = "A".repeat(64)), b, ofl)).single().contains("sha256"))
        assertTrue(ReadingFonts.problems(listOf(a.copy(name = "../x.ttf"), b, ofl)).any { it.contains("plain") })
        assertTrue(ReadingFonts.problems(listOf(a, a, ofl)).single().contains("twice"))
        assertTrue(ReadingFonts.problems(listOf(a, b)).single().contains("Fam-OFL.txt"))
    }

    @Test
    fun aDownloadIsKeptOnlyWhenItsHashMatches() {
        assertTrue(ReadingFonts.verified(a, "1".repeat(64)))
        assertTrue(ReadingFonts.verified(a, " " + "1".repeat(64).uppercase() + "\n"))
        assertFalse(ReadingFonts.verified(a, "2".repeat(64)))
        assertFalse(ReadingFonts.verified(a, null))
    }

    @Test
    fun onDownloadsWhatIsMissingOrWrongAndNothingTwice() {
        val p = ReadingFonts.plan(true, mapOf(a.name to a.sha256, b.name to "9".repeat(64)), files = files)
        assertEquals(listOf(b, ofl), p.download)
        assertEquals(emptyList<String>(), p.delete)
        val all = files.associate { it.name to it.sha256 }
        assertTrue("a finished plan again does nothing", ReadingFonts.plan(true, all, files = files).nothing)
    }

    @Test
    fun offDeletesOnlyOurFilesAndLeftoverParts() {
        val p = ReadingFonts.plan(false, mapOf(a.name to a.sha256, b.name to "9".repeat(64)),
            stray = listOf("Fam-Bold.ttf.orbit-part", "Mine.ttf"), files = files)
        assertEquals(emptyList<File>(), p.download)
        // b is the user's own file under the same name: kept.
        assertEquals(listOf(a.name, "Fam-Bold.ttf.orbit-part"), p.delete)
        assertTrue(ReadingFonts.plan(false, emptyMap(), files = files).nothing)
    }

    @Test
    fun installedReadsSizes() {
        assertTrue(ReadingFonts.installed(mapOf(a.name to 10L, b.name to 20L, ofl.name to 5L), files))
        assertFalse(ReadingFonts.installed(mapOf(a.name to 10L, b.name to 19L, ofl.name to 5L), files))
        assertFalse(ReadingFonts.installed(mapOf(a.name to 10L), files))
    }

    @Test
    fun theRestartWaitsForScreenOffUnlessTappedAndNeverOnTopOfThePlugins() {
        assertEquals(ReadingFonts.Restart.NONE, ReadingFonts.restart(pending = false, manual = true, screenOff = true, patchRestarting = false))
        assertEquals(ReadingFonts.Restart.WAIT, ReadingFonts.restart(pending = true, manual = false, screenOff = false, patchRestarting = false))
        assertEquals(ReadingFonts.Restart.NOW, ReadingFonts.restart(pending = true, manual = false, screenOff = true, patchRestarting = false))
        assertEquals(ReadingFonts.Restart.NOW, ReadingFonts.restart(pending = true, manual = true, screenOff = false, patchRestarting = false))
        assertEquals(ReadingFonts.Restart.NONE, ReadingFonts.restart(pending = true, manual = false, screenOff = true, patchRestarting = true))
    }

    @Test
    fun verbsAndLines() {
        assertEquals("Turn on", ReadingFonts.verb(wanted = false, busy = false, installed = false, restartPending = false))
        assertNull(ReadingFonts.verb(wanted = true, busy = true, installed = false, restartPending = false))
        assertEquals("Retry", ReadingFonts.verb(wanted = true, busy = false, installed = false, restartPending = false))
        assertEquals("Restart KOReader", ReadingFonts.verb(wanted = true, busy = false, installed = true, restartPending = true))
        assertEquals("Turn off", ReadingFonts.verb(wanted = true, busy = false, installed = true, restartPending = false))
        assertEquals("Downloading…", ReadingFonts.extra(true, true, false, false, ""))
        assertEquals("Not installed: offline", ReadingFonts.extra(true, false, false, false, "offline"))
        assertNull(ReadingFonts.extra(false, false, false, false, "offline"))
        assertNull(ReadingFonts.extra(true, false, true, false, ""))
    }

    @Test
    fun theRowIsOptionalWithItsOwnLines() {
        assertEquals(Checklist.Group.OPTIONAL, Checklist.GROUP_OF[ReadingFonts.ID])
        assertEquals("Without it: ${Checklist.LOSS[ReadingFonts.ID]}", Checklist.optionalLine(ReadingFonts.ID, on = false))
        assertEquals("On: Bitter and Literata are in KOReader's font menu.", Checklist.optionalLine(ReadingFonts.ID, on = true))
    }
}
