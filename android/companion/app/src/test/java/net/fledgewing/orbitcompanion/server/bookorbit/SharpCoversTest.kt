package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import android.content.Context
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * Sharp covers on the device (docs/design/lock-screen.md L7), with a fake server: the sign-in keeps
 * only the token (never the password), the fetch uses the ETag, and a 401 puts Setup's row under
 * Needs you with its loss line.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SharpCoversTest {
    private val ctx: Context = org.robolectric.RuntimeEnvironment.getApplication()
    private val password = "pw-Zq81-never-stored"
    // @fixture opds/recent-feed.xml
    private val feed = File("../../../shared/fixtures/opds/recent-feed.xml").readBytes()
    private val requests = mutableListOf<Pair<String, Map<String, String>>>()
    private var reply: (String, Map<String, String>) -> BookOrbitCovers.Resp = { _, _ -> BookOrbitCovers.Resp(500, null, null) }

    private object FakeVault : BookOrbitCovers.Vault {
        override fun seal(plain: String) = "sealed:" + plain.reversed()
        override fun open(sealed: String) = sealed.removePrefix("sealed:").reversed()
    }

    @Before
    fun setUp() {
        BookOrbitCovers.http = BookOrbitCovers.Http { url, h -> requests += url to h; reply(url, h) }
        BookOrbitCovers.vault = FakeVault
        BookOrbitCovers.scaler = { bytes, _, _ -> byteArrayOf(1, 2) + bytes }
        SettingsStore.store(ctx, "sleep_mode", "recommended")
        val d = SleepScreen.dir().apply { mkdirs() }
        File(d, "covers").mkdirs()
        listOf(5L, 6L).forEach { File(d, "covers/$it.jpg").writeBytes(byteArrayOf(9)) }
        File(d, "pool.json").writeText(
            """{"v":1,"at":1,"source":"up_next","server":"https://b.example/api/v1","user":"reader","storage_limit_mb":250,
               "items":[{"id":5,"title":"A","file":"covers/5.jpg"},{"id":6,"title":"B","file":"covers/6.jpg"}]}""",
        )
    }

    @After
    fun tearDown() {
        SleepScreen.dir().deleteRecursively()
    }

    private fun signIn(): String? {
        reply = { _, _ -> BookOrbitCovers.Resp(200, null, feed) }
        val pw = password.toCharArray()
        val msg = BookOrbitCovers.signIn(ctx, "https://b.example/api/v1", "reader", pw)
        assertTrue("the password is cleared from memory", pw.all { it == '\u0000' })
        return msg
    }

    /** Every file the app keeps: its preferences and its storage. */
    private fun stored(): List<File> {
        val data = ctx.filesDir.parentFile!!
        return data.walkTopDown().filter { it.isFile }.toList() + SleepScreen.dir().walkTopDown().filter { it.isFile }
    }

    @Test
    fun signInKeepsOnlyTheTokenNeverThePassword() {
        assertNull(signIn())
        val (url, headers) = requests.single()
        assertEquals("https://b.example/api/v1/opds/recent?page=1&size=20", url)
        val basic = android.util.Base64.encodeToString("reader:$password".toByteArray(), android.util.Base64.NO_WRAP)
        assertEquals("Basic $basic", headers["Authorization"])
        assertEquals(SharpCoversLogic.State.ON, BookOrbitCovers.state(ctx))
        val files = stored()
        assertTrue("prefs were written: ${files.map { it.name }}", files.any { it.name == "orbit_sharp.xml" })
        files.forEach { f ->
            val text = String(f.readBytes(), Charsets.ISO_8859_1)
            assertFalse("${f.path} holds the password", text.contains(password))
            assertFalse("${f.path} holds the Basic header", text.contains(basic))
            assertFalse("${f.path} holds the plain token", text.contains("7.0123456789abcdef0123456789abcdef"))
        }
    }

    @Test
    fun signInErrorsSayWhatHappened() {
        reply = { _, _ -> BookOrbitCovers.Resp(401, null, null) }
        assertEquals("OPDS username or password not accepted.", BookOrbitCovers.signIn(ctx, "https://b.example", "reader", password.toCharArray()))
        reply = { _, _ -> BookOrbitCovers.Resp(403, null, null) }
        assertTrue(BookOrbitCovers.signIn(ctx, "https://b.example", "reader", password.toCharArray())!!.startsWith("OPDS is off on this server or for this account"))
        assertEquals(SharpCoversLogic.State.NONE, BookOrbitCovers.state(ctx))
        assertNull(BookOrbitCovers.check(ctx))
    }

    @Test
    fun fetchUsesTheEtagAndA401PutsSetupUnderNeedsYou() {
        assertNull(signIn())
        requests.clear()
        reply = { _, _ -> BookOrbitCovers.Resp(200, "\"111\"", byteArrayOf(7, 7)) }
        assertEquals(2, BookOrbitCovers.syncNow(ctx, "test"))
        assertEquals("https://b.example/api/v1/opds/5/cover?t=7.0123456789abcdef0123456789abcdef", requests[0].first)
        assertNull(requests[0].second["If-None-Match"])
        val five = BookOrbitCovers.fileFor(ctx, 5)
        assertNotNull(five)
        assertArrayEquals("stored scaled, not the original", byteArrayOf(1, 2, 7, 7), five!!.readBytes())

        // Second pass: conditional; a 304 keeps the file.
        requests.clear()
        reply = { _, h -> assertEquals("\"111\"", h["If-None-Match"]); BookOrbitCovers.Resp(304, null, null) }
        assertEquals(0, BookOrbitCovers.syncNow(ctx, "test"))
        assertEquals(2, requests.size)
        assertArrayEquals(byteArrayOf(1, 2, 7, 7), BookOrbitCovers.fileFor(ctx, 5)!!.readBytes())

        // The server's secret changed: 401. Thumbnails again, and Setup asks to sign in again.
        reply = { _, _ -> BookOrbitCovers.Resp(401, null, null) }
        BookOrbitCovers.syncNow(ctx, "test")
        assertEquals(SharpCoversLogic.State.LOST, BookOrbitCovers.state(ctx))
        assertNull("the thumbnail is the fallback", BookOrbitCovers.fileFor(ctx, 5))
        val check = BookOrbitCovers.check(ctx)!!
        assertEquals("Sign in again", check.action)
        val item = Checklist.items(listOf(check.row())).single()
        assertEquals(Checklist.State.NEEDS_YOU, item.state)
        assertEquals(Checklist.Group.BOOKORBIT, item.group)
        assertEquals("Until then: sleep-screen covers come from the small thumbnail and look soft.", item.loss)
        // The token is dropped, not kept sealed.
        assertFalse(stored().any { String(it.readBytes(), Charsets.ISO_8859_1).contains("sealed:") })
    }

    @Test
    fun coversLeavingThePoolAreRemoved() {
        assertNull(signIn())
        reply = { _, _ -> BookOrbitCovers.Resp(200, "\"1\"", byteArrayOf(3)) }
        BookOrbitCovers.syncNow(ctx, "test")
        assertTrue(File(BookOrbitCovers.dir(ctx), "6.jpg").isFile)
        File(SleepScreen.dir(), "pool.json").writeText(
            """{"v":1,"server":"https://b.example/api/v1","user":"reader","items":[{"id":5,"title":"A","file":"covers/5.jpg"}]}""",
        )
        BookOrbitCovers.syncNow(ctx, "test")
        assertFalse(File(BookOrbitCovers.dir(ctx), "6.jpg").isFile)
        assertFalse(File(BookOrbitCovers.dir(ctx), "6.etag").isFile)
    }
}
