package net.fledgewing.orbitcompanion

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * shared/fixtures/REGISTRY.json against the companion's tests: every rule table that names "kt"
 * as a reader is marked read ("@fixture <file>#<section>", or "@fixture <file>" for a whole file)
 * by a test here, and no test marks one the registry does not give to "kt". The plugin's
 * test_registry.lua also checks that every table has a row.
 */
class RegistryTest {
    private val root = File("../../../shared/fixtures")
    private val mark = Regex("@fixture ([\\w./-]+(?:#[\\w.]+)?)")

    @Test
    fun theCompanionReadsEveryTableItIsNamedFor() {
        val tables = JSONObject(File(root, "REGISTRY.json").readText()).getJSONArray("tables")
        val given = (0 until tables.length()).map { tables.getJSONObject(it) }
            .filter { r -> r.getJSONArray("readers").let { a -> (0 until a.length()).any { a.getString(it) == "kt" } } }
            .map { r -> r.getString("file") + (r.optString("section").takeIf { it.isNotEmpty() }?.let { "#$it" } ?: "") }
            .toSortedSet()
        val marks = File("src/test/java").walk().filter { it.isFile && it.name.endsWith(".kt") && it.name != "RegistryTest.kt" }
            .flatMap { f -> mark.findAll(f.readText()).map { it.groupValues[1] to f.name } }
            .groupBy({ it.first }, { it.second })
        val problems = given.filter { it !in marks }.map { "no companion test reads $it (mark it '@fixture $it')" } +
            marks.filterKeys { it !in given }.map { (m, where) -> "${where.first()} marks $m, which REGISTRY.json does not give to kt" }
        assertEquals("REGISTRY.json", "", problems.sorted().joinToString("\n"))
    }
}
