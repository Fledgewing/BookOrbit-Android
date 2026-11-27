// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import android.app.Application
import android.content.Intent
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[34])
class AddonFallbackTest {
    private val app get() = RuntimeEnvironment.getApplication()
    @Before fun prepare() {
        SettingsStore.useSchema(SettingsSchema.parse(File("../../../shared/settings/schema.json").readText()))
        Prefs(app).mode=OrbitMode.ADDON
    }
    @Test fun declinedInstallPermissionUsesManualPathOnlyInAddonAndKeepsSignerWarning() {
        for (state in KoreaderRelease.State.values()) {
            assertEquals(state!=KoreaderRelease.State.OTHER_SIGNER,KoreaderRelease.manualInstall(true,false,state))
            assertFalse(KoreaderRelease.manualInstall(false,false,state))
            assertFalse(KoreaderRelease.manualInstall(true,true,state))
        }
    }
    @Test fun downloadFallbackHonorsChannelVersionAndHttpsAndNeverCreatesInstallSession() {
        val p=Prefs(app)
        p.updateDownloadVersion="99.0.0-preview.1"
        p.updateDownloadUrl="https://example.test/update.apk"
        p.updateChannel=UpdateChannel.STABLE
        assertNull(Updater.readyToDownload(app))
        p.updateChannel=UpdateChannel.PREVIEW
        assertEquals(Intent.ACTION_VIEW,Updater.readyToDownload(app)?.second?.action)
        assertTrue(Updater.readySummary(app)!!.contains("99.0.0-preview.1"))
        assertNull(Updater.pendingSession())
        p.updateWithdrawn=setOf("99.0.0-preview.1")
        assertNull("persisted signed withdrawals survive process restart",Updater.readyToDownload(app))
        p.updateWithdrawn=emptySet()
        p.updateDownloadUrl="file:///untrusted.apk"
        assertNull(Updater.readyToDownload(app))
        p.updateDownloadUrl="https://example.test/update.apk"
        p.updateDownloadVersion="0.1.0"
        assertNull(Updater.readyToDownload(app))
        p.updateDownloadVersion="99.0.0"
        p.mode=OrbitMode.FULL
        assertNull(Updater.readyToDownload(app))
    }
    @Test fun helperLinkOpensExistingSyncSettingsRatherThanSetup() {
        val intent=Intent(app,StatusActivity::class.java).putExtra("booksync_page","helpers")
        val controller=Robolectric.buildActivity(StatusActivity::class.java,intent).setup()
        val next=shadowOf(controller.get()).nextStartedActivity
        assertEquals(SettingsSectionActivity::class.java.name,next.component?.className)
        assertEquals("sync",next.getStringExtra(SettingsPage.EXTRA_SECTION))
        assertEquals("helper_wifi",next.getStringExtra(SettingsPage.EXTRA_FOCUS))
        controller.pause().stop().destroy()
    }
    @Test fun helperLinkAlsoWorksWhenAndroidReusesTheVisibleStatusActivity() {
        val controller=Robolectric.buildActivity(StatusActivity::class.java).setup()
        val shadow=shadowOf(controller.get())
        while (shadow.nextStartedActivity!=null) { }
        controller.newIntent(Intent(app,StatusActivity::class.java).putExtra("booksync_page","helpers"))
        val next=shadow.nextStartedActivity
        assertEquals(SettingsSectionActivity::class.java.name,next.component?.className)
        assertEquals("helper_wifi",next.getStringExtra(SettingsPage.EXTRA_FOCUS))
        assertTrue(controller.get().isFinishing)
        controller.pause().stop().destroy()
    }
    @Test fun modeSwitchOffersScreenOffSeparatelyFromSleepSync() {
        Prefs(app).mode=OrbitMode.FULL
        val controller=Robolectric.buildActivity(ModeActivity::class.java).setup()
        fun all(v:View):List<View> = listOf(v)+if(v is ViewGroup) (0 until v.childCount).flatMap { all(v.getChildAt(it)) } else emptyList()
        val labels=all(controller.get().window.decorView).filterIsInstance<TextView>().map { it.text.toString() }
        assertTrue(labels.contains("Sleep sync"))
        assertTrue(labels.contains("Screen off after Sync and sleep"))
        assertFalse(labels.contains("Sleep sync (and screen off after it)"))
        controller.pause().stop().destroy()
    }
}
