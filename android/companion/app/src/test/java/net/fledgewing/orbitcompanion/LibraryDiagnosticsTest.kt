// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import android.content.Context
import android.os.Looper
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.atomic.AtomicReference

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class LibraryDiagnosticsTest {
    private val ctx: Context get() = RuntimeEnvironment.getApplication()
    private fun <T> await(start: ((T) -> Unit) -> Unit): T {
        val result = AtomicReference<T>()
        start { result.set(it) }
        val deadline = System.nanoTime() + 10_000_000_000L
        while (result.get() == null && System.nanoTime() < deadline) {
            shadowOf(Looper.getMainLooper()).idle(); Thread.sleep(10)
        }
        return requireNotNull(result.get()) { "Library callback missing" }
    }
    @Test fun privateNonBackupStoreAndLibrarySnapshotClearCommand() {
        val store = LibraryDiagnostics.store(ctx); store.clear()
        val sentinel = java.io.File(ctx.filesDir,"reading-sentinel").apply { writeText("kept") }
        store.record(IllegalStateException("private message"),"0.12.0")
        assertTrue(java.io.File(ctx.noBackupFilesDir,"companion-crashes.bin").isFile)
        val snapshot = await<LibraryDiagnostics.Snapshot> { LibraryDiagnostics.snapshot(ctx,it) }
        assertEquals(1,snapshot.rows); assertTrue(snapshot.bytes <= 8192); assertTrue(snapshot.canClear)
        assertTrue(snapshot.text.contains("1 matching crashes")); assertFalse(snapshot.text.contains("private message"))
        assertTrue(await<Boolean> { LibraryDiagnostics.clear(ctx,it) })
        val empty = await<LibraryDiagnostics.Snapshot> { LibraryDiagnostics.snapshot(ctx,it) }
        assertFalse(empty.canClear); assertEquals("No companion crash summaries saved.",empty.text)
        assertEquals("kept",sentinel.readText())
    }
    @Test fun corruptionKeepsDetailsAvailableAndCanBeExplicitlyCleared() {
        java.io.File(ctx.noBackupFilesDir,"companion-crashes.bin").writeBytes(byteArrayOf(1,2))
        val snapshot = await<LibraryDiagnostics.Snapshot> { LibraryDiagnostics.snapshot(ctx,it) }
        assertEquals("Crash summary unavailable",snapshot.text); assertTrue(snapshot.canClear)
        assertTrue(snapshot.setup.isNotEmpty())
        assertTrue(await<Boolean> { LibraryDiagnostics.clear(ctx,it) })
    }
}
