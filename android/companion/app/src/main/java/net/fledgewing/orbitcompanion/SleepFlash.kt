package net.fledgewing.orbitcompanion

/**
 * The sleep screen's clearing flash (docs/design/lock-screen.md L10): a full black frame, then a
 * full white one, then the cover. A whole-panel black/white change clears e-ink ghosting on most
 * controllers whatever refresh mode the app runs in, with plain Android drawing only (no vendor
 * API). Off by default (Sleep screen › "Clearing flash before the cover", `sleep_flash`): the
 * alternative to setting the reader's screen mode for Orbit (Setup's "Screen mode for Orbit").
 * Each flash frame is held until it has been drawn (a frame callback) plus [HOLD_MS], so the
 * panel has time to show it before the next one.
 *
 * Pure: the dream supplies how to show a frame, wait for a drawn frame, wait, and read the clock
 * (SleepFlashTest drives it with a fake clock).
 */
object SleepFlash {
    enum class Frame { BLACK, WHITE, COVER }

    val SEQUENCE = listOf(Frame.BLACK, Frame.WHITE, Frame.COVER)

    /** What the dream draws: the flash sequence when it is on, else the cover alone. */
    fun frames(flash: Boolean): List<Frame> = if (flash) SEQUENCE else listOf(Frame.COVER)

    const val LABEL = "Clearing flash before the cover"
    const val ABOUT = "If the sleep screen shows ghosting and you can't set the reader's screen mode for BookSync, " +
        "a short black-and-white flash clears it before the cover appears."

    /** How long each flash frame stays after it is drawn: long enough for one panel update. */
    const val HOLD_MS = 250L

    fun line(ms: Long): String = "sleep screen: flash sequence done in $ms ms"

    class Runner(
        private val frames: List<Frame>,
        private val show: (Frame) -> Unit,
        /** Runs the callback once the frame just shown has been drawn. */
        private val afterDrawn: (() -> Unit) -> Unit,
        private val delay: (Long, () -> Unit) -> Unit,
        private val now: () -> Long,
        /** Called once the cover is shown, with the time since start (ms). */
        private val done: (Long) -> Unit,
        private val hold: Long = HOLD_MS,
    ) {
        @Volatile
        var cancelled = false
            private set
        private var t0 = 0L

        fun start() {
            t0 = now()
            step(0)
        }

        /** The dream stopped: nothing more is shown and done is never called. */
        fun cancel() {
            cancelled = true
        }

        private fun step(i: Int) {
            if (cancelled) return
            val f = frames[i]
            show(f)
            if (f == Frame.COVER) return done(now() - t0)
            afterDrawn { delay(hold) { step(i + 1) } }
        }
    }
}
