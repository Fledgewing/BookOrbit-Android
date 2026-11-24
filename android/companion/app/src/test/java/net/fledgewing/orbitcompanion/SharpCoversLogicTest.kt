package net.fledgewing.orbitcompanion

import net.fledgewing.orbitcompanion.SharpCoversLogic.Outcome
import net.fledgewing.orbitcompanion.SharpCoversLogic.State
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Sharp sleep-screen covers' rules (docs/design/lock-screen.md L7). */
class SharpCoversLogicTest {
    private val feed = File("../../../shared/fixtures/opds/recent-feed.xml").readText()

    @Test
    fun theTokenComesFromTheFeedsImageLinks() {
        // The first book has no cover; the token is on the second one's image links.
        assertEquals("7.0123456789abcdef0123456789abcdef", SharpCoversLogic.tokenFromFeed(feed))
        assertNull(SharpCoversLogic.tokenFromFeed(feed.replace(Regex("""<link rel="http://opds-spec.org/image[^>]*>"""), "")))
        // Download links and garbage never pass for a token.
        assertNull(SharpCoversLogic.tokenFromFeed("""<link href="/api/v1/opds/42/download?t=7.0123456789abcdef0123456789abcdef"/>"""))
        assertNull(SharpCoversLogic.tokenFromFeed("""<link href="/api/v1/opds/42/cover?t=nope"/>"""))
        assertEquals("12.00112233445566778899aabbccddeeff",
            SharpCoversLogic.tokenFromFeed("""<link href="/api/v1/opds/9/thumbnail?t=12%2E00112233445566778899aabbccddeeff"/>"""))
    }

    @Test
    fun urlsFollowThePluginsServerUrl() {
        listOf("https://b.example", "https://b.example/", "https://b.example/api/v1", "https://b.example/api/v1/", "https://b.example/api/v1/koreader")
            .forEach { assertEquals(it, "https://b.example/api/v1", SharpCoversLogic.apiBase(it)) }
        assertNull(SharpCoversLogic.apiBase(""))
        assertNull(SharpCoversLogic.apiBase("ftp://b"))
        assertEquals("https://b.example/api/v1/opds/42/cover?t=7.abc", SharpCoversLogic.coverUrl("https://b.example/api/v1", 42, "7.abc"))
        assertTrue(SharpCoversLogic.feedUrl("https://b.example/api/v1").startsWith("https://b.example/api/v1/opds/recent?"))
    }

    @Test
    fun statusCodes() {
        assertEquals(Outcome.OK, SharpCoversLogic.outcome(200))
        assertEquals(Outcome.NOT_MODIFIED, SharpCoversLogic.outcome(304))
        assertEquals(Outcome.AUTH_LOST, SharpCoversLogic.outcome(401))
        assertEquals(Outcome.OPDS_OFF, SharpCoversLogic.outcome(403))
        assertEquals(Outcome.NO_COVER, SharpCoversLogic.outcome(404))
        assertEquals(Outcome.LATER, SharpCoversLogic.outcome(502))
        assertEquals(SharpCoversLogic.WRONG, SharpCoversLogic.signInMessage(Outcome.AUTH_LOST, false))
        assertEquals("OPDS username or password not accepted.", SharpCoversLogic.WRONG)
        assertTrue(SharpCoversLogic.signInMessage(Outcome.OPDS_OFF, false)!!.startsWith("OPDS is off on this server or for this account"))
        assertTrue(SharpCoversLogic.signInMessage(Outcome.OPDS_OFF, false)!!.contains("thumbnail"))
        assertEquals(SharpCoversLogic.NO_TOKEN, SharpCoversLogic.signInMessage(Outcome.OK, false))
        assertNull(SharpCoversLogic.signInMessage(Outcome.OK, true))
    }

    @Test
    fun coversAreFittedToThePanelOnceAndNeverEnlarged() {
        // A 1600 x 2400 cover on the M8C (1404 x 1872): height-bound.
        assertEquals(1248 to 1872, SharpCoversLogic.fit(1600, 2400, 1404, 1872))
        // A wide cover: width-bound.
        assertEquals(1404 to 702, SharpCoversLogic.fit(2000, 1000, 1404, 1872))
        // The thumbnail size, already smaller: kept as it is.
        assertEquals(400 to 600, SharpCoversLogic.fit(400, 600, 1404, 1872))
        assertEquals(0 to 0, SharpCoversLogic.fit(0, 600, 1404, 1872))
        assertEquals(1, SharpCoversLogic.sample(1600, 2400, 1248, 1872))
        assertEquals(2, SharpCoversLogic.sample(3200, 4800, 1248, 1872))
        assertEquals(4, SharpCoversLogic.sample(6000, 9000, 1248, 1872))
    }

    @Test
    fun storageStaysBounded() {
        assertEquals(24L * 1024 * 1024, SharpCoversLogic.maxBytes(0))
        assertEquals(24L * 1024 * 1024, SharpCoversLogic.maxBytes(1024))
        assertEquals(10L * 1024 * 1024, SharpCoversLogic.maxBytes(100))
        val s = listOf(
            SharpCoversLogic.Stored(1, 400, usedAt = 30), SharpCoversLogic.Stored(2, 400, usedAt = 10),
            SharpCoversLogic.Stored(3, 400, usedAt = 20), SharpCoversLogic.Stored(9, 400, usedAt = 99),
        )
        // 9 left the pool; then the least recently used until 800 bytes fit.
        assertEquals(listOf(9L, 2L), SharpCoversLogic.prune(s, setOf(1, 2, 3), 800))
        assertEquals(listOf(9L), SharpCoversLogic.prune(s, setOf(1, 2, 3), 10_000))
    }

    @Test
    fun theRowSaysTheFallbackNotAMode() {
        val (none, v0) = SharpCoversLogic.row(State.NONE, true, 0, 12, null)
        assertEquals("Sign in once ›", v0)
        assertTrue(none.contains("OPDS login") && none.contains("thumbnail"))
        assertEquals("Sign in again ›", SharpCoversLogic.row(State.LOST, true, 0, 12, "OPDS is off on this server or for this account").second)
        assertTrue(SharpCoversLogic.row(State.ON, true, 9, 12, null).first.contains("9 of 12"))
        assertEquals("", SharpCoversLogic.row(State.NONE, false, 0, 0, null).second)
        assertTrue(SharpCoversLogic.PROMPT.contains("BookOrbit OPDS login (often the same as your KOReader sync login)"))
    }
}
