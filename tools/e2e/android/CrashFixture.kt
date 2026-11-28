// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import java.io.File

/** Installed only by the external emulator builder; absent from shipping source/manifest. */
class CrashFixtureReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Thread {
            val error = IllegalStateException("synthetic-private-message /Books/private.epub https://private.example account-token")
            error.stackTrace = arrayOf(StackTraceElement("net.fledgewing.orbitcompanion.Worker", "run", "/Books/private.epub", 7))
            throw error
        }.start()
    }
}
class CrashFixtureActivity : Activity() {
    override fun onCreate(state: android.os.Bundle?) {
        super.onCreate(state)
        if (intent.getBooleanExtra("reset", false)) {
            finish()
        } else if (intent.getBooleanExtra("clipboard", false)) {
            // Access clipboard only with this activity in the foreground.
            setContentView(android.widget.TextView(this).apply { text = "Checking support clipboard" })
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                val clip = (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).primaryClip
                File(noBackupFilesDir,"fixture-clipboard.txt").writeText(clip?.getItemAt(0)?.text?.toString().orEmpty())
                finish()
            }, 500)
        } else {
            startActivity(Intent(this,SetupDetailsActivity::class.java)); finish()
        }
    }
}
