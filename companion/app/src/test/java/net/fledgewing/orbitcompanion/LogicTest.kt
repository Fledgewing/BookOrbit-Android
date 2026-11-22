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

class VersionTest {
    private fun v(s: String) = Version.parse(s)!!

    @Test
    fun parsesTagsAndRejectsJunk() {
        assertEquals(Version(0, 1, 0), Version.parse("v0.1.0"))
        assertEquals(Version(1, 2, 3, "rc.1"), Version.parse("1.2.3-rc.1"))
        assertEquals(Version(1, 2, 3), Version.parse("v1.2.3+build.7"))
        assertNull(Version.parse("1.2"))
        assertNull(Version.parse("latest"))
        assertNull(Version.parse(""))
        assertNull(Version.parse(null))
    }

    @Test
    fun ordersNumericallyNotAsText() {
        assertTrue(v("0.10.0") > v("0.9.9"))
        assertTrue(v("1.0.0") > v("0.99.99"))
        assertTrue(v("0.1.1") > v("0.1.0"))
        assertEquals(0, v("v0.1.0").compareTo(v("0.1.0")))
    }

    @Test
    fun preReleasesSortBeforeTheRelease() {
        assertTrue(v("0.2.0-rc.1") < v("0.2.0"))
        assertTrue(v("0.2.0-rc.1") > v("0.1.9"))
        assertTrue(v("0.2.0-rc.2") > v("0.2.0-rc.1"))
        assertTrue(v("0.2.0-rc.10") > v("0.2.0-rc.9"))
        assertTrue(v("0.2.0-beta") < v("0.2.0-rc"))
        assertTrue(v("0.2.0-rc") < v("0.2.0-rc.1"))
        assertTrue(v("0.0.0-dev") < v("0.1.0"))
    }

    @Test
    fun versionCodeIsMonotonic() {
        assertEquals(100, v("0.1.0").code)
        assertEquals(10203, v("1.2.3").code)
        assertTrue(v("0.1.1").code > v("0.1.0").code)
        assertTrue(v("1.0.0").code > v("0.99.99").code)
    }
}

class UpdatePolicyTest {
    private fun r(tag: String, pre: Boolean = false, draft: Boolean = false) = ReleaseInfo(tag, pre, draft, emptyMap())

    @Test
    fun picksNewestStableUnlessPreReleasesWanted() {
        val list = listOf(r("v0.3.0-rc.1", pre = true), r("v0.2.0"), r("v0.4.0", draft = true), r("v0.1.0"), r("nightly"))
        assertEquals("v0.2.0", UpdatePolicy.pick(list, includePre = false)?.tag)
        assertEquals("v0.3.0-rc.1", UpdatePolicy.pick(list, includePre = true)?.tag)
        assertNull(UpdatePolicy.pick(listOf(r("v1.0.0-rc.1", pre = true)), includePre = false))
    }

    @Test
    fun onlyStrictlyNewerUpdates() {
        assertTrue(UpdatePolicy.isNewer(Version.parse("0.1.1"), Version.parse("0.1.0")))
        assertFalse(UpdatePolicy.isNewer(Version.parse("0.1.0"), Version.parse("0.1.0")))
        assertFalse(UpdatePolicy.isNewer(Version.parse("0.0.9"), Version.parse("0.1.0")))
        assertFalse(UpdatePolicy.isNewer(null, Version.parse("0.1.0")))
        assertTrue(UpdatePolicy.isNewer(Version.parse("0.1.0"), null))
    }

    @Test
    fun checksAtMostDaily() {
        val day = UpdatePolicy.INTERVAL_MS
        assertTrue(UpdatePolicy.due(0, 1_000))
        assertFalse(UpdatePolicy.due(1_000, 1_000 + day - 1))
        assertTrue(UpdatePolicy.due(1_000, 1_000 + day))
        assertTrue(UpdatePolicy.due(5_000, 1_000)) // clock went backwards
    }

    @Test
    fun apkNameFollowsTheReleaseAsset() {
        assertEquals("orbit-companion-0.1.0.apk", UpdatePolicy.apkName(Version.parse("v0.1.0")!!))
    }
}

class ChecksumsTest {
    private val a = "a".repeat(64)
    private val b = "0123456789ABCDEF".repeat(4)

    @Test
    fun parsesSha256sumOutput() {
        val sums = Checksums.parse("$a  orbit-companion-0.1.0.apk\n$b *2-orbit-android.lua\r\n")
        assertEquals(a, sums["orbit-companion-0.1.0.apk"])
        assertEquals(b.lowercase(), sums["2-orbit-android.lua"])
    }

    @Test
    fun skipsBadLines() {
        val sums = Checksums.parse("# comment\n\nabc  short.apk\n${a}x  long.apk\n$a  ok.apk\n")
        assertEquals(1, sums.size)
        assertEquals(a, sums["ok.apk"])
    }
}

class AppStatesTest {
    @Test
    fun frozenIsNotMissing() {
        assertEquals(AppState.MISSING, AppStates.of(false, 0, false, false))
        assertEquals(AppState.OK, AppStates.of(true, 0, true, false))
        assertEquals(AppState.OK, AppStates.of(true, 1, true, false))
        // A vendor launcher's app freeze: enabled=2 (COMPONENT_ENABLED_STATE_DISABLED).
        assertEquals(AppState.FROZEN, AppStates.of(true, 2, false, false))
        assertEquals(AppState.FROZEN, AppStates.of(true, 3, false, false))
        assertEquals(AppState.FROZEN, AppStates.of(true, 4, true, false))
        assertEquals(AppState.FROZEN, AppStates.of(true, 0, true, true))
    }
}

class WifiOwnershipTest {
    @Test
    fun ourRecentRequestIsOursOtherwiseTheUsers() {
        assertEquals(WifiOwner.AUTO, WifiOwnership.onEnabled(10_000, 5_000, WifiOwner.AUTO))
        assertEquals(WifiOwner.MANUAL, WifiOwnership.onEnabled(10_000, 5_000, WifiOwner.MANUAL))
        // Quick settings, long after any request of ours: the user's.
        assertEquals(WifiOwner.MANUAL, WifiOwnership.onEnabled(100_000, 5_000, WifiOwner.AUTO))
        assertEquals(WifiOwner.MANUAL, WifiOwnership.onEnabled(10_000, 0, WifiOwner.AUTO))
    }

    @Test
    fun automaticOffNeverTurnsOffTheUsersWifi() {
        assertFalse(WifiOwnership.allowOff(auto = true, owner = WifiOwner.MANUAL))
        assertTrue(WifiOwnership.allowOff(auto = true, owner = WifiOwner.AUTO))
        assertTrue(WifiOwnership.allowOff(auto = true, owner = WifiOwner.NONE))
        assertTrue(WifiOwnership.allowOff(auto = false, owner = WifiOwner.MANUAL)) // KOReader's own toggle
    }

    @Test
    fun sleepSyncRestoresOffWhenWifiWasOff() {
        val a = WifiPolicy.afterSleepSync(WifiAfterSleep.KEEP_ON, "sleep", screenOn = false, nowWallMs = 0, restoreOff = true)
        assertEquals(SleepWifiAction.OffNow, a)
        val b = WifiPolicy.afterSleepSync(WifiAfterSleep.KEEP_ON, "sync_and_sleep", screenOn = true, nowWallMs = 0, restoreOff = true)
        assertEquals(SleepWifiAction.OffAtNextScreenOff, b)
        assertEquals(SleepWifiAction.KeepOn, WifiPolicy.afterSleepSync(WifiAfterSleep.KEEP_ON, "sleep", false, 0))
    }
}

class SharedSettingsTest {
    @Test
    fun defaultsAndParsing() {
        assertEquals(WifiMode.JIT, WifiMode.fromKey(null))
        assertEquals(WifiMode.OFF_READING, WifiMode.fromKey("off_reading"))
        assertEquals(HomeButton.SMART, HomeButton.fromKey("bogus"))
        assertTrue(SharedSettings.validIdle(5))
        assertFalse(SharedSettings.validIdle(3))
    }
}

class HomeCommandsTest {
    @Test
    fun commandFollowsTheSetting() {
        assertEquals("home_smart", HomeCommands.forPress(HomeButton.SMART))
        assertEquals("home", HomeCommands.forPress(HomeButton.BOOKORBIT))
        assertEquals("home_smart", HomeCommands.forUncovered(HomeButton.SMART))
        assertNull(HomeCommands.forUncovered(HomeButton.BOOKORBIT))
    }

    @Test
    fun fromOtherAppOnlyWhenKnown() {
        assertEquals("other_app", HomeCommands.from(companionPageInFront = true, uncovered = false))
        assertEquals("other_app", HomeCommands.from(companionPageInFront = false, uncovered = true))
        assertNull(HomeCommands.from(companionPageInFront = false, uncovered = false))
    }
}

class WifiTestPlanTest {
    @Test
    fun leavesWifiAsFound() {
        assertEquals(listOf(WifiTestPlan.Step.OFF, WifiTestPlan.Step.ON), WifiTestPlan.steps(wasOn = true))
        assertEquals(listOf(WifiTestPlan.Step.ON, WifiTestPlan.Step.OFF), WifiTestPlan.steps(wasOn = false))
    }
}

class VendorProfilesTest {
    private val none: (String) -> Boolean = { false }

    @Test
    fun byManufacturerOrBrand() {
        assertEquals("haoqing", VendorProfiles.pick("Haoqing", "Meebook", none).id)
        assertEquals("onyx", VendorProfiles.pick("ONYX", "Onyx", none).id)
        assertEquals("generic", VendorProfiles.pick("Google", "google", none).id)
        assertEquals("generic", VendorProfiles.pick(null, null, none).id)
    }

    @Test
    fun byLauncherPackageWhenTheBuildSaysNothing() {
        assertEquals("haoqing", VendorProfiles.pick("alps", "alps") { it == "com.haoqing.app.hqreader" }.id)
    }

    @Test
    fun genericHasNoVendorHomeOrHint() {
        assertNull(VendorProfiles.GENERIC.home)
        assertNull(VendorProfiles.GENERIC.launcherPkg)
        assertFalse(VendorProfiles.ONYX.verified)
    }

    @Test
    fun disabledMessageNamesTheDisablerOrStaysNeutral() {
        assertEquals(
            "KOReader is disabled by Meebook Launcher: re-enable it in Meebook Launcher › Freeze management.",
            AppStates.disabledMessage("KOReader", "Meebook Launcher", "Freeze management"),
        )
        assertEquals(
            "KOReader is disabled by the system: re-enable it in Settings › Apps.",
            AppStates.disabledMessage("KOReader", null, null),
        )
        assertEquals("Disabled by the system", AppStates.disabledShort(null))
    }
}

class NetErrorsTest {
    @Test
    fun lockdownSetting() {
        assertEquals(true, NetErrors.lockdown("1"))
        assertEquals(false, NetErrors.lockdown("0"))
        assertNull(NetErrors.lockdown(null))
        assertNull(NetErrors.lockdown("x"))
    }

    @Test
    fun permissionDeniedMeansBlocked() {
        val e = java.net.SocketException("socket failed: EACCES (Permission denied)")
        assertEquals("permission", NetErrors.kindOf(e))
        assertEquals(NetErrors.BLOCKED, NetErrors.message("permission", true, true, true, ""))
        assertEquals("permission", NetErrors.kindOf(java.io.IOException("wrap", java.net.SocketException("connect failed: EPERM"))))
    }

    @Test
    fun connectFailureWithWifiAndVpnUpMeansBlocked() {
        assertEquals("connect", NetErrors.kindOf(java.net.UnknownHostException("api.github.com")))
        assertEquals(NetErrors.BLOCKED, NetErrors.message("connect", true, true, vpnUp = true, detail = ""))
        assertEquals("no internet: GitHub can't be reached", NetErrors.message("connect", true, true, vpnUp = false, detail = ""))
        assertEquals("no internet: Wi-Fi is off", NetErrors.message("connect", false, false, vpnUp = true, detail = ""))
    }
}

class PatchFileTest {
    @Test
    fun readsPatchVersion() {
        assertEquals("0.2.2", PatchFile.version("-- x\nlocal PATCH_VERSION = \"0.2.2\"\nlocal y = 1\n"))
        assertNull(PatchFile.version("-- nothing here"))
        assertNull(PatchFile.version(null))
    }

    @Test
    fun installWhenMissingOrOlder() {
        assertTrue(PatchFile.needsInstall(null, "0.2.2"))
        assertTrue(PatchFile.needsInstall("0.2.0", "0.2.2"))
        assertTrue(PatchFile.needsInstall("0.0.0-dev", "0.2.2"))
        assertFalse(PatchFile.needsInstall("0.2.2", "0.2.2"))
        assertFalse(PatchFile.needsInstall("0.3.0", "0.2.2"))
    }
}
