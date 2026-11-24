package net.fledgewing.orbitcompanion

import android.app.Application
import android.app.admin.DevicePolicyManager
import android.app.usage.UsageStatsManager
import android.content.ComponentName
import android.content.Context
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
    @Test
    fun allowlistedIsDone() {
        assertEquals(BatteryRow.Row(true, "done"), BatteryRow.of(true, ignoring = true, activeAdmin = false, standbyBucket = null))
    }

    @Test
    fun deviceAdminIsDoneWithWhy() {
        // Boox Page, v0.11.2: Orbit is Home and device admin; Settings says "not available".
        val r = BatteryRow.of(true, ignoring = false, activeAdmin = true, standbyBucket = 10)
        assertTrue(r.done)
        assertEquals("exempt (device admin): can't be restricted on this reader", r.detail)
    }

    @Test
    fun exemptBucketIsDoneWithWhy() {
        val r = BatteryRow.of(true, ignoring = false, activeAdmin = false, standbyBucket = BatteryRow.BUCKET_EXEMPTED)
        assertTrue(r.done)
        assertEquals("exempt (system): can't be restricted on this reader", r.detail)
    }

    @Test
    fun restrictedIsNotDone() {
        listOf(null, 10, 20, 30, 40, 45).forEach { bucket ->
            val r = BatteryRow.of(true, ignoring = false, activeAdmin = false, standbyBucket = bucket)
            assertFalse("bucket $bucket", r.done)
            assertEquals("set App battery usage › Unrestricted", r.detail)
        }
    }

    @Test
    fun missingIsNotDone() {
        assertEquals(BatteryRow.Row(false, "not installed"), BatteryRow.of(false, ignoring = true, activeAdmin = true, standbyBucket = 5))
    }
}

/** Net.batteryRow's wiring against Robolectric's PowerManager, DevicePolicyManager and UsageStatsManager. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class BatteryRowTest {
    private lateinit var app: Application
    private val other = "org.koreader.launcher"

    @Before
    fun setUp() {
        app = RuntimeEnvironment.getApplication()
        shadowOf(app.packageManager).installPackage(
            android.content.pm.PackageInfo().apply {
                packageName = other
                applicationInfo = android.content.pm.ApplicationInfo().apply { packageName = other; enabled = true }
            },
        )
    }

    private fun power() = shadowOf(app.getSystemService(Context.POWER_SERVICE) as PowerManager)
    private fun dpm() = shadowOf(app.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager)
    private fun usage() = shadowOf(app.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager)

    @Test
    fun ownAppRestrictedIsNotDone() {
        power().setIgnoringBatteryOptimizations(app.packageName, false)
        usage().setCurrentAppStandbyBucket(UsageStatsManager.STANDBY_BUCKET_ACTIVE)
        assertFalse(Net.batteryRow(app, app.packageName).done)
    }

    @Test
    fun ownAppAllowlistedIsDone() {
        power().setIgnoringBatteryOptimizations(app.packageName, true)
        assertEquals(BatteryRow.Row(true, "done"), Net.batteryRow(app, app.packageName))
    }

    @Test
    fun ownAppDeviceAdminIsDone() {
        power().setIgnoringBatteryOptimizations(app.packageName, false)
        dpm().setActiveAdmin(ComponentName(app.packageName, "net.fledgewing.orbitcompanion.AdminReceiver"))
        val r = Net.batteryRow(app, app.packageName)
        assertTrue(r.done)
        assertTrue(r.detail, r.detail.startsWith("exempt (device admin)"))
    }

    @Test
    fun ownAppExemptBucketIsDone() {
        power().setIgnoringBatteryOptimizations(app.packageName, false)
        usage().setCurrentAppStandbyBucket(BatteryRow.BUCKET_EXEMPTED)
        assertTrue(Net.batteryRow(app, app.packageName).detail.startsWith("exempt (system)"))
    }

    @Test
    fun otherAppUsesAllowlistAndAdminOnly() {
        // Another package's bucket is not ours to read: only the allowlist and admin count.
        usage().setCurrentAppStandbyBucket(BatteryRow.BUCKET_EXEMPTED)
        power().setIgnoringBatteryOptimizations(other, false)
        assertFalse(Net.batteryRow(app, other).done)
        power().setIgnoringBatteryOptimizations(other, true)
        assertTrue(Net.batteryRow(app, other).done)
    }

    @Test
    fun otherAppMissingIsNotInstalled() {
        assertEquals(BatteryRow.Row(false, "not installed"), Net.batteryRow(app, "com.tailscale.ipn"))
    }
}
