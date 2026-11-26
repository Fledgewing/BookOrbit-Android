package net.fledgewing.orbitcompanion

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class MirrorRunsTest {
    @Test fun queuedAndWorkingRunsSurviveQueriesAndDeduplicateUntilEnded() {
        val root = Files.createTempDirectory("mirror-admission").toFile()
        fun state() = LuaValue.parse(File(root, "mirror/run.lua").readBytes()) as Map<*, *>
        try {
            val runs = MirrorRuns { root }
            assertTrue(runs.admit("one", "resume", 15, 100))
            // The executor has not started: sleep work can block it indefinitely.
            repeat(100) {
                runs.query("one")
                assertEquals("queued", state()["state"])
                assertFalse(runs.admit("duplicate", "resume", 0, 100))
                assertEquals("one", state()["run"])
                assertEquals("duplicate", state()["query_for"])
                assertEquals(15L, state()["done"])
                assertEquals(100L, state()["total"])
            }
            runs.started("one")
            assertEquals("started", state()["state"])
            runs.progress(mapOf("run" to "one", "done" to 37L, "total" to 100L, "pct" to 37L))
            runs.query("one")
            assertEquals("progress", state()["state"])
            assertEquals(37L, state()["done"])
            assertFalse(runs.admit("three", "resume", 0, 100))
            runs.ended("one")
            assertEquals("stopped", state()["state"])
            assertTrue(runs.admit("next", "resume", 37, 100))
            // A new process cannot vouch for the previous process's queued/running work.
            MirrorRuns { root }.query("next")
            assertEquals("stopped", state()["state"])
        } finally { root.deleteRecursively() }
    }
}
