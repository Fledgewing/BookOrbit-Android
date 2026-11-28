package net.fledgewing.orbitcompanion

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/** Transparent, reader-requested handoff; Android/security pages themselves remain visible.
 * Its isolated task disappears when the requested page returns. No settings are changed here.
 */
class ReaderActionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) return
        val next=ReaderCompanion.systemIntent(this,intent.getStringExtra("booksync_action"))
        if (next==null) { finish();return }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(next, 1)
        } catch (_: Exception) { finish() }
    }
    @Deprecated("Activity result bridge")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode,resultCode,data)
        finish()
    }
}
