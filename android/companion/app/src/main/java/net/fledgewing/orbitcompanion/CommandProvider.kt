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
import android.os.Process
import android.os.SystemClock

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

        /** The plugin asks whether the companion sent the command on KOReader's start (extra `command`). */
        const val TAKE_COMMAND = "${Contract.PACKAGE}.call.TAKE_COMMAND"

        /** The plugin's key and the companion's proof for one `GET /clicks` (ClickChannel). */
        const val CLICKS = "${Contract.PACKAGE}.call.CLICKS"

        /** USB only: the shell (adb, tools/sideload-android.sh) asks for KOReader's restart. */
        const val RESTART_KOREADER = "${Contract.PACKAGE}.call.RESTART_KOREADER"

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
            // The shell already controls the device over USB; it gets this one method and no other.
            if (method == RESTART_KOREADER) {
                if (uid != Process.SHELL_UID) return answer(false, "caller")
                main.post { Koreader.restart(ctx, "adb: restart KOReader") }
                return answer(true)
            }
            if (!KoreaderTrust.check(ctx, uid)) return answer(false, "caller")
            if (method == ServerCommands.START) {
                val encoded = extras?.getString("args")?.takeIf { it.length <= 8192 } ?: return answer(false,"budget")
                val op = extras.getString("op") ?: return answer(false,"missing")
                return try {
                    val args = LuaValue.parse(encoded.toByteArray(Charsets.ISO_8859_1)) as? Map<*, *> ?: return answer(false,"invalid")
                    answer(true).apply { putString("id",ServerCommands.start(ctx,op,args)) }
                } catch (_: Exception) { answer(false,"invalid") }
            }
            if (method == ServerCommands.RESULT) {
                val id = extras?.getString("id")?.takeIf { it.length <= 64 } ?: return answer(false,"invalid")
                return answer(true).apply { putString("body",String(LuaValue.encode(ServerCommands.result(id)),Charsets.ISO_8859_1)) }
            }
            if (method == LibraryAccount.STATE) {
                LibraryAccount.initialize(ctx)
                return answer(true).apply {
                    putString("pending", if (LibraryAccount.ready()) "0" else "1")
                    putString("owner", LibraryAccount.owner())
                    putString("body",String(LuaValue.encode(LibraryAccount.state()),Charsets.ISO_8859_1))
                }
            }
            if (method == LibraryAccount.OPEN) {
                val server = extras?.getString("server").orEmpty()
                main.post { ctx.startActivity(Intent(ctx, AccountActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("server", server)) }
                return answer(true)
            }
            if (method == TAKE_COMMAND) {
                val c = extras?.getString("command")
                val ok = SentCommands.shared.take(c, SystemClock.elapsedRealtime())
                if (!ok) OLog.w("command ${c ?: "-"} on KOReader's start was not sent by the companion")
                return answer(ok)
            }
            if (method == CLICKS) {
                val (key, proof) = ClickChannel.newKey()
                return answer(true).apply { putString("key", key); putString("proof", proof) }
            }
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
