package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URI
import java.nio.file.Files

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ConnectorTransportTest {
    @Test fun standaloneOpdsAndSyncReachTheirProtocolsWithoutExportingCredentials() {
        val root = Files.createTempDirectory("connector-http").toFile()
        val server = ServerSocket(0,16,InetAddress.getLoopbackAddress())
        val headers = java.util.Collections.synchronizedList(mutableListOf<Map<String,List<String>>>())
        val thread = Thread {
            try {
                while (!server.isClosed) server.accept().use { socket ->
                    val reader = socket.getInputStream().bufferedReader()
                    val path = reader.readLine().split(' ')[1].substringBefore('?')
                    val captured = mutableMapOf<String,List<String>>()
                    while (true) {
                        val line = reader.readLine() ?: break
                        if (line.isEmpty()) break
                        captured[line.substringBefore(':')] = listOf(line.substringAfter(':').trim())
                    }
                    headers.add(captured)
                    val text = when {
                        path.endsWith("/catalog") -> """<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>Moon</title><link rel="http://opds-spec.org/acquisition" href="/api/v1/opds/1/download?fileId=1" type="application/epub+zip"/></entry></feed>"""
                        path.endsWith("/opds") -> """<feed xmlns="http://www.w3.org/2005/Atom"/>"""
                        path.endsWith("/download") -> "fixture-book"
                        else -> """{"percentage":0.5,"progress":"position","userkey":"must-not-escape"}"""
                    }
                    val body = text.toByteArray()
                    socket.getOutputStream().apply {
                        write("HTTP/1.1 200 OK\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
                        write(body); flush()
                    }
                }
            } catch (_: java.net.SocketException) { }
        }.apply { isDaemon = true; start() }
        try {
            val base = URI("http",null,server.inetAddress.hostAddress,server.localPort,"/api/v1",null,null).toString()
            val credentials = ServerCredentials(object : AccountVault {
                var v: Map<String,Any?>? = null
                override fun load() = v
                override fun save(value: Map<String,Any?>?) { v = value }
            })
            val account = BookOrbitAccount(credentials.accountVault,AccountHttp)
            val adapter = BookOrbitServerAdapter(credentials,account,ConnectorHttp)
            val key = "a".repeat(32)
            adapter.setLogin("sync",base,"fixture",key.toCharArray(),derivedKey = true)
            assertEquals(key,credentials.login("sync")!!.secret)
            val position = adapter.position("b".repeat(32))
            assertEquals(0.5,position["percentage"]); assertFalse(position.toString().contains("must-not-escape"))
            adapter.setLogin("opds",base,"fixture","opds-fixture-secret".toCharArray())
            val catalog = adapter.catalog()
            val row = (catalog["items"] as List<*>).single() as Map<*,*>
            val destination = root.resolve("book.epub")
            assertTrue(adapter.download(row["key"] as String,destination)); assertEquals("fixture-book",destination.readText())
            assertTrue(headers.any { h -> h.entries.any { it.key.equals("x-auth-key",true) && it.value.single() == key } })
            assertTrue(headers.any { h -> h.keys.any { it.equals("Authorization",true) } })
            for (result in listOf(adapter.state(),catalog,position)) {
                assertFalse(result.toString().contains(key)); assertFalse(result.toString().contains("opds-fixture-secret"))
            }
            adapter.removeLogin("sync"); assertEquals(true,(adapter.state()["opds"] as Map<*,*>)["set"])
        } finally { server.close(); thread.join(1000); root.deleteRecursively() }
    }
    @Test fun opdsRejectsExternalCredentialsAndDocumentDeclarations() {
        val base = "https://library.invalid/api/v1"
        for (link in listOf("https://other.invalid/api/v1/opds/1/download", "https://user:password@library.invalid/api/v1/opds/1/download", "/api/v1/auth/me")) {
            try { OpdsCatalog.safePath(base,link); fail() } catch (_: IllegalArgumentException) { }
        }
        val xml = """<!DOCTYPE feed [<!ENTITY xxe SYSTEM "https://other.invalid/">]><feed><entry><title>&xxe;</title></entry></feed>"""
        try { OpdsCatalog.parse(xml,base,24); fail() } catch (_: Exception) { }
    }
}
