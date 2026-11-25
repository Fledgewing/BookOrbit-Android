package net.fledgewing.orbitcompanion

import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import kotlin.concurrent.thread

/**
 * One interception path (v0.4.2, android/docs/BTKEYS-DESIGN.md "One path"): with the accessibility
 * service on, it takes mapped keys in every app. In KOReader it doesn't tap: it sends the
 * action to the patch, which does it exactly. Pure, tested.
 */
object ClickRoute {
    enum class Route { PASS, TO_PATCH, ACT }

    /**
     * [fg]: the app in front; [own]: the companion (the capture screen needs raw keys);
     * [patchListening]: the patch holds the /clicks channel. Without it KOReader gets the key
     * and the patch's own key path (the fallback) handles it.
     */
    fun route(fg: String?, own: String, patchListening: Boolean): Route = when (fg) {
        own -> Route.PASS
        Koreader.PKG -> if (patchListening) Route.TO_PATCH else Route.PASS
        else -> Route.ACT
    }

    /** Channel lines (android/docs/INTERFACE.md "/clicks"). */
    fun clickLine(action: ClickAction, seq: Int): String = "CLICK ${action.inKoreader.key} $seq\n"
    fun serviceLine(on: Boolean): String = "SERVICE ${if (on) "on" else "off"}\n"
    fun settingsLine(at: Long): String = "SETTINGS $at\n"
    fun proofLine(proof: String): String = "ORBIT $proof\n"
}

/**
 * The click channel's keys (docs/design/security.md): the plugin gets a key and a proof through
 * the caller-checked call, sends the key with `GET /clicks`, and trusts the channel only once its
 * first line carries the proof. Another app can neither open the channel nor pose as it.
 */
class ClickKeys(private val random: java.security.SecureRandom = java.security.SecureRandom(), private val keepMs: Long = 60_000L) {
    private val issued = HashMap<String, Pair<String, Long>>()

    private fun hex(): String = ByteArray(16).also { random.nextBytes(it) }.joinToString("") { "%02x".format(it) }

    @Synchronized
    fun issue(nowMs: Long): Pair<String, String> {
        issued.entries.removeAll { nowMs - it.value.second > keepMs }
        val key = hex()
        val proof = hex()
        issued[key] = proof to nowMs
        return key to proof
    }

    @Synchronized
    fun take(key: String?, nowMs: Long): String? {
        val e = issued.remove(key ?: return null) ?: return null
        return if (nowMs - e.second <= keepMs) e.first else null
    }
}

/**
 * The patch's end of `GET /clicks` on the loopback status port: a kept-open connection that
 * gets one line per action. The patch watches the socket in KOReader's own event loop, so
 * nothing polls. A reader thread notices the patch going away at once.
 */
object ClickChannel {
    private val clients = CopyOnWriteArrayList<Socket>()
    private val keys = ClickKeys()

    /** A key and its proof for the plugin's next `GET /clicks` (asked through CommandProvider). */
    fun newKey(): Pair<String, String> = keys.issue(android.os.SystemClock.elapsedRealtime())

    /** The proof for [key] when the plugin asked for it (once, within a minute), else null. */
    fun accept(key: String?): String? = keys.take(key, android.os.SystemClock.elapsedRealtime())
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "orbit-clicks").apply { isDaemon = true } }
    @Volatile
    private var seq = 0

    val listening: Boolean get() = clients.isNotEmpty()

    /**
     * Called on the status server's thread for `GET /clicks` (headers already read), with the
     * proof for the key it carried: the first line proves to the plugin that this is the companion.
     */
    fun add(s: Socket, patchVersion: String?, proof: String) {
        try {
            s.tcpNoDelay = true
            s.soTimeout = 0
            val out = s.getOutputStream()
            out.write(("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\n\r\n" +
                ClickRoute.proofLine(proof) + ClickRoute.serviceLine(ClickerService.connected)).toByteArray(Charsets.ISO_8859_1))
            out.flush()
        } catch (e: Exception) {
            OLog.w("clicks: patch channel failed to start", e)
            runCatching { s.close() }
            return
        }
        clients += s
        OLog.i("clicks: patch ${patchVersion ?: "?"} listening (service ${if (ClickerService.connected) "on" else "off"})")
        thread(name = "orbit-clicks-peer", isDaemon = true) {
            try {
                while (s.getInputStream().read() >= 0) Unit
            } catch (_: Exception) {
            }
            drop(s, "closed by KOReader")
        }
    }

    private fun drop(s: Socket, why: String) {
        if (clients.remove(s)) OLog.i("clicks: patch channel $why")
        runCatching { s.close() }
    }

    /** Send an action to the patch; false when no patch is listening. */
    fun send(a: ClickAction): Boolean {
        if (clients.isEmpty()) return false
        val line = ClickRoute.clickLine(a, ++seq)
        write(line)
        return true
    }

    /** A setting changed here: the plugin reads /status now (docs/design/companion-settings.md §4.5). */
    fun settings(at: Long) {
        if (clients.isNotEmpty()) write(ClickRoute.settingsLine(at))
    }

    /** The service came or went: the patch turns its own key path off or on. */
    fun service(on: Boolean) {
        if (clients.isNotEmpty()) write(ClickRoute.serviceLine(on))
    }

    private fun write(line: String) {
        io.execute {
            clients.forEach { s ->
                try {
                    s.getOutputStream().apply { write(line.toByteArray(Charsets.ISO_8859_1)); flush() }
                } catch (e: Exception) {
                    drop(s, "write failed ($e)")
                }
            }
        }
    }
}
