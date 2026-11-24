package net.fledgewing.orbitcompanion

import android.app.Application
import android.content.Intent
import android.content.pm.PackageInstaller
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File

/**
 * Every state of the app update's install session, through Updater's real code against
 * Robolectric's PackageInstaller (docs/design/emulated-release-tests.md, stage 2): Android's
 * results arrive as InstallReceiver would deliver them, and taps go through Updater.check.
 * UpdateSessionTest (LogicTest.kt) covers the decisions alone; this covers their wiring.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class UpdaterSessionTest {
    private lateinit var app: Application
    private val version = "99.0.0"

    @Before
    fun setUp() {
        app = RuntimeEnvironment.getApplication()
        Prefs(app).updateStatus = ""
    }

    @After
    fun tearDown() {
        // Updater is a process-wide object: end whatever session a test left.
        Updater.onSessionStatus(app, result(PackageInstaller.STATUS_SUCCESS))
        installer().allSessions.forEach { installer().abandonSession(it.sessionId) }
    }

    private fun installer(): PackageInstaller = app.packageManager.packageInstaller

    private fun commit(interactive: Boolean): Int {
        val apk = File(app.cacheDir, "update.apk").apply { writeBytes(ByteArray(64) { it.toByte() }) }
        Updater.installApk(app, apk, app.packageName, version, interactive, Updater.INSTALL_KEY)
        val pending = Updater.pendingSession()
        assertNotNull("a committed session is pending", pending)
        return pending!!.id
    }

    private fun prompt() = Intent("android.content.pm.action.CONFIRM_INSTALL").setPackage("com.android.packageinstaller")

    private fun result(status: Int, interactive: Boolean = false, message: String? = null, confirm: Intent? = null) =
        Intent(app, InstallReceiver::class.java)
            .putExtra(PackageInstaller.EXTRA_STATUS, status)
            .putExtra(Updater.EXTRA_VERSION, version)
            .putExtra(Updater.EXTRA_KEY, Updater.INSTALL_KEY)
            .putExtra(Updater.EXTRA_INTERACTIVE, interactive)
            .apply {
                if (message != null) putExtra(PackageInstaller.EXTRA_STATUS_MESSAGE, message)
                if (confirm != null) putExtra(Intent.EXTRA_INTENT, confirm)
            }

    private fun status() = Prefs(app).updateStatus

    private fun startedActivity(): Intent? = shadowOf(app).nextStartedActivity

    @Test
    fun committedSessionIsPendingAndOpen() {
        val id = commit(interactive = true)
        assertEquals(UpdateSession.Phase.COMMITTED, Updater.pendingSession()!!.phase)
        assertNotNull("Android holds the session", installer().getSessionInfo(id))
    }

    @Test
    fun pendingUserActionByHandOpensThePrompt() {
        commit(interactive = true)
        Updater.onSessionStatus(app, result(PackageInstaller.STATUS_PENDING_USER_ACTION, interactive = true, confirm = prompt()))
        assertEquals(UpdateSession.Phase.PROMPTED, Updater.pendingSession()!!.phase)
        assertEquals("com.android.packageinstaller", startedActivity()?.`package`)
        assertEquals("v$version ready: confirm the install", status())
    }

    @Test
    fun pendingUserActionInTheBackgroundWaitsForInstall() {
        commit(interactive = false)
        Updater.onSessionStatus(app, result(PackageInstaller.STATUS_PENDING_USER_ACTION, confirm = prompt()))
        assertNull("no activity starts from the background", startedActivity())
        assertEquals(version, Updater.readyToInstall()?.first)
        assertEquals("v$version ready: confirm the install", status())
    }

    @Test
    fun pendingUserActionWithoutAPromptSaysSo() {
        commit(interactive = true)
        Updater.onSessionStatus(app, result(PackageInstaller.STATUS_PENDING_USER_ACTION, interactive = true))
        assertEquals("v$version: Android wants a confirmation but sent no prompt", status())
    }

    @Test
    fun secondTapWhilePromptedOpensThePromptAgainWithoutANewSession() {
        val id = commit(interactive = true)
        Updater.onSessionStatus(app, result(PackageInstaller.STATUS_PENDING_USER_ACTION, interactive = true, confirm = prompt()))
        startedActivity()
        Updater.check(app, interactive = true, why = "second tap")
        assertEquals("the prompt again", "com.android.packageinstaller", startedActivity()?.`package`)
        assertEquals(id, Updater.pendingSession()!!.id)
        assertEquals(1, installer().allSessions.size)
        assertEquals(false, Updater.busy)
    }

    @Test
    fun backFromThePromptIsPendingVerification() {
        val id = commit(interactive = true)
        Updater.onSessionStatus(app, result(PackageInstaller.STATUS_PENDING_USER_ACTION, interactive = true, confirm = prompt()))
        Updater.onPageResumed(app)
        assertEquals(UpdateSession.Phase.CHECKING, Updater.pendingSession()!!.phase)
        assertEquals(UpdateSession.CHECKING, status())

        // A tap now: "Android is checking", never a second session.
        startedActivity()
        Updater.check(app, interactive = true, why = "tap while checking")
        assertNull(startedActivity())
        assertEquals(UpdateSession.CHECKING, status())
        assertEquals(id, Updater.pendingSession()!!.id)
        assertEquals(1, installer().allSessions.size)
        assertEquals(false, Updater.busy)
    }

    @Test
    fun abortedEndsTheSessionAndSaysTapToRetry() {
        commit(interactive = true)
        Updater.onSessionStatus(app, result(PackageInstaller.STATUS_PENDING_USER_ACTION, interactive = true, confirm = prompt()))
        Updater.onSessionStatus(app, result(UpdateSession.STATUS_ABORTED, message = "INSTALL_FAILED_ABORTED: User rejected"))
        assertNull(Updater.pendingSession())
        assertEquals(UpdateSession.CANCELLED, status())
    }

    @Test
    fun otherFailureEndsTheSessionWithItsReason() {
        commit(interactive = false)
        Updater.onSessionStatus(app, result(PackageInstaller.STATUS_FAILURE_CONFLICT, message = "INSTALL_FAILED_UPDATE_INCOMPATIBLE"))
        assertNull(Updater.pendingSession())
        assertEquals("v$version install failed (${PackageInstaller.STATUS_FAILURE_CONFLICT}: INSTALL_FAILED_UPDATE_INCOMPATIBLE)", status())
    }

    @Test
    fun successEndsTheSession() {
        commit(interactive = false)
        Updater.onSessionStatus(app, result(PackageInstaller.STATUS_PENDING_USER_ACTION, confirm = prompt()))
        Updater.onSessionStatus(app, result(PackageInstaller.STATUS_SUCCESS))
        assertNull(Updater.pendingSession())
        assertNull("nothing left to install", Updater.readyToInstall())
        assertEquals("updated to v$version", status())
    }

    @Test
    fun aSessionAndroidDroppedNoLongerHoldsThePrompt() {
        val id = commit(interactive = true)
        Updater.onSessionStatus(app, result(PackageInstaller.STATUS_PENDING_USER_ACTION, interactive = true, confirm = prompt()))
        installer().abandonSession(id)
        Updater.onPageResumed(app)
        assertEquals("not confirmed: the session is gone", UpdateSession.Phase.PROMPTED, Updater.pendingSession()!!.phase)
        assertEquals(true, UpdateSession.canCommit(Updater.pendingSession(), alive = false, nowMs = System.currentTimeMillis()))
    }

    @Test
    fun otherInstallsGoToInstallers() {
        Prefs(app).koreaderInstallStatus = ""
        Updater.onSessionStatus(app, result(PackageInstaller.STATUS_SUCCESS).putExtra(Updater.EXTRA_KEY, "koreader"))
        assertEquals("installed KOReader $version", Prefs(app).koreaderInstallStatus)
        assertEquals("the app update's status is untouched", "", status())
    }
}
