package net.fledgewing.orbitcompanion

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.Handler
import android.os.Looper

/**
 * KOReader's way in (android/docs/INTERFACE.md, docs/design/security.md): the plugin calls
 * `ContentResolver.call(content://net.fledgewing.orbitcompanion.commands, <action>, null, extras)`
 * through KOReader's JNI bridge. Each call is checked first: the calling UID must be the pinned
 * KOReader ([KoreaderTrust]). A command is then run on the main thread as the old broadcast was
 * ([Commands.dispatch]) and the call returns at once; the status call answers with the status JSON.
 * A provider, not a receiver, because the binder tells it who called; a stopped companion is
 * still started for it.
 */
class CommandProvider : ContentProvider() {
    companion object {
        const val AUTHORITY = "${Contract.PACKAGE}.commands"

        /** The status call's method (what `GET /status` was). */
        const val STATUS = "${Contract.PACKAGE}.call.STATUS"

        /** Every command KOReader may send; anything else is refused. */
        val COMMANDS = setOf(
            Contract.NET_UP, Contract.NET_DONE, Contract.WIFI_OFF, Contract.SLEEP_NOW, Contract.SETTINGS, Contract.STATS,
            Contract.RELAUNCH, Contract.SETUP_LATER, Contract.REPORT, SleepScreen.ACTION_POOL,
            Worker.ACTION_MIRROR, Worker.ACTION_CHECK, Worker.ACTION_STORAGE, Worker.ACTION_COPIES, Worker.ACTION_SLEEP_REFRESH,
            Worker.ACTION_RECHECK, Worker.ACTION_SQLITE_STRESS, Worker.ACTION_PATCH, Updater.ACTION_UPDATE,
        )

        fun answer(ok: Boolean, why: String? = null) = Bundle().apply {
            putString("ok", if (ok) "1" else "0")
            why?.let { putString("why", it) }
        }
    }

    private val main by lazy { Handler(Looper.getMainLooper()) }

    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        val ctx = context ?: return null
        val uid = Binder.getCallingUid()
        val token = Binder.clearCallingIdentity()
        try {
            if (!KoreaderTrust.check(ctx, uid)) return answer(false, "caller")
            if (method == STATUS) {
                val svc = OrbitService.current ?: return answer(false, "no service")
                return answer(true).apply { putString("status", svc.answerStatus(extras?.getString("patch_version"), extras?.getString("book"))) }
            }
            if (method !in COMMANDS) {
                OLog.w("command ${Contract.shortName(method)} refused: not a command")
                return answer(false, "unknown")
            }
            val intent = Intent(method).setPackage(ctx.packageName)
            extras?.let { intent.putExtras(it) }
            main.post { Commands.dispatch(ctx, intent) }
            return answer(true)
        } finally {
            Binder.restoreCallingIdentity(token)
        }
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}
