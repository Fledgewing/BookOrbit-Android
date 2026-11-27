// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class StatusMarginRepairTest {
    private val keys = StatusMarginRepair.bookKeys + StatusMarginRepair.footerKeys
    private fun lua(bottom: Int) = """-- KOReader metadata
return {
    ["copt_t_page_margin"] = 15,
    ["copt_b_page_margin"] = $bottom,
    ["copt_sync_t_b_page_margins"] = 1,
    ["copt_l_page_margin"] = 23,
    ["copt_font_size"] = 24,
    ["reader_footer_mode"] = 2,
    ["progress"] = 0.75,
    ["nested"] = { ["copt_b_page_margin"] = 999 },
    ["text"] = [=[ ["copt_b_page_margin"] = 123, ]=],
}
"""
    @Test fun repairsOnlyAllowlistedKeysWithoutReserializingOtherBytes() {
        val current = lua(10)
        val old = lua(15).replace("= 23", "= 99").replace("= 24", "= 8").replace("= 0.75", "= 0.1")
        assertEquals(lua(15), StatusMarginRepair.restore(current, old, keys))
        val noSync = lua(15).replace("    [\"copt_sync_t_b_page_margins\"] = 1,\n", "")
        val restored = StatusMarginRepair.restore(current, noSync, keys)!!
        assertFalse(restored.contains("copt_sync_t_b_page_margins"))
        assertTrue(restored.contains("[\"copt_b_page_margin\"] = 15,"))
        assertTrue(restored.contains("[\"copt_l_page_margin\"] = 23,"))
    }
    @Test fun malformedExecutableAndDuplicateValuesAreNeverEvaluatedOrRepaired() {
        for (source in listOf("return os.execute('ignored')", "return { [\"copt_b_page_margin\"] = bad() }", "return {", lua(10).replace("return {", "return { [\"copt_b_page_margin\"]=5,"))) {
            assertNull(StatusMarginRepair.restore(source, lua(15), keys))
        }
        assertNull(StatusMarginRepair.restore(lua(10), "broken backup", keys))
        assertEquals(lua(10), StatusMarginRepair.restore(lua(10), lua(10), keys))
    }
    @Test fun startupRepairsBooksAndGlobalModeOncePreservesBackupsAndCheckpointsEveryWalk() {
        val root = Files.createTempDirectory("margin-repair").toFile()
        val external = Files.createTempDirectory("outside-repair").toFile()
        try {
            val book = File(root, "Books/Synthetic.sdr/metadata.epub.lua").apply { parentFile!!.mkdirs(); writeText(lua(10)) }
            val old = File(book.path + ".old").apply { writeText(lua(15)) }
            val global = File(root, "koreader/settings.reader.lua").apply { parentFile!!.mkdirs(); writeText("return { [\"reader_footer_mode\"] = 1, [\"footer\"] = { [\"reclaim_height\"] = true }, }") }
            File(global.path + ".old").writeText("return { [\"reader_footer_mode\"] = 0, [\"footer\"] = { [\"reclaim_height\"] = false }, }")
            val outside = File(external, "Untouched.sdr").apply { mkdirs() }
            File(outside,"metadata.epub.lua").writeText(lua(10))
            File(outside,"metadata.epub.lua.old").writeText(lua(15))
            Files.createSymbolicLink(File(root,"linked.sdr").toPath(),outside.toPath())
            val missing = File(root,"Books/Missing.sdr/metadata.epub.lua").apply { parentFile!!.mkdirs(); writeText(lua(10)) }
            var checks = 0
            val logs = arrayListOf<String>()
            StatusMarginRepair.run(root, { checks++ }, logs::add)
            assertTrue(checks > 10)
            assertEquals(lua(15),book.readText()); assertEquals(lua(15),old.readText())
            assertEquals(lua(10),File(book.path + ".booksync-before-w31").readText())
            assertEquals(lua(10),missing.readText()); assertEquals(lua(10),File(outside,"metadata.epub.lua").readText())
            assertTrue(global.readText().contains("[\"reader_footer_mode\"] = 0,"))
            assertTrue(global.readText().contains("[\"reclaim_height\"] = true"))
            assertEquals(2,logs.count { it.contains("restored") })
            book.writeText(lua(25)) // the user's later choice must survive every future startup
            File(root,"koreader/settings/booksync-w31-repair.done").delete() // interrupted/restarted scan
            StatusMarginRepair.run(root, {}, {})
            assertEquals(lua(25),book.readText())
            StatusMarginRepair.run(root, {}, {})
        } finally { root.deleteRecursively(); external.deleteRecursively() }
    }
    @Test fun loadedBookCapturesGoodBackupBeforeNativeCloseRotatesIt() {
        val root=Files.createTempDirectory("margin-loaded").toFile()
        try {
            val book=File(root,"Book.sdr/metadata.epub.lua").apply { parentFile!!.mkdirs(); writeText(lua(10)) }
            val old=File(book.path+".old").apply { writeText(lua(15)) }
            assertFalse(StatusMarginRepair.run(root, {}, {}, canApply={false}))
            assertEquals(lua(10),book.readText())
            assertEquals(lua(15),File(book.path+".booksync-w31.old").readText())
            assertFalse(File(root,"koreader/settings/booksync-w31-repair.done").exists())
            // KOReader closes and saves progress, rotating the original backup.
            old.writeText(lua(10))
            book.writeText(lua(10).replace("= 0.75", "= 0.8"))
            assertTrue(StatusMarginRepair.run(root, {}, {}, canApply={true}))
            assertEquals(lua(15).replace("= 0.75", "= 0.8"),book.readText())
            assertEquals(lua(10),old.readText())
        } finally { root.deleteRecursively() }
    }
    @Test fun openingBookBeforeReplacementDefersWithoutChangingNativeFile() {
        val root=Files.createTempDirectory("margin-reopen").toFile()
        try {
            val book=File(root,"Book.sdr/metadata.epub.lua").apply { parentFile!!.mkdirs(); writeText(lua(10)) }
            File(book.path+".old").writeText(lua(15))
            var queries=0
            assertFalse(StatusMarginRepair.run(root, {}, {}, canApply={ ++queries < 2 }))
            assertEquals(lua(10),book.readText())
            assertFalse(File(book.path+".booksync-w31.tmp").exists())
            assertFalse(File(book.path+".booksync-w31.done").exists())
            assertTrue(StatusMarginRepair.run(root, {}, {}))
            assertEquals(lua(15),book.readText())
        } finally { root.deleteRecursively() }
    }
    @Test fun crashAfterReplacementNeverReplaysOverLaterUserValues() {
        val root=Files.createTempDirectory("margin-crash").toFile()
        try {
            val book=File(root,"Book.sdr/metadata.epub.lua").apply { parentFile!!.mkdirs(); writeText(lua(25)) }
            File(book.path+".old").writeText(lua(15))
            File(book.path+".booksync-before-w31").writeText(lua(10))
            StatusMarginRepair.run(root, {}, {})
            assertEquals(lua(25),book.readText())
        } finally { root.deleteRecursively() }
    }
    @Test fun selectedStarbreakerSidecarIsCheckedEvenAfterTheStartupScanFinished() {
        val root = Files.createTempDirectory("repair-selected").toFile()
        try {
            File(root, "koreader/settings/booksync-w31-repair.done").apply { parentFile!!.mkdirs(); writeText("complete") }
            val file = File(root, "Books/MoonReader/Series/Starbreaker/06.00 - Starbreaker_ Volume 6_ Starbreaker (Unabridged) - Text Only [21234].sdr/metadata.epub.lua")
            file.parentFile!!.mkdirs(); file.writeText(lua(10))
            File(file.path + ".old").writeText(lua(15))
            val logs = arrayListOf<String>()
            assertTrue(StatusMarginRepair.run(root, {}, logs::add, target = file))
            assertEquals(lua(15), file.readText())
            assertEquals(lua(10), File(file.path + ".booksync-before-w31").readText())
            assertTrue(logs.any { "selected sidecar scan" in it })
            assertTrue(logs.any { "restored" in it })
            file.writeText(lua(25))
            StatusMarginRepair.run(root, {}, {}, target = file)
            assertEquals("a later user choice survives", lua(25), file.readText())
        } finally { root.deleteRecursively() }
    }


    @Test fun closedBookScanDiscoversAnotherBookAfterAnEarlierCompleteScan() {
        val root = Files.createTempDirectory("repair-new-history").toFile()
        try {
            assertTrue(StatusMarginRepair.run(root, {}, {}))
            val book = File(root, "New.sdr/metadata.epub.lua").apply { parentFile!!.mkdirs(); writeText(lua(10)) }
            File(book.path + ".old").writeText(lua(15))
            val logs = arrayListOf<String>()
            assertTrue(StatusMarginRepair.run(root, {}, logs::add))
            assertEquals(lua(15), book.readText())
            assertTrue(logs.any { "copt_b_page_margin:10->15" in it })
        } finally { root.deleteRecursively() }
    }

    @Test fun globalRepairPublishesMatchingNativeMemoryUpdateAndRetainsItsRecoverySource() {
        val root = Files.createTempDirectory("repair-global-memory").toFile()
        try {
            val global = File(root, "koreader/settings.reader.lua").apply {
                parentFile!!.mkdirs(); writeText("return { [\"reader_footer_mode\"] = 1, }")
            }
            val old = File(global.path + ".old").apply { writeText("return { [\"reader_footer_mode\"] = 0, }") }
            val events = arrayListOf<Triple<String, String, String>>()
            val notify: (String, String, String) -> Unit = { b, a, t -> events.add(Triple(b, a, t)) }
            assertFalse(StatusMarginRepair.run(root, {}, {}, globalRepair = notify, canApply = { false }))
            assertTrue(events.isEmpty())
            assertTrue(StatusMarginRepair.run(root, {}, {}, globalRepair = notify))
            assertEquals("1", events.single().first)
            assertEquals("0", events.single().second)
            assertTrue(global.readText().contains("= 0"))
            // A subsequent native flush can rotate .old. The recovery event must
            // survive a companion restart until KOReader acknowledges its mailbox.
            old.writeText("return { [\"reader_footer_mode\"] = 1, }")
            StatusMarginRepair.run(root, {}, {}, globalRepair = notify)
            assertEquals(2, events.size)
            assertEquals(events[0], events[1])
        } finally { root.deleteRecursively() }
    }

    @Test(timeout = 3000) fun oversizedSettingsTokenStreamStopsWithoutChangingAnyFile() {
        val root = Files.createTempDirectory("repair-budget").toFile()
        try {
            val book = File(root, "Book.sdr/metadata.epub.lua").apply { parentFile!!.mkdirs() }
            val text = "return {" + "[1]=1,".repeat(50_000) + "}"
            book.writeText(text)
            File(book.path + ".old").writeText(lua(15))
            val logs = arrayListOf<String>()
            assertTrue(StatusMarginRepair.run(root, {}, logs::add))
            assertEquals(text, book.readText())
            assertTrue(logs.any { "unsupported settings" in it })
            assertFalse(File(book.path + ".booksync-w31.done").exists())
        } finally { root.deleteRecursively() }
    }

    @Test fun scanWatchdogStopsWithoutCompletionAndKeepsAlreadyCheckedFiles() {
        val root = Files.createTempDirectory("repair-watchdog").toFile()
        try {
            val book = File(root, "Book.sdr/metadata.epub.lua").apply { parentFile!!.mkdirs(); writeText(lua(10)) }
            File(book.path + ".old").writeText(lua(15))
            var time = 0L
            try {
                StatusMarginRepair.run(root, {}, {}, clock = { time.also { time += 30_001 } })
                fail("scan must stop")
            } catch (e: IllegalStateException) { assertEquals("status repair scan watchdog", e.message) }
            assertFalse(File(root, "koreader/settings/booksync-w31-repair.done").exists())
            assertEquals(lua(10), book.readText())
            assertTrue(StatusMarginRepair.run(root, {}, {}))
            assertEquals(lua(15), book.readText())
        } finally { root.deleteRecursively() }
    }

    @Test fun interruptionDoesNotMarkMigrationComplete() {
        val root=Files.createTempDirectory("margin-paused").toFile()
        try {
            try { StatusMarginRepair.run(root, { throw InterruptedException() }, {}); fail() } catch (_: InterruptedException) { }
            assertFalse(File(root,"koreader/settings/booksync-w31-repair.done").exists())
            val source=File("src/main/java/net/fledgewing/orbitcompanion/StatusMarginRepair.kt").readText()
            assertTrue(source.contains("BulkWork::checkpoint"))
            assertTrue(source.contains("closedReported && prefs.koreaderBook == \"0\""))
            assertTrue(source.indexOf("maintenance.execute") < source.indexOf("val complete = run(android.os.Environment"))
        } finally { root.deleteRecursively() }
    }
}
