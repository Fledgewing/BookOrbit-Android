package net.fledgewing.orbitcompanion

import net.fledgewing.orbitcompanion.SleepFlash.Frame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The clearing flash (lock-screen.md L10): order and timing on a fake clock and frame queue. */
class SleepFlashTest {
    private class Fake {
        var t = 1_000L
        val log = mutableListOf<String>()
        private val drawn = ArrayDeque<() -> Unit>()
        private val timers = mutableListOf<Pair<Long, () -> Unit>>()
        var doneMs: Long? = null

        fun runner(flash: Boolean) = SleepFlash.Runner(
            SleepFlash.frames(flash),
            show = { log += "${it.name}@${t - 1_000}" },
            afterDrawn = { drawn.addLast(it) },
            delay = { ms, next -> timers += (t + ms) to next },
            now = { t },
            done = { doneMs = it },
        )

        /** One panel frame of 16 ms, then any timers that are due. */
        fun pump(until: Long) {
            while (t - 1_000 < until) {
                t += 16
                repeat(drawn.size) { drawn.removeFirst()() }
                timers.filter { it.first <= t }.also { timers.removeAll(it) }.forEach { it.second() }
            }
        }
    }

    @Test
    fun offDrawsTheCoverOnly() {
        val f = Fake()
        f.runner(flash = false).start()
        f.pump(2_000)
        assertEquals(listOf("COVER@0"), f.log)
        assertEquals(0L, f.doneMs)
    }

    @Test
    fun onRunsBlackWhiteThenCoverEachHeldAfterItsFrame() {
        val f = Fake()
        f.runner(flash = true).start()
        f.pump(2_000)
        assertEquals(listOf("BLACK", "WHITE", "COVER"), f.log.map { it.substringBefore('@') })
        val at = f.log.map { it.substringAfter('@').toLong() }
        assertEquals(0L, at[0])
        // Each step waits for its frame to be drawn, then holds HOLD_MS.
        val step = at[1] - at[0]
        assertEquals(true, step >= SleepFlash.HOLD_MS && step < SleepFlash.HOLD_MS + 50)
        assertEquals(step, at[2] - at[1])
        assertEquals(at[2], f.doneMs)
        assertEquals("sleep screen: flash sequence done in ${f.doneMs} ms", SleepFlash.line(f.doneMs!!))
    }

    @Test
    fun cancelledStopsTheSequenceAndNeverReportsDone() {
        val f = Fake()
        val r = f.runner(flash = true)
        r.start()
        f.pump(100)
        r.cancel()
        f.pump(2_000)
        assertEquals(listOf("BLACK"), f.log.map { it.substringBefore('@') })
        assertNull(f.doneMs)
    }

    @Test
    fun theSettingIsOffByDefaultAndRoundTrips() {
        assertEquals(false, SleepSettings.DEFAULT.flash)
        assertEquals("0", SleepSettings.DEFAULT.toMap()["sleep_flash"])
        val on = SleepSettings.DEFAULT.copy(flash = true)
        assertEquals(on, SleepSettings.merge(SleepSettings.DEFAULT) { on.toMap()[it] })
        // An older plugin sends no sleep_flash: ours is kept.
        assertEquals(true, SleepSettings.merge(on) { if (it == "sleep_mode") "current" else null }.flash)
        assertEquals(listOf(Frame.COVER), SleepFlash.frames(false))
    }
}
