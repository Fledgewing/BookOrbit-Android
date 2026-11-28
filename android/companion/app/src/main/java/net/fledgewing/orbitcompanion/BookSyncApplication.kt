// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import android.app.Application

/** Installs once per process, before activities and workers; never opens UI or reads native logs. */
class BookSyncApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        if (Thread.getDefaultUncaughtExceptionHandler() is CrashSummaryHandler) return
        val store = LibraryDiagnostics.store(this)
        val previous = Thread.getDefaultUncaughtExceptionHandler() ?: Thread.UncaughtExceptionHandler { _, _ ->
            android.os.Process.killProcess(android.os.Process.myPid())
            kotlin.system.exitProcess(10)
        }
        Thread.setDefaultUncaughtExceptionHandler(CrashSummaryHandler({ store.record(it, BuildConfig.VERSION_NAME) }, previous))
    }
}
