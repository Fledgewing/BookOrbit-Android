package net.fledgewing.orbitcompanion

import org.junit.Assert.assertNull
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketException
import kotlin.concurrent.thread
import java.security.MessageDigest

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class UpdaterUrlTest {
    @Test
    fun canonicalRepository() {
        assertEquals("Fledgewing/BookSync", Updater.REPO)
        assertEquals("https://api.github.com/repos/Fledgewing/BookSync", Updater.API)
    }

    @Test
    fun missingNewRepositoryFallsBackOnceWithoutChangingAssetUrls() {
        val oldApi = "https://api.github.com/repos/${Updater.LEGACY_REPO}"
        assertEquals("$oldApi/releases/latest", Updater.legacyRepoUrl("${Updater.API}/releases/latest", 404))
        assertEquals("$oldApi/releases?per_page=5", Updater.legacyRepoUrl("${Updater.API}/releases?per_page=5", 404))
        assertNull(Updater.legacyRepoUrl("$oldApi/releases/latest", 404))
        assertNull(Updater.legacyRepoUrl("${Updater.API}/releases/latest", 403))
        assertNull(Updater.legacyRepoUrl("https://github.com/${Updater.REPO}/releases/download/v1/file", 404))
    }

    @Test
    fun signedFeedUsesCanonicalLocationWithOneLegacyLocationFallback() {
        assertEquals("https://raw.githubusercontent.com/Fledgewing/BookSync/android-feed/android/releases.json",
            AndroidReleaseFeed.URL)
        assertEquals(AndroidReleaseFeed.LEGACY_URL, Updater.legacyRepoUrl(AndroidReleaseFeed.URL, 404))
        assertNull(Updater.legacyRepoUrl(AndroidReleaseFeed.LEGACY_URL, 404))
        assertNull(Updater.legacyRepoUrl(AndroidReleaseFeed.URL, 403))
    }

    @Test
    fun metadataAndDownloadsFollowRepositoryAndAssetRedirects() {
        val payload = "release bytes".toByteArray()
        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        val base = "http://127.0.0.1:${server.localPort}"
        val worker = thread(isDaemon = true) {
            try {
                while (!server.isClosed) server.accept().use { socket ->
                    val input = socket.getInputStream().bufferedReader()
                    val path = input.readLine().split(" ")[1]
                    while (!input.readLine().isNullOrEmpty()) { /* request headers */ }
                    val response = if (path == "/bytes") {
                        "HTTP/1.1 200 OK\r\nContent-Length: ${payload.size}\r\nConnection: close\r\n\r\n${String(payload)}"
                    } else {
                        val status = path.removePrefix("/")
                        // Change host too, as GitHub's asset downloads do.
                        "HTTP/1.1 $status Moved\r\nLocation: http://localhost:${server.localPort}/bytes\r\n" +
                            "Content-Length: 0\r\nConnection: close\r\n\r\n"
                    }
                    socket.getOutputStream().write(response.toByteArray())
                }
            } catch (e: SocketException) {
                if (!server.isClosed) throw e
            }
        }
        val file = File.createTempFile("updater-url-", ".part")
        try {
            for (status in listOf(301, 302, 307)) {
                assertEquals(String(payload), Updater.httpText("$base/$status"))
                val digest = MessageDigest.getInstance("SHA-256").digest(payload)
                    .joinToString("") { "%02x".format(it) }
                assertEquals(digest, Updater.download("$base/$status", file))
                assertEquals(String(payload), file.readText())
            }
        } finally {
            file.delete()
            server.close()
            worker.join(2_000)
        }
    }
}
