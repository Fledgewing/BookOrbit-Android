package net.fledgewing.orbitcompanion

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeDeciderTest {
    private val start = HomeAction.START_KOREADER
    private val launcher = HomeAction.SHOW_LAUNCHER

    @Test
    fun singlePressesStartKoreader() {
        val d = HomeDecider()
        assertEquals(start, d.onHomePress(10_000, true, true))
        assertEquals(start, d.onHomePress(12_001, true, true))
        assertEquals(start, d.onHomePress(60_000, true, true))
    }

    @Test
    fun secondPressWithinTwoSecondsShowsLauncher() {
        val d = HomeDecider()
        assertEquals(start, d.onHomePress(10_000, true, true))
        assertEquals(launcher, d.onHomePress(12_000, true, true))
    }

    @Test
    fun thirdQuickPressStartsANewPair() {
        val d = HomeDecider()
        d.onHomePress(10_000, true, true)
        assertEquals(launcher, d.onHomePress(10_500, true, true))
        assertEquals(start, d.onHomePress(11_000, true, true))
        assertEquals(launcher, d.onHomePress(11_500, true, true))
    }

    @Test
    fun missingKoreaderOrSettingOffShowsLauncher() {
        assertEquals(launcher, HomeDecider().onHomePress(10_000, false, true))
        assertEquals(launcher, HomeDecider().onHomePress(10_000, true, false))
        assertEquals(launcher, HomeDecider().onUncovered(10_000, false, true))
    }

    @Test
    fun uncoveredRestartsKoreaderUnlessItJustStarted() {
        val d = HomeDecider()
        assertEquals(start, d.onHomePress(10_000, true, true))
        // KOReader died 2 s after starting: it isn't staying up.
        assertEquals(launcher, d.onUncovered(12_000, true, true))
        // Killed long after a start (firmware, after sleep): start it again.
        val e = HomeDecider()
        e.onHomePress(10_000, true, true)
        assertEquals(start, e.onUncovered(200_000, true, true))
        // ...and if that start dies at once, the launcher shows.
        assertEquals(launcher, e.onUncovered(201_000, true, true))
    }

    @Test
    fun failedStartIsForgotten() {
        val d = HomeDecider()
        d.onHomePress(10_000, true, true)
        d.startFailed()
        assertEquals(start, d.onUncovered(11_000, true, true))
    }

    @Test
    fun clockGoingBackwardsIsNotADoublePress() {
        val d = HomeDecider()
        d.onHomePress(10_000, true, true)
        assertEquals(start, d.onHomePress(9_000, true, true))
    }
}

class WifiPolicyTest {
    private val now = 1_000_000_000L

    @Test
    fun onlySleepReasonsTouchWifi() {
        for (r in listOf("start", "wake", "retry", "reading", "test", "koreader_wifi_on", "", null, "something_new")) {
            assertNull(r, WifiPolicy.afterSleepSync(WifiAfterSleep.OFF_NOW, r, false, now))
        }
    }

    @Test
    fun defaultIsOffAfterThirtyMinutes() {
        assertEquals(WifiAfterSleep.OFF_AFTER_30, WifiAfterSleep.fromKey(null))
        assertEquals(WifiAfterSleep.OFF_AFTER_30, WifiAfterSleep.fromKey("bogus"))
        assertEquals(
            SleepWifiAction.OffAt(now + 30 * 60_000L),
            WifiPolicy.afterSleepSync(WifiAfterSleep.OFF_AFTER_30, "sleep", false, now),
        )
        // Scheduled with the screen on too: the screen is checked when the timer fires.
        assertEquals(
            SleepWifiAction.OffAt(now + 30 * 60_000L),
            WifiPolicy.afterSleepSync(WifiAfterSleep.OFF_AFTER_30, "sync_and_sleep", true, now),
        )
    }

    @Test
    fun keepOn() {
        assertEquals(SleepWifiAction.KeepOn, WifiPolicy.afterSleepSync(WifiAfterSleep.KEEP_ON, "sleep", false, now))
    }

    @Test
    fun offNowOnlyWithTheScreenOff() {
        assertEquals(SleepWifiAction.OffNow, WifiPolicy.afterSleepSync(WifiAfterSleep.OFF_NOW, "sleep", false, now))
        assertEquals(SleepWifiAction.KeepOn, WifiPolicy.afterSleepSync(WifiAfterSleep.OFF_NOW, "sleep", true, now))
        // Sync and sleep: NET_DONE comes before SLEEP_NOW, so wait for the screen to go off.
        assertEquals(
            SleepWifiAction.OffAtNextScreenOff,
            WifiPolicy.afterSleepSync(WifiAfterSleep.OFF_NOW, "sync_and_sleep", true, now),
        )
    }

    @Test
    fun timerTurnsWifiOffOnlyWithTheScreenStillOff() {
        val deadline = now
        assertEquals(TimerVerdict.TURN_OFF, WifiPolicy.onTimer(now, deadline, screenOn = false, wifiOn = true))
        assertEquals(TimerVerdict.SCREEN_ON, WifiPolicy.onTimer(now, deadline, screenOn = true, wifiOn = true))
        assertEquals(TimerVerdict.ALREADY_OFF, WifiPolicy.onTimer(now, deadline, screenOn = false, wifiOn = false))
        assertEquals(TimerVerdict.NO_TIMER, WifiPolicy.onTimer(now, 0, screenOn = false, wifiOn = true))
        assertEquals(TimerVerdict.NOT_DUE, WifiPolicy.onTimer(now - 60_000, deadline, screenOn = false, wifiOn = true))
        assertEquals(TimerVerdict.TURN_OFF, WifiPolicy.onTimer(now - 2_000, deadline, screenOn = false, wifiOn = true))
    }

    @Test
    fun wakeLockIsCappedAtTwentyFiveSeconds() {
        assertEquals(25_000L, WifiPolicy.wakeLockMs("25", true))
        assertEquals(25_000L, WifiPolicy.wakeLockMs("120", true))
        assertEquals(20_500L, WifiPolicy.wakeLockMs("20.5", true))
        assertEquals(0L, WifiPolicy.wakeLockMs("0", true))
        assertEquals(0L, WifiPolicy.wakeLockMs(null, true))
        assertEquals(0L, WifiPolicy.wakeLockMs("x", true))
        assertEquals(0L, WifiPolicy.wakeLockMs("-3", true))
        assertEquals(0L, WifiPolicy.wakeLockMs("20", false))
    }

    @Test
    fun minutesLeftRoundsUp() {
        assertEquals(30L, WifiPolicy.minutesLeft(now, now + 30 * 60_000L))
        assertEquals(28L, WifiPolicy.minutesLeft(now, now + 27 * 60_000L + 1))
        assertEquals(0L, WifiPolicy.minutesLeft(now, now - 1))
    }

    @Test
    fun sleepNowRateLimit() {
        val r = RateLimiter(5_000)
        assertTrue(r.tryAcquire(10_000))
        assertFalse(r.tryAcquire(12_000))
        assertTrue(r.tryAcquire(15_000))
    }
}
