package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InstallLogicTest {
    /** koreader/koreader v2026.07.1's assets. */
    private val koAssets = listOf(
        "koreader-android-arm-v2026.07.1.apk", "koreader-android-arm64-v2026.07.1.apk",
        "koreader-android-x86-v2026.07.1.apk", "koreader-appimage-x86_64-v2026.07.1.AppImage",
    )

    @Test
    fun koreaderApkForTheDeviceAbi() {
        assertEquals("koreader-android-arm64-v2026.07.1.apk", KoreaderRelease.assetFor(listOf("arm64-v8a", "armeabi-v7a", "armeabi"), koAssets))
        assertEquals("koreader-android-arm-v2026.07.1.apk", KoreaderRelease.assetFor(listOf("armeabi-v7a", "armeabi"), koAssets))
        assertEquals("koreader-android-x86-v2026.07.1.apk", KoreaderRelease.assetFor(listOf("x86_64", "x86"), koAssets))
        assertEquals("falls back to the next ABI", "koreader-android-arm-v2026.07.1.apk",
            KoreaderRelease.assetFor(listOf("arm64-v8a", "armeabi-v7a"), koAssets - "koreader-android-arm64-v2026.07.1.apk"))
        assertNull(KoreaderRelease.assetFor(listOf("mips"), koAssets))
    }

    @Test
    fun koreaderDigestAndVersions() {
        val hex = "89cecbe06eacd2ff7d91e37152d6beeb52809f2ca38060b6515ed8b00d152412"
        assertEquals(hex, KoreaderRelease.digest("sha256:$hex"))
        assertNull("not published", KoreaderRelease.digest(""))
        assertNull(KoreaderRelease.digest("sha1:abc"))
        assertTrue(KoreaderRelease.newer("v2026.07.1", "v2026.07"))
        assertTrue(KoreaderRelease.newer("v2026.08", "v2026.07.1"))
        assertFalse(KoreaderRelease.newer("v2026.07.1", "v2026.07.1"))
        assertFalse(KoreaderRelease.newer("v2026.07", "v2026.07.1"))
        assertFalse("unknown installed version", KoreaderRelease.newer("v2026.07.1", null))
    }

    @Test
    fun koreaderBuildDetection() {
        assertEquals(KoreaderRelease.State.MISSING, KoreaderRelease.state(null, fdroidInstalled = false))
        assertEquals(KoreaderRelease.State.FDROID_ONLY, KoreaderRelease.state(null, fdroidInstalled = true))
        assertEquals(KoreaderRelease.State.OFFICIAL, KoreaderRelease.state(setOf(KoreaderRelease.OFFICIAL_CERT), fdroidInstalled = true))
        assertEquals(KoreaderRelease.State.OTHER_SIGNER, KoreaderRelease.state(setOf("AA:BB"), fdroidInstalled = false))
        assertTrue(KoreaderRelease.explain(KoreaderRelease.State.FDROID_ONLY).contains("skips user patches"))
    }

    @Test
    fun pluginInstallsOnlyWhenMissingOrTooOld() {
        assertEquals("2.3.0", PluginRelease.version("local x = 1\nlocal PLUGIN_VERSION = \"2.3.0\"\n"))
        assertNull(PluginRelease.version("return {}"))
        assertTrue(PluginRelease.needsInstall(null))
        assertTrue(PluginRelease.needsInstall("2.2.9"))
        assertFalse(PluginRelease.needsInstall("2.3.0"))
        assertFalse("newer: its own updater's business", PluginRelease.needsInstall("2.4.0"))
    }

    @Test
    fun pluginFilesAreCheckedAndStayInsideTheFolder() {
        // git hash-object of "hello\n"
        assertEquals("ce013625030ba8dba906f756967f9e9ca394464a", PluginRelease.gitBlobSha1("hello\n".toByteArray()))
        assertTrue(PluginRelease.safePath("main.lua"))
        assertTrue(PluginRelease.safePath("assets/icons/a.svg"))
        assertFalse(PluginRelease.safePath("../main.lua"))
        assertFalse(PluginRelease.safePath("/etc/x"))
        assertFalse(PluginRelease.safePath("a//b"))
        assertFalse(PluginRelease.safePath("a/./b"))
    }

    @Test
    fun managedDevicesAreExplainedInPlainWords() {
        assertNull(DeviceChecks.managed(false, setOf("no_sms"), emptyList()))
        val fl = DeviceChecks.managed(true, setOf("no_install_unknown_sources"), emptyList())!!
        assertTrue(fl, fl.contains("approve it in the parent's Family Link app"))
        assertTrue(fl, fl.contains("installing apps from outside the Play Store"))
        val work = DeviceChecks.managed(false, emptySet(), listOf("com.example.mdm"))!!
        assertTrue(work, work.contains("managed (com.example.mdm)"))
        assertTrue(DeviceChecks.playProtect().contains("Install anyway"))
    }

    @Test
    fun fixNextWalksPendingRowsInOrderOnce() {
        val rows = listOf("play_protect" to true, "managed" to false, "koreader" to false, "plugin" to true, "patch" to false, "home" to false)
        assertEquals("koreader", SetupWalk.next(rows, emptySet()))
        assertEquals("patch", SetupWalk.next(rows, setOf("koreader")))
        assertEquals("home", SetupWalk.next(rows, setOf("koreader", "patch")))
        assertNull(SetupWalk.next(rows, setOf("koreader", "patch", "home")))
    }

    @Test
    fun newSetupRowsHaveStableIds() {
        assertEquals("koreader", SetupAttention.idOf("KOReader app installed (v2026.07.1)"))
        assertEquals("plugin", SetupAttention.idOf("BookOrbit plugin installed (v2.3.0)"))
        assertEquals("patch", SetupAttention.idOf("KOReader patch installed (v0.5.1)"))
        assertEquals("managed", SetupAttention.idOf("Family Link supervision"))
        assertEquals("play_protect", SetupAttention.idOf("Play Protect scans installs"))
    }

    @Test
    fun anAdvisoryAloneMeansSetupIsComplete() {
        val rows = listOf("managed" to false, "play_protect" to true, "freeze_tip" to true, "home" to true, "patch" to true)
        assertTrue(SetupTips.complete(rows))
        assertEquals(listOf("home" to true, "patch" to true), SetupTips.steps(rows))
        assertFalse(SetupTips.complete(rows + ("notifications" to false)))
        // Never a "Fix next" stop, a prompt or setup_needed.
        assertNull(SetupWalk.next(rows, emptySet()))
        val st = SetupAttention.evaluate(rows, SetupAttention.State(), 50200, emptySet())
        assertTrue(st.needed.isEmpty())
    }

    @Test
    fun gotItHidesATipUntilShownAgain() {
        val hidden = SetupTips.hide(emptySet(), "managed")
        assertEquals(setOf("managed"), hidden)
        assertEquals("only tips can be hidden", hidden, SetupTips.hide(hidden, "home"))
        assertEquals(listOf("play_protect", "home"), SetupTips.visible(listOf("managed", "play_protect", "home"), hidden))
        assertEquals("Show hidden tips", listOf("managed", "home"), SetupTips.visible(listOf("managed", "home"), emptySet()))
        assertEquals("freeze_tip", SetupAttention.idOf("Launcher can freeze apps"))
    }
}
