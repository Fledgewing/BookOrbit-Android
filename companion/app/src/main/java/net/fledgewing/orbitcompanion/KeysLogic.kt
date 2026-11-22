package net.fledgewing.orbitcompanion

/**
 * The Orbit keyboard's ids: Settings.Secure ENABLED_INPUT_METHODS is "id;subtype:id2;…" and
 * DEFAULT_INPUT_METHOD one id, each in short ("pkg/.Cls") or long ("pkg/pkg.Cls") form.
 */
object ImeIds {
    fun forms(pkg: String, cls: String): Set<String> {
        val short = if (cls.startsWith("$pkg.")) "$pkg/${cls.removePrefix(pkg)}" else "$pkg/$cls"
        return setOf("$pkg/$cls", short)
    }

    fun enabledIn(setting: String?, pkg: String, cls: String): Boolean {
        val ids = forms(pkg, cls)
        return setting.orEmpty().split(':').any { it.substringBefore(';') in ids }
    }

    fun isCurrent(current: String?, pkg: String, cls: String): Boolean = current != null && current in forms(pkg, cls)
}

/**
 * "Switch keyboards just in time" for Send-key actions (docs/BTKEYS-DESIGN.md "Send key"):
 * a press switches to the Orbit keyboard, which sends the queued keys once bound, then the
 * previous keyboard comes back. Pure: the caller does the switching and reports back.
 *
 * - Presses during a switch are queued and sent together.
 * - A focused text field skips the press (before the switch if the service saw it; else when
 *   the Orbit keyboard binds to a text editor, which drops the queue and restores).
 * - No bind within [timeoutMs]: the queue is dropped, the previous keyboard restored, and the
 *   failure counted (the UI then suggests "Keep Orbit keyboard active").
 * - Keep active: the Orbit keyboard stays current; presses are sent at once, no switching.
 */
class ImeSwitch(private val timeoutMs: Long = TIMEOUT_MS) {
    companion object {
        const val TIMEOUT_MS = 700L
    }

    enum class Phase { IDLE, SWITCHING, RESTORING }

    /** What the caller does now. [log] is one line for the companion log (never any text). */
    data class Out(
        val switchToOrbit: Boolean = false,
        val send: List<Int> = emptyList(),
        val restore: String? = null,
        val failed: Boolean = false,
        val log: String? = null,
    )

    var phase = Phase.IDLE
        private set
    var failures = 0
        private set
    private var previous: String? = null
    private val queue = mutableListOf<Int>()
    private var startedAt = 0L
    private var restoreAt = 0L

    val queued: List<Int> get() = queue.toList()

    /** When the next [tick] is due, or null. */
    fun nextDue(): Long? = when (phase) {
        Phase.SWITCHING -> startedAt + timeoutMs
        Phase.RESTORING -> restoreAt + timeoutMs
        Phase.IDLE -> null
    }

    /**
     * A mapped press. [current]: the current keyboard's id; [orbitCurrent]: it is the Orbit
     * keyboard and bound (send at once); [editorFocused]: the service saw a text field focused.
     */
    fun press(now: Long, keycode: Int, current: String?, orbitCurrent: Boolean, keepActive: Boolean, editorFocused: Boolean): Out {
        if (orbitCurrent && phase == Phase.IDLE) {
            return Out(send = listOf(keycode), log = "key $keycode sent (Orbit keyboard already active${if (keepActive) ", kept active" else ""})")
        }
        if (editorFocused) return Out(log = "key $keycode skipped: a text field is focused")
        return when (phase) {
            Phase.IDLE -> {
                previous = current
                queue.clear()
                queue += keycode
                startedAt = now
                phase = Phase.SWITCHING
                Out(switchToOrbit = true, log = "key $keycode: switching to the Orbit keyboard")
            }
            Phase.SWITCHING, Phase.RESTORING -> {
                queue += keycode
                Out(log = "key $keycode queued (${phase.name.lowercase()})")
            }
        }
    }

    /** The Orbit keyboard is bound to the app in front. [textEditor]: the editor takes text. */
    fun bound(now: Long, textEditor: Boolean): Out {
        if (phase != Phase.SWITCHING) return Out()
        val ms = now - startedAt
        val prev = previous
        phase = Phase.RESTORING
        restoreAt = now
        if (textEditor) {
            val n = queue.size
            queue.clear()
            return Out(restore = prev, log = "switch took $ms ms; a text field is focused: $n key(s) skipped, restoring")
        }
        val keys = queue.toList()
        queue.clear()
        return Out(send = keys, restore = prev, log = "switch took $ms ms; sent ${keys.joinToString(",")}, restoring")
    }

    /** The previous keyboard is back. Keys queued meanwhile start a new switch. */
    fun restored(now: Long, current: String?): Out {
        if (phase != Phase.RESTORING) return Out()
        val ms = now - restoreAt
        phase = Phase.IDLE
        if (queue.isEmpty()) return Out(log = "restore took $ms ms")
        previous = current
        startedAt = now
        phase = Phase.SWITCHING
        return Out(switchToOrbit = true, log = "restore took $ms ms; ${queue.size} queued key(s): switching again")
    }

    /** Timeouts: no bind (failure) or no restore confirmation (give up waiting). */
    fun tick(now: Long): Out {
        val due = nextDue() ?: return Out()
        if (now < due) return Out()
        return when (phase) {
            Phase.SWITCHING -> {
                failures++
                val n = queue.size
                queue.clear()
                phase = Phase.IDLE
                Out(restore = previous, failed = true, log = "switch timed out after ${now - startedAt} ms: $n key(s) dropped (failure $failures)")
            }
            Phase.RESTORING -> {
                phase = Phase.IDLE
                val n = queue.size
                queue.clear()
                Out(log = "restore not confirmed after ${now - restoreAt} ms${if (n > 0) "; $n queued key(s) dropped" else ""}")
            }
            Phase.IDLE -> Out()
        }
    }
}
