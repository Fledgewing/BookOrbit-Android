// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import android.os.Environment
import android.os.SystemClock
import java.io.File

/** Only copied into the disposable emulator APK. Production composition has no fake clock. */
object ReminderClock {
    private fun value(index:Int):Long? = runCatching {
        val file=File(Environment.getExternalStorageDirectory(),"koreader/settings/e2e-reminder-clock")
        if(!file.isFile || file.length()>80) null else file.readText().trim().split(" ")[index].toLong()
    }.getOrNull()
    fun failSleep():Boolean = value(3)==1L
    fun failSave():Boolean = value(2)==1L
    fun wall():Long = value(0) ?: System.currentTimeMillis()
    fun elapsed():Long = value(1) ?: SystemClock.elapsedRealtime()
}
