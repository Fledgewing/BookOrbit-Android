package net.fledgewing.orbitcompanion

import android.app.ActivityManager
import android.app.AppOpsManager
import android.app.Application
import android.app.admin.DevicePolicyManager
import android.app.usage.UsageStatsManager
import android.content.ComponentName
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.os.PowerManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** The "Battery: Unrestricted" row's decision alone. */
class BatteryRowLogicTest {
    private fun row(
        own: Boolean = true,
        restricted: Boolean? = false,
        allowlisted: Boolean = true,
        bucket: Int? = 5,
        locked: Boolean = false,
        installed: Boolean = true,
    ) = BatteryRow.of(installed, own, restricted, allowlisted, bucket, locked)

    @Test
    fun allSettingsGoodIsDone() {
        assertEquals(BatteryRow.Row(true, "done"), row())
        assertEquals("unknown background state doesn't block", BatteryRow.Row(true, "done"), row(restricted = null, bucket = null))
        listOf(5, 10, 20, 30).forEach { assertTrue("bucket $it", row(bucket = it).done) }
    }

    @Test
    fun deviceAdminAloneIsNotDone() {
        // Boox Page, v0.11.2: Orbit is device admin, Settings says "not available", but Doze applies.
        val r = row(allowlisted = false, locked = true)
        assertFalse(r.done)
        assertEquals(BatteryRow.LOCKED, r.detail)
        assertEquals(BatteryRow.Open.PROMPT, r.open)
        val other = row(own = false, allowlisted = false, locked = true, bucket = null)
        assertFalse(other.done)
        assertEquals(BatteryRow.LOCKED_OTHER, other.detail)
        assertEquals(BatteryRow.Open.BATTERY_PAGE, other.open)
    }

    @Test
    fun deviceAdminOnTheAllowlistIsDone() {
        assertTrue(row(locked = true).done)
    }

    @Test
    fun notAllowlistedIsNotDone() {
        assertEquals(BatteryRow.Row(false, BatteryRow.FIX, BatteryRow.Open.PROMPT), row(allowlisted = false))
        assertEquals(BatteryRow.Row(false, BatteryRow.FIX, BatteryRow.Open.BATTERY_PAGE), row(own = false, allowlisted = false, bucket = null))
    }

    @Test
    fun backgroundRestrictedIsNotDoneEvenWhenAllowlisted() {
        val r = row(restricted = true)
        assertFalse(r.done)
        assertTrue(r.detail, r.detail.startsWith("background usage is restricted"))
    }

    @Test
    fun rareOrRestrictedBucketIsNotDone() {
        listOf(BatteryRow.BUCKET_RARE, BatteryRow.BUCKET_RESTRICTED).forEach {
            val r = row(bucket = it)
            assertFalse("bucket $it", r.done)
            assertTrue(r.detail, r.detail.startsWith("Android is holding BookSync back"))
        }
    }

    @Test
    fun missingIsNotDone() {
        assertEquals(BatteryRow.Row(false, "not installed"), row(installed = false))
    }
}

/** Net.batteryRow's wiring against Robolectric's PowerManager, ActivityManager, AppOps, DevicePolicyManager and UsageStatsManager. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class BatteryRowTest {
    private lateinit var app: Application
    private val other = "org.koreader.launcher"
    private val otherUid = 10_123

    @Before
    fun setUp() {
        app = RuntimeEnvironment.getApplication()
        shadowOf(app.packageManager).installPackage(
            PackageInfo().apply {
                packageName = other
                applicationInfo = ApplicationInfo().apply { packageName = other; uid = otherUid; enabled = true }
            },
        )
        power().setIgnoringBatteryOptimizations(app.packageName, true)
        power().setIgnoringBatteryOptimizations(other, true)
        usage().setCurrentAppStandbyBucket(UsageStatsManager.STANDBY_BUCKET_ACTIVE)
    }

    private fun power() = shadowOf(app.getSystemService(Context.POWER_SERVICE) as PowerManager)
    private fun dpm() = shadowOf(app.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager)
    private fun usage() = shadowOf(app.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager)
    private fun am() = shadowOf(app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager)
    private fun appOps() = shadowOf(app.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager)
    private fun makeAdmin() = dpm().setActiveAdmin(ComponentName(app.packageName, "net.fledgewing.orbitcompanion.AdminReceiver"))

    @Test
    fun ownAppAllowlistedIsDone() {
        assertEquals(BatteryRow.Row(true, "done"), Net.batteryRow(app, app.packageName))
    }

    @Test
    fun ownAppDeviceAdminNotAllowlistedNeedsYou() {
        power().setIgnoringBatteryOptimizations(app.packageName, false)
        makeAdmin()
        assertEquals(BatteryRow.Row(false, BatteryRow.LOCKED, BatteryRow.Open.PROMPT), Net.batteryRow(app, app.packageName))
    }

    @Test
    fun ownAppDeviceAdminAllowlistedIsDone() {
        makeAdmin()
        assertTrue(Net.batteryRow(app, app.packageName).done)
    }

    @Test
    fun ownAppBackgroundRestrictedIsNotDone() {
        am().setBackgroundRestricted(true)
        assertFalse(Net.batteryRow(app, app.packageName).done)
    }

    @Test
    fun ownAppRareBucketIsNotDone() {
        usage().setCurrentAppStandbyBucket(UsageStatsManager.STANDBY_BUCKET_RARE)
        assertFalse(Net.batteryRow(app, app.packageName).done)
    }

    @Test
    fun otherAppReadsRunAnyInBackground() {
        assertTrue(Net.batteryRow(app, other).done)
        appOps().setMode(Net.OP_RUN_ANY_IN_BACKGROUND, otherUid, other, AppOpsManager.MODE_IGNORED)
        val r = Net.batteryRow(app, other)
        assertFalse(r.done)
        assertTrue(r.detail, r.detail.startsWith("background usage is restricted"))
    }

    @Test
    fun otherAppNotAllowlistedIsNotDone() {
        power().setIgnoringBatteryOptimizations(other, false)
        assertEquals(BatteryRow.Row(false, BatteryRow.FIX, BatteryRow.Open.BATTERY_PAGE), Net.batteryRow(app, other))
    }

    @Test
    fun otherAppIgnoresOurBucket() {
        usage().setCurrentAppStandbyBucket(UsageStatsManager.STANDBY_BUCKET_RESTRICTED)
        assertTrue(Net.batteryRow(app, other).done)
    }

    @Test
    fun otherAppMissingIsNotInstalled() {
        assertEquals(BatteryRow.Row(false, "not installed"), Net.batteryRow(app, "com.tailscale.ipn"))
    }
}
